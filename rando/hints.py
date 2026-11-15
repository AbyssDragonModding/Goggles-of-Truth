"""Gossip Stone hints.

The hint kinds, their weights, the always/sometimes lists and the wording are Clawshot's
(https://github.com/hiKareeem/Clawshot, src/clawshot/data/hints.toml and generate/hints.py, MIT License,
Copyright (c) 2026 Kareem Albaba and the Clawshot contributors), which follow OoT Randomizer's Hints.py
(MIT, commit 526b4c8d). The method is re-done on this randomizer's logic (rando/logic.py):

- Stones. Every talking stone is an Obj_GossipStone_A_01 placement whose Name (GOSSIP_<AREA>_<NN>) is also the label
  of its line in EventFlowMsg/GossipStone.msbt (one per language archive, Mals/*.sarc.zs). Changing a stone's hint is
  changing that one message.
- Readable. A stone is read when its area is reachable (rando/logic.py REGIONS; a stone placed in a grotto also needs
  the area's grotto requirement). With "Mask of Truth required", only as child holding the Mask of Truth, and then no
  hint names something needed to get the mask.
- Where it matters. A hint naming a location goes only on a stone readable with that location's item withheld, so a
  stone never needs the item it points at. Junk lines take the unreadable stones first.
- Way of the Hero ("woth"): a shuffled location whose item the seed can't be finished without.
- Barren ("foolish"): an area none of whose shuffled locations holds a required or major item.
- Item / always / sometimes / random: a location (or area) and its item. Own-dungeon keys, maps and compasses are
  never named.

Only shuffled locations are hinted. The choices use their own random generator seeded from the seed, so placements
are never changed.
"""
import random
import struct

from . import evfl
from . import formats as F
from . import logic as L

STONE_ACTOR = "Obj_GossipStone_A_01"
GOSSIP_FLOW = "Event/EventFlow/GossipStone.bfevfl.zs"
GOSSIP_MESSAGES = "EventFlowMsg/GossipStone.msbt"
MASK_OF_TRUTH = "Armor_Child_Mask_Truth"
HINT_WIDTH, HINT_ROWS = 60, 2       # characters a row and rows a page; the game's own stone lines fit these

KINDS = ("always", "woth", "barren", "item", "sometimes", "random", "junk")
DISTRIBUTIONS = {
    # OoT Randomizer data/Hints/balanced.json (entrance hints left out), via Clawshot
    "balanced": dict(weights=dict(woth=3.5, barren=2.0, item=5.0, sometimes=4.5, random=6.0, junk=3.0),
                     dungeon_woth_limit=2, dungeon_barren_limit=1, always=True),
    # OoT Randomizer data/Hints/strong.json, via Clawshot
    "strong": dict(weights=dict(woth=3.0, barren=3.0, item=1.0, sometimes=1.65, random=2.0),
                   dungeon_woth_limit=2, dungeon_barren_limit=1, always=True),
    # every stone a joke
    "useless": dict(weights=dict(junk=1.0), dungeon_woth_limit=0, dungeon_barren_limit=0, always=False),
}

# OoT Randomizer's always / sometimes hint locations (HintList.py at 526b4c8d, via Clawshot), by this randomizer's
# location names. Names this randomizer doesn't have are skipped.
ALWAYS = ["Song from Ocarina of Time", "HF Ocarina of Time", "DMT Biggoron", "Kak 30 Gold Skulltula Reward",
          "Kak 40 Gold Skulltula Reward", "Kak 50 Gold Skulltula Reward", "ZR Frogs Song Game"]
SOMETIMES = ["Song from Royal Familys Tomb", "Sheik in Forest", "Sheik at Temple", "Sheik in Crater",
             "Sheik in Ice Cavern", "Sheik in Kakariko", "Sheik at Colossus", "Market Big Poe Bottle",
             "Kak 20 Gold Skulltula Reward", "Kak Anju as Child", "GC Darunias Joy", "LW Skull Kid",
             "LW Target in Woods", "LH Lab Dive", "HC Great Fairy Reward", "OGC Great Fairy Reward",
             "ZR Frogs Bug Game", "GF Horseback Archery", "Graveyard Dampe Race Reward"]

