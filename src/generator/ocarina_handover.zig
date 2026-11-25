//! An Ocarina handed over held up by Link (a Business Scrub sale, a character's gift) finishes the way the game's own
//! Ocarina scene does.
//!
//! Why: a held-up hand-over names the Ocarina's display actor (pickups.chestDisplayActor, "Item_Rando_Ocarina_<x>"),
//! because the real Ocarina actor is equipment Link wears and crashed the game held up (issue #5). The game picks an
//! item's tutorial and button setup by the actor it is handed (ActionGuide:ActionGuide {ActorName}), so with the
//! display actor the Ocarina came without its tutorial, and the player couldn't use it (test report, OCARINA1). The
//! game's own Fairy Ocarina scene (Dm_Kokiri_0155) adds Item_Ocarina_Fairy silently, and the Ocarina tutorial
//! (ActionGuide:OpenActionGuideSceenForOcarina) plays on the first arrival in Hyrule Field after it
//! (Dm_SY_BancChangeArrive), which Shuffle Ocarinas skips.
//!
//! So after hand-over G (which led to N), only when the player now has the display actor (a scrub sale that was
//! turned down hands nothing over):
//!
//!     own the display actor? (PouchSystemActor.EventQueryIsExistInPouch, case 0: owned)
//!       yes -> remove the display actor (Num -1, as the game removes the Weird Egg or a Magic Bean)
//!           -> add the real Ocarina silently (as Dm_Kokiri_0155 does)
//!           -> ActionGuide:ActionGuide {ActorName = the real Ocarina} (what the hand-over runs for any item)
//!           -> ActionGuide:OpenActionGuideSceenForOcarina (the Ocarina tutorial; shown once by the game)
//!           -> N
//!       no  -> N
//!
//! Removing first: whether the display actor's pouch entry is the real Ocarina (its ActorName) or one of its own, the
//! player ends with the real Ocarina once.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const evfl_view = @import("../formats/evfl_view.zig");
const flows = @import("flows.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const Container = evfl.Container;

const pouch_actor_name = "PouchSystemActor";
const owns_query = "EventQueryIsExistInPouch";
const add_or_remove_action = "EventTriggerAddOrRemovePouchContent";
/// the pouch query's "owned" case (dump: MiniGame_BombchuBowling Event76)
const case_owned: u32 = 0;
const case_not_owned: u32 = 1;
const action_guide_flow = "ActionGuide";
const item_action_guide_entry = "ActionGuide";
const ocarina_tutorial_entry = "OpenActionGuideSceenForOcarina";
/// the infix of the added events' names ("<G>_RandoOcarina<step>")
const added_infix = "_RandoOcarina";

/// One held-up Ocarina hand-over.
pub const HandOver = struct {
    /// the file offset of the hand-over's item parameter (world.EventRef.offset)
    item_offset: usize,
    /// the actor the hand-over now names ("Item_Rando_Ocarina_Time")
    display_actor: []const u8,
    /// the real Ocarina ("Item_Ocarina_Time")
    real_actor: []const u8,
};

/// The flow `data` (`view` read from it) with each hand-over followed by the real Ocarina and its tutorial.
pub fn finishHandOvers(allocator: Allocator, data: []const u8, view: *const evfl_view.View, hand_overs: []const HandOver, rel: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, rel, progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} has no flowchart", .{rel});
    try ensurePouchActor(fc, allocator, rel, progress);
    const query = try flows.requireQuery(fc, allocator, pouch_actor_name, owns_query, progress);
    const add_or_remove = try flows.requireAction(fc, allocator, pouch_actor_name, add_or_remove_action, progress);

    var finished: std.ArrayList(u16) = .empty;
    var added_calls: std.ArrayList(u16) = .empty;
    for (hand_overs) |hand_over| {
        const event_index = findEventWithParameterAt(view, fc, hand_over.item_offset) orelse
            return progress.fail(error.NotAsExpected, "{s}: no hand-over at offset {d}", .{ rel, hand_over.item_offset });
        // a location listed twice edits one node once
        if (std.mem.indexOfScalar(u16, finished.items, event_index) != null) continue;
        finished.append(allocator, event_index) catch return error.OutOfMemory;
        try finishOne(allocator, fc, query, add_or_remove, event_index, hand_over, &added_calls);
    }
    // an entry point lists the sub flow calls it reaches (flows.listReachedCalls: a missing one hung the game)
    try flows.listReachedCalls(allocator, fc, added_calls.items);
    return flows.writeBack(allocator, &doc, rel, progress);
}

