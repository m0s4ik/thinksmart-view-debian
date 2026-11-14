# Hardware notes (Lenovo ThinkSmart View CD-18781Y)

What we found on our unit (Himax panel variant) with the postmarketOS kernel 7.1.3-msm8953. A second unit, with the
FocalTech FT8201 panel, runs the same image: [below](#the-ft8201-panel-variant).

| Part | Details | Status |
|---|---|---|
| SoC | Qualcomm APQ8053 (MSM8953 family, 8× Cortex-A53), Adreno 506 | ok |
| RAM / storage | 2 GB / eMMC 8 GB (15,269,888 sectors of 512 bytes) | ok |
| Display | **Himax HX83100A** panel, 800×1280 portrait, DT `apq8053-lenovo-cd-18781y.dtb` (`lenovo,cd-18781y-hx83100a`). Framebuffer `msmdrmfb` (DRM msm fbdev emulation): 32 bpp, B,G,R,X byte order, 3200-byte lines. Backlight `/sys/class/backlight/backlight/brightness` 0-4095 | ok (works on 6.12 and 7.1.3; one report of a black screen with 6.19 elsewhere). Units with the FocalTech FT8201 panel get `lenovo,cd-18781y-ft8201` from lk2nd: [below](#the-ft8201-panel-variant) |
| Touch | Himax touchscreen on i2c-2, address 0x48, `/dev/input/by-path/platform-78b7000.i2c-event`, single touch `ABS_X`/`ABS_Y` 0-799 × 0-1279 (FT8201 units: multi-touch, [below](#the-ft8201-panel-variant)) | ok |
| Speaker | **TI TAS5782M** on I²C 1, address 0x49, out-of-tree driver ([driver/tas5782m](../driver/tas5782m/README.md)), DSP firmware `tas5728m_dsp_lenovo_cd-18781y.bin`. Card `cd-18781y`, playback `hw:0,0` | ok, hardware volume `Speaker Amp Master` (1 dB per step). 16-bit playback only: S24_LE plays silence, so `/etc/asound.conf` converts to S16_LE ([known-issues.md](known-issues.md)) |
| Microphones | 2 digital microphones on `hw:0,1` (2 channels), gain `TX1/TX2 Digital Volume` 115 from UCM, noise floor about -32 dBFS RMS, no clipping with speech | ok |
| Wi-Fi | **Qualcomm QCA9379** (ath10k SDIO), firmware `WLAN.NPL.1.6-00163`, board file from the firmware package | ok; a roam between access points can drop the link for ~3 s ([known-issues.md](known-issues.md)) |
| Bluetooth | Same **QCA9379** chip, on UART (`hci_uart`/`btqca`), firmware `qca/rampatch_00150100.bin` + `nvm_00150100.bin` from the firmware package. `hci0` comes up at boot (one harmless "Frame reassembly failed (-84)" while the firmware loads) | works in the kernel; `bluez` is not in the image (`apt install bluez`), not tested beyond `hci0` |
| GPU | **Adreno 506** (`msm` DRM, `/dev/dri/card0` and `renderD128`, `a530_pm4`/`a530_pfp` firmware) | **ok**: Mesa freedreno (OpenGL ES 3.1, EGL, GBM) built without LLVM by `image/build-mesa.sh` (package `mesa-freedreno`, libglvnd vendor). kmscube runs at 60 fps vsync-locked with ~5% of one core; an animated 440x760 character at 16 fps through Slint's femtovg renderer takes ~6.5% |
| Accelerometer | **Bosch BMA253** (`bmc150_accel_i2c`), `/sys/bus/iio/devices/iio:device0`, `in_accel_{x,y,z}_raw`, scale 0.019154 m/s², identity mount matrix | ok. Upright on its stand: x ≈ 0, y ≈ -9.2 m/s², z ≈ +3 (+y points down like framebuffer rows, +z out of the screen, so +x points to the panel's left). Used for screen rotation; landscape orientations are derived, not verified |
| Keys | Vol+ = `gpio-keys` (`event0`, `KEY_VOLUMEUP`), Vol− = `pm8941_resin` (`event1`, `KEY_VOLUMEDOWN`). **No power button**. The kernel does not autorepeat them | ok; both wake the device from suspend |
| Camera shutter / mic switch | camera lens cover on GPIO 87 (`SW_CAMERA_LENS_COVER`, reported by `gpio-keys`), microphone switch on GPIO 86 (switch code 4, `SW_MICROPHONE_INSERT`, on the same input device; not on every unit) | readable with `EVIOCGSW` (both read on one device) |
| Light / proximity sensor | **Vishay VCNL4200** at 0x51 on the sensor I²C bus (`i2c-sensors`, with the accelerometer); upstream driver `vcnl4000`, IIO device named `vcnl4000`, `in_illuminance_raw` × `in_illuminance_scale` = lux | **light ok** with the out-of-tree module ([driver/vcnl4000](../driver/vcnl4000/README.md), optional part) declared at boot by `thinksmart-light.service` (no node in the postmarketOS device tree). **proximity ok** at short range (a hand within ~30 cm) with the settings applied by the same service |
| Camera | **Samsung S5KC505A** (5 MP, 2608×1960, RAW10 GRBG, 2 MIPI lanes at 480 MHz, CCI address 0x37, chip ID 0x5034 at register 0x0000, fixed focus; Lenovo's `mount-angle` 270 is relative to the portrait panel, the read-out is upside down with the device on its stand: DT `rotation` 180). Lenovo's camera config also lists OV5693 and S5K4E8 as alternative modules | **raw frames ok, optional**: needs a patched DTB and jethac's sensor driver with our flip controls ([driver/s5kc505a](../driver/s5kc505a/README.md)); the kernel's own `qcom-camss` and `i2c-qcom-cci` do the rest. RAW10 through CAMSS with `v4l2-ctl` tried on 7.1.3; libcamera 0.7.1 (trixie-backports) streams upright frames, debayered on the GPU: about 14 fps at 2560×1600 with `cma=128M`, 25 fps at 1280×960 (also with the default CMA) |
| Video decoder | **Venus** (`qcom-venus`, firmware VIDEO.VE.4.2 from the `modem` partition), V4L2 `qcom-venus-decoder` / `qcom-venus-encoder` | **ok** with the rebuilt `venus-core` ([driver/venus](../driver/venus/README.md), optional part; the kernel package's one fails with -5): H.264, HEVC, VP8, VP9, MPEG-2/4 → NV12. 1080p30 H.264 at ~8× real time with ~0.5 s of CPU per 10 s of video. Draining at end of file hangs with B-frames (live streams unaffected); AirPlay screen mirroring from an iPhone decoded on it with low latency |
| USB-C | data only | no USB gadget (no network over USB) and no host mode with this kernel |
| "Headset Jack" input | reported by the sound card | not a real jack (there is none on the device): ignore it |
| Power | separate barrel power supply; USB-C for data only (no CC resistors) | |

## The FT8201 panel variant

Some units have a **FocalTech FT8201** panel instead of the Himax one: display and touch controller in one chip
(TDDI). Under Android: `panel_name=boyift8201 800p video mode dsi panel` in `/sys/class/graphics/fb0/msm_fb_panel_info`
and the touch input device `fts_ts` (stock firmware, [#4](https://github.com/m0s4ik/thinksmart-view-debian/issues/4));
with root, `mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_boyift8201_800p_video:…` in `/proc/cmdline` (LineageOS). Himax
units say `hx83100a` instead.

Nothing in the image changes: lk2nd reads the panel from the stock bootloader and patches the same
`apq8053-lenovo-cd-18781y.dtb` (panel `lenovo,cd-18781y-ft8201`, the FT8201 touch node enabled instead of the Himax
one), and the 7.1.3 kernel package has both panel drivers. Two FT8201 units run the v0.4 image with the steps of
[install.md](install.md) unchanged: the one in [#4](https://github.com/m0s4ik/thinksmart-view-debian/issues/4) (plain
image, `CAMERA=0`) and one with `WEB=1 AIRPLAY=1` and m0s4ik/home-companion 0.2.0 (built from `0b481a3`, rickx's
prebuilt lk2nd `20.0-next-b9c007bb5492-20250123`), where this was found:

| Part | FT8201 unit | Status |
|---|---|---|
| Display | module `panel_lenovo_cd_18781y_ft8201`, same framebuffer and backlight (`/sys/class/backlight/backlight`, 0-4095) | ok on the bootstrap's 6.12, after its upgrade to 7.1.3 and in the Debian image |
| Touch | `generic ft5x06 (09)` (`edt_ft5x06`) on i2c-2, address 0x38, same `/dev/input/by-path/platform-78b7000.i2c-event`; **multi-touch**, 10 slots, `ABS_MT_POSITION_X`/`_Y` 0-799 × 0-1279 (also `ABS_X`/`ABS_Y`) | ok |
| Wi-Fi, audio | `nmcli` state 100 (connected), card `cd-18781y` | ok |
| Web layer, AirPlay | home-companion's Home Assistant view (WPE WebKit): 50-60 fps, `WPEWebProcess` ~390 MB + `WPENetworkProcess` ~85 MB RSS; screen mirroring from a phone over AirPlay, picture and sound | ok |

Seen in the kernel log while the panel driver probes (the panel works anyway; not compared with a Himax unit): on 7.1.3
`WARNING: drivers/clk/qcom/clk-rcg2.c:136 at update_config` with `boyift8201_800p_probe` in the trace (twice); on the
bootstrap's 6.12 `Unbalanced enable for IRQ 31` from `wled_ovp_work`.

Not tested: whether touch keeps working after the panel is blanked. The FT8201 shares its reset between display and
touch, and community kernels for this device patch the panel driver so that blanking does not stop the touch
controller; 7.1.3 does not have that patch. Dimming the backlight (`brightness` 0) is not blanking.

## Camera

Works on the 7.1.3 kernel (one device, installed by hand and as a written `CAMERA=1` image: what was tested how is in
[image/README.md](../image/README.md#tested); the modules load at boot through udev and the boot time does not change): chip
ID 0x5034 at 0x37, the sensor's colour bars and a real scene at 1304×980 through CSIPHY0 → CSID0 → ISPIF0 → VFE0
RDI0 (`SGRBG10_1X10`, `pgAA` in memory; `SGBRG10_1X10`, `pGAA` with both flips) with `media-ctl`/`v4l2-ctl`, no errors in the kernel log. Everything is in
[driver/s5kc505a](../driver/s5kc505a/README.md). What it takes:

- **Sensor driver**: jethac's `s5kc505a` (GPL-2.0, ~1,200 lines) with horizontal and vertical flip controls added
  here (the Bayer order follows them), built out of tree with the same clang/KCFI recipe as the TAS5782M driver. The kernel package's `qcom-camss`, `i2c-qcom-cci`, `v4l2-cci`,
  `v4l2-fwnode` and `v4l2-async` are used as they are.
- **Device tree**: no overlays (the live DT has no `__symbols__`, and lk2nd loads a full DTB), so the DTS of
  msm8953-mainline 7.1.3 is patched and rebuilt: `camss` and `cci` enabled, two fixed regulators (VANA L17 2.85 V via
  GPIO 119, VDIG L2 **1.2 V** via GPIO 118, L2 pinned at 1.2 V), the sensor at 0x37 with MCLK0 24 MHz, reset GPIO 40,
  powerdown GPIO 39, VIO L6, `rotation = <180>`. Every value comes from the Lenovo DTB (table in the driver's README):
  a wrong VDIG can damage the sensor. The unpatched source rebuilds the device's DTB byte for byte, and the patch
  changes nothing else. Because of this patched DTB the camera is **optional**: `CAMERA=1` in the build config.
- **libcamera**: 0.7.1 of trixie-backports (simple pipeline handler, software ISP on the GPU through EGL) streams
  through `libcamerasrc` with auto exposure and sets the sensor's flips from the DT's `rotation = <180>`, so frames
  are upright: 2560×1600 (its default) at about 14 fps with `cma=128M` on the kernel command line (`CAMERA=1` adds
  it), 1280×960 at about 25 fps also with the default 32 MB CMA. Without root: groups `video` (with the image's
  `dma_heap` udev rule) and `render`. Details, and why not trixie's own 0.4, in the
  [driver README](../driver/s5kc505a/README.md#libcamera).
- **Open**: no sensor tuning (raw: grey world; libcamera: `uncalibrated.yaml`, colours acceptable). One slow boot
  (85 s) came once after the first camera session; its logs point to the CPU clock, not to the camera
  ([known-issues.md](known-issues.md#boot)).
- **VDIG rail**: RPM reports L2 at 1.200 V, the SPMI view of the same LDO 1.175 V; most likely a decoding difference
  of one 25 mV step, not a low rail ([driver README](../driver/s5kc505a/README.md#electrical-values)).
- Realistic uses: presence detection at 1304×980 binned, snapshots on request; the lens cover (GPIO 87) does not cut
  the sensor's power, so software has to check it (`driver/s5kc505a/lens-cover.py`, [driver README](../driver/s5kc505a/README.md#lens-cover)).

Sources: [jethac/lenovo-thinksmart-view](https://github.com/jethac/lenovo-thinksmart-view),
[rickx/ubuntu-thinksmart research/camera](https://github.com/rickx/ubuntu-thinksmart/tree/main/research/camera),
[msm8953-mainline/linux](https://github.com/msm8953-mainline/linux).
