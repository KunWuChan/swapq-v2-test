#!/bin/bash
# Apply the 13 v2 patches to kp-server's current mm-unstable tree.
# Uses 'patch -F5' (fuzz factor) to handle line-offset differences.
# For hunks that fail, stops and asks user to manually fix.
#
# After successful application, creates two branches:
#   swapq-v2-base  → original mm-unstable HEAD (Arm D)
#   swapq-v2       → with all 13 patches applied (Arm E)

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_kernel_src

PATCHES=(
    "0001-mm-swap-remove-unused-parameter-for-reading-swap-hea"
    "0002-mm-swap-slightly-cleanup-the-code-for-hibernation-er"
    "0003-mm-swap-cleanup-and-document-swap-device-availabilit"
    "0004-mm-swap-introduce-swap-device-iteration-helper"
    "0005-mm-swap-change-the-swapon-lock-into-a-percpu-rwsem"
    "0006-mm-swap-remove-swapon-mutex-and-update-proc-reader"
    "0007-mm-swap-consolidate-swap-inuse-accounting-helpers"
    "0008-mm-swap-change-back-to-use-each-swap-device-s-percpu"
    "0009-mm-swap-add-priority-queue-for-swap-device-allocatio"
    "0010-mm-swap-remove-available-list"
    "0011-mm-swap-bound-synchronous-discard-during-allocation"
    "0012-mm-swap-drop-swap-active-plist"
    "0013-lib-plist.c-remove-requeue-function"
)

MANUAL_FIX_DIR="$TEST_DIR/manual-fixes"
APPLIED_LOG="$TEST_DIR/applied-patches.log"

info "=== Step 1: Create base branch ==="
cd "$KERNEL_SRC"

# Save current HEAD
BASE_HEAD=$(git rev-parse HEAD)
info "Current HEAD: $BASE_HEAD"

# Create swapq-v2-base branch from current position
git checkout -b swapq-v2-base 2>/dev/null || {
    info "swapq-v2-base already exists, checking out"
    git checkout swapq-v2-base
}

# Now create swapq-v2 branch
git checkout -b swapq-v2 2>/dev/null || {
    info "swapq-v2 already exists, checking out"
    git checkout swapq-v2
}

# If already applied, skip
if [ -f "$APPLIED_LOG" ] && grep -q "ALL_PATCHES_APPLIED" "$APPLIED_LOG" 2>/dev/null; then
    info "All patches already applied according to $APPLIED_LOG"
    info "To re-apply: rm $APPLIED_LOG && git reset --hard swapq-v2-base"
    exit 0
fi

info "=== Step 2: Apply patches with fuzz factor ==="
rm -f "$APPLIED_LOG"
mkdir -p "$MANUAL_FIX_DIR"

APPLIED_COUNT=0
for patch_prefix in "${PATCHES[@]}"; do
    patch_file=$(ls "$PATCH_DIR/${patch_prefix}"*.patch 2>/dev/null | head -1)
    if [ -z "$patch_file" ]; then
        warn "Patch file not found for: $patch_prefix"
        continue
    fi

    patch_name=$(basename "$patch_file")
    info "Applying: $patch_name"

    # First try patch with fuzz factor
    if patch -p1 -l -F5 -t -N --dry-run < "$patch_file" 2>/dev/null; then
        # All hunks apply, do the real application
        patch -p1 -l -F5 -t -N < "$patch_file" 2>/dev/null
        git add -A
        git commit -m "$(head -5 "$patch_file" | grep 'Subject:' | sed 's/Subject: \[RFC PATCH v2 [0-9]*\/[0-9]*\] //')" \
            --author="$(head -20 "$patch_file" | grep 'From:' | head -1 | sed 's/From: //')" \
            2>/dev/null || git commit -m "Apply: $patch_name"
        info "  OK"
        echo "OK  $patch_name" >> "$APPLIED_LOG"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
    else
        # Some hunks failed — try to apply and generate .rej files
        warn "  Some hunks failed. Generating .rej files..."
        patch -p1 -l -F5 -t -N --force < "$patch_file" 2>&1 | tee "$MANUAL_FIX_DIR/${patch_name}.log" || true

        # Find reject files
        rejects=$(find . -name "*.rej" -newer "$APPLIED_LOG" 2>/dev/null || true)

        if [ -n "$rejects" ]; then
            warn "  === MANUAL INTERVENTION REQUIRED ==="
            warn "  Reject files:"
            echo "$rejects" | while read -r r; do
                warn "    $r"
            done
            warn ""
            warn "  Action needed:"
            warn "  1. Examine each .rej file and manually fix the corresponding source"
            warn "  2. Remove the .rej files"
            warn "  3. git add -A && git commit -m 'Fixup: $patch_name'"
            warn "  4. Press Enter to continue to next patch"
            read -r
        fi

        echo "FIX $patch_name" >> "$APPLIED_LOG"
    fi
done

info "=== Step 3: Verify ==="
info "Applied $APPLIED_COUNT / ${#PATCHES[@]} patches cleanly"
echo "ALL_PATCHES_APPLIED $(date)" >> "$APPLIED_LOG"

# Show the patch stack
info "Current patch stack on swapq-v2:"
git log --oneline swapq-v2-base..swapq-v2

info ""
info "=== Done ==="
info "Arm D (base): branch swapq-v2-base at $(git rev-parse --short swapq-v2-base)"
info "Arm E (v2):   branch swapq-v2 at $(git rev-parse --short swapq-v2)"
info ""
info "Next: copy kernel config and run 01-build-arm.sh"
info "  cp /boot/config-\$(uname -r) $CONFIG_DIR/base.config"
info "  bash scripts/01-build-arm.sh D"
info "  bash scripts/01-build-arm.sh E"
