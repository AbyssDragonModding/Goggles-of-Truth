//! Starting Inventory (0.8.0 feature): the items a new game starts with, chosen on the window's Starting Inventory
//! tab or in a test plan's [settings] (starting_inventory = ["Hookshot", "Hookshot", "Melody_ZeldaLullaby"]).
//!
//! The setting is a list of entry ids, one per copy: an entry's id is the item key of its first tier, so a test plan
//! can name items the way the item catalog does (items.txt). A tiered entry (Hookshot, then Longshot) gives its tiers
//! in order, as a progressive line hands them out; any tier's key counts as one copy, so ["Hookshot", "Longshot"]
//! and ["Hookshot", "Hookshot"] both mean the Longshot. Unknown names are left out (the generator's log says which).
//!
//! The generator (fill.zig Plan.applyStartingInventory) counts the items in the logic, takes one copy of each out of
//! the item pool (a Blue Rupee takes its place) and hands them over like Skip Child Zelda's start checks
//! (patches.zig). Boss rewards and dungeon keys aren't offered: their spots and dungeons need them in the pool.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The window's sections of the list.
pub const Group = enum { equipment, items, upgrades, songs, hearts };

pub const Entry = struct {
    /// item keys; with more than one, copy n is tier n (Hookshot, then Longshot). The first is the entry's id.
    tiers: []const []const u8,
    /// what the window shows
    label: []const u8,
    group: Group,
    /// copies one start can hold (a tiered entry: its tier count)
    max: u8,

    pub fn id(self: *const Entry) []const u8 {
        return self.tiers[0];
    }

    /// The item key copy number `copy` (0-based) hands over.
    pub fn itemOfCopy(self: *const Entry, copy: usize) []const u8 {
        return self.tiers[@min(copy, self.tiers.len - 1)];
    }
};

fn single(key: []const u8, label: []const u8, group: Group) Entry {
    return .{ .tiers = &.{key}, .label = label, .group = group, .max = 1 };
}

fn repeated(key: []const u8, label: []const u8, group: Group, max: u8) Entry {
    return .{ .tiers = &.{key}, .label = label, .group = group, .max = max };
}

fn tiered(comptime tiers: []const []const u8, label: []const u8, group: Group) Entry {
    return .{ .tiers = tiers, .label = label, .group = group, .max = tiers.len };
}

/// Every item a start can hold, in the window's order. The tiered lines follow logic/progressive.zig.
pub const entries = [_]Entry{
    single("Sword_Kokiri", "Kokiri Sword", .equipment),
    single("Sword_Biggoron", "Biggoron Sword", .equipment),
    single("Shield_Deku", "Deku Shield", .equipment),
    single("Shield_Hylian", "Hylian Shield", .equipment),
    single("Shield_Mirror", "Mirror Shield", .equipment),
    single("HeavyBoot", "Iron Boots", .equipment),
    single("HoverBoot", "Hover Boots", .equipment),
    tiered(&.{ "Gauntlet_Goron", "Gauntlet_Silver", "Gauntlet_Gold" }, "Goron Bracelet / Silver / Golden Gauntlets", .equipment),
    tiered(&.{ "Scale_Silver", "Scale_Gold" }, "Silver / Golden Scale", .equipment),

    tiered(&.{ "Ocarina_Fairy", "Ocarina_Time" }, "Fairy Ocarina / Ocarina of Time", .items),
    single("Range_SlingShot", "Fairy Slingshot", .items),
    single("Boomerang", "Boomerang", .items),
    single("Range_Bow", "Fairy Bow", .items),
    single("Arrow_Fire", "Fire Arrow", .items),
    single("Arrow_Ice", "Ice Arrow", .items),
    single("Arrow_Light", "Light Arrow", .items),
    tiered(&.{ "Hookshot", "Longshot" }, "Hookshot / Longshot", .items),
    single("Hammer", "Megaton Hammer", .items),
    single("GlassTruth", "Lens of Truth", .items),
    single("DinFire", "Din's Fire", .items),
    single("FaroreWind", "Farore's Wind", .items),
    single("NayruLove", "Nayru's Love", .items),
    repeated("Bottle", "Empty Bottle", .items, 4),
    single("AgonyStone", "Echo Gem (Stone of Agony)", .items),

    tiered(&.{ "BombBag_Small", "BombBag_Medium", "BombBag_Large" }, "Bomb Bag / Bigger / Biggest", .upgrades),
    tiered(&.{ "Quiver_Medium", "Quiver_Large" }, "Bigger / Biggest Quiver", .upgrades),
    tiered(&.{ "BulletBag_Medium", "BulletBag_Large" }, "Bigger / Biggest Deku Seed Bag", .upgrades),
    single("StickBag_Medium", "Bigger Deku Stick Bag", .upgrades),
    single("NutBag_Medium", "Bigger Deku Nut Bag", .upgrades),
    tiered(&.{ "Wallet_Medium", "Wallet_Large" }, "Adult's / Giant's Wallet", .upgrades),
    single("FairyBless_MP", "Magic (Gift of Improved Spin)", .upgrades),
    single("FairyBless_MPDouble", "Gift of Doubled Magic", .upgrades),
    single("FairyBless_DefenseDouble", "Gift of Halved Damage", .upgrades),

    single("Melody_ZeldaLullaby", "Zelda's Lullaby", .songs),
    single("Melody_EponaSong", "Epona's Song", .songs),
    single("Melody_SariaSong", "Saria's Song", .songs),
    single("Melody_SunSong", "Sun's Song", .songs),
    single("Melody_TimeSong", "Song of Time", .songs),
    single("Melody_StormSong", "Song of Storms", .songs),
    single("Melody_ForestMinuet", "Minuet of Forest", .songs),
    single("Melody_FireBolero", "Bolero of Fire", .songs),
    single("Melody_WaterSerenade", "Serenade of Water", .songs),
    single("Melody_ShadowNocturne", "Nocturne of Shadow", .songs),
    single("Melody_SpiritRequiem", "Requiem of Spirit", .songs),
    single("Melody_LightPrelude", "Prelude of Light", .songs),

    repeated("Heart_Container", "Heart Container", .hearts, 17),
    repeated("Heart_Piece", "Piece of Heart", .hearts, 3),
};

