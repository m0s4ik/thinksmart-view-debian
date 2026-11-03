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
- No suspend.

## Screen

- `/dev/fb0` (fbdev emulation) has no vsync and no double buffering. For tear-free drawing use DRM/KMS with page
  flipping through the GPU (reduced Mesa in `/opt/mesa-freedreno`, EGL/GBM); a program must then be DRM master of
  `/dev/dri/card0` (root, or the `video` group with nobody else holding it).
- The video decoder `venus` fails to start on 7.1.3 (-5): video is decoded in software.
- Landscape orientations from the accelerometer are derived from its axes ([hardware.md](hardware.md)), not verified.

## Sensors

- Proximity always reads 0: the VCNL4200 IR LED supply (`vled`) is missing from the postmarketOS device tree, so
  the driver uses a dummy regulator. The ambient light part works ([driver/vcnl4000](../driver/vcnl4000/README.md)).

## Not done yet

- Faster boot (initramfs framebuffer wait).
- Camera ([hardware.md](hardware.md)).
- A newer kernel (the image is frozen on 7.1.3).
