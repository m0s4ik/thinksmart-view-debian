#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Builds the image of the "system" partition of a Lenovo ThinkSmart View (CD-18781Y): Debian 13 trixie arm64 minimal,
# with the postmarketOS kernel 7.1.3-msm8953 (frozen), working audio, Wi-Fi and ssh. Applications (for example a voice
# assistant) are added on top by a customization script (CUSTOMIZE in config.env) or installed later over ssh.
#
#   sudo ./image/build.sh [image/config.env]
#
# Runs on any Debian/Ubuntu x86_64 or arm64 machine as root (debootstrap + qemu-user-static, installed if missing).
# It never touches the device: repartitioning and flashing over EDL are separate steps (docs/flashing.md).
#
# Inputs:  config.env (see config.env.example: Wi-Fi, ssh key, root password, ...)
#          $PARTS_DIR  device files (docs/kernel.md): boot.tar, modules-7.1.3-msm8953.tar, firmware.tar, ucm.tar,
#                      snd-soc-tas5782m.ko
#                      mesa-freedreno_<ver>_arm64.deb (image/build-mesa.sh)
#                      vcnl4000.ko (optional, light sensor: driver/vcnl4000)
#                      venus-core.ko (optional, video decoder: driver/venus)
#                      libwpewebkit-2.0-1_<ver>_arm64.deb (only with WEB=1: image/build-wpe.sh)
#                      s5kc505a.ko + apq8053-lenovo-cd-18781y-camera.dtb (only with CAMERA=1: driver/s5kc505a)
#          AIRPLAY=1 needs nothing in PARTS_DIR (Debian packages only; venus-core.ko for screen mirroring)
#          image/rootfs/ of this repository, and optionally the CUSTOMIZE script
# Output:  $WORK_DIR/out/thinksmart-debian-YYYYMMDD.img (sparse) + .img.gz + .sha256
#          (AIRPLAY=1: also gstreamer1.0-plugins-bad-airplay_<ver>_arm64.deb, see image/README.md)
#
# Image = the whole "system" partition after apply-ubuntu-gpt.sh ($SYSTEM_SECTORS sectors) with an MBR inside:
#   p1 2048 + 497664 sectors, ext2 (minimal features like postmarketOS: lk2nd reads it), /boot with extlinux;
#   p2 from 499712 to the end, ext4 (root). Both are mounted by the postmarketOS initramfs (kpartx, pmos_*_uuid).
set -eu
umask 022

