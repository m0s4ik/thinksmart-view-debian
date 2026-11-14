#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
"""Check that an ALSA stream restarts after a stop, an underrun or a re-prepare (driver/q6asm/README.md).

Plays short tones at -20 dBFS (digital silence with --quiet) on --device, with small periods (480 frames x 4) so that
the ring laps quickly, and prints "ok" or "FAIL" for each step; exit status 1 if any step fails. Every call that could
block is bounded: the stream is opened non-blocking and waits use snd_pcm_wait() with a timeout.

  1  write 1 s, drop, prepare, write 1 s at another pitch, drain   the second second is accepted in ~1 s (two beeps)
  2  write 0.3 s, sleep 1 s, recover with prepare, write 0.5 s     the state is XRUN after the sleep (the stock
                                                                    kernel stays RUNNING: no underrun is detected)
  3  write 0.5 s, drain                                            drain returns in under ~1.5 s
  4  --cycles times: write 1..7 periods, drop, prepare, write one  avail the same wherever the previous run stopped,
     full buffer, wait one period                                   below the whole ring, no xrun (no stale position)
  5  with --capture-device: read 0.5 s, drop, prepare, read 0.5 s  both reads complete in time

Tell the people around the device before running it: it plays sound (unless --quiet). It does not change the volume.
Standard library only (ctypes on libasound.so.2). "--device null" runs it without a sound card, as a dry run: the
results then say nothing about the driver.
"""
import argparse
import array
import ctypes
import ctypes.util
import errno
import math
import sys
import time

STREAM_PLAYBACK, STREAM_CAPTURE = 0, 1
NONBLOCK = 1
ACCESS_RW_INTERLEAVED = 3
FORMAT_S16_LE = 2
STATES = {0: "OPEN", 1: "SETUP", 2: "PREPARED", 3: "RUNNING", 4: "XRUN", 5: "DRAINING", 6: "PAUSED",
          7: "SUSPENDED", 8: "DISCONNECTED"}
CHANNELS = 2
PERIOD = 480
PERIODS = 4

name = ctypes.util.find_library("asound") or "libasound.so.2"
lib = ctypes.CDLL(name)
lib.snd_pcm_writei.restype = ctypes.c_long
lib.snd_pcm_writei.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
lib.snd_pcm_readi.restype = ctypes.c_long
lib.snd_pcm_readi.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
lib.snd_pcm_avail.restype = ctypes.c_long
lib.snd_strerror.restype = ctypes.c_char_p
for f in ("snd_pcm_state", "snd_pcm_drop", "snd_pcm_drain", "snd_pcm_prepare", "snd_pcm_start", "snd_pcm_close",
          "snd_pcm_avail"):
    getattr(lib, f).argtypes = [ctypes.c_void_p]
for f in ("snd_pcm_hw_params", "snd_pcm_hw_params_any", "snd_pcm_sw_params", "snd_pcm_sw_params_current"):
    getattr(lib, f).argtypes = [ctypes.c_void_p, ctypes.c_void_p]
lib.snd_pcm_wait.argtypes = [ctypes.c_void_p, ctypes.c_int]


class AlsaError(Exception):
    pass


def check(ret, what):
    if ret < 0:
        raise AlsaError(f"{what}: {lib.snd_strerror(ret).decode()}")
    return ret


