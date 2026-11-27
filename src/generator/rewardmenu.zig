//! The medallions menu after a Spiritual Stone or a medallion handed over by an event check (a boss's sage scene,
//! Rauru, a character's gift...).
//!
//! The game itself opens it once, in the Deku Tree's Kokiri Emerald scene (Dm_Kokiri_0130:Event52,
//! UISystemActor.EventOpenPerformanceImportantMenu). Wherever an event check now hands over a Stone or a medallion,
//! the menu opens right after that hand-over's item window: the hand-over call
//! (GetPouchContent<GetPouchContentByActorName> and the other calls of the game's hand-over flows, naming the item)
//! leads to the menu, and the menu to what came after the call.
//!
//! Only event checks: a Stone or a medallion in a chest, on a shelf or on the ground goes through the game's shared
//! hand-over (GetPouchContent), which can't tell a reward from the other key items, so no menu there (Shuffle
//! Spiritual Stones/Medallions: Anywhere). The Deku Tree giving its own Kokiri Emerald keeps the game's menu. With
//! Skip Cutscenes, the boss scenes whose check is given at once without the scene don't open it either.
//!
//! The menu's line is one fixed text for the whole game (textpatches.writeStartRewardText): with menus after
//! rewards it says "Added to Key Items" (the item window before it names the item).

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const Container = evfl.Container;

const menu_actor = "UISystemActor";
const menu_action = "EventOpenPerformanceImportantMenu";
const menu_event_prefix = "Rando_RewardMenu";
/// the scene where the game opens the menu itself, and the reward it does it for
const game_menu_flow = "Dm_Kokiri_0130";
const game_menu_reward = "Item_Stone_Forest";
/// the hand-over flows whose call shows the item window for the actor it names (world.zig isGiftSubFlow)
const hand_over_flows = [_][]const u8{ "GetPouchContent", "Dm_SY_GetInEvent", "Dm_SY_Get" };
const hand_over_actor_param = "ActorName";

/// One event check that hands over a reward: its flow files and the reward's event actor.
pub const RewardHandOver = struct {
    location: []const u8,
    rels: []const []const u8,
    actor: []const u8,
};

/// Adds the menu after each hand-over of `hand_overs`. Returns how many hand-overs got it; a check whose flow has no
/// hand-over call naming its reward (a silent add) is listed in the log and keeps no menu.
pub fn addMenuAfterRewardHandOvers(patches: *patchset.PatchSet, hand_overs: []const RewardHandOver, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    var done: usize = 0;
    for (hand_overs) |hand_over| {
        var found_for_check = false;
        for (hand_over.rels) |rel| {
            const flow_name = flowNameOf(rel);
            if (std.mem.eql(u8, flow_name, game_menu_flow) and std.mem.eql(u8, hand_over.actor, game_menu_reward)) {
                found_for_check = true; // the game's own menu
                continue;
            }
            const orig = try patches.read(rel);
            var doc = try flows.readFlow(a, orig.data, flow_name, progress);
            const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} has no flowchart", .{flow_name});
            const added = try addMenuAfterCallsNaming(fc, a, hand_over.actor, rel, progress);
            if (added == 0) continue;
            found_for_check = true;
            done += added;
            const out = try flows.writeBack(a, &doc, flow_name, progress);
            try patches.emitZs(rel, orig, out);
        }
        if (!found_for_check) progress.log("note: {s} hands over {s} without an item window; no medallions menu after it", .{ hand_over.location, hand_over.actor });
    }
    return done;
}

/// "Event/EventFlow/Dm_Awake_Fire_Get.bfevfl.zs" -> "Dm_Awake_Fire_Get"
fn flowNameOf(rel: []const u8) []const u8 {
    const base = std.fs.path.basename(rel);
    return base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
}

/// Puts the menu after every hand-over call in `fc` that names `actor`. Returns how many.
fn addMenuAfterCallsNaming(fc: *evfl.Flowchart, allocator: Allocator, actor: []const u8, rel: []const u8, progress: *Progress) PatchError!usize {
    var calls: std.ArrayList(u16) = .empty;
    // a scene that adds the item and shows its window in two calls (the Deku Tree's, once npcrewards replaced its
    // display with GetPouchContent<DisplayGetByActorName>) gets the menu after the window only
    var window_calls: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |e, i| {
        const call = switch (e.kind) {
            .sub_flow => |s| s,
            else => continue,
        };
        if (!flows.contains(&hand_over_flows, call.flowchart)) continue;
        const params = call.params orelse continue;
        const named = params.getString(hand_over_actor_param) orelse continue;
        if (!std.mem.eql(u8, named, actor)) continue;
        calls.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        if (std.mem.startsWith(u8, call.entry_point, "Display")) window_calls.append(allocator, @intCast(i)) catch return error.OutOfMemory;
    }
    if (window_calls.items.len > 0) calls = window_calls;
    if (calls.items.len == 0) return 0;
    try flows.ensureSystemActor(fc, allocator, menu_actor, rel, progress);
    const menu_aa = try flows.requireAction(fc, allocator, menu_actor, menu_action, progress);
    for (calls.items, 0..) |call_index, k| {
        const go_on = fc.events.items[call_index].next() orelse evfl.NONE;
        const name = std.fmt.allocPrint(allocator, "{s}{d}", .{ menu_event_prefix, k }) catch return error.OutOfMemory;
        const menu = try fc.addEvent(allocator, evfl.makeAction(name, menu_aa, go_on, try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        })));
        // addEvent may move the events: the call is found again by its index
        fc.events.items[call_index].nextPtr().?.* = menu;
    }
    return calls.items.len;
}
