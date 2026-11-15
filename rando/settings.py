"""Setting definitions (shared by the GUI, the CLI and the settings string)."""
import base64
import json
import zlib

# (key, tab, group, label, type, options or None, default, tooltip)
SETTINGS = [
    # ---- World
    ("logic_rules", "World", "Logic", "Logic Rules", "choice",
     [("glitchless", "Glitchless"), ("none", "No Logic (experimental)")], "glitchless",
     "Glitchless: the seed can always be beaten without glitches. The logic is cautious, so it may expect\n"
     "an item a little earlier than you strictly need it.\n"
     "No Logic: items are placed completely at random; the seed may be unbeatable."),
    ("reachable_locations", "World", "Logic", "Guarantee Reachable Locations", "choice",
     [("all", "All"), ("beatable", "Required Only (experimental)")], "all",
     "All: every check in the seed can be reached, so you can collect everything.\n"
     "Required Only: only beating the game is guaranteed; some checks may be out of reach."),
    ("open_forest", "World", "Open Areas", "Kokiri Forest", "choice",
     [("closed", "Closed"), ("closed_deku", "Closed Deku"), ("open", "Open")], "closed",
     "Closed: as in the original. Mido blocks the Deku Tree until you have a sword and shield, and the\n"
     "Kokiri boy blocks the forest exit until the Deku Tree is beaten.\n"
     "Closed Deku: the forest exit is open from the start; Mido still wants a sword and shield.\n"
     "Open: both are out of the way; you can go to the Deku Tree or leave the forest right away."),
    ("open_door", "World", "Open Areas", "Door of Time", "choice",
     [("closed", "Closed"), ("open", "Open")], "closed",
     "Open: the Door of Time in the Temple of Time is already open, so you can walk in and pull the\n"
     "Master Sword without the three Spiritual Stones, an ocarina or the Song of Time."),
    ("open_zora", "World", "Open Areas", "Zora's Fountain", "choice",
     [("closed", "Closed"), ("open", "Open")], "closed",
     "Open: King Zora has already moved aside and stays aside, so Zora's Fountain and Jabu-Jabu can be\n"
     "reached without Ruto's Letter. Ruto still gives her reward in Jabu-Jabu. The quest log's Zora entry\n"
     "stays empty. Ruto's Letter would be useless, so it is replaced by an empty Bottle (wherever it\n"
     "lands, or at Lake Hylia if freestanding items aren't shuffled)."),
    ("open_dmt", "World", "Open Areas", "Open Death Mountain", "bool", None, False,
     "The gate from Kakariko to Death Mountain is open for child Link from the start, so you don't need\n"
     "to show Zelda's Letter to the soldier. The Happy Mask Shop opens too. Zelda's Letter is then only\n"
     "needed for the soldier's mask trade."),
    ("skip_child_zelda", "World", "Story Skips", "Skip Child Zelda", "bool", None, False,
     "A new save starts as if you had already been through Hyrule Castle as a child. You already own\n"
     "the items from Zelda (HC Zeldas Letter), Malon (HC Malon Egg) and Impa (Song from Impa), Malon and\n"
     "Talon are at Lon Lon Ranch, and Hyrule Field has day and night from the start. Those three checks\n"
     "only hold items a save can start with (songs and single items, no ammo or upgrades)."),
    ("skip_epona_race", "World", "Story Skips", "Skip Epona Race (experimental, not working)", "bool", None, False,
     "Not working yet: in testing, Epona doesn't come to Epona's Song with this on. Leave it off and\n"
     "win Ingo's race as usual.\n"
     "Meant to work like this: as adult, play Epona's Song once inside the Lon Lon Ranch fence and\n"
     "Epona becomes your horse without the race."),
    # ---- Items
    ("shuffle_songs", "Items", "Quest Items", "Shuffle Songs", "choice",
     [("vanilla", "Vanilla"), ("song", "Song Locations"), ("anywhere", "Anywhere")], "song",
     "Song Locations: every place that teaches a song (Impa, Malon, Saria, Sheik, the Royal Tomb, the\n"
     "windmill and the Ocarina of Time scene) teaches a random song instead.\n"
     "Anywhere: songs can be in any check: lying on the ground, in chests, dropped by Gold\n"
     "Skulltulas, on shop shelves or given by people. A song shows as a harp."),
    ("shuffle_rewards", "Items", "Quest Items", "Shuffle Spiritual Stones/Medallions", "choice",
     [("vanilla", "Vanilla"), ("reward", "Dungeon Reward Locations"), ("anywhere", "Anywhere")], "vanilla",
     "Dungeon Reward Locations: the Spiritual Stones and Medallions are swapped between the bosses.\n"
     "Anywhere: beating a boss gives a random item, and the stones and medallions can be in any check.\n"
     "The story still follows the dungeons you've beaten: the Door of Time opens after the three child\n"
     "dungeons, and the Light Arrows and Ganon's bridge come after the Shadow and Spirit Temples. With a\n"
     "closed Door of Time, all three Spiritual Stones can be found as child. The sage cutscenes play for\n"
     "the dungeon you beat."),
    ("shuffle_ocarinas", "Items", "Quest Items", "Shuffle Ocarinas", "bool", None, False,
     "The Fairy Ocarina and the Ocarina of Time are found in random checks. Saria doesn't hand you the\n"
     "Fairy Ocarina on the forest bridge, and Zelda's Ocarina of Time at the castle moat becomes a check.\n"
     "Either ocarina plays every song and opens the Door of Time."),
    ("shuffle_kokiri_sword", "Items", "Quest Items", "Shuffle Kokiri Sword", "bool", None, True,
     "The Kokiri Sword chest gives a random item, and the sword is found in another check.\n"
     "Off: the sword stays in its chest, which still plays the sword's own scene (also with Chests\n"
     "Without Cutscene)."),
    ("shuffle_weird_egg", "Items", "Quest Items", "Shuffle Weird Egg", "bool", None, False,
     "Off: Malon at Hyrule Castle gives the Weird Egg as usual.\n"
     "On: her reward is random and the Weird Egg is in another check. It hatches into the Cucco on the\n"
     "game's usual timer once you have it. Needs NPC & Minigame Rewards shuffled."),
    ("shuffle_freestanding", "Items", "Shuffled Locations", "Shuffle Freestanding Items", "bool", None, True,
     "Items lying in the world become checks: the freestanding Pieces of Heart, the Fire Arrows at\n"
     "Lake Hylia and Ruto's Letter. Walk into a shuffled item to collect it (Pieces of Heart and Ruto's\n"
     "Letter still need A)."),
    ("shuffle_rupees", "Items", "Shuffled Locations", "Shuffle Freestanding Rupees", "bool", None, False,
     "The 109 green, blue, red and purple rupees lying around the world (Kokiri Forest, Hyrule Field,\n"
     "Zora's River/Domain/Fountain, Death Mountain, Graveyard) become checks. Walk into one to collect it,\n"
     "and each can only be collected once. Silver rupee puzzles are not changed."),
    ("shuffle_heart_containers", "Items", "Shuffled Locations", "Shuffle Boss Heart Containers", "bool", None, True,
     "The Heart Container each boss leaves behind becomes a random item."),
    ("shuffle_npc", "Items", "Shuffled Locations", "Character Gifts and Minigames (needs further testing)", "bool",
     None, True,
     "The rewards people and minigames give are random, as OotrR picks them: Darunia, the rolling Goron,\n"
     "the Lost Woods targets and Skull Kid, the Deku Theater (Skull Mask and Mask of Truth), both shooting\n"
     "galleries, Bombchu Bowling, horseback archery, the diving game, Anju, Talon, the Big Poe buyer,\n"
     "fishing, the lab dive, the frogs, Dampe, the man on the roof and the lost dog. Every branch of one\n"
     "reward (e.g. the Bigger or the Biggest bag) gives the same item.\n"
     "Never shuffled: the Gerudo Membership Card (the guards check the carpenter rescue, not the card) and\n"
     "the adult trade items (they share the Cucco's slot and would hide it)."),
    ("shuffle_quest", "Items", "Shuffled Locations", "Shuffle Quest Rewards", "bool", None, True,
     "Zelda's Letter, the Light Arrows (Temple of Time) and Biggoron's reward give random items.\n"
     "The ocarinas are Shuffle Ocarinas, Malon's egg is Shuffle Weird Egg."),
    ("shuffle_scrubs", "Items", "Shuffled Locations", "Business Scrubs", "bool", None, False,
     "The Business Scrubs that sell one thing once sell a random item instead (from OotrR): the Deku Stick\n"
     "upgrade (Lost Woods bridge), the Deku Nut upgrade (Lost Woods), and the Pieces of Heart in Hyrule\n"
     "Field and Death Mountain Crater. The scrub names the item it sells. Refill scrubs are unchanged.\n"
     "Their price is Business Scrub Prices."),
    ("scrub_prices", "Items", "Shuffled Locations", "Business Scrub Prices", "choice",
     [("low", "10 Rupees"), ("regular", "Game's Price (40 / 100 Rupees)"), ("random", "Random (10-99 Rupees)"),
      ("random_wallet", "Random (10-200 Rupees)")], "low",
     "What the shuffled Business Scrubs charge. Game's Price is 40 rupees for the Lost Woods scrubs and\n"
     "100 for the heart scrubs. A price above 99 rupees needs the Adult's Wallet in the logic."),
    ("shuffle_fairies", "Items", "Shuffled Locations", "Shuffle Great Fairy Rewards", "bool", None, True,
     "The six Great Fairies give random items instead of Din's Fire, Farore's Wind, Nayru's Love and\n"
     "their three blessings (magic, double magic, halved damage)."),
    ("shuffle_house", "Items", "Shuffled Locations", "Shuffle Skulltula House Rewards", "bool", None, True,
     "The Skulltula House rewards for 10, 20, 30, 40 and 50 Gold Skulltula Tokens are random. Its two\n"
     "wallets are found in chests instead: the first one you open gives the Adult's Wallet, the second\n"
     "the Giant's Wallet."),
    ("tokensanity", "Items", "Shuffled Locations", "Tokensanity", "choice",
     [("off", "Off"), ("dungeons", "Dungeons Only"), ("overworld", "Overworld Only"), ("all", "All Tokens")], "off",
     "Gold Skulltulas drop a random item instead of a token. It floats where the Skulltula died, like a\n"
     "token, and you collect it by touching it, even while climbing a wall. A Skulltula only stays dead\n"
     "once you've collected its item; if you leave without it, the Skulltula comes back.\n"
     "Rupees, Deku Seeds, magic jars and other refills drop as the game's own pickup instead, so\n"
     "they fall to the ground like any dropped rupee; shields and real items float."),
    ("shopsanity", "Items", "Shuffled Locations", "Items Shuffled Per Shop", "choice",
     [("off", "Off"), ("1", "1 Item"), ("2", "2 Items"), ("3", "3 Items"), ("4", "4 Items"),
      ("random", "1 to 4 Items (Random)")], "off",
     "Shelves in every shop sell random items (from OotrR): Kokiri, Goron and Zora shops, the Market's\n"
     "bazaar, potion shop and Bombchu shop, and Kakariko's bazaar and potion shop. Each can be bought\n"
     "once: a bought shelf is gone for good, also after reloading. One shelf of every purchase you\n"
     "need (Deku and Hylian Shields, tunics, Blue Fire, bugs, fish, fairies) stays on sale. Masks\n"
     "aren't shuffled. A shelf that rolls junk keeps its goods.\n"
     "Their price is Shop Prices."),
    ("shop_prices", "Items", "Shuffled Locations", "Shop Prices", "choice",
     [("low", "10 Rupees"), ("random", "Random (10-99 Rupees)"), ("random_wallet", "Random (10-200 Rupees)")], "low",
     "What the shuffled shop shelves charge. Random prices are rounded to 5 rupees. A price above 99\n"
     "rupees needs the Adult's Wallet in the logic."),
    ("item_pool", "Items", "Item Pool", "Item Pool", "choice",
     [("balanced", "Balanced"), ("scarce", "Scarce (experimental)"), ("minimal", "Minimal (experimental)")], "balanced",
     "Balanced: the same items as the original game.\nScarce: half of the Pieces of Heart and Heart Containers become rupees.\n"
     "Minimal: all Pieces of Heart and Heart Containers become rupees."),
    ("refill_needs_item", "Items", "Item Pool", "Refills Need Their Item", "bool", None, True,
     "A chest with arrows, bombs, Bombchus or Deku seeds gives a blue rupee instead until you own the\n"
     "Bow, a Bomb Bag (Bombchus go in the Bomb Bag in the remake) or the Slingshot. Refills placed\n"
     "anywhere other than a chest are always blue rupees."),
    # ---- Dungeon Items
    ("maps_compasses", "Dungeon Items", "Dungeon Items", "Maps & Compasses", "choice",
     [("vanilla", "Vanilla"), ("own", "Own Dungeon"), ("remove", "Remove (replaced by junk, experimental)"),
      ("start_with", "Start With")], "own",
     "Own Dungeon: maps and compasses go in a chest of their own dungeon. The remake decides a key's dungeon\n"
     "from the dungeon the chest is in, so 'Anywhere' (keysanity) is not possible.\n"
     "Remove: their checks hold a Blue Rupee and you never get them.\n"
     "Start With: a new save already has every dungeon's map and compass, and the chests that held them\n"
     "give a random bonus instead (rupees up to Gold, Bombchus, ammo, sometimes a Piece of Heart)."),
    ("small_keys", "Dungeon Items", "Dungeon Items", "Small Keys", "choice",
     [("vanilla", "Vanilla"), ("own", "Own Dungeon (experimental)")], "vanilla",
     "Own Dungeon shuffles small keys inside their dungeon. The logic has no door-by-door key model,\n"
     "so a key can end up behind its own locked door."),
    ("boss_keys", "Dungeon Items", "Dungeon Items", "Boss Keys", "choice",
     [("vanilla", "Vanilla"), ("own", "Own Dungeon (experimental)")], "vanilla",
     "Own Dungeon puts the boss key in a chest of its own dungeon (same caveat as small keys)."),
    # ---- Hints
    ("hint_distribution", "Hints", "Gossip Stones", "Hint Distribution", "choice",
     [("none", "No Hints"), ("balanced", "Balanced"), ("strong", "Strong"),
      ("useless", "Useless")], "none",
     "What the Gossip Stones say. No Hints: their normal rumors.\n"
     "Balanced: a mix of clues: areas on the Way of the Hero (holding something you can't finish without),\n"
     "areas that are a waste of time, where some major items are, and what some locations hold.\n"
     "Strong: more Way of the Hero and waste-of-time clues, fewer item clues, no joke lines.\n"
     "Useless: every stone tells a joke.\n"
     "A clue that names a location is only put on a stone you can read without that location's item.\n"
     "Hints are listed in the spoiler log. (Clawshot's hint system.)"),
    ("gossip_stones", "Hints", "Gossip Stones", "Gossip Stones", "choice",
     [("mask", "Mask of Truth Required"), ("no_mask", "No Mask of Truth")], "mask",
     "Mask of Truth Required: as in the original game, a stone only speaks to child Link wearing the\n"
     "Mask of Truth; otherwise Navi comments on it. Hints then never name something you need to get the mask.\n"
     "No Mask of Truth: every stone speaks to anyone, at any age, with or without the mask."),
    # ---- Quality of Life
    ("skip_cutscenes", "Quality of Life", "Cutscenes", "Make All Cutscenes Skippable", "bool", None, True,
     "Every cutscene can be skipped with the skip button, including the opening, the staff credits and\n"
     "the title-screen demos that normally can't be. Cutscenes still start: items and story progress\n"
     "are given inside them."),
    ("skip_story_scenes", "Quality of Life", "Cutscenes", "Skip Story Scenes (experimental, needs additional testing)", "bool", None, False,
     "The story scenes that come with quest progress don't play; you get their item straight away:\n"
     "- Temple of Time: the door opening, Ganondorf, pulling the Master Sword, and Rauru's talk in the\n"
     "  Chamber of Sages (his Light Medallion check is given at once);\n"
     "- adult Temple of Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows;\n"
     "- after a boss: each sage's awakening and medallion, and the Deku Tree / Darunia / Ruto handing over\n"
     "  the Spiritual Stones;\n"
     "- leaving Kokiri Forest: Saria's goodbye on the bridge (the Fairy Ocarina is given at once).\n"
     "Song lessons, boss intros and the ending still play (Make All Cutscenes Skippable covers those).\n"
     "Tested in-game so far: only Rauru's Light Medallion after the Master Sword and Saria's Fairy\n"
     "Ocarina on the bridge. Known to still play: leaving the Temple of Time as adult and Ganon's\n"
     "Castle's first-visit scene."),
    ("skip_area_intros", "Quality of Life", "Cutscenes", "Skip Area Intro Cutscenes (experimental)", "bool", None, False,
     "Experimental: early reports say the intros still play.\n"
     "First-arrival camera pans count as already seen: Kakariko, Graveyard, Hyrule Castle, Lake Hylia,\n"
     "Gerudo Valley/Fortress, Zora's River/Fountain, Ganon's Castle, Lost Woods (after Saria), and the\n"
     "Fire Temple / Bottom of the Well / Spirit Temple entrances. Intros that also advance a quest\n"
     "(Deku Tree, Death Mountain, Zora's Domain, Colossus, Castle Town, Crater, Ice Cavern, Shadow Temple,\n"
     "Training Ground, Kokiri Forest, Goron City, Hyrule Field) still play; use the skip button for those."),
    ("skip_kaepora", "Quality of Life", "Cutscenes", "Skip Kaepora Gaebora", "bool", None, True,
     "Kaepora Gaebora doesn't stop you to talk when you leave Kokiri Forest, in Hyrule Field or at\n"
     "Zora's River. The quest menu and the amiibo menu item he unlocks are available anyway. His optional\n"
     "rides at Lake Hylia and Death Mountain, and his talk in front of Hyrule Castle, are unchanged."),
    ("skip_opening", "Quality of Life", "Cutscenes", "Skip Opening Movie", "bool", None, True,
     "A new game starts in Link's house without the opening movie (the narrated prologue, the Great Deku\n"
     "Tree's dream and Navi's flight). The game still waits for Kokiri Forest to load. Navi waking Link\n"
     "still plays. (From Clawshot.)"),
    ("skip_saria_intro", "Quality of Life", "Cutscenes", "Skip Saria's Wake-Up Scene", "bool", None, True,
     "Saria doesn't wait at Link's door, walk him out or greet Navi. The door is open, Saria counts as\n"
     "talked to, and the pause map works. The basic-controls tip still shows. (From Clawshot.)"),
    ("skip_deku_talk", "Quality of Life", "Cutscenes", "Skip the Great Deku Tree's Talk", "bool", None, True,
     "The Great Deku Tree's speech when you first reach him doesn't play: his mouth is open and you can\n"
     "walk straight in. With Mido still blocking (Kokiri Forest not Open), this happens when Mido steps\n"
     "aside after seeing your sword and shield. (From Clawshot.)"),
    ("quick_chests", "Quality of Life", "Cutscenes", "Chests Without Cutscene", "bool", None, True,
     "Big chests open without the camera move and Link's opening animation: the lid opens, Link holds\n"
     "the item up and its message shows. The fanfare starts at once. (From OotrR.) Small chests keep\n"
     "their own short opening. A chest that starts a story scene (such as the vanilla Kokiri Sword)\n"
     "keeps it."),
    ("free_bombs", "Quality of Life", "Gameplay", "Bombs Usable Without Goron Bracelet", "bool", None, True,
     "Bombs from the bag can be pulled out and thrown as soon as you have a Bomb Bag. In the remake they\n"
     "normally need the Goron Bracelet, which the original always gave you first. Bomb Flowers still\n"
     "need the bracelet. Off: the logic expects the Goron Bracelet before bombs."),
    ("dodongo_bag_bombs", "Quality of Life", "Gameplay", "Bag Bombs Open Dodongo's Cavern", "bool", None, True,
     "A bomb from your Bomb Bag breaks the boulder in front of Dodongo's Cavern, so you don't need the\n"
     "Goron Bracelet to open it. Off: only the bomb flower next to it works, which needs the bracelet."),
    ("saria_song_ocarina", "Quality of Life", "Gameplay", "Saria's Song With Just an Ocarina", "bool", None, True,
     "Saria teaches her song in Sacred Forest Meadow as soon as you own an ocarina (either one);\n"
     "you don't need to meet Zelda first. Works with any Kokiri Forest setting."),
    ("anju_one_cucco", "Quality of Life", "Minigames & NPCs", "Anju Needs Only 1 Cucco", "bool", None, True,
     "Return a single cucco to Anju's pen in Kakariko to finish her minigame and get the reward."),
    ("big_poe_one", "Quality of Life", "Minigames & NPCs", "Big Poe Buyer Needs Only 1 Big Poe (experimental)", "bool", None, False,
     "Sell a single Big Poe to the ghost shop in the adult Market to get his reward (normally ten,\n"
     "1000 points), so your first sale is the last one. Not yet confirmed in-game."),
    # ---- Exclusions
    ("excluded_locations", "Exclusions", "Excluded", "Excluded Locations (experimental)", "list", None, [],
     "Locations that never hold progression or dungeon items (only rupees, ammo, hearts)."),
    # ---- ROM Options
    ("create_spoiler", "ROM Options", "Output", "Create Spoiler Log", "bool", None, True,
     "Write spoiler.txt / spoiler.json next to the mod."),
]

