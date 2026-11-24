//! Event-flow edits that shorten the start of the game and chest openings.
//!
//! Each edit checks the native structure it changes, refuses anything it does not recognise (error.NotAsExpected,
//! with the reason in the Progress failure message), and reads its result back.
//!
//! - openingWithoutMovie, completeDekuMeeting: ported from Clawshot (https://github.com/hiKareeem/Clawshot,
//!   src/clawshot/patch/gamedata.py and patch/mido.py, data/fast_start.toml), MIT License, Copyright (c) 2026
//!   Kareem Albaba and the Clawshot contributors.
//! - quickChest: ported from OotrR (https://github.com/Mozencaz/OotrR, src/oot_rando/patching/qol_patches.py), MIT
//!   License, Copyright (c) 2026 Mozencaz.
//!
//! (The Python version also had quick_small_chest, which nothing called; it is not ported.)

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const flows = @import("flows.zig");
const Progress = @import("../core/Progress.zig");
const PatchError = @import("patchset.zig").PatchError;
const Allocator = std.mem.Allocator;
const Container = evfl.Container;
const Item = evfl.Item;
const NONE = evfl.NONE;

// --- Skip the opening movie ---------------------------------------------------------------------------------
// OpeningEvent:Opening_LoadingKokiriForest plays the movie (EventSystemActor.EventTransition Dm_Kokiri_0000: the
// narrated prologue, the Deku Tree's dream, Navi's flight) while Kokiri Forest loads, then waits on
// GameSystemActor.EventQueryBancChangeIsLoaded, whose only case (1) fades in. The entry now starts at that query
// and the movie's event becomes its case 0: a one-frame wait back to the query, so the flow still waits for the
// load the movie used to cover. Navi waking Link still plays.
pub const opening_flow = "Event/EventFlow/OpeningEvent.bfevfl.zs";
const opening_loading = "Opening_LoadingKokiriForest";
const opening_movie = "Dm_Kokiri_0000";

pub fn openingWithoutMovie(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = try flows.expectFlowchart(&doc, "OpeningEvent", progress);

    var entry: ?*evfl.EntryPoint = null;
    var count: usize = 0;
    for (fc.entry_points.items) |*e| if (std.mem.eql(u8, e.name, opening_loading)) {
        entry = e;
        count += 1;
    };
    if (count != 1) return progress.fail(error.NotAsExpected, "expected one {s} entry, found {d}", .{ opening_loading, count });
    const ep = entry.?;
    const movie_index = ep.main_event;
    const movie = fc.event(movie_index) orelse return progress.fail(error.NotAsExpected, "the opening's start is not the expected movie + load check", .{});
    const query_index: u16 = if (movie.kind == .action) movie.kind.action.next else NONE;
    const query = fc.event(query_index);

    const ok = blk: {
        if (!fc.isAction(movie, "EventSystemActor", "EventTransition")) break :blk false;
        const mp = movie.params() orelse break :blk false;
        if (!mp.isString("EventName", opening_movie)) break :blk false;
        const q = query orelse break :blk false;
        if (!fc.isQuery(q, "GameSystemActor", "EventQueryBancChangeIsLoaded")) break :blk false;
        if (q.params() != null) break :blk false;
        const cases = q.kind.switch_.cases.items;
        if (cases.len != 1 or cases[0].value != 1) break :blk false;
        const actor = fc.actors.items[q.kind.switch_.actor];
        if (!flows.contains(actor.actions.items, "EventWait")) break :blk false;
        break :blk true;
    };
    if (!ok) return progress.fail(error.NotAsExpected, "the opening's start is not the expected movie + load check", .{});

    // nothing else may lead into the movie's event
    for (fc.events.items) |*e| {
        if (e.leadsTo(movie_index)) return progress.fail(error.NotAsExpected, "the movie's event is also reached from {s}", .{e.name});
    }
    for (fc.entry_points.items) |*e| {
        if (e == ep) continue;
        if (e.main_event == movie_index or e.hasSubFlowEvent(movie_index)) return progress.fail(error.NotAsExpected, "the movie's event is also reached from {s}", .{e.name});
    }
    if (ep.hasSubFlowEvent(movie_index)) return progress.fail(error.NotAsExpected, "the movie's event is a sub flow call", .{});

    const q = query.?;
    const actor_index = q.kind.switch_.actor;
    const wait_action: u16 = @intCast(flows.indexOf(fc.actors.items[actor_index].actions.items, "EventWait").?);
    fc.events.items[movie_index] = evfl.makeAction("RandoWaitForKokiriForest", .{ actor_index, wait_action }, query_index, try Container.from(allocator, &.{
        .{ .name = "Frames", .value = .{ .int = 1 } },
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
    }));
    // the query is still at query_index
    const cases = &fc.events.items[query_index].kind.switch_.cases;
    cases.insert(allocator, 0, .{ .value = 0, .event = movie_index }) catch return error.OutOfMemory;
    ep.main_event = query_index;
    return flows.writeBack(allocator, &doc, "OpeningEvent", progress);
}

