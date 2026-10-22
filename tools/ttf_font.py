#!/usr/bin/env python3
# Pixel-font TrueType -> bitmap: the reference model for the core's TTF loader (rtl/zm_ttf.sv) and the font file the
# sim reference (verilator/ref) draws V6 text with. For fonts drawn on a pixel grid:
#   Flathead by Kawa (2014, a recreation of the Zork Zero font): 1000 units/em, 125 units = 1 pixel, 8 rows.
#   Amiga Topaz Unicode (dMG of Trueschool and Divine Stylers, 2009; Topaz is (c) Amiga Inc): Topaz 8 drawn 8 x 16
#     (every row twice, for square pixels) at 100 units = 1 pixel.
#   Grid (from the font's own metrics): H = hhea ascender - descender; a TALL font when 2 * advance('0') <= H
#   (16 rows drawn, shown as 8: each output row = the OR of a row pair; Topaz's ( ) [ ] { } have half rows), else 8
#   rows; u = H / 16 or H / 8 (rounded down) units per pixel. Top row = round(ascender / u) - 1.
#   Character map: the Mac (1, 0) format 0 table (256 glyph numbers). Glyphs: 'glyf' + 'loca' (long or short),
#   straight segments only (every point on-curve). Advance widths: 'hmtx' (the last entry repeats).
#   Raster: every point snapped to the nearest grid line (round(v / u), (u - 1) / 2 rounds down; Flathead has a few
#   drafting slips of 1-3 units, Topaz of 1), so every edge is horizontal or vertical; a pixel is set when its
#   centre's nonzero winding number is non-zero (vertical edges to the left of the centre that span its height, +1
#   upward / -1 downward). Columns 0-7. Advance = round(advance / u) pixels.
#   Kind (zm_ttf's slot, decided before any glyph is drawn): "cell" = '0' is 8 pixels wide (Topaz: V1-V5 text
#   cells), else post.isFixedPitch "fixed" / "proportional".
#   ttf_font.py <font.ttf> [--hex <out>] [--png <out.png>] [--kind]
#     --hex: 96 glyphs (ZSCII 32..127; 127 blank) x 9 lines: 8 rows (bit i = column i) then the advance, as hex
import struct, sys