WORDING = {
    "woth": "They say {area} holds something the hero cannot do without.",
    "barren": "They say searching {area} would only waste the hero's time.",
    "item": "They say {area} hides the {item}.",
    "location": "They say {location} holds the {item}.",
}
JUNK_LINES = [
    "They say this stone has nothing to tell you today.",
    "They say a stone never forgets, but it rarely remembers anything useful.",
    "They say the owl knows every road, if only he would stop talking about them.",
    "They say the Kokiri never grow up, but their pranks keep getting bigger.",
    "They say the cuccos remember every hero who ever struck one.",
    "They say Song of Time blocks are patient. Very, very patient.",
    "They say a hero who reads every stone has read too many stones.",
    "They say the Gold Skulltulas count every token you take.",
]

# Hint areas: a location's dungeon, else its region (stage folder), else by its name. The remake keeps Lake Hylia
# in the Hyrule Field stages, so its stage spots are hinted as Hyrule Field.
AREA_NAMES = {
    "KokiriForest": "Kokiri Forest", "LostWood": "the Lost Woods", "SacredForestMeadow": "the Sacred Forest Meadow",
    "HyruleField": "Hyrule Field", "LonLonRanch": "Lon Lon Ranch", "Market": "the Market",
    "TimeTemple": "the Temple of Time", "HyruleCastle": "Hyrule Castle", "OutsideGanonCastle": "outside Ganon's Castle",
    "KakarikoVillage": "Kakariko Village", "Graveyard": "the Graveyard", "DeathMountainTrail": "Death Mountain Trail",
    "GoronCity": "Goron City", "DeathMountainCrater": "Death Mountain Crater", "ZoraRiver": "Zora's River",
    "ZoraDomain": "Zora's Domain", "ZoraFountain": "Zora's Fountain", "LakeHylia": "Lake Hylia",
    "GerudoValley": "Gerudo Valley", "GerudoFortress": "Gerudo's Fortress", "HountedWasteland": "the Haunted Wasteland",
    "DesertColossus": "the Desert Colossus",
    "InsideTheDekuTree": "the Deku Tree", "DodongoCavern": "Dodongo's Cavern",
    "InsideJabuJabuBelly": "Jabu-Jabu's Belly", "ForestTemple": "the Forest Temple", "FireTemple": "the Fire Temple",
    "WaterTemple": "the Water Temple", "ShadowTemple": "the Shadow Temple", "SpiritTemple": "the Spirit Temple",
    "BottomOfTheWell": "the Bottom of the Well", "IceCavern": "the Ice Cavern",
    "GerudoTrainingGround": "the Gerudo Training Ground", "InsideGanonCastle": "Ganon's Castle",
    "GanonCastle": "Ganon's Castle",
}
DUNGEON_AREAS = {"InsideTheDekuTree", "DodongoCavern", "InsideJabuJabuBelly", "ForestTemple", "FireTemple",
                 "WaterTemple", "ShadowTemple", "SpiritTemple", "BottomOfTheWell", "IceCavern",
                 "GerudoTrainingGround", "InsideGanonCastle", "GanonCastle"}
