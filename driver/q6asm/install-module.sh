#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# SPDX-FileCopyrightText: 2026 Andrea Mattera
# Installs the rebuilt q6asm.ko and q6asm-dai.ko (driver/q6asm) on a running ThinkSmart View, or puts back the
# previous ones. Run on the device, as root:
#   ./install-module.sh /dir/with/both/ko   # install q6asm.ko and q6asm-dai.ko from this directory
#   ./install-module.sh restore             # put back the modules that were there before
# The current modules are backed up once (the backup always stays the original pair). The two modules are installed
# together: q6asm-dai calls into q6asm and the patches of one assume the other.
# Nothing is reloaded: the whole sound card hangs off these modules, so the new ones are loaded by the next boot. The
# script never reboots by itself. Nothing in the initramfs or the boot path uses them: a wrong module can only cost
# the sound card, ssh stays up and "restore" works remotely. Plays no sound.
set -euo pipefail

KVER=${KVER:-7.1.3-msm8953}
DIR=/usr/lib/modules/$KVER/kernel/sound/soc/qcom/qdsp6
BACKUP=/var/lib/thinksmart/q6asm-before
MODULES="q6asm.ko q6asm-dai.ko"

[ "$(id -u)" = 0 ] || { echo "must be run as root" >&2; exit 1; }
[ "$(uname -r)" = "$KVER" ] || { echo "running kernel $(uname -r), these modules are for $KVER" >&2; exit 1; }

reboot_note() {
    echo
    echo "The running kernel still has the old modules: a reboot loads the new ones (systemctl reboot)."
    echo "To go back: $0 restore, then reboot."
}

case "${1:-}" in
"")
    echo "usage: $0 /dir/with/q6asm.ko-and-q6asm-dai.ko | restore" >&2
    exit 2
    ;;
restore)
    for m in $MODULES; do
        [ -s "$BACKUP/$m" ] || { echo "no backup $BACKUP/$m" >&2; exit 1; }
    done
    for m in $MODULES; do
        install -m 0644 "$BACKUP/$m" "$DIR/$m"
        echo "restored $DIR/$m ($(sha256sum "$DIR/$m" | cut -d' ' -f1))"
    done
    depmod -a "$KVER"
    reboot_note
    exit 0
    ;;
esac

SRC=$1
[ -d "$SRC" ] || { echo "$SRC is not a directory" >&2; exit 1; }
for m in $MODULES; do
    f=$SRC/$m
    [ -s "$f" ] || { echo "missing or empty: $f (the two modules are installed together)" >&2; exit 1; }
    vm=$(modinfo -F vermagic "$f")
    case "$vm" in
        "$KVER "*) ;;
        *) echo "$f: wrong vermagic '$vm' (need $KVER)" >&2; exit 1 ;;
    esac
    if grep -aq 'intree=Y' "$f"; then
        echo "$f is the kernel package's module, not the one rebuilt from driver/q6asm" >&2
        exit 1
    fi
done

if [ ! -d "$BACKUP" ]; then
    mkdir -p "$BACKUP.tmp"
    for m in $MODULES; do cp -p "$DIR/$m" "$BACKUP.tmp/$m"; done
    mv "$BACKUP.tmp" "$BACKUP"
    echo "current modules backed up to $BACKUP"
else
    echo "backup already in $BACKUP (kept: it is the original pair)"
fi
for m in $MODULES; do
    echo "backup   $m $(sha256sum "$BACKUP/$m" | cut -d' ' -f1)"
done

for m in $MODULES; do
    install -m 0644 "$SRC/$m" "$DIR/$m"
    echo "installed $m $(sha256sum "$DIR/$m" | cut -d' ' -f1)"
done
depmod -a "$KVER"
for m in $MODULES; do
    grep -q "^kernel/sound/soc/qcom/qdsp6/$m:" "/usr/lib/modules/$KVER/modules.dep" ||
        { echo "$m is not in modules.dep after depmod" >&2; exit 1; }
done
echo "modules.dep: both modules listed"
reboot_note
