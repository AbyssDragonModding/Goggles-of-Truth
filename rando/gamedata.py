"""Edits to the default save data (GameData/GameDataList), applied when a new file is started.

GameData entries are keyed by MurmurHash3 (seed 0) of the flag name, e.g.
"KokiriForest_Npc_Kokiri_007_Child_Blocker_00". Plain Bool/Int defaults are changed directly;
computed BoolExp flags are formulas over other flags ([opcode, hash] lists, opcode 0 = read a Bool).
"""
import copy

from . import formats as F


def mm3(name, seed=0):
    key = name.encode()
    h, c1, c2, n = seed, 0xCC9E2D51, 0x1B873593, len(key)
    for i in range(0, n // 4 * 4, 4):
        k = int.from_bytes(key[i:i + 4], "little")
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
    tail, k = key[n // 4 * 4:], 0
    for i, b in enumerate(tail):
        k |= b << (8 * i)
    if tail:
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= n
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


# Opening flags
FOREST_EXIT = "KokiriForest_Npc_Kokiri_007_Child_Blocker_00"      # Kokiri boy at the forest exit
FOREST_MIDO = "KokiriForest_Npc_Kokiri_Mido_Child_Blocker"         # Mido in front of the Deku Tree
ZORA_OPEN = ["HavePlayedEvent.Dm_Zora_0010",                       # King Zora reads Ruto's letter and moves
             "Get_StoneOfWater_ReadRutoLetter", "Get_StoneOfWater_TalkedZoraAboutRutoLetter"]
# King Zora's position and talk follow the Zora quest, not those flags: his pack reads
# Get_StoneOfWater_IsAfter_Step06_Exp, and showing him the letter (Get_StoneOfWater:StoneOfWater_ShowLetter)
# moves the quest to Step07 before Dm_Zora_0010 plays.
ZORA_OPEN_QUEST = ("Get_StoneOfWater_IsAfter_Step06_Exp", "Step07")
DOOR_OPEN = "Market_Child_TimeTempleDoor_Opened"   # not set: the door follows its quest (rando/door.py)
# Door of Time: Open (rando/door.py) opens the door from quest step Ready on. A new save starts the quest at NotReady
# (it moves on later in the story), so the door stayed shut for a player who went straight to the Temple of Time
# (0.5.0 test seed 5). The quest starts at Ready instead; Skip Child Zelda starts it further on (Step02).
DOOR_QUEST = ("Step_DoorOfTime", "Ready")
# The Kakariko gate soldier sets this when shown Zelda's Letter (Npc_Hylia_Soldier_003 flow); the gate shutter
# (Obj_Kakariko_SwitchShutter_A_01) is grouped with it in KakarikoVillage_Child_Static's PlgGdTable.
DMT_GATE_OPEN = "Npc_Hylia_Soldier_003_GateOpen"
# Skip Epona Race used to rewrite Get_Epona_IsCompleted_Exp to "owns Epona's Song". That flag is also the ranch
# Epona's presence condition (gone once it's true), and owning a horse is engine state, not a flag; so the song
# found Epona nowhere (0.5.0 test seed 10). It's now a flow edit (faststart.epona_without_race).

# Skip Child Zelda: quest progress is an Enum per challenge (found through a computed flag that reads it).
# Goto_HyruleCastle Complete = Zelda met (the courtyard flow sets it, then DoorOfTime Step01); Impa's send-off
# (DoorOfTime:DoorOfTime_SendOff, after her song) sets DoorOfTime Step02 and Get_StoneOfFire KakarikoVillageNpc.
# Malon's and Talon's ranch schedules read Goto_HyruleCastle_IsAfter_Step03_02_Exp / later steps.
SKIP_ZELDA_QUESTS = [("Goto_HyruleCastle_IsCompleted_Exp", "Complete"),
                     ("DoorOfTime_IsAfter_Step02_Exp", "Step02"),
                     ("Get_StoneOfFire_IsCompleted_Exp", "KakarikoVillageNpc")]
# ...and the quest's scenes count as already seen, so none of them (or the step it would set) plays later:
# Kaepora's Hyrule Field intro (Dm_HrlField_0000/0005/0010), the Market intro (Dm_HrlCastle_0005, its arrival runs
# Goto_HyruleCastle_EntryMarket), Talon waking up (_0020), the courtyard (_0030.._0060), Impa's song and send-off.
SKIP_ZELDA_PLAYED = ["Goto_HyruleCastle_EntryMarket", "HyruleCastle_Goto_HyruleCastle_MeetZelda",
                     "Dm_HrlField_0000", "Dm_HrlField_0005", "Dm_HrlField_0010", "Dm_HrlCastle_0005",
                     "Dm_HrlCastle_0020", "Dm_HrlCastle_0030", "Dm_HrlCastle_0035", "Dm_HrlCastle_0045",
                     "Dm_HrlCastle_0050", "Dm_HrlCastle_0060", "Dm_MelodyGet_Zelda", "Dm_HrlField_0020"]
# What Kaepora's flow sets on the way: the quest menu opens, the field entrance counts as reached, and the
# amiibo pouch entry is handed out (PouchSystemActor Pouch_Amiibo)
SKIP_ZELDA_FLAGS = ["UI_IsFinishChallengeMenuOpenEvent", "HyruleField_ArriveEntrance"]
SKIP_ZELDA_ITEMS = ["Pouch_Amiibo"]
# Skip Kaepora Gaebora: his forced first talks. Each is started by stage logic (HoldGameDataHavePlayedEvent) or
# Dm_SY_BancChangeArrive only while HavePlayedEvent.<scene> is False. Dm_HrlField_0010 is the first Hyrule Field
# talk (Goto_HyruleCastle_Kaepora_00), which also opens the quest menu and gives the amiibo item (SKIP_ZELDA_FLAGS /
# _ITEMS); its quest step (Goto_HyruleCastle Step02) is only read by two NPCs' dialogue, and entering the Market moves
# the quest on to Step02_01 anyway. Left alone: Dm_HrlCastle_0000 (an entrance InitEvent, the same mechanism as the
# area intros, which didn't skip in testing), Dm_HrlField_0080 (sets DreamWorld_Open), and the optional Lake Hylia
# and Death Mountain rides (talk only).
# Dm_LostWood_0010 is his Lost Woods talk after Saria's Song (Dm_SY_BancChangeArrive plays it once
# HavePlayedEvent.SacredForestMeadow_Field_MelodyGet_Saria is set; talk only), missed until seed 3LETP69LQZ. Its
# Goron City variant (Dm_LostWood_0000:EnterFromGoronCity) only plays while Dm_LostWood_0000 is unseen, so it's
# covered by Dm_LostWood_0000.
# 0.5.1 (checked against the ootdump decompile and Clawshot's data/fast_start.toml "kaepora"):
# - Dm_HrlField_0000 and _0005 are the start of the same first Hyrule Field talk. Their own flag also matters:
#   HavePlayedEvent.Dm_HrlField_0000 ends the field's BGM-off stretch before the panorama (Bootup
#   BGMGeneralParam_Default SequenceRangeDisableBgm), so skipping only _0010 could leave Hyrule Field silent.
# - Dm_HrlField_0050 is his talk on the way to Lake Hylia (HyruleField_Child_Prefab_b9db: plays unless seen or
#   IsVisitLocation.LakeHylia), and Dm_HrlCastle_0000 his talk in front of Hyrule Castle (an entrance InitEvent
#   on HavePlayedEvent.Dm_HrlCastle_0000; talk only). Both were still playing.
# - His first talk also moves Goto_HyruleCastle to Step02, and the Market's entry event
#   (Market_Child_Prefab_c061: HoldChallengeCurrentStepCheckOrder IsEqual Step02) only fires at exactly that step;
#   it starts the chain that leads to Zelda's courtyard. So the skip now also sets Step02
#   (KAEPORA_QUEST; Skip Child Zelda sets the quest to Complete instead).
KAEPORA_SCENES = ["Dm_LostWood_0000",                      # outside Kokiri Forest (Lost Woods bridge)
                  "Dm_LostWood_0010",                      # Lost Woods, after Saria's Song
                  "Dm_HrlField_0000", "Dm_HrlField_0005", "Dm_HrlField_0010",   # first Hyrule Field talk
                  "Dm_HrlField_0030", "Dm_HrlField_0040",   # Hyrule Field (0040: near Gerudo Valley)
                  "Dm_HrlField_0050",                      # Hyrule Field, on the way to Lake Hylia
                  "Dm_HrlCastle_0000",                     # in front of Hyrule Castle
                  "Dm_ZoraRiver_0000", "Dm_ZoraRiver_0005"]
KAEPORA_QUEST = ("Goto_HyruleCastle_IsCompleted_Exp", "Step02")
# Owning an item: IsGet.<actor> plus, for pouch items, the count in PouchData.<actor> (a one-Int struct). Songs only
# have the IsGet flag.
# Skip Saria's Opening Scene (from Clawshot, data/fast_start.toml "saria"): Saria waking Link at his door and
# walking him out (Dm_Kokiri_0045, Dm_Kokiri_0050) and her greeting Navi (Dm_Kokiri_0060) count as seen; the door
# flag and her talk flag they set are on; the area banner's visit flag is on, so the pause map still works.
SARIA_INTRO = ["HavePlayedEvent.Dm_Kokiri_0045", "HavePlayedEvent.Dm_Kokiri_0050", "HavePlayedEvent.Dm_Kokiri_0060",
               "KokiriForest_LinkHouseDoor_Open", "HaveTalked.Npc_Kokiri_Saria_Child", "IsVisitLocation.KokiriForest"]
# Skip the Great Deku Tree's Talk (Clawshot "deku_tree"): the state its arrival talk (Dm_Kokiri_0070, _0075)
# leaves. Only as new-save values when Mido is already gone (Open Forest); with Mido kept, his clear sets it
# (faststart.complete_deku_meeting).
DEKU_TREE_TALK_FLAGS = ["HavePlayedEvent.Dm_Kokiri_0070", "KokiriForest_Meet_DekuTree_OpenDekuTreeMouth"]
DEKU_TREE_TALK_STEPS = [("Step_Meet_DekuTree", "Complete"), ("Step_Get_StoneOfForest", "GoInside")]

POUCH_STRUCT = "PouchData"

# Dungeon map / compass ownership: DungeonInfo.<dungeon>.IsGetMap / .IsGetCompass (plain Bools)
MAP_DUNGEONS = ["InsideTheDekuTree", "DodongoCavern", "InsideJabuJabuBelly", "ForestTemple", "FireTemple",
                "WaterTemple", "ShadowTemple", "SpiritTemple", "BottomOfTheWell", "IceCavern"]

# Saria's Song: the meadow trigger normally checks DoorOfTime_IsAfter_Step01_Exp (met Zelda).
# A new computed flag "owns an ocarina" replaces that check (see qol.patch_saria_song).
SARIA_GATE_OLD = "DoorOfTime_IsAfter_Step01_Exp"
SARIA_GATE_NEW = "Rando_HasOcarina_Exp"
OCARINA_FLAGS = ["IsGet.Item_Ocarina_Fairy", "IsGet.Item_Ocarina_Time"]

# First-arrival intro scenes that only move the camera/actors, and whose arrival entry (the
# entrance's InitEventName in the stage data, or the shared Dm_SY_BancChangeArrive entry) does
# nothing else: no quest step, flag or sub-flow. Their "played" flag only feeds the entrance check
# (directly, or through InitDemo_* computed flags).
# Left out on purpose because their arrival entry also advances a quest / sets flags (since 0.6.0 most of these
# are skipped inside their arrival flow instead: storyskip.AREA_SKIPS / AREA_STANDALONE):
#   Dm_Deku_0000 (Get_StoneOfForest MeetBoss), Dm_DeathMtTrail_0000 (Get_StoneOfFire DeathMtTrailNpc),
#   Dm_Zora_0000 (Get_StoneOfWater Step03), Dm_DesertColossus_0000 (SageOfSpirit Step04),
#   Dm_HrlCastle_0005 (Goto_HyruleCastle EntryMarket), Dm_DeathMtCrater_0000(+_FromTop) (SageOfFire),
#   Goto_IceCave (SageOfWater Step03), Goto_ShadowTemple (SageOfShadow MeetBoss),
#   Goto_GerudoTrainingGround (SubEvent_GetIceArrow), Goto_SacredForest (Moblin position flag),
#   Dm_Kokiri_0000 / Dm_Goron_0000 / Dm_LostWood_0000 / Dm_HrlField_0000 / Dm_ZoraRiver_0000 (story).
AREA_INTROS = ["Dm_LakeHrl_0000", "Dm_ZoraFountain_0000", "Dm_GanonCastle_0000", "Dm_LostWood_0010",
               "Dm_Kakariko_0000", "Dm_Graveyard_0000", "Dm_HrlCastle_0000", "Dm_Gerudo_0000",
               "Dm_GerudoValley_0000", "Goto_ZoraRiver", "Goto_KakarikoWells", "Goto_FireTemple",
               "Goto_SpritTemple"]
# The intros above are also where those areas are first "visited": each one opens its area's name banner
# (UISystemActor.EventTriggerOpenLocationUI), and these locations show their banner only in that scene
# (RSDB Location: IsShowLocationUIFirstTimeInDemo). Skipped, the visit flag the banner sets was never set, the
# way Saria's skipped scene left Kokiri Forest unvisited (Clawshot "saria": IsVisitLocation.KokiriForest so the
# pause map still works). So skipping them also marks their areas as visited.
AREA_INTRO_VISITS = ["LakeHylia", "ZoraFountain", "GanonCastle", "KakarikoVillage", "Graveyard", "HyruleCastle",
                     "GerudoFortress", "GerudoValley", "ZoraRiver", "BottomOfTheWell", "FireTemple", "SpiritTemple"]

# Rainbow Bridge Requirement (GameDataPatcher.rainbow_bridge)
BRIDGE_MEDALLIONS = ["IsGet.Item_Medal_" + m for m in ("Forest", "Fire", "Water", "Shadow", "Spirit", "Light")]
BRIDGE_STONES = ["IsGet.Item_Stone_" + m for m in ("Forest", "Fire", "Water")]
BRIDGE_BOW, BRIDGE_LIGHT_ARROWS = "IsGet.Weapon_Range_Bow", "IsGet.Item_Arrow_Light"
TOKEN_COUNT = "PouchData.Item_Token_Gold.StockNum"
BRIDGE_QUEST_EXP = "Defeat_Ganon_IsAfter_Step01_Exp"          # the castle quest's own "past Step01" check
BRIDGE_EXP = "Rando_Bridge_Exp"                                 # the requirement + Bow + Light Arrows
BRIDGE_MAX_ENTRIES = 26                                         # the longest computed flag in the game

# Skip Ganon's Trials. Each trial's barrier scene (Defeat_Ganon:InsideGanonCastle_Dungeon_BarrierRemove_<trial>,
# requested by an EventRequestActor in its sage room) sets InsideGanonCastle_Dungeon_BarrierRemove_<trial>, and the
# barrier is gone while that flag is set; the scene's played flag shows the sage's light in the middle room
# (EftLoc_InsideGanonCastle_SageRoom_*). Each one also counts InsideGanonCastle_Dungeon_Barrier_Count down from 6;
# at 0 BarrierRemove_All removes the tower barrier and sets InsideGanonCastle_IsAllBarrierClear, which the middle
# room's logic reads (InsideGanonCastle_Level_Room_01_Prefab). It then plays Dm_InsideGanonCastle_0090, whose played
# flag enables the tower's lift, and moves the Defeat_Ganon quest to Step04 (qol.patch_ganon_trials).
GANON_TRIALS = ["Forest", "Fire", "Water", "Shadow", "Spirit", "Light"]


class GameDataPatcher:
    def __init__(self, world, read, emit, progress=print):
        self.world, self.read, self.emit, self.progress = world, read, emit, progress
        self.rel = world._find("GameData", "GameDataList")
        self.orig, self.dname = read(self.rel)
        self.ver = F.BymlReader(self.orig).ver
        self.big = self.orig[:2] == b"BY"
        self.root = F.byml_load(self.orig)
        self.index = {}
        for typ, rows in self.root["Data"].items():
            for r in rows:
                if isinstance(r, dict) and "Hash" in r:
                    self.index[int(r["Hash"])] = (typ, r)
        self.changed = 0

    def _get(self, name, typ):
        hit = self.index.get(mm3(name))
        if hit is None or hit[0] != typ:
            self.progress("warning: save flag %s not found as %s; skipped" % (name, typ))
            return None
        return hit[1]

    def set_bool(self, name, value):
        row = self._get(name, "Bool")
        if row is not None and bool(row["DefaultValue"]) != value:
            row["DefaultValue"] = bool(value)
            self.changed += 1
        return row is not None

    def set_int(self, name, value):
        row = self._get(name, "Int")
        if row is not None and row["DefaultValue"] != value:
            row["DefaultValue"] = type(row["DefaultValue"])(value)
            self.changed += 1
        return row is not None

    def rainbow_bridge(self, mode, medallions=6, tokens=100):
        """Rainbow Bridge Requirement. Logic/GanonCastle_Level_Field_00_Prefab (its multi-input links decoded: entries
        of 8 bytes at the end of the input tables; node index -100-start, parameter index = count):
            areas Area_2dac / Area_99ec and the appear point exist while  Ready_Exp AND NOT Step01_Exp
            the bridge scene (GanonCastle_Adult_Field_Rainbow) starts when Link is in both areas (and in state 2)
            the bridge exists when that scene has played, or once it sets its EventBoolEX1
        "IsAfter_X" means past step X. Zelda's Light Arrows scene (AllSage) sets Step01, so Ready_Exp (past Ready)
        turns on; the bridge scene sets Step02, so Step01_Exp (past Step01) turns the areas off again.
        So the requirement is OR-ed into Ready_Exp only; Step01_Exp stays the quest's own (0.6.1's first version
        replaced it, which kept the areas off for good: no bridge in-game).

        Computed flags are reverse Polish over [opcode, value]: 0 reads a Bool, 10 reads another computed flag (all 356
        uses in the game do), 3 AND, 4 OR, 5 NOT, 18 reads an Int and compares it "less than" the next constant (16),
        so "at least N" is NOT(Int < N), as MiniGame_DampeRace_IsClearLeastOnce writes "at least once".
        The game's own computed flags are at most 26 entries long. 0.6.1's first "3 of 6 medallions" was one flag of 123
        entries and never came true in-game (debug test: 4 medallions, Bow and Light Arrows, no bridge). So every flag
        here stays short, and the count is a chain of small flags:
            Rando_Bridge_Medals_<k>_<i> = at least k of the first i medallions
                                       = <k of i-1> OR (<k-1 of i-1> AND medallion i)          (5 entries)
            Rando_Bridge_Exp            = requirement AND Bow AND Light Arrows
            Defeat_Ganon_IsAfter_Ready_Exp = its old value OR Rando_Bridge_Exp
        AllSage's guard (qol.bridge_quest_guard) reads Step01_Exp (BRIDGE_QUEST_EXP), the quest's own."""
        step01 = self._get("Defeat_Ganon_IsAfter_Step01_Exp", "BoolExp")
        ready = self._get("Defeat_Ganon_IsAfter_Ready_Exp", "BoolExp")
        if step01 is None or ready is None:
            return False
        if mode not in ("medallions", "stones", "tokens"):
            return True
        u = type(step01["Values"][0][0])
        need = [BRIDGE_BOW, BRIDGE_LIGHT_ARROWS] + (BRIDGE_MEDALLIONS if mode == "medallions" else
                                                     BRIDGE_STONES if mode == "stones" else [])
        missing = [f for f in need if self._get(f, "Bool") is None]
        if mode == "tokens" and self._get(TOKEN_COUNT, "Int") is None:
            missing.append(TOKEN_COUNT)
        if missing:
            self.progress("warning: Rainbow Bridge: save flags not found (%s); the bridge is left as it is"
                          % ", ".join(missing))
            return False

        def const(n):
            """Opcode 16's number is a plain signed Int in the game's own flags ([16, 1] in
            MiniGame_DampeRace_IsClearLeastOnce, [16, 100] in ..._Collect100Tokens), not the U64 of the other entries.
            0.6.1's token bridge wrote a U64 and the bridge was there with 0 tokens (the game read no number)."""
            return int(n)

        def flag(name):
            return [u(0), u(mm3(name))]

        def exp(name):
            return [u(10), u(mm3(name))]

        def put(name, values):
            """Add (or replace) computed flag `name`, shaped like the game's own."""
            h = mm3(name)
            hit = self.index.get(h)
            if hit is None:
                row = {"Hash": type(step01["Hash"])(h), "ResetTypeValue": step01["ResetTypeValue"],
                       "SaveFileIndex": step01["SaveFileIndex"], "Values": values}
                self.root["Data"]["BoolExp"].append(row)
                self.index[h] = ("BoolExp", row)
            else:
                hit[1]["Values"] = values
            assert len(values) <= BRIDGE_MAX_ENTRIES, (name, len(values))

        def have(name):
            """Owning item `IsGet.<item>`: its "got it" flag OR its pouch count above 0. Items given by a debug menu
            fill the pouch (PouchData.<item>.StockNum) without the flag, which is how the 0.6.1 stones and tokens tests
            missed the Light Arrows; the game's own "at least one" reads are `Int > 0` (opcode 19, as
            HaveDefeatedEnemy_* write it). One small computed flag per item, read with opcode 10."""
            item = name.split(".", 1)[1]
            count = "PouchData.%s.StockNum" % item
            if self._get(count, "Int") is None:
                return flag(name)
            helper = "Rando_Have_" + item
            put(helper, [flag(name), [u(19), u(mm3(count))], [u(16), const(0)], [u(4)]])
            return exp(helper)

        if mode == "medallions":
            n = max(1, min(6, int(medallions)))
            ref = {}                                  # (k, i) -> computed flag holding "k of the first i"
            for i in range(1, 7):
                m = have(BRIDGE_MEDALLIONS[i - 1])
                for k in range(1, min(i, n) + 1):
                    name = "Rando_Bridge_Medals_%d_%d" % (k, i)
                    if k == i:                        # all of the first i
                        values = ([ref[(k - 1, i - 1)], m, [u(3)]] if k > 1 else [m])
                    elif k == 1:                      # any of the first i
                        values = [ref[(1, i - 1)], m, [u(4)]]
                    else:
                        values = [ref[(k, i - 1)], ref[(k - 1, i - 1)], m, [u(3)], [u(4)]]
                    put(name, values)
                    ref[(k, i)] = exp(name)
            cond = [ref[(n, 6)]]
        elif mode == "stones":
            a, b, c = (have(x) for x in BRIDGE_STONES)
            cond = [a, b, [u(3)], c, [u(3)]]
        else:
            cond = [[u(18), u(mm3(TOKEN_COUNT))], [u(16), const(tokens)], [u(5)]]
        put(BRIDGE_EXP, cond + [have(BRIDGE_BOW), [u(3)], have(BRIDGE_LIGHT_ARROWS), [u(3)]])
        ready["Values"] = [list(v) for v in ready["Values"]] + [exp(BRIDGE_EXP), [u(4)]]
        self.changed += 1
        return True

    def set_bool_exp_to_flag(self, name, flag):
        """Make computed flag `name` equal to plain Bool `flag`."""
        row = self._get(name, "BoolExp")
        if row is None or self._get(flag, "Bool") is None:
            return False
        tmpl = row["Values"][0]
        op = type(tmpl[0])(0)
        h = type(tmpl[1])(mm3(flag))
        row["Values"] = [[op, h]]
        self.changed += 1
        return True

    def add_bool_exp_any(self, name, flags):
        """Add a new computed flag `name` = flag1 OR flag2 OR ... (plain Bools). BoolExps are not saved."""
        h = mm3(name)
        if h in self.index:
            return False
        if any(self._get(f, "Bool") is None for f in flags):
            return False
        tmpl = self.root["Data"]["BoolExp"][0]
        u64 = type(tmpl["Values"][0][0])
        values = [[u64(0), u64(mm3(flags[0]))]]
        for f in flags[1:]:
            values += [[u64(0), u64(mm3(f))], [u64(4)]]          # 0 = read Bool, 4 = OR
        row = {"Hash": type(tmpl["Hash"])(h), "ResetTypeValue": tmpl["ResetTypeValue"],
               "SaveFileIndex": tmpl["SaveFileIndex"], "Values": values}
        self.root["Data"]["BoolExp"].append(row)
        self.index[h] = ("BoolExp", row)
        self.changed += 1
        return True

    def set_quest_step(self, exp_name, step):
        """Start challenge (quest) at `step`; the Enum is the one computed flag `exp_name` reads."""
        exp = self._get(exp_name, "BoolExp")
        if exp is None:
            return False
        enum = self.index.get(int(exp["Values"][0][1]))
        if enum is None or enum[0] != "Enum" or step not in enum[1].get("RawValues", []):
            self.progress("warning: quest for %s not recognised; skipped" % exp_name)
            return False
        row = enum[1]
        value = type(row["DefaultValue"])(mm3(step))
        if row["DefaultValue"] != value:
            row["DefaultValue"] = value
            self.changed += 1
        return True

    def set_enum(self, name, value):
        """Start Enum `name` (a challenge's Step_<name>) at `value`."""
        row = self._get(name, "Enum")
        if row is None:
            return False
        if value not in row.get("RawValues", []):
            self.progress("warning: %s has no value %s; skipped" % (name, value))
            return False
        new = type(row["DefaultValue"])(mm3(value))
        if row["DefaultValue"] != new:
            row["DefaultValue"] = new
            self.changed += 1
        return True

    def pouch_count_row(self, actor):
        """The Int holding how many of `actor` the player has (PouchData.<actor>), or None."""
        hit = self.index.get(mm3(POUCH_STRUCT))
        if hit is None or hit[0] != "Struct":
            return None
        member = next((m for m in hit[1]["DefaultValue"] if int(m["Hash"]) == mm3(actor)), None)
        inner = self.index.get(int(member["Value"])) if member else None
        if inner is None or inner[0] != "Struct" or len(inner[1]["DefaultValue"]) != 1:
            return None
        count = self.index.get(int(inner[1]["DefaultValue"][0]["Value"]))
        return count[1] if count and count[0] == "Int" else None

    def grant_item(self, actor):
        """A new save already owns one `actor`: its IsGet flag, plus its pouch count for pouch items."""
        ok = self.set_bool("IsGet." + actor, True)
        row = self.pouch_count_row(actor)
        if row is not None and row["DefaultValue"] < 1:
            row["DefaultValue"] = type(row["DefaultValue"])(1)
            self.changed += 1
        return ok

    def finish(self):
        if self.changed:
            self.emit(self.rel, self.orig, F.byml_dump(self.root, version=self.ver, big_endian=self.big), self.dname)


def isget_exists(world, actor):
    """Does the save data have an IsGet.<actor> flag (set the first time the item is owned)?"""
    cache = world.__dict__.setdefault("_isget_exists", {})
    if actor not in cache:
        if "_gd_probe" not in world.__dict__:
            world._gd_probe = GameDataPatcher(world, world.zs.read, lambda *a, **k: None, lambda *a: None)
        cache[actor] = mm3("IsGet." + actor) in world._gd_probe.index
    return cache[actor]


def bool_exists(world, name):
    """Is `name` a plain Bool save flag?"""
    if "_gd_probe" not in world.__dict__:
        world._gd_probe = GameDataPatcher(world, world.zs.read, lambda *a, **k: None, lambda *a: None)
    hit = world._gd_probe.index.get(mm3(name))
    return hit is not None and hit[0] == "Bool"


def pouch_entry_exists(world, actor):
    """Can a new save own `actor` through its IsGet flag and a PouchData count (see GameDataPatcher.grant_item)?"""
    cache = world.__dict__.setdefault("_pouch_grantable", {})
    if actor not in cache:
        if "_gd_probe" not in world.__dict__:
            world._gd_probe = GameDataPatcher(world, world.zs.read, lambda *a, **k: None, lambda *a: None)
        gd = world._gd_probe
        cache[actor] = mm3("IsGet." + actor) in gd.index and gd.pouch_count_row(actor) is not None
    return cache[actor]


def planned_changes(st, ocarina_bridge_patched=True):
    """Save-data edits for these settings: [(kind, flag, value, setting key, what it does)].
    kind: "bool" (default value), "exp" (computed flag rewritten to read `value`), "new_exp" (added, OR of flags)."""
    out = []
    if st["open_forest"] in ("closed_deku", "open"):
        out.append(("bool", FOREST_EXIT, False, "open_forest", "Kokiri boy / invisible wall at the forest exit is gone"))
    if st["open_forest"] == "open":
        out.append(("bool", FOREST_MIDO, False, "open_forest", "Mido no longer blocks the path to the Deku Tree"))
    if st["open_zora"] == "open":
        for f in ZORA_OPEN:
            out.append(("bool", f, True, "open_zora", "King Zora has already read Ruto's letter and moved aside"))
        out.append(("quest", ZORA_OPEN_QUEST[0], ZORA_OPEN_QUEST[1], "open_zora",
                    "Zora quest starts at %s (letter shown, King Zora moved)" % ZORA_OPEN_QUEST[1]))
    if st["open_door"] == "open" and not st["skip_child_zelda"]:
        out.append(("enum", DOOR_QUEST[0], DOOR_QUEST[1], "open_door",
                    "Door of Time quest starts at %s, the step the open door follows" % DOOR_QUEST[1]))
    if st["open_dmt"]:
        out.append(("bool", DMT_GATE_OPEN, True, "open_dmt", "Kakariko's Death Mountain gate starts open"))
    if st["skip_area_intros"]:
        for ev in AREA_INTROS:
            out.append(("bool", "HavePlayedEvent." + ev, True, "skip_area_intros", "Intro %s counts as already seen" % ev))
        # the Lake Hylia intros (Dm_LakeHrl_0003 / _0005, skipped through InitDemo_LakeHylia) are what put
        # Kaepora on the lake for his optional ride
        out.append(("bool", "Npc_Kaepora_LakeHrl_Appeared_FromValley", True, "skip_area_intros",
                    "Kaepora waits at Lake Hylia (set by the skipped lake intro)"))
        for loc in AREA_INTRO_VISITS:
            out.append(("bool", "IsVisitLocation." + loc, True, "skip_area_intros",
                        "%s counts as visited (its banner showed only in the skipped intro)" % loc))
    if st["maps_compasses"] == "start_with":
        for d in MAP_DUNGEONS:
            for f in ("IsGetMap", "IsGetCompass"):
                out.append(("bool", "DungeonInfo.%s.%s" % (d, f), True, "maps_compasses",
                            "Start with the %s %s" % (d, f[5:].lower())))
    if st["shuffle_ocarinas"] and not ocarina_bridge_patched:
        # Fallback when the bridge trigger couldn't be patched (qol.patch_ocarina_bridge): mark Saria's goodbye
        # (Goto_HyruleCastle -> Dm_Kokiri_0150 + 0155, the Fairy Ocarina) as seen so the trigger never fires.
        # Side effect: Saria's forest schedule treats her as gone from the start, so the opening greeting
        # outside Link's house plays without her (0.2.1 report).
        for ev in ("Dm_Kokiri_0150", "Dm_Kokiri_0155"):
            out.append(("bool", "HavePlayedEvent." + ev, True, "shuffle_ocarinas",
                        "Saria's bridge goodbye (Fairy Ocarina gift) counts as already seen"))
    if st["skip_child_zelda"]:
        for exp, step in SKIP_ZELDA_QUESTS:
            out.append(("quest", exp, step, "skip_child_zelda",
                        "Quest read by %s starts at %s (Hyrule Castle as child already done)" % (exp, step)))
        for ev in SKIP_ZELDA_PLAYED:
            out.append(("bool", "HavePlayedEvent." + ev, True, "skip_child_zelda", "Scene %s counts as already seen" % ev))
        for f in SKIP_ZELDA_FLAGS:
            out.append(("bool", f, True, "skip_child_zelda", "Set by Kaepora's Hyrule Field scene"))
        for actor in SKIP_ZELDA_ITEMS:
            out.append(("item", actor, None, "skip_child_zelda", "Given in Kaepora's Hyrule Field scene"))
    if st.get("skip_kaepora"):
        for ev in KAEPORA_SCENES:
            out.append(("bool", "HavePlayedEvent." + ev, True, "skip_kaepora", "Kaepora's talk %s counts as already seen" % ev))
        for f in SKIP_ZELDA_FLAGS:
            out.append(("bool", f, True, "skip_kaepora", "Set by Kaepora's first Hyrule Field talk"))
        for actor in SKIP_ZELDA_ITEMS:
            out.append(("item", actor, None, "skip_kaepora", "Given in Kaepora's first Hyrule Field talk"))
        if not st["skip_child_zelda"]:
            out.append(("quest", KAEPORA_QUEST[0], KAEPORA_QUEST[1], "skip_kaepora",
                        "Goto_HyruleCastle starts at Step02, as Kaepora's first talk leaves it (the Market's entry "
                        "event needs it)"))
    if st["open_forest"] in ("closed_deku", "open") or st["shuffle_ocarinas"] or st["skip_child_zelda"]:
        # Hyrule Field uses a "first visit" light table (MainField_Bluesky_First: IsForceMainLight, the sun pinned
        # at one angle) until this flag is set, which vanilla does in Saria's bridge goodbye after the Deku Tree.
        # Leaving the forest early (or skipping that scene) kept the sun frozen; start with the normal day cycle.
        key = ("open_forest" if st["open_forest"] in ("closed_deku", "open") else
               "shuffle_ocarinas" if st["shuffle_ocarinas"] else "skip_child_zelda")
        out.append(("bool", "HyruleField_ChangeENV", True, key,
                    "Hyrule Field uses its normal day/night lighting instead of the fixed first-visit sun"))
    # every seed: a new game starts outside the shop (faststart.start_outside), Saria's wake-up already done
    for f in SARIA_INTRO + ["HavePlayedEvent.Dm_Kokiri_0030"]:
        out.append(("bool", f, True, "new_game", "New game starts outside: %s" % f))
    if st.get("skip_deku_talk") and st["open_forest"] == "open":
        for f in DEKU_TREE_TALK_FLAGS:
            out.append(("bool", f, True, "skip_deku_talk", "Great Deku Tree talk state: %s" % f))
        for name, value in DEKU_TREE_TALK_STEPS:
            out.append(("enum", name, value, "skip_deku_talk", "%s starts at %s" % (name, value)))
    if st.get("skip_ganon_trials"):
        for t in GANON_TRIALS:
            for f in ("InsideGanonCastle_Dungeon_BarrierRemove_" + t,
                      "HavePlayedEvent.InsideGanonCastle_Dungeon_BarrierRemove_" + t):
                out.append(("bool", f, True, "skip_ganon_trials", "Ganon's %s Trial counts as done: %s" % (t, f)))
        out.append(("int", "InsideGanonCastle_Dungeon_Barrier_Count", 0, "skip_ganon_trials",
                    "No trial barriers left"))
        out.append(("bool", "InsideGanonCastle_IsAllBarrierClear", True, "skip_ganon_trials",
                    "The tower barrier is gone"))
        # the barrier-dispel scene that follows the last trial: the tower's lift only works once it has played
        # (InsideGanonCastle_Level_Room_01_Prefab_e183, Obj_InsideGanonCastle_ElevatedFloor_A_01)
        out.append(("bool", "HavePlayedEvent.Dm_InsideGanonCastle_0090", True, "skip_ganon_trials",
                    "The tower's lift works"))
    if st["saria_song_ocarina"]:
        out.append(("new_exp", SARIA_GATE_NEW, OCARINA_FLAGS, "saria_song_ocarina",
                    "True when you own the Fairy Ocarina or Ocarina of Time (replaces the met-Zelda check)"))
    return out


def apply(world, st, read, emit, progress, ocarina_bridge_patched=True, start_items=()):
    """start_items: actors a new save already owns (Skip Child Zelda: Zelda's, Malon's and Impa's checks)."""
    gd = GameDataPatcher(world, read, emit, progress)
    ok = True
    for actor in start_items:
        if not gd.grant_item(actor):
            progress("warning: could not give %s at the start" % actor)
    for kind, flag, value, _, _ in planned_changes(st, ocarina_bridge_patched):
        if kind == "bool":
            gd.set_bool(flag, value)
        elif kind == "int":
            gd.set_int(flag, value)
        elif kind == "quest":
            gd.set_quest_step(flag, value)
        elif kind == "enum":
            gd.set_enum(flag, value)
        elif kind == "item":
            gd.grant_item(flag)
        elif kind == "exp":
            gd.set_bool_exp_to_flag(flag, value)
        elif kind == "new_exp":
            ok = gd.add_bool_exp_any(flag, value) or mm3(flag) in gd.index
    if st.get("rainbow_bridge", "vanilla") != "vanilla":
        if not gd.rainbow_bridge(st["rainbow_bridge"], st.get("bridge_medallions", 6), st.get("bridge_tokens", 100)):
            ok = False
    gd.finish()
    return ok
