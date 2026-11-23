# Changelog

All notable changes to the randomizer. Versions are `Major.Minor.Patch`: a new setting or feature raises the
minor version, a fix raises the patch version. The same seed and settings string make a different mod in a
different version.

## 0.7.3 - 2026-11-22

### Added
- **Key rings and boss keys outside their dungeon** (Dungeon Items tab, all experimental), adapted from
  [OotrR](https://github.com/Mozencaz/OotrR)'s key adapter. The remake's small and boss keys are generic: a key counts
  for the dungeon Link picks it up in, so a key can't simply be placed in another dungeon. So, as in OotrR:
  - **Small Keys: Any Dungeon / Overworld / Anywhere, as key rings.** A dungeon gets one Key Ring item
    (`Item_KeyRing_<dungeon>`) that gives all of its small keys at once (Forest 5, Fire 8, Water 6, Shadow 5,
    Spirit 5, Bottom of the Well 3, Gerudo Training Ground 9, Ganon's Castle 2), wherever it is found: in any
    dungeon, only outside dungeons, or anywhere. The small key chests of those dungeons hold other items.
  - **Key Ring Dungeons:** All Dungeons, Chosen Dungeons (eight ticks, greyed out otherwise) or Random Dungeons
    (each by chance, from the seed). A dungeon without a key ring keeps its small keys where they are.
  - **Boss Keys: Any Dungeon / Anywhere.** Each temple's boss key becomes an item of its own
    (`Item_BossKey_<dungeon>`, "Boss Key (Forest Temple)") that opens that temple's boss door wherever it is found.
    Ganon's Castle's boss key stays in its chest.
  - **Small Keys: Removed / Boss Keys: Removed.** A new save starts with every key dungeon's small keys
    (`DungeonInfo.<dungeon>.SmallKeyNum` and `SmallKeyTotalNum`) or the five temples' boss keys (`IsGetBossKey`); their
    chests hold other items.
  - How it works: the new items are key items built on the Forest Medallion with the native key's model, with their
    own name, RSDB rows, get texts in every language, and a saved `IsGet.<item>` flag listed in the game's IsGet
    structure (so the item is recorded from a chest, a pickup or a gift). Every item get ends in
    `ActionGuide/ActionGuide`, which now first checks each key item of the seed: a key ring got and not yet applied
    adds its keys once (saved flag `RandoKeyRing.<dungeon>`), a boss key got sets `IsGetBossKey`. The save data's
    size fields grow by 8 bytes per new saved flag, as OotrR does. OotrR also gives each new item a cloned pickup event
    (an AI graph) that writes its flag; that part isn't ported, the IsGet structure entry is what records it.
  - The logic expects a dungeon's key ring and boss key before anything in that dungeon (it has no door-by-door
    model), so they are never placed inside their own dungeon. Neither is ever a Skip Child Zelda start item or sold
    in a shop.
  - Checked on the files: the packs, rows, save flags, IsGet entries and hook are written as described; seeds
    generate on the first attempt with every mode (romfs and `.nup`). **Not tested in-game yet** (OotrR: not
    validated in-game either).

- **THIRD_PARTY.md** in the repository and in every download: which file took what from Clawshot, OotrR and nup,
  with their license notices (the README's link pointed at the Python version's copy, no longer on `main`).
- **Your own presets**: type a name and click **Save Preset** (next to the Seed preset list) to keep your settings as
  a preset; it shows in the list with a star and is kept in `custom_presets.toml` next to the program. **Delete
  Preset** removes it.
- **Race preset**: a fast, fair seed for racing, after the classic randomizer's tournament settings (forest exit and
  Door of Time open, 4 medallions for the bridge, rewards on the dungeon bosses, no token, shop or scrub shuffle,
  maps and compasses from the start, Strong hints without the Mask of Truth).
- **`goggles_cli generate --preset NAME`** applies a built-in preset.

### Changed
- **Generate Mod always makes a new seed**: when the seed number in the box was already made, a new one is picked, before in the zig rewrite 0.7.0 -> 0.7.2 this was not the case and considered a bug lost in the translation between the original python implementation and the zig one. 
- **Beginner, Standard and Expert are refreshed** to match how hard each option is: Beginner gets Strong hints and
  every time saver; Standard closes the Deku Tree until you have a sword and shield, puts the stones and medallions
  on the dungeon bosses, shuffles 2 items per shop and keeps maps and compasses in their own dungeon; Expert needs
  all six medallions for the bridge, prices up to 200 rupees and plays by the game's own rules (bombs need the
  Goron Bracelet, Gold Skulltulas keep their time and age, Saria needs Zelda, Anju wants all her Cuccos, Ganon's
  trials stay). A test now checks that no preset uses an experimental option.
- **The Not Supported tab no longer lists Gossip Stone hints, keysanity and scrubsanity**: hints have been in since
  0.5.0, Business Scrubs since 0.5.0, and dungeon keys can now leave their dungeon as key rings and boss key items.
- **The file cache is always on**: the Cache Compressed Files switch is gone from ROM Options > Output. It costs next
  to nothing when no file can be reused and saves a lot when many can, and the mod is the same either way. An old
  `cache_files` line in `user_settings.toml` is ignored; `goggles_cli --no-cache` still skips the cache for
  measuring.
- **Compressing uses about 75% of the CPU cores**, with no fixed limit (on 0.7.2 it was at most 8 threads), so the computer
  stays responsive, and CPUS with more cores make seeds faster. A seed is still byte for byte the same.
- **Builds for Windows and Linux on ARM** (`windows-arm64-cli`, `linux-arm64-cli`): the command-line tool only, since
  the window's library (Raven) has no ARM build for those yet.
- **`zig build` makes a release build** (ReleaseFast) by default; a debug build needs `-Doptimize=Debug`.
- **Each page of the window has its own XML file** (`src/ui/pages`); the window looks the same to the end user, this is purely a maintainability thing.

### Fixed
- **A Gold Skulltula's drop could play its pickup and give nothing** (reported with a token-looking drop). Upgrade
  items such as the Bigger Deku Stick Bag, Nut Bag, Quiver and Wallet inherit their pickup settings
  (`PouchContentRef`) and game parameters from the smaller version's file through `$parent`; the drop was built from
  the item's own file only, so it had no pickup settings. Drops, freestanding pickups and shop shelves are now built
  from the item with everything it inherits, as OotrR does (`item_forms.resolve_components`), and the item's game
  parameters are added to the pickup's own instead of replacing them. An item without a PouchActorInfo row gets the
  template's (OotrR too). Checked on the reported seed's files: the Bigger Deku Stick Bag drop now has its pickup
  settings.

## 0.7.2 - 2026-11-22

Seeds are made 3–6× faster: a `.nup` seed takes 1.5–2.5 s instead of 9–10 s, an extracted romfs 1.3–1.7 s instead
of 4–5 s (README benchmark).

### Changed
- **The mod's files are compressed on several threads at once** (up to 8, one per CPU core). Timing a seed showed
  where its time went: about 90% was compressing the patched files again (zstd level 16 with the game's
  dictionaries), one after another. Reading the game is a small part: a `.nup` costs only about 0.15 s more than
  an extracted romfs. A `.nup` seed took longer because it holds the game text in all 16 languages, and each
  language's message archive takes 0.3–0.6 s to compress (an extracted romfs dump may only have English).
  - Each file is still compressed on its own, and the files are written in the same order afterwards, so the files
    are byte for byte the same as when they were compressed one at a time (checked from a `.nup` and from a romfs,
    Defaults and Expert). Seeds still change with the version number, as always.
  - The game's compression dictionaries are built before the threads start (`zstd.Context.prepare`), since
    building one isn't safe on two threads at once (`src/generator/compressor.zig`).
  - Peak memory use is higher while the files are compressed: up to about 690 MB for a `.nup` seed with the Expert
    preset, against 440 MB in 0.7.0.

### Added
- **Cache Compressed Files** (ROM Options > Output, on by default; `cache_files` in `user_settings.toml`, and
  `--no-cache` for `goggles_cli`). Every compressed file of 32 KB or more is also kept in a `cache` folder next to
  the program, named by the SHA-256 of what it was made from (its bytes, the dictionary, the compression level and
  the zstd version). A later seed that writes the same file takes it from there instead of compressing it again.
  The log says how many files were reused.
  - A cached file is only used when it decompresses to exactly the bytes it stands for, so the mod is byte for byte
    the same with the cache or without it (also checked with damaged cache files, which are deleted and made again).
    It works the same for both kinds of game files: a file compressed for a `.nup` seed is reused by a romfs seed.
  - What it saves depends on the settings. Files that depend on the item placement (stage files, many event flows)
    differ from seed to seed; the text of every language only does when Gossip Stone hints are on. With the default
    settings a `.nup` seed drops from 2.1 s to 1.5 s once one seed was made; with hints on (Standard, Expert) there
    is little to reuse. Making the same seed again reuses every file.
  - The cache stays under 1 GB on its own (the files used longest ago are deleted first) and can be deleted at any
    time. It isn't part of the settings string, so it never changes a seed.

## 0.7.1 - 2026-11-21

### Fixed
- **The randomizer could crash while making a seed.** Two bugs made debug builds of 0.7.0 stop every time (while
  writing the mod files), and with Mask of Truth hints (as in the Expert preset) also while choosing hints. Release
  builds, like the 0.7.0 downloads, didn't stop, but the hint bug read memory that was no longer in use, so it
  could have gone wrong there too. Both are fixed. The mods 0.7.0 made were not affected.