// --- New game starts outside, in front of the Kokiri Shop (every seed) -------------------------------------
// Sequence/Opening runs OpeningEvent:Opening_Introduction once on a new save. It fades to black, sets Meet_DekuTree
// Step01, pins the terrain at the Deku Tree, points the event camera there, waits 75 frames and plays Dm_Kokiri_0030:
// Navi's flight through the forest to Link's bed and Navi waking him (a 12,544-frame timeline). Its load was the long
// black screen after "New Game". As in the N64 randomizer, a new game now starts outside: after Step01 the terrain is
// pinned at the spawn, Link and Navi are warped in front of the shop, the flow waits a moment for the area, fades in
// (the native fade used after the scene), and continues with the native tail (in-game BGM, Navi counted as talked to,
// the autosave). Saria's wake-up (gamedata.saria_intro) and the scene itself count as seen, so the house door is open.
// Spawn: an NPC's standing anchor on the ground in front of the shop door, facing the door. YAngle 0 faces +Z.
const shop_spawn = [3]f64{ 2.237, 110.754, -11.235 };
const shop_spawn_angle: f32 = 205.0;
const navi_offset = [3]f64{ 0.6, 1.0, 0.4 };
const wake_scene = "Dm_Kokiri_0030";

pub fn startOutside(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = try flows.expectFlowchart(&doc, "OpeningEvent", progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoStartOutside")) return progress.fail(error.NotAsExpected, "the new-game start was already changed", .{});
    }

    const step = try flows.findOneAction(fc, "ChallengeSystemActor", "EventExecuteProgressChallengeStep", &.{
        .{ .name = "ChallengeName", .value = .{ .string = "Meet_DekuTree" } },
    }, progress);
    const pin = try flows.findOneAction(fc, "TerrainSystemActor", "EventTerrainPinResource", &.{}, progress);
    const scene = try flows.findOneAction(fc, "EventSystemActor", "EventTransition", &.{
        .{ .name = "EventName", .value = .{ .string = wake_scene } },
    }, progress);
    const fade_in = try flows.findOneAction(fc, "UISystemActor", "EventEventFadeIn", &.{
        .{ .name = "Length", .value = .{ .int = 1 } },
        .{ .name = "IsNoPlayAnime", .value = .{ .bool = false } },
    }, progress);
    var bgm_query: ?u16 = null;
    var bgm_count: usize = 0;
    for (fc.events.items, 0..) |*e, i| {
        if (e.kind != .switch_) continue;
        const q = fc.queryName(e) orelse continue;
        if (std.mem.eql(u8, q, "EventQueryIsInGameBgmSuspend")) {
            bgm_query = @intCast(i);
            bgm_count += 1;
        }
    }
    if (fc.events.items[step].next() != pin or bgm_count != 1 or fc.events.items[fade_in].next() != bgm_query.?) {
        return progress.fail(error.NotAsExpected, "the opening's introduction is not in the expected order", .{});
    }

    // nothing else may lead into the part that is cut out (the camera, the wait and the scene)
    const cut = allocator.alloc(bool, fc.events.items.len) catch return error.OutOfMemory;
    @memset(cut, false);
    var i: u16 = fc.events.items[pin].next().?;
    while (i != scene) {
        if (i >= fc.events.items.len or cut[i] or fc.events.items[i].kind != .action) {
            return progress.fail(error.NotAsExpected, "unexpected events between the terrain pin and {s}", .{wake_scene});
        }
        cut[i] = true;
        i = fc.events.items[i].next().?;
    }
    cut[scene] = true;
    for (fc.events.items, 0..) |*e, k| {
        if (k == pin or cut[k]) continue;
        for (cut, 0..) |c, target| {
            if (c and e.leadsTo(@intCast(target))) return progress.fail(error.NotAsExpected, "the wake-up scene is also reached from {s}", .{e.name});
        }
    }
    for (fc.entry_points.items) |e| {
        if (e.main_event < cut.len and cut[e.main_event]) return progress.fail(error.NotAsExpected, "the wake-up scene is also reached from {s}", .{e.name});
        for (e.sub_flow_events.items) |s| if (s < cut.len and cut[s]) return progress.fail(error.NotAsExpected, "the wake-up scene is also reached from {s}", .{e.name});
    }

    // the file stores binary32: the positions are the f32 of the sums, as they read back
    const navi_pos = allocator.alloc(f32, 3) catch return error.OutOfMemory;
    const spawn = allocator.alloc(f32, 3) catch return error.OutOfMemory;
    for (0..3) |k| {
        navi_pos[k] = @floatCast(shop_spawn[k] + navi_offset[k]);
        spawn[k] = @floatCast(shop_spawn[k]);
    }

    const wait_aa = try flows.requireAction(fc, allocator, "EventSystemActor", "EventWait", progress);
    const wait = try fc.addEvent(allocator, evfl.makeAction("RandoStartOutside_Wait", wait_aa, fade_in, try Container.from(allocator, &.{
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        .{ .name = "Frames", .value = .{ .int = 30 } },
    })));
    const navi_aa = try flows.requireAction(fc, allocator, "Npc_Navi", "EventTriggerNaviWarpToTargetPosAndRot", progress);
    const navi = try fc.addEvent(allocator, evfl.makeAction("RandoStartOutside_Navi", navi_aa, wait, try Container.from(allocator, &.{
        .{ .name = "Position", .value = .{ .float_array = navi_pos } },
        .{ .name = "ClothWarpMode", .value = .{ .int = -1 } },
        .{ .name = "YAngle", .value = .{ .float = shop_spawn_angle } },
    })));
    const link_aa = try flows.requireAction(fc, allocator, "Player_Event", "EventPlayerWarpToTargetPosAndRot", progress);
    const link = try fc.addEvent(allocator, evfl.makeAction("RandoStartOutside_Link", link_aa, navi, try Container.from(allocator, &.{
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        .{ .name = "UseDemoWait", .value = .{ .bool = true } },
        .{ .name = "YAngle", .value = .{ .float = shop_spawn_angle } },
        .{ .name = "Position", .value = .{ .float_array = spawn } },
        .{ .name = "ASCommand", .value = .{ .string = "EvtWait" } },
    })));

    const pin_event = &fc.events.items[pin];
    const old_params = pin_event.params() orelse return progress.fail(error.NotAsExpected, "the opening's terrain pin has no position", .{});
    if ((old_params.get("Position") orelse Param{ .int = 0 }) != .float_array) return progress.fail(error.NotAsExpected, "the opening's terrain pin has no position", .{});
    const params = try old_params.clone(allocator);
    try params.put(allocator, "Position", .{ .float_array = spawn });
    pin_event.kind.action.params = params;
    pin_event.kind.action.next = link;
    // the cut events stay in the file, unreachable; the wake-up scene's own event loses its target
    return flows.writeBack(allocator, &doc, "OpeningEvent (start outside)", progress);
}

