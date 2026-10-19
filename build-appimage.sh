#!/usr/bin/env bash
# Builds the Dia AppImage inside the container.
#
# The dia source is shallow-cloned from GitHub into a throw-away temp
# directory; DIA_REPO / DIA_REF select the repo and ref to build.  The final
# AppImage is written to /output (output/ on the host).
set -euo pipefail

OUT=${OUT:-/output}
DIA_REPO=${DIA_REPO:-https://github.com/gnome/dia}
DIA_REF=${DIA_REF:-}
export APPIMAGE_EXTRACT_AND_RUN=1
export DEPLOY_GTK_VERSION=3

log() { printf '\n=== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$OUT"

WORK=$(mktemp -d /tmp/dia-appimage.XXXXXX)
BUILD="$WORK/build"
APPDIR="$WORK/AppDir"
SRC="$WORK/src"

# ------------------------------------------------------------------ source
log "1/7 Cloning $DIA_REPO${DIA_REF:+ (ref: $DIA_REF)}"
# Fetching an explicit ref by name works for branches and tags; fetching by
# SHA works for any commit reachable from one (GitHub allows this).  With
# DIA_REF unset, fetch the remote's default branch (its HEAD).  --depth 1
# keeps the clone cheap; the build needs no history.
git init -q "$SRC"
git -C "$SRC" remote add origin "$DIA_REPO"
git -C "$SRC" fetch --depth 1 origin "${DIA_REF:-HEAD}"
git -C "$SRC" checkout -q FETCH_HEAD

[ -f "$SRC/meson.build" ] || die "cloned tree at $SRC does not look like dia"

# ---------------------------------------------------------------- configure
log "2/7 Configuring (meson)"
# -Dtests=false      : no xmllint/appstreamcli needed
# -Ddoc=disabled     : no docbook/xsltproc needed (man pages are irrelevant
#                      for an AppImage)
# -Dstrip=true       : strip debug info on install (build stays debugoptimized)
# --libdir=lib       : Ubuntu's meson defaults to multiarch lib/x86_64-linux-gnu,
#                      but the AppDir spec (and linuxdeploy's dependency
#                      resolution) expects libraries in usr/lib.
meson setup "$BUILD" "$SRC" \
    --prefix=/usr \
    --libdir=lib \
    -Dtests=false \
    -Ddoc=disabled \
    -Dstrip=true

# ------------------------------------------------------------------- build
log "3/7 Building"
meson compile -C "$BUILD"

# ---------------------------------------------------------------- staging
log "4/7 Staging AppDir"
DESTDIR="$APPDIR" meson install -C "$BUILD"

# --- Strip Python support (deliberate, see README.md) ----------------------
# dia's meson hard-requires python3-embed at configure time, so python3-dev is
# present in the image, but the AppImage must ship without Python: bundling a
# working Python runtime (stdlib + PyGObject) is fragile across host distros.
find "$APPDIR" -name '*python_plugin*' -delete
rm -rf "$APPDIR/usr/share/dia/python"
rm -f "$APPDIR/usr/share/dia/python-startup.py"
if find "$APPDIR" \( -name 'libpython*' -o -name '*python_plugin*' \) -print -quit | grep -q .; then
    die "libpython unexpectedly referenced in AppDir"
fi

# Dia's libdir is multiarch on Ubuntu (usr/lib/x86_64-linux-gnu), so the
# plug-in directory is located from the staged files rather than hardcoded.
PLUGIN_SO=$(find "$APPDIR/usr" -name 'liblayout_filter.so' -print -quit)
[ -n "$PLUGIN_SO" ] || die "staged plug-in liblayout_filter.so not found"
PLUGIN_DIR=${PLUGIN_SO%/*}
PLUGIN_REL=${PLUGIN_DIR#"$APPDIR"}
[ -n "$PLUGIN_REL" ] || die "could not derive plug-in dir relative to AppDir"

# --- Relocation fix-ups ----------------------------------------------------
# Dia bakes absolute /usr paths at compile time.  At runtime the AppRun hook
# below sets DIA_BASE_PATH=$APPDIR/usr/share, but dia appends a literal
# "/data" to it (a source-tree quirk: in the source tree data lives in
# <root>/data, while an installed prefix uses <prefix>/share/dia).  A
# compatibility symlink makes the installed layout resolve:
#   $DIA_BASE_PATH/data -> $APPDIR/usr/share/dia
ln -sfn dia "$APPDIR/usr/share/data"

# Runtime environment: tell dia where its plug-ins and data live inside the
# AppImage (sourced by linuxdeploy's generated AppRun at startup).
# Quoted-style heredoc via printf: the values must stay literal — $APPDIR and
# friends are evaluated at AppRun time.  The APPDIR fallback mirrors the GTK
# hook's workaround: the linuxdeploy-generated AppRun sources THIS hook before
# the GTK hook (alphabetical order), and the AppImage runtime only sets APPDIR
# for real AppImage runs, not for `--appimage-extract` runs.  XDG_DATA_DIRS
# keeps the host default when unset (the AppImage must still find host
# icons/themes).
mkdir -p "$APPDIR/apprun-hooks"
{
    echo '# dia AppImage path relocation'
    echo 'export APPDIR="${APPDIR:-$(dirname "$(realpath "$0")")}"'
    echo 'export DIA_BASE_PATH="$APPDIR/usr/share"'
    echo "export DIA_LIB_PATH=\"\$APPDIR$PLUGIN_REL\""
    echo 'export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"'
} > "$APPDIR/apprun-hooks/dia-paths.sh"

# ----------------------------------------------------------------- deploy
log "5/7 Deploying dependencies (linuxdeploy + GTK plugin)"
# linuxdeploy resolves an executable's DT_NEEDED entries via the loader, which
# knows nothing about the AppDir (Dia's libdia.so has an empty install rpath).
# Point the loader at the staged lib dirs for the deploy run.
LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/dia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
linuxdeploy --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/dia" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Dia.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Dia.svg" \
    --plugin gtk

# linuxdeploy gives the libraries it deploys a '$ORIGIN' runpath, but Dia's
# plug-ins live one level deeper (usr/lib/dia) and must dlopen libdia.so from
# the parent directory — without this, object types silently fail to register
# at runtime.  --add-rpath appends, keeping linuxdeploy's entries intact.
while IFS= read -r -d '' f; do
    patchelf --add-rpath '$ORIGIN/..:$ORIGIN/../..:$ORIGIN/../../..:$ORIGIN/../../../..' "$f" \
        || die "patchelf failed on $f"
done < <(find "$APPDIR/usr" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

# ---------------------------------------------------------------- package
log "6/7 Creating AppImage"
VERSION=$(sed -n "s/^ *version: *'\([^']*\)'.*/\1/p" "$SRC/meson.build" | head -n1)
[ -n "$VERSION" ] || VERSION=unknown
APPIMAGE="$OUT/dia-${VERSION}-x86_64.AppImage"
rm -f "$APPIMAGE"
ARCH=x86_64 appimagetool "$APPDIR" "$APPIMAGE"

# --------------------------------------------------------------- verify
log "7/7 Verifying"
SMOKE="$WORK/smoke"
mkdir -p "$SMOKE"
( cd "$SMOKE" && "$APPIMAGE" --appimage-extract >/dev/null )
SQ="$SMOKE/squashfs-root"

# (a) The relocation chain must resolve inside the AppImage:
#     $APPDIR/usr/share/data/sheets -> share/dia/sheets (via the compat symlink)
[ -e "$SQ/usr/share/data/sheets/UML.sheet" ] \
    || die "relocation chain broken: usr/share/data/sheets/UML.sheet not resolvable"
[ -d "$SQ/usr/share/data/shapes/Flowchart" ] \
    || die "relocation chain broken: usr/share/data/shapes not resolvable"
[ -f "$SQ/apprun-hooks/dia-paths.sh" ] \
    || die "AppRun hook missing from AppImage"
HOOK_LIBP=$(sed -n 's/^export DIA_LIB_PATH="\$APPDIR\(.*\)"$/\1/p' "$SQ/apprun-hooks/dia-paths.sh")
[ -n "$HOOK_LIBP" ] && [ -d "$SQ$HOOK_LIBP" ] \
    || die "DIA_LIB_PATH in hook does not resolve to a directory in the AppImage"

# (b) Python must be absent
if find "$SQ" \( -name 'libpython*' -o -name '*python_plugin*' \) -print -quit | grep -q .; then
    die "python leaked into AppImage"
fi
[ ! -e "$SQ/usr/share/dia/python" ] || die "python scripts leaked into AppImage"

# (c) Every ELF inside the AppImage must resolve all its libraries using only
# its own runpaths + system defaults (no LD_LIBRARY_PATH help — that is what
# the runtime environment will look like).
log "Checking library resolution of all bundled binaries"
bad=0
while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
        ELF*) ;;
        *) continue ;;
    esac
    out=$(env -u LD_LIBRARY_PATH ldd "$f" 2>&1) || true
    if grep -q 'not found' <<<"$out"; then
        echo "!! unresolved libraries in ${f#"$SQ"/}:" >&2
        grep 'not found' <<<"$out" >&2
        bad=1
    fi
done < <(find "$SQ" -type f -print0)
[ "$bad" -eq 0 ] || die "AppImage contains unresolved libraries"

# (d) GUI smoke test: the AppImage must actually start (under Xvfb).
#     Exit 0 (clean quit) or 124 (still running when the timeout hit) = OK.
log "GUI smoke test (Xvfb, 30s)"
set +e
timeout 30 xvfb-run -a "$SQ/AppRun" >"$WORK/smoke.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "--- dia startup log ---" >&2
    cat "$WORK/smoke.log" >&2
    die "GUI smoke test failed (exit $rc)"
fi

log "SUCCESS"
rm -rf "$WORK"
ls -lh "$APPIMAGE"
sha256sum "$APPIMAGE"
