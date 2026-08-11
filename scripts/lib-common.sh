#!/bin/bash
# Common functions for swapq-v2 testing
# Source this from other scripts: . "$(dirname "$0")/lib-common.sh"

set -euo pipefail

# Paths
TEST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC=${KERNEL_SRC:-/home/chentao/mm}
PATCH_DIR=${PATCH_DIR:-$TEST_DIR/patches}
V1_PATCH_DIR=${V1_PATCH_DIR:-$TEST_DIR/patches-v1}
BASE_BUNDLE=${BASE_BUNDLE:-$TEST_DIR/bundles/swapq-v2-base-from-v1-base.bundle}
RESULT_DIR=${RESULT_DIR:-$TEST_DIR/results}
CONFIG_DIR=${CONFIG_DIR:-$TEST_DIR/configs}
SCRIPT_DIR="$TEST_DIR/scripts"
BUILD_ROOT=${BUILD_ROOT:-/home/chentao/swapq-build}

# Exact comparison points.  Never silently move Arm D to a newer rebased
# mm-unstable commit: doing so makes the D/E attribution invalid.
BASE_COMMIT=${BASE_COMMIT:-94f9b3980dd446b56acf1dfed649e9b32a9f3813}
EXPECTED_V2_TREE=${EXPECTED_V2_TREE:-e41508faa11f60c1d4cf73051a0a9e38534352d5}
V1_BEFORE_COMMIT=${V1_BEFORE_COMMIT:-bdc38bfc1262e3d1432afadd2aa2ffd83d139dbb}
V1_PATCH8_COMMIT=${V1_PATCH8_COMMIT:-4a7d8bd1b6644d139f5aa9074141437aa3b060a3}
V1_PATCH13_COMMIT=${V1_PATCH13_COMMIT:-a438694aa41a39aaaa23926e14d7560c147f6af3}
V1_BEFORE_TREE=${V1_BEFORE_TREE:-57ee9934fd5312d2d89d51806206d772ae784e4a}
V1_PATCH8_TREE=${V1_PATCH8_TREE:-8597824ce792d0f77b2e06674f69e93e3e2d0a3b}
V1_PATCH13_TREE=${V1_PATCH13_TREE:-d03738f4dbd68439c82db25078ec0bcb584f7735}
BASE_TREE=${BASE_TREE:-0dd2a1e02d48d4689ef2a46c7f3797927cdcf9ef}
BASE_BUNDLE_SHA256=${BASE_BUNDLE_SHA256:-adf3a20e597d6ead3a459158c1ffb4fecd2cd628bf233b1049f44c23f2de1c9a}

# ARM definitions
# These are set up by 00-apply-patches.sh:
#   swapq-v1-before  → v1 parent (Arm A)
#   swapq-v1-patch8  → v1 through patch 8 (Arm B)
#   swapq-v1-patch13 → complete v1 (Arm C)
#   swapq-v2-base    → exact v2 base commit (Arm D)
#   swapq-v2         → base + 13 patches (Arm E)
arm_branch() {
    case "$1" in
        A) echo swapq-v1-before ;;
        B) echo swapq-v1-patch8 ;;
        C) echo swapq-v1-patch13 ;;
        D) echo swapq-v2-base ;;
        E) echo swapq-v2 ;;
        *) return 1 ;;
    esac
}

arm_desc() {
    case "$1" in
        A) echo "v1 parent (before queue patches)" ;;
        B) echo "v1 through patch 8" ;;
        C) echo "v1 complete (through patch 13)" ;;
        D) echo "v2 exact base" ;;
        E) echo "v2 current (13 patches)" ;;
        *) return 1 ;;
    esac
}

arm_expected_commit() {
    case "$1" in
        A) echo "$V1_BEFORE_COMMIT" ;;
        D) echo "$BASE_COMMIT" ;;
        B|C|E) return 1 ;;
        *) return 1 ;;
    esac
}

arm_expected_tree() {
    case "$1" in
        A) echo "$V1_BEFORE_TREE" ;;
        B) echo "$V1_PATCH8_TREE" ;;
        C) echo "$V1_PATCH13_TREE" ;;
        D) echo "$BASE_TREE" ;;
        E) echo "$EXPECTED_V2_TREE" ;;
        *) return 1 ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        error "Neither sha256sum nor shasum is available"
        return 1
    fi
}

# Build settings (override via env)
cpu_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
    else
        echo 1
    fi
}

BUILD_JOBS=${BUILD_JOBS:-$(cpu_count)}
KERNEL_CONFIG=${KERNEL_CONFIG:-$CONFIG_DIR/base.config}
MIN_BUILD_FREE_GIB=${MIN_BUILD_FREE_GIB:-20}
MIN_BOOT_FREE_MIB=${MIN_BOOT_FREE_MIB:-1024}

# Test settings
ZRAM_DEVICES=${ZRAM_DEVICES:-8}
ZRAM_DEVICE_SIZE=${ZRAM_DEVICE_SIZE:-8G}
BUILD_REPETITIONS=${BUILD_REPETITIONS:-12}
BUILD_JOBS_BENCH=${BUILD_JOBS_BENCH:-96}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }

