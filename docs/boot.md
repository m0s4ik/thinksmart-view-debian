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

## Kernel command line

The `append` line of `extlinux.conf`: the postmarketOS one (`pmos_boot_uuid`, `pmos_root_uuid`, `pmos_rootfsopts`)
plus

- `consoleblank=0 vt.global_cursor_default=0`: no blanking, no cursor;
- `quiet loglevel=0 systemd.show_status=0`: no kernel text on the screen while booting (an application can show its
  own splash, see below);
- `deviceinfo_no_framebuffer=true` (since v0.4), last: the postmarketOS initramfs (3.7.2) waits for `/dev/fb0`
  in a loop of 100 × `sleep 0.1` before showing its splash, but it contains no kernel modules, so fb0 cannot appear
  there and every boot lost 10 s (`ERROR: /dev/fb0 did not appear after waiting 10 seconds!`). The kernel passes
  `name=value` parameters it does not know into the environment of `/init` (that is how `pmos_root_uuid` gets
  there), and neither `deviceinfo` file of the initramfs sets this one, so the value stays: the initramfs logs `NOTE: Skipping framebuffer setup (deviceinfo_no_framebuffer)` and goes on. Nothing in `/boot` other than
  `extlinux.conf` changes. fb0 appears later anyway, from Debian (`msmdrmfb`, about 12 s after the kernel starts).
  The kernel lists the parameter among its "Unknown kernel command line parameters" and systemd finds it in its
  environment: both harmless;