NAME_AREAS = {   # locations without a stage (events): exact names first, then name prefixes
    "Queen Gohma (Kokiri Emerald)": "InsideTheDekuTree", "King Dodongo (Goron Ruby)": "DodongoCavern",
    "Barinade (Zora Sapphire)": "InsideJabuJabuBelly", "Phantom Ganon (Forest Medallion)": "ForestTemple",
    "Volvagia (Fire Medallion)": "FireTemple", "Morpha (Water Medallion)": "WaterTemple",
    "Bongo Bongo (Shadow Medallion)": "ShadowTemple", "Twinrova (Spirit Medallion)": "SpiritTemple",
    "Rauru (Light Medallion)": "TimeTemple", "Song from Impa": "HyruleCastle", "Song from Malon": "LonLonRanch",
    "Song from Saria": "SacredForestMeadow", "Song from Royal Familys Tomb": "Graveyard",
    "Song from Windmill": "KakarikoVillage", "Song from Ocarina of Time": "HyruleField",
    "Sheik in Forest": "SacredForestMeadow", "Sheik in Crater": "DeathMountainCrater",
    "Sheik in Ice Cavern": "IceCavern", "Sheik in Kakariko": "KakarikoVillage", "Sheik at Colossus": "DesertColossus",
    "Sheik at Temple": "TimeTemple", "King Zora Thawed": "ZoraDomain",
}
PREFIX_AREAS = [("Kak ", "KakarikoVillage"), ("DMT ", "DeathMountainTrail"), ("DMC ", "DeathMountainCrater"),
                ("GC ", "GoronCity"), ("GF ", "GerudoFortress"), ("Hideout ", "GerudoFortress"),
                ("HC ", "HyruleCastle"), ("OGC ", "OutsideGanonCastle"), ("HF ", "HyruleField"),
                ("LH ", "LakeHylia"), ("LLR ", "LonLonRanch"), ("LW ", "LostWood"), ("Market ", "Market"),
                ("ToT ", "TimeTemple"), ("ZD ", "ZoraDomain"), ("ZF ", "ZoraFountain"), ("ZR ", "ZoraRiver"),
                ("Graveyard ", "Graveyard"), ("Colossus ", "DesertColossus"), ("KF ", "KokiriForest"),
                ("SFM ", "SacredForestMeadow"), ("GV ", "GerudoValley")]
DUNGEON_NAME_PREFIXES = [("Dodongo Cavern ", "DodongoCavern"), ("Fire Temple ", "FireTemple"),
                         ("Forest Temple ", "ForestTemple"), ("Lord Jabu-Jabu's Belly ", "InsideJabuJabuBelly"),
                         ("Great Deku Tree ", "InsideTheDekuTree"), ("Shadow Temple ", "ShadowTemple"),
                         ("Spirit Temple ", "SpiritTemple"), ("Water Temple ", "WaterTemple")]

# Stones whose stage folder is not their area's: a grotto under that area (its grotto requirement applies), except
# these, which stand in the open (Lake Hylia is part of the Hyrule Field stages; the Lost Woods bridge stone is also
# placed in the Kokiri Forest files).
OPEN_AIR_ELSEWHERE = {("HyruleField", "LAKE_HYLIA"), ("KokiriForest", "LOST_WOOD")}
# Stage folder -> area the label's middle part names
LABEL_AREAS = {"DEATH_MOUNTAIN_CRATER": "DeathMountainCrater", "DEATH_MOUNTAIN_TRAIL": "DeathMountainTrail",
               "DESERT_COLOSSUS": "DesertColossus", "DODONGO_CAVERN": "DodongoCavern",
               "GERUDO_VALLEY": "GerudoValley", "GORON_CITY": "GoronCity", "GRAVEYARD": "Graveyard",
               "HYRULE_CASTLE": "HyruleCastle", "HYRULE_FIELD": "HyruleField", "HYRULE_MARKET": "Market",
               "KAKARIKO_VILLAGE": "KakarikoVillage", "KOKIRI_FOREST": "KokiriForest", "LAKE_HYLIA": "HyruleField",
               "LOST_WOOD": "LostWood", "SACRED_FOREST_MEADOW": "SacredForestMeadow", "ZORA_DOMAIN": "ZoraDomain",
               "ZORA_FOUNTAIN": "ZoraFountain", "ZORA_RIVER": "ZoraRiver"}


def _mask_of_truth(s):
    """Child Link can get the Mask of Truth: the Happy Mask Shop (Zelda's Letter shown at the Kakariko gate), the
    Skull Kid in the Lost Woods (Saria's Song) and the Graveyard. An approximation: the logic doesn't model the
    mask quest itself."""
    return s.hf_child and s.has("ZeldaLetter") and L.song(s, "SariaSong")


def area_of(loc):
    if loc.dungeon:
        return loc.dungeon
    if loc.region:
        return loc.region
    if loc.name in NAME_AREAS:
        return NAME_AREAS[loc.name]
    for prefix, area in DUNGEON_NAME_PREFIXES + PREFIX_AREAS:
        if loc.name.startswith(prefix):
            return area
    return None


def area_name(area):
    return AREA_NAMES.get(area, area or "somewhere")


