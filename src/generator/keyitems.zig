//! Key rings and dungeon boss keys: dungeon keys that can be placed outside their dungeon. Adapted from OotrR
//! (https://github.com/Mozencaz/OotrR, src/oot_rando/patching/key_adapter.py; MIT License, Copyright (c) 2026
//! Mozencaz). See THIRD_PARTY.md.
//!
//! The remake's small and boss keys are generic: picking one up credits it to the dungeon Link is standing in (native
//! EventGetDungeonSmallKey and the like), so a key found elsewhere would count for the wrong dungeon. Each dungeon
//! keeps its keys in the save entry DungeonInfo.<folder>: SmallKeyNum (keys held, what the locked doors use),
//! SmallKeyTotalNum (keys found) and IsGetBossKey. So, as in OotrR:
//!
//! - a dungeon gets a key ring, `Item_KeyRing_<dungeon>` (every small key at once), and each temple a boss key item,
//!   `Item_BossKey_<dungeon>`: new key items built on the Forest Medallion with the native key's model
//!   (pickups.PickupCloner.keyItem), placeable anywhere;
//! - each gets a saved IsGet.<actor> flag, listed in the IsGet structure so the game sets it when the item reaches the
//!   pouch, from a chest, a pickup or a gift (gamedata.addIsGetMember);
//! - every item get ends in ActionGuide/ActionGuide, which now first checks each key item of the seed: a key ring got
//!   and not applied yet adds its keys to SmallKeyNum and SmallKeyTotalNum once (saved flag RandoKeyRing.<dungeon>),
//!   a boss key got sets IsGetBossKey. A key got another way is applied at the next item get.
//!
//! OotrR also gives each new item a cloned pickup event (AI) that writes its IsGet flag; that AI-graph edit isn't
//! ported, the IsGet structure entry is what records the item. Not yet tested in-game (OotrR: not validated either).
//!
//! Maps & Compasses Anywhere (new here, not in OotrR) works the same way: the game's map and compass are generic too
//! (Dm_SY_Treasurebox's EventGetDungeonMap / Compass credit the dungeon Link is in), so each map dungeon
//! (logic.map_dungeons) gets `Item_Map_<short>` and `Item_Compass_<short>` on the native map / compass model, and
//! the hook sets DungeonInfo.<folder>.IsGetMap / IsGetCompass once its item is got (the flags Start With sets).

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const logic = @import("../logic/logic.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const pickups = @import("pickups.zig");
const gamedata = @import("gamedata.zig");
const flows = @import("flows.zig");
const textpatches = @import("textpatches.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const Container = evfl.Container;

pub const action_guide_flow = "Event/EventFlow/ActionGuide.bfevfl.zs";
const action_guide_entry = "ActionGuide";
/// the saved flag that marks a key ring as applied
const applied_prefix = "RandoKeyRing.";
const small_key_model = "Item_Dungeon_SmallKey";
const boss_key_model = "Item_Dungeon_BossKey";
const map_model = "Item_Dungeon_Map";
const compass_model = "Item_Dungeon_Compass";
/// the IsGet flag every new key item's own flag is shaped like
const isget_template = "IsGet.Item_Medal_Forest";
const item_messages = "ActorMsg/PouchContent.msbt";

pub const Kind = enum { ring, boss_key, map, compass };

pub const KeyItem = struct {
    kind: Kind,
    /// the dungeon's folder: its save entry is DungeonInfo.<folder>
    folder: []const u8,
    /// its English name ("Forest Temple")
    name: []const u8,
    /// a key ring: how many small keys it gives
    keys: u8 = 0,
    /// "Item_KeyRing_ForestTemple", "Item_Map_Forest"
    actor: []const u8,
};

/// The key items of this seed (Plan.options): one per dungeon with a key ring, one per temple whose boss key is an
/// item, and with Maps & Compasses Anywhere a map and a compass per map dungeon.
pub fn active(allocator: Allocator, options: *const logic.Options) error{OutOfMemory}![]KeyItem {
    var out: std.ArrayList(KeyItem) = .empty;
    for (logic.key_dungeons, 0..) |d, i| {
        if (options.key_ring[i]) {
            try out.append(allocator, .{ .kind = .ring, .folder = d.folder, .name = d.name, .keys = d.keys, .actor = try std.fmt.allocPrint(allocator, "Item_{s}", .{@tagName(d.ring)}) });
        }
        if (options.boss_key_item[i]) {
            if (d.boss) |b| try out.append(allocator, .{ .kind = .boss_key, .folder = d.folder, .name = d.name, .actor = try std.fmt.allocPrint(allocator, "Item_{s}", .{@tagName(b)}) });
        }
    }
    if (options.map_items) {
        for (logic.map_dungeons, 0..) |d, i| {
            for ([_]bool{ false, true }) |compass| {
                const key = try logic.mapItemKey(allocator, i, compass);
                try out.append(allocator, .{ .kind = if (compass) .compass else .map, .folder = d.folder, .name = d.name, .actor = try std.fmt.allocPrint(allocator, "Item_{s}", .{key}) });
            }
        }
    }
    return out.items;
}

/// The save entry field a key item sets (a key ring adds to two: savedFields).
fn modelOf(kind: Kind) []const u8 {
    return switch (kind) {
        .ring => small_key_model,
        .boss_key => boss_key_model,
        .map => map_model,
        .compass => compass_model,
    };
}

/// The DungeonInfo fields a key item writes (the hook reads and writes them: they must be the game's own).
fn savedFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .ring => &.{ "SmallKeyNum", "SmallKeyTotalNum" },
        .boss_key => &.{"IsGetBossKey"},
        .map => &.{"IsGetMap"},
        .compass => &.{"IsGetCompass"},
    };
}

