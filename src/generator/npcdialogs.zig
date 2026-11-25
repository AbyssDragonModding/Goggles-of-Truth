//! Skip NPC Dialogs (0.8.0 feature, temporary until it joins Skip Cutscenes): characters' long story talks that only
//! talk count as already heard on a new save, so the character goes straight to the short line.
//!
//! How the game does it: a character's flow asks GameDataActor.EventQueryIsGameDataBool
//! {GameDataName = HaveTalked_Special.<flow>_<event>} before a long talk. Case 0 (heard; the game's bool queries
//! answer 0 for true, DoorOfTime:Event41) goes to the short line; case 1 plays the long talk, which ends by setting
//! that flag (DoorOfTime:Event40). Saria in Kokiri Forest, for example, has one for each stage of the Deku Tree quest.
//!
//! Which flags are set: every one whose long-talk branches (all the switches that read it, in every Npc_ flow) only
//! talk. Each branch is followed from its case 1 until it sets the flag (or ends); it may talk, animate, turn, move
//! the camera, wait, set other HaveTalked flags and call the shared talk helpers (safe_sub_flows) or another entry
//! of its own flow (followed too). Anything else in it makes the flag unsafe and it keeps playing: an item or pouch
//! change, a quest step, any other save flag, a scene change or a cutscene, or a call to another flow.
//!
//! The flags are found from the game's own flows on every seed with the setting, so they follow the game's files.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const gamedata = @import("gamedata.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const NONE = evfl.NONE;

const flow_folder = "Event/EventFlow";
const npc_flow_prefix = "Npc_";
const heard_prefix = "HaveTalked_Special.";
/// the long talk's "not heard yet" case
const case_not_heard: u32 = 1;
/// shared helpers a talk calls that only set up the talk (camera, Navi, the character turning to Link)
const safe_sub_flows = [_][]const u8{ "NaviEventCommon", "InitTalk", "Common_Camera_Pln", "NpcCommon_Camera" };
/// actors whose every action changes what the player owns or where the story is
const unsafe_actors = [_][]const u8{ "PouchSystemActor", "ChallengeSystemActor" };
/// actions that change the scene or play a cutscene
const unsafe_actions = [_][]const u8{ "EventReserveBancChange", "EventTransition" };
/// a long branch that long is not a talk (and stops a broken flow from running on)
const max_branch_events = 400;

/// The HaveTalked_Special flags a new save sets with Skip NPC Dialogs, sorted, each once.
pub fn heardFlags(allocator: Allocator, world: *World) PatchError![]const []const u8 {
    // flag -> still safe (false once any of its branches isn't only a talk)
    var verdict = std.StringHashMap(bool).init(allocator);
    const names = world.files.listDir(allocator, flow_folder) catch return error.GameFiles;
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, npc_flow_prefix) or !std.mem.endsWith(u8, name, ".bfevfl.zs")) continue;
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ flow_folder, name });
        const file = try world.readZs(allocator, rel);
        const doc = evfl.read(allocator, file.data) catch continue; // a flow this reader can't read has no flags for us
        const fc = doc.flowchart orelse continue;
        try judgeFlow(allocator, fc, &verdict);
    }
    var out: std.ArrayList([]const u8) = .empty;
    var it = verdict.iterator();
    while (it.next()) |entry| if (entry.value_ptr.*) try out.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return out.items;
}

/// Records, for each heard-flag switch in `fc`, whether its long talk only talks.
fn judgeFlow(allocator: Allocator, fc: *evfl.Flowchart, verdict: *std.StringHashMap(bool)) PatchError!void {
    for (fc.events.items) |*e| {
        if (e.kind != .switch_) continue;
        const query = fc.queryName(e) orelse continue;
        if (!std.mem.eql(u8, query, "EventQueryIsGameDataBool")) continue;
        const params = e.kind.switch_.params orelse continue;
        const flag = params.getString("GameDataName") orelse continue;
        if (!std.mem.startsWith(u8, flag, heard_prefix)) continue;
        var long_talk: ?u16 = null;
        for (e.kind.switch_.cases.items) |c| if (c.value == case_not_heard) {
            long_talk = c.event;
        };
        const safe = if (long_talk) |start| try onlyTalks(allocator, fc, start, flag) else false;
        const slot = verdict.getOrPut(flag) catch return error.OutOfMemory;
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* and safe else safe;
    }
}

