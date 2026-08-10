#!/bin/bash
# Quick environment verification - runs on the CURRENT kernel
# No build required. Verifies that:
#   1. Required tools are available
#   2. zram can be loaded and used
#   3. memcg is working
#   4. THP is available
#   5. swap basic functionality works without disabling existing swap

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

FAILS=0

HOSTNAME_NOW=$(hostname)
if [[ ! "$HOSTNAME_NOW" =~ kp ]] && [ "${ALLOW_NON_KP_HOST:-0}" != 1 ]; then
    fail "Expected hostname matching 'kp', got '$HOSTNAME_NOW'"
    exit 1
fi

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
for cmd in usemem; do
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
info "--- Testing one unused zram device ---"
modprobe zram 2>/dev/null || true
TEST_ZRAM=$(zramctl -f 2>/dev/null || true)
if [ -z "$TEST_ZRAM" ]; then
    fail "No unused zram device is available; existing devices were left untouched"
    FAILS=$((FAILS + 1))
else
    ZRAM_NAME=${TEST_ZRAM#/dev/}
    cleanup_verify_zram() {
        swapoff "$TEST_ZRAM" 2>/dev/null || true
        [ -w "/sys/block/$ZRAM_NAME/reset" ] &&
            echo 1 > "/sys/block/$ZRAM_NAME/reset" 2>/dev/null || true
    }
    trap cleanup_verify_zram EXIT

    echo lzo-rle > "/sys/block/$ZRAM_NAME/comp_algorithm" 2>/dev/null || true
    echo 64M > "/sys/block/$ZRAM_NAME/disksize"
    mkswap "$TEST_ZRAM" >/dev/null
    if swapon -p 10 "$TEST_ZRAM"; then
        pass "$TEST_ZRAM swap enabled; pre-existing swap remained active"
        awk -v target="$TEST_ZRAM" 'NR == 1 || $1 == target' /proc/swaps
    else
        fail "Could not enable $TEST_ZRAM"
        FAILS=$((FAILS + 1))
    fi
    cleanup_verify_zram
    trap - EXIT
fi

# ── 4. Memory cgroup test ──────────────────────────────────
info "--- Testing cgroup v2 memory controller ---"
VERIFY_CG=/sys/fs/cgroup/swapq-verify-$$
if [ -f /sys/fs/cgroup/cgroup.controllers ] &&
        grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    if mkdir "$VERIFY_CG" && echo 50M > "$VERIFY_CG/memory.max"; then
        pass "cgroup v2 memory.max set to 50M"
        rmdir "$VERIFY_CG"
    else
        fail "Cannot create or configure $VERIFY_CG"
        rmdir "$VERIFY_CG" 2>/dev/null || true
        FAILS=$((FAILS + 1))
    fi
else
    fail "cgroup v2 memory controller is required by the benchmark scripts"
    FAILS=$((FAILS + 1))
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
    echo "  2. for arm in A B C D E; do bash scripts/01-build-arm.sh \"\$arm\"; done"
    echo "  3. bash scripts/02-switch-kernel.sh E"
    echo "  4. bash scripts/03-run-functional.sh"
    echo "  5. bash scripts/04-run-benchmark.sh 2g"
else
    fail "$FAILS check(s) failed. Fix before proceeding."
fi
echo "=========================================="
