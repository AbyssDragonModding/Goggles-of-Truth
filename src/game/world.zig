//! Scans the user's game files and builds the list of items and item locations.
//!
//! Nothing here is bundled game data: actor names, IDs, positions and English text are all read from the romfs the
//! user points the program at.

const std = @import("std");
const gamefiles = @import("gamefiles.zig");
const zstd = @import("../formats/zstd.zig");
const sarc = @import("../formats/sarc.zig");
const byml = @import("../formats/byml.zig");
const msbt = @import("../formats/msbt.zig");
const evfl_view = @import("../formats/evfl_view.zig");
const logic = @import("../logic/logic.zig");
const progressive = @import("../logic/progressive.zig");
const fsmod = @import("../core/fs.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const ItemId = logic.ItemId;

pub const WorldError = error{
    /// the game files could not be opened or read (the Progress failure message says why)
    GameFiles,
    /// a game file isn't as expected
    InvalidData,
    OutOfMemory,
};

pub const event_locations = @import("event_locations.zig").event_locations;

/// Dungeon stage folders and the age(s) Link visits them at.
pub const Dungeon = struct { name: []const u8, ages: Ages };
pub const dungeons = [_]Dungeon{
    .{ .name = "InsideTheDekuTree", .ages = .{ .child = true } },
    .{ .name = "DodongoCavern", .ages = .{ .child = true } },
    .{ .name = "InsideJabuJabuBelly", .ages = .{ .child = true } },
    .{ .name = "BottomOfTheWell", .ages = .{ .child = true } },
    .{ .name = "ForestTemple", .ages = .{ .adult = true } },
    .{ .name = "FireTemple", .ages = .{ .adult = true } },
    .{ .name = "WaterTemple", .ages = .{ .adult = true } },
    .{ .name = "ShadowTemple", .ages = .{ .adult = true } },
    .{ .name = "SpiritTemple", .ages = .{ .child = true, .adult = true } },
    .{ .name = "IceCavern", .ages = .{ .adult = true } },
    .{ .name = "GerudoTrainingGround", .ages = .{ .adult = true } },
    .{ .name = "InsideGanonCastle", .ages = .{ .adult = true } },
    .{ .name = "GanonCastle", .ages = .{ .adult = true } },
};

pub fn dungeonAges(folder: []const u8) ?Ages {
    for (dungeons) |d| if (std.mem.eql(u8, d.name, folder)) return d.ages;
    return null;
}

pub fn isDungeon(folder: []const u8) bool {
    return dungeonAges(folder) != null;
}

const skip_folders = [_][]const u8{ "BancBasedResource", "DreamWorld", "SageRoom" };

const item_prefixes = [_][]const u8{ "Item_", "Obj_", "TBox_", "Tbox_", "Weapon_", "Shop_", "Pouch_" };

/// Items that are never worth anything (rupees, refills, hearts, basic shields).
pub const junk = [_][]const u8{
    "Rupee_Green",          "Rupee_Blue",         "Rupee_Red",           "Rupee_Purple",          "Rupee_Gold",
    "Heart",                "MagicJar_Small",     "MagicJar_Large",      "ArrowBundle_Small",     "ArrowBundle_Medium",
    "ArrowBundle_Large",    "DekuNutBundle",      "DekuSeedBundle",      "BombBundle_Small",      "BombchuBundle_Small",
    "BombchuBundle_Medium", "BombchuBundle_Large", "DekuStickBundle_Small", "ScrubBusinessSeed",  "Shield_Deku",
    "Shield_Hylian",
};

pub fn isJunkName(name: []const u8) bool {
    for (junk) |j| if (std.mem.eql(u8, j, name)) return true;
    return false;
}

/// "TBox_Rupee_Red" / "Obj_Rupee_Red" -> "Rupee_Red"; "Item_Hookshot" -> "Hookshot".
pub fn canon(actor: []const u8) []const u8 {
    var name = actor;
    for (item_prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) {
            name = name[p.len..];
            break;
        }
    }
    if (std.mem.eql(u8, name, "GerudoValley_Heart_Piece")) return "Heart_Piece";
    return name;
}

// ----------------------------------------------------------------------------------------------- the item table

/// Every item key the seed uses, interned to a small id. The logic's `Item` enum comes first (its values are ids),
/// then every other key as it is first seen.
pub const ItemTable = struct {
    allocator: Allocator,
    names: std.ArrayList([]const u8),
    ids: std.StringHashMap(ItemId),

    const Self = @This();

    pub fn init(allocator: Allocator) error{OutOfMemory}!Self {
        var self = Self{ .allocator = allocator, .names = .empty, .ids = std.StringHashMap(ItemId).init(allocator) };
        for (std.meta.tags(logic.Item)) |item| _ = try self.intern(@tagName(item));
        return self;
    }

    /// The id of `name`, added when it is new (`name` is copied).
    pub fn intern(self: *Self, key: []const u8) error{OutOfMemory}!ItemId {
        if (self.ids.get(key)) |id| return id;
        const copy = try self.allocator.dupe(u8, key);
        const id: ItemId = @intCast(self.names.items.len);
        try self.names.append(self.allocator, copy);
        try self.ids.put(copy, id);
        return id;
    }

    pub fn lookup(self: *const Self, key: []const u8) ?ItemId {
        return self.ids.get(key);
    }

    pub fn name(self: *const Self, id: ItemId) []const u8 {
        return self.names.items[id];
    }

    pub fn count(self: *const Self) usize {
        return self.names.items.len;
    }

    /// True when item `id` is named `n`.
    pub fn is(self: *const Self, id: ItemId, n: []const u8) bool {
        return std.mem.eql(u8, self.name(id), n);
    }

    pub fn isJunk(self: *const Self, id: ItemId) bool {
        return isJunkName(self.name(id));
    }

    /// The dungeon of an own-dungeon item ("Dungeon_SmallKey@ForestTemple" -> "ForestTemple"), or null.
    pub fn dungeonOf(self: *const Self, id: ItemId) ?[]const u8 {
        const n = self.name(id);
        const at = std.mem.indexOfScalar(u8, n, '@') orelse return null;
        return n[at + 1 ..];
    }
};

// ------------------------------------------------------------------------------------------------- locations

pub const Ages = struct {
    child: bool = false,
    adult: bool = false,

    pub fn only(self: Ages, child: bool, adult: bool) bool {
        return self.child == child and self.adult == adult;
    }
};

pub const Kind = enum { chest, freestanding, heart_container, gs, rupee, event, shop };

pub const Category = enum {
    chest,
    freestanding,
    heart_container,
    gs,
    rupee,
    event,
    shop,
    song,
    reward,
    npc,
    fairy,
    house,
    quest,
    scrub,
    egg,
    ocarina,
};

/// An actor placement in a stage file.
pub const StageRef = struct {
    rel: []const u8,
    hash: u64,
};

