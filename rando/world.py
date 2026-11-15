"""Scans the user's extracted romfs and builds the list of items and item locations.

Nothing here is bundled game data: actor names, IDs, positions and English text are all
read from the romfs the user points the program at.
"""
import math
import os
import re
from collections import defaultdict

from . import formats as F
from .gamefiles import open_game

DUNGEONS = {
    "InsideTheDekuTree": "child", "DodongoCavern": "child", "InsideJabuJabuBelly": "child",
    "BottomOfTheWell": "child", "ForestTemple": "adult", "FireTemple": "adult",
    "WaterTemple": "adult", "ShadowTemple": "adult", "SpiritTemple": "both",
    "IceCavern": "adult", "GerudoTrainingGround": "adult", "InsideGanonCastle": "adult",
    "GanonCastle": "adult",
}
SKIP_FOLDERS = {"BancBasedResource", "DreamWorld", "SageRoom"}

ITEM_PREFIXES = ("Item_", "Obj_", "TBox_", "Tbox_", "Weapon_", "Shop_", "Pouch_")
JUNK = {"Rupee_Green", "Rupee_Blue", "Rupee_Red", "Rupee_Purple", "Rupee_Gold", "Heart",
        "MagicJar_Small", "MagicJar_Large", "ArrowBundle_Small", "ArrowBundle_Medium",
        "ArrowBundle_Large", "DekuNutBundle", "DekuSeedBundle", "BombBundle_Small",
        "BombchuBundle_Small", "BombchuBundle_Medium", "BombchuBundle_Large",
        "DekuStickBundle_Small", "ScrubBusinessSeed", "Shield_Deku", "Shield_Hylian"}


def canon(actor):
    """'TBox_Rupee_Red' / 'Obj_Rupee_Red' -> 'Rupee_Red'; 'Item_Hookshot' -> 'Hookshot'."""
    for p in ITEM_PREFIXES:
        if actor.startswith(p):
            actor = actor[len(p):]
            break
    return {"GerudoValley_Heart_Piece": "Heart_Piece"}.get(actor, actor)


class Location:
    def __init__(self, **kw):
        self.id = kw["id"]                 # stable ID (survives regeneration)
        self.name = kw["name"]             # readable name for the spoiler log
        self.region = kw["region"]         # Banc folder name (logic region)
        self.dungeon = kw.get("dungeon")   # dungeon folder or None
        self.kind = kw["kind"]             # chest | freestanding | heart_container | gs | event
        self.category = kw.get("category", self.kind)  # song | reward | npc | fairy | house ...
        self.ages = kw["ages"]             # set of "child"/"adult"
        self.vanilla = kw["vanilla"]       # canonical item key (dungeon items get @Dungeon)
        self.vanilla_actor = kw["vanilla_actor"]
        self.stage_refs = kw.get("stage_refs", [])   # [(banc relpath, hash)]
        self.event_refs = kw.get("event_refs", [])   # [(evfl relpath, field offset)]
        self.presence = kw.get("presence", "")
        self.get_event = kw.get("get_event", "")
        self.conditional = kw.get("conditional", False)
        self.pos = kw.get("pos")
        self.room = kw.get("room")
        self.rule_key = kw.get("rule_key")   # explicit logic rule for events / specials
        self.upgrade_ok = kw.get("upgrade_ok", False)   # an upgrade-giving location that may still be shuffled
        self.price_refs = kw.get("price_refs", [])    # business scrubs: [(evfl relpath, Price field offset, price)]
        self.shop = kw.get("shop")                    # shop shelves: the shop's name

    def __repr__(self):
        return "<Location %s>" % self.name