## 0.7.0 - 2026-11-21

The randomizer is now a Zig program. 0.6.2 was never released: everything planned for it is in this version,
listed below under Added, Changed and Fixed.

### The Zig rewrite
- **One small program, nothing to install.** The randomizer used to need Python 3.14+, four pip packages and a
  setup script. It's now a single program per system (Windows, Linux, macOS on Intel or Apple Silicon) with the
  Raven library next to it: about 5.7 MB on Windows. Unzip it and run it, and it opens straight away.
- **2.3–3.4× faster seeds** with about the same memory use (benchmark in the README's "Why Zig?" section).
- **New seeds for the same seed number.** Items are picked with a different random number generator, so a seed
  number gives a different seed than it did in the Python version. The same version, seed and settings string
  still always make the same mod, on every system.
- **Settings strings still work** between the Python and Zig versions, both ways.
- **Updating:** download the new build and copy your `user_settings.toml` into its folder. The Python version's
  git auto-updater isn't part of the Zig version.

### Deprecated
- **The Python version** (0.6.1 and earlier) is deprecated and won't get any more updates. Use this version for
  new seeds. Its last state is kept under the tag `python-legacy`.
- **The Python item tracker** (`Tools/OOTNS2-Tracker`) is deprecated along with it and moved off `main`: it's kept
  under the tag `python-legacy` and won't be updated. It will be rebuilt later with a better layout.

### Added
- **The altar in the Temple of Time tells the Rainbow Bridge requirement.** Reading it (as child or adult) shows
  the inscription as before, then a second sign: "Rainbow Bridge to Ganon's Castle", the requirement with what you
  have of it (e.g. "Medallions: 2/4", "Spiritual Stones: 1/3", "Gold Skulltula Tokens: 12/30"), and "Bow: 1/1
  Light Arrows: 0/1". The numbers are live: the altar's flow (`DoorOfTime:Check_SpiritStoneBase`) counts them
  each time with the game's own actions into three new Int flags that aren't saved, from the same "owned" flags
  the bridge itself reads, or the token count. With Vanilla it says to finish the Shadow and Spirit Temples and
  come back for the Light Arrows. English in every language, like the hints. Confirmed in-game.
- **Character gifts and minigames show and name the item they really give.**
  - Models: the gift flows that show the reward with an actor of their own (the Lost Woods target scrub's bullet
    bags, Darunia's Goron Bracelet, Biggoron's sword, Zelda's Letter) now show the shuffled item's model, the one a
    chest would show. Their own animations are made for the original item, so the new model doesn't move; it
    appears where the original was bound (the scrub's display spot, Darunia's hand).
  - Text: the lines that announce or describe a reward name the shuffled item, in the highlight colour the game
    uses: both shooting galleries, Bombchu Bowling (both prizes), horseback archery (both prizes), the Deku
    Theater, Anju, Talon, the diving game, Biggoron and Zelda (23 lines; e.g. "I'll give you the Hover Boots!").
    A check that keeps its vanilla item keeps its text. Not yet tested in-game.
- **The Lost Woods ocarina game gives all its rewards for one won song** (every seed, no setting). The Skull Kids'
  game (`Npc_SkullKid_Child_02`) used to take three rounds of growing songs, a Blue Rupee, then a Red Rupee, then
  the check (LW Ocarina Memory Game, vanilla a Piece of Heart). The first won round now gives the Blue Rupee, the
  Red Rupee and the check in a row and sets the song length the third round has
  (`Minigame_SkullKidSession_CurrentGradeSoundNumForSession` 8), so a later round gives the third round's reward
  (a Blue Rupee once the check is taken). Not yet tested in-game.

### Changed
- **Skip Epona Race** works a third way, now In Testing: a new save already owns Epona, and Epona's Song as
  adult calls her anywhere you can ride; no race, and Malon's song check isn't needed for her (the logic follows:
  adult and Epona's Song). Found in a real save after Ingo's race (seed NXZ8W3YNXF): a horse is yours when it is
  in the save's horse list, `OwnedHorseList.ActorName` (10 entries), and the race's end leaves
  `Animal_Epona_Adult` in entry 0 with every other horse field (name, tack, body, hair, stats) at its default.
  A first try wrote that entry from Epona's Song during play (`EventTriggerSetGameDataString64`, Index 0): the
  entry was written, but Epona only came after saving and reloading (seed EUWM5Z4VQV), as the game reads the list
  when a save loads. So the new save starts with it: the list's default (one value for all 10 entries) is Epona.
  The song's write stays as a fallback for a save made before. The 0.6.1 way (the song in the ranch counting the
  race as won) is gone. Confirmed in-game (seed M69CJ7HK7X): on a new save, Epona came to her song as adult, with
  no reload. (A song added from the debug menu isn't kept in the save; songs learned at their check are.)
- **Open Death Mountain** takes Zelda's Letter out of the seed. The gate flag it sets
  (`Npc_Hylia_Soldier_003_GateOpen`) is what the letter would set, and the Happy Mask Shop's masks read it, so the
  letter had no use. A Red Rupee takes its place in the pool, and Zelda's check is shuffled (a random item from
  the pool) even with Shuffle Quest Rewards off. The logic's mask trade (the Deku Theater's Skull Mask and Mask of
  Truth, and the Mask of Truth for Gossip Stone hints) follows: Open Death Mountain or the letter.
- **Skip Child Zelda's three start checks** (HC Zeldas Letter, HC Malon Egg, Song from Impa) can hold any item,
  filled like every other check. They used to take only items a new save can simply own (an "obtained" flag
  and a pouch count: 26 kinds of item in a full pool, mostly songs and key items; outside progression only
  Farore's Wind, Nayru's Love and the Stone of Agony), and an empty one was filled with that junk first. Those
  items are still set in the new save; anything else (bags, ammo, rupees, hearts, medallions, tokens...) is
  handed over when a new game starts, at the end of the opening before its autosave, by the same gift call the
  game's NPC and check flows use (`GetPouchContent:GetPouchContentByActorName`, with the item window); the
  opening's event info now lists that flow.
- **Items Shuffled Per Shop puts a real item on every chosen shelf.** Junk landing on a shelf left its normal
  goods, and the pool is mostly junk, so most chosen shelves looked unchanged (seed 83WVJZQBZE: 10 of 13; the
  Kokiri, Market, Goron, Zora and potion shops looked vanilla). After the progression items are placed, each empty
  chosen shelf now takes an item it can sell once (songs, equipment, spells, key items); junk goes on a shelf only
  if no such item is left. Few items qualify (an item a shelf sells must exist once in the seed, so its
  "obtained" flag can hide the bought shelf), so with 3-4 shelves per shop some still keep their goods: about
  10 of 18-28 in test seeds, against 3 of 13 before. Confirmed in-game in the Kokiri Shop (seed FMUSCNWQBR).
- **The Kokiri Shop takes part in Items Shuffled Per Shop.** It never did, though the tooltip listed it: each of
  its eight shelves is placed three times, once for adult Link and twice for child Link, with complementary
  conditions (`Meet_DekuTree_IsAfter_Step02_Exp` and its negation: the stock before and after the Deku Tree), and
  every shelf with a condition was skipped, since the sold-out condition replaces it. A shuffled shelf's child
  copies now get a new computed flag each, "its own condition AND not owned"
  (`Rando_Shop_<item>_[Not_]Meet_DekuTree_IsAfter_Step02_Exp`, read the way the game's own placements read
  computed flags), and the adult copy the plain "not owned" one. A shelf with a condition but no copy for its
  negation can be missing in a way the logic doesn't know (the Market Potion Shop's bug, after the bottle
  tutorial) and is still never shuffled. Confirmed in-game (seed FMUSCNWQBR): the Kokiri Shop sold the Gift of
  Halved Damage and the Gift of Doubled Magic.

### Fixed
- **The Kokiri Sword chest played the sword scene** when Shuffle Kokiri Sword was off (seed 83WVJZQBZE). Its own
  opening event (`Get_StoneOfForest_GetSword`: the chest opening, the sword swing `Dm_Kokiri_0063`, a Navi tip)
  was only removed when the chest held another item. With **Skip Story Scenes** it's now removed for the vanilla
  sword too: the scene sets no save flags, and the normal chest opening gives the sword (the swing and Navi's tip
  are gone). Confirmed in-game (seed FMUSCNWQBR, where it was tied to Chests Without Cutscene; it belongs with the
  story scenes, so it moved there).
