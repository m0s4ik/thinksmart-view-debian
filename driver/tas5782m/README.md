# TAS5782M speaker amplifier driver

Out-of-tree ASoC codec driver for the Texas Instruments TAS5782M amplifier of the ThinkSmart View (I²C bus 1,
address 0x49). **Written by [rickx](https://github.com/rickx)** for
[rickx/ubuntu-thinksmart](https://github.com/rickx/ubuntu-thinksmart/tree/main/sources/driver) (GPL-2.0), copied on
2026-11-02 and **modified on 2026-11-03** (hardware volume and delayed standby, see [Changes](#changes-2026-11-03)).
Licensed **GPL-2.0-only** ([LICENSE](LICENSE)) while the rest of this repository is GPL-3.0-or-later. See the header
of `tas5782m.c` for its own credits (TI reference driver, Lenovo OSS package, earlier TI smart-amp drivers).

Without this module the sound card `qcom,msm8953-qdsp6-sndcard` stays deferred ("Quaternary MI2S: codec dai not
found") and **the microphones do not work either**. The driver loads the DSP firmware
`/lib/firmware/tas5728m_dsp_lenovo_cd-18781y.bin` (shipped in the postmarketOS firmware package; it comes with
`firmware.tar`, see [docs/kernel.md](../../docs/kernel.md)).

The `Makefile` builds two modules: `snd-soc-tas5782m.ko` (use this one) and `snd-soc-tas5782m-dbg.ko` (verbose
debug build). Install **only** the normal one in `extra/`: the debug module has the same aliases and would be loaded
instead.

## Building for the postmarketOS 7.1.3 kernel

The postmarketOS kernel is built with clang and **KCFI** (`CONFIG_CFI=y`, `CFI_ICALL_NORMALIZE_INTEGERS`), so the
module must be built with clang against the same source and the same `.config`: built with GCC it loads, but its
`init` fails the KCFI check.

Tested on Ubuntu 22.04 and Debian 13 x86_64 (cross-compiling):

1. clang/lld/llvm **22**: on Debian 13 `clang-22 lld-22 llvm-22` from the Debian archive, on Ubuntu 22.04 from
   apt.llvm.org (`llvm-toolchain-jammy-22`); plus
   `make flex bison bc libssl-dev libelf-dev python3 cpio rsync kmod dwarves`. **`dwarves` (pahole) is required**:
   without it `olddefconfig` drops `CONFIG_DEBUG_INFO_BTF` and the module fails with "Exec format error"
   (`.gnu.linkonce.this_module section size must match`).
2. Kernel source, outside this repository (its own `kernel/` folder only holds the config):
   `git clone --depth 1 --branch v7.1.3-r0 https://github.com/msm8953-mainline/linux /tmp/linux-7.1.3` (the tag
   matches the package `linux-postmarketos-qcom-msm8953` 7.1.3), then `rm -rf /tmp/linux-7.1.3/.git` so that
   `setlocalversion` does not append a "+". From the root of this repository, copy
   [`kernel/config-7.1.3-msm8953`](../../kernel/config-7.1.3-msm8953) (the same as `/boot/config` of the device and in
   `boot.tar`): `cp kernel/config-7.1.3-msm8953 /tmp/linux-7.1.3/.config`.
3. `make -C /tmp/linux-7.1.3 ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 olddefconfig` (diff the result: CFI,
   `LOCALVERSION="-msm8953"` and an unset `LOCALVERSION_AUTO` must not change), then
   `make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 modules_prepare`.
4. From the root of this repository:
   `make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/tas5782m" modules`
   (`KBUILD_MODPOST_WARN=1` because without building the whole kernel there is no `Module.symvers`; fine, the kernel
   has no `MODVERSIONS`). `modinfo driver/tas5782m/snd-soc-tas5782m.ko` must show
   `vermagic: 7.1.3-msm8953 SMP preempt mod_unload aarch64` and the parameters `standby_ms` and `volume_mode`
   (a module without them is the old one, without hardware volume: `image/build.sh` refuses it).
5. Copy `snd-soc-tas5782m.ko` to `image/parts/` for `image/build.sh`, or install it on a running device with
   [`install-module.sh`](install-module.sh).

CI builds the module the same way on every push ([.github/workflows/ci.yml](../../.github/workflows/ci.yml)) and keeps
it as a downloadable artifact. The module must be rebuilt for every new kernel. The same recipe works for other out-of-tree modules.

## Installing on a running device

Copy the module and `install-module.sh` to the device, stop every program that plays or records, then:

```bash
./install-module.sh /tmp/snd-soc-tas5782m.ko   # install this module (the current one is backed up once)
./install-module.sh restore                    # put back the module that was there before
```

It checks the vermagic, refuses to go on while `/dev/snd` is open, installs into
`/usr/lib/modules/7.1.3-msm8953/extra/`, runs `depmod`, unbinds the codec and reloads the module, then restarts
`thinksmart-audio` (which sets the volume again). If the old module cannot be unloaded, or the card does not come back
within 30 s, it reboots the device: the new module is already in place. It plays no sound.

## Usage

- Card `hw:0` (`cd-18781y`): playback `hw:0,0` (MultiMedia1), capture `hw:0,1` (MultiMedia2, 2 channels = DMIC1/DMIC2).
  S16_LE or S24_LE only.
- The UCM profile is in postmarketOS (`soc-qcom-msm8953-ucm`, part of `ucm.tar`):
  `alsaucm -c hw:0 set _verb HiFi set _enadev Speaker set _enadev Microphone` (routes `QUAT_MI2S_RX` ←
  MultiMedia1, `TERT_MI2S_TX` → MultiMedia2, DMICs on the decimators, `TX1/TX2 Digital Volume` 115).
- **Volume**: `Speaker Amp Master` 0-85, 1 dB per step, 85 = 0 dB, 0 = mute (with dB information, so `amixer` shows
  them). Measured: 85/79/73 give 0/−6/−12 dB. The full name for `cset`/`cget` is
  `Speaker Amp Master Playback Volume` (one value sets both channels). **It restarts at 0 (muted) every time the module
  is loaded**: set it afterwards (`thinksmart-audio` does). While a stream is open (or within `standby_ms` after it) a
  change is written to the chip at once; otherwise it is applied at the next stream.

### Module parameters

| Parameter | Default | Meaning |
|---|---|---|
| `volume_mode` | `0` | `0`: DAC digital volume (Book 0 / Page 0, registers 0x3D/0x3E); the DSP fine volume stays as the Lenovo firmware sets it, so 85 is the level the old driver always played at. `1`: fallback, DSP fine volume (Book 0x8C / Page 0x1E, 0x44/0x48, scaled from the firmware's own value) + swap flag, with 0x3D/0x3E at 0 dB |
| `standby_ms` | `3000` | after a stream ends the amplifier is only muted; it goes to standby after this many ms without a new stream. `0` = standby at once (old behaviour), negative = never. Can be changed at runtime in `/sys/module/snd_soc_tas5782m/parameters/standby_ms` |

Set them in `/etc/modprobe.d/tas5782m.conf`, e.g. `options snd_soc_tas5782m standby_ms=10000`.

## Changes 2026-11-03

### What was wrong

Measured with the device's own microphone (full scale tones): with the original driver `Speaker Amp Master` **did not
change the level** (1 to 70: same level ±0.5 dB), and **every sound started after ~600 ms of silence**.

1. **Volume written to the wrong place.** `tas5782m_set_volume` wrote a coefficient in Book 0x8C / Page 0x2A,
   registers 0x24/0x28: that is the undocumented location of the **TAS5805M** (from `sound/soc/codecs/tas5805m.c`).
   The Lenovo DSP firmware (`tas5728m_dsp_lenovo_cd-18781y.bin`, 1522 register/value pairs) never touches page 0x2A.
   The TAS5782M datasheet (SLASEG8A) has two real volumes:
   - **Book 0 / Page 0, registers 0x3D (left) and 0x3E (right)**: DAC digital volume, 0x00 = +24 dB,
     **0x30 = 0 dB**, −0.5 dB per step, 0xFF = mute, ramped by the chip (P0-R63). The Lenovo firmware itself writes
     0x30/0x30 there.
   - **Book 0x8C / Page 0x1E, registers 0x44/0x48**: the process flow's "fine volume", Q9.23 (0x00800000 = 0 dB);
     the Lenovo firmware sets 0x004C3EA8 (−4.5 dB). It lies in the range that needs the **swap flag**, Book 0x8C /
     Page 0x23 / register 0x14 = `00 00 00 01` (section 9.3.9.6.2).
2. **Immediate standby.** The qcom machine driver sets `ignore_pmdown_time` on the DPCM back-ends
   (`sound/soc/qcom/common.c`), so the `DAC` widget is powered down as soon as the stream stops and the driver's
   `PRE_PMD` put the chip in standby at once. Every stream then redid reset + firmware load (~1500 I²C writes,
   ~550 ms) while the audio was already flowing: the silence before every sound.

### What changed (`tas5782m.c`, `tas5782m.h`, `tas5782m_priv.h`)

- **Volume** on the real registers, selectable with `volume_mode` (see above); the control has a TLV (−84…0 dB,
  0 = mute). Value for mode 0: `0x30 + 2 × (85 − v)`, `v = 0` → `0xFF`.
- **Delayed standby** (`standby_ms`): at the end of a stream `PRE_PMD` only soft-mutes (register 0x03 = 0x11, while
  BCLK is still running: no click) and keeps DSP and firmware loaded; a delayed work puts the chip in standby
  (register 0x02 = 0x10) later. A stream that starts again before that finds the chip ready: volume + unmute only.
  Power: about 0.35 W muted, 0.06 W in standby (datasheet); with no clocks the chip is in the clock-error standby
  anyway.
- Races: `stream_active` (from `trigger(START)` to `PRE_PMD`) keeps the delayed standby from switching off a stream
  that has just started again; if the standby already happened, the new stream reloads everything as before.

Result on the device: 85/79/73 measured as 0.0/−6.0/−12.0 dB; the first sound after standby still has ~500 ms of
delay, the following ones (within `standby_ms`) none.

`standby_ms=0` restores the old immediate standby.
