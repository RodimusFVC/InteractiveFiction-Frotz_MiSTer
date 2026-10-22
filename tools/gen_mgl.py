#!/usr/bin/env python3
# The core goes in _RodimusCores/_InteractiveFiction/cores/ (hidden from the menu: Main lists only _ folders; as _VCR does).
# Writes the MiSTer .mgl launchers for Frotz_MiSTer from a story archive sorted by tools/sort_archive.py
# (games/Frotz/<Title>/<story files + pictures>, games/Frotz/_Unfinished/<Title>/...). Output = releases/, whose
# contents the Rodimus_MiSTer_DB custom database deploys into _RodimusCores/_InteractiveFiction/ (MGL <rbf> paths are from the SD root):
#   <Title>.mgl                                    main release (Solid Gold where there is one)
#   _alternatives/_<Title>/<Title> (<release>).mgl every other release
#   _Unfinished/<Title> (<release>).mgl
# A V6 launcher first loads every graphics set through Load Graphics (F index 2), so the OSD's Graphics option can switch
# between them (saved with the OSD): the Blorb (Blorb is the core's format: sounds come only from Blorbs; its pictures
# = Infocom's MCGA set as PNG; user 2026-10-22: MG1 only for a game without a Blorb), EGA (.eg1 + .eg2), CGA; the
# core's Auto takes the Blorb. Then the font through Load Font (F index 3, the user's own file in games/Frotz/Fonts/;
# Main skips a file that isn't there and the core keeps its built-in font): Amiga Topaz (dMG's TTF) for every game
# (V6 in Amiga Frotz's 640-unit layout). Flathead isn't loaded: Topaz replaces it whenever Topaz is in, and the six
# items don't hold both. Then the story through Load Story (F index 1; the save file mounts as usual), whose arrival
# starts the game. A V1-5 story whose
# folder has a Blorb with sounds (RIdx 'Snd ' entries: Lurking Horror, Sherlock) loads it first through Load Graphics
# (its BLB extension: zm_snd plays sound_effect from it).
# MAIN KEEPS AT MOST 6 <file> ITEMS (Main_MiSTer support/arcade/mra_loader.h: mgl_item_struct item[6]) and silently
# drops the rest: a 7-item launcher never loaded its story (V6 launchers with every picture set, 2026-10-21).
#   gen_mgl.py <sorted archive dir> <output dir>     (rebuilds the output's *.mgl, _alternatives/ and _Unfinished/;
#                                                     anything else there - the rbf files - is left alone)
import os, re, shutil, sys
from xml.sax.saxutils import quoteattr

arch, outroot = sys.argv[1], sys.argv[2]
out = outroot
MGL_MAX = 6                                            # Main's mgl_item_struct item[6]
TOPAZ = ("Fonts/AmigaTopazUnicodeRus.ttf",)           # every game (zm_ttf: the cell font)
STORY = re.compile(r"(.+?) \(((?:Solid Gold )?(?:Release|Beta) ([0-9]+)([a-z]?)(.*?))\)\.z([1-8])$")

def rank(m, path):                                     # main release: Solid Gold, then plain releases by number, then
    tag, num, suf, extra = m.group(2), int(m.group(3)), m.group(4), m.group(5)   # serial (build date), then no letter
    plain = not extra.strip() and not tag.startswith("Beta")
    with open(path, "rb") as f:
        serial = f.read(0x18)[0x12:0x18]
    return (tag.startswith("Solid Gold"), plain, num, serial, not suf)

def mgl(path, story, pics, snd=()):
    lines = ["<mistergamedescription>", "\t<rbf>_RodimusCores/_InteractiveFiction/cores/Frotz</rbf>"]
    files = [(2, p) for p in list(pics) + list(snd)] + [(3, f) for f in TOPAZ] + [(1, story)]   # delay (s) = after
                                                       # the previous item: 1 for the core to start
    assert len(files) <= MGL_MAX, f"{path}: {len(files)} items, Main keeps {MGL_MAX}"
    lines += [f'\t<file delay="{int(i == 0)}" type="f" index="{x}" path={quoteattr(p)}/>' for i, (x, p) in enumerate(files)]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    assert not os.path.exists(path), path
    with open(path, "w") as f:
        f.write("\n".join(lines + ["</mistergamedescription>"]) + "\n")

def blorbs(folder, rel, usage):                       # the folder's Blorbs holding resources of this usage
    out = []
    for f in sorted(os.listdir(folder)):
        if f.endswith(".blb"):
            with open(os.path.join(folder, f), "rb") as b:
                d = b.read()
            n = int.from_bytes(d[20:24], "big") if d[:4] == b"FORM" and d[12:16] == b"RIdx" else 0
            if any(d[24 + 12 * i: 28 + 12 * i] == usage for i in range(n)):
                out.append(f"{rel}/{f}")
    return out

def sounds(folder, rel):                               # the folder's Blorb, if it holds sounds
    return blorbs(folder, rel, b"Snd ")

def picsets(folder, rel):                              # the picture files per set (EGA: .eg1 then .eg2)
    fs = sorted(os.listdir(folder))
    s = {"mg1": [f for f in fs if f.endswith(".mg1")], "eg": [f for f in fs if re.search(r"\.eg[12]$", f)],
         "cg1": [f for f in fs if f.endswith(".cg1")]}
    s = {k: [f"{rel}/{f}" for f in v] for k, v in s.items()}
    s["blb"] = blorbs(folder, rel, b"Pict")
    return s

os.makedirs(out, exist_ok=True)
for f in os.listdir(out):                             # only what this script writes
    if f.endswith(".mgl"):
        os.remove(os.path.join(out, f))
for d in ("_alternatives", "_Unfinished"):
    if os.path.isdir(os.path.join(out, d)):
        shutil.rmtree(os.path.join(out, d))
count = 0
for title in sorted(os.listdir(arch)):
    folder = os.path.join(arch, title)
    if title.startswith("_") or not os.path.isdir(folder):
        continue
    stories = [(f, STORY.match(f)) for f in sorted(os.listdir(folder)) if re.search(r"\.z[1-8]$", f)]
    if not stories:                                    # Fonts/ (the TTFs live in the archive too)
        continue
    for f, m in stories:
        assert m, f"unrecognised story name: {title}/{f}"
    main = max(stories, key=lambda x: rank(x[1], os.path.join(folder, x[0])))
    sets = picsets(folder, title)
    ps = (sets["blb"] or sets["mg1"]) + sets["eg"] + sets["cg1"]   # every set: Blorb (else MG1), EGA, CGA
    v6 = lambda m: m.group(6) == "6"
    snd = sounds(folder, title)
    mgl(os.path.join(out, title + ".mgl"), f"{title}/{main[0]}", ps if v6(main[1]) else [], [] if v6(main[1]) else snd)
    count += 1
    for f, m in stories:
        if f == main[0]:
            continue
        mgl(os.path.join(out, "_alternatives", "_" + title, f"{title} ({m.group(2)}).mgl"), f"{title}/{f}",
            ps if v6(m) else [], [] if v6(m) else snd)
        count += 1

unf = os.path.join(arch, "_Unfinished")
for title in sorted(os.listdir(unf)):
    for f in sorted(os.listdir(os.path.join(unf, title))):
        m = STORY.match(f)
        if m:
            mgl(os.path.join(out, "_Unfinished", f"{title} ({m.group(2)}).mgl"), f"_Unfinished/{title}/{f}", [])
            count += 1
print(f"{count} launchers in {os.path.normpath(out)}")
