#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Builds a reduced Mesa for the ThinkSmart View's GPU (Adreno 506) as a Debian package: only the freedreno Gallium
# driver, EGL, GBM and OpenGL ES, no LLVM, no X11, no Vulkan, no video. Debian's Mesa pulls LLVM (~450 MB on disk);
# this one is ~20 MB installed.
#
# Why it looks the way it does:
# - Wayland platform: on, permanently. WPE WebKit 2.54 (the optional web layer, image/build-wpe.sh) creates its EGL
#   displays and buffers through it, also when it draws off screen; without it the web process cannot use the GPU.
#   It only adds libwayland-client0 (~90 KB) to the image.
# - Installed under /usr (/usr/lib/aarch64-linux-gnu), not /opt: WebKit's bubblewrap sandbox does not expose /opt,
#   and libgbm looks for its backend (gbm/dri_gbm.so) at the path it was built for.
# - libglvnd, like Debian's own Mesa (-Dglvnd=enabled): Debian's libegl1, libgles2 and libgl1 are libglvnd
#   dispatchers (~1 MB together) and other packages link against them (GStreamer's GL library, which WPE needs, links
#   libGL.so.1 and libEGL.so.1). This package is the vendor behind them: libEGL_mesa.so.0 plus its json in
#   /usr/share/glvnd/egl_vendor.d/, libgbm.so.1, libgallium and the GBM backend.
# - The package mesa-freedreno provides and replaces Debian's libegl-mesa0, libgbm1 and libglx-mesa0 (there is no
#   GLX: no X server on the device) and conflicts with mesa-libgallium and libgl1-mesa-dri, so apt never installs
#   Debian's Mesa or LLVM next to it, and refuses (instead of pulling them) a package that really needs them.
#
# Cross-compiles on Debian 13 x86_64 (or builds natively on arm64). Output: image/parts/mesa-freedreno_<ver>_arm64.deb
#   ./image/build-mesa.sh            (as a normal user; it never calls sudo)
#   MESA_JOBS=3 ./image/build-mesa.sh   fewer parallel compile jobs (default: ninja's, all CPUs)
#   MESA_VERSION=x.y.z MESA_SHA256=<sum> ./image/build-mesa.sh     another release (check the .sig on archive.mesa3d.org)
# Build dependencies: the script does not install them. Install them once by hand, as root (cross build):
#   dpkg --add-architecture arm64 && apt update
#   apt install --no-install-recommends ca-certificates curl xz-utils binutils meson ninja-build python3-mako
#     python3-yaml python3-packaging bison flex gcc-aarch64-linux-gnu g++-aarch64-linux-gnu pkg-config dpkg-dev
#     libwayland-bin libwayland-dev libdrm-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 libexpat1-dev:arm64
#     libwayland-dev:arm64 libwayland-egl-backend-dev:arm64 libglvnd-dev:arm64
#   (native build on arm64: the same without the :arm64 suffixes and with gcc g++ instead of the cross compilers)
# Mesa 26.x bundles wayland-protocols 1.49, whose XML Debian 13's wayland-scanner (1.23) rejects in --strict mode:
# with a scanner older than 1.24 the build runs it through a small wrapper that drops --strict (same generated code).
set -euo pipefail
umask 022

VER=${MESA_VERSION:-26.3.0}
case "$VER" in
    # signatures checked against the release managers' keys (docs/release-maintainers-keys.asc in the tarball;
    # archive.mesa3d.org has no .sha256sum)
    26.3.0) SUM=91d729aa68bb89e4ec857841300bbe922bcb3e52b1f97566ca83930d3b28343a ;;
    26.3.0-rc3) SUM=3600c01f11439628d0a85de5ed9cb76f297d13e9783cdeecb91aa685055c9942 ;;
    *) SUM=${MESA_SHA256:-} ;;
esac
[ -n "$SUM" ] || { echo "no known sha256 for Mesa $VER: set MESA_SHA256 (after checking the .sig)" >&2; exit 1; }
DEBVER=${VER/-rc/\~rc}-1
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${PARTS_DIR:-$REPO/image/parts}
W=${MESA_WORK:-/var/tmp/mesa-freedreno-build}
DEB=$OUT/mesa-freedreno_${DEBVER}_arm64.deb
MA=aarch64-linux-gnu

mkdir -p "$W" "$OUT"
OUT=$(cd "$OUT" && pwd); DEB=$OUT/mesa-freedreno_${DEBVER}_arm64.deb
cd "$W"
[ -s "mesa-$VER.tar.xz" ] || curl -fsSLO "https://archive.mesa3d.org/mesa-$VER.tar.xz"
echo "$SUM  mesa-$VER.tar.xz" | sha256sum -c -
rm -rf "mesa-$VER"
tar xf "mesa-$VER.tar.xz"

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

