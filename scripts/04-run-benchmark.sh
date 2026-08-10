#!/bin/bash
# Run swap priority queue v2 performance benchmarks
# Usage: bash 04-run-benchmark.sh <2g|3g|brd> [--quick]
#
#   2g  = kernel build, make -j96, 2GiB memcg, 8 ZRAM
#   3g  = kernel build, make -j96, 3GiB memcg, 8 ZRAM
#   brd = 12 brd devices, usemem -n 32 160M (scaled VM workload)

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

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
    echo "  brd - 12 brd devices, usemem -n 32 160M (scaled VM, needs ~5.5 GiB)"
    echo ""
    echo "  --quick  run only warm-up (no measured repetitions)"
    exit 1
fi

# ── Configuration ──────────────────────────────────────────
KERNEL_SRC_ARCHIVE=${KERNEL_SRC_ARCHIVE:-/root/linux.tar.xz}
WARMUP=1
MEASURED=${MEASURED:-12}
if [ "$QUICK_MODE" -eq 1 ]; then
    WARMUP=1
    MEASURED=0
fi

RUN_DIR="$RESULT_DIR/bench-${WORKLOAD}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
ARM_LABEL=$(detect_running_arm)
info "Running benchmark on ARM: $ARM_LABEL"

# ── Kernel source preparation ──────────────────────────────
prepare_linux_src() {
    if [ -f "$KERNEL_SRC_ARCHIVE" ]; then
        info "Using kernel source archive: $KERNEL_SRC_ARCHIVE"
        local sha
        sha=$(sha256sum "$KERNEL_SRC_ARCHIVE" | awk '{print $1}')
        info "SHA-256: $sha"
    elif [ -d /root/linux ]; then
        info "Using /root/linux as kernel source"
        KERNEL_SRC_ARCHIVE="/root/linux"
    else
        warn "No kernel source archive at $KERNEL_SRC_ARCHIVE"
        warn "Setting KERNEL_SRC_ARCHIVE to use the current mm tree"
        KERNEL_SRC_ARCHIVE="$KERNEL_SRC"
    fi
}

# ── ZRAM setup ─────────────────────────────────────────────
setup_zram_bench() {
    local count=${1:-8}
    local total_size=${2:-64G}
    local algo=${3:-lzo-rle}

    info "Setting up $count zram devices (total $total_size, $algo)"

    # Disable root swap
    swapoff -a 2>/dev/null || true

    modprobe zram 2>/dev/null || true

    # Reset existing zram devices
    for dev in /sys/block/zram*; do
        [ -w "$dev/reset" ] || continue
        echo 1 > "$dev/reset" 2>/dev/null || true
    done

    # Create zram devices
    for ((i = 0; i < count; i++)); do
        echo "$algo" > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
        echo "$total_size" > "/sys/block/zram${i}/disksize" 2>/dev/null || true
        mkswap "/dev/zram${i}" 2>/dev/null
        swapon -p 10 "/dev/zram${i}" 2>/dev/null
    done

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
    setup_zram_bench "$zram_count" "$ZRAM_TOTAL_SIZE"

    # VM counters before
    vm_counters_snapshot > "$sample_dir/vmstat.before"

    # Dmesg before
    local dmesg_before_lines
    dmesg_before_lines=$(dmesg | wc -l)

    # Create memcg
    local cg_name="swapq-bench-${memory_label}-${sample_label}"
    cgcreate -g memory:"$cg_name" 2>/dev/null || true
    echo "$memory_bytes" > "/sys/fs/cgroup/${cg_name}/memory.max" 2>/dev/null || true
    echo "$memory_bytes" > "/sys/fs/cgroup/${cg_name}/memory.high" 2>/dev/null || true

    # Start the kernel build inside memcg
    local build_pid
    info "Starting kernel build (memcg=${memory_label}, sample=${sample_label})..."

    # Prepare source dir
    local src_dir="/tmp/swapq-build-src-${sample_label}"
    rm -rf "$src_dir"
    if [ -f "$KERNEL_SRC_ARCHIVE" ]; then
        mkdir -p "$src_dir"
        tar -xf "$KERNEL_SRC_ARCHIVE" -C "$src_dir" --strip-components=1 2>/dev/null || \
            tar -xf "$KERNEL_SRC_ARCHIVE" -C "$src_dir" 2>/dev/null
    else
        cp -r "$KERNEL_SRC_ARCHIVE" "$src_dir"
    fi

    # Build inside cgroup
    cgexec -g memory:"$cg_name" \
        /usr/bin/time -o "$sample_dir/time.txt" -v \
        make -C "$src_dir" -j"$BUILD_JOBS_BENCH" defconfig bzImage modules 2>&1 \
        > "$sample_dir/build.log" &
    build_pid=$!

    # Sample peaks in background
    sample_swap_peaks "$build_pid" "$sample_dir/peak-swap.txt" "$zram_count" &
    local sampler_pid=$!

    # Wait for build
    local build_rc=0
    wait "$build_pid" || build_rc=$?
    wait "$sampler_pid" 2>/dev/null || true

    # VM counters after
    vm_counters_snapshot > "$sample_dir/vmstat.after"
    vm_counters_delta "$sample_dir/vmstat.before" "$sample_dir/vmstat.after" > "$sample_dir/vmstat.delta"

    # Dmesg delta
    dmesg | tail -n "+$((dmesg_before_lines + 1))" > "$sample_dir/dmesg.delta"

    # Check for OOM
    local oom_kill=0
    grep -q "oom_kill" "$sample_dir/dmesg.delta" 2>/dev/null && oom_kill=1

    # Results
    echo "build_exit=$build_rc"
    echo "oom_kill=$oom_kill"
    echo "peak_swap:"
    cat "$sample_dir/peak-swap.txt"
    echo "system_time: $(grep 'System time' "$sample_dir/time.txt" 2>/dev/null || echo 'N/A')"
    echo "elapsed_time: $(grep 'Elapsed' "$sample_dir/time.txt" 2>/dev/null || echo 'N/A')"
    echo "=== SWAPQ_BENCH_SAMPLE_END ==="

    # Cleanup
    cgdelete memory:"$cg_name" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    for dev in /sys/block/zram*; do
        [ -w "$dev/reset" ] && echo 1 > "$dev/reset" 2>/dev/null || true
    done

    # Record result
    {
        echo "sample=$sample_label"
        echo "measured=$measured"
        echo "build_exit=$build_rc"
        echo "oom_kill=$oom_kill"
        grep 'peak_used_kib' "$sample_dir/peak-swap.txt" 2>/dev/null || echo "peak_used_kib=N/A"
        grep -E 'System time|Elapsed' "$sample_dir/time.txt" 2>/dev/null || echo "time=N/A"
    } > "$sample_dir/result.txt"

    return "$build_rc"
}

