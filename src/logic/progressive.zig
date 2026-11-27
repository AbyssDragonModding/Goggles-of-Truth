//! Progressive items: one item key for every copy of an upgrade line ("Progressive Hookshot"), that hands out the
//! next tier the player doesn't own yet, whatever order the copies are found in.
//!
//! How each kind of location does it (generator/patches.zig, generator/progressive_flows.zig):
//! - Character gifts, minigames and Business Scrubs (event flows): before each hand-over the flow asks the game's
//!   own pouch query (PouchSystemActor.EventQueryIsExistInPouch, the one the Bombchu Bowling and Mask Shop flows use)
//!   from the highest tier down, and hands over the next tier. Any number of tiers works.
//! - Chests: the game's conditional chest (Drop__CheckActor -> Drop__DropActor_Substitute, else Drop__DropActor)
//!   makes one check. Two tiers: "own tier 1 -> tier 2, else tier 1", exact. Three tiers: "own tier 2 -> tier 3,
//!   else tier 2", exact only when the player owns tier 1 already, so the fill only puts a three-tier copy in a
//!   chest that the logic can't reach without one copy of the line (generator/fill.zig).
//! - Everything else (freestanding items, Gold Skulltulas, shop shelves, ...) can't branch: no progressive item is
//!   placed there.
//!
//! The logic counts copies: owning any n copies of a line (or n of its tiers) means owning its first n tiers.

const std = @import("std");

/// One tier of a progressive line.
pub const Tier = struct {
    /// the tier's canonical item key ("Longshot"); world.actorFor gives its actors
    key: []const u8,
    /// the actor name the game's pouch query asks for (EventQueryIsExistInPouch {Actor=...}). Why it isn't always
    /// the Item_ actor: the gauntlets are kept in the pouch as their Armor_ actors, and the game's own flows ask for
    /// those (dump: Npc_Goron_012_Child, Npc_Gerudo_004: Armor_Adult_Gauntlet_Silver).
    pouch_actor: []const u8,
};

pub const Chain = struct {
    /// the progressive item's key in the item pool ("Progressive_Hookshot")
    key: []const u8,
    /// its name in the spoiler log, the hints and the scrubs' lines
    display_name: []const u8,
    /// lowest tier first
    tiers: []const Tier,
    /// With Progressive Items off, each tier is its own item and the fill keeps them in order: a stronger tier only
    /// goes where the logic needs the weaker one (generator/fill.zig, 0.7.8's rule). False for the lines nothing in
    /// the logic needs the weaker tier of (the wallets, Deku Seed bags and quivers): no spot could keep their stronger
    /// tier from being found first, so they stay progressive items either way. The Ocarinas too: an Ocarina lying in
    /// the world comes without its tutorial and Ocarina button (generator/ocarina_handover.zig only fixes hand-overs
    /// and chests), and a progressive one is never placed there.
    separate_without_progressive: bool = false,

    /// The tier a chest shows when it has no check to make: the tier below the last one (chests make one check,
    /// see the module comment).
    pub fn chestFallbackTier(self: *const Chain) *const Tier {
        return &self.tiers[self.tiers.len - 2];
    }

    /// True when a chest can only give the right tier to a player who owns the first one already.
    pub fn chestNeedsOneCopy(self: *const Chain) bool {
        return self.tiers.len >= 3;
    }
};