/// The entry whose id or tier key is `name` (item keys are case-sensitive in the game; the match here isn't, so a
/// test plan may write "hookshot").
pub fn entryOf(name: []const u8) ?usize {
    for (&entries, 0..) |*e, i| {
        for (e.tiers) |tier| if (std.ascii.eqlIgnoreCase(tier, name)) return i;
    }
    return null;
}

pub const Counts = [entries.len]u8;

/// Copies per entry in a setting list (each name one copy, capped at the entry's max). Unknown names are skipped.
pub fn countsOf(list: []const []const u8) Counts {
    var counts: Counts = @splat(0);
    for (list) |name| {
        const i = entryOf(name) orelse continue;
        if (counts[i] < entries[i].max) counts[i] += 1;
    }
    return counts;
}

/// The names in `list` that are no entry's (for the generator's log).
pub fn unknownNames(allocator: Allocator, list: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |name| if (entryOf(name) == null) try out.append(allocator, name);
    return out.items;
}

/// The setting list for `counts`: each entry's id once per copy, in table order.
pub fn listOf(allocator: Allocator, counts: *const Counts) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (&entries, counts) |*e, n| {
        for (0..n) |_| try out.append(allocator, e.id());
    }
    return out.items;
}

/// The item keys a start with `counts` hands over, in table order (a tiered entry's tiers in order).
pub fn itemKeysOf(allocator: Allocator, counts: *const Counts) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (&entries, counts) |*e, n| {
        for (0..n) |copy| try out.append(allocator, e.itemOfCopy(copy));
    }
    return out.items;
}

test "starting inventory: tiers count up, unknown names are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const counts = countsOf(&.{ "Hookshot", "longshot", "Hookshot", "Bottle", "Bottle", "NotAnItem" });
    const hookshot = entryOf("Hookshot").?;
    try std.testing.expectEqual(@as(u8, 2), counts[hookshot]);
    try std.testing.expectEqual(@as(u8, 2), counts[entryOf("Bottle").?]);
    const keys = try itemKeysOf(a, &counts);
    try std.testing.expectEqualStrings("Hookshot", keys[0]);
    try std.testing.expectEqualStrings("Longshot", keys[1]);
    try std.testing.expectEqual(@as(usize, 4), keys.len);
    const list = try listOf(a, &counts);
    try std.testing.expectEqualDeep(countsOf(list), counts);
    try std.testing.expectEqual(@as(usize, 1), (try unknownNames(a, &.{ "Hookshot", "NotAnItem" })).len);
}

test "starting inventory: every id is unique" {
    for (&entries, 0..) |*e, i| {
        try std.testing.expectEqual(i, entryOf(e.id()).?);
        try std.testing.expect(e.max >= 1);
    }
}