# ── BRD benchmark ──────────────────────────────────────────
run_brd_sample() {
    local sample_label=$1
    local measured=$2
    local brd_count=12
    local brd_total_mb=2040
    local per_size_mb=$((brd_total_mb / brd_count))
    local sample_dir="$RUN_DIR/${sample_label}"
    mkdir -p "$sample_dir"

    info "=== BRD sample: $sample_label ==="

    swapoff -a 2>/dev/null || true
    modprobe brd "rd_nr=$brd_count" "rd_size=$((per_size_mb * 1024))" 2>/dev/null || modprobe brd 2>/dev/null

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

    /usr/bin/time -o "$sample_dir/time.txt" -v \
        usemem --init-time -O -y -x -n 32 160M 2>&1 | tee "$sample_dir/usemem.log"

    vm_counters_snapshot > "$sample_dir/vmstat.after"
    vm_counters_delta "$sample_dir/vmstat.before" "$sample_dir/vmstat.after" > "$sample_dir/vmstat.delta"

    dmesg | tail -n "+$((dmesg_before_lines + 1))" > "$sample_dir/dmesg.delta"

    # Throughput extraction (if kmb helpers available)
    if command -v kmb-grep-usemem.sh &>/dev/null; then
        kmb-grep-usemem.sh --throughput-sum "$sample_dir/usemem.log" 2>/dev/null | tee "$sample_dir/throughput.txt"
    fi

    # Cleanup
    swapoff -a 2>/dev/null || true
    rmmod brd 2>/dev/null || true
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
    warn "Warm-up failed with exit code $?"
}

# Measured repetitions
for sample_num in $(seq -w 1 "$MEASURED"); do
    info "=== SAMPLE $sample_num / $MEASURED ==="
    run_build_sample "$MEMORY_BYTES" "$MEMORY_LABEL" "sample-${sample_num}" 1 "$ZRAM_COUNT" || {
        warn "Sample $sample_num failed, continuing..."
    }
done

# Restore root swap
swapon -p -1 /dev/dm-1 2>/dev/null || swapon -p -1 /swap.img 2>/dev/null || true

info "=========================================="
info "Benchmark $WORKLOAD complete!"
info "Results: $RUN_DIR"
info ""
info "Extract times:"
info "  grep -r 'elapsed_time\|system_time' $RUN_DIR/*/time.txt"
info "=========================================="
