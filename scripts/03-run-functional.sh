#!/bin/bash
# Run functional tests for the currently running swapq kernel
# Usage: bash 03-run-functional.sh [--quick]
#
# Tests:
#   1. kernel identity verification
#   2. same-priority distribution (3 zram: 2 same prio + 1 low prio)
#   3. swapon/swapoff concurrency stress
#   4. full/unmask/refill cycle
#   5. large-folio same-ring peer retry
#   6. dmesg cleanliness

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host
[ "$(detect_running_arm)" = E ] || {
    error "Functional queue tests must run on the identified Arm E kernel"
    exit 1
}

QUICK_MODE=0
if [ "${1:-}" == "--quick" ]; then
    QUICK_MODE=1
fi

RUN_DIR="$RESULT_DIR/functional-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
TESTS_PASSED=0
TESTS_FAILED=0

info "=========================================="
info "Swap Queue v2 Functional Tests"
info "Kernel: $(uname -r)"
info "Results: $RUN_DIR"
info "=========================================="

# ── Helper: exit trap ──────────────────────────────────────
ORIG_SWAP_STATE="$RUN_DIR/original-swaps.txt"
snapshot_swap_state "$ORIG_SWAP_STATE"
ORIG_THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)
DMESG_BEFORE=$(dmesg | wc -l)

if [ "$(id -u)" -ne 0 ]; then
    error "Functional tests must run as root"
    exit 1
fi
if [ ! -f /sys/fs/cgroup/cgroup.controllers ] ||
        ! grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    error "Functional tests require cgroup v2 with the memory controller"
    exit 1
fi

start_memcg_alloc() {
    local name=$1 limit=$2 bytes=$3 hold=${4:-30}
    ALLOC_CG="/sys/fs/cgroup/$name"
    mkdir "$ALLOC_CG"
    echo "$limit" > "$ALLOC_CG/memory.max"
    echo max > "$ALLOC_CG/memory.swap.max"
    CG_PATH="$ALLOC_CG" ALLOC_BYTES="$bytes" HOLD_SECS="$hold" python3 -c '
import os, time
cg = os.environ["CG_PATH"]
with open(cg + "/cgroup.procs", "w") as f:
    f.write(str(os.getpid()))
size = int(os.environ["ALLOC_BYTES"])
data = bytearray(size)
page = os.urandom(4096)
for i in range(0, size, 4096):
    data[i:i + 4096] = page[:min(4096, size - i)]
print("allocated", size, flush=True)
time.sleep(int(os.environ["HOLD_SECS"]))
' > "$RUN_DIR/${name}.log" 2>&1 &
    ALLOC_PID=$!
}

stop_memcg_alloc() {
    local pid=${1:-} cg=${2:-}
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    [ -n "$cg" ] && rmdir "$cg" 2>/dev/null || true
}

cleanup_test() {
    local rc=$?
    info "Cleaning up..."
    stop_memcg_alloc "${ALLOC_PID:-}" "${ALLOC_CG:-}"
    cleanup_zram_devices 3
    restore_swap_state "$ORIG_SWAP_STATE" || rc=1
    case "$ORIG_THP" in
        *\[always\]*) echo always > /sys/kernel/mm/transparent_hugepage/enabled ;;
        *\[madvise\]*) echo madvise > /sys/kernel/mm/transparent_hugepage/enabled ;;
        *\[never\]*) echo never > /sys/kernel/mm/transparent_hugepage/enabled ;;
    esac
    exit "$rc"
}
trap cleanup_test EXIT

# ── Test 0: Pre-test dmesg check ───────────────────────────
info "=== Test 0: Pre-test environment ==="
echo "uname: $(uname -r)" | tee "$RUN_DIR/00-env.txt"
echo "cpu: $(nproc) cores" | tee -a "$RUN_DIR/00-env.txt"
echo "mem: $(free -h | grep Mem)" | tee -a "$RUN_DIR/00-env.txt"
cat /proc/swaps | tee -a "$RUN_DIR/00-env.txt"

# ── Test 1: Same-priority distribution ─────────────────────
info "=== Test 1: Same-priority distribution ==="
swapoff -a
modprobe -r zram 2>/dev/null || true
modprobe zram num_devices=3 2>/dev/null || modprobe zram 2>/dev/null || true

# Create 3 zram devices: zram0,zram1 at prio 10, zram2 at prio 0
for i in 0 1 2; do
    echo lzo-rle > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
    echo 256M > "/sys/block/zram${i}/disksize" 2>/dev/null
    mkswap "/dev/zram${i}" 2>/dev/null
