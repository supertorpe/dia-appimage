#!/usr/bin/env bash
# Build the Dia AppImage in Docker.  Only Docker (plus network) is required
# on the host: the source is shallow-cloned from GitHub inside the container
# and the artifact ends up in output/.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${IMAGE:-dia-appimage}

if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: the AppImage toolchain in the Dockerfile is x86_64-only (host is $(uname -m))." >&2
    exit 1
fi

echo "==> Building image $IMAGE"
docker build -t "$IMAGE" "$HERE"

mkdir -p "$HERE/output"

# DIA_REPO / DIA_REF are passed through to the build script when set on the
# host (e.g. DIA_REF=DIA_0_97_2 ./run.sh); when unset, the container defaults
# apply (the default branch of https://github.com/gnome/dia).
echo "==> Running AppImage build (dia cloned inside the container)"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e APPIMAGE_EXTRACT_AND_RUN=1 \
    -e DIA_REPO -e DIA_REF \
    -v "$HERE/output:/output" \
    "$IMAGE"

echo "==> Done. Artifacts in $HERE/output:"
ls -lh "$HERE/output"