- `CAMERA=1` only, after it: `cma=128M`, 128 MB of contiguous memory instead of the default 32 MB, for libcamera's
  full-size buffers ([driver/s5kc505a](../driver/s5kc505a/README.md#libcamera)).

A broken `append` line (a lost UUID, a cut line) means the initramfs does not find the root file system: edit
`extlinux.conf` with care ([image/README.md](../image/README.md#upgrading-without-reflashing)).

## Boot time

`systemd-analyze` on a device: `Startup finished in 6.004s (kernel) + 7.836s (userspace) = 13.840s` with
`deviceinfo_no_framebuffer=true` (13.1-14.1 s over about ten boots; the first boot of a freshly written `CAMERA=1`
image: `5.979s + 7.111s = 13.091s`); `16.396s + 7.813s = 24.210s` before it (v0.3 and earlier). "kernel" includes the
initramfs. Where the time of a boot before the change went, from the kernel's timestamps:

| In order | Time |
|---|---|
| kernel, up to `/init` of the initramfs | 0.88 s |
| initramfs, before its udev (eudev) starts; this ends exactly when `random: crng init done` is logged (most likely udevd reading `/dev/urandom` while there is no hardware RNG and no seed from lk2nd: inferred, not traced) | ~2.06 s |
| **waiting for `/dev/fb0`**, from 3.35 s to 13.66 s (gone since v0.4) | 10.3 s |
| `check_keys` (a `sleep 1`) | ~1.0 s |
| sub-partitions mapped (`kpartx`) and found (`blkid`) | ~1.0 s |
| resize check and `e2fsck` of the root | 0.33 s |
| userspace: `msm-firmware-loader.service`, ordered before udev (about 500 forks for 157 modem blobs), so every hardware probe waits for it | 2.5 s |

The remaining seconds need changes to the initramfs or to the firmware loader and are not done
([known-issues.md](known-issues.md#boot)).

## Boot report

Since v0.4 every image has `thinksmart-boot-report.service`, so each boot leaves its time in the journal and a
slow boot leaves what is needed to understand it. It starts with userspace (`DefaultDependencies=no`, wanted by
`sysinit.target`), is `Type=simple` so nothing waits for it, and runs `/usr/local/sbin/thinksmart-boot-report`
(POSIX sh, coreutils and util-linux only). About once a second until systemd reports the boot finished
(`FinishTimestampMonotonic`), at most until 180 s after the kernel started, it takes a sample: a fixed CPU benchmark
(a shell loop of 2000 iterations, about 20 ms on the device, timed in its own CPU time from `/proc/<pid>/schedstat`,
so other work on the CPUs does not count), `scaling_cur_freq` and `cpuinfo_cur_freq` of `policy0` and the online
CPUs. The CPU clock state (every cpufreq policy with `time_in_state` and `total_trans`, the CPU lines of
`/sys/kernel/debug/clk/clk_summary`, the `cpr`/`cpu` lines of `pm_genpd_summary`, `devices_deferred`, the thermal
zones) is kept at the first sample, whenever the benchmark changes by `SLOW_RATIO` or more from one sample to the next
(at most four times: while slow and right after), and at the end of a slow boot. All of it stays in
`/run/thinksmart-boot/` (`samples`, `snapshot-*`, `report`) until the next boot. To stay cheap while the system
boots, a sample forks nothing but `sleep`, and systemd is asked whether the boot has finished only once
`thinksmart-boot-report-done.service` (wanted by and ordered after `multi-user.target`) has touched
`/run/thinksmart-boot/default-target`, or every tenth sample if that never happens.

Then one line in the journal, identifier `thinksmart-boot` (the times here are a real boot's, the other figures only
show the format):

```
$ journalctl -t thinksmart-boot          # every boot; the journal is on disk (50 MB), so earlier boots are there
boot 13.840s (kernel 6.004s + userspace 7.836s); CPU benchmark 19/22/32 ms (fastest/median/slowest of 7, cpu time); cpu0 1689600 kHz (hw 1689600), online 0-7, max 41 C; unused clocks off 0.871730s, cpufreq 0.965845s: clocks before cpufreq
```

The times are systemd's own (as in `systemd-analyze`; "kernel" includes the postmarketOS initramfs); the last part is
the order of `clk: Disabling unused clocks` and `cpufreq_policy_online` in the kernel log
([known-issues.md](known-issues.md#boot)). A boot is **SLOW** when it takes more than `SLOW_TOTAL` seconds (30), when
the slowest benchmark sample takes `SLOW_RATIO` (5) times the fastest or more (against at least 10 ms: CPU time is
counted in 4 ms scheduler ticks), when a sample takes `SLOW_BENCH_MS` or more (off by default), or when the boot has
not finished after `MAX_WAIT` (180 s). Then the line starts with `SLOW`, has priority warning
(`journalctl -t thinksmart-boot -p warning` lists only those) and ends with the reasons, and every sample and snapshot
follows as separate lines. The settings are in `/etc/default/thinksmart-boot-report`. The service reads `/proc`,
`/sys` and debugfs only (systemd mounts debugfs at the start), has no network and runs under `ProtectSystem=strict`;
it ignores every error and exits by itself. Its own cost is in `journalctl -u thinksmart-boot-report` (`Consumed …
CPU time`).

Measured on the device: a normal boot gives the one line, with a benchmark of 17/19/35 ms at the default
`BENCH_LOOPS=2000`; the service used 0.46 s of CPU time (`CPUUsageNSec`) in a 13.4 s boot, and the boot time did not
change. The `SLOW` branch, forced with a threshold of 0, logged the samples and real `clk_summary` lines.

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
- **Services**: `msm-firmware-loader`, `thinksmart-audio`, `thinksmart-boot-report` and its `-done` unit
  ([above](#boot-report)),
  NetworkManager, ssh, timesyncd, nftables, avahi-daemon; login on the screen (`getty@tty1`).
- **Splash** (optional, done by an application): the screen is free about 12 s after the kernel starts (17.5 s
  in v0.3, [above](#boot-time)). The framebuffer is `/dev/fb0` (800×1280, BGRX); a unit with
  `DefaultDependencies=no` that loads `msm` and the panel module itself (without waiting for udev) and copies a
  pre-rendered raw image can show it that early.

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
- `/boot` in fstab with `nofail,x-systemd.device-timeout=90`: if it does not appear, the system still reaches Wi-Fi
  and ssh (`/boot` is only needed to change kernel or `extlinux.conf`); with `nofail` nothing waits for it, and the
  timeout is 90 s rather than 15 s (v0.3 and earlier) because in one slow boot the device appeared later than 15 s and
  `/boot` stayed unmounted ([known-issues.md](known-issues.md#boot));
- `systemd-gpt-auto-generator` disabled: it follows the root up to `mmcblk0` (Android's GPT, dozens of partitions).

None of our units requires `local-fs.target` or `/boot`; everything else is `Wants=`. `image/verify.sh` checks all of
this on the built image, including a `udevadm test` of a real device-mapper with the image's rules and an empty
database.
