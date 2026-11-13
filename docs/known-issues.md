# Known issues and open work

## Audio

- **dmix** works only with the rebuilt q6asm modules ([driver/q6asm](../driver/q6asm/README.md), v0.5-rc): on the
  stock ones `hw_ptr` stays at 0 and `aplay` on dmix never finishes draining, so one program plays at a time.
  `/etc/asound.conf` still opens the card directly (`speaker`, `default`): an application that needs several sounds
  at once mixes them itself and owns the pcm, or uses a `dmix` pcm of its own. PipeWire: not tried.
- **24-bit playback is silent**: the card offers S16_LE and S24_LE, but with S24_LE the speaker plays nothing (no error).
  Anything decoded to 32 bit (GStreamer's `avdec_*`, ffmpeg) was converted to S24_LE by the plug and came out silent.
  Since v0.3-rc3 `/etc/asound.conf` converts everything going through `speaker` (and `default`) to S16_LE
  (`speaker_hw`); programs that open `hw:0,0` directly must use S16_LE. Where the 24-bit path breaks (q6asm, the DSP or
  the amplifier's 32-bit I2S word) is not known yet; driver/q6asm does not change formats.
- **Amplifier power-up**: after a stream the amplifier is muted and goes to standby `standby_ms` later (default 3 s,
  see [driver/tas5782m/README.md](../driver/tas5782m/README.md)). The first sound after standby still needs ~0.5 s for
  the DSP firmware to load, which swallows short sounds: start them with ~600 ms of silence, raise `standby_ms`, or keep
  the pcm open. Sounds within `standby_ms` of the previous one start at once.
- **Playback does not restart after a stop or an underrun** (stock q6asm modules): after `snd_pcm_drop()` or an
  underrun followed by `snd_pcm_prepare()`, playback does not restart (nothing reaches the DSP) or the driver sends
  bogus buffers, depending on the period size; an underrun itself is never detected, and drain ends only on its
  timeout. A fix is in [driver/q6asm](../driver/q6asm/README.md): the two modules rebuilt with four patches,
  optional, v0.5-rc, tested on a device. Without them: keep the pcm open and fed (silence when there is nothing to
  play), or close and reopen it instead of dropping and preparing.

## Wi-Fi

- **ath10k key install timeouts**: rickx reports drops on every group key renewal without his ath10k patch. On our
  device it did not happen: about 11 hours of persistent journal show no drop on a key renewal. The one drop seen was
  a roam between two access points: `failed to install key ... -110` while leaving the old one, then a reconnect within
  about 3 s. The patch (report success when the key install times out) would not prevent that and could leave the
  link silently broken if it fired on a new association, so it is **not used**. If drops on key renewal ever show up
  (`failed to install key` followed by `deauthenticating` with no roam), a patch limited to the group key and to
  -ETIMEDOUT can be built with the clang recipe of the TAS5782M driver.
- **Fast roaming (802.11r, FT-PSK): associated but no traffic**: reported in
  [issue #2](https://github.com/m0s4ik/thinksmart-view-debian/issues/2), not reproduced on our device. During an FT
  transition between two access points ath10k logs `failed to install key ... -110`, `failed to remove key ... from
  hardware (-110)` and `Got RX ind from invalid peer`; the reassociation succeeds and wpa_supplicant reports
  `COMPLETED`, but no IP traffic passes until the connection is brought up again (`nmcli connection up <name>`). The
  timeout comes from the QCA9379 firmware not answering the key removal in time, so a real fix belongs upstream in
  ath10k. Workarounds for a device that stays on a desk: use the network without FT (plain WPA-PSK), so that a
  transition is a normal reconnection, or reconnect when the interface is associated but the gateway does not answer.

## Boot

- **Boot time**: about 14 s (`systemd-analyze`). Up to v0.3 the postmarketOS initramfs lost 10 s waiting for
  `/dev/fb0`, which cannot appear there (no modules in it); since v0.4 `deviceinfo_no_framebuffer=true` on the
  kernel command line skips the wait, with no change to the initramfs ([boot.md](boot.md#kernel-command-line)). The
  largest pieces left are in files the image takes as they are: ~2 s before the initramfs's udev starts (it ends at
  `random: crng init done`), `check_keys` (~1 s, a `sleep 1`), the sub-partition mapping (~1 s), and
  `msm-firmware-loader.service` (2.5 s, ordered before udev, so hardware probing waits for it). Not planned yet;
  timeline in [boot.md](boot.md#boot-time).
- **Open: one slow boot (85 s), seen once and not reproduced** (about ten boots since the framebuffer-wait fix, all
  13.1-14.1 s). Compared with the journals of normal boots (kernel timestamps), it is identical up to ~0.95 s; from
  there the CPU was slow: steps bound by the CPU took 18-27 times longer, those bound by I/O ~1.5 times, and only in
  that boot systemd logged more than a second of CPU time for trivial units (`modprobe@configfs.service: Consumed
  1.296s CPU time`). 8 CPUs online, as in the other boots; no thermal or throttling messages (temperatures were not
  logged then). In that boot `cpufreq-dt` came online (0.952 s) before the late initcalls `clk: Disabling unused
  clocks` and `PM: genpd: Disabling unused power domains` (1.008 s); most boots have the other order (unused clocks
  off at ~0.87 s, cpufreq at 0.96-0.98 s), but the boot report has since seen the slow boot's order in roughly one
  boot in four or five without a slow boot (cpufreq 1.0019 s, unused clocks off 1.0082 s, boot 13.4 s): the order is
  not sufficient. Speed came back abruptly at 81.555 s, at `remoteproc0: adsp is available`; nothing in the log says
  what changed. Most likely a probe-order race between cpufreq-dt/CPR and the clean-up of unused clocks and power
  domains that left the CPUs clocked from a slow source: not proven. Not related, as far as the logs show: the camera
  DTB's `rotation`, `kernel.panic` set at run time, `modprobe -i`. It came right after the first camera session
  (captures, then a warm reboot), which cannot be excluded, but two reboots after captures were normal. Side effect:
  the `/boot` device came up after the 15 s `x-systemd.device-timeout` of fstab and `/boot` was not mounted
  (`systemctl start boot.mount` mounts it once the device is there); since v0.4 the timeout is 90 s (on an older
  device edit `/etc/fstab` as in [image/README.md](../image/README.md#upgrading-without-reflashing)).
  **If it happens again**, the boot report has recorded it: `journalctl -t thinksmart-boot -p warning` lists the
  `SLOW` boots, each followed by the samples taken while it was slow, the CPU clock state and the order of the two
  kernel messages ([boot.md](boot.md#boot-report)). Keep that journal (it is on disk).
- lk2nd supports a **single entry** in `extlinux.conf`.
- **Volume Up at power-on is not a rescue path**: with a rescue boot image written to the `recovery` partition,
  holding Volume Up at power-on did not boot it (tried once on one device, 2026-11-11: black screen, no Linux; cause
  unknown). EDL ([flashing.md](flashing.md#going-back)) is the tested way back; lk2nd's fastboot (`fastboot boot`) is
  not tried yet.
- `kernel.panic` is 0 and there is no watchdog device: after a kernel panic the device stays stopped until the power
  is cut.
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

## Camera

- The camera does not change boot time: about 14 s with it as without it (13.1 s on the first boot of a written
  `CAMERA=1` image). The one slow boot seen after the first camera session points to the CPU clock, not to the
  camera: see [Boot](#boot).
- No sensor tuning: libcamera 0.7.1 falls back to `uncalibrated.yaml` and warns about missing sensor properties and
  helper; colours are acceptable (neutral on a white-ish scene), not calibrated.
- The GPU debayer leaves a one-pixel border in the wrong colour (first row, first and last column): crop it if it
  matters.
- The sensor's flips change the Bayer order and keep the value the last program set (libcamera sets both): a raw
  capture sets them first ([driver/s5kc505a](../driver/s5kc505a/README.md#capturing-a-raw-frame)). They cannot change
  while streaming. trixie's own libcamera 0.4 does not follow the changing Bayer order (expected to fail at stream
  start with this driver, from its code, not tried): use 0.7 from trixie-backports, as `CAMERA=1` does.
- With libcamera 0.7.1, `multifilesink` wrote no file (no error, not investigated); `filesink` works.
- The lens cover does not cut the sensor's power: software reads the switch before capturing
  ([lens cover](../driver/s5kc505a/README.md#lens-cover)).

## Not done yet

- The last seconds of boot time (entropy wait, `check_keys`, sub-partition mapping, `msm-firmware-loader`): they need
  changes to the initramfs or to the firmware loader ([Boot](#boot)).
- Camera sensor tuning ([Camera](#camera)).
- A newer kernel (the image is frozen on 7.1.3).