const Param = evfl.Param;

// --- Start items given by the game's own pouch action -------------------------------------------------------
// Most start items (Skip Child Zelda) are save-data defaults: IsGet.<item> and the PouchData count. That isn't
// enough for an ocarina: the pouch action the game's own scenes use (PouchSystemActor
// EventTriggerAddOrRemovePouchContent) also records which ocarina Link holds. With only the flags, the ocarina was in
// the menu but couldn't be played (seed 3LETP69LQZ). These items are added by that same action, silently, at the end
// of OpeningEvent:Opening_Introduction (it runs once on every new save), just before its autosave.
// Any other start item that a save default can't hold (bags, ammo, rupees, hearts, medallions, tokens...) is handed
// over there too, after the silent adds, by the gift call the game's NPC and check flows use
// (GetPouchContent:GetPouchContentByActorName, which shows the item's window), so a start check can hold any item.
pub const start_item_flow = opening_flow;
pub const gift_flow = "GetPouchContent";
pub const gift_entry = "GetPouchContentByActorName";
const start_item_entry = "Opening_Introduction";
/// start items that need the pouch action (an ocarina)
pub const start_by_event = [_][]const u8{ "Item_Ocarina_Fairy", "Item_Ocarina_Time" };

/// The base Deku Seed bag and quiver, given on every new save. Why: they are items of their own (Item_BulletBag_Small,
/// Item_Quiver_Small: the ammo's SmallBagActor, which sets how much Link can carry), and nothing hands them out with
/// the Slingshot or the Bow (the Slingshot's chest event is only a Navi hint), so a Slingshot found anywhere came
/// without seeds (test report, 0.7.4). On their own they do nothing; the Bigger bags stay in the item pool.
pub const base_bags_at_start = [_][]const u8{ "Item_BulletBag_Small", "Item_Quiver_Small" };

