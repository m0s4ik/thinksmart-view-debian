#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Checks on a finished image without the device (root, on the build machine):
#   bash image/verify.sh <image> [sectors]        (run by build.sh before compressing)
# Opens the image read-only through loop devices and checks: size, MBR, p1 features (lk2nd), UUIDs in extlinux.conf
# and fstab, deviceinfo_no_framebuffer=true on the kernel command line (no 10 s wait for fb0 in the initramfs), the
# TAS5782M module in modules.dep, firmware, UCM, enabled services, users and keys, Wi-Fi profile, Python and the ALSA
# configuration (through qemu); the reduced Mesa (package, libglvnd vendor, no Debian Mesa or LLVM;
# EGL and GBM loaded through qemu) and the web layer when /etc/thinksmart-version says it is on. Front camera
# (CAMERA=1, found from extlinux.conf, the module or the camera DTB): `fdt` instead of `fdtdir`, `cma=` on the command
# line, the DTBs, the module, libcamera with its software ISP and libcamerasrc (loaded through qemu), no Debian Mesa
# pulled by them.
# Headless boot: dmsetup and the device-mapper udev rules, /boot nofail (fstab generator of the image), and a test
# device-mapper on p1 (read-only, removed at the end) run through `udevadm test` with the rules of the image and an
# empty udev database, as after switch_root from the postmarketOS initramfs.
# Prints no secrets (of the Wi-Fi profile it only checks that a PSK is present).
set -u
# Tools of the build machine (build.sh installs the packages): without them the checks below would fail one by one
# for the wrong reason, so stop first.
missing=
for t in sfdisk:fdisk tune2fs:e2fsprogs e2fsck:e2fsprogs dmsetup:dmsetup udevadm:udev systemctl:systemd nft:nftables; do
    command -v "${t%%:*}" >/dev/null 2>&1 || missing="$missing ${t%%:*} (package ${t#*:})"
done
[ -z "$missing" ] || { echo "verify.sh: missing on the build machine:$missing" >&2; exit 2; }
IMG=$1
SECTORS=${2:-14280671}
KVER=7.1.3-msm8953
SUMS=$(cd "$(dirname "$0")/.." && pwd)/driver/s5kc505a/dtb.sha256
V=$(mktemp -d /tmp/verify-image.XXXXXX)
ERR=0
LOOP1=
LOOP2=
DMN=verify-image-p1
LOOP_DM=