REPO=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${1:-$REPO/image/config.env}
[ -r "$CONFIG" ] || { echo "missing $CONFIG (copy image/config.env.example)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

DEVICE_HOSTNAME=${DEVICE_HOSTNAME:-thinksmart}
TIMEZONE=${TIMEZONE:-Etc/UTC}
WIFI_COUNTRY=${WIFI_COUNTRY:-}
WIFI_MAC=${WIFI_MAC:-}
ROOT_PASSWORD=${ROOT_PASSWORD:-}
LAN_V4=${LAN_V4:-192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12}
LAN_V6=${LAN_V6:-fc00::/7, fe80::/10}
LAN_TCP_PORTS=${LAN_TCP_PORTS:-22}
SYSTEM_SECTORS=${SYSTEM_SECTORS:-14280671}
CUSTOMIZE=${CUSTOMIZE:-}
WEB=${WEB:-0}
AIRPLAY=${AIRPLAY:-0}
CAMERA=${CAMERA:-0}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
cd "$REPO"
P=$(cd "${PARTS_DIR:-image/parts}" && pwd)
W=${WORK_DIR:-/var/tmp/thinksmart-build}
C=$W/cache
R=$W/chroot
M=$W/mnt
OUT=$W/out
FS=$REPO/image/rootfs
KVER=7.1.3-msm8953
P1_START=2048; P1_SECTORS=497664
P2_START=499712
TODAY=$(date +%Y%m%d)
DTB=apq8053-lenovo-cd-18781y.dtb
CAMERA_DTB=apq8053-lenovo-cd-18781y-camera.dtb
# CAMERA=1: contiguous memory for libcamera's dma-buf heap; the kernel's default 32 MB is too small for full-size
# frames (2560x1600 fails to allocate, 128 MB streams it; driver/s5kc505a/README.md#libcamera)
CAMERA_CMA=cma=128M
LOOP1=
LOOP2=

PACKAGES="systemd systemd-sysv systemd-timesyncd udev kmod dbus
  network-manager wpasupplicant openssh-server nftables avahi-daemon
  alsa-utils alsa-ucm-conf python3 python3-venv python3-pip
  iproute2 iputils-ping iw curl ca-certificates less vim-tiny procps tzdata locales e2fsprogs
  fonts-dejavu-core dmsetup"
# AIRPLAY=1: what an AirPlay receiver built on UxPlay needs at run time (the receiver itself comes with the
# application): GStreamer with its base (appsrc, audioconvert), good (v4l2 decoders on venus, capssetter) and libav
# (AAC, ALAC) plugins, libplist and avahi's dns_sd compatibility library. Of the bad plugins it needs only h264parse
# and unixfdsink, but Debian's gstreamer1.0-plugins-bad is one package that pulls ~80 more packages and ~210 MB (GTK,
# onnxruntime, oneDNN, ...): AIRPLAY_BAD_PLUGINS are taken from it into a small local package instead (see below).
# No GStreamer GL, ALSA plugin, encoder or tools.
AIRPLAY_PACKAGES="gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav libgstreamer-plugins-bad1.0-0
  libplist-2.0-4 libavahi-compat-libdnssd1"
AIRPLAY_BAD_PLUGINS="libgstvideoparsersbad.so libgstunixfd.so"
# CAMERA=1: libcamera 0.4 with the simple pipeline handler and its software ISP (ipa_soft_simple, for qcom-camss),
# GStreamer's libcamerasrc and gst-launch-1.0 (GStreamer core only: 15 packages, ~45 MB). Not gstreamer1.0-plugins-base
# (videoconvert) or -good (videoflip, to turn the upside-down frame): they pull X11 libraries, cairo, PulseAudio, ...
# (+24 and +93 packages); apt install them on the device if an application needs them (driver/s5kc505a/README.md).
CAMERA_PACKAGES="libcamera0.4 libcamera-ipa gstreamer1.0-libcamera gstreamer1.0-tools"
# dmsetup: udev rules of device-mapper (55-dm.rules, 60-persistent-storage-dm.rules). /boot and the root file system
# are device-mapper devices (kpartx in the initramfs): without them, no /dev/disk/by-uuid for /boot and emergency mode
# at boot. The postmarketOS initramfs also needs rootfs/etc/udev/rules.d/54-dm-initramfs.rules (docs/boot.md).

step() { echo; echo "=== $(date +%T) $*"; }

unmount_all() {
    for d in $(awk '{print $2}' /proc/mounts | grep -E "^($R|$M)(/|$)" | sort -r); do
        umount -l "$d" 2>/dev/null || true
    done
    for l in "$LOOP1" "$LOOP2"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null || true; done
    LOOP1=; LOOP2=
}
loop_attach() {  # loop_attach IMG START SIZE [losetup options]: one partition (in sectors) on its own loop device
    # No losetup -P: in a container (LXC, docker) /dev is not devtmpfs, so neither the loop node nor the partition
    # nodes appear by themselves; create the node if missing and attach the partition with an offset instead.
    local img=$1 start=$2 size=$3 dev
    shift 3
    dev=$(losetup -f | awk '{print $1}')
    [ -b "$dev" ] || mknod -m 0660 "$dev" b 7 "${dev#/dev/loop}"
    losetup "$@" -o $((start * 512)) --sizelimit $((size * 512)) "$dev" "$img" && echo "$dev"
}
on_exit() {
    s=$?
    unmount_all
    [ $s = 0 ] || echo "ERROR: build interrupted (code $s); chroot and mounts cleaned up" >&2
    exit $s
}
trap on_exit EXIT

# commands inside the chroot (arm64, through qemu-user-static and binfmt_misc on non-arm64 hosts)
in_chroot() {
    chroot "$R" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive SKIP_CYTHON=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$@"
}
install_file() {  # install_file SRC DEST: keeps the executable bit
    mkdir -p "$(dirname "$2")"
    if [ -x "$1" ]; then install -m 0755 "$1" "$2"; else install -m 0644 "$1" "$2"; fi
}

# --- checks --------------------------------------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "must be run as root" >&2; exit 1; }
MESA_DEB=$(find "$P" -maxdepth 1 -name "mesa-freedreno_*_arm64.deb" | sort -V | tail -n1)
if [ -z "$MESA_DEB" ]; then
    echo "missing $P/mesa-freedreno_*_arm64.deb: build it with image/build-mesa.sh" >&2
    [ -z "$(find "$P" -maxdepth 1 -name "mesa-freedreno-*.tar.gz")" ] || \
        echo "(the mesa-freedreno-*.tar.gz there is the old format, installed in /opt: rebuild)" >&2
    exit 1
fi
case "$WEB" in
    0|"") WEB=0 ;;
    1)  WPE_DEB=$(find "$P" -maxdepth 1 -name "libwpewebkit-2.0-1_*_arm64.deb" | sort -V | tail -n1)
        [ -n "$WPE_DEB" ] || { echo "WEB=1 but no $P/libwpewebkit-2.0-1_*_arm64.deb: build it with image/build-wpe.sh" >&2; exit 1; } ;;
    *)  echo "WEB must be 0 or 1" >&2; exit 1 ;;
