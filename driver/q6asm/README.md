# q6asm audio stream modules (v0.5-rc)

**Status: built and checked by CI, not yet tested on a device (v0.5-rc).** Optional: an image without these modules
uses the kernel package's ones, as v0.4 does.

`q6asm` (the client of the DSP's audio stream manager) and `q6asm-dai` (the ALSA PCM on top of it) of the 7.1.3
kernel, rebuilt out of tree with three patches. The rest of the audio stack (`q6core`, `q6afe`, `q6adm`, `q6routing`,
the machine driver, the TAS5782M driver) is the kernel package's, unchanged.

## Why

On the stock modules a playback stream that is stopped and prepared again (`snd_pcm_drop()` then
`snd_pcm_prepare()`, or the recovery after an underrun) does not restart properly, and an underrun is never detected:
the stream stays `RUNNING` and `snd_pcm_drain()` only ends on its timeout.

| Patch | Origin | What breaks without it |
|---|---|---|
| [`0001-…-wrap-the-position-of-a-full-ring-to-0.patch`](0001-ASoC-qcom-q6asm-dai-wrap-the-position-of-a-full-ring-to-0.patch) | upstream [`222d04cf55bc`](https://git.kernel.org/torvalds/c/222d04cf55bc), the unmodified commit (`Cc: stable`, not yet in 7.1.y) | the position is reported one frame short: an underrun is never detected, drain waits for its timeout; on capture the last frame of each period is held back |
| [`0002-…-reset-the-queue-pointer-in-prepare.patch`](0002-ASoC-qcom-q6asm-dai-reset-the-queue-pointer-in-prepare.patch) | ours, not upstream | after a prepare ALSA restarts `appl_ptr` from 0 but `queue_ptr` keeps the old value: with 480, 2400 or 4800 frames per period nothing reaches the DSP any more (silent stall); with 960, 1440 or 1920 the driver sends hundreds of millions of bogus write commands until the transport refuses one |
| [`0003-…-reset-the-buffer-index-and-hw-pointer-when-mapping.patch`](0003-ASoC-qcom-q6asm-reset-the-buffer-index-and-hw-pointer-when-mapping.patch) | ours, not upstream | `dsp_buf` and `hw_ptr` survive a re-prepare: the DSP is handed the ring from where the last run stopped (stale audio, and an out-of-bounds read if the new stream has fewer periods), the position is the previous run's until the first buffer returns (a spurious xrun); on capture up to that many stale periods |

- **0001 must not be used without 0002.** On the stock modules an underrun goes unnoticed and the stream resumes by
  itself when data comes back. With 0001 the underrun is detected, the application prepares again, and without 0002
  that prepare stalls the stream or floods the DSP: xrun recovery would be worse than before.
- **0002 and 0003 come from reading the code**: the mechanism is described in each patch, but neither is confirmed on
  hardware yet. 0002 is the q6asm counterpart of upstream `cab45ab95ce7` (q6apm-dai), 0003 of `cab45ab95ce7` and
  `0337b8129cf6` (q6apm).
- The modules are built and installed **together**: 0003 changes `q6asm`, 0001 and 0002 change `q6asm-dai`.

Already in 7.1.3, so not to be backported again: `cee3e63e7106` with `048c540ee76d` (STOP and EOS do not change the
stream state) and `4b4db09f283d` (a failed prepare keeps the audio client). Between 7.1.3 and Linus' master the only
other changes to these two files are a comment typo and `devm_kzalloc_obj` conversions.

## What it does not fix

- **dmix** ([docs/known-issues.md](../../docs/known-issues.md#audio)): the driver queues data only when `appl_ptr`
  moves, and dmix never moves it. Expected unchanged; to be retested.
- **24-bit silence**: nothing here touches formats. Expected unchanged; to be retested.

## Building

Same toolchain, kernel source and `.config` as the speaker driver: follow steps 1-3 of
[driver/tas5782m/README.md](../tas5782m/README.md#building-for-the-postmarketos-713-kernel) (kernel source in
`/tmp/linux-7.1.3`), then, from the root of this repository:

```sh
cp /tmp/linux-7.1.3/sound/soc/qcom/qdsp6/q6asm.c /tmp/linux-7.1.3/sound/soc/qcom/qdsp6/q6asm-dai.c driver/q6asm/
(cd driver/q6asm && sha256sum --strict -c source.sha256)   # the unpatched 7.1.3 files
for p in driver/q6asm/000*.patch; do patch -d driver/q6asm -p5 --fuzz=0 < "$p"; done
make -C /tmp/linux-7.1.3 -j"$(nproc)" ARCH=arm64 LLVM=1 LLVM_SUFFIX=-22 KBUILD_MODPOST_WARN=1 M="$PWD/driver/q6asm" modules
/sbin/modinfo driver/q6asm/q6asm.ko driver/q6asm/q6asm-dai.ko   # vermagic "7.1.3-msm8953 SMP preempt mod_unload aarch64"
cp driver/q6asm/q6asm.ko driver/q6asm/q6asm-dai.ko image/parts/
```

Only the two `.c` files are copied: the headers come from the kernel tree (`ccflags-y` in the [Makefile](Makefile)).
The patches are applied with `-p5` because their paths are the kernel's (`a/sound/soc/qcom/qdsp6/…`). Without the
kernel's `Module.symvers` modpost warns about undefined symbols and the `depends` field of `modinfo` is incomplete;
`depmod` on the device (or in `image/build.sh`) still finds the dependencies from the symbols. The CI builds both
modules (artifact `q6asm-7.1.3-msm8953`).

`image/build.sh` installs `image/parts/q6asm.ko` and `q6asm-dai.ko` over the kernel package's
`kernel/sound/soc/qcom/qdsp6/` ones when both are there, refuses only one of them, and without them builds the image
with the stock modules (a NOTE). `/etc/thinksmart-version` then says `audio: q6asm and q6asm-dai rebuilt`.

## Installing on a running device, and going back

Copy the two `.ko` files and [`install-module.sh`](install-module.sh) to the device, then as root:

```sh
./install-module.sh /dir/with/the/two/ko   # checks vermagic, backs up the current pair once, installs, depmod
systemctl reboot                           # only when the person agrees: the new modules load at boot
./install-module.sh restore                # puts back the original pair (from /var/lib/thinksmart/q6asm-before)
```

Nothing is reloaded live: the whole sound card hangs off these modules. A wrong module can only cost the sound card:
nothing in the initramfs or the boot path uses it, so ssh stays up and `restore` plus a reboot works remotely.

## Testing on the device

Tell the person before any sound and do not raise the volume. [`restart-test.py`](restart-test.py) (Python standard
library, `ctypes` on `libasound.so.2`) plays short tones at −20 dBFS (`--quiet`: digital silence) with periods of
480 frames × 4, and prints `ok` or `FAIL` for each step:

| Step | What it does | Pass | Exercises |
|---|---|---|---|
| 1 | write 1 s, drop, prepare, write 1 s at another pitch, drain | the second second is accepted in ~1 s; two beeps heard | 0002 |
| 2 | write 0.3 s, sleep 1 s, check the state, recover with prepare, write 0.5 s | `XRUN` after the sleep; playback continues after recovery | 0001 + 0002 |
| 3 | write 0.5 s, drain | drain returns in under ~1.5 s | 0001 |
| 4 | `--cycles` times: write 1…7 periods (the stop falls mid-lap), drop, prepare, write one full buffer, wait one period | avail ≤ 2 periods, no immediate xrun; no stale burst heard | 0003 |
| 5 | only with `--capture-device`: read 0.5 s, drop, prepare, read 0.5 s | both reads complete in time | 0001 + 0003 on capture |

On the stock modules step 2 never reaches `XRUN`: that is the expected "before" result. The limit of step 4 is a first
guess (it assumes the DSP returns buffers as it plays them): compare it with the baseline before calling it a
failure. `--device null` runs the script without a sound card, as a dry run that says nothing about the driver.

In this order:

1. Before installing: `./restart-test.py` on the stock modules; keep the output as the baseline.
2. `./install-module.sh`, reboot (the person agrees), then `aplay -l`, `journalctl -u thinksmart-audio -b`
   ("audio ready"), `dmesg | grep -i q6asm` (no new errors), `cat /sys/module/q6asm/taint` (the rebuilt modules are
   out of tree: `O`).
3. `./restart-test.py` again: every step `ok`.
4. Normal use: `aplay` of a file, `arecord` as in [docs/install.md](../../docs/install.md), one suspend and resume with a
   stream open.
5. **AirPlay pause latency**, a measurement and not a pass criterion: with an AirPlay receiver playing straight to
   ALSA, pause from the phone and time until silence, before and after. The modules shorten nothing by themselves: they
   make `snd_pcm_drop()` + `snd_pcm_prepare()` usable, which an application can then use to cut queued audio at once.
6. **S24_LE**: `aplay -D hw:0,0 -f S24_LE` of a tone: still silent? An optional experiment, a guess from memory and
   not from this code: the DSP may expect the 24 bits in the top of the 32-bit word, which would make ALSA's
   `S24_LE` 48 dB quieter rather than broken. Play 32-bit MSB-aligned data declared as `S24_LE` at the normal volume
   setting and note what comes out.
7. dmix: retest the case in [docs/known-issues.md](../../docs/known-issues.md#audio) and record the result.
8. To roll back: `./install-module.sh restore` and a reboot.

## Upstream

0002 and 0003 could be proposed to linux-sound (the ASoC maintainers); they carry no `Signed-off-by` yet. Whether and
when to send them is the owner's decision.

## License

The Makefile, the patches and `install-module.sh` are GPL-2.0-only like the kernel files they change; 0001 is the
upstream commit as published. `restart-test.py` is GPL-3.0-or-later like the rest of this repository.
