#!/usr/bin/env python3
# Converts Beyond Zork's font 3 (character graphics) from Amiga Frotz 2.55 amiga.c graphic_font[] (GPL, Frotz
# project) into zm_font3.hex for zm_disp: 256 glyphs x 8 rows (only 32..126 drawn), one byte per row,
# bit i = pixel column i (bit 0 = left). amiga.c has 95 glyphs x 8 rows from ' ', bit 7 = left.
#   gen_font3.py <path to Frotz/Source/amiga.c> > zm_font3.hex
import re, sys
src = open(sys.argv[1]).read()
body = re.search(r'static unsigned char graphic_font\[\]\s*=\s*\{(.*?)\};', src, re.S).group(1)
rows = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{2})', body)]
assert len(rows) == 95 * 8, len(rows)
rev = lambda b: int('{:08b}'.format(b)[::-1], 2)
out = [0] * (256 * 8)
for i, b in enumerate(rows):
    out[32 * 8 + i] = rev(b)
for b in out:
    print('%02x' % b)
