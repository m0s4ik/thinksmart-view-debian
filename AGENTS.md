# Notes for coding agents

You are probably helping someone install Debian on a Lenovo ThinkSmart View (CD-18781Y). The procedure for people
is [docs/install.md](docs/install.md): follow it step by step and do not invent shortcuts. This file adds what an
agent needs on top: where things are, the exact checks, and **where to stop and ask**.

## Stop and ask the person

Flashing over EDL can make the device unbootable, and only the full backup brings it back. So:

- **Never write to the device over EDL** (`edl w`, `edl wf`, `edl wl`, `apply-ubuntu-gpt.sh`, any repartitioning)
  without an explicit "yes" for that exact command. Before asking, say which partition it writes and what is lost.
- **No EDL write before the full backup exists and is checked**: `stock-full-emmc.bin` must be exactly
  **7,818,182,656 bytes** (`edl rf` truncates it silently when the disk is full) and `gpt-original.txt` must exist.
  If either is missing, stop.
- **Physical steps are the person's**: entering EDL mode (power off, hold Vol+ and Vol−, power on), cables, watching
  the screen. Tell them what to do and wait for them to confirm.
- **Secrets**: `image/config.env` holds the Wi-Fi password and the root password hash, and the built image holds them
  plus the ssh host keys. Never print them, commit them (`config.env` is git-ignored: keep it so) or upload the image.
- **Sound**: tell the person before playing anything on the speaker (`speaker-test`, `aplay`).
- `image/build.sh` needs root and loop devices. In a privileged LXC container it creates the missing loop nodes
  itself, and `verify.sh` skips (and says so) the one udev test that needs to open a device-mapper device. If it fails
  on permissions anyway, say so; do not change the container's configuration on your own.

## Map

| Path | What |
|---|---|
| `docs/install.md` | the procedure, from a sealed device to ssh |
| `docs/flashing.md` | EDL details and how to go back to the original firmware |
| `docs/kernel.md` | where the kernel, modules, firmware and UCM in `image/parts/` come from |
| `docs/boot.md`, `docs/hardware.md`, `docs/known-issues.md` | what is in the system, what works, what does not |
| `image/build.sh` | builds the image (root); `image/verify.sh` checks it read-only (build.sh runs it) |
| `image/fetch-parts.sh` | copies kernel parts from a device running postmarketOS 7.1.3 |
| `image/build-mesa.sh` | reduced Mesa (freedreno, Wayland platform, libglvnd vendor) as the package `mesa-freedreno_*_arm64.deb` |
| `image/build-wpe.sh` | WPE WebKit 2.54 backport for the optional web layer (`WEB=1`; Docker on a fast arm64 machine) |
| `AIRPLAY=1` in `config.env` | optional GStreamer runtime for an AirPlay receiver built on UxPlay (Debian packages only) |
| `image/config.env.example` | every setting, with comments; copy to `image/config.env` |
| `image/rootfs/` | files copied into the image |
| `driver/tas5782m/` | speaker driver (GPL-2.0-only), its build recipe and `install-module.sh` |
| `driver/vcnl4000/` | optional light sensor module: recipe for the upstream driver, built out of tree |
| `driver/venus/` | optional video decoder core: kernel source + `hfi_parser.patch`, built out of tree |
| `driver/s5kc505a/` | optional front camera: jethac's sensor driver (out of tree) + device tree patch; needs a rebuilt DTB (sha256 pinned in `dtb.sha256`), `fdt` and `cma=128M` in `extlinux.conf`: `CAMERA=1` in `config.env` (flashed and booted on one device), or by hand |

## Commands and the checks that must pass