/// OpeningEvent with `actors` added to the pouch (one each), then `gifts` handed over (one each, with their item
/// window), just before the opening's autosave.
pub fn giveAtStart(allocator: Allocator, data: []const u8, actors: []const []const u8, gifts: []const []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = try flows.expectFlowchart(&doc, "OpeningEvent", progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoStartItem")) return progress.fail(error.NotAsExpected, "start items already added", .{});
    }
    if (fc.entryPoint(start_item_entry) == null) return progress.fail(error.NotAsExpected, "{s} entry not found", .{start_item_entry});

    var save: ?u16 = null;
    var saves: usize = 0;
    for (fc.events.items, 0..) |*e, k| {
        if (fc.isAction(e, "GameSystemActor", "EventTriggerRequestAutoSave")) {
            save = @intCast(k);
            saves += 1;
        }
    }
    if (saves != 1) return progress.fail(error.NotAsExpected, "expected one autosave in the opening, found {d}", .{saves});
    const before = try fc.predecessors(allocator, save.?);
    var entry_reaches_save = false;
    for (fc.entry_points.items) |e| if (e.main_event == save.? or e.hasSubFlowEvent(save.?)) {
        entry_reaches_save = true;
    };
    if (before.len != 1 or fc.events.items[before[0]].kind != .action or entry_reaches_save) {
        return progress.fail(error.NotAsExpected, "the opening's autosave is not reached by one event", .{});
    }

    var next: u16 = save.?;
    var added: std.ArrayList(u16) = .empty;
    var n = gifts.len;
    while (n > 0) {
        n -= 1;
        const name = std.fmt.allocPrint(allocator, "RandoStartGift{d}", .{n}) catch return error.OutOfMemory;
        next = try fc.addEvent(allocator, evfl.makeSubFlow(name, gift_flow, gift_entry, next, try Container.from(allocator, &.{
            .{ .name = "ActorName", .value = .{ .string = gifts[n] } },
        })));
        added.append(allocator, next) catch return error.OutOfMemory;
    }
    if (actors.len > 0) {
        const base_index = fc.findActor("GameSystemActor") orelse return progress.fail(error.NotAsExpected, "GameSystemActor not in OpeningEvent", .{});
        if (fc.findActor("PouchSystemActor") == null) {
            const base_params = fc.actors.items[base_index].params;
            const params = if (base_params) |p| try p.clone(allocator) else try Container.create(allocator);
            fc.actors.append(allocator, evfl.Actor{ .name = "PouchSystemActor", .params = params }) catch return error.OutOfMemory;
        }
        const pouch_action = (try fc.actionIndex(allocator, "PouchSystemActor", "EventTriggerAddOrRemovePouchContent")).?;
        n = actors.len;
        while (n > 0) {
            n -= 1;
            const name = std.fmt.allocPrint(allocator, "RandoStartItem{d}", .{n}) catch return error.OutOfMemory;
            next = try fc.addEvent(allocator, evfl.makeAction(name, pouch_action, next, try Container.from(allocator, &.{
                .{ .name = "Num", .value = .{ .int = 1 } },
                .{ .name = "IsEquipDIrect", .value = .{ .bool = false } },
                .{ .name = "IsSetMessageTargetActorName", .value = .{ .bool = false } },
                .{ .name = "Actor", .value = .{ .string = actors[n] } },
                .{ .name = "IsGetEvent", .value = .{ .bool = false } },
            })));
        }
    }
    fc.events.items[before[0]].kind.action.next = next;
    // an entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13)
    try flows.listReachedCalls(allocator, fc, added.items);
    return flows.writeBack(allocator, &doc, "OpeningEvent (start items)", progress);
}

