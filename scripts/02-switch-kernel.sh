#!/bin/bash
# Switch to a specific ARM kernel and reboot
# Usage: GRUB_ENTRY='<exact submenu>entry id>' bash 02-switch-kernel.sh <A|B|C|D|E> [--reboot]
#
# Uses grub2-set-default / grub2-reboot for one-time boot

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host

ARM="${1:-}"
if [ -z "$ARM" ] || ! arm_branch "$ARM" >/dev/null 2>&1; then
    echo "Usage: $0 <A|B|C|D|E> [--reboot]"
    for arm in A B C D E; do echo "  $arm = $(arm_desc "$arm")"; done
    exit 1
fi
DO_REBOOT=0
[ "${2:-}" = "--reboot" ] && DO_REBOOT=1

DESC=$(arm_desc "$ARM")
BUILD_META="$RESULT_DIR/build-arm-${ARM}-meta.txt"
[ -f "$BUILD_META" ] || {
    error "Missing build metadata: $BUILD_META"
    error "Build Arm $ARM successfully before selecting it"
    exit 1
}
KVER=$(awk -F= '$1 == "kernel_version" { print substr($0, index($0, "=") + 1) }' "$BUILD_META")
[ -n "$KVER" ] || { error "kernel_version is absent from $BUILD_META"; exit 1; }

info "=========================================="
info "Switching to ARM $ARM: $DESC"
info "Kernel: $KVER"
info "=========================================="

# Find the GRUB menu entry
if [ -d /boot/loader/entries ]; then
    # systemd-boot style
    ENTRIES_DIR=/boot/loader/entries
    ENTRY_FILE=$(ls "$ENTRIES_DIR"/*"swapq-${ARM}"* 2>/dev/null | head -1)
    if [ -z "$ENTRY_FILE" ]; then
        error "No loader entry found for swapq-${ARM} in $ENTRIES_DIR"
        ls -la "$ENTRIES_DIR"/
        exit 1
    fi
    ENTRY_TITLE=$(grep '^title' "$ENTRY_FILE" | head -1 | sed 's/title //')
    ENTRY_ID=$(basename "$ENTRY_FILE" .conf)
    info "Entry: $ENTRY_TITLE"
    bootctl set-oneshot "$ENTRY_ID"

elif [ -f /boot/grub2/grub.cfg ] || [ -f /boot/grub/grub.cfg ]; then
    # GRUB2 style
    if [ -f /boot/grub2/grub.cfg ]; then
        MENU_FILE=/boot/grub2/grub.cfg
    else
        MENU_FILE=/boot/grub/grub.cfg
    fi
    # Find menu entries matching our kernel
    info "Available swapq entries:"
    grep -E 'menuentry |submenu ' "$MENU_FILE" | grep -i 'swapq' || warn "No swapq entries found in grub.cfg"

    if [ -z "${GRUB_ENTRY:-}" ]; then
        error "GRUB_ENTRY is required; refusing to guess a menu/submenu path"
        error "Set it to the exact verified entry id, for example submenu_id>entry_id"
        exit 2
    fi
    if command -v grub2-reboot >/dev/null 2>&1; then
        grub2-reboot "$GRUB_ENTRY"
    elif command -v grub-reboot >/dev/null 2>&1; then
        grub-reboot "$GRUB_ENTRY"
    else
        error "Neither grub2-reboot nor grub-reboot is available"
        exit 1
    fi
else
    error "Cannot find GRUB configuration"
    warn "Known paths checked: /boot/loader/entries, /boot/grub2/grub.cfg, /boot/grub/grub.cfg"
    exit 1
fi

if [ "$DO_REBOOT" -eq 1 ]; then
    info "Rebooting into the verified one-shot entry..."
    systemctl reboot
else
    info "One-shot boot entry set. Re-run with --reboot after verifying it."
fi