- **A Gold Skulltula that dropped a rupee or refill came back after its drop was collected** (Tokensanity; the
  Kakariko tree Skulltula with a Gold Rupee, seed 83WVJZQBZE). Only the token's own pickup logic records the kill,
  and only when the pickup's get event ends; consumables dropped as the game's own pickup, which never does
  (OotrR's notes report the same). They are now token-based like every other drop, built from the item's
  chest form, and every token-based drop's pouch plays the get event on each pickup, even at full capacity
  (`PlayGetEventManyTimes`, `IsPlayGetEventPouchMax`, as OotrR sets them). Without those two, a token-based rupee
  stayed on the ground (0.5.0 test seeds 4 and 6). Rupees and refills now float like the other drops. Confirmed
  in-game (seed FMUSCNWQBR): a Kokiri Forest Skulltula's Purple Rupee was collected and the Skulltula stayed dead.

## 0.6.1 - 2026-11-16

### Added
- **Rainbow Bridge Requirement** (World > Rainbow Bridge, Vanilla by default): what makes the rainbow
  bridge to Ganon's Castle appear. **Vanilla** (after Zelda's Light Arrows scene), **Medallions** (any 1 to 6 of the
  six, set with Medallions Needed), **Spiritual Stones** (all three) or **Gold Skulltula Tokens** (1 to 100, set
  with Gold Skulltula Tokens Needed). Every option also needs the Bow and the Light Arrows, in the game and in the
  logic, since Ganon can't be beaten without them. How the bridge works (`Logic/GanonCastle_Level_Field_00_Prefab`,
  its multi-input links decoded): its two trigger areas exist while the castle quest is past Ready and not past
  Step01 (`Defeat_Ganon_IsAfter_Ready_Exp` AND NOT `..._Step01_Exp`), that is after Zelda's Light Arrows scene
  (`AllSage` sets Step01) and before the bridge scene (`GanonCastle_Adult_Field_Rainbow`, which sets Step02 and makes
  the bridge stay). The chosen requirement is OR-ed into the Ready flag, so the areas, and the bridge scene, come
  once it's met. Zelda's scene no longer sets the quest back to Step01 when the bridge came first. Two first
  versions failed in-game (no bridge): one replaced the Step01 flag (which switches the areas off), and its "3 of 6
  medallions" was one computed flag of 123 entries where the game's own are at most 26; the count is now a chain of
  small flags (at most 9 entries). Checked on 16 seeds (every option, 1/3/5/6 medallions, Beginner and Expert):
  each requirement is exact (one medallion, stone or token short, or no Bow, keeps it away). Confirmed in-game
  with Medallions (3, with the Bow and Light Arrows, no Zelda scene: the bridge appeared). Spiritual Stones and
  Gold Skulltula Tokens go through the same flags (only the requirement part differs: three stone flags, or the
  token count) and are marked In Testing until seen in-game. The fishing pond owner also reads the Ready flag for one line, so that line may change once the
  requirement is met.
  In-game tests of Spiritual Stones and Gold Skulltula Tokens (both with the Light Arrows added last from the
  debug menu) showed no bridge. Every item has two records: its "got it" flag (`IsGet.<item>`) and its pouch
  count (`PouchData.<item>.StockNum`); items given by a debug menu fill the pouch only. Each bridge item (medallions,
  stones, Bow, Light Arrows) now counts as owned when either is set: a small computed flag per item,
  `Rando_Have_<item>` = flag OR count > 0 (opcode 19, the game's own "more than" as `HaveDefeatedEnemy_*` use it).
  Checked offline with items given either way. **Spiritual Stones** then worked in-game (no bridge without the
  stones, the bridge scene once all three and the Bow and Light Arrows were there) and is now stable; Medallions
  was rechecked in-game and works as intended.
  **Gold Skulltula Tokens** then gave the bridge with 0 tokens. The token count's number (opcode 16) was written as
  a U64, like the other entries; the game's own flags write it as a plain signed Int (`[16, 1]` in
  `MiniGame_DampeRace_IsClearLeastOnce`, `[16, 100]` in the 100-token check), so the game most likely read no
  number and "not fewer than 0 tokens" was always true. It's now an Int, also in the pouch-count checks
  (`count > 0`, which only worked by luck). Checked by writing and reading the file back, then in-game: no
  bridge without the tokens, the bridge with them. All four options (Vanilla, Medallions, Spiritual Stones, Gold
  Skulltula Tokens) are now stable, and their tooltips say what each one needs.
- **Number fields in the window** (a SpinBox, for the two counts above); a count is greyed out unless its option
  is chosen.
