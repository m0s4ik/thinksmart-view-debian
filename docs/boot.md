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
  `config`, `System.map`, the flat DTBs **and** `dtbs/qcom/…`, and `extlinux/extlinux.conf` with **a single entry**.
  With `fdtdir /` lk2nd (its `extlinux.c`) looks for its DTB name `apq8053-lenovo-cd-18781y` as `/qcom/<name>.dtb`,
  then `/qcom-<name>.dtb`, then `/<name>.dtb`: on this partition only the last exists, so it reads the **flat**
  `/apq8053-lenovo-cd-18781y.dtb` (the copy in `dtbs/qcom/` is identical and unused). `fdt /<file>.dtb` loads another
  DTB (the camera one, [driver/s5kc505a](../driver/s5kc505a/README.md), `CAMERA=1`); when both are present
  **`fdtdir` wins**, so replace the line. A missing file makes lk2nd skip the entry instead of booting it.
- **p2**, sector 499712 to the end: **ext4** (no `metadata_csum`, like postmarketOS), label `pmOS_root`.

Kernel command line: the postmarketOS one plus `consoleblank=0 vt.global_cursor_default=0` (no blanking, no cursor)
and `quiet loglevel=0 systemd.show_status=0` (no kernel text on the screen while booting; an application can show
its own splash, see below).

## System

Debian 13 trixie arm64, `minbase` + `--no-install-recommends`: systemd, udev, NetworkManager + wpasupplicant,
OpenSSH, nftables, avahi, ALSA utils + UCM, Python 3.13, DejaVu fonts, dmsetup. No desktop, no PipeWire. GPU: reduced Mesa (freedreno, EGL, GBM,
OpenGL ES, no LLVM), the package `mesa-freedreno` in `/usr/lib/aarch64-linux-gnu`, behind Debian's libglvnd
(`libegl1`, `libgles2`). Optional web layer (`WEB=1`): WPE WebKit 2.54 with bubblewrap. Optional AirPlay runtime
(`AIRPLAY=1`): GStreamer base/good/libav plugins and two of the bad ones, libplist, avahi's dns_sd library. Journal on
disk (50 MB, kept across reboots). About 470 MB used on root without the optional layers, ~1.7 GB of RAM free.

- **Users**: root only (ssh with keys only; optional password for the login on the screen). Applications create
  their own users.
- **Wi-Fi**: one NetworkManager profile from `config.env`, infinite retries, power saving off, optional fixed MAC.
  `NetworkManager-wait-online` is disabled.
- **Firewall**: inbound only loopback, replies, ICMP, DHCPv6, port 22 (plus `LAN_TCP_PORTS` of `config.env`) and mDNS
  (UDP 5353) from `LAN_V4`/`LAN_V6`. Applications add their own rules as `/etc/nftables.d/*.nft` (rule lines of the
  input chain, with `$LAN_V4`/`$LAN_V6`; see the README in that directory), so they bring their ports with them
  instead of the image's configuration.
- **mDNS**: `avahi-daemon` answers for `<hostname>.local` and lets applications announce services (AirPlay, …).
- **Firmware**: `msm-firmware-loader` (copied from postmarketOS 1.5.0, MIT) runs before udev, mounts `modem` and
  `persist` read-only and points the kernel firmware path at their blobs (audio DSP, Wi-Fi, venus).
- **Video decoder**: with `venus-core.ko` in the parts, the kernel package's `venus-core` is replaced by the rebuilt
  one ([driver/venus](../driver/venus/README.md)); udev loads it and `/dev/video*` appear (`qcom-venus-decoder`,
  `qcom-venus-encoder`).
- **Audio**: `thinksmart-audio.service` waits for the `cd18781y` card (udev loads `snd-soc-tas5782m`), applies the
  UCM boot sequence and `HiFi`/`Speaker`/`Microphone`, sets the volume on the amplifier (`Speaker Amp Master`)
  from `/var/lib/thinksmart/volume` or `VOLUME` of `/etc/default/thinksmart-audio`, and leaves the software volume
  (`/etc/asound.conf`, pcm `speaker`, control `Master`, also the `default` pcm; converted to 16 bit, see known-issues) at 100%. `alsa-restore`/`alsa-state` are
  masked.
- **Services**: `msm-firmware-loader`, `thinksmart-audio`, NetworkManager, ssh, timesyncd, nftables, avahi-daemon; login on the screen
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
