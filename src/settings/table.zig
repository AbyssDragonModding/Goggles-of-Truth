//! The setting table, presets and the list of classic options the remake can't do.
//! Generated once from rando/settings.py; edit it here. The order of `Key` is the order of `specs` (checked by
//! settings.zig) and the order the window and settings.txt show them in.

const settings = @import("settings.zig");
const Spec = settings.Spec;
const Preset = settings.Preset;
const Unsupported = settings.Unsupported;


pub const Key = enum {
    logic_rules,
    reachable_locations,
    open_forest,
    open_door,
    open_zora,
    open_dmt,
    rainbow_bridge,
    bridge_medallions,
    bridge_tokens,
    skip_child_zelda,
    skip_epona_race,
    shuffle_songs,
    shuffle_rewards,
    shuffle_ocarinas,
    shuffle_kokiri_sword,
    shuffle_weird_egg,
    shuffle_freestanding,
    shuffle_rupees,
    shuffle_heart_containers,
    shuffle_npc,
    shuffle_quest,
    shuffle_scrubs,
    scrub_prices,
    shuffle_fairies,
    shuffle_house,
    tokensanity,
    shopsanity,
    shop_prices,
    item_pool,
    refill_needs_item,
    maps_compasses,
    small_keys,
    key_rings,
    key_ring_forest,
    key_ring_fire,
    key_ring_water,
    key_ring_shadow,
    key_ring_spirit,
    key_ring_well,
    key_ring_gtg,
    key_ring_ganon,
    boss_keys,
    hint_distribution,
    gossip_stones,
    skip_cutscenes,
    skip_story_scenes,
    skip_area_intros,
    skip_kaepora,
    skip_opening,
    skip_deku_talk,
    quick_chests,
    bag_bombs_no_bracelet,
    dodongo_bag_bombs,
    gs_any_time,
    skip_ganon_trials,
    saria_song_ocarina,
    anju_one_cucco,
    big_poe_one,
    excluded_locations,
    create_spoiler,
    per_seed_saves,
};

