# Building the system image

`build.sh` builds the image of the ThinkSmart View's `system` partition: **Debian 13 trixie arm64, minimal**, with
the frozen postmarketOS kernel 7.1.3-msm8953, working audio (speaker and microphones), Wi-Fi and ssh. It never touches
the device; flashing is described in [docs/flashing.md](../docs/flashing.md). Your application goes on top, either
built into the image with a [customization script](#customization) or installed later over ssh.

## Requirements

- A Debian or Ubuntu machine (x86_64 or arm64; a VM or container with loop devices works), root, ~10 GB free in
  `WORK_DIR` for the build itself. The host packages `build.sh` needs (`debootstrap qemu-user-static binfmt-support
  pigz python3 fdisk e2fsprogs`) are installed by `build.sh` if missing; the build dependencies of `build-mesa.sh`
  and of the driver are not (install them by hand, see their own instructions).
- The device files in `image/parts/` ([docs/kernel.md](../docs/kernel.md)): `boot.tar`, `modules-7.1.3-msm8953.tar`,
  `firmware.tar`, `ucm.tar` (with `fetch-parts.sh` from a device running postmarketOS 7.1.3),
  `snd-soc-tas5782m.ko` ([driver/tas5782m](../driver/tas5782m/README.md)) and
  `mesa-freedreno_<version>_arm64.deb` (with `build-mesa.sh`, dependencies at the top of the script).
  Optional: `vcnl4000.ko` ([driver/vcnl4000](../driver/vcnl4000/README.md)), `venus-core.ko`
  ([driver/venus](../driver/venus/README.md)); for the web layer, `libwpewebkit-2.0-1_<version>_arm64.deb` (with
  `build-wpe.sh`); for the front camera, `s5kc505a.ko` and `apq8053-lenovo-cd-18781y-camera.dtb`
  ([driver/s5kc505a](../driver/s5kc505a/README.md), both built by CI).

## Build

```bash
cp image/config.env.example image/config.env
chmod 600 image/config.env
$EDITOR image/config.env          # Wi-Fi, ssh key, time zone, firewall, ...
sudo ./image/build.sh image/config.env
```

About 10 minutes (apt runs under qemu). Output in `$WORK_DIR/out/`: `thinksmart-debian-YYYYMMDD.img` (sparse, 6.8 GB
apparent), `.img.gz` and `.sha256`. The chroot is rebuilt from scratch every time; `.deb` files are cached in
`$WORK_DIR/cache/`, together with the identities that stay the same across builds (partition UUIDs, `machine-id`, ssh
host keys, so your ssh client does not complain after a reflash) as long as you keep that directory.

**The image contains your Wi-Fi PSK, the root password hash and the ssh host keys**: do not share it.

| File | What it does |
|---|---|
| `build.sh` | debootstrap, packages, configuration, kernel/modules/firmware/UCM, services, optional customization, image (sfdisk, loop, mkfs, copy), `verify.sh`, compressed copy. A trap unmounts everything if it stops halfway |
| `verify.sh` | read-only checks of the finished image (see below) |
| `fetch-parts.sh` | copies kernel, initramfs, DTBs, modules, firmware and UCM from a device running postmarketOS 7.1.3 |
| `build-mesa.sh` | builds the reduced Mesa package `mesa-freedreno` (cross-compiles on x86_64; see [docs/kernel.md](../docs/kernel.md#mesa)) |
| `build-wpe.sh` | optional: backports WPE WebKit 2.54 to Debian 13 in a Docker container on a fast arm64 machine, for the web layer |
| `config.env.example` | all settings, with comments |
| `rootfs/` | files copied as they are into the image (`*.in` are templates) |

## What is in the image

Debian `minbase` with systemd, NetworkManager, OpenSSH, nftables, ALSA (with the ThinkSmart UCM profile), Python 3
with venv, DejaVu fonts, a reduced Mesa for the GPU (package `mesa-freedreno`, Mesa 26.3.0 behind Debian's
libglvnd, no LLVM: [docs/kernel.md](../docs/kernel.md#mesa)); the kernel, modules (including `snd-soc-tas5782m` and,
when they are in the parts, `vcnl4000` and the rebuilt `venus-core`), firmware and `msm-firmware-loader`. Details in
[docs/boot.md](../docs/boot.md).

- **Audio**: `thinksmart-audio.service` sets up the card at boot. `default` plays on the speaker (volume on the
  amplifier: `amixer -c 0 sset 'Speaker Amp Master' 70`, 0-85) and records from the two microphones; `aplay`/`arecord`
  work without options. Playback is converted to 16 bit (24-bit playback is silent on this card).
- **Network**: one Wi-Fi profile from `config.env`; firewall open only to `LAN_TCP_PORTS` (default 22) and mDNS from
  your LAN, plus what applications add in `/etc/nftables.d/`; `<hostname>.local` through avahi.
- **Access**: `ssh root@<device>` with your key; optional root password for a login on the screen with a USB keyboard.

## Web layer (optional)

`WEB=1` in `config.env` installs WPE WebKit 2.54 (`libwpewebkit-2.0-1_*_arm64.deb` from `PARTS_DIR`, built by
`build-wpe.sh`) and what apt pulls with it: `bubblewrap` and `xdg-dbus-proxy` for WebKit's sandbox, GStreamer, ICU,
libsoup with `glib-networking`, libglvnd's `libgl1`. It is for an application that shows web pages (a Home Assistant
dashboard, for example) through its own small WPE program; no browser, compositor or session is installed. With
`WEB=0` (the default) none of it is in the image.

Measured on test builds of v0.3-rc1 (same configuration, `du` of the root file system as `verify.sh` prints it;
v0.3-rc3 figures in the table of the next section):

| | packages | root file system | `.img.gz` |
|---|---|---|---|
| `WEB=0` | 213 | 467 MB | 182 MB |
| `WEB=1` | 299 | 772 MB | 292 MB |

WebKit itself is ~130 MB of that, ICU ~38 MB, the speech synthesizer flite (a WebKit dependency) ~27 MB. RAM depends
on the pages shown: the web engine took ~450-600 MB for a Home Assistant dashboard on the GPU in a test setup on the
device (not yet measured on this image).

The application should run the web engine with `FD_MESA_DEBUG=sysmem` in its own environment (its systemd unit), not
system-wide: see [known-issues.md](../docs/known-issues.md#gpu-and-web-layer).

## AirPlay runtime (optional)

`AIRPLAY=1` in `config.env` installs what an AirPlay receiver built on [UxPlay](https://github.com/FDH2/UxPlay) needs
at run time, all Debian binaries: GStreamer with `gstreamer1.0-plugins-base` (`appsrc`,
audio conversion), `-good` (the V4L2 decoders on the Venus hardware decoder, `capssetter`) and `-libav` (AAC and ALAC
audio), `h264parse` and `unixfdsink` from `-bad`, plus `libplist-2.0-4` and avahi's `libavahi-compat-libdnssd1`.

Debian's `gstreamer1.0-plugins-bad` is a single package whose other plugins pull GTK 3, onnxruntime, oneDNN and ~80
more packages (~210 MB). So `build.sh` installs only its library (`libgstreamer-plugins-bad1.0-0`, where the codec
parsers live) and packs the two plugins it needs, unchanged, from Debian's `.deb` of the same version into a local
package, `gstreamer1.0-plugins-bad-airplay`. It conflicts with the full package: `apt install
gstreamer1.0-plugins-bad` on the device replaces it, if an application needs more.

The receiver itself is not in the image: the application that uses it ships it (for example as its child process)
together with its firewall rules in `/etc/nftables.d/`. mDNS (avahi, UDP 5353 from the LAN) is already open in every
image, which is what the receiver needs to be found. No GStreamer GL, ALSA plugin, encoder or tools are installed.

Screen mirroring decodes H.264 on the hardware: build with `venus-core.ko` in `PARTS_DIR`
([driver/venus](../driver/venus/README.md)); see [known-issues.md](../docs/known-issues.md#video) for what the
pipeline needs on this device. The speaker cannot be shared (no dmix), so the receiver's audio either owns the speaker
or goes to the application that does.

Measured on test builds of v0.3-rc3 (same configuration):

| | packages | root file system | `.img.gz` |
|---|---|---|---|
| plain | 218 | 472 MB | 184 MB |
| `AIRPLAY=1` | 405 | 741 MB | 292 MB |
| `WEB=1 AIRPLAY=1` | 440 | 933 MB | 358 MB |

`AIRPLAY=1` adds 187 packages and ~270 MB. Most of it is `gstreamer1.0-libav`: FFmpeg's `libavcodec` and the codec
libraries Debian builds it with (~110 packages, ~170 MB, for the AAC and ALAC decoders); GStreamer's core and base
plugins are ~50 MB, the good plugins ~45 MB, the bad plugins' library ~35 MB. With Debian's whole
`gstreamer1.0-plugins-bad` it would be 486 packages and 958 MB. A GStreamer and FFmpeg built for these few elements
would be far smaller: a possible later improvement.

## Front camera (optional)

`CAMERA=1` in `config.env` installs the S5KC505A sensor driver (`s5kc505a.ko` in `extra/`), `v4l-utils` and the
libcamera userspace that was tried on a device (from Debian trixie main, without recommends: `libcamera0.4`,
`libcamera-ipa` with the software ISP of the `simple` pipeline handler, `gstreamer1.0-libcamera` for `libcamerasrc`,
`gstreamer1.0-tools` for `gst-launch-1.0`; no Debian Mesa), and puts
the camera DTB (`apq8053-lenovo-cd-18781y-camera.dtb`) in `/boot` **next to** the kernel package's DTB, which stays
as it is. lk2nd reads one entry and `fdtdir` wins over `fdt`, so `extlinux.conf` gets
`fdt /apq8053-lenovo-cd-18781y-camera.dtb` **instead of** `fdtdir /`; `/boot/extlinux/extlinux.conf.nocamera` is the
same file with `fdtdir /`, to go back (`cp` it over `extlinux.conf` and reboot). `build.sh` accepts only the camera
DTB whose sha256 is in `driver/s5kc505a/dtb.sha256`, on top of a `boot.tar` whose DTB is the one it was patched from:
the DTB is what lk2nd boots, and a DTB that does not boot needs someone at the device
([driver/s5kc505a](../driver/s5kc505a/README.md#installing)). With `CAMERA=0` the image is the same as without the
option.

Measured on test builds of v0.4-rc1 (same configuration otherwise): `CAMERA=1` adds 20 packages and 48 MB to the
plain image (218 → 238 packages, root 472 → 520 MB, `.img.gz` 183 → 199 MB): 5 for `v4l-utils`, 15 for libcamera,
GStreamer's core and base library, liblttng-ust and libyuv. With `WEB=1`, which already has GStreamer, 14 packages and
13 MB (304 → 318, 777 → 790 MB). It does not include GStreamer's plugins: `videoconvert` (`gstreamer1.0-plugins-base`) and `videoflip`
(`gstreamer1.0-plugins-good`, which turns the upside-down frame) pull X11 libraries, cairo, PulseAudio and more
(+24 and +93 packages; no Mesa). An application that needs them installs them
([driver/s5kc505a](../driver/s5kc505a/README.md#libcamera)).

## Customization

Set `CUSTOMIZE=/path/to/script.sh` in `config.env` to add an application to the image. The script is **sourced** by
`build.sh` after the system is set up, with the chroot mounted and the network available. It can use:

| Name | What |
|---|---|
| `$R` | root of the image being built |
| `in_chroot <command>` | runs a command inside the image (arm64, through qemu: slow for pip) |
| `install_file SRC DEST` | copies a file, keeping the executable bit |
| `step "title"` | prints a section title in the build log |
| `$C` | cache directory, kept between builds (downloads) |
| config variables | everything in `config.env`, including your own variables |

Example:

```bash
# my-app.sh
step "my application"
in_chroot apt-get install -y -q --no-install-recommends python3-pil
install_file my-app/app.py "$R/opt/my-app/app.py"
install_file my-app/my-app.service "$R/etc/systemd/system/my-app.service"
in_chroot systemctl enable my-app
```

`/etc/thinksmart-version` in the image records which script was used (`customization: <name>`).

## What `verify.sh` checks

Size and MBR; p1 features (lk2nd); `e2fsck -fn` of both partitions; UUIDs in `extlinux.conf` and `fstab`; `/boot`
with `nofail`; `dmsetup` and the device-mapper udev rules (`udevadm verify`); `systemd-gpt-auto-generator` disabled;
no unit requires `local-fs.target` or `/boot`; a **test device-mapper on p1** run through `udevadm test --action=add`
in a mount namespace with the image's rules and an empty `/run/udev` (it must get `/dev/disk/by-uuid/<p1>` and not
`SYSTEMD_READY=0`); the image's own `systemd-fstab-generator` (through qemu); kernel, initramfs, DTBs; `modules.dep`
(TAS5782M, ath10k, accelerometer); firmware; UCM; enabled and masked services; keys, Wi-Fi profile (without printing
the PSK), `nft -c`; inside the image: Python with venv and the ALSA pcms `speaker` and `default`. GPU: the
`mesa-freedreno` package, libglvnd's dispatchers and Mesa's vendor file, what the package provides, libgbm's backend
path, no Debian Mesa or LLVM, `libEGL.so.1` loading Mesa through libglvnd (gbm and wayland platforms) and `ldd` of the
GL libraries through qemu. Web layer: on (WPE ≥ 2.54, bubblewrap, user namespaces in the kernel, `ldd` of WebKit's
processes) or off (no WebKit or bubblewrap). AirPlay runtime: on (its packages, the GStreamer plugins UxPlay's
pipelines use, `ldd` of libplist, `libdns_sd` and the plugins) or off (no GStreamer at all when the web layer is off
too). Front camera (found from `extlinux.conf`, the module or the camera DTB): no `fdtdir`, exactly one `fdt` naming
the camera DTB, that file in `/boot`, the original DTB still there, both DTBs as pinned in
`driver/s5kc505a/dtb.sha256`, `extlinux.conf.nocamera`, the module's vermagic, `modules.dep` and `modules.alias`,
`v4l-utils`, the libcamera packages, `ipa_soft_simple.so` with its signature and `soft_ipa_proxy`, no Debian Mesa,
`ldd` of libcamera, the IPA and the GStreamer plugin and `gst-inspect-1.0 libcamerasrc` through qemu; without it,
`fdtdir /` (and no GStreamer when the web layer and the AirPlay runtime are off too).

## After the first boot

- `ssh root@<device>`; versions in `/etc/thinksmart-version`.
- Volume at boot: `/etc/default/thinksmart-audio` (or write the percent to `/var/lib/thinksmart/volume`).
- `apt upgrade` is fine: Debian packages do not touch `/boot` or the 7.1.3 modules.
- From v0.2 or earlier (Mesa in `/opt/mesa-freedreno`) to the Mesa package without reflashing (done on a device
  running v0.2: apt adds libglvnd0, libegl1, libgles2 and libwayland-client0; GPU programs then use the new Mesa
  with no other change; stop them first, restart them after): copy the `.deb` over, then
  `apt install --no-install-recommends ./mesa-freedreno_*_arm64.deb && rm -rf /opt/mesa-freedreno
  /etc/ld.so.conf.d/mesa-freedreno.conf && ldconfig`.
- From v0.3-rc2 to v0.3-rc3 without reflashing (done on a device): copy `rootfs/etc/asound.conf` to `/etc/asound.conf`
  (16-bit playback; programs that play pick it up when they reopen the pcm), and install the rebuilt `venus-core.ko`
  as in [driver/venus](../driver/venus/README.md#building). For the AirPlay runtime, `apt install
  --no-install-recommends` the packages of `AIRPLAY_PACKAGES` in `build.sh`, then the
  `gstreamer1.0-plugins-bad-airplay_*_arm64.deb` an `AIRPLAY=1` build leaves in `$WORK_DIR/out/`.