```bash
./image/fetch-parts.sh user@<device-ip>          # then image/parts/ has boot.tar, modules-7.1.3-msm8953.tar,
                                                 # firmware.tar, ucm.tar
# build snd-soc-tas5782m.ko: driver/tas5782m/README.md, then copy it to image/parts/
# optional: vcnl4000.ko (light sensor) from driver/vcnl4000/README.md, also to image/parts/
# optional: venus-core.ko (video decoder) from driver/venus/README.md, also to image/parts/
# optional, CAMERA=1: s5kc505a.ko + apq8053-lenovo-cd-18781y-camera.dtb (driver/s5kc505a/README.md or CI artifacts)
./image/build-mesa.sh                            # reduced Mesa for the GPU -> image/parts/mesa-freedreno_*_arm64.deb
/sbin/modinfo image/parts/snd-soc-tas5782m.ko    # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"
                                                 # and parm volume_mode + standby_ms
cp image/config.env.example image/config.env     # the person fills in Wi-Fi, ssh key; SYSTEM_SECTORS from edl printgpt
sudo ./image/build.sh image/config.env           # ~10 min; ends with verify.sh: every line "ok", none "FAIL"
```

After flashing (step 7 of the guide), on the device:

```bash
aplay -l                                  # card cd-18781y
journalctl -u thinksmart-audio -b         # "audio ready (... on amplifier: amplifier N, softvol 100%)"
nmcli -t -f GENERAL.STATE dev show wlan0  # 100 (connected)
```

## Known traps

- The speaker module must be built with **clang 22** against the exact 7.1.3 source and `.config` (KCFI): built
  with GCC it loads but `init` fails. Without `dwarves` (pahole) it fails with "Exec format error".
- `build.sh` refuses a `snd-soc-tas5782m.ko` without the `volume_mode` parameter (the old driver, no hardware
  volume). Rebuild it; `ALLOW_OLD_TAS5782M=1` only if the person asks.
- Install only `snd-soc-tas5782m.ko` in `extra/`, never the `-dbg` module (same aliases).
- lk2nd reads a **single entry** in `extlinux.conf`; the boot partition is ext2 with 1 KiB blocks: do not "fix" it.
- The `append` line ends with `deviceinfo_no_framebuffer=true` (then `cma=128M` with `CAMERA=1`): it saves the
  initramfs's 10 s wait for `/dev/fb0`, keep it. A broken `append` line means no root file system and someone at the
  device: change `extlinux.conf` only by writing a new file and checking it first
  ([image/README.md](image/README.md#after-the-first-boot)), and ask before rebooting.
- `SYSTEM_SECTORS` must equal the `system` partition size after repartitioning, or the image does not fit / boot.
- The USB-C port has no CC resistors: if EDL does not see the device, suggest a USB-A to USB-C cable.
- Mesa lives in `/usr` as the package `mesa-freedreno`, which provides `libgbm1`, `libegl-mesa0` and `libglx-mesa0`:
  never install Debian's Mesa (`libgl1-mesa-dri`, `mesa-libgallium`, `libgbm1`). apt cannot put it next to
  `mesa-freedreno`, so it offers to **remove** `mesa-freedreno` instead: read the list of removals before answering yes.
  `-dev` packages (`libgbm-dev`, pulled by GStreamer's or WebKit's `-dev`) do this: build elsewhere.
  `FD_MESA_DEBUG=sysmem` goes in the browser's environment only, never system-wide.
- The camera DTB ([driver/s5kc505a](driver/s5kc505a/README.md)) changes what lk2nd boots: keep the old DTB, keep a
  copy of `extlinux.conf`, and ask before rebooting into it (or flashing a `CAMERA=1` image). `kernel.panic` is 0 and
  there is no watchdog, so a hang needs someone at the device. Never put `fdt` next to `fdtdir` (fdtdir wins) and never
  name a DTB that is not in `/boot` (no boot); `build.sh` refuses a camera DTB other than the one in
  `driver/s5kc505a/dtb.sha256`: rebuild it; the sum changes only together with the patch. The DT says `rotation = <180>`
  (the read-out is upside down on the stand; the sensor cannot flip). libcamera's default 2560x1600 needs `cma=128M` on
  the kernel command line (`CAMERA=1` adds it; a hand install must add it too): with the default 32 MB CMA ask for
  1280x960.
- More in [docs/known-issues.md](docs/known-issues.md).

## Before committing

- `.github/scripts/check-private.sh`: no private IP or MAC addresses, home host names, tokens or keys (CI runs it too;
  put your own host names, SSIDs and serial numbers in the git-ignored `.private-patterns`).
- `shellcheck -S warning` on the scripts you touched (CI runs it on all of them).
- Code, comments and docs in English; new files start with the SPDX header of their neighbours.
