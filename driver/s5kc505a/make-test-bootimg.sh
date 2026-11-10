#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
#
# Build an Android boot image for a one-off `fastboot boot` from lk2nd: the device's own kernel, initramfs and kernel
# command line with a different DTB appended. Nothing is written to the device; a power cycle boots the installed
# system again. Used to try a new device tree (for example the camera one) before installing it.
#
# usage: make-test-bootimg.sh <dir with vmlinuz, initramfs, extlinux.conf from /boot> <dtb> <out.img>
# needs: mkbootimg (Debian package mkbootimg)
set -eu

if [ $# -ne 3 ]; then
	echo "usage: $0 <boot dir> <dtb> <out.img>" >&2
	exit 2
fi
boot=$1 dtb=$2 out=$3

for f in "$boot/vmlinuz" "$boot/initramfs" "$boot/extlinux.conf" "$dtb"; do
	[ -s "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# lk2nd reads one entry: the last "append" line wins, as in lk2nd's own parser.
cmdline=$(sed -n 's/^[[:space:]]*append[[:space:]]\{1,\}//p' "$boot/extlinux.conf" | tail -n 1)
[ -n "$cmdline" ] || { echo "no append line in $boot/extlinux.conf" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# gzip kernel + appended DTB: lk2nd finds the DTB after the gzip stream and checks qcom,msm-id/board-id.
cat "$boot/vmlinuz" "$dtb" > "$tmp/kernel-dtb"

# lk2nd on msm8953 ignores the load addresses in the header (ABOOT_IGNORE_BOOT_HEADER_ADDRS); these are the
# Lenovo boot image's anyway.
mkbootimg --header_version 0 --pagesize 2048 --base 0x80000000 --kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
	--kernel "$tmp/kernel-dtb" --ramdisk "$boot/initramfs" --cmdline "$cmdline" -o "$out"

echo "$out: $(wc -c < "$out") bytes"