esac
case "$AIRPLAY" in
    0|"") AIRPLAY=0 ;;
    1)  ;;
    *)  echo "AIRPLAY must be 0 or 1" >&2; exit 1 ;;
esac
# CAMERA=1: front camera (driver/s5kc505a). Its DTB is the kernel package's one rebuilt with the patch: only the
# exact file pinned in driver/s5kc505a/dtb.sha256 (built by CI) is accepted, because lk2nd boots it.
case "$CAMERA" in
    0|"") CAMERA=0 ;;
    1)  for f in s5kc505a.ko "$CAMERA_DTB"; do
            [ -s "$P/$f" ] || { echo "CAMERA=1 but no $P/$f: see driver/s5kc505a/README.md" >&2; exit 1; }
        done
        grep -aq "vermagic=$KVER SMP preempt mod_unload aarch64" "$P/s5kc505a.ko" || \
            { echo "$P/s5kc505a.ko is not built for $KVER (vermagic)" >&2; exit 1; }
        want=$(awk -v f="$CAMERA_DTB" '$2 == f {print $1}' "$REPO/driver/s5kc505a/dtb.sha256")
        [ "$(sha256sum < "$P/$CAMERA_DTB" | cut -d' ' -f1)" = "$want" ] || \
            { echo "$P/$CAMERA_DTB is not the one in driver/s5kc505a/dtb.sha256: rebuild it (driver/s5kc505a)" >&2; exit 1; }
        PACKAGES="$PACKAGES v4l-utils" ;;
    *)  echo "CAMERA must be 0 or 1" >&2; exit 1 ;;
esac
for f in boot.tar modules-$KVER.tar firmware.tar ucm.tar snd-soc-tas5782m.ko; do
    [ -s "$P/$f" ] || { echo "missing $P/$f (see docs/kernel.md)" >&2; exit 1; }
done
# the old driver (before 2026-11-03) has no hardware volume: thinksmart-audio would fall back to the softvol
if ! grep -aq 'parm=volume_mode:' "$P/snd-soc-tas5782m.ko" && [ "${ALLOW_OLD_TAS5782M:-}" != 1 ]; then
    echo "$P/snd-soc-tas5782m.ko is the old driver (no volume_mode parameter): rebuild it from driver/tas5782m" >&2
    echo "(see driver/tas5782m/README.md), or set ALLOW_OLD_TAS5782M=1 to use it anyway" >&2
    exit 1
fi
[ -n "${WIFI_SSID:-}" ] && [ -n "${WIFI_PSK:-}" ] || { echo "WIFI_SSID and WIFI_PSK are required" >&2; exit 1; }
[ -s "${SSH_AUTHORIZED_KEYS_FILE:-}" ] || { echo "SSH_AUTHORIZED_KEYS_FILE (${SSH_AUTHORIZED_KEYS_FILE:-}) missing or empty" >&2; exit 1; }
if [ -n "$CUSTOMIZE" ]; then
    CUSTOMIZE=$(cd "$(dirname "$CUSTOMIZE")" && pwd)/$(basename "$CUSTOMIZE")
    [ -r "$CUSTOMIZE" ] || { echo "CUSTOMIZE script $CUSTOMIZE not found" >&2; exit 1; }
fi
mkdir -p "$C/apt/partial" "$OUT"

step "host packages"
missing=
for p in debootstrap qemu-user-static binfmt-support pigz python3 fdisk e2fsprogs; do
    dpkg-query -W -f='${Status}' $p 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"
done
if [ -n "$missing" ]; then
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $missing
fi
if [ "$(uname -m)" != aarch64 ]; then
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        systemctl restart systemd-binfmt 2>/dev/null || update-binfmts --enable qemu-aarch64
    fi
    grep -q '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || { echo "binfmt qemu-aarch64 without the F flag" >&2; exit 1; }
fi

