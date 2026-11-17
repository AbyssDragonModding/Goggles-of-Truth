# Technical notes

How the generator works and why each setting is done the way it is. This is for contributors and curious
testers; you don't need any of it to play. Version numbers like "0.2.2" below refer to private builds made
before the public 0.1.0 release.

## Settings

| Classic setting | Here |
|---|---|
| Logic Rules (Glitchless / No Logic) | Same |
| Guarantee Reachable Locations (All / Required Only) | Same |
| Open Forest (Closed / Closed Deku / Open) | Same (explained below) |
| Zora's Fountain (Closed / Open) | Open = King Zora already moved, for both ages |
| Open Door of Time | Closed / Open |
| Open Death Mountain | New: the Kakariko gate starts open for child Link (off by default) |
| Skip Child Zelda | New save already owns Zelda's, Malon's and Impa's items; castle quest complete; experimental (explained below) |
| Skip Epona Race | Adult Epona's Song inside the Lon Lon Ranch fence counts Ingo's race as won; ride Epona out of the ranch and she's yours. Experimental |
| Shuffle Kokiri Sword | Toggle (on by default) |
| Shuffle Songs (Song Locations / Anywhere) | Same; *Anywhere* is experimental |
| Shuffle Spiritual Stones/Medallions | Vanilla / Dungeon Reward Locations / Anywhere; experimental (explained below) |
| Freestanding items, boss Heart Containers | Toggles |
| Shuffle Freestanding Rupees | New: 109 world rupees become checks (off by default) |
| Character Gifts and Minigames (OotrR's list), Quest Rewards, Great Fairies, Skulltula House | Toggles |
| Business Scrubs + Business Scrub Prices (10 rupees / game's price / random 10-99 / random 10-200) | The four one-time scrubs, experimental (explained below) |
| Tokensanity (Off / Dungeons / Overworld / All) | Same |
| Shuffle Ocarinas | Toggle, experimental (explained below) |
| Items Shuffled Per Shop (Off / 1-4 / random) + Shop Prices (10 rupees / random 10-99 / random 10-200) | All eight shops (explained below) |
| Maps & Compasses / Small Keys / Boss Keys | Vanilla / Own Dungeon (keys experimental) / Remove (maps) / **Start With** (maps, explained below) |
| Item Pool (Balanced / Scarce / Minimal) | Same (Plentiful not available) |
| Excluded Locations | Same |
| Hints | **Hint Distribution** (No Hints / Balanced / Strong / Useless) and **Gossip Stones** (Mask of Truth Required / No Mask of Truth); Strong and Useless experimental (explained below) |
| Quality of Life | **Skip Opening Movie**, **Skip the Great Deku Tree's Talk**, **Chests Without Cutscene** (off; explained below); **Skip Story Scenes** (experimental, needs additional testing, on; explained below); **Make All Cutscenes Skippable**, **Bag Bombs without Goron Bracelet**, **Anju Needs Only 1 Cucco**, **Refills Need Their Item** (all on by default); **Bag Bombs Open Dodongo's Cavern** (off); **Skip Area Intro Cutscenes** (experimental, off); **Big Poe Buyer Needs Only 1 Big Poe**, **Skip Kaepora Gaebora** (experimental, off) |
| Settings string | Same idea (import / copy) |

The **Not Supported** tab lists the classic options that can't be done yet, and why.

## Open settings and story flags

These settings change the **default save data** (`GameData/GameDataList`). A flag's key is the MurmurHash3
(seed 0) of its name, and new values only take effect on a **new save file**.

| Setting | What changes |
|---|---|
| Kokiri Forest: Closed Deku | `KokiriForest_Npc_Kokiri_007_Child_Blocker_00` False: the invisible wall and Kokiri boy at the exit |
| Kokiri Forest: Open | also `KokiriForest_Npc_Kokiri_Mido_Child_Blocker` False: Mido's wall at the Deku Tree. That flag alone left Mido standing guard (0.2.0 report): his AI schedule keeps him on the path until `Meet_DekuTree_IsAfter_Step02_Exp`. So the opening cutscene (`OpeningEvent`, the node that starts the "Meet the Deku Tree" quest at `Step01`) starts it at `Step03`, the state right after Mido steps aside. This also opens the Kokiri Shop shelves that are sold out before Mido's step |
| Zora's Fountain: Open | The Zora quest (`Get_StoneOfWater`) starts at `Step07`, plus `HavePlayedEvent.Dm_Zora_0010` (the Ruto's-letter scene), `Get_StoneOfWater_ReadRutoLetter` and `..._TalkedZoraAboutRutoLetter` True. The flags alone left King Zora in place (0.3.1 report): his pack reads `Get_StoneOfWater_IsAfter_Step06_Exp`, and showing him the letter (`Get_StoneOfWater:StoneOfWater_ShowLetter`) sets `Step07` before `Dm_Zora_0010` plays. The first arrival in Zora's Domain (`Dm_SY_BancChangeArrive:Goto_ZoraDomain`, after `Dm_Zora_0000`) progresses the quest to `Step03`/`Step03_Impa`, and progressing also moves backwards: King Zora was back in front of Jabu-Jabu after the next load (0.4.3 report). Since 0.4.4 both steps are `Step07` (`qol.patch_open_zora_arrival`) |
| Open Death Mountain | `Npc_Hylia_Soldier_003_GateOpen` True: the flag the Kakariko gate soldier sets when shown Zelda's Letter. The gate shutter (`Obj_Kakariko_SwitchShutter_A_01`) is tied to it through `KakarikoVillage_Child_Static`'s `PlgGdTable`. The same flag opens the Happy Mask Shop in the market. Child Death Mountain then needs no letter in the logic |
| Door of Time: Open | Clawshot's Open mode (`rando/door.py`): the door's logic module `Logic/Market_Common_f252.logic.module.ainb` opens the door from Door of Time quest step `Step06`; its one `Step06` literal becomes `Ready` (same size). The child Master Sword pedestal's AI group in `Market_Child_Static` gets the ungated module `SpiritTemple_Prefab_5299` with the first-pull request and the sword. A new save starts that quest (`Step_DoorOfTime`) at `NotReady`, before `Ready`, so the quest is also started at `Ready` (not with Skip Child Zelda, which starts it at `Step02`): without it the door stayed shut for a player who went straight there (test seed 5). Setting `Market_Child_TimeTempleDoor_Opened` (up to 0.5.0's first test seeds) left the door shut. Works in-game (test seed 6) |
| Skip Epona Race | Flow edit of `Dm_SY_Ocarina_EponaSong` (`rando/faststart.py`, `epona_without_race`); see below |
| Saria's Song With Just an Ocarina | Adds a computed flag `Rando_HasOcarina_Exp` (`IsGet.Item_Ocarina_Fairy` OR `IsGet.Item_Ocarina_Time`) and re-points the two child Sacred Forest Meadow logic modules (`SacredForestMeadow_Child_Prefab_3265` / `_bbc3`) from `DoorOfTime_IsAfter_Step01_Exp` (met Zelda) to it. The quest-log step the scene advances is already guarded by Darunia's progress, so getting the song early is safe |
| Skip Area Intro Cutscenes (experimental) | `HavePlayedEvent.<intro>` True for 13 first-arrival intros (listed in `rando/gamedata.py`, explained below), `IsVisitLocation.<area>` True for their 12 areas, and `Npc_Kaepora_LakeHrl_Appeared_FromValley` True |

The logic follows the open settings:
- The forest exit no longer needs the Deku Tree.
- Saria's Song (on by default) needs only the Kokiri Sword (for the meadow) and the ocarina, under any
  forest setting; with the option off it also needs meeting Zelda.
- Beating the Deku Tree needs the Kokiri Sword and the Slingshot. With a **Closed** forest the Slingshot is
  always placed in Kokiri Forest, the Lost Woods or Sacred Forest Meadow (never inside the Deku Tree or
  outside the forest), even with logic set to none, so it cannot be locked behind the forest exit. With
  Closed Deku or Open it can be anywhere.
- An open Zora's Fountain no longer needs Ruto's Letter. The letter could never be delivered there, so it
  would be a dead item. **The generator replaces it with an empty Bottle:**
  - **Freestanding items shuffled:** the letter in the item pool becomes a Bottle.
  - **Freestanding items not shuffled:** the letter's spot at Lake Hylia (`Obj_Bottle_Letter`) is patched
    to hold `Item_Bottle`.
- An open Door of Time makes adult reachable without the stones or the Song of Time.

An area intro is started by the entrance actor in the *previous* area's stage data: its `InitEventName` plays
unless its `InitEventFlag` is true. That flag is either `HavePlayedEvent.<intro>` or a computed
`InitDemo_<area>` flag built from those (for example `InitDemo_LakeHylia` = any Lake Hylia intro played). Some
`InitEventName`s are entries in the shared `Dm_SY_BancChangeArrive` flow that do more than play the intro, so
skipping them would skip that work too. The 13 intros skipped (`AREA_INTROS` in `rando/gamedata.py`) are the
ones whose arrival does nothing else: Kakariko, Graveyard, Hyrule Castle, Lake Hylia, Gerudo Valley, Gerudo
Fortress, Zora's River, Zora's Fountain, Ganon's Castle, Lost Woods (after Saria's Song), and the Fire Temple,
Bottom of the Well and Spirit Temple entrances.

The `InitDemo_<area>` flags are `BoolExp`s in reverse Polish notation over `[opcode, hash]` items (0 reads a
Bool, 4 is OR, 5 is NOT, as in `GameDataPatcher.add_bool_exp_any`): `InitDemo_KakarikoVillage` =
`HavePlayedEvent.Dm_Kakariko_0000` OR NOT `Sequence_IsChildhood`, `InitDemo_LakeHylia` = any of
`Dm_LakeHrl_0000` / `_0003` / `_0005` OR adult, `InitDemo_DeathMtCrater` = `Dm_DeathMtCrater_0000` OR
`_0000_FromTop` (the hashes were matched by MurmurHash3). So a played flag in the default save data does satisfy
them. Version 0.1.0's report that the intros still played predates most of the save-data work and wasn't
reproduced since.

What the setting missed until 0.6.0: an intro is where its area is first "visited". Each of these intros opens
the area's name banner (`UISystemActor.EventTriggerOpenLocationUI`), which sets `IsVisitLocation.<area>`, and
these locations show their banner only in that scene (RSDB `Location`: `IsShowLocationUIFirstTimeInDemo`).
Clawshot found the same for Saria's skipped scene (`IsVisitLocation.KokiriForest`, needed for the pause map).
So the 12 areas (`AREA_INTRO_VISITS`) now count as visited from the start. The Lake Hylia intros
(`Dm_LakeHrl_0003` / `_0005`) also set `Npc_Kaepora_LakeHrl_Appeared_FromValley`, which puts Kaepora on the lake
for his ride; that's set too. Tested in-game for Kakariko, Hyrule Field, Lake Hylia, Zora's River and
Fountain, Gerudo Valley and the Fire Temple, Spirit Temple and Bottom of the Well entrances.

The intros whose arrival entry also advances a quest or sets a flag can't simply count as played (the entry
would never run, which could stall the quest; version 0.1 did that). Since 0.6.0 they are skipped inside the
arrival flow instead (`AREA_SKIPS` in `rando/storyskip.py`): the `EventTransition` to the intro is replaced like
a story scene (`skip_scenes` with `area_intro=True`), so what follows it still runs. Two differences from story
scenes: the intro's `UISystemActor.EventTriggerOpenLocationUI` (its name banner) is allowed and becomes its
`IsVisitLocation.<area>` flag, and the replacement always fades in (black) unless the intro starts with a fade
out, because an arrival intro may be what ends the loading screen's fade. Covered, with what keeps running:
- **Deku Tree** (`Dm_Deku_0000`): Get_StoneOfForest, MeetBoss.
- **Death Mountain Trail from Kakariko** (`Dm_DeathMtTrail_0000`): Get_StoneOfFire, DeathMtTrailIn.
- **Goron City from the trail** (`Dm_Goron_0000`): Get_StoneOfFire, ArriveCity.
- **Zora's Domain from the river** (`Dm_Zora_0000`): Get_StoneOfWater, Step03 / Step03_Impa.
- **Desert Colossus from the wasteland** (`Dm_DesertColossus_0000`): SageOfSpirit, Step04.
- **Castle Town** (`Dm_HrlCastle_0005`): Goto_HyruleCastle.
- **Death Mountain Crater from Goron City** (`Dm_DeathMtCrater_0000`): Navi's remark (SageOfFire), the
  first-entry flag. From the trail the crater plays `Dm_DeathMtCrater_0000_FromTop`, which has no flowchart
  file to check, so it still plays.
