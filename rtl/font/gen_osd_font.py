#!/usr/bin/env python3
# Converts the MiSTer OSD font (Main_MiSTer charrom.cpp, GPLv3, MiSTer project) into zm_font_osd.hex for zm_disp:
# 256 glyphs x 8 rows, one byte per row, bit i = pixel column i (bit 0 = left). charrom.cpp stores 8 column bytes
# per glyph, bit r = pixel row r (bit 0 = top); it stops at 150.
# 160..255 (Latin-1, what Frotz turns ZSCII 155..223 into) are composed here in the OSD font's style: lowercase =
# the OSD letter (rows 2-6) + an accent in rows 0-1; uppercase = the OSD capital squeezed to 5 rows (small capital)
# + the accent; a few without a base letter are drawn below. Anything else above 150 stays blank.
#   gen_osd_font.py <path to Main_MiSTer/charrom.cpp> > zm_font_osd.hex
import re, sys
src = open(sys.argv[1]).read()
glyphs = [[int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{2})', m)]
          for m in re.findall(r'\{\s*(0x[0-9A-Fa-f]{2}(?:\s*,\s*0x[0-9A-Fa-f]{2}){7})\s*\}', src)]
assert len(glyphs) >= 128, len(glyphs)
glyphs += [[0] * 8] * (256 - len(glyphs))
rows = [[sum(((cols[c] >> r) & 1) << c for c in range(8)) for r in range(8)] for cols in glyphs]

def pat(s):                                            # "..##.." -> row byte (first character = bit 0)
    return sum(1 << i for i, ch in enumerate(s) if ch == '#')

ACC = {                                                # two rows above the letter body
    'grave':  ['.##...', '..##..'], 'acute': ['...##.', '..##..'], 'circ': ['..##..', '.#..#.'],
    'tilde':  ['.##..#', '#..##.'], 'diaer': ['##..##', '......'], 'ring':  ['.####.', '.#..#.'],   # dots: a gap row
}
def lower(base, acc, dotless=False):
    g = rows[ord(base)][:]
    if dotless: g[0] = g[1] = 0
    g[0] |= pat(ACC[acc][0]); g[1] |= pat(ACC[acc][1])
    return g
def small_cap(base, pick=(0, 1, 3, 5, 6)):            # the capital in 5 rows, on rows 2-6
    src_rows = rows[ord(base)]
    return [0, 0] + [src_rows[i] for i in pick] + [0]
def upper(base, acc, pick=(0, 1, 3, 5, 6)):
    g = small_cap(base, pick)
    g[0] = pat(ACC[acc][0]); g[1] = pat(ACC[acc][1])
    return g
def drawn(lines):
    return [pat(l) for l in lines]

L1 = {}
for code, base, acc in [(0xe0,'a','grave'),(0xe1,'a','acute'),(0xe2,'a','circ'),(0xe3,'a','tilde'),(0xe4,'a','diaer'),(0xe5,'a','ring'),
                        (0xe8,'e','grave'),(0xe9,'e','acute'),(0xea,'e','circ'),(0xeb,'e','diaer'),
                        (0xf2,'o','grave'),(0xf3,'o','acute'),(0xf4,'o','circ'),(0xf5,'o','tilde'),(0xf6,'o','diaer'),
                        (0xf9,'u','grave'),(0xfa,'u','acute'),(0xfb,'u','circ'),(0xfc,'u','diaer'),
                        (0xf1,'n','tilde'),(0xfd,'y','acute'),(0xff,'y','diaer')]:
    L1[code] = lower(base, acc)
for code, acc in [(0xec,'grave'),(0xed,'acute'),(0xee,'circ'),(0xef,'diaer')]:
    L1[code] = lower('i', acc, dotless=True)
for code, base, acc in [(0xc0,'A','grave'),(0xc1,'A','acute'),(0xc2,'A','circ'),(0xc3,'A','tilde'),(0xc4,'A','diaer'),(0xc5,'A','ring'),
                        (0xc8,'E','grave'),(0xc9,'E','acute'),(0xca,'E','circ'),(0xcb,'E','diaer'),
                        (0xcc,'I','grave'),(0xcd,'I','acute'),(0xce,'I','circ'),(0xcf,'I','diaer'),
                        (0xd2,'O','grave'),(0xd3,'O','acute'),(0xd4,'O','circ'),(0xd5,'O','tilde'),(0xd6,'O','diaer'),
                        (0xd9,'U','grave'),(0xda,'U','acute'),(0xdb,'U','circ'),(0xdc,'U','diaer'),(0xdd,'Y','acute')]:
    L1[code] = upper(base, acc)
L1[0xd1] = upper('N', 'tilde', pick=(0, 2, 3, 4, 6))
L1[0xe7] = rows[ord('c')][:7] + [pat('...##.')]                      # c cedilla
L1[0xc7] = small_cap('C')[:7] + [pat('...##.')]                      # C cedilla
o = rows[ord('o')][:]; o[1] |= pat('.....#'); o[7] |= pat('#.....')  # o / O slash: a thin stroke through
for r, c in [(2,4),(3,3),(4,2),(5,1),(6,0)]: o[r] |= 1 << c
L1[0xf8] = o
O = small_cap('O'); O[1] |= pat('.....#'); O[7] |= pat('#.....')
for r, c in [(2,4),(3,3),(4,2),(5,1),(6,0)]: O[r] |= 1 << c
L1[0xd8] = O
L1[0xdf] = drawn(['.####.', '##..##', '##.##.', '##..##', '##..##', '##.##.', '##....', '......'])   # sharp s
L1[0xe6] = drawn(['......', '......', '##.##.', '..#..#', '.#####', '#.#...', '.##.##', '......'])   # ae
L1[0xc6] = drawn(['......', '......', '.#####', '#.#...', '#####.', '#.#...', '#.####', '......'])   # AE
L1[0xfe] = drawn(['##....', '##....', '#####.', '##..##', '##..##', '#####.', '##....', '##....'])   # thorn
L1[0xde] = drawn(['......', '......', '##....', '#####.', '##..##', '#####.', '##....', '......'])   # Thorn
L1[0xf0] = drawn(['.##.#.', '...##.', '.#..##', '.#####', '##..##', '##..##', '.####.', '......'])   # eth
D = small_cap('D'); D[4] |= pat('####..'); L1[0xd0] = D                                              # Eth
L1[0xa3] = drawn(['..###.', '.##..#', '.##...', '####..', '.##...', '.##...', '######', '......'])   # pound
L1[0xab] = drawn(['......', '......', '..#..#', '.#..#.', '#..#..', '.#..#.', '..#..#', '......'])   # <<
L1[0xbb] = drawn(['......', '......', '#..#..', '.#..#.', '..#..#', '.#..#.', '#..#..', '......'])   # >>
L1[0xa1] = [0] + [rows[ord('!')][6 - i] for i in range(7)]                                          # upside-down !
q = rows[ord('?')]
L1[0xbf] = [0] + [int('{:08b}'.format(q[6 - i])[::-1], 2) >> 2 for i in range(7)]                  # upside-down ?
for code, g in L1.items():
    rows[code] = g
for g in rows:
    for b in g:
        print('%02x' % (b & 0xFF))