pub const specs = [_]Spec{
    .{
        .key = .logic_rules,
        .tab = "World",
        .group = "Logic",
        .label = "Logic Rules",
        .kind = .choice,
        .options = &.{
            .{ .value = "glitchless", .label = "Glitchless" },
            .{ .value = "none", .label = "No Logic (experimental)" },
        },
        .default = .{ .choice = "glitchless" },
        .tip =
            \\Glitchless: the seed can always be beaten without glitches. The logic is cautious, so it may expect
            \\an item a little earlier than you strictly need it.
            \\No Logic: items are placed completely at random; the seed may be unbeatable.
        ,
    },
    .{
        .key = .reachable_locations,
        .tab = "World",
        .group = "Logic",
        .label = "Guarantee Reachable Locations",
        .kind = .choice,
        .options = &.{
            .{ .value = "all", .label = "All" },
            .{ .value = "beatable", .label = "Required Only (experimental)" },
        },
        .default = .{ .choice = "all" },
        .tip =
            \\All: every check in the seed can be reached, so you can collect everything.
            \\Required Only: only beating the game is guaranteed; some checks may be out of reach.
        ,
    },
    .{
        .key = .open_forest,
        .tab = "World",
        .group = "Open Areas",
        .label = "Kokiri Forest",
        .kind = .choice,
        .options = &.{
            .{ .value = "closed", .label = "Closed" },
            .{ .value = "closed_deku", .label = "Closed Deku" },
            .{ .value = "open", .label = "Open" },
        },
        .default = .{ .choice = "closed" },
        .tip =
            \\Closed: as in the original. Mido blocks the Deku Tree until you have a sword and shield, and the
            \\Kokiri boy blocks the forest exit until the Deku Tree is beaten.
            \\Closed Deku: the forest exit is open from the start; Mido still wants a sword and shield.
            \\Open: both are out of the way; you can go to the Deku Tree or leave the forest right away.
        ,
    },
    .{
        .key = .open_door,
        .tab = "World",
        .group = "Open Areas",
        .label = "Door of Time",
        .kind = .choice,
        .options = &.{
            .{ .value = "closed", .label = "Closed" },
            .{ .value = "open", .label = "Open" },
        },
        .default = .{ .choice = "closed" },
        .tip =
            \\Open: the Door of Time in the Temple of Time is already open, so you can walk in and pull the
            \\Master Sword without the three Spiritual Stones, an ocarina or the Song of Time.
        ,
    },
    .{
        .key = .open_zora,
        .tab = "World",
        .group = "Open Areas",
        .label = "Zora's Fountain",
        .kind = .choice,
        .options = &.{
            .{ .value = "closed", .label = "Closed" },
            .{ .value = "open", .label = "Open" },
        },
        .default = .{ .choice = "closed" },
        .tip =
            \\Open: King Zora has already moved aside and stays aside, so Zora's Fountain and Jabu-Jabu can be
            \\reached without Ruto's Letter. Ruto still gives her reward in Jabu-Jabu. The quest log's Zora entry
            \\stays empty. Ruto's Letter would be useless, so it is replaced by an empty Bottle (wherever it
            \\lands, or at Lake Hylia if freestanding items aren't shuffled).
        ,
    },
    .{
        .key = .open_dmt,
        .tab = "World",
        .group = "Open Areas",
        .label = "Open Death Mountain",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The gate from Kakariko to Death Mountain is open for child Link from the start, so you don't need
            \\to show Zelda's Letter to the soldier. The Happy Mask Shop opens too, and the soldier's mask trade
            \\is ready. Zelda's Letter has no use then, so it isn't in the seed: a Red Rupee takes its place in
            \\the item pool, and Zelda gives a random item, also when quest rewards aren't shuffled.
        ,
    },
    .{
        .key = .rainbow_bridge,
        .tab = "World",
        .group = "Rainbow Bridge",
        .label = "Rainbow Bridge Requirement",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "medallions", .label = "Medallions" },
            .{ .value = "stones", .label = "Spiritual Stones" },
            .{ .value = "tokens", .label = "Gold Skulltula Tokens" },
        },
        .default = .{ .choice = "vanilla" },
        .tip =
            \\What makes the rainbow bridge to Ganon's Castle appear when you walk up to the castle as adult.
            \\Every option also needs the Bow and the Light Arrows, since Ganon can't be beaten without them.
            \\Vanilla: as in the original. Beat the Shadow and Spirit Temples, get the Light Arrows from Zelda
            \\in the Temple of Time, then the sages build the bridge.
            \\Medallions: own the number of medallions set in Medallions Needed (any of the six), plus the Bow
            \\and the Light Arrows. Zelda's scene isn't needed.
            \\Spiritual Stones: own all three Spiritual Stones (Kokiri Emerald, Goron Ruby, Zora Sapphire),
            \\plus the Bow and the Light Arrows. Zelda's scene isn't needed.
            \\Gold Skulltula Tokens: own the number of tokens set in Gold Skulltula Tokens Needed, plus the Bow
            \\and the Light Arrows. Zelda's scene isn't needed.
            \\Once the bridge has appeared it stays. The altar in the Temple of Time tells the requirement and
            \\what you have of it (e.g. Medallions: 2/4).
        ,
    },
    .{
        .key = .bridge_medallions,
        .tab = "World",
        .group = "Rainbow Bridge",
        .label = "Medallions Needed",
        .kind = .int,
        .min = 1,
        .max = 6,
        .default = .{ .int = 6 },
        .tip =
            \\For Rainbow Bridge Requirement: Medallions. How many medallions you need for the bridge, out of
            \\the six; any of them count.
        ,
    },
    .{
        .key = .bridge_tokens,
        .tab = "World",
        .group = "Rainbow Bridge",
        .label = "Gold Skulltula Tokens Needed",
        .kind = .int,
        .min = 1,
        .max = 100,
        .default = .{ .int = 100 },
        .tip =
            \\For Rainbow Bridge Requirement: Gold Skulltula Tokens. How many Gold Skulltula Tokens you need
            \\for the bridge (1 to 100).
        ,
    },
    .{
        .key = .skip_child_zelda,
        .tab = "World",
        .group = "Story Skips",
        .label = "Skip Child Zelda",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\A new save starts as if you had already been through Hyrule Castle as a child. You already own
            \\the items from Zelda (HC Zeldas Letter), Malon (HC Malon Egg) and Impa (Song from Impa), Malon and
            \\Talon are at Lon Lon Ranch, and Hyrule Field has day and night from the start. Those three checks
            \\can hold any item. Most come with the new save; bags, ammo, rupees, hearts, medallions and the
            \\like are handed over, with their item window, the moment a new game starts.
        ,
    },
    .{
        .key = .skip_epona_race,
        .tab = "World",
        .group = "Story Skips",
        .label = "Skip Epona Race (needs further testing)",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\Epona is your horse from the start of a new save. Once you have Epona's Song, play it as adult
            \\anywhere you can ride (Hyrule Field, Lon Lon Ranch, Gerudo Valley...) and she comes to you.
            \\No race against Ingo, and Malon's song check at the ranch isn't needed for her. Lon Lon Ranch
            \\and its race are left as they are. Needs a new save.
        ,
    },
    .{
        .key = .shuffle_songs,
        .tab = "Items",
        .group = "Quest Items",
        .label = "Shuffle Songs",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "song", .label = "Song Locations" },
            .{ .value = "anywhere", .label = "Anywhere" },
        },
        .default = .{ .choice = "song" },
        .tip =
            \\Song Locations: every place that teaches a song (Impa, Malon, Saria, Sheik, the Royal Tomb, the
            \\windmill and the Ocarina of Time scene) teaches a random song instead.
            \\Anywhere: songs can be in any check: lying on the ground, in chests, dropped by Gold
            \\Skulltulas, on shop shelves or given by people. A song shows as a harp.
        ,
    },
    .{
        .key = .shuffle_rewards,
        .tab = "Items",
        .group = "Quest Items",
        .label = "Shuffle Spiritual Stones/Medallions",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "reward", .label = "Dungeon Reward Locations" },
            .{ .value = "anywhere", .label = "Anywhere" },
        },
        .default = .{ .choice = "vanilla" },
        .tip =
            \\Dungeon Reward Locations: the Spiritual Stones and Medallions are swapped between the bosses.
            \\Anywhere: beating a boss gives a random item, and the stones and medallions can be in any check.
            \\The story still follows the dungeons you've beaten: the Door of Time opens after the three child
            \\dungeons, and the Light Arrows and Ganon's bridge come after the Shadow and Spirit Temples. With a
            \\closed Door of Time, all three Spiritual Stones can be found as child. The sage cutscenes play for
            \\the dungeon you beat.
        ,
    },
    .{
        .key = .shuffle_ocarinas,
        .tab = "Items",
        .group = "Quest Items",
        .label = "Shuffle Ocarinas",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The Fairy Ocarina and the Ocarina of Time are found in random checks. Saria doesn't hand you the
            \\Fairy Ocarina on the forest bridge, and Zelda's Ocarina of Time at the castle moat becomes a check.
            \\Either ocarina plays every song and opens the Door of Time.
        ,
    },
    .{
        .key = .shuffle_kokiri_sword,
        .tab = "Items",
        .group = "Quest Items",
        .label = "Shuffle Kokiri Sword",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\The Kokiri Sword chest gives a random item, and the sword is found in another check.
            \\Off: the sword stays in its chest. It plays the sword's own scene, unless Skip Cutscenes is
            \\on: then the chest opens like any other and Link holds the sword up.
        ,
    },
    .{
        .key = .shuffle_weird_egg,
        .tab = "Items",
        .group = "Quest Items",
        .label = "Shuffle Weird Egg",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\Off: Malon at Hyrule Castle gives the Weird Egg as usual.
            \\On: her reward is random and the Weird Egg is in another check. It hatches into the Cucco on the
            \\game's usual timer once you have it. Needs NPC & Minigame Rewards shuffled.
        ,
    },
    .{
        .key = .shuffle_freestanding,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Freestanding Items",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Items lying in the world become checks: the freestanding Pieces of Heart, the Fire Arrows at
            \\Lake Hylia and Ruto's Letter. Walk into a shuffled item to collect it (Pieces of Heart and Ruto's
            \\Letter still need A).
        ,
    },
    .{
        .key = .shuffle_rupees,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Freestanding Rupees",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The 109 green, blue, red and purple rupees lying around the world (Kokiri Forest, Hyrule Field,
            \\Zora's River/Domain/Fountain, Death Mountain, Graveyard) become checks. Walk into one to collect it,
            \\and each can only be collected once. Silver rupee puzzles are not changed.
        ,
    },
    .{
        .key = .shuffle_heart_containers,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Boss Heart Containers",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip = "The Heart Container each boss leaves behind becomes a random item.",
    },
    .{
        .key = .shuffle_npc,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Character Gifts and Minigames (needs further testing)",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\The rewards people and minigames give are random, as OotrR picks them: Darunia, the rolling Goron,
            \\the Lost Woods targets and Skull Kid, the Deku Theater (Skull Mask and Mask of Truth), both shooting
            \\galleries, Bombchu Bowling, horseback archery, the diving game, Anju, Talon, the Big Poe buyer,
            \\fishing, the lab dive, the frogs, Dampe, the man on the roof and the lost dog. Every branch of one
            \\reward (e.g. the Bigger or the Biggest bag) gives the same item.
            \\Never shuffled: the Gerudo Membership Card (the guards check the carpenter rescue, not the card) and
            \\the adult trade items (they share the Cucco's slot and would hide it).
        ,
    },
    .{
        .key = .shuffle_quest,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Quest Rewards",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Zelda's Letter, the Light Arrows (Temple of Time) and Biggoron's reward give random items.
            \\The ocarinas are Shuffle Ocarinas, Malon's egg is Shuffle Weird Egg.
        ,
    },
    .{
        .key = .shuffle_scrubs,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Business Scrubs",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The Business Scrubs that sell one thing once sell a random item instead: the Deku Stick
            \\upgrade (Lost Woods bridge), the Deku Nut upgrade (Lost Woods), and the Pieces of Heart in Hyrule
            \\Field and Death Mountain Crater. The scrub names the item it sells. Refill scrubs are unchanged.
            \\Their price is set by Business Scrub Prices.
        ,
    },
    .{
        .key = .scrub_prices,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Business Scrub Prices",
        .kind = .choice,
        .options = &.{
            .{ .value = "low", .label = "10 Rupees" },
            .{ .value = "regular", .label = "Game's Price (40 / 100 Rupees)" },
            .{ .value = "random", .label = "Random (10-99 Rupees)" },
            .{ .value = "random_wallet", .label = "Random (10-200 Rupees)" },
        },
        .default = .{ .choice = "low" },
        .tip =
            \\What the shuffled Business Scrubs charge. Game's Price is 40 rupees for the Lost Woods scrubs and
            \\100 for the heart scrubs. A price above 99 rupees needs the Adult's Wallet in the logic.
        ,
    },
    .{
        .key = .shuffle_fairies,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Great Fairy Rewards",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\The six Great Fairies give random items instead of Din's Fire, Farore's Wind, Nayru's Love and
            \\their three blessings (magic, double magic, halved damage).
        ,
    },
    .{
        .key = .shuffle_house,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shuffle Skulltula House Rewards",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\The Skulltula House rewards for 10, 20, 30, 40 and 50 Gold Skulltula Tokens are random. Its two
            \\wallets are found in chests instead: the first one you open gives the Adult's Wallet, the second
            \\the Giant's Wallet.
        ,
    },
    .{
        .key = .tokensanity,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Tokensanity",
        .kind = .choice,
        .options = &.{
            .{ .value = "off", .label = "Off" },
            .{ .value = "dungeons", .label = "Dungeons Only" },
            .{ .value = "overworld", .label = "Overworld Only" },
            .{ .value = "all", .label = "All Tokens" },
        },
        .default = .{ .choice = "off" },
        .tip =
            \\Gold Skulltulas drop a random item instead of a token. It floats where the Skulltula died, like a
            \\token, and you collect it by touching it, even while climbing a wall. A Skulltula only stays dead
            \\once you've collected its item; if you leave without it, the Skulltula comes back.
            \\Rupees, Deku Seeds, magic jars and other refills float and count the same way.
        ,
    },
    .{
        .key = .shopsanity,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Items Shuffled Per Shop",
        .kind = .choice,
        .options = &.{
            .{ .value = "off", .label = "Off" },
            .{ .value = "1", .label = "1 Item" },
            .{ .value = "2", .label = "2 Items" },
            .{ .value = "3", .label = "3 Items" },
            .{ .value = "4", .label = "4 Items" },
            .{ .value = "random", .label = "1 to 4 Items (Random)" },
        },
        .default = .{ .choice = "off" },
        .tip =
            \\Shelves in every shop sell random items: Kokiri, Goron and Zora shops, the Market's
            \\bazaar, potion shop and Bombchu shop, and Kakariko's bazaar and potion shop. Each can be bought
            \\once: a bought shelf is gone for good, also after reloading. One shelf of every purchase you
            \\need (Deku and Hylian Shields, tunics, Blue Fire, bugs, fish, fairies) stays on sale. Masks
            \\aren't shuffled. Each chosen shelf sells a real item (songs, equipment, spells, key items); it
            \\only keeps its normal goods if the seed has no item left that a shelf can sell once.
            \\Their price is set by Shop Prices.
        ,
    },
    .{
        .key = .shop_prices,
        .tab = "Items",
        .group = "Shuffled Locations",
        .label = "Shop Prices",
        .kind = .choice,
        .options = &.{
            .{ .value = "low", .label = "10 Rupees" },
            .{ .value = "random", .label = "Random (10-99 Rupees)" },
            .{ .value = "random_wallet", .label = "Random (10-200 Rupees)" },
        },
        .default = .{ .choice = "low" },
        .tip =
            \\What the shuffled shop shelves charge. Random prices are rounded to 5 rupees. A price above 99
            \\rupees needs the Adult's Wallet in the logic.
        ,
    },
    .{
        .key = .item_pool,
        .tab = "Items",
        .group = "Item Pool",
        .label = "Item Pool",
        .kind = .choice,
        .options = &.{
            .{ .value = "balanced", .label = "Balanced" },
            .{ .value = "scarce", .label = "Scarce (experimental)" },
            .{ .value = "minimal", .label = "Minimal (experimental)" },
        },
        .default = .{ .choice = "balanced" },
        .tip =
            \\Balanced: the same items as the original game.
            \\Scarce: half of the Pieces of Heart and Heart Containers become rupees.
            \\Minimal: all Pieces of Heart and Heart Containers become rupees.
        ,
    },
    .{
        .key = .refill_needs_item,
        .tab = "Items",
        .group = "Item Pool",
        .label = "Refills Need Their Item",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\A chest with arrows, bombs, Bombchus or Deku seeds gives a blue rupee instead until you own the
            \\Bow, a Bomb Bag (Bombchus go in the Bomb Bag in the remake) or the Slingshot. Deku Nuts and Deku
            \\Sticks work the same way: a bundle only counts once you have picked up a single nut or stick
            \\(that gives you their bag), so until then their chests give a blue rupee too. Refills placed
            \\anywhere other than a chest are always blue rupees.
        ,
    },
    .{
        .key = .maps_compasses,
        .tab = "Dungeon Items",
        .group = "Dungeon Items",
        .label = "Maps & Compasses",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "own", .label = "Own Dungeon" },
            .{ .value = "remove", .label = "Remove (replaced by junk, experimental)" },
            .{ .value = "start_with", .label = "Start With" },
        },
        .default = .{ .choice = "own" },
        .tip =
            \\Vanilla: maps and compasses stay in their usual chests.
            \\Own Dungeon: maps and compasses are shuffled among the chests of their own dungeon.
            \\Remove: their checks hold a Blue Rupee and you never get them.
            \\Start With: a new save already has every dungeon's map and compass, and the chests that held them
            \\give a random bonus instead (rupees up to Gold, Bombchus, ammo, sometimes a Piece of Heart).
        ,
    },
    .{
        .key = .small_keys,
        .tab = "Dungeon Items",
        .group = "Dungeon Items",
        .label = "Small Keys",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "own", .label = "Own Dungeon (experimental)" },
            .{ .value = "remove", .label = "Removed: All Keys From the Start (experimental)" },
            .{ .value = "any_dungeon", .label = "Any Dungeon, as Key Rings (experimental)" },
            .{ .value = "overworld", .label = "Overworld, as Key Rings (experimental)" },
            .{ .value = "anywhere", .label = "Anywhere, as Key Rings (experimental)" },
        },
        .default = .{ .choice = "vanilla" },
        .tip =
            \\Own Dungeon shuffles small keys inside their dungeon. The logic has no door-by-door key model,
            \\so a key can end up behind its own locked door.
            \\Removed: every dungeon starts with all its small keys, so every locked door opens; the small key
            \\chests hold other items.
            \\Key rings: the remake's small keys count for whichever dungeon you pick them up in, so a key can't
            \\be placed in another dungeon. Instead each dungeon with a key ring (see Key Ring Dungeons) gets one
            \\Key Ring item that gives all of its small keys at once, wherever it is found: in any dungeon, only
            \\outside dungeons (Overworld), or anywhere. The small key chests of those dungeons hold other items.
            \\The logic expects the key ring before anything in its dungeon. (From OotrR.)
        ,
    },
    .{
        .key = .key_rings,
        .tab = "Dungeon Items",
        .group = "Dungeon Items",
        .label = "Key Ring Dungeons",
        .kind = .choice,
        .options = &.{
            .{ .value = "all", .label = "All Dungeons" },
            .{ .value = "choose", .label = "Chosen Dungeons" },
            .{ .value = "random", .label = "Random Dungeons" },
        },
        .default = .{ .choice = "all" },
        .tip =
            \\For Small Keys as key rings: which dungeons get a key ring (Forest, Fire, Water, Shadow and Spirit
            \\Temples, Bottom of the Well, Gerudo Training Ground, Ganon's Castle). Chosen Dungeons: the ones
            \\ticked below. Random Dungeons: each one by chance, from the seed. A dungeon without a key ring keeps
            \\its small keys where they are in the original.
        ,
    },
    .{
        .key = .key_ring_forest,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Forest Temple",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Forest Temple gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_fire,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Fire Temple",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Fire Temple gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_water,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Water Temple",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Water Temple gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_shadow,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Shadow Temple",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Shadow Temple gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_spirit,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Spirit Temple",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Spirit Temple gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_well,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Bottom of the Well",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Bottom of the Well gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_gtg,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Gerudo Training Ground",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Gerudo Training Ground gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .key_ring_ganon,
        .tab = "Dungeon Items",
        .group = "Key Ring Dungeons",
        .label = "Ganon's Castle",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\With Key Ring Dungeons: Chosen Dungeons, whether the Ganon's Castle gets a key ring. Without one its small
            \\keys stay where they are in the original.
        ,
    },
    .{
        .key = .boss_keys,
        .tab = "Dungeon Items",
        .group = "Dungeon Items",
        .label = "Boss Keys",
        .kind = .choice,
        .options = &.{
            .{ .value = "vanilla", .label = "Vanilla" },
            .{ .value = "own", .label = "Own Dungeon (experimental)" },
            .{ .value = "remove", .label = "Removed: Boss Keys From the Start (experimental)" },
            .{ .value = "any_dungeon", .label = "Any Dungeon (experimental)" },
            .{ .value = "anywhere", .label = "Anywhere (experimental)" },
        },
        .default = .{ .choice = "vanilla" },
        .tip =
            \\Own Dungeon puts the boss key in a chest of its own dungeon (same caveat as small keys).
            \\Removed: the five temples (Forest, Fire, Water, Shadow, Spirit) start with their boss key; the boss
            \\key chests hold other items.
            \\Any Dungeon / Anywhere: each temple's boss key becomes an item of its own ("Boss Key (Forest
            \\Temple)") that opens that temple's boss door wherever it is found: in any dungeon, or anywhere.
            \\The logic expects it before anything in its temple. Ganon's Castle's boss key stays where it is.
            \\(From OotrR.)
        ,
    },
    .{
        .key = .hint_distribution,
        .tab = "Hints",
        .group = "Gossip Stones",
        .label = "Hint Distribution",
        .kind = .choice,
        .options = &.{
            .{ .value = "none", .label = "No Hints" },
            .{ .value = "balanced", .label = "Balanced" },
            .{ .value = "strong", .label = "Strong" },
            .{ .value = "useless", .label = "Useless" },
        },
        .default = .{ .choice = "none" },
        .tip =
            \\What the Gossip Stones say. No Hints: their normal rumors.
            \\Balanced: a mix of clues: areas on the Way of the Hero (holding something you can't finish without),
            \\areas that are a waste of time, where some major items are, and what some locations hold.
            \\Strong: more Way of the Hero and waste-of-time clues, fewer item clues, no joke lines.
            \\Useless: every stone tells a joke.
            \\A clue that names a location is only put on a stone you can read without that location's item.
            \\Hints are listed in the spoiler log.
        ,
    },
    .{
        .key = .gossip_stones,
        .tab = "Hints",
        .group = "Gossip Stones",
        .label = "Gossip Stones",
        .kind = .choice,
        .options = &.{
            .{ .value = "mask", .label = "Mask of Truth Required" },
            .{ .value = "no_mask", .label = "No Mask of Truth" },
        },
        .default = .{ .choice = "mask" },
        .tip =
            \\Mask of Truth Required: as in the original game, a stone only speaks to child Link wearing the
            \\Mask of Truth; otherwise Navi comments on it. Hints then never name something you need to get the mask.
            \\No Mask of Truth: every stone speaks to anyone, at any age, with or without the mask.
        ,
    },
    .{
        .key = .skip_cutscenes,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Make All Cutscenes Skippable",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Every cutscene can be skipped with the skip button, including the opening, the staff credits and
            \\the title-screen demos that normally can't be. Cutscenes still start: items and story progress
            \\are given inside them.
        ,
    },
    .{
        .key = .skip_story_scenes,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Skip Cutscenes (experimental, needs additional testing)",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The cutscenes that come with quest progress don't play; you get their item straight away:
            \\- Temple of Time: the door opening, Ganondorf, pulling the Master Sword, and Rauru's talk in the
            \\  Chamber of Sages (his Light Medallion check is given at once);
            \\- adult Temple of Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows;
            \\- after a boss: each sage's awakening and medallion, and the Deku Tree / Darunia / Ruto handing over
            \\  the Spiritual Stones;
            \\- leaving Kokiri Forest: Saria's goodbye on the bridge (the Fairy Ocarina is given at once);
            \\- the Kokiri Sword chest: Link's sword swing and Navi's tip after it (the chest opens like any other);
            \\- the rest of each post-boss chain (the Deku Tree's death, Darunia, Ruto, the Deku Sprout, the
            \\  lake refilling...), Sheik/Mido/Ruto/Nabooru before the adult temples, and Ganon's Castle's
            \\  first visit, trial barriers and tower barrier (not yet tested in-game);
            \\- Kakariko Graveyard: the Royal Family's Tomb opening to Zelda's Lullaby, and the Sun's Song stone
            \\  inside (its lesson and scene; its check is given at once; not yet tested in-game).
            \\Other song lessons, boss intros and the ending still play (Make All Cutscenes Skippable covers those).
            \\Tested in-game so far: Rauru's Light Medallion after the Master Sword, the Great Deku Tree after
            \\Gohma (his check is given) and Saria's Fairy Ocarina on the bridge. Known to still play: leaving
            \\the Temple of Time as adult.
        ,
    },
    .{
        .key = .skip_area_intros,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Skip Area Intro Cutscenes (needs further testing)",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\First-arrival camera pans don't play: Kakariko, Graveyard, Hyrule Castle, Lake Hylia, Gerudo
            \\Valley/Fortress, Zora's River/Fountain, Ganon's Castle, and the Fire Temple / Bottom of the Well /
            \\Spirit Temple entrances (tested). Those areas count as visited, so their maps work without the
            \\intro's area-name banner, and Kaepora still waits at Lake Hylia for his ride.
            \\Also skipped, keeping the quest step they start (not yet tested): inside the Deku Tree, Dodongo's
            \\Cavern, Death Mountain Trail from Kakariko, Goron City, Death Mountain Crater, Zora's Domain,
            \\Lon Lon Ranch, Castle Town, Sacred Forest Meadow, Desert Colossus, Ice Cavern, Shadow Temple,
            \\Gerudo Training Ground, the Water Temple, inside Ganon's Castle and the Temple of Time
            \\(first entry, and first step out as adult).
        ,
    },
    .{
        .key = .skip_kaepora,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Skip Kaepora Gaebora",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Kaepora Gaebora doesn't stop you to talk when you leave Kokiri Forest, in the Lost Woods after
            \\Saria's Song, in Hyrule Field (also on the way to Lake Hylia), in front of Hyrule Castle or at
            \\Zora's River. The quest menu and the amiibo menu item he unlocks are available anyway, the field
            \\music plays, and Castle Town works as if he had talked to you. His optional rides at Lake Hylia
            \\and Death Mountain are unchanged.
        ,
    },
    .{
        .key = .skip_opening,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Skip Opening Movie",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\A new game doesn't play the opening movie (the narrated prologue and the Great Deku Tree's dream).
            \\The game still waits for Kokiri Forest to load.
            \\Whatever this is set to, every seed starts outside in front of the Kokiri Shop, without Navi's
            \\flight, Navi waking Link or Saria at the door.
        ,
    },
    .{
        .key = .skip_deku_talk,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Skip the Great Deku Tree's Talk",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\The Great Deku Tree's speech when you first reach him doesn't play: his mouth is open and you can
            \\walk straight in. With Mido still blocking (Kokiri Forest not Open), this happens when Mido steps
            \\aside after seeing your sword and shield.
        ,
    },
    .{
        .key = .quick_chests,
        .tab = "Quality of Life",
        .group = "Cutscenes",
        .label = "Chests Without Cutscene",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Big chests open without the camera move and Link's opening animation: the lid opens, Link holds
            \\the item up and its message shows. The fanfare starts at once. Small chests keep
            \\their own short opening. The Kokiri Sword chest's sword scene is Skip Cutscenes.
        ,
    },
    .{
        .key = .bag_bombs_no_bracelet,
        .tab = "Quality of Life",
        .group = "Gameplay",
        .label = "Bag Bombs without Goron Bracelet",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Bombs from the bag can be pulled out and thrown as soon as you have a Bomb Bag. In the remake they
            \\normally need the Goron Bracelet, which the original always gave you first. Bomb Flowers still
            \\need the bracelet. Off: the logic expects the Goron Bracelet before bombs.
        ,
    },
    .{
        .key = .dodongo_bag_bombs,
        .tab = "Quality of Life",
        .group = "Gameplay",
        .label = "Bag Bombs Open Dodongo's Cavern",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\A bomb from your Bomb Bag breaks the boulder in front of Dodongo's Cavern when it explodes, like any
            \\bombable rock (no cutscene), so you don't need the Goron Bracelet to open it. The bomb flower still
            \\plays its cutscene.
            \\Off: only the bomb flower next to it works, which needs the bracelet.
        ,
    },
    .{
        .key = .gs_any_time,
        .tab = "Quality of Life",
        .group = "Gameplay",
        .label = "Gold Skulltulas Day and Night, Any Age",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\Night-only Gold Skulltulas are there in the daytime too, and the overworld Gold Skulltulas that
            \\only appear for adult Link (Kakariko, Death Mountain Trail, Zora's River and others) are there for
            \\child Link too, at the same spot; it's the same Skulltula, so it counts once. Not copied: the ones
            \\tied to another object (Lake Hylia, Zora's Domain) and Gerudo's Fortress (child can't go there).
            \\The logic doesn't count on this: it still expects night or adult Link for them.
        ,
    },
    .{
        .key = .skip_ganon_trials,
        .tab = "Quality of Life",
        .group = "Gameplay",
        .label = "Skip Ganon's Trials",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\The six trials inside Ganon's Castle count as done from the start: the barriers are gone and the
            \\way up the tower is open. The trial rooms and their chests are still there. The logic then only
            \\needs the rainbow bridge, the Bow and the Light Arrows to beat Ganon (the trial rooms' own
            \\checks still expect what the trials need).
        ,
    },
    .{
        .key = .saria_song_ocarina,
        .tab = "Quality of Life",
        .group = "Gameplay",
        .label = "Saria's Song With Just an Ocarina",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Saria teaches her song in Sacred Forest Meadow as soon as you own an ocarina (either one);
            \\you don't need to meet Zelda first. Works with any Kokiri Forest setting.
        ,
    },
    .{
        .key = .anju_one_cucco,
        .tab = "Quality of Life",
        .group = "Minigames & NPCs",
        .label = "Anju Needs Only 1 Cucco",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Return a single cucco to Anju's pen in Kakariko to finish her minigame and get the reward.
        ,
    },
    .{
        .key = .big_poe_one,
        .tab = "Quality of Life",
        .group = "Minigames & NPCs",
        .label = "Poe shop requires only 1 Big Poe (experimental)",
        .kind = .boolean,
        .default = .{ .boolean = false },
        .tip =
            \\Sell a single Big Poe to the ghost shop in the adult Market to get his reward (normally ten,
            \\1000 points), so your first sale is the last one. Not yet confirmed in-game.
        ,
    },
    .{
        .key = .excluded_locations,
        .tab = "Exclusions",
        .group = "Excluded",
        .label = "Excluded Locations",
        .kind = .list,
        .default = .{ .list = &.{} },
        .tip =
            \\Checks you exclude never hold anything you need: no progression items, keys or boss rewards,
            \\only rupees, ammo, hearts and the like (a map or compass may land there).
            \\A song or boss reward spot that can only hold a song or reward with your settings stays included
            \\(the log says which). Excluding a great many checks can leave too little room for the required
            \\items; generation then fails and says to exclude fewer.
        ,
    },
    .{
        .key = .create_spoiler,
        .tab = "ROM Options",
        .group = "Output",
        .label = "Create Spoiler Log",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Writes spoiler.txt and spoiler.json next to the mod: where every item is, the hints and the
            \\settings.
        ,
    },
    .{
        .key = .per_seed_saves,
        .tab = "ROM Options",
        .group = "Output",
        .label = "Per-Seed Saves",
        .kind = .boolean,
        .default = .{ .boolean = true },
        .tip =
            \\Each seed keeps its own save slots, in Longshot and in Switch emulators (Eden, Citron, Lichii and
            \\other yuzu-family emulators: set the output folder to the emulator's load/0400486024DEC000 folder).
            \\Generating a seed, or Play This Seed on the ROM Options tab, stores the slots you have now with their
            \\seed and brings in the new seed's (empty slots for a new one). Slots no seed owns are copied to
            \\save_backups first. The game's options are shared. Close the game before switching.
        ,
    },
};

pub const presets = [_]Preset{
    .{
        .name = "Beginner",
        .tip =
            \\A first randomizer: the world is open from the start (Kokiri Forest, Door of Time, Zora's Fountain,
            \\Death Mountain), child Zelda is skipped, songs stay at song spots and the stones and medallions where they
            \\normally are, the Kokiri Sword stays in its chest, no Gold Skulltula, shop or Business Scrub shuffle, every map
            \\and compass from the start, Strong hints that speak without the Mask of Truth, and every time saver on
            \\(Ganon's trials skipped, Gold Skulltulas day and night).
        ,
        .values = &.{
            .{ .key = .logic_rules, .value = .{ .choice = "glitchless" } },
            .{ .key = .reachable_locations, .value = .{ .choice = "all" } },
            .{ .key = .open_forest, .value = .{ .choice = "open" } },
            .{ .key = .open_door, .value = .{ .choice = "open" } },
            .{ .key = .open_zora, .value = .{ .choice = "open" } },
            .{ .key = .open_dmt, .value = .{ .boolean = true } },
            .{ .key = .rainbow_bridge, .value = .{ .choice = "vanilla" } },
            .{ .key = .bridge_medallions, .value = .{ .int = 6 } },
            .{ .key = .bridge_tokens, .value = .{ .int = 100 } },
            .{ .key = .skip_child_zelda, .value = .{ .boolean = true } },
            .{ .key = .skip_epona_race, .value = .{ .boolean = false } },
            .{ .key = .shuffle_songs, .value = .{ .choice = "song" } },
            .{ .key = .shuffle_rewards, .value = .{ .choice = "vanilla" } },
            .{ .key = .shuffle_ocarinas, .value = .{ .boolean = false } },
            .{ .key = .shuffle_kokiri_sword, .value = .{ .boolean = false } },
            .{ .key = .shuffle_weird_egg, .value = .{ .boolean = false } },
            .{ .key = .shuffle_freestanding, .value = .{ .boolean = true } },
            .{ .key = .shuffle_rupees, .value = .{ .boolean = false } },
            .{ .key = .shuffle_heart_containers, .value = .{ .boolean = true } },
            .{ .key = .shuffle_npc, .value = .{ .boolean = true } },
            .{ .key = .shuffle_quest, .value = .{ .boolean = true } },
            .{ .key = .shuffle_scrubs, .value = .{ .boolean = false } },
            .{ .key = .scrub_prices, .value = .{ .choice = "low" } },
            .{ .key = .shuffle_fairies, .value = .{ .boolean = true } },
            .{ .key = .shuffle_house, .value = .{ .boolean = true } },
            .{ .key = .tokensanity, .value = .{ .choice = "off" } },
            .{ .key = .shopsanity, .value = .{ .choice = "off" } },
            .{ .key = .shop_prices, .value = .{ .choice = "low" } },
            .{ .key = .item_pool, .value = .{ .choice = "balanced" } },
            .{ .key = .refill_needs_item, .value = .{ .boolean = true } },
            .{ .key = .maps_compasses, .value = .{ .choice = "start_with" } },
            .{ .key = .small_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .key_rings, .value = .{ .choice = "all" } },
            .{ .key = .key_ring_forest, .value = .{ .boolean = true } },
            .{ .key = .key_ring_fire, .value = .{ .boolean = true } },
            .{ .key = .key_ring_water, .value = .{ .boolean = true } },
            .{ .key = .key_ring_shadow, .value = .{ .boolean = true } },
            .{ .key = .key_ring_spirit, .value = .{ .boolean = true } },
            .{ .key = .key_ring_well, .value = .{ .boolean = true } },
            .{ .key = .key_ring_gtg, .value = .{ .boolean = true } },
            .{ .key = .key_ring_ganon, .value = .{ .boolean = true } },
            .{ .key = .boss_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .hint_distribution, .value = .{ .choice = "strong" } },
            .{ .key = .gossip_stones, .value = .{ .choice = "no_mask" } },
            .{ .key = .skip_cutscenes, .value = .{ .boolean = true } },
            .{ .key = .skip_story_scenes, .value = .{ .boolean = false } },
            .{ .key = .skip_area_intros, .value = .{ .boolean = false } },
            .{ .key = .skip_kaepora, .value = .{ .boolean = true } },
            .{ .key = .skip_opening, .value = .{ .boolean = true } },
            .{ .key = .skip_deku_talk, .value = .{ .boolean = true } },
            .{ .key = .quick_chests, .value = .{ .boolean = true } },
            .{ .key = .bag_bombs_no_bracelet, .value = .{ .boolean = true } },
            .{ .key = .dodongo_bag_bombs, .value = .{ .boolean = true } },
            .{ .key = .gs_any_time, .value = .{ .boolean = true } },
            .{ .key = .skip_ganon_trials, .value = .{ .boolean = true } },
            .{ .key = .saria_song_ocarina, .value = .{ .boolean = true } },
            .{ .key = .anju_one_cucco, .value = .{ .boolean = true } },
            .{ .key = .big_poe_one, .value = .{ .boolean = false } },
        },
    },
    .{
        .name = "Standard",
        .tip =
            \\The usual randomizer: the forest exit open (Mido still wants a sword and shield), the Door of Time open, Zora's Fountain and Death Mountain as in the game, child Zelda skipped, the stones and
            \\medallions shuffled among the dungeon bosses, the Kokiri Sword, Business Scrubs (game's prices), the dungeon Gold
            \\Skulltulas and 2 items per shop shuffled, maps and compasses in their own dungeon, Balanced hints (Mask of
            \\Truth needed), Ganon's trials skipped.
        ,
        .values = &.{
            .{ .key = .logic_rules, .value = .{ .choice = "glitchless" } },
            .{ .key = .reachable_locations, .value = .{ .choice = "all" } },
            .{ .key = .open_forest, .value = .{ .choice = "closed_deku" } },
            .{ .key = .open_door, .value = .{ .choice = "open" } },
            .{ .key = .open_zora, .value = .{ .choice = "closed" } },
            .{ .key = .open_dmt, .value = .{ .boolean = false } },
            .{ .key = .rainbow_bridge, .value = .{ .choice = "vanilla" } },
            .{ .key = .bridge_medallions, .value = .{ .int = 6 } },
            .{ .key = .bridge_tokens, .value = .{ .int = 100 } },
            .{ .key = .skip_child_zelda, .value = .{ .boolean = true } },
            .{ .key = .skip_epona_race, .value = .{ .boolean = false } },
            .{ .key = .shuffle_songs, .value = .{ .choice = "song" } },
            .{ .key = .shuffle_rewards, .value = .{ .choice = "reward" } },
            .{ .key = .shuffle_ocarinas, .value = .{ .boolean = false } },
            .{ .key = .shuffle_kokiri_sword, .value = .{ .boolean = true } },
            .{ .key = .shuffle_weird_egg, .value = .{ .boolean = false } },
            .{ .key = .shuffle_freestanding, .value = .{ .boolean = true } },
            .{ .key = .shuffle_rupees, .value = .{ .boolean = false } },
            .{ .key = .shuffle_heart_containers, .value = .{ .boolean = true } },
            .{ .key = .shuffle_npc, .value = .{ .boolean = true } },
            .{ .key = .shuffle_quest, .value = .{ .boolean = true } },
            .{ .key = .shuffle_scrubs, .value = .{ .boolean = true } },
            .{ .key = .scrub_prices, .value = .{ .choice = "regular" } },
            .{ .key = .shuffle_fairies, .value = .{ .boolean = true } },
            .{ .key = .shuffle_house, .value = .{ .boolean = true } },
            .{ .key = .tokensanity, .value = .{ .choice = "dungeons" } },
            .{ .key = .shopsanity, .value = .{ .choice = "2" } },
            .{ .key = .shop_prices, .value = .{ .choice = "random" } },
            .{ .key = .item_pool, .value = .{ .choice = "balanced" } },
            .{ .key = .refill_needs_item, .value = .{ .boolean = true } },
            .{ .key = .maps_compasses, .value = .{ .choice = "own" } },
            .{ .key = .small_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .key_rings, .value = .{ .choice = "all" } },
            .{ .key = .key_ring_forest, .value = .{ .boolean = true } },
            .{ .key = .key_ring_fire, .value = .{ .boolean = true } },
            .{ .key = .key_ring_water, .value = .{ .boolean = true } },
            .{ .key = .key_ring_shadow, .value = .{ .boolean = true } },
            .{ .key = .key_ring_spirit, .value = .{ .boolean = true } },
            .{ .key = .key_ring_well, .value = .{ .boolean = true } },
            .{ .key = .key_ring_gtg, .value = .{ .boolean = true } },
            .{ .key = .key_ring_ganon, .value = .{ .boolean = true } },
            .{ .key = .boss_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .hint_distribution, .value = .{ .choice = "balanced" } },
            .{ .key = .gossip_stones, .value = .{ .choice = "mask" } },
            .{ .key = .skip_cutscenes, .value = .{ .boolean = true } },
            .{ .key = .skip_story_scenes, .value = .{ .boolean = false } },
            .{ .key = .skip_area_intros, .value = .{ .boolean = false } },
            .{ .key = .skip_kaepora, .value = .{ .boolean = true } },
            .{ .key = .skip_opening, .value = .{ .boolean = true } },
            .{ .key = .skip_deku_talk, .value = .{ .boolean = true } },
            .{ .key = .quick_chests, .value = .{ .boolean = true } },
            .{ .key = .bag_bombs_no_bracelet, .value = .{ .boolean = true } },
            .{ .key = .dodongo_bag_bombs, .value = .{ .boolean = true } },
            .{ .key = .gs_any_time, .value = .{ .boolean = true } },
            .{ .key = .skip_ganon_trials, .value = .{ .boolean = true } },
            .{ .key = .saria_song_ocarina, .value = .{ .boolean = true } },
            .{ .key = .anju_one_cucco, .value = .{ .boolean = true } },
            .{ .key = .big_poe_one, .value = .{ .boolean = false } },
        },
    },
    .{
        .name = "Expert",
        .tip =
            \\For experienced players: everything closed as in the game (child Zelda too), the bridge needs all six
            \\medallions, songs and the stones and medallions anywhere, both ocarinas, the Weird Egg, freestanding rupees,
            \\every Gold Skulltula, 4 items per shop and Business Scrubs shuffled at random prices up to 200 rupees, maps and
            \\compasses where they are in the game, Balanced hints (Mask of Truth needed), and the game's own rules: bombs need
            \\the Goron Bracelet, Gold Skulltulas keep their time and age, Saria needs Zelda's visit, Anju wants all her
            \\Cuccos and Ganon's trials stay.
        ,
        .values = &.{
            .{ .key = .logic_rules, .value = .{ .choice = "glitchless" } },
            .{ .key = .reachable_locations, .value = .{ .choice = "all" } },
            .{ .key = .open_forest, .value = .{ .choice = "closed" } },
            .{ .key = .open_door, .value = .{ .choice = "closed" } },
            .{ .key = .open_zora, .value = .{ .choice = "closed" } },
            .{ .key = .open_dmt, .value = .{ .boolean = false } },
            .{ .key = .rainbow_bridge, .value = .{ .choice = "medallions" } },
            .{ .key = .bridge_medallions, .value = .{ .int = 6 } },
            .{ .key = .bridge_tokens, .value = .{ .int = 100 } },
            .{ .key = .skip_child_zelda, .value = .{ .boolean = false } },
            .{ .key = .skip_epona_race, .value = .{ .boolean = false } },
            .{ .key = .shuffle_songs, .value = .{ .choice = "anywhere" } },
            .{ .key = .shuffle_rewards, .value = .{ .choice = "anywhere" } },
            .{ .key = .shuffle_ocarinas, .value = .{ .boolean = true } },
            .{ .key = .shuffle_kokiri_sword, .value = .{ .boolean = true } },
            .{ .key = .shuffle_weird_egg, .value = .{ .boolean = true } },
            .{ .key = .shuffle_freestanding, .value = .{ .boolean = true } },
            .{ .key = .shuffle_rupees, .value = .{ .boolean = true } },
            .{ .key = .shuffle_heart_containers, .value = .{ .boolean = true } },
            .{ .key = .shuffle_npc, .value = .{ .boolean = true } },
            .{ .key = .shuffle_quest, .value = .{ .boolean = true } },
            .{ .key = .shuffle_scrubs, .value = .{ .boolean = true } },
            .{ .key = .scrub_prices, .value = .{ .choice = "random_wallet" } },
            .{ .key = .shuffle_fairies, .value = .{ .boolean = true } },
            .{ .key = .shuffle_house, .value = .{ .boolean = true } },
            .{ .key = .tokensanity, .value = .{ .choice = "all" } },
            .{ .key = .shopsanity, .value = .{ .choice = "4" } },
            .{ .key = .shop_prices, .value = .{ .choice = "random_wallet" } },
            .{ .key = .item_pool, .value = .{ .choice = "balanced" } },
            .{ .key = .refill_needs_item, .value = .{ .boolean = true } },
            .{ .key = .maps_compasses, .value = .{ .choice = "vanilla" } },
            .{ .key = .small_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .key_rings, .value = .{ .choice = "all" } },
            .{ .key = .key_ring_forest, .value = .{ .boolean = true } },
            .{ .key = .key_ring_fire, .value = .{ .boolean = true } },
            .{ .key = .key_ring_water, .value = .{ .boolean = true } },
            .{ .key = .key_ring_shadow, .value = .{ .boolean = true } },
            .{ .key = .key_ring_spirit, .value = .{ .boolean = true } },
            .{ .key = .key_ring_well, .value = .{ .boolean = true } },
            .{ .key = .key_ring_gtg, .value = .{ .boolean = true } },
            .{ .key = .key_ring_ganon, .value = .{ .boolean = true } },
            .{ .key = .boss_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .hint_distribution, .value = .{ .choice = "balanced" } },
            .{ .key = .gossip_stones, .value = .{ .choice = "mask" } },
            .{ .key = .skip_cutscenes, .value = .{ .boolean = true } },
            .{ .key = .skip_story_scenes, .value = .{ .boolean = false } },
            .{ .key = .skip_area_intros, .value = .{ .boolean = false } },
            .{ .key = .skip_kaepora, .value = .{ .boolean = true } },
            .{ .key = .skip_opening, .value = .{ .boolean = true } },
            .{ .key = .skip_deku_talk, .value = .{ .boolean = true } },
            .{ .key = .quick_chests, .value = .{ .boolean = true } },
            .{ .key = .bag_bombs_no_bracelet, .value = .{ .boolean = false } },
            .{ .key = .dodongo_bag_bombs, .value = .{ .boolean = false } },
            .{ .key = .gs_any_time, .value = .{ .boolean = false } },
            .{ .key = .skip_ganon_trials, .value = .{ .boolean = false } },
            .{ .key = .saria_song_ocarina, .value = .{ .boolean = false } },
            .{ .key = .anju_one_cucco, .value = .{ .boolean = false } },
            .{ .key = .big_poe_one, .value = .{ .boolean = false } },
        },
    },
    .{
        .name = "Race",
        .tip =
            \\For racing: built like the tournament settings of the classic randomizer, fair and fast for everyone.
            \\The forest exit open (Mido still wants a sword and shield), the Door of Time open, child Zelda skipped, the bridge needs 4
            \\medallions, the stones and medallions shuffled among the dungeon bosses, songs at song spots, no Gold Skulltula,
            \\shop or Business Scrub shuffle (fewer places to check), every map and compass from the start, Strong hints
            \\without the Mask of Truth, and every confirmed time saver on. Make one seed and share its settings string with
            \\the other racers (turn Create Spoiler Log off on the ROM Options tab if no one should see the spoiler).
        ,
        .values = &.{
            .{ .key = .logic_rules, .value = .{ .choice = "glitchless" } },
            .{ .key = .reachable_locations, .value = .{ .choice = "all" } },
            .{ .key = .open_forest, .value = .{ .choice = "closed_deku" } },
            .{ .key = .open_door, .value = .{ .choice = "open" } },
            .{ .key = .open_zora, .value = .{ .choice = "closed" } },
            .{ .key = .open_dmt, .value = .{ .boolean = false } },
            .{ .key = .rainbow_bridge, .value = .{ .choice = "medallions" } },
            .{ .key = .bridge_medallions, .value = .{ .int = 4 } },
            .{ .key = .bridge_tokens, .value = .{ .int = 100 } },
            .{ .key = .skip_child_zelda, .value = .{ .boolean = true } },
            .{ .key = .skip_epona_race, .value = .{ .boolean = false } },
            .{ .key = .shuffle_songs, .value = .{ .choice = "song" } },
            .{ .key = .shuffle_rewards, .value = .{ .choice = "reward" } },
            .{ .key = .shuffle_ocarinas, .value = .{ .boolean = false } },
            .{ .key = .shuffle_kokiri_sword, .value = .{ .boolean = true } },
            .{ .key = .shuffle_weird_egg, .value = .{ .boolean = false } },
            .{ .key = .shuffle_freestanding, .value = .{ .boolean = true } },
            .{ .key = .shuffle_rupees, .value = .{ .boolean = false } },
            .{ .key = .shuffle_heart_containers, .value = .{ .boolean = true } },
            .{ .key = .shuffle_npc, .value = .{ .boolean = true } },
            .{ .key = .shuffle_quest, .value = .{ .boolean = true } },
            .{ .key = .shuffle_scrubs, .value = .{ .boolean = false } },
            .{ .key = .scrub_prices, .value = .{ .choice = "low" } },
            .{ .key = .shuffle_fairies, .value = .{ .boolean = true } },
            .{ .key = .shuffle_house, .value = .{ .boolean = true } },
            .{ .key = .tokensanity, .value = .{ .choice = "off" } },
            .{ .key = .shopsanity, .value = .{ .choice = "off" } },
            .{ .key = .shop_prices, .value = .{ .choice = "low" } },
            .{ .key = .item_pool, .value = .{ .choice = "balanced" } },
            .{ .key = .refill_needs_item, .value = .{ .boolean = true } },
            .{ .key = .maps_compasses, .value = .{ .choice = "start_with" } },
            .{ .key = .small_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .key_rings, .value = .{ .choice = "all" } },
            .{ .key = .key_ring_forest, .value = .{ .boolean = true } },
            .{ .key = .key_ring_fire, .value = .{ .boolean = true } },
            .{ .key = .key_ring_water, .value = .{ .boolean = true } },
            .{ .key = .key_ring_shadow, .value = .{ .boolean = true } },
            .{ .key = .key_ring_spirit, .value = .{ .boolean = true } },
            .{ .key = .key_ring_well, .value = .{ .boolean = true } },
            .{ .key = .key_ring_gtg, .value = .{ .boolean = true } },
            .{ .key = .key_ring_ganon, .value = .{ .boolean = true } },
            .{ .key = .boss_keys, .value = .{ .choice = "vanilla" } },
            .{ .key = .hint_distribution, .value = .{ .choice = "strong" } },
            .{ .key = .gossip_stones, .value = .{ .choice = "no_mask" } },
            .{ .key = .skip_cutscenes, .value = .{ .boolean = true } },
            .{ .key = .skip_story_scenes, .value = .{ .boolean = false } },
            .{ .key = .skip_area_intros, .value = .{ .boolean = false } },
            .{ .key = .skip_kaepora, .value = .{ .boolean = true } },
            .{ .key = .skip_opening, .value = .{ .boolean = true } },
            .{ .key = .skip_deku_talk, .value = .{ .boolean = true } },
            .{ .key = .quick_chests, .value = .{ .boolean = true } },
            .{ .key = .bag_bombs_no_bracelet, .value = .{ .boolean = true } },
            .{ .key = .dodongo_bag_bombs, .value = .{ .boolean = true } },
            .{ .key = .gs_any_time, .value = .{ .boolean = true } },
            .{ .key = .skip_ganon_trials, .value = .{ .boolean = true } },
            .{ .key = .saria_song_ocarina, .value = .{ .boolean = true } },
            .{ .key = .anju_one_cucco, .value = .{ .boolean = true } },
            .{ .key = .big_poe_one, .value = .{ .boolean = false } },
        },
    },
};

pub const unsupported = [_]Unsupported{
    .{ .name = "Bunny Hood speed boost (Majora's Mask style)", .why = "Run speed comes from the animations; the only speed value in the data is a global scale. Masks have no movement parameter and the equipment effect list (e.g. UnderwaterBreathing) has no speed effect that can be confirmed." },
    .{ .name = "Fast climbing", .why = "Climb speed is computed by the player code and passed to the climb animation at runtime; no data file holds it." },
    .{ .name = "Cow Shuffle / Beans", .why = "Cows use one shared event; the bean seller isn't mapped yet." },
    .{ .name = "Shuffle the Gerudo Membership Card", .why = "The guards, the wasteland gate, the Training Ground and horseback archery check the carpenter rescue, not the card, so a card found elsewhere does nothing. It stays vanilla." },
    .{ .name = "Shuffle the adult trade items", .why = "All trade items share one slot and adult items take priority: an adult trade item found as a child hides the Cucco for good. Only Biggoron's reward is shuffled." },
    .{ .name = "Other capacity upgrades (Deku Seed bag from the Deku Tree)", .why = "Stays vanilla: the logic needs the Slingshot from its chest. The stick and nut upgrades are shuffled with Character Gifts and Minigames and Business Scrubs." },
    .{ .name = "Entrance Randomizer", .why = "Not supported." },
    .{ .name = "Ice Traps / Chest Appearance Matches Contents / Cosmetics", .why = "Not implemented." },
    .{ .name = "Master Quest dungeons", .why = "Not present in the remake." },
};
