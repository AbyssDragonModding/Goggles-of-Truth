# Goggles of Truth

**An item randomizer for the Switch 2 remake of *The Legend of Zelda: Ocarina of Time* (OoT26), attempting to bring back most of the settings from the classic randomizer (with some additional qol settings).**

## Version **0.7.2** (public beta) · [Discord](https://discord.gg/adSV8cWfBY) ·
[Source](https://github.com/AbyssDragonModding/Goggles-of-Truth)

Goggles of Truth shuffles chests, songs, dungeon rewards, NPC gifts, shop items, Gold Skulltulas and more, and
checks that every seed can be beaten. Its settings follow the classic [OoT Randomizer](https://ootrandomizer.com),
adjusted to what the remake allows. The **Goggles of Truth Randomizer** is the program that makes the seeds.

**No game files are included.** The randomizer reads your own game files (a `.nup` package or an extracted `romfs`
and `exefs`) and writes only the files it changes into a new mod folder. Share seeds and settings strings, never
mod folders.

> [!WARNING]
> **This randomizer is early in development.** Expect bugs and broken logic: items that don't appear or can't be
> picked up, seeds that softlock, settings that don't do what they say. Settings marked *Experimental* are the least
> reliable. Don't play a seed you can't afford to abandon, and keep the spoiler log handy.
> Your test reports make it better: see [Testing and reporting problems](#testing-and-reporting-problems).

*Disclaimer: Claude was used to help build this; it speeds development up a lot. Settings are tested in-game by hand.*
## Contents

- [Features](#features)
- [Why Zig?](#why-zig)
- [What you need](#what-you-need)
- [Getting the randomizer](#getting-the-randomizer)
- [Making a seed](#making-a-seed)
- [Installing a seed](#installing-a-seed)
- [Testing and reporting problems](#testing-and-reporting-problems)
- [Settings](#settings)
- [Command-line tool](#command-line-tool)
- [For developers](#for-developers)
- [Supported game versions](#supported-game-versions)
- [Known issues](#known-issues)
- [Versions](#versions)
- [Credits](#credits)
- 
## Features

Everything the randomizer can do, and how far each part has been tested in-game. The status is the same as the
badge the window shows next to each option:

| Status | Badge | Meaning |
|---|---|---|
| 🟢 **Stable** | green | Confirmed in-game |
| 🟡 **Semi-tested** | yellow (*In Testing*) | Partly confirmed: some of it was seen working, the rest still needs a check |
| 🔴 **Not tested** | red (*Experimental*) | Built and checked on the files, but not yet confirmed in-game |

When only some choices of an option have a different status, they're named in the table.

### World

| Feature | Choices | Status |
|---|---|---|
| Logic Rules | Glitchless | 🟢 Stable |
| | No Logic | 🔴 Not tested |
| Guarantee Reachable Locations | All | 🟢 Stable |
| | Required Only | 🔴 Not tested |
| Kokiri Forest | Closed, Closed Deku, Open | 🟢 Stable |
| Door of Time | Closed, Open | 🟢 Stable |
| Zora's Fountain | Closed, Open | 🟢 Stable |
| Open Death Mountain | Off, On (Zelda's Letter leaves the seed) | 🟢 Stable |
| Rainbow Bridge Requirement | Vanilla, Medallions (1–6), Spiritual Stones, Gold Skulltula Tokens (1–100) | 🟢 Stable |
| The Temple of Time altar shows the bridge requirement and your progress | always on | 🟢 Stable |
| Skip Child Zelda (her, Malon's and Impa's checks can hold any item) | Off, On | 🟢 Stable |
| Skip Epona Race (Epona is yours from the start) | On | 🟡 Semi-tested |

### Items

| Feature | Choices | Status |
|---|---|---|
| Shuffle Songs | Vanilla, Song Locations, Anywhere | 🟢 Stable |
| Shuffle Spiritual Stones / Medallions | Vanilla, Dungeon Reward Locations, Anywhere | 🟢 Stable |
| Shuffle Ocarinas | Off, On | 🟢 Stable |
| Shuffle Kokiri Sword | Off, On | 🟢 Stable |
| Shuffle Weird Egg | Off, On | 🟢 Stable |
| Shuffle Freestanding Items | Off, On | 🟢 Stable |
| Shuffle Freestanding Rupees | Off, On | 🟢 Stable |
| Shuffle Boss Heart Containers | Off, On | 🟢 Stable |
| Character Gifts and Minigames | On | 🟡 Semi-tested |
| Gifts show the model of the item they really give, and their text names it | always on | 🔴 Not tested |
| Shuffle Quest Rewards | Off, On | 🟢 Stable |
| Business Scrubs (the four one-time scrubs) | Off, On; price 10, the game's, or random | 🟢 Stable |
| Shuffle Great Fairy Rewards | Off, On | 🟢 Stable |
| Shuffle Skulltula House Rewards | Off, On | 🟢 Stable |
| Tokensanity (Gold Skulltulas drop shuffled items) | Off, Dungeons Only, Overworld Only, All Tokens | 🟢 Stable |
| Items Shuffled Per Shop (Kokiri Shop included) | Off, 1–4 items or random; price 10 or random | 🟢 Stable |
| Item Pool | Balanced | 🟢 Stable |
| | Scarce, Minimal | 🔴 Not tested |
| Refills Need Their Item (ammo chests give rupees until you have the bag or weapon) | Off, On | 🟢 Stable |

### Dungeon Items

| Feature | Choices | Status |
|---|---|---|
| Maps & Compasses | Vanilla, Own Dungeon, Start With | 🟢 Stable |
| | Remove (replaced by junk) | 🔴 Not tested |
| Small Keys | Vanilla | 🟢 Stable |
| | Own Dungeon | 🔴 Not tested |
| Boss Keys | Vanilla | 🟢 Stable |
| | Own Dungeon (can fail to place items with some settings) | 🔴 Not tested |

### Hints

| Feature | Choices | Status |
|---|---|---|
| Gossip Stone hints | No Hints, Balanced, Strong, Useless | 🟢 Stable |
| Gossip Stones need the Mask of Truth | Mask of Truth Required, No Mask of Truth | 🟢 Stable |

### Quality of Life

| Feature | Choices | Status |
|---|---|---|
| Every seed starts outside the Kokiri Shop (no 30-second black screen) | always on | 🟢 Stable |
| Make All Cutscenes Skippable | Off, On | 🟢 Stable |
| Skip Opening Movie | Off, On | 🟢 Stable |
| Skip the Great Deku Tree's Talk | Off, On | 🟢 Stable |
| Skip Kaepora Gaebora | Off, On | 🟢 Stable |
| Chests Without Cutscene (big chests) | Off, On | 🟢 Stable |
| Skip Area Intro Cutscenes | On | 🟡 Semi-tested |
| Skip Story Scenes | On | 🟡 Semi-tested (a few scenes confirmed, most not yet) |
| Bag Bombs without Goron Bracelet | Off, On | 🟢 Stable |
| Bag Bombs Open Dodongo's Cavern | Off, On | 🟢 Stable |
| Gold Skulltulas Day and Night, Any Age | Off, On | 🟢 Stable |
| Skip Ganon's Trials | Off, On | 🟢 Stable |
| Saria's Song With Just an Ocarina | Off, On | 🟢 Stable |
| Anju Needs Only 1 Cucco | Off, On | 🟢 Stable |
| Poe shop requires only 1 Big Poe | On | 🔴 Not tested |
| The Lost Woods ocarina game gives all its rewards for one won song | always on | 🔴 Not tested |

### The program

| Feature | Status |
|---|---|
| Reads a `.nup` package or an extracted romfs and exefs, and checks the game version | 🟢 Stable |
| Seeds, settings strings and seed presets (Beginner, Standard, Expert) | 🟢 Stable |
| Excluded Locations (checks that only ever hold minor items) | 🟢 Stable |
| Spoiler log (`spoiler.txt`, `spoiler.json`) and test checklist (`checklist.xlsx`) | 🟢 Stable |
| Longshot support: finds the game, follows its updates, switches older seeds off | 🟢 Stable |
| Per-Seed Saves (Longshot, and Lichii and other yuzu-family emulators) | 🟢 Stable |
| Cache Compressed Files: later seeds reuse files compressed before (the mod is byte for byte the same) | 🟢 Stable |
| Command-line tool (`goggles_cli`) | 🟢 Stable |
| Windows, Linux | 🟢 Stable |
| macOS (Intel and Apple Silicon) | 🔴 Not tested (built, but not yet run on a Mac) |

Options the randomizer doesn't support yet (need more investigation) (keysanity, entrance randomizer, cows, ...) are listed with the
reason on the window's **Not Supported** tab. The [changelog](CHANGELOG.md) says which version each setting was
confirmed in.

## Why Zig?

Up to 0.6.2 the randomizer was a Python program. It is now written in [Zig](https://ziglang.org): one small program
per system, with nothing to install, that opens straight away and makes seeds 8.6–12.4× faster, Insane speed gains due to zigs compiled nature and adding multi-threading (uses multiple cpu cores to generate seeds) and caching.

The Python version is deprecated and no longer updated. Its last state is kept under the tag
[`python-legacy`](https://github.com/AbyssDragonModding/Goggles-of-Truth/tree/python-legacy).

### Benchmark

The same settings, the same game files and the same machine, every generator making a complete mod folder
(including the spoiler log and checklist). Three runs per case, each with its own seed; times are wall-clock from
start to exit, averaged.

| Game files | Settings | Python 0.6.2 | Zig 0.7.0 | Zig 0.7.2 | Zig 0.7.2, cache filled | Faster than Python |
|---|---|---|---|---|---|---|
| Extracted romfs | Defaults | 11.6 s | 3.8 s | **1.3 s** | 1.4 s | **8.6×** |
| Extracted romfs | Expert preset | 17.5 s | 4.8 s | **1.6 s** | 1.7 s | **10.9×** |
| `.nup` package | Defaults | 18.5 s | 8.9 s | 2.1 s | **1.5 s** | **12.4×** |
| `.nup` package | Expert preset | 24.0 s | 10.3 s | **2.5 s** | **2.5 s** | **9.7×** |

"Zig 0.7.2" is a seed with an empty cache (or Cache Compressed Files off: the same within ±0.05 s). "Cache filled"
means one seed with the same settings (and another seed number) was made before, as when you make several seeds in a
row.

**Where the time goes:** in 0.7.0, about 90% of a seed was compressing the changed files again for the mod (zstd at
level 16, with the game's dictionaries), one file after another. Reading the game is a small part: a `.nup` costs
only about 0.15 s more to read than an extracted romfs. A `.nup` seed takes longer because the `.nup` holds the
game text in all 16 languages, and each language's text archive (2–3.5 MB) takes 0.3–0.6 s to compress; the
extracted romfs used here only has English.

**What 0.7.2 changed:**
- **The files are compressed on several threads at once** (up to 8, one per CPU core). This is most of the gain,
  for every seed and every setting. Each file is still compressed on its own and written in the same order, so a
  seed comes out byte for byte the same as when the files were compressed one at a time.
- **Cache Compressed Files** reuses files that come out the same as in an earlier seed. With the default settings
  that's the text of all 16 languages, so a `.nup` seed saves another 0.6 s. Gossip Stone hints are written into
  every language's text and differ from seed to seed, so with hints on (Standard and Expert presets) there is
  little to reuse. Making the same seed again (same seed and settings) reuses every file.

Peak memory use (RAM). Compressing eight files at once takes more memory than one at a time:

| Game files | Settings | Python 0.6.2 | Zig 0.7.0 | Zig 0.7.2 |
|---|---|---|---|---|
| Extracted romfs | Defaults / Expert | 186 / 215 MB | 172 / 236 MB | 310 / 354 MB |
| `.nup` package | Defaults / Expert | 377 / 415 MB | 326 / 441 MB | 572 / 689 MB |

<sub>Test machine: AMD Ryzen 9 9950X (16 cores), 64 GB RAM, Windows 11, game files on a local drive. Python 3.15.0
with the 0.6.2 Python randomizer; Zig 0.17.1 `ReleaseFast` builds of `goggles_cli generate` (0.7.0 from its tag).
Seeds `BENCH1`–`BENCH3`. With fewer cores 0.7.2 uses fewer threads, and the gain is smaller. Python 0.6.2 crashes in
its small-chest patch (`qol.py`), so the Python runs used an in-memory fix of that one function (the same fix the
Zig version has). The game files and the Python source were not changed.</sub>

### What else changed for players

| | Python version | Zig version |
|---|---|---|
| Install | Python 3.14+, four pip packages, a setup script | Nothing. Unzip and run. |
| Download | Python (~100 MB installed) + packages | About 5.7 MB on Windows (the program and `raven.dll`) |
| Start | A script checks Python and packages first | Opens straight away |
| Systems | Windows, Linux (macOS untested) | Windows, Linux, macOS (Intel and Apple Silicon) |
| Settings strings | | Work in both versions, in both directions |

The same version, seed and settings string still always makes the same mod, but the Zig version picks items with a
different random number generator, so **a seed number makes a different seed than it did in the Python version**.

## What you need

- A PC with a **Vulkan** graphics driver (any recent NVIDIA, AMD or Intel driver).
- **Your own game files**, either:
  - the game's **`.nup` file** (nothing to extract; it is only read, never changed), or
  - the **extracted romfs and exefs**, side by side:
    ```
    D:\Games\OoT Remake\romfs\     <- folders like Banc, Event, Pack, RSDB, System
    D:\Games\OoT Remake\exefs\     <- the files main and main.npdm
    ```
    Most Switch emulators extract both: right-click the game and choose **Extract RomFS** / **Dump RomFS**, then
    **Extract ExeFS** / **Dump ExeFS**.
- **A supported game version** (see [Supported game versions](#supported-game-versions)).

## Getting the randomizer

1. Download the build for your system from the project's **Releases** page, or [build it yourself](#building).
2. Extract the ZIP somewhere easy to find (not inside your romfs folder).
3. Start it:

| System | Program |
|---|---|
| Windows | `goggles_of_truth_rando.exe` (keep `raven.dll` next to it) |
| Linux | `goggles_of_truth_rando` (keep `libraven.so.0` next to it) |
| macOS (Intel or Apple Silicon) | `Goggles of Truth Randomizer.app` |

If Windows shows **"Windows protected your PC"**, click **More info**, then **Run anyway**.

If macOS says the app **can't be opened** because it's from an unidentified developer, right-click it, choose
**Open**, then **Open** again (once). Move it out of your Downloads folder first: macOS runs apps opened from there
from a read-only copy, where your settings can't be saved.

**Updating:** download the new build and copy your `user_settings.toml` into the new folder. Keep your output folder
with your seeds. (The Python version's git auto-updater isn't part of the Zig version.)

### If something goes wrong

| What you see | What to do |
|---|---|
| "Raven could not start (a Vulkan driver is required)" | Update your graphics driver from NVIDIA, AMD or Intel. |
| "The randomizer couldn't open" | It names an `error_log.txt` next to the program. Attach it when you [open an issue](#opening-an-issue). |
| The game line on ROM Options is red | Your game version isn't supported: see [Supported game versions](#supported-game-versions). |

## Making a seed

1. **ROM Options** tab: choose your game and an **output folder**.
   - **Browse .nup** picks the game's `.nup` file (its own exefs is used for the version check).
   - **Browse folder** picks the extracted romfs folder (or the folder holding `romfs` and `exefs`). The output
     folder can't be inside the romfs.
   - **Playing on PC with [Longshot](https://git.magicbean.dev/MagicBeanDev/Longshot)?** Click **Longshot**. See
     [Playing with Longshot](#playing-with-longshot-pc).
   - The line under the game turns **green** when your version is supported.
2. Optional: **Scan game** checks your files and fills the **Exclusions** tab, where you can double-click a location
   so it never holds an important item.
3. Pick settings on the **World**, **Items**, **Dungeon Items**, **Hints** and **Quality of Life** tabs (hover over an
   option to see what it does), or start from a [seed preset](#seed-presets).
4. Click **Generate Mod**. **Open Folder** opens the output folder. Each seed gets its own folder:

```
<output folder>/GogglesOfTruth_<seed>/
    romfs/            <- the mod itself; this goes into the emulator
    settings.txt      <- version, seed and settings string
    spoiler.txt       <- where every item is, plus a playthrough
    spoiler.json      <- the same, for tools
    checklist.xlsx    <- test checklist (see below)
```

The spoiler and checklist are only written with **Create Spoiler Log** on (ROM Options tab).

**Sharing a seed:** the same **version + seed + settings string** always makes the same mod. Send the seed and the
settings string (copy it from the window or `settings.txt`) so others can make it from their own game files.

### Your saved settings

Everything you change is saved to `user_settings.toml` next to the program, including the game and output folders.
On macOS it's next to `Goggles of Truth Randomizer.app`, not inside it (as are `save_backups`, `cache` and
`error_log.txt`).

- **Reset everything:** close the randomizer and delete `user_settings.toml`. **Reset** (next to the settings
  string) resets only the settings.
- **Edit by hand:** close the randomizer first; every setting is listed with its allowed values and default. An
  invalid value is ignored and the log says so.
- **The `cache` folder** holds compressed files kept by **Cache Compressed Files** (ROM Options > Output, on by
  default): a later seed that writes the same file takes it from there instead of compressing it again. It stays under 1 GB on its own (the files used longest ago go first) and can be deleted at any
  time; it is filled again as you make seeds. Turning the option off makes every seed compress every file, with the
  same result.
- Versions before 0.5.0 kept settings in `.ootr_remake.json` in your user folder. It is read once if
  `user_settings.toml` doesn't exist yet.

## Installing a seed

### Emulator

1. Right-click the game in your emulator and choose **Open Mod Data Location**.
2. Copy the whole `GogglesOfTruth_<seed>` folder there, so you get `<mod data location>/GogglesOfTruth_<seed>/romfs/...`.
3. Enable only one randomizer seed at a time (usually the game's **Properties** > **Add-Ons**).
4. **Start a new save file** for every seed, or use [per-seed saves](#per-seed-saves). A new save starts in front
   of the Kokiri Shop.

Tip: set the output folder to the emulator's mod folder for this game (`<emulator user folder>/load/0400486024DEC000`)
and the randomizer installs seeds and manages saves for you.

### Playing with Longshot (PC)

[Longshot](https://git.magicbean.dev/MagicBeanDev/Longshot) runs the game natively on Windows and Linux.

1. Build the game with the Longshot launcher first.
2. Click **Longshot** next to the output folder. It finds the launcher's game (by default in
   `Games\Longshot\<version>` in your user folder), sets the output folder to its `mods` folder, and fills in the
   launcher's `.nup` if the game field is empty. On the first start this happens by itself.
   A Longshot game somewhere else: choose its `mods` folder (next to `longshot.exe`) with **Browse**.
3. **Close the game, then generate.** Longshot reads mods only when it starts.
4. Longshot loads every mod in `mods`, so older seeds are **switched off** by renaming them to
   `_GogglesOfTruth_<seed>` (seeds before 0.6.0 were `OoTR_Remake_<seed>`). Nothing is deleted; remove the `_` to
   play one again. Other mods are left alone.
5. After a Longshot update (a new `Games\Longshot\<version>` folder), the randomizer switches to the new `mods`
   folder by itself. Seeds in the old folder aren't loaded any more.

### Per-seed saves

With **Per-Seed Saves** on (ROM Options > Output, on by default), every seed keeps its own six save slots. It works
when the output folder is:

- Longshot's `mods` folder (saves in `%APPDATA%\Longshot\save\<account>`, on Linux `~/.local/share/Longshot/save`), or
- an emulator's `load/0400486024DEC000` folder (Eden, Citron, Sudachi, Lichii and other yuzu-family emulators). Older
  seeds are then switched off by moving them to `load/GogglesOfTruth_off`. The emulator's `config/qt-config.ini` says
  where its saves are, and you're warned if it reads mods from somewhere else.

**Close the game first.** Then:

- **Generating** stores your current slots with the seed they belong to and gives the new seed empty slots.
- **Play This Seed** (ROM Options > Seeds and saves, or double-click a seed) switches that seed on, all others off,
  and brings its slots back. ▶ marks the seed that's on, ★ the one whose saves are in the game.

A seed's slots live in `<seed folder>/saves/`. Slots no seed owns (like saves from before) are copied to
`save_backups/` next to the randomizer first; nothing is deleted before it's copied. `option.sav` is shared by all
seeds.

## Testing and reporting problems

### The checklist

Every seed with a spoiler log comes with `checklist.xlsx`. It opens in Excel, LibreOffice or Google Sheets
(**File** > **Import** > **Upload** > **Replace spreadsheet**), with its dropdowns, colours and totals.

**Left block (A–G): the settings.** Version, seed and settings string at the top (copy these into bug reports), a
place for your emulator and name, then every setting with **Expected In-Game**, **How to Test**, **Result** and
**Notes**.

**Right block (J–O): the checks.** Every location by **Region** (roughly in visiting order), with its **Vanilla
Item**, **Randomized Item** (shop items show their price), **Result** and **Notes**.

**Result** is a dropdown, so "not tested yet" and "failed" look different:

| Result | Colour | Use it when |
|---|---|---|
| **Pass** | green | It works as described |
| **Partial** | orange | Mostly works, something is off (say what in Notes) |
| **Fail** | red | It doesn't work |
| *(empty)* | none | Not tested yet |

Tips:
- **Data** > **Create a filter** lets you show one region, or only failures.
- You don't have to test everything. A few checks per region and every setting you can see in-game already help.
- For anything that fails, write what happened: didn't appear, couldn't be picked up, wrong item or text, came back
  after reloading, softlock, crash. Mention what you were doing and which items you had.

**Exporting:** Google Sheets **File** > **Download** > **CSV**, or Excel **Save As** > **CSV UTF-8**. Don't move
columns or delete the top rows, so results can be matched check by check.

### Opening an issue

Open an issue on the repository's **Issues** tab (search existing ones first) and include:

- **Version, seed and settings string** (top of the checklist, or `settings.txt`)
- **Your emulator and its version**, and the game's version
- **What went wrong and where:** the location name, what you expected, what happened
- **Attachments:** the exported checklist `.csv`, `error_log.txt` if the randomizer crashed, and `spoiler.txt` if
  you have it

## Settings

Hover over any option in the window for a full explanation. Each option has a badge showing how far it's been
tested: **Stable** (green, confirmed in-game), **In Testing** (yellow, partly confirmed) or **Experimental** (red,
not confirmed). For a drop-down, the badge follows the chosen option (Item Pool "Scarce" is Experimental,
"Balanced" Stable).

| Tab | What you can change |
|---|---|
| **ROM Options** | Game and output folders, mod name, seed, spoiler log, per-seed saves, the file cache |
| **World** | Logic (glitchless or none); open Kokiri Forest, Door of Time, Zora's Fountain and Death Mountain; the Rainbow Bridge requirement (vanilla, medallions, Spiritual Stones or Gold Skulltula tokens, shown at the Temple of Time altar); skip child Zelda; skip Epona's race |
| **Items** | Songs, Spiritual Stones and Medallions, ocarinas, Kokiri Sword, Weird Egg; freestanding items and rupees, boss Heart Containers, character gifts and minigames, quest rewards, Great Fairies, Skulltula House, Tokensanity, items shuffled per shop, Business Scrubs; item pool size; ammo chests needing their bag |
| **Dungeon Items** | Maps & Compasses, small keys, boss keys |
| **Hints** | Gossip Stone hints (none, balanced, strong, useless) and whether stones need the Mask of Truth |
| **Quality of Life** | Cutscene skips, bombs without the Goron Bracelet, bag bombs open Dodongo's Cavern, Saria's Song with just an ocarina, Gold Skulltulas at any time, skip Ganon's trials, easier minigames |
| **Exclusions** | Locations that only ever hold minor items |
| **Not Supported** | Classic randomizer options the remake can't support yet, and why |

### Seed presets

The **Seed preset** drop-down (bottom of the window) sets every gameplay setting at once; Excluded Locations and
Create Spoiler Log are kept. Presets only use options confirmed in-game. Change anything afterwards and it shows
**Custom** (it shows the preset's name again whenever your settings match one).

| | Beginner | Standard | Expert |
|---|---|---|---|
| Kokiri Forest / Door of Time | Open / Open | Open / Open | Closed / Closed |
| Zora's Fountain / Death Mountain | Open / Open | Closed / Closed | Closed / Closed |
| Skip Child Zelda | On | On | Off |
| Songs | Song Locations | Song Locations | Anywhere |
| Spiritual Stones / Medallions | Vanilla | Vanilla | Anywhere |
| Ocarinas, Weird Egg, freestanding rupees | Not shuffled | Not shuffled | Shuffled |
| Kokiri Sword | In its chest | Shuffled | Shuffled |
| Business Scrubs | Off | On (game's price) | On (random price) |
| Tokensanity | Off | Dungeons Only | All Tokens |
| Items Shuffled Per Shop | Off | Off | 4 items, random prices |
| Maps & Compasses | Start With | Start With | Vanilla |
| Hints | Balanced, no Mask of Truth | Balanced | Balanced |
| Bombs without the Goron Bracelet | On | On | Off |

All three: glitchless logic with every location reachable, balanced item pool, freestanding items, boss Heart
Containers, character gifts, quest rewards, Great Fairies and Skulltula House shuffled, vanilla keys, refills need
their item, and every confirmed cutscene skip and Quality of Life option on.

## Command-line tool

`goggles_cli` makes seeds without the window (handy for scripts and testing):

```
goggles_cli generate --game <.nup or romfs> --out <folder> [--seed S] [--name N] [--settings STRING]
                     [--from-user-settings] [--exefs <folder>] [--no-cache]
goggles_cli check <.nup, romfs or exefs>        check the game version
goggles_cli scan <.nup or romfs>                list the item locations
goggles_cli vanilla-test <.nup or romfs>        logic test on the unshuffled game
goggles_cli dump-world <game> <out.jsonl>       every location, for tools
goggles_cli dump-plan <game> <settings> <out>   the item pool a settings string makes
goggles_cli selftest <game>                     read and rewrite every event flow, byte for byte
```

`--from-user-settings` uses the settings saved by the window. The tool keeps its own `cache` folder next to itself
(Cache Compressed Files); `--no-cache` compresses every file instead, for the same mod.

## For developers

### Building

You need [Zig 0.17.1](https://ziglang.org/download/). Nothing else: zstd is compiled from `vendor/zstd`, and Raven
0.3 comes with prebuilt libraries in `vendor/Raven/lib`.

```bash
zig build                              # debug build of this system: zig-out/<system>
zig build -Doptimize=ReleaseFast       # release build
zig build run                          # build and open the window
zig build cli                          # only the command-line tool
zig build test                         # unit tests
```

Cross-compiling works from any system, and every system gets its own folder in `zig-out`:

```bash
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows   # zig-out/windows
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux     # zig-out/linux
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-macos     # zig-out/macos
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos    # zig-out/macos-aarch64
```

Each folder holds the window, the command-line tool and the Raven library, under the name the program loads:
`raven.dll`, `libraven.so.0` or `libraven.0.dylib` (the macOS library is universal: Intel and Apple Silicon). On
macOS the window and its library are in `Goggles of Truth Randomizer.app` (`Contents/MacOS`), with the icon and
`Info.plist` (version from `src/version.zig`); the command-line tool sits next to the app. The Windows program carries
the icon too (`src/ui/app.rc`); on Linux the window sets it when it opens.
Ship the folder as it is: on Linux and macOS the programs look for the library next to themselves. The Linux window is a
glibc program, because Raven is built against glibc; the Linux command-line tool is static and runs on any
distribution. Release builds leave out debug information, which would hold the build machine's folder paths
(`-Dstrip=false` keeps it). On Windows the window never opens a console window; `-Dconsole=true` gives it one for debugging.

### Releases

GitHub Actions (`.github/workflows/build.yml`) builds Windows, Linux and both macOS versions on every push and keeps
them as artifacts of the run (Actions tab). When a push to `main` carries a version (`src/version.zig`) that has no
Release yet, it also publishes one: tag `<version>`, a ZIP per system, and that version's section of `CHANGELOG.md` as
the notes. To release: raise the version in `src/version.zig` and `build.zig.zon`, add its section to the changelog,
and push.

### Layout

| Folder | What's in it |
|---|---|
| `src/core` | Byte readers, hashes, file system, progress reporting, the seeded random number generator |
| `src/formats` | The game's file formats: zstd, SARC, BYML, BFEVFL event flows, RESTBL, MSBT text, AINB, NUP packages, xlsx, TOML |
| `src/game` | Reading the game (folder or `.nup`), the version check, the location scan |
| `src/settings` | The setting table, presets, settings strings, `user_settings.toml` |
| `src/logic` | Items and the access rules for every region and location |
| `src/generator` | Item pool and fill, hints, every patch written to the mod, compressing on threads (`compressor.zig`) and the file cache (`filecache.zig`) |
| `src/platform` | Longshot, emulator folders and per-seed saves |
| `src/ui` | The window: `main.xml` / `widgets.xml` layouts and `App.zig` |
| `src/cli.zig`, `src/main.zig` | The two programs |
| `vendor` | Raven (GUI), the string library, zstd 1.5.7 |

Coding rules for this repository are in [Agents.md](Agents.md). In short: plain, explicit code that's easy to edit by
hand; allocators passed explicitly (an arena per generation); concrete error sets; and a random number generator
seeded only from the version, seed and settings string, so every system makes identical seeds.

### Tools

The item tracker was a Python program (`Tools/OOTNS2-Tracker`). It is deprecated along with the Python randomizer and
is no longer on `main`: it is kept under the tag
[`python-legacy`](https://github.com/AbyssDragonModding/Goggles-of-Truth/tree/python-legacy/Tools/OOTNS2-Tracker). It will be
rebuilt later with a better layout.

## Supported game versions

The randomizer edits the game's data files, whose layout can change with an update. To avoid broken mods it only
runs on versions it has been checked against, by comparing the SHA-256 of `exefs/main` (inside the `.nup`, or next
to the romfs) with a list of known versions (`src/game/gamecheck.zig`).

| Game version | SHA-256 of `exefs/main` |
|---|---|
| 1.1.1 | `7db9ddfda088c22d219ef13496decd7077c68cd67d4b37f53f4ac46a082768f2` |

If yours isn't supported, update the game and the randomizer to their latest versions. If you're on the latest of
both, open an issue with the hash the randomizer shows.

## Known issues

- **Start a new save for every seed** (or use per-seed saves).
- **Cutscene leftovers:** a chest that held a story item may still play that item's follow-up dialogue, because
  the story flags are set inside those cutscenes.
- **Garbled text box graphics** sometimes. The randomizer doesn't touch UI files, so this is most likely the
  emulator; screenshots are welcome.
- **Cautious logic:** it may expect an item earlier than strictly needed.
- **Zelda's Letter and the Cucco share a slot:** while holding the letter you can't use the Weird Egg's Cucco. Show
  the letter to the Kakariko gate soldier first. (With Open Death Mountain the letter isn't in the seed.)
- **Bag Bombs Open Dodongo's Cavern:** the cavern still plays its opening cutscene.
- **Boss Keys "Own Dungeon"** (experimental) can fail to place items with some settings.

## Versions

Versions are `Major.Minor.Patch`: **Minor** goes up for a new setting or feature, **Patch** for fixes. The version is
part of every seed (the same seed and settings make a different mod in another version), so always say which version
you used. It's shown under the window's title, in `settings.txt` and at the top of the checklist. What changed in each
version is in [CHANGELOG.md](CHANGELOG.md).

## Credits

- Settings and logic modelled on the classic [OoT Randomizer](https://ootrandomizer.com).
- GUI built with [Raven](https://github.com/oscar-soirey/Raven) (Apache-2.0).
- Event flow writer, start-of-game skips, Gossip Stone hints and the Gerudo card / small chest findings from
  [Clawshot](https://github.com/hiKareeem/Clawshot) by Kareem (MIT).
- Chests without cutscene, token-based Gold Skulltula drops, items shuffled per shop, Business Scrubs and the
  character gift list from [OotrR](https://github.com/Mozencaz/OotrR) by Mozencaz (MIT).
- NUP package reader based on [nup](https://github.com/a55uka/nup).
- [zstd](https://github.com/facebook/zstd) (BSD) for the game's compressed files.
- License details: the original repository's
  [docs/THIRD_PARTY.md](https://github.com/AbyssDragonModding/Goggles-of-Truth/blob/main/docs/THIRD_PARTY.md).
- A fan project, not affiliated with or endorsed by Nintendo. Use your own copy of the game.
