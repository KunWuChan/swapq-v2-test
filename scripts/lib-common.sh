#!/bin/bash
# Common functions for swapq-v2 testing
# Source this from other scripts: . "$(dirname "$0")/lib-common.sh"

set -euo pipefail

# Paths
TEST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="/home/chentao/mm"
PATCH_DIR="$TEST_DIR/patches"
RESULT_DIR="$TEST_DIR/results"
CONFIG_DIR="$TEST_DIR/configs"
SCRIPT_DIR="$TEST_DIR/scripts"

# ARM definitions
# These are set up by 00-apply-patches.sh:
#   swapq-v2-base  → current mm-unstable HEAD (Arm D)
#   swapq-v2       → base + 13 patches (Arm E)
declare -A ARM_BRANCHES=(
    [D]="swapq-v2-base"
    [E]="swapq-v2"
)
declare -A ARM_DESC=(
    [D]="v2 base (mm-unstable)"
    [E]="v2 current (13 patches)"
)

# Build settings (override via env)
BUILD_JOBS=${BUILD_JOBS:-$(nproc)}
KERNEL_CONFIG=${KERNEL_CONFIG:-$CONFIG_DIR/base.config}

# Test settings
ZRAM_TOTAL_SIZE=${ZRAM_TOTAL_SIZE:-64G}
ZRAM_DEVICES=${ZRAM_DEVICES:-8}
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
    if [[ ! "$hostname" =~ kp ]]; then
        warn "Expected hostname matching 'kp', got '$hostname'. Continue? [y/N]"
        read -r ans
        [[ "$ans" == "y" ]] || exit 1
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
    if [[ "$kver" =~ -swapq-D ]]; then
        echo "D"
    elif [[ "$kver" =~ -swapq-E ]]; then
        echo "E"
    else
        echo "unknown"
    fi
}

# Get kernel version string for an ARM
get_kernel_version() {
    local arm=$1
    local branch=${ARM_BRANCHES[$arm]}
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

# Restore system state: remove test zram/swap, restore /swap.img
cleanup_swap_state() {
    info "Cleaning up swap state..."
    local dev

    # Stop all swap on zram
    for dev in /dev/zram*; do
        [ -b "$dev" ] || continue
        swapoff "$dev" 2>/dev/null || true
    done

    # Reset zram devices
    for dev in /sys/block/zram*; do
        [ -w "$dev/reset" ] || continue
        echo 1 > "$dev/reset" 2>/dev/null || true
    done

    # Restore root swap if missing
    if ! awk '$1 ~ /\/swap/ || $1 ~ /dm-/{found=1} END{exit !found}' /proc/swaps; then
        if [ -f /swap.img ] || [ -b /dev/dm-1 ]; then
            local swapdev="/swap.img"
            [ -b /dev/dm-1 ] && swapdev="/dev/dm-1"
            swapon -p -1 "$swapdev" 2>/dev/null || warn "Could not restore $swapdev"
        fi
    fi

    info "Current swap state:"
    cat /proc/swaps
}

# Setup zram swap devices for testing
# Args: count [total_size] [algo]
setup_zram_swap() {
    local count=${1:-8}
    local total_size=${2:-$ZRAM_TOTAL_SIZE}
    local algo=${3:-lzo-rle}
    local i

    info "Setting up $count zram devices (total $total_size, $algo)"
    modprobe zram 2>/dev/null || true

    for ((i = 0; i < count; i++)); do
        # Find next free zram device
        local dev
        dev=$(zramctl -f 2>/dev/null || echo "/dev/zram$i")
        if [ ! -b "$dev" ]; then
            warn "zram$i not available, stopping at $i devices"
            break
        fi
        echo "$algo" > "/sys/block/zram${i}/comp_algorithm" 2>/dev/null || true
        echo "$total_size" > "/sys/block/zram${i}/disksize" 2>/dev/null || true
        mkswap "$dev" 2>/dev/null
        swapon -p 10 "$dev" 2>/dev/null  # same priority for all
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
