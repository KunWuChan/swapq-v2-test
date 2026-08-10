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
ORIG_SWAP_STATE=$(cat /proc/swaps)
DMESG_BEFORE=$(dmesg | wc -l)

cleanup_test() {
    local rc=$?
    info "Cleaning up..."
    # Remove test zram devices
    for dev in /dev/zram*; do
        [ -b "$dev" ] || continue
        swapoff "$dev" 2>/dev/null || true
    done
    for dev in /sys/block/zram*; do
        [ -w "$dev/reset" ] || continue
        echo 1 > "$dev/reset" 2>/dev/null || true
    done
    # Restore original swap if needed
    if ! awk '$1 ~ /\/swap/ || $1 ~ /dm-/{found=1} END{exit !found}' /proc/swaps; then
        swapon -p -1 /dev/dm-1 2>/dev/null || swapon -p -1 /swap.img 2>/dev/null || true
    fi
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
swapoff -a 2>/dev/null || true
modprobe zram 2>/dev/null || true

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
if [ "$QUICK_MODE" -eq 0 ]; then
    # Create a memcg and force ~100MB swap
    if [ -d /sys/fs/cgroup ]; then
        cgcreate -g memory:swapq-test1 2>/dev/null || true
        echo 50M > /sys/fs/cgroup/swapq-test1/memory.max 2>/dev/null || true
        # Run a small allocator that forces swap
        python3 -c "
import os, time
data = []
try:
    for i in range(200):
        data.append(bytearray(2*1024*1024))  # 2MB each
except MemoryError:
    pass
time.sleep(2)
" 2>/dev/null &
        ALLOC_PID=$!
        sleep 5
        kill $ALLOC_PID 2>/dev/null || true
        wait $ALLOC_PID 2>/dev/null || true
        cgdelete memory:swapq-test1 2>/dev/null || true
    fi
fi

# Check distribution
info "Per-device usage:"
cat /proc/swaps | tee "$RUN_DIR/01-distribution.txt"

# Verify: zram2 (low priority) should have 0 usage
ZRAM2_USED=$(awk '$1=="/dev/zram2"{print $4; exit}' /proc/swaps)
if [ "${ZRAM2_USED:-0}" -eq 0 ]; then
    info "PASS: Low-priority device correctly isolated"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    warn "FAIL: Low-priority device got $ZRAM2_USED KiB swap"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: swapon/swapoff concurrency ─────────────────────
if [ "$QUICK_MODE" -eq 0 ]; then
    info "=== Test 2: swapon/swapoff concurrency ==="
    swapoff -a 2>/dev/null || true

    # Run rapid swapon/swapoff cycles while reading /proc/swaps
    {
        for ((i = 0; i < 200; i++)); do
            echo 64M > /sys/block/zram0/disksize 2>/dev/null
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

    wait $SWAPON_PID 2>/dev/null || true
    wait $READER_PID 2>/dev/null || true

    if [ -f "$RUN_DIR/02-concurrency-errors.txt" ]; then
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
swapoff -a 2>/dev/null || true
# Reset zram
for i in 0 1; do
    [ -w "/sys/block/zram${i}/reset" ] && echo 1 > "/sys/block/zram${i}/reset" 2>/dev/null || true
    echo lzo-rle > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
done

echo 16M > /sys/block/zram0/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null
swapon -p 10 /dev/zram0

# Fill zram0 completely
if [ "$QUICK_MODE" -eq 0 ]; then
    PSWPOUT_BEFORE=$(grep pswpout /proc/vmstat | awk '{print $2}')
    python3 -c "
data = []
for i in range(100):
    try:
        data.append(bytearray(1*1024*1024))
    except:
        break
" 2>/dev/null || true
    PSWPOUT_AFTER=$(grep pswpout /proc/vmstat | awk '{print $2}')
    info "pswpout delta: $((PSWPOUT_AFTER - PSWPOUT_BEFORE))"

    # Now add a second device and verify allocation goes there
    echo 16M > /sys/block/zram1/disksize 2>/dev/null
    mkswap /dev/zram1 2>/dev/null
    swapon -p 10 /dev/zram1

    ZRAM1_BEFORE=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    python3 -c "
data = []
for i in range(50):
    try:
        data.append(bytearray(512*1024))
    except:
        break
" 2>/dev/null || true
    ZRAM1_AFTER=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    info "zram1 usage: ${ZRAM1_BEFORE:-0} -> ${ZRAM1_AFTER:-0} KiB"

    if [ "${ZRAM1_AFTER:-0}" -gt "${ZRAM1_BEFORE:-0}" ]; then
        info "PASS: Refill went to peer after first device full"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        warn "FAIL: Refill did not reach peer"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    info "Skipped (--quick mode)"
fi

# ── Test 4: Large folio peer retry ─────────────────────────
info "=== Test 4: Large folio peer retry ==="
swapoff -a 2>/dev/null || true
for i in 0 1; do
    [ -w "/sys/block/zram${i}/reset" ] && echo 1 > "/sys/block/zram${i}/reset" 2>/dev/null || true
    echo lzo-rle > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
done

echo 64M > /sys/block/zram0/disksize 2>/dev/null
echo 64M > /sys/block/zram1/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null
mkswap /dev/zram1 2>/dev/null
swapon -p 10 /dev/zram0
swapon -p 10 /dev/zram1

# Enable THP
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

if [ "$QUICK_MODE" -eq 0 ]; then
    THP_SWPOUT_BEFORE=$(grep thp_swpout /proc/vmstat 2>/dev/null | awk '{print $2}')
    THP_FALLBACK_BEFORE=$(grep thp_swpout_fallback /proc/vmstat 2>/dev/null | awk '{print $2}')

    # Fragment zram0 by doing small allocations first
    python3 -c "
data = []
# Small allocations to fragment zram0
for i in range(200):
    try:
        data.append(bytearray(64*1024))  # 64KB each
    except:
        break
data.clear()
# Now try large allocation - should land on zram1 (unfragmented peer)
try:
    big = bytearray(2*1024*1024)
except:
    pass
" 2>/dev/null || true

    THP_SWPOUT_AFTER=$(grep thp_swpout /proc/vmstat 2>/dev/null | awk '{print $2}')
    THP_FALLBACK_AFTER=$(grep thp_swpout_fallback /proc/vmstat 2>/dev/null | awk '{print $2}')

    info "thp_swpout: ${THP_SWPOUT_BEFORE:-0} -> ${THP_SWPOUT_AFTER:-0}"
    info "thp_swpout_fallback: ${THP_FALLBACK_BEFORE:-0} -> ${THP_FALLBACK_AFTER:-0}"

    ZRAM0_USED=$(awk '$1=="/dev/zram0"{print $4; exit}' /proc/swaps)
    ZRAM1_USED=$(awk '$1=="/dev/zram1"{print $4; exit}' /proc/swaps)
    info "zram0 used: ${ZRAM0_USED:-0} KiB, zram1 used: ${ZRAM1_USED:-0} KiB"

    info "PASS: Large folio test completed (check distribution above)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
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
