//! Progressive items in event flows: a character gift, minigame prize or Business Scrub sale hands out the next tier
//! of its line that the player doesn't own yet (logic/progressive.zig).
//!
//! Each hand-over node G becomes a chain of the game's own pouch query, PouchSystemActor.EventQueryIsExistInPouch
//! {Actor, Num=1} (case 0: owned, case 1: not owned; the Bombchu Bowling flow gives the Biggest Bomb Bag on case 0),
//! asked from the highest tier down:
//!
//!     own tier 2? -> G with tier 3
//!     own tier 1? -> G with tier 2
//!     else        -> G with tier 1
//!
//! The first query takes G's place (same index), so every event and entry point that led to G now leads to the
//! checks; G itself moves to a new index with its name, so later patches that look it up by name (the scrubs' sale
//! lines) still find it, and its copies are named "<G>_RandoProgressive<tier>".
//!
//! A node that only shows the item window of an item handed over just before (world.EventRef.shows_item_only) asks
//! for the highest tier owned instead, which by then is the one just handed over.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const evfl_view = @import("../formats/evfl_view.zig");
const progressive = @import("../logic/progressive.zig");
const flows = @import("flows.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const Container = evfl.Container;

const pouch_actor_name = "PouchSystemActor";
const owns_query = "EventQueryIsExistInPouch";
/// the pouch query's cases (dump: MiniGame_BombchuBowling Event76)
const case_owned: u32 = 0;
const case_not_owned: u32 = 1;
/// the suffix of a hand-over's copies, before the tier number (textpatches.zig finds the scrubs' copies by it)
pub const copy_suffix = "_RandoProgressive";

/// One hand-over to branch.
pub const HandOver = struct {
    /// the file offset of the node's item parameter (world.EventRef.offset)
    item_offset: usize,
    chain: *const progressive.Chain,
    /// the actor each tier is handed over as, lowest first (a held-up Ocarina's is its display actor)
    tier_actors: []const []const u8,
    shows_item_only: bool,
};

/// the infix of the tier checks' names ("<G>_RandoOwns<tier>")
const check_infix = "_RandoOwns";

/// True for one of the tier checks made here. Later flow edits that look for a hand-over (qol.memoryGameAllRewards)
/// find these in its place.
pub fn isOwnsCheck(event_name: []const u8) bool {
    return std.mem.indexOf(u8, event_name, check_infix) != null;
}

/// True for an event that is a copy of hand-over `original` made here.
pub fn isCopyOf(event_name: []const u8, original: []const u8) bool {
    if (!std.mem.startsWith(u8, event_name, original)) return false;
    return std.mem.startsWith(u8, event_name[original.len..], copy_suffix);
}

/// The flow `data` (with its item edits already made; `view` read from it) with each hand-over branched.
pub fn branchHandOvers(allocator: Allocator, data: []const u8, view: *const evfl_view.View, hand_overs: []const HandOver, rel: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, rel, progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} has no flowchart", .{rel});
    const query = try pouchQuery(fc, allocator, rel, progress);

    var branched: std.ArrayList(u16) = .empty;
    var added_calls: std.ArrayList(u16) = .empty;
    for (hand_overs) |hand_over| {
        const found = findItemParameter(view, fc, hand_over.item_offset) orelse
            return progress.fail(error.NotAsExpected, "{s}: no hand-over at offset {d}", .{ rel, hand_over.item_offset });
        // two edits of one node (a location listed twice) branch it once
        if (std.mem.indexOfScalar(u16, branched.items, found.event) != null) continue;
        branched.append(allocator, found.event) catch return error.OutOfMemory;
        try branchOne(allocator, fc, query, found, hand_over, &added_calls);
    }
    // an entry point lists the sub flow calls it reaches (flows.listReachedCalls: a missing one hung the game)
    try flows.listReachedCalls(allocator, fc, added_calls.items);
    return flows.writeBack(allocator, &doc, rel, progress);
}

/// Branches one hand-over of a flowchart being edited (the reward scenes' item window, npcrewards.zig): event
/// `event_index`, whose parameter `parameter` names the item.
pub fn branchEvent(allocator: Allocator, fc: *evfl.Flowchart, event_index: u16, parameter: []const u8, hand_over: HandOver, rel: []const u8, progress: *Progress) PatchError!void {
    const query = try pouchQuery(fc, allocator, rel, progress);
    var added_calls: std.ArrayList(u16) = .empty;
    try branchOne(allocator, fc, query, .{ .event = event_index, .parameter = parameter }, hand_over, &added_calls);
    try flows.listReachedCalls(allocator, fc, added_calls.items);
}

