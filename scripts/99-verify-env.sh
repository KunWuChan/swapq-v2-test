#!/bin/bash
# Quick environment verification - runs on the CURRENT kernel
# No build required. Verifies that:
#   1. Required tools are available
#   2. zram can be loaded and used
#   3. memcg is working
#   4. THP is available
#   5. swap basic functionality works

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

FAILS=0

echo "=========================================="
echo "Swap Queue v2 - Environment Verification"
echo "Kernel: $(uname -r)"
echo "Date:   $(date)"
echo "=========================================="

# ── 1. Required commands ───────────────────────────────────
info "--- Checking required commands ---"
for cmd in make git cc gcc ld awk grep python3 mkswap swapon swapoff modprobe zramctl; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd"
    else
        fail "$cmd (not found)"
        FAILS=$((FAILS + 1))
    fi
done

# Optional
for cmd in cgcreate cgexec cgdelete usemem; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd (optional)"
    else
        info "$cmd not found (optional, needed for full benchmarks)"
    fi
done

# ── 2. Kernel config ───────────────────────────────────────
info "--- Checking kernel config ---"
check_config() {
    local opt=$1
    local expected=$2
    if [ -f /proc/config.gz ]; then
        local val=$(zcat /proc/config.gz | grep "^${opt}=" | head -1)
        if echo "$val" | grep -qE "${expected}"; then
            pass "$opt = $val"
        else
            fail "$opt = $val (expected $expected)"
            FAILS=$((FAILS + 1))
        fi
    elif [ -f "/boot/config-$(uname -r)" ]; then
        local val=$(grep "^${opt}=" "/boot/config-$(uname -r)" | head -1)
        if echo "$val" | grep -qE "${expected}"; then
            pass "$opt = $val"
        else
            fail "$opt = $val (expected $expected)"
            FAILS=$((FAILS + 1))
        fi
    else
        info "$opt: cannot check (no config found)"
    fi
}

check_config CONFIG_SWAP "y"
check_config CONFIG_ZRAM "[my]"
check_config CONFIG_MEMCG "y"
check_config CONFIG_TRANSPARENT_HUGEPAGE "y"
check_config CONFIG_BLK_DEV_RAM "y|m"

# ── 3. ZRAM test ───────────────────────────────────────────
info "--- Testing zram ---"
ORIG_SWAPS=$(cat /proc/swaps)

swapoff -a 2>/dev/null || true
modprobe zram 2>/dev/null || true

# Reset any existing zram
for dev in /sys/block/zram*; do
    [ -w "$dev/reset" ] && echo 1 > "$dev/reset" 2>/dev/null || true
done

# Create a test zram
echo lzo-rle > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo 64M > /sys/block/zram0/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null

if swapon /dev/zram0 2>/dev/null; then
    pass "zram0 swap enabled"
    cat /proc/swaps | grep zram
else
    fail "Could not enable zram0 swap"
    FAILS=$((FAILS + 1))
fi

# Cleanup
swapoff /dev/zram0 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true

# Restore original swap
echo "$ORIG_SWAPS" | while read -r line; do
    dev=$(echo "$line" | awk 'NR>1{print $1}')
    prio=$(echo "$line" | awk 'NR>1{print $5}')
    [ -n "$dev" ] || continue
    swapon -p "${prio:--1}" "$dev" 2>/dev/null || true
done

# ── 4. Memory cgroup test ──────────────────────────────────
info "--- Testing memcg ---"
if [ -d /sys/fs/cgroup ] && command -v cgcreate &>/dev/null; then
    cgcreate -g memory:swapq-verify 2>/dev/null || true
    if [ -d /sys/fs/cgroup/swapq-verify ]; then
        echo 50M > /sys/fs/cgroup/swapq-verify/memory.max 2>/dev/null && \
            pass "memcg memory.max set to 50M" || \
            fail "Cannot set memory.max (cgroup v1?)"
        cgdelete memory:swapq-verify 2>/dev/null || true
    else
        fail "Cannot create memcg"
        FAILS=$((FAILS + 1))
    fi
else
    info "memcg not tested (cgroup fs or cgcreate missing)"
fi

# ── 5. THP check ───────────────────────────────────────────
info "--- THP status ---"
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    THP_STATUS=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
    info "THP: $THP_STATUS"
    pass "THP available"
else
    info "THP not available"
fi

# ── 6. CPU and memory ──────────────────────────────────────
info "--- System resources ---"
echo "CPU cores: $(nproc)"
echo "CPU model: $(grep 'model name' /proc/cpuinfo | head -1 | sed 's/.*: //')"
free -h | grep -E 'Mem:|Swap:'

# ── 7. Disk space ──────────────────────────────────────────
info "--- Disk space ---"
df -h / /boot 2>/dev/null || df -h /

# ── Summary ─────────────────────────────────────────────────
echo ""
echo "=========================================="
if [ "$FAILS" -eq 0 ]; then
    pass "All checks passed! Environment is ready."
    echo ""
    echo "Next steps:"
    echo "  1. bash scripts/00-apply-patches.sh"
    echo "  2. bash scripts/01-build-arm.sh D"
    echo "  3. bash scripts/01-build-arm.sh E"
    echo "  4. bash scripts/02-switch-kernel.sh E"
    echo "  5. bash scripts/03-run-functional.sh"
    echo "  6. bash scripts/04-run-benchmark.sh 2g"
else
    fail "$FAILS check(s) failed. Fix before proceeding."
fi
echo "=========================================="
