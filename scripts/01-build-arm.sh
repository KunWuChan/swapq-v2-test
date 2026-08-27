#!/bin/bash
# Build a kernel for a specific comparison arm.
# Usage: bash 01-build-arm.sh <A|B|C|D|E> [--config <config-file>]

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host
[ "$(id -u)" -eq 0 ] || { error "Kernel build/install must run as root"; exit 1; }

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
BUILD_DIR="$BUILD_ROOT/arm-$ARM"

info "=========================================="
info "Building ARM $ARM: $DESC"
info "Branch: $BRANCH"
info "Config: $CONFIG_FILE"
info "Output: $BUILD_DIR"
info "Jobs: $BUILD_JOBS"
info "=========================================="

check_kernel_src
cd "$KERNEL_SRC"

git diff --quiet && git diff --cached --quiet || {
    error "Kernel source has tracked changes; refusing to build a comparison arm"
    exit 1
}

# Checkout the branch
info "Checking out branch $BRANCH..."
git checkout "$BRANCH"

# Verify exact comparison identity.  A and D retain exact commit identity;
# rebuilt B/C/E may have different committer dates, so their source trees are
# the authoritative identity.
CURRENT_COMMIT=$(git rev-parse HEAD)
info "Building from commit: $CURRENT_COMMIT"
EXPECTED_TREE=$(arm_expected_tree "$ARM")
if [ "$(git rev-parse HEAD^{tree})" != "$EXPECTED_TREE" ]; then
    error "Arm $ARM source tree does not match $EXPECTED_TREE"
    exit 1
fi
if [ "$ARM" = A ] || [ "$ARM" = D ]; then
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
CONFIG_FILE=$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")

mkdir -p "$BUILD_DIR"
build_free_kib=$(df -Pk "$BUILD_DIR" | awk 'NR == 2 { print $4 }')
boot_free_kib=$(df -Pk /boot | awk 'NR == 2 { print $4 }')
if [ "$build_free_kib" -lt "$((MIN_BUILD_FREE_GIB * 1024 * 1024))" ]; then
    error "Less than ${MIN_BUILD_FREE_GIB} GiB is free for $BUILD_DIR"
    exit 1
fi
if [ "$boot_free_kib" -lt "$((MIN_BOOT_FREE_MIB * 1024))" ]; then
    error "Less than ${MIN_BOOT_FREE_MIB} MiB is free on /boot"
    exit 1
fi

info "Preparing kernel config..."
cp "$CONFIG_FILE" "$BUILD_DIR/.config"

# Set local version to identify this ARM
scripts/config --file "$BUILD_DIR/.config" --set-str LOCALVERSION "-swapq-${ARM}"
scripts/config --file "$BUILD_DIR/.config" --enable LOCALVERSION_AUTO

# Update config for new kernel version
make O="$BUILD_DIR" olddefconfig 2>&1 | tail -3
KVER=$(make -s O="$BUILD_DIR" kernelrelease)
info "Kernel version: $KVER"

# Verify key options
info "Verifying key config options..."
for opt in CONFIG_SWAP CONFIG_ZRAM CONFIG_MEMCG CONFIG_TRANSPARENT_HUGEPAGE; do
    val=$(grep "^${opt}=" "$BUILD_DIR/.config" || true)
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

make O="$BUILD_DIR" -j"$BUILD_JOBS" 2>&1 | tee "$BUILD_LOG"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    error "Kernel build FAILED. Log: $BUILD_LOG"
    exit 1
fi
info "Kernel build OK"

# Install modules
info "Installing modules..."
make O="$BUILD_DIR" modules_install 2>&1 | tail -5

BUILT_IMAGE="$BUILD_DIR/arch/arm64/boot/Image"
[ -f "$BUILT_IMAGE" ] || BUILT_IMAGE="$BUILD_DIR/arch/arm64/boot/Image.gz"

if [ "${NO_INSTALL:-0}" = "1" ]; then
    info "Skipping kernel install and grub update (NO_INSTALL=1)"
    info "Kernel image: $BUILT_IMAGE"
    info "Manual install steps:"
    info "  cp $BUILT_IMAGE /boot/vmlinuz-$KVER"
    info "  cp $BUILD_DIR/System.map /boot/System.map-$KVER"
    info "  dracut /boot/initramfs-$KVER.img $KVER"
    info "  grub2-mkconfig -o /boot/grub2/grub.cfg"
    BOOT_IMAGE="(manual: $BUILT_IMAGE)"
    BOOT_IMAGE_SHA="(skipped)"
else
    # Install kernel
    info "Installing kernel..."
    make O="$BUILD_DIR" install 2>&1 | tail -5

    # Verify installation
    BOOT_IMAGE="/boot/vmlinuz-${KVER}"

    if [ -f "$BOOT_IMAGE" ]; then
        info "Boot image: $BOOT_IMAGE ($(du -h "$BOOT_IMAGE" | cut -f1))"
    else
        BOOT_IMAGE=$(ls -t /boot/vmlinuz-*swapq-${ARM}* 2>/dev/null | head -1)
        if [ -z "$BOOT_IMAGE" ]; then
            error "Cannot find installed kernel image for ARM $ARM"
            error "Look for files in /boot containing 'swapq-${ARM}'"
            exit 1
        fi
        info "Boot image: $BOOT_IMAGE"
    fi
    BOOT_IMAGE_SHA=$(sha256_file "$BOOT_IMAGE")

    # Update grub
    info "Updating grub..."
    if command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tail -3
    elif command -v update-grub &>/dev/null; then
        update-grub 2>&1 | tail -3
    else
        warn "Could not update grub automatically. Run: grub2-mkconfig -o /boot/grub2/grub.cfg"
    fi
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
    echo "config_sha256=$(sha256_file "$BUILD_DIR/.config")"
    echo "build_dir=$BUILD_DIR"
    echo "built_image=$BUILT_IMAGE"
    echo "build_dir_filesystem_free_kib_before=$build_free_kib"
    echo "boot_filesystem_free_kib_before=$boot_free_kib"
    echo "jobs=$BUILD_JOBS"
    echo "build_log=$BUILD_LOG"
    echo "boot_image=$BOOT_IMAGE"
    echo "boot_image_sha256=$BOOT_IMAGE_SHA"
    echo "build_date=$(date -Iseconds)"
} > "$BUILD_META"

info ""
info "=========================================="
info "ARM $ARM build complete!"
info "Kernel: $KVER"
info "Image:  $BUILT_IMAGE"
info "Meta:   $BUILD_META"
info "Log:    $BUILD_LOG"
info ""
if [ "${NO_INSTALL:-0}" = "1" ]; then
    info "Manual install:"
    info "  cp $BUILT_IMAGE /boot/vmlinuz-$KVER"
    info "  dracut /boot/initramfs-$KVER.img $KVER"
    info "  grub2-mkconfig -o /boot/grub2/grub.cfg"
    info "  grub2-reboot '<entry>' && reboot"
else
    info "To switch to this kernel:"
    info "  bash scripts/02-switch-kernel.sh $ARM"
fi
info "=========================================="
