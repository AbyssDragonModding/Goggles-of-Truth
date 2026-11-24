//! Which locations are shuffled and which items go into the pool (Plan), and the assumed fill that places them
//! (Filler).

const std = @import("std");
const world_mod = @import("../game/world.zig");
const logic = @import("../logic/logic.zig");
const settings_mod = @import("../settings/settings.zig");
const gamedata = @import("gamedata.zig");
const hash = @import("../core/hash.zig");
const Rng = @import("../core/rng.zig").Rng;
const Progress = @import("../core/Progress.zig");
const seedinfo = @import("../core/seedinfo.zig");
const Allocator = std.mem.Allocator;
const World = world_mod.World;
const Location = world_mod.Location;
const ItemId = logic.ItemId;
const Settings = settings_mod.Settings;

pub const FillError = error{
    /// the items could not be placed this time (another attempt may work); Progress has the reason
    PlacementFailed,
    NotAsExpected,
    InvalidData,
    GameFiles,
    OutOfMemory,
};

// ------------------------------------------------------------------------------------------- item groups

/// Items a shuffled shelf may not sell. Shop_Rando_ shelves are bought once (pickups.zig), as in OotrR; the token
/// and the capacity upgrades (handed out as "Bigger, else Biggest" elsewhere) stay off shelves; so do the rewards.
pub const shop_forbidden = [_][]const u8{
    "Token_Gold", "BombBag_Medium", "BulletBag_Medium", "Quiver_Medium", "Wallet_Medium", "Wallet_Large",
} ++ rewards;
/// OotrR: every shuffled shelf costs 10 rupees
pub const shop_price: i64 = 10;
/// Shelves whose purchase the game needs: at least one copy of each stays on sale. The Deku Shield and the tunics
/// are sold in one shop only, so they never move.
pub const shop_keep_one = [_][]const u8{
    "Shop_Weapon_Shield_Deku", "Shop_Weapon_Shield_Hylian", "Shop_Armor_Goron", "Shop_Armor_Zora",
    "Shop_Bottle_BlueFire",    "Shop_Bottle_Bug",           "Shop_Bottle_Fish", "Shop_Bottle_Fairy",
};
/// Business Scrubs: "low" 10 rupees, "regular" the game's own price (40 or 100), "random" 10 to 99 (child wallet)
pub const scrub_low_price: i64 = 10;
pub const child_wallet: i64 = 99;
pub const adult_wallet: i64 = 200;
pub const upgrades = [_][]const u8{ "Wallet_Medium", "Wallet_Large", "BombBag_Medium", "BombBag_Large" };
pub const rewards = [_][]const u8{
    "Stone_Forest", "Stone_Fire", "Stone_Water", "Medal_Forest", "Medal_Fire", "Medal_Water",
    "Medal_Shadow", "Medal_Spirit", "Medal_Light",
};

/// Skip Child Zelda: the checks whose items a new save already owns (gamedata.grantItem)
pub const start_locations = [_][]const u8{ "event:HC Zeldas Letter", "event:HC Malon Egg", "event:Song from Impa" };
/// Open Death Mountain takes Zelda's Letter out of the seed: a Red Rupee takes its place in the pool, and Zelda's
/// check is shuffled (it gets a random item) even with quest rewards off
pub const open_dmt_letter_junk = "Rupee_Red";
/// Items the save can't simply be given (they need ammo, capacity, hearts, magic or a bottle slot set up too)
const start_deny_prefixes = [_][]const u8{
    "Heart_", "Token_Gold", "Bottle",   "BombBag_", "Quiver_",     "BulletBag_",   "Wallet_", "NutBag_",
    "StickBag_", "Range_",  "FairyBless_", "Arrow_", "Bombchu",     "Bomb",         "Deku",    "Rupee_",
    "MagicJar_", "ArrowBundle", "ScrubBusinessSeed",
    // a key ring / dungeon boss key only does something through an item get (keyitems.zig: the ActionGuide hook)
    "KeyRing_",  "BossKey_",
};

/// Refills that are useless without their container: the item a chest checks for before giving them. Bombchus
/// count against the Bomb Bag; Deku Nuts and Sticks have no item of their own, only a bag that a single nut or
/// stick picked up gives (a bundle found first was lost).
const RefillContainer = struct { prefix: []const u8, container: []const u8 };
const refill_containers = [_]RefillContainer{
    .{ .prefix = "ArrowBundle", .container = "Item_Range_Bow" },
    .{ .prefix = "BombBundle", .container = "Item_BombBag_Small" },
    .{ .prefix = "BombchuBundle", .container = "Item_BombBag_Small" },
    .{ .prefix = "DekuSeedBundle", .container = "Item_Range_SlingShot" },
    .{ .prefix = "DekuNutBundle", .container = "Item_NutBag_Small" },
    .{ .prefix = "DekuStickBundle", .container = "Item_StickBag_Small" },
};
pub const refill_fallback = "Rupee_Blue";

/// Pouch actor a refill needs (e.g. arrows -> Bow), or null for anything else.
pub fn refillContainer(item: []const u8) ?[]const u8 {
    for (refill_containers) |r| if (std.mem.startsWith(u8, item, r.prefix)) return r.container;
    return null;
}

/// Maps & Compasses "Remove": what their chests hold instead, in place.
const removed_map_compass_item = "Rupee_Blue";

/// Maps & Compasses "Start With": what their checks hold instead (item, weight). Never progression.
const BonusItem = struct { item: []const u8, weight: f64 };
const start_with_bonus = [_]BonusItem{
    .{ .item = "Rupee_Blue", .weight = 3 },           .{ .item = "Rupee_Red", .weight = 5 },
    .{ .item = "Rupee_Purple", .weight = 4 },         .{ .item = "Rupee_Gold", .weight = 2 },
    .{ .item = "BombchuBundle_Medium", .weight = 2 }, .{ .item = "ArrowBundle_Large", .weight = 2 },
    .{ .item = "DekuNutBundle", .weight = 1 },        .{ .item = "Heart_Piece", .weight = 1 },
};

/// Capacity upgrades that several locations hand out as "Bigger". In a chest they become progressive with the
/// game's conditional-chest check: own the Bigger one (CheckActor) -> the Biggest (Substitute), else Bigger.
pub const ProgressiveUpgrade = struct { item: []const u8, bigger: []const u8, biggest: []const u8 };
pub const progressive_upgrades = [_]ProgressiveUpgrade{
    .{ .item = "BombBag_Medium", .bigger = "Item_BombBag_Medium", .biggest = "Item_BombBag_Large" },
    .{ .item = "BulletBag_Medium", .bigger = "Item_BulletBag_Medium", .biggest = "Item_BulletBag_Large" },
    .{ .item = "Quiver_Medium", .bigger = "Item_Quiver_Medium", .biggest = "Item_Quiver_Large" },
    .{ .item = "Wallet_Medium", .bigger = "Item_Wallet_Medium", .biggest = "Item_Wallet_Large" },
};

pub fn progressiveUpgrade(item: []const u8) ?ProgressiveUpgrade {
    for (progressive_upgrades) |p| if (std.mem.eql(u8, p.item, item)) return p;
    return null;
}

/// The Skulltula House wallets go into the pool as two Adult's Wallets that only chests may hold: a chest's
/// conditional check gives the Giant's Wallet if you already own the Adult's one.
pub const progressive_wallet = "Wallet_Medium";

/// Never shuffled. The Gerudo Membership Card does nothing by itself (the guards check the carpenter rescue).
const always_vanilla = [_][]const u8{"Token_Gerudo"};

