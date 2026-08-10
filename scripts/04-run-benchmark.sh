#!/bin/bash
# Run swap priority queue v2 performance benchmarks
# Usage: bash 04-run-benchmark.sh <2g|3g|brd> [--quick]
#
#   2g  = kernel build, make -j96, 2GiB memcg, 8 ZRAM
#   3g  = kernel build, make -j96, 3GiB memcg, 8 ZRAM
#   brd = 12 brd devices, explicitly sized usemem workload

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host

WORKLOAD="${1:-}"
QUICK_MODE=0
if [ "${2:-}" == "--quick" ]; then
    QUICK_MODE=1
fi

if [ -z "$WORKLOAD" ]; then
    echo "Usage: $0 <2g|3g|brd> [--quick]"
    echo ""
    echo "  2g  - kernel build, make -j96, 2 GiB memcg, 8 equal-priority ZRAM"
    echo "  3g  - kernel build, make -j96, 3 GiB memcg, 8 equal-priority ZRAM"
    echo "  brd - 12 brd devices, explicitly sized usemem workload"
    echo ""
    echo "  --quick  run only warm-up (no measured repetitions)"
    exit 1
fi

# ── Configuration ──────────────────────────────────────────
KERNEL_SRC_ARCHIVE=${KERNEL_SRC_ARCHIVE:-/root/linux.tar.xz}
KERNEL_ARCHIVE_STRIP_COMPONENTS=${KERNEL_ARCHIVE_STRIP_COMPONENTS:-1}
WARMUP=1
MEASURED=${MEASURED:-12}
if [ "$QUICK_MODE" -eq 1 ]; then
    WARMUP=1
    MEASURED=0
fi

ARM_LABEL=$(detect_running_arm)
[[ "$ARM_LABEL" =~ ^[A-E]$ ]] || {
    error "Running kernel is not an identified Arm A-E kernel"
    exit 1
}
RUN_DIR="$RESULT_DIR/arm-${ARM_LABEL}/bench-${WORKLOAD}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
ORIG_SWAP_STATE="$RUN_DIR/original-swaps.txt"
snapshot_swap_state "$ORIG_SWAP_STATE"
if [ "$(id -u)" -ne 0 ]; then
    error "Benchmarks must run as root"
    exit 1
fi
if [ ! -f /sys/fs/cgroup/cgroup.controllers ] ||
        ! grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    error "Benchmarks require cgroup v2 with the memory controller"
    exit 1
fi
if grep -Eq '^/dev/(zram|ram)[0-9]+ ' "$ORIG_SWAP_STATE"; then
    error "Pre-existing zram/brd swap is active; refusing to overwrite it"
    exit 1
fi
ACTIVE_CG=""
ACTIVE_SRC=""
ACTIVE_BUILD_PID=""
ACTIVE_SAMPLER_PID=""
BRD_ACTIVE=0

cleanup_benchmark() {
    local rc=$?
    [ -n "$ACTIVE_SAMPLER_PID" ] && kill "$ACTIVE_SAMPLER_PID" 2>/dev/null || true
    [ -n "$ACTIVE_BUILD_PID" ] && kill "$ACTIVE_BUILD_PID" 2>/dev/null || true
    [ -n "$ACTIVE_BUILD_PID" ] && wait "$ACTIVE_BUILD_PID" 2>/dev/null || true
    cleanup_zram_devices "$ZRAM_DEVICES"
    if [ "$BRD_ACTIVE" -eq 1 ]; then
        local i
        for ((i = 0; i < 12; i++)); do
            swapoff "/dev/ram$i" 2>/dev/null || true
        done
        rmmod brd 2>/dev/null || true
    fi
    if [ -n "$ACTIVE_CG" ] && [ -d "$ACTIVE_CG" ]; then
        rmdir "$ACTIVE_CG" 2>/dev/null || true
    fi
    if [ -n "$ACTIVE_SRC" ] && [[ "$ACTIVE_SRC" == /tmp/swapq-build-src-* ]]; then
        rm -rf -- "$ACTIVE_SRC"
    fi
    restore_swap_state "$ORIG_SWAP_STATE" || rc=1
    exit "$rc"
}
trap cleanup_benchmark EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
info "Running benchmark on ARM: $ARM_LABEL"

# ── Kernel source preparation ──────────────────────────────
prepare_linux_src() {
    if [ ! -f "$KERNEL_SRC_ARCHIVE" ]; then
        error "A fixed kernel source archive is required: $KERNEL_SRC_ARCHIVE"
        exit 1
    fi
    info "Using kernel source archive: $KERNEL_SRC_ARCHIVE"
    local sha
    sha=$(sha256sum "$KERNEL_SRC_ARCHIVE" | awk '{print $1}')
    if [ -n "${KERNEL_SRC_SHA256:-}" ] && [ "$sha" != "$KERNEL_SRC_SHA256" ]; then
        error "Kernel source archive SHA-256 mismatch"
        exit 1
    fi
    echo "$sha  $KERNEL_SRC_ARCHIVE" > "$RUN_DIR/source.sha256"
}

