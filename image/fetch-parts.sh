#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Copies the device files needed by build.sh from a ThinkSmart View running postmarketOS with the kernel package
# linux-postmarketos-qcom-msm8953 7.1.3 (e.g. rickx's bootstrap after `apk upgrade`, see docs/kernel.md):
#   ./image/fetch-parts.sh user@device [parts-dir]          (parts-dir: image/parts)
# Produces boot.tar (vmlinuz, initramfs, config, System.map, flat DTBs and dtbs/), modules-7.1.3-msm8953.tar,
# firmware.tar (/lib/firmware without the msm-firmware-loader mount), ucm.tar (ThinkSmart UCM profile) and
# parts.sha256. snd-soc-tas5782m.ko is built separately (driver/tas5782m/README.md) and copied there by hand.
# Only reads from the device (busybox tar over ssh). These files are not redistributable as part of this repository.
set -euo pipefail
DEV=${1:?usage: $0 user@device [parts-dir]}
OUT=${2:-$(dirname "$0")/parts}
KVER=7.1.3-msm8953
mkdir -p "$OUT"

ssh "$DEV" "test -d /usr/lib/modules/$KVER" || { echo "the device does not have /usr/lib/modules/$KVER" >&2; exit 1; }
# name | tar command on the device
PARTS=(
  "boot.tar|cd /boot && tar -cf - vmlinuz initramfs config System.map dtbs \$(ls *.dtb)"
  "modules-$KVER.tar|tar -C /usr/lib/modules -cf - --exclude='*-dbg*' $KVER"
  "firmware.tar|cd /lib/firmware && tar -cf - \$(ls | grep -v '^msm-firmware-loader\$')"
  "ucm.tar|tar -C /usr/share/alsa/ucm2 -cf - conf.d/cd-18781y Lenovo/cd-18781y codecs/msm8953-wcd"
)
for p in "${PARTS[@]}"; do
    name=${p%%|*}; cmd=${p#*|}
    echo "from the device: $name"
    ssh "$DEV" "$cmd" > "$OUT/$name.tmp"
    tar -tf "$OUT/$name.tmp" >/dev/null
    mv "$OUT/$name.tmp" "$OUT/$name"
done
(cd "$OUT" && sha256sum ./*.tar > parts.sha256 2>/dev/null || shasum -a 256 ./*.tar > parts.sha256)
echo "done: $OUT (add snd-soc-tas5782m.ko, see driver/tas5782m/README.md)"