/// Junk with a floating form a Gold Skulltula can drop, and the consumables with a world pickup of their own.
const gs_floating_junk = [_][]const u8{ "Shield_Deku", "Shield_Hylian" };
const NativeDrop = struct { item: []const u8, actor: []const u8 };
const native_drops = [_]NativeDrop{
    .{ .item = "BombBundle_Small", .actor = "Obj_Bomb" },     .{ .item = "DekuStickBundle_Small", .actor = "Obj_DekuStick" },
    .{ .item = "DekuNutBundle", .actor = "Obj_DekuNut" },     .{ .item = "DekuSeedBundle", .actor = "Obj_DekuSeed" },
    .{ .item = "BombchuBundle_Small", .actor = "Obj_Bombchu" },
};

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

pub fn isSong(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "Melody_");
}

pub fn isReward(name: []const u8) bool {
    return inList(name, &rewards);
}

pub const DungeonItem = enum { small_keys, boss_keys, maps_compasses };

pub fn dungeonItemType(name: []const u8) ?DungeonItem {
    if (std.mem.startsWith(u8, name, "Dungeon_SmallKey")) return .small_keys;
    if (std.mem.startsWith(u8, name, "Dungeon_BossKey")) return .boss_keys;
    if (std.mem.startsWith(u8, name, "Dungeon_Map") or std.mem.startsWith(u8, name, "Dungeon_Compass")) return .maps_compasses;
    return null;
}

/// The Key Ring Dungeons choices, in logic.key_dungeons order.
const key_ring_settings = [_]settings_mod.Key{ .key_ring_forest, .key_ring_fire, .key_ring_water, .key_ring_shadow, .key_ring_spirit, .key_ring_well, .key_ring_gtg, .key_ring_ganon };

comptime {
    if (key_ring_settings.len != logic.key_dungeons.len) @compileError("one Key Ring Dungeons setting per key dungeon");
}

/// Small Keys as key rings (Any Dungeon, Overworld, Anywhere).
pub fn keyRingMode(st: *const Settings) bool {
    return st.is(.small_keys, "any_dungeon") or st.is(.small_keys, "overworld") or st.is(.small_keys, "anywhere");
}

/// Boss Keys as items of their own (Any Dungeon, Anywhere).
pub fn bossKeyItemMode(st: *const Settings) bool {
    return st.is(.boss_keys, "any_dungeon") or st.is(.boss_keys, "anywhere");
}

fn settingOf(d: DungeonItem) settings_mod.Key {
    return switch (d) {
        .small_keys => .small_keys,
        .boss_keys => .boss_keys,
        .maps_compasses => .maps_compasses,
    };
}

/// A price for `mode`: low, regular (the game's), random (10-99) or random_wallet (10-200). Derived from a hash of
/// the seed key and the location, so it never depends on the order things are placed in.
fn price(mode: []const u8, what: []const u8, seed_key: []const u8, loc_id: []const u8, low: i64, step: i64, regular: ?i64) i64 {
    if (std.mem.eql(u8, mode, "regular")) {
        if (regular) |r| return r;
    }
    const is_random = std.mem.eql(u8, mode, "random");
    if (is_random or std.mem.eql(u8, mode, "random_wallet")) {
        const top: i64 = if (is_random) child_wallet else adult_wallet;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s}-price|{s}|{s}", .{ what, seed_key, loc_id }) catch return low;
        const digest = hash.sha256(text);
        const n = std.mem.readInt(u64, digest[0..8], .big);
        if (step > 1) {
            const choices: u64 = @intCast(@divFloor(top - low, step) + 1);
            return low + step * @as(i64, @intCast(n % choices));
        }
        return low + @as(i64, @intCast(n % @as(u64, @intCast(top - low + 1))));
    }
    return low;
}

// --------------------------------------------------------------------------------------------------- the plan