// --- Skip the Great Deku Tree's arrival talk, Mido kept ----------------------------------------------------
// With Mido still blocking, the talk's state (Dm_Kokiri_0070 seen, Meet_DekuTree Complete, Get_StoneOfForest
// GoInside, the mouth open) is set at the end of Mido's own sword-and-shield clear, after his native steps. Setting it
// on a new save instead picks the wrong Mido schedule (Clawshot round 13). With Mido gone (Open Forest), the same
// values are plain new-save values (gamedata.deku_tree_talk_flags).
pub const mido_flow = "Event/EventFlow/Npc_Kokiri_Mido_Child.bfevfl.zs";
const mido_blocker = "KokiriForest_Npc_Kokiri_Mido_Child_Blocker";
const seen_tree = "HavePlayedEvent.Dm_Kokiri_0070";
const mouth_open = "KokiriForest_Meet_DekuTree_OpenDekuTreeMouth";

pub fn completeDekuMeeting(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = try flows.expectFlowchart(&doc, "Npc_Kokiri_Mido_Child", progress);
    const names = [_][]const u8{ "Event26", "Event32", "Event33", "Event48", "Event0" };
    var idx: [5]u16 = undefined;
    for (names, 0..) |n, k| idx[k] = fc.eventByName(n) orelse return progress.fail(error.NotAsExpected, "Mido's clear steps not found", .{});
    const clear = &fc.events.items[idx[0]];
    const end = &fc.events.items[idx[1]];
    const talk1 = &fc.events.items[idx[2]];
    const talk2 = &fc.events.items[idx[3]];
    const step = &fc.events.items[idx[4]];

    const expected_clear = try Container.from(allocator, &.{
        .{ .name = "Index", .value = .{ .int = -1 } },
        .{ .name = "GameDataName", .value = .{ .string = mido_blocker } },
        .{ .name = "Value", .value = .{ .bool = false } },
    });
    const expected_step = try Container.from(allocator, &.{
        .{ .name = "ChallengeName", .value = .{ .string = "Meet_DekuTree" } },
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        .{ .name = "IsIgnoreChallengeProgressUI", .value = .{ .bool = false } },
        .{ .name = "StepName", .value = .{ .string = "Step03" } },
        .{ .name = "IsIgnoreCompletedChallenge", .value = .{ .bool = false } },
    });
    const ok = blk: {
        for ([_]*evfl.Event{ clear, end, talk1, talk2, step }) |e| if (e.kind != .action) break :blk false;
        const c = clear.kind.action;
        if (c.params == null or !c.params.?.looseEql(expected_clear)) break :blk false;
        if (c.next != idx[1] or !fc.isAction(clear, "GameDataActor", "EventTriggerSetGameDataBool")) break :blk false;
        if (!fc.isAction(end, "Npc_Kokiri_Mido_Child", "EventNpcBlockerEndBlockerAI") or end.kind.action.next != idx[2]) break :blk false;
        const t1 = talk1.kind.action;
        const t2 = talk2.kind.action;
        if (t1.actor != c.actor or t1.action != c.action or t1.next != idx[3]) break :blk false;
        if (t2.actor != c.actor or t2.action != c.action or t2.next != idx[4]) break :blk false;
        if (!fc.isAction(step, "ChallengeSystemActor", "EventExecuteProgressChallengeStep")) break :blk false;
        const s = step.kind.action;
        if (s.params == null or !s.params.?.looseEql(expected_step) or s.next != NONE) break :blk false;
        break :blk true;
    };
    if (!ok) return progress.fail(error.NotAsExpected, "Mido's clear steps are not the expected ones", .{});

    const clear_aa = [2]u16{ clear.kind.action.actor, clear.kind.action.action };
    const step_aa = [2]u16{ step.kind.action.actor, step.kind.action.action };
    const step_params = step.kind.action.params.?;
    const go_inside = try step_params.clone(allocator);
    try go_inside.put(allocator, "ChallengeName", .{ .string = "Get_StoneOfForest" });
    try go_inside.put(allocator, "StepName", .{ .string = "GoInside" });
    const first: u16 = @intCast(fc.events.items.len);
    _ = try fc.addEvent(allocator, evfl.makeAction("RandoDekuSeen", clear_aa, idx[4], try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = seen_tree } },
        .{ .name = "Index", .value = .{ .int = -1 } },
        .{ .name = "Value", .value = .{ .bool = true } },
    })));
    _ = try fc.addEvent(allocator, evfl.makeAction("RandoDekuGoInside", step_aa, first + 2, go_inside));
    _ = try fc.addEvent(allocator, evfl.makeAction("RandoDekuMouth", clear_aa, NONE, try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = mouth_open } },
        .{ .name = "Index", .value = .{ .int = -1 } },
        .{ .name = "Value", .value = .{ .bool = true } },
    })));
    // the list may have moved: index again
    fc.events.items[idx[3]].kind.action.next = first;
    const complete = try step_params.clone(allocator);
    try complete.put(allocator, "StepName", .{ .string = "Complete" });
    fc.events.items[idx[4]].kind.action.params = complete;
    fc.events.items[idx[4]].kind.action.next = first + 1;
    return flows.writeBack(allocator, &doc, "Npc_Kokiri_Mido_Child", progress);
}

