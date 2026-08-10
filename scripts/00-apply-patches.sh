#!/bin/bash
# Apply the 13 v2 patches to their exact mm-unstable base.
#
# Creates exact A-E comparison branches.  The three v1 commits must already
# exist in the local object database; this script never downloads source.

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host
check_kernel_src

PATCHES=("$PATCH_DIR"/*.patch)
APPLIED_LOG="$TEST_DIR/applied-patches.log"

cd "$KERNEL_SRC"

if [ "${#PATCHES[@]}" -ne 13 ]; then
    error "Expected exactly 13 patches, found ${#PATCHES[@]}"
    exit 1
fi

git diff --quiet && git diff --cached --quiet || {
    error "Kernel tree is dirty; refusing to create comparison branches"
    exit 1
}
git cat-file -e "$BASE_COMMIT^{commit}"

ensure_exact_branch() {
    local branch=$1 commit=$2

    if ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
        error "Required commit $commit for $branch is not available locally"
        error "Import/fetch the already-downloaded v1 history, then retry"
        exit 1
    fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        [ "$(git rev-parse "$branch")" = "$commit" ] || {
            error "Existing $branch does not point to $commit"
            exit 1
        }
    else
        git branch "$branch" "$commit"
    fi
}

ensure_exact_branch swapq-v1-before "$V1_BEFORE_COMMIT"
ensure_exact_branch swapq-v1-patch8 "$V1_PATCH8_COMMIT"
ensure_exact_branch swapq-v1-patch13 "$V1_PATCH13_COMMIT"

ensure_exact_branch swapq-v2-base "$BASE_COMMIT"

if git show-ref --verify --quiet refs/heads/swapq-v2; then
    [ "$(git rev-parse swapq-v2^{tree})" = "$EXPECTED_V2_TREE" ] || {
        error "Existing swapq-v2 has an unexpected source tree"
        exit 1
    }
    info "Existing swapq-v2 already matches expected tree $EXPECTED_V2_TREE"
else
    git switch --detach "$BASE_COMMIT"
    git switch -c swapq-v2
    if ! git am "${PATCHES[@]}"; then
        git am --abort || true
        error "Patch application failed; fuzzy/manual application is prohibited"
        exit 1
    fi
fi

git diff --check "$BASE_COMMIT" swapq-v2
[ "$(git rev-list --count "$BASE_COMMIT"..swapq-v2)" -eq 13 ]
[ "$(git rev-parse swapq-v2^{tree})" = "$EXPECTED_V2_TREE" ]

{
    echo "base=$BASE_COMMIT"
    echo "head=$(git rev-parse swapq-v2)"
    echo "tree=$(git rev-parse swapq-v2^{tree})"
    echo "patches=${#PATCHES[@]}"
    echo "applied_at=$(date -Iseconds)"
} > "$APPLIED_LOG"

info "Current patch stack on swapq-v2:"
git log --oneline --reverse "$BASE_COMMIT"..swapq-v2

info ""
info "=== Done ==="
for arm in A B C D E; do
    info "Arm $arm: $(arm_branch "$arm") at $(git rev-parse --short "$(arm_branch "$arm")")"
done
info ""
info "Next: copy kernel config and run 01-build-arm.sh"
info "  cp /boot/config-\$(uname -r) $CONFIG_DIR/base.config"
info "  for arm in A B C D E; do bash scripts/01-build-arm.sh \"\$arm\"; done"
