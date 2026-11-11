#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrea Mattera
"""Turn one packed RAW10 frame (as written by v4l2-ctl --stream-to) into a viewable PNG.

The Bayer order follows the sensor's flip controls: GRBG ('pgAA') as read out, RGGB ('pRAA') with horizontal_flip,
BGGR ('pBAA') with vertical_flip, GBRG ('pGAA') with both. The read-out is upside down with the device on its stand
(landscape; the DT says rotation 180): capture with both flips and --bayer gbrg for an upright picture, or without
flips and --rotation 180. Half resolution: one RGB pixel per 2x2 Bayer quad, black level subtracted, grey-world
white balance, sRGB-like gamma. Standard library only (runs on the device), a few seconds for a 1304x980 frame. A
quick look, not an ISP.

usage: raw10-to-png.py <frame.raw> <width> <height> <out.png> [--bayer grbg|rggb|bggr|gbrg] [--stride N]
                       [--rotation 0|90|180|270] [--frame N]
"""
import argparse
import struct
import sys
import zlib

BLACK = 64
WHITE = 1023
# 2x2 quad of each Bayer order, row by row
BAYER = ("grbg", "rggb", "bggr", "gbrg")


def unpack_row(buf):
    """MIPI RAW10: 4 pixels in 5 bytes, 8 MSBs each, then a byte with the four 2-bit LSBs."""
    out = [0] * (len(buf) // 5 * 4)
    lo = buf[4::5]
    for i in range(4):
        hi = buf[i::5]
        shift = 2 * i
        out[i::4] = [(h << 2) | ((l >> shift) & 3) for h, l in zip(hi, lo)]
    return out


def png(path, width, height, rows):
    def chunk(kind, data):
        c = kind + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def rotate(rows, w, h, rotation):
    """rows: list of h lists of w (r, g, b) tuples. Returns (rows, w, h) turned clockwise by `rotation` degrees."""
    if rotation == 0:
        return rows, w, h
    if rotation == 180:
        return [r[::-1] for r in rows[::-1]], w, h
    if rotation == 90:
        return [[rows[h - 1 - y][x] for y in range(h)] for x in range(w)], h, w
    if rotation == 270:
        return [[rows[y][w - 1 - x] for y in range(h)] for x in range(w)], h, w
    raise ValueError(rotation)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("raw")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("out")
    ap.add_argument("--stride", type=int, help="bytes per line (default: width*10/8 rounded up to 8)")
    ap.add_argument("--bayer", choices=BAYER, default="grbg",
                    help="colour order of the frame (default grbg: no flips; gbrg with both flips)")
    ap.add_argument("--rotation", type=int, default=0,
                    help="clockwise turn applied to the image (default 0; 180 for a frame captured without flips, "
                         "upright then with the device on its stand)")
    ap.add_argument("--frame", type=int, default=0, help="frame index when the file holds several")
    a = ap.parse_args()

    stride = a.stride or ((a.width * 10 // 8 + 7) // 8 * 8)
    size = stride * a.height
    with open(a.raw, "rb") as f:
        data = f.read()
    if len(data) < size * (a.frame + 1):
        sys.exit(f"{a.raw}: {len(data)} bytes, need {size * (a.frame + 1)} for frame {a.frame} "
                 f"({a.width}x{a.height}, stride {stride})")
    data = data[size * a.frame:size * (a.frame + 1)]
    line = a.width * 10 // 8

    hw, hh = a.width // 2, a.height // 2
    # offset (row * 2 + column) of R, B and the two G in each quad
    ri, bi = a.bayer.index("r"), a.bayer.index("b")
    g0, g1 = [i for i, c in enumerate(a.bayer) if c == "g"]
    quads = []
    sums = [0, 0, 0]
    for y in range(hh):
        r0 = unpack_row(data[(2 * y) * stride:(2 * y) * stride + line])
        r1 = unpack_row(data[(2 * y + 1) * stride:(2 * y + 1) * stride + line])
        rows = (r0, r1)

        def plane(i):  # the samples at quad offset i along this pair of lines
            return rows[i >> 1][i & 1:2 * hw:2]

        row = []
        for rs, ga, gb, bs in zip(plane(ri), plane(g0), plane(g1), plane(bi)):
            g = (ga + gb) / 2 - BLACK
            r = rs - BLACK
            b = bs - BLACK
            row.append((max(r, 0), max(g, 0), max(b, 0)))
            sums[0] += r
            sums[1] += g
            sums[2] += b
        quads.append(row)

    # Grey world, normalised to green; then scale so the mean lands around 18 % grey.
    gain = [sums[1] / s if s > 0 else 1.0 for s in sums]
    mean = sums[1] / (hw * hh) / (WHITE - BLACK)
    expo = 0.18 / mean if mean > 0 else 1.0
    expo = min(expo, 16.0)
    lut = [min(255, int(255 * (i / 4095) ** (1 / 2.2) + 0.5)) for i in range(4096)]
    scale = [4095 * expo * g / (WHITE - BLACK) for g in gain]

    out = [[tuple(lut[min(4095, int(c * s))] for c, s in zip(px, scale)) for px in row] for row in quads]
    out, ow, oh = rotate(out, hw, hh, a.rotation % 360)
    png(a.out, ow, oh, [[v for px in row for v in px] for row in out])
    print(f"{a.out}: {ow}x{oh}, mean green {mean:.3f} of full scale, gains R {gain[0]:.2f} B {gain[2]:.2f}")


if __name__ == "__main__":
    main()
