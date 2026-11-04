# Known issues and open work

## Audio

- **dmix does not work** on this card: in mmap mode `hw_ptr` stays at 0 (q6asm) and `aplay` on dmix never finishes
  draining. So the speaker cannot be shared: one player at a time. Music/AirPlay alongside a voice assistant would need
  this fixed (or PipeWire, not tried).
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
- Harmless messages: `Failed to set OPP config` on cpu0, `psci: failed to set PC mode`, `venus` -5.
- **Suspend works** (`systemctl suspend`, s2idle, the only mode the kernel offers): screen off, under 0.5 W at the
  wall (a smart plug with 1 W resolution reads 0 W, against ~1 W idle with the screen on), Wi-Fi off. **Vol+ and Vol−
  wake it** within a second or two, and so does an RTC alarm (`rtcwake -m freeze -s <seconds>`); Wi-Fi reconnects by
  itself a few seconds later. Tested on 2026-11-04. Logged at suspend, harmless: ath10k `failed to install key ...
  -110` while leaving the access point.
- **`poweroff` turns the device back on** about 25 s later while the power supply is plugged in: there is no battery
  and no power button, so the PMIC takes the supply itself as a power-on event (CBLPWR_N). For "off" in daily use,
  suspend it instead (above): a volume key brings it back. To switch it off for unplugging, run `systemctl halt` (the screen goes black and nothing restarts), then unplug the supply; wait ~30 s before
  plugging it back in. An experimental module that keeps `poweroff` off is in
  [driver/thinksmart-poweroff](../driver/thinksmart-poweroff/README.md), not tested yet.
- **No battery-backed clock**: until `systemd-timesyncd` gets the time from the network, the clock starts from the
  last saved time, so the first lines of each boot in the journal can carry an old date.

## Screen

- `/dev/fb0` (fbdev emulation) has no vsync and no double buffering. For tear-free drawing use DRM/KMS with page
  flipping through the GPU (reduced Mesa in `/opt/mesa-freedreno`, EGL/GBM); a program must then be DRM master of
  `/dev/dri/card0` (root, or the `video` group with nobody else holding it).
- The video decoder `venus` fails to start on 7.1.3 (-5): video is decoded in software.
- Landscape orientations from the accelerometer are derived from its axes ([hardware.md](hardware.md)), not verified.

## Sensors

- Proximity is short-range: behind the cover glass it reads ~35 at rest, ~60-100 for a hand at 30 cm, ~100-170 at
  10 cm and over 1500 at 2-3 cm (with the settings `thinksmart-light.service` applies, see
  [driver/vcnl4000](../driver/vcnl4000/README.md)). Reliable for "a hand in front of the screen", not for "someone in
  the room". With the driver's own defaults it reads 0.

## Not done yet

- Faster boot (initramfs framebuffer wait).
- Camera ([hardware.md](hardware.md)).
- A newer kernel (the image is frozen on 7.1.3).
