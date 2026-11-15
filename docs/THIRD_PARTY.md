# Code and data from other projects

Parts of this randomizer are ported from other open-source randomizers and tools for the same remake. Each is used under
its MIT License; the notices are kept below and in the files' own headers.

## Clawshot

https://github.com/hiKareeem/Clawshot — MIT License, Copyright (c) 2026 Kareem Albaba and the Clawshot
contributors.

- `rando/evfl.py`: Clawshot's `src/clawshot/formats/evfl.py`, the event flow (BFEVFL) reader and writer, unchanged
  apart from a header line. It rewrites all 914 of the remake's flow files byte for byte.
- `rando/faststart.py`: `opening_without_movie` (Skip Opening Movie) and `complete_deku_meeting` (Skip the Great
  Deku Tree's Talk with Mido kept), from `src/clawshot/patch/gamedata.py` and `patch/mido.py`.
- `rando/door.py`: Door of Time: Open (the door logic's `Step06` -> `Ready` edit and the ungated Master Sword
  pedestal module), from `src/clawshot/patch/door.py` and `patch/age.py`.
- `rando/gamedata.py`: the save-data values for Skip Saria's Wake-Up Scene and Skip the Great Deku Tree's Talk,
  from `src/clawshot/data/fast_start.toml`.
- `rando/hints.py`: the hint kinds, distributions, always/sometimes lists, wording and joke lines from
  `src/clawshot/data/hints.toml`, the choosing method from `src/clawshot/generate/hints.py`, and the Mask of
  Truth flow edit and stone-line layout from `src/clawshot/patch/text.py`. Clawshot's hint data follows OoT
  Randomizer's (https://github.com/OoTRandomizer/OoT-Randomizer, MIT, commit 526b4c8d).
- The Gerudo Membership Card and small-chest findings (0.5.0) were reported by Kareem.

## OotrR

https://github.com/Mozencaz/OotrR — MIT License, Copyright (c) 2026 Mozencaz.

- `rando/faststart.py`: `quick_chest` and `quick_small_chest` (Chests Without Cutscene), from
  `src/oot_rando/patching/qol_patches.py`, rewritten for `rando/evfl.py`.
- `rando/pickups.py`: building Gold Skulltula drops on the token's own pickup (`Obj_Token_Gold`) and shop shelves
  on the arrow shelf (`Shop_ArrowBundle_01`, sold once for 10 rupees), after `src/oot_rando/game/item_forms.py`.
- `rando/world.py`, `rando/generator.py`: Items Shuffled Per Shop (slots per shop, one copy of each needed
  purchase kept), the Business Scrub checks and prices (`SCRUB_GIFTS`, `scrub_price`), and the character gift
  and minigame events (`NPC_GIFTS`), from `src/oot_rando/game/extra_sources.py` and
  `src/oot_rando/randomizer/full_randomizer.py`.

## a55uka/nup

https://github.com/a55uka/nup — MIT License, Copyright (c) 2026 a55uka. Its notice is also in
`rando/nup/LICENSE.txt`.

- `rando/nup/format.py`, `rando/nup/read.py`: the NUP (NX Package) format and reader, as vendored by Clawshot
  (`src/clawshot/pack/_nup`, upstream commit a4840f06). One change: zstd extents are decompressed with Python's
  standard library (`compression.zstd`) instead of the `zstandard` package.
- `rando/gamefiles.py`: choosing the newest base/update package follows Clawshot's `src/clawshot/pack/source.py`.
- `Tools/OOTNS2-Tracker/nup/`: the same reader for the item tracker, and `NupRomfs` in
  `Tools/OOTNS2-Tracker/extract_item_icons.py` (the same package choice).

## MIT License (applies to the parts above)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of
the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
