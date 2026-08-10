#!/bin/bash
# Build a kernel for a specific ARM (D or E)
# Usage: bash 01-build-arm.sh <D|E> [--config <config-file>]

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

ARM="${1:-}"
if [ -z "$ARM" ] || [ -z "${ARM_BRANCHES[$ARM]:-}" ]; then
    echo "Usage: $0 <D|E> [--config <file>]"
    echo "  D = v2 base (mm-unstable without patches)"
    echo "  E = v2 current (mm-unstable + 13 patches)"
    exit 1
fi

# Parse optional --config
CONFIG_FILE="$KERNEL_CONFIG"
if [ "${2:-}" == "--config" ] && [ -n "${3:-}" ]; then
    CONFIG_FILE="$3"
fi

BRANCH="${ARM_BRANCHES[$ARM]}"
DESC="${ARM_DESC[$ARM]}"
KVER=$(get_kernel_version "$ARM")

info "=========================================="
info "Building ARM $ARM: $DESC"
info "Branch: $BRANCH"
info "Kernel version: $KVER"
info "Config: $CONFIG_FILE"
info "Jobs: $BUILD_JOBS"
info "=========================================="

check_kernel_src
cd "$KERNEL_SRC"

# Checkout the branch
info "Checking out branch $BRANCH..."
git checkout "$BRANCH"

# Verify branch state
CURRENT_COMMIT=$(git rev-parse --short HEAD)
info "Building from commit: $CURRENT_COMMIT"

# Prepare config
if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
    error "Get it from running kernel: zcat /proc/config.gz > $CONFIG_FILE"
    error "Or: cp /boot/config-\$(uname -r) $CONFIG_FILE"
    exit 1
fi

info "Preparing kernel config..."
cp "$CONFIG_FILE" .config

# Set local version to identify this ARM
sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"-swapq-${ARM}\"/" .config
# Also use CONFIG_LOCALVERSION_AUTO for git describe
sed -i 's/.*CONFIG_LOCALVERSION_AUTO=.*/CONFIG_LOCALVERSION_AUTO=y/' .config

# Update config for new kernel version
make olddefconfig 2>&1 | tail -3

# Verify key options
info "Verifying key config options..."
for opt in CONFIG_SWAP CONFIG_ZRAM CONFIG_MEMCG CONFIG_TRANSPARENT_HUGEPAGE; do
    val=$(grep "^${opt}=" .config || echo "NOT_FOUND")
    case "$opt" in
        CONFIG_ZRAM) info "  $opt=$val (expected: m or y)" ;;
        *) info "  $opt=$val (expected: y)" ;;
    esac
done

# Build kernel
info "Building kernel (this will take a while)..."
BUILD_LOG="$RESULT_DIR/build-arm-${ARM}-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$RESULT_DIR"

make -j"$BUILD_JOBS" 2>&1 | tee "$BUILD_LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    error "Kernel build FAILED. Log: $BUILD_LOG"
    exit 1
fi
info "Kernel build OK"

# Install modules
info "Installing modules..."
make modules_install 2>&1 | tail -5

# Install kernel
info "Installing kernel..."
make install 2>&1 | tail -5

# Verify installation
BOOT_IMAGE="/boot/vmlinuz-${KVER}"
BOOT_INITRD="/boot/initramfs-${KVER}.img"
BOOT_SYSTEM_MAP="/boot/System.map-${KVER}"

if [ -f "$BOOT_IMAGE" ]; then
    info "Boot image: $BOOT_IMAGE ($(du -h "$BOOT_IMAGE" | cut -f1))"
else
    # Try to find the installed image
    BOOT_IMAGE=$(ls -t /boot/vmlinuz-*swapq-${ARM}* 2>/dev/null | head -1)
    if [ -z "$BOOT_IMAGE" ]; then
        error "Cannot find installed kernel image for ARM $ARM"
        error "Look for files in /boot containing 'swapq-${ARM}'"
        exit 1
    fi
    info "Boot image: $BOOT_IMAGE"
fi

# Update grub
info "Updating grub..."
if command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tail -3
elif command -v update-grub &>/dev/null; then
    update-grub 2>&1 | tail -3
else
    warn "Could not update grub automatically. Run: grub2-mkconfig -o /boot/grub2/grub.cfg"
fi

# Save build metadata
BUILD_META="$RESULT_DIR/build-arm-${ARM}-meta.txt"
{
    echo "arm=$ARM"
    echo "branch=$BRANCH"
    echo "commit=$CURRENT_COMMIT"
    echo "kernel_version=$KVER"
    echo "config=$CONFIG_FILE"
    echo "jobs=$BUILD_JOBS"
    echo "build_log=$BUILD_LOG"
    echo "boot_image=$BOOT_IMAGE"
    echo "build_date=$(date -Iseconds)"
} > "$BUILD_META"

info ""
info "=========================================="
info "ARM $ARM build complete!"
info "Kernel: $KVER"
info "Image:  $BOOT_IMAGE"
info "Meta:   $BUILD_META"
info "Log:    $BUILD_LOG"
info ""
info "To switch to this kernel:"
info "  bash scripts/02-switch-kernel.sh $ARM"
info "=========================================="