# ── ZRAM setup ─────────────────────────────────────────────
setup_zram_bench() {
    local count=${1:-8}
    local device_size=${2:-$ZRAM_DEVICE_SIZE}
    local algo=${3:-lzo-rle}

    info "Setting up $count zram devices (${device_size} each, $algo)"

    # Disable root swap
    swapoff -a

    modprobe zram 2>/dev/null || true

    cleanup_zram_devices "$count"
    setup_zram_swap "$count" "$device_size" "$algo"

    # Verify: all devices active, same priority
    local active_cnt
    active_cnt=$(awk '$1 ~ /^\/dev\/zram[0-9]+$/{cnt++} END{print cnt+0}' /proc/swaps)
    local prio_cnt
    prio_cnt=$(awk '$1 ~ /^\/dev\/zram[0-9]+$/{print $5}' /proc/swaps | sort -u | wc -l)

    info "Active zram devices: $active_cnt, unique priorities: $prio_cnt"
    cat /proc/swaps

    if [ "$active_cnt" -ne "$count" ]; then
        error "Expected $count zram devices, got $active_cnt"
        exit 1
    fi
}

# ── Sample peak swap usage during build ────────────────────
sample_swap_peaks() {
    local watched_pid=$1
    local output=$2
    local zram_count=$3
    local -a peaks=()
    local i

    for ((i = 0; i < zram_count; i++)); do peaks[$i]=0; done

    while kill -0 "$watched_pid" 2>/dev/null; do
        while read -r dev _ _ used _; do
            case "$dev" in
                /dev/zram*)
                    i=${dev#/dev/zram}
                    [ "$i" -lt "$zram_count" ] || continue
                    [ "$used" -le "${peaks[$i]}" ] || peaks[$i]=$used
                    ;;
            esac
        done < /proc/swaps
        sleep 2
    done

    {
        printf 'peak_used_kib'
        for ((i = 0; i < zram_count; i++)); do
            printf ' zram%d=%d' "$i" "${peaks[$i]}"
        done
        printf '\n'
    } > "$output"
}

