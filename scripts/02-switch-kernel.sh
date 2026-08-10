#!/bin/bash
# Switch to a specific ARM kernel and reboot
# Usage: bash 02-switch-kernel.sh <D|E>
#
# Uses grub2-set-default / grub2-reboot for one-time boot

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

ARM="${1:-}"
if [ -z "$ARM" ] || [ -z "${ARM_BRANCHES[$ARM]:-}" ]; then
    echo "Usage: $0 <D|E>"
    echo "  D = v2 base (mm-unstable)"
    echo "  E = v2 current (13 patches)"
    exit 1
fi

KVER=$(get_kernel_version "$ARM")
DESC="${ARM_DESC[$ARM]}"

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
    info "Entry: $ENTRY_TITLE"

elif [ -f /boot/grub2/grub.cfg ]; then
    # GRUB2 style
    MENU_FILE=/boot/grub2/grub.cfg
    # Find menu entries matching our kernel
    info "Available swapq entries:"
    grep -E 'menuentry |submenu ' "$MENU_FILE" | grep -i 'swapq' || warn "No swapq entries found in grub.cfg"

    # Get all menu entries
    mapfile -t MENU_LINES < <(grep -n 'menuentry \|submenu ' "$MENU_FILE")

    # Show all entries for user to select
    info "All GRUB menu entries:"
    local i=0
    for line in "${MENU_LINES[@]}"; do
        echo "  [$i] $line"
        i=$((i+1))
    done

    warn ""
    warn "Cannot automatically determine GRUB entry index."
    warn "Please manually set the boot entry and reboot:"
    warn ""
    warn "  # List exact menu entry title:"
    warn "  grep -A0 'menuentry' /boot/grub2/grub.cfg | grep -i swapq"
    warn ""
    warn "  # Set one-time boot (example):"
    warn "  grub2-reboot '<exact menu entry title>'"
    warn ""
    warn "  # Or set as default:"
    warn "  grub2-set-default '<exact menu entry title>'"
    warn ""
    warn "  # Then reboot:"
    warn "  systemctl reboot"
    warn ""
    read -rp "Open a new terminal to set grub, then press Enter here to reboot... "

elif [ -f /boot/grub/grub.cfg ]; then
    # Debian/Ubuntu style
    MENU_FILE=/boot/grub/grub.cfg
    info "Available swapq entries:"
    grep 'menuentry ' "$MENU_FILE" | grep -i 'swapq' || warn "No swapq entries found"

    warn "Please manually:"
    warn "  grep 'menuentry' /boot/grub/grub.cfg | grep -i swapq"
    warn "  grub-reboot '<entry>'"
    warn "  reboot"
    read -rp "Press Enter to reboot..."
else
    error "Cannot find GRUB configuration"
    warn "Known paths checked: /boot/loader/entries, /boot/grub2/grub.cfg, /boot/grub/grub.cfg"
    exit 1
fi

info "Rebooting..."
systemctl reboot