done
swapon -p 10 /dev/zram0
swapon -p 10 /dev/zram1
swapon -p 0  /dev/zram2

info "Swap layout:"
cat /proc/swaps

# Allocate swap pages using memcg pressure
PSWPOUT_BEFORE=0
if [ "$QUICK_MODE" -eq 0 ]; then
        PSWPOUT_BEFORE=$(awk '$1 == "pswpout" { print $2 }' /proc/vmstat)
        start_memcg_alloc swapq-test1 50M $((400 * 1024 * 1024)) 30
        sleep 8
fi

# Check distribution
info "Per-device usage:"
cat /proc/swaps | tee "$RUN_DIR/01-distribution.txt"

# Verify: zram2 (low priority) should have 0 usage
ZRAM2_USED=$(awk '$1=="/dev/zram2"{print $4; exit}' /proc/swaps)
ZRAM0_USED=$(awk '$1=="/dev/zram0"{print $4; exit}' /proc/swaps)
ZRAM1_USED=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
PSWPOUT_AFTER=$(awk '$1 == "pswpout" { print $2 }' /proc/vmstat)
ALLOC_ALIVE=0
[ -n "${ALLOC_PID:-}" ] && kill -0 "$ALLOC_PID" 2>/dev/null && ALLOC_ALIVE=1
stop_memcg_alloc "${ALLOC_PID:-}" "${ALLOC_CG:-}"
unset ALLOC_PID ALLOC_CG
if [ "$QUICK_MODE" -eq 1 ]; then
    info "Skipped distribution pressure (--quick mode)"
elif [ "$ALLOC_ALIVE" -eq 1 ] && [ "${ZRAM2_USED:-0}" -eq 0 ] &&
        [ "${ZRAM0_USED:-0}" -gt 0 ] &&
        [ "${ZRAM1_USED:-0}" -gt 0 ] &&
        [ "$PSWPOUT_AFTER" -gt "$PSWPOUT_BEFORE" ]; then
    info "PASS: both same-priority devices used; low-priority device isolated"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    warn "FAIL: no proven same-priority distribution (z0=${ZRAM0_USED:-0}, z1=${ZRAM1_USED:-0}, z2=${ZRAM2_USED:-0})"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: swapon/swapoff concurrency ─────────────────────
if [ "$QUICK_MODE" -eq 0 ]; then
    info "=== Test 2: swapon/swapoff concurrency ==="
    swapoff -a

    # Run rapid swapon/swapoff cycles while reading /proc/swaps
    {
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        echo lzo-rle > /sys/block/zram0/comp_algorithm 2>/dev/null || true
        echo 64M > /sys/block/zram0/disksize 2>/dev/null
        for ((i = 0; i < 200; i++)); do
            mkswap /dev/zram0 2>/dev/null
            swapon -p 5 /dev/zram0 2>/dev/null
            swapoff /dev/zram0 2>/dev/null
        done
    } &
    SWAPON_PID=$!

    # Concurrent /proc/swaps reader
    {
        for ((i = 0; i < 2000; i++)); do
            awk 'NF==5 && $1~/zram/{print $1, $4}' /proc/swaps 2>/dev/null || true
            # Check for malformed lines
            if cat /proc/swaps | grep -q '^$\|^[^/F]'; then
                echo "MALFORMED_ROW" >> "$RUN_DIR/02-concurrency-errors.txt"
            fi
        done
    } &
    READER_PID=$!

    SWAPON_RC=0
    READER_RC=0
    wait "$SWAPON_PID" || SWAPON_RC=$?
    wait "$READER_PID" || READER_RC=$?

    if [ -f "$RUN_DIR/02-concurrency-errors.txt" ] ||
            [ "$SWAPON_RC" -ne 0 ] || [ "$READER_RC" -ne 0 ]; then
        warn "FAIL: Malformed /proc/swaps rows detected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        info "PASS: No concurrency issues detected"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
else
    info "Skipped (--quick mode)"
fi

# ── Test 3: Full/unmask/refill ─────────────────────────────
info "=== Test 3: Full/unmask/refill ==="
swapoff -a
# Reset zram
for i in 0 1; do
    [ -w "/sys/block/zram${i}/reset" ] && echo 1 > "/sys/block/zram${i}/reset" 2>/dev/null || true
    echo lzo-rle > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