# --- identities kept between builds (the device keeps its ssh host keys after a reflash) ---------------------------
[ -s "$C/uuid-boot" ] || cat /proc/sys/kernel/random/uuid > "$C/uuid-boot"
[ -s "$C/uuid-root" ] || cat /proc/sys/kernel/random/uuid > "$C/uuid-root"
[ -s "$C/machine-id" ] || tr -d '-' < /proc/sys/kernel/random/uuid > "$C/machine-id"
BOOT_UUID=$(cat "$C/uuid-boot"); ROOT_UUID=$(cat "$C/uuid-root")

# --- debootstrap ----------------------------------------------------------------------------------------------------
step "new chroot (debootstrap trixie arm64 minbase)"
unmount_all
rm -rf "$R"
debootstrap --arch=arm64 --variant=minbase --cache-dir="$C/apt" trixie "$R" "$DEBIAN_MIRROR"

mount -t proc proc "$R/proc"
mount -t sysfs sys "$R/sys"
mount --bind /dev "$R/dev"
mount --bind /dev/pts "$R/dev/pts"
mount -t tmpfs tmpfs "$R/run"
mount -t tmpfs tmpfs "$R/tmp"
rm -f "$R/etc/resolv.conf"; cp -L /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"

step "Debian packages"
install -m 0644 "$FS/etc/apt/sources.list.d/debian.sources" "$R/etc/apt/sources.list.d/debian.sources"
rm -f "$R/etc/apt/sources.list"
install -m 0644 "$FS/etc/apt/apt.conf.d/90thinksmart" "$R/etc/apt/apt.conf.d/90thinksmart"
mount --bind "$C/apt" "$R/var/cache/apt/archives"
in_chroot apt-get update -q
in_chroot apt-get install -y -q --no-install-recommends $PACKAGES
# GPU: reduced Mesa (freedreno, EGL/GBM/GLES through libglvnd, no LLVM), see image/build-mesa.sh. It provides
# libgbm1 and libegl-mesa0, so neither this nor anything installed later pulls Debian's Mesa and LLVM.
cp "$MESA_DEB" "$R/tmp/"
in_chroot apt-get install -y -q --no-install-recommends "/tmp/$(basename "$MESA_DEB")"
if [ "$WEB" = 1 ]; then
    # web layer: WPE WebKit and what apt pulls with it (bubblewrap and xdg-dbus-proxy for its sandbox, GStreamer,
    # ICU, libsoup, glib-networking, libglvnd's libgl1 for GStreamer's GL library); nothing when WEB=0
    step "web layer: $(basename "$WPE_DEB")"
    cp "$WPE_DEB" "$R/tmp/"
    in_chroot apt-get install -y -q --no-install-recommends "/tmp/$(basename "$WPE_DEB")"