pub const Plan = struct {
    allocator: Allocator,
    world: *World,
    st: *const Settings,
    seed_key: []const u8,
    options: logic.Options,
    /// per location (index into world.locations)
    rules: []logic.LocationRule,
    /// a price above 99 rupees needs the Adult's Wallet (or the Giant's)
    needs_wallet: []bool,
    shop_chosen: []bool,
    shop_prices: []?i64,
    scrub_prices: []?i64,
    /// unshuffled locations and their item
    fixed: []?ItemId,
    /// unshuffled locations that still get a different item (patched like placements)
    forced: []?ItemId,
    shuffled: std.ArrayList(usize),
    is_shuffled: []bool,
    excluded: []bool,
    user_excluded: []bool,
    start_locs: []bool,
    pool: std.ArrayList(ItemId),
    /// excluded spots that could only hold a song or a boss reward (their exclusion is ignored)
    exclusion_ignored: std.ArrayList([]const u8),
    grantable_cache: std.AutoHashMap(ItemId, bool),
    sold_once_cache: std.AutoHashMap(ItemId, bool),
    gs_refuses_cache: std.AutoHashMap(ItemId, bool),
    copies: ?std.AutoHashMap(ItemId, usize) = null,
    /// a test seed's chosen placements in settings.txt form ("" for a normal seed; applyTestPlacements)
    test_placements_text: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: Allocator, world: *World, st: *const Settings, seed_key: []const u8) FillError!*Self {
        const n = world.locations.items.len;
        const self = allocator.create(Self) catch return error.OutOfMemory;
        self.* = Self{
            .allocator = allocator,
            .world = world,
            .st = st,
            .seed_key = seed_key,
            .options = logic.Options.fromSettings(st),
            .rules = allocator.alloc(logic.LocationRule, n) catch return error.OutOfMemory,
            .needs_wallet = try boolArray(allocator, n),
            .shop_chosen = try boolArray(allocator, n),
            .shop_prices = try optArray(allocator, i64, n),
            .scrub_prices = try optArray(allocator, i64, n),
            .fixed = try optArray(allocator, ItemId, n),
            .forced = try optArray(allocator, ItemId, n),
            .shuffled = .empty,
            .is_shuffled = try boolArray(allocator, n),
            .excluded = try boolArray(allocator, n),
            .user_excluded = try boolArray(allocator, n),
            .start_locs = try boolArray(allocator, n),
            .pool = .empty,
            .exclusion_ignored = .empty,
            .grantable_cache = std.AutoHashMap(ItemId, bool).init(allocator),
            .sold_once_cache = std.AutoHashMap(ItemId, bool).init(allocator),
            .gs_refuses_cache = std.AutoHashMap(ItemId, bool).init(allocator),
        };
        self.chooseKeyItems();
        for (world.locations.items, 0..) |*loc, i| self.rules[i] = locationRuleFor(loc, &world.items);
        try self.chooseShopSlots();
        try self.chooseScrubPrices();

        const items = &world.items;
        const zelda_letter = items.lookup("ZeldaLetter");
        const bottle_letter = items.lookup("Bottle_Letter");
        const bottle = try world.items.intern("Bottle");
        for (world.locations.items, 0..) |*loc, i| {
            // Open Death Mountain: Zelda's Letter has no use (the gate and the mask shop are open), so her check is
            // shuffled even with quest rewards off: it gets a random item and the letter leaves the pool
            if (try self.isShuffledLocation(loc, i) or (zelda_letter != null and loc.vanilla == zelda_letter.? and st.flag(.open_dmt))) {
                try self.shuffled.append(allocator, i);
                self.is_shuffled[i] = true;
            } else {
                self.fixed[i] = loc.vanilla;
                if (dungeonItemType(items.name(loc.vanilla)) == .maps_compasses and st.is(.maps_compasses, "remove")) {
                    // Maps & Compasses "Remove": the map's or compass's chest holds junk where it is (test report,
                    // EPONAPOE1: shuffled, the chests got random items, which is what "Start With" is for)
                    const junk = try world.items.intern(removed_map_compass_item);
                    self.fixed[i] = junk;
                    self.forced[i] = junk;
                }
                if (bottle_letter != null and loc.vanilla == bottle_letter.? and st.is(.open_zora, "open")) {
                    // King Zora is already moved: the letter would be a dead item, give an empty bottle
                    self.fixed[i] = bottle;
                    self.forced[i] = bottle;
                }
            }
        }
        for (self.shuffled.items) |i| {
            const loc = &world.locations.items[i];
            if (st.isExcluded(loc.id) or st.isExcluded(loc.name)) self.excluded[i] = true;
        }
        if (st.flag(.skip_child_zelda)) {
            for (world.locations.items, 0..) |loc, i| {
                if (inList(loc.id, &start_locations)) self.start_locs[i] = true;
            }
        }
        for (self.shuffled.items) |i| try self.pool.append(allocator, world.locations.items[i].vanilla);
        try self.adjustPool();

        // An excluded spot that can only take a song or a boss reward (Shuffle Songs: Song Locations, rewards at the
        // reward spots) can never be free of progression: excluding even one made every seed fail. Such a spot keeps
        // its exclusion off (generate() logs which).
        var junk_items: std.ArrayList(ItemId) = .empty;
        for (self.pool.items) |item| {
            const name = items.name(item);
            if (logic.isProgression(item) or dungeonItemType(name) != null or isReward(name)) continue;
            if (std.mem.indexOfScalar(ItemId, junk_items.items, item) == null) try junk_items.append(allocator, item);
        }
        if (junk_items.items.len > 0) {
            for (self.shuffled.items) |i| {
                if (!self.excluded[i]) continue;
                var any = false;
                for (junk_items.items) |j| {
                    if (try self.allowed(i, j)) {
                        any = true;
                        break;
                    }
                }
                if (!any) {
                    try self.exclusion_ignored.append(allocator, world.locations.items[i].name);
                    self.excluded[i] = false;
                }
            }
        }
        @memcpy(self.user_excluded, self.excluded);
        return self;
    }

    /// Test seeds (`goggles_cli generate --place`): each chosen location keeps the chosen item and leaves the
    /// shuffle, and one copy of that item leaves the item pool, so the pool still fits the locations; the fill
    /// places everything else around them and its logic counts them like any unshuffled item. Returns a message
    /// saying what is wrong, or null when every placement was applied. Normal seeds have none, so this never
    /// changes their placements.
    pub fn applyTestPlacements(self: *Self, requests: []const seedinfo.TestPlacement) FillError!?[]const u8 {
        const allocator = self.allocator;
        for (requests) |request| {
            const location_index = for (self.world.locations.items, 0..) |*loc, i| {
                if (std.mem.eql(u8, loc.name, request.location) or std.mem.eql(u8, loc.id, request.location)) break i;
            } else {
                return std.fmt.allocPrint(allocator, "no location named \"{s}\" (use the name the spoiler log shows)", .{request.location}) catch error.OutOfMemory;
            };
            if (!self.is_shuffled[location_index]) {
                return std.fmt.allocPrint(allocator, "\"{s}\" isn't shuffled with these settings, so it can't take a chosen item", .{request.location}) catch error.OutOfMemory;
            }
            var pool_index: ?usize = null;
            for (self.pool.items, 0..) |item, i| {
                const display_name = self.world.itemNameById(allocator, item) catch return error.OutOfMemory;
                if (std.mem.eql(u8, self.world.items.name(item), request.item) or std.mem.eql(u8, display_name, request.item)) {
                    pool_index = i;
                    break;
                }
            }
            const item = if (pool_index) |chosen_index| self.pool.orderedRemove(chosen_index) else (try self.takeItemFromOutsideThePool(request.item)) orelse {
                return std.fmt.allocPrint(allocator, "no \"{s}\" left in the item pool (use the name the spoiler log shows; each copy can be placed once)", .{request.item}) catch error.OutOfMemory;
            };
            const shuffled_position = std.mem.indexOfScalar(usize, self.shuffled.items, location_index).?;
            _ = self.shuffled.orderedRemove(shuffled_position);
            self.is_shuffled[location_index] = false;
            self.excluded[location_index] = false;
            self.user_excluded[location_index] = false;
            self.fixed[location_index] = item;
            self.forced[location_index] = item;
        }
        return null;
    }

    /// Test seeds only: a requested item the pool doesn't hold but the game has (by its key, e.g. "Bottle_BigPoe" for
    /// a Big Poe in a bottle at a start check), placed in place of one junk item taken out of the pool, so the pool
    /// still fills every check exactly. Why: some features need an item no seed shuffles to be tested quickly (the
    /// Big Poe buyer). Null when the game has no such item or the pool has no junk left.
    fn takeItemFromOutsideThePool(self: *Self, item_key: []const u8) FillError!?ItemId {
        // an item no check holds isn't in the item list yet: added when the game has its item actor ("Item_<key>")
        const outside_item = self.world.items.lookup(item_key) orelse blk: {
            const item_actor = std.fmt.allocPrint(self.allocator, "Item_{s}", .{item_key}) catch return error.OutOfMemory;
            if (!self.world.actorExists(item_actor)) return null;
            break :blk self.world.items.intern(item_key) catch return error.OutOfMemory;
        };
        for (self.pool.items, 0..) |pool_item, i| if (self.isJunk(pool_item)) {
            _ = self.pool.orderedRemove(i);
            return outside_item;
        };
        return null;
    }

    fn boolArray(allocator: Allocator, n: usize) FillError![]bool {
        const out = allocator.alloc(bool, n) catch return error.OutOfMemory;
        @memset(out, false);
        return out;
    }

    fn optArray(allocator: Allocator, comptime T: type, n: usize) FillError![]?T {
        const out = allocator.alloc(?T, n) catch return error.OutOfMemory;
        @memset(out, null);
        return out;
    }

    pub fn location(self: *const Self, i: usize) *Location {
        return &self.world.locations.items[i];
    }

    pub fn itemName(self: *const Self, item: ItemId) []const u8 {
        return self.world.items.name(item);
    }

    pub fn isJunk(self: *const Self, item: ItemId) bool {
        return world_mod.isJunkName(self.itemName(item));
    }

    pub fn countUserExcluded(self: *const Self) usize {
        var n: usize = 0;
        for (self.user_excluded) |e| if (e) {
            n += 1;
        };
        return n;
    }

    /// Can location `i` be reached in state `s`? (its rule, and the wallet a high price needs)
    pub fn reachable(self: *const Self, i: usize, s: *logic.State) bool {
        if (!logic.check(s, self.rules[i])) return false;
        if (self.needs_wallet[i]) return s.has(.Wallet_Medium) or s.has(.Wallet_Large);
        return true;
    }

    /// Items Shuffled Per Shop (OotrR): N shelves per shop (1 to 4 at random with "random"), at the shop price,
    /// keeping one copy on sale of every shelf in shop_keep_one.
    fn chooseShopSlots(self: *Self) FillError!void {
        const mode = self.st.choice(.shopsanity);
        if (std.mem.eql(u8, mode, "off")) return;
        var key_buf: [1024]u8 = undefined;
        var rng = Rng.fromText(std.fmt.bufPrint(&key_buf, "shops|{s}", .{self.seed_key}) catch self.seed_key);
        const locs = self.world.locations.items;

        // shops by name, sorted; copies of each shelf actor over all shops
        var shop_names: std.ArrayList([]const u8) = .empty;
        var copies = std.StringHashMap(usize).init(self.allocator);
        for (locs) |loc| {
            if (loc.kind != .shop) continue;
            if (!inList(loc.shop.?, shop_names.items)) try appendItem([]const u8, &shop_names, self.allocator, loc.shop.?);
            const slot = copies.getOrPut(loc.vanilla_actor) catch return error.OutOfMemory;
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* += 1;
        }
        std.mem.sort([]const u8, shop_names.items, {}, lessString);

        for (shop_names.items) |shop| {
            var wanted: i64 = if (std.mem.eql(u8, mode, "random")) rng.intRange(1, 4) else std.fmt.parseInt(i64, mode, 10) catch 0;
            var slots: std.ArrayList(usize) = .empty;
            for (locs, 0..) |loc, i| {
                if (loc.kind == .shop and std.mem.eql(u8, loc.shop.?, shop)) try appendItem(usize, &slots, self.allocator, i);
            }
            std.mem.sort(usize, slots.items, locs, lessLocationId);
            rng.shuffle(usize, slots.items);
            for (slots.items) |i| {
                if (wanted <= 0) break;
                const loc = &locs[i];
                // may be missing under a story condition the logic doesn't know
                if (self.world.shop_conditional.contains(loc.id)) continue;
                // a shelf always there through complementary story conditions (the Kokiri Shop's copies before /
                // after the Deku Tree) keeps them, each AND-ed with sold-out (gamedata.addShopPresence)
                const count = copies.getPtr(loc.vanilla_actor).?;
                if (inList(loc.vanilla_actor, &shop_keep_one) and count.* <= 1) continue;
                count.* -= 1;
                self.shop_chosen[i] = true;
                self.shop_prices[i] = price(self.st.choice(.shop_prices), "shop", self.seed_key, loc.id, shop_price, 5, null);
                wanted -= 1;
            }
        }
        for (self.shop_prices, 0..) |p, i| {
            if (p) |v| self.needsWalletFor(i, v);
        }
    }

    /// Small Keys as key rings / Boss Keys outside their temple: which dungeons' keys become items of their own
    /// (logic.Options.key_ring / boss_key_item). Random Dungeons draws each one from the seed.
    fn chooseKeyItems(self: *Self) void {
        const st = self.st;
        if (keyRingMode(st)) {
            const mode = st.choice(.key_rings);
            var key_buf: [1024]u8 = undefined;
            var rng = Rng.fromText(std.fmt.bufPrint(&key_buf, "key_rings|{s}", .{self.seed_key}) catch self.seed_key);
            for (logic.key_dungeons, 0..) |_, i| {
                self.options.key_ring[i] = if (std.mem.eql(u8, mode, "choose"))
                    st.flag(key_ring_settings[i])
                else if (std.mem.eql(u8, mode, "random"))
                    rng.below(2) == 0
                else
                    true;
            }
        }
        if (bossKeyItemMode(st)) {
            for (logic.key_dungeons, 0..) |d, i| self.options.boss_key_item[i] = d.boss != null;
        }
    }

    /// Is the vanilla small key / boss key / map / compass `item` (its location's original item) shuffled?
    fn dungeonItemShuffled(self: *Self, dtype: DungeonItem, item: []const u8) bool {
        const st = self.st;
        const mode = st.choice(settingOf(dtype));
        if (std.mem.eql(u8, mode, "vanilla")) return false;
        // Maps & Compasses "Remove": their chests hold a Blue Rupee in place (removed_map_compass_item), not shuffled;
        // "Start With": the save has them and their chests take random items from the pool
        if (dtype == .maps_compasses) return !std.mem.eql(u8, mode, "remove");
        if (std.mem.eql(u8, mode, "own")) return true;
        // the item's own dungeon ("Dungeon_SmallKey@ForestTemple"); keys outside the key dungeons (the Thieves'
        // Hideout's) stay where they are
        const at = std.mem.indexOfScalar(u8, item, '@') orelse return false;
        const i = logic.keyDungeonIndex(item[at + 1 ..]) orelse return false;
        return switch (dtype) {
            // Removed: every key dungeon's key chests get other items; key rings: only the dungeons with a ring
            .small_keys => std.mem.eql(u8, mode, "remove") or self.options.key_ring[i],
            // Ganon's Castle's boss key stays in its chest
            .boss_keys => logic.key_dungeons[i].boss != null,
            .maps_compasses => true,
        };
    }

    fn needsWalletFor(self: *Self, i: usize, p: i64) void {
        if (p > child_wallet) self.needs_wallet[i] = true;
    }

    /// Business Scrubs: each shuffled scrub's price, and the wallet it needs when that is above 99.
    fn chooseScrubPrices(self: *Self) FillError!void {
        if (!self.st.flag(.shuffle_scrubs)) return;
        const mode = self.st.choice(.scrub_prices);
        for (self.world.locations.items, 0..) |loc, i| {
            if (loc.category != .scrub) continue;
            var game: i64 = scrub_low_price;
            if (loc.price_refs.len > 0) {
                game = loc.price_refs[0].price;
                for (loc.price_refs) |r| game = @max(game, r.price);
            }
            const p = price(mode, "scrub", self.seed_key, loc.id, scrub_low_price, 1, game);
            self.scrub_prices[i] = p;
            self.needsWalletFor(i, p);
        }
    }

    fn isShuffledLocation(self: *Self, loc: *const Location, i: usize) FillError!bool {
        const st = self.st;
        const item = self.itemName(loc.vanilla);
        if (loc.kind == .shop) return self.shop_chosen[i];
        if (dungeonItemType(item)) |dtype| return self.dungeonItemShuffled(dtype, item);
        if (std.mem.eql(u8, item, "Sword_Kokiri") and !st.flag(.shuffle_kokiri_sword)) return false;
        if (inList(item, &upgrades) and !loc.upgrade_ok) return false;
        if (std.mem.eql(u8, item, "WeirdEgg") and !st.flag(.shuffle_weird_egg)) return false;
        if (inList(item, &always_vanilla)) return false;
        return switch (loc.category) {
            .ocarina => st.flag(.shuffle_ocarinas),
            .song => !st.is(.shuffle_songs, "vanilla"),
            .reward => !st.is(.shuffle_rewards, "vanilla"),
            .npc => st.flag(.shuffle_npc),
            .quest => st.flag(.shuffle_quest),
            .scrub => st.flag(.shuffle_scrubs),
            .egg => true, // Shuffle Weird Egg (checked above)
            .fairy => st.flag(.shuffle_fairies),
            .house => st.flag(.shuffle_house),
            .gs => blk: {
                const t = st.choice(.tokensanity);
                break :blk std.mem.eql(u8, t, "all") or (std.mem.eql(u8, t, "dungeons") and loc.dungeon != null) or
                    (std.mem.eql(u8, t, "overworld") and loc.dungeon == null);
            },
            .freestanding => st.flag(.shuffle_freestanding),
            .rupee => st.flag(.shuffle_rupees),
            .heart_container => st.flag(.shuffle_heart_containers),
            .chest => true,
            else => false,
        };
    }

    fn replaceAll(self: *Self, from: []const u8, to: []const u8) FillError!void {
        const from_id = self.world.items.lookup(from) orelse return;
        const to_id = try self.world.items.intern(to);
        for (self.pool.items) |*item| {
            if (item.* == from_id) item.* = to_id;
        }
    }

    fn adjustPool(self: *Self) FillError!void {
        const st = self.st;
        const items = &self.world.items;
        // Ruto's Letter can't be delivered with an open Fountain; an empty bottle takes its place
        if (st.is(.open_zora, "open")) try self.replaceAll("Bottle_Letter", "Bottle");
        // Open Death Mountain: the Kakariko gate and the Happy Mask Shop are open, Zelda's Letter has no use
        if (st.flag(.open_dmt)) try self.replaceAll("ZeldaLetter", open_dmt_letter_junk);
        if (st.flag(.shuffle_house)) try self.replaceAll("Wallet_Large", progressive_wallet);
        if (st.flag(.shuffle_ocarinas)) {
            // Saria's bridge gift is switched off; her Fairy Ocarina replaces junk
            var key_buf: [1024]u8 = undefined;
            var rng = Rng.fromText(std.fmt.bufPrint(&key_buf, "ocarina|{s}", .{self.seed_key}) catch self.seed_key);
            var junk_at: std.ArrayList(usize) = .empty;
            for (self.pool.items, 0..) |item, i| if (items.isJunk(item)) try appendItem(usize, &junk_at, self.allocator, i);
            const fairy = try self.world.items.intern("Ocarina_Fairy");
            if (junk_at.items.len > 0) {
                self.pool.items[junk_at.items[rng.below(junk_at.items.len)]] = fairy;
            } else {
                try appendItem(ItemId, &self.pool, self.allocator, fairy);
            }
        }
        // (Maps & Compasses "Remove": their chests aren't shuffled, so none of them is in the pool)
        if (st.is(.maps_compasses, "start_with")) {
            // the save already has them (gamedata.plannedChanges); their checks get a random bonus
            var key_buf: [1024]u8 = undefined;
            var rng = Rng.fromText(std.fmt.bufPrint(&key_buf, "start_maps|{s}", .{self.seed_key}) catch self.seed_key);
            var weights: [start_with_bonus.len]f64 = undefined;
            for (start_with_bonus, 0..) |b, i| weights[i] = b.weight;
            for (self.pool.items) |*item| {
                if (dungeonItemType(items.name(item.*)) == .maps_compasses) {
                    item.* = try self.world.items.intern(start_with_bonus[rng.weighted(&weights)].item);
                }
            }
        }
        try self.keyPool();
        const pool_mode = st.choice(.item_pool);
        if (std.mem.eql(u8, pool_mode, "scarce") or std.mem.eql(u8, pool_mode, "minimal")) {
            const red = try self.world.items.intern("Rupee_Red");
            var pieces: usize = 0;
            var containers: usize = 0;
            for (self.pool.items) |*item| {
                const n = items.name(item.*);
                const counter = if (std.mem.eql(u8, n, "Heart_Piece")) &pieces else if (std.mem.eql(u8, n, "Heart_Container")) &containers else continue;
                counter.* += 1;
                if (std.mem.eql(u8, pool_mode, "minimal") or counter.* % 2 == 0) item.* = red;
            }
        }
    }

    /// The keys in the pool for Small Keys / Boss Keys other than Vanilla and Own Dungeon: a key ring dungeon's small
    /// keys become its key ring (one of them; the others a Blue Rupee), a temple's boss key its own boss key item,
    /// and the removed keys Blue Rupees (a new save already holds them, gamedata.plannedChanges).
    fn keyPool(self: *Self) FillError!void {
        const st = self.st;
        const items = &self.world.items;
        const ring_mode = keyRingMode(st);
        const remove_keys = st.is(.small_keys, "remove");
        const boss_mode = bossKeyItemMode(st);
        const remove_boss = st.is(.boss_keys, "remove");
        if (!ring_mode and !remove_keys and !boss_mode and !remove_boss) return;
        const blue = try items.intern("Rupee_Blue");
        var ring_in_pool: [logic.key_dungeons.len]bool = @splat(false);
        for (self.pool.items) |*item| {
            const name = items.name(item.*);
            const dtype = dungeonItemType(name) orelse continue;
            const at = std.mem.indexOfScalar(u8, name, '@') orelse continue;
            const i = logic.keyDungeonIndex(name[at + 1 ..]) orelse continue;
            const d = logic.key_dungeons[i];
            switch (dtype) {
                .small_keys => {
                    if (remove_keys) {
                        item.* = blue;
                    } else if (ring_mode and self.options.key_ring[i]) {
                        item.* = if (ring_in_pool[i]) blue else d.ring.id();
                        ring_in_pool[i] = true;
                    }
                },
                .boss_keys => if (d.boss) |b| {
                    if (remove_boss) {
                        item.* = blue;
                    } else if (boss_mode) {
                        item.* = b.id();
                    }
                },
                .maps_compasses => {},
            }
        }
        if (!ring_mode) return;
        // a key ring dungeon whose small keys the scan didn't find (none shuffled) still gets its ring, in place of junk
        var key_buf: [1024]u8 = undefined;
        var rng = Rng.fromText(std.fmt.bufPrint(&key_buf, "key_ring_junk|{s}", .{self.seed_key}) catch self.seed_key);
        for (logic.key_dungeons, 0..) |d, i| {
            if (!self.options.key_ring[i] or ring_in_pool[i]) continue;
            var junk_at: std.ArrayList(usize) = .empty;
            for (self.pool.items, 0..) |item, k| if (items.isJunk(item)) try appendItem(usize, &junk_at, self.allocator, k);
            if (junk_at.items.len == 0) return error.PlacementFailed;
            self.pool.items[junk_at.items[rng.below(junk_at.items.len)]] = d.ring.id();
        }
    }

    /// Skip Child Zelda: can a new save simply own `item` (its "obtained" flag plus a pouch count of 1)?
    pub fn grantable(self: *Self, item: ItemId) FillError!bool {
        if (self.grantable_cache.get(item)) |v| return v;
        const name = self.itemName(item);
        var ok = std.mem.indexOfScalar(u8, name, '@') == null and !isReward(name) and !startsWithAny(name, &start_deny_prefixes);
        if (ok and !isSong(name)) {
            const actor = try self.world.actorFor(self.allocator, name, .event);
            ok = if (actor) |a| try gamedata.pouchEntryExists(self.world, a) else false;
        }
        self.grantable_cache.put(item, ok) catch return error.OutOfMemory;
        return ok;
    }

    /// Can a shelf sell `item` once? A bought shelf is hidden by its item's IsGet flag, so the item must exist once
    /// in the seed (a second Piece of Heart found elsewhere would hide an unbought shelf) and have that flag.
    pub fn soldOnce(self: *Self, item: ItemId) FillError!bool {
        if (self.sold_once_cache.get(item)) |v| return v;
        if (self.copies == null) {
            var copies = std.AutoHashMap(ItemId, usize).init(self.allocator);
            for (self.pool.items) |p| try countUp(&copies, p);
            for (self.fixed) |f| if (f) |x| try countUp(&copies, x);
            self.copies = copies;
        }
        const name = self.itemName(item);
        var ok = false;
        if (try self.world.actorFor(self.allocator, name, .event)) |actor| {
            // bottles: filling an empty bottle (milk, fish, ...) may set the same flag and hide an unbought shelf
            ok = (self.copies.?.get(item) orelse 0) <= 1 and !std.mem.startsWith(u8, name, "Bottle") and
                self.world.actorExists(actor) and try gamedata.isGetExists(self.world, actor);
        }
        self.sold_once_cache.put(item, ok) catch return error.OutOfMemory;
        return ok;
    }

    fn countUp(map: *std.AutoHashMap(ItemId, usize), item: ItemId) FillError!void {
        const slot = map.getOrPut(item) catch return error.OutOfMemory;
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
    }

    /// The game's own world pickup for consumable `item` (it falls when dropped), or null.
    pub fn nativeDrop(self: *Self, item: ItemId) FillError!?[]const u8 {
        const name = self.itemName(item);
        var actor: ?[]const u8 = null;
        for (native_drops) |d| if (std.mem.eql(u8, d.item, name)) {
            actor = d.actor;
        };
        if (actor == null) actor = try self.world.actorFor(self.allocator, name, .world);
        const a = actor orelse return null;
        return if (std.mem.startsWith(u8, a, "Obj_") and self.world.actorExists(a)) a else null;
    }

    /// Junk a Gold Skulltula can't drop (no floating form, no pickup of its own).
    pub fn gsRefuses(self: *Self, item: ItemId) FillError!bool {
        if (self.gs_refuses_cache.get(item)) |v| return v;
        const name = self.itemName(item);
        const v = world_mod.isJunkName(name) and !inList(name, &gs_floating_junk) and (try self.nativeDrop(item)) == null;
        self.gs_refuses_cache.put(item, v) catch return error.OutOfMemory;
        return v;
    }

    /// May shuffled location `i` receive `item`?
    pub fn allowed(self: *Self, i: usize, item: ItemId) FillError!bool {
        const st = self.st;
        const loc = self.location(i);
        const name = self.itemName(item);
        const dtype = dungeonItemType(name);
        // excluded: never progression, keys or boss rewards (maps and compasses only show the map, so they may)
        if (self.excluded[i] and (logic.isProgression(item) or isReward(name) or dtype == .small_keys or dtype == .boss_keys)) return false;
        const own_dungeon = std.mem.indexOfScalar(u8, name, '@');
        // Skip Child Zelda's start checks take any item except own-dungeon items: one a save default can hold is set
        // in the new save, any other is handed over when the game starts (faststart.giveAtStart)
        if (self.start_locs[i] and own_dungeon != null) return false;
        if (std.mem.eql(u8, name, progressive_wallet) and loc.kind != .chest) return false;
        if (logic.keyItemOf(name)) |k| {
            // handed over at the start (Skip Child Zelda) it would skip the item get that applies it
            if (self.start_locs[i]) return false;
            const mode = st.choice(if (k.ring) .small_keys else .boss_keys);
            if (std.mem.eql(u8, mode, "any_dungeon") and loc.dungeon == null) return false;
            if (std.mem.eql(u8, mode, "overworld") and loc.dungeon != null) return false;
        }
        if (loc.kind == .gs and try self.gsRefuses(item)) return false;
        const is_reward_loc = loc.category == .reward;
        const is_song_loc = loc.category == .song;
        if (!st.is(.shuffle_rewards, "anywhere")) {
            if (isReward(name)) return is_reward_loc;
            if (is_reward_loc) return false;
        }
        if (isSong(name)) {
            if (st.is(.shuffle_songs, "song")) return is_song_loc;
        } else if (is_song_loc and st.is(.shuffle_songs, "song")) {
            return false;
        }
        if (std.mem.eql(u8, name, "Range_SlingShot") and st.is(.open_forest, "closed")) {
            // the Deku Tree needs it and a closed forest cannot be left before the Deku Tree is done
            const forest = loc.region != null and logic.isForestRegion(loc.region.?);
            if (!isDekuSlingshotChest(loc, &self.world.items) and (loc.dungeon != null or !forest)) return false;
        }
        if (own_dungeon) |at| {
            // dungeon items stay in their own dungeon
            const dungeon = loc.dungeon orelse return false;
            if (!std.mem.eql(u8, dungeon, name[at + 1 ..])) return false;
            // Boss keys, maps and compasses only count for the dungeon when a chest's opening gives them (qol.zig
            // patchSmallChestDungeonItems); a pickup only puts them in the pouch.
            if (dtype == .boss_keys or dtype == .maps_compasses) return loc.kind == .chest;
            return true;
        }
        if (loc.kind == .shop) {
            // a shelf needs a pouch actor with its own pack
            if (world_mod.isJunkName(name)) return true; // the shelf keeps its normal goods
            if (inList(name, &shop_forbidden) or isReward(name)) return false;
            return self.soldOnce(item);
        }
        return true;
    }
};