# --------------------------------------------------------------------------- stones
def scan_stones(world, read):
    """{label: {"folders": {folder: ages}}} for every talking stone. ages: set of "child"/"adult"."""
    stones = {}
    for folder in sorted(world.files.listdir("Banc")):
        if not world.files.isdir("Banc/" + folder):
            continue
        for fn in sorted(world.files.listdir("Banc/" + folder)):
            if not fn.endswith(".bcett.byml.zs"):
                continue
            rel = "Banc/%s/%s" % (folder, fn)
            raw = read(rel)[0]
            if STONE_ACTOR.encode() not in raw:
                continue
            ages = {"child"} if "_Child_" in fn else {"adult"} if "_Adult_" in fn else {"child", "adult"}
            for a in F.byml_load(raw).get("Actors", []):
                if a.get("Gyaml") == STONE_ACTOR and a.get("Name"):
                    stones.setdefault(a["Name"], {}).setdefault(folder, set()).update(ages)
    return stones


def _stone_rule(label, folders):
    """State -> readable, for a stone placed in `folders` ({folder: ages})."""
    middle = label[len("GOSSIP_"):].rsplit("_", 1)[0]
    rules = []
    for folder, ages in folders.items():
        if folder == "DodongoCavern":
            rules.append(lambda s: (s.dmt_child or s.adult) and (L.bombs(s) or s.has("Hammer")))
            continue
        region = L.REGIONS.get(folder)
        if region is None:
            continue
        child_ok, adult_ok, extra = region
        grotto = LABEL_AREAS.get(middle) != folder and (folder, middle) not in OPEN_AIR_ELSEWHERE
        for age in ages:
            access = child_ok if age == "child" else adult_ok
            if grotto:
                rules.append(lambda s, a=access, e=extra, g=age: a(s) and e(s, g))
            else:
                rules.append(access)
    return lambda s: any(r(s) for r in rules)


# --------------------------------------------------------------------------- choosing
class _Searches:
    """Sweeps of the seed's placements, each with at most one location's item withheld (cached)."""

    def __init__(self, filler):
        self.filler = filler
        self.contents = filler.contents()
        self._done = {}

    def __call__(self, without=None):
        if without is not None and self.contents.get(without) not in L.PROGRESSION:
            without = None
        if without not in self._done:
            contents = {k: v for k, v in self.contents.items() if k != without}
            self._done[without] = self.filler.sweep([], contents)[0]
        return self._done[without]

    def won(self, without=None):
        return bool(self(without).win)


def _major(item):
    return item in L.PROGRESSION and "@" not in item and item != "Token_Gold"


def _worth_naming(item):
    return "@" not in item and item != "Token_Gold" and (item in L.PROGRESSION or item.startswith("Heart_"))


class Hint:
    def __init__(self, label, kind, area=None, location=None, item=None, line=None):
        self.label, self.kind, self.area, self.location, self.item, self.line = label, kind, area, location, item, line


