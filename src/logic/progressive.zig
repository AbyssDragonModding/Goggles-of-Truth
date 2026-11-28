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
//! - Items lying in the world (freestanding spots, rupee spots, boss Heart Container spots, Gold Skulltula drops):
//!   the pickup is a new item of its own per line, "Progressive <line>" (Chain.ground_pickup_item, with the first
//!   tier's model; generator/progressive_pickups.zig). Every item get ends in ActionGuide:ActionGuide, which then
//!   checks each such item got: it clears its saved IsGet flag and hands over the next tier, asking the same pouch
//!   query as the event flows. Any number of tiers works.
//! - Shop shelves: the same, with a stand-in item of each shelf's own, applied once when bought
//!   (generator/progressive_pickups.zig).
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
    /// The item a copy lying in the world is (generator/progressive_pickups.zig builds it): "Item_Prog_<line>". Short
    /// on purpose: a generated item over 25 characters crashed its item get (pickups.max_key_item_name).
    ground_pickup_item: []const u8,
    /// The actor whose model that pickup shows: the first tier's item. The Fairy Ocarina's is its Pouch_ actor, the
    /// same model with the item-get animations (its Item_ actor is the equipment Link wears, world.actorFor).
    ground_pickup_model: []const u8,

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
    .{ .key = "Progressive_Ocarina", .display_name = "Progressive Ocarina", .ground_pickup_item = "Item_Prog_Ocarina", .ground_pickup_model = "Pouch_Ocarina_Fairy", .tiers = &.{
        .{ .key = "Ocarina_Fairy", .pouch_actor = "Item_Ocarina_Fairy" },
        .{ .key = "Ocarina_Time", .pouch_actor = "Item_Ocarina_Time" },
    } },
    .{ .key = "Progressive_Hookshot", .display_name = "Progressive Hookshot", .ground_pickup_item = "Item_Prog_Hookshot", .ground_pickup_model = "Item_Hookshot", .tiers = &.{
        .{ .key = "Hookshot", .pouch_actor = "Item_Hookshot" },
        .{ .key = "Longshot", .pouch_actor = "Item_Longshot" },
    } },
    .{ .key = "Progressive_Strength", .display_name = "Progressive Strength Upgrade", .ground_pickup_item = "Item_Prog_Strength", .ground_pickup_model = "Item_Gauntlet_Goron", .tiers = &.{
        .{ .key = "Gauntlet_Goron", .pouch_actor = "Armor_Child_Gauntlet_Goron" },
        .{ .key = "Gauntlet_Silver", .pouch_actor = "Armor_Adult_Gauntlet_Silver" },
        .{ .key = "Gauntlet_Gold", .pouch_actor = "Armor_Adult_Gauntlet_Gold" },
    } },
    .{ .key = "Progressive_Scale", .display_name = "Progressive Scale", .ground_pickup_item = "Item_Prog_Scale", .ground_pickup_model = "Item_Scale_Silver", .tiers = &.{
        .{ .key = "Scale_Silver", .pouch_actor = "Item_Scale_Silver" },
        .{ .key = "Scale_Gold", .pouch_actor = "Item_Scale_Gold" },
    } },
    // the game has no Tycoon's Wallet (dump: Item_Wallet_Small / _Medium / _Large only); the Kokiri Wallet is owned
    // from the start
    .{ .key = "Progressive_Wallet", .display_name = "Progressive Wallet", .ground_pickup_item = "Item_Prog_Wallet", .ground_pickup_model = "Item_Wallet_Medium", .tiers = &.{
        .{ .key = "Wallet_Medium", .pouch_actor = "Item_Wallet_Medium" },
        .{ .key = "Wallet_Large", .pouch_actor = "Item_Wallet_Large" },
    } },
    .{ .key = "Progressive_BombBag", .display_name = "Progressive Bomb Bag", .ground_pickup_item = "Item_Prog_BombBag", .ground_pickup_model = "Item_BombBag_Small", .tiers = &.{
        .{ .key = "BombBag_Small", .pouch_actor = "Item_BombBag_Small" },
        .{ .key = "BombBag_Medium", .pouch_actor = "Item_BombBag_Medium" },
        .{ .key = "BombBag_Large", .pouch_actor = "Item_BombBag_Large" },
    } },
    // a new save already has the base seed bag and quiver (generator/faststart.zig base_bags_at_start): these lines
    // are their upgrades
    .{ .key = "Progressive_BulletBag", .display_name = "Progressive Deku Seed Bag", .ground_pickup_item = "Item_Prog_BulletBag", .ground_pickup_model = "Item_BulletBag_Medium", .tiers = &.{
        .{ .key = "BulletBag_Medium", .pouch_actor = "Item_BulletBag_Medium" },
        .{ .key = "BulletBag_Large", .pouch_actor = "Item_BulletBag_Large" },
    } },
    .{ .key = "Progressive_Quiver", .display_name = "Progressive Quiver", .ground_pickup_item = "Item_Prog_Quiver", .ground_pickup_model = "Item_Quiver_Medium", .tiers = &.{
        .{ .key = "Quiver_Medium", .pouch_actor = "Item_Quiver_Medium" },
        .{ .key = "Quiver_Large", .pouch_actor = "Item_Quiver_Large" },
    } },
};

/// The line whose ground pickup item (Chain.ground_pickup_item) is actor `actor`, or null.
pub fn chainOfGroundPickupItem(actor: []const u8) ?*const Chain {
    for (&chains) |*chain| if (std.mem.eql(u8, chain.ground_pickup_item, actor)) return chain;
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
    try std.testing.expectEqualStrings("Gauntlet_Silver", chainOfProgressiveItem("Progressive_Strength").?.chestFallbackTier().key);
    try std.testing.expectEqualStrings("Progressive_Scale", chainOfGroundPickupItem("Item_Prog_Scale").?.key);
    try std.testing.expect(chainOfGroundPickupItem("Item_Scale_Silver") == null);
}

test "ground pickup items are short, unique and named Item_" {
    for (chains, 0..) |chain, i| {
        // pickups.max_key_item_name: a longer generated item crashed its item get
        try std.testing.expect(chain.ground_pickup_item.len <= 25);
        try std.testing.expect(std.mem.startsWith(u8, chain.ground_pickup_item, "Item_"));
        for (chains[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, chain.ground_pickup_item, other.ground_pickup_item));
    }
}
