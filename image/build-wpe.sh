#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Backport of WPE WebKit (the web engine for embedded devices) from Debian forky/sid to Debian 13 trixie, arm64.
# Debian 13 ships WPE 2.48, which cannot use the GPU with Mesa 26 and is no longer updated; this rebuilds Debian's
# own source package of a newer release against trixie. Optional: only for a web view on the device (not in the
# image yet). WebKit is a large build: run it on a fast arm64 machine with Docker, natively (no emulation):
# an Apple Silicon Mac (Docker Desktop, OrbStack, Rancher Desktop) or an arm64 Linux box. Measured: 46 minutes on a
# 20-core arm64 machine with 120 GB of RAM. Each parallel job needs ~3 GB of memory when linking.
#   ./image/build-wpe.sh [OUT_DIR]          default OUT_DIR: image/parts
# Output: libwpewebkit-2.0-1, libwpewebkit-2.0-dev and wpewebkit-webdriver .deb files, version <ver>~bpo13+1.
# Work directory: $WPE_WORK (default ~/wpe-backport): sources, build.log; the build itself runs inside the container.
set -euo pipefail

VER=${WPE_VERSION:-2.54.2-1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/image/parts}
W=${WPE_WORK:-$HOME/wpe-backport}

command -v docker >/dev/null || { echo "Docker is needed (Docker Desktop, OrbStack or Rancher Desktop on a Mac)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but not running" >&2; exit 1; }
case "$(uname -m)" in arm64|aarch64) ;; *) echo "warning: not an arm64 machine, the build will be emulated and very slow" >&2 ;; esac
MEM_GB=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
CPUS=$(docker info --format '{{.NCPU}}')
JOBS=$(( MEM_GB / 3 )); [ "$JOBS" -lt 2 ] && JOBS=2; [ "$JOBS" -gt "$CPUS" ] && JOBS=$CPUS
echo "Docker: ${MEM_GB} GB of memory, ${CPUS} CPUs -> ${JOBS} parallel jobs"

mkdir -p "$W/out" "$OUT"
rm -f "$W"/out/*.deb
date > "$W/started"
# shellcheck disable=SC2016  # the script below is expanded inside the container
docker run --rm --platform linux/arm64 -v "$W:/work" -e VER="$VER" -e JOBS="$JOBS" debian:trixie bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q --no-install-recommends ca-certificates curl dpkg-dev devscripts equivs xz-utils >/dev/null
  cd /work
  for f in wpewebkit_${VER}.dsc wpewebkit_${VER%-*}.orig.tar.xz wpewebkit_${VER%-*}.orig.tar.xz.asc wpewebkit_${VER}.debian.tar.xz; do
    [ -s "$f" ] || curl -fsSLO "https://deb.debian.org/debian/pool/main/w/wpewebkit/$f"
  done
  # build inside the container: extracting onto a volume shared with macOS fails on file permissions
  mkdir -p /build && cp wpewebkit_* /build/ && cd /build
  dpkg-source -x wpewebkit_${VER}.dsc src
  cd src
  dch --bpo --distribution trixie-backports "Rebuild for Debian 13 (trixie), for the Lenovo ThinkSmart View."
  mk-build-deps -i -r -t "apt-get -y -q --no-install-recommends" debian/control
  DEB_BUILD_OPTIONS="nocheck nodoc parallel=${JOBS}" DEB_BUILD_PROFILES=nodoc dpkg-buildpackage -B -uc -us > /work/build.log 2>&1
  cp ../*.deb /work/out/
'
date > "$W/finished"
# the debug symbol packages (~150 MB) stay in $W/out
for p in libwpewebkit-2.0-1 libwpewebkit-2.0-dev wpewebkit-webdriver; do
  cp "$W"/out/"${p}"_*.deb "$OUT/"
done
echo "done: $(cat "$W/started") -> $(cat "$W/finished"); packages in $OUT (debug symbols in $W/out)"