done

echo 64M > /sys/block/zram0/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null
swapon -p 10 /dev/zram0

# Fill zram0 completely
if [ "$QUICK_MODE" -eq 0 ]; then
    PSWPOUT_BEFORE=$(grep pswpout /proc/vmstat | awk '{print $2}')
    start_memcg_alloc swapq-full 8M $((48 * 1024 * 1024)) 30
    FULL_PID=$ALLOC_PID
    FULL_CG=$ALLOC_CG
    sleep 5
    FULL_ALIVE=0
    kill -0 "$FULL_PID" 2>/dev/null && FULL_ALIVE=1
    ZRAM0_USED=$(awk '$1=="/dev/zram0"{print $4; exit}' /proc/swaps)
    PSWPOUT_AFTER=$(grep pswpout /proc/vmstat | awk '{print $2}')
    info "pswpout delta: $((PSWPOUT_AFTER - PSWPOUT_BEFORE))"

    # Now add a second device and verify allocation goes there
    echo 48M > /sys/block/zram1/disksize 2>/dev/null
    mkswap /dev/zram1 2>/dev/null
    swapon -p 10 /dev/zram1

    ZRAM1_BEFORE=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    start_memcg_alloc swapq-refill 8M $((48 * 1024 * 1024)) 20
    REFILL_PID=$ALLOC_PID
    REFILL_CG=$ALLOC_CG
    sleep 5
    REFILL_ALIVE=0
    kill -0 "$REFILL_PID" 2>/dev/null && REFILL_ALIVE=1
    ZRAM1_AFTER=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    info "zram1 usage: ${ZRAM1_BEFORE:-0} -> ${ZRAM1_AFTER:-0} KiB"

    if [ "$FULL_ALIVE" -eq 1 ] && [ "$REFILL_ALIVE" -eq 1 ] &&
            [ "${ZRAM0_USED:-0}" -ge 12288 ] &&
            [ "$PSWPOUT_AFTER" -gt "$PSWPOUT_BEFORE" ] &&
            [ "${ZRAM1_AFTER:-0}" -gt "${ZRAM1_BEFORE:-0}" ]; then
        info "PASS: Refill went to peer after first device full"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        warn "FAIL: no proven full/peer refill (z0=${ZRAM0_USED:-0} KiB, z1=${ZRAM1_AFTER:-0} KiB)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    stop_memcg_alloc "$REFILL_PID" "$REFILL_CG"
    stop_memcg_alloc "$FULL_PID" "$FULL_CG"
    unset ALLOC_PID ALLOC_CG
else
    info "Skipped (--quick mode)"
fi

# ── Test 4: Large folio peer retry ─────────────────────────
info "=== Test 4: Large folio peer retry ==="
swapoff -a
for i in 0 1; do
    [ -w "/sys/block/zram${i}/reset" ] && echo 1 > "/sys/block/zram${i}/reset" 2>/dev/null || true
    echo lzo-rle > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
done

echo 48M > /sys/block/zram0/disksize 2>/dev/null
echo 64M > /sys/block/zram1/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null
mkswap /dev/zram1 2>/dev/null
swapon -p 10 /dev/zram0

# Enable THP
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

if [ "$QUICK_MODE" -eq 0 ]; then
    # Keep zram0 almost full with base-page swap, then add an empty peer.
    start_memcg_alloc swapq-large-prefill 8M $((48 * 1024 * 1024)) 30
    PREFILL_PID=$ALLOC_PID
    PREFILL_CG=$ALLOC_CG
    sleep 5
    PREFILL_ALIVE=0
    kill -0 "$PREFILL_PID" 2>/dev/null && PREFILL_ALIVE=1
    ZRAM0_BEFORE=$(awk '$1=="/dev/zram0"{print $4; exit}' /proc/swaps)
    swapon -p 10 /dev/zram1
    ZRAM1_BEFORE=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)

    THP_SWPOUT_BEFORE=$(awk '$1 == "thp_swpout" { print $2 }' /proc/vmstat)
    THP_FALLBACK_BEFORE=$(awk '$1 == "thp_swpout_fallback" { print $2 }' /proc/vmstat)

    python3 -c '
import ctypes, mmap, time, os
MB = 1024 * 1024
length = 32 * MB
mapping = mmap.mmap(-1, length, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS,
                    prot=mmap.PROT_READ | mmap.PROT_WRITE)