/// The file offset of an item parameter in an event flow.
pub const EventRef = struct {
    rel: []const u8,
    offset: usize,
    /// the item is handed over by a call of the game's hand-over flows (a sub-flow: GetInEvent, GetPouchContent...),
    /// which creates the named actor in Link's hands; false for a silent add (AddOrRemovePouchContent)
    held_up: bool = false,
    /// the node only shows the item window of an item handed over just before (EventTriggerSetForGetWindow, a
    /// GetPouchContent<Display...> call): a progressive item there shows the highest tier the player now owns, not
    /// the next one (generator/progressive_flows.zig)
    shows_item_only: bool = false,
};

/// A Business Scrub's Price parameter.
pub const PriceRef = struct {
    rel: []const u8,
    offset: usize,
    price: i64,
};

pub const Location = struct {
    /// stable ID (survives regeneration)
    id: []const u8,
    /// readable name for the spoiler log and the exclusion list
    name: []const u8,
    /// Banc folder (logic region), or null for events
    region: ?[]const u8,
    /// dungeon folder, or null
    dungeon: ?[]const u8,
    kind: Kind,
    category: Category,
    ages: Ages,
    /// canonical item key (dungeon items get @Dungeon)
    vanilla: ItemId,
    vanilla_actor: []const u8,
    stage_refs: []const StageRef = &.{},
    event_refs: []const EventRef = &.{},
    presence: []const u8 = "",
    get_event: []const u8 = "",
    conditional: bool = false,
    room: ?i128 = null,
    /// explicit logic rule for events and special spots
    rule_key: ?logic.Special = null,
    /// an upgrade-giving location that may still be shuffled
    upgrade_ok: bool = false,
    price_refs: []const PriceRef = &.{},
    /// shop shelves: the shop's name
    shop: ?[]const u8 = null,
};

// -------------------------------------------------------------------------------------------- event specs

pub const NamedEvent = struct {
    event: []const u8,
    actor: []const u8,
    price: ?i64 = null,
};

pub const EventLocation = struct {
    name: []const u8,
    flows: []const []const u8,
    vanilla: []const u8,
    category: Category,
    rule: logic.Special,
    upgrade_ok: bool = false,
    via: ?[]const u8 = null,
    events: ?[]const NamedEvent = null,
};

/// The item parameters a gift event may hand its item over with.
const item_keys = [_][]const u8{ "ActorName", "ReveiveItem", "ReceiveItem", "TakenRewardActor", "DropActorName", "Actor" };

/// Sub-flows / actions that hand an item to the player (rando/world.py _GIFT_SUB).
fn isGiftSubFlow(name: []const u8) bool {
    const exact = [_][]const u8{ "Dm_SY_GetInEvent", "GetPouchContent", "GetInEvent_EggHatche", "Dm_SY_Get" };
    for (exact) |e| if (std.mem.eql(u8, e, name)) return true;
    const anywhere = [_][]const u8{ "HandOver_NpcToPlayer", "TakenReward", "GetInEvent", "MushiToriGame" };
    for (anywhere) |a| if (std.mem.indexOf(u8, name, a) != null) return true;
    return std.mem.endsWith(u8, name, "DiggingHoleTour_Demo");
}

// ---------------------------------------------------------------------------------------------- stage kinds

const StageKind = struct { kind: Kind, label: []const u8 };

/// What kind of item location an actor is (rando/world.py STAGE_KINDS), or null.
fn stageKind(g: []const u8) ?StageKind {
    if (std.mem.startsWith(u8, g, "Obj_TBox_GlassTruth")) return .{ .kind = .chest, .label = "Invisible Chest" };
    if (std.mem.startsWith(u8, g, "Obj_TBox_A_06")) return .{ .kind = .chest, .label = "Chest" };
    if (std.mem.startsWith(u8, g, "Obj_TBox_A_0") and g.len > 12 and std.mem.indexOfScalar(u8, "1235", g[12]) != null)
        return .{ .kind = .chest, .label = "Chest" };
    if (eqlAny(g, &.{ "Obj_Arrow_Fire", "Obj_Bottle_Letter" })) return .{ .kind = .freestanding, .label = "Freestanding" };
    if (std.mem.eql(u8, g, "Obj_Heart_Container")) return .{ .kind = .heart_container, .label = "Heart Container" };
    if (eqlAny(g, &.{ "Obj_Heart_Piece", "Obj_GerudoValley_Heart_Piece" })) return .{ .kind = .freestanding, .label = "Freestanding Heart Piece" };
    if (std.mem.eql(u8, g, "Obj_Dungeon_SmallKey")) return .{ .kind = .freestanding, .label = "Freestanding Small Key" };
    // green/blue/red/purple rupees lying in the world; each has its own save flag (Bool64bitKey), so an item placed
    // there is collected once. Silver rupees are puzzle pieces and stay vanilla.
    if (eqlAny(g, &.{ "Obj_Rupee_Green", "Obj_Rupee_Blue", "Obj_Rupee_Red", "Obj_Rupee_Purple" })) return .{ .kind = .rupee, .label = "Freestanding Rupee" };
    if (std.mem.eql(u8, g, "Enemy_Skulltula_Gold")) return .{ .kind = .gs, .label = "Gold Skulltula" };
    return null;
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// The three Deku Tree scrub-drop rupees appear inside the beaten scrub's flower; an item there can't be picked up
/// (0.4.2 report), so they stay vanilla.
const scrub_drop_flag = "Enemy_Scrub_Deku_ItemDrop";

fn specialRule(actor: []const u8) ?logic.Special {
    if (std.mem.eql(u8, actor, "Obj_Arrow_Fire")) return .fire_arrows;
    if (std.mem.eql(u8, actor, "Obj_Bottle_Letter")) return .rutos_letter;
    return null;
}

// --------------------------------------------------------------------------------------------------- shops
// Shops (OotrR's "items shuffled per shop"): every shelf placement (Shop_*, not masks, signs or swords) is a slot.
// A shuffled slot's placement gets a new Shop_Rando_<item> actor (pickups.zig) instead of its shelf, so a shelf
// type sold in several shops can be shuffled in one only. Shops are told apart by where their shelves stand: the
// Market holds the bazaar, the potion shop and the Bombchu shop, Kakariko the bazaar and the potion shop.

const shop_excluded_prefixes = [_][]const u8{ "Shop_Mask_", "Shop_Board_", "Shop_Item_Base", "Shop_Sword_" };
const shop_folders = [_][]const u8{ "KokiriForest", "GoronCity", "ZoraDomain", "Market", "KakarikoVillage" };
/// metres: the shelves of one shop stand within this of each other
const shop_radius: f64 = 6.0;
/// what a shuffled shelf adds to the item pool
pub const shop_slot_vanilla = "Rupee_Blue";

fn shopRule(folder: []const u8) logic.Special {
    if (std.mem.eql(u8, folder, "KokiriForest")) return .shop_kokiri;
    if (std.mem.eql(u8, folder, "GoronCity")) return .shop_goron;
    if (std.mem.eql(u8, folder, "ZoraDomain")) return .shop_zora;
    if (std.mem.eql(u8, folder, "Market")) return .shop_market;
    return .shop_kakariko;
}

fn townName(folder: []const u8) []const u8 {
    if (std.mem.eql(u8, folder, "Market")) return "Market";
    if (std.mem.eql(u8, folder, "KakarikoVillage")) return "Kakariko";
    return folder;
}

const ShelfCondition = struct {
    flag: []const u8,
    negated: bool,
};

const Shelf = struct {
    folder: []const u8,
    actor: []const u8,
    rel: []const u8,
    hash: u64,
    index: i128,
    condition: ?ShelfCondition,
    pos: [3]f64,
};

// -------------------------------------------------------------------------------------------------- helpers

/// Python's round() of a float: to nearest, ties to even.
fn roundHalfEven(x: f64) f64 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) {
        // a tie: take the even neighbour
        const lower = @floor(x);
        return if (@mod(lower, 2) == 0) lower else lower + 1;
    }
    return r;
}

