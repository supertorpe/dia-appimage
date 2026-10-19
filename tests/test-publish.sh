#!/usr/bin/env bash
# Tests for publish.sh — runs entirely against local git fixtures (no network,
# no dependencies beyond git + bash).
#
# Each test builds a sandbox:
#   origin.git    bare — stands in for github.com/supertorpe/dia-appimage
#   upstream.git  bare — stands in for github.com/gnome/dia (main + DIA_0_97_2)
#   clone/        working clone of origin on main; publish.sh runs here
# with DIA_REPO pointed at the local upstream so the ref check needs no network.
set -u

PUBLISH=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/publish.sh
passes=0
fails=0

make_sandbox() {
    SB=$(mktemp -d "${TMPDIR:-/tmp}/publish-test.XXXXXX")
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

    # origin: the dia-appimage repo with main
    git init -q --bare "$SB/origin.git"
    git -C "$SB/origin.git" symbolic-ref HEAD refs/heads/main
    git init -q -b main "$SB/seed"
    (
        cd "$SB/seed" || exit 1
        echo v1 >file.txt
        git add file.txt
        git commit -qm "seed"
        git remote add origin "$SB/origin.git"
        git push -q origin main
    )

    # upstream: dia with main and a release tag
    git init -q --bare "$SB/upstream.git"
    git -C "$SB/upstream.git" symbolic-ref HEAD refs/heads/main
    git init -q -b main "$SB/dia-seed"
    (
        cd "$SB/dia-seed" || exit 1
        echo "version: '0.97.2'" >meson.build
        git add meson.build
        git commit -qm "dia"
        git remote add origin "$SB/upstream.git"
        git push -q origin main
        git tag DIA_0_97_2
        git push -q origin DIA_0_97_2
    )

    # clone: where publish.sh is run
    git clone -q "$SB/origin.git" "$SB/clone"
    git -C "$SB/clone" config user.name test
    git -C "$SB/clone" config user.email test@example.invalid
}

# origin's refs/tags/<tag>, peeled to the commit it points at ("", if absent)
origin_tag_commit() {
    git -C "$SB/origin.git" rev-parse --quiet --verify \
        "refs/tags/$1^{}" 2>/dev/null || true
}

origin_has_tag() {
    git -C "$SB/origin.git" rev-parse --quiet --verify "refs/tags/$1" >/dev/null 2>&1
}

run_pub() {
    (cd "$SB/clone" && DIA_REPO="$SB/upstream.git" bash "$PUBLISH" "$@")
}

t() {
    local name=$1
    shift
    if ("$@") >/dev/null 2>&1; then
        echo "PASS: $name"
        passes=$((passes + 1))
    else
        echo "FAIL: $name"
        fails=$((fails + 1))
    fi
}

# Runs publish.sh, requiring it to FAIL with the given error marker on stderr.
# Proves rejections happen for the right reason, not an incidental crash.
run_pub_rejected() {
    local marker=$1
    shift
    local out
    if out=$(run_pub "$@" 2>&1); then
        return 1
    fi
    grep -q "$marker" <<<"$out"
}

# ---------------------------------------------------------------- tests

test_default_ref_pushes_build_main_tag() {
    make_sandbox
    run_pub || return 1
    origin_has_tag build-main || return 1
    # annotated tag: the tag object itself differs from the commit it points to
    local tagobj commit
    tagobj=$(git -C "$SB/origin.git" rev-parse refs/tags/build-main)
    commit=$(origin_tag_commit build-main)
    [ -n "$commit" ] && [ "$tagobj" != "$commit" ] || return 1
    # points at main's HEAD
    [ "$commit" = "$(git -C "$SB/origin.git" rev-parse main)" ] || return 1
    # message names the ref
    git -C "$SB/origin.git" tag -l --format='%(contents)' build-main | grep -q "main"
}

test_explicit_ref_tagged_build_ref() {
    make_sandbox
    run_pub DIA_0_97_2 || return 1
    origin_has_tag build-DIA_0_97_2 || return 1
    ! origin_has_tag build-main || return 1
    git -C "$SB/origin.git" tag -l --format='%(contents)' build-DIA_0_97_2 \
        | grep -q "DIA_0_97_2"
}

test_unknown_upstream_ref_rejected() {
    make_sandbox
    run_pub_rejected "ERROR:" DIA_9_9_9 || return 1
    ! origin_has_tag build-DIA_9_9_9 || return 1
}

test_dirty_tree_rejected() {
    make_sandbox
    echo dirty >>"$SB/clone/file.txt"
    run_pub_rejected "ERROR:" || return 1
    ! origin_has_tag build-main || return 1
}

test_non_main_branch_rejected() {
    make_sandbox
    git -C "$SB/clone" checkout -qb feature
    run_pub_rejected "ERROR:" || return 1
    ! origin_has_tag build-main || return 1
}

test_local_main_out_of_sync_rejected() {
    make_sandbox
    # origin/main moves ahead (someone else pushed); local clone is now behind
    git clone -q "$SB/origin.git" "$SB/other"
    git -C "$SB/other" config user.name test
    git -C "$SB/other" config user.email test@example.invalid
    (
        cd "$SB/other" || exit 1
        echo more >>file.txt
        git commit -qam "their commit"
        git push -q origin main
    )
    run_pub_rejected "ERROR:" || return 1
    ! origin_has_tag build-main || return 1
}

test_rerun_moves_trigger_tag() {
    make_sandbox
    run_pub || return 1
    # a new commit lands on main and is pushed; re-publish must move the tag
    (
        cd "$SB/clone" || exit 1
        echo v2 >file.txt
        git commit -qam "second release"
        git push -q origin main
    )
    run_pub || return 1
    local commit
    commit=$(origin_tag_commit build-main)
    [ "$commit" = "$(git -C "$SB/origin.git" rev-parse main)" ] || return 1
}

test_full_sha_accepted() {
    make_sandbox
    local sha
    sha=$(git -C "$SB/upstream.git" rev-parse main)
    run_pub "$sha" || return 1
    origin_has_tag "build-$sha"
}

test_too_many_args_rejected() {
    make_sandbox
    run_pub_rejected "usage:" one two || return 1
    ! origin_has_tag build-one || return 1
    ! origin_has_tag build-two || return 1
}

# ---------------------------------------------------------------- runner

t "default ref pushes annotated build-main tag" test_default_ref_pushes_build_main_tag
t "explicit ref gets build-<ref> tag" test_explicit_ref_tagged_build_ref
t "unknown upstream ref is rejected" test_unknown_upstream_ref_rejected
t "dirty working tree is rejected" test_dirty_tree_rejected
t "non-main branch is rejected" test_non_main_branch_rejected
t "local main out of sync with origin is rejected" test_local_main_out_of_sync_rejected
t "re-running moves the trigger tag to new HEAD" test_rerun_moves_trigger_tag
t "full commit SHA is accepted" test_full_sha_accepted
t "extra arguments are rejected" test_too_many_args_rejected

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