/// The event whose parameter value sits at `offset`. The view and the document read the same bytes, so the view's
/// event index is the document's (the names are compared to be sure).
fn findEventWithParameterAt(view: *const evfl_view.View, fc: *const evfl.Flowchart, offset: usize) ?u16 {
    for (view.flowcharts) |view_fc| {
        if (!std.mem.eql(u8, view_fc.name, fc.name)) continue;
        for (view_fc.events) |e| {
            const params = e.params orelse continue;
            for (params.offsets) |value_offset| {
                if (value_offset != offset) continue;
                if (e.index >= fc.events.items.len or !std.mem.eql(u8, fc.events.items[e.index].name, e.name)) return null;
                return @intCast(e.index);
            }
        }
    }
    return null;
}

/// Adds PouchSystemActor when the flow has none, with the parameters of one of its system actors. Why copied: a named
/// actor without them crashed the game (OotrR; faststart.giveAtStart does the same).
fn ensurePouchActor(fc: *evfl.Flowchart, allocator: Allocator, rel: []const u8, progress: *Progress) PatchError!void {
    try flows.ensureSystemActor(fc, allocator, pouch_actor_name, rel, progress);
}

/// The parameters of a silent pouch change, as the game's own scenes write them (Dm_Kokiri_0155 Event68).
fn pouchChange(allocator: Allocator, actor: []const u8, num: i32) PatchError!*Container {
    return Container.from(allocator, &.{
        .{ .name = "Num", .value = .{ .int = num } },
        .{ .name = "IsEquipDIrect", .value = .{ .bool = false } },
        .{ .name = "IsSetMessageTargetActorName", .value = .{ .bool = true } },
        .{ .name = "Actor", .value = .{ .string = actor } },
        .{ .name = "IsGetEvent", .value = .{ .bool = false } },
    });
}

fn addedName(allocator: Allocator, original: []const u8, step: []const u8) PatchError![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ original, added_infix, step }) catch error.OutOfMemory;
}

fn finishOne(allocator: Allocator, fc: *evfl.Flowchart, query: [2]u16, add_or_remove: [2]u16, event_index: u16, hand_over: HandOver, added_calls: *std.ArrayList(u16)) PatchError!void {
    const original_name = fc.events.items[event_index].name;
    const after = (fc.events.items[event_index].nextPtr() orelse return error.NotAsExpected).*;
    const check = try addSwap(allocator, fc, query, add_or_remove, original_name, .{ .display_actor = hand_over.display_actor, .real_actor = hand_over.real_actor }, after, added_calls);
    // addEvent may have moved the events: look the hand-over up again
    (fc.events.items[event_index].nextPtr() orelse return error.NotAsExpected).* = check;
}

/// An Ocarina's display actor and the real Ocarina it stands for.
pub const Ocarina = struct { display_actor: []const u8, real_actor: []const u8 };

/// Adds the check, swap, add, item guide and tutorial for `ocarina` (see the top of this file), leading on to
/// `after`, with names starting `name_prefix`. Returns the check's index.
fn addSwap(allocator: Allocator, fc: *evfl.Flowchart, query: [2]u16, add_or_remove: [2]u16, name_prefix: []const u8, ocarina: Ocarina, after: u16, added_calls: *std.ArrayList(u16)) PatchError!u16 {
    // built from the end back, so each event knows the one after it
    const tutorial = try fc.addEvent(allocator, evfl.makeSubFlow(try addedName(allocator, name_prefix, "Tutorial"), action_guide_flow, ocarina_tutorial_entry, after, null));
    const item_guide = try fc.addEvent(allocator, evfl.makeSubFlow(try addedName(allocator, name_prefix, "Guide"), action_guide_flow, item_action_guide_entry, tutorial, try Container.from(allocator, &.{
        .{ .name = "ActorName", .value = .{ .string = ocarina.real_actor } },
    })));
    added_calls.append(allocator, tutorial) catch return error.OutOfMemory;
    added_calls.append(allocator, item_guide) catch return error.OutOfMemory;
    const add_real = try fc.addEvent(allocator, evfl.makeAction(try addedName(allocator, name_prefix, "Add"), add_or_remove, item_guide, try pouchChange(allocator, ocarina.real_actor, 1)));
    const remove_display = try fc.addEvent(allocator, evfl.makeAction(try addedName(allocator, name_prefix, "Swap"), add_or_remove, add_real, try pouchChange(allocator, ocarina.display_actor, -1)));

    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = case_owned, .event = remove_display }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = case_not_owned, .event = after }) catch return error.OutOfMemory;
    return fc.addEvent(allocator, evfl.Event{
        .name = try addedName(allocator, name_prefix, "Check"),
        .kind = .{ .switch_ = .{
            .actor = query[0],
            .query = query[1],
            .cases = cases,
            .params = try Container.from(allocator, &.{
                .{ .name = "Actor", .value = .{ .string = ocarina.display_actor } },
                .{ .name = "Num", .value = .{ .int = 1 } },
            }),
        } },
    });
}

