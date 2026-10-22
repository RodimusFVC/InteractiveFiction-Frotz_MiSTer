#!/usr/bin/env python3
# Sorts an Infocom story archive (flat "Title (Release N).zV" files + "Additional Data/" + "Incomplete/") into one
# folder per title, the layout games/Frotz/ uses on the SD card:
#   <Title>/<original file names>, its V6 pictures (.mg1 .eg1 .eg2 .cg1) and Sound/
#   _Unfinished/<Title>/...       unreleased / incomplete games
#   _Unused/...                   files the core doesn't use (kept, not deleted)
# Files named with a short title (Zork0 / Zork1-3, "Leather Goddesses Of Phobos") are renamed to the folder's title.
# Story copies in Additional Data that are byte-identical to a release file are removed. Nothing is overwritten.
#   sort_archive.py <archive dir> [--do]      (without --do: print the plan only)
import hashlib, os, re, shutil, sys

root = sys.argv[1]
do = "--do" in sys.argv[2:]

TITLE = {                                              # file-name prefix -> folder (display) name
    "Zork1": "Zork I", "Zork2": "Zork II", "Zork3": "Zork III", "Zork0": "Zork Zero",
    "Leather Goddesses of Phobos": "Leather Goddesses of Phobos",
    "Leather Goddesses Of Phobos": "Leather Goddesses of Phobos",
}
EXTRA = {                                              # Additional Data folder -> title folder
    "Arthur": "Arthur", "Journey": "Journey", "Shogun": "Shogun", "Zork0": "Zork Zero",
    "Lurking Horror": "Lurking Horror", "Sherlock": "Sherlock",
}

def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

plan = []                                              # (action, src, dst)
top = {}
for f in sorted(os.listdir(root)):
    p = os.path.join(root, f)
    if not os.path.isfile(p):
        continue
    m = re.match(r"(.+?) \((?:Solid Gold )?(?:Release|Beta) [^)]*\)\.z[1-8]$", f)
    assert m, f"unrecognised top-level file: {f}"
    t = TITLE.get(m.group(1), m.group(1))
    plan.append(("move", p, os.path.join(root, t, t + f[len(m.group(1)):])))
    top[md5(p)] = f

inc = os.path.join(root, "Incomplete")
for f in sorted(os.listdir(inc)):
    p = os.path.join(inc, f)
    m = re.match(r"(.+?) \(Release [^)]*\)\.z[1-8]$", f)
    if m:
        plan.append(("move", p, os.path.join(root, "_Unfinished", m.group(1), f)))
    else:
        plan.append(("move", p, os.path.join(root, "_Unused", f)))   # e.g. checkpoint-r46.zip: ZIL source, no story

add = os.path.join(root, "Additional Data")
for d in sorted(os.listdir(add)):
    dp = os.path.join(add, d)
    for f in sorted(os.listdir(dp)):
        p = os.path.join(dp, f)
        if d not in EXTRA:                             # Beyond Zork: WinFrotz + its own story copy and font
            plan.append(("move", p, os.path.join(root, "_Unused", "Beyond Zork (WinFrotz)", f)))
        elif os.path.isdir(p):                         # Sound / sound
            plan.append(("move", p, os.path.join(root, EXTRA[d], "Sound")))
        elif re.search(r"\.z[1-8]$", f):
            h = md5(p)
            assert h in top, f"{d}/{f} matches no release file"
            plan.append(("remove", p, f"identical to {top[h]}"))
        else:                                          # pictures: named after the title (Zork0.mg1 -> Zork Zero.mg1)
            plan.append(("move", p, os.path.join(root, EXTRA[d], EXTRA[d] + os.path.splitext(f)[1])))

for a, s, d in plan:
    print(f"{a:6} {os.path.relpath(s, root)}  ->  {d if a == 'remove' else os.path.relpath(d, root)}")
    if a == "move":
        assert not os.path.exists(d), f"target exists: {d}"
print(f"{len(plan)} actions" + ("" if do else " (dry run; --do to apply)"))
if do:
    for a, s, d in plan:
        if a == "move":
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.move(s, d)
        else:
            os.remove(s)
    for d in ("Incomplete", "Additional Data"):        # now empty: remove bottom-up
        for dp, dn, fn in os.walk(os.path.join(root, d), topdown=False):
            assert not fn, f"left behind: {dp} {fn}"
            os.rmdir(dp)
    print("done")