/// Builds every key item of the seed: packs and RSDB rows (through `cloner`, before anything clones them into a
/// pickup or a shelf), saved flags, get texts in every language and the ActionGuide hook. Returns how many.
pub fn build(world: *World, patches: *patchset.PatchSet, cloner: *pickups.PickupCloner, options: *const logic.Options, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    const items = try active(a, options);
    if (items.len == 0) return 0;
    for (items) |k| try cloner.keyItem(k.actor, modelOf(k.kind));
    try addFlags(world, patches, items, progress);
    try addTexts(world, patches, items, progress);
    const orig = try patches.read(action_guide_flow);
    const hooked = try addHook(a, orig.data, items, progress);
    try patches.emitZs(action_guide_flow, orig, hooked);
    return items.len;
}

fn dungeonData(allocator: Allocator, folder: []const u8, field: []const u8) PatchError![]const u8 {
    return std.fmt.allocPrint(allocator, "DungeonInfo.{s}.{s}", .{ folder, field }) catch error.OutOfMemory;
}

/// IsGet.<actor> for every key item (and its IsGet structure entry), RandoKeyRing.<dungeon> for every key ring.
fn addFlags(world: *World, patches: *patchset.PatchSet, items: []const KeyItem, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const rel = try world.find(a, "GameData", "GameDataList");
    const original = try patches.read(rel);
    var gd = try gamedata.GameDataPatcher.init(a, rel, original.data, original.dictionary, progress);
    for (items) |k| {
        // the hook reads and writes these: they must be the game's own saved entries
        for (savedFields(k.kind)) |f| {
            const name = try dungeonData(a, k.folder, f);
            if (!gd.hasFlag(name)) return progress.fail(error.NotAsExpected, "the save data has no {s}", .{name});
        }
        const flag = std.fmt.allocPrint(a, "IsGet.{s}", .{k.actor}) catch return error.OutOfMemory;
        if (!try gd.addSavedBool(flag, false, isget_template)) return progress.fail(error.NotAsExpected, "the save data already has {s}", .{flag});
        if (!try gd.addIsGetMember(k.actor)) return progress.fail(error.NotAsExpected, "the IsGet structure already has {s}", .{k.actor});
        if (k.kind == .ring) {
            const applied = std.fmt.allocPrint(a, "{s}{s}", .{ applied_prefix, k.folder }) catch return error.OutOfMemory;
            if (!try gd.addSavedBool(applied, false, null)) return progress.fail(error.NotAsExpected, "the save data already has {s}", .{applied});
        }
    }
    try gd.finish(patches);
}

/// The item's name, description and get message in every language (English everywhere, like the hints). Without them
/// the item window has no text and never closes (OotrR).
fn addTexts(world: *World, patches: *patchset.PatchSet, items: []const KeyItem, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    var texts: std.ArrayList(@import("../formats/msbt.zig").NewText) = .empty;
    for (items) |k| {
        const n = k.name;
        const pairs: [4][2][]const u8 = switch (k.kind) {
            .ring => .{
                .{ "Name", try fmt(a, "Key Ring: {s}", .{n}) },
                .{ "Caption", try fmt(a, "Every small key of the {s}.", .{n}) },
                .{ "GetMessage", try fmt(a, "You got the {s} key ring!", .{n}) },
                .{ "GetCaption", "Its locked doors can now open." },
            },
            .boss_key => .{
                .{ "Name", try fmt(a, "Boss Key: {s}", .{n}) },
                .{ "Caption", try fmt(a, "The boss key of the {s}.", .{n}) },
                .{ "GetMessage", try fmt(a, "You got the {s} boss key!", .{n}) },
                .{ "GetCaption", "It opens the boss door of this temple." },
            },
            .map => .{
                .{ "Name", try fmt(a, "Map: {s}", .{n}) },
                .{ "Caption", try fmt(a, "The dungeon map of {s}.", .{n}) },
                .{ "GetMessage", try fmt(a, "You got the {s} map!", .{n}) },
                .{ "GetCaption", "Its rooms now show on the pause map." },
            },
            .compass => .{
                .{ "Name", try fmt(a, "Compass: {s}", .{n}) },
                .{ "Caption", try fmt(a, "The compass of {s}.", .{n}) },
                .{ "GetMessage", try fmt(a, "You got the {s} compass!", .{n}) },
                .{ "GetCaption", "Its chests and boss now show on the pause map." },
            },
        };
        for (pairs) |p| {
            texts.append(a, .{ .label = try fmt(a, "{s}_{s}", .{ k.actor, p[0] }), .text = p[1] }) catch return error.OutOfMemory;
        }
    }
    const done = try textpatches.addToArchives(world, patches, item_messages, texts.items, "key items", progress);
    if (done == 0) return progress.fail(error.NotAsExpected, "no message archive holds {s}", .{item_messages});
}