def snap(v, u):
    return (v + (u - 1) // 2) // u if v >= 0 else -((-v + (u - 1) // 2) // u)

def parse(path):
    d = open(path, "rb").read()
    T = {}
    for i in range(struct.unpack(">H", d[4:6])[0]):
        tag, _, off, _ = struct.unpack(">4sIII", d[12 + 16 * i: 28 + 16 * i])
        T[tag.decode("latin-1")] = off
    long_loca = struct.unpack(">h", d[T["head"] + 50: T["head"] + 52])[0] == 1
    ng = struct.unpack(">H", d[T["maxp"] + 4: T["maxp"] + 6])[0]
    nhm = struct.unpack(">H", d[T["hhea"] + 34: T["hhea"] + 36])[0]
    asc, desc = struct.unpack(">hh", d[T["hhea"] + 4: T["hhea"] + 8])
    H = asc - desc
    cmap = None
    cm = T["cmap"]
    for k in range(struct.unpack(">H", d[cm + 2: cm + 4])[0]):
        pid, eid, off = struct.unpack(">HHI", d[cm + 4 + 8 * k: cm + 12 + 8 * k])
        if pid == 1 and eid == 0 and struct.unpack(">H", d[cm + off: cm + off + 2])[0] == 0:
            cmap = d[cm + off + 6: cm + off + 6 + 256]
    assert cmap, "no Mac format 0 cmap"
    def loca(g):
        return (struct.unpack(">I", d[T["loca"] + 4 * g: T["loca"] + 4 * g + 4])[0] if long_loca
                else 2 * struct.unpack(">H", d[T["loca"] + 2 * g: T["loca"] + 2 * g + 2])[0])
    def advance(g):
        return struct.unpack(">H", d[T["hmtx"] + 4 * min(g, nhm - 1): T["hmtx"] + 4 * min(g, nhm - 1) + 2])[0]
    tall = 2 * advance(cmap[48]) <= H                  # '0' (one Topaz glyph is 900 wide: not advanceWidthMax)
    u = H >> 4 if tall else H >> 3
    top = snap(asc, u) - 1
    def contours(g):
        o, e = T["glyf"] + loca(g), T["glyf"] + loca(g + 1)
        if o == e:
            return []
        nc = struct.unpack(">h", d[o: o + 2])[0]
        ends = struct.unpack(">%dH" % nc, d[o + 10: o + 10 + 2 * nc]); n = ends[-1] + 1
        p = o + 12 + 2 * nc + struct.unpack(">H", d[o + 10 + 2 * nc: o + 12 + 2 * nc])[0]
        fl = []
        while len(fl) < n:
            f = d[p]; p += 1; fl.append(f)
            if f & 8:
                fl += [f] * d[p]; p += 1
        pts = [[0, 0] for _ in range(n)]
        for axis, short, same in ((0, 2, 16), (1, 4, 32)):
            v = 0
            for i, f in enumerate(fl):
                if f & short:
                    v += d[p] if f & same else -d[p]; p += 1
                elif not f & same:
                    v += struct.unpack(">h", d[p: p + 2])[0]; p += 2
                pts[i][axis] = v
        assert all(f & 1 for f in fl), "curves are not supported"
        cs, s = [], 0
        for e2 in ends:
            cs.append([(snap(x, u), snap(y, u)) for x, y in pts[s: e2 + 1]]); s = e2 + 1
        return cs
    return cmap, contours, advance, u, tall, top

def raster(cs, tall, top):                             # 8 rows (top first) of 8 bits, bit i = column i
    rows = []
    for r in range(8):
        bits = 0
        for k in ([top - 2 * r, top - 2 * r - 1] if tall else [top - r]):   # the grid line under each sampled row
            y2 = 2 * k + 1                             # the row's centre, doubled
            for c in range(8):
                x2 = 2 * c + 1
                w = 0
                for pts in cs:
                    for i in range(len(pts)):
                        (xa, ya), (xb, yb) = pts[i - 1], pts[i]
                        if xa == xb and 2 * xa < x2 and min(ya, yb) * 2 < y2 < max(ya, yb) * 2:
                            w += 1 if yb > ya else -1
                if w:
                    bits |= 1 << c
        rows.append(bits)
    return rows

def font(path):                                        # {zscii: (rows, advance)} for 32..126
    cmap, contours, advance, u, tall, top = parse(path)
    return {ch: (raster(contours(cmap[ch]), tall, top), snap(advance(cmap[ch]), u)) for ch in range(32, 127)}

def kind(path):                                        # zm_ttf's slot: "cell" / "fixed" / "proportional"
    if font(path)[48][1] == 8:
        return "cell"
    return "fixed" if fixed_pitch(path) else "proportional"

def fixed_pitch(path):                                  # post.isFixedPitch (zm_ttf picks the slot by it)
    d = open(path, "rb").read()
    for i in range(struct.unpack(">H", d[4:6])[0]):
        tag, _, off, _ = struct.unpack(">4sIII", d[12 + 16 * i: 28 + 16 * i])
        if tag == b"post":
            return struct.unpack(">I", d[off + 12: off + 16])[0] != 0
    return False

if __name__ == "__main__":
    if "--kind" in sys.argv:
        print(kind(sys.argv[1])); sys.exit(0)
    F = font(sys.argv[1])
    if "--hex" in sys.argv:
        with open(sys.argv[sys.argv.index("--hex") + 1], "w") as f:
            for ch in range(32, 128):
                rows, adv = F.get(ch, ([0] * 8, 0))
                f.write("".join("%02x\n" % b for b in rows) + "%02x\n" % adv)
    if "--png" in sys.argv:
        from PIL import Image
        S = 6
        im = Image.new("RGB", (16 * 9 * S, 6 * 10 * S), (255, 255, 255))
        for ch in range(32, 127):
            rows, adv = F[ch]
            ox, oy = (ch - 32) % 16 * 9 * S, (ch - 32) // 16 * 10 * S
            for c in range(adv):                       # advance shaded
                for r in range(8):
                    for a in range(S):
                        for b in range(S):
                            im.putpixel((ox + c * S + a, oy + r * S + b), (225, 235, 255))
            for r in range(8):
                for c in range(8):
                    if rows[r] >> c & 1:
                        for a in range(S):
                            for b in range(S):
                                im.putpixel((ox + c * S + a, oy + r * S + b), (0, 0, 0))
        im.save(sys.argv[sys.argv.index("--png") + 1])
    print(sys.argv[1], "advances", sorted(set(a for _, a in F.values())), "widest ink",
          max(max((r.bit_length() for r in rows), default=0) for rows, _ in F.values()))