fn appendItem(comptime T: type, list: *std.ArrayList(T), allocator: Allocator, item: T) FillError!void {
    list.append(allocator, item) catch return error.OutOfMemory;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessLocationId(locs: []Location, a: usize, b: usize) bool {
    return std.mem.order(u8, locs[a].id, locs[b].id) == .lt;
}

/// The Deku Tree's own Slingshot chest (room 2), opened before the Slingshot is ever needed.
pub fn isDekuSlingshotChest(loc: *const Location, items: *const world_mod.ItemTable) bool {
    const dungeon = loc.dungeon orelse return false;
    return std.mem.eql(u8, dungeon, "InsideTheDekuTree") and loc.kind == .chest and items.is(loc.vanilla, "Range_SlingShot");
}

/// A location's logic rule (rando/logic.py location_rule).
pub fn locationRuleFor(loc: *const Location, items: *const world_mod.ItemTable) logic.LocationRule {
    if (loc.rule_key) |key| return .{ .special = key };
    const region = loc.region orelse return .never;
    if (loc.kind == .rupee and std.mem.eql(u8, region, "ZoraDomain")) return .zora_domain_pool;
    if (isDekuSlingshotChest(loc, items)) return .deku_slingshot_chest;
    if (std.mem.eql(u8, region, "GanonCastle") and loc.kind == .gs) return .adult_only;
    if (loc.dungeon) |dungeon| {
        const done = logic.dungeonRule(dungeon) orelse return .never;
        var gs: logic.LocationRule.GsTool = .none;
        if (loc.kind == .gs) gs = if (loc.ages.only(true, false)) .boomerang else .hookshot;
        return .{ .dungeon = .{ .done = done, .gs = gs } };
    }
    const r = logic.regionByName(region) orelse return .never;
    const kf_free = std.mem.eql(u8, region, "KokiriForest") and loc.kind == .chest and
        (items.is(loc.vanilla, "Sword_Kokiri") or std.mem.eql(u8, loc.get_event, "KokiriForest_TreasureBox_NaviChatOff"));
    return .{ .overworld = .{
        .region = r,
        .child = loc.ages.child,
        .adult = loc.ages.adult,
        .kf_free = kf_free,
        .is_gs = loc.kind == .gs,
        .bean_gs = std.mem.indexOf(u8, loc.presence, "MagicBeanSoil") != null,
    } };
}

// ------------------------------------------------------------------------------------------------- the filler

pub const Sweep = struct {
    state: logic.State,
    /// per location: collected in the sweep
    got: []bool,
    /// the locations collected in each sphere, in order
    spheres: std.ArrayList(std.ArrayList(usize)),
};

pub const Filler = struct {
    allocator: Allocator,
    plan: *Plan,
    rng: Rng,
    /// per location: the item placed there
    placed: []?ItemId,
    /// placement order (Python's dict order, used where it mattered)
    order: std.ArrayList(usize),
    no_logic: bool,
    progress: *Progress,

    const Self = @This();

    pub fn init(allocator: Allocator, plan: *Plan, seed: u64, progress: *Progress) FillError!Self {
        return Self{
            .allocator = allocator,
            .plan = plan,
            .rng = Rng.init(seed),
            .placed = try Plan.optArray(allocator, ItemId, plan.rules.len),
            .order = .empty,
            .no_logic = plan.st.is(.logic_rules, "none"),
            .progress = progress,
        };
    }

    fn place(self: *Self, i: usize, item: ItemId) FillError!void {
        if (self.placed[i] == null) try appendItem(usize, &self.order, self.allocator, i);
        self.placed[i] = item;
    }

    /// The item at each location: fixed ones and placed ones.
    pub fn contents(self: *const Self) FillError![]?ItemId {
        const out = self.allocator.dupe(?ItemId, self.plan.fixed) catch return error.OutOfMemory;
        for (self.placed, 0..) |p, i| {
            if (p) |item| out[i] = item;
        }
        return out;
    }

    /// Collects everything reachable starting from `base` items, with the items at `contents`.
    pub fn sweep(self: *Self, base: []const ItemId, items_at: []const ?ItemId) FillError!Sweep {
        var s = try logic.State.init(self.allocator, self.plan.world.items.count(), &self.plan.options);
        for (base) |item| s.addKeepingCache(item);
        const got = try Plan.boolArray(self.allocator, items_at.len);
        var spheres: std.ArrayList(std.ArrayList(usize)) = .empty;
        var new: std.ArrayList(usize) = .empty;
        while (true) {
            new.clearRetainingCapacity();
            // every rule is checked on the state at the start of the sphere, then the sphere's items are added
            for (items_at, 0..) |item, i| {
                if (item == null or got[i]) continue;
                if (self.plan.reachable(i, &s)) try appendItem(usize, &new, self.allocator, i);
            }
            if (new.items.len == 0) break;
            var sphere: std.ArrayList(usize) = .empty;
            sphere.appendSlice(self.allocator, new.items) catch return error.OutOfMemory;
            spheres.append(self.allocator, sphere) catch return error.OutOfMemory;
            for (new.items) |i| {
                got[i] = true;
                s.addKeepingCache(items_at[i].?);
            }
            s.clearCache();
        }
        return Sweep{ .state = s, .got = got, .spheres = spheres };
    }

    /// Assumed fill for `items`, retried locally (a fresh order each time) before giving up.
    fn placeGroup(self: *Self, items: []const ItemId, unplaced_rest: []const ItemId) FillError!void {
        const snapshot = self.allocator.dupe(?ItemId, self.placed) catch return error.OutOfMemory;
        const order_len = self.order.items.len;
        const tries = 25;
        var t: usize = 0;
        while (t < tries) : (t += 1) {
            if (self.placeGroupOnce(items, unplaced_rest)) |_| {
                return;
            } else |err| switch (err) {
                error.PlacementFailed => {
                    @memcpy(self.placed, snapshot);
                    self.order.shrinkRetainingCapacity(order_len);
                    if (t == tries - 1) return err;
                },
                else => return err,
            }
        }
    }

    fn sortRank(item: ItemId) u8 {
        // most constrained first: higher-tier items, then other progression, then the rest
        if (logic.lowerTier(item) != null) return 0;
        if (logic.isProgression(item)) return 1;
        return 2;
    }

    fn lessRank(_: void, a: ItemId, b: ItemId) bool {
        return sortRank(a) < sortRank(b);
    }

    fn placeGroupOnce(self: *Self, group: []const ItemId, unplaced_rest: []const ItemId) FillError!void {
        const plan = self.plan;
        const items = self.allocator.dupe(ItemId, group) catch return error.OutOfMemory;
        self.rng.shuffle(ItemId, items);
        std.mem.sort(ItemId, items, {}, lessRank);
        var remaining: std.ArrayList(ItemId) = .empty;
        remaining.appendSlice(self.allocator, items) catch return error.OutOfMemory;

        var empty: std.ArrayList(usize) = .empty;
        var cands: std.ArrayList(usize) = .empty;
        var base: std.ArrayList(ItemId) = .empty;
        for (items) |item| {
            // one copy of this item leaves the "still to place" list
            if (std.mem.indexOfScalar(ItemId, remaining.items, item)) |k| _ = remaining.orderedRemove(k);

            empty.clearRetainingCapacity();
            for (plan.shuffled.items) |i| {
                if (self.placed[i] == null and try plan.allowed(i, item)) try appendItem(usize, &empty, self.allocator, i);
            }
            if (empty.items.len == 0) return self.progress.fail(error.PlacementFailed, "no free location can hold {s}", .{plan.itemName(item)});

            cands.clearRetainingCapacity();
            if (self.no_logic or !logic.isProgression(item)) {
                cands.appendSlice(self.allocator, empty.items) catch return error.OutOfMemory;
            } else {
                // assume every item still to place is owned; place this one where that state reaches
                base.clearRetainingCapacity();
                for (remaining.items) |r| if (logic.isProgression(r)) try appendItem(ItemId, &base, self.allocator, r);
                for (unplaced_rest) |r| if (logic.isProgression(r)) try appendItem(ItemId, &base, self.allocator, r);
                var result = try self.sweep(base.items, try self.contents());
                for (empty.items) |i| if (plan.reachable(i, &result.state)) try appendItem(usize, &cands, self.allocator, i);
                if (logic.lowerTier(item)) |lower| {
                    if (cands.items.len > 0) {
                        // without the lower tier and without other copies of this item (e.g. two Bigger Bomb Bags)
                        var without = try result.state.clone(self.allocator);
                        without.counts[lower] = 0;
                        if (item < without.counts.len) without.counts[item] = 0;
                        without.clearCache();
                        var tiered: std.ArrayList(usize) = .empty;
                        for (cands.items) |i| if (!plan.reachable(i, &without)) try appendItem(usize, &tiered, self.allocator, i);
                        if (tiered.items.len == 0) {
                            return self.progress.fail(error.PlacementFailed, "no location for {s} that requires {s}", .{ plan.itemName(item), plan.itemName(lower) });
                        }
                        cands.clearRetainingCapacity();
                        cands.appendSlice(self.allocator, tiered.items) catch return error.OutOfMemory;
                    }
                }
                if (cands.items.len == 0) return self.progress.fail(error.PlacementFailed, "no reachable location for {s}", .{plan.itemName(item)});
            }
            try self.place(cands.items[self.rng.below(cands.items.len)], item);
        }
    }

    fn isProgressionItem(item: ItemId) bool {
        return logic.isProgression(item);
    }

    pub fn run(self: *Self) FillError!void {
        const plan = self.plan;
        const a = self.allocator;
        const anywhere = plan.st.is(.shuffle_rewards, "anywhere");

        // dungeon items first (they are the most constrained), then rewards, songs, other progression
        var dungeon_items: std.ArrayList(ItemId) = .empty;
        var reward_items: std.ArrayList(ItemId) = .empty;
        var song_items: std.ArrayList(ItemId) = .empty;
        var prog_rest: std.ArrayList(ItemId) = .empty;
        var junk_rest: std.ArrayList(ItemId) = .empty;
        for (plan.pool.items) |item| {
            const name = plan.itemName(item);
            if (std.mem.indexOfScalar(u8, name, '@') != null) {
                try appendItem(ItemId, &dungeon_items, a, item);
            } else if (!anywhere and isReward(name)) {
                try appendItem(ItemId, &reward_items, a, item);
            } else if (isSong(name)) {
                try appendItem(ItemId, &song_items, a, item);
            } else if (logic.isProgression(item)) {
                try appendItem(ItemId, &prog_rest, a, item);
            } else {
                try appendItem(ItemId, &junk_rest, a, item);
            }
        }

        var later: std.ArrayList(ItemId) = .empty;
        for ([_][]const ItemId{ reward_items.items, song_items.items, prog_rest.items }) |list| {
            for (list) |i| if (logic.isProgression(i)) try appendItem(ItemId, &later, a, i);
        }
        try self.placeGroup(dungeon_items.items, later.items);
        later.clearRetainingCapacity();
        for ([_][]const ItemId{ song_items.items, prog_rest.items }) |list| {
            for (list) |i| if (logic.isProgression(i)) try appendItem(ItemId, &later, a, i);
        }
        try self.placeGroup(reward_items.items, later.items);
        later.clearRetainingCapacity();
        for (prog_rest.items) |i| if (logic.isProgression(i)) try appendItem(ItemId, &later, a, i);
        try self.placeGroup(song_items.items, later.items);
        try self.placeGroup(prog_rest.items, &.{});
        self.rng.shuffle(ItemId, junk_rest.items);

        // Items Shuffled Per Shop: junk on a shelf leaves its normal goods, so most chosen shelves looked unchanged
        // (0.6.2 seed 83WVJZQBZE: 10 of 13). Each empty chosen shelf first takes a real item it can sell once; junk
        // goes on a shelf only when none is left
        var shelves: std.ArrayList(usize) = .empty;
        for (plan.shuffled.items) |i| {
            if (plan.location(i).kind == .shop and self.placed[i] == null) try appendItem(usize, &shelves, a, i);
        }
        self.rng.shuffle(usize, shelves.items);
        for (shelves.items) |i| {
            for (junk_rest.items, 0..) |item, k| {
                if (!plan.isJunk(item) and try plan.allowed(i, item)) {
                    try self.place(i, junk_rest.orderedRemove(k));
                    break;
                }
            }
        }

        // Skip Child Zelda's start checks are filled like any other check: they take any item (Plan.allowed)
        var empty: std.ArrayList(usize) = .empty;
        for (plan.shuffled.items) |i| if (self.placed[i] == null) try appendItem(usize, &empty, a, i);
        // restricted junk first
        std.mem.sort(ItemId, junk_rest.items, plan, lessShopForbiddenFirst);
        self.rng.shuffle(usize, empty.items);
        const refills = plan.st.flag(.refill_needs_item);

        // some junk can't go on a Gold Skulltula (gsRefuses): keep enough other spots free for it
        var junk_left: usize = 0;
        for (junk_rest.items) |item| if (try plan.gsRefuses(item)) {
            junk_left += 1;
        };
        for (junk_rest.items) |original_item| {
            var item = original_item;
            var spot: ?usize = null;
            if (try plan.gsRefuses(item)) {
                junk_left -= 1;
            } else {
                var free: usize = 0;
                for (empty.items) |i| if (self.placed[i] == null and plan.location(i).kind != .gs) {
                    free += 1;
                };
                if (free <= junk_left) spot = try self.firstEmpty(empty.items, item, .gs);
            }
            if (spot == null and progressiveUpgrade(plan.itemName(item)) != null) {
                // chests make repeat copies progressive (see patches.zig); prefer them
                spot = try self.firstEmpty(empty.items, item, .chest);
            } else if (spot == null and refills and refillContainer(plan.itemName(item)) != null) {
                // only chests can check for the container; elsewhere the refill becomes a blue rupee
                spot = try self.firstEmpty(empty.items, item, .chest);
                if (spot == null) item = try plan.world.items.intern(refill_fallback);
            }
            if (spot == null) spot = try self.firstEmpty(empty.items, item, null);
            if (spot == null and try plan.gsRefuses(item)) {
                spot = try self.makeRoomOffSkulltulas(empty.items, &item);
            }
            const s = spot orelse {
                var left: [7]usize = @splat(0);
                for (empty.items) |i| if (self.placed[i] == null) {
                    left[@intFromEnum(plan.location(i).kind)] += 1;
                };
                var text: std.ArrayList(u8) = .empty;
                for (std.meta.tags(world_mod.Kind)) |kind| {
                    const n = left[@intFromEnum(kind)];
                    if (n == 0) continue;
                    if (text.items.len > 0) text.appendSlice(a, ", ") catch return error.OutOfMemory;
                    text.print(a, "{d} {s}", .{ n, @tagName(kind) }) catch return error.OutOfMemory;
                }
                return self.progress.fail(error.PlacementFailed, "no location left for {s} (empty: {s})", .{
                    plan.itemName(item), if (text.items.len > 0) text.items else "none",
                });
            };
            try self.place(s, item);
        }
    }

    fn lessShopForbiddenFirst(plan: *Plan, a: ItemId, b: ItemId) bool {
        const ra: u8 = if (inList(plan.itemName(a), &shop_forbidden)) 0 else 1;
        const rb: u8 = if (inList(plan.itemName(b), &shop_forbidden)) 0 else 1;
        return ra < rb;
    }

    /// The first empty location in `order` (of kind `kind`, if given) that may hold `item`.
    fn firstEmpty(self: *Self, order: []const usize, item: ItemId, kind: ?world_mod.Kind) FillError!?usize {
        for (order) |i| {
            if (self.placed[i] != null) continue;
            if (kind) |k| if (self.plan.location(i).kind != k) continue;
            if (try self.plan.allowed(i, item)) return i;
        }
        return null;
    }

    /// Only Skulltula spots are left for junk a Skulltula can't drop: move a placed item that unlocks nothing (a Piece
    /// of Heart, ...) onto one and put the junk where it was; moving such an item can't change the logic. With more
    /// junk than other spots, a Skulltula keeps its own token instead (an extra token only makes the Skulltula
    /// House easier). Returns the spot for `item` (which may become the token), or null.
    fn makeRoomOffSkulltulas(self: *Self, empty: []const usize, item: *ItemId) FillError!?usize {
        const plan = self.plan;
        var gs_free: std.ArrayList(usize) = .empty;
        for (empty) |i| if (self.placed[i] == null and plan.location(i).kind == .gs) try appendItem(usize, &gs_free, self.allocator, i);

        // the placed locations in a random order
        const Keyed = struct { loc: usize, key: f64 };
        var others: std.ArrayList(Keyed) = .empty;
        for (self.order.items) |i| try appendItem(Keyed, &others, self.allocator, Keyed{ .loc = i, .key = self.rng.float() });
        std.mem.sort(Keyed, others.items, {}, struct {
            fn less(_: void, x: Keyed, y: Keyed) bool {
                return x.key < y.key;
            }
        }.less);
        for (others.items) |o| {
            const moved = self.placed[o.loc].?;
            const other = plan.location(o.loc);
            if (other.kind == .gs or plan.start_locs[o.loc] or logic.isProgression(moved) or plan.isJunk(moved) or
                !try plan.allowed(o.loc, item.*)) continue;
            for (gs_free.items) |g| {
                if (try plan.allowed(g, moved)) {
                    try self.place(g, moved);
                    return o.loc;
                }
            }
        }
        const token = plan.world.items.lookup("Token_Gold") orelse return null;
        for (gs_free.items) |g| {
            if (try plan.allowed(g, token)) {
                item.* = token;
                return g;
            }
        }
        return null;
    }
};