// ------------------------------------------------------------------------------------------------------ chests
// A chest hands its item over in the game's chest scenes (Dm_SY_Treasurebox for big chests, Dm_SY_TreasureboxSmall
// for small ones), not in a flow of its own. Both call ActionGuide:ActionGuide {ActorName = the chest's ContentName}
// once the item is added (dump: Dm_SY_Treasurebox Event13, Dm_SY_TreasureboxSmall Event31), so each Ocarina's check
// goes right after that call: after any chest, a player holding an Ocarina's display actor gets it swapped for the
// real one and sees the tutorial. Other chests only cost the checks.

/// The chest scene `data` with the checks of `ocarinas` after its item guide call(s).
pub fn finishChestOpenings(allocator: Allocator, data: []const u8, ocarinas: []const Ocarina, rel: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, rel, progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} has no flowchart", .{rel});
    try ensurePouchActor(fc, allocator, rel, progress);
    const query = try flows.requireQuery(fc, allocator, pouch_actor_name, owns_query, progress);
    const add_or_remove = try flows.requireAction(fc, allocator, pouch_actor_name, add_or_remove_action, progress);

    var guide_calls: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |e, i| {
        if (e.kind != .sub_flow) continue;
        const call = e.kind.sub_flow;
        if (!std.mem.eql(u8, call.flowchart, action_guide_flow) or !std.mem.eql(u8, call.entry_point, item_action_guide_entry)) continue;
        const params = call.params orelse continue;
        const named = params.get("ActorName") orelse continue;
        if (named != .argument or !std.mem.eql(u8, named.argument, chest_content_argument)) continue;
        guide_calls.append(allocator, @intCast(i)) catch return error.OutOfMemory;
    }
    if (guide_calls.items.len == 0) return progress.fail(error.NotAsExpected, "{s}: no item guide call for the chest's item", .{rel});

    var added_calls: std.ArrayList(u16) = .empty;
    for (guide_calls.items) |guide_call| {
        var after = (fc.events.items[guide_call].nextPtr() orelse return error.NotAsExpected).*;
        // the last Ocarina's check first, so the first one's check comes first
        var k = ocarinas.len;
        while (k > 0) {
            k -= 1;
            const prefix = std.fmt.allocPrint(allocator, "{s}_{s}", .{ fc.events.items[guide_call].name, ocarinas[k].real_actor }) catch return error.OutOfMemory;
            after = try addSwap(allocator, fc, query, add_or_remove, prefix, ocarinas[k], after, &added_calls);
        }
        (fc.events.items[guide_call].nextPtr() orelse return error.NotAsExpected).* = after;
    }
    try flows.listReachedCalls(allocator, fc, added_calls.items);
    return flows.writeBack(allocator, &doc, rel, progress);
}

/// the chest scenes: big chests, small chests
pub const chest_flows = [_][]const u8{ "Event/EventFlow/Dm_SY_Treasurebox.bfevfl.zs", "Event/EventFlow/Dm_SY_TreasureboxSmall.bfevfl.zs" };

/// the chest scenes' parameter naming the chest's item
const chest_content_argument = "ContentName";