# wayland-scanner of the build machine; older than 1.24: a wrapper without --strict, found through its own .pc
scanner_ver=$(pkg-config --modversion wayland-scanner)
if [ "$(printf '%s\n1.24\n' "$scanner_ver" | sort -V | head -n1)" != 1.24 ]; then
    scanner=$(pkg-config --variable=wayland_scanner wayland-scanner)
    rm -rf wl-scanner; mkdir -p wl-scanner/pkgconfig
    printf '#!/bin/sh\n# %s without --strict (Mesa 26 bundles wayland-protocols 1.49)\nfor a do shift; [ "$a" = --strict ] || set -- "$@" "$a"; done\nexec %s "$@"\n' \
        "$scanner" "$scanner" > wl-scanner/wayland-scanner
    chmod 755 wl-scanner/wayland-scanner
    sed "s|^wayland_scanner=.*|wayland_scanner=$W/wl-scanner/wayland-scanner|" \
        "$(pkg-config --variable=pcfiledir wayland-scanner)/wayland-scanner.pc" > wl-scanner/pkgconfig/wayland-scanner.pc
    export PKG_CONFIG_PATH_FOR_BUILD=$W/wl-scanner/pkgconfig
    [ ${#cross[@]} -gt 0 ] || export PKG_CONFIG_PATH=$W/wl-scanner/pkgconfig
    echo "wayland-scanner $scanner_ver < 1.24: running it without --strict"
fi

rm -rf build stage pkg
meson setup build "mesa-$VER" "${cross[@]}" \
    --prefix=/usr --libdir=lib/$MA --sysconfdir=/etc --buildtype=release -Db_ndebug=true -Dstrip=true \
    -Dgallium-drivers=freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers= -Dplatforms=wayland \
    -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dglx=disabled -Dglvnd=enabled \
    -Dllvm=disabled -Dshared-llvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
    -Dbuild-tests=false -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=enabled \
    -Dgallium-va=disabled -Dvideo-codecs= -Dtools=
ninja -C build ${MESA_JOBS:+-j"$MESA_JOBS"}
DESTDIR="$W/stage" ninja -C build install >/dev/null

# Runtime files only (no headers, no pkg-config, no build-time libxml2)
L=stage/usr/lib/$MA
D=pkg/usr/lib/$MA
mkdir -p "$D/gbm" pkg/usr/share/glvnd/egl_vendor.d pkg/usr/share/doc/mesa-freedreno pkg/DEBIAN
cp -a "$L"/libEGL_mesa.so.0* "$L"/libgallium-"$VER".so "$L"/libgbm.so.1* "$D/"
cp -a "$L"/gbm/dri_gbm.so "$D/gbm/"
cp -a stage/usr/share/glvnd/egl_vendor.d/50_mesa.json pkg/usr/share/glvnd/egl_vendor.d/
cp "mesa-$VER/docs/license.rst" pkg/usr/share/doc/mesa-freedreno/copyright
echo "Mesa $VER, freedreno only, built by thinksmart-view-debian image/build-mesa.sh" > pkg/usr/share/doc/mesa-freedreno/VERSION

# Depends: the package of every library the files need (arm64 libraries of the build machine), plus the dispatchers
deps=$(for f in "$D"/*.so* "$D"/gbm/*.so; do [ -L "$f" ] || objdump -p "$f"; done | awk '/NEEDED/ {print $2}' | sort -u |
    while read -r so; do
        case "$so" in libEGL_mesa*|libgbm.so*|libgallium-*) continue ;; esac
        dpkg -S "*/$MA/$so" 2>/dev/null | head -n1 | cut -d: -f1
    done | sort -u | paste -sd, | sed 's/,/, /g')
[ -n "$deps" ] || { echo "could not work out the dependencies" >&2; exit 1; }
cat > pkg/DEBIAN/control <<EOF
Package: mesa-freedreno
Version: $DEBVER
Architecture: arm64
Maintainer: Andrea Mattera <26578395+m0s4ik@users.noreply.github.com>
Section: libs
Priority: optional
Installed-Size: $(du -sk --exclude=DEBIAN pkg | cut -f1)
Depends: $deps, libegl1, libgles2
Provides: libegl-mesa0, libgbm1 (= $DEBVER), libglx-mesa0
Conflicts: libegl-mesa0, libgbm1, libglx-mesa0, mesa-libgallium, libgl1-mesa-dri
Replaces: libegl-mesa0, libgbm1, libglx-mesa0, mesa-libgallium, libgl1-mesa-dri
Homepage: https://github.com/m0s4ik/thinksmart-view-debian
Description: Mesa $VER for the Lenovo ThinkSmart View (freedreno only, no LLVM)
 EGL (libglvnd vendor), GBM and OpenGL ES for the Adreno 506, with the Wayland
 platform, built by image/build-mesa.sh of thinksmart-view-debian. Replaces
 Debian's Mesa, which pulls LLVM. No GLX, Vulkan or video acceleration.
EOF
cat > pkg/DEBIAN/triggers <<'EOF'
activate-noawait ldconfig
EOF
dpkg-deb --root-owner-group -Zxz --build pkg "$DEB" >/dev/null
echo "done: $DEB ($(du -h "$DEB" | cut -f1), $(du -sh --exclude=DEBIAN pkg | cut -f1) installed)"
dpkg-deb -f "$DEB" Depends Provides