// --- Chests without cutscene -----------------------------------------------------------------------------
// Big chests (Dm_SY_Treasurebox, also used by the scripted chests): Success_ plays the fanfare ->
// /Success_PlayerPerform (camera, Link's kick, item shown rotating, a 473-frame wait) -> a 90-frame wait ->
// /Success_AddContent (item added, get window) -> /Success_Leave (opened flag, auto-save). The quick version calls the
// chest's own /Open (lid only, not awaited) instead, then Link holds the item up (the vanilla item-get pose) while it
// is added, and the fanfare starts without its intro.
pub const chest_flow = "Event/EventFlow/Dm_SY_Treasurebox.bfevfl.zs";
const chest_lid_animations = [_][]const u8{ "FrontOpen", "FrontOpen_Adult" };

const Step = struct { actor: []const u8, action: []const u8 };

fn showItemSteps(allocator: Allocator) PatchError![5]struct { step: Step, params: *Container } {
    const zero3 = allocator.alloc(f32, 3) catch return error.OutOfMemory;
    @memset(zero3, 0);
    return .{
        .{ .step = .{ .actor = "Player_Event", .action = "EventCreateShowItemFromActorFileName" }, .params = try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "Actor", .value = .{ .argument = "ContentName" } },
        }) },
        .{ .step = .{ .actor = "Player_Event", .action = "EventPlayerPlayASForFlowchart" }, .params = try Container.from(allocator, &.{
            .{ .name = "UseAnmDriven", .value = .{ .bool = false } },
            .{ .name = "KeepOneTimeAnm", .value = .{ .bool = false } },
            .{ .name = "IsWaitEnd", .value = .{ .bool = false } },
            .{ .name = "ASCommand", .value = .{ .string = "DemoGet" } },
            .{ .name = "IsAllSlot", .value = .{ .bool = true } },
            .{ .name = "ForceFadeFrame", .value = .{ .float = 0.0 } },
            .{ .name = "ClothWarpMode", .value = .{ .int = -1 } },
        }) },
        .{ .step = .{ .actor = "Player_Event", .action = "EventIgnitionShowItem" }, .params = try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "ItemPos", .value = .{ .float_array = zero3 } },
            .{ .name = "IsScale", .value = .{ .bool = false } },
            .{ .name = "CreateTime", .value = .{ .float = 0.0 } },
            .{ .name = "IsInvalidateShadow", .value = .{ .bool = true } },
            .{ .name = "IsAsPlay", .value = .{ .bool = true } },
            .{ .name = "ASCommand", .value = .{ .string = "Rotate_GetDemo" } },
        }) },
        .{ .step = .{ .actor = "EventSystemActor", .action = "EventWait" }, .params = try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "Frames", .value = .{ .int = 40 } },
        }) },
        // the last one hides the item again
        .{ .step = .{ .actor = "Player_Event", .action = "EventDeleteShowItem" }, .params = try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "IsFadeOut", .value = .{ .bool = false } },
            .{ .name = "IsScaleOut", .value = .{ .bool = false } },
            .{ .name = "ChangeVisibleOffWithRequestDelete", .value = .{ .bool = false } },
        }) },
    };
}

