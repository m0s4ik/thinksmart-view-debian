#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
"""Print the state of the camera's lens cover: "open" or "closed" (exit status 0 or 1; 2 if not found).

The cover is the switch SW_CAMERA_LENS_COVER of gpio-keys (GPIO 87). The input device is found by that capability,
not by its event number, and its state read with the EVIOCGSW ioctl. Needs read access to /dev/input/event* (root).
Which state is which follows the kernel's meaning of the switch (1 = covered); on this device only the open cover
has been checked so far.
"""
import fcntl
import glob
import os
import sys

SW_CAMERA_LENS_COVER = 0x09
EVIOCGSW = (2 << 30) | (8 << 16) | (ord("E") << 8) | 0x1B  # _IOR('E', 0x1b, 8 bytes): switch states, bit per code


def has_switch(sysdir, code):
    try:
        with open(os.path.join(sysdir, "device/capabilities/sw")) as f:
            words = f.read().split()  # hex words, most significant first
    except OSError:
        return False
    return bool(words) and int(words[-1], 16) >> code & 1


for sysdir in sorted(glob.glob("/sys/class/input/event*")):
    if has_switch(sysdir, SW_CAMERA_LENS_COVER):
        fd = os.open("/dev/input/" + os.path.basename(sysdir), os.O_RDONLY)
        state = fcntl.ioctl(fd, EVIOCGSW, bytes(8))
        os.close(fd)
        covered = state[SW_CAMERA_LENS_COVER // 8] >> (SW_CAMERA_LENS_COVER % 8) & 1
        print("closed" if covered else "open")
        sys.exit(1 if covered else 0)
print("no input device with SW_CAMERA_LENS_COVER", file=sys.stderr)
sys.exit(2)