# ── Run a single build sample ──────────────────────────────
run_build_sample() {
    local memory_bytes=$1
    local memory_label=$2
    local sample_label=$3
    local measured=$4   # 0=warmup, 1=measured
    local zram_count=${5:-8}

    local kernel_tag
    kernel_tag=$(uname -r | tr -c 'A-Za-z0-9._-' '-')
    local sample_dir="$RUN_DIR/${sample_label}"
    mkdir -p "$sample_dir"

    echo "=== SWAPQ_BENCH_SAMPLE_BEGIN memory=$memory_label sample=$sample_label measured=$measured ==="
    echo "kernel=$kernel_tag"
    echo "timestamp=$(date -Iseconds)"

    # Setup ZRAM
    setup_zram_bench "$zram_count" "$ZRAM_DEVICE_SIZE"

    # VM counters before
    vm_counters_snapshot > "$sample_dir/vmstat.before"

    # Dmesg before
    local dmesg_before_lines
    dmesg_before_lines=$(dmesg | wc -l)

    # Create memcg
    local cg_name="swapq-bench-${ARM_LABEL}-${memory_label}-${sample_label}"
    local cg_path="/sys/fs/cgroup/${cg_name}"
    mkdir "$cg_path"
    echo "$memory_bytes" > "$cg_path/memory.max"
    echo "$memory_bytes" > "$cg_path/memory.high"
    echo max > "$cg_path/memory.swap.max"
    ACTIVE_CG="$cg_path"

    # Start the kernel build inside memcg
    local build_pid
    info "Starting kernel build (memcg=${memory_label}, sample=${sample_label})..."

    # Prepare source dir
    local src_dir="/tmp/swapq-build-src-${ARM_LABEL}-${memory_label}-${sample_label}"
    rm -rf "$src_dir"
    ACTIVE_SRC="$src_dir"
    mkdir -p "$src_dir"
    tar -xf "$KERNEL_SRC_ARCHIVE" -C "$src_dir" \
        "--strip-components=$KERNEL_ARCHIVE_STRIP_COMPONENTS"

    # Build inside cgroup
    CG_PATH="$cg_path" bash -c '
        echo $$ > "$CG_PATH/cgroup.procs"
        exec "$@"
    ' _ /usr/bin/time -o "$sample_dir/time.txt" -v \
        make -C "$src_dir" -j"$BUILD_JOBS_BENCH" defconfig bzImage modules \
        > "$sample_dir/build.log" 2>&1 &
    build_pid=$!
    ACTIVE_BUILD_PID=$build_pid

    # Sample peaks in background
    sample_swap_peaks "$build_pid" "$sample_dir/peak-swap.txt" "$zram_count" &
    local sampler_pid=$!
    ACTIVE_SAMPLER_PID=$sampler_pid

    # Wait for build
    local build_rc=0
    wait "$build_pid" || build_rc=$?
    wait "$sampler_pid" 2>/dev/null || true
    ACTIVE_BUILD_PID=""
    ACTIVE_SAMPLER_PID=""

    # VM counters after
    vm_counters_snapshot > "$sample_dir/vmstat.after"
    vm_counters_delta "$sample_dir/vmstat.before" "$sample_dir/vmstat.after" > "$sample_dir/vmstat.delta"

    # Dmesg delta
    dmesg | tail -n "+$((dmesg_before_lines + 1))" > "$sample_dir/dmesg.delta"

    # Check for OOM
    local oom_kill
    oom_kill=$(awk '$1 == "oom_kill" { print $2 }' "$cg_path/memory.events")
    local pswpout_delta
    pswpout_delta=$(awk '$1 == "pswpout" { print $2 }' "$sample_dir/vmstat.delta" | tr -d '+')
    local dmesg_bad=0
    grep -qEi 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|soft lockup|hard LOCKUP|rcu.*stall|hung task' \
        "$sample_dir/dmesg.delta" && dmesg_bad=1

    # Results
    echo "build_exit=$build_rc"
    echo "oom_kill=$oom_kill"
    echo "peak_swap:"
    cat "$sample_dir/peak-swap.txt"
    echo "system_time: $(grep 'System time' "$sample_dir/time.txt" 2>/dev/null || echo 'N/A')"
    echo "elapsed_time: $(grep 'Elapsed' "$sample_dir/time.txt" 2>/dev/null || echo 'N/A')"
    echo "=== SWAPQ_BENCH_SAMPLE_END ==="

    # Cleanup
    rmdir "$cg_path"
    ACTIVE_CG=""
    cleanup_zram_devices "$zram_count"
    restore_swap_state "$ORIG_SWAP_STATE"
    rm -rf -- "$src_dir"
    ACTIVE_SRC=""

    # Record result
    {
        echo "sample=$sample_label"
        echo "measured=$measured"
        echo "build_exit=$build_rc"
        echo "oom_kill=$oom_kill"
        echo "pswpout_delta=${pswpout_delta:-0}"
        echo "dmesg_bad=$dmesg_bad"
        grep 'peak_used_kib' "$sample_dir/peak-swap.txt" 2>/dev/null || echo "peak_used_kib=N/A"
        grep -E 'System time|Elapsed' "$sample_dir/time.txt" 2>/dev/null || echo "time=N/A"
    } > "$sample_dir/result.txt"

    if [ "$build_rc" -ne 0 ] || [ "$oom_kill" -ne 0 ] ||
            [ "${pswpout_delta:-0}" -le 0 ] || [ "$dmesg_bad" -ne 0 ]; then
        return 1
    fi
    return 0
}