pub fn quickChest(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart in Dm_SY_Treasurebox", .{});
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoQuickChest")) return progress.fail(error.NotAsExpected, "big chest flow already changed", .{});
    }
    const entry = fc.entryPoint("Success_") orelse return progress.fail(error.NotAsExpected, "no Success_ entry", .{});
    const sw = fc.event(entry.main_event) orelse return progress.fail(error.NotAsExpected, "unexpected big chest start", .{});
    if (sw.kind != .switch_ or sw.kind.switch_.cases.items.len == 0 or sw.kind.switch_.cases.items[0].value != 0) {
        return progress.fail(error.NotAsExpected, "unexpected big chest start", .{});
    }
    const fanfare_i = sw.kind.switch_.cases.items[0].event;
    const bad_steps = "unexpected big chest steps";
    const fanfare = fc.event(fanfare_i) orelse return progress.fail(error.NotAsExpected, bad_steps, .{});
    if (fanfare.kind != .action) return progress.fail(error.NotAsExpected, bad_steps, .{});
    const perform_i = fanfare.kind.action.next;
    const perform = fc.event(perform_i) orelse return progress.fail(error.NotAsExpected, bad_steps, .{});
    if (perform.kind != .sub_flow) return progress.fail(error.NotAsExpected, bad_steps, .{});
    const wait = fc.event(perform.kind.sub_flow.next) orelse return progress.fail(error.NotAsExpected, bad_steps, .{});
    if (wait.kind != .action) return progress.fail(error.NotAsExpected, bad_steps, .{});
    const add_i = wait.kind.action.next;
    const add = fc.event(add_i) orelse return progress.fail(error.NotAsExpected, bad_steps, .{});
    if (add.kind != .sub_flow) return progress.fail(error.NotAsExpected, bad_steps, .{});
    const leave_i = add.kind.sub_flow.next;
    const leave = fc.event(leave_i) orelse return progress.fail(error.NotAsExpected, bad_steps, .{});
    const perform_params = perform.kind.sub_flow.params;
    const ok = std.mem.eql(u8, perform.kind.sub_flow.entry_point, "Success_PlayerPerform") and perform.kind.sub_flow.flowchart.len == 0 and
        std.mem.eql(u8, fc.actionName(wait) orelse "", "EventWait") and
        std.mem.eql(u8, add.kind.sub_flow.entry_point, "Success_AddContent") and
        leave.kind == .sub_flow and std.mem.eql(u8, leave.kind.sub_flow.entry_point, "Success_Leave") and
        perform_params != null and perform_params.?.isString("ContentName", "ContentName") and fc.entryPoint("Open") != null;
    if (!ok) return progress.fail(error.NotAsExpected, bad_steps, .{});
    const fanfare_params = fanfare.kind.action.params;
    if (!std.mem.eql(u8, fc.actionName(fanfare) orelse "", "EventTriggerSoundStartFanfare") or fanfare_params == null or
        !fanfare_params.?.is("IsEnableIntro", .{ .bool = true }) or (fanfare_params.?.get("IsEnableIntro").? != .bool))
    {
        return progress.fail(error.NotAsExpected, "unexpected big chest fanfare", .{});
    }
    try fanfare_params.?.put(allocator, "IsEnableIntro", .{ .bool = false });

    const steps = try showItemSteps(allocator);
    const first: u16 = @intCast(fc.events.items.len);
    for (steps, 0..) |s, k| {
        const aa = try flows.requireAction(fc, allocator, s.step.actor, s.step.action, progress);
        const name = if (k < steps.len - 1)
            std.fmt.allocPrint(allocator, "RandoQuickChestShow_{d}", .{k}) catch return error.OutOfMemory
        else
            "RandoQuickChestHide";
        _ = try fc.addEvent(allocator, evfl.makeAction(name, aa, NONE, s.params));
    }
    const pose_count: u16 = steps.len - 1;
    const hide = first + pose_count;
    var k: u16 = 0;
    while (k + 1 < pose_count) : (k += 1) fc.events.items[first + k].kind.action.next = first + k + 1;
    fc.events.items[first + pose_count - 1].kind.action.next = add_i;
    fc.events.items[add_i].kind.sub_flow.next = hide;
    fc.events.items[hide].kind.action.next = leave_i;
    const p = &fc.events.items[perform_i].kind.sub_flow;
    p.entry_point = "Open";
    p.params = null;
    p.next = first;

    // the lid animation is timed on the whole performance; /Open waits for it, so Link would stand frozen
    var found: [2]bool = .{ false, false };
    var count: usize = 0;
    for (fc.events.items) |*e| {
        if (e.kind != .action) continue;
        if (!std.mem.eql(u8, fc.actionName(e) orelse "", "EventPlayAS")) continue;
        const ep = e.kind.action.params orelse continue;
        const as_name = ep.getString("ASName") orelse continue;
        for (chest_lid_animations, 0..) |lid, li| {
            if (!std.mem.eql(u8, as_name, lid)) continue;
            if (!ep.is("IsWaitEnd", .{ .bool = true }) or ep.get("IsWaitEnd").? != .bool) return progress.fail(error.NotAsExpected, "unexpected chest lid animations", .{});
            found[li] = true;
            count += 1;
            try ep.put(allocator, "IsWaitEnd", .{ .bool = false });
        }
    }
    if (count != 2 or !found[0] or !found[1]) return progress.fail(error.NotAsExpected, "unexpected chest lid animations", .{});
    return flows.writeBack(allocator, &doc, "Dm_SY_Treasurebox", progress);
}