pub const chains = [_]Chain{
    .{ .key = "Progressive_Ocarina", .display_name = "Progressive Ocarina", .tiers = &.{
        .{ .key = "Ocarina_Fairy", .pouch_actor = "Item_Ocarina_Fairy" },
        .{ .key = "Ocarina_Time", .pouch_actor = "Item_Ocarina_Time" },
    } },
    .{ .key = "Progressive_Hookshot", .display_name = "Progressive Hookshot", .separate_without_progressive = true, .tiers = &.{
        .{ .key = "Hookshot", .pouch_actor = "Item_Hookshot" },
        .{ .key = "Longshot", .pouch_actor = "Item_Longshot" },
    } },
    .{ .key = "Progressive_Strength", .display_name = "Progressive Strength Upgrade", .separate_without_progressive = true, .tiers = &.{
        .{ .key = "Gauntlet_Goron", .pouch_actor = "Armor_Child_Gauntlet_Goron" },
        .{ .key = "Gauntlet_Silver", .pouch_actor = "Armor_Adult_Gauntlet_Silver" },
        .{ .key = "Gauntlet_Gold", .pouch_actor = "Armor_Adult_Gauntlet_Gold" },
    } },
    .{ .key = "Progressive_Scale", .display_name = "Progressive Scale", .separate_without_progressive = true, .tiers = &.{
        .{ .key = "Scale_Silver", .pouch_actor = "Item_Scale_Silver" },
        .{ .key = "Scale_Gold", .pouch_actor = "Item_Scale_Gold" },
    } },
    // the game has no Tycoon's Wallet (dump: Item_Wallet_Small / _Medium / _Large only); the Kokiri Wallet is owned
    // from the start
    .{ .key = "Progressive_Wallet", .display_name = "Progressive Wallet", .tiers = &.{
        .{ .key = "Wallet_Medium", .pouch_actor = "Item_Wallet_Medium" },
        .{ .key = "Wallet_Large", .pouch_actor = "Item_Wallet_Large" },
    } },
    .{ .key = "Progressive_BombBag", .display_name = "Progressive Bomb Bag", .separate_without_progressive = true, .tiers = &.{
        .{ .key = "BombBag_Small", .pouch_actor = "Item_BombBag_Small" },
        .{ .key = "BombBag_Medium", .pouch_actor = "Item_BombBag_Medium" },
        .{ .key = "BombBag_Large", .pouch_actor = "Item_BombBag_Large" },
    } },
    // a new save already has the base seed bag and quiver (generator/faststart.zig base_bags_at_start): these lines
    // are their upgrades
    .{ .key = "Progressive_BulletBag", .display_name = "Progressive Deku Seed Bag", .tiers = &.{
        .{ .key = "BulletBag_Medium", .pouch_actor = "Item_BulletBag_Medium" },
        .{ .key = "BulletBag_Large", .pouch_actor = "Item_BulletBag_Large" },
    } },
    .{ .key = "Progressive_Quiver", .display_name = "Progressive Quiver", .tiers = &.{
        .{ .key = "Quiver_Medium", .pouch_actor = "Item_Quiver_Medium" },
        .{ .key = "Quiver_Large", .pouch_actor = "Item_Quiver_Large" },
    } },
};

/// The tier just below tier `key` of a line that stays separate items with Progressive Items off
/// (Chain.separate_without_progressive), or null: "Longshot" -> "Hookshot", "BombBag_Large" -> "BombBag_Medium".
pub fn weakerTierOf(key: []const u8) ?[]const u8 {
    const chain = chainOfTierItem(key) orelse return null;
    if (!chain.separate_without_progressive) return null;
    for (chain.tiers[1..], 1..) |tier, i| {
        if (std.mem.eql(u8, tier.key, key)) return chain.tiers[i - 1].key;
    }
    return null;
}

/// The line whose progressive item is `key`, or null.
pub fn chainOfProgressiveItem(key: []const u8) ?*const Chain {
    for (&chains) |*chain| if (std.mem.eql(u8, chain.key, key)) return chain;
    return null;
}

/// The line `key` is a tier of, or null.
pub fn chainOfTierItem(key: []const u8) ?*const Chain {
    for (&chains) |*chain| {
        for (chain.tiers) |tier| if (std.mem.eql(u8, tier.key, key)) return chain;
    }
    return null;
}

/// The line `key` belongs to, as its progressive item or as one of its tiers.
pub fn chainOfAnyItem(key: []const u8) ?*const Chain {
    return chainOfProgressiveItem(key) orelse chainOfTierItem(key);
}

test "every line has two or three tiers and unique keys" {
    for (chains, 0..) |chain, i| {
        try std.testing.expect(chain.tiers.len >= 2 and chain.tiers.len <= 3);
        for (chains[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, chain.key, other.key));
        for (chain.tiers) |tier| try std.testing.expectEqualStrings(chain.key, chainOfTierItem(tier.key).?.key);
    }
    try std.testing.expectEqualStrings("Longshot", chainOfProgressiveItem("Progressive_Hookshot").?.tiers[1].key);
    try std.testing.expect(chainOfProgressiveItem("Hookshot") == null);
    try std.testing.expect(chainOfProgressiveItem("Progressive_Strength").?.chestNeedsOneCopy());
    try std.testing.expectEqualStrings("Hookshot", weakerTierOf("Longshot").?);
    try std.testing.expectEqualStrings("Gauntlet_Goron", weakerTierOf("Gauntlet_Silver").?);
    try std.testing.expect(weakerTierOf("Hookshot") == null);
    try std.testing.expect(weakerTierOf("Wallet_Large") == null);
    try std.testing.expectEqualStrings("Gauntlet_Silver", chainOfProgressiveItem("Progressive_Strength").?.chestFallbackTier().key);
}
