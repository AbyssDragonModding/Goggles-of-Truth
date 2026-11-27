//! More randomness: the Random options a seed rolls when it's made, and the window's Randomize buttons.
//!
//! Random options (rollRandomChoices): Kokiri Forest, Door of Time, Zora's Fountain, Death Mountain and Rainbow
//! Bridge can be Random; the bridge's Medallion and token counts can be Random (from 1 up to the number set); and
//! Random Starting Items adds 1 to 5 items to the starting inventory. The generator rolls them from the seed, each
//! from a stream of its own, into a copy of the settings that the fill and every patch read. The settings string
//! (settings.txt, the spoiler's top) keeps "Random", so Rebuild Seed rolls the same again; the spoiler log lists
//! what this seed got. Starting Age, Key Rings and Barren Dungeons keep rolling in the fill, as before.
//!
//! Randomize buttons (randomizeSettings): a whole tab, one card (a setting group), or every gameplay setting at
//! once. They pick real values the window shows. Only Stable and In Testing settings and options are picked from:
//! never an Experimental one, never the lists (exclusions, item restrictions, the chosen starting items), never the
//! General Settings tab, and never Logic Rules (No Logic makes seeds that can't be finished).

const std = @import("std");
const settings = @import("settings.zig");
const startinventory = @import("startinventory.zig");
const Rng = @import("../core/rng.zig").Rng;
const Allocator = std.mem.Allocator;
const Settings = settings.Settings;
const Key = settings.Key;

/// What a seed rolled for one Random setting, for the spoiler log.
pub const Roll = struct { label: []const u8, value: []const u8 };

pub const Rolled = struct {
    settings: Settings,
    rolls: []const Roll,
};

/// The choice settings whose Random option the seed rolls here.
const rolled_choices = [_]Key{ .open_forest, .open_door, .open_zora, .open_dmt, .rainbow_bridge };

/// What Rainbow Bridge's Random picks from: every requirement but the two that need all 100 Gold Skulltula Tokens
/// (a seed needing all of them by chance would take far longer than any other).
const random_bridges = [_][]const u8{ "vanilla", "medallions", "stones", "tokens", "rewards" };

/// Random Starting Items "random": 1 to this many.
pub const max_random_start_items = 5;

/// `st` with every Random option rolled from `seed_key`, and what was rolled. Settings without a Random option
/// chosen are returned as they are, so seeds without one keep their placements.
pub fn rollRandomChoices(allocator: Allocator, st: *const Settings, seed_key: []const u8) error{OutOfMemory}!Rolled {
    var out = st.*;
    var rolls: std.ArrayList(Roll) = .empty;

    for (rolled_choices) |key| {
        if (!out.is(key, "random")) continue;
        var rng = try streamFor(allocator, @tagName(key), seed_key);
        const s = settings.spec(key);
        const picked: []const u8 = if (key == .rainbow_bridge) random_bridges[rng.below(random_bridges.len)] else blk: {
            var choices: std.ArrayList([]const u8) = .empty;
            for (s.options) |o| if (!std.mem.eql(u8, o.value, "random")) try choices.append(allocator, o.value);
            break :blk choices.items[rng.below(choices.items.len)];
        };
        const option = s.option(picked) orelse continue;
        out.set(key, .{ .choice = option.value });
        try rolls.append(allocator, .{ .label = try plainLabel(allocator, s.label), .value = try plainLabel(allocator, option.label) });
    }

    // the bridge's counts, when its requirement (as rolled) uses them
    if (out.flag(.bridge_medallions_random) and out.is(.rainbow_bridge, "medallions")) {
        var rng = try streamFor(allocator, "bridge_medallions", seed_key);
        const n = rollCount(&rng, out.int(.bridge_medallions));
        out.set(.bridge_medallions, .{ .int = n });
        try rolls.append(allocator, .{ .label = settings.spec(.bridge_medallions).label, .value = try std.fmt.allocPrint(allocator, "{d}", .{n}) });
    }
    if (out.flag(.bridge_tokens_random) and out.is(.rainbow_bridge, "tokens")) {
        var rng = try streamFor(allocator, "bridge_tokens", seed_key);
        const n = rollCount(&rng, out.int(.bridge_tokens));
        out.set(.bridge_tokens, .{ .int = n });
        try rolls.append(allocator, .{ .label = settings.spec(.bridge_tokens).label, .value = try std.fmt.allocPrint(allocator, "{d}", .{n}) });
    }

    // Random Starting Items: one copy at a time of an entry the start can still hold more of (an upgrade already
    // chosen gives its next tier)
    const mode = out.choice(.random_start_items);
    if (!std.mem.eql(u8, mode, "off")) {
        var rng = try streamFor(allocator, "random_start_items", seed_key);
        const wanted: usize = if (std.mem.eql(u8, mode, "random"))
            1 + rng.below(max_random_start_items)
        else
            std.fmt.parseInt(usize, mode, 10) catch 0;
        var counts = startinventory.countsOf(out.startingInventory());
        var names: std.ArrayList([]const u8) = .empty;
        var open: std.ArrayList(usize) = .empty;
        for (0..wanted) |_| {
            open.clearRetainingCapacity();
            for (startinventory.entries, 0..) |e, i| if (counts[i] < e.max) try open.append(allocator, i);
            if (open.items.len == 0) break;
            const i = open.items[rng.below(open.items.len)];
            counts[i] += 1;
            try names.append(allocator, startinventory.entries[i].label);
        }
        out.set(.starting_inventory, .{ .list = try startinventory.listOf(allocator, &counts) });
        try rolls.append(allocator, .{ .label = try plainLabel(allocator, settings.spec(.random_start_items).label), .value = try std.mem.join(allocator, ", ", names.items) });
    }
    return .{ .settings = out, .rolls = rolls.items };
}