# Curated reward events. Each entry patches every "give item" node in the flow whose item
# parameter equals `vanilla` (optionally filtered by the `via` sub-flow name).
EVENT_LOCATIONS = [
    # songs
    dict(name="Song from Impa", flow="Dm_MelodyGet_Zelda", vanilla="Item_Melody_ZeldaLullaby", category="song", rule="song_impa"),
    dict(name="Song from Malon", flow="Dm_MelodyGet_Epona", vanilla="Item_Melody_EponaSong", category="song", rule="song_malon"),
    dict(name="Song from Saria", flow="Dm_MelodyGet_Saria", vanilla="Item_Melody_SariaSong", category="song", rule="song_saria"),
    dict(name="Song from Royal Familys Tomb", flow="Dm_MelodyGet_Sun_03", vanilla="Item_Melody_SunSong", category="song", rule="song_tomb"),
    dict(name="Song from Windmill", flow="Dm_MelodyGet_Storm", vanilla="Item_Melody_StormSong", category="song", rule="song_windmill"),
    dict(name="Song from Ocarina of Time", flow="Dm_MelodyGet_Time", vanilla="Item_Melody_TimeSong", category="song", rule="song_oot"),
    # Zelda throws the Ocarina of Time at the moat in the same flow (shuffled with "Shuffle Ocarinas")
    dict(name="HF Ocarina of Time", flow="Dm_MelodyGet_Time", vanilla="Item_Ocarina_Time", category="ocarina", rule="oot_gift"),
    dict(name="Sheik in Forest", flow="Dm_MelodyGet_Forest", vanilla="Item_Melody_ForestMinuet", category="song", rule="song_minuet"),
    dict(name="Sheik in Crater", flow="Dm_MelodyGet_Fire", vanilla="Item_Melody_FireBolero", category="song", rule="song_bolero"),
    dict(name="Sheik in Ice Cavern", flow="Dm_MelodyGet_Water", vanilla="Item_Melody_WaterSerenade", category="song", rule="song_serenade"),
    dict(name="Sheik in Kakariko", flow="Dm_MelodyGet_Shadow", vanilla="Item_Melody_ShadowNocturne", category="song", rule="song_nocturne"),
    dict(name="Sheik at Colossus", flow="Dm_MelodyGet_Spilit", vanilla="Item_Melody_SpiritRequiem", category="song", rule="song_requiem"),
    dict(name="Sheik at Temple", flow="Dm_MelodyGet_Shine", vanilla="Item_Melody_LightPrelude", category="song", rule="song_prelude"),
    # dungeon rewards
    dict(name="Queen Gohma (Kokiri Emerald)", flow="Dm_Kokiri_0130", vanilla="Item_Stone_Forest", category="reward", rule="deku_done"),
    dict(name="King Dodongo (Goron Ruby)", flow="Dm_DeathMtTrail_0025", vanilla="Item_Stone_Fire", category="reward", rule="dodongo_done"),
    dict(name="Barinade (Zora Sapphire)", flow=["Dm_ZoraFountain_0030", "Dm_InsideJabu_Jabu_0030"], vanilla="Item_Stone_Water", category="reward", rule="jabu_done"),
    dict(name="Phantom Ganon (Forest Medallion)", flow="Dm_Awake_Forest_Get", vanilla="Item_Medal_Forest", category="reward", rule="forest_done"),
    dict(name="Volvagia (Fire Medallion)", flow="Dm_Awake_Fire_Get", vanilla="Item_Medal_Fire", category="reward", rule="fire_done"),
    dict(name="Morpha (Water Medallion)", flow="Dm_Awake_Water_Get", vanilla="Item_Medal_Water", category="reward", rule="water_done"),
    dict(name="Bongo Bongo (Shadow Medallion)", flow="Dm_Awake_Shadow_Get", vanilla="Item_Medal_Shadow", category="reward", rule="shadow_done"),
    dict(name="Twinrova (Spirit Medallion)", flow="Dm_Awake_Spirit_Get", vanilla="Item_Medal_Spirit", category="reward", rule="spirit_done"),
    dict(name="Rauru (Light Medallion)", flow="Dm_SageRoom_0005", vanilla="Item_Medal_Light", category="reward", rule="adult"),
    # great fairies
    dict(name="DMT Great Fairy Reward", flow="Dm_FairyFountain_Power", vanilla="Item_FairyBless_MP", category="fairy", rule="fairy_dmt"),
    dict(name="DMC Great Fairy Reward", flow="Dm_FairyFountain_Wisdom", vanilla="Item_FairyBless_MPDouble", category="fairy", rule="fairy_dmc"),
    dict(name="OGC Great Fairy Reward", flow="Dm_FairyFountain_Courage", vanilla="Item_FairyBless_DefenseDouble", category="fairy", rule="fairy_ogc"),
    dict(name="HC Great Fairy Reward", flow="Dm_FairyFountain_Din", vanilla="Item_DinFire", category="fairy", rule="fairy_hc"),
    dict(name="ZF Great Fairy Reward", flow="Dm_FairyFountain_Frore", vanilla="Item_FaroreWind", category="fairy", rule="fairy_zf"),
    dict(name="Colossus Great Fairy Reward", flow="Dm_FairyFountain_Nayru", vanilla="Item_NayruLove", category="fairy", rule="fairy_colossus"),
    # Character gifts and minigames. The gift events are OotrR's (game/extra_sources.py NPC_GIFTS): each names the
    # flow events that hand the reward over; every branch of one gift (e.g. the Bigger or the Biggest bag, when you
    # already own the Bigger one) gets the same item. Each minigame upgrade is guarded by its own one-time flag.
    dict(name="GC Darunias Joy", flow="Dm_Goron_0030", vanilla="Item_Gauntlet_Goron", category="npc", rule="darunia",
         events=[("Event127", "Item_Gauntlet_Goron")]),
    dict(name="GC Rolling Goron", flow="Npc_Goron_006_Child", vanilla="Item_BombBag_Medium", category="npc",
         rule="rolling_goron", upgrade_ok=True,
         events=[("Event58", "Item_BombBag_Medium"), ("Event92", "Item_BombBag_Large")]),
    dict(name="LW Target in Woods", flow="Dm_LostWood_0040", vanilla="Item_BulletBag_Medium", category="npc",
         rule="lw_target", upgrade_ok=True,
         events=[("Event30", "Item_BulletBag_Medium"), ("Event17", "Item_BulletBag_Large")]),
    dict(name="LW Deku Theater Skull Mask", flow="LostWood_ScrubForestStageElder_SkullMaskFirst",
         vanilla="Item_StickBag_Medium", category="npc", rule="theater_skull", upgrade_ok=True,
         events=[("Event29", "Item_StickBag_Medium"), ("Event32", "Item_StickBag_Large")]),
    dict(name="LW Deku Theater Mask of Truth", flow="LostWood_ScrubForestStageElder_TrueMaskFirst",
         vanilla="Item_NutBag_Medium", category="npc", rule="theater_truth", upgrade_ok=True,
         events=[("Event2", "Item_NutBag_Medium"), ("Event31", "Item_NutBag_Large")]),
    dict(name="Market Shooting Gallery Reward", flow="MiniGame_HitTarget", vanilla="Item_BulletBag_Medium",
         category="npc", rule="market_gallery", upgrade_ok=True,
         events=[("Event241", "Item_BulletBag_Medium"), ("Event378", "Item_BulletBag_Large")]),
    dict(name="Kak Shooting Gallery Reward", flow="MiniGame_HitTarget", vanilla="Item_Quiver_Medium",
         category="npc", rule="kak_gallery", upgrade_ok=True,
         events=[("Event381", "Item_Quiver_Medium"), ("Event242", "Item_Quiver_Large")]),
    dict(name="Market Bombchu Bowling Bomb Bag", flow="MiniGame_BombchuBowling", vanilla="Item_BombBag_Medium",
         category="npc", rule="bowling", upgrade_ok=True,
         events=[("Event304", "Item_BombBag_Medium"), ("Event306", "Item_BombBag_Large")]),
    dict(name="Market Bombchu Bowling Piece of Heart", flow="MiniGame_BombchuBowling", vanilla="Obj_Heart_Piece",
         category="npc", rule="bowling", events=[("Event143", "Obj_Heart_Piece")]),
    dict(name="GF HBA Quiver", flow="Minigame_HorsebackArchery", vanilla="Item_Quiver_Medium", category="npc",
         rule="hba", upgrade_ok=True, events=[("Event320", "Item_Quiver_Medium"), ("Event319", "Item_Quiver_Large")]),
    dict(name="GF Horseback Archery", flow="Minigame_HorsebackArchery", vanilla="Obj_Heart_Piece", category="npc",
         rule="hba", events=[("Event322", "Obj_Heart_Piece")]),
    dict(name="ZD Diving Minigame", flow="MiniGame_Diving", vanilla="Item_Scale_Silver", category="npc",
         rule="zd_child", events=[("Event21", "Item_Scale_Silver")]),
    dict(name="Kak Anju as Child", flow="Minigame_CatchCucco", vanilla="Item_Bottle", category="npc", rule="kak_child",
         events=[("Event181", "Item_Bottle")]),
    # Talon's first win only; the flow's other milk nodes are buying milk and refilling a bottle on later wins.
    dict(name="LLR Talons Chickens", flow="Minigame_FindOutCucco", vanilla="Item_Bottle_Milk", category="npc",
         rule="llr_child", events=[("Event23", "Item_Bottle_Milk")]),
    # the ghost shop in the adult Market: selling Big Poes up to 1000 points gives a bottle (later sales: rupees)
    dict(name="Market Big Poe Bottle", flow="Npc_Hylia_048_BottleShop", vanilla="Item_Bottle", category="npc",
         rule="big_poes", events=[("Event329", "Item_Bottle")]),
    dict(name="LH Child Fishing", flow="MiniGame_Fishing", vanilla="Obj_Heart_Piece", category="npc",
         rule="fishing_child", events=[("Event573", "Obj_Heart_Piece"), ("Event821", "Obj_Heart_Piece")]),
    dict(name="LH Adult Fishing", flow="MiniGame_Fishing", vanilla="Item_Scale_Gold", category="npc",
         rule="fishing_adult", events=[("Event579", "Item_Scale_Gold"), ("Event822", "Item_Scale_Gold")]),
    dict(name="LH Lab Dive", flow="Npc_Hylia_045_Child", vanilla="Obj_Heart_Piece", category="npc", rule="lab_dive",
         events=[("Event113", "Obj_Heart_Piece")]),
    dict(name="ZR Frogs Song Game", flow="MiniGame_FrogTenors", vanilla="Obj_Heart_Piece", category="npc",
         rule="frogs", events=[("Event384", "Obj_Heart_Piece")]),
    # Not in OotrR's list: the bug game's heart piece is passed to the flow's own MushiToriGame entry.
    dict(name="ZR Frogs Bug Game", flow="MiniGame_FrogTenors", vanilla="Obj_Heart_Piece", via="MushiToriGame",
         category="npc", rule="frogs"),
    dict(name="Graveyard Dampe Gravedigging Tour", flow="Npc_Hylia_Dampe_001", vanilla="Obj_Heart_Piece",
         category="npc", rule="graveyard_child", events=[("Event628", "Obj_Heart_Piece")]),
    # Not in OotrR's list (kept from earlier versions): Dampe's race prize.
    dict(name="Graveyard Dampe Race Reward", flow="Npc_Hylia_Dampe_001", vanilla="Obj_Heart_Piece", via="NotNpc_Dampe",
         category="npc", rule="graveyard_adult"),
    dict(name="LW Skull Kid", flow="Npc_SkullKid_Child", vanilla="Obj_Heart_Piece", category="npc", rule="skull_kid",
         events=[("Event71", "Obj_Heart_Piece")]),
    dict(name="LW Ocarina Memory Game", flow="Npc_SkullKid_Child_02", vanilla="Obj_Heart_Piece", category="npc",
         rule="memory_game", events=[("Event24", "Obj_Heart_Piece")]),
    dict(name="Kak Adult Villager Reward", flow="Npc_Hylia_001_Adult", vanilla="Obj_Heart_Piece", category="npc",
         rule="kak_adult_hook", events=[("Event4", "Obj_Heart_Piece")]),
    dict(name="Market Lost Dog", flow="SubEvent_FindRichard", vanilla="Obj_Heart_Piece", category="npc",
         rule="market_child", events=[("Event16", "Obj_Heart_Piece")]),
    # Quest rewards (OotrR's "Quest rewards" option; the ocarinas have Shuffle Ocarinas): Zelda's Letter,
    # the Light Arrows and Biggoron's claim-check reward (the adult trade items themselves stay vanilla).
    dict(name="HC Zeldas Letter", flow="Dm_HrlCastle_0050", vanilla="Item_ZeldaLetter", category="quest", rule="zelda"),
    dict(name="ToT Light Arrows Cutscene", flow="Dm_TimeTemple_0130", vanilla="Item_Arrow_Light", category="quest",
         rule="light_arrows"),
    dict(name="DMT Biggoron", flow="Npc_Goron_Biggoron_Adult", vanilla="Item_Sword_Biggoron", category="quest",
         rule="biggoron"),
    # Malon's egg: Shuffle Weird Egg. The Gerudo Membership Card always stays vanilla.
    dict(name="HC Malon Egg", flow="Goto_HyruleCastle", vanilla="Item_WeirdEgg", category="egg", rule="hc_child"),
    dict(name="Hideout Gerudo Membership Card", flow="Dm_Gerudo_0025", vanilla="Item_Token_Gerudo", category="npc",
         rule="gerudo_card"),
    # Business Scrubs that sell one thing once (OotrR's SCRUB_GIFTS): the item is the ActorName of each
    # SimpleShopSub_Scrub_Business_OneTime call, the price its Price. Each scrub has its own saved flag, set when
    # the purchase succeeds (then the scrub leaves). Refill scrubs and the Dream World ones are not checks.
    dict(name="LW Deku Scrub Stick Upgrade", flow="Enemy_Scrub_Business_Common", vanilla="Item_StickBag_Medium",
         category="scrub", rule="scrub_lw_bridge", upgrade_ok=True,
         events=[("Event322", "Item_StickBag_Medium", 40), ("Event317", "Item_StickBag_Large", 40),
                 ("Event555", "Item_StickBag_Medium", 40)]),
    dict(name="LW Deku Scrub Nut Upgrade", flow="Enemy_Scrub_Business_Common", vanilla="Item_NutBag_Medium",
         category="scrub", rule="scrub_lw_nuts", upgrade_ok=True,
         events=[("Event326", "Item_NutBag_Medium", 40), ("Event318", "Item_NutBag_Large", 40)]),
    dict(name="HF Deku Scrub Piece of Heart", flow="Enemy_Scrub_Business_Common", vanilla="Obj_Heart_Piece",
         category="scrub", rule="scrub_hf", events=[("Event645", "Obj_Heart_Piece", 100)]),
    dict(name="DMC Deku Scrub Piece of Heart", flow="Enemy_Scrub_Business_Common", vanilla="Obj_Heart_Piece",
         category="scrub", rule="scrub_dmc", events=[("Event293", "Obj_Heart_Piece", 100)]),
    # skulltula house (its own setting); the wallets are shuffled as two progressive chest wallets
    dict(name="Kak 10 Gold Skulltula Reward", flow="GatheringTokenGold", vanilla="Item_Wallet_Medium", category="house",
         rule="tokens10", upgrade_ok=True, events=[("Event398", "Item_Wallet_Medium")]),
    dict(name="Kak 20 Gold Skulltula Reward", flow="GatheringTokenGold", vanilla="Item_AgonyStone", category="house",
         rule="tokens20", events=[("Event75", "Item_AgonyStone")]),
    dict(name="Kak 30 Gold Skulltula Reward", flow="GatheringTokenGold", vanilla="Item_Wallet_Large", category="house",
         rule="tokens30", upgrade_ok=True, events=[("Event194", "Item_Wallet_Large")]),
    dict(name="Kak 40 Gold Skulltula Reward", flow="GatheringTokenGold", vanilla="Item_BombchuBundle_Large",
         category="house", rule="tokens40", events=[("Event200", "Item_BombchuBundle_Large")]),
    dict(name="Kak 50 Gold Skulltula Reward", flow="GatheringTokenGold", vanilla="Obj_Heart_Piece", category="house",
         rule="tokens50", events=[("Event219", "Obj_Heart_Piece")]),
]

