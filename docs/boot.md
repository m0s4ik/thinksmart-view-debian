# How the system boots

```
PBL → aboot (Lenovo) → lk2nd (partition "boot") → extlinux.conf on p1 of "system"
    → kernel 7.1.3-msm8953 + postmarketOS initramfs → kpartx, e2fsck, mount p2 → switch_root → Debian systemd
```

## Image layout

The image is the whole `system` partition after repartitioning, with an MBR inside:

- **p1**, sector 2048, 497664 sectors, type `ef`, bootable: **ext2** with 1 KiB blocks and the same minimal feature
  set as postmarketOS (`ext_attr resize_inode dir_index filetype sparse_super large_file`; no
  `extent`/`64bit`/`metadata_csum`/journal: lk2nd reads it), label `pmOS_boot`. Contains `vmlinuz`, `initramfs`,
  `config`, `System.map`, the flat DTBs **and** `dtbs/qcom/…` (it is unclear which one lk2nd reads with `fdtdir /`),
  and `extlinux/extlinux.conf` with **a single entry**.
- **p2**, sector 499712 to the end: **ext4** (no `metadata_csum`, like postmarketOS), label `pmOS_root`.

Kernel command line: the postmarketOS one plus `consoleblank=0 vt.global_cursor_default=0` (no blanking, no cursor)
and `quiet loglevel=0 systemd.show_status=0` (no kernel text on the screen while booting; an application can show
its own splash, see below).

## System

Debian 13 trixie arm64, `minbase` + `--no-install-recommends`: systemd, udev, NetworkManager + wpasupplicant,
OpenSSH, nftables, ALSA utils + UCM, Python 3.13, DejaVu fonts, dmsetup. No desktop, no PipeWire. GPU: reduced Mesa (freedreno, EGL, GBM,
OpenGL ES, no LLVM), the package `mesa-freedreno` in `/usr/lib/aarch64-linux-gnu`, behind Debian's libglvnd
(`libegl1`, `libgles2`). Optional web layer (`WEB=1`): WPE WebKit 2.54 with bubblewrap. Journal on disk
(50 MB, kept across reboots). About 600 MB used on root, ~1.6 GB of RAM free.

- **Users**: root only (ssh with keys only; optional password for the login on the screen). Applications create
  their own users.
- **Wi-Fi**: one NetworkManager profile from `config.env`, infinite retries, power saving off, optional fixed MAC.
  `NetworkManager-wait-online` is disabled.
- **Firewall**: inbound only loopback, replies, ICMP, DHCPv6 and port 22 (plus `LAN_TCP_PORTS` of `config.env`) from `LAN_V4`/`LAN_V6`.
- **Firmware**: `msm-firmware-loader` (copied from postmarketOS 1.5.0, MIT) runs before udev, mounts `modem` and
  `persist` read-only and points the kernel firmware path at their blobs (audio DSP, Wi-Fi, venus).
- **Audio**: `thinksmart-audio.service` waits for the `cd18781y` card (udev loads `snd-soc-tas5782m`), applies the
  UCM boot sequence and `HiFi`/`Speaker`/`Microphone`, sets the volume on the amplifier (`Speaker Amp Master`)
  from `/var/lib/thinksmart/volume` or `VOLUME` of `/etc/default/thinksmart-audio`, and leaves the software volume
  (`/etc/asound.conf`, pcm `speaker`, control `Master`, also the `default` pcm) at 100%. `alsa-restore`/`alsa-state` are
  masked.
- **Services**: `msm-firmware-loader`, `thinksmart-audio`, NetworkManager, ssh, timesyncd, nftables; login on the screen
  (`getty@tty1`).
- **Splash** (optional, done by an application): the screen is free about 17.5 s after the kernel starts. The
  framebuffer is `/dev/fb0` (800×1280, BGRX); a unit with `DefaultDependencies=no` that loads `msm` and the panel
  module itself (without waiting for udev) and copies a pre-rendered raw image can show it that early.

## Headless boot: the emergency mode we hit (and fixed)

The first boot of an early image stopped in **emergency mode**: `Timed out waiting for device
dev-disk-by\x2duuid-<boot uuid>`, then `Dependency failed` for `boot.mount` and `local-fs.target`. Without a keyboard
that is a dead end (`sulogin` waits for a password on the console). Two causes, reproduced with `udevadm test` on a
device-mapper with an empty udev database:

1. **`dmsetup` was missing**: without its udev rules (`55-dm.rules`, `60-persistent-storage-dm.rules`) the
   device-mapper devices created by kpartx (`dm-0` = `/boot`, `dm-1` = root) get no `/dev/mapper/*` or
   `/dev/disk/by-uuid/*`, and `99-systemd.rules` marks them `SYSTEMD_READY=0`.
2. **Even with `dmsetup`**: at coldplug `55-dm.rules` accepts an already existing device-mapper only if the udev
   database says it was activated properly (`DM_UDEV_PRIMARY_SOURCE_FLAG`). A Debian/dracut initramfs keeps that by
   moving `/run`; the postmarketOS one does not, so the device ends up in `dm_disable`.

Fixes in the image:

- package `dmsetup`;
- `image/rootfs/etc/udev/rules.d/54-dm-initramfs.rules` (before `55-dm.rules`): for a device-mapper udev has never
  seen during this boot, on `add` without a cookie, with a name, active and with a table, set
  `DM_UDEV_PRIMARY_SOURCE_FLAG=1`; the standard rules then do the rest;
- `/boot` in fstab with `nofail,x-systemd.device-timeout=15`: if it does not appear, the system still reaches Wi-Fi
  and ssh (`/boot` is only needed to change kernel or `extlinux.conf`);
- `systemd-gpt-auto-generator` disabled: it follows the root up to `mmcblk0` (Android's GPT, dozens of partitions).

None of our units requires `local-fs.target` or `/boot`; everything else is `Wants=`. `image/verify.sh` checks all of
this on the built image, including a `udevadm test` of a real device-mapper with the image's rules and an empty
database.
