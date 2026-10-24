#!/usr/bin/env python3
"""compare-canvas.py: compare two canvas dumps (raw RGBA8, rows top-down) by colour statistics.

Usage: scripts/compare-canvas.py <a.rgba> <b.rgba> [--width 1280]

The dumps come from scripts/build-game.sh mac-check (build/wrapper/mac-check-canvas.rgba, the
title screen on the Mac) and from the device (Documents/c64-canvas-<machine>-tick600.rgba, written
by the app in mode C64_CELESTE=play). The title screen is animated, so the comparison is
statistical, not byte by byte: mean per channel, a 16-bin luminance histogram and its
intersection, the share of black pixels. The height follows from the file size; when one dump is
taller (mac-check uses a 1280x800 canvas with letterbox bars of 40 rows), the extra rows are
cropped symmetrically before comparing. Only the standard library is used.
"""

import struct
import sys


def load(path, width):
    data = open(path, "rb").read()
    if len(data) % (width * 4) != 0:
        sys.exit(f"{path}: {len(data)} bytes is not a multiple of {width}x4")
    return data, len(data) // (width * 4)


def crop(data, width, height, target_height):
    if height == target_height:
        return data
    top = (height - target_height) // 2
    row = width * 4
    return data[top * row:(top + target_height) * row]


def stats(data):
    n = len(data) // 4
    sums = [0, 0, 0]
    hist = [0] * 16
    black = 0
    for i in range(0, len(data), 4):
        r, g, b = data[i], data[i + 1], data[i + 2]
        sums[0] += r
        sums[1] += g
        sums[2] += b
        lum = (299 * r + 587 * g + 114 * b) // 1000
        hist[lum >> 4] += 1
        if r == 0 and g == 0 and b == 0:
            black += 1
    return [s / n for s in sums], [h / n for h in hist], black / n


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    width = 1280
    for i, a in enumerate(sys.argv):
        if a == "--width":
            width = int(sys.argv[i + 1])
    if len(args) != 2:
        sys.exit(__doc__)
    a, ha = load(args[0], width)
    b, hb = load(args[1], width)
    h = min(ha, hb)
    a = crop(a, width, ha, h)
    b = crop(b, width, hb, h)
    ma, hista, blacka = stats(a)
    mb, histb, blackb = stats(b)
    intersection = sum(min(x, y) for x, y in zip(hista, histb))
    print(f"A {args[0]}: {width}x{ha} (compared {h} rows) mean rgb = {ma[0]:.1f} {ma[1]:.1f} {ma[2]:.1f} black = {blacka * 100:.1f}%")
    print(f"B {args[1]}: {width}x{hb} (compared {h} rows) mean rgb = {mb[0]:.1f} {mb[1]:.1f} {mb[2]:.1f} black = {blackb * 100:.1f}%")
    print(f"mean difference (B - A) = {mb[0] - ma[0]:+.1f} {mb[1] - ma[1]:+.1f} {mb[2] - ma[2]:+.1f}")
    print("luminance histogram (16 bins, percent):")
    print("  A " + " ".join(f"{x * 100:5.1f}" for x in hista))
    print("  B " + " ".join(f"{x * 100:5.1f}" for x in histb))
    print(f"histogram intersection = {intersection * 100:.1f}% (100 = identical distributions)")
    verdict = "same colour space" if max(abs(mb[i] - ma[i]) for i in range(3)) < 12 and intersection > 0.8 else "DIFFERENT, check gamma or content"
    print(f"verdict: {verdict} (threshold: channel means within 12, intersection above 80%; the title screen animates, so expect small differences)")


if __name__ == "__main__":
    main()
