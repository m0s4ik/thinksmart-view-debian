# S5KC505A front camera (driver + device tree)

**Status: raw frames work on the 7.1.3 kernel of this system** (one device, 2026-11-10): installed as below (module
in `extra/`, camera DTB next to the original, `fdt` in `extlinux.conf`), udev loads `i2c-qcom-cci`, `s5kc505a` and
`qcom-camss` at boot, the sensor answers with chip ID 0x5034, test pattern and real scene captured through CAMSS with
`v4l2-ctl`, no errors in the kernel log. Boot time unchanged (24.2 s); one isolated slow boot is still unexplained
([known-issues.md](../../docs/known-issues.md#camera)). libcamera 0.4 of Debian trixie streams 1280x960 with auto
exposure ([below](#libcamera)); full size fails on CMA. The read-out is upside down, so the DT now says
`rotation = <180>` (every frame so far was taken with 0): that DTB has not been booted on a device yet. The camera needs a patched DTB,
so it is optional: `CAMERA=1` in `image/config.env` builds it into the image ([image/README.md](../../image/README.md#front-camera-optional);
not flashed on a device yet), or install it by hand as below.

The ThinkSmart View's front camera is a Samsung **S5KC505A** (5 Mpixel, RAW10 GRBG, 2 CSI-2 lanes at 480 MHz, 24 MHz
MCLK) on the camera I²C controller (CCI) of the SoC. Two pieces are needed on top of the frozen 7.1.3 kernel:

| File | What |
|---|---|
| `s5kc505a.c`, `Makefile` | the sensor driver, built out of tree into `s5kc505a.ko` |
| `cd-18781y-front-camera.patch` | patch for `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` of msm8953-mainline `v7.1.3-r0`: enables `camss` and `cci`, adds the camera rails and the sensor node |
| `samsung,s5kc505a.yaml` | the device tree binding (only for `dtbs_check`) |
| `dtb.sha256` | sha256 of the kernel package's DTB (rebuilt from the unpatched source) and of the camera DTB: CI checks both builds against it, `image/build.sh` and `verify.sh` the files they install |
| `make-test-bootimg.sh` | builds an Android boot image for a one-off `fastboot boot` from lk2nd with a different DTB, to try the device tree without writing to the device |
| `raw10-to-png.py` | turns one raw frame into a PNG (standard library only, runs on the device) |

The kernel's own `qcom-camss`, `i2c-qcom-cci`, `v4l2-cci`, `v4l2-fwnode` and `v4l2-async` modules are used as they
are; only the DTB changes and one module is added.

## Electrical values

Taken from the Lenovo DTB (`qcom,camera@0` in the "APQ8053 Lite DragonBoard V2.0" DTB appended to the stock boot
image, `qcom,board-id = <0x1010520 0>` like this device), and checked against jethac's and rickx's notes.
**A wrong VDIG can damage the sensor: do not change these.**

| Rail / line | Value | Lenovo DTB |
|---|---|---|
| VANA (`vdda`) | `pm8953_l17`, 2.85 V, switched by GPIO 119 | `cam_vana-supply` → `pm8953_l17` (2850000 fixed), `cam-vreg-min/max-voltage` 2850000, `qcom,gpio-vana` → GPIO 119 "CAM_VANA" |
| VDIG (`vddd`) | `pm8953_l2`, 1.2 V, switched by GPIO 118 | `cam_vdig-supply` → `pm8953_l2` (range 975000-1225000), `cam-vreg-min/max-voltage` 1200000, `qcom,gpio-vdig` → GPIO 118 "CAM_VDIG" |
| VIO (`vddio`) | `pm8953_l6`, 1.8 V | `cam_vio-supply` → `pm8953_l6` (1800000 fixed) |
| CSI PHY supply | `pm8953_s3`, 1.224 V (already on for the display) | CSID `qcom,mipi-csi-vdd-supply` → `pm8953_s3` 1225000 |
| MCLK | GPIO 26, MCLK0, 24 MHz | `gpios[0]` = 26 "CAMIF_MCLK0", `qcom,clock-rates` 24000000 |
| Reset | GPIO 40, active low | `gpios[1]` = 40 "CAM_RESET0" |
| Standby | GPIO 39, active low | `gpios[2]` = 39 "CAM_STANDBY0" |
| Bus | CCI master 0, 7-bit address 0x37 | `qcom,cci-master = <0>`; 8-bit 0x6e in the Lenovo sensor library (rickx, jethac); jethac read chip ID 0x5034 there |
| CSI | CSIPHY 0 / CSID 0, 2 data lanes | `qcom,csiphy-sd-index`, `qcom,csid-sd-index` = 0 |
| Mount | front; DT `rotation = <180>` (see below) | `qcom,sensor-position = <1>`, `qcom,mount-angle = <270>` |

Notes:

- A fixed regulator does not set the voltage of its supply, so the patch pins `pm8953_l2` at 1.2 V (min = max): Linux
  asks the RPM for exactly 1.2 V at boot. Lenovo leaves L2 at 0.975 V while the camera is off and sets 1.2 V while it
  is on; with the patch L2 stays at 1.2 V (still inside Lenovo's own range), and GPIO 118 keeps it off the sensor until
  the driver powers it. The Lenovo DTB has no other consumer of L2.
- The Lenovo DTB's pin state `cam_sensor_rear_vdig` configures GPIO 134, not 118: it is left over from Qualcomm's
  reference board; the line the Lenovo driver drives is the `gpios` entry, GPIO 118.
- **Rotation.** `video-interface-devices.yaml` defines `rotation` between the sensor's read-out and the scene. With
  the device on its stand (landscape, as it is used) the read-out is **upside down**: raw frames (`media-ctl` and
  `v4l2-ctl`) and libcamera frames alike. So the patch sets `rotation = <180>`. Lenovo's `qcom,mount-angle = <270>` is
  relative to the panel's native portrait orientation (800x1280), an Android convention, and jethac's DT patch has
  270 too: wrong for landscape. An earlier version of this patch had 0, judged on a dim frame: also wrong. The driver
  has no `hflip`/`vflip` controls, so nothing is turned in the sensor: consumers turn the image by the rotation
  property (`camera_sensor_rotation` on the subdevice, libcamera's `Rotation`).
- Measured on the device: RPM reports L2 at 1.200 V, the PMIC's own register (read through the SPMI regulator
  driver) at **1.175 V**. Lower than requested, so on the safe side; why they differ is not known yet.
- Power-up order in the driver (from the Lenovo library): reset and standby low, VANA, VDIG, VIO, MCLK, reset high,
  standby high.

## Building

Toolchain, kernel source and `.config` as in [driver/tas5782m/README.md](../tas5782m/README.md#building-for-the-postmarketos-713-kernel),
steps 1-3 (kernel source in `/tmp/linux-7.1.3`). Then, from the root of this repository:

```sh
make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/s5kc505a" modules
/sbin/modinfo driver/s5kc505a/s5kc505a.ko      # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"

# device tree: the unpatched source rebuilds the device's DTB byte for byte, so check that first
make -C /tmp/linux-7.1.3 ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 qcom/apq8053-lenovo-cd-18781y.dtb
sha256sum /tmp/linux-7.1.3/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb   # = /boot/apq8053-lenovo-cd-18781y.dtb
patch -d /tmp/linux-7.1.3 -p1 < driver/s5kc505a/cd-18781y-front-camera.patch
make -C /tmp/linux-7.1.3 ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 qcom/apq8053-lenovo-cd-18781y.dtb
cp /tmp/linux-7.1.3/arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dtb apq8053-lenovo-cd-18781y-camera.dtb
```

`cd` to a directory with both DTBs under those names and `sha256sum -c driver/s5kc505a/dtb.sha256` must say OK twice.
CI does all of this on every push and keeps `s5kc505a.ko` and the camera DTB as artifacts (`s5kc505a-7.1.3-msm8953`,
`cd-18781y-camera-dtb`); copy both to `image/parts/` for `CAMERA=1`. A change to the patch changes the camera DTB's
sum: update `dtb.sha256` in the same commit.

Every symbol the module needs is exported by the 7.1.3 kernel, the media modules already loaded for the video
decoder (`videodev`, `mc`) or `v4l2-cci`, `v4l2-fwnode`, `v4l2-async` of the kernel package.

## Trying it without writing to the device (not tried yet)

lk2nd ([docs/boot.md](../../docs/boot.md)) also has a fastboot mode, and `fastboot boot` runs an image from RAM: the
installed system is untouched and a power cycle goes back to it. Copy `vmlinuz`, `initramfs` and
`extlinux/extlinux.conf` from the device's `/boot`, then:

```sh
./driver/s5kc505a/make-test-bootimg.sh boot-copy/ apq8053-lenovo-cd-18781y-camera.dtb boot-camera-test.img
./driver/s5kc505a/make-test-bootimg.sh boot-copy/ boot-copy/apq8053-lenovo-cd-18781y.dtb boot-current.img   # rescue
```

The command line comes from `extlinux.conf` (it holds the file system UUIDs: keep the images to yourself).
On the device: `systemctl reboot bootloader`, or power on holding **Volume Down**; lk2nd shows its menu. Connect a
USB-A to USB-C cable (the port has no CC resistors), then `fastboot boot boot-camera-test.img`. Load the driver from
RAM instead of installing it: `modprobe v4l2-cci; modprobe v4l2-fwnode; insmod /run/s5kc505a.ko`; the kernel log
should show `s5kc505a ...-0037: chip id 0x5034`.

## Installing

`CAMERA=1` (above) does these steps in the image. On a running system, by hand: lk2nd reads one entry of
`extlinux.conf`. With `fdtdir /` it loads `/apq8053-lenovo-cd-18781y.dtb` (it tries `/qcom/…` and `/qcom-…` first,
which do not exist on the boot partition); `fdtdir` wins over `fdt` when both are present. To keep the old DTB
untouched:

```sh
cp -a /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.nocamera
install -m 644 apq8053-lenovo-cd-18781y-camera.dtb /boot/
sed -i 's|^\([[:space:]]*\)fdtdir /$|\1fdt /apq8053-lenovo-cd-18781y-camera.dtb|' /boot/extlinux/extlinux.conf
install -m 644 s5kc505a.ko /usr/lib/modules/7.1.3-msm8953/extra/ && depmod -a 7.1.3-msm8953
sync && systemctl reboot
```

udev then loads the camera modules by itself (`i2c-qcom-cci`, `s5kc505a`, `qcom-camss`); the sensor's subdevice,
`/dev/media*` and the `msm_vfe*_video*` nodes appear about 21 s after power-on. The live DT should have
`rotation = <180>` (`/proc/device-tree/soc@0/cci@1b0c000/i2c-bus@0/camera@37/rotation`; a camera DTB built before
the change has 0).

Back: `cp /boot/extlinux/extlinux.conf.nocamera /boot/extlinux/extlinux.conf`, remove `extra/s5kc505a.ko`,
`depmod -a`, reboot. If Linux does not come up, boot `boot-current.img` with `fastboot boot` and do the same.

How it was tried first, on a device without a USB cable at hand: the camera boot counted once. A oneshot unit
ordered before `boot.mount` and `sysinit.target` (`DefaultDependencies=no`; it mounts the `pmOS_boot` file system
itself, found with `blkid -L`, when `/boot` is not mounted yet) moved `extlinux.conf.nocamera` back over
`extlinux.conf` at the start of that boot, so any later reboot came up with the old DTB; `/etc/modprobe.d/` had
`blacklist` and `install … /bin/false` for `qcom_camss`, `i2c_qcom_cci` and `s5kc505a`, and the modules were loaded
by hand with `modprobe -i`, `kernel.panic=10` and `kernel.panic_on_oops=1` set first (the defaults are 0: a panic
does not reboot, and there is no watchdog). A hang before that unit runs would still need someone at the device.

## Capturing a raw frame

`apt install v4l-utils`. CAMSS path: sensor → `msm_csiphy0` → `msm_csid0` → `msm_ispif0` → `msm_vfe0_rdi0` →
video node `msm_vfe0_video0`, `SGRBG10_1X10` on every pad, `pgAA` (packed RAW10) in memory. Modes: 2608x1960,
1936x1096, 1304x980 (binned), 1296x736.

```sh
MD=$(for m in /dev/media*; do media-ctl -d "$m" -p 2>/dev/null | grep -q msm_vfe0_rdi0 && echo "$m"; done | head -n 1)
SENSOR=$(media-ctl -d "$MD" -p | sed -n 's/.*: \(s5kc505a [0-9]*-0037\).*/\1/p')
W=1304 H=980 F=SGRBG10_1X10
media-ctl -d "$MD" -r
media-ctl -d "$MD" -l '"msm_csiphy0":1->"msm_csid0":0[1],"msm_csid0":1->"msm_ispif0":0[1],"msm_ispif0":1->"msm_vfe0_rdi0":0[1]'
media-ctl -d "$MD" -V "\"$SENSOR\":0[fmt:$F/${W}x$H],\"msm_csiphy0\":0[fmt:$F/${W}x$H],\"msm_csid0\":0[fmt:$F/${W}x$H],\"msm_ispif0\":0[fmt:$F/${W}x$H],\"msm_vfe0_rdi0\":0[fmt:$F/${W}x$H]"
v4l2-ctl -d "$(media-ctl -d "$MD" -e "$SENSOR")" -c test_pattern=2          # colour bars; 0 = the real image
v4l2-ctl -d "$(media-ctl -d "$MD" -e msm_vfe0_video0)" --set-fmt-video=width=$W,height=$H,pixelformat=pgAA \
	--stream-mmap --stream-skip=4 --stream-count=1 --stream-to=/run/frame.raw
python3 raw10-to-png.py /run/frame.raw $W $H /run/frame.png    # 652x490, turned 180°: upright on the stand
```

A 1304x980 frame is 1,599,360 bytes (1632 bytes per line). The sensor subdevice has `exposure` (lines; in the
1304x980 mode the default is already 2000 and the maximum 2022 at 30 fps; longer needs a larger
`vertical_blanking`), `analogue_gain` (32 = 1x … 511) and `vertical_blanking`. In a room in half-light
`analogue_gain=256` (8x) at the default exposure gives a recognisable but dark image (mean green about 1 % of full
scale): raise `vertical_blanking` for longer exposures (lower frame rate) or use the remaining gain up to 511. The lens cover is the switch `SW_CAMERA_LENS_COVER` of `gpio-keys`
(GPIO 87): it does not cut the sensor's power, so check it before capturing.

## libcamera

Debian trixie's own **0.4.0** works (one device, 2026-11-11; trixie-backports' 0.7.1 not tried):

```sh
apt install --no-install-recommends libcamera0.4 libcamera-ipa gstreamer1.0-libcamera gstreamer1.0-tools   # no Debian Mesa
gst-launch-1.0 libcamerasrc ! video/x-raw,width=1280,height=960 ! videoconvert ! video/x-raw,format=RGB ! \
	multifilesink location=/run/lc.raw max-files=1 next-file=buffer      # as root; 3,686,400-byte RGB frames
```

The `simple` pipeline handler with the software ISP (`ipa_soft_simple`) picks up `qcom-camss`; dma-buf memory comes
from `/dev/dma_heap/reserved` (CMA, 32 MB by default, root only). Auto exposure works (exposure 4-2022 lines, gain
0-511), colours are plausible with a slight green cast; 1280x960 and 640x480 stream. Warnings: no static sensor
properties, no `s5kc505a.yaml` tuning (falls back to `uncalibrated.yaml`), no camera sensor helper, no sensor delays.

- **Full size (2560x1600, the default) fails**: `dma-heap allocation failure`, kernel `cma: ... alloc failed,
  req-size: 3000 pages, ret: -16`. The 32 MB CMA is too small or too fragmented for full-size RGB buffers; a larger
  `cma=` on the kernel command line is not tried. Ask for 1280x960.
- The frames were upside down (taken with a DT that said `rotation = <0>`); whether `libcamerasrc` turns them with
  `rotation = <180>` is not checked yet.
- `CAMERA=1` does not install libcamera: it stays optional, with the line above.

## Credits and licence

The driver is **jethac's** ([jethac/lenovo-thinksmart-view](https://github.com/jethac/lenovo-thinksmart-view),
commit `fe9c0a58`, `kernel/patches/0402-media-i2c-add-samsung-s5kc505a-sensor-driver.patch` plus `0404`, by Jetha
Chan), unchanged: `s5kc505a.c` is the file those two patches create (sha256 `d044ecca…07946fe25`). It is
**GPL-2.0-only** like the other drivers here (header `SPDX-License-Identifier: GPL-2.0`); the binding
(`0401`) is `GPL-2.0-only OR BSD-2-Clause`. The device tree patch follows jethac's `0403`, rewritten for the 7.1.3
source (the original does not apply to it) and with `rotation = <180>` instead of 270; the device tree source itself is BSD-3-Clause. Register tables, I²C
address and power sequence were decoded by jethac and rickx
([rickx/ubuntu-thinksmart research/camera](https://github.com/rickx/ubuntu-thinksmart/tree/main/research/camera))
from Lenovo's sensor library.