fi
if [ "$AIRPLAY" = 1 ]; then
    step "AirPlay runtime (GStreamer for UxPlay)"
    # shellcheck disable=SC2086
    in_chroot apt-get install -y -q --no-install-recommends $AIRPLAY_PACKAGES
    # gstreamer1.0-plugins-bad-airplay: AIRPLAY_BAD_PLUGINS, unchanged, out of Debian's gstreamer1.0-plugins-bad of the
    # same version as the installed libgstreamer-plugins-bad1.0-0. It conflicts with the full package, so
    # `apt install gstreamer1.0-plugins-bad` on the device replaces it. The parsing code itself is in
    # libgstreamer-plugins-bad1.0-0 (libgstcodecparsers), which apt keeps upgrading; a rebuild refreshes the plugins.
    badver=$(in_chroot dpkg-query -W -f='${Version}' libgstreamer-plugins-bad1.0-0)
    upver=${badver%%-*}
    in_chroot sh -c "cd /tmp && apt-get download -q gstreamer1.0-plugins-bad=$badver"
    BP=$R/tmp/pkg; GD=usr/lib/aarch64-linux-gnu/gstreamer-1.0; DOC=usr/share/doc/gstreamer1.0-plugins-bad-airplay
    rm -rf "$R/tmp/bad" "$BP"; mkdir -p "$BP/DEBIAN" "$BP/$GD" "$BP/$DOC"
    dpkg-deb -x "$R"/tmp/gstreamer1.0-plugins-bad_*_arm64.deb "$R/tmp/bad"
    for f in $AIRPLAY_BAD_PLUGINS; do install -m 0644 "$R/tmp/bad/$GD/$f" "$BP/$GD/"; done
    install -m 0644 "$R/tmp/bad/usr/share/doc/gstreamer1.0-plugins-bad/copyright" "$BP/$DOC/"
    {
        echo "Package: gstreamer1.0-plugins-bad-airplay"
        echo "Version: $badver+thinksmart1"
        echo "Architecture: arm64"
        echo "Maintainer: thinksmart-view-debian image/build.sh <root@localhost>"
        echo "Depends: libgstreamer-plugins-bad1.0-0 (>= $upver), libgstreamer-plugins-bad1.0-0 (<< ${upver%.*}.99), libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libglib2.0-0t64"
        echo "Conflicts: gstreamer1.0-plugins-bad"
        echo "Replaces: gstreamer1.0-plugins-bad"
        echo "Section: libs"
        echo "Priority: optional"
        echo "Description: h264parse and unixfdsink from gstreamer1.0-plugins-bad $badver"
        echo " $AIRPLAY_BAD_PLUGINS, unchanged, from Debian's gstreamer1.0-plugins-bad,"
        echo " without its other plugins and their dependencies. Built by image/build.sh of"
        echo " thinksmart-view-debian for the AirPlay runtime (AIRPLAY=1)."
    } > "$BP/DEBIAN/control"
    in_chroot dpkg-deb --root-owner-group -b /tmp/pkg /tmp/gstreamer1.0-plugins-bad-airplay.deb
    in_chroot apt-get install -y -q --no-install-recommends /tmp/gstreamer1.0-plugins-bad-airplay.deb
    # kept next to the image, for devices that get the AirPlay runtime without reflashing (image/README.md)
    rm -f "$OUT"/gstreamer1.0-plugins-bad-airplay_*_arm64.deb
    cp "$R/tmp/gstreamer1.0-plugins-bad-airplay.deb" "$OUT/gstreamer1.0-plugins-bad-airplay_${badver}+thinksmart1_arm64.deb"
    rm -rf "$R/tmp/bad" "$BP" "$R"/tmp/gstreamer1.0-plugins-bad*.deb
fi
if [ "$CAMERA" = 1 ]; then
    # after mesa-freedreno, like the web layer and the AirPlay runtime: it stands in for Debian's Mesa
    step "camera userspace (libcamera, libcamerasrc)"
    # shellcheck disable=SC2086
    in_chroot apt-get install -y -q --no-install-recommends $CAMERA_PACKAGES
