#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Builds a reduced Mesa for the ThinkSmart View's GPU (Adreno 506): only the freedreno Gallium driver, EGL, GBM and
# OpenGL ES, no LLVM, no X11/Wayland, no Vulkan, no video. Debian's Mesa pulls LLVM (~450 MB on disk); this one is
# ~19 MB installed. It goes to /opt/mesa-freedreno (plus /etc/ld.so.conf.d/mesa-freedreno.conf), so it never collides
# with Debian packages: do not install Debian's libegl1/libgbm1/libgl1-mesa-dri on the device next to it.
# Cross-compiles on Debian 13 x86_64 (or builds natively on arm64). Output: image/parts/mesa-freedreno-<ver>-aarch64.tar.gz
#   ./image/build-mesa.sh            (as a normal user; it never calls sudo)
# Build dependencies: the script does not install them. Install them once by hand, as root (cross build):
#   dpkg --add-architecture arm64 && apt update
#   apt install --no-install-recommends ca-certificates curl xz-utils binutils meson ninja-build python3-mako
#     python3-yaml python3-packaging bison flex gcc-aarch64-linux-gnu g++-aarch64-linux-gnu pkg-config
#     libdrm-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 libexpat1-dev:arm64
#   (native build on arm64: the same without the :arm64 suffixes and with gcc g++ instead of the cross compilers)
# On the device it needs libdrm2, zlib and libzstd (in the image).
set -euo pipefail

VER=${MESA_VERSION:-25.0.7}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${PARTS_DIR:-$REPO/image/parts}
W=${MESA_WORK:-/var/tmp/mesa-freedreno-build}
TAR=$OUT/mesa-freedreno-$VER-aarch64.tar.gz

mkdir -p "$W" "$OUT"
cd "$W"
if [ ! -d "mesa-$VER" ]; then
    curl -fsSLO "https://archive.mesa3d.org/mesa-$VER.tar.xz"
    curl -fsSLO "https://archive.mesa3d.org/mesa-$VER.tar.xz.sha256sum" || true
    if [ -s "mesa-$VER.tar.xz.sha256sum" ]; then sha256sum -c "mesa-$VER.tar.xz.sha256sum"; fi
    tar xf "mesa-$VER.tar.xz"
fi

cross=()
if [ "$(uname -m)" != aarch64 ]; then
    cat > cross-aarch64.ini <<'INI'
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = '/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'cortex-a53'
endian = 'little'
INI
    cross=(--cross-file cross-aarch64.ini)
    export PKG_CONFIG_SYSROOT_DIR=/
fi

rm -rf build stage pkg
meson setup build "mesa-$VER" "${cross[@]}" \
    --prefix=/opt/mesa-freedreno --libdir=lib --buildtype=release -Db_ndebug=true -Dstrip=true \
    -Dgallium-drivers=freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers= -Dplatforms= \
    -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dglx=disabled -Dglvnd=disabled \
    -Dllvm=disabled -Dshared-llvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
    -Dbuild-tests=false -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=enabled \
    -Dgallium-va=disabled -Dgallium-vdpau=disabled -Dgallium-xa=disabled -Dvideo-codecs= -Dtools=
ninja -C build
DESTDIR="$W/stage" ninja -C build install >/dev/null

# Runtime files only (no headers, no pkg-config, no build-time libxml2)
L=stage/opt/mesa-freedreno/lib
mkdir -p pkg/opt/mesa-freedreno/lib/gbm pkg/etc/ld.so.conf.d
cp -a "$L"/libEGL.so.1* "$L"/libGLESv2.so.2* "$L"/libgallium-"$VER".so "$L"/libgbm.so.1* pkg/opt/mesa-freedreno/lib/
cp -a "$L"/gbm/dri_gbm.so pkg/opt/mesa-freedreno/lib/gbm/
echo /opt/mesa-freedreno/lib > pkg/etc/ld.so.conf.d/mesa-freedreno.conf
cp "mesa-$VER/docs/license.rst" pkg/opt/mesa-freedreno/LICENSE.rst
echo "Mesa $VER, freedreno only, built by thinksmart-view-debian image/build-mesa.sh" > pkg/opt/mesa-freedreno/VERSION
tar czf "$TAR" --owner=0 --group=0 -C pkg .
echo "done: $TAR ($(du -h "$TAR" | cut -f1), $(du -sh pkg | cut -f1) installed)"