ok() { echo "  ok    $*"; }
no() { echo "  FAIL  $*"; ERR=$((ERR + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
cleanup() {
    for d in $(awk '{print $2}' /proc/mounts | grep -E "^$V(/|$)" | sort -r); do umount -l "$d" 2>/dev/null || true; done
    dmsetup remove "$DMN" 2>/dev/null || true
    [ -n "$LOOP_DM" ] && losetup -d "$LOOP_DM" 2>/dev/null || true
    for l in "$LOOP1" "$LOOP2"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null || true; done
    rmdir "$V" 2>/dev/null || true
}
trap cleanup EXIT
loop_attach() {  # loop_attach IMG START SIZE [losetup options]: one partition (in sectors) on its own loop device
    # No losetup -P: in a container (LXC, docker) /dev is not devtmpfs, so neither the loop node nor the partition
    # nodes appear by themselves; create the node if missing and attach the partition with an offset instead.
    local img=$1 start=$2 size=$3 dev
    shift 3
    dev=$(losetup -f | awk '{print $1}')
    [ -b "$dev" ] || mknod -m 0660 "$dev" b 7 "${dev#/dev/loop}"
    losetup "$@" -o $((start * 512)) --sizelimit $((size * 512)) "$dev" "$img" && echo "$dev"
}
inside() { chroot "$V" /usr/bin/env -i PATH=/usr/sbin:/usr/bin HOME=/tmp LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 "$@"; }
enabled() { systemctl --root="$V" is-enabled "$1" 2>/dev/null; }
dpkgq() { dpkg-query --admindir="$V/var/lib/dpkg" "$@" 2>/dev/null; }
installed() { dpkgq -W -f='${db:Status-Abbrev}' "$1" | grep -q '^ii'; }
# Debian's Mesa and LLVM: mesa-freedreno stands in for them, nothing may pull them
debian_mesa() {
    dpkgq -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" {print $2}' |
        grep -E '^(libllvm|libgl1-mesa-dri|mesa-libgallium|libegl-mesa0|libglx-mesa0|libgbm1|mesa-)' | grep -vx mesa-freedreno
}

echo "Verifying $IMG"
size=$(stat -c %s "$IMG")
[ "$size" = $((SECTORS * 512)) ] && ok "size $size bytes = $SECTORS sectors" || no "size $size, expected $((SECTORS * 512))"
sfdisk -d "$IMG" | grep -q "start=        2048, size=      497664, type=ef, bootable" && ok "MBR: p1 2048+497664 ef bootable" || no "MBR: p1"
sfdisk -d "$IMG" | grep -q "start=      499712, size= *$((SECTORS - 499712)), type=83" && ok "MBR: p2 from 499712 to the end" || no "MBR: p2"

LOOP1=$(loop_attach "$IMG" 2048 497664 -r)
LOOP2=$(loop_attach "$IMG" 499712 $((SECTORS - 499712)) -r)
feat=$(tune2fs -l "$LOOP1" | sed -n 's/^Filesystem features: *//p')
echo "  p1 features: $feat (block $(tune2fs -l "$LOOP1" | sed -n 's/^Block size: *//p'))"
bad=
for f in extent 64bit metadata_csum has_journal flex_bg huge_file orphan_file; do
    echo " $feat " | grep -q " $f " && bad="$bad $f"
done
[ -z "$bad" ] && ok "p1 ext2 without newer features (like postmarketOS)" || no "p1 with features:$bad"
echo "  p2 features: $(tune2fs -l "$LOOP2" | sed -n 's/^Filesystem features: *//p')"
U1=$(blkid -s UUID -o value "$LOOP1"); U2=$(blkid -s UUID -o value "$LOOP2")
[ "$(blkid -s TYPE -o value "$LOOP1")" = ext2 ] && ok "p1 ext2 ($U1, $(blkid -s LABEL -o value "$LOOP1"))" || no "p1 is not ext2"
[ "$(blkid -s TYPE -o value "$LOOP2")" = ext4 ] && ok "p2 ext4 ($U2, $(blkid -s LABEL -o value "$LOOP2"))" || no "p2 is not ext4"
e2fsck -fn "$LOOP1" >/dev/null 2>&1 && ok "e2fsck p1" || no "e2fsck p1"
e2fsck -fn "$LOOP2" >/dev/null 2>&1 && ok "e2fsck p2" || no "e2fsck p2"

mount -o ro "$LOOP2" "$V"
mount -o ro "$LOOP1" "$V/boot"

echo "-- boot"
E=$V/boot/extlinux/extlinux.conf
grep -q "pmos_boot_uuid=$U1 " "$E" && ok "extlinux.conf: pmos_boot_uuid = UUID of p1" || no "extlinux.conf: pmos_boot_uuid"
grep -q "pmos_root_uuid=$U2 " "$E" && ok "extlinux.conf: pmos_root_uuid = UUID of p2" || no "extlinux.conf: pmos_root_uuid"
[ "$(grep -c '^label' "$E")" = 1 ] && ok "extlinux.conf: a single entry (lk2nd)" || no "extlinux.conf: several entries"
grep -q "consoleblank=0 vt.global_cursor_default=0" "$E" && ok "extlinux.conf: consoleblank=0 vt.global_cursor_default=0" || no "extlinux.conf: console options"
grep -q "quiet loglevel=0 systemd.show_status=0 " "$E" && ok "extlinux.conf: quiet loglevel=0 systemd.show_status=0 (no text on the screen while booting)" || no "extlinux.conf: loglevel/show_status"
NO_FB_WAIT=deviceinfo_no_framebuffer=true   # as in build.sh: the initramfs skips its 10 s wait for /dev/fb0
no_fb_wait() {  # exactly one deviceinfo_no_framebuffer=, =true, on the append line
    [ "$(grep -Ec "^[[:space:]]*append .* $NO_FB_WAIT( |\$)" "$1")" = 1 ] && [ "$(grep -o ' deviceinfo_no_framebuffer=[^ ]*' "$1" | wc -l)" = 1 ]
}
no_fb_wait "$E" && ok "extlinux.conf: $NO_FB_WAIT once on the kernel command line (no 10 s wait for /dev/fb0)" \
    || no "extlinux.conf: not exactly one deviceinfo_no_framebuffer=, expected $NO_FB_WAIT on the append line"
grep -q "^UUID=${U2}[[:space:]]*/[[:space:]]" "$V/etc/fstab" && grep -q "^UUID=${U1}[[:space:]]*/boot[[:space:]]" "$V/etc/fstab" \
    && ok "fstab with the same UUIDs" || no "fstab"
grep -q "^UUID=${U1}[[:space:]]*/boot[[:space:]].*nofail,x-systemd.device-timeout=90[[:space:]]" "$V/etc/fstab" \
    && ok "fstab: /boot with nofail,x-systemd.device-timeout=90" || no "fstab: /boot without nofail/device-timeout=90"
for f in /usr/lib/udev/rules.d/55-dm.rules /usr/lib/udev/rules.d/60-persistent-storage-dm.rules /etc/udev/rules.d/54-dm-initramfs.rules; do
    check "udev: $f" test -s "$V$f"
done
dms=$(grep -ho '/[a-z/]*sbin/dmsetup' "$V/usr/lib/udev/rules.d/55-dm.rules" 2>/dev/null | sort -u)
[ -n "$dms" ] || no "55-dm.rules without the path of dmsetup"
for p in $dms; do check "dmsetup in $p (called by the udev rules)" test -x "$V$p"; done
check "54-dm-initramfs.rules valid (udevadm verify)" udevadm verify --resolve-names=never "$V/etc/udev/rules.d/54-dm-initramfs.rules"
[ "$(readlink "$V/etc/systemd/system-generators/systemd-gpt-auto-generator")" = /dev/null ] \
    && ok "systemd-gpt-auto-generator disabled" || no "systemd-gpt-auto-generator active"
if grep -lE '^(Requires|BindsTo|Requisite|RequiresMountsFor)=.*(local-fs\.target|boot\.mount|/boot)' "$V"/etc/systemd/system/*.service >/dev/null 2>&1; then
    no "one of our units requires local-fs.target or /boot"
else
    ok "none of our units requires local-fs.target or /boot"
fi
for f in vmlinuz initramfs apq8053-lenovo-cd-18781y.dtb dtbs/qcom/apq8053-lenovo-cd-18781y.dtb config; do
    check "/boot/$f" test -s "$V/boot/$f"
done
cmp -s "$V/boot/apq8053-lenovo-cd-18781y.dtb" "$V/boot/dtbs/qcom/apq8053-lenovo-cd-18781y.dtb" && ok "the two DTBs are identical" || no "DTBs differ"
check "/sbin/init -> systemd" test "$(readlink -f "$V/sbin/init" | sed "s|^$V||")" = /usr/lib/systemd/systemd
check "/etc/os-release (required by the initramfs)" test -e "$V/usr/lib/os-release" -a -L "$V/etc/os-release"

echo "-- device-mapper of /boot as created by the initramfs (kpartx), coldplug without udev database"
# on a separate loop with only the bytes of p1: the image loop has its partitions mounted
LOOP_DM=$(loop_attach "$IMG" 2048 497664 -r)
if dmsetup create --readonly "$DMN" --table "0 497664 linear $LOOP_DM 0"; then
    udevadm settle 2>/dev/null || true
    D=$(dmsetup info --noheadings -c -o blkdevname "$DMN")
    # in a container nothing creates /dev/dm-N, and udev's blkid needs it: make the node for the test
    DM_NODE=
    if [ ! -b "/dev/$D" ]; then
        mknod -m 0600 "/dev/$D" b "$(dmsetup info --noheadings -c -o major "$DMN")" \
            "$(dmsetup info --noheadings -c -o minor "$DMN")" && DM_NODE=/dev/$D
    fi
    # udevadm test in a mount namespace: rules of the image, empty /run/udev (database and runtime rules; in a
    # container without udev /run/udev does not exist yet)
    test_dm() {
        unshare -m sh -c 'mkdir -p /run/udev && mount -t tmpfs tmpfs /run/udev && mount --bind "$1/usr/lib/udev/rules.d" /usr/lib/udev/rules.d \
            && mount --bind "$2" /etc/udev/rules.d && udevadm test --action=add "/sys/class/block/$3"' sh "$V" "$1" "$D" 2>/dev/null | sed 's/^ *//'
    }
    out=$(test_dm "$V/etc/udev/rules.d")
    if ! dd if="/dev/$D" of=/dev/null bs=512 count=1 status=none 2>/dev/null; then
        # e.g. an LXC container whose device cgroup allows loop but not device-mapper (major 252) devices
        echo "  --    add without database: SKIPPED, /dev/$D cannot be opened here (container?), udev's blkid needs it"
    elif echo "$out" | grep -q "^DEVLINKS=.*/dev/disk/by-uuid/$U1" && ! echo "$out" | grep -q '^SYSTEMD_READY=0'; then
        ok "add without database: /dev/disk/by-uuid/$U1 and device ready for systemd"
    else
        no "add without database: no by-uuid or SYSTEMD_READY=0 (/boot would not mount)"
        echo "$out" | grep -E '^(DEVLINKS|SYSTEMD_READY|DM_)' | sed 's/^/        /'
    fi
    empty=$(mktemp -d)
    if test_dm "$empty" | grep -q '^SYSTEMD_READY=0'; then
        echo "  --    without 54-dm-initramfs.rules: SYSTEMD_READY=0 and no by-uuid (the cause of the emergency mode)"
    else
        echo "  --    without 54-dm-initramfs.rules the device would be ready anyway (dm rules changed?)"
    fi
    rmdir "$empty"
    [ -n "$DM_NODE" ] && rm -f "$DM_NODE"
    dmsetup remove "$DMN" 2>/dev/null || true
    losetup -d "$LOOP_DM" 2>/dev/null || true; LOOP_DM=
else
    no "dmsetup create of the test device"
fi

echo "-- modules, firmware, UCM"
MD=$V/usr/lib/modules/$KVER
grep -q '^extra/snd-soc-tas5782m.ko:' "$MD/modules.dep" && ok "modules.dep: extra/snd-soc-tas5782m.ko" || no "modules.dep without tas5782m"
grep -q 'tas5782m' "$MD/modules.alias" && ok "modules.alias: tas5782m" || no "modules.alias without tas5782m"
grep -aq 'parm=volume_mode:' "$MD/extra/snd-soc-tas5782m.ko" && ok "tas5782m with hardware volume" || no "tas5782m is the old driver (no hardware volume)"
[ -z "$(find "$MD/extra" -name "*dbg*")" ] && ok "no -dbg module" || no "-dbg module present"
grep -q '^kernel/drivers/net/wireless/ath/ath10k/ath10k_sdio.ko' "$MD/modules.dep" && ok "modules.dep: ath10k_sdio" || no "ath10k_sdio"
for m in bmc150-accel-i2c bmc150-accel-core; do
    grep -q "^kernel/drivers/iio/accel/$m.ko:" "$MD/modules.dep" && ok "modules.dep: $m" || no "modules.dep without $m"
done
if grep -q '^alias of:N\*T\*Cbosch,bma253 bmc150_accel_i2c$' "$MD/modules.alias"; then
    ok "modules.alias: bosch,bma253 -> bmc150_accel_i2c"
elif grep -q '^bmc150_accel_i2c$' "$V/etc/modules-load.d/thinksmart.conf" 2>/dev/null; then
    ok "bmc150_accel_i2c without alias, but in /etc/modules-load.d/thinksmart.conf"
else
    no "bmc150_accel_i2c: neither alias nor modules-load.d"
fi
grep -aq 'bosch,bma253' "$V/boot/apq8053-lenovo-cd-18781y.dtb" && ok "DTB: bosch,bma253 node" || no "DTB without bosch,bma253"
echo "  modules: $(find "$MD" -name '*.ko' | wc -l) .ko files"
F=$V/usr/lib/firmware
for f in ath10k/QCA9379/hw1.0/firmware-sdio-6.bin ath10k/QCA9379/hw1.0/board-2.bin qcom/a530_pm4.fw qcom/a530_pfp.fw \
         qcom/msm8953/lenovo/cd-18781y/a506_zap.mdt tas5728m_dsp_lenovo_cd-18781y.bin regulatory.db; do
    check "firmware $f" test -s "$F/$f"
done
check "directory for msm-firmware-loader" test -d "$F/msm-firmware-loader"
check "msm-firmware-loader.sh" test -x "$V/usr/local/sbin/msm-firmware-loader.sh"
for f in conf.d/cd-18781y/cd-18781y.conf Lenovo/cd-18781y/HiFi.conf lib/card-init.conf lib/ctl-remap.conf; do
    check "UCM $f" test -s "$V/usr/share/alsa/ucm2/$f"
done
check "softvol speaker in /etc/asound.conf" grep -q 'Master Playback Volume' "$V/etc/asound.conf"

echo "-- front camera"
CAMERA_DTB=apq8053-lenovo-cd-18781y-camera.dtb
CAMERA_CMA=cma=128M     # as in build.sh: libcamera's full-size buffers do not fit in the default 32 MB
pinned() { awk -v f="$1" '$2 == f {print $1}' "$SUMS" 2>/dev/null; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
if grep -Eq '^[[:space:]]*fdt[[:space:]]' "$E" || [ -e "$MD/extra/s5kc505a.ko" ] || [ -e "$V/boot/$CAMERA_DTB" ]; then
    # lk2nd: one entry, fdtdir wins over fdt, a missing fdt file means no boot
    grep -Eq '^[[:space:]]*fdtdir([[:space:]]|$)' "$E" && no "extlinux.conf: fdtdir present (lk2nd takes it over fdt)" \
        || ok "extlinux.conf: no fdtdir"
    fdt=$(sed -n 's/^[[:space:]]*fdt[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$E")
    if [ "$(echo "$fdt" | grep -c .)" != 1 ]; then
        no "extlinux.conf: not exactly one fdt line"
    elif [ "$fdt" != "/$CAMERA_DTB" ]; then
        no "extlinux.conf: fdt $fdt, expected /$CAMERA_DTB"
    else
        ok "extlinux.conf: fdt $fdt"
    fi
    [ "$(grep -Ec "^[[:space:]]*append .* $CAMERA_CMA( |\$)" "$E")" = 1 ] && [ "$(grep -o ' cma=[^ ]*' "$E" | wc -l)" = 1 ] \
        && ok "extlinux.conf: $CAMERA_CMA on the kernel command line (libcamera at full size)" || no "extlinux.conf: not exactly one cma=, expected $CAMERA_CMA"
    # build.sh appends cma= to the template's append line, which ends with NO_FB_WAIT (the kernel does not mind the order)
    grep -Eq "^[[:space:]]*append .* $NO_FB_WAIT $CAMERA_CMA\$" "$E" && ok "extlinux.conf: append line ends with $NO_FB_WAIT $CAMERA_CMA" \
        || no "extlinux.conf: append line does not end with $NO_FB_WAIT $CAMERA_CMA"
    if [ -n "$fdt" ] && [ -s "$V/boot/${fdt#/}" ]; then ok "/boot${fdt}: the DTB named by fdt exists"; else no "/boot${fdt}: missing (Linux would not boot)"; fi
    check "original DTB /boot/apq8053-lenovo-cd-18781y.dtb still present" test -s "$V/boot/apq8053-lenovo-cd-18781y.dtb"
    [ -n "$(pinned "$CAMERA_DTB")" ] || no "no pinned sums in $SUMS"
    [ -s "$V/boot/$CAMERA_DTB" ] && [ "$(sha "$V/boot/$CAMERA_DTB")" = "$(pinned "$CAMERA_DTB")" ] \
        && ok "camera DTB = driver/s5kc505a/dtb.sha256" || no "camera DTB differs from driver/s5kc505a/dtb.sha256"
    [ "$(sha "$V/boot/apq8053-lenovo-cd-18781y.dtb")" = "$(pinned apq8053-lenovo-cd-18781y.dtb)" ] \
        && ok "original DTB = the source the camera DTB was patched from" || no "original DTB is not the one in driver/s5kc505a/dtb.sha256"
    grep -aq 'samsung,s5kc505a' "$V/boot/$CAMERA_DTB" 2>/dev/null && ok "camera DTB: samsung,s5kc505a node" || no "camera DTB without samsung,s5kc505a"
    NC=$V/boot/extlinux/extlinux.conf.nocamera
    if [ -e "$NC" ]; then
        [ "$(grep -c '^label' "$NC")" = 1 ] && grep -Eq '^[[:space:]]*fdtdir /$' "$NC" && ! grep -Eq '^[[:space:]]*fdt[[:space:]]' "$NC" && ! grep -q ' cma=' "$NC" \
            && ok "extlinux.conf.nocamera: one entry with fdtdir /, no cma= (to go back)" || no "extlinux.conf.nocamera"
        no_fb_wait "$NC" && ok "extlinux.conf.nocamera: $NO_FB_WAIT once on the kernel command line" \
            || no "extlinux.conf.nocamera: not exactly one deviceinfo_no_framebuffer=, expected $NO_FB_WAIT"
    fi
    vm=$(grep -ao 'vermagic=[^[:cntrl:]]*' "$MD/extra/s5kc505a.ko" 2>/dev/null)
    [ "$vm" = "vermagic=$KVER SMP preempt mod_unload aarch64" ] && ok "s5kc505a.ko: $vm" || no "s5kc505a.ko: vermagic '${vm#vermagic=}', expected $KVER"
    grep -q '^extra/s5kc505a.ko:' "$MD/modules.dep" && ok "modules.dep: extra/s5kc505a.ko" || no "modules.dep without s5kc505a"
    grep -q 'samsung,s5kc505a' "$MD/modules.alias" && ok "modules.alias: samsung,s5kc505a" || no "modules.alias without s5kc505a"
    for p in v4l-utils libcamera0.4 libcamera-ipa gstreamer1.0-libcamera gstreamer1.0-tools; do
        if installed $p; then ok "$p $(dpkgq -W -f='${Version}' $p)"; else no "$p not installed"; fi
    done
    # the simple pipeline handler's software ISP (qcom-camss has no ISP of its own); the .sign is checked when loaded
    for f in libcamera/ipa_soft_simple.so libcamera/ipa_soft_simple.so.sign gstreamer-1.0/libgstlibcamera.so; do
        check "/usr/lib/aarch64-linux-gnu/$f" test -s "$V/usr/lib/aarch64-linux-gnu/$f"
    done
    check "soft_ipa_proxy" test -x "$V/usr/libexec/aarch64-linux-gnu/libcamera/soft_ipa_proxy"
    m=$(debian_mesa)
    [ -z "$m" ] && ok "camera userspace without Debian Mesa" || no "Debian Mesa installed with the camera userspace: $m"
    CAMERA=1
else
    CAMERA=0
    grep -Eq '^[[:space:]]*fdtdir /$' "$E" && ok "camera off: extlinux.conf with fdtdir / (the kernel package's DTB)" \
        || no "extlinux.conf without fdtdir / and without fdt"
    ! grep -q ' cma=' "$E" && ok "camera off: no cma= on the kernel command line" || no "camera off but cma= in extlinux.conf"
fi

echo "-- GPU: reduced Mesa"
ML=$V/usr/lib/aarch64-linux-gnu
if installed mesa-freedreno; then ok "mesa-freedreno $(dpkgq -W -f='${Version}' mesa-freedreno) installed"; else no "mesa-freedreno not installed"; fi
for f in libEGL_mesa.so.0 libgbm.so.1 gbm/dri_gbm.so; do
    check "/usr/lib/aarch64-linux-gnu/$f" test -s "$ML/$f"
done
check "libglvnd vendor: /usr/share/glvnd/egl_vendor.d/50_mesa.json -> libEGL_mesa.so.0" \
    grep -q '"libEGL_mesa.so.0"' "$V/usr/share/glvnd/egl_vendor.d/50_mesa.json"
for p in libglvnd0 libegl1 libgles2; do
    if installed $p; then ok "$p (libglvnd) $(dpkgq -W -f='${Version}' $p)"; else no "$p not installed"; fi
done
prov=$(dpkgq -W -f='${Provides}' mesa-freedreno)
for p in libgbm1 libegl-mesa0 libglx-mesa0; do
    echo "$prov" | grep -qw "$p" && ok "$p provided by mesa-freedreno" || no "$p not provided by mesa-freedreno"
done
grep -aq "/usr/lib/aarch64-linux-gnu/gbm" "$ML/libgbm.so.1" && ok "libgbm looks for its backend in /usr/lib/aarch64-linux-gnu/gbm" \
    || no "libgbm built for another path (its backend would not be found)"
debmesa=$(debian_mesa)
llvm=$(find "$V/usr/lib" -name "libLLVM*" 2>/dev/null | head -n1)
[ -z "$debmesa$llvm" ] && ok "no Debian Mesa or LLVM" || no "Debian Mesa or LLVM installed: $debmesa $llvm"
[ ! -e "$V/opt/mesa-freedreno" ] && [ ! -e "$V/etc/ld.so.conf.d/mesa-freedreno.conf" ] && ok "no Mesa left in /opt" || no "old Mesa in /opt/mesa-freedreno"

echo "-- web layer"
if grep -q '^web layer: WPE' "$V/etc/thinksmart-version"; then
    WEB=1
    for p in libwpewebkit-2.0-1 bubblewrap xdg-dbus-proxy libgl1; do
        if installed $p; then ok "$p $(dpkgq -W -f='${Version}' $p)"; else no "$p not installed"; fi
    done
    case "$(dpkgq -W -f='${Version}' libwpewebkit-2.0-1)" in
        2.5[4-9]*|2.[6-9]*) ok "WPE WebKit 2.54 or newer (2.48 cannot use Mesa 26)" ;;
        *) no "WPE WebKit older than 2.54" ;;
    esac
    check "bwrap" test -x "$V/usr/bin/bwrap"
    grep -q '^CONFIG_USER_NS=y' "$V/boot/config" && ok "kernel with user namespaces (WebKit's bubblewrap sandbox)" || no "kernel without CONFIG_USER_NS"
else
    WEB=0
    pkgs=$(dpkgq -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" {print $2}' | grep -E '^(libwpewebkit|bubblewrap$)')
    [ -z "$pkgs" ] && ok "web layer off: no WPE WebKit or bubblewrap" || no "web layer off but installed: $pkgs"
fi

echo "-- AirPlay runtime"
if grep -q '^AirPlay runtime: GStreamer' "$V/etc/thinksmart-version"; then
    AIRPLAY=1
    for p in gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav libgstreamer-plugins-bad1.0-0 \
             gstreamer1.0-plugins-bad-airplay libplist-2.0-4 libavahi-compat-libdnssd1; do
        if installed $p; then ok "$p $(dpkgq -W -f='${Version}' $p)"; else no "$p not installed"; fi
    done
    # the elements UxPlay's pipelines use: appsrc, h264parse, unixfdsink, v4l2h264dec (venus), capssetter,
    # avdec_aac/avdec_alac, audioconvert, audioresample, fdsink
    for f in libgstapp.so libgstvideoparsersbad.so libgstunixfd.so libgstvideo4linux2.so libgstdebug.so libgstlibav.so \
             libgstaudioconvert.so libgstaudioresample.so libgstcoreelements.so; do
        check "GStreamer plugin $f" test -e "$V/usr/lib/aarch64-linux-gnu/gstreamer-1.0/$f"
    done
    ! installed gstreamer1.0-plugins-bad && ok "not the whole gstreamer1.0-plugins-bad (GTK, onnxruntime, ...)" \
        || no "gstreamer1.0-plugins-bad installed"
else
    AIRPLAY=0
    if [ "$WEB" = 0 ] && [ "$CAMERA" = 0 ]; then
        pkgs=$(dpkgq -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" {print $2}' | grep -E '^libgstreamer')
        [ -z "$pkgs" ] && ok "web layer, AirPlay runtime and camera off: no GStreamer" || no "GStreamer installed: $pkgs"
    fi
fi

echo "-- services"
for s in NetworkManager ssh systemd-timesyncd nftables avahi-daemon msm-firmware-loader thinksmart-audio thinksmart-light; do
    st=$(enabled "$s"); [ "$st" = enabled ] && ok "$s: $st" || no "$s: $st"
done
for s in alsa-restore alsa-state; do
    st=$(enabled "$s"); [ "$st" = masked ] && ok "$s: $st" || no "$s: $st (should be masked)"
done
echo "  NetworkManager-wait-online: $(enabled NetworkManager-wait-online)"
echo "  getty@tty1: $(enabled getty@tty1) (login on the screen)"

echo "-- system"
echo "  hostname $(cat "$V/etc/hostname")"
grep -q "^127.0.1.1[[:space:]]*$(cat "$V/etc/hostname")\$" "$V/etc/hosts" && ok "/etc/hosts" || no "/etc/hosts"
grep -Eq '^[0-9a-f]{32}$' "$V/etc/machine-id" && ok "machine-id" || no "machine-id"
echo "  time zone $(readlink "$V/etc/localtime")"
grep -q '^ssh-' "$V/root/.ssh/authorized_keys" && [ "$(stat -c %a "$V/root/.ssh/authorized_keys")" = 600 ] \
    && ok "root authorized_keys ($(grep -c '^ssh-' "$V/root/.ssh/authorized_keys") keys)" || no "authorized_keys"
awk -F: '$1=="root"{exit !($2 ~ /^(\$|!)/)}' "$V/etc/shadow" && ok "root password set or locked" || no "root without password"
grep -q '^PasswordAuthentication no' "$V/etc/ssh/sshd_config.d/thinksmart.conf" && ok "ssh without passwords" || no "sshd"
check "ssh host keys" test -s "$V/etc/ssh/ssh_host_ed25519_key"
WP=$V/etc/NetworkManager/system-connections/wifi.nmconnection
[ "$(stat -c '%a %U' "$WP")" = "600 root" ] && ok "Wi-Fi profile 0600 root" || no "permissions of the Wi-Fi profile"
grep -q '^ssid=.' "$WP" && grep -q '^psk=.' "$WP" && grep -q '^autoconnect-retries=0$' "$WP" \
    && ok "Wi-Fi profile: SSID and PSK present, infinite retries$(grep -q '^cloned-mac-address=' "$WP" && echo ', fixed MAC')" || no "Wi-Fi profile"
grep -q '^wifi.scan-rand-mac-address=no' "$V/etc/NetworkManager/conf.d/thinksmart.conf" && ok "scans without random MAC" || no "NM conf"
grep -q '^Storage=persistent' "$V/etc/systemd/journald.conf.d/thinksmart.conf" && ok "journal on disk" || no "journald"
nft -c -f "$V/etc/nftables.conf" >/dev/null 2>&1 && ok "nftables.conf valid (nft -c)" || no "nftables.conf"
grep -q '^[[:space:]]*include "/etc/nftables.d/\*.nft"' "$V/etc/nftables.conf" && test -d "$V/etc/nftables.d" \
    && ok "nftables.d: applications' rules included" || no "nftables.d"
check "/etc/thinksmart-version" test -s "$V/etc/thinksmart-version"
grep -q "^VOLUME=" "$V/etc/default/thinksmart-audio" && ok "/etc/default/thinksmart-audio" || no "/etc/default/thinksmart-audio"
check "thinksmart-audio script" test -x "$V/usr/local/sbin/thinksmart-audio"
check "thinksmart-light script" test -x "$V/usr/local/sbin/thinksmart-light"
if [ -e "$MD/extra/vcnl4000.ko" ]; then
    grep -q '^extra/vcnl4000.ko:' "$MD/modules.dep" && ok "modules.dep: extra/vcnl4000.ko (light sensor)" || no "vcnl4000.ko not in modules.dep"
else
    echo "  skip  no vcnl4000.ko: image without the light sensor (optional)"
fi
echo "  used: root $(du -sh --exclude=boot "$V" 2>/dev/null | cut -f1), /boot $(du -sh "$V/boot" | cut -f1); $(dpkgq -W -f='${db:Status-Abbrev}\n' | grep -c '^ii') packages"

echo "-- inside the image (arm64 through qemu)"
mount -t proc proc "$V/proc"
mount -t tmpfs tmpfs "$V/tmp"
mount --bind /dev "$V/dev"
mount -t sysfs sys "$V/sys"     # without /sys the fstab generator believes it runs in a container
# fstab generator of the image: /boot must not end up in local-fs.target.requires (that would be emergency mode)
G=$V/tmp/gen; mkdir -p "$G"
inside SYSTEMD_PROC_CMDLINE= SYSTEMD_IN_INITRD=0 /usr/lib/systemd/system-generators/systemd-fstab-generator /tmp/gen /tmp/gen /tmp/gen >/dev/null 2>&1
[ -e "$G/local-fs.target.wants/boot.mount" ] && [ ! -e "$G/local-fs.target.requires/boot.mount" ] \
    && ok "fstab generator: boot.mount only wanted by local-fs.target (nofail)" || no "fstab generator: boot.mount"
[ "$(ls "$G/local-fs.target.requires" 2>/dev/null | tr '\n' ' ')" = "-.mount " ] \
    && ok "fstab generator: local-fs.target requires only -.mount" || no "fstab generator: local-fs.target.requires = $(ls "$G/local-fs.target.requires" 2>/dev/null | tr '\n' ' ')"
grep -qs '^JobRunningTimeoutSec=90$' "$G"/*.device.d/50-device-timeout.conf && ok "fstab generator: 90 s wait for the /boot device" || no "fstab generator: device-timeout"
inside /usr/bin/python3 -c "import venv, ssl, sqlite3" 2>/dev/null && ok "python3 with venv (for applications)" || no "python3"
inside /usr/bin/aplay -L > "$V/tmp/pcm.txt" 2>&1; grep -q '^speaker$' "$V/tmp/pcm.txt" && grep -q '^default$' "$V/tmp/pcm.txt" \
    && ok "ALSA pcms speaker and default (asound.conf parsed)" || { no "ALSA pcms"; head -5 "$V/tmp/pcm.txt"; }

# EGL through libglvnd: the client extensions come from the vendors it found, so Mesa's must be among them
cat > "$V/tmp/egl.py" <<'EOF'
import ctypes
egl = ctypes.CDLL("libEGL.so.1")
egl.eglQueryString.restype = ctypes.c_char_p
egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_int]
print((egl.eglQueryString(None, 0x3055) or b"").decode())  # EGL_EXTENSIONS of EGL_NO_DISPLAY
ctypes.CDLL("libGLESv2.so.2")
ctypes.CDLL("libgbm.so.1")
ctypes.CDLL("/usr/lib/aarch64-linux-gnu/gbm/dri_gbm.so")
print("gbm ok")
EOF
out=$(inside /usr/bin/python3 /tmp/egl.py 2>&1)
if echo "$out" | grep -q 'EGL_MESA_platform_gbm' && echo "$out" | grep -Eq 'EGL_(KHR|EXT)_platform_wayland'; then
    ok "EGL loads Mesa through libglvnd (platforms gbm and wayland)"
else
    no "EGL: Mesa vendor not loaded"; echo "$out" | head -3 | sed 's/^/        /'
fi
echo "$out" | grep -q '^gbm ok$' && ok "GLESv2, GBM and its backend dri_gbm.so load" || no "GBM or GLESv2 do not load"
libs="libEGL.so.1 libGLESv2.so.2 libEGL_mesa.so.0 libgbm.so.1 gbm/dri_gbm.so"
[ "$WEB" = 1 ] && libs="$libs libWPEWebKit-2.0.so.1 wpe-webkit-2.0/WPEWebProcess wpe-webkit-2.0/WPENetworkProcess libgstgl-1.0.so.0"
[ "$CAMERA" = 1 ] && libs="$libs libcamera.so.0.4 libcamera/ipa_soft_simple.so gstreamer-1.0/libgstlibcamera.so"
[ "$AIRPLAY" = 1 ] && libs="$libs libplist-2.0.so.4 libdns_sd.so.1 gstreamer-1.0/libgstvideo4linux2.so gstreamer-1.0/libgstvideoparsersbad.so gstreamer-1.0/libgstunixfd.so gstreamer-1.0/libgstlibav.so"
for f in $libs; do
    nf=$(inside /usr/bin/ldd "/usr/lib/aarch64-linux-gnu/$f" 2>&1 | grep -E 'not found|No such file|not a dynamic')
    [ -z "$nf" ] && ok "ldd $f: every library found" || no "ldd $f: $nf"
done
if [ "$CAMERA" = 1 ]; then
    # registers GStreamer's libcamera plugin and creates the element (no camera is opened before it starts)
    out=$(inside GST_REGISTRY=/tmp/gst-registry.bin /usr/bin/gst-inspect-1.0 libcamerasrc 2>&1)
    echo "$out" | grep -q 'libgstlibcamera.so' && ok "gst-inspect-1.0 libcamerasrc: element loads" \
        || { no "gst-inspect-1.0 libcamerasrc"; echo "$out" | head -3 | sed 's/^/        /'; }
fi

echo
sed 's/^/  /' "$V/etc/thinksmart-version"
echo
if [ $ERR = 0 ]; then echo "VERIFY OK"; else echo "VERIFY: $ERR checks failed"; fi
exit $ERR