// --- Skip Epona Race --------------------------------------------------------------------------------------
// A horse is yours when it is in the save's horse list (OwnedHorseList.ActorName, a String64Array of 10).
// Dm_SY_Ocarina_EponaSong:EponaSong, for adult Link, asks GameSystemActor.EventQueryHasOwnedHorse: with a horse it
// calls it (EventQueryIsCurrentSceneEnableRide, then EventCreateAndCallOwnedHorse). The no-horse branch now first
// writes entry 0 (GameDataActor.EventTriggerSetGameDataString64, Index 0) and then goes on to that call. So the first
// Epona's Song as adult, anywhere you can ride, makes Epona yours and calls her. (The new save also starts with her in
// the list: gamedata.epona_owned_list.) Switch cases: 0 = true.
pub const epona_song_flow = "Event/EventFlow/Dm_SY_Ocarina_EponaSong.bfevfl.zs";

fn caseTarget(cases: []const evfl.Case, value: u32) ?u16 {
    var found: ?u16 = null;
    for (cases) |c| if (c.value == value) {
        found = c.event; // the last case of a value wins, as a Python dict built from the list
    };
    return found;
}

pub fn eponaWithoutRace(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try evfl.read(allocator, data);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart in Dm_SY_Ocarina_EponaSong", .{});
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoEpona")) return progress.fail(error.NotAsExpected, "Epona's Song flow already changed", .{});
    }
    // EponaSong's own check: "yes" leads to the call, "no" to the ranch branch (StartToPrepareCallOwnedHorse asks too
    // but has no "no" case)
    var owned: ?u16 = null;
    var count: usize = 0;
    for (fc.events.items, 0..) |*e, i| {
        if (!fc.isQuery(e, "GameSystemActor", "EventQueryHasOwnedHorse")) continue;
        const cases = e.kind.switch_.cases.items;
        const yes = caseTarget(cases, 0) orelse continue;
        if (caseTarget(cases, 1) == null) continue;
        const target = fc.event(yes) orelse continue;
        if (!fc.isQuery(target, "GameSystemActor", "EventQueryIsCurrentSceneEnableRide")) continue;
        owned = @intCast(i);
        count += 1;
    }
    if (count != 1) return progress.fail(error.NotAsExpected, "Epona's Song owned-horse check is not as expected", .{});
    const call = caseTarget(fc.events.items[owned.?].kind.switch_.cases.items, 0).?;
    const aa = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataString64", progress);
    const register = try fc.addEvent(allocator, evfl.makeAction("RandoEpona_Register", aa, call, try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = "OwnedHorseList.ActorName" } },
        .{ .name = "Value", .value = .{ .string = "Animal_Epona_Adult" } },
        .{ .name = "Index", .value = .{ .int = 0 } },
    })));
    for (fc.events.items[owned.?].kind.switch_.cases.items) |*c| {
        if (c.value == 1) c.event = register;
    }
    return flows.writeBack(allocator, &doc, "Dm_SY_Ocarina_EponaSong", progress);
}