- **Per-Seed Saves** (ROM Options > Output, on by default; tested in Longshot and in Lichii). Each seed keeps its own save slots,
  in Longshot and in yuzu-family emulators (output folder = the emulator's `load/0400486024DEC000`). Generating
  a seed stores the current slots with the seed they belong to (in `<seed folder>/saves/`) and starts the new
  one with empty slots; **Play This Seed** (new Seeds and saves card on the ROM Options tab) switches a seed
  back on, every other one off, and restores its slots. Slots no seed owns go to `save_backups/` first;
  nothing is deleted before it's copied; `option.sav` is shared. With an emulator, older seeds are switched
  off by moving them to `load/GogglesOfTruth_off`. The game must be closed. Checked on copies of the save
  folders, then confirmed in Longshot and in Lichii: stable.
- **Status badges in the window.** Every option shows a pill-shaped badge instead of "(experimental)" or
  "(needs further testing)" in its name: Stable (green), In Testing (yellow), Experimental (red). A drop-down's
  badge follows the chosen option. The spoiler log, settings.txt and the checklist keep the written status.
  The badges are XML widgets (`rando/ui/widgets.xml`: `Badge`, `StableBadge`, `TestingBadge`,
  `ExperimentalBadge`), registered before the window loads, so their look and colours are defined in one place.

### Fixed
- **Skip Epona Race** works a new way (still experimental). In-game, Epona's Song inside the Lon Lon Ranch fence
  did nothing: the old edit tried to register the ranch's Epona as your horse inside the song's own flow. The
  game does that itself when you ride Epona out over a ranch fence or through the main gate while the Get_Epona
  quest is at exactly AfterWonGambleRace (`Get_Epona`'s `Sub_Get_Epona_EscapeRanch_*_Warp`:
  `EventCopyAndRegisterOwnedHorse`, then the quest's Complete). So the song, as adult inside the fence with no horse
  of your own, now moves the quest to AfterWonGambleRace (as if Ingo's race was won) and then calls the ranch horses
  as usual; ride Epona out of the ranch and she's yours, and from then on Epona's Song calls her. Only once child
  Malon's song scene has played (the quest is then past ReadyForGetEponaSong, which child Malon's scene needs; moving
  the quest on earlier would lose the Song from Malon check), not while riding or racing. A first in-game try paid
  Ingo for a ride (that counts as riding, so the song only called the horses) and Epona didn't come in Hyrule
  Field afterwards; the tooltip now says not to pay for a ride. Still to be tested in a full seed.
- **Epona in the logic** needed only adult Link and Epona's Song. Ingo's race (and Skip Epona Race) also needs the
  Get_Epona quest past ReadyForGetEponaSong, which only child Malon's song scene does (the Song from Malon check,
  whatever it holds), so Epona now also needs that check's rule (child in Hyrule Field with an ocarina).
- **The seed number** in the window stayed the same after changing a setting, so the next seed could overwrite the
  one made before with other settings. Changing any setting now rolls a new seed number when the one in the box was
  already used (made this session, or its folder is in the output folder); a number you typed and haven't used stays.
- **Skip Area Intros** also skips the Temple of Time's first-entry scene (`Dm_TimeTemple_0000`) and adult Link's first
  step out into the ruined Castle Town (`Dm_TimeTemple_0065`; the adult Market's location area waits for it). Both
  are events of their own, emptied down to their visited flags. Not yet tested in-game.
- **Excluded Locations** is now stable. Checked with 12 seeds across the three presets and a maximum-shuffle
  setup, with 25% to 60% of all locations excluded at random: no excluded spot got progression, a key or a
  boss reward, and every seed generated was beatable. Fixed along the way:
  - excluding a song spot with Shuffle Songs: Song Locations (or a boss reward spot with rewards at reward
    spots) made every seed fail, since that spot can only hold a song; such a spot now stays included and
    the log names it;
  - maps and compasses may now go on excluded spots (they're optional), so excluding most of a dungeon
    with Own Dungeon maps and compasses works;
  - when too many locations are excluded to fit the required items, the error now says so.
- **The Gold Skulltula on Ganon's Castle's grounds** was only in logic once all of Ganon's Castle was done. It's on
  the Castle Town side of the rainbow bridge, by the Great Fairy (as in the original game), so it now needs only
  adult Link. That made 100 tokens impossible for a token bridge; it also puts that Skulltula in logic earlier in
  every seed.

### Changed
- **Presets:** Beginner, Standard and Expert now turn on Gold Skulltulas Day and Night, Any Age and Skip Ganon's
  Trials (both confirmed in-game).
- **Skip Ganon's Trials** and **Gold Skulltulas Day and Night, Any Age** are confirmed in-game (the barriers are gone,
  the tower's lift works and the way up to Ganondorf works; night-only Skulltulas appear by day, adult-only ones as
  child) and are no longer marked experimental.
- The **0.6.0 Rainbow Bridge logic** (Shadow and Spirit Medallion quests) is the Vanilla option and now also asks for
  the Bow and the Light Arrows, which Ganon needs anyway.
- **Tooltips of stable settings** say only what the setting does: test notes ("Tested in-game", "confirmed
  in-game"), internal remarks and source credits are gone (the README's Credits list them). Maps & Compasses
  describes Vanilla, Excluded Locations is wrapped like the others, Create Spoiler Log says what the log holds.

## 0.6.0 - 2026-11-15

The randomizer is now called **Goggles of Truth** (an OoT26 randomizer mod); the generator is the **Goggles of
Truth Randomizer**.

### Added
- **Every seed starts outside, in front of the Kokiri Shop.** After "New Game" the screen stayed black for about
  30 seconds. The new-game event (`OpeningEvent:Opening_Introduction`) played `Dm_Kokiri_0030`, Navi's flight
  through the forest to Link's bed and Navi waking him: a 12,544-frame scene, most likely what was loading
  behind the black screen. It no longer plays. Link and Navi are placed on the ground in front of the shop door, the screen fades in, and
  the game's own end of the event runs as before (field music, Navi counted as talked to, the autosave, and a
  starting ocarina if the seed has one). Saria's wake-up scene is part of every seed too: the **Skip Saria's
  Wake-Up Scene** setting is gone, and Link's door is open from the start. **Skip Opening Movie** still decides
  whether the opening movie plays before that. Tested in-game: the black screen is much shorter and Link starts
  by the shop.
- **Skip Area Intro Cutscenes covers the intros that start a quest step.** These were left playing because their
  arrival event also moves a quest on (the Deku Tree's `MeetBoss`, the Goron Ruby's trail and city steps, the
  Zora Sapphire's `Step03`, the Spirit sage's `Step04`, Navi's remark in the crater, Malon's whereabouts at Lon
  Lon Ranch...). Now the intro scene itself is cut out of that arrival event, the same way Skip Story Scenes
  does it, so the rest still runs; the area's name banner becomes its visited flag. Covered: inside the Deku
  Tree, Death Mountain Trail from Kakariko, Goron City from the trail, Death Mountain Crater from Goron City,
  Zora's Domain from the river, Lon Lon Ranch, Castle Town, Sacred Forest Meadow, Desert Colossus, Ice Cavern,
  Shadow Temple and Gerudo Training Ground. Dodongo's Cavern's intro is an event of its own, so it is cut down
  to its visited flag. Still playing: the hookshot-target scene at Lake Hylia that raises the Water Temple's
  pillar (it's what makes the pillar appear), the Shadow Temple's gate scene inside, and the Crater intro when
  you come down from the trail. Also skipped since the debug test: the Water Temple's intro inside
  (`Goto_WaterTemple`, an event of its own, emptied like Dodongo's Cavern) and the first visit inside Ganon's
  Castle (`Dm_InsideGanonCastle_0003`, played by `Defeat_Ganon`; refused before because of its voice-screen
  action, which is presentation). Not yet tested in-game.
- **Gold Skulltulas Day and Night, Any Age** (Quality of Life > Gameplay, off by default).
  Night-only Gold Skulltulas lose their night-only marker (`Enemy_Skulltula_Gold_Nocturnal`) and are there by
  day. The 11 overworld Skulltulas placed only for adult Link get a copy, with the same save flag, at the same
  spot for child Link (Death Mountain Trail, Goron City, Kakariko, Kokiri Forest, Sacred Forest Meadow,
  Zora's River, Gerudo Valley, Hyrule Field), carrying the same shuffled item; it's one Skulltula, so it
  counts once. Not copied: Gerudo's Fortress (child can't go there) and three tied to another object (Lake
  Hylia, Zora's Domain). The logic doesn't count on any of this. Tested in-game: the night-only Skulltulas
  appear by day and the adult-only ones as child (for example Goron City's middle one). Lon Lon Ranch's
  night Skulltulas still stayed away by day: every night-only Skulltula is also run by a night-time logic
  group (`Gimmick_Nighttime_Skulltula_Gold_Appear`, which reads the time of day). Those groups are now
  removed as well; a killed Skulltula's spider web then stays. Tested: Lon Lon Ranch's appear by day. The two
  adult-only Skulltulas on Death Mountain Trail are hidden behind a rock that only adult Link can break (the
  Hammer); child Link's copies are out in the open.
- **Skip Ganon's Trials** (Quality of Life > Gameplay, experimental, off by default). The six trials inside
  Ganon's Castle count as done in a new save: each trial's barrier flag
  (`InsideGanonCastle_Dungeon_BarrierRemove_<trial>`) and its scene's played flag are set, the barrier
  counter starts at 0 and `InsideGanonCastle_IsAllBarrierClear` is set, so the tower is open. The last
  barrier's own event also enables the tower's lift (the played flag of its scene, `Dm_InsideGanonCastle_0090`,
  is set too) and moves the castle quest on to Step04; that step can't be in the save (the rainbow bridge
  appears from Step01 on), so the event that gives Step03 when you first see the tower barrier now gives
  Step04 right after. (Debug test 3: the door was open but the lift didn't work.) The logic then
  needs only the rainbow bridge, the Bow and the Light Arrows to beat Ganon; the trial rooms' own checks still
  expect the trials' items. Not yet tested in-game.
- **Longshot updates are followed.** The launcher installs each Longshot version in its own folder
  (`Games\Longshot\v3.0.0-rc.4`). When the saved output folder is an older version's `mods` folder (by its
  `longshot_version.txt`: `v3.0.0-rc.3` < `-rc.4` < `v3.0.0`), the window switches to the launcher's current
  version when it opens, and the log says so. Seeds in the old folder stay there; the new version doesn't load
  them.

### Fixed
- **Skip Area Intro Cutscenes** (still experimental). The intros are started by each entrance's
  `InitEventName` unless its `InitEventFlag` is true, which the setting already gave. But an intro is also where
  its area gets "visited" (its name banner sets `IsVisitLocation.<area>`, and these areas show the banner only
  in the intro), so a skipped intro left the area unvisited. Those 12 areas now count as visited from the start.
  The skipped Lake Hylia intros are also what put Kaepora on the lake for his ride
  (`Npc_Kaepora_LakeHrl_Appeared_FromValley`), so that's set too. Tested in-game: Kakariko, Hyrule Field,
  Lake Hylia, Zora's River and Fountain, Gerudo Valley, and the Fire Temple, Spirit Temple and Bottom of the
  Well entrances no longer play their intros. The pause maps and the Graveyard, Hyrule Castle and Gerudo's
  Fortress intros still need a check.
- **Skip Kaepora Gaebora** missed some of his talks, checked against the a decompile of the files and Clawshot's notes:
  - his talk on the way to Lake Hylia (`Dm_HrlField_0050`) and in front of Hyrule Castle (`Dm_HrlCastle_0000`)
    still played;
  - his first Hyrule Field talk starts with `Dm_HrlField_0000` and `_0005`; only `_0010` was marked as seen.
    `HavePlayedEvent.Dm_HrlField_0000` also ends the field's music-off stretch, so the field could stay silent;
  - his first talk moves the castle quest (`Goto_HyruleCastle`) to `Step02`, and Castle Town's entry event only
    fires at exactly that step. Without Skip Child Zelda, the chain to Zelda's courtyard could stall. The quest
    now starts at `Step02` (Skip Child Zelda still sets it to complete).

  Not yet tested in-game.
- **Refills Need Their Item** now covers Deku Nuts and Deku Sticks. A nut or stick bundle only counts once you
  have picked up a single nut or stick (that gives you their bag; a bundle doesn't, as the game's item data
  shows), so one found first was lost. Their chests now give a blue rupee until you own the bag, like arrows
  without the Bow.

### Changed
- **Renamed: Goggles of Truth.** The window, the spoiler log, the launch scripts and the README use the new name.
  A seed's folder is now `GogglesOfTruth_<seed>` (was `OoTR_Remake_<seed>`); Longshot support still switches
  off older `OoTR_Remake_*` seeds. The start file is now `goggles_of_truth_rando.pyw` (was `ootr_remake.pyw`);
  `Start Randomizer (Windows).bat`, `run_linux.sh` and the Linux menu entry (`setup_linux.sh`) start it. The
  old `ootr_remake.pyw` stays as a small file that only opens the new one, so shortcuts to it and the restart
  after updating from 0.5.x keep working. After an automatic update, the randomizer also restarts from the
  start file when the file it was started from is gone.
- **The GitHub repository is now https://github.com/AbyssDragonModding/Goggles-of-Truth** (was
  `OOTNS2-Rando`). GitHub forwards the old address, so existing clones keep updating; a new clone's folder
  is called `Goggles-of-Truth`. To point an old clone at the new address:
  `git remote set-url origin https://github.com/AbyssDragonModding/Goggles-of-Truth`.
- **Bombs Usable Without Goron Bracelet** is now **Bag Bombs without Goron Bracelet** (`bag_bombs_no_bracelet`
  in `user_settings.toml`; the old `free_bombs` is read as the new name, and old settings strings still load).
- **Skip Story Scenes skips many more scenes** (still experimental). Every scene the game's quest flows play
  was surveyed (from the ootdump flow dumps), and each one was run through the skip's own safety checks. Added:
  - the rest of each post-boss chain: the Deku Tree's last talk and death, the Deku Sprout, Darunia, Ruto and
    Jabu-Jabu, the lake refilling, Kakariko, the graveyard and the dungeon exits;
  - before the adult temples: Sheik, Mido, Ruto and Nabooru's scenes (the song lessons still play);
  - Ganon's Castle: the first visit, each trial's barrier and sage (the barrier flag is still set), and the
    tower's barrier.
  Left playing on purpose: the Forest Temple elevator and Shadow Temple boat scenes (they move the dungeon), the
  sages after Ganon (part of the ending), the child Zelda / Impa scenes (Skip Child Zelda), Ganondorf, Ganon and
  the ending. A test seed skipped all 84 listed scenes, and none was refused; not yet tested in-game.
- **Skip Story Scenes**: confirmed in-game: the Great Deku Tree after Gohma (skipped, his check given) and
  Saria's Fairy Ocarina on the forest bridge.

## 0.5.1 - 2026-11-15

### Added
- **Longshot support** (the PC version, https://git.magicbean.dev/MagicBeanDev/Longshot). A **Longshot** button
  next to the output folder finds the Longshot game (the launcher's default build in its `builds.json`, or a
  game folder in `Games\Longshot`) and writes seeds to that game's `mods` folder. If the game field is empty, it
  also fills in the `.nup` the launcher was given. On a first start with no output folder, this is done by
  itself. Any folder named `mods` next to a Longshot game (its `longshot_version.txt`) counts, so a game
  elsewhere works with Browse. Longshot loads every mod in its `mods` folder, so after a seed is written there
  the older randomizer seeds are renamed to `_OoTR_Remake_<seed>`, which Longshot skips; nothing is deleted,
  and other mods are left alone. If a seed can't be renamed (the game is running), the log warns. New file
  `rando/longshot.py`. Tested: finding the build on a PC with the launcher, and generating into a test game
  folder (the older seed was switched off, the other mods left alone). Not yet tried in-game with Longshot.
- **Automatic updates for a git clone.** When the randomizer opens, it checks GitHub for a newer version
  (`git fetch`, 15 seconds at most). If there is one, it pulls it with `git pull --ff-only`. If
  `requirements.txt` changed, it installs the new packages. Then it starts again on the new version, and the
  window's log lists the new commits. It never merges or overwrites anything: with changed tracked files,
  commits of your own, or no internet, it skips the update and the log says why. A ZIP download (no `.git`
  folder) is never touched. Turn it off with `auto_update = false` in the new `[app]` section of
  `user_settings.toml`, or with `OOTR_NO_UPDATE=1`. New file `rando/updater.py`. Tested with local test clones
  (pull and restart, up to date, changed files, own commits, unreachable remote, turned off) and in the
  window from a test clone, but not yet against GitHub itself.

### Fixed
- **Skip Kaepora Gaebora missed his Lost Woods talk after Saria's Song** (seed 3LETP69LQZ): going back into the
  Lost Woods after learning the song, Kaepora still stopped you. That talk (`Dm_LostWood_0010`) now counts as
  already seen too. It's talk only (no item or quest step) and starts the same way as his Lost Woods bridge
  talk, which the setting already skips. Not yet tested in-game.
- **An ocarina at a starting check couldn't be played** (Skip Child Zelda, seed 3LETP69LQZ). The Ocarina of Time
  at HC Malon Egg was in the menu from the start, but it couldn't be played, and Link held no ocarina in Saria's
  song scene. The save only marked it as owned. The game's own ocarina scenes also record which ocarina Link
  holds, so a starting ocarina is now given by the same action, right after Navi wakes Link (no item window).
  Make a new save. Confirmed in-game: the ocarina is in the menu, plays, and shows in Saria's scene.

## 0.5.0 - 2026-11-13

### Added
- **Your settings are saved in `user_settings.toml`**, next to `ootr_remake.pyw`, instead of `.ootr_remake.json`
  in your user folder. The window loads it when it opens and saves it on every change (before, only when you
  pressed Generate Mod), with the game and output folders. Delete it to reset everything. It's a readable
  TOML file that lists every setting with its allowed values and default, so it can be edited by hand while the
  window is closed. An invalid or unknown value is ignored, the default is used, and the log says so. An
  existing `.ootr_remake.json` is read once and left alone. `user_settings.toml` is in `.gitignore`.
- **Seed presets: Beginner, Standard and Expert** (the Seed preset drop-down next to the settings string). A
  preset sets every gameplay setting; Excluded Locations and Create Spoiler Log are kept. Presets use only
  options confirmed in-game. The drop-down shows Custom once you change something, and the preset's name
  whenever your settings match one. The README has a table of what each preset sets. Not yet tried in the
  window by hand: an automated test applied each preset through the window's own code and checked the
  controls, the drop-down and the saved file.
- **Read the game from a .nup file.** The game field (ROM Options) takes your game's `.nup` package as well as the
  extracted romfs folder: **Browse .nup** picks the file, **Browse folder** the romfs. The randomizer reads every
  file it needs straight from the package (the newest base or update inside it), checks each one against the
  SHA-256 stored in the package, and never changes the `.nup`. The game version check uses the package's own
  `exefs/main`, so no exefs folder is needed. Choosing the game folder that holds `romfs` and `exefs` also works
  now. The separate exefs folder field is gone: with a romfs folder, the exefs is found next to it
  (`<game>/romfs` and `<game>/exefs`), and the line under the game field turns green when the version is supported. A path from the folder dialog
  is cleaned up first (quotes, `file://` form, trailing separator), and choosing a folder inside the romfs (such
  as `romfs/Banc`) or the game folder finds the romfs and its exefs; when the exefs is missing, the message names
  the folder it looked in. The `.nup` reader is a55uka/nup (MIT), as Clawshot ships it.
- **The item tracker reads a .nup too** (`Tools/OOTNS2-Tracker`): its setup window has **Browse .nup...** next
  to **Browse folder...**, and the icons are extracted straight from the package. `extract_item_icons.py
  --romfs` also takes a `.nup`. The tracker has its own copy of the reader (`nup/`), so it still runs on its
  own.
- **Items Shuffled Per Shop** replaces Shopsanity (experimental; from OotrR). Every shop takes part: Kokiri,
  Goron and Zora, the Market's bazaar, potion shop and Bombchu shop, and Kakariko's bazaar and potion shop. Choose
  1 to 4 shelves per shop, or 1 to 4 at random. Each shuffled shelf is bought once, at the **Shop Prices**
  setting's price: 10 rupees, random from 10 to 99, or random from 10 to 200 (rounded to 5; above 99 needs the
  Adult's Wallet in the logic). One
  shelf of every purchase you need (shields, tunics, Blue Fire, bugs, fish, fairies) stays on sale. A shuffled
  shelf is now a new actor at that spot instead of an edited shelf type, which is what lets the bazaars and
  potion shops take part.
- **Business Scrubs** (experimental; from OotrR): the four scrubs that sell one thing once (the Lost Woods stick
  and nut upgrades, the Hyrule Field and Death Mountain Crater Pieces of Heart) sell random items. The price is
  its own setting, **Business Scrub Prices**: 10 rupees, the game's price (40 / 100), random from 10 to 99 or
  random from 10 to 200 (above 99 needs the Adult's Wallet in the logic). Each scrub's sale line names the item
  it really sells ("Ohhh, Silver Scale! Shimmery glimmery! It's 10 rupees."), in English in every language, like
  the hints. Settings strings from before keep their scrub price.
- **Character Gifts and Minigames** replaces Shuffle NPC & Minigame Rewards (needs further testing; from OotrR):
  every gift is now patched at the exact events OotrR lists instead of by matching the vanilla item. New checks:
  the Deku Theater's Skull Mask and Mask of Truth rewards (Deku Stick and Nut upgrades). Settings strings that
  have the old setting keep their value.
- **Shuffle Quest Rewards** (on by default, as before): Zelda's Letter, the Light Arrows and Biggoron's reward,
  which OotrR keeps apart from the gifts.
- **Gossip Stone hints** (new Hints tab, off by default). Hint Distribution: No Hints, Balanced,
  Strong or Useless (Strong and Useless experimental), using Clawshot's hint system (which follows OoT Randomizer's): areas on the Way of the
  Hero, areas that are a waste of time, where some major items are, and what some locations hold. A hint that
  names a location only goes on a stone you can read without that location's item, and unreadable stones get
  the joke lines. All 40 stones are written in every language (in English, with the names highlighted), and
  the hints are listed in the spoiler log.
- **Gossip Stones: Mask of Truth Required / No Mask of Truth** (Hints tab). Required is the original game:
  stones speak only to child Link wearing the Mask of Truth, and hints never name something you need to get
  the mask. No Mask of Truth lets every stone speak to anyone, at any age.
- **Skip Opening Movie** (Quality of Life): a new game starts in Link's house without the
  prologue movie; the game still waits for Kokiri Forest to load. From Clawshot.
- **Skip Saria's Wake-Up Scene** (Quality of Life): Saria doesn't wait at the door, walk Link
  out or greet Navi; the door is open and the pause map works. From Clawshot.
- **Skip the Great Deku Tree's Talk** (Quality of Life): his speech doesn't play and his mouth
  is open. With Mido still blocking, this happens when Mido steps aside. From Clawshot.
- **Chests Without Cutscene** (Quality of Life): big chests open without the camera move and Link's
  opening animation; Link still holds the item up. From OotrR. Small chests keep their own short opening:
  with the quick version they could not be opened at all (0.5.0 test seed 3).
- **Skip Story Scenes** (Quality of Life, experimental, needs additional testing, on by default): the story scenes that come with quest
  progress don't play, and their item is given straight away. Temple of Time: the door opening, Ganondorf,
  pulling the Master Sword and Rauru's talk in the Chamber of Sages (his Light Medallion check). Adult Temple of
  Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows. After a boss: each sage's
  awakening and medallion, and the Deku Tree, Darunia and Ruto handing over the Spiritual Stones. Leaving
  Kokiri Forest: Saria's goodbye on the bridge (the Fairy Ocarina is given at once). These scenes are played by
  the quest flows (`DoorOfTime`, `AllSage`, `Goto_HyruleCastle`, `Dm_SY_BancChange_EscapeDungeon`), so the skip is
  made there: each scene counts as seen (its `HavePlayedEvent` flag, which the quests read) and its item (the
  randomized one) is handed over with the call the scene itself used. The game's event table
  (`GameAnalyzedEventInfo`) lists, for each event, the other flows it calls; an event that calls one it doesn't
  list stops. Each changed event's row now lists `GetPouchContent` (without it, test seed 7 stayed on a white
  screen in the Chamber of Sages after the Master Sword, and in test seed 8 the Master Sword couldn't be pulled and
  Saria's bridge event gave no ocarina). Most of these scenes start on a faded screen and fade it in themselves,
  often from white (the Chamber of Sages is entered with a white fade); a skipped scene now fades in with its
  own colour, and an item scene fades in before its window (test seed 9: the Light Medallion was given behind a
  white screen, so no window showed). Rauru's talk is a talking scene, which the skip button doesn't skip. Song
  lessons, boss intros and the ending still play. Tested in-game so far: Rauru's Light Medallion and Saria's
  Fairy Ocarina (the tooltip says so). Known to still play: leaving the Temple of Time as adult and Ganon's
  Castle's first-visit scene.

### Fixed
- **Skip Epona Race** (experimental) didn't work: Epona never came to Epona's Song (test seed 10). Owning a horse
  isn't a save flag: the end of Ingo's race registers the ranch's Epona as your horse
  (`EventCopyAndRegisterOwnedHorse`), and the song only calls a registered horse. The old version also rewrote
  `Get_Epona_IsCompleted_Exp`, which is the ranch Epona's presence condition, so owning the song made her vanish.
  Now, as adult, playing Epona's Song once inside the Lon Lon Ranch fence (where the song normally calls the
  ranch horses over) does what the race's end does: Epona becomes your horse, Ingo's Epona quest is complete,
  and she comes to you. After that the song calls her anywhere you can ride. Not while riding a rented horse or
  during a race. Test seed 11 (this version's first build): an Epona appeared on Link whenever the ocarina came
  out, at any age, outside the ranch. Taking out the ocarina starts the song's flow, and Epona was named there
  as an actor the event creates when she's missing (`EventMemberCreateMethod` 0). She now uses 3, like the
  game's own flows that name Epona where she may be absent: used if she's in the scene, never created. Not yet
  tested in-game.
- **Tokensanity tooltip**: says that rupees and other refills dropped by Gold Skulltulas fall to the ground (the
  game's own pickup), while shields and real items float.
- **Small chests could not be opened** (0.5.0 test seeds 3 and 4). The map / compass / boss key fix for small
  chests sent the small chest's item step into the big chest's flow file, skipping the small chest's own item
  display. It now adds the big chest's question ("is this the dungeon's map, compass or boss key?") and its
  steps inside the small chest's own flow; small keys and every other item go through the small chest's steps
  as before. Chests Without Cutscene changes big chests only.
- **A bought shop shelf could be bought again** (Items Shuffled Per Shop, test seed 4), even after reloading:
  OotrR's `NoRespawn` setting only acts when a pickup is collected. A shuffled shelf is now hidden once you own
  its item (its `IsGet` save flag), so shelves only sell items that exist once in the seed (songs, equipment,
  key items) or keep their normal goods. Shelves that only appear later in the story (the Kokiri shop's full
  stock) aren't used.
- **Junk dropped by a Gold Skulltula** (Tokensanity, test seeds 4 to 6). A token-based rupee stayed on the
  ground after it was collected and its Skulltula came back; the game's own rupee (as OotrR drops it) fell
  instead of floating; and a token-based copy of its chest form (`TBox_Rupee_Green`, the ammo bundles, ...)
  floated but still wasn't removed when collected (test seed 6). Consumables (rupees, ammo, hearts, magic, the
  Business Scrub Seed) now drop as the game's own pickup, which falls to the ground but is collected and stays
  gone; shields float like the other items. Only the bigger Bombchu bundles have neither and stay off
  Skulltulas. The fill keeps enough other spots free for them, and if a seed runs short it moves an item that
  unlocks nothing (a Piece of Heart, ...) onto a Skulltula to make room; with more such junk than other spots, the
  last Skulltulas keep their own token instead.
- **Door of Time: Open left the door shut** (test seeds 4 and 5): the save flag it set isn't what the door
  follows. It now uses Clawshot's Open mode (the door's logic module and the Master Sword pedestal no longer
  wait for the Door of Time quest past step Ready) and starts that quest at Ready on a new save; it started at
  NotReady, which only moves on later in the story, so the door stayed shut for a player who went straight to
  the Temple of Time. Test seed 6: the door is open, so its *experimental* tag is removed.
- **Songs showed a green rupee in chests** (Songs Anywhere, 0.5.0 test seed 3). Only songs lying in the world
  had the harp model; in a chest, from a character, a scrub or a shelf, and on a Gold Skulltula, the song's own
  item actor still used its placeholder rupee model. The song items themselves now use Sheik's harp model, so a
  song looks like a harp wherever it is found.
- **Gold Skulltula drops** ([issue #2](https://github.com/AbyssDragonModding/Goggles-of-Truth/issues/2)). With
  Tokensanity, a Skulltula on a vine dropped its item where Link couldn't collect it, a dropped rupee fell
  instead of floating, and the Skulltula counted as killed (and never came back) even when its drop was
  lost. Every Gold Skulltula drop is now built on the token's own pickup, as OotrR does: it floats where the
  Skulltula died like a token, is collected by touching it, and the token's logic marks the Skulltula as
  killed only when the drop is collected. Pieces of Heart and Ruto's Letter can be Skulltula drops again.
  Confirmed in-game: drops float and are collected by touch, and a Skulltula whose drop you
  didn't collect comes back when the area reloads.
- **Own Dungeon boss keys, maps and compasses only go in chests.** A boss key could land on the boss's own
  Heart Container, behind the door it opens, so the seed couldn't be finished. On a Gold Skulltula or a
  freestanding spot they only went into the pouch without counting for the dungeon (only a chest's opening
  credits them). Small keys are unchanged. Found in a 0.5.0 test seed's spoiler.
- **The Gerudo Membership Card is no longer shuffled** (reported by Kareem from the Clawshot randomizer,
  confirmed in the game files). The guards, the wasteland gate, the Training Ground and horseback archery
  check the Spirit quest step that only the captain's scene after the carpenter rescue sets. The card itself
  only stops the guards from jailing you in the sneak areas. With Shuffle NPC & Minigame Rewards on, a card
  found elsewhere left the guards hostile while the logic expected the fortress to be open. The captain now
  always gives the card. The adult trade items were already never shuffled (they share the Cucco's slot and
  would hide it); the tooltip and the Not Supported tab now say so.
- **Boss keys, maps and compasses in small chests didn't count** (reported by Kareem from the Clawshot
  randomizer, confirmed in the game files). Only the big chest's opening credits the dungeon; the small
  chest's opening just put the item in the pouch. With Own Dungeon, a map, compass or boss key could land in
  a small chest, and the boss door stayed shut (the seed couldn't be finished) or the pause map stayed blank.
  Small Chests Only (removed below) did the same to the Boss Key chests. The small chest now gives its item
  through the big chest's item step, which credits the dungeon whatever the chest holds. Applied with Maps &
  Compasses: Own Dungeon or Boss Keys: Own Dungeon. Not yet tested in-game.

### Removed
- **Small Chests Only.** Replaced by Chests without cutscenes: Only for large chests, skips their camera and opening animation. Small chests are still vanilla.

### Changed
- **The randomizer window is now defined in XML** (`rando/ui/main.xml`), Raven's (the randomizers GUI Framework) layout format, instead of
  being built widget by widget in Python. The settings cards are still made from `rando/settings.py`, so
  adding a setting doesn't need an XML change. It looks and works the same.
- **Reorganized the settings tabs.** Main Rules and Other are replaced by tabs grouped by what they change:
  - **World**: Logic, Open Areas (Kokiri Forest, Door of Time, Zora's Fountain, Death Mountain) and Story
    Skips (Skip Child Zelda, Skip Epona Race).
  - **Items**: Quest Items (songs, stones/medallions, ocarinas, Kokiri Sword, Weird Egg), Shuffled Locations
    (freestanding items and rupees, Heart Containers, NPCs, Great Fairies, Skulltula House, Tokensanity,
    Shopsanity) and Item Pool (with Refills Need Their Item).
  - **Quality of Life**: Cutscenes (with Skip Kaepora Gaebora), Gameplay (with Saria's Song With Just an
    Ocarina and Small Chests Only) and Minigames & NPCs.
  - **Create Spoiler Log** moved to the ROM Options tab, next to the seed.
  No setting changed what it does, and settings strings from earlier versions still import.
- **Labels from test seed 12**: Skip Epona Race is now *(experimental, not working)*: Epona still doesn't come
  to Epona's Song, and its tooltip says so and says to leave it off. Big Poe Buyer Needs Only 1 Big Poe stays
  *(experimental)* (no Big Poe sold yet; the tooltip says it's not confirmed). Skip Story Scenes is
  *(experimental, needs additional testing)*.
- **Tooltips of confirmed settings** describe what they do in the game: Door of Time Open (walk in and pull
  the Master Sword without the stones, an ocarina or the Song of Time), Zora's Fountain Open (King Zora stays
  aside, Ruto's reward is still given, the quest log entry stays empty), Shuffle Songs Anywhere (no longer
  "untested"; songs show as a harp on the ground, in chests, on Gold Skulltulas and on shelves), Shuffle Kokiri
  Sword (off keeps the sword scene, also with Chests Without Cutscene), Items Shuffled Per Shop (a bought shelf
  stays gone after reloading) and Chests Without Cutscene (a story chest keeps its scene).

### Checked
- **Test seed 12:** no Epona appears when the ocarina comes out any more, but Skip Epona Race still doesn't
  work (Epona never came to the song).
- **Tested in-game (0.5.0 test seed):** Gold Skulltula drops (Tokensanity), Gossip Stones with No Mask
  of Truth and Balanced hints, Skip Opening Movie, Skip Saria's Wake-Up Scene, Skip the Great Deku Tree's
  Talk (with Kokiri Forest Closed), Chests Without Cutscene and Kokiri Forest: Closed all work, so their
  *experimental* tags are removed.
- **Tested in-game (test seeds 3 and 4):** Zora's Fountain: Open (King Zora stays moved through every load,
  Ruto's reward is given), Business Scrubs (the line names the item), Hint Distribution (Strong) and Songs
  Anywhere (the harp on the ground, in big chests, on Gold Skulltulas and on shelves) work, so their tags are
  removed. Test seed 5: Shuffle Kokiri Sword (also not shuffled; the sword chest keeps its story scene),
  Items Shuffled Per Shop (a bought shelf is gone for good) and Chests Without Cutscene (big chests quick,
  small chests normal) work, so their tags are removed. Test seed 6: Door of Time: Open works (tag removed);
  Gold Skulltula drops float, but collected junk stayed (consumables now fall as the game's own pickup).
  Test seed 7: Saria's bridge scene still played (now skipped too) and the Master Sword left a white screen in
  the Chamber of Sages. Test seed 8 (a version that skipped the Chamber of Sages): the Master Sword couldn't be
  pulled and Saria's skipped goodbye gave no ocarina. All three were the event table above. Test seed 9:
  Saria's goodbye is skipped and the Fairy Ocarina window shows; the first Master Sword pull skips to the
  Light Medallion, but its window didn't show (the fade colour above). Test seed 10: the Light Medallion window
  shows (Rauru's skip works); Gold Skulltula drops work again (rupees fall, items float); Skip Epona Race
  didn't (fixed above); the Big Poe buyer wasn't reached yet.
- **Your game files are never changed.** The generator only reads the romfs and writes every patched file
  as a copy in the mod folder. I generated a seed with 18 settings on (262 mod files: 190 patched copies
  of game files, 72 new files). Afterwards all 186,587 romfs files had the same size and modified time,
  and none were added or removed. The generator itself now refuses an output folder inside the romfs, as
  the randomizer window already did.

## 0.4.5 - 2026-11-12

### Fixed
- **Shuffle Songs: Anywhere**: a song lying in the world (freestanding, rupee or boss Heart Container spot,
  or dropped by a Gold Skulltula) looked like a green rupee, because songs have no model of their own in the
  remake. Song pickups now show Sheik's harp and keep the song's name. Like every shuffled world item since
  0.4.4, they're collected by walking into them. Not yet tested in-game.

## 0.4.4 - 2026-11-12

### Fixed
- **Skip Child Zelda**: about 1 in 15 setting combinations couldn't be generated ("no item the save can
  grant for HC Malon Egg / HC Zeldas Letter / Song from Impa"). The three checks a new save already owns
  need items the save can simply be given, and with Shopsanity, a Scarce/Minimal pool or Weird Egg shuffle
  the leftover items sometimes had none. The generator now moves a suitable item there from another check
  and puts junk in its place. Found by a 6,810-seed fill simulation.
- **Zora's Fountain: Open**: King Zora was moved aside at first, but after leaving Jabu-Jabu's Belly he sat
  in front of the door again, a softlock. The first arrival in Zora's Domain set the Zora quest back to its
  "first visit" step, and he only showed it after the area reloaded. That arrival now keeps the quest where
  Open starts it. Not yet tested in-game.
- **Tokensanity**: an item dropped by a Gold Skulltula on a vine or wall needed A to pick up, which you can't
  press while climbing, so it could only be collected with the Boomerang or Hookshot.
- **Shuffle Freestanding Items / Freestanding Rupees**: shuffled items lying in the world also needed A
  (for example the rupee spots at Zora's River).

  Shuffled items in the world are now collected by walking into them, like rupees. Pieces of Heart and
  Ruto's Letter still need A, because they use their own pickup logic. For that reason the randomizer no
  longer puts them on Gold Skulltulas. Not yet tested in-game.

- **Door of Time: Closed** logic: going to adult now also expects an ocarina and Zelda met (Impa's send-off
  is a step of the Door of Time quest). The two moat checks (Song from Ocarina of Time, HF Ocarina of Time)
  expect the same. Before, both were only implied by other rules.

### Changed
- **Labels from the 0.4.3 test run (seed W68ETAG92L):** these passed in-game and are no longer tagged:
  Skip Child Zelda, Shuffle Spiritual Stones/Medallions, Shuffle Weird Egg, Shuffle Ocarinas, Shuffle
  Freestanding Rupees, Shuffle Great Fairy Rewards, Shuffle Skulltula House Rewards, Maps & Compasses' Start
  With, Skip Kaepora Gaebora and Small Chests Only. Zora's Fountain's Open stays (needs further testing):
  King Zora is back in front of the door after leaving Jabu-Jabu's Belly. Still (experimental) because
  untested or only tested off: Door of Time's Open (the tag moved from the whole setting to that option),
  Skip Epona Race, Shuffle Kokiri Sword, Shopsanity, Big Poe
  Buyer Needs Only 1 Big Poe, Skip Area Intro Cutscenes, Excluded Locations and the other options already
  marked.
- **Tooltips** of the confirmed settings now describe what happens in-game rather than how it's done,
  and no longer say "untested". This covers Logic Rules, Guarantee Reachable Locations, Kokiri Forest,
  Open Death Mountain, Skip Child Zelda, Saria's Song, Shuffle Songs, Stones/Medallions, Freestanding Items,
  Weird Egg, Ocarinas, Freestanding Rupees, Boss Heart Containers, NPC & Minigame Rewards, Great Fairies,
  Skulltula House, Tokensanity, Start With maps and compasses, Balanced pool, Skippable Cutscenes, Bag
  Bombs Open Dodongo's Cavern, Refills, Anju, Kaepora, Bombs Without Bracelet and Small Chests.
- **Door of Time: Closed**: when the Spiritual Stones are shuffled, all three are now placed where child Link
  can reach them, so you hold them before going to adult as in the original. The game itself still only
  checks the three child dungeons. The medallions are unchanged.

### Added
- **One-click setup** for people who don't code:
  - `Setup (Windows).bat` installs Python 3.14 for your user if needed (winget, or the python.org
    installer), installs `requirements.txt` and makes `.py`/`.pyw` files open with Python.
  - `setup_linux.sh` does the same on Linux. It uses your package manager, or uv as a fallback; asks
    before using sudo; installs the packages into a private `.venv`; and adds a menu entry plus a `.pyw`
    association.
  - `Start Randomizer (Windows).bat` and `run_linux.sh` open the randomizer and install any missing
    packages first.
  - `Install Requirements.bat` is replaced by the setup script.
- **README**: a step-by-step Setup guide (game files, download, setup, start, updating, troubleshooting).

### Checked
- **Skip Child Zelda** confirmed in-game (0.4.4): a new save gets the three start checks (Zelda's Letter,
  Malon's Egg, Impa's song), Malon and Talon are at Lon Lon Ranch, and Hyrule Field has day and night.
- **Door of Time: Closed** accepts either ocarina: the altar only checks the quest step, not which ocarina
  you hold, so no patch is needed. In a simulation of 540 seeds across forest, reward, song, ocarina and
  Skip Child Zelda combinations, the three child dungeons, an ocarina and the Song of Time were always
  reachable as child.

## 0.4.3 - 2026-11-11

### Fixed
- **Shuffle Freestanding Rupees**: an item dropped by a Deku Scrub in the Deku Tree landed inside its flower,
  behind an invisible wall, so it couldn't be picked up. The three Deku Tree scrub drops are no longer rupee
  checks (109 instead of 112). Seeds made with 0.4.2 or older can have an important item stuck there, so
  make a new seed.

- **LLR Talons Chickens**: buying milk from Talon and refilling a bottle on later wins also handed out the
  check's item, so it could be collected again and again. Only his first-win prize is the check now.

### Added
- **DMT Biggoron** (Shuffle NPC & Minigame Rewards): the Biggoron's Sword at the end of the adult trade
  sequence is a check. The trade items themselves stay vanilla.
- **Big Poe Buyer Needs Only 1 Big Poe** (Other > Quality of Life, experimental, off by default).
- **Skip Kaepora Gaebora** (Other > Quality of Life, experimental, off by default): his first talks outside
  Kokiri Forest, in Hyrule Field and at Zora's River count as already seen.

### Changed
- **Shuffle NPC & Minigame Rewards** is no longer experimental: all 28 of its checks were randomized in a
  0.4.2 test seed, alongside earlier in-game checks.
- Partly confirmed settings are now labelled **(needs further testing)** in the randomizer instead of
  (experimental): Zora's Fountain's Open, Skip Child Zelda, Shuffle Spiritual Stones/Medallions, Shuffle
  Ocarinas, Shuffle Freestanding Rupees, Shuffle Skulltula House Rewards and Small Chests Only.
- Checked against the full list of minigames and NPC rewards: every one with an item reward is a check,
  except the Treasure Chest Game (its prize chest needs a minigame-only preview model for each prize) and
  Medigoron's Giant's Knife (bought, like a shop).

### Test results (0.4.2 seed)
- Small Chests Only: every big chest in the Deku Tree was small and opened with the short animation. The
  Kokiri Sword chest stays big when the sword isn't shuffled (its chest plays the sword scene).
- Shuffle Spiritual Stones/Medallions: Anywhere: beating the Deku Tree gave its random item.
- Shuffle Skulltula House Rewards: all five rewards random in the spoiler.

## 0.4.2 - 2026-11-11

### Fixed
- **Small Chests Only**: in 0.4.1 the swapped chests couldn't be opened. The 0.4.1 change (sending the big
  chests' scripts to the small chest's opening) is undone. Instead, chests whose script only adds a Navi line
  or a camera move lose that script and open like normal small chests. The eleven chests whose script runs
  a story event (Nabooru, the Serenade of Water, Ruto in Jabu-Jabu, Dampé's race, Ganon's Castle's Golden
  Gauntlets, the Ice Arrow quest, the vanilla Kokiri Sword) stay big chests.

### Changed
- Every setting or option that isn't confirmed in-game is now marked experimental: Kokiri Forest's Closed
  Deku, Zora's Fountain's Open, No Logic, Required Only, Skip Epona Race, Shuffle Kokiri Sword, Shuffle NPC &
  Minigame Rewards, Shuffle Great Fairy Rewards, Shuffle Skulltula House Rewards, every Maps & Compasses
  option other than Vanilla, the Scarce and Minimal item pools, and Excluded Locations.

### Test results (0.4.1 seed)
- Skip Child Zelda with a Closed forest: Mido now blocks the way without a sword and shield (the 0.4.1 fix).

## 0.4.1 - 2026-11-11

### Fixed
- **Skip Child Zelda** with a Closed forest: Mido was gone but his invisible wall still blocked the Deku
  Tree, even with a sword and shield. The Kokiri schedules read the Hyrule Castle quest, which the setting
  completes, so Mido had moved to where he stands after you've met Zelda. The Kokiri now stay on their
  before-the-castle schedules, and Mido guards the path until you show him a sword and shield.
- **Small Chests Only**: the swapped chests still played the long big-chest sequence. About 30 big chests
  run their own script (a Navi line or story flags) that jumps to the big-chest sequence; those jumps now go
  to the small chest's sequence. Every big chest in the game is now swapped, not only the randomized ones.

### Test results (0.4.0 seed)
- Working: Open Death Mountain (On), Tokensanity (Overworld Only).
- Partly working: Skip Child Zelda (starting items and day/night confirmed; the Mido bug is fixed above),
  Shuffle Spiritual Stones/Medallions: Anywhere (a medallion at a freestanding spot works; dungeon rewards
  not tested yet), Small Chests Only (fixed above).

## 0.4.0 - 2026-11-11

### Added
- **Item tracker** (`Tools/OOTNS2-Tracker`): a clickable tracker for items, songs, stones, medallions and
  counters, with save/load. It takes its icons from your own extracted romfs; no game files are included.
- **Small Chests Only** (Other > Quality of Life, experimental, off by default): big chests and Boss Key
  chests use the small chest, so opening one skips the long big-chest animation.
- **Market Big Poe Bottle**: the bottle the Big Poe buyer gives at 1000 points is now an NPC & Minigame
  check (Shuffle NPC & Minigame Rewards).

### Fixed
- **Zora's Fountain: Open**: King Zora still blocked the Fountain. The setting now also starts the Zora
  quest where showing him Ruto's Letter leaves it, which is what moves him.
- **Shuffle Skulltula House Rewards**: the 10 and 30 token rewards were still the Adult's and Giant's
  Wallet. All five rewards are now random. The two wallets go into chests as progressive wallets: the first
  one gives the Adult's Wallet, the second the Giant's Wallet.

### Test results (0.3.1 seed)
- Working: Open Death Mountain (Off), Shuffle Songs (Song Locations), Shuffle Weird Egg (Off), Shuffle
  Freestanding Rupees (Off), Shuffle Boss Heart Containers, Tokensanity (Dungeons Only), Bag Bombs Open
  Dodongo's Cavern.
- Partly working: Zora's Fountain (Open), Shuffle NPC & Minigame Rewards and Shuffle Skulltula House
  Rewards, all fixed above; Shuffle Ocarinas (the Ocarina of Time check is still untested).
- Known issue, not fixable: while holding Zelda's Letter you can't use the Cucco, because the remake keeps
  the child trade items in one slot.

## 0.3.2 - 2026-11-11

### Added
- **Skip Child Zelda** (Main Rules > Open, experimental, off by default): a new save already owns whatever
  Zelda, Malon and Impa would have given you (the items at HC Zeldas Letter, HC Malon Egg and Song from
  Impa). The Hyrule Castle quest counts as complete, so Talon and Malon are at Lon Lon Ranch and Hyrule
  Field has its normal day/night cycle from the start. Those three checks only hold items the save can
  grant directly (songs and single key items).
- **Shuffle Spiritual Stones/Medallions: Anywhere** (experimental): finishing a dungeon gives a random item,
  and the stones and medallions can be anywhere. The setting (formerly "Shuffle Dungeon Rewards") is now
  marked experimental.

### Changed
- The logic now follows finished dungeons instead of held stones and medallions, because that's what the
  remake checks. The Door of Time needs the three child dungeons, and the bridge and Light Arrows need the
  Shadow and Spirit Temples. This also fixes Dungeon Reward Locations seeds, where the logic could expect the
  bridge after the wrong two dungeons.

### Confirmed
- Shuffle Ocarinas: Saria is there for her opening greeting outside Link's house again (the 0.3.1 fix).

## 0.3.1 - 2026-11-11

### Fixed
- **Shuffle Ocarinas**: Saria's greeting outside Link's house at the start played without Saria there.
  Her bridge goodbye is now switched off at the bridge trigger itself, instead of by marking it as already
  seen, which made Saria act as if she had left the forest from the start. After the Deku Tree she waits
  by the bridge, but the goodbye (and its Fairy Ocarina) still doesn't play.

## 0.3.0 - 2026-11-11

### Added
- **Open Death Mountain** (Main Rules > Open, off by default): the Kakariko gate to Death Mountain starts
  open for child Link, so Zelda's Letter isn't needed to get past the soldier. The logic follows the
  setting. This also opens the Happy Mask Shop from the start.
- `CHANGELOG.md`, and a **Test results** section in the README listing which settings are confirmed working.

### Removed
- **Load Saves at Dungeon Entrance**. It never moved the restart point in testing.

### Changed
- **Tokensanity** and **Bag Bombs Open Dodongo's Cavern** are no longer marked experimental; both were
  confirmed working in-game.

## 0.2.1 - 2026-11-11

### Fixed
- **Bombchus** picked up without a Bomb Bag showed "Five Bombchus" but gave none, because the remake keeps
  Bombchus in the Bomb Bag. With **Refills Need Their Item** on, Bombchus are now placed in chests that
  give a Blue Rupee until you have a Bomb Bag (like arrows, bombs and seeds).
- **Open forest**: Mido still blocked the path to the Deku Tree until you had a sword and shield. The
  "Meet the Deku Tree" quest now starts past his step, so he has already moved aside.
- **Shuffle Kokiri Sword**: the original sword chest still played the sword cutscene and handed Link a
  sword that disappeared after saving and quitting. A randomized sword chest now opens like a normal chest.

### Changed
- Test checklist: a new **Partial** result (orange) next to Pass and Fail, counted in both sets of totals.
  Result cells are centred, and the Category column is wider.
- The checklist is now only written as `checklist.xlsx`. Testers export it to CSV from Google Sheets for
  bug reports.

## 0.2.0 - 2026-11-10

### Added
- **Game version check**: the randomizer hashes the game's `exefs/main` (SHA-256) and only runs on known
  versions (currently game version 1.1.1). The ROM Options tab has an **exefs folder** row (empty = the
  `exefs` folder next to the romfs), a status line that turns green for a supported version, and the
  current hash under the romfs box.

## 0.1.0 - 2026-11-10

First public release.

- README for testers: installing Python, `Install Requirements.bat`, starting the randomizer by
  double-clicking `ootr_remake.pyw`, installing seeds and using the test checklist.
- Test checklist (`checklist.xlsx` / `checklist.csv`) with the seed's settings and every check grouped
  by region, Pass/Fail dropdowns and running totals.
- **Open Folder** button that opens the output folder.
- Crash messages and `error_log.txt` when started without a console.
- **Skip Area Intro Cutscenes** marked experimental and off by default (the intros still play).
