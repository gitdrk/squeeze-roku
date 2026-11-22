"""Draws the channel icons and splash screen (a record in the app's teal) with no dependencies.

Run: python tools/make_images.py
"""
import math
import os
import struct
import zlib

BG = (0x0E, 0x13, 0x16)
DISC = (0x2F, 0x5F, 0x59)
GROOVE = (0x27, 0x50, 0x4B)
LABEL = (0x4C, 0xC3, 0xB8)
TEXT = (0xE8, 0xED, 0xF0)

OUT = os.path.join(os.path.dirname(__file__), "..", "images")


def png(path, w, h, pixel):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows.extend(pixel(x, y))
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    data += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def record(cx, cy, r):
    """Pixel function for a record of radius r at (cx, cy), with soft edges."""
    def pixel(x, y):
        d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
        if d > r + 1:
            return BG
        color = DISC
        # grooves
        if r * 0.42 < d < r * 0.95 and int(d / max(2, r * 0.045)) % 2 == 0:
            color = GROOVE
        if d < r * 0.36:
            color = LABEL
        if d < r * 0.06:
            color = BG
        if d > r:
            return mix(color, BG, d - r)
        return color
    return pixel


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, w, h in (("icon_fhd.png", 540, 405), ("icon_hd.png", 290, 218)):
        png(os.path.join(OUT, name), w, h, record(w / 2, h / 2, h * 0.38))
    png(os.path.join(OUT, "splash_fhd.png"), 1920, 1080, record(960, 540, 220))
    print("wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
