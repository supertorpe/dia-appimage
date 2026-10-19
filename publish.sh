#!/usr/bin/env bash
# Publish a Dia AppImage release.
#
# Pushes an annotated trigger tag `build-<ref>` to this repository; the tag
# push triggers the GitHub Actions workflow
# (.github/workflows/build-appimage.yml), which builds dia at <ref> inside
# Docker and publishes a GitHub Release named after the version in dia's
# meson.build.
#
# Usage: ./publish.sh [dia-ref]     (default: main)
#
# DIA_REPO overrides the upstream dia repository (default: gnome/dia), mainly
# for testing against a fork or local fixture.
set -euo pipefail

REF=${1:-main}
[ "$#" -le 1 ] || { echo "usage: $0 [dia-ref]" >&2; exit 2; }
TAG="build-$REF"
DIA_REPO=${DIA_REPO:-https://github.com/gnome/dia}
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || die "check out main first"
[ -z "$(git status --porcelain)" ] \
    || die "working tree is dirty; commit or stash first"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main differs from origin/main; pull/push first"
# Full commit SHAs cannot be verified with ls-remote (GitHub only serves
# refs); build-appimage.sh validates them by fetching, so let them through.
if [[ ! "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    git ls-remote --exit-code "$DIA_REPO" \
        "refs/heads/$REF" "refs/tags/$REF" >/dev/null \
        || die "ref '$REF' does not exist in $DIA_REPO (use a branch, tag, or full commit SHA)"
fi

git tag -f -a "$TAG" -m "trigger CI build of dia ref '$REF'" HEAD
git push -f origin "refs/tags/$TAG"

echo "Pushed trigger tag $TAG — CI is building dia ref '$REF'."
echo "Watch the run in the GitHub Actions tab:"
echo "  https://github.com/supertorpe/dia-appimage/actions"