def choose(world, plan, filler, seed, read, distribution="balanced", mask=False):
    """One Hint per stone, in label order."""
    dist = DISTRIBUTIONS[distribution]
    stones = scan_stones(world, read)
    if not stones:
        return []
    rules = {label: _stone_rule(label, folders) for label, folders in sorted(stones.items())}
    if mask:
        rules = {label: (lambda s, r=r: s.hf_child and _mask_of_truth(s) and r(s)) for label, r in rules.items()}
    rng = random.Random("ootr-remake hints %s" % seed)
    searches = _Searches(filler)
    full = searches()
    contents = searches.contents
    locs = {l.id: l for l in world.locations}
    shuffled = [l.id for l in plan.shuffled if l.id in filler.placed]
    free = sorted(rules)
    rng.shuffle(free)
    hints = {}

    def place(kind, location=None, **fields):
        state = searches(location) if location is not None else full
        for stone in free:
            if rules[stone](state):
                free.remove(stone)
                item = contents[location] if location is not None else None
                hints[stone] = Hint(stone, kind, location=location, item=item, **fields)
                return True
        return False

    area = {lid: area_of(locs[lid]) for lid in shuffled}
    hinted_locations, hinted_areas, hinted_items = set(), set(), set()
    dungeons = {"woth": 0, "barren": 0}
    limits = {"woth": dist["dungeon_woth_limit"], "barren": dist["dungeon_barren_limit"]}

    required = [lid for lid in shuffled if contents[lid] in L.PROGRESSION and "@" not in contents[lid]
                and not searches.won(lid)] if searches.won() else []
    before_mask = set()
    if mask and _mask_of_truth(full):
        before_mask = {lid for lid in shuffled if contents[lid] in L.PROGRESSION
                       and not _mask_of_truth(searches(lid))}
        required = [lid for lid in required if lid not in before_mask]
    by_area = {}
    for lid in shuffled:
        if area[lid]:
            by_area.setdefault(area[lid], []).append(lid)

    def location_hint(kind, candidates):
        candidates = [lid for lid in candidates if lid not in hinted_locations]
        if kind == "item":
            candidates = [lid for lid in candidates if contents[lid] not in hinted_items]
        while candidates:
            lid = candidates.pop(rng.randrange(len(candidates)))
            hinted_locations.add(lid)
            if place(kind, lid, area=area[lid]):
                if kind == "item":
                    hinted_items.add(contents[lid])
                return True
        return False

    def woth():
        candidates = [lid for lid in required if area[lid] and area[lid] not in hinted_areas
                      and not (area[lid] in DUNGEON_AREAS and dungeons["woth"] >= limits["woth"])]
        while candidates:
            lid = candidates.pop(rng.randrange(len(candidates)))
            if place("woth", lid, area=area[lid]):
                hinted_locations.add(lid)
                hinted_areas.add(area[lid])
                dungeons["woth"] += area[lid] in DUNGEON_AREAS
                return True
        return False

    def barren():
        areas = [a for a, lids in sorted(by_area.items()) if a not in hinted_areas
                 and not (a in DUNGEON_AREAS and dungeons["barren"] >= limits["barren"])
                 and not any(lid in required or _major(contents[lid]) for lid in lids)]
        if not areas:
            return False
        a = rng.choices(areas, weights=[len(by_area[x]) for x in areas])[0]
        if not place("barren", area=a):
            return False
        hinted_areas.add(a)
        dungeons["barren"] += a in DUNGEON_AREAS
        return True

    named = [lid for lid in shuffled if _worth_naming(contents[lid]) and lid not in before_mask]
    by_name = {locs[lid].name: lid for lid in named}
    always = [by_name[n] for n in ALWAYS if n in by_name]
    sometimes = [by_name[n] for n in SOMETIMES if n in by_name]
    majors = [lid for lid in named if _major(contents[lid])]
    junk_order = list(range(len(JUNK_LINES)))
    rng.shuffle(junk_order)

    def junk():
        unreadable = [stone for stone in free if not rules[stone](full)]
        stone = (unreadable or free)[0]
        free.remove(stone)
        n = sum(1 for h in hints.values() if h.kind == "junk")
        hints[stone] = Hint(stone, "junk", line=junk_order[n % len(junk_order)])
        return True

    makers = {"woth": woth, "barren": barren, "item": lambda: location_hint("item", majors),
              "sometimes": lambda: location_hint("sometimes", sometimes),
              "random": lambda: location_hint("random", named), "junk": junk}
    if dist["always"]:
        for lid in always:
            if free and lid not in hinted_locations:
                hinted_locations.add(lid)
                place("always", lid, area=area[lid])
    weights = {k: w for k, w in dist["weights"].items() if w > 0}
    while free and weights:
        kinds = sorted(weights)
        kind = rng.choices(kinds, weights=[weights[k] for k in kinds])[0]
        if not makers[kind]():
            del weights[kind]
    while free:
        junk()
    return [hints[label] for label in sorted(hints)]


def text(world, hint, marked=False):
    """The hint's sentence. marked: names between \\x01 and \\x02 (shown in the highlight colour)."""
    if hint.kind == "junk":
        return JUNK_LINES[hint.line or 0]
    locs = {l.id: l for l in world.locations}
    fields = {"area": area_name(hint.area), "item": world.item_name(hint.item) if hint.item else "",
              "location": locs[hint.location].name if hint.location else ""}
    if marked:
        fields = {k: "\x01%s\x02" % v for k, v in fields.items()}
    template = WORDING["location"] if hint.kind in ("always", "sometimes", "random") else WORDING[hint.kind]
    return template.format(**fields)