# ── BRD benchmark ──────────────────────────────────────────
run_brd_sample() {
    local sample_label=$1
    local measured=$2
    local brd_count=12
    local per_size_mb=${BRD_DEVICE_SIZE_MIB:-}
    local per_thread_mib=${BRD_PER_THREAD_MIB:-}
    local sample_dir="$RUN_DIR/${sample_label}"
    mkdir -p "$sample_dir"

    info "=== BRD sample: $sample_label ==="

    if [ -z "$per_size_mb" ] || [ -z "$per_thread_mib" ]; then
        error "Set BRD_DEVICE_SIZE_MIB and BRD_PER_THREAD_MIB explicitly"
        error "Use BRD_PER_THREAD_MIB=1536 for the original v1 workload"
        return 1
    fi

    swapoff -a
    modprobe brd "rd_nr=$brd_count" "rd_size=$((per_size_mb * 1024))" 2>/dev/null || modprobe brd 2>/dev/null
    BRD_ACTIVE=1

    # Create swap on each brd
    for ((i = 0; i < brd_count; i++)); do
        [ -b "/dev/ram${i}" ] || continue
        mkswap "/dev/ram${i}" 2>/dev/null
        swapon -p 10 "/dev/ram${i}" 2>/dev/null
    done

    info "BRD swap:"
    cat /proc/swaps

    vm_counters_snapshot > "$sample_dir/vmstat.before"
    local dmesg_before_lines
    dmesg_before_lines=$(dmesg | wc -l)
    local oom_before pswpout_before
    oom_before=$(awk '$1 == "oom_kill" { print $2 }' /proc/vmstat)
    pswpout_before=$(awk '$1 == "pswpout" { print $2 }' /proc/vmstat)

    local usemem_rc=0
    /usr/bin/time -o "$sample_dir/time.txt" -v \
        usemem --init-time -O -y -x -n 32 "${per_thread_mib}M" \
        > "$sample_dir/usemem.log" 2>&1 || usemem_rc=$?

    vm_counters_snapshot > "$sample_dir/vmstat.after"
    vm_counters_delta "$sample_dir/vmstat.before" "$sample_dir/vmstat.after" > "$sample_dir/vmstat.delta"

    dmesg | tail -n "+$((dmesg_before_lines + 1))" > "$sample_dir/dmesg.delta"

    local oom_after pswpout_after oom_delta pswpout_delta dmesg_bad used_devices
    oom_after=$(awk '$1 == "oom_kill" { print $2 }' /proc/vmstat)
    pswpout_after=$(awk '$1 == "pswpout" { print $2 }' /proc/vmstat)
    oom_delta=$((oom_after - oom_before))
    pswpout_delta=$((pswpout_after - pswpout_before))
    dmesg_bad=0
    grep -qEi 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|lockup|rcu.*stall|hung task' \
        "$sample_dir/dmesg.delta" && dmesg_bad=1
    used_devices=$(awk 'NR > 1 && $1 ~ /^\/dev\/ram[0-9]+$/ && $4 > 0 { n++ } END { print n+0 }' /proc/swaps)

    {
        echo "sample=$sample_label"
        echo "measured=$measured"
        echo "build_exit=$usemem_rc"
        echo "oom_kill=$oom_delta"
        echo "pswpout_delta=$pswpout_delta"
        echo "dmesg_bad=$dmesg_bad"
        echo "used_devices=$used_devices"
    } > "$sample_dir/result.txt"

    # Throughput extraction (if kmb helpers available)
    if command -v kmb-grep-usemem.sh &>/dev/null; then
        kmb-grep-usemem.sh --throughput-sum "$sample_dir/usemem.log" 2>/dev/null | tee "$sample_dir/throughput.txt"
    fi

    # Cleanup
    for ((i = 0; i < brd_count; i++)); do
        swapoff "/dev/ram${i}" 2>/dev/null || true
    done
    rmmod brd 2>/dev/null || true
    BRD_ACTIVE=0

    if [ "$usemem_rc" -ne 0 ] || [ "$oom_delta" -ne 0 ] ||
            [ "$pswpout_delta" -le 0 ] || [ "$dmesg_bad" -ne 0 ] ||
            [ "$used_devices" -lt 2 ]; then
        error "BRD sample failed one or more validity gates"
        return 1
    fi
}

# ── Main ────────────────────────────────────────────────────
prepare_linux_src

info "=========================================="
info "Benchmark: $WORKLOAD"
info "Kernel: $(uname -r)"
info "ARM: $ARM_LABEL"
info "Warmup: $WARMUP, Measured: $MEASURED"
info "Source: $KERNEL_SRC_ARCHIVE"
info "Results: $RUN_DIR"
info "=========================================="

case "$WORKLOAD" in
    2g)
        MEMORY_BYTES=2147483648
        MEMORY_LABEL="2g"
        ZRAM_COUNT=8
        ;;
    3g)
        MEMORY_BYTES=3221225472
        MEMORY_LABEL="3g"
        ZRAM_COUNT=8
        ;;
    brd)
        # BRD is a single-sample test (no warmup/measured distinction)
        run_brd_sample "brd-001" 1
        info "BRD test complete. Results: $RUN_DIR"
        exit 0
        ;;
    *)
        error "Unknown workload: $WORKLOAD"
        exit 1
        ;;
esac

# Warm-up
info "=== WARM-UP ==="
run_build_sample "$MEMORY_BYTES" "$MEMORY_LABEL" "warmup" 0 "$ZRAM_COUNT" || {
    error "Warm-up failed; measured repetitions are blocked"
    exit 1
}

# Measured repetitions
for sample_num in $(seq -w 1 "$MEASURED"); do
    info "=== SAMPLE $sample_num / $MEASURED ==="
    run_build_sample "$MEMORY_BYTES" "$MEMORY_LABEL" "sample-${sample_num}" 1 "$ZRAM_COUNT" || {
        error "Sample $sample_num failed; refusing to mix it into statistics"
        exit 1
    }
done

# Restore root swap
restore_swap_state "$ORIG_SWAP_STATE"

trap - EXIT INT TERM

info "=========================================="
info "Benchmark $WORKLOAD complete!"
info "Results: $RUN_DIR"
info ""
info "Extract times:"
info "  grep -r 'elapsed_time\|system_time' $RUN_DIR/*/time.txt"
info "=========================================="