class Pcm:
    def __init__(self, device, stream, rate):
        self.p = ctypes.c_void_p()
        self.stream = stream
        check(lib.snd_pcm_open(ctypes.byref(self.p), device.encode(), stream, NONBLOCK), f"open {device}")
        hw = ctypes.c_void_p()
        check(lib.snd_pcm_hw_params_malloc(ctypes.byref(hw)), "hw_params_malloc")
        try:
            check(lib.snd_pcm_hw_params_any(self.p, hw), "hw_params_any")
            check(lib.snd_pcm_hw_params_set_access(self.p, hw, ACCESS_RW_INTERLEAVED), "access")
            check(lib.snd_pcm_hw_params_set_format(self.p, hw, FORMAT_S16_LE), "format S16_LE")
            check(lib.snd_pcm_hw_params_set_channels(self.p, hw, CHANNELS), "channels")
            r = ctypes.c_uint(rate)
            check(lib.snd_pcm_hw_params_set_rate_near(self.p, hw, ctypes.byref(r), None), "rate")
            ps = ctypes.c_ulong(PERIOD)
            check(lib.snd_pcm_hw_params_set_period_size_near(self.p, hw, ctypes.byref(ps), None), "period size")
            n = ctypes.c_uint(PERIODS)
            check(lib.snd_pcm_hw_params_set_periods_near(self.p, hw, ctypes.byref(n), None), "periods")
            check(lib.snd_pcm_hw_params(self.p, hw), "hw_params")
            self.rate, self.period, self.periods = r.value, ps.value, n.value
        finally:
            lib.snd_pcm_hw_params_free(hw)
        self.buffer = self.period * self.periods
        sw = ctypes.c_void_p()
        check(lib.snd_pcm_sw_params_malloc(ctypes.byref(sw)), "sw_params_malloc")
        try:
            check(lib.snd_pcm_sw_params_current(self.p, sw), "sw_params_current")
            check(lib.snd_pcm_sw_params_set_avail_min(self.p, sw, ctypes.c_ulong(self.period)), "avail_min")
            # playback starts as soon as one period is written
            check(lib.snd_pcm_sw_params_set_start_threshold(self.p, sw, ctypes.c_ulong(self.period)), "start")
            check(lib.snd_pcm_sw_params(self.p, sw), "sw_params")
        finally:
            lib.snd_pcm_sw_params_free(sw)

    def state(self):
        return STATES.get(lib.snd_pcm_state(self.p), "?")

    def drop(self):
        check(lib.snd_pcm_drop(self.p), "drop")

    def prepare(self):
        check(lib.snd_pcm_prepare(self.p), "prepare")

    def restart(self):
        """Stop whatever runs (prepare refuses a running stream: EBUSY) and prepare again."""
        self.drop()
        self.prepare()

    def avail(self):
        return lib.snd_pcm_avail(self.p)

    def write(self, data, timeout):
        """Write all of data (an array of int16, interleaved); returns (frames written, "ok"|"xrun"|"timeout")."""
        frames = len(data) // CHANNELS
        addr = data.buffer_info()[0]
        done = 0
        end = time.monotonic() + timeout
        while done < frames:
            if time.monotonic() > end:
                return done, "timeout"
            n = lib.snd_pcm_writei(self.p, addr + done * CHANNELS * 2, frames - done)
            if n == -errno.EAGAIN:
                lib.snd_pcm_wait(self.p, 100)
            elif n == -errno.EPIPE:
                return done, "xrun"
            elif n < 0:
                check(n, "writei")
            else:
                done += n
        return done, "ok"

    def read(self, frames, timeout):
        data = array.array("h", bytes(frames * CHANNELS * 2))
        addr = data.buffer_info()[0]
        done = 0
        end = time.monotonic() + timeout
        if lib.snd_pcm_state(self.p) == 2:
            check(lib.snd_pcm_start(self.p), "start")
        while done < frames:
            if time.monotonic() > end:
                return done, "timeout"
            n = lib.snd_pcm_readi(self.p, addr + done * CHANNELS * 2, frames - done)
            if n == -errno.EAGAIN:
                lib.snd_pcm_wait(self.p, 100)
            elif n == -errno.EPIPE:
                return done, "xrun"
            elif n < 0:
                check(n, "readi")
            else:
                done += n
        return done, "ok"

    def drain(self, timeout):
        """Drain (non-blocking: poll the state); returns the seconds it took, or None on timeout."""
        start = time.monotonic()
        ret = lib.snd_pcm_drain(self.p)
        if ret < 0 and ret != -errno.EAGAIN:
            check(ret, "drain")
        while lib.snd_pcm_state(self.p) == 5:
            if time.monotonic() - start > timeout:
                lib.snd_pcm_drop(self.p)
                return None
            time.sleep(0.01)
        return time.monotonic() - start

    def close(self):
        lib.snd_pcm_close(self.p)


def tone(rate, seconds, hz, quiet):
    n = int(rate * seconds)
    amp = 0 if quiet else 0.1 * 32767  # -20 dBFS
    out = array.array("h", bytes(n * CHANNELS * 2))
    for i in range(n):
        v = int(amp * math.sin(2 * math.pi * hz * i / rate))
        out[2 * i] = out[2 * i + 1] = v
    return out


FAILS = 0


def report(step, good, detail):
    global FAILS
    print(f"  {'ok  ' if good else 'FAIL'}  step {step}: {detail}", flush=True)
    if not good:
        FAILS += 1