/// A setting's label for the spoiler log, without its status note ("Random Starting Items (needs further testing)").
fn plainLabel(allocator: Allocator, label: []const u8) error{OutOfMemory}![]const u8 {
    var buffer: [512]u8 = undefined;
    return allocator.dupe(u8, settings.splitStatus(&buffer, label).text);
}

/// A count from 1 up to `max` (at least 1).
fn rollCount(rng: *Rng, max: i64) i64 {
    const top: usize = @intCast(@max(max, 1));
    return @intCast(1 + rng.below(top));
}

fn streamFor(allocator: Allocator, what: []const u8, seed_key: []const u8) error{OutOfMemory}!Rng {
    const text = try std.fmt.allocPrint(allocator, "random|{s}|{s}", .{ what, seed_key });
    defer allocator.free(text);
    return Rng.fromText(text);
}

// --------------------------------------------------------------------------------------------- the buttons

/// What a Randomize button changes: every gameplay setting, one tab's, or one card's (a tab and setting group).
pub const Scope = union(enum) {
    all,
    tab: []const u8,
    group: struct { tab: []const u8, group: []const u8 },
};

/// Settings the buttons never change.
const never_randomized = [_]Key{.logic_rules};
/// Tabs the buttons never change (paths and output options; the exclusion lists).
const fixed_tabs = [_][]const u8{ "General Settings", "Exclusions" };

/// Can the Randomize buttons change setting `s`?
pub fn isRandomizable(s: *const settings.Spec) bool {
    if (s.kind == .list) return false;
    for (never_randomized) |k| if (k == s.key) return false;
    for (fixed_tabs) |t| if (std.mem.eql(u8, t, s.tab)) return false;
    return settings.settingStatus(s.key, null) != .experimental;
}

fn inScope(s: *const settings.Spec, scope: Scope) bool {
    return switch (scope) {
        .all => true,
        .tab => |tab| std.mem.eql(u8, s.tab, tab),
        .group => |g| std.mem.eql(u8, s.tab, g.tab) and std.mem.eql(u8, s.group, g.group),
    };
}

/// Gives every setting of `scope` the buttons may change a random value (a choice: one of its options that isn't
/// Experimental). Returns how many settings it changed.
pub fn randomizeSettings(st: *Settings, rng: *Rng, scope: Scope) usize {
    var changed: usize = 0;
    for (&settings.specs) |*s| {
        if (!inScope(s, scope) or !isRandomizable(s)) continue;
        switch (s.kind) {
            .boolean => st.set(s.key, .{ .boolean = rng.below(2) == 1 }),
            .int => st.set(s.key, .{ .int = s.min + @as(i64, @intCast(rng.below(@intCast(s.max - s.min + 1)))) }),
            .choice => {
                var allowed: [32]usize = undefined;
                var n: usize = 0;
                for (s.options, 0..) |o, i| {
                    if (n == allowed.len) break;
                    if (settings.settingStatus(s.key, o.value) == .experimental) continue;
                    allowed[n] = i;
                    n += 1;
                }
                if (n == 0) continue;
                st.set(s.key, .{ .choice = s.options[allowed[rng.below(n)]].value });
            },
            .list => continue,
        }
        changed += 1;
    }
    return changed;
}

/// Does `scope` hold a setting the buttons may change (a tab or card worth a Randomize button)?
pub fn hasRandomizable(scope: Scope) bool {
    for (&settings.specs) |*s| if (inScope(s, scope) and isRandomizable(s)) return true;
    return false;
}

test "rolls only what is Random, the same for a seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = Settings.defaults();
    const plain = try rollRandomChoices(a, &st, "seed A");
    try std.testing.expectEqual(@as(usize, 0), plain.rolls.len);
    st.set(.open_forest, .{ .choice = "random" });
    st.set(.rainbow_bridge, .{ .choice = "random" });
    st.set(.random_start_items, .{ .choice = "3" });
    const first = try rollRandomChoices(a, &st, "seed A");
    const again = try rollRandomChoices(a, &st, "seed A");
    try std.testing.expect(!first.settings.is(.open_forest, "random"));
    try std.testing.expect(!first.settings.is(.rainbow_bridge, "random"));
    try std.testing.expectEqualStrings(first.settings.choice(.open_forest), again.settings.choice(.open_forest));
    try std.testing.expectEqual(@as(usize, 3), first.settings.startingInventory().len);
    // never a bridge that needs all 100 tokens
    for (0..40) |k| {
        const key = try std.fmt.allocPrint(a, "seed {d}", .{k});
        const r = try rollRandomChoices(a, &st, key);
        try std.testing.expect(!r.settings.is(.rainbow_bridge, "all_tokens") and !r.settings.is(.rainbow_bridge, "everything"));
    }
}

test "the buttons leave Logic Rules, the lists and General Settings alone" {
    var st = Settings.defaults();
    var rng = Rng.init(1);
    _ = randomizeSettings(&st, &rng, .all);
    try std.testing.expect(st.is(.logic_rules, settings.spec(.logic_rules).default.choice));
    try std.testing.expectEqual(@as(usize, 0), st.startingInventory().len);
    try std.testing.expectEqual(settings.spec(.create_spoiler).default.boolean, st.flag(.create_spoiler));
    try std.testing.expect(hasRandomizable(.{ .tab = "Quality of Life" }));
    try std.testing.expect(!hasRandomizable(.{ .tab = "Exclusions" }));
}