/// Does everything reached from `start` until `flag` is set only talk (see the top of the file)?
fn onlyTalks(allocator: Allocator, fc: *evfl.Flowchart, start: u16, flag: []const u8) PatchError!bool {
    const seen = allocator.alloc(bool, fc.events.items.len) catch return error.OutOfMemory;
    @memset(seen, false);
    var stack: std.ArrayList(u16) = .empty;
    try stack.append(allocator, start);
    var visited: usize = 0;
    while (stack.pop()) |index| {
        if (index == NONE) continue;
        if (index >= fc.events.items.len) return false;
        if (seen[index]) continue;
        seen[index] = true;
        visited += 1;
        if (visited > max_branch_events) return false;
        const e = &fc.events.items[index];
        switch (e.kind) {
            .action => |action| {
                const actor = fc.actors.items[action.actor].name;
                const name = fc.actionName(e) orelse return false;
                const target = if (action.params) |p| p.getString("GameDataName") orelse "" else "";
                if (std.mem.eql(u8, actor, "GameDataActor")) {
                    // the talk's own end, or another heard flag: fine; any other save flag changes the game
                    if (std.mem.eql(u8, target, flag)) continue;
                    if (!std.mem.startsWith(u8, target, heard_prefix) or !std.mem.startsWith(u8, name, "EventTriggerSetGameDataBool")) return false;
                }
                for (unsafe_actors) |a| if (std.mem.eql(u8, actor, a)) return false;
                for (unsafe_actions) |a| if (std.mem.eql(u8, name, a)) return false;
                try stack.append(allocator, action.next);
            },
            .switch_ => |s| for (s.cases.items) |c| try stack.append(allocator, c.event),
            .fork => |f| {
                for (f.forks.items) |branch| try stack.append(allocator, branch);
                try stack.append(allocator, f.join);
            },
            .join => |j| try stack.append(allocator, j.next),
            .sub_flow => |call| {
                if (call.flowchart.len == 0 or std.mem.eql(u8, call.flowchart, fc.name)) {
                    // another entry of this flow: it is part of the talk
                    const entry = fc.entryPoint(call.entry_point) orelse return false;
                    try stack.append(allocator, entry.main_event);
                } else {
                    var known = false;
                    for (safe_sub_flows) |f| if (std.mem.eql(u8, call.flowchart, f)) {
                        known = true;
                    };
                    if (!known) return false;
                }
                try stack.append(allocator, call.next);
            },
            // a call that branches on what it returns, or a return: not a plain talk
            .sub_flow_switch, .return_ => return false,
        }
    }
    return true;
}

/// The save-data changes: each heard flag the save data has as a Bool, set.
pub fn changes(allocator: Allocator, world: *World, flags: []const []const u8) PatchError![]const gamedata.Change {
    const probe = try gamedata.probeOf(world);
    var out: std.ArrayList(gamedata.Change) = .empty;
    for (flags) |flag| {
        if (probe.flagKind(flag) != .Bool) continue;
        try out.append(allocator, .{ .kind = .bool_flag, .flag = flag, .bool_value = true });
    }
    return out.items;
}

test "a long talk that only talks is skipped; one that gives an item is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fc = evfl.Flowchart{ .name = "Npc_Test" };
    var data_actor = evfl.Actor{ .name = "GameDataActor", .params = try evfl.Container.create(a) };
    try data_actor.queries.append(a, "EventQueryIsGameDataBool");
    try data_actor.actions.append(a, "EventTriggerSetGameDataBool");
    try fc.actors.append(a, data_actor);
    var npc = evfl.Actor{ .name = "Npc_Test", .params = try evfl.Container.create(a) };
    try npc.actions.append(a, "EventTalk");
    try fc.actors.append(a, npc);
    var pouch = evfl.Actor{ .name = "PouchSystemActor", .params = try evfl.Container.create(a) };
    try pouch.actions.append(a, "EventTriggerAddOrRemovePouchContent");
    try fc.actors.append(a, pouch);

    // 0: heard A? 0 -> 3 (short line), 1 -> 1 (long talk) -> 2 (set A) -> end
    // 4: heard B? 1 -> 5 (talk) -> 6 (give an item) -> 7 (set B) -> end
    const heard = struct {
        fn switchOn(alloc: Allocator, flag: []const u8, heard_event: u16, long_event: u16) !evfl.Event {
            var cases: std.ArrayList(evfl.Case) = .empty;
            try cases.append(alloc, .{ .value = 0, .event = heard_event });
            try cases.append(alloc, .{ .value = case_not_heard, .event = long_event });
            return .{ .name = "Heard", .kind = .{ .switch_ = .{ .actor = 0, .query = 0, .cases = cases, .params = try evfl.Container.from(alloc, &.{.{ .name = "GameDataName", .value = .{ .string = flag } }}) } } };
        }
        fn set(alloc: Allocator, flag: []const u8) !evfl.Event {
            return evfl.makeAction("Set", .{ 0, 0 }, NONE, try evfl.Container.from(alloc, &.{.{ .name = "GameDataName", .value = .{ .string = flag } }}));
        }
    };
    _ = try fc.addEvent(a, try heard.switchOn(a, "HaveTalked_Special.Npc_Test_A", 3, 1));
    _ = try fc.addEvent(a, evfl.makeAction("Talk", .{ 1, 0 }, 2, null));
    _ = try fc.addEvent(a, try heard.set(a, "HaveTalked_Special.Npc_Test_A"));
    _ = try fc.addEvent(a, evfl.makeAction("Short", .{ 1, 0 }, NONE, null));
    _ = try fc.addEvent(a, try heard.switchOn(a, "HaveTalked_Special.Npc_Test_B", 3, 5));
    _ = try fc.addEvent(a, evfl.makeAction("Talk2", .{ 1, 0 }, 6, null));
    _ = try fc.addEvent(a, evfl.makeAction("Give", .{ 2, 0 }, 7, null));
    _ = try fc.addEvent(a, try heard.set(a, "HaveTalked_Special.Npc_Test_B"));

    var verdict = std.StringHashMap(bool).init(a);
    try judgeFlow(a, &fc, &verdict);
    try std.testing.expect(verdict.get("HaveTalked_Special.Npc_Test_A").?);
    try std.testing.expect(!verdict.get("HaveTalked_Special.Npc_Test_B").?);
}