const FoundParameter = struct { event: u16, parameter: []const u8 };

/// The event and parameter name whose string value sits at `offset`. The view and the document read the same bytes,
/// so the view's event index is the document's (the names are compared to be sure).
fn findItemParameter(view: *const evfl_view.View, fc: *const evfl.Flowchart, offset: usize) ?FoundParameter {
    for (view.flowcharts) |view_fc| {
        if (!std.mem.eql(u8, view_fc.name, fc.name)) continue;
        for (view_fc.events) |e| {
            const params = e.params orelse continue;
            for (params.offsets, 0..) |value_offset, k| {
                if (value_offset != offset) continue;
                if (e.index >= fc.events.items.len or !std.mem.eql(u8, fc.events.items[e.index].name, e.name)) return null;
                return .{ .event = @intCast(e.index), .parameter = params.names[k] };
            }
        }
    }
    return null;
}

/// (actor, query) of the pouch query, adding PouchSystemActor when the flow has none. Why its parameters are copied
/// from another system actor: a named actor without them crashed the game (OotrR; faststart.giveAtStart does the
/// same).
fn pouchQuery(fc: *evfl.Flowchart, allocator: Allocator, rel: []const u8, progress: *Progress) PatchError![2]u16 {
    if (fc.findActor(pouch_actor_name) == null) {
        const template = fc.findActor("GameSystemActor") orelse fc.findActor("EventSystemActor") orelse fc.findActor("GameDataActor") orelse
            anySystemActor(fc) orelse
            return progress.fail(error.NotAsExpected, "{s} has no system actor to model {s} on", .{ rel, pouch_actor_name });
        const template_params = fc.actors.items[template].params;
        const params = if (template_params) |p| try p.clone(allocator) else try Container.create(allocator);
        fc.actors.append(allocator, evfl.Actor{ .name = pouch_actor_name, .params = params }) catch return error.OutOfMemory;
    }
    return flows.requireQuery(fc, allocator, pouch_actor_name, owns_query, progress);
}

/// Any "...SystemActor" of the flow (a scene's flow may only have UISystemActor: Dm_MelodyGet_Sun_03).
fn anySystemActor(fc: *const evfl.Flowchart) ?u16 {
    for (fc.actors.items, 0..) |actor, i| {
        if (std.mem.endsWith(u8, actor.name, "SystemActor") and actor.secondary_name.len == 0) return @intCast(i);
    }
    return null;
}

fn branchOne(allocator: Allocator, fc: *evfl.Flowchart, query: [2]u16, found: FoundParameter, hand_over: HandOver, added_calls: *std.ArrayList(u16)) PatchError!void {
    const tiers = hand_over.chain.tiers;
    if (hand_over.tier_actors.len != tiers.len) return error.NotAsExpected;
    const original = fc.events.items[found.event];
    const is_call = original.kind == .sub_flow;

    // the hand-over itself, moved: tier 1
    var first_tier = try original.clone(allocator);
    try setItem(allocator, &first_tier, found.parameter, hand_over.tier_actors[0]);
    const first_tier_index = try fc.addEvent(allocator, first_tier);
    if (is_call) added_calls.append(allocator, first_tier_index) catch return error.OutOfMemory;

    // its copies for the other tiers
    const copies = allocator.alloc(u16, tiers.len) catch return error.OutOfMemory;
    copies[0] = first_tier_index;
    for (1..tiers.len) |t| {
        var copy = try original.clone(allocator);
        copy.name = std.fmt.allocPrint(allocator, "{s}{s}{d}", .{ original.name, copy_suffix, t + 1 }) catch return error.OutOfMemory;
        try setItem(allocator, &copy, found.parameter, hand_over.tier_actors[t]);
        copies[t] = try fc.addEvent(allocator, copy);
        if (is_call) added_calls.append(allocator, copies[t]) catch return error.OutOfMemory;
    }

    // the checks, built from the bottom one up; the top one takes the hand-over's place
    var otherwise: u16 = first_tier_index;
    for (1..tiers.len) |t| {
        // a hand-over: own tier t (1-based: tiers[t - 1]) -> hand over tier t + 1. An item window: own tier t + 1
        // -> show tier t + 1
        const asked = if (hand_over.shows_item_only) tiers[t] else tiers[t - 1];
        var cases: std.ArrayList(evfl.Case) = .empty;
        cases.append(allocator, .{ .value = case_owned, .event = copies[t] }) catch return error.OutOfMemory;
        cases.append(allocator, .{ .value = case_not_owned, .event = otherwise }) catch return error.OutOfMemory;
        const check = evfl.Event{
            .name = std.fmt.allocPrint(allocator, "{s}{s}{d}", .{ original.name, check_infix, t }) catch return error.OutOfMemory,
            .kind = .{ .switch_ = .{
                .actor = query[0],
                .query = query[1],
                .cases = cases,
                .params = try Container.from(allocator, &.{
                    .{ .name = "Actor", .value = .{ .string = asked.pouch_actor } },
                    .{ .name = "Num", .value = .{ .int = 1 } },
                }),
            } },
        };
        if (t == tiers.len - 1) {
            fc.events.items[found.event] = check;
        } else {
            otherwise = try fc.addEvent(allocator, check);
        }
    }

    // an entry point that listed the call at its old index now lists its moved copy (the copies are added after)
    if (is_call) for (fc.entry_points.items) |*entry| {
        for (entry.sub_flow_events.items) |*listed| {
            if (listed.* == found.event) listed.* = first_tier_index;
        }
    };
}

