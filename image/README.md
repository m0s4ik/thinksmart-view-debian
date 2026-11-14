# Building the system image

`build.sh` builds the image of the ThinkSmart View's `system` partition: **Debian 13 trixie arm64, minimal**, with
the frozen postmarketOS kernel 7.1.3-msm8953, working audio (speaker and microphones), Wi-Fi and ssh. It never touches
the device; flashing is described in [docs/flashing.md](../docs/flashing.md). Your application goes on top, either
built into the image with a [customization script](#customization) or installed later over ssh.

## Requirements

- A Debian or Ubuntu machine (x86_64 or arm64; a VM or container with loop devices works), root, ~10 GB free in
  `WORK_DIR` for the build itself. The host packages `build.sh` needs (`debootstrap qemu-user-static binfmt-support
  pigz python3 fdisk e2fsprogs`, `systemd udev dmsetup nftables` for `verify.sh`, and `git` for the commit in
  `/etc/thinksmart-version`) are installed by `build.sh` if missing (`verify.sh` run on its own stops with the names
  of the tools it lacks); the build dependencies of `build-mesa.sh` and of the driver are not (install them by hand,
  see their own instructions). Without git metadata (a tarball, or a git worktree mounted in a container without its
  main repository's `.git`) the image says `repository: unknown`.
- The device files in `image/parts/` ([docs/kernel.md](../docs/kernel.md)): `boot.tar`, `modules-7.1.3-msm8953.tar`,
  `firmware.tar`, `ucm.tar` (with `fetch-parts.sh` from a device running postmarketOS 7.1.3),
  `snd-soc-tas5782m.ko` ([driver/tas5782m](../driver/tas5782m/README.md)) and
  `mesa-freedreno_<version>_arm64.deb` (with `build-mesa.sh`, dependencies at the top of the script).
  Optional: `vcnl4000.ko` ([driver/vcnl4000](../driver/vcnl4000/README.md)), `venus-core.ko`
  ([driver/venus](../driver/venus/README.md)), `q6asm.ko` + `q6asm-dai.ko` (both or neither; v0.5-rc:
  [driver/q6asm](../driver/q6asm/README.md)); for the web layer, `libwpewebkit-2.0-1_<version>_arm64.deb` (with
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
when they are in the parts, `vcnl4000`, the rebuilt `venus-core` and the rebuilt `q6asm` and `q6asm-dai`), firmware and `msm-firmware-loader`. Details in
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

**No `FD_MESA_DEBUG=sysmem` any more.** With `mesa-freedreno` 26.3.0-2 (v0.5) the web engine runs on freedreno's
normal tiled path: if a unit of yours sets `FD_MESA_DEBUG=sysmem`, remove it after updating (it only costs speed and
memory now). Measured on the device: a Home Assistant dashboard ready in ~11 s, ~450 MB, the same as with sysmem; a
1280x800 test with 4x MSAA and depth that used to hang now draws 60 frames in 0.5 s. Only images before v0.5 (`26.3.0-1` and
earlier) still need it, in the browser's own environment, never system-wide: see
[known-issues.md](../docs/known-issues.md#gpu-and-web-layer).

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
pipeline needs on this device. The speaker cannot be shared on the stock q6asm modules (no dmix; see [driver/q6asm](../driver/q6asm/README.md)), so the receiver's audio either owns the speaker
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

`CAMERA=1` in `config.env` adds the front camera. How the sensor, the driver and libcamera behave is in
[driver/s5kc505a](../driver/s5kc505a/README.md); this is what the option puts in the image:

- **Driver and DTB**: `s5kc505a.ko` in `extra/` (jethac's driver with the flip controls libcamera uses to turn the
  frame upright) and the camera DTB (`apq8053-lenovo-cd-18781y-camera.dtb`) in `/boot` **next to** the kernel
  package's DTB, which stays as it is. lk2nd reads one entry and `fdtdir` wins over `fdt`, so `extlinux.conf` gets
  `fdt /apq8053-lenovo-cd-18781y-camera.dtb` **instead of** `fdtdir /`, and `cma=128M` at the end of its `append`
  line: 128 MB of contiguous memory instead of the kernel's default 32 MB, which libcamera needs for full-size frames
  (2560×1600 fails without it; the reservation does not change boot time or, in practice, free memory). A constant in
  `build.sh` (`CAMERA_CMA`), not a setting. `/boot/extlinux/extlinux.conf.nocamera` is the file a `CAMERA=0` image
  has (`fdtdir /`, no `cma=`), to go back (`cp` it over `extlinux.conf` and reboot). `build.sh` accepts only the
  camera DTB whose sha256 is in `driver/s5kc505a/dtb.sha256`, on top of a `boot.tar` whose DTB is the one it was
  patched from: the DTB is what lk2nd boots, and a DTB that does not boot needs someone at the device.
- **libcamera 0.7.1 from trixie-backports**: `libcamera0.7`, `libcamera-ipa` (the software ISP of the `simple`
  pipeline handler, debayering on the GPU through `mesa-freedreno`) and `gstreamer1.0-libcamera` (`libcamerasrc`);
  their dependencies, `v4l-utils` and `gstreamer1.0-tools` (`gst-launch-1.0`) from trixie; no recommends, no Debian
  Mesa. trixie's own libcamera 0.4 debayers on the CPU and does not follow the sensor's flips. The image keeps
  `/etc/apt/sources.list.d/debian-backports.sources` (trixie-backports at Debian's default priority, no pin): `apt
  upgrade` updates these three packages from there and takes nothing else from it unless asked
  (`apt install <package>/trixie-backports`).
- **Without root**: `/etc/udev/rules.d/70-camera-dma-heap.rules` gives group `video` the dma-buf heaps
  (`/dev/dma_heap/*`, root only by default). A program that is not root needs groups `video` and `render` (the GPU
  debayer opens `/dev/dri/renderD128`): `SupplementaryGroups=video render` in its unit. The image adds no user to
  them.

With `CAMERA=0` the image is the same as without the option.

### Tested

On one device. A `CAMERA=1` image (`WEB=1 AIRPLAY=1 CAMERA=1`, 451 packages) of commit 3a88a34, which had jethac's
driver without flip controls and libcamera 0.4, was written to the device and booted: lk2nd booted the camera DTB, no
failed units, `CmaTotal` 131072 kB, the sensor found, a raw frame and libcamera at 2560×1600, boot 13.1 s. Everything
added after that commit (the flip controls, libcamera 0.7.1, the `dma_heap` rule, the boot report) was then installed
on that device by hand with the steps of [Upgrading without reflashing](#upgrading-without-reflashing), and works
there: upright frames, about 25 fps at 1280×960 and 14 fps at 2560×1600, a user without privileges in groups `video`
and `render` streams 2560×1600, boot about 14 s with the boot report running.
Then an image of the final code (`WEB=1 AIRPLAY=1 CAMERA=1`, 456 packages, `verify.sh` 182 ok) was written to the
same device and booted: 13.3 s, no failed units, the boot report line in the journal, upright libcamera frames from a
user without privileges in groups `video` and `render` at 1280×960 and 2560×1600 with nothing installed by hand.

Measured on test builds of v0.4 (same configuration otherwise): `CAMERA=1` adds 25 packages and 62 MB to the plain
image (218 → 243 packages, root 472 → 534 MB, `.img.gz` 183 → 202 MB): 5 for `v4l-utils`, 20 for libcamera 0.7 (with libpisp and
three Boost libraries), GStreamer's core and base library, liblttng-ust and libyuv. With `WEB=1`, which already has
GStreamer, 19 packages and 27 MB (304 → 323, 777 → 804 MB). It does not include GStreamer's plugins: `videoconvert`
(`gstreamer1.0-plugins-base`) and `videoflip` (`gstreamer1.0-plugins-good`) pull X11 libraries, cairo, PulseAudio
and more (+24 and +93 packages; no Mesa). An application that needs them installs them
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

Size and MBR; p1 features (lk2nd); `e2fsck -fn` of both partitions; UUIDs in `extlinux.conf` and `fstab`;
`deviceinfo_no_framebuffer=true` once on the `append` line (also in `extlinux.conf.nocamera`); `/boot`
with `nofail` and a 90 s device timeout; `dmsetup` and the device-mapper udev rules (`udevadm verify`); `systemd-gpt-auto-generator` disabled;
no unit requires `local-fs.target` or `/boot`; a **test device-mapper on p1** run through `udevadm test --action=add`
in a mount namespace with the image's rules and an empty `/run/udev` (it must get `/dev/disk/by-uuid/<p1>` and not
`SYSTEMD_READY=0`); the image's own `systemd-fstab-generator` (through qemu); kernel, initramfs, DTBs; `modules.dep`
(TAS5782M, ath10k, accelerometer, `q6asm-dai` with its dependencies); the q6asm modules: the kernel package's (a
`skip` line) or both rebuilt, with their vermagic and alias; firmware; UCM; enabled and masked services, the boot report (`sh -n`,
`Type=simple`); keys, Wi-Fi profile (without printing the PSK), `nft -c`; inside the image: Python with venv and the ALSA pcms `speaker` and `default`. GPU: the
`mesa-freedreno` package, libglvnd's dispatchers and Mesa's vendor file, what the package provides, libgbm's backend
path, no Debian Mesa or LLVM, `libEGL.so.1` loading Mesa through libglvnd (gbm and wayland platforms) and `ldd` of the
GL libraries through qemu. Web layer: on (WPE ≥ 2.54, bubblewrap, user namespaces in the kernel, `ldd` of WebKit's
processes) or off (no WebKit or bubblewrap). AirPlay runtime: on (its packages, the GStreamer plugins UxPlay's
pipelines use, `ldd` of libplist, `libdns_sd` and the plugins) or off (no GStreamer at all when the web layer is off
too). Front camera (found from `extlinux.conf`, the module or the camera DTB): no `fdtdir`, exactly one `fdt` naming
the camera DTB, `cma=128M` once on the `append` line and after `deviceinfo_no_framebuffer=true`, that file in `/boot`, the original DTB still there, both DTBs as pinned in
`driver/s5kc505a/dtb.sha256`, `extlinux.conf.nocamera` (with `fdtdir /` and no `cma=`), the module's vermagic, `modules.dep` and `modules.alias`,
`v4l-utils`, libcamera 0.7 from trixie-backports (not 0.4), `ipa/ipa_soft_simple.so` with its signature and
`soft_ipa_proxy`, no Debian Mesa, the trixie-backports source and no apt pin naming backports, the `dma_heap` udev
rule (`udevadm verify`), groups `video` and `render`, `ldd` of libcamera (with `libEGL.so.1` and `libGLESv2.so.2`
resolved for the GPU debayer), the IPA and the GStreamer plugin and `gst-inspect-1.0 libcamerasrc` (0.7) through
qemu; without it, `fdtdir /`, no `cma=`, no backports source or `dma_heap` rule (and no GStreamer when the web layer
and the AirPlay runtime are off too).

## After the first boot

- `ssh root@<device>`; versions in `/etc/thinksmart-version`.
- Volume at boot: `/etc/default/thinksmart-audio` (or write the percent to `/var/lib/thinksmart/volume`).
- Boot times: `journalctl -t thinksmart-boot` (one line per boot, `SLOW` ones with details; settings in
  `/etc/default/thinksmart-boot-report`, [docs/boot.md](../docs/boot.md#boot-report)).
- `apt upgrade` is fine: Debian packages do not touch `/boot` or the 7.1.3 modules.

## Upgrading without reflashing

### From v0.4 to v0.5-rc

The playback restart fixes are two kernel modules: build them
([driver/q6asm](../driver/q6asm/README.md#building), or take the CI artifact `q6asm-7.1.3-msm8953`), copy them with
`driver/q6asm/install-module.sh` to the device, run `./install-module.sh <dir>` as root, then reboot. The script keeps
the original pair; `./install-module.sh restore` and a reboot go back. Nothing in the boot path uses these modules: a
wrong one costs the sound card only, and ssh stays up.

### From v0.3 to v0.4

Every step below was done by hand on a device (the faster boot: 24.2 s → 13.8 s). On every device:

1. The longer `/boot` timeout: `sed -i 's/x-systemd.device-timeout=15/x-systemd.device-timeout=90/' /etc/fstab &&
   systemctl daemon-reload`.
2. The faster boot: `deviceinfo_no_framebuffer=true` at the end of the `append` line of `extlinux.conf`. A broken
   `append` line (a cut line, a lost UUID) means the initramfs does not find the root file system and someone has to
   recover the device over USB: p1 rewritten over EDL ([docs/flashing.md](../docs/flashing.md#seeing-why-an-image-does-not-boot)),
   or lk2nd's `fastboot boot` of a copy of the old `/boot` (copy it to another machine first; the recipe is in
   [driver/s5kc505a](../driver/s5kc505a/README.md#trying-it-without-writing-to-the-device-not-tried-yet), not tried
   on a device yet). So do not edit the file in place: write a new one, check it, then move it over the old one:

   ```sh
   cd /boot/extlinux
   grep -q deviceinfo_no_framebuffer extlinux.conf && echo "already there: stop here"
   sed '/^[[:space:]]*append /s/$/ deviceinfo_no_framebuffer=true/' extlinux.conf > extlinux.conf.new && sync
   wc -l extlinux.conf extlinux.conf.new     # the same number of lines
   diff extlinux.conf extlinux.conf.new      # exactly one changed line: the append line, now ending with the parameter
   # only if both checks are right:
   mv extlinux.conf.new extlinux.conf && sync
   ```

   After the next reboot `journalctl -b | grep -i framebuffer` shows the initramfs's `NOTE: Skipping framebuffer setup
   (deviceinfo_no_framebuffer)` instead of `ERROR: /dev/fb0 did not appear after waiting 10 seconds!`, and
   `systemd-analyze` says about 14 s. `extlinux.conf.nocamera`, if there is one, gets the same change the same way.
3. The boot report: copy, from `image/` of this repository, `rootfs/usr/local/sbin/thinksmart-boot-report` (mode 0755),
   `rootfs/etc/systemd/system/thinksmart-boot-report.service`,
   `rootfs/etc/systemd/system/thinksmart-boot-report-done.service` and `rootfs/etc/default/thinksmart-boot-report` to
   the same paths, then `systemctl daemon-reload && systemctl enable thinksmart-boot-report
   thinksmart-boot-report-done` (`systemctl start thinksmart-boot-report` reports the current boot within ten
   seconds).

For the front camera, also:

4. The module, the camera DTB, `fdt` and `cma=128M`, as in
   [driver/s5kc505a](../driver/s5kc505a/README.md#installing) (that page also says how to go back). The module is the
   CI artifact `s5kc505a-7.1.3-msm8953` or built as in [driver/s5kc505a](../driver/s5kc505a/README.md#building).
5. libcamera 0.7.1 from trixie-backports and the `dma_heap` rule:

   ```sh
   cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
   Types: deb
   URIs: http://deb.debian.org/debian
   Suites: trixie-backports
   Components: main
   Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
   EOF
   apt update
   apt install --no-install-recommends v4l-utils libcamera0.7/trixie-backports libcamera-ipa/trixie-backports \
       gstreamer1.0-libcamera/trixie-backports gstreamer1.0-tools    # read the list: no Debian Mesa, nothing removed
   echo 'SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660"' > /etc/udev/rules.d/70-camera-dma-heap.rules
   udevadm control --reload && udevadm trigger --subsystem-match=dma_heap
   ```

Then `systemctl reboot`. After it, `cat /proc/cmdline` ends with `deviceinfo_no_framebuffer=true`. With the camera
it ends with `cma=128M` after it, `grep CmaTotal /proc/meminfo` says 131072 kB, `v4l2-ctl -d <sensor subdevice> -l`
lists `horizontal_flip` and `vertical_flip`, `ls -l /dev/dma_heap` shows group `video`, and `libcamerasrc` frames are
upright. Programs that are not root: groups `video` and `render` (`SupplementaryGroups=video render` in their unit,
or `usermod -aG video,render <user>`).

### From v0.4-rc1

v0.4-rc1 was published as a pre-release with the camera driver without flip controls, trixie's libcamera 0.4 (frames
upside down), no `cma=` and none of steps 1-3. Do steps 1-3. With the camera, the DTB and `fdt` are already right (the
DTB has not changed since); stop programs that use the camera, replace the module (`install -m 644 s5kc505a.ko
/usr/lib/modules/7.1.3-msm8953/extra/s5kc505a.ko && depmod -a 7.1.3-msm8953`), add `cma=128M` at the end of the
`append` line with step 2's commands (`cma=128M` in place of `deviceinfo_no_framebuffer=true`; not in
`extlinux.conf.nocamera`), do step 5 and `apt purge libcamera0.4` if apt left it behind, then reboot.

### Older versions

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
