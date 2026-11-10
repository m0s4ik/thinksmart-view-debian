# Known issues and open work

## Audio

- **dmix does not work** on this card: in mmap mode `hw_ptr` stays at 0 (q6asm) and `aplay` on dmix never finishes
  draining. So the speaker cannot be shared: one program plays at a time. An application that needs several sounds at
  once (music, a voice, alerts) mixes them itself and owns the pcm; an AirPlay receiver can hand its decoded audio to
  that application instead of opening the card (UxPlay's audio sink is a GStreamer pipeline). PipeWire: not tried.
- **24-bit playback is silent**: the card offers S16_LE and S24_LE, but with S24_LE the speaker plays nothing (no error).
  Anything decoded to 32 bit (GStreamer's `avdec_*`, ffmpeg) was converted to S24_LE by the plug and came out silent.
  Since v0.3-rc3 `/etc/asound.conf` converts everything going through `speaker` (and `default`) to S16_LE
  (`speaker_hw`); programs that open `hw:0,0` directly must use S16_LE. Where the 24-bit path breaks (q6asm, the DSP or
  the amplifier's 32-bit I2S word) is not known yet.
- **Amplifier power-up**: after a stream the amplifier is muted and goes to standby `standby_ms` later (default 3 s,
  see [driver/tas5782m/README.md](../driver/tas5782m/README.md)). The first sound after standby still needs ~0.5 s for
  the DSP firmware to load, which swallows short sounds: start them with ~600 ms of silence, raise `standby_ms`, or keep
  the pcm open. Sounds within `standby_ms` of the previous one start at once.

## Wi-Fi

- **ath10k key install timeouts**: rickx reports drops on every group key renewal without his ath10k patch. On our
  device it did not happen: about 11 hours of persistent journal show no drop on a key renewal. The one drop seen was
  a roam between two access points: `failed to install key ... -110` while leaving the old one, then a reconnect within
  about 3 s. The patch (report success when the key install times out) would not prevent that and could leave the
  link silently broken if it fired on a new association, so it is **not used**. If drops on key renewal ever show up
  (`failed to install key` followed by `deauthenticating` with no roam), a patch limited to the group key and to
  -ETIMEDOUT can be built with the clang recipe of the TAS5782M driver.

## Boot

- **10 s lost in the initramfs**: the postmarketOS initramfs waits up to 10 s for `/dev/fb0`, but the panel module is
  not in it. Possible fix without touching the original file: append a second cpio archive to `/boot/initramfs` with
  `etc/deviceinfo` containing `deviceinfo_no_framebuffer="true"` (the kernel reads concatenated archives in order).
  Untested; a broken initramfs needs EDL to recover.
- lk2nd supports a **single entry** in `extlinux.conf`.
- Harmless messages: `Failed to set OPP config` on cpu0, `psci: failed to set PC mode`.
- **Suspend works** (`systemctl suspend`, s2idle, the only mode the kernel offers): screen off, under 0.5 W at the
  wall (a smart plug with 1 W resolution reads 0 W, against ~1 W idle with the screen on), Wi-Fi off. **Vol+ and Vol−
  wake it** within a second or two, and so does an RTC alarm (`rtcwake -m freeze -s <seconds>`); Wi-Fi reconnects by
  itself a few seconds later. Tested on 2026-11-04. Logged at suspend, harmless: ath10k `failed to install key ...
  -110` while leaving the access point.
- **`poweroff` turns the device back on** about 25 s later while the power supply is plugged in: there is no battery
  and no power button, so the PMIC takes the supply itself as a power-on event (CBLPWR_N). For "off" in daily use,
  suspend it instead (above): a volume key brings it back. To switch it off for unplugging, run `systemctl halt`
  (the screen goes black and nothing restarts), then unplug the supply; wait ~30 s before plugging it back in. An experimental module that keeps `poweroff` off is in
  [driver/thinksmart-poweroff](../driver/thinksmart-poweroff/README.md), not tested yet.
- **No battery-backed clock**: until `systemd-timesyncd` gets the time from the network, the clock starts from the
  last saved time, so the first lines of each boot in the journal can carry an old date.

## Screen

- `/dev/fb0` (fbdev emulation) has no vsync and no double buffering. For tear-free drawing use DRM/KMS with page
  flipping through the GPU (the reduced Mesa, EGL/GBM); a program must then be DRM master of `/dev/dri/card0` (root,
  or the `video` group with nobody else holding it).
- Landscape orientations from the accelerometer are derived from its axes ([hardware.md](hardware.md)), not verified.

## GPU and web layer

- **freedreno loops forever on some browser render targets** (Adreno 5xx, GMEM tiling): `layout_gmem()` /
  `calc_nbins()` in `src/gallium/drivers/freedreno/freedreno_gmem.c` keeps adding bins while a bin does not fit in
  the 136 KiB of GMEM, and when even the smallest aligned bin does not fit the loop never ends. The thread spins at
  100 %, the page hangs. Seen with WebKit's GPU 2D canvas, WebGL and, with WPE 2.54, some ordinary Home Assistant
  dashboards; same in Mesa 25.0.7, 26.3.0-rc3 and 26.3.0. Programs with simple surfaces (a Slint or femtovg UI, a compositor)
  do not hit it. **Workaround**: `FD_MESA_DEBUG=sysmem` (render straight to memory, no tiling) **in the browser's
  environment only**, e.g. `Environment=FD_MESA_DEBUG=sysmem` in the browser's systemd unit: then the canvas and
  WebGL work on the GPU. Do not set it system-wide (`/etc/environment`): every other GL program would lose tiling
  for nothing. A real fix (fall back to sysmem only for the batch that does not fit) is to be proposed to Mesa.
- **Debian's Mesa replaces ours if a package asks for it**: `mesa-freedreno` provides `libgbm1` and `libegl-mesa0`
  and conflicts with Debian's Mesa, so apt never installs both; but a package that needs Debian's exact versions
  (`libgbm-dev`, pulled by many `-dev` packages) makes apt propose removing `mesa-freedreno` and installing Debian's
  Mesa 25 with LLVM. Seen on a device while installing build dependencies. Check apt's list of removals, and build
  software for the device elsewhere; to go back, `apt install --no-install-recommends ./mesa-freedreno_*_arm64.deb`.
- **WPE WebKit 2.48** (Debian 13's own) cannot use Mesa 26 (`egl: failed to create dri2 screen`): the web layer
  uses our 2.54 backport (`image/build-wpe.sh`).
- **WebKit's sandbox does not see `/opt`**: Mesa and anything the web process loads must live under `/usr`; that is
  why the image installs Mesa as a package in `/usr/lib/aarch64-linux-gnu` since v0.3.

## Video

- The video decoder `venus` of the 7.1.3 kernel package fails to start (-5, `Unsupported property: 0`): since v0.3-rc3
  the image replaces `venus-core` with the module of [driver/venus](../driver/venus/README.md) (optional part, without
  it there is no hardware decoder). With it, a stream with B-frames decodes but the drain at end of file hangs: give
  file playback a timeout. Live streams (AirPlay screen mirroring from an iPhone, tested) are not affected.
- The decoder rejects H.264 streams whose caps declare the sRGB transfer function (`not-negotiated`), which iPhones
  do when mirroring: override the colorimetry before the decoder, e.g. `h264parse ! capssetter
  caps="video/x-h264,colorimetry=(string)1:3:5:1" ! v4l2h264dec`.
- Decoded frames live in memory the CPU reads slowly: scaling or rotating them on the CPU (`videoflip`, `kmssink`)
  gives 5-8 fps at 1080p. Import them into the GPU instead (`glupload` of the dmabuf, `glvideoflip`, `glimagesink`):
  smooth playback. That takes GStreamer's GL plugins (`gstreamer1.0-gl`, not part of `AIRPLAY=1`) or an application
  that imports the dmabuf itself.
- GStreamer's GL elements on GBM pick a 10-10-10-2 EGL config by default, which turns the colours of an 8-bit
  (AR24) scanout buffer into noise: set `GST_GL_CONFIG=gst-gl-context-config,red-size=(int)8,green-size=(int)8,blue-size=(int)8,alpha-size=(int)8`
  (with `GST_GL_WINDOW=gbm GST_GL_PLATFORM=egl GST_GL_API=gles2`).

## Sensors

- Proximity is short-range: behind the cover glass it reads ~35 at rest, ~60-100 for a hand at 30 cm, ~100-170 at
  10 cm and over 1500 at 2-3 cm (with the settings `thinksmart-light.service` applies, see
  [driver/vcnl4000](../driver/vcnl4000/README.md)). Reliable for "a hand in front of the screen", not for "someone in
  the room". With the driver's own defaults it reads 0.

## Not done yet

- Faster boot (initramfs framebuffer wait).
- Camera ([hardware.md](hardware.md)).
- A newer kernel (the image is frozen on 7.1.3).
