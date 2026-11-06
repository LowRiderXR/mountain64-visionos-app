#!/usr/bin/env python3
"""Pixel-art app icon proposals for the visionOS port (mountain motif).

Draws on a 64x64 pixel grid, scales by 16 (nearest neighbour) to the 1024x1024 layer size of a
visionOS solid image stack, and writes three layers per variant (Back, Middle, Front) plus a
circular composite preview. Pure Python (zlib PNG writer), no dependencies.

usage: python3 scripts/icon/make-icons.py [outdir]   (default build/icon; the final variant is
"nacht-schnee", whose three layers live in Assets.xcassets/AppIcon.solidimagestack)
"""
import math
import os
import struct
import sys
import zlib

N = 64          # grid size
SCALE = 16      # 64 * 16 = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "icon")


def png(path, w, h, rgba_rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rgba_rows)
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


class Grid:
    def __init__(self):
        self.p = [[(0, 0, 0, 0)] * N for _ in range(N)]

    def set(self, x, y, c):
        if 0 <= x < N and 0 <= y < N:
            self.p[y][x] = c if len(c) == 4 else (*c, 255)

    def get(self, x, y):
        return self.p[y][x] if 0 <= x < N and 0 <= y < N else (0, 0, 0, 0)

    def fill(self, c):
        for y in range(N):
            for x in range(N):
                self.set(x, y, c)

    def vgradient(self, stops):
        """stops: list of (y, colour); linear between, quantised to bands of 4 px (pixel-art look)."""
        for y in range(N):
            yb = (y // 4) * 4
            for (y0, c0), (y1, c1) in zip(stops, stops[1:]):
                if y0 <= yb <= y1:
                    t = (yb - y0) / max(1, y1 - y0)
                    c = tuple(round(a + (b - a) * t) for a, b in zip(c0, c1))
                    break
            else:
                c = stops[-1][1] if yb > stops[-1][0] else stops[0][1]
            for x in range(N):
                self.set(x, y, c)

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.set(x, y, c)

    def disc(self, cx, cy, r, c):
        for y in range(N):
            for x in range(N):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self.set(x, y, c)

    def outline(self, c, inside=True):
        """1 px outline around every opaque region (drawn on transparent neighbours)."""
        add = []
        for y in range(N):
            for x in range(N):
                if self.get(x, y)[3] == 0:
                    if any(self.get(x + dx, y + dy)[3] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                        add.append((x, y))
        for x, y in add:
            self.set(x, y, c)

    def scaled_rows(self):
        for y in range(N):
            row = []
            for x in range(N):
                row.extend(self.p[y][x] * SCALE)
            for _ in range(SCALE):
                yield row


def ridge(peaks, base=N):
    """Height per column from a list of (x, y_top) points, linear in between; columns outside
    the first/last point take the base."""
    h = [base] * N
    for (x0, y0), (x1, y1) in zip(peaks, peaks[1:]):
        for x in range(max(0, x0), min(N - 1, x1) + 1):
            t = (x - x0) / max(1, x1 - x0)
            h[x] = round(y0 + (y1 - y0) * t)
    return h


def mountain(g, peaks, light, dark, snow=None, snow_depth=0, snow_jag=None, peak_x=None, base=N):
    """Fills a ridge: left face light, right face dark (from the highest peak), optional snow
    cap down to `snow_depth` rows under the summit with a jagged lower edge."""
    h = ridge(peaks, base)
    top = min(h)
    if peak_x is None:
        peak_x = h.index(top)
    for x in range(N):
        for y in range(h[x], base):
            face = light if x <= peak_x else dark
            if snow is not None and y < top + snow_depth + (snow_jag[x % len(snow_jag)] if snow_jag else 0):
                face = snow if x <= peak_x else tuple(max(0, c - 28) for c in snow)
            g.set(x, y, face)
    return h


def stars(g, seeds, c, bright=None):
    for (x, y, big) in seeds:
        g.set(x, y, bright if (big and bright) else c)
        if big:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                g.set(x + dx, y + dy, c)


def composite(layers, path, mask=True, size=1024):
    """Flattens Back, Middle, Front (in that order) with a circular mask into a preview PNG."""
    rows = []
    s = size / N
    for py in range(size):
        row = []
        for px in range(size):
            x, y = int(px / s), int(py / s)
            r, gg, b = 0, 0, 0
            for L in layers:
                cr, cg, cb, ca = L.get(x, y)
                a = ca / 255
                r, gg, b = r + (cr - r) * a, gg + (cg - gg) * a, b + (cb - b) * a
            inside = (px + 0.5 - size / 2) ** 2 + (py + 0.5 - size / 2) ** 2 <= (size / 2) ** 2
            row.extend((round(r), round(gg), round(b), 255 if (inside or not mask) else 0))
        rows.append(row)
    png(path, size, size, rows)


def write_variant(name, back, middle, front):
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    for layer, g in (("Back", back), ("Middle", middle), ("Front", front)):
        png(os.path.join(d, f"{layer}.png"), N * SCALE, N * SCALE, g.scaled_rows())
    composite([back, middle, front], os.path.join(OUT, f"preview-{name}.png"))
    print("wrote", name)


# ---------------------------------------------------------------- variant 1: Abend (dusk)
def abend():
    back = Grid()
    back.vgradient([(0, (36, 30, 78)), (24, (92, 60, 120)), (40, (214, 118, 96)), (52, (246, 190, 110)), (63, (246, 190, 110))])
    stars(back, [(10, 6, False), (22, 11, False), (40, 4, True), (52, 13, False), (31, 17, False), (57, 7, False), (6, 20, False)], (230, 226, 255), (255, 255, 255))
    # sun, half behind the far ridge
    back.disc(51, 27, 6, (255, 226, 150))
    back.disc(51, 27, 4, (255, 244, 200))

    middle = Grid()
    # far ridge, bluish purple, flat (in the haze)
    mountain(middle, [(-1, 40), (8, 34), (16, 38), (26, 30), (36, 37), (46, 33), (56, 38), (64, 35)], (122, 96, 160), (104, 80, 142))
    middle.outline((70, 52, 100))

    front = Grid()
    jag = [0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 2, 2, 3, 3, 1, 1]
    mountain(front, [(-1, 58), (10, 48), (18, 40), (30, 16), (40, 30), (50, 42), (64, 52)], (96, 112, 160), (58, 66, 112),
             snow=(240, 244, 255), snow_depth=8, snow_jag=jag)
    # second small peak on the right
    mountain(front, [(40, 50), (50, 38), (58, 46), (64, 50)], (96, 112, 160), (58, 66, 112), snow=(240, 244, 255), snow_depth=3, snow_jag=jag)
    # ground band
    front.rect(0, 56, 63, 63, (40, 46, 84))
    front.rect(0, 56, 63, 56, (58, 66, 112))
    front.outline((20, 16, 48))
    write_variant("abend", back, middle, front)


# ---------------------------------------------------------------- variant 1b: Abend mit Schnee (dusk, snowfall)
def flakes(g, seeds, c, big=False):
    """Snowflakes: single pixels, or a 2x2 block with a plus for the near layer."""
    for x, y in seeds:
        if big:
            # a crisp 2x2 flake with single-pixel arms (no half-transparent halo, pixel-art style)
            g.rect(x, y, x + 1, y + 1, c)
            for dx, dy in ((-1, 0), (2, 1), (0, -1), (1, 2)):
                g.set(x + dx, y + dy, c)
        else:
            g.set(x, y, c)


def abend_schnee():
    back = Grid()
    # a shade cooler and paler than "abend": overcast dusk
    back.vgradient([(0, (44, 38, 92)), (24, (100, 70, 132)), (40, (206, 124, 110)), (52, (240, 190, 130)), (63, (240, 190, 130))])
    stars(back, [(10, 6, False), (40, 4, True), (57, 7, False)], (230, 226, 255), (255, 255, 255))
    back.disc(51, 27, 6, (255, 226, 150))
    back.disc(51, 27, 4, (255, 244, 200))
    # far flakes: small, slightly transparent
    flakes(back, [(4, 10), (14, 3), (20, 16), (27, 9), (34, 20), (45, 12), (53, 19), (60, 14), (8, 26), (24, 24),
                  (38, 27), (17, 31), (47, 31), (3, 36), (30, 33), (58, 35)], (255, 255, 255, 215))

    middle = Grid()
    # far ridge, snowed in: pale top, violet lower part
    mountain(middle, [(-1, 40), (8, 34), (16, 38), (26, 30), (36, 37), (46, 33), (56, 38), (64, 35)], (168, 150, 200), (140, 120, 180),
             snow=(226, 222, 244), snow_depth=5, snow_jag=[0, 1, 1, 2, 2, 1, 0, 0])
    middle.outline((88, 70, 124))
    flakes(middle, [(6, 14), (12, 22), (22, 6), (36, 12), (42, 22), (50, 6), (62, 24), (30, 28), (56, 30), (2, 30)], (255, 255, 255, 220))

    front = Grid()
    jag = [0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 2, 2, 3, 3, 1, 1]
    mountain(front, [(-1, 58), (10, 48), (18, 40), (30, 16), (40, 30), (50, 42), (64, 52)], (104, 120, 170), (62, 70, 118),
             snow=(244, 246, 255), snow_depth=13, snow_jag=jag)
    mountain(front, [(40, 50), (50, 38), (58, 46), (64, 50)], (104, 120, 170), (62, 70, 118), snow=(244, 246, 255), snow_depth=5, snow_jag=jag)
    # snow ledges on the left face: short bright strips
    for (x0, x1, y) in ((14, 18, 44), (20, 25, 38), (10, 13, 50)):
        front.rect(x0, x1, y, y, (244, 246, 255)) if False else front.rect(x0, y, x1, y, (244, 246, 255))
    # snowed-in ground
    front.rect(0, 56, 63, 63, (222, 226, 244))
    front.rect(0, 56, 63, 56, (244, 246, 255))
    front.outline((22, 18, 52))
    # near flakes: large, in front of everything (the layer with the strongest parallax)
    flakes(front, [(5, 6), (16, 14), (26, 4), (44, 8), (56, 18), (9, 30), (37, 24), (60, 40), (22, 44), (48, 48), (3, 46)], (255, 255, 255, 255), big=True)
    write_variant("abend-schnee", back, middle, front)

# ---------------------------------------------------------------- variant 2: Nacht (night)
def nacht():
    back = Grid()
    back.vgradient([(0, (8, 10, 32)), (32, (18, 24, 64)), (63, (34, 44, 96))])
    stars(back, [(8, 8, False), (18, 14, True), (28, 6, False), (37, 12, False), (46, 5, False), (55, 16, True),
                 (12, 24, False), (60, 26, False), (33, 22, False), (50, 24, False), (4, 34, False), (24, 30, False)],
          (200, 210, 255), (255, 255, 255))
    back.disc(48, 14, 6, (250, 246, 220))
    back.disc(51, 12, 5, (8, 10, 32))      # crescent
    back.vgradient_done = True

    middle = Grid()
    mountain(middle, [(-1, 44), (10, 36), (20, 41), (30, 33), (42, 40), (52, 35), (64, 42)], (44, 56, 110), (34, 44, 92))
    middle.outline((22, 26, 60))

    front = Grid()
    jag = [0, 0, 2, 2, 1, 1, 3, 3, 1, 1, 0, 0, 2, 2, 1, 1]
    mountain(front, [(-1, 60), (12, 46), (24, 36), (34, 14), (44, 34), (54, 44), (64, 54)], (70, 84, 140), (36, 44, 90),
             snow=(226, 236, 255), snow_depth=9, snow_jag=jag)
    # a lit window hut at the foot (a warm accent, like the start of the climb)
    front.rect(14, 51, 19, 55, (60, 40, 40))
    front.rect(13, 50, 20, 50, (90, 60, 60))
    front.rect(16, 53, 17, 54, (255, 200, 90))
    front.rect(0, 56, 63, 63, (24, 30, 64))
    front.outline((8, 8, 28))
    write_variant("nacht", back, middle, front)


# ---------------------------------------------------------------- variant 3: Celeste palette (teal and pink)
def teal():
    back = Grid()
    back.vgradient([(0, (250, 120, 150)), (20, (252, 170, 160)), (36, (255, 214, 170)), (63, (255, 230, 200))])
    back.disc(13, 22, 7, (255, 250, 230))
    back.disc(13, 22, 5, (255, 255, 245))

    middle = Grid()
    mountain(middle, [(-1, 42), (10, 36), (22, 40), (32, 30), (44, 38), (54, 33), (64, 40)], (120, 196, 196), (90, 166, 170))
    middle.outline((60, 120, 128))

    front = Grid()
    jag = [0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 3, 3, 2, 2, 1, 1]
    mountain(front, [(-1, 58), (8, 50), (20, 38), (32, 12), (44, 32), (56, 46), (64, 50)], (56, 150, 150), (30, 104, 112),
             snow=(255, 255, 255), snow_depth=9, snow_jag=jag)
    front.rect(0, 56, 63, 63, (26, 80, 92))
    front.outline((16, 48, 64))
    write_variant("teal", back, middle, front)


# ---------------------------------------------------------------- variant 4: Minimal (flat, bold)
def minimal():
    back = Grid()
    back.fill((40, 56, 120))

    middle = Grid()
    # big soft sun disc as the only depth element
    middle.disc(32, 34, 20, (255, 214, 120))

    front = Grid()
    mountain(front, [(4, 56), (32, 10), (60, 56)], (60, 80, 150), (36, 50, 104), snow=(255, 255, 255), snow_depth=10, snow_jag=[0, 0, 0, 2, 2, 2, 1, 1, 1, 3, 3, 3])
    front.rect(0, 56, 63, 63, (26, 36, 84))
    front.outline((14, 18, 44))
    write_variant("minimal", back, middle, front)


# ---------------------------------------------------------------- final: Nacht mit Schneefall
# Layers as agreed: Back = sky, moon, far ridge (opaque, edge to edge); Middle = the main peak with
# its snow cap and outline; Front = the side peak on the right, the snowy ground and the flakes
# (they float in front of everything). No glow around the moon (the system adds shine and shadow).
def nacht_schnee():
    back = Grid()
    back.vgradient([(0, (8, 10, 34)), (28, (16, 22, 60)), (48, (30, 40, 92)), (63, (38, 50, 106))])
    stars(back, [(8, 8, False), (18, 14, True), (28, 6, False), (37, 12, False), (46, 5, False), (58, 22, False),
                 (12, 24, False), (33, 22, False), (4, 34, False), (24, 30, False), (56, 32, False), (14, 38, False)],
          (190, 200, 240), (236, 240, 255))
    # pale full moon, no halo; two darker pixels as maria
    back.disc(50, 13, 5, (214, 218, 232))
    back.set(49, 12, (190, 196, 214)); back.set(51, 14, (190, 196, 214)); back.set(48, 15, (196, 202, 220))
    # far ridge with a thin snow line, edge to edge; its outline goes on the sky pixel above the
    # ridge (the layer stays opaque: every pixel keeps an alpha of 255)
    ridge_cols = ((58, 72, 130), (46, 58, 110), (172, 184, 222), (144, 156, 194))
    mountain(back, [(-1, 44), (8, 37), (16, 41), (26, 33), (36, 40), (46, 35), (56, 41), (64, 38)], ridge_cols[0], ridge_cols[1],
             snow=ridge_cols[2], snow_depth=2, snow_jag=[0, 1, 1, 0, 0, 1, 2, 1])
    for x in range(N):
        for y in range(1, N):
            if back.get(x, y)[:3] in ridge_cols and back.get(x, y - 1)[:3] not in ridge_cols:
                back.set(x, y - 1, (16, 20, 50))
    back.rect(0, 56, 63, 63, (30, 40, 86))

    middle = Grid()
    jag = [0, 0, 2, 2, 1, 1, 3, 3, 1, 1, 0, 0, 2, 2, 1, 1]
    mountain(middle, [(-1, 60), (10, 48), (22, 38), (32, 10), (42, 32), (52, 44), (64, 56)], (76, 90, 148), (40, 48, 96),
             snow=(230, 238, 255), snow_depth=10, snow_jag=jag)
    for (x0, x1, y) in ((18, 22, 42), (24, 28, 36), (14, 17, 48)):
        middle.rect(x0, y, x1, y, (230, 238, 255))
    middle.outline((8, 8, 30))

    front = Grid()
    mountain(front, [(40, 56), (50, 40), (58, 48), (64, 52)], (62, 74, 128), (34, 40, 84), snow=(216, 226, 250), snow_depth=4,
             snow_jag=[0, 1, 1, 2, 0, 0, 1, 1])
    front.rect(0, 56, 63, 63, (206, 214, 240))
    front.rect(0, 56, 63, 56, (236, 240, 255))
    front.outline((8, 8, 30))
    # flakes: 2x2 with pixel arms, nine of them, spread so the circle stays calm
    flakes(front, [(6, 10), (20, 6), (44, 7), (57, 16), (10, 30), (38, 24), (60, 38), (24, 46), (48, 50)], (255, 255, 255, 255), big=True)
    write_variant("nacht-schnee", back, middle, front)

# ---------------------------------------------------------------- Abend mit Schnee, ohne Sonne und Mond
# Same layer split as nacht_schnee (Back sky and far ridge, Middle main peak, Front side peak,
# ground and flakes), dusk palette, no sun and no moon: the sky gradient alone carries the light.
def abend_schnee_ohne():
    back = Grid()
    back.vgradient([(0, (40, 34, 88)), (20, (96, 64, 130)), (36, (196, 118, 118)), (48, (240, 186, 132)), (63, (246, 204, 150))])
    stars(back, [(10, 6, False), (40, 4, True), (57, 7, False), (24, 12, False), (50, 15, False), (6, 18, False)], (230, 226, 255), (255, 255, 255))
    ridge_cols = ((168, 150, 200), (140, 120, 180), (236, 232, 248), (208, 204, 220))
    mountain(back, [(-1, 44), (8, 37), (16, 41), (26, 33), (36, 40), (46, 35), (56, 41), (64, 38)], ridge_cols[0], ridge_cols[1],
             snow=ridge_cols[2], snow_depth=3, snow_jag=[0, 1, 1, 0, 0, 1, 2, 1])
    for x in range(N):
        for y in range(1, N):
            if back.get(x, y)[:3] in ridge_cols and back.get(x, y - 1)[:3] not in ridge_cols:
                back.set(x, y - 1, (92, 72, 128))
    back.rect(0, 56, 63, 63, (120, 104, 160))

    middle = Grid()
    jag = [0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 2, 2, 3, 3, 1, 1]
    mountain(middle, [(-1, 60), (10, 48), (22, 38), (32, 10), (42, 32), (52, 44), (64, 56)], (104, 120, 170), (62, 70, 118),
             snow=(244, 246, 255), snow_depth=12, snow_jag=jag)
    for (x0, x1, y) in ((18, 22, 44), (24, 28, 38), (14, 17, 50)):
        middle.rect(x0, y, x1, y, (244, 246, 255))
    middle.outline((22, 18, 52))

    front = Grid()
    mountain(front, [(40, 56), (50, 40), (58, 48), (64, 52)], (104, 120, 170), (62, 70, 118), snow=(244, 246, 255), snow_depth=5,
             snow_jag=[0, 1, 1, 2, 0, 0, 1, 1])
    front.rect(0, 56, 63, 63, (222, 226, 244))
    front.rect(0, 56, 63, 56, (244, 246, 255))
    front.outline((22, 18, 52))
    flakes(front, [(6, 10), (20, 6), (44, 7), (57, 16), (10, 30), (38, 24), (60, 38), (24, 46), (48, 50)], (255, 255, 255, 255), big=True)
    write_variant("abend-schnee-ohne", back, middle, front)

# ---------------------------------------------------------------- Abend mit Schnee, nach der Vorlage
# Like abend_schnee_ohne, but after the reference picture: a large snow cap with a darker right
# half, a higher lavender far ridge with its own snow, a pale ground and twelve flakes.
def abend_schnee_v2():
    back = Grid()
    back.vgradient([(0, (54, 42, 102)), (16, (84, 58, 126)), (30, (138, 78, 138)), (40, (196, 104, 130)), (48, (236, 140, 116)), (63, (246, 176, 128))])
    stars(back, [(10, 6, False), (40, 4, True), (24, 12, False), (50, 15, False), (6, 18, False), (58, 24, False), (34, 20, False), (16, 28, False)],
          (226, 220, 250), (255, 255, 255))
    ridge_cols = ((154, 140, 200), (132, 116, 182), (230, 224, 244), (202, 196, 226))
    mountain(back, [(-1, 46), (6, 39), (14, 43), (24, 36), (34, 41), (44, 35), (54, 40), (64, 37)], ridge_cols[0], ridge_cols[1],
             snow=ridge_cols[2], snow_depth=3, snow_jag=[0, 1, 2, 1, 0, 0, 1, 1])
    for x in range(N):
        for y in range(1, N):
            if back.get(x, y)[:3] in ridge_cols and back.get(x, y - 1)[:3] not in ridge_cols:
                back.set(x, y - 1, (96, 76, 136))
    back.rect(0, 56, 63, 63, (132, 116, 182))

    middle = Grid()
    jag = [0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 2, 2, 3, 3, 1, 1]
    peak_light, peak_dark = (110, 122, 182), (66, 74, 128)
    mountain(middle, [(-1, 60), (10, 48), (22, 36), (32, 12), (42, 30), (52, 42), (64, 54)], peak_light, peak_dark,
             snow=(236, 232, 250), snow_depth=14, snow_jag=jag)
    # the cap's right half darker lavender (the reference shades the shadow side of the snow)
    for x in range(33, N):
        for y in range(N):
            if middle.get(x, y)[:3] == (208, 204, 222):
                middle.set(x, y, (176, 168, 212))
    for (x0, x1, y) in ((18, 22, 44), (24, 28, 38), (14, 17, 50), (28, 31, 30)):
        middle.rect(x0, y, x1, y, (236, 232, 250))
    middle.outline((24, 18, 56))

    front = Grid()
    mountain(front, [(40, 56), (50, 38), (58, 46), (64, 50)], peak_light, peak_dark, snow=(236, 232, 250), snow_depth=6,
             snow_jag=[0, 1, 1, 2, 0, 0, 1, 1])
    for x in range(51, N):
        for y in range(N):
            if front.get(x, y)[:3] == (208, 204, 222):
                front.set(x, y, (176, 168, 212))
    front.rect(0, 56, 63, 63, (204, 198, 232))
    front.rect(0, 56, 63, 56, (226, 222, 244))
    front.outline((24, 18, 56))
    flakes(front, [(6, 10), (20, 6), (36, 4), (46, 8), (57, 16), (10, 30), (33, 22), (52, 30), (60, 40), (24, 46), (46, 50), (4, 48)],
           (255, 255, 255, 255), big=True)
    write_variant("abend-schnee-v2", back, middle, front)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    abend()
    abend_schnee()
    nacht()
    teal()
    minimal()
    nacht_schnee()
    abend_schnee_ohne()
    abend_schnee_v2()
