# Hardware notes (Lenovo ThinkSmart View CD-18781Y)

What we found on our unit (Himax panel variant) with the postmarketOS kernel 7.1.3-msm8953.

| Part | Details | Status |
|---|---|---|
| SoC | Qualcomm APQ8053 (MSM8953 family, 8× Cortex-A53), Adreno 506 | ok |
| RAM / storage | 2 GB / eMMC 8 GB (15,269,888 sectors of 512 bytes) | ok |
| Display | **Himax HX83100A** panel, 800×1280 portrait, DT `apq8053-lenovo-cd-18781y.dtb` (`lenovo,cd-18781y-hx83100a`). Framebuffer `msmdrmfb` (DRM msm fbdev emulation): 32 bpp, B,G,R,X byte order, 3200-byte lines. Backlight `/sys/class/backlight/backlight/brightness` 0-4095 | ok (works on 6.12 and 7.1.3; one report of a black screen with 6.19 elsewhere). Units with the FocalTech FT8201 panel use a different DT compatible |
| Touch | Himax touchscreen on i2c-2, address 0x48, `/dev/input/by-path/platform-78b7000.i2c-event`, single touch `ABS_X`/`ABS_Y` 0-799 × 0-1279 | ok |
| Speaker | **TI TAS5782M** on I²C 1, address 0x49, out-of-tree driver ([driver/tas5782m](../driver/tas5782m/README.md)), DSP firmware `tas5728m_dsp_lenovo_cd-18781y.bin`. Card `cd-18781y`, playback `hw:0,0` | ok, hardware volume `Speaker Amp Master` (1 dB per step). 16-bit playback only: S24_LE plays silence, so `/etc/asound.conf` converts to S16_LE ([known-issues.md](known-issues.md)) |
| Microphones | 2 digital microphones on `hw:0,1` (2 channels), gain `TX1/TX2 Digital Volume` 115 from UCM, noise floor about -32 dBFS RMS, no clipping with speech | ok |
| Wi-Fi | **Qualcomm QCA9379** (ath10k SDIO), firmware `WLAN.NPL.1.6-00163`, board file from the firmware package | ok; a roam between access points can drop the link for ~3 s ([known-issues.md](known-issues.md)) |
| Bluetooth | Same **QCA9379** chip, on UART (`hci_uart`/`btqca`), firmware `qca/rampatch_00150100.bin` + `nvm_00150100.bin` from the firmware package. `hci0` comes up at boot (one harmless "Frame reassembly failed (-84)" while the firmware loads) | works in the kernel; `bluez` is not in the image (`apt install bluez`), not tested beyond `hci0` |
| GPU | **Adreno 506** (`msm` DRM, `/dev/dri/card0` and `renderD128`, `a530_pm4`/`a530_pfp` firmware) | **ok**: Mesa freedreno (OpenGL ES 3.1, EGL, GBM) built without LLVM by `image/build-mesa.sh` (package `mesa-freedreno`, libglvnd vendor). kmscube runs at 60 fps vsync-locked with ~5% of one core; an animated 440x760 character at 16 fps through Slint's femtovg renderer takes ~6.5% |
| Accelerometer | **Bosch BMA253** (`bmc150_accel_i2c`), `/sys/bus/iio/devices/iio:device0`, `in_accel_{x,y,z}_raw`, scale 0.019154 m/s², identity mount matrix | ok. Upright on its stand: x ≈ 0, y ≈ -9.2 m/s², z ≈ +3 (+y points down like framebuffer rows, +z out of the screen, so +x points to the panel's left). Used for screen rotation; landscape orientations are derived, not verified |
| Keys | Vol+ = `gpio-keys` (`event0`, `KEY_VOLUMEUP`), Vol− = `pm8941_resin` (`event1`, `KEY_VOLUMEDOWN`). **No power button**. The kernel does not autorepeat them | ok; both wake the device from suspend |
| Camera shutter / mic switch | camera lens cover on GPIO 87 (`SW_CAMERA_LENS_COVER`, reported by `gpio-keys`), microphone switch on GPIO 86 (switch code 4; not on every unit) | readable with `EVIOCGSW` |
| Light / proximity sensor | **Vishay VCNL4200** at 0x51 on the sensor I²C bus (`i2c-sensors`, with the accelerometer); upstream driver `vcnl4000`, IIO device named `vcnl4000`, `in_illuminance_raw` × `in_illuminance_scale` = lux | **light ok** with the out-of-tree module ([driver/vcnl4000](../driver/vcnl4000/README.md), optional part) declared at boot by `thinksmart-light.service` (no node in the postmarketOS device tree). **proximity ok** at short range (a hand within ~30 cm) with the settings applied by the same service |
| Camera | **Samsung S5KC505A** (5 MP, 2608×1960, RAW10 GRBG, 2 MIPI lanes at 480 MHz, CCI address 0x37, chip ID 0x5034 at register 0x0000, fixed focus; Lenovo's `mount-angle` 270 is relative to the portrait panel, the read-out is upright with the device on its stand). Lenovo's camera config also lists OV5693 and S5K4E8 as alternative modules | **raw frames ok, optional**: needs a patched DTB and jethac's sensor driver ([driver/s5kc505a](../driver/s5kc505a/README.md)); the kernel's own `qcom-camss` and `i2c-qcom-cci` do the rest. RAW10 through CAMSS with `v4l2-ctl` tried on 7.1.3; libcamera not tried |
| Video decoder | **Venus** (`qcom-venus`, firmware VIDEO.VE.4.2 from the `modem` partition), V4L2 `qcom-venus-decoder` / `qcom-venus-encoder` | **ok** with the rebuilt `venus-core` ([driver/venus](../driver/venus/README.md), optional part; the kernel package's one fails with -5): H.264, HEVC, VP8, VP9, MPEG-2/4 → NV12. 1080p30 H.264 at ~8× real time with ~0.5 s of CPU per 10 s of video. Draining at end of file hangs with B-frames (live streams unaffected); AirPlay screen mirroring from an iPhone decoded on it with low latency |
| USB-C | data only | no USB gadget (no network over USB) and no host mode with this kernel |
| "Headset Jack" input | reported by the sound card | not a real jack (there is none on the device): ignore it |
| Power | separate barrel power supply; USB-C for data only (no CC resistors) | |

## Camera

Works for raw frames on the 7.1.3 kernel (tried on one device, 2026-11-10): chip ID 0x5034 at 0x37, the sensor's
colour bars and a real scene at 1304×980 through CSIPHY0 → CSID0 → ISPIF0 → VFE0 RDI0 (`SGRBG10_1X10`, `pgAA` in
memory) with `media-ctl`/`v4l2-ctl`, no errors in the kernel log. Everything is in
[driver/s5kc505a](../driver/s5kc505a/README.md). What it takes:

- **Sensor driver**: jethac's `s5kc505a` (GPL-2.0, ~1,200 lines), unchanged, built out of tree with the same
  clang/KCFI recipe as the TAS5782M driver. The kernel package's `qcom-camss`, `i2c-qcom-cci`, `v4l2-cci`,
  `v4l2-fwnode` and `v4l2-async` are used as they are.
- **Device tree**: no overlays (the live DT has no `__symbols__`, and lk2nd loads a full DTB), so the DTS of
  msm8953-mainline 7.1.3 is patched and rebuilt: `camss` and `cci` enabled, two fixed regulators (VANA L17 2.85 V via
  GPIO 119, VDIG L2 **1.2 V** via GPIO 118, L2 pinned at 1.2 V), the sensor at 0x37 with MCLK0 24 MHz, reset GPIO 40,
  powerdown GPIO 39, VIO L6, `rotation = <0>`. Every value comes from the Lenovo DTB (table in the driver's README):
  a wrong VDIG can damage the sensor. The unpatched source rebuilds the device's DTB byte for byte, and the patch
  changes nothing else. Because of this patched DTB the camera is **optional** and not in the image.
- **Open**: RPM reports L2 at 1.200 V, the PMIC register at 1.175 V; libcamera (simple pipeline handler with the
  Software ISP, 0.7.1 in trixie-backports) not tried; no sensor tuning, so colours from a raw frame are only a quick
  grey-world guess.
- Realistic uses: presence detection at 1304×980 binned, snapshots on request; the lens cover (GPIO 87) does not cut
  the sensor's power, so software has to check it.

Sources: [jethac/lenovo-thinksmart-view](https://github.com/jethac/lenovo-thinksmart-view),
[rickx/ubuntu-thinksmart research/camera](https://github.com/rickx/ubuntu-thinksmart/tree/main/research/camera),
[msm8953-mainline/linux](https://github.com/msm8953-mainline/linux).
