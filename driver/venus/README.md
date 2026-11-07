# Venus video decoder module

The ThinkSmart View's SoC has a hardware video codec block, **Venus**, with its own firmware (`venus.mdt`, version
VIDEO.VE.4.2, loaded from the device's `modem` partition by `msm-firmware-loader`). The kernel driver `qcom-venus`
exposes it as two standard V4L2 memory-to-memory devices:

| Device | Name | Formats |
|---|---|---|
| decoder | `qcom-venus-decoder` | in: H.264, HEVC, VP8, VP9, MPEG-2, MPEG-4 Part 2, H.263, VC-1, Xvid; out: NV12 (and a Qualcomm compressed format) |
| encoder | `qcom-venus-encoder` | H.264, HEVC, VP8, MPEG-4, H.263 |

GStreamer uses them through `v4l2h264dec`, `v4l2h265dec`, `v4l2vp9dec`, … (`gstreamer1.0-plugins-good`), ffmpeg through
`h264_v4l2m2m` and friends.

## Why a rebuilt module

With the `venus-core` of the postmarketOS 7.1.3 kernel the probe fails:

```
qcom-venus 1d00000.venus: Unsupported property: 0
qcom-venus 1d00000.venus: probe with driver qcom-venus failed with error -5
```

The firmware starts and answers the init with the list of what it supports; the msm8953-mainline 7.1.3 tree carries a
rewritten `hfi_parser.c` that reads that list with the wrong sizes, loses alignment and rejects it. Mainline Linux
(7.0, 7.1, 7.2 and master) keeps the older parser, with two fixes from 2026 (`a51cea23e409` and `bd595b745eb7`,
"fix payload size …"), and rickx's 6.19 kernel decodes video with the same firmware.

[`hfi_parser.patch`](hfi_parser.patch) replaces the 7.1.3 `hfi_parser.c` with the mainline one (master after
`bd595b745eb7`), adapted to the 7.1.3 headers (the `IS_V1` codec filter instead of the newer codec blacklist,
`hfi_platform_get_codecs()`, `plane_info` as a flexible array). Only `venus-core` changes; `venus-dec` and `venus-enc`
of the kernel package are used as they are.

## Measured on our device

1080p30 H.264 High (300 frames, GStreamer `filesrc ! h264parse ! <decoder> ! fakesink sync=false`):

| Stream | `v4l2h264dec` (Venus) | `avdec_h264` (software) |
|---|---|---|
| no B-frames | 1.2 s, 0.5 s of CPU | 2.2 s, 8.3 s of CPU (all four cores) |
| B-frames (3) | all 300 frames, in order; **the pipeline then hangs at end of stream** | 2.5 s, 11.2 s of CPU |

B-frames decode fine: every frame comes out, in presentation order. What hangs is the drain at the end of a file: after
the last frame the decoder never reports the end of the stream (`V4L2_DEC_CMD_STOP` gets no last buffer), so the
pipeline waits forever. Live streams (AirPlay mirroring, cameras) never drain, so they are not affected; for files use
a timeout or the software decoder. rickx saw streams with B-frames stall at frame 0 through ffmpeg's `h264_v4l2m2m`
(6.19 kernel); through GStreamer they do not.

## Building

Same toolchain, kernel source and `.config` as the speaker driver: follow steps 1-3 of
[driver/tas5782m/README.md](../tas5782m/README.md#building-for-the-postmarketos-713-kernel) (kernel source in
`/tmp/linux-7.1.3`), then, from the root of this repository:

```sh
cp /tmp/linux-7.1.3/drivers/media/platform/qcom/venus/*.[ch] driver/venus/
patch -d driver/venus -p1 < driver/venus/hfi_parser.patch
make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/venus" modules
/sbin/modinfo driver/venus/venus-core.ko        # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"
cp driver/venus/venus-core.ko image/parts/
```

`image/build.sh` installs `image/parts/venus-core.ko` over the kernel package's
`kernel/drivers/media/platform/qcom/venus/venus-core.ko` when it is there; it is optional (without it the image builds
and has no hardware video decoder). The CI builds it too (artifact `venus-core-7.1.3-msm8953`).

On a running device: copy the module over
`/usr/lib/modules/$(uname -r)/kernel/drivers/media/platform/qcom/venus/venus-core.ko` (keep the old one), `depmod -a`,
then `rmmod venus_dec venus_enc venus_core; modprobe venus_core` (or reboot). `/dev/video*` appear, named as above in
`/sys/class/video4linux/*/name`.