# sub-flows / actions that hand an item to the player
_GIFT_SUB = re.compile(r"^(Dm_SY_GetInEvent|GetPouchContent|GetInEvent_EggHatche|Dm_SY_Get)$|HandOver_NpcToPlayer"
                       r"|TakenReward|DiggingHoleTour_Demo$|GetInEvent|MushiToriGame")
_ITEM_KEYS = ("ActorName", "ReveiveItem", "ReceiveItem", "TakenRewardActor", "DropActorName", "Actor")

STAGE_KINDS = [
    (r"^Obj_TBox_GlassTruth", "chest", "Invisible Chest"),
    (r"^Obj_TBox_A_06", "chest", "Chest"),
    (r"^Obj_TBox_A_0[1235]", "chest", "Chest"),
    (r"^Obj_(Arrow_Fire|Bottle_Letter)$", "freestanding", "Freestanding"),
    (r"^Obj_Heart_Container$", "heart_container", "Heart Container"),
    (r"^Obj_(GerudoValley_)?Heart_Piece$", "freestanding", "Freestanding Heart Piece"),
    (r"^Obj_Dungeon_SmallKey$", "freestanding", "Freestanding Small Key"),
    # green/blue/red/purple rupees lying in the world; each has its own save flag (Bool64bitKey),
    # so an item placed there is collected once. Silver rupees are puzzle pieces and stay vanilla.
    (r"^Obj_Rupee_(Green|Blue|Red|Purple)$", "rupee", "Freestanding Rupee"),
    (r"^Enemy_Skulltula_Gold$", "gs", "Gold Skulltula"),
]

