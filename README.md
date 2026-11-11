# 🖥️ ThinkSmart View Debian

Run an **ultra-light Debian 13** on the **Lenovo ThinkSmart View** (CD-18781Y, the 8" Teams/Zoom desk display), with
working **screen, touch, GPU, speaker, microphones, Wi-Fi, sensors and hardware video decoder**. No Android, no
browser: a clean Linux base with no desktop, for whatever you want to build on it — a voice assistant, a smart-home
panel, a clock, a kiosk. Two optional layers add what some applications need: a web engine (WPE WebKit) to show web
pages, and the GStreamer runtime of an AirPlay receiver (UxPlay) for music and screen mirroring; a third one turns on
the front camera.

<p align="center"><img src="docs/images/thinksmart-view.png" width="720" alt="A ThinkSmart View in landscape showing fastfetch: Debian GNU/Linux 13 (trixie) aarch64, kernel 7.1.3-msm8953, GPU freedreno FD506"></p>
<p align="center"><sub>The ThinkSmart View running this system: the real <code>fastfetch</code> output (v0.1, no application
running). This project is not affiliated with or endorsed by Lenovo; ThinkSmart is a trademark of its owner.</sub></p>

[<img src="https://img.shields.io/github/v/release/m0s4ik/thinksmart-view-debian?include_prereleases&logo=github&label=Release">](https://github.com/m0s4ik/thinksmart-view-debian/releases)
[<img src="https://github.com/m0s4ik/thinksmart-view-debian/actions/workflows/ci.yml/badge.svg">](https://github.com/m0s4ik/thinksmart-view-debian/actions/workflows/ci.yml)
[<img src="https://img.shields.io/badge/Debian-13%20trixie-A81D33?logo=debian&logoColor=white">](https://www.debian.org)
[<img src="https://img.shields.io/badge/kernel-postmarketOS%207.1.3-009900?logo=linux&logoColor=white">](docs/kernel.md)
[<img src="https://img.shields.io/badge/arch-arm64-informational">](docs/hardware.md)
[<img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">](LICENSE)
[<img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-m0s4ik-FFDD00?logo=buymeacoffee&logoColor=black">](https://buymeacoffee.com/m0s4ik)

<a href="docs/install.md">Installation guide 🚀</a> | <a href="docs/hardware.md">Hardware</a> |
<a href="docs/flashing.md">Flashing over EDL</a> | <a href="docs/known-issues.md">Known issues</a>

**⭐ If you have one of these devices gathering dust, give it a second life, and star the repo if it helps!**

If this project saved you some time, you can also
[buy me a coffee ☕](https://buymeacoffee.com/m0s4ik): it keeps the next one coming.

## Why this one

Built to be **as light as possible**, so that the 2 GB of RAM and the eight small Cortex-A53 cores are left to your
application:

| | |
|---|---|
| 🪶 **~190 MB of RAM** | used by the whole system, kernel included, with no application running: ~1.7 GB left for yours |
| 📦 **~220 Debian packages** | ~470 MB on disk with kernel modules and GPU drivers; the compressed image is ~185 MB |
| ⚙️ **A handful of services** | systemd, journald, udev, NetworkManager, wpa_supplicant, ssh, timesyncd, nftables, avahi (mDNS), plus the audio and light sensor setup. No desktop, no display server, no browser |
| ⏱️ **~14 s boot** | 6 s kernel and initramfs, 8 s userspace (`systemd-analyze`; 24 s before v0.4-rc2) |
| 🎮 **GPU without the weight** | Mesa built for this GPU only and without LLVM: ~22 MB instead of the ~170 MB of Debian's Mesa |
| 🧱 **Plain Debian** | apt and Debian's security updates, systemd, nothing custom to learn; the whole image comes from one script you can read |

<sub>RAM measured on our device on 2026-11-04, right after flashing v0.1, with no application running (the picture
above; v0.1 had 208 packages, before avahi). Boot time: the same device on 2026-11-11, with v0.4-rc2's kernel command
line. Packages and disk: a test build of v0.3-rc3 with the
optional layers off.</sub>

## What works

| | |
|---|---|
| 🖥️ **Display** | 800×1280 Himax panel, framebuffer `/dev/fb0`, backlight 0-4095 |
| ✋ **Touch** | Himax touchscreen (evdev) |
| 🎮 **GPU** | Adreno 506 with a reduced Mesa 26.3 (freedreno, OpenGL ES 3.1, EGL/GBM, Wayland platform, no LLVM): 60 fps with vsync |
| 🎞️ **Video decoder** | Venus hardware decoder (H.264, HEVC, VP8, VP9, MPEG-2/4) through V4L2, with a rebuilt `venus-core` module: 1080p30 H.264 with ~5% of one core |
| 🌐 **Web (optional)** | WPE WebKit 2.54 on the GPU with its sandbox, for an application that shows web pages (`WEB=1`) |
| 📡 **AirPlay runtime (optional)** | GStreamer plugins and libraries for an AirPlay receiver built on UxPlay, shipped by the application (`AIRPLAY=1`) |
| 📷 **Front camera (optional)** | Samsung S5KC505A with jethac's driver (plus flip controls) and a patched DTB: raw RAW10 frames up to 2608×1960 through V4L2, libcamera 0.7 with auto exposure and the GPU debayering, upright, ~14 fps at 2560×1600 (`CAMERA=1`, or [by hand](driver/s5kc505a/README.md#installing)) |
| 🔊 **Speaker** | TAS5782M amplifier with the out-of-tree driver, hardware volume (`Speaker Amp Master`), 16-bit playback |
| 🎙️ **Microphones** | two digital microphones, ready for wake word and speech recognition |
| 📶 **Wi-Fi** | QCA9379 (ath10k), NetworkManager profile from the build config |
| 🧭 **Sensors and keys** | BMA253 accelerometer (rotation), VCNL4200 ambient light and proximity, Vol+ / Vol− keys, camera shutter switch |
| 🔒 **Access** | ssh with keys only, nftables firewall open only to your LAN |
| 🌙 **Suspend** | `systemctl suspend`: under 0.5 W, Vol+ / Vol− or an RTC alarm wake it |
| 🚀 **Headless boot** | ready in ~14 s, survives without a keyboard (no emergency-mode dead ends) |
| 🧩 **Your app on top** | a customization hook adds your application to the image at build time |

Not yet: camera tuning. `poweroff` does not stay off with the power supply plugged in (use suspend, or `systemctl
halt` before unplugging). See [known issues](docs/known-issues.md).

## What's new in v0.4

> [!IMPORTANT]
> **Release candidate.** v0.4 adds the front camera as an option. A `CAMERA=1` image (`WEB=1 AIRPLAY=1 CAMERA=1`) of
> an earlier commit (libcamera 0.4, driver without flips) has been flashed and booted on a device: no failed units,
> the camera DTB and `cma=128M` in use, the sensor found, raw frames and libcamera at 2560×1600, boot in 13.1 s. The
> flip controls, libcamera 0.7.1 and the `dma_heap` rule were then tried by hand on that device, not yet as a flashed
> image. With `CAMERA=0` (the default) the image is the same as v0.3 (same packages and sizes on test builds) apart
> from the faster boot and the longer `/boot` timeout of rc2.

- **Faster boot, 24 s → 14 s**, on every image: `deviceinfo_no_framebuffer=true` on the kernel command line stops
  the postmarketOS initramfs from waiting 10 s for a framebuffer that cannot appear there. Nothing else in `/boot`
  changes; measured on a device with `systemd-analyze` (13.1-13.8 s, 24.2 s before)
  ([docs/boot.md](docs/boot.md#kernel-command-line)). *(rc2)*
- **Front camera** (Samsung S5KC505A): jethac's out-of-tree sensor driver and a device tree patch that turns on
  CAMSS and CCI, the camera rails and the sensor, with `rotation = <180>` (the read-out is upside down on the stand).
  Raw RAW10 frames through V4L2; libcamera's `simple` pipeline with the software ISP and auto exposure
  ([driver/s5kc505a](driver/s5kc505a/README.md)). *(rc1)*
- **`CAMERA=1`** in `config.env` (off by default): the module, the camera DTB next to the original one, `fdt` in
  `extlinux.conf` (the old file kept as `extlinux.conf.nocamera`), `v4l-utils` and libcamera, no Debian Mesa
  ([image/README.md](image/README.md#front-camera-optional)). `build.sh`, `verify.sh` and CI check both DTBs against
  `driver/s5kc505a/dtb.sha256`. *(rc1)*
- **Upright frames**: the driver gets horizontal and vertical flip controls (our change; the Bayer order follows
  them), and libcamera turns the read-out in the sensor from the DT's rotation. *(rc2)*
- **libcamera 0.7.1 from trixie-backports** instead of trixie's 0.4: debayering on the GPU, about 25 fps at 1280×960
  and 14 fps at 2560×1600 (0.4: about 10 fps on the CPU), neutral colours without tuning. `CAMERA=1` keeps the
  trixie-backports source at Debian's default priority (updates for these packages, nothing else taken from it) and
  adds `cma=128M` to the kernel command line for full size (128 MB of contiguous memory instead of 32 MB; boot time
  and free memory unchanged in practice). Raw frames at the full 2608×1960 work too
  ([driver/s5kc505a](driver/s5kc505a/README.md#libcamera)). *(rc2)*
- **Camera without root**: a udev rule gives group `video` the dma-buf heaps; a program in groups `video` and
  `render` streams (`SupplementaryGroups=video render` in its unit). *(rc2)*
- **Lens cover**: `driver/s5kc505a/lens-cover.py` prints whether the cover is open or closed
  ([driver/s5kc505a](driver/s5kc505a/README.md#lens-cover)). *(rc2)*
- **`/boot` device timeout 90 s** instead of 15 s, on every image: in one slow boot the device came up after 15 s and
  `/boot` was left unmounted ([docs/boot.md](docs/boot.md)). *(rc2)*
- **Boot report**, on every image: `thinksmart-boot-report.service` writes each boot's time, a small CPU benchmark,
  the CPU frequency and temperature to the journal in one line (`journalctl -t thinksmart-boot`); a slow boot is
  marked `SLOW` and gets the samples and CPU clock state taken while it was slow
  ([docs/boot.md](docs/boot.md#boot-report)). *(rc2)*
- **Build host tools**: `build.sh` also installs `systemd udev dmsetup nftables`, which `verify.sh` needs on the build
  machine (in a bare `debian:trixie` container they were missing and 13 checks failed for that reason only), and
  `verify.sh` stops with the names of missing tools instead. *(rc2)*
- Known: no sensor tuning (colours acceptable, not calibrated), the lens cover switch does not cut the sensor's
  power ([driver/s5kc505a](driver/s5kc505a/README.md#libcamera),
  [known issues](docs/known-issues.md#camera)).

v0.3 brought Mesa 26.3.0 in `/usr`, the optional web layer and AirPlay runtime, application firewall rules, mDNS, the
hardware video decoder and 16-bit audio ([release notes](https://github.com/m0s4ik/thinksmart-view-debian/releases/tag/v0.3)).

## Installation

> [!NOTE]
> **Requirements:** a ThinkSmart View CD-18781Y (tested on the Himax panel variant), a USB-A to USB-C cable, a
> Debian/Ubuntu machine (or VM) with root and ~20 GB free (EDL backup, image build, kernel source and Mesa build).

> [!WARNING]
> Installing rewrites the eMMC. The guide starts with a **full backup over EDL**, the only way back to the Lenovo
> firmware.

There is no ready-made image: it would contain your Wi-Fi password and ssh keys, and the kernel and firmware come from
postmarketOS and your own device. After putting the parts in `image/parts/` (kernel files, speaker driver, Mesa: see
the guide), you build it with one script:

```bash
git clone https://github.com/m0s4ik/thinksmart-view-debian.git
cd thinksmart-view-debian
cp image/config.env.example image/config.env && chmod 600 image/config.env   # Wi-Fi, ssh key, time zone, firewall
sudo ./image/build.sh image/config.env                                         # ~10 min, ends with VERIFY OK
```

The full walkthrough (backup, lk2nd, kernel files, speaker driver, Mesa, build, flashing) is in the
**[installation guide 📚](docs/install.md)**.

## Documentation

| | |
|---|---|
| [Installation guide](docs/install.md) | from a sealed device to Debian over ssh, step by step |
| [Flashing over EDL](docs/flashing.md) | backup, lk2nd, repartitioning, writing the image, going back |
| [Kernel and device files](docs/kernel.md) | where kernel, initramfs, firmware and UCM come from |
| [Boot](docs/boot.md) | image layout, system services, the headless-boot fixes |
| [Hardware](docs/hardware.md) | panel, audio, Wi-Fi, sensors, keys, camera |
| [Known issues](docs/known-issues.md) | what does not work (yet) |
| [`image/`](image/README.md) | the build script, its options (web layer, AirPlay runtime) and customization hook |
| [`driver/`](driver/) | the speaker driver ([tas5782m](driver/tas5782m/README.md)), the light sensor ([vcnl4000](driver/vcnl4000/README.md)), video decoder ([venus](driver/venus/README.md)) and front camera ([s5kc505a](driver/s5kc505a/README.md)) modules, the experimental [thinksmart-poweroff](driver/thinksmart-poweroff/README.md) |

## Roadmap

- [x] Debian 13 image on the postmarketOS 7.1.3 kernel, headless boot
- [x] Speaker, microphones, Wi-Fi, touch, accelerometer, light and proximity sensor, keys
- [x] Customization hook for applications
- [x] Hardware volume of the TAS5782M amplifier
- [x] Mesa 26.3 in `/usr` with the Wayland platform; optional web layer (WPE WebKit 2.54)
- [x] Suspend, woken by the volume keys
- [x] Hardware video decoder (Venus); optional AirPlay runtime
- [x] Mesa 26.3.0 final (v0.3)
- [ ] Fix for the freedreno GMEM loop, proposed upstream
- [ ] `poweroff` that stays off with the supply plugged in
- [x] Faster boot: no initramfs framebuffer wait, 24 s → 14 s (v0.4-rc2)
- [ ] Faster boot, the last seconds (entropy wait, `check_keys`, `msm-firmware-loader`)
- [x] Front camera (S5KC505A): raw frames and libcamera, optional (patched DTB)
- [x] Camera in the image: `CAMERA=1` (v0.4-rc1; flashed and booted with rc2)
- [x] libcamera at full size (`cma=128M`, v0.4-rc2)
- [x] Upright camera frames (sensor flips) and libcamera 0.7 on the GPU (v0.4-rc2)
- [ ] Camera sensor tuning (colours are acceptable untuned with libcamera 0.7)
- [ ] FT8201 panel variant

## Credits

This project stands on the work of others:

- **[rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart)**: the TAS5782M driver, lk2nd and bootstrap
  images, the repartitioning script, and the research that made Linux on this device practical.
- **[jethac/lenovo-thinksmart-view](https://github.com/jethac/lenovo-thinksmart-view)**: mainline work on the device,
  panel drivers and the camera (S5KC505A) analysis, driver and device tree (the driver used here with flip controls
  added, the device tree rewritten for 7.1.3).
- **[Felix Kaechele (FelixKa)](https://github.com/kaechele)**: the device's support in the kernel this image runs
  ([msm8953-mainline/linux](https://github.com/msm8953-mainline/linux)): the ThinkSmart View device tree, the
  FocalTech FT8201 touchscreen (`edt-ft5x06`) and the QCA9379 SDIO Wi-Fi (`ath10k`); the device's postmarketOS port
  and lk2nd builds ([his images](https://felix.kaechele.ca/projects/thinksmart/)), and the community work in the
  [Home Assistant forum thread](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324).
- **[msm8953-mainline](https://github.com/msm8953-mainline)**: the kernel.
- **[postmarketOS](https://postmarketos.org)**: kernel package, initramfs, firmware packaging, msm-firmware-loader,
  UCM profiles.
- **[lk2nd](https://github.com/msm8916-mainline/lk2nd)** and **[bkerler/edl](https://github.com/bkerler/edl)**.

## License

Copyright (C) 2026 Andrea Mattera.

- **GPL-3.0-or-later** for everything written for this project (`image/`, `docs/`): see [LICENSE](LICENSE). Source
  files carry an `SPDX-License-Identifier: GPL-3.0-or-later` header.
- **GPL-2.0-only** for the kernel code in [`driver/`](driver/): the TAS5782M driver, a modified copy of rickx's
  driver (changes listed in [driver/tas5782m/README.md](driver/tas5782m/README.md#changes-2026-11-03)), and its
  `install-module.sh`; `thinksmart-poweroff`; the build files and `hfi_parser.patch` of the venus and vcnl4000
  modules (they build the kernel's own sources). Like any Linux kernel module they stay under the kernel's license
  (GPL-2.0-only is not compatible with GPL-3.0). See [driver/tas5782m/LICENSE](driver/tas5782m/LICENSE).
- [`kernel/config-7.1.3-msm8953`](kernel/config-7.1.3-msm8953) is the kernel configuration of the postmarketOS
  package `linux-postmarketos-qcom-msm8953` (GPL-2.0).
- `image/rootfs/usr/local/sbin/msm-firmware-loader.sh` is an unmodified copy from postmarketOS under the MIT license.
- **Built images** also contain third-party components under their own licenses: Debian packages, Mesa (MIT and
  others), the postmarketOS kernel, initramfs, firmware and UCM profiles. The firmware is proprietary and the image
  holds your secrets (Wi-Fi password, ssh host keys): **do not redistribute built images**.

This project is not affiliated with or endorsed by Lenovo. Lenovo and ThinkSmart are trademarks of their owner.