DEFAULTS = {s[0]: s[6] for s in SETTINGS}
SPEC = {s[0]: s for s in SETTINGS}

# Seed presets (the Preset drop-down). Each one sets every gameplay setting; Excluded Locations and Create Spoiler
# Log are left as they are. Only options confirmed in-game are used: nothing experimental or untested.
_PRESET_QOL = {
    "skip_cutscenes": True, "skip_story_scenes": False, "skip_area_intros": False, "skip_kaepora": True,
    "skip_opening": True, "skip_saria_intro": True, "skip_deku_talk": True, "quick_chests": True,
    "dodongo_bag_bombs": True, "saria_song_ocarina": True, "anju_one_cucco": True, "big_poe_one": False,
    "skip_epona_race": False, "logic_rules": "glitchless", "reachable_locations": "all",
    "small_keys": "vanilla", "boss_keys": "vanilla", "item_pool": "balanced", "refill_needs_item": True,
    "shuffle_freestanding": True, "shuffle_heart_containers": True, "shuffle_npc": True, "shuffle_quest": True,
    "shuffle_fairies": True, "shuffle_house": True,
}
PRESETS = {
    "Beginner": dict(_PRESET_QOL,
        open_forest="open", open_door="open", open_zora="open", open_dmt=True, skip_child_zelda=True,
        shuffle_songs="song", shuffle_rewards="vanilla", shuffle_ocarinas=False, shuffle_kokiri_sword=False,
        shuffle_weird_egg=False, shuffle_rupees=False, shuffle_scrubs=False, scrub_prices="low",
        tokensanity="off", shopsanity="off", shop_prices="low", maps_compasses="start_with",
        hint_distribution="balanced", gossip_stones="no_mask", free_bombs=True),
    "Standard": dict(_PRESET_QOL,
        open_forest="open", open_door="open", open_zora="closed", open_dmt=False, skip_child_zelda=True,
        shuffle_songs="song", shuffle_rewards="vanilla", shuffle_ocarinas=False, shuffle_kokiri_sword=True,
        shuffle_weird_egg=False, shuffle_rupees=False, shuffle_scrubs=True, scrub_prices="regular",
        tokensanity="dungeons", shopsanity="off", shop_prices="low", maps_compasses="start_with",
        hint_distribution="balanced", gossip_stones="mask", free_bombs=True),
    "Expert": dict(_PRESET_QOL,
        open_forest="closed", open_door="closed", open_zora="closed", open_dmt=False, skip_child_zelda=False,
        shuffle_songs="anywhere", shuffle_rewards="anywhere", shuffle_ocarinas=True, shuffle_kokiri_sword=True,
        shuffle_weird_egg=True, shuffle_rupees=True, shuffle_scrubs=True, scrub_prices="random",
        tokensanity="all", shopsanity="4", shop_prices="random", maps_compasses="vanilla",
        hint_distribution="balanced", gossip_stones="mask", free_bombs=False),
}
PRESET_TIPS = {
    "Beginner": "Everything open from the start (Kokiri Forest, Door of Time, Zora's Fountain, Death Mountain),\n"
                "child Zelda skipped, songs only at song spots, the stones and medallions where they normally are,\n"
                "the Kokiri Sword in its chest, every map and compass from the start, and Balanced hints that\n"
                "speak without the Mask of Truth.",
    "Standard": "Kokiri Forest and the Door of Time open, child Zelda skipped, Business Scrubs and the dungeon Gold\n"
                "Skulltulas shuffled, every map and compass from the start, Balanced hints (Mask of Truth needed).",
    "Expert": "Everything closed as in the original, songs and the stones and medallions anywhere, both\n"
              "ocarinas, the Weird Egg, freestanding rupees, Business Scrubs, every Gold Skulltula and 4 items per\n"
              "shop shuffled at random prices, vanilla maps and compasses, and bombs need the Goron Bracelet.",
}
for _name, _p in PRESETS.items():
    assert set(_p) == set(DEFAULTS) - {"excluded_locations", "create_spoiler"}, (_name, set(DEFAULTS) ^ set(_p))
    for _k, _v in _p.items():
        assert SPEC[_k][4] != "choice" or _v in {o[0] for o in SPEC[_k][5]}, (_name, _k, _v)


