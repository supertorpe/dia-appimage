# Building the Dia AppImage in Docker

Everything needed to compile [Dia](https://gitlab.gnome.org/GNOME/dia) and
package it as an x86_64 AppImage lives in this directory. The host only needs
**Docker** (plus network): the dia source is shallow-cloned from the official
GitHub mirror (<https://github.com/gnome/dia>) inside the container at build
time, and nothing is written to the host except the finished artifact.

## Usage

```bash
./run.sh
```

The finished artifact lands in `output/`:

```
output/dia-<version>-x86_64.AppImage
```

Run it on any Linux distribution with glibc ≥ 2.39 (Ubuntu 24.04+, Fedora 40+,
Debian 13+, Arch, …):

```bash
./output/dia-*.AppImage
```

The first run downloads the base image, packages, and the dia source;
afterwards Docker's layer cache makes image rebuilds fast. Re-running `run.sh`
always does a fresh shallow clone and a fresh compile of the selected ref.

### Building a specific version

By default the repository's default branch (HEAD) is built. To build a
different ref — a tag, a branch, or a commit SHA — set `DIA_REF`:

```bash
DIA_REF=DIA_0_97_2 ./run.sh     # a release tag
DIA_REF=<commit-sha> ./run.sh   # any commit reachable from a branch or tag
```

A commit SHA must be reachable from some branch or tag on the remote (GitHub
allows fetching reachable commits directly). `DIA_REPO` overrides the
repository URL, e.g. to build from a fork:

```bash
DIA_REPO=https://github.com/<user>/dia DIA_REF=<branch> ./run.sh
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Build environment: toolchain, GTK3 stack, pinned libxml2 2.14.6 + xpm-pixbuf (built from source into `/usr/local`), and the AppImage tooling (`linuxdeploy`, `linuxdeploy-plugin-gtk`, `appimagetool`). |
| `build-appimage.sh` | Runs inside the container: shallow-clone dia → meson compile → stage `AppDir` → linuxdeploy + GTK plugin → appimagetool → verify. |
| `run.sh` | Host entry point: builds the image, runs the container (passing `DIA_REPO`/`DIA_REF` through when set), and mounts `output/` for the artifact. |
| `.dockerignore` | Keeps `output/` out of the image build context. |

## How the AppImage works

* **Prefix** is `/usr` at compile time, but everything is staged under an
  `AppDir` and bundled. Dia bakes absolute paths (`PKGDATADIR=/usr/share/dia`,
  `DIALIBDIR=/usr/lib/dia`) at compile time, so an AppRun hook
  (`AppDir/apprun-hooks/dia-paths.sh`) exports:
  * `DIA_BASE_PATH=$APPDIR/usr/share` — with a compatibility symlink
    `usr/share/data → dia`, because dia appends a literal `/data` to
    `DIA_BASE_PATH` (a source-tree quirk); this relocates sheets, shapes,
    lines, UI files and XSLT stylesheets.
  * `DIA_LIB_PATH` — plug-ins and object libraries; the directory is detected
    at build time (Dia's libdir is multiarch on Ubuntu, e.g.
    `usr/lib/x86_64-linux-gnu/dia`).
  * `XDG_DATA_DIRS` — so the bundled icons are found.
* **GTK 3, GLib, cairo, poppler, libxml2, …** are bundled by
  `linuxdeploy` + `linuxdeploy-plugin-gtk` (schemas, pixbuf loaders, IM
  modules, typelibs included). OpenGL/Mesa is intentionally left to the host,
  as usual for AppImages.
* **Verification** (runs on every build): relocation chain resolves inside the
  extracted image, no Python present, every bundled ELF resolves all its
  libraries, and the GUI starts under Xvfb.

## Customizing

* **Re-enable the Python scripting plug-in:** remove the "Strip Python
  support" block in `build-appimage.sh`, then bundle a Python runtime — copy
  `/usr/lib/python3.*` plus PyGObject into `AppDir/usr/lib/` and export
  `PYTHONHOME=$APPDIR/usr` in the AppRun hook. Not enabled by default because
  it is fragile across host distributions.
* **Add/ remove dependencies:** edit the `apt-get install` list in the
  `Dockerfile`. Optional Dia plug-ins currently enabled: PDF (poppler-cpp),
  XSLT (libxslt), WMF (libemf). OGDF (auto-layout) and the `doc`/man-page
  targets are disabled/not packaged.
* **libxml2 / xpm-pixbuf versions:** `ARG`s at the top of the `Dockerfile`.
  If the xpm-pixbuf pin check fails, upstream moved `main`; update
  `XPM_PIXBUF_COMMIT` (`git ls-remote https://gitlab.gnome.org/ZanderBrown/xpm-pixbuf.git main`).

## Known limitations

* **glibc floor 2.39** — inherited from the Ubuntu 24.04 base (Dia needs
  glib ≥ 2.80, which rules out older bases unless glib is also built from
  source). Older distros than 2024-era ones cannot run this AppImage.
* **UI translations:** Dia compiles gettext's `LOCALEDIR=/usr/share/locale`
  with no runtime override, so the AppImage falls back to English unless the
  host happens to have Dia translations installed. Fixing this would require
  patching Dia itself.
* **x86_64 only.** The tool URLs in the `Dockerfile` are x86_64; build on (or
  cross-build with) a matching host. For aarch64, swap the tool URLs for the
  aarch64 releases and build on an aarch64 machine.
* `linuxdeploy`/`appimagetool` are fetched from GitHub's `continuous`
  releases (they publish no versioned tags); they are frozen into the image
  layer whenever you rebuild the image.
