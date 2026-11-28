# Code and data from other projects

Parts of this randomizer are ported from other open-source randomizers and tools for the same remake. Each is used
under its MIT License; the notices are kept below, and the files say in their own comments what they took from where.
The Zig version is a port of the Python version (kept under the tag
[`python-legacy`](https://github.com/AbyssDragonModding/Goggles-of-Truth/tree/python-legacy)), so what the Python version
took from these projects is in the Zig files named below.

## Clawshot

https://github.com/hiKareeem/Clawshot — MIT License, Copyright (c) 2026 Kareem Albaba and the Clawshot contributors.

- `src/formats/evfl.zig`: the event flow (BFEVFL) reader and writer, ported from Clawshot's
  `src/clawshot/formats/evfl.py`. It rewrites all of the remake's flow files byte for byte.
- `src/generator/faststart.zig`: Skip Opening Movie and Skip the Great Deku Tree's Talk (with Mido kept), from
  `src/clawshot/patch/gamedata.py` and `patch/mido.py`.
- `src/generator/door.zig`: Door of Time: Open (the door logic's `Step06` -> `Ready` edit and the ungated Master
  Sword pedestal module), from `src/clawshot/patch/door.py` and `patch/age.py`.
- `src/generator/gamedata.zig`: the save-data values for the start-of-game skips, from
  `src/clawshot/data/fast_start.toml`.
- `src/generator/hints.zig`: the hint kinds, distributions, always/sometimes lists, wording and joke lines from
  `src/clawshot/data/hints.toml`, the choosing method from `src/clawshot/generate/hints.py`, and the Mask of Truth
  flow edit and stone-line layout from `src/clawshot/patch/text.py`. Clawshot's hint data follows OoT Randomizer's
  (https://github.com/OoTRandomizer/OoT-Randomizer, MIT, commit 526b4c8d).
- The Gerudo Membership Card and small-chest findings (0.5.0) were reported by Kareem.

## OotrR

https://github.com/Mozencaz/OotrR — MIT License, Copyright (c) 2026 Mozencaz.

- `src/generator/faststart.zig`: Chests Without Cutscene (`quick_chest`), from
  `src/oot_rando/patching/qol_patches.py`.
- `src/generator/pickups.zig`: building Gold Skulltula drops on the token's own pickup (`Obj_Token_Gold`, with
  `PlayGetEventManyTimes` and `IsPlayGetEventPouchMax`) and shop shelves on the arrow shelf (`Shop_ArrowBundle_01`,
  sold once), after `src/oot_rando/game/item_forms.py`. Since 0.7.3 also, from the same file: reading an item's
  components through its `$parent` chain (`resolve_components`), adding the item's game parameters to the pickup's
  own (`_merge_game_parameters`) and the PouchActorInfo row fallback (`add_rsdb_rows`), which fixed Gold Skulltula
  drops that played their pickup and gave nothing.
- `src/game/world.zig`, `src/game/event_locations.zig`, `src/generator/fill.zig`: Items Shuffled Per Shop (slots per
  shop, one copy of each needed purchase kept), the Business Scrub checks and prices, and the character gift and
  minigame events, from `src/oot_rando/game/extra_sources.py` and `src/oot_rando/randomizer/full_randomizer.py`.
- Key rando (0.7.3): key rings, dungeon boss keys and removed keys, from `src/oot_rando/patching/key_adapter.py`,
  `src/oot_rando/patching/soul_adapter.py` (`build_item_files`), `src/oot_rando/game/tracking_metadata.py`
  (`add_saved_flags`) and the key options of `src/oot_rando/logic/rando_options.py`:
  - `src/generator/keyitems.zig`: the key ring and boss key items, their get texts, the `RandoKeyRing.<dungeon>`
    flags and the `ActionGuide/ActionGuide` hook that applies them (`add_key_hook`);
  - `src/generator/pickups.zig` (`keyItem`): new key items built on the Forest Medallion with the native key's
    model, their own ActorName and RSDB rows, and the 25-character name limit;
  - `src/generator/gamedata.zig` (`addSavedBool`, `addIsGetMember`, the removed-key start values): saved flags with
    the save size grown by 8 bytes each, the IsGet structure entries, `start_dungeon_values`;
  - `src/logic/logic.zig` (`key_dungeons`), `src/generator/fill.zig`, `src/settings/table.zig`: which dungeons have
    key rings and boss keys, their key counts, and the Small Keys / Key Ring Dungeons / Boss Keys choices.

## a55uka/nup

https://github.com/a55uka/nup — MIT License, Copyright (c) 2026 a55uka.

- `src/formats/nup.zig`: the NUP (NX Package) format and reader, a port of the library's `format.py`, `read.py` and
  `access.py` (SPEC.md v1), as vendored by Clawshot (`src/clawshot/pack/_nup`, upstream commit a4840f06).
- `src/game/gamefiles.zig`: choosing the newest base/update package follows Clawshot's `src/clawshot/pack/source.py`.

## Vendored libraries

- `vendor/zstd`: [Zstandard](https://github.com/facebook/zstd) 1.5.7, BSD License (`vendor/zstd/LICENSE`).
- `vendor/Raven`: [Raven](https://github.com/oscar-soirey/Raven) 0.3, the GUI library, Apache License 2.0.
- `vendor/string`: the string library used by the window, built by me since Zig doesnt have a string type.

## Hylia Serif

http://artsyomni.com/hyliaserif - Hylia Serif Beta, a fan-made font after the lettering of the Zelda titles, by Omni
Jacala. Its author's terms: it is free and may not be distributed for profit.

- `src/generator/title_subtitle.pgm`: the title screen's line "Goggles of Truth Randomizer", set in Hylia Serif Beta
  and kept as a small picture (293 x 18 pixels). The font itself is not part of this program.

## MIT License (applies to the parts above from Clawshot, OotrR and nup)

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