# The three Deku Tree scrub-drop rupees (ScrubDekuRupee_*) appear inside the beaten scrub's flower
# (Presence Enemy_Scrub_Deku_ItemDrop_0N). A rupee there can be collected, but an item in that spot sits behind
# the flower's collision and can't be picked up (0.4.2 report), so they stay vanilla.
SCRUB_DROP_FLAG = "Enemy_Scrub_Deku_ItemDrop"
SPECIAL_RULES = {"Obj_Arrow_Fire": "fire_arrows", "Obj_Bottle_Letter": "rutos_letter"}

# Shopsanity: shelf types that are only ever placed in one shop, so re-targeting the shelf's
# actor pack changes exactly one shop. Deku Shield and the tunics are left alone (logic buys them).
# Shops (OotrR's "items shuffled per shop"): every shelf placement (Shop_*, not masks, signs or swords) is a slot.
# A shuffled slot's placement gets a new Shop_Rando_<item> actor (rando/pickups.py) instead of its shelf, so a
# shelf type sold in several shops can be shuffled in one only. Shops are told apart by where their shelves stand:
# the Market holds the bazaar, the potion shop and the Bombchu shop, Kakariko the bazaar and the potion shop.
SHOP_EXCLUDED_PREFIXES = ("Shop_Mask_", "Shop_Board_", "Shop_Item_Base", "Shop_Sword_")
SHOP_FOLDERS = {"KokiriForest", "GoronCity", "ZoraDomain", "Market", "KakarikoVillage"}
SHOP_RADIUS = 6.0          # metres: the shelves of one shop stand within this of each other
SHOP_RULES = {"KokiriForest": "shop_kokiri", "GoronCity": "shop_goron", "ZoraDomain": "shop_zora",
              "Market": "shop_market", "KakarikoVillage": "shop_kakariko"}