- **Sacred Forest Meadow, Ice Cavern, Shadow Temple, Gerudo Training Ground** (`Goto_SacredForest`,
  `Goto_IceCave`, `Goto_ShadowTemple`, `Goto_GerudoTrainingGround`): their quest steps and flags.
- **Lon Lon Ranch** (`Dm_LonLon_0010` in `Entry_LonLonRanch`): Malon's whereabouts flags; the scene's
  `LonLonRanch_IsVisited_Child` is copied.

A flow that has no `GameDataActor` (or other system actor) for the new steps gets one, with another system
actor's parameters, as `faststart` does.

**Inside Ganon's Castle** (`Dm_InsideGanonCastle_0003`, in `Defeat_Ganon`): the first visit; the castle's
`LocationArea` exists only once it has played. Its `VoicePlayActor.EventTriggerCloseDemoScreen` (closing the
voice/subtitle screen) is counted as presentation.

**Dodongo's Cavern** (`Dm_DodongoCave_0000`) and **the Water Temple** (`Goto_WaterTemple`) intros are events of
their own, each requested by an `EventRequestActor` inside, with no arrival flow. Their first entry is cut down
to setting their flags (`AREA_STANDALONE`, `empty_intro`): the area's `IsVisitLocation` flag and its
`HavePlayedEvent` flag (Dodongo's Cavern's `LocationArea` only exists once `HavePlayedEvent.Dm_DodongoCave_0000`
is set).

Still playing:
- **Lake Hylia's hookshot target** (the debug test's "Water Temple still played" was the intro inside,
  `Goto_WaterTemple`, now emptied) (`Dm_WaterTemple_0000`, an `EventRequestActor` in Hyrule Field): the scene
  that raises the Water Temple's pillar. It sets `WaterTemple_EmitGatePillar`, so it's gameplay, not an intro.
- **Shadow Temple gate** (`Dm_ShadowTemple_0000`, inside): opens the temple's gates (four flags).
- **Story intros:** Kokiri Forest, Lost Woods, Hyrule Field and Zora's River (Kaepora, see Skip Kaepora).

## Maps & Compasses: Start With

Each dungeon's map and compass are plain save flags, `DungeonInfo.<dungeon>.IsGetMap` and `.IsGetCompass`
(found in the room logic modules). **Start With** turns all 20 on in the default save data, covering the ten
dungeons that have them.

The 20 map and compass checks stay shuffled. Their items in the pool are replaced by random bonus items,
seeded from the seed, drawn from `START_WITH_BONUS` in `rando/generator.py`:
- Blue, Red, Purple and Gold Rupees
- 10 Bombchus
- 30 Arrows
- Deku Nuts
- occasionally a Piece of Heart

These bonus items are never progression. They go into the general pool, so the old map and compass checks
can hold anything, and the bonuses can land anywhere.

A few rooms use these flags to mark their room hint as cleared, so those hints are simply marked done from the
start. In Water Temple room 3 the compass flag is also one of the inputs to a moving-platform node. Check that
room in-game.

## Dodongo's Cavern boulder

The child boulder (`DodongoCavern_CrackRock`) is controlled by
`Logic/DeathMountainTrail_Child_Prefab_ffa7.logic.module.ainb`:
- **The boulder:** it disappears (node 7, `ActorLogicDeathProcComplete`) once its break event has run.
- **The trigger:** the event is requested by node 14, `OperateAND`. Its two inputs are the special bomb
  flower's own state (node 6) and an OR of three `BombFruit` sensors.
- **Bag bombs:** a bag bomb can't satisfy that AND. Node 20, a sensor for `Item_Bomb`, isn't wired into it.

The game therefore only opens the cavern with that bomb flower, which needs the Goron Bracelet, so **the
logic now requires the Goron Bracelet** to enter Dodongo's Cavern. Version 0.1 also accepted bag bombs.

**Bag Bombs Open Dodongo's Cavern** (off by default, confirmed in-game in 0.2.1) makes two changes:
- node 14 becomes an `OperateOR` (name and MurmurHash3 name hash);
- its flower-state input becomes node 20's hit output.

A bag bomb near the boulder, or a bomb-flower fruit, then triggers the break. With the option on, the logic
accepts bombs or the bracelet. If the file isn't recognised, generation stops with an error rather than
producing an unsafe seed.

## Gold Skulltulas day and night, any age

A Gold Skulltula is an `Enemy_Skulltula_Gold` placement in the stage files. A night-only one has the dynamic
parameter `Enemy_Skulltula_Gold_Nocturnal = true` (30 placements); the setting deletes it, so the Skulltula is
always there.

A Skulltula that both ages meet is placed in both the area's Adult and Child stage files with the same instance
hash, and that hash is its save flag (`Bool64bitKey`), so killing it as either age counts once. An adult-only
Skulltula is placed only in the Adult file(s). The setting copies such a placement (after the item edits, so with
its shuffled drop) into the area's `<Area>_Child_Static` file, unchanged. Overworld only (dungeon stage files are
shared by both ages). Left out: a placement with `Links` (a link names another actor of its own file, which the
child file doesn't have: two in Hyrule Field near Lake Hylia, one in Zora's Domain), and Gerudo's Fortress (no
child stage file). That leaves 11: Death Mountain Trail 2, Goron City 1, Kakariko 1, Kokiri Forest 1, Sacred
Forest Meadow 1, Zora's River 2, Gerudo Valley 2, Hyrule Field 1 (`qol.patch_gs_any_time`).