# Verify we're on kp-server
check_host() {
    local hostname
    hostname=$(hostname)
    if [[ ! "$hostname" =~ kp ]] && [ "${ALLOW_NON_KP_HOST:-0}" != 1 ]; then
        error "Expected hostname matching 'kp', got '$hostname'"
        error "Set ALLOW_NON_KP_HOST=1 only for an explicitly approved host"
        exit 1
    fi
}

# Verify kernel source exists
check_kernel_src() {
    if [ ! -d "$KERNEL_SRC/.git" ]; then
        error "Kernel source not found at $KERNEL_SRC"
        exit 1
    fi
}

# Check current ARM from running kernel version tag
# The build script tags kernels with -swapq-{ARM} suffix
detect_running_arm() {
    local kver
    kver=$(uname -r)
    if [[ "$kver" =~ -swapq-([A-E])([^-A-Za-z0-9]|$) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Get kernel version string for an ARM
get_kernel_version() {
    local arm=$1
    local branch
    branch=$(arm_branch "$arm")
    cd "$KERNEL_SRC"
    local commit_short
    commit_short=$(git rev-parse --short=12 "$branch")
    local base_ver
    base_ver=$(make -s kernelversion 2>/dev/null || echo "7.1.0-rc5")
    echo "${base_ver}-swapq-${arm}-g${commit_short}"
}

# Verify dmesg is clean (no BUG/WARNING/Oops/panic/lockdep/KASAN/KCSAN/UBSAN/stall)
check_dmesg_clean() {
    local label=${1:-test}
    local result_file="$RESULT_DIR/dmesg-${label}-$(date +%Y%m%d-%H%M%S).txt"
    dmesg > "$result_file"
    local bad=0
    for pattern in 'BUG:' 'WARNING:' 'Oops:' 'kernel panic' 'KASAN:' 'KCSAN:' 'UBSAN:' \
                   'soft lockup' 'hard LOCKUP' 'rcu.*stall' 'hung_task' 'Call Trace:.*\n.*WARNING'; do
        if grep -E -q "$pattern" "$result_file"; then
            error "Found '$pattern' in dmesg"
            bad=1
        fi
    done
    if [ "$bad" -eq 0 ]; then
        info "dmesg clean ($label)"
        return 0
    else
        return 1
    fi
}

snapshot_swap_state() {
    local output=$1
    awk 'NR > 1 { print $1, $5 }' /proc/swaps > "$output"
}

restore_swap_state() {
    local snapshot=$1
    local failed=0 dev prio

    while read -r dev prio; do
        [ -n "$dev" ] || continue
        if ! awk -v target="$dev" 'NR > 1 && $1 == target { found=1 }
                END { exit !found }' /proc/swaps; then
            swapon -p "$prio" "$dev" || failed=1
        fi
    done < "$snapshot"

    if [ "$failed" -ne 0 ]; then
        error "Failed to restore one or more original swap devices"
        return 1
    fi
}

cleanup_zram_devices() {
    local count=${1:-$ZRAM_DEVICES}
    local i

    for ((i = 0; i < count; i++)); do
        [ -b "/dev/zram$i" ] || continue
        swapoff "/dev/zram$i" 2>/dev/null || true
        [ -w "/sys/block/zram$i/reset" ] &&
            echo 1 > "/sys/block/zram$i/reset" 2>/dev/null || true
    done
}

# Setup zram swap devices for testing
# Args: count [per_device_size] [algo]
setup_zram_swap() {
    local count=${1:-8}
    local device_size=${2:-$ZRAM_DEVICE_SIZE}
    local algo=${3:-lzo-rle}
    local i

    info "Setting up $count zram devices (${device_size} each, $algo)"
    modprobe zram 2>/dev/null || true

    for ((i = 0; i < count; i++)); do
        local dev="/dev/zram$i"
        [ -b "$dev" ] || { error "$dev is unavailable"; return 1; }
        if awk -v target="$dev" 'NR > 1 && $1 == target { found=1 }
                END { exit !found }' /proc/swaps; then
            error "$dev is already active; refusing to reuse it"
            return 1
        fi
        [ -w "/sys/block/zram$i/reset" ] &&
            echo 1 > "/sys/block/zram$i/reset" 2>/dev/null || true
        echo "$algo" > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
        echo "$device_size" > "/sys/block/zram${i}/disksize"
        mkswap "$dev" >/dev/null
        swapon -p 10 "$dev"
    done

    info "Swap after zram setup:"
    cat /proc/swaps
}

# Save a timestamped result file
save_result() {
    local name=$1
    local arm=$2
    local run_dir="$RESULT_DIR/arm-${arm}"
    mkdir -p "$run_dir"
    local out="$run_dir/${name}-$(date +%Y%m%d-%H%M%S).txt"
    cat > "$out"
    echo "$out"
}

# Record VM counters delta
vm_counters_snapshot() {
    awk '/^pg/ || /^workingset/ || /^pswp/ || /^thp/ || /^compact/ || /^oom/ {
        print $1, $2
    }' /proc/vmstat
}

# Compute VM counter deltas between two snapshots
vm_counters_delta() {
    local before=$1
    local after=$2
    join -j1 <(sort "$before") <(sort "$after") | \
        awk '{delta=$3-$2; if(delta!=0) printf "%-40s %+d\n", $1, delta}' | \
        sort -t: -k2 -rn
}