fn setItem(allocator: Allocator, event: *evfl.Event, parameter: []const u8, actor: []const u8) PatchError!void {
    const params = event.params() orelse return error.NotAsExpected;
    try params.put(allocator, parameter, .{ .string = actor });
}

test "a copy's name marks its original" {
    try std.testing.expect(isCopyOf("Event322_RandoProgressive2", "Event322"));
    try std.testing.expect(!isCopyOf("Event3220_RandoProgressive2", "Event322"));
    try std.testing.expect(!isCopyOf("Event322", "Event322"));
}

test "a hand-over branches on the tiers owned, highest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();

    // Start: wait, then GetPouchContent<GetPouchContentByActorName> {ActorName=Item_Gauntlet_Goron}
    var fc = evfl.Flowchart{ .name = "TestGift" };
    var system = evfl.Actor{ .name = "GameSystemActor", .params = try Container.create(a) };
    system.actions.append(a, "EventWait") catch unreachable; // why unreachable: an arena in a test
    fc.actors.append(a, system) catch unreachable;
    _ = try fc.addEvent(a, evfl.makeAction("Event0", .{ 0, 0 }, 1, try Container.from(a, &.{.{ .name = "Frames", .value = .{ .int = 1 } }})));
    _ = try fc.addEvent(a, evfl.makeSubFlow("Event1", "GetPouchContent", "GetPouchContentByActorName", evfl.NONE, try Container.from(a, &.{
        .{ .name = "ActorName", .value = .{ .string = "Item_Gauntlet_Goron" } },
    })));
    var entry = evfl.EntryPoint{ .name = "Start", .main_event = 0 };
    entry.sub_flow_events.append(a, 1) catch unreachable;
    fc.entry_points.append(a, entry) catch unreachable;
    const doc = evfl.Document{ .name = "TestGift", .flowchart = &fc };
    const data = try evfl.write(a, &doc);

    var view = try evfl_view.View.init(a, data);
    const gift = &view.flowcharts[0].events[1];
    const offset = gift.params.?.stringOffset("ActorName").?;
    const chain = progressive.chainOfProgressiveItem("Progressive_Strength").?;
    const actors = [_][]const u8{ "Item_Gauntlet_Goron", "Item_Gauntlet_Silver", "Item_Gauntlet_Gold" };
    const out = try branchHandOvers(a, data, &view, &.{.{ .item_offset = offset, .chain = chain, .tier_actors = &actors, .shows_item_only = false }}, "TestGift", &progress);

    const result = (try evfl.read(a, out)).flowchart.?;
    // the wait still leads to index 1, now the check for the Silver Gauntlets
    const top = result.events.items[1];
    try std.testing.expect(result.isQuery(&top, pouch_actor_name, owns_query));
    try std.testing.expectEqualStrings("Armor_Adult_Gauntlet_Silver", top.params().?.getString("Actor").?);
    const owned_silver = result.events.items[top.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("Item_Gauntlet_Gold", owned_silver.params().?.getString("ActorName").?);
    const lower = result.events.items[top.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Armor_Child_Gauntlet_Goron", lower.params().?.getString("Actor").?);
    const owned_bracelet = result.events.items[lower.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("Item_Gauntlet_Silver", owned_bracelet.params().?.getString("ActorName").?);
    const nothing_owned = result.events.items[lower.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Event1", nothing_owned.name);
    try std.testing.expectEqualStrings("Item_Gauntlet_Goron", nothing_owned.params().?.getString("ActorName").?);
    // the entry point lists all three calls
    try std.testing.expectEqual(@as(usize, 3), result.entry_points.items[0].sub_flow_events.items.len);
    for (result.entry_points.items[0].sub_flow_events.items) |listed| try std.testing.expect(result.events.items[listed].kind == .sub_flow);
}