The child area can differ from the adult one at the same spot, so a copy might float or sit inside a wall. The
Every night-only Skulltula is also referenced by an `AiGroup` (the stage file's `AiGroups`) running
`Logic/Module/Gimmick_Nighttime_Skulltula_Gold_Appear`: it reads the time of day (`HoldWmGetTimeDiv`) and drives
the Skulltula's and its spider web's `Logic_Delete`. With only the parameter removed, Lon Lon Ranch's night
Skulltulas still didn't appear by day (debug test 1), so those groups are removed too; the Skulltula is then an
ordinary placement (like the copies for child Link, which never had a group). Its spider web, no longer tied to
it, stays after it's killed. Tested: Lon Lon Ranch's appear by day.

Other Skulltula gates (survey of every placement's `AiGroups` and `Presence`): `Gimmick_AllDay_Skulltula` (51,
no time check), `Gimmick_SwayingTree_Skulltula_Gold_00` (7, pop out of a tree), `Gimmick_BoxBroken_Skulltula`
(4, in a crate), bean soil `Presence` flags (10, child only), and room / area prefabs. Of the adult-only
Skulltulas copied for child Link, the two on Death Mountain Trail are in `DeathMountainTrail_Adult_Prefab`
groups with an `Obj_BrokenRock_A_02` in front (the Hammer rocks). The rock exists only in the adult file and
isn't copied, so child Link's copies are in the open (with the rock they'd be unreachable as child). The
other copies are in `Gimmick_AllDay_Skulltula` or night-time groups, which aren't copied either.

The logic is unchanged: it still expects night or adult Link for these Skulltulas, so a seed never depends on them.
Tested in-game (debug seed): night-only ones appear by day, adult-only ones as child.

## Rainbow Bridge Requirement

The bridge is `Obj_GanonCastle_Bridge_A_01` in `Logic/GanonCastle_Level_Field_00_Prefab`. The dump showed its
multi-input links only as `<-[65436]`; decoded from the file: an input whose node index is -100 or less reads
entries of the multi-input table (8 bytes each: node, output, flags; at the end of the input tables, 0x1230 here),
starting at entry -100 - index, with the parameter index as the count. So:
- the trigger areas (`Area_2dac`, `Area_99ec`) and the appear point exist while
  `Defeat_Ganon_IsAfter_Ready_Exp` AND NOT `Defeat_Ganon_IsAfter_Step01_Exp` (node 6's False output);
- the bridge scene `GanonCastle_Adult_Field_Rainbow` (in `Defeat_Ganon`; it plays `Dm_InsideGanonCastle_0000`, the
  sages' bridge) starts when Link is in both areas and in player state 2;
- the bridge exists when that scene has played, or from its `EventBoolEX1` on.
"IsAfter_X" means past step X. A new save is at `NotReady`; Zelda's Light Arrows scene (`AllSage`) sets Step01 (past
Ready: the areas come), the bridge scene sets Step02 (past Step01: the areas go, the bridge stays). The fishing pond
also reads the Ready flag for a line.

Computed flags (`BoolExp`) are reverse Polish lists of `[opcode, value]` (survey of the game's 884): 0 reads a Bool,
3 is AND, 4 OR, 5 NOT, 12 + 2 compare a quest step, 16 pushes a constant, and 15 / 18 / 19 read an Int and compare it
with that constant: 15 is "equal" (`KakarikoVillage_GatheringTokenGold_Collect100Tokens` = token count, 100), 18 is
"less than" (`MiniGame_DampeRace_IsClearLeastOnce` = NOT(clear count < 1)). So with a requirement other than
Vanilla (`GameDataPatcher.rainbow_bridge`):
- **Medallions N:** a chain of small computed flags, `Rando_Bridge_Medals_<k>_<i>` = "at least k of the first i
  medallions" = `<k of i-1>` OR (`<k-1 of i-1>` AND medallion i), read with opcode 10 (reads another computed flag;
  all 356 uses in the game do). The game's own computed flags are at most 26 entries long and need at most 9 stack
  slots; 0.6.1's first version wrote 3 of 6 as one flag of 123 entries (every combination), and in-game the bridge
  never appeared with 4 medallions, the Bow and the Light Arrows. Every flag now has at most 9 entries;
- **Spiritual Stones:** AND of the three `IsGet.Item_Stone_*` (the items, not the dungeon quests);
- **Tokens N:** NOT(`PouchData.Item_Token_Gold.StockNum` < N), the count the Skulltula House reads. Opcode 16's
  number must be a plain signed Int, as in the game's own flags (the other entries are U64): written as a U64 it
  wasn't read, and in-game the bridge was there with 0 tokens;
- AND the Bow AND the Light Arrows for every option.

"Owning" an item (each medallion, stone, the Bow, the Light Arrows) is `Rando_Have_<item>` = `IsGet.<item>` OR
`PouchData.<item>.StockNum` > 0 (opcode 19 with constant 0, as `HaveDefeatedEnemy_*` write "at least one"). Every
item has both, and a debug menu fills the pouch count without the flag: the first stones and tokens tests (Light
Arrows added last from the debug menu) got no bridge with `IsGet` alone.
That is `Rando_Bridge_Exp`, and `Defeat_Ganon_IsAfter_Ready_Exp` becomes its old value OR it; the Step01 flag
stays the quest's own. (0.6.1's first version replaced the Step01 flag with the requirement instead, which keeps the
areas switched off: no bridge in-game.)

The bridge's event moves the castle quest to Step02, and the quest goes on in the castle (Step03, Step04 ...). If
the bridge came before Zelda's scene, `AllSage` would set Step01 behind it. So `qol.bridge_quest_guard` puts a switch
on `Defeat_Ganon_IsAfter_Step01_Exp` in front of AllSage's Step01: past Step01 already, the step is skipped.

Logic (`logic.bridge`): adult, the requirement (medallion items, the three stone items, or `Token_Gold` count; Vanilla
keeps the Shadow and Spirit quests), the Bow and the Light Arrows. Checked by generating every option with Beginner and Expert and evaluating the written flags (one medallion,
stone or token short, or no Bow: no bridge). Confirmed in-game with 3 medallions, the Bow and the Light Arrows and no
Zelda scene, then with the three Spiritual Stones (none without them). Then with Gold Skulltula Tokens (after the Int fix): all four options are stable.

## Skip Ganon's Trials

Each trial's sage room has an `EventRequestActor` for
`Defeat_Ganon:InsideGanonCastle_Dungeon_BarrierRemove_<trial>` (Forest, Fire, Water, Shadow, Spirit, Light).
That entry sets `InsideGanonCastle_Dungeon_BarrierRemove_<trial>` (the barrier is gone while it's set) and
counts the Int `InsideGanonCastle_Dungeon_Barrier_Count` down from 6. At 0 it calls `BarrierRemove_All`, which
removes the tower barrier and sets `InsideGanonCastle_IsAllBarrierClear` (read by the middle room's logic,
`InsideGanonCastle_Level_Room_01_Prefab`). The sage's light in the middle room
(`EftLoc_InsideGanonCastle_SageRoom_*`) shows once the entry's played flag is set.

The setting starts a new save with all of that done: the six barrier flags and their
`HavePlayedEvent.InsideGanonCastle_Dungeon_BarrierRemove_*` flags true, the counter at 0 and
`IsAllBarrierClear` true (`GANON_TRIALS` in `rando/gamedata.py`; `GameDataPatcher.set_int` for the counter).

`BarrierRemove_All` does two more things. It plays `Dm_InsideGanonCastle_0090`, and the tower's lift
(`Obj_InsideGanonCastle_ElevatedFloor_A_01`, `InsideGanonCastle_Level_Room_01_Prefab_e183`) only works once
that scene's played flag is set, so the save sets it too (debug test 3: door open, lift dead). And it moves the
`Defeat_Ganon` quest from Step03 to Step04 (Ganondorf's rooms then check Step05). The quest can't start at
Step04 in the save: `GanonCastle_Level_Field_00_Prefab` makes the rainbow bridge appear once the quest is past
Step01. So `qol.patch_ganon_trials` adds a Step04 progress right after each of the two Step03 progresses
(`GanonCastle_Adult_Field_SeeTowerBarrier` and `_FromDoor`, the first look at the tower barrier from the middle
room).

Tested in-game (debug test 4): barriers gone, the lift there and working, the way up to Ganondorf works.

Logic: `win` becomes `ganon_tower`, which with the setting on needs only the bridge, the Bow and the Light
Arrows (Ganondorf; the Master Sword comes with adult Link). The trial rooms' locations keep the full
`ganon_done` rule, so they still expect the trials' items.

## Songs: the teaching flow gave the vanilla song too

Every song event teaches its melody through the shared `Dm_SY_Ocarina` flow:
- `LearningOcarinaPlayAuto` covers Zelda's Lullaby through the Song of Storms.
- `LearningOcarinaPlayAutoForSeek` covers the six warp songs.

After you play the song back, that flow **adds the song being taught to your inventory** (one
`EventTriggerAddOrRemovePouchContent` per song). This happens on top of the location's own give node, so
every song location gave its vanilla song as well as the randomized item.

Whenever songs are shuffled, those 12 adds are set to `Num = 0`, so a song location only gives its randomized
item. The demonstration still shows the location's original melody, which is only cosmetic. The Scarecrow's
Song is left alone.

## Weird Egg

**Shuffle Weird Egg** (experimental, off) makes the egg a shuffled item:
- **Off:** Malon at Hyrule Castle always gives the Weird Egg.
- **On:** her reward is random and the egg is placed somewhere else. This needs NPC rewards shuffled.

Normally, when the Hyrule Castle quest reaches step `Step03_01`, the flow
`Goto_HyruleCastle:Step03_01_Npc_Navi_StepStart` hatches the egg into the Wake-Up Cucco without checking that
you have it. With the option on, that flow is rewired to check first:
- **The check:** an unreachable pouch query in the same flow (event 41, left over from Malon's dialogue)
  is changed to "owns `Item_WeirdEgg`?", and the step-start query (event 129) now leads into it.
- **Egg owned:** the normal hatch plays, then the quest step advances.
- **No egg:** the hatch is skipped but the quest step still advances, so the story doesn't stall. An egg
  found later should hatch on the game's own egg timer. This is untested.

## Shuffle Ocarinas (experimental)

Both ocarinas join the item pool:
- **Fairy Ocarina:** Saria gives it in her goodbye on the forest bridge. That scene is played by the
  `Goto_HyruleCastle` quest flow (entry `KokiriForest_ArriveLostWood`: `Dm_Kokiri_0150`, then `Dm_Kokiri_0155`,
  which holds the give node). The bridge area trigger (`Logic/KokiriForest_Child_Level_All_02_ddcd`) only
  requests it while `Dm_Kokiri_0150` hasn't been played. Since 0.3.1 that check is pointed at `Dm_Kokiri_0045`
  instead, the greeting outside Link's house that always plays first, so the trigger never fires. The setting
  also starts `HyruleField_ChangeENV` as true, the only flag the flow sets on its way to Hyrule Field. The Fairy
  Ocarina then replaces one junk item in the pool.
  - Up to 0.3.0 the setting started `HavePlayedEvent.Dm_Kokiri_0150` / `_0155` as true instead. Saria's forest
    AI schedule (`Npc_Kokiri_Saria_Child`, schedule "HavePlayedEvent.Dm_Kokiri_0150") and two forest logic
    modules (`..._c64d`, `..._Npc_Kokiri_Saria_Child_a766`) also read that flag, so she was treated as gone from
    the start and the opening greeting played without her. That is now only the fallback if the trigger
    isn't recognised. After the Deku Tree, Saria now waits by the bridge for a goodbye that never comes.
- **Ocarina of Time:** Zelda's gift at the castle moat is the new check "HF Ocarina of Time" (both give nodes
  in `Dm_MelodyGet_Time`, the same flow as the Song of Time). She teaches the Song of Time right after, so the
  logic only expects this check once you own an ocarina.

**Logic:** "has an ocarina" means owning either one. With the setting off it's still "Deku Tree done" (Saria's
gift), plus the Ocarina of Time.

## Skip Child Zelda (experimental)

A new save starts as if Hyrule Castle had already been done as a child:

- **Quests.** Quest progress is one Enum per challenge, found through a computed flag that reads it.
  `Goto_HyruleCastle` (read by `Goto_HyruleCastle_IsCompleted_Exp`) starts at `Complete`, as after meeting
  Zelda. `DoorOfTime` starts at `Step02`, and `Get_StoneOfFire` at `KakarikoVillageNpc`: that's what Impa's
  send-off (`DoorOfTime:DoorOfTime_SendOff`, after her song) sets. Malon's and Talon's schedules read these
  steps (`Goto_HyruleCastle_IsAfter_Step03_02_Exp` and later), so they're at Lon Lon Ranch, and Zelda's own
  schedule hides her once the quest is complete. `HyruleField_ChangeENV` is also set, so Hyrule Field has its
  normal day/night lighting.
- **Scenes.** The quest's scenes count as already seen (`HavePlayedEvent.*`): Kaepora's Hyrule Field intro
  (`Dm_HrlField_0000/0005/0010`), the Market intro (`Dm_HrlCastle_0005`, whose arrival runs
  `Goto_HyruleCastle_EntryMarket`), Talon waking up, the courtyard (`Dm_HrlCastle_0030`..`0060`), Impa's song
  and send-off (`Dm_MelodyGet_Zelda`, `Dm_HrlField_0020`). Kaepora's flow also opens the quest menu, marks the
  field entrance as reached and gives the amiibo pouch entry; those are set directly
  (`UI_IsFinishChallengeMenuOpenEvent`, `HyruleField_ArriveEntrance`, `Pouch_Amiibo`).
- **Items.** Owning an item is its `IsGet.<actor>` flag, plus, for pouch items, a count: `PouchData` is a struct
  with one member per pouch actor, each a one-Int struct holding how many you have. Songs only have the IsGet
  flag. The items at **HC Zeldas Letter**, **HC Malon Egg** and **Song from Impa** are granted this way. So
  those three checks only hold items the save can grant: songs and single key items that have a `PouchData`
  entry. Ammo, capacity upgrades, bottles, hearts, magic, rupees and the stones/medallions are kept out. If no
  progression item lands there, they get a grantable minor item, such as a shield, Farore's Wind or the Stone
  of Agony. In the logic, these three checks are reachable from the start, and "met Zelda" is always true.
- **Ocarinas at a start check.** The flags aren't enough for an ocarina. The game's own ocarina scenes
  (`Dm_Kokiri_0155`, `Dm_MelodyGet_Time`) give it with `PouchSystemActor.EventTriggerAddOrRemovePouchContent`,
  which also records which ocarina Link holds (`PouchActorInfo` `OcarinaTypeValue`: Fairy 1, Time 2). Granted
  through the save flags, the Ocarina of Time was in the menu but couldn't be played, and Link held no ocarina
  in Saria's song scene (seed 3LETP69LQZ). So a start check's ocarina (`faststart.START_BY_EVENT`) is no longer
  a save default. `faststart.give_at_start` adds it with that same action, silently (`IsGetEvent` false), in
  `OpeningEvent:Opening_Introduction` (once per new save; it no longer plays Navi waking Link since 0.6.0), just before the
  flow's autosave. Confirmed in-game (seed 3LETP69LQZ).
- **Unknowns.** It hasn't been tested whether a new save picks up these Enum and Int defaults like it does
  the plain Bools. It also hasn't been tested whether a later scene could still move the castle quest back.
  If Kaepora, Zelda or the Market intro shows up anyway, please report it.
- **Kokiri.** Every child Kokiri's AI schedule ends with a condition on `Goto_HyruleCastle_IsCompleted_Exp`
  (where they stand once you've met Zelda). With the quest complete from the start, Mido left his post while
  his invisible wall (`KokiriForest_Npc_Kokiri_Mido_Child_Blocker`, cleared only by his own sword-and-shield
  talk) stayed, so a Closed forest couldn't reach the Deku Tree (0.4.0 report). Since 0.4.1 that condition is
  removed from the 12 child Kokiri schedules (`Component/AIScheduleParam/Npc_Kokiri_*_Child`), so they follow
  their Deku Tree quest schedules as before the castle trip.

## Shuffle Spiritual Stones/Medallions (experimental)

The remake never checks which stones or medallions you hold. No event flow queries them, and no computed flag
or logic module reads their `IsGet` flags. Story progress follows the quests instead. The Door of Time quest
(the Ocarina of Time at the moat, then the altar) counts the three child-dungeon quests
(`Get_StoneOf*_IsCompleted_Exp`, completed by beating the boss). The later story follows the sage quests.

So since 0.3.2 the logic follows the dungeons, not the items. Going to adult needs the Deku Tree, Dodongo's
Cavern and Jabu-Jabu finished. The bridge and the Light Arrows need the Shadow and Spirit Temples finished.
The medallions are not progression items. The stones are, but only for the Closed Door of Time (see below).

### Closed Door of Time, step by step (checked in 0.4.4)

The `DoorOfTime` quest (`Challenge/DoorOfTime`) is what opens the door. The items you hold don't matter.
1. **Step02** is set by Impa's send-off after Zelda (`DoorOfTime:DoorOfTime_SendOff`). Skip Child Zelda
   presets it.
2. **Step03** is set by `DoorOfTime_CheckStoneNum`, which runs when Dodongo's Cavern or Jabu-Jabu is
   cleared (`Dm_SY_BancChange_EscapeDungeon`). It only reads `Get_StoneOfFire_IsCompleted_Exp` and
   `Get_StoneOfWater_IsCompleted_Exp`. The Deku Tree is a given, because a Closed forest can't be left
   without it.
3. **Step04** is set by the moat scene (`HyruleField_DoorOfTime_Escape`, logic module
   `HyruleField_Child_Prefab_32f7`, `Dm_HrlField_0060`). This is the "HF Ocarina of Time" check.
4. **Step05** is set after Zelda's song (`Dm_MelodyGet_Time` → `Dm_MelodyGet_Time_After`). This is the
   "Song from Ocarina of Time" check.
5. **The altar** (`Obj_TimeTemple_SpiritStoneBase_A_01`, an `OcarinaPoint`) plays
   `Market_Child_DoorOfTime_OpenDoor` when the Song of Time is played at it. Its `ReplaceEventParam` is
   gated by `Market_Child_TimeTempleDoor_OcarinaReacts`, which is DoorOfTime == Step05 AND NOT
   `Market_Child_TimeTempleDoor_Opened`. No ocarina item is checked, so the **Fairy Ocarina opens the door
   as well as the Ocarina of Time**, and no patch is needed.

The logic follows this. `moat` = child in Hyrule Field + the three child dungeons + Zelda met + an ocarina.
It gates both moat checks. `adult` = `moat` + the Song of Time (an ocarina and the song) + the three
Spiritual Stone items. The game doesn't read the stones, but since 0.4.4 they are progression items again
(only for Door of Time: Closed), so a shuffled stone always lands within child reach. A simulation
filled 10 seeds for each of 54 Closed-door combinations: forest Closed/Closed Deku/Open, rewards
Vanilla/Reward/Anywhere, songs Vanilla/Song/Anywhere, ocarinas shuffled or not, Skip Child Zelda on or
off. A child-only sweep (adult forced off) reached the three dungeons, the three stone items, Zelda, an
ocarina, the Song of Time and the moat scene in every seed.

- **Dungeon Reward Locations**: the nine rewards are shuffled among the boss rewards, as before.
- **Anywhere**: the boss reward checks hold any item, and the stones and medallions go anywhere: chests
  (`Item_Stone_*` / `Item_Medal_*` as the drop actor), freestanding spots (a cloned pickup actor, see below)
  or events. They are kept out of shop shelves and excluded locations. The sage cutscenes still play for the
  original dungeon. Whether they behave with a different item in their give node is untested.

## Zelda's Letter

Zelda's reward (**HC Zeldas Letter**) is an NPC check like any other, so she can give a random item. The
letter is then elsewhere, and the logic waits for it before Kakariko's gate and Death Mountain. Impa's song is
a song location. It gets Zelda's Lullaby fairly often, about 30% of seeds, because it's one of the earliest
song checks and the logic needs the Lullaby early.

## Character Gifts and Minigames

The setting follows OotrR's NPC gift list (`game/extra_sources.py` `NPC_GIFTS`): each check names the exact flow
events that hand its reward over (`events` in `rando/world.py`), and every branch of one gift gets the same item.
Before 0.5.0 the generator patched every give node whose item parameter matched the vanilla item, which needed
filters for flows with several rewards (Talon, Dampe, the frogs). Each event is checked against its expected item
when the world is scanned, so a changed flow shows up as a warning instead of a wrong patch.

The upgrade rewards normally give the "Bigger" version, or the "Biggest" if you already own the Bigger one; both
branches carry the random item, and each event has its own one-time flag (later wins give rupees):

| Check | Flow (events) | Normal reward | Logic |
|---|---|---|---|
| GC Rolling Goron | `Npc_Goron_006_Child` (58, 92) | Bomb Bag | child Death Mountain + bombs |
| LW Target in Woods | `Dm_LostWood_0040` (30, 17) | Deku Seed Bag | Slingshot |
| LW Deku Theater Skull Mask | `LostWood_ScrubForestStageElder_SkullMaskFirst` (29, 32) | Deku Stick upgrade | child + Zelda's Letter |
| LW Deku Theater Mask of Truth | `LostWood_ScrubForestStageElder_TrueMaskFirst` (2, 31) | Deku Nut upgrade | child + Zelda's Letter + Saria's Song |
| Market Shooting Gallery Reward | `MiniGame_HitTarget` (241, 378) | Deku Seed Bag | child + Slingshot |
| Kak Shooting Gallery Reward | `MiniGame_HitTarget` (381, 242) | Quiver | adult + Bow |
| Market Bombchu Bowling Bomb Bag | `MiniGame_BombchuBowling` (304, 306) | Bomb Bag (2nd win) | child + bombs |
| GF HBA Quiver | `Minigame_HorsebackArchery` (320, 319) | Quiver | as the HBA Piece of Heart |

The other gifts: Darunia, Bombchu Bowling's Piece of Heart, horseback archery's Piece of Heart, the diving game,
Anju as child, Talon's first win, the Big Poe buyer's bottle, both fishing prizes, the lab dive, the frogs' song
game, Dampe's gravedigging tour, the Skull Kid, the ocarina memory game, the man on the roof and the lost dog.
Two checks are not in OotrR's list and keep the older matching: the frogs' bug game and Dampe's race prize.

The Deku Theater checks depend on the mask trading sequence, which the logic doesn't model: showing a mask needs
the masks from the Happy Mask Shop (Zelda's Letter at the Kakariko gate), the Mask of Truth also the Skull Kid
(Saria's Song). That is an approximation.

**Quest Rewards** (own setting, as OotrR's `shuffle_quest_rewards`): Zelda's Letter, the Light Arrows and
Biggoron's reward. Malon's egg follows Shuffle Weird Egg; the ocarinas follow Shuffle Ocarinas.

The upgrades go into the pool as the Bigger Bomb Bag, Bigger Seed Bag and Bigger Quiver, two copies of each:
- **Chests are progressive:** a chest holding one uses the game's conditional-chest check. You get the
  Biggest version if you already own the Bigger one, and the Bigger one otherwise.
- **Fill prefers chests:** capacity upgrades go into chests when possible, and they never go on shop shelves.

**Skulltula House wallets** (with Shuffle Skulltula House Rewards, since 0.4.0): both wallets go into the pool as
two Adult's Wallets that only chests can hold, with the same conditional-chest check: a chest gives the Giant's
Wallet if you already own the Adult's one. The logic counts two of them as the Giant's Wallet.

## Business Scrubs

From OotrR (`SCRUB_GIFTS`). The four scrubs that sell one thing once are checks:

| Check | Events in `Enemy_Scrub_Business_Common` | Normal sale | Game's price | Logic |
|---|---|---|---|---|
| LW Deku Scrub Stick Upgrade | 322, 317, 555 | Deku Stick upgrade | 40 | always (Lost Woods bridge) |
| LW Deku Scrub Nut Upgrade | 326, 318 | Deku Nut upgrade | 40 | bombs or hammer |
| HF Deku Scrub Piece of Heart | 645 | Piece of Heart | 100 | Hyrule Field + bombs or hammer |
| DMC Deku Scrub Piece of Heart | 293 | Piece of Heart | 100 | child Death Mountain Crater |

Each sale is a `SimpleShopSub_Scrub_Business_OneTime` call whose `ActorName` is the item and `Price` the price;
both are changed in place. The scrub has its own saved flag, set when the purchase succeeds. Price options
(Business Scrub Prices): 10 rupees, the game's price, random from 10 to 99 or from 10 to 200 per scrub; a price
above 99 needs the Adult's Wallet in the logic (`Plan._needs_wallet`).

**Sale line** (`rando/scrubtext.py`). Each call's `SellerMessageId` names its line in
`EventFlowMsg/Enemy_Event.msbt`, and the two heart scrubs share one (`Enemy_Scrub_Business_Heart_01`). So every
shuffled scrub gets a new label, `Rando_Scrub_<first event>`, in each language's `Enemy_Event.msbt` (UTF-8,
LBL1 and TXT2 only; the label goes into the LBL1 bucket its hash names, `h = h * 0x492 + byte`, mod the bucket
count), and its calls point at it. The line is the English heart line with the item's name in place of "a
Piece of Heart", keeping the colour tags and the `SimpleShop_Price` tag, which shows the call's own price. Refill scrubs (three choices, repeatable) and the
Dream World scrubs are not checks. The Lost Woods stick scrub is placed in both the Lost Woods and Kokiri Forest
stage files and uses the same events, so it is one check.

## Refills need their item

A chest can already say "if the player owns X, give Y, otherwise give Z" (`Drop__CheckActor`,
`Drop__DropActor_Substitute`, `Drop__DropActor`). For example, a vanilla chest gives arrows with the Bow and a
red rupee without. With **Refills Need Their Item**, every randomized chest holding arrows, bombs, Bombchus or
Deku Seeds gets that check against the Bow, the Bomb Bag or the Slingshot, with a blue rupee as the fallback.
Other check types (NPCs, freestanding items, heart containers, Gold Skulltulas) can't test for an item. The fill
therefore puts refills in chests, and any refill that doesn't fit in a chest becomes a blue rupee.

Deku Nuts and Sticks (since 0.6.0) have no item of their own, only a bag. A single nut or stick picked up
(`Item_DekuNut`, `Item_DekuStick`, `Obj_DekuStick`: `IsAbleToGetBagIfGet`, `SmallBagActor`
`Item_NutBag_Small` / `Item_StickBag_Small`) gives that bag, and only then do they have a slot. A bundle
(`TBox_DekuNutBundle`, `Item_DekuStickBundle_Small`) has no `IsAbleToGetBagIfGet`, so one found first was
lost. Their chests check for the small bag.

Unlike the original, the remake keeps Bombchus in the Bomb Bag: `Item_Bombchu`'s PouchContentParam has
`MaxNumGameData: "Bomb"` and `SmallBagActor: Item_BombBag_Small`. Bombchus picked up without a bag show the
"Five Bombchus" message but the count stays at 0 (reported in-game from a freestanding rupee spot).

## Time of day before the Deku Tree (open forest)

With Open or Closed Deku forest, time seemed not to pass in Hyrule Field until the Deku Tree was done.

**Cause (found in 0.2.4):** Hyrule Field's `WorldParam` (`ConditionEnvTimePalette`) and two
`EnvPaletteTimeTableChangeArea` actors switch on the flag `HyruleField_ChangeENV`. While it's false, the
field uses `MainField_Bluesky_First`, a light table with `IsForceMainLight: true` that pins the sun at one
angle. Vanilla sets the flag in Saria's bridge goodbye (`Goto_HyruleCastle`, right before the banc change to
Hyrule Field), which you only see after the Deku Tree. Leaving an open forest earlier kept the field on the
fixed sun.

**Fix:** with Open or Closed Deku forest (and with Shuffle Ocarinas, which skips that scene), the flag starts
as true, so Hyrule Field uses its normal day/night table from the first visit. The trade-off is that the
special first-visit lighting is gone. This hasn't been tested in-game.

Earlier versions documented this as a game-code limit. Quest rules, area files and cutscene commands really
don't stop the clock; the cause was this lighting flag.

## Using items early: the bomb fix

In the remake, a bomb pulled from the Bomb Bag is a *liftable* object. Lifting it needs the strength the
**Goron Bracelet** grants (lift grade `3655598229`). Without the bracelet, Link starts the pull-out animation
and then nothing happens. Vanilla never hits this, because you always get the bracelet before the Bomb Bag.

**Bag Bombs without Goron Bracelet** (`bag_bombs_no_bracelet`, called Bombs Usable Without Goron Bracelet /
`free_bombs` before 0.6.0; `settings.RENAMED` maps the old key) lowers the required lift grade of bag bombs (`Item_Bomb`'s
LiftableParam) to the grade pots, small rocks and Bombchus use (`3069107721`). The change is made in every
pack that carries a copy of that shared resource. Bomb Flowers use their own parameter, so they still need the
bracelet, as in vanilla. With the option off, the logic requires the Goron Bracelet before bombs count.

I checked every other item ability the remake grants on pickup:
- **Magic**: every magic item (Din's, Farore's, Nayru's, the Lens and all magic arrows) unlocks magic by itself.
- **Dive depth** (scales) and **adult gauntlet strength**: covered by the tier rule, which only places the
  Golden Scale or Golden Gauntlets where the Silver version is already required.

No other item depends on a different item being found first.

## Items lying in the world (freestanding, rupee, Heart Container and Gold Skulltula spots)

The game has two kinds of item actors:
- **`Obj_*` pickups** (`Obj_Item_Base`): rupees, Pieces of Heart, Heart Containers, tokens, small keys, shields,
  and Lake Hylia's `Obj_Arrow_Fire`. You walk up to them and collect them.
- **`Item_*` actors** (`Item_EventObject_Base`): the model an item-get cutscene puts in Link's hands. Most key
  items only have one of these.

Placed in the world, an `Item_*` actor just lies there and can't be collected. Examples are a Megaton Hammer
on a rupee spot, or Light Arrows dropped by a Gold Skulltula.

For every item that lands in such a spot without an `Obj_` actor of its own, the generator builds a new pickup
actor, `Obj_Rando_<item>` (`rando/pickups.py`):
- **Pack:** a copy of the `Obj_Arrow_Fire` pickup pack plus the item's own component files. A new ActorParam
  takes its model, name, animation, parameter-table and effect references from the item. A new
  PouchContentParam inherits the item's settings, with `PouchActor` set to the item.
- **RSDB:** `ActorInfo` and `GameActorInfo` rows cloned from `Obj_Arrow_Fire`, using the item's model fields and
  its `ActorName`, so the pickup shows the item's own name and get message. There is also a `PouchActorInfo`
  row cloned from the item. Rows are inserted in sorted order.
- **Size table:** entries for the new pack and the new files inside it.

The spot's own save flag, its actor hash, still records the pickup.

**Song pickups (0.4.5).** `Item_Melody_*` has no model: its ModelInfo and ActorInfo row point at
`Obj_Rupee` as a placeholder, because the song-get scene never shows it. So a song clone looked like a
green rupee. Song clones take `ModelInfoRef` and the `ActorInfo` model fields (`FmdbName`,
`ModelProjectName`, AABB) from `Dm_Item_Sheik_Harp`, the harp model from Sheik's song scenes. The
`ActorName`, pouch content and get text stay the song's (`pickups.MODEL_OVERRIDES`).

**Songs everywhere else (0.5.0).** A chest, a character, a scrub or a shelf shows the item's own actor, so a
song in a chest was still a rupee. With Songs Anywhere, `pickups.patch_song_models` gives every `Item_Melody_*`
pack the harp's ModelInfo file (same path, the harp's content) and its `ActorInfo` row the harp's model fields.

**Walk-over pickup (0.4.4).** Whether a pickup needs A is set by its `AttentionSenderRef`. `Obj_Item_Base`
uses `AutoPickUpItem`: touching the item collects it, like a rupee. `Obj_Arrow_Fire`, and so every
`Obj_Rando_` clone, overrides it with `PickUpItem`, which needs A. That made an item dropped by a Gold
Skulltula on a vine impossible to collect without the Boomerang or Hookshot, because Link can't press A
while climbing. Every shuffled item placed in the world now gets an `Obj_RandoAuto_<item>` copy of its
pickup:
- **Pack:** the same pack, with a new ActorParam whose `AttentionSenderRef` is `AutoPickUpItem`. The
  `AutoPickUpItem`, `Auto_Item_Catch` and `LookOnly_Middle_Small` files are copied from `Obj_Rupee_Green`.
- **RSDB:** `ActorInfo`, `GameActorInfo` and `PouchActorInfo` rows are copied from the pickup it copies.

This covers freestanding spots, rupee spots and Gold Skulltula drops. Pickups that already collect on touch
are used as they are: rupees, small keys, shields, the Ocarina of Time and tokens. So is a spot that keeps
its vanilla item.

The walk-over check reads the `IsEnableAttention` blackboard flag, which the `DropItem` AI raises.
`Obj_Heart_Piece` and `Obj_Bottle_Letter` run their own AI, so they keep needing A on the ground.

**Gold Skulltula drops** (0.5.0, issue #2) are built on the token's own pickup instead, as OotrR does:
`Obj_RandoGS_<item>` (`TOKEN_TEMPLATE` in `rando/pickups.py`) is a copy of the `Obj_Token_Gold` pack with the
item's model, name, animations, parameter table (merged with the pickup's drop and physics tables) and a
pouch setting that only names the item. It keeps the token's AI (`AI/Item_Token_Gold.root.ainb`), blackboard,
physics and `AutoPickUpItemLockOn_Token_Gold` attention, so:
- the drop floats where the Skulltula died, like a token, and is collected by touching it, even while climbing;
- the Skulltula writes its save flag into the drop's `GoldTokenGmdHash` and the token AI
  (`OneShotGoldTokenDeadAfter`) sets it on pickup, so a Skulltula stays dead only once its item is collected.
- Consumable junk (rupees, ammo, hearts, magic, the Business Scrub Seed) drops as the game's own pickup
  (`native_drop` in `rando/generator.py`, as OotrR does): it falls to the ground but is collected and stays gone
  (test seed 5). A token-based drop only disappears when its item has an `IsGet` flag: a token-based rupee built
  from the world rupee (`Obj_Rupee_*`) stayed on the ground after it was collected and its Skulltula came back
  (test seed 4), and so did token-based copies of the chest forms (`TBox_Rupee_*`, the ammo bundles; test seed 6).
  Shields (`GS_FLOATING_JUNK`) float like the other items. Junk with no pickup of its own (the bigger Bombchu
  bundles, `gs_refuses`) is kept off Skulltulas: the fill keeps enough other spots for it (a non-junk item takes a
  Skulltula once that junk needs every other spot) and, if that isn't enough, moves a placed non-progression item
  onto a free Skulltula; with more of it than other spots, a free Skulltula keeps its own token instead.

History: a dropped actor has no save flag of its own, and before 0.2.2 a shuffled drop (a plain pickup) came
back with its Skulltula whenever the room reloaded. 0.2.1 gave the plain pickup the token's AI, and the drop
didn't spawn at all. 0.2.2 to 0.4.5 set `IsSetGmdRespawnFlagToFalse: True` in `Enemy_Skulltula_Gold`'s death
procedures instead, so killing a Skulltula was permanent even when its drop was lost (issue #2), and
0.4.4 to 0.4.5 kept Pieces of Heart and Ruto's Letter off Skulltulas because their pickups need A. 0.5.0 drops
both: the whole token pack is the template, so its AI has everything it reads. Not yet tested in-game.

The earlier attempt at this (giving `Item_Arrow_*` packs the Boomerang's physics) didn't make anything
collectible, and it has been removed.

## Skip Epona Race (experimental)

Epona's Song calls a horse only once one is registered as yours (`OwnedHorseList` in the save, a horse-stable
struct like Tears of the Kingdom's: actor name, name, tack, body, stats). The game registers her itself: after
Ingo's race the quest is at exactly `AfterWonGambleRace` (`LonLonRanch_AfterWonGambleRace`), and riding Epona out
over a ranch fence (`Obj_LonLon_Fence_A_02`, `PlayEventName` `Get_Epona_EscapeRanch_EscapeFromA/B/C`) or through
the main gate (`Sub_Get_Epona_EscapeRanch_EscapeFromMainGate`) runs `Sub_Get_Epona_EscapeRanch_*_Warp`:
`Animal_Epona_Adult.EventCopyAndRegisterOwnedHorse`, `EventGoOffstageForUser`, then the challenge's Complete. The
ranch's Epona stands in `HyruleField_Adult_Static` (Lon Lon Ranch is part of the Hyrule Field scene) while
`Get_Epona_IsCompleted_Exp` is false.

`Dm_SY_Ocarina_EponaSong:EponaSong`, for adult Link, asks `GameSystemActor.EventQueryHasOwnedHorse`. With no horse,
inside the ranch fence (`LonLonRanch_GambleRace_IsInsideFence`) it calls the ranch horses over
(`EponaSong_CallHorseAround`). That branch now first checks, in order: not riding a rented horse
(`LonLonRanch_PlayingHorseRiding`), not racing (`LonLonRanch_PlayingGambleRace`), the quest not past
`GambleRacePlaying` yet, and the quest past `ReadyForGetEponaSong`. Then `ChallengeSystemActor.
EventExecuteProgressChallengeStep` moves `Get_Epona` to `AfterWonGambleRace`, and the flow goes on to the horse call
as before. Any other case calls the horses unchanged. In these flows a query's case 0 is true.

The quest steps: NotReady, Ready, GuideToLonLonRanch, GuideToLonLonRanchAdult, ReadyForGetEponaSong,
AfterGetEponaSong, ReadyForGambleRace, AfterTalkMalon, GambleRacePlaying, AfterWonGambleRace, Complete. Only child
Malon's song scene (`Dm_MelodyGet_Epona`, the Song from Malon check) moves it past ReadyForGetEponaSong, and child
Malon's flow picks that scene by step, so the quest isn't moved on earlier (nor set in the new save): that would
lose the check. The logic's `epona` has the same need (Song from Malon's rule) for the race and for this skip.

Earlier versions, which didn't work in-game: 0.5.0 rewrote `Get_Epona_IsCompleted_Exp` to "owns Epona's Song"
(that registered nothing and removed the ranch Epona; test seed 10). 0.5.0 - 0.6.1 registered the ranch's Epona
inside the song's flow (an added `Animal_Epona_Adult` actor with `EventMemberCreateMethod` 3, then register,
offstage, Complete, call): Epona never came (test seeds 11, 12 and a 0.6.1 seed). With method 0 an Epona appeared on
Link whenever the ocarina came out, at any age.

## Big Poe buyer needs only 1 Big Poe (experimental)

The ghost shop in the adult Market (`Npc_Hylia_048_BottleShop`) gives 100 points per Big Poe. Before each sale
its flow compares `GhostShop_CouponNum` with 900 (`EventQueryIsGameDataInt`): below that it's a normal sale, at
900 or more it's the final sale (`Sell_AfterCheckingLoseMoney_900`), which completes `SubEvent_GhostShop` and
gives his reward (the **Market Big Poe Bottle** check). The option sets that 900 to 0, so the first Big Poe sold
is the final sale. The logic still expects Epona, the Bow and a bottle.

## Skip Kaepora Gaebora (experimental)

His forced first talks count as already seen (`HavePlayedEvent.<scene>` True). Each one is started by stage logic
(`HoldGameDataHavePlayedEvent` in a `*_Prefab` logic module) or by `Dm_SY_BancChangeArrive`, only while that flag
is False:

| Scene | Where |
|---|---|
| `Dm_LostWood_0000` | Outside Kokiri Forest (the Lost Woods bridge). Its Goron City version (`EnterFromGoronCity`) only plays while this one is unseen |
| `Dm_LostWood_0010` | Lost Woods after Saria's Song (`Dm_SY_BancChangeArrive`, once `HavePlayedEvent.SacredForestMeadow_Field_MelodyGet_Saria` is set). Added after seed 3LETP69LQZ |
| `Dm_HrlField_0000`, `_0005`, `Dm_HrlField_0010` | First Hyrule Field talk (`Goto_HyruleCastle:Goto_HyruleCastle_Kaepora_00`). `_0000`/`_0005` added in 0.6.0: `HavePlayedEvent.Dm_HrlField_0000` also ends the field's BGM-off stretch (Bootup `BGMGeneralParam_Default` `SequenceRangeDisableBgm`, Clawshot) |
| `Dm_HrlField_0030`, `Dm_HrlField_0040` | Hyrule Field (0040 after visiting Gerudo Valley) |
| `Dm_HrlField_0050` | Hyrule Field on the way to Lake Hylia (`HyruleField_Child_Prefab_b9db`: unless seen or `IsVisitLocation.LakeHylia`). Added in 0.6.0 |
| `Dm_HrlCastle_0000` | In front of Hyrule Castle (an entrance `InitEvent` on `HavePlayedEvent.Dm_HrlCastle_0000`; talk only). Added in 0.6.0 |
| `Dm_ZoraRiver_0000`, `Dm_ZoraRiver_0005` | Zora's River |

The first Hyrule Field talk also opens the quest menu (`UI_IsFinishChallengeMenuOpenEvent`), sets
`HyruleField_ArriveEntrance` and gives the amiibo menu item (`Pouch_Amiibo`); those are set too, as Skip Child
Zelda does. Its quest step matters (fixed in 0.6.0): the talk moves `Goto_HyruleCastle` to `Step02`, and
Castle Town's entry event (`Market_Child_Prefab_c061`: `HoldChallengeCurrentStepCheckOrder` on `Step02`, then
an AND) only fires at exactly that step, which starts the chain to Zelda's courtyard (Clawshot: the courtyard's
`HyruleCastle_Prefab_941f` fires at exactly `Step04`). So without Skip Child Zelda the quest now starts at
`Step02` (`KAEPORA_QUEST`); Skip Child Zelda sets it to Complete instead. Left alone:
- `Dm_HrlField_0080` (sets `DreamWorld_Open`).
- His optional rides at Lake Hylia and Death Mountain, which only start when you talk to him.

## Items Shuffled Per Shop

From OotrR (`shopsanity`, `game/item_forms.py`): every shelf placement (`Shop_*`, not masks, signs or swords) is a
slot, 64 in all: the Kokiri, Goron and Zora shops, the Market's bazaar, potion shop and Bombchu shop, and
Kakariko's bazaar and potion shop. The Market and Kakariko stage files hold several shops each; they are told
apart by where their shelves stand (shelves of one shop are within 6 m of each other). A slot's child and adult
placements are one check.

- **Choice:** N slots per shop (1 to 4, or 1 to 4 at random per shop). One shelf of every purchase the game needs
  stays on sale somewhere: the Deku and Hylian Shields, both tunics, Blue Fire, bugs, fish and fairies (the
  Deku Shield and the tunics are sold in one shop only, so they never move).
- **Shelf:** a shuffled slot's placement gets a new actor, `Shop_Rando_<item>`, instead of its shelf. It is the
  arrow shelf `Shop_ArrowBundle_01` (its shop AI, physics and put-in-pouch parameters) with the item's model,
  name and animations, a pouch setting that names only the item, the item's game parameters, its price (Shop
  Prices: 10 rupees, or random from 10 to 99 or 10 to 200 in steps of 5; above 99 needs the Adult's Wallet in
  the logic). RSDB rows: `ActorInfo` and `GameActorInfo` from
  the shelf with the item's model fields, `PouchActorInfo` from the item with the shelf's price.
- **Because the placement changes, not the shelf type,** a shelf sold in several shops can be shuffled in one of
  them only. Before 0.5.0 the shelf packs themselves were edited, so only shelves unique to one shop could be used.
- **Bought once:** the placement gets `Presence` `{FlagName: IsGet.<item>, IsNegation: true}`, so the shelf is
  gone once the item is owned. OotrR's `NoRespawn` save setting only acts when a pickup is collected; with it a
  bought shelf could be bought again (test seed 4). So a shelf only sells an item that exists once in the seed
  and has an `IsGet` flag (`Plan.sold_once`: songs, equipment, key items; not bottles, whose flag filling an
  empty bottle may set), and slots that already have a
  `Presence` condition (the Kokiri shop's full stock) are never used.
- **Restrictions:** tokens and the capacity upgrades never go on a shelf. A shelf that rolls junk keeps its goods.
- **Text:** the shelf uses the item's own name; no shop caption is added (as in OotrR).

## Anju needs only 1 cucco

The minigame logic (`Logic/MiniGame_CatchCucco_c69b.logic.module.ainb`) finishes the minigame when a compare
node's constant input `Int_A = 7` equals the live fence count. The option sets that constant to 1. Anju's
event flow also keeps a "cuccos left" counter that starts at 7 and is compared with 7 for her dialogue, so
both of those become 1 too. Her reward stays randomized.

## Small Chests Only (removed in 0.5.0)

Turned big chests into small ones (`Obj_TBox_A_02` / `A_03` -> `A_01`) to get the short opening.
Chests Without Cutscene does that for every chest without swapping models, so the setting was removed.
Settings strings that still have it import without it.

## Dungeon items in small chests

Only the big chest's opening credits a dungeon's map, compass or boss key (reported by the Clawshot
randomizer, confirmed in the flows):

- `Dm_SY_Treasurebox` has an entry, `Success_AddContent`, that asks
  `EventQueryTreasureBoxIsDungeonCommonItemInside` what the chest holds. For a map, compass, boss key or small
  key it runs `EventGetDungeonMap` / `Compass` / `BossKey` / `SmallKey` (the boss key also turns on the boss
  key display). Anything else is added to the pouch.
- `Dm_SY_TreasureboxSmall`'s own item steps (`ItemDisplay`, `ItemDisplayNoSpace`) only add to the pouch. A
  boss key from a small chest left the boss door shut, and a map or compass left the pause map blank.

`patch_small_chest_dungeon_items` (`rando/qol.py`) adds the big chest's steps inside the small chest's flow,
in front of its pouch check (`EventQueryCanAddToPorch`, reached from `ItemDisplay` and `ItemDisplayNoSpace`):
the question (on the small chest's own `TreasureBox_EventStarter`, by the item's actor name); for 0-2 the get
text (`GetPouchContent:DisplayGetByActorName`, listed in the entries' `sub_flow_events`), then
`EventGetDungeonMap` / `Compass` / `BossKey` (+ boss key display and a 50-frame wait) and the pick-up window;
for 3 (small key) and 4 the small chest's own steps. The question decides by the item, so one edit covers every
small chest whatever the seed puts in it. Applied with Maps & Compasses: Own Dungeon or Boss Keys: Own Dungeon.

The first 0.5.0 version instead pointed the small chest's `ItemDisplay` calls at
`Dm_SY_Treasurebox:Success_AddContent` (another flow file, added to the small chest's `SubFlowList` in
`RSDB/GameAnalyzedEventInfo`). That skipped the small chest's item display (fanfare, model in Link's hands), and
in test seeds 3 and 4 small chests could not be opened at all.

## Requested but not possible from the game data

- **Keysanity (keys anywhere).** The remake has one generic small key and one generic boss key (Ganon's
  included). The stage you pick a key up in decides which dungeon it counts for (`RSDB/DungeonParam` defines
  these per stage), and no event action can add a key to a different dungeon. A Forest Temple key found in
  Kakariko would count for Kakariko. **Own Dungeon** (Dungeon Items tab) is the most that works.
- **Bunny Hood speed boost.** Running speed comes from the animations; the only speed value in the data is a
  global `GroundSpeedScale`. Masks have no movement parameter. Equipment effects are hashed names
  (MurmurHash3), and the one I could decode is the Zora Tunic's `UnderwaterBreathing`. There's no speed effect
  I can confirm the engine supports, and the executable uses a compression format I can't read.
- **Fast climbing.** The climb speed is computed by the player code and handed to the climb animation at
  runtime (`PrevClimbSpeedRate`); no data file holds it.
- **Scrubsanity (all scrubs).** Only the four one-time scrubs are checks (Business Scrubs). The others sell
  refills through the Scrub Business Seed trading system: their goods and prices are fixed per item type inside
  one shared event flow, and they restock.
- **Auto-skip all cutscenes.** Items, songs and story flags are handed out inside the cutscene flows, so
  removing cutscenes wholesale would lose them. Every cutscene can be skipped with the button, and the
  side-effect-free area intros are skipped automatically.

## Per-seed saves

`rando/saves.py`. The game keeps one save folder per account, the same files everywhere:
- Longshot: `%APPDATA%\Longshot\save\<account id>\` (Linux: `$XDG_DATA_HOME/Longshot/save`, `~/.config/Longshot/save`);
- yuzu-family emulators: `<NAND>/user/save/0000000000000000/<profile>/0400486024DEC000/`, found from the output
  folder `<user>/load/0400486024DEC000`. `<NAND>` is `<user>/nand` unless the emulator's `<user>/config/qt-config.ini`
  sets `nand_directory` (Fritchii's points at Lichii's NAND, and its `load_directory` at Lichii's `load`: a seed in
  Fritchii's own `load` folder wouldn't be read, so the log and the Seeds card warn when `load_directory` is
  another folder). Checked on Lichii and Fritchii; a copy of Lichii's real save went through two seeds and came
  back byte for byte, and its save folder holds nothing but the game's files and the marker.

Contents: `option.sav` (options, 42 KB), `account.sav` (320 bytes: a table of 32 entries plus a flag that changed
during play), and `slot_00` ... `slot_05`, each `caption.sav` + `progress.sav`. Longshot also writes
`temp/TemporaryGame.sav` while saving; it isn't touched.

Everything but `option.sav` belongs to a seed. A marker file in the save folder (`goggles_of_truth_seed.txt`)
names the seed whose files are there. `switch_saves(target, seed)`:
1. copies the current files into the owner's folder, `<seed folder>/saves/<account>/`, with the seed's
   `settings.txt` as `seed_settings.txt`; with no owner (or its folder gone), and any slot not empty, into
   `save_backups/<time> unassigned <account>/` instead;
2. removes the live `slot_*` (and `account.sav` if the new seed has one stored) and copies the new seed's stored
   files in. A seed with nothing stored starts with no slot folders (the game makes them, as on a new account)
   and keeps the current `account.sav`. Stored files whose `seed_settings.txt` differs from the seed folder's
   `settings.txt` (a folder name used again for another seed) are moved to `save_backups/` instead;
3. writes the marker.
It refuses while the game runs (Longshot: a `longshot*` process other than the launcher; emulators: any `.exe` of
a portable emulator's own folder, or a known emulator name), since the game keeps its saves open.

Switching seeds: Longshot skips mod folders starting with `.`, `-` or `_` (`_<seed>`, as before). The yuzu family
loads every folder in `load/<title id>/` that isn't disabled in its own configuration, so seeds there are moved to
`load/GogglesOfTruth_off/` (not a title id, so it isn't read). Other mods are left alone.

The generator switches after writing a seed (`per_seed_saves`, left out of the settings string: it doesn't change
the seed). If the game is running, the seed is still written and the log says to use **Play This Seed** later.
Tested on fake save folders (store, restore, backups, reused names, emulator moves), then in Longshot and in Lichii.

## Status badges

Each setting's status comes from its label (`settings.split_status`): "needs ... testing" is In Testing, "experimental"
or "not working" is Experimental, anything else Stable; for a drop-down, the chosen option's own note counts first
(`setting_status`). The window shows it as a badge instead of the text. The badges are Raven XML widgets declared in
`rando/ui/widgets.xml` (a `<Widget Name="...">` with its parameters and their defaults as attributes, `{Parameter}`
inside): `Badge` (the pill: a `Border` with corner radius 11 and a centred `Label`) and `StableBadge`, `TestingBadge`,
`ExperimentalBadge` (text and colours). `gui_glass.py` registers the file (`Rxml_register_widgets_from_file`) before
it creates the window from `main.xml`, writes `<StableBadge Name="badge_<key>" LabelName="badgelab_<key>"/>` into
each generated settings row, and reads the three badges' colours from the same file to recolour a drop-down's badge
at runtime (`Rborder_set_background`, `Rlabel_set_text`).

## Reading the game from a .nup

`rando/gamefiles.py` is the one place the generator reads game files from. `FolderFiles` reads an extracted romfs
folder; `NupFiles` reads a `.nup` (NX Package, a55uka/nup) without extracting it. Both offer `read`, `exists`,
`isdir` and `listdir` on romfs-relative paths, and `World(game)` takes either a folder or a `.nup` path; every
module reads through `world.files` (or `world.zs`, which reads through it).

A `.nup` holds packages (base, update, add-on), each with its own exefs and romfs folder tree. As in Clawshot,
the newest base/update package of the one game in the file is used, and only a package with a complete romfs is
accepted (the original dump holds a standalone update 2.0.0, a repack holds the base; both are full). The folder
tree is indexed once; each file read is decompressed if needed (zstd extents, via the standard library) and
checked against the SHA-256 in the package's table of contents. `gamecheck.check_nup` hashes the package's own
`exefs/main` for the version check. The `.nup` is memory-mapped read-only, so the output-folder guard only
applies to romfs folders.

## Event flow editing

Most patches change a flow file in place (re-pointing a string, rewriting case targets). Edits that add events
use `rando/evfl.py`, Clawshot's BFEVFL reader and writer: it reads a flow into plain objects and writes it back
in the game's own layout, and rewrites all 914 of the remake's flow files byte for byte. Each edit checks the
structure it changes, refuses anything else, and reads its result back. An entry point lists the sub flow calls
reachable from it (`sub_flow_events`); a call missing from that list hung the game in Clawshot's tests, so new
calls are registered.

## New game start, Skip Opening Movie, the Great Deku Tree's Talk

- **New game start (every seed, 0.6.0, `faststart.start_outside`):** `Sequence/Opening` runs
  `OpeningEvent:Opening_Introduction` once on a new save (`Sequence_ReservedBootEventName`). It fades out,
  sets `Meet_DekuTree` Step01, pins the terrain at the Deku Tree (`Event31`), moves the event camera there
  (`Event32`), waits 75 frames (`Event27`) and plays `Dm_Kokiri_0030`: Navi's flight to Link's bed and Navi
  waking him, a 12,544-frame timeline (`GameAnalyzedEventInfo`). After 0.5.1 testers saw about 30 seconds of
  black after New Game. Now the terrain pin moves to the spawn, then `Player_Event.EventPlayerWarpToTargetPosAndRot`
  and `Npc_Navi.EventTriggerNaviWarpToTargetPosAndRot` put Link and Navi in front of the Kokiri Shop, a
  30-frame wait, and the flow joins the native fade-in `Event26` and its tail (BGM, Navi talked to, autosave).
  The spawn is an NPC standing anchor (`AnchorAction2`, 2.24, 110.75, -11.24) in front of the shop door
  (`Obj_Kokiri_DoorPillar_A_01` at -0.9, 110.1, -18.3), YAngle 205 (0 faces +Z, 90 faces +X: `Dm_Kokiri_0075`
  turns Link to the Deku Tree with 95). The cut events stay in the file, unreachable. Saria's wake-up state
  (below) and `HavePlayedEvent.Dm_Kokiri_0030` (read by the basic-controls tip's logic) are new-save values
  on every seed; the Skip Saria's Wake-Up Scene setting was removed (`settings.BUILT_IN`). Float parameters
  are rounded to binary32 first so the flow reads back.

From Clawshot (`rando/faststart.py`, `rando/gamedata.py`):
- **Opening movie:** `OpeningEvent:Opening_LoadingKokiriForest` plays `Dm_Kokiri_0000` while Kokiri Forest loads,
  then waits on `EventQueryBancChangeIsLoaded`. The entry now starts at that query, and the movie's event
  becomes a one-frame wait back to it (its "not loaded yet" case).
- **Saria (every seed since 0.6.0):** new-save values only: `HavePlayedEvent.Dm_Kokiri_0045` / `_0050` / `_0060`,
  `KokiriForest_LinkHouseDoor_Open`, `HaveTalked.Npc_Kokiri_Saria_Child`, and `IsVisitLocation.KokiriForest`
  (the area banner of `Dm_Kokiri_0045` sets it; without it the pause map stays unavailable).
- **Deku Tree:** the talk's state is `HavePlayedEvent.Dm_Kokiri_0070`, `Meet_DekuTree` Complete,
  `Get_StoneOfForest` GoInside and `KokiriForest_Meet_DekuTree_OpenDekuTreeMouth`. With Kokiri Forest Open
  (Mido gone) these are new-save values. With Mido kept they are set at the end of his own sword-and-shield clear
  (`Npc_Kokiri_Mido_Child` Event26 to Event0): setting them on a new save picks the wrong Mido schedule.

## Skip Story Scenes (experimental)

`rando/storyskip.py`. Story scenes are not started by the area but by a quest flow, which plays them one after
another with `EventSystemActor.EventTransition` and then moves Link on (`EventReserveBancChange`):
- `DoorOfTime`: `Dm_TimeTemple_0010` (the door opening), `_0020`, `_0040` (Ganondorf), `_0030` (the Master Sword),
  `Dm_SageRoom_0000` (Rauru, a timeline) and `Dm_SageRoom_0005` (Rauru's talk and the Light Medallion);
- `AllSage`: `Dm_TimeTemple_0050` / `_0055` (Sheik's first talk as adult), `Dm_SageRoom_0010`, `Dm_TimeTemple_0090`
  to `_0135` (the sages, Zelda's reveal, `_0130` the Light Arrows);
- `Dm_SY_BancChange_EscapeDungeon` (after each boss): `Dm_Awake_<sage>` and `Dm_Awake_<sage>_Get` (the medallion),
  `Dm_Kokiri_0130`, `Dm_DeathMtTrail_0025` and `Dm_ZoraFountain_0030` (the stones);
- `Goto_HyruleCastle`: `Dm_Kokiri_0150` / `_0155` (Saria's goodbye on the bridge and the Fairy Ocarina).

Added in 0.5.1, from a survey of every `EventTransition` in the game (the ootdump flow dumps), each one run
through the same checks as above before it was listed:
- `Dm_SY_BancChange_EscapeDungeon`, the rest of each post-boss chain: `Dm_Deku_0010`, `Dm_Kokiri_0080` to `_0095`
  and `_0140` (the Deku Tree's last talk and death), `Dm_Kokiri_0158` to `_0162` (the Deku Sprout),
  `Dm_DodongoCave_0030`, `Dm_DeathMtTrail_0020` / `_0027`, `Dm_DeathMtCrater_0010`, `Dm_InsideJabu_Jabu_0060`,
  `Dm_ZoraFountain_0020`, `Dm_ForestTemple_0020`, `Dm_FireTemple_0030`, `Dm_WaterTemple_0040`, `Dm_LakeHrl_0020`
  (the lake refilling), `Dm_ShadowTemple_0020`, `Dm_Graveyard_0030`, `Dm_Kakariko_0025`, `Dm_SpiritTemple_0040`,
  `Dm_DesertColossus_0040`;
- `SageOfForest` (`Dm_LostWood_0021` / `_0025`), `SageOfFire` (`Dm_FireTemple_0000`), `SageOfWater`
  (`Dm_WaterTemple_0010` / `_0015`), `SageOfSpirit` (`Dm_DesertColossus_0020` to `_0030`, `Dm_SpiritTemple_0010` to
  `_0030`, `Dm_TimeTemple_0086` / `_0087`): Sheik, Mido, Ruto and Nabooru before each adult temple;
- `Defeat_Ganon`: `Dm_InsideGanonCastle_0000` (the first visit), `_0006` to `_0085` (each trial's barrier and its
  sage; the scene sets `InsideGanonCastle_Dungeon_BarrierRemove_<trial>`, which is copied), `_0090` / `_0110` (the
  tower barrier), and `InsideGanonCastle_CommonGimmick`'s `Dm_InsideGanonCastle_0005`.

Left playing on purpose, although they pass the checks: `Dm_ForestTemple_0016` (moves the Forest Temple's elevator
and candlesticks) and `Dm_ShadowTemple_0010` (the boat; sets `ShadowTemple_RoomB3FB4FJ_Departure`), which are
gameplay; `Dm_SageRoom_0020` / `_0025` / `_0027`, which follow `Dm_FinalBattle_BossOut` (the ending); the child
Zelda / Impa scenes in `DoorOfTime` and `Goto_HyruleCastle` (Skip Child Zelda); song lessons, boss intros and
outros, Ganondorf, Ganon and the ending. Refused by the checks (they keep playing): the Jabu-Jabu scenes with Ruto,
Darunia's dance and Goron City scenes, the Zora's Domain / Zora's River scenes, the Water Temple water-level scenes,
the Fire Temple chain lock, the Gerudo Fortress scenes, the escape from Ganon's Castle.

Each of those transitions is replaced in the quest flow by what the scene leaves behind:
- a scene that is only a timeline (camera, voices, actors; no flowchart, so nothing in it changes the save) is
  marked as seen: `HavePlayedEvent.<scene>`, which the quests read (`AllSage` checks
  `HavePlayedEvent.Dm_Awake_Spirit` / `_Shadow`, `DoorOfTime_Draw` checks `Dm_TimeTemple_0040`);
- a flowchart scene is checked to do nothing but talk, animate, set plain save flags (copied) and hand over one
  item with `GetPouchContent:GetPouchContentByActorName`. Its `ActorName` is read from the already-patched scene,
  so it is the randomized item, and the quest flow makes the same call after a fade-in, as NPC flows without an
  event-info row do (`Npc_Bonooru`, `SubEvent_GetSwordBigGoron`). A scene that adds its item itself
  (`PouchSystemActor.EventTriggerAddOrRemovePouchContent`, then `GetPouchContent:DisplayGetByActorName`: Saria's
  Fairy Ocarina) has those two steps copied. Every entry point lists exactly the sub flow calls it reaches
  (`sub_flow_events`; true of every flow in the game), so the lists are rebuilt after the change.

**Event info** (`update_event_info`). An event is a row of `RSDB/EventSetting`: the flow file and entry it runs
(`FlowchartFileName`, `EntryPointName`; the event name is usually the entry's, but e.g.
`ShadowTemple_SageOfShadow_SageRoom` runs `ShadowTemple_Warp_ChamberOfSages`, and the Master Sword pull
`Market_Child_DoorOfTime_Draw` runs `DoorOfTime_Draw`). An event with a row in `RSDB/GameAnalyzedEventInfo` lists
there every other flow its entry calls (`SubFlowList`): true of all 2037 such events in the game; 1997 events have
no row and call what they like. A call to a flow that isn't listed stops the event:
- test seed 7: Rauru's boot event in the Chamber of Sages (`SageRoom_MeetRauru`, no `SubFlowList`) stopped at the
  new `GetPouchContent` call, leaving Link on a white screen in that room;
- test seed 8 (a version that ran the Chamber of Sages steps in the Temple of Time instead, which made the pull
  event call `ReplaceEquipmentForEraChange` and `GetPouchContent`): the Master Sword couldn't be pulled, and Saria's
  bridge event (`KokiriForest_ArriveLostWood`) didn't run at all, so no ocarina.
So after the skip, every event of a changed flow that has a row gets the flows it now calls added (12 events,
all `GetPouchContent`). `ChildEventList` (the scenes it plays) may list more than the event plays (169 events in
the game do), so the skipped scenes stay in it. The table is written back with the same size and content (only
the order inside differs), the way `rando/pickups.py` writes its tables.

**Fades** (`first_fade`). Most of these scenes start on a faded screen and fade it in themselves: the stage change
to the Chamber of Sages uses a white fade (`FadePattern: 2`), `Dm_SageRoom_0000` and every `Dm_Awake_*` scene start
with a white fade-in (`Color: 1`), the Temple of Time timelines with black or white. A skipped scene whose first
fade is a fade-in gets an `UISystemActor.EventEventFadeIn` in that colour; an item scene fades in before its item
window in its first fade's colour. A scene whose transition is only reached from another skipped scene's
transition adds none, so a run of skipped scenes fades in once. Test seed 9 used a black fade-in everywhere: the
Light Medallion was given in the still-white Chamber of Sages and its window wasn't seen.

A scene that branches on quest state or save flags (other than owning an item, `IsGet.*`), changes the pouch,
a quest or the area, or calls another sub flow is refused and keeps playing; the generator log names it. Song
lessons (`Dm_MelodyGet_*`), boss intros and the ending are not on the list. The game's skip button already skips
timeline scenes (Make All Cutscenes Skippable); talking scenes like Rauru's can't be skipped that way.

## Chests Without Cutscene

From OotrR (`rando/faststart.py`):
- **Big chests** (`Dm_SY_Treasurebox:Success_`): `/Success_PlayerPerform` (camera, Link's kick, the spinning
  item, a 473-frame wait) and the 90-frame wait after it are replaced by the chest's own `/Open` (the lid,
  not awaited), then Link's item-get pose (the actions of `Dm_SY_GetInEvent`) while `/Success_AddContent` adds
  the item and shows its window. The fanfare starts without its intro.
- **Small chests are left alone** (since 0.5.0 test seed 3). OotrR's small-chest version
  (`faststart.quick_small_chest`: the lid's own actions and Link's get pose in place of `/Open`) left small
  chests impossible to open in the remake, and their own opening is short. The function is kept, unused.

## Gossip Stone hints

`rando/hints.py`, after Clawshot's hint system (which follows OoT Randomizer's):
- **Stones:** every talking stone is an `Obj_GossipStone_A_01` whose `Name` (`GOSSIP_<AREA>_<NN>`) is also the
  label of its line in `EventFlowMsg/GossipStone.msbt`. There are 40 (one Lost Woods stone is placed in both the
  Lost Woods and Kokiri Forest files). A hint is written into that message in every language archive
  (`Mals/*.sarc.zs`), in English, in the stone's own style tags, 60 characters a row and two rows a page, with
  the area, item and location names in the highlight colour.
- **Readable:** a stone is readable when its stage area is reachable (`logic.REGIONS`); a stone placed in another
  area's stage files sits in a grotto and also needs that area's grotto requirement. With Mask of Truth
  Required, only as child holding the Mask of Truth. The logic doesn't model the mask quest, so that is
  approximated as: child out of the forest, Zelda's Letter and Saria's Song.
- **Kinds:** Way of the Hero (an area holding a shuffled item the seed can't be finished without, found by
  re-running the playthrough with that item withheld), barren (an area with no required or major item), item
  (the area of a major item), always / sometimes (listed locations), random (any location with a progression item
  or a heart), and junk. Weights per distribution are OoT Randomizer's balanced and strong. Own-dungeon keys,
  maps and compasses are never named.
- **Placement:** a hint that names a location goes only on a stone readable with that location's item withheld.
  With Mask of Truth Required, no hint names an item needed to get the mask. Junk lines take the unreadable
  stones first.
- **No Mask of Truth:** the `GossipStone` flow asks two Mask of Truth questions before the stone's line (in the
  pouch, then worn). Both now send every answer where "yes" went.

## Cutscene skipping

The remake already lets you skip almost every cutscene. Only one shared setting
(`Event/EventSetting/EventSettingComponent/SkipSetting/DisableSkip...bgyml`) blocks skipping, and the opening
cutscene, the staff credits and the title-screen demos use it. **Make All Cutscenes Skippable** writes a copy
of that file with skipping allowed.

Cutscenes aren't removed outright, because the remake grants items and sets story flags inside them.

## What gets randomized (about 200 locations by default, up to about 480)

- **178 chests**, including invisible Lens chests and conditional chests. The conditional "only if you don't
  own X" behaviour is removed when a conditional chest is randomized.
- **18 freestanding items**: Pieces of Heart, Fire Arrows at Lake Hylia and Ruto's Letter. Freestanding small
  keys follow the Small Keys setting.
- **8 boss Heart Containers**, **100 Gold Skulltulas** (Tokensanity only)
- **Event rewards**: 12 songs, 9 dungeon rewards, 6 Great Fairies, 26 character gifts and minigames, 3 quest
  rewards, Malon's egg, 5 Skulltula House rewards and 4 Business Scrubs
- **Up to 32 shop shelves** (Items Shuffled Per Shop: up to 4 in each of the 8 shops)
- **109 freestanding rupees** (**Shuffle Freestanding Rupees**, off by default):
  - **Where:** green, blue, red and purple rupees in Hyrule Field (26), Zora's River (20), Kokiri Forest
    (17), Zora's Fountain (16), Death Mountain Crater (10), the Graveyard (8), Death Mountain Trail (6) and
    Zora's Domain (6).
  - **Not the Deku Tree scrub drops** (since 0.4.3): the three `ScrubDekuRupee_*` rupees appear inside the
    beaten Deku Scrub's flower (Presence `Enemy_Scrub_Deku_ItemDrop_0N`). A rupee there can be collected,
    but an item placed there sat behind the flower's collision and couldn't be picked up (0.4.2 report).
  - **Collected once:** each rupee placement has its own save flag in `Bool64bitKey`, like a freestanding
    Piece of Heart, so an item placed there doesn't respawn.
  - **Patching:** the actor's `Gyaml` is swapped, and placements shared by the child and adult stages
    count as one check.
  - **Logic:** the six Zora's Domain rupees lie at the bottom of the pool, so they need the Silver Scale
    as child or the Iron Boots as adult. The others follow their area's rules.
  - **Left alone:** silver rupees are puzzle pieces with linked counters, so they aren't touched.

These are always left vanilla: the Ocarinas (unless Shuffle Ocarinas is on), the Master Sword, the Gerudo Membership Card (the guards, the wasteland gate, the Training Ground and horseback archery check the Spirit quest step `SageOfSpirit_IsAfter_Step03_Exp`, set only by the captain's scene after the carpenter rescue; the card itself only stops the jail in the sneak areas, `Logic/GerudoFortress_Common_35d7`), the adult trade sequence's items (all trade items share one slot and adult items take priority, so an adult trade item found as a child would hide the Cucco for good; its final reward, the Biggoron's Sword, is the **DMT Biggoron** check), the Treasure Chest Game (its prize chest shows its prize through a minigame-only preview model), the Deku Tree's Slingshot
upgrade, the masks, the refill Business Scrubs, cows and the Treasure Chest Game. The
trap chests and the Hall of Fallen Foes are left untouched.

## How it works

| File | Role |
|---|---|
| `rando/formats.py` | zstd with the game's ZsDic dictionaries; SARC read/rebuild (byte-identical on unchanged archives); a type-exact BYML v7 reader/writer (both byte orders); BFEVFL reader and string-parameter patcher; RESTBL; MSBT read and text replace |
| `rando/world.py` | Scans the stage files, event flows and shops for item locations, reads names, and picks the right actor name for each item in each context |
| `rando/logic.py` | Region/age logic modelled on the classic randomizer |
| `rando/generator.py` | Assumed fill (most constrained items first), playthrough validation, patch writing, spoiler |
| `rando/qol.py` | Quality-of-life patches (Anju) |
| `rando/gamedata.py` | Default save-data edits (open settings, Epona, area intros) |
| `rando/gamecheck.py` | Game version check: SHA-256 of `exefs/main` (from the exefs folder or the `.nup`) against the supported-version list |
| `rando/gamefiles.py` | The game's files, from an extracted romfs folder or a `.nup` package |
| `rando/nup/` | The `.nup` reader (a55uka/nup, MIT, as vendored by Clawshot) |
| `rando/pickups.py` | New actors for items in the world, on Gold Skulltulas and on shop shelves |
| `rando/evfl.py` | BFEVFL reader and writer for edits that add events (from Clawshot) |
| `rando/faststart.py` | Opening, Deku Tree and chest flow edits (from Clawshot and OotrR) |
| `rando/hints.py` | Gossip Stone hints: choosing, stone text, the Mask of Truth flow edit |
| `rando/scrubtext.py` | Business Scrub sale lines naming the item (new MSBT labels) |
| `rando/door.py` | Door of Time: Open (from Clawshot) |
| `rando/storyskip.py` | Skip Story Scenes: quest-flow transitions replaced by the scene's flags and item |
| `rando/usersettings.py` | `user_settings.toml` (next to `goggles_of_truth_rando.pyw`): the window's settings and folders, loaded when it opens and saved on every change. Read with `tomllib`, written by hand with every setting's allowed values as comments; invalid values fall back to the default. Takes over `~/.ootr_remake.json` once |
| `rando/updater.py` | Update check at launch, called from `goggles_of_truth_rando.pyw` before the window is imported. Only in a git clone with an upstream branch: `git fetch` (15 s timeout, `GIT_TERMINAL_PROMPT=0`, no console window), then `git pull --ff-only` when behind and the tree has no tracked changes and no local commits. Runs `pip install -r requirements.txt` when that file changed. Restarts with `sys.executable` and `OOTR_JUST_UPDATED=1` (so the new process doesn't check again), and passes the log text in `OOTR_UPDATE_MSG`, which `gui_glass` writes to the log. Off with `[app] auto_update = false` (`usersettings.load_app`; `save` keeps the `[app]` section) or `OOTR_NO_UPDATE` |
| `rando/longshot.py` | Longshot (PC version) support. `find_builds()` reads the launcher's `builds.json` (Windows `%LOCALAPPDATA%\LongshotLauncher`, Linux `~/.local/share/LongshotLauncher` or `~/.config/LongshotLauncher`; entries have `folder`, `name`, `nup`, `default`), then scans `~/Games/Longshot/*` and the launcher's `buildsFolder`; a game folder is one with `longshot_version.txt`. Mods go in `<game folder>/mods/<mod>/romfs` (seen in Longshot's log: `mods: 2 mods from D:\Games\OOT PC\mods`). Longshot loads every mod there, sorted by path, and skips names starting with `.`, `-` or `_`, so after a successful generate into a `mods` folder `generate()` renames the other `GogglesOfTruth_*` (and pre-0.6.0 `OoTR_Remake_*`) folders to `_<name>`. The launcher installs each version in its own folder, so `newer_build(out)` returns the default build when the saved output is the `mods` folder of an older version (`longshot_version.txt`, `v3.0.0-rc.3` < `-rc.4` < `v3.0.0`), and the window switches to it at startup. Longshot merges its button prompts into a mod's `ResourceSizeTable` itself and ignores exefs patches (the randomizer writes none) |
| `rando/gui_glass.py` | The Raven GUI (`goggles_of_truth_rando.pyw` starts it); its layout is `rando/ui/main.xml`, Raven's XML format, with the settings cards made from `rando/settings.py` when the window opens |

How each location type is patched:
- **Chests**: `Dynamic.Drop__DropActor` in the stage file.
- **Freestanding items and Heart Containers**: the actor's `Gyaml` is swapped.
- **Gold Skulltulas**: the enemy's `Dynamic.Drop__DropActor`.
- **Event rewards**: the item string parameter of each "give item" node is re-pointed to a new string
  appended to the event flow.
- **Shop shelves**: the placement's `Gyaml`, see Items Shuffled Per Shop above.

Every changed file's entry in the resource size table is grown by the amount the file grew.

### Logic

The logic is **conservative**:
- Every location in a dungeon requires everything needed to finish that dungeon.
- Overworld grottos and hidden spots assume explosives, plus a scale or Hookshot where relevant.
- The higher tier of a two-tier item (Longshot, Golden Gauntlets, Golden Scale) is only placed where the
  logic already requires the lower tier, so it can't be picked up first.

Seeds are therefore beatable even where the remake's exact room layouts aren't modelled. The cost is that some
items always show up later than they strictly need to.

## Status / caveats

- **Testing in-game has started.** The first report found the bomb issue, which is fixed above. Everything
  else is verified offline only: every patched field reads back as the item in the spoiler, and every modified
  file parses again.
- Settings marked *experimental* (Shuffle Ocarinas, Skip Story Scenes, own-dungeon keys) are the least
  certain.
- Chest "get" cutscene events are kept, because they carry story flags. The exception is the Kokiri Sword chest's `Get_StoneOfForest_GetSword`: its Dm_Kokiri_0063 scene hands Link an unsaved sword (gone after reloading), so a randomized sword chest opens like a normal chest. A chest that used to hold, say, the Bow
  may still play the Bow's follow-up dialogue.
- If something breaks, the spoiler tells you which location holds which item.

## Tests

```
python tests/vanilla_test.py "D:/path/to/romfs"   # informational: shows which regions the logic reaches with vanilla items
```