fn round2(x: f64) f64 {
    return roundHalfEven(x * 100) / 100;
}

fn translateOf(a: *byml.Dict) [3]f64 {
    var out = [3]f64{ 0, 0, 0 };
    const list = a.getArray("Translate") orelse return out;
    for (list.items.items, 0..) |v, i| {
        if (i >= 3) break;
        out[i] = v.asFloat() orelse 0;
    }
    return out;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ----------------------------------------------------------------------------------------------- the world

pub const World = struct {
    /// owns every string, list and location of the world
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    fs: fsmod.Fs,
    files: *gamefiles.GameFiles,
    zs: zstd.Context,
    items: ItemTable,
    actor_packs: std.StringHashMap(void),
    pouch_rows: std.StringHashMap(void),
    item_text: std.StringHashMap([]const u8),
    region_text: std.StringHashMap([]const u8),
    locations: std.ArrayList(Location),
    /// shop slots that may be missing under a story condition the logic doesn't know (never shuffled)
    shop_conditional: std.StringHashMap(void),
    shelves: std.ArrayList(Shelf),
    /// save-data probes (gamedata.zig), filled on first use
    probe: ?*anyopaque = null,
    probe_deinit: ?*const fn (*anyopaque) void = null,

    const Self = @This();

    /// Opens the game and scans it. `progress` gets what is being scanned and, on failure, why.
    pub fn init(gpa: Allocator, fs: fsmod.Fs, game_path: []const u8, progress: *Progress) WorldError!*Self {
        const files = gamefiles.GameFiles.open(gpa, fs, game_path, progress) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GameFiles,
        };
        errdefer files.deinit();

        const self = gpa.create(Self) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);
        self.* = Self{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
            .fs = fs,
            .files = files,
            .zs = undefined,
            .items = undefined,
            .actor_packs = undefined,
            .pouch_rows = undefined,
            .item_text = undefined,
            .region_text = undefined,
            .locations = .empty,
            .shop_conditional = undefined,
            .shelves = .empty,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.items = ItemTable.init(a) catch return error.OutOfMemory;
        self.actor_packs = std.StringHashMap(void).init(a);
        self.pouch_rows = std.StringHashMap(void).init(a);
        self.item_text = std.StringHashMap([]const u8).init(a);
        self.region_text = std.StringHashMap([]const u8).init(a);
        self.shop_conditional = std.StringHashMap(void).init(a);

        const dic = files.read(gpa, "Pack/ZsDic.pack.zs") catch
            return progress.fail(error.GameFiles, "Pack/ZsDic.pack.zs couldn't be read from {s}.", .{files.path});
        defer gpa.free(dic);
        self.zs = zstd.Context.init(gpa, dic) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return progress.fail(error.InvalidData, "Pack/ZsDic.pack.zs is not as expected.", .{}),
        };
        errdefer self.zs.deinit();

        try self.scanActorPacks(progress);
        try self.loadPouch(progress);
        self.loadText(progress);
        try self.scanStages(progress);
        try self.scanEvents(progress);
        try self.scanShops();
        try self.internConstants();

        // why: placements and patches find locations by id
        var seen = std.StringHashMap(void).init(gpa);
        defer seen.deinit();
        for (self.locations.items) |l| {
            const slot = seen.getOrPut(l.id) catch return error.OutOfMemory;
            if (slot.found_existing) return progress.fail(error.InvalidData, "duplicate location id {s}", .{l.id});
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.probe_deinit) |f| f(self.probe.?);
        self.zs.deinit();
        self.files.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// The decompressed bytes of a .zs file and its dictionary name. Allocated with `allocator`.
    pub fn readZs(self: *Self, allocator: Allocator, rel: []const u8) WorldError!zstd.Context.Decompressed {
        const raw = self.files.read(allocator, rel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GameFiles,
        };
        defer allocator.free(raw);
        return self.zs.decompress(allocator, raw) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidData,
        };
    }

    /// "folder/name" of the first file in `folder` starting with `prefix`.
    pub fn find(self: *Self, allocator: Allocator, folder: []const u8, prefix: []const u8) WorldError![]const u8 {
        return self.files.find(allocator, folder, prefix) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.GameFiles,
        };
    }

    pub fn regionName(self: *const Self, folder: []const u8) []const u8 {
        return self.region_text.get(folder) orelse folder;
    }

    /// The English name of item key `key` ("Dungeon_SmallKey@ForestTemple" -> "Small Key (Forest Temple)").
    pub fn itemName(self: *const Self, allocator: Allocator, key: []const u8) error{OutOfMemory}![]const u8 {
        // the key rings and dungeon boss keys are made by the generator: the game has no name for them
        if (logic.keyItemOf(key)) |k| {
            const d = logic.key_dungeons[k.dungeon];
            return std.fmt.allocPrint(allocator, "{s} ({s})", .{ if (k.ring) "Key Ring" else "Boss Key", d.name });
        }
        // a progressive item is the generator's too: which tier it gives depends on what the player owns
        if (progressive.chainOfProgressiveItem(key)) |chain| return allocator.dupe(u8, chain.display_name);
        const at = std.mem.indexOfScalar(u8, key, '@');
        const base = if (at) |i| key[0..i] else key;
        const prefixes = [_][]const u8{ "Item_", "Obj_", "Weapon_", "TBox_", "Shop_", "Armor_", "Armor_Adult_", "Armor_Child_" };
        var text: ?[]const u8 = null;
        var buf: [256]u8 = undefined;
        for (prefixes) |p| {
            const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ p, base }) catch continue;
            if (self.item_text.get(full)) |t| {
                if (t.len > 0) {
                    text = t;
                    break;
                }
            }
        }
        const plain = text orelse blk: {
            const copy = try allocator.dupe(u8, base);
            std.mem.replaceScalar(u8, copy, '_', ' ');
            break :blk copy;
        };
        if (at) |i| return std.fmt.allocPrint(allocator, "{s} ({s})", .{ plain, self.regionName(key[i + 1 ..]) });
        return plain;
    }

    pub fn itemNameById(self: *const Self, allocator: Allocator, id: ItemId) error{OutOfMemory}![]const u8 {
        return self.itemName(allocator, self.items.name(id));
    }

    pub fn actorExists(self: *const Self, name: []const u8) bool {
        return self.actor_packs.contains(name);
    }

    pub const Context = enum { chest, event, world };

    /// Items whose Item_ actor is equipment Link wears; a chest shows their Pouch_ actor instead (actorFor).
    const equipment_shown_by_pouch_actor = [_][]const u8{ "Ocarina_Fairy", "Ocarina_Time" };

    /// The item key's base ("Ocarina_Time") when its Item_ actor is equipment Link wears, which can't be held up
    /// (equipment_shown_by_pouch_actor); null for every other item.
    pub fn wornEquipmentBase(key: []const u8) ?[]const u8 {
        const base = if (std.mem.indexOfScalar(u8, key, '@')) |i| key[0..i] else key;
        return if (isListed(&equipment_shown_by_pouch_actor, base)) base else null;
    }

    fn isListed(list: []const []const u8, name: []const u8) bool {
        for (list) |entry| if (std.mem.eql(u8, entry, name)) return true;
        return false;
    }

    /// The actor to write for item `key` in a placement context ("Hookshot" -> "Item_Hookshot"), or null when the
    /// game has none. Allocated with `allocator`.
    pub fn actorFor(self: *const Self, allocator: Allocator, key: []const u8, context: Context) error{OutOfMemory}!?[]const u8 {
        // a key ring or dungeon boss key: the actor the generator makes for it (keyitems.zig), in every context
        if (logic.keyItemOf(key) != null) return try std.fmt.allocPrint(allocator, "Item_{s}", .{key});
        // a progressive item: its first tier's actor. Why: that is the model a gift shows and what a location that
        // can't branch would give; the hand-overs that branch pick each tier's own actor (generator/patches.zig)
        if (progressive.chainOfProgressiveItem(key)) |chain| return self.actorFor(allocator, chain.tiers[0].key, context);
        const base = if (std.mem.indexOfScalar(u8, key, '@')) |i| key[0..i] else key;
        // why: the Ocarinas' Item_ actors are the equipment Link wears (accessory, equipment death and blackboard, no
        // item-get animation set), so held up out of a chest they were invisible. Their Pouch_ actors are the shown
        // item: the same model with the item-get set, and named Item_Ocarina_* so the same item is given (dump:
        // Pack/Actor/Pouch_Ocarina_*.pack). Only chests: a shop shelf's sold flag is named after its actor.
        if (context == .chest and isListed(&equipment_shown_by_pouch_actor, base)) {
            var pouch_buf: [256]u8 = undefined;
            const pouch_actor = std.fmt.bufPrint(&pouch_buf, "Pouch_{s}", .{base}) catch base;
            if (self.actorExists(pouch_actor)) return try allocator.dupe(u8, pouch_actor);
        }
        const order: []const []const u8 = switch (context) {
            .chest => &.{ "TBox_", "Item_", "Obj_", "Tbox_", "Weapon_" },
            .event => &.{ "Item_", "Obj_", "Weapon_", "TBox_" },
            .world => &.{ "Obj_", "Item_", "TBox_", "Weapon_" },
        };
        var buf: [256]u8 = undefined;
        // an actor with a PouchActorInfo row first (a real item), then any actor of that name
        for (order) |p| {
            const n = std.fmt.bufPrint(&buf, "{s}{s}", .{ p, base }) catch continue;
            if (self.pouch_rows.contains(n) and self.actorExists(n)) return try allocator.dupe(u8, n);
        }
        for (order) |p| {
            const n = std.fmt.bufPrint(&buf, "{s}{s}", .{ p, base }) catch continue;
            if (self.actorExists(n)) return try allocator.dupe(u8, n);
        }
        return null;
    }

    pub fn actorForId(self: *const Self, allocator: Allocator, id: ItemId, context: Context) error{OutOfMemory}!?[]const u8 {
        return self.actorFor(allocator, self.items.name(id), context);
    }

    /// Items the randomizer hands out as another item than the one the logic and the spoiler log name: the Weird
    /// Egg as the Cucco that hatches from it. Why: the egg only hatches at one moment of the Hyrule Castle quest
    /// (Goto_HyruleCastle:Step03_01_Npc_Navi_StepStart runs :EggHatch, which swaps Item_WeirdEgg for
    /// Item_AlarmCucco), so an egg found after that moment never hatched (test report, seed FBRZU9NLY4: the egg at
    /// King Dodongo). Handing out the hatched Cucco straight away is what the egg would have become; Talon wakes up
    /// when the Cucco is used near him, whatever the quest's step. Malon's own egg, when her check isn't shuffled,
    /// is the game's and still hatches as usual.
    const handed_out_as = [_]struct { item: []const u8, given: []const u8 }{
        .{ .item = "WeirdEgg", .given = "AlarmCucco" },
    };

    /// The actor the randomizer writes to hand item `id` out in a placement context: actorForId, but for an item
    /// of handed_out_as, the actor of what it is given as. Only for writing patches: the fill and the logic go on
    /// using the item itself, so placements don't change.
    pub fn handedOutActorForId(self: *const Self, allocator: Allocator, id: ItemId, context: Context) error{OutOfMemory}!?[]const u8 {
        const key = self.items.name(id);
        for (handed_out_as) |entry| {
            if (!std.mem.eql(u8, entry.item, key)) continue;
            if (try self.actorFor(allocator, entry.given, context)) |given_actor| return given_actor;
        }
        return self.actorFor(allocator, key, context);
    }

    pub fn location(self: *Self, id: []const u8) ?*Location {
        for (self.locations.items) |*l| if (std.mem.eql(u8, l.id, id)) return l;
        return null;
    }

    // ------------------------------------------------------------------------------------------- scanning

    fn scanActorPacks(self: *Self, progress: *Progress) WorldError!void {
        const a = self.arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const names = self.files.listDir(tmp.allocator(), "Pack/Actor") catch
            return progress.fail(error.GameFiles, "Pack/Actor couldn't be listed in {s}.", .{self.files.path});
        for (names) |n| {
            if (!std.mem.endsWith(u8, n, ".pack.zs")) continue;
            const actor = a.dupe(u8, n[0 .. n.len - ".pack.zs".len]) catch return error.OutOfMemory;
            self.actor_packs.put(actor, {}) catch return error.OutOfMemory;
        }
    }

    fn loadPouch(self: *Self, progress: *Progress) WorldError!void {
        const a = self.arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const t = tmp.allocator();
        const preferred = "RSDB/PouchActorInfo.Product.111.rstbl.byml.zs";
        const rel = if (self.files.exists(preferred)) preferred else try self.find(t, "RSDB", "PouchActorInfo");
        const d = self.readZs(t, rel) catch return progress.fail(error.InvalidData, "{s} couldn't be read.", .{rel});
        const doc = byml.load(t, d.data) catch return progress.fail(error.InvalidData, "{s} is not as expected.", .{rel});
        const rows = (doc.root orelse return error.InvalidData).asArray() orelse return error.InvalidData;
        for (rows.items.items) |row| {
            const r = row.asDict() orelse continue;
            const id = r.getString("__RowId") orelse continue;
            self.pouch_rows.put(a.dupe(u8, id) catch return error.OutOfMemory, {}) catch return error.OutOfMemory;
        }
    }

    /// English item and region names (cosmetic: a failure only logs a warning).
    fn loadText(self: *Self, progress: *Progress) void {
        self.loadTextOrFail() catch |err| progress.log("warning: could not read English text ({s})", .{@errorName(err)});
    }

    fn loadTextOrFail(self: *Self) WorldError!void {
        const a = self.arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const t = tmp.allocator();
        const mals = try self.find(t, "Mals", "USen");
        const d = try self.readZs(t, mals);
        // the archive's bytes are kept: the parsed texts point into them
        const archive = a.dupe(u8, d.data) catch return error.OutOfMemory;
        const pouch = (sarc.find(t, archive, "ActorMsg/PouchContent.msbt") catch return error.InvalidData) orelse return error.InvalidData;
        var names = msbt.parse(a, pouch.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidData,
        };
        var it = names.iterator();
        while (it.next()) |e| {
            const label = e.key_ptr.*;
            if (!std.mem.endsWith(u8, label, "_Name")) continue;
            // collapse runs of whitespace (names can hold line breaks)
            var collapsed: std.ArrayList(u8) = .empty;
            var space = false;
            for (e.value_ptr.*) |c| {
                if (std.ascii.isWhitespace(c)) {
                    if (!space) collapsed.append(a, ' ') catch return error.OutOfMemory;
                    space = true;
                } else {
                    collapsed.append(a, c) catch return error.OutOfMemory;
                    space = false;
                }
            }
            self.item_text.put(label[0 .. label.len - 5], collapsed.items) catch return error.OutOfMemory;
        }
        const location_msg = (sarc.find(t, archive, "LocationMsg/Location.msbt") catch return error.InvalidData) orelse return error.InvalidData;
        self.region_text = msbt.parse(a, location_msg.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidData,
        };
    }

    const Merged = struct {
        region: []const u8,
        hash: u64,
        kind: Kind,
        label: []const u8,
        actor: []const u8,
        vanilla_actor: []const u8,
        ages: Ages,
        refs: std.ArrayList(StageRef),
        presence: []const u8,
        get_event: []const u8,
        conditional: bool,
        pos: [3]f64,
        room: ?i128,
        skip: bool = false,
    };

    fn lessMerged(_: void, x: *Merged, y: *Merged) bool {
        switch (std.mem.order(u8, x.region, y.region)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, @tagName(x.kind), @tagName(y.kind))) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        const xr = x.room orelse 0;
        const yr = y.room orelse 0;
        if (xr != yr) return xr < yr;
        for (x.pos, y.pos) |p, q| if (p != q) return p < q;
        return false;
    }

    fn scanStages(self: *Self, progress: *Progress) WorldError!void {
        const a = self.arena.allocator();
        var keep = std.heap.ArenaAllocator.init(self.gpa);
        defer keep.deinit();
        const k = keep.allocator();
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();

        var merged = std.AutoHashMap(u64, std.ArrayList(*Merged)).init(k);
        var all: std.ArrayList(*Merged) = .empty;

        const banc = self.files.listDir(k, "Banc") catch return progress.fail(error.GameFiles, "Banc couldn't be listed.", .{});
        var folders: std.ArrayList([]const u8) = .empty;
        for (banc) |f| {
            if (eqlAny(f, &skip_folders)) continue;
            const sub = std.fmt.allocPrint(k, "Banc/{s}", .{f}) catch return error.OutOfMemory;
            if (self.files.isDir(sub)) folders.append(k, f) catch return error.OutOfMemory;
        }

        for (folders.items, 0..) |folder, fi| {
            progress.log("Scanning stages: {s} ({d}/{d})", .{ folder, fi + 1, folders.items.len });
            const sub = std.fmt.allocPrint(k, "Banc/{s}", .{folder}) catch return error.OutOfMemory;
            const names = self.files.listDir(k, sub) catch return error.GameFiles;
            const folder_copy = a.dupe(u8, folder) catch return error.OutOfMemory;
            for (names) |fname| {
                if (!std.mem.endsWith(u8, fname, ".bcett.byml.zs") or std.mem.startsWith(u8, fname, "Demo_")) continue;
                _ = tmp.reset(.retain_capacity);
                const t = tmp.allocator();
                const rel = std.fmt.allocPrint(a, "Banc/{s}/{s}", .{ folder, fname }) catch return error.OutOfMemory;

                var ages = Ages{};
                if (dungeonAges(folder)) |d| {
                    ages = d;
                } else if (std.mem.indexOf(u8, fname, "_Adult") != null and !hasEarlierChild(fname)) {
                    ages.adult = true;
                } else if (std.mem.indexOf(u8, fname, "_Child") != null) {
                    ages.child = true;
                } else {
                    ages = .{ .child = true, .adult = true };
                }

                const d = self.readZs(t, rel) catch return progress.fail(error.InvalidData, "{s} couldn't be read.", .{rel});
                const root = byml.loadDict(t, d.data) catch return progress.fail(error.InvalidData, "{s} is not as expected.", .{rel});
                const actors = root.getArray("Actors") orelse continue;
                for (actors.items.items) |actor_value| {
                    const actor = actor_value.asDict() orelse continue;
                    const g = actor.getString("Gyaml") orelse continue;
                    const h: u64 = @truncate(@as(u128, @bitCast(actor.getInt("Hash") orelse 0)));
                    const dyn = actor.getDict("Dynamic");
                    const presence = actor.getDict("Presence");

                    if (std.mem.startsWith(u8, g, "Shop_") and eqlAny(folder, &shop_folders) and !startsWithAny(g, &shop_excluded_prefixes)) {
                        var condition: ?ShelfCondition = null;
                        if (presence) |p| {
                            condition = ShelfCondition{
                                .flag = a.dupe(u8, p.getString("FlagName") orelse "") catch return error.OutOfMemory,
                                .negated = if (p.get("IsNegation")) |v| v.isTruthy() else false,
                            };
                        }
                        self.shelves.append(a, Shelf{
                            .folder = folder_copy,
                            .actor = a.dupe(u8, g) catch return error.OutOfMemory,
                            .rel = rel,
                            .hash = h,
                            .index = if (dyn) |dd| dd.getInt("ShopItemIndex") orelse 0 else 0,
                            .condition = condition,
                            .pos = translateOf(actor),
                        }) catch return error.OutOfMemory;
                    }

                    const sk = stageKind(g) orelse continue;
                    const flag_name = if (presence) |p| p.getString("FlagName") orelse "" else "";
                    if (sk.kind == .rupee and std.mem.startsWith(u8, flag_name, scrub_drop_flag)) continue;

                    const vanilla_actor: []const u8 = switch (sk.kind) {
                        .chest => blk: {
                            const drop = if (dyn) |dd| dd.getString("Drop__DropActor") orelse "" else "";
                            break :blk if (drop.len > 0) drop else "Obj_Rupee_Green";
                        },
                        .gs => "Obj_Token_Gold",
                        else => g,
                    };

                    // one location per (folder, hash): the same placement in the child and adult files is one spot
                    const slot = merged.getOrPut(h) catch return error.OutOfMemory;
                    if (!slot.found_existing) slot.value_ptr.* = .empty;
                    var loc: ?*Merged = null;
                    for (slot.value_ptr.items) |m| {
                        if (std.mem.eql(u8, m.region, folder_copy)) loc = m;
                    }
                    if (loc == null) {
                        const pos = translateOf(actor);
                        const m = k.create(Merged) catch return error.OutOfMemory;
                        const get_event = if (dyn) |dd| dd.getString("GetEventName") orelse "" else "";
                        m.* = Merged{
                            .region = folder_copy,
                            .hash = h,
                            .kind = sk.kind,
                            .label = sk.label,
                            .actor = a.dupe(u8, g) catch return error.OutOfMemory,
                            .vanilla_actor = a.dupe(u8, vanilla_actor) catch return error.OutOfMemory,
                            .ages = .{},
                            .refs = .empty,
                            .presence = a.dupe(u8, flag_name) catch return error.OutOfMemory,
                            .get_event = a.dupe(u8, get_event) catch return error.OutOfMemory,
                            .conditional = if (dyn) |dd| dd.contains("Drop__CheckActor") else false,
                            .pos = .{ round2(pos[0]), round2(pos[1]), round2(pos[2]) },
                            .room = if (dyn) |dd| dd.getInt("DefaultDungeonRoomIndex") else null,
                        };
                        slot.value_ptr.append(k, m) catch return error.OutOfMemory;
                        all.append(k, m) catch return error.OutOfMemory;
                        loc = m;
                    }
                    const m = loc.?;
                    m.ages.child = m.ages.child or ages.child;
                    m.ages.adult = m.ages.adult or ages.adult;
                    m.refs.append(a, StageRef{ .rel = rel, .hash = h }) catch return error.OutOfMemory;
                }
            }
        }

        // stacked minigame prize chests (e.g. the Dampe race goal): keep only the non-junk members
        for (all.items, 0..) |x, i| {
            if (x.kind != .chest) continue;
            var stacked = false;
            for (all.items, 0..) |y, j| {
                if (i == j or y.kind != .chest or !std.mem.eql(u8, x.region, y.region)) continue;
                if (sameRoundedPos(x.pos, y.pos)) stacked = true;
            }
            if (stacked and isJunkName(canon(x.vanilla_actor))) x.skip = true;
        }

        std.mem.sort(*Merged, all.items, {}, lessMerged);
        var counters = std.StringHashMap(usize).init(k);
        for (all.items) |m| {
            if (m.skip) continue;
            const dungeon: ?[]const u8 = if (isDungeon(m.region)) m.region else null;
            const van_name = canon(m.vanilla_actor);
            const van = if (std.mem.startsWith(u8, van_name, "Dungeon_") and dungeon != null)
                std.fmt.allocPrint(k, "{s}@{s}", .{ van_name, dungeon.? }) catch return error.OutOfMemory
            else
                van_name;
            const counter_key = std.fmt.allocPrint(k, "{s}|{s}", .{ m.region, m.label }) catch return error.OutOfMemory;
            const counter = counters.getOrPut(counter_key) catch return error.OutOfMemory;
            if (!counter.found_existing) counter.value_ptr.* = 0;
            counter.value_ptr.* += 1;
            const room_text = if (m.room) |r| std.fmt.allocPrint(k, " (room {d})", .{r}) catch return error.OutOfMemory else "";
            const name = std.fmt.allocPrint(a, "{s} {s} {d}{s}", .{ self.regionName(m.region), m.label, counter.value_ptr.*, room_text }) catch return error.OutOfMemory;
            const id = std.fmt.allocPrint(a, "stage:{s}:{d}", .{ m.region, m.hash }) catch return error.OutOfMemory;
            self.locations.append(a, Location{
                .id = id,
                .name = name,
                .region = m.region,
                .dungeon = dungeon,
                .kind = m.kind,
                .category = kindCategory(m.kind),
                .ages = m.ages,
                .vanilla = try self.items.intern(van),
                .vanilla_actor = m.vanilla_actor,
                .stage_refs = m.refs.items,
                .presence = m.presence,
                .get_event = m.get_event,
                .conditional = m.conditional,
                .room = m.room,
                .rule_key = specialRule(m.actor),
            }) catch return error.OutOfMemory;
        }
    }

    fn scanEvents(self: *Self, progress: *Progress) WorldError!void {
        const a = self.arena.allocator();
        var cache_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer cache_arena.deinit();
        const c = cache_arena.allocator();
        var cache = std.StringHashMap(*evfl_view.View).init(c);

        for (event_locations) |spec| {
            progress.log("Scanning events: {s}", .{spec.name});
            var refs: std.ArrayList(EventRef) = .empty;
            var price_refs: std.ArrayList(PriceRef) = .empty;
            for (spec.flows) |flow| {
                for ([_][]const u8{ "", ".110" }) |suffix| {
                    const rel = std.fmt.allocPrint(a, "Event/EventFlow/{s}{s}.bfevfl.zs", .{ flow, suffix }) catch return error.OutOfMemory;
                    if (!self.files.exists(rel)) continue;
                    const view = cache.get(rel) orelse blk: {
                        const d = self.readZs(c, rel) catch return progress.fail(error.InvalidData, "{s} couldn't be read.", .{rel});
                        const v = c.create(evfl_view.View) catch return error.OutOfMemory;
                        v.* = evfl_view.View.init(c, d.data) catch return progress.fail(error.InvalidData, "{s} is not as expected.", .{rel});
                        cache.put(rel, v) catch return error.OutOfMemory;
                        break :blk v;
                    };
                    if (spec.events) |named| {
                        const found = (try namedGiftNodes(c, view, named)) orelse {
                            // the .110 update may drop an event: only the base file counts
                            if (suffix.len > 0) continue;
                            refs.clearRetainingCapacity();
                            price_refs.clearRetainingCapacity();
                            break;
                        };
                        for (found) |f| {
                            refs.append(a, EventRef{ .rel = rel, .offset = f.item_offset, .held_up = f.held_up, .shows_item_only = f.shows_item_only }) catch return error.OutOfMemory;
                            if (f.price_offset) |po| {
                                price_refs.append(a, PriceRef{ .rel = rel, .offset = po, .price = f.price }) catch return error.OutOfMemory;
                            }
                        }
                        continue;
                    }
                    const nodes = try giftNodes(c, view, spec.vanilla, spec.via);
                    for (nodes) |n| refs.append(a, EventRef{ .rel = rel, .offset = n.offset, .held_up = n.held_up, .shows_item_only = n.shows_item_only }) catch return error.OutOfMemory;
                }
            }
            if (refs.items.len == 0) {
                progress.log("warning: event location '{s}' not found; skipped", .{spec.name});
                continue;
            }
            self.locations.append(a, Location{
                .id = std.fmt.allocPrint(a, "event:{s}", .{spec.name}) catch return error.OutOfMemory,
                .name = spec.name,
                .region = null,
                .dungeon = null,
                .kind = .event,
                .category = spec.category,
                .ages = .{},
                .vanilla = try self.items.intern(canon(spec.vanilla)),
                .vanilla_actor = spec.vanilla,
                .event_refs = refs.items,
                .rule_key = spec.rule,
                .upgrade_ok = spec.upgrade_ok,
                .price_refs = price_refs.items,
            }) catch return error.OutOfMemory;
        }
    }

    const NamedFound = struct {
        item_offset: usize,
        held_up: bool,
        shows_item_only: bool,
        price_offset: ?usize,
        price: i64,
    };

    /// The item field offsets (and Price offsets) of the named events, or null when one is missing or doesn't hand
    /// over its expected item.
    fn namedGiftNodes(allocator: Allocator, view: *const evfl_view.View, named: []const NamedEvent) WorldError!?[]NamedFound {
        var out: std.ArrayList(NamedFound) = .empty;
        for (named) |spec| {
            // the last event of that name (over every flowchart) wins, as a Python dict built in order did
            var event: ?*const evfl_view.Event = null;
            for (view.flowcharts) |fc| {
                for (fc.events) |*e| if (std.mem.eql(u8, e.name, spec.event)) {
                    event = e;
                };
            }
            const e = event orelse return null;
            const p = e.params orelse return null;
            var found_key: ?usize = null;
            var hits: usize = 0;
            for (item_keys) |key| {
                if (p.isString(key, spec.actor)) {
                    if (p.stringOffset(key)) |off| {
                        found_key = off;
                        hits += 1;
                    }
                }
            }
            if (hits != 1) return null;
            var found = NamedFound{ .item_offset = found_key.?, .held_up = e.type == .sub_flow, .shows_item_only = showsItemOnly(e), .price_offset = null, .price = 0 };
            if (spec.price) |price| {
                const actual = p.getInt("Price") orelse return null;
                const off = p.intOffset("Price") orelse return null;
                if (actual != price) return null;
                found.price_offset = off;
                found.price = price;
            }
            out.append(allocator, found) catch return error.OutOfMemory;
        }
        return out.items;
    }

    const GiftNode = struct { offset: usize, held_up: bool, shows_item_only: bool };

    /// An event that only shows the item window of an item already handed over (EventRef.shows_item_only).
    fn showsItemOnly(e: *const evfl_view.Event) bool {
        if (e.type == .action) return std.mem.eql(u8, e.action orelse "", "EventTriggerSetForGetWindow");
        if (e.type == .sub_flow) return std.mem.startsWith(u8, e.entry orelse "", "Display");
        return false;
    }

    /// The item field offsets of every gift node handing over `item` (optionally only through sub-flow `via`).
    fn giftNodes(allocator: Allocator, view: *const evfl_view.View, item: []const u8, via: ?[]const u8) WorldError![]GiftNode {
        var out: std.ArrayList(GiftNode) = .empty;
        for (view.flowcharts) |fc| {
            for (fc.events) |*e| {
                const p = e.params orelse continue;
                for (item_keys) |key| {
                    if (!p.isString(key, item)) continue;
                    const off = p.stringOffset(key) orelse continue;
                    var ok = false;
                    if (e.type == .sub_flow) {
                        const flowchart = e.flowchart orelse "";
                        const entry = e.entry orelse "";
                        ok = isGiftSubFlow(flowchart) or isGiftSubFlow(entry);
                        if (via) |v| {
                            // "flowchart:entry" must contain `via`
                            const sub = std.fmt.allocPrint(allocator, "{s}:{s}", .{ flowchart, entry }) catch return error.OutOfMemory;
                            if (std.mem.indexOf(u8, sub, v) == null) ok = false;
                        }
                    } else if (e.type == .action and via == null) {
                        const action = e.action orelse "";
                        if (std.mem.eql(u8, action, "EventTriggerAddOrRemovePouchContent")) {
                            ok = (p.getInt("Num") orelse 0) > 0;
                        } else if (std.mem.eql(u8, action, "EventTriggerSetForGetWindow")) {
                            ok = true;
                        }
                    }
                    if (ok) out.append(allocator, .{ .offset = off, .held_up = e.type == .sub_flow, .shows_item_only = showsItemOnly(e) }) catch return error.OutOfMemory;
                }
            }
        }
        return out.items;
    }

    const Shop = struct {
        folder: []const u8,
        centre: [3]f64,
        members: std.ArrayList(*const Shelf),
    };

    const Slot = struct {
        index: i128,
        actor: []const u8,
        placed: std.ArrayList(*const Shelf),
    };

    fn lessSlot(_: void, x: Slot, y: Slot) bool {
        if (x.index != y.index) return x.index < y.index;
        return std.mem.order(u8, x.actor, y.actor) == .lt;
    }

    fn lessStageRef(_: void, x: StageRef, y: StageRef) bool {
        switch (std.mem.order(u8, x.rel, y.rel)) {
            .lt => return true,
            .gt => return false,
            .eq => return x.hash < y.hash,
        }
    }

    /// One location per shop shelf: its placements in the child and adult files are one slot.
    fn scanShops(self: *Self) WorldError!void {
        const a = self.arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const t = tmp.allocator();

        var shops: std.ArrayList(Shop) = .empty;
        for (self.shelves.items) |*sh| {
            var placed = false;
            for (shops.items) |*shop| {
                if (std.mem.eql(u8, shop.folder, sh.folder) and distance(shop.centre, sh.pos) <= shop_radius) {
                    shop.members.append(t, sh) catch return error.OutOfMemory;
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                var members: std.ArrayList(*const Shelf) = .empty;
                members.append(t, sh) catch return error.OutOfMemory;
                shops.append(t, Shop{ .folder = sh.folder, .centre = sh.pos, .members = members }) catch return error.OutOfMemory;
            }
        }

        for (shops.items) |shop| {
            const name = try shopName(a, shop.folder, shop.members.items);
            var slots: std.ArrayList(Slot) = .empty;
            for (shop.members.items) |m| {
                var found = false;
                for (slots.items) |*s| {
                    if (s.index == m.index and std.mem.eql(u8, s.actor, m.actor)) {
                        s.placed.append(t, m) catch return error.OutOfMemory;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    var placed: std.ArrayList(*const Shelf) = .empty;
                    placed.append(t, m) catch return error.OutOfMemory;
                    slots.append(t, Slot{ .index = m.index, .actor = m.actor, .placed = placed }) catch return error.OutOfMemory;
                }
            }
            std.mem.sort(Slot, slots.items, {}, lessSlot);

            const compact = std.mem.replaceOwned(u8, t, name, " ", "") catch return error.OutOfMemory;
            for (slots.items) |slot| {
                const lid = std.fmt.allocPrint(a, "shop:{s}:{s}:{d}", .{ compact, slot.actor, slot.index }) catch return error.OutOfMemory;
                // a slot that may be missing under a story condition: never shuffled. A file holding one copy for a
                // condition and one for its negation (the Kokiri Shop before / after the Deku Tree) is always there.
                if (slotIsConditional(slot.placed.items)) self.shop_conditional.put(lid, {}) catch return error.OutOfMemory;

                var refs: std.ArrayList(StageRef) = .empty;
                for (slot.placed.items) |m| {
                    var dup = false;
                    for (refs.items) |r| if (std.mem.eql(u8, r.rel, m.rel) and r.hash == m.hash) {
                        dup = true;
                    };
                    if (!dup) refs.append(a, StageRef{ .rel = m.rel, .hash = m.hash }) catch return error.OutOfMemory;
                }
                std.mem.sort(StageRef, refs.items, {}, lessStageRef);
                self.locations.append(a, Location{
                    .id = lid,
                    .name = std.fmt.allocPrint(a, "{s} Item {d}", .{ name, slot.index + 1 }) catch return error.OutOfMemory,
                    .region = shop.folder,
                    .dungeon = null,
                    .kind = .shop,
                    .category = .shop,
                    .ages = .{},
                    .vanilla = try self.items.intern(shop_slot_vanilla),
                    .vanilla_actor = slot.actor,
                    .rule_key = shopRule(shop.folder),
                    .stage_refs = refs.items,
                    .shop = name,
                }) catch return error.OutOfMemory;
            }
        }
    }

    /// Items the generator uses that may not be any location's vanilla item.
    fn internConstants(self: *Self) WorldError!void {
        const constants = [_][]const u8{
            "Bottle",            "Rupee_Red",           "Rupee_Blue",        "Rupee_Purple",    "Rupee_Gold",
            "Wallet_Medium",     "Ocarina_Fairy",       "Token_Gold",        "BombchuBundle_Medium", "ArrowBundle_Large",
            "DekuNutBundle",     "Heart_Piece",         "Heart_Container",   "Shield_Deku",     "Shield_Hylian",
        };
        for (constants) |c| _ = try self.items.intern(c);
    }
};

/// True when the file name's first age marker is "_Child" (Python's re.search(r"_(Adult|Child)") takes the first).
fn hasEarlierChild(fname: []const u8) bool {
    const child = std.mem.indexOf(u8, fname, "_Child") orelse return false;
    const adult = std.mem.indexOf(u8, fname, "_Adult") orelse return true;
    return child < adult;
}

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

fn kindCategory(kind: Kind) Category {
    return switch (kind) {
        .chest => .chest,
        .freestanding => .freestanding,
        .heart_container => .heart_container,
        .gs => .gs,
        .rupee => .rupee,
        .event => .event,
        .shop => .shop,
    };
}

fn sameRoundedPos(a: [3]f64, b: [3]f64) bool {
    for (a, b) |x, y| if (roundHalfEven(x) != roundHalfEven(y)) return false;
    return true;
}

fn distance(a: [3]f64, b: [3]f64) f64 {
    var sum: f64 = 0;
    for (a, b) |x, y| sum += (x - y) * (x - y);
    return @sqrt(sum);
}

fn slotIsConditional(placed: []const *const Shelf) bool {
    // per file: the set of conditions its copies have (null = always there)
    for (placed, 0..) |m, i| {
        // first copy of this file only
        var first = true;
        for (placed[0..i]) |prev| if (std.mem.eql(u8, prev.rel, m.rel)) {
            first = false;
        };
        if (!first) continue;
        var unconditional = false;
        var complemented = false;
        for (placed) |x| {
            if (!std.mem.eql(u8, x.rel, m.rel)) continue;
            const cx = x.condition orelse {
                unconditional = true;
                continue;
            };
            for (placed) |y| {
                if (!std.mem.eql(u8, y.rel, m.rel)) continue;
                const cy = y.condition orelse continue;
                if (std.mem.eql(u8, cx.flag, cy.flag) and cx.negated != cy.negated) complemented = true;
            }
        }
        if (!unconditional and !complemented) return true;
    }
    return false;
}

fn shopName(allocator: Allocator, folder: []const u8, members: []const *const Shelf) error{OutOfMemory}![]const u8 {
    if (std.mem.eql(u8, folder, "KokiriForest")) return "Kokiri Shop";
    if (std.mem.eql(u8, folder, "GoronCity")) return "Goron Shop";
    if (std.mem.eql(u8, folder, "ZoraDomain")) return "Zora Shop";
    var bombchu = false;
    var potion = false;
    var shield = false;
    for (members) |m| {
        if (std.mem.startsWith(u8, m.actor, "Shop_BombchuBundle")) bombchu = true;
        if (std.mem.startsWith(u8, m.actor, "Shop_Bottle_RedPotion")) potion = true;
        if (std.mem.indexOf(u8, m.actor, "Shield") != null) shield = true;
    }
    if (bombchu) return "Bombchu Shop";
    if (potion and !shield) return std.fmt.allocPrint(allocator, "{s} Potion Shop", .{townName(folder)});
    return std.fmt.allocPrint(allocator, "{s} Bazaar", .{townName(folder)});
}

test "canon" {
    try std.testing.expectEqualStrings("Rupee_Red", canon("TBox_Rupee_Red"));
    try std.testing.expectEqualStrings("Heart_Piece", canon("Obj_GerudoValley_Heart_Piece"));
    try std.testing.expectEqual(@as(f64, 2), roundHalfEven(2.5));
    try std.testing.expectEqual(@as(f64, 4), roundHalfEven(3.5));
}