def playback_steps(pcm, args):
    rate, q = pcm.rate, args.quiet
    t1, t2 = tone(rate, 1.0, 440, q), tone(rate, 1.0, 660, q)

    # 1: a drop and a prepare in the middle of playback (0002)
    pcm.prepare()
    pcm.write(t1, 2.0)
    pcm.restart()
    start = time.monotonic()
    n, how = pcm.write(t2, 2.0)
    took = time.monotonic() - start
    drained = pcm.drain(2.0)
    report(1, how == "ok" and took < 1.5 and drained is not None,
           f"second second after drop+prepare: {n}/{len(t2) // CHANNELS} frames, {how}, {took:.2f} s; "
           f"drain {'timed out' if drained is None else f'{drained:.2f} s'}")

    # 2: an underrun is detected and recovered with prepare (0001 + 0002)
    pcm.prepare()
    pcm.write(tone(rate, 0.3, 523, q), 1.0)
    time.sleep(1.0)
    st = pcm.state()
    if st == "XRUN":
        pcm.prepare()
    else:
        pcm.restart()
    n, how = pcm.write(tone(rate, 0.5, 523, q), 1.5)
    drained = pcm.drain(2.0)
    report(2, st == "XRUN" and how == "ok" and drained is not None,
           f"state after 1 s without data: {st} (expected XRUN; the stock modules stay RUNNING); "
           f"after recovery {how}, drain {'timed out' if drained is None else f'{drained:.2f} s'}")

    # 3: drain ends when the data ends (0001)
    pcm.prepare()
    n, how = pcm.write(tone(rate, 0.5, 587, q), 1.5)
    drained = pcm.drain(3.0)
    report(3, how == "ok" and drained is not None and drained < 1.5,
           f"drain after 0.5 s: {'timed out (3 s)' if drained is None else f'{drained:.2f} s'}")

    # 4: restarts that stop in the middle of a lap (0002). One period after the restart the position depends only on
    # how far ahead the DSP takes buffers (3 periods measured on the device): it must be the same wherever the previous
    # run stopped. A stale buffer index or hw_ptr makes it depend on k (the stock modules: always the whole ring).
    full = tone(rate, pcm.buffer / rate, 392, q)
    seen, bad = {}, []
    for c in range(args.cycles):
        k = 1 + c % 7
        pcm.restart()
        pcm.write(tone(rate, k * pcm.period / rate, 392, q), 1.0)
        pcm.restart()
        n, how = pcm.write(full, 1.0)
        time.sleep(pcm.period / rate)
        av, st = pcm.avail(), pcm.state()
        seen.setdefault(k, set()).add(av)
        if how != "ok" or st == "XRUN" or av < 0 or av >= pcm.buffer - 1:
            bad.append(f"cycle {c + 1} ({k} periods): {how}, {st}, avail {av}")
    pcm.drop()
    values = sorted(set().union(*seen.values()))
    if values[-1] - values[0] > pcm.period // 4:
        bad.append("avail depends on where the previous run stopped: "
                   + ", ".join(f"{k}: {sorted(v)}" for k, v in sorted(seen.items())))
    report(4, not bad, f"{args.cycles} restarts, avail after one period {values} frames "
           f"(same for every stop point, below the whole ring of {pcm.buffer})"
           + ("; " + "; ".join(bad[:3]) if bad else ""))


def capture_step(args):
    pcm = Pcm(args.capture_device, STREAM_CAPTURE, args.rate)
    try:
        frames = pcm.rate // 2
        pcm.prepare()
        n1, how1 = pcm.read(frames, 1.5)
        pcm.restart()
        n2, how2 = pcm.read(frames, 1.5)
        pcm.drop()
        report(5, how1 == "ok" and how2 == "ok",
               f"capture 0.5 s, drop, prepare, 0.5 s: {n1} {how1}, {n2} {how2} (of {frames} frames)")
    finally:
        pcm.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--device", default="hw:0,0", help="playback PCM (default hw:0,0; 'null' for a dry run)")
    ap.add_argument("--capture-device", help="capture PCM for step 5 (skipped without it)")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--quiet", action="store_true", help="play digital silence instead of tones")
    ap.add_argument("--cycles", type=int, default=20, help="restarts in step 4 (default 20)")
    args = ap.parse_args()

    try:
        pcm = Pcm(args.device, STREAM_PLAYBACK, args.rate)
    except AlsaError as e:
        print(f"  FAIL  {e}", file=sys.stderr)
        return 1
    print(f"{args.device}: {pcm.rate} Hz, S16_LE stereo, period {pcm.period} frames x {pcm.periods}"
          f"{', silence' if args.quiet else ', tones at -20 dBFS'}", flush=True)
    try:
        playback_steps(pcm, args)
    except AlsaError as e:
        report("-", False, str(e))
    finally:
        pcm.close()
    if args.capture_device:
        try:
            capture_step(args)
        except AlsaError as e:
            report(5, False, str(e))
    else:
        print("  skip  step 5: no --capture-device")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
