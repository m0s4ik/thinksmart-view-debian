#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Installs a new snd-soc-tas5782m module on a running ThinkSmart View, or puts back the previous one.
# Run on the device, as root:
#   ./install-module.sh /path/to/snd-soc-tas5782m.ko   # install this module
#   ./install-module.sh restore                        # put back the module that was there before
# Stop every program that plays or records first: the script refuses to go on while /dev/snd is open.
# The current module is backed up once (the backup always stays the original one). After installing, the codec is
# unbound and the module reloaded (the card comes back by itself), then thinksmart-audio sets the volume again.
# If the old module cannot be unloaded, or the card does not come back within 30 s, the device reboots: the new module
# is already in place. Plays no sound.
set -euo pipefail

KVER=${KVER:-7.1.3-msm8953}
EXTRA=/usr/lib/modules/$KVER/extra
CURRENT=$EXTRA/snd-soc-tas5782m.ko
BACKUP=/var/lib/thinksmart/snd-soc-tas5782m.ko.before
CODEC=1-0049

case "${1:-}" in
"")
    echo "usage: $0 /path/to/snd-soc-tas5782m.ko | restore" >&2
    exit 2
    ;;
restore)
    [ -f "$BACKUP" ] || { echo "no backup in $BACKUP" >&2; exit 1; }
    NEW=$BACKUP
    ;;
*)
    NEW=$1
    [ -f "$NEW" ] || { echo "$NEW not found" >&2; exit 1; }
    ;;
esac

# modinfo only accepts file names ending in .ko
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$NEW" "$tmp/snd-soc-tas5782m.ko"
vm=$(modinfo -F vermagic "$tmp/snd-soc-tas5782m.ko")
case "$vm" in
    "$KVER "*) ;;
    *) echo "wrong vermagic: '$vm' (need $KVER)" >&2; exit 1 ;;
esac
modinfo -F parm "$tmp/snd-soc-tas5782m.ko" | grep -q '^volume_mode:' ||
    echo "note: this module has no hardware volume (old driver): use a software volume" >&2

open=$(for f in /proc/[0-9]*/fd/*; do
    l=$(readlink "$f" 2>/dev/null) || continue
    case "$l" in (/dev/snd/*) p=${f#/proc/}; echo "${p%%/*}" ;; esac
done | sort -u)
if [ -n "$open" ]; then
    echo "the sound card is still open by:" >&2
    for p in $open; do echo "  $p $(tr '\0' ' ' < "/proc/$p/cmdline")" >&2; done
    exit 1
fi

mkdir -p "$(dirname "$BACKUP")"
if [ ! -f "$BACKUP" ] && [ -f "$CURRENT" ]; then
    cp -p "$CURRENT" "$BACKUP"
    echo "current module backed up to $BACKUP"
fi
install -m 0644 "$tmp/snd-soc-tas5782m.ko" "$CURRENT"
depmod -a "$KVER"
echo "installed $CURRENT ($(sha256sum "$CURRENT" | cut -c1-16)…)"

if [ -e "/sys/bus/i2c/drivers/tas5782m/$CODEC" ]; then
    echo "$CODEC" > /sys/bus/i2c/drivers/tas5782m/unbind
fi
if ! modprobe -r snd_soc_tas5782m; then
    echo "the old module does not unload: rebooting (the new one loads at boot)" >&2
    systemctl reboot
    exit 0
fi
modprobe snd_soc_tas5782m
i=0
until grep -q cd18781y /proc/asound/cards 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 60 ]; then
        echo "sound card cd-18781y not back after 30 s: rebooting" >&2
        systemctl reboot
        exit 0
    fi
    sleep 0.5
done
systemctl restart thinksmart-audio
dmesg | grep -E "tas5782m|$CODEC" | tail -5
for p in /sys/module/snd_soc_tas5782m/parameters/*; do
    [ -e "$p" ] && echo "$(basename "$p") = $(cat "$p")"
done
amixer -c 0 sget 'Speaker Amp Master' | tail -2