test "a held-up Ocarina hand-over is followed by the real Ocarina and its tutorial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();

    // Start: GetPouchContent<GetPouchContentByActorName> {ActorName=Item_Rando_Ocarina_Time} -> wait
    var fc = evfl.Flowchart{ .name = "TestGift" };
    var system = evfl.Actor{ .name = "GameSystemActor", .params = try Container.create(a) };
    system.actions.append(a, "EventWait") catch unreachable; // why unreachable: an arena in a test
    fc.actors.append(a, system) catch unreachable;
    _ = try fc.addEvent(a, evfl.makeSubFlow("Event0", "GetPouchContent", "GetPouchContentByActorName", 1, try Container.from(a, &.{
        .{ .name = "ActorName", .value = .{ .string = "Item_Rando_Ocarina_Time" } },
    })));
    _ = try fc.addEvent(a, evfl.makeAction("Event1", .{ 0, 0 }, evfl.NONE, try Container.from(a, &.{.{ .name = "Frames", .value = .{ .int = 1 } }})));
    var entry = evfl.EntryPoint{ .name = "Start", .main_event = 0 };
    entry.sub_flow_events.append(a, 0) catch unreachable;
    fc.entry_points.append(a, entry) catch unreachable;
    const doc = evfl.Document{ .name = "TestGift", .flowchart = &fc };
    const data = try evfl.write(a, &doc);

    var view = try evfl_view.View.init(a, data);
    const offset = view.flowcharts[0].events[0].params.?.stringOffset("ActorName").?;
    const out = try finishHandOvers(a, data, &view, &.{.{ .item_offset = offset, .display_actor = "Item_Rando_Ocarina_Time", .real_actor = "Item_Ocarina_Time" }}, "TestGift", &progress);

    const result = (try evfl.read(a, out)).flowchart.?;
    const check = result.events.items[result.events.items[0].next().?];
    try std.testing.expect(result.isQuery(&check, pouch_actor_name, owns_query));
    try std.testing.expectEqualStrings("Item_Rando_Ocarina_Time", check.params().?.getString("Actor").?);
    // not owned (a sale turned down): straight on to the wait
    try std.testing.expectEqualStrings("Event1", result.events.items[check.kind.switch_.cases.items[1].event].name);
    // owned: swap, add, item guide, Ocarina tutorial, then the wait
    const swap = result.events.items[check.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("Item_Rando_Ocarina_Time", swap.params().?.getString("Actor").?);
    try std.testing.expectEqual(@as(?i64, -1), swap.params().?.get("Num").?.asInt());
    const add = result.events.items[swap.next().?];
    try std.testing.expectEqualStrings("Item_Ocarina_Time", add.params().?.getString("Actor").?);
    const guide = result.events.items[add.next().?];
    try std.testing.expectEqualStrings("Item_Ocarina_Time", guide.params().?.getString("ActorName").?);
    const tutorial = result.events.items[guide.next().?];
    try std.testing.expectEqualStrings(ocarina_tutorial_entry, tutorial.kind.sub_flow.entry_point);
    try std.testing.expectEqualStrings("Event1", result.events.items[tutorial.next().?].name);
    // the entry point lists the two new calls
    try std.testing.expectEqual(@as(usize, 3), result.entry_points.items[0].sub_flow_events.items.len);
}

test "after a chest's item guide, each Ocarina's display actor is swapped for the real one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();

    // Success: ActionGuide:ActionGuide {ActorName = $ContentName} -> wait
    var fc = evfl.Flowchart{ .name = "TestChest" };
    var system = evfl.Actor{ .name = "GameSystemActor", .params = try Container.create(a) };
    system.actions.append(a, "EventWait") catch unreachable; // why unreachable: an arena in a test
    fc.actors.append(a, system) catch unreachable;
    _ = try fc.addEvent(a, evfl.makeSubFlow("Event13", action_guide_flow, item_action_guide_entry, 1, try Container.from(a, &.{
        .{ .name = "ActorName", .value = .{ .argument = chest_content_argument } },
    })));
    _ = try fc.addEvent(a, evfl.makeAction("Event14", .{ 0, 0 }, evfl.NONE, try Container.from(a, &.{.{ .name = "Frames", .value = .{ .int = 1 } }})));
    var entry = evfl.EntryPoint{ .name = "Success", .main_event = 0 };
    entry.sub_flow_events.append(a, 0) catch unreachable;
    fc.entry_points.append(a, entry) catch unreachable;
    const doc = evfl.Document{ .name = "TestChest", .flowchart = &fc };
    const data = try evfl.write(a, &doc);

    const ocarinas = [_]Ocarina{
        .{ .display_actor = "Item_Rando_Ocarina_Fairy", .real_actor = "Item_Ocarina_Fairy" },
        .{ .display_actor = "Item_Rando_Ocarina_Time", .real_actor = "Item_Ocarina_Time" },
    };
    const out = try finishChestOpenings(a, data, &ocarinas, "TestChest", &progress);
    const result = (try evfl.read(a, out)).flowchart.?;

    // the guide leads to the Fairy Ocarina's check; not owned -> the Ocarina of Time's check; not owned -> the wait
    const fairy_check = result.events.items[result.events.items[0].next().?];
    try std.testing.expectEqualStrings("Item_Rando_Ocarina_Fairy", fairy_check.params().?.getString("Actor").?);
    const time_check = result.events.items[fairy_check.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Item_Rando_Ocarina_Time", time_check.params().?.getString("Actor").?);
    try std.testing.expectEqualStrings("Event14", result.events.items[time_check.kind.switch_.cases.items[1].event].name);
    // owned Fairy Ocarina: swap ... tutorial, then on to the Ocarina of Time's check
    var step = result.events.items[fairy_check.kind.switch_.cases.items[0].event];
    for (0..3) |_| step = result.events.items[step.next().?];
    try std.testing.expectEqualStrings(ocarina_tutorial_entry, step.kind.sub_flow.entry_point);
    try std.testing.expectEqualStrings(time_check.name, result.events.items[step.next().?].name);
}
