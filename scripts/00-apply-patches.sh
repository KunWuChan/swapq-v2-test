#!/bin/bash
# Apply the 13 v2 patches to their exact mm-unstable base.
#
# Creates reproducible A-E comparison branches without network access:
#   - A must already exist (the colleague's downloaded v1 base).
#   - B/C are reused by source tree or rebuilt from bundled v1 patches.
#   - D is reused locally or imported from the checked-in Git bundle.
#   - E is rebuilt from the 13 v2 patches.

set -euo pipefail
. "$(dirname "$0")/lib-common.sh"

check_host
check_kernel_src

PATCHES=("$PATCH_DIR"/*.patch)
V1_PATCHES=("$V1_PATCH_DIR"/*.patch)
APPLIED_LOG="$TEST_DIR/applied-patches.log"

cd "$KERNEL_SRC"

if [ "${#PATCHES[@]}" -ne 13 ]; then
    error "Expected exactly 13 v2 patches, found ${#PATCHES[@]}"
    exit 1
fi
if [ "${#V1_PATCHES[@]}" -ne 13 ]; then
    error "Expected exactly 13 v1 patches, found ${#V1_PATCHES[@]}"
    exit 1
fi

git diff --quiet && git diff --cached --quiet || {
    error "Kernel tree is dirty; refusing to create comparison branches"
    exit 1
}
ensure_exact_branch() {
    local branch=$1 commit=$2

    if ! git cat-file -e "$commit^{commit}" 2>/dev/null; then
        error "Required commit $commit for $branch is not available locally"
        error "Import the required comparison history, then retry"
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

verify_tree_branch() {
    local branch=$1 expected_tree=$2

    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
        return 1
    fi
    [ "$(git rev-parse "$branch^{tree}")" = "$expected_tree" ] || {
        error "Existing $branch has an unexpected source tree"
        exit 1
    }
}

create_v1_branch() {
    local branch=$1 exact_commit=$2 expected_tree=$3 start=$4 count=$5 base=$6

    if verify_tree_branch "$branch" "$expected_tree"; then
        info "Existing $branch matches expected tree $expected_tree"
        return
    fi
    if git cat-file -e "$exact_commit^{commit}" 2>/dev/null &&
            [ "$(git rev-parse "$exact_commit^{tree}")" = "$expected_tree" ]; then
        git branch "$branch" "$exact_commit"
        return
    fi

    git switch --detach "$base"
    git switch -c "$branch"
    if ! git am "${V1_PATCHES[@]:$start:$count}"; then
        git am --abort || true
        error "Failed to rebuild $branch from the bundled v1 patches"
        exit 1
    fi
    [ "$(git rev-parse HEAD^{tree})" = "$expected_tree" ] || {
        error "$branch rebuilt to an unexpected source tree"
        exit 1
    }
}

create_v1_branch swapq-v1-patch8 "$V1_PATCH8_COMMIT" "$V1_PATCH8_TREE" 0 8 "$V1_BEFORE_COMMIT"
create_v1_branch swapq-v1-patch13 "$V1_PATCH13_COMMIT" "$V1_PATCH13_TREE" 8 5 swapq-v1-patch8

git diff --check "$V1_BEFORE_COMMIT" swapq-v1-patch8
git diff --check "$V1_BEFORE_COMMIT" swapq-v1-patch13

if ! git cat-file -e "$BASE_COMMIT^{commit}" 2>/dev/null; then
    [ -f "$BASE_BUNDLE" ] || {
        error "Arm D is missing and its bundle is unavailable: $BASE_BUNDLE"
        exit 1
    }
    [ "$(sha256_file "$BASE_BUNDLE")" = "$BASE_BUNDLE_SHA256" ] || {
        error "Arm D bundle SHA-256 mismatch"
        exit 1
    }
    info "Importing exact Arm D from $BASE_BUNDLE"
    git bundle verify "$BASE_BUNDLE"
    git fetch "$BASE_BUNDLE" \
        refs/remotes/origin/mm-unstable:refs/heads/swapq-v2-base
fi

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