TOWN = {"Market": "Market", "KakarikoVillage": "Kakariko"}
SHOP_SLOT_VANILLA = "Rupee_Blue"       # what a shuffled shelf adds to the item pool


def shop_name(folder, shelves):
    if folder == "KokiriForest":
        return "Kokiri Shop"
    if folder == "GoronCity":
        return "Goron Shop"
    if folder == "ZoraDomain":
        return "Zora Shop"
    if any(g.startswith("Shop_BombchuBundle") for g in shelves):
        return "Bombchu Shop"
    if any(g.startswith("Shop_Bottle_RedPotion") for g in shelves) and not any("Shield" in g for g in shelves):
        return "%s Potion Shop" % TOWN.get(folder, folder)
    return "%s Bazaar" % TOWN.get(folder, folder)


class World:
    def __init__(self, game, progress=print):
        """`game`: an extracted romfs folder, a .nup file, or a gamefiles.GameFiles."""
        self.files = open_game(game)
        self.romfs = self.files.path        # what the user chose; all reads go through self.files
        self.progress = progress
        self.zs = F.ZsContext(self.files)
        self.actor_packs = {n[:-8] for n in self.files.listdir("Pack/Actor") if n.endswith(".pack.zs")}
        d, _ = self.zs.read("RSDB/PouchActorInfo.Product.111.rstbl.byml.zs") if self.files.exists(
            "RSDB/PouchActorInfo.Product.111.rstbl.byml.zs") else self.zs.read(self._find("RSDB", "PouchActorInfo"))
        self.pouch = {r["__RowId"]: r for r in F.byml_load(d)}
        self._load_text()
        self.locations = []
        self._scan_stages()
        self._scan_events()
        self._scan_shops()
        ids = [l.id for l in self.locations]
        assert len(ids) == len(set(ids)), "duplicate location ids"

    # ------------------------------------------------------------------ helpers
    def _find(self, folder, prefix):
        for n in sorted(self.files.listdir(folder)):
            if n.startswith(prefix):
                return folder + "/" + n
        raise FileNotFoundError(folder + "/" + prefix)

    def _load_text(self):
        self.item_text, self.region_text = {}, {}
        try:
            mals = self._find("Mals", "USen")
            raw, _ = self.zs.read(mals)
            files = F.sarc_files(raw)
            pc = F.msbt_parse(files["ActorMsg/PouchContent.msbt"])
            self.item_text = {k[:-5]: re.sub(r"\s+", " ", v) for k, v in pc.items() if k.endswith("_Name")}
            self.region_text = F.msbt_parse(files["LocationMsg/Location.msbt"])
        except Exception as e:  # text is cosmetic only
            self.progress("warning: could not read English text (%s)" % e)

    def region_name(self, folder):
        return self.region_text.get(folder, folder)

    def item_name(self, key):
        base = key.split("@")[0]
        for pre in ("Item_", "Obj_", "Weapon_", "TBox_", "Shop_", "Armor_", "Armor_Adult_", "Armor_Child_"):
            t = self.item_text.get(pre + base)
            if t:
                break
        else:
            t = base.replace("_", " ")
        if "@" in key:
            t += " (%s)" % self.region_name(key.split("@")[1])
        return t

    def actor_exists(self, name):
        return name in self.actor_packs

    def actor_for(self, key, context):
        """Actor name to write for canonical item `key` in a given placement context."""
        base = key.split("@")[0]
        order = {
            "chest": ("TBox_", "Item_", "Obj_", "Tbox_", "Weapon_"),
            "event": ("Item_", "Obj_", "Weapon_", "TBox_"),
            "world": ("Obj_", "Item_", "TBox_", "Weapon_"),
        }[context]
        for p in order:
            n = p + base
            if n in self.pouch and self.actor_exists(n):
                return n
        for p in order:
            n = p + base
            if self.actor_exists(n):
                return n
        raise KeyError("no actor for item %s in %s context" % (key, context))

    # ------------------------------------------------------------------ stages
    def _scan_stages(self):
        merged = {}
        self.shop_places = defaultdict(set)     # Shop_* actor type -> stage folders it is placed in
        self.shelves = []                       # shop shelf placements (one per stage file)
        folders = sorted(f for f in self.files.listdir("Banc") if self.files.isdir("Banc/" + f) and f not in SKIP_FOLDERS)
        for i, folder in enumerate(folders):
            self.progress("Scanning stages: %s (%d/%d)" % (folder, i + 1, len(folders)))
            for fn in sorted(self.files.listdir("Banc/" + folder)):
                if not fn.endswith(".bcett.byml.zs") or fn.startswith("Demo_"):
                    continue
                rel = "Banc/%s/%s" % (folder, fn)
                m = re.search(r"_(Adult|Child)", fn)
                if folder in DUNGEONS:
                    ages = {"child", "adult"} if DUNGEONS[folder] == "both" else {DUNGEONS[folder]}
                elif m:
                    ages = {m.group(1).lower()}
                else:
                    ages = {"child", "adult"}
                data, _ = self.zs.read(rel)
                root = F.byml_load(data)
                for a in root.get("Actors", []):
                    g = a["Gyaml"]
                    if g.startswith("Shop_"):
                        self.shop_places[g].add(folder)
                        if folder in SHOP_FOLDERS and not g.startswith(SHOP_EXCLUDED_PREFIXES):
                            self.shelves.append(dict(folder=folder, actor=g, rel=rel, hash=int(a["Hash"]),
                                                     index=(a.get("Dynamic") or {}).get("ShopItemIndex", 0),
                                                     presence="Presence" in a,
                                                     pos=tuple(float(x) for x in a["Translate"])))
                    dyn = a.get("Dynamic") or {}
                    for pat, kind, label in STAGE_KINDS:
                        if re.search(pat, g):
                            break
                    else:
                        continue
                    if kind == "rupee" and (a.get("Presence") or {}).get("FlagName", "").startswith(SCRUB_DROP_FLAG):
                        continue
                    if kind == "chest":
                        vanilla = dyn.get("Drop__DropActor") or "Obj_Rupee_Green"
                    elif kind == "gs":
                        vanilla = "Obj_Token_Gold"
                    else:
                        vanilla = g
                    key = (folder, int(a["Hash"]))
                    loc = merged.get(key)
                    if loc is None:
                        merged[key] = loc = dict(
                            region=folder, hash=int(a["Hash"]), kind=kind, label=label, actor=g,
                            vanilla_actor=vanilla, ages=set(), refs=[], presence=(a.get("Presence") or {}).get("FlagName", ""),
                            get_event=dyn.get("GetEventName", ""), conditional="Drop__CheckActor" in dyn,
                            pos=tuple(round(float(x), 2) for x in a["Translate"]), room=dyn.get("DefaultDungeonRoomIndex"))
                    loc["ages"] |= ages
                    loc["refs"].append((rel, int(a["Hash"])))
        # stacked minigame prize chests (e.g. the Dampe race goal): keep only the non-junk members
        stacks = defaultdict(list)
        for loc in merged.values():
            if loc["kind"] == "chest":
                stacks[(loc["region"], tuple(round(c) for c in loc["pos"]))].append(loc)
        skip = set()
        for group in stacks.values():
            if len(group) > 1:
                for loc in group:
                    if canon(loc["vanilla_actor"]) in JUNK:
                        skip.add((loc["region"], loc["hash"]))
        counters = defaultdict(int)
        for key in sorted(merged, key=lambda k: (merged[k]["region"], merged[k]["kind"], merged[k]["room"] or 0, merged[k]["pos"])):
            loc = merged[key]
            if key in skip:
                continue
            region = loc["region"]
            dungeon = region if region in DUNGEONS else None
            van = canon(loc["vanilla_actor"])
            if van.startswith("Dungeon_") and dungeon:
                van += "@" + dungeon
            counters[(region, loc["label"])] += 1
            n = counters[(region, loc["label"])]
            room = " (room %s)" % loc["room"] if loc["room"] is not None else ""
            name = "%s %s %d%s" % (self.region_name(region), loc["label"], n, room)
            self.locations.append(Location(
                id="stage:%s:%d" % (region, loc["hash"]), name=name, region=region, dungeon=dungeon,
                kind=loc["kind"], category=loc["kind"], ages=loc["ages"], vanilla=van,
                vanilla_actor=loc["vanilla_actor"], stage_refs=loc["refs"], presence=loc["presence"],
                get_event=loc["get_event"], conditional=loc["conditional"], pos=loc["pos"], room=loc["room"],
                rule_key=SPECIAL_RULES.get(loc["actor"])))

    # ------------------------------------------------------------------ events
    def _scan_events(self):
        cache = {}
        for i, spec in enumerate(EVENT_LOCATIONS):
            self.progress("Scanning events: %s" % spec["name"])
            flows = spec["flow"] if isinstance(spec["flow"], list) else [spec["flow"]]
            refs, price_refs = [], []
            for flow in flows:
                for suffix in ("", ".110"):
                    rel = "Event/EventFlow/%s%s.bfevfl.zs" % (flow, suffix)
                    if not self.files.exists(rel):
                        continue
                    if rel not in cache:
                        data, _ = self.zs.read(rel)
                        cache[rel] = F.EvflFile(data)
                    if "events" in spec:
                        found = self._named_gift_nodes(cache[rel], spec["events"])
                        if found is None:
                            if suffix:              # the .110 update may drop an event: only the base file counts
                                continue
                            refs, price_refs = [], []
                            break
                        refs += [(rel, off) for off, _ in found]
                        price_refs += [(rel, poff, price) for _, (poff, price) in found if poff is not None]
                        continue
                    for vanilla in [spec["vanilla"]] + spec.get("also", []):
                        refs += [(rel, off) for off in self._gift_nodes(cache[rel], vanilla, spec.get("via"))]
            if not refs:
                self.progress("warning: event location '%s' not found; skipped" % spec["name"])
                continue
            self.locations.append(Location(
                id="event:" + spec["name"], name=spec["name"], region=None, dungeon=None, kind="event",
                category=spec["category"], ages=set(), vanilla=canon(spec["vanilla"]),
                vanilla_actor=spec["vanilla"], event_refs=refs, rule_key=spec["rule"],
                upgrade_ok=spec.get("upgrade_ok", False), price_refs=price_refs))

    # ------------------------------------------------------------------ shops
    def _scan_shops(self):
        """One location per shop shelf: its placements in the child and adult files are one slot."""
        shops = []          # [(folder, centre, [shelf placements])]
        self.shop_conditional = set()   # slots shown only under a story condition (Presence): never shuffled
        for sh in self.shelves:
            for folder, centre, members in shops:
                if folder == sh["folder"] and math.dist(centre, sh["pos"]) <= SHOP_RADIUS:
                    members.append(sh)
                    break
            else:
                shops.append((sh["folder"], sh["pos"], [sh]))
        for folder, centre, members in shops:
            name = shop_name(folder, {m["actor"] for m in members})
            slots = defaultdict(list)
            for m in members:
                slots[(m["index"], m["actor"])].append(m)
            for n, ((index, actor), placed) in enumerate(sorted(slots.items()), 1):
                lid = "shop:%s:%s:%d" % (name.replace(" ", ""), actor, index)
                if any(m["presence"] for m in placed):
                    self.shop_conditional.add(lid)
                self.locations.append(Location(
                    id=lid, name="%s Item %d" % (name, index + 1),
                    region=folder, dungeon=None, kind="shop", category="shop", ages=set(),
                    vanilla=SHOP_SLOT_VANILLA, vanilla_actor=actor, rule_key=SHOP_RULES[folder],
                    stage_refs=sorted({(m["rel"], m["hash"]) for m in placed}), shop=name))

    @staticmethod
    def _named_gift_nodes(ev, events):
        """[(item field offset, (Price field offset, price) or (None, None))] for the named events, or None when one
        is missing or doesn't hand over its expected item."""
        by_name = {e["name"]: e for fc in ev.flowcharts for e in fc["events"]}
        out = []
        for spec in events:
            name, actor = spec[0], spec[1]
            e = by_name.get(name)
            p = e.get("params") if e else None
            keys = [k for k in _ITEM_KEYS if isinstance(p, dict) and p.get(k) == actor and k in e["ptrs"]]
            if len(keys) != 1:
                return None
            price = (None, None)
            if len(spec) > 2:
                if p.get("Price") != spec[2] or "#int:Price" not in e["ptrs"]:
                    return None
                price = (e["ptrs"]["#int:Price"], spec[2])
            out.append((e["ptrs"][keys[0]], price))
        return out

    @staticmethod
    def _gift_nodes(ev, item, via=None):
        offs = []
        for fc in ev.flowcharts:
            for e in fc["events"]:
                p = e.get("params")
                if not isinstance(p, dict):
                    continue
                for k in _ITEM_KEYS:
                    if p.get(k) != item or k not in e["ptrs"]:
                        continue
                    ok = False
                    if e["type"] == 4:
                        sub = "%s:%s" % (e.get("flowchart") or "", e.get("entry") or "")
                        ok = bool(_GIFT_SUB.search(e.get("flowchart") or "") or _GIFT_SUB.search(e.get("entry") or ""))
                        if via and via not in sub:
                            ok = False
                    elif e["type"] == 0 and not via:
                        if e.get("action") == "EventTriggerAddOrRemovePouchContent":
                            ok = isinstance(p.get("Num"), int) and p["Num"] > 0
                        elif e.get("action") == "EventTriggerSetForGetWindow":
                            ok = True
                    if ok:
                        offs.append(e["ptrs"][k])
        return offs