fi
rm -f "$R"/tmp/*.deb
in_chroot apt-get -y -q dist-upgrade
umount "$R/var/cache/apt/archives"

# --- configuration files -------------------------------------------------------------------------------------------
step "configuration"
(cd "$FS" && find . -type f ! -name '*.in' | while read -r f; do install_file "$f" "$R/${f#./}"; done)
sed -e "s/@BOOT_UUID@/$BOOT_UUID/; s/@ROOT_UUID@/$ROOT_UUID/" "$FS/etc/fstab.in" > "$R/etc/fstab"
sed -e "s|@LAN_V4@|{ $LAN_V4 }|; s|@LAN_V6@|{ $LAN_V6 }|; s|@LAN_TCP_PORTS@|{ $(echo "$LAN_TCP_PORTS" | sed 's/[ ,]\{1,\}/, /g') }|g" "$FS/etc/nftables.conf.in" > "$R/etc/nftables.conf"
chmod 0755 "$R/etc/nftables.conf"
mkdir -p "$R/etc/nftables.d"
# no automatic mounts from the GPT of the disk (systemd-gpt-auto-generator): the disk is Android's, with dozens of
# partitions; a "home"/"srv" type GUID would end up in local-fs.target.requires (emergency mode if it fails)
mkdir -p "$R/etc/systemd/system-generators"
ln -sf /dev/null "$R/etc/systemd/system-generators/systemd-gpt-auto-generator"
[ -e "$R/usr/share/zoneinfo/$TIMEZONE" ] || { echo "unknown TIMEZONE $TIMEZONE" >&2; exit 1; }
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$R/etc/localtime"
echo "$TIMEZONE" > "$R/etc/timezone"
echo "$DEVICE_HOSTNAME" > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\nff02::1\t\tip6-allnodes\nff02::2\t\tip6-allrouters\n' \
    "$DEVICE_HOSTNAME" > "$R/etc/hosts"
[ -z "$WIFI_COUNTRY" ] || printf '# Wi-Fi regulatory domain (without it cfg80211 uses the restrictive "world" domain)\noptions cfg80211 ieee80211_regdom=%s\n' \
    "$WIFI_COUNTRY" > "$R/etc/modprobe.d/wifi-country.conf"
install -m 0444 "$C/machine-id" "$R/etc/machine-id"
mkdir -p "$R/var/lib/dbus"; ln -sf /etc/machine-id "$R/var/lib/dbus/machine-id"

# root: ssh with key only; password for the console, or locked
if [ -n "$ROOT_PASSWORD" ]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | in_chroot chpasswd
else
    in_chroot passwd -l root >/dev/null
fi
install -d -m 0700 "$R/root/.ssh"
install -m 0600 "$SSH_AUTHORIZED_KEYS_FILE" "$R/root/.ssh/authorized_keys"
# /var/lib/thinksmart/volume: speaker volume restored at boot by thinksmart-audio (applications may write it)
mkdir -p "$R/var/lib/thinksmart"

# ssh host keys: the same at every build
if ls "$C"/ssh/ssh_host_*_key >/dev/null 2>&1; then
    rm -f "$R"/etc/ssh/ssh_host_*
    cp -p "$C"/ssh/ssh_host_* "$R/etc/ssh/"
else
    mkdir -p "$C/ssh"; chmod 700 "$C/ssh"
    cp -p "$R"/etc/ssh/ssh_host_* "$C/ssh/"
fi

# Wi-Fi: NetworkManager profile (written from the environment, never on a command line or in a log)
WIFI_SSID=$WIFI_SSID WIFI_PSK=$WIFI_PSK WIFI_MAC=$WIFI_MAC python3 - "$R/etc/NetworkManager/system-connections/wifi.nmconnection" <<'PY'
import os, sys, uuid

def keyfile(s):
    # keyfile format (GKeyFile): \ doubled, leading space as \s
    s = s.replace("\\", "\\\\")
    return "\\s" + s[1:] if s.startswith(" ") else s

mac = os.environ.get("WIFI_MAC", "").strip()
text = f"""[connection]
id=wifi
uuid={uuid.uuid4()}
type=wifi
autoconnect=true
autoconnect-priority=100
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid={keyfile(os.environ["WIFI_SSID"])}
{"cloned-mac-address=" + mac if mac else ""}

[wifi-security]
key-mgmt=wpa-psk
psk={keyfile(os.environ["WIFI_PSK"])}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
"""
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, text.encode())
os.close(fd)
os.chmod(sys.argv[1], 0o600)
PY

# --- kernel, modules, firmware, UCM ---------------------------------------------------------------------------------
step "kernel $KVER, modules, firmware, UCM"
rm -rf "${R:?}/boot"; mkdir -p "$R/boot/extlinux"
tar -xf "$P/boot.tar" -C "$R/boot" --no-same-owner
sed -e "s/@BOOT_UUID@/$BOOT_UUID/; s/@ROOT_UUID@/$ROOT_UUID/" "$FS/boot/extlinux/extlinux.conf.in" > "$R/boot/extlinux/extlinux.conf"
for f in vmlinuz initramfs apq8053-lenovo-cd-18781y.dtb dtbs/qcom/apq8053-lenovo-cd-18781y.dtb; do
    [ -s "$R/boot/$f" ] || { echo "missing /boot/$f in boot.tar" >&2; exit 1; }
done
if [ "$CAMERA" = 1 ]; then
    # the camera DTB is the patched source of boot.tar's DTB: refuse a boot.tar whose DTB is not that source's
    want=$(awk -v f="$DTB" '$2 == f {print $1}' "$REPO/driver/s5kc505a/dtb.sha256")
    [ "$(sha256sum < "$R/boot/$DTB" | cut -d' ' -f1)" = "$want" ] || \
        { echo "/boot/$DTB of boot.tar is not the one the camera DTB was made from (driver/s5kc505a/dtb.sha256)" >&2; exit 1; }
    # next to the original, which stays as it is; lk2nd loads the file named by `fdt` (fdtdir would win over it)
    install -m 0644 "$P/$CAMERA_DTB" "$R/boot/$CAMERA_DTB"
    # extlinux.conf.nocamera: the file as a CAMERA=0 image has it (fdtdir, no cma=), to go back to the old DTB
    cp -p "$R/boot/extlinux/extlinux.conf" "$R/boot/extlinux/extlinux.conf.nocamera"
    sed -i -e "s|^\([[:space:]]*\)fdtdir /\$|\1fdt /$CAMERA_DTB|" \
        -e "s|^\([[:space:]]*append .*\)\$|\1 $CAMERA_CMA|" "$R/boot/extlinux/extlinux.conf"
    if ! grep -q "^[[:space:]]*fdt /$CAMERA_DTB\$" "$R/boot/extlinux/extlinux.conf" || \
       grep -q '^[[:space:]]*fdtdir' "$R/boot/extlinux/extlinux.conf"; then
        echo "extlinux.conf: could not replace fdtdir with fdt" >&2; exit 1
    fi
    [ "$(grep -c "^[[:space:]]*append .* $CAMERA_CMA\$" "$R/boot/extlinux/extlinux.conf")" = 1 ] || \
        { echo "extlinux.conf: could not add $CAMERA_CMA to the append line" >&2; exit 1; }
fi
rm -rf "$R/usr/lib/modules/$KVER"; mkdir -p "$R/usr/lib/modules"
tar -xf "$P/modules-$KVER.tar" -C "$R/usr/lib/modules" --no-same-owner
mkdir -p "$R/usr/lib/modules/$KVER/extra"
# only the production module: the -dbg one has the same aliases and would be loaded instead
rm -f "$R/usr/lib/modules/$KVER"/extra/*dbg*
install -m 0644 "$P/snd-soc-tas5782m.ko" "$R/usr/lib/modules/$KVER/extra/snd-soc-tas5782m.ko"
# light sensor (optional, driver/vcnl4000): without it thinksmart-light.service only logs that it is missing
if [ -s "$P/vcnl4000.ko" ]; then
    install -m 0644 "$P/vcnl4000.ko" "$R/usr/lib/modules/$KVER/extra/vcnl4000.ko"
else
    echo "NOTE: no $P/vcnl4000.ko: image without the light sensor (see driver/vcnl4000/README.md)"
fi
# video decoder (optional, driver/venus): the venus-core of the kernel package fails to start (-5) with our firmware
if [ -s "$P/venus-core.ko" ]; then
    install -m 0644 "$P/venus-core.ko" "$R/usr/lib/modules/$KVER/kernel/drivers/media/platform/qcom/venus/venus-core.ko"
else
    echo "NOTE: no $P/venus-core.ko: image without the hardware video decoder (see driver/venus/README.md)"
    [ "$AIRPLAY" = 0 ] || echo "NOTE: AIRPLAY=1 without venus-core.ko: screen mirroring has no hardware H.264 decoder"
fi
# front camera (CAMERA=1, driver/s5kc505a): udev loads it, i2c-qcom-cci and qcom-camss from the camera DTB
[ "$CAMERA" = 0 ] || install -m 0644 "$P/s5kc505a.ko" "$R/usr/lib/modules/$KVER/extra/s5kc505a.ko"
in_chroot ldconfig
in_chroot depmod -a "$KVER"
# BMA253 accelerometer (screen rotation): normally udev loads it from the device tree alias
if ! grep -q '^alias of:N\*T\*Cbosch,bma253 bmc150_accel_i2c$' "$R/usr/lib/modules/$KVER/modules.alias"; then
    echo "WARNING: no bosch,bma253 alias, bmc150_accel_i2c added to /etc/modules-load.d/thinksmart.conf"
    echo bmc150_accel_i2c > "$R/etc/modules-load.d/thinksmart.conf"
fi
mkdir -p "$R/usr/lib/firmware"
tar -xf "$P/firmware.tar" -C "$R/usr/lib/firmware" --no-same-owner
mkdir -p "$R/usr/lib/firmware/msm-firmware-loader"
tar -xf "$P/ucm.tar" -C "$R/usr/share/alsa/ucm2" --no-same-owner

# --- services ------------------------------------------------------------------------------------------------------
step "services"
in_chroot systemctl enable NetworkManager ssh systemd-timesyncd nftables avahi-daemon msm-firmware-loader \
    thinksmart-audio thinksmart-light
in_chroot systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
# mixer state is set by thinksmart-audio only: alsactl must not restore a saved volume (or 0) afterwards
in_chroot systemctl mask alsa-restore.service alsa-state.service

# --- customization (optional) --------------------------------------------------------------------------------------
# CUSTOMIZE is sourced here, with the chroot still mounted and the network available: it can use $R (the root of the
# image), in_chroot <command> (runs inside, arm64 through qemu), install_file SRC DEST, step "title", $C (cache
# directory) and every variable of config.env. Typical use: install an application, its venv and its services.
EXTRA=
if [ -n "$CUSTOMIZE" ]; then
    step "customization ($CUSTOMIZE)"
    # shellcheck disable=SC1090
    . "$CUSTOMIZE"
    EXTRA="customization: $(basename "$CUSTOMIZE")"
fi

# --- version and cleanup -------------------------------------------------------------------------------------------
step "version and cleanup"
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] || COMMIT="$COMMIT+changes"
cat > "$R/etc/thinksmart-version" <<EOF
thinksmart-view-debian, Debian image built on $(date '+%F %T')
repository: $COMMIT
Debian: $(cat "$R/etc/debian_version") arm64 (systemd $(in_chroot dpkg-query -W -f='${Version}' systemd))
kernel: $KVER (postmarketOS linux-postmarketos-qcom-msm8953, frozen), postmarketOS initramfs
Mesa: $(in_chroot dpkg-query -W -f='${Version}' mesa-freedreno) (mesa-freedreno, freedreno only, libglvnd vendor)
web layer: $([ "$WEB" = 1 ] && in_chroot dpkg-query -W -f='WPE WebKit ${Version}' libwpewebkit-2.0-1 || echo off)
AirPlay runtime: $([ "$AIRPLAY" = 1 ] && in_chroot dpkg-query -W -f='GStreamer ${Version}' libgstreamer1.0-0 || echo off)
${EXTRA:-customization: none}
UUID: boot $BOOT_UUID  root $ROOT_UUID
EOF
[ "$CAMERA" = 0 ] || echo "camera: s5kc505a, fdt /$CAMERA_DTB and $CAMERA_CMA (extlinux.conf.nocamera: without them), libcamera $(in_chroot dpkg-query -W -f='${Version}' libcamera0.4)" >> "$R/etc/thinksmart-version"
rm -f "$R/usr/sbin/policy-rc.d" "$R/etc/resolv.conf"
rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/*.bin "$R"/var/cache/apt/archives/*.deb
find "$R/var/log" -type f -exec truncate -s 0 {} +
rm -rf "$R"/root/.cache "$R"/root/.bash_history
unmount_all
# /tmp and /run were tmpfs during the build: they must stay empty in the image
mkdir -p "$R/tmp" "$R/run"; chmod 1777 "$R/tmp"

# --- image ---------------------------------------------------------------------------------------------------------
step "image ($SYSTEM_SECTORS sectors)"
NAME=thinksmart-debian-$TODAY.img
IMG=$OUT/$NAME
rm -f "$IMG"
truncate -s $((SYSTEM_SECTORS * 512)) "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SECTORS, type=ef, bootable
start=$P2_START, size=$((SYSTEM_SECTORS - P2_START)), type=83
EOF
LOOP1=$(loop_attach "$IMG" "$P1_START" "$P1_SECTORS")
LOOP2=$(loop_attach "$IMG" "$P2_START" $((SYSTEM_SECTORS - P2_START)))
# p1 like postmarketOS: ext2 with 1 KiB blocks, no extent/64bit/metadata_csum/journal (lk2nd reads it)
mkfs.ext2 -q -t ext2 -b 1024 -I 256 -L pmOS_boot -U "$BOOT_UUID" \
    -O ^64bit,^extent,^metadata_csum,^has_journal,^flex_bg,^huge_file,^dir_nlink,^extra_isize "$LOOP1"
# p2 like postmarketOS (no metadata_csum), otherwise Debian defaults
mkfs.ext4 -q -L pmOS_root -U "$ROOT_UUID" -O ^metadata_csum -E lazy_itable_init=0,lazy_journal_init=0 "$LOOP2"
mkdir -p "$M"
mount "$LOOP2" "$M"
mkdir -p "$M/boot"
mount "$LOOP1" "$M/boot"
cp -a "$R/boot/." "$M/boot/"
(cd "$R" && find . -mindepth 1 -maxdepth 1 ! -name boot -exec cp -a {} "$M/" \;)
sync
df -h "$M" "$M/boot" | sed 's/^/  /'
unmount_all

step "verify"
bash "$REPO/image/verify.sh" "$IMG" "$SYSTEM_SECTORS"

step "compressed copy"
pigz -c -6 "$IMG" > "$IMG.gz.tmp"
mv "$IMG.gz.tmp" "$IMG.gz"
# contains the Wi-Fi PSK, the root password hash and the ssh host keys: root only
chmod 0600 "$IMG" "$IMG.gz"
(cd "$OUT" && sha256sum "$NAME" "$NAME.gz" > "$NAME.sha256")
echo "image:  $IMG ($(du -h --apparent-size "$IMG" | cut -f1), $(du -h "$IMG" | cut -f1) on disk)"
echo "copy:   $IMG.gz ($(du -h "$IMG.gz" | cut -f1))"
echo "sha256: $OUT/$NAME.sha256"