fn fmt(allocator: Allocator, comptime format: []const u8, args: anytype) PatchError![]const u8 {
    return std.fmt.allocPrint(allocator, format, args) catch error.OutOfMemory;
}

/// Puts the key checks in front of ActionGuide/ActionGuide, the end of every item get. Each item's checks lead to the
/// next item's, the last to the entry's original first event. A Bool switch takes case 0 when the flag is true (as the
/// game's own flows). OotrR: key_adapter.add_key_hook.
pub fn addHook(allocator: Allocator, data: []const u8, items: []const KeyItem, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "ActionGuide", progress);
    const fc = try flows.expectFlowchart(&doc, "ActionGuide", progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoKey")) return progress.fail(error.NotAsExpected, "ActionGuide already has the key checks", .{});
    }
    const entry = fc.entryPoint(action_guide_entry) orelse return progress.fail(error.NotAsExpected, "ActionGuide has no {s} entry", .{action_guide_entry});
    if (entry.main_event == evfl.NONE) return progress.fail(error.NotAsExpected, "ActionGuide's {s} entry is empty", .{action_guide_entry});
    // GameDataActor is already in the flow with its parameters (a named actor without them crashed the game, OotrR)
    const is_bool = try flows.requireQuery(fc, allocator, "GameDataActor", "EventQueryIsGameDataBool", progress);
    const set_bool = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataBool", progress);
    const add_int = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerAddOrSubGameDataInt", progress);

    var following = entry.main_event;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const k = items[i];
        const stem = k.actor["Item_".len..];
        const got = try fmt(allocator, "IsGet.{s}", .{k.actor});
        if (k.kind == .ring) {
            const applied = try fmt(allocator, "{s}{s}", .{ applied_prefix, k.folder });
            const mark = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "RandoKeyApplied_{s}", .{stem}), set_bool, following, try Container.from(allocator, &.{
                .{ .name = "GameDataName", .value = .{ .string = applied } },
                .{ .name = "Value", .value = .{ .bool = true } },
                .{ .name = "Index", .value = .{ .int = -1 } },
            })));
            // keys found too, as the native key get credits them: held keys alone didn't show in the dungeon (OotrR)
            const found = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "RandoKeyFound_{s}", .{stem}), add_int, mark, try Container.from(allocator, &.{
                .{ .name = "GameDataName", .value = .{ .string = try dungeonData(allocator, k.folder, "SmallKeyTotalNum") } },
                .{ .name = "Value", .value = .{ .int = k.keys } },
                .{ .name = "Index", .value = .{ .int = -1 } },
            })));
            const give = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "RandoKeyGive_{s}", .{stem}), add_int, found, try Container.from(allocator, &.{
                .{ .name = "GameDataName", .value = .{ .string = try dungeonData(allocator, k.folder, "SmallKeyNum") } },
                .{ .name = "Value", .value = .{ .int = k.keys } },
                .{ .name = "Index", .value = .{ .int = -1 } },
            })));
            const done = try boolSwitch(fc, allocator, try fmt(allocator, "RandoKeyDone_{s}", .{stem}), is_bool, applied, following, give);
            following = try boolSwitch(fc, allocator, try fmt(allocator, "RandoKeyHeld_{s}", .{stem}), is_bool, got, done, following);
        } else {
            // a boss key, map or compass: its one DungeonInfo Bool
            const give = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "RandoKeyGive_{s}", .{stem}), set_bool, following, try Container.from(allocator, &.{
                .{ .name = "GameDataName", .value = .{ .string = try dungeonData(allocator, k.folder, savedFields(k.kind)[0]) } },
                .{ .name = "Value", .value = .{ .bool = true } },
                .{ .name = "Index", .value = .{ .int = -1 } },
            })));
            following = try boolSwitch(fc, allocator, try fmt(allocator, "RandoKeyHeld_{s}", .{stem}), is_bool, got, give, following);
        }
    }
    entry.main_event = following;
    return flows.writeBack(allocator, &doc, "ActionGuide", progress);
}

/// A switch on saved Bool `flag`: `when_true` (case 0) or `when_false` (case 1).
fn boolSwitch(fc: *evfl.Flowchart, allocator: Allocator, name: []const u8, query: [2]u16, flag: []const u8, when_true: u16, when_false: u16) PatchError!u16 {
    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = 0, .event = when_true }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = 1, .event = when_false }) catch return error.OutOfMemory;
    return fc.addEvent(allocator, .{ .name = name, .kind = .{ .switch_ = .{
        .actor = query[0],
        .query = query[1],
        .cases = cases,
        .params = try Container.from(allocator, &.{
            .{ .name = "GameDataName", .value = .{ .string = flag } },
            .{ .name = "Index", .value = .{ .int = -1 } },
        }),
    } } });
}
