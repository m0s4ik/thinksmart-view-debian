# Flashing over EDL

Everything is written over Qualcomm's **EDL** (emergency download) mode with
[bkerler/edl](https://github.com/bkerler/edl). It works on Linux and macOS. Nothing here needs Android, adb or an
unlocked bootloader.

> **Make a full backup first.** It is the only way back to the original Lenovo firmware.

## Tools and cable

- `edl` from git (`pip install git+https://github.com/bkerler/edl` in a venv; tested at commit 1cda1a6, Python 3.12).
  It recognises the Lenovo firehose loader by itself.
- A **USB-A to USB-C** cable (or a hub/adapter with a USB-A port): the device's USB-C port has no CC resistors, so a
  plain C-to-C cable from a laptop is often not detected. USB 2.0 ports/hubs are the safest (USB 3 sometimes gives
  Sahara errors); a dock hub and a Mac's USB-C port with an adapter both worked for us.
- About 8 GB of free disk space for the backup.
- On Linux, `edl` needs raw access to the USB device: install the udev rules shipped with bkerler/edl or run it with
  `sudo`, and stop ModemManager (`sudo systemctl stop ModemManager`), which otherwise grabs the device.

## Entering EDL

1. Unplug the power supply.
2. Hold **Vol+ and Vol−** together, plug the power supply back in, release after 5-10 s.
3. The screen stays black; the host sees a Qualcomm `QUSB__BULK` device (USB ID `05c6:9008`;
   `lsusb` on Linux, `ioreg -p IOUSB` on macOS).

From Android with adb enabled (LineageOS, for example) `adb reboot edl` does the same without the buttons.

`edl reset` reboots the device. It may print `USBError(5)`; the device reboots anyway.

The device does not stay in EDL forever: on one unit it dropped off the bus a few minutes after the last command.
Run the commands one after the other, and if `05c6:9008` is gone, enter EDL again.

## 1. Full backup

```bash
edl rf stock-full-emmc.bin
```

The eMMC is 7,818,182,656 bytes (15,269,888 sectors). **Check the size of the file afterwards**: if the disk fills up,
`edl rf` truncates the file without failing. Keep a checksum and a compressed copy somewhere safe
(`gzip` brings it to ~1.1 GB on a device that was never used; more if the partitions hold more data). Also save the partition table: `edl printgpt > gpt-original.txt`.

Restore (everything, including the partition table): `edl wf stock-full-emmc.bin`.

If `edl rf` stops halfway (on one unit behind a monitor's USB hub the connection dropped at 68 % and `edl` kept
printing `USBError` without exiting), read the eMMC in parts with `edl rs` and join them. A part that fails is read
again after entering EDL again; the parts already read stay:

```bash
for ((start = 0; start < 15269888; start += 1048576)); do   # 15 parts of 512 MiB, the last one shorter
  count=$((15269888 - start)); [ "$count" -gt 1048576 ] && count=1048576
  f=$(printf 'part-%08d.bin' "$start")
  [ "$( { wc -c < "$f"; } 2>/dev/null)" -eq $((count * 512)) ] 2>/dev/null || edl rs "$start" "$count" "$f"
done
cat part-*.bin > stock-full-emmc.bin                    # then check: 7,818,182,656 bytes
```

Stop a stalled `edl rs` with Ctrl-C (it does not exit on its own) and run the loop again. Reading every part a second
time and comparing the two (`cmp`) shows that the backup is good.

## 2. lk2nd and the bootstrap

We use the pieces published by [rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart):

- **lk2nd** (`prebuilt/lk2nd.img`, a secondary bootloader from [msm8916-mainline/lk2nd](https://github.com/msm8916-mainline/lk2nd))
  into the `boot` partition: `edl w boot lk2nd.img`. lk2nd reads `extlinux/extlinux.conf` from the first partition of
  the MBR inside `system`.
- rickx's **postmarketOS bootstrap image** into the `system` partition: `edl w system bootstrap.img`. It is only
  needed to obtain the kernel, initramfs and firmware (see [kernel.md](kernel.md)) and as a fallback system.

From now on Android does not boot any more; the backup brings it back.

## 3. Repartitioning

Android's `system` partition is too small for comfort. rickx's `apply-ubuntu-gpt.sh` (from the same repository;
follow its instructions) rewrites the GPT: partitions 1-23 (among them `boot` with lk2nd and `modem`) stay as they
are; every partition after `system` (p25-p51: `vendor`, `cache`, `persist`, `oem`, … `userdata`) is removed; `system`
grows to sector 15204318 and a new **`persist`** (p27, 65536 sectors) takes the last 32 MiB of the eMMC.

The new `persist` does not get the old one's contents: the old `persist` (p27 of the stock GPT, sector 5238784, 65536
sectors) now lies inside `system` and the image overwrites it, and the new one holds whatever `userdata` left there.
msm-firmware-loader mounts `persist` read-only; the only file it links from it is `WCNSS_qcom_wlan_nv.bin`, which is
for Qualcomm's WCNSS Wi-Fi (this device's Wi-Fi is the QCA9379, `ath10k`). To keep the original contents anyway (Android's
calibration files), copy them from the full backup into the new `persist`, over EDL after repartitioning:

```bash
dd if=stock-full-emmc.bin of=persist-original.bin bs=512 skip=5238784 count=65536
edl ws 15204319 persist-original.bin       # by sector: see below why not "edl w persist"
```

`edl` at commit 1cda1a6 stops reading the GPT at the first empty entry, so after repartitioning `edl printgpt` ends at
`system` and does not find `persist` (p27 comes after the empty p25 and p26; fix proposed in
[bkerler/edl#840](https://github.com/bkerler/edl/pull/840)). Linux and `sfdisk -l` on the device see all 25.

On our device, after the script: `system` starts at sector 923648 and is **14,280,671 sectors** (6.8 GB) long. That is
the default `SYSTEM_SECTORS` of `image/build.sh`; check yours with `edl printgpt` and, if different, set it in
`config.env` and rebuild the image before writing it.

## 4. Writing the Debian image

```bash
gunzip -k thinksmart-debian-YYYYMMDD.img.gz     # only if you have just the .gz; build.sh leaves the .img too
edl w system thinksmart-debian-YYYYMMDD.img
edl reset
```

About 28 MB/s, ~4.5 minutes. The image contains its own MBR (p1 `/boot`, p2 root), relative to the start of
`system`. The first boot takes about 14 s like the others; the device then joins your Wi-Fi and accepts `ssh root@<device>` with your key.

To update only the boot partition (kernel, DTB, extlinux) you can write p1 alone at its absolute offset. Cut p1 out
of the image (it starts at sector 2048 of the image and is 497664 sectors long), then write it at
`<system start + 2048>` (923648 + 2048 = 925696 on our layout):

```bash
dd if=thinksmart-debian-YYYYMMDD.img of=p1.img bs=512 skip=2048 count=497664
edl ws 925696 p1.img
```

### Seeing why an image does not boot

The image boots with `quiet loglevel=0 systemd.show_status=0`, so the screen shows nothing. To see the kernel log,
remove those words from `extlinux/extlinux.conf` in p1 of the image on the build machine and write p1 again:

```bash
LOOP=$(sudo losetup -P --show -f thinksmart-debian-YYYYMMDD.img)
sudo mount "${LOOP}p1" /mnt
sudo nano /mnt/extlinux/extlinux.conf     # drop "quiet loglevel=0 systemd.show_status=0", or add pmos.debug-shell
sudo umount /mnt && sudo losetup -d "$LOOP"
dd if=thinksmart-debian-YYYYMMDD.img of=p1.img bs=512 skip=2048 count=497664
edl ws 925696 p1.img && edl reset
```

`pmos.debug-shell` gives a shell in the initramfs. lk2nd reads only one entry of `extlinux.conf`: edit it, do not add
a second one.

## Going back

| Situation | What to do |
|---|---|
| New image does not boot | remove `quiet` from `extlinux.conf` to see the kernel log, or add `pmos.debug-shell` for a shell in the initramfs ([above](#seeing-why-an-image-does-not-boot)); otherwise rewrite the last good image (`edl w system`) |
| Debian unusable | write rickx's bootstrap image to `system` again (its MBR is relative to `system`, so it also works after repartitioning) |
| Back to Android | `edl wf stock-full-emmc.bin` (restores the original GPT too) |
| Before an experiment | `edl rf current.bin` takes a full backup of the working system (~8 GB raw, about 1 GB or less with `gzip`, depending on how much data it holds) |