def apply_preset(settings, name):
    """`settings` with preset `name` applied (Excluded Locations and Create Spoiler Log kept)."""
    out = dict(normalize(settings))
    out.update(PRESETS[name])
    return out


def matching_preset(settings):
    """Name of the preset `settings` match exactly, or None (custom)."""
    st = normalize(settings)
    return next((name for name, p in PRESETS.items() if all(st[k] == v for k, v in p.items())), None)

# Classic options that cannot be done with the current data swaps, shown in the GUI for reference.
UNSUPPORTED = [
    ("Keysanity (small keys / boss keys / Ganon's keys anywhere)",
     "The remake has one generic small key and one generic boss key; the stage you pick a key up in "
     "decides which dungeon it counts for, and no event can add a key to another dungeon. Use "
     "'Own Dungeon' on the Dungeon Items tab instead."),
    ("Bunny Hood speed boost (Majora's Mask style)",
     "Run speed comes from the animations; the only speed value in the data is a global scale. Masks "
     "have no movement parameter and the equipment effect list (e.g. UnderwaterBreathing) has no "
     "speed effect that can be confirmed."),
    ("Fast climbing",
     "Climb speed is computed by the player code and passed to the climb animation at runtime; no "
     "data file holds it."),
    ("Scrubsanity (all Business Scrubs)",
     "Only the four one-time scrubs are shuffled (Business Scrubs). The others sell refills through the "
     "Scrub Business Seed trading system, can be bought again and again, and their goods and prices are "
     "fixed per item type inside one shared event flow."),
    ("Cow Shuffle / Beans", "Cows use one shared event; the bean seller isn't mapped yet."),
    ("Shuffle the Gerudo Membership Card", "The guards, the wasteland gate, the Training Ground and horseback "
     "archery check the carpenter rescue, not the card, so a card found elsewhere does nothing. It stays vanilla."),
    ("Shuffle the adult trade items", "All trade items share one slot and adult items take priority: an adult "
     "trade item found as a child hides the Cucco for good. Only Biggoron's reward is shuffled."),
    ("Other capacity upgrades (Deku Seed bag from the Deku Tree)",
     "Stays vanilla: the logic needs the Slingshot from its chest. The stick and nut upgrades are shuffled "
     "with Character Gifts and Minigames and Business Scrubs."),
    ("Entrance Randomizer", "Not supported."),
    ("Hints (Gossip Stones)", "Gossip Stone text editing is not implemented; use the spoiler log."),
    ("Ice Traps / Chest Appearance Matches Contents / Cosmetics", "Not implemented."),
    ("Master Quest dungeons", "Not present in the remake."),
]


def normalize(settings):
    out = dict(DEFAULTS)
    settings = dict(settings or {})
    if settings.get("shuffle_scrubs") in ("off", "low", "regular", "random"):
        # before 0.5.0's price settings, the scrub setting held the price
        old = settings.pop("shuffle_scrubs")
        settings["shuffle_scrubs"] = old != "off"
        if old != "off" and "scrub_prices" not in settings:
            settings["scrub_prices"] = old
    for k, v in settings.items():
        if k in SPEC:
            out[k] = v
    return out


def to_string(settings):
    diff = {k: v for k, v in normalize(settings).items() if v != DEFAULTS[k]}
    raw = zlib.compress(json.dumps(diff, sort_keys=True, separators=(",", ":")).encode(), 9)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def from_string(s):
    s = s.strip()
    raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    return normalize(json.loads(zlib.decompress(raw)))