base = ctypes.addressof(ctypes.c_char.from_buffer(mapping))
aligned = (base + 16 * MB - 1) & ~(16 * MB - 1)
offset = aligned - base
libc = ctypes.CDLL(None, use_errno=True)
if libc.madvise(ctypes.c_void_p(aligned), ctypes.c_size_t(16 * MB), 14) != 0:
    raise OSError(ctypes.get_errno(), "MADV_HUGEPAGE")
page = os.urandom(4096)
for pos in range(offset, offset + 16 * MB, 4096):
    mapping[pos:pos + 4096] = page
time.sleep(1)
if libc.madvise(ctypes.c_void_p(aligned), ctypes.c_size_t(16 * MB), 21) != 0:
    raise OSError(ctypes.get_errno(), "MADV_PAGEOUT")
time.sleep(5)
' > "$RUN_DIR/04-large-folio-helper.log" 2>&1

    THP_SWPOUT_AFTER=$(grep thp_swpout /proc/vmstat 2>/dev/null | awk '{print $2}')
    THP_FALLBACK_AFTER=$(grep thp_swpout_fallback /proc/vmstat 2>/dev/null | awk '{print $2}')

    info "thp_swpout: ${THP_SWPOUT_BEFORE:-0} -> ${THP_SWPOUT_AFTER:-0}"
    info "thp_swpout_fallback: ${THP_FALLBACK_BEFORE:-0} -> ${THP_FALLBACK_AFTER:-0}"

    ZRAM0_USED=$(awk '$1=="/dev/zram0"{print $4; exit}' /proc/swaps)
    ZRAM1_USED=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    info "zram0 used: ${ZRAM0_USED:-0} KiB, zram1 used: ${ZRAM1_USED:-0} KiB"

    TOTAL_SWAP_AFTER=$(( ${ZRAM0_USED:-0} + ${ZRAM1_USED:-0} ))
    TOTAL_SWAP_BEFORE=${ZRAM0_BEFORE:-0}

    if [ "$PREFILL_ALIVE" -eq 1 ] &&
            [ "${ZRAM0_BEFORE:-0}" -gt 0 ] &&
            [ "${THP_SWPOUT_AFTER:-0}" -gt "${THP_SWPOUT_BEFORE:-0}" ] &&
            [ "${THP_FALLBACK_AFTER:-0}" -eq "${THP_FALLBACK_BEFORE:-0}" ] &&
            [ "$TOTAL_SWAP_AFTER" -gt "$TOTAL_SWAP_BEFORE" ]; then
        info "PASS: THP swapout increased (no fallback), swap usage grew after peer available"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        warn "FAIL: THP swapout did not grow or fallback occurred (z0=${ZRAM0_USED:-0} KiB, z1=${ZRAM1_USED:-0} KiB, thp_delta=$(( ${THP_SWPOUT_AFTER:-0} - ${THP_SWPOUT_BEFORE:-0} )))"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    stop_memcg_alloc "$PREFILL_PID" "$PREFILL_CG"
    unset ALLOC_PID ALLOC_CG
else
    info "Skipped (--quick mode)"
fi

# ── Test 5: Dmesg check ────────────────────────────────────
info "=== Test 5: Dmesg cleanliness ==="
DMESG_AFTER=$(dmesg | wc -l)
DMESG_DELTA=$((DMESG_AFTER - DMESG_BEFORE))
info "dmesg lines added: $DMESG_DELTA"

dmesg | tail -n "$DMESG_DELTA" > "$RUN_DIR/05-dmesg-delta.txt"
if grep -qEi 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|soft lockup|hard LOCKUP|rcu.*stall|hung_task' "$RUN_DIR/05-dmesg-delta.txt"; then
    warn "FAIL: Kernel failure signatures in dmesg delta:"
    grep -Ei 'BUG:|WARNING:|Oops:|panic|KASAN:|KCSAN:|UBSAN:|soft lockup|hard LOCKUP|rcu.*stall|hung_task' "$RUN_DIR/05-dmesg-delta.txt"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    info "PASS: dmesg clean"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
info "=========================================="
info "Functional Tests Complete"
info "Passed: $TESTS_PASSED"
info "Failed: $TESTS_FAILED"
info "Results: $RUN_DIR"
info "=========================================="

cat /proc/swaps | tee "$RUN_DIR/99-final-swap.txt"

if [ "$TESTS_FAILED" -gt 0 ]; then
    error "Some tests FAILED"
    exit 1
fi

info "All tests PASSED"
exit 0
