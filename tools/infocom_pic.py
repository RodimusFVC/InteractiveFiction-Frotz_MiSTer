#!/usr/bin/env python3
# Infocom V6 picture files (.mg1 MCGA, .eg1/.eg2 EGA, .cg1 CGA): reader + decoder, following Amiga Frotz amiga.c
# (LoadGraphicsFile / os_picture_data / os_draw_picture). Reference model for the core's picture decoder, and
# renders pictures to PNG.
#   File: 16-byte little-endian header (byte 0 part, word 4 picture count, byte 8 directory entry size, word 14
#   version), then entries: number, width, height, flags (words), 3-byte big-endian data offset, and when the entry
#   is 14 bytes a 3-byte palette offset (MCGA). Palette: a count byte, then RGB triples for colours 2..15.
#   Data: LZW, 9..12-bit codes packed LSB first, 256 = clear (back to 9 bits), 257 = end. MCGA / EGA: one value per
#   pixel; CGA with flags bit 0: one value per pixel, 2 white, 3 black; CGA without it: one value = 8 pixels
#   (bitmask, MSB leftmost, 1 white), ceil(width / 8) values per row. Flags bit 0: colour (flags >> 12) is
#   transparent (MCGA 0, EGA 1). Checked 2026-10-21: all 2180 pictures of the four V6 games decode to exactly
#   width x height values (CGA bitmask pictures: ceil(width / 8) x height).
#   infocom_pic.py <file> [--list] [--png <dir> [numbers...]]
import struct, sys

EGA = [(0,0,0),(0,0,170),(0,170,0),(0,170,170),(170,0,0),(170,0,170),(170,85,0),(170,170,170),
       (85,85,85),(85,85,255),(85,255,85),(85,255,255),(255,85,85),(255,85,255),(255,255,85),(255,255,255)]

class PicFile:
    def __init__(self, path):
        self.d = d = open(path, "rb").read()
        self.kind = path.rsplit(".", 1)[1].lower()[:2]          # mg / eg / cg
        self.part, n, self.esize, self.version = d[0], d[4] | d[5] << 8, d[8], d[14] | d[15] << 8
        self.pics = {}
        for i in range(n):
            e = d[16 + i * self.esize: 16 + (i + 1) * self.esize]
            num, w, h, fl = struct.unpack("<HHHH", e[:8])
            data = e[8] << 16 | e[9] << 8 | e[10]
            pal = (e[11] << 16 | e[12] << 8 | e[13]) if self.esize >= 14 else 0
            self.pics[num] = dict(w=w, h=h, flags=fl, data=data, pal=pal)

    def values(self, num):                                   # the LZW-decoded value stream (Amiga Frotz's loop)
        p = self.pics[num]; d = self.d; pos = p["data"]
        seq, val_t = [0] * 3840, [0] * 3840
        bits_per_code, bits_left, bits, count, prev = 9, 0, 0, 257, 0
        out = []
        while True:
            code, i = 0, bits_per_code
            while True:
                if bits_left <= 0:
                    bits = d[pos]; pos += 1; bits_left = 8
                code |= (bits >> (8 - bits_left)) << (bits_per_code - i)
                i -= bits_left; bits_left = -i
                if i <= 0:
                    break
            code &= 0xFFF >> (12 - bits_per_code)
            if code == 256:
                bits_per_code, count = 9, 257
                continue
            if code == 257:
                break
            v, buf = code, []
            if code == count:
                v = prev; buf.append(None)                     # KwKwK: the first character goes last (filled below)
            while v > 255:
                buf.append(val_t[v - 256]); v = seq[v - 256]
            buf.append(v)
            if code == count:
                buf[0] = v
            val_t[count - 256] = v; seq[count - 256] = prev
            count += 1
            if count == (1 << bits_per_code) and bits_per_code < 12:
                bits_per_code += 1
            out.extend(reversed(buf))
            prev = code
        return out

    def rgb(self, num):                                      # -> (width, height, [(r,g,b) or None = transparent], #values)
        p = self.pics[num]; w, h, fl = p["w"], p["h"], p["flags"]
        vals = self.values(num)
        tr = fl >> 12 if fl & 1 else -1                      # flags bit 0: colour (flags >> 12) is transparent
        if self.kind == "cg" and not fl & 1:                 # 8 pixels per value, rows padded to a whole byte
            bpr = (w + 7) // 8; px = []
            for y in range(h):
                for x in range(w):
                    px.append((255,255,255) if vals[y * bpr + x // 8] >> (7 - x % 8) & 1 else (0,0,0))
            return w, h, px, len(vals)
        if self.kind == "cg":
            pal = [(0,0,0), (0,0,0), (255,255,255), (0,0,0)] + [(0,0,0)] * 12
        elif self.kind == "mg":
            pal = [(0,0,0), (255,255,255)] + [(0,0,0)] * 14
            if p["pal"]:
                a = p["pal"] + 1
                pal[2:16] = [tuple(self.d[a + 3 * k: a + 3 * k + 3]) for k in range(14)]
        else:
            pal = EGA
        return w, h, [None if v == tr else pal[v & 15] for v in vals], len(vals)

if __name__ == "__main__":
    f = PicFile(sys.argv[1])
    if "--list" in sys.argv:
        print(f"{sys.argv[1]}: part {f.part}, {len(f.pics)} pictures, entry {f.esize} bytes, version {f.version}")
        for n, p in sorted(f.pics.items()):
            print(f"  {n:4} {p['w']:4} x {p['h']:3}  flags {p['flags']:04x}  data {p['data']:06x}  pal {p['pal']:06x}")
    if "--png" in sys.argv:
        from PIL import Image
        k = sys.argv.index("--png"); out = sys.argv[k + 1]; nums = [int(x) for x in sys.argv[k + 2:]] or sorted(f.pics)
        for n in nums:
            w, h, px, nv = f.rgb(n)
            im = Image.new("RGB", (w, h))
            im.putdata([c or (0, 0, 0) for c in px[: w * h]] + [(0, 0, 0)] * max(0, w * h - len(px)))
            im.save(f"{out}/{f.kind}_{n}.png")
