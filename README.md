# Frotz_MiSTer

A native Z-machine interpreter for MiSTer: Infocom's interactive fiction run directly in the FPGA (no soft CPU,
no ARM software). The interpreter, screen model and save format follow Frotz and the Z-Machine Standard 1.1.

**Status:** in development. Versions 1–5, 7 and 8 run, checked in simulation instruction by instruction and screen by
screen against Frotz 2.55 on every Infocom V1–V5 story (V3–V5 also played on hardware). Version 6 (Zork Zero, Shogun,
Journey, Arthur) with its pictures (MCGA, EGA, CGA, Blorb) and the Zork Zero font runs in simulation, every screen
identical to the reference; Zork Zero also played on hardware.

## Install

| What | Where on the SD card |
|---|---|
| The core (`Frotz_<date>.rbf`) | `_InteractiveFiction/cores/` (make the folders; `cores` is hidden from the menu) |
| Launchers (`releases/`: `*.mgl`, `_alternatives/`, `_Unfinished/`) | `_InteractiveFiction/`: one per game (the final release, Solid Gold where there is one); other releases in `_alternatives/_<Title>/`; unreleased games in `_Unfinished/` |
| Stories and pictures | `games/Frotz/<Title>/`, unreleased games in `games/Frotz/_Unfinished/<Title>/` (`tools/sort_archive.py` sorts a flat Infocom archive into this layout) |
| Font (optional) | `games/Frotz/Fonts/AmigaTopazUnicodeRus.ttf`: **Amiga Topaz** by dMG, downloaded by you from [fonts2u.com](https://fonts2u.com/amiga-topaz-unicode-rus.font) (not included); the launchers load it for every game (V6 then uses Amiga Frotz's layout). Use the file exactly as downloaded; the core reads TrueType files itself. Without it the core uses its built-in font. **Flathead** by Kawa (`FlatheadRegular.ttf` / `FlatheadMono.ttf`, the MS-DOS Infocom MCGA font; [IF Archive](https://ifarchive.org/indexes/if-archive/infocom/fonts/): `flatheadregular.zip` holds both) also works, through Load Font, when Topaz isn't loaded |
| Saves | `saves/Frotz/<story>.sav`, created automatically |

A launcher starts the core and loads its story (and, for V6, its Blorb, EGA and CGA pictures, so the OSD can switch
between them) in one pick. **To change games:** F12,
Right arrow, **Core**: MiSTer opens the folder the launcher came from, i.e. the game list. (The OSD's Load Story entry
is only there until a story is loaded; launchers use it.) Stories can also be loaded
directly with Load Story. Homebrew or other stories: copy any launcher, rename it and change its path (relative to
`games/Frotz/`). `tools/gen_mgl.py` rebuilds all the launchers from the sorted archive.

Each story gets one save file with ten slots (0–9). Slot *n* is a standard **Quetzal** save (the format Frotz and
most interpreters use) stored at byte *n* × 128 KB. **Slot 0 is a plain `.qzl` file**, so a save from another
interpreter can be copied over `<story>.sav` and loaded as slot 0. Copy a save into `saves/Frotz/` **before** loading the story:
the core reads the save file's size when the story loads. To copy slot *n* out: `dd if=<story>.sav of=slot.qzl bs=128k skip=n count=1`.
Slots 10–15 of the same file hold the small data files some games save by name (SAVE with a table): no prompt, the
game's own name picks the slot.

### Blorb files

A Blorb (`.blb`, [the standard](https://www.eblong.com/zarf/blorb/blorb.html); [introduction](https://inform-fiction.org/zmachine/standards/blorb/index.html))
packs a game's pictures and sounds into one file. The core uses a resource-only Blorb next to the story (the story stays a
separate `.z?` file): Lurking Horror's and Sherlock's sounds, and the V6 games' pictures as an alternative to `.mg1`.
Blorb tools (perlBlorb, blorbtools, the lblorb suite, ztools) build them from the original Infocom files: the MS-DOS
`.SND` sounds and the `.mg1` pictures.

What the core reads:

- Pictures: palette PNGs (1/2/4/8-bit, not interlaced), `Rect` placeholders, `APal` (adaptive palette), `RelN` (picture 0
  returns it). Pictures are drawn 1:1 (`Reso` is not read; every Infocom Blorb is 1:1 at 320 x 200). Not supported: JPEG,
  full-colour PNGs.
- Sounds: 8-bit mono AIFF. Not supported: Ogg Vorbis, MOD, 16-bit or stereo samples. V3 repeats follow Frotz's table for
  Lurking Horror (the same as its Blorb's `Loop` chunk).
- The Blorb's `IFhd` is not checked against the story, so one Blorb serves every release of a game.

### Transcripts

SCRIPT is not supported. The game still prints its "Here begins a transcript" banner, but nothing is recorded and the
save file is not touched.

## Keys

| Key | |
|---|---|
| Typing, Return, Backspace | command line |
| Cursor keys, F1–F12, keypad digits | passed to the game: single-key input gets them all; at the command line they act only if the game lists them as command keys (Beyond Zork: F1–F10 and the keypad) |
| **Shift + F1…F10** | save to slot 1…9, 0 (types `save` and answers the slot prompt) |
| **Ctrl + F1…F10** | restore from slot 1…9, 0 |
| F12 | MiSTer OSD |

The hotkeys work at an empty command prompt. They use the game's own SAVE / RESTORE, so the files are ordinary
Quetzal saves. Typing SAVE or RESTORE yourself shows the slot list and asks for a digit.

## OSD

The launcher loads the story, its graphics and the fonts. Everything about the game is on the **Game Options** page:

- **Text**
  - **Load Font**: a TrueType font file (Amiga Topaz, or Flathead for V6 without Topaz), also mid-game.
  - **Colours**: white on black, black on white, white on blue, yellow on black, blue on black. Games that set their
    own colours (Beyond Zork) override this.
  - **[MORE] Prompts**: pause when a screenful of text has scrolled (on by default).
- **Pictures** (V6 games only)
  - **Graphics**: which graphics set to use (pictures, side art, menu bars, compass rose): **Auto** (the first loaded
    of MCGA, Blorb, EGA, CGA: Blorb with the launchers), Blorb (`.blb`: Infocom's MCGA pictures, a 16-colour palette
    per picture, the default), EGA (`.eg1`/`.eg2`, twice the horizontal detail in 16 fixed colours) or CGA (`.cg1`,
    black and white). The launchers load all three. MCGA (`.mg1`, the same pictures as the Blorb) works when loaded by
    hand. A set that wasn't loaded falls back to Auto. **Changing it restarts the
    story** (the picture sizes decide the game's screen layout): save first. It is one setting for the core, not per game.
- **Sound**
  - **Beep**: what a game's beep does: a tone, a screen flash (as on the Amiga), or nothing.
- **Mouse**
  - **Pointer Speed**: Normal, Slow, Fast, Faster.
  - **Pointer Colour**: the arrow's fill colour.

The main menu keeps **Aspect Ratio** and **Scandoubler Fx** (standard MiSTer video options) and Reset.

## If the core stops

If a game uses something the core doesn't support yet, the core stops and prints
`[Frotz_MiSTer stopped: code N at <address> op <opcode>]` at the bottom of the text, then waits for a reset.
Code 1 = an opcode that isn't implemented yet (V6 ones in particular); 4 = division by zero; 5 = stack overflow;
6 = return from the main routine; 7 = a story version not supported; 8 = put_prop on a missing
property; 9 = memory streams nested deeper than 16; 11 = throw to a deeper frame;
12 = a corrupt save file found after the game state was already replaced;
14 = a V6 newline interrupt inside another one; 15 = a V6 story started without its graphics files (use its launcher).
Please report the whole line.

## Video and CRTs

The core draws its own 640×240 picture at **15.75 kHz / 60 Hz** (80×30 text), for 15 kHz TVs, PVMs and arcade
monitors directly. 31 kHz VGA monitors get it through MiSTer's scandoubler (`forced_scandoubler=1` or a Scandoubler
Fx setting). HDMI is scaled as usual.

For native 15 kHz output, `MiSTer.ini` needs `vga_scaler=0` and `forced_scandoubler=0`, and the OSD's Scandoubler Fx
set to None. With `vga_scaler=1` the analog output carries the HDMI timing instead of the core's.

## Credits

- Interpreter behaviour and screen model: **Frotz** by Stefan Jokisch and contributors; Amiga Frotz 2.55 by David
  Kinder and Ingo Paschke (GPL). Quetzal save format and Frotz's implementation of it: Martin Frost.
- Text font: the **MiSTer OSD font** (Main_MiSTer `charrom.cpp`, GPLv3).
- Beyond Zork's character-graphics font (font 3): the bitmap from Amiga Frotz `amiga.c` (GPL).
- **Amiga Topaz** TrueType by **dMG**, and V6 font **Flathead** by **Kawa** (2014), a recreation of the Zork Zero font.
  The core loads them from the user's own TrueType files (`rtl/zm_ttf.sv`); neither is part of the core or this
  repository.
- Test suites used in development: **Czech** by Amir Karger, **Praxix** by Zarf and Dannii.
- MiSTer framework (`sys/`): the MiSTer project.

## License

GPL v2 or later (see the headers of the source files); `sys/` is under its own licence from the MiSTer project.