# --------------------------------------------------------------------------- writing
def _tag(group, typ, params=b""):
    return b"\x0e" + struct.pack("<HHH", group, typ, len(params)) + params


PAGE_BREAK = _tag(0, 4)
HIGHLIGHT = _tag(0, 3, b"\x00\x00")
RESET = _tag(0, 3, b"\xff\xff")


def _lead_tags(raw):
    """The tags a UTF-8 message opens with (its colour, size and voice), and the group-0 ones among them."""
    j, lead, style = 0, b"", b""
    while j < len(raw) and raw[j] == 0x0E:
        group, _typ, plen = struct.unpack_from("<HHH", raw, j + 1)
        tag = raw[j:j + 7 + plen]
        lead += tag
        if group == 0:
            style += tag
        j += 7 + plen
    return lead, style


def _rows(sentence, width):
    rows, row = [], ""
    for word in sentence.split():
        candidate = "%s %s" % (row, word) if row else word
        if row and len(candidate.replace("\x01", "").replace("\x02", "")) > width:
            rows.append(row)
            candidate = word
        row = candidate
    return rows + [row] if row else rows


def stone_line(original_raw, sentence):
    """A UTF-8 stone message saying `sentence` in the look of the stone's original line."""
    lead, style = _lead_tags(original_raw)
    lines = _rows(sentence, HINT_WIDTH)
    pages = ["\n".join(lines[i:i + HINT_ROWS]) for i in range(0, len(lines), HINT_ROWS)]
    out = bytearray(lead)
    for i, page in enumerate(pages):
        if i:
            out += PAGE_BREAK + style
        for ch in page:
            if ch == "\x01":
                out += HIGHLIGHT
            elif ch == "\x02":
                out += RESET
            else:
                out += ch.encode("utf-8")
    return bytes(out) + b"\x00"


def write_text(world, hints_list, read, emit, progress):
    """Every language archive's stone lines (English sentences, like the item names the spoiler uses)."""
    lines = {h.label: text(world, h, marked=True) for h in hints_list}
    done = 0
    for fn in sorted(world.files.listdir("Mals")):
        if not fn.endswith(".sarc.zs"):
            continue
        rel = "Mals/" + fn
        orig, dname = read(rel)
        files = F.sarc_files(orig)
        msbt = files.get(GOSSIP_MESSAGES)
        if msbt is None:
            continue
        if msbt[0xC] != 0:
            progress("warning: %s stone text is not UTF-8; hints skipped for it" % fn)
            continue
        labels, texts = F.msbt_raw(msbt)
        new = {label: stone_line(texts[labels[label]], line) for label, line in lines.items() if label in labels}
        if new:
            emit(rel, orig, F.sarc_rebuild(orig, replace={GOSSIP_MESSAGES: F.msbt_set_raw(msbt, new)}), dname)
            done += 1
    progress("Hints: %d stones written in %d languages" % (len(lines), done))


def stones_without_mask(data):
    """GossipStone flow (decompressed) where every Mask of Truth question on the way to the stone's line sends each
    answer where the needed one went (has it, wears it), so stones speak without the mask."""
    doc = evfl.read(data)
    fc = doc.flowchart
    gates = [e for e in fc.events if isinstance(e, evfl.SwitchEvent)
             and MASK_OF_TRUTH in (e.params or {}).values()]
    queries = sorted(fc.actors[e.actor].queries[e.query] for e in gates)
    if queries != ["EventQueryIsExistInPouch", "EventQueryPlayerIsEquipArmor"]:
        raise ValueError("GossipStone: Mask of Truth questions not as expected (%s)" % queries)
    for e in gates:
        target = dict(e.cases).get(0)
        if target is None:
            raise ValueError("GossipStone: %s has no 'yes' case" % e.name)
        e.cases = [(v, target) for v, _ in e.cases]
    out = evfl.write(doc)
    if evfl.read(out) != doc:
        raise ValueError("GossipStone: the written flow does not read back")
    return out
