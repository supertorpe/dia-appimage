# Build environment for producing a Dia AppImage without installing anything
# on the host.  See README.md for usage.
#
#   ./run.sh                   (builds this image, then runs the build)
#
# The dia source is shallow-cloned from https://github.com/gnome/dia at
# runtime into a temp directory (see build-appimage.sh); the final AppImage
# is written to /output (output/ on the host).

FROM ubuntu:24.04

# APPIMAGE_EXTRACT_AND_RUN=1 lets the AppImage tool binaries (linuxdeploy,
# appimagetool) run without FUSE inside the container.
# DEPLOY_GTK_VERSION=3 tells linuxdeploy-plugin-gtk which GTK to bundle.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    APPIMAGE_EXTRACT_AND_RUN=1 \
    DEPLOY_GTK_VERSION=3 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig \
    PATH=/opt/appimage-tools:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# System dependencies.
#
# NOTE: python3-dev is installed only because dia's plug-ins/python/meson.build
# calls dependency('python3-embed') as *mandatory* (meson would abort without
# it).  The resulting python plug-in is stripped from the AppDir in
# build-appimage.sh — the AppImage ships without Python support.
#
# NOTE: libxml2-dev is deliberately not requested.  Ubuntu 24.04 ships
# libxml2 2.9.x but dia requires >= 2.14.0, so our own copy is built below and
# made visible first via PKG_CONFIG_PATH (verified after the build steps).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        desktop-file-utils \
        file \
        gettext \
        git \
        gir1.2-gtk-3.0 \
        libcairo2-dev \
        libemf-dev \
        libgdk-pixbuf2.0-bin \
        libgdk-pixbuf-2.0-dev \
        libgirepository1.0-dev \
        libglib2.0-bin \
        libglib2.0-dev \
        libglib2.0-dev-bin \
        libgraphene-1.0-dev \
        libgtk-3-dev \
        liblzma-dev \
        libpoppler-cpp-dev \
        libpoppler-private-dev \
        librsvg2-bin \
        librsvg2-dev \
        libxpm-dev \
        libxslt1-dev \
        meson \
        ninja-build \
        patchelf \
        pkg-config \
        python3-dev \
        xauth \
        xz-utils \
        xvfb \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# libxml2 >= 2.14.0 (dia hard requirement; Ubuntu ships 2.9.x) -> /usr/local
ARG LIBXML2_VERSION=2.14.6
ARG LIBXML2_SHA256=7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a
RUN curl -fsSL -o /tmp/libxml2.tar.xz \
        "https://download.gnome.org/sources/libxml2/2.14/libxml2-${LIBXML2_VERSION}.tar.xz" \
    && echo "${LIBXML2_SHA256}  /tmp/libxml2.tar.xz" | sha256sum -c - \
    && tar -C /tmp -xf /tmp/libxml2.tar.xz \
    && meson setup /tmp/libxml2-build "/tmp/libxml2-${LIBXML2_VERSION}" \
        --prefix=/usr/local --buildtype=release \
        -Dpython=disabled -Dlzma=enabled -Dzlib=enabled \
    && ninja -C /tmp/libxml2-build \
    && ninja -C /tmp/libxml2-build install \
    && rm -rf /tmp/libxml2* \
    && ldconfig

# xpm-pixbuf (not packaged by Ubuntu; also pulled in by dia's meson wrap when
# missing).  Baking it into the image makes meson find it system-wide, so the
# build never needs wrap downloads.
# If the build fails with the pin check, upstream moved main: update
# XPM_PIXBUF_COMMIT below (git ls-remote <url> main).
ARG XPM_PIXBUF_COMMIT=d290a0c846687b22d2a8c5aaec83a6689f30e1c3
RUN git clone --depth 1 https://gitlab.gnome.org/ZanderBrown/xpm-pixbuf.git /tmp/xpm-pixbuf \
    && cd /tmp/xpm-pixbuf \
    && HEAD="$(git rev-parse HEAD)" \
    && if [ "$HEAD" != "$XPM_PIXBUF_COMMIT" ]; then \
           echo "ERROR: xpm-pixbuf main is now $HEAD (pinned: $XPM_PIXBUF_COMMIT)." \
                "Update XPM_PIXBUF_COMMIT in the Dockerfile." >&2; exit 1; \
       fi \
    && meson setup /tmp/xpm-build . --prefix=/usr/local --buildtype=release \
    && ninja -C /tmp/xpm-build \
    && ninja -C /tmp/xpm-build install \
    && rm -rf /tmp/xpm* \
    && ldconfig

# Fail fast at image build time if dia's hard version requirements are not met
# (guards against pkg-config picking Ubuntu's older libxml2).
RUN pkg-config --atleast-version=2.14.0 libxml-2.0 \
    && pkg-config --exists xpm-pixbuf \
    && echo "OK: libxml-2.0 $(pkg-config --modversion libxml-2.0)," \
             "xpm-pixbuf $(pkg-config --modversion xpm-pixbuf)"

# AppImage packaging tools (downloaded once here; the build itself needs no
# network).  linuxdeploy-plugin-gtk is a plain shell script plugin; the
# symlink covers both names the plugin discovery may probe.
RUN mkdir -p /opt/appimage-tools \
    && cd /opt/appimage-tools \
    && curl -fsSL -O https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage \
    && curl -fsSL -O https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage \
    && curl -fsSL -O https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh \
    && chmod +x linuxdeploy-x86_64.AppImage appimagetool-x86_64.AppImage linuxdeploy-plugin-gtk.sh \
    && ln -sf linuxdeploy-plugin-gtk.sh linuxdeploy-plugin-gtk \
    && ln -sf linuxdeploy-x86_64.AppImage linuxdeploy \
    && ln -sf appimagetool-x86_64.AppImage appimagetool

COPY build-appimage.sh /opt/build-appimage.sh
RUN chmod +x /opt/build-appimage.sh

WORKDIR /opt
ENTRYPOINT ["/opt/build-appimage.sh"]
