#!/bin/bash
# Build a kernel for a specific comparison arm.
# Usage: bash 01-build-arm.sh <A|B|C|D|E> [--config <config-file>]

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host

ARM="${1:-}"
if [ -z "$ARM" ] || ! arm_branch "$ARM" >/dev/null 2>&1; then
    echo "Usage: $0 <A|B|C|D|E> [--config <file>]"
    for arm in A B C D E; do echo "  $arm = $(arm_desc "$arm")"; done
    exit 1
fi

# Parse optional --config
CONFIG_FILE="$KERNEL_CONFIG"
if [ "${2:-}" == "--config" ] && [ -n "${3:-}" ]; then
    CONFIG_FILE="$3"
fi

BRANCH=$(arm_branch "$ARM")
DESC=$(arm_desc "$ARM")

info "=========================================="
info "Building ARM $ARM: $DESC"
info "Branch: $BRANCH"
info "Config: $CONFIG_FILE"
info "Jobs: $BUILD_JOBS"
info "=========================================="

check_kernel_src
cd "$KERNEL_SRC"

# Checkout the branch
info "Checking out branch $BRANCH..."
git checkout "$BRANCH"

# Verify branch state
CURRENT_COMMIT=$(git rev-parse HEAD)
info "Building from commit: $CURRENT_COMMIT"
if [ "$ARM" = E ]; then
    if [ "$(git rev-parse HEAD^{tree})" != "$EXPECTED_V2_TREE" ]; then
        error "Arm E source tree does not match $EXPECTED_V2_TREE"
        exit 1
    fi
else
    EXPECTED_COMMIT=$(arm_expected_commit "$ARM")
    if [ "$CURRENT_COMMIT" != "$EXPECTED_COMMIT" ]; then
        error "Arm $ARM must be exact commit $EXPECTED_COMMIT"
        exit 1
    fi
fi

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
KVER=$(make -s kernelrelease)
info "Kernel version: $KVER"

# Verify key options
info "Verifying key config options..."
for opt in CONFIG_SWAP CONFIG_ZRAM CONFIG_MEMCG CONFIG_TRANSPARENT_HUGEPAGE; do
    val=$(grep "^${opt}=" .config || true)
    case "$opt" in
        CONFIG_ZRAM)
            echo "$val" | grep -Eq '^CONFIG_ZRAM=[my]$' || {
                error "$opt is not enabled: ${val:-NOT_FOUND}"
                exit 1
            }
            ;;
        *)
            [ "$val" = "$opt=y" ] || {
                error "$opt is not enabled: ${val:-NOT_FOUND}"
                exit 1
            }
            ;;
    esac
    info "  $val"
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
    echo "tree=$(git rev-parse HEAD^{tree})"
    echo "kernel_version=$KVER"
    echo "config=$CONFIG_FILE"
    echo "config_sha256=$(sha256sum .config | awk '{print $1}')"
    echo "jobs=$BUILD_JOBS"
    echo "build_log=$BUILD_LOG"
    echo "boot_image=$BOOT_IMAGE"
    echo "boot_image_sha256=$(sha256sum "$BOOT_IMAGE" | awk '{print $1}')"
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
