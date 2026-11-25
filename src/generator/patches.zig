//! Writing a seed: every item placement and setting becomes edits of the game's files, written to the mod folder.
//! (rando/generator.py write_patches.)

const std = @import("std");
const byml = @import("../formats/byml.zig");
const sarc = @import("../formats/sarc.zig");
const evfl = @import("../formats/evfl.zig");
const evfl_view = @import("../formats/evfl_view.zig");
const restbl_mod = @import("../formats/restbl.zig");
const fsmod = @import("../core/fs.zig");
const world_mod = @import("../game/world.zig");
const logic = @import("../logic/logic.zig");
const patchset = @import("patchset.zig");
const fill = @import("fill.zig");
const gamedata = @import("gamedata.zig");
const faststart = @import("faststart.zig");
const qol = @import("qol.zig");
const storyskip = @import("storyskip.zig");
const hints = @import("hints.zig");
const npcrewards = @import("npcrewards.zig");
const textpatches = @import("textpatches.zig");
const ocarina_handover = @import("ocarina_handover.zig");
const teststart = @import("teststart.zig");
const door = @import("door.zig");
const pickups = @import("pickups.zig");
const flows = @import("flows.zig");
const filecache = @import("filecache.zig");
const compressor = @import("compressor.zig");
const keyitems = @import("keyitems.zig");
const progressive = @import("../logic/progressive.zig");
const progressive_flows = @import("progressive_flows.zig");
const zstd = @import("../formats/zstd.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const ItemId = logic.ItemId;

pub const WriteError = PatchError || error{
    /// a setting can't be applied to this romfs (the Progress failure message says which and why)
    SettingFailed,
    /// the mod folder couldn't be written
    WriteFailed,
};

const bomb_lift_param = "Component/LiftableParam/Item_Bomb.game__component__LiftableParam.bgyml";
const bomb_packs = [_][]const u8{
    "Pack/Actor/Item_Bomb.pack.zs",
    "Pack/Actor/Npc_Hylia_ImperialSoldier_Bomb.pack.zs",
    "Pack/Actor/Obj_BombFlower_A_01.pack.zs",
    "Pack/Actor/Obj_BombFlower_A_04.pack.zs",
    "Pack/Actor/Obj_BombFlower_Fruit_For_Break_Obj_DeathMtTrail_BrokenRock_A_01.pack.zs",
};
/// LiftableGrade granted by the Goron Bracelet
const bracelet_grade: u32 = 3655598229;
/// grade of pots, small rocks, Bombchus (no bracelet needed)
const default_grade: u32 = 3069107721;
const skip_setting = "Event/EventSetting/EventSettingComponent/SkipSetting/DisableSkip.engine__event__SkipSetting.bgyml";

/// Chest "get" events that act out the vanilla item. Get_StoneOfForest_GetSword (the Kokiri Sword chest) plays a scene
/// where Link swings the sword: he ends up holding a Kokiri Sword that isn't in the save. A randomized chest uses the
/// normal chest event instead, and so does the vanilla sword chest with Skip Cutscenes (skip_story_scenes).
const item_get_events = [_][]const u8{"Get_StoneOfForest_GetSword"};

const StageEdit = struct {
    hash: u64,
    loc: usize,
    item: ItemId,
};

const EventEdit = struct {
    offset: usize,
    value: union(enum) {
        actor: []const u8,
        /// an Ocarina handed over by a hand-over call: written as its held-up display actor (built by the pickup
        /// builder, so resolved when the edits are applied), or `fallback` if that can't be built
        held_up_ocarina: struct { item_base: []const u8, fallback: []const u8 },
        /// a progressive item: the hand-over branches on the tiers owned (progressive_flows.zig)
        progressive: ProgressiveHandOver,
        price: i64,
    },
};

const ProgressiveHandOver = struct {
    chain: *const progressive.Chain,
    /// handed over by a hand-over call (world.EventRef.held_up): a held-up Ocarina gets its display actor
    held_up: bool,
    shows_item_only: bool,
};

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn appendTo(comptime T: type, map: *std.StringHashMap(std.ArrayList(T)), allocator: Allocator, key: []const u8, value: T) PatchError!void {
    const slot = map.getOrPut(key) catch return error.OutOfMemory;
    if (!slot.found_existing) slot.value_ptr.* = .empty;
    slot.value_ptr.append(allocator, value) catch return error.OutOfMemory;
}

fn sortedKeys(comptime V: type, allocator: Allocator, map: *const std.StringHashMap(V)) PatchError![][]const u8 {
    const out = allocator.alloc([]const u8, map.count()) catch return error.OutOfMemory;
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    std.mem.sort([]const u8, out, {}, lessString);
    return out;
}

/// An actor that must exist for an item (patching can't go on without it).
/// The Ocarinas some chest holds, as their display actor (pickups.chestDisplayActor, already built for the chest) and
/// the real Ocarina.
fn ocarinasInChests(allocator: Allocator, world: *World, plan: *fill.Plan, cloner: *pickups.PickupCloner, locs: []const world_mod.Location, placed: []const ?ItemId) PatchError![]const ocarina_handover.Ocarina {
    var out: std.ArrayList(ocarina_handover.Ocarina) = .empty;
    for (placed, 0..) |maybe, i| {
        const item = maybe orelse continue;
        if (locs[i].kind != .chest) continue;
        // a progressive Ocarina's chest shows either tier (the conditional chest)
        const single = [_][]const u8{world.items.name(item)};
        var keys: []const []const u8 = &single;
        if (fill.progressiveChainOf(plan, item)) |chain| {
            const tier_keys = allocator.alloc([]const u8, chain.tiers.len) catch return error.OutOfMemory;
            for (chain.tiers, 0..) |tier, t| tier_keys[t] = tier.key;
            keys = tier_keys;
        }
        for (keys) |key| {
            const base = World.wornEquipmentBase(key) orelse continue;
            const display_actor = (try cloner.chestDisplayActor(base)) orelse continue;
            const real_actor = (try world.actorFor(allocator, key, .event)) orelse continue;
            try ocarina_handover.appendOnce(allocator, &out, .{ .display_actor = display_actor, .real_actor = real_actor });
        }
    }
    return out.items;
}

/// Adds flow `rel` (now `data`) to `list` for storyskip.updateEventInfo, by its flow name ("Event/EventFlow/X.bfevfl.zs" -> X).
fn rememberChangedFlow(allocator: Allocator, list: *std.ArrayList(storyskip.ChangedFlow), rel: []const u8, data: []const u8) PatchError!void {
    const base = fsmod.basename(rel);
    const name = if (std.mem.indexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    const doc = evfl.read(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData => return error.NotAsExpected,
    };
    const flowchart = doc.flowchart orelse return error.NotAsExpected;
    for (list.items) |*known| if (std.mem.eql(u8, known.name, name)) {
        known.flowchart = flowchart;
        return;
    };
    list.append(allocator, .{ .name = name, .flowchart = flowchart }) catch return error.OutOfMemory;
}

/// True when location `i` gets an item of the fill's choosing or a test placement: a shuffled location, or one a
/// test placement took off the shuffled list (Plan.applyTestPlacements). Unshuffled vanilla locations are false.
fn locationGetsPlacedItem(plan: *const fill.Plan, i: usize) bool {
    return plan.is_shuffled[i] or plan.forced[i] != null;
}

fn requireActor(allocator: Allocator, world: *World, item: ItemId, context: World.Context, progress: *Progress) PatchError![]const u8 {
    return (try world.actorForId(allocator, item, context)) orelse
        progress.fail(error.NotAsExpected, "no actor for item {s} in {s} context", .{ world.items.name(item), @tagName(context) });
}

pub const Inputs = struct {
    world: *World,
    plan: *fill.Plan,
    /// per location: the item placed there (shuffled placements and forced ones)
    placed: []const ?ItemId,
    hint_list: []const hints.Hint,
    out_romfs: []const u8,
    /// the file cache: where compressed files are reused from, or null to compress every file
    cache: ?*filecache.FileCache = null,
    /// a test seed's start (teststart.resolve), or null
    test_start: ?*const teststart.Resolved = null,
};

/// Every changed file goes to `inputs.out_romfs`. Returns the written romfs-relative paths.
///
/// `allocator` (the generation arena) holds what spans the whole run: the edit lists, the emitted files, the size
/// table. Each patch step works in a scratch arena on `gpa` that is cleared when the step is done (patches.endStep):
/// the decompressed originals and parse trees of one step are never all in memory together with the next step's.
pub fn writePatches(gpa: Allocator, allocator: Allocator, inputs: Inputs, progress: *Progress) WriteError![][]const u8 {
    const world = inputs.world;
    const plan = inputs.plan;
    const st = plan.st;
    const placed = inputs.placed;
    const a = allocator;
    const locs = world.locations.items;
    const items = &world.items;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var patches = patchset.PatchSet.init(a, &scratch, world);
    // the current step's scratch memory (cleared by patches.endStep)
    const s = patches.allocator;
    var stage_edits = std.StringHashMap(std.ArrayList(StageEdit)).init(a);
    var event_edits = std.StringHashMap(std.ArrayList(EventEdit)).init(a);
    var shop_presences: std.ArrayList(gamedata.ShopPresence) = .empty;
    const refills = st.flag(.refill_needs_item);

    // Skip Cutscenes: the Kokiri Sword chest uses the normal chest opening even with the sword in it; its sword scene
    // only puts the sword in Link's hand and sets no save flags
    const quick_vanilla = a.alloc(bool, locs.len) catch return error.OutOfMemory;
    @memset(quick_vanilla, false);
    if (st.flag(.skip_story_scenes)) {
        for (locs, 0..) |l, i| {
            if (l.kind == .chest and items.is(l.vanilla, "Sword_Kokiri")) quick_vanilla[i] = true;
        }
    }
    for (locs, 0..) |l, i| {
        if (!quick_vanilla[i] or placed[i] != null) continue;
        const item = plan.fixed[i] orelse l.vanilla;
        for (l.stage_refs) |r| try appendTo(StageEdit, &stage_edits, a, r.rel, .{ .hash = r.hash, .loc = i, .item = item });
    }
    for (placed, 0..) |maybe, i| {
        const item = maybe orelse continue;
        const loc = &locs[i];
        const needs = if (refills and loc.kind == .chest) fill.refillContainer(items.name(item)) else null;
        if (item == loc.vanilla and !loc.conditional and needs == null and !quick_vanilla[i]) continue;
        if (loc.kind == .shop and items.isJunk(item)) continue; // junk on a shelf: the shelf keeps its normal goods
        for (loc.stage_refs) |r| try appendTo(StageEdit, &stage_edits, a, r.rel, .{ .hash = r.hash, .loc = i, .item = item });
        if (loc.event_refs.len > 0) {
            const actor = try requireActor(a, world, item, .event, progress);
            // Why: a hand-over call creates the named actor in Link's hands, and an Ocarina's Item_ actor is the
            // equipment Link wears: the game crashed when a Business Scrub sold the Ocarina of Time (issue #5, seed
            // LZ9S6JU9BS). The game's own scenes only ever add an Ocarina silently. Such a call gets the display actor
            // chests already use (pickups.chestDisplayActor), which gives the real Ocarina; silent adds keep it.
            const worn_base = World.wornEquipmentBase(items.name(item));
            const chain = fill.progressiveChainOf(plan, item);
            for (loc.event_refs) |r| {
                const value: @FieldType(EventEdit, "value") = if (chain) |line|
                    .{ .progressive = .{ .chain = line, .held_up = r.held_up, .shows_item_only = r.shows_item_only } }
                else if (r.held_up and worn_base != null)
                    .{ .held_up_ocarina = .{ .item_base = worn_base.?, .fallback = actor } }
                else
                    .{ .actor = actor };
                try appendTo(EventEdit, &event_edits, a, r.rel, .{ .offset = r.offset, .value = value });
            }
        }
    }

    const rt_rel = try world.find(a, "System/Resource", "ResourceSizeTable");
    const rt_original = try patches.read(rt_rel);
    // only the table's dictionary name (owned by the zstd context) is used after this: its bytes are scratch
    const rt_dictionary = rt_original.dictionary;
    var restbl = restbl_mod.Restbl.parse(a, rt_original.data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData => return progress.fail(error.NotAsExpected, "the resource size table is not as expected", .{}),
    };
    patches.endStep();

    // items lying in the world need a real pickup actor (pickups.zig)
    var cloner = pickups.PickupCloner.init(world, &patches, &restbl, progress);
    // key rings and dungeon boss keys first: the chests, drops and gifts below place them
    const key_items = try keyitems.build(world, &patches, &cloner, &plan.options, progress);
    patches.endStep();
    if (key_items > 0) progress.log("Dungeon keys: {d} key rings / boss keys made", .{key_items});

    for (try sortedKeys(std.ArrayList(StageEdit), a, &stage_edits)) |rel| {
        const edits = stage_edits.get(rel).?.items;
        // one stage file at a time: its tree (often tens of MB) is freed before the next one is parsed
        const orig = try patches.read(rel);
        const doc = try byml.load(s, orig.data);
        const root = (doc.root orelse return error.InvalidData).asDict() orelse return error.InvalidData;
        var hits: usize = 0;
        if (root.getArray("Actors")) |actors| {
            for (actors.items.items) |av| {
                const actor = av.asDict() orelse continue;
                const h: u64 = @truncate(@as(u128, @bitCast(actor.getInt("Hash") orelse 0)));
                for (edits) |edit| {
                    if (edit.hash != h) continue;
                    hits += 1;
                    try patchActor(s, a, world, plan, &cloner, &shop_presences, actor, edit, quick_vanilla[edit.loc], refills, progress);
                }
            }
            try hideBoardsOfSoldShelves(s, actors, edits, world, shop_presences.items);
        }
        if (hits != edits.len) return progress.fail(error.NotAsExpected, "{s}: expected {d} actors, patched {d}", .{ rel, edits.len, hits });
        try patches.emitZs(rel, orig, try byml.dumpDefault(s, .{ .dict = root }));
        patches.endStep();
    }

    // Dampé's gravedigging tour: the prize his dig brings up out of the hole shows the placed item (qol.zig says why
    // it stays his own Piece of Heart actor)
    for (locs, 0..) |l, i| {
        if (!std.mem.eql(u8, l.name, qol.dampe_tour_location)) continue;
        const item = placed[i] orelse continue;
        if (item == l.vanilla) continue;
        const model_actor = try requireActor(a, world, item, .world, progress);
        if (try cloner.dressInModelOf(qol.dampe_dig_prize_actor, model_actor)) {
            progress.log("Dampé's gravedigging tour: the prize he digs up looks like {s}", .{model_actor});
        }
        patches.endStep();
    }

    if (cloner.heights_moved > 0) {
        progress.log("Item heights: {d} placements raised or lowered to rest like the item they replace (largest move {d:.2})", .{ cloner.heights_moved, cloner.largest_height_move });
    }

    if (st.flag(.gs_any_time)) {
        // after the item edits: a Skulltula copied for child Link carries its shuffled drop
        try qol.patchGsAnyTime(world, &patches, progress);
        patches.endStep();
    }
    if (st.is(.maps_compasses, "own") or st.is(.boss_keys, "own")) {
        // a map, compass or boss key can end up in a small chest, whose opening didn't credit the dungeon
        _ = try qol.patchSmallChestDungeonItems(&patches, progress);
        patches.endStep();
    }

    // Business Scrubs: the price of each shuffled scrub's purchase calls. A test placement takes its location off
    // the shuffled list, so test-placed scrubs are included too (they kept the vanilla price and sale line before).
    for (0..locs.len) |i| {
        if (!locationGetsPlacedItem(plan, i)) continue;
        const price = plan.scrub_prices[i] orelse continue;
        for (locs[i].price_refs) |r| try appendTo(EventEdit, &event_edits, a, r.rel, .{ .offset = r.offset, .value = .{ .price = price } });
    }
    // flows given an Ocarina's swap and tutorial (ocarina_handover.zig): their event info must list what they call
    var ocarina_changed_flows: std.ArrayList(storyskip.ChangedFlow) = .empty;
    for (try sortedKeys(std.ArrayList(EventEdit), a, &event_edits)) |rel| {
        const orig = try patches.read(rel);
        var v = evfl_view.View.init(s, orig.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidData => return progress.fail(error.NotAsExpected, "{s} is not a readable event flow", .{rel}),
        };
        var hand_overs: std.ArrayList(progressive_flows.HandOver) = .empty;
        // Ocarina display actors this flow now hands over (plain or as a progressive tier), for ocarina_handover.zig
        var ocarinas_handed_over: std.ArrayList(ocarina_handover.Ocarina) = .empty;
        for (event_edits.get(rel).?.items) |e| {
            switch (e.value) {
                .price => |p| v.setIntParam(e.offset, @intCast(p)),
                .actor => |actor| try v.setStringParam(e.offset, actor),
                .held_up_ocarina => |o| {
                    const display_actor = (try cloner.chestDisplayActor(o.item_base)) orelse o.fallback;
                    try v.setStringParam(e.offset, display_actor);
                    // the display actor gives no tutorial or button: swapped for the real Ocarina after (ocarina_handover.zig)
                    if (!std.mem.eql(u8, display_actor, o.fallback)) try ocarina_handover.appendOnce(a, &ocarinas_handed_over, .{ .display_actor = display_actor, .real_actor = o.fallback });
                },
                .progressive => |p| {
                    const tier_actors = try progressiveTierActors(s, world, &cloner, p, progress);
                    // the node itself keeps tier 1; the branch adds the others after the plain edits
                    try v.setStringParam(e.offset, tier_actors[0]);
                    hand_overs.append(s, .{ .item_offset = e.offset, .chain = p.chain, .tier_actors = tier_actors, .shows_item_only = p.shows_item_only }) catch return error.OutOfMemory;
                    // a held-up Ocarina tier is its display actor (progressiveTierActors)
                    for (p.chain.tiers, tier_actors) |tier, tier_actor| {
                        const real_actor = (try world.actorFor(a, tier.key, .event)) orelse continue;
                        if (World.wornEquipmentBase(tier.key) != null and !std.mem.eql(u8, tier_actor, real_actor))
                            try ocarina_handover.appendOnce(a, &ocarinas_handed_over, .{ .display_actor = tier_actor, .real_actor = real_actor });
                    }
                },
            }
        }
        v.check(s) catch return progress.fail(error.NotAsExpected, "{s}: the patched flow doesn't parse", .{rel});
        // progressive branches first: their tier copies are hand-overs too, found by the display actor they name
        var flow_data: []const u8 = v.bytesView();
        if (hand_overs.items.len > 0) {
            flow_data = try progressive_flows.branchHandOvers(s, flow_data, &v, hand_overs.items, rel, progress);
            progress.log("Progressive items: {d} hand-overs in {s} give the next tier", .{ hand_overs.items.len, fsmod.basename(rel) });
        }
        if (ocarinas_handed_over.items.len > 0) {
            flow_data = try ocarina_handover.finishHandOvers(a, flow_data, ocarinas_handed_over.items, rel, progress);
            try rememberChangedFlow(a, &ocarina_changed_flows, rel, flow_data);
        }
        try patches.emitZs(rel, orig, flow_data); // emit keeps its own copy
        patches.endStep();
    }

    if (inputs.hint_list.len > 0) {
        try hints.writeText(world, &patches, inputs.hint_list, progress);
        patches.endStep();
    }

    // Business Scrubs: a sale line of its own for each shuffled scrub, naming the item it sells
    var scrubs: std.ArrayList(textpatches.Scrub) = .empty;
    for (0..locs.len) |i| {
        if (!locationGetsPlacedItem(plan, i)) continue;
        const loc = &locs[i];
        if (loc.category != .scrub) continue;
        const item = placed[i] orelse continue;
        for (world_mod.event_locations) |spec| {
            if (!std.mem.eql(u8, spec.name, loc.name) or spec.category != .scrub) continue;
            const named = spec.events orelse continue;
            const names = a.alloc([]const u8, named.len) catch return error.OutOfMemory;
            for (named, 0..) |n, k| names[k] = n.event;
            scrubs.append(a, .{ .events = names, .item_name = try world.itemNameById(a, item) }) catch return error.OutOfMemory;
        }
    }
    if (scrubs.items.len > 0) {
        _ = textpatches.writeScrubText(world, &patches, scrubs.items, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => progress.log("warning: Business Scrub text not changed ({s}); the scrubs still sell their random items", .{progress.failureMessage()}),
            else => return err,
        };
        patches.endStep();
    }

    // flow edits that add events (faststart.zig); after the item edits above, on the latest version
    const FlowEdit = struct {
        what: []const u8,
        rel: []const u8,
        kind: enum { stones_without_mask, opening_without_movie, start_outside, memory_game, dampe_prize_spot, bridge_guard, deku_meeting, quick_chest, epona },
    };
    var flow_edits: std.ArrayList(FlowEdit) = .empty;
    if (st.is(.gossip_stones, "no_mask")) flow_edits.append(a, .{ .what = "Gossip Stones: No Mask of Truth", .rel = hints.gossip_flow, .kind = .stones_without_mask }) catch return error.OutOfMemory;
    if (st.flag(.skip_opening)) flow_edits.append(a, .{ .what = "Skip Opening Movie", .rel = faststart.opening_flow, .kind = .opening_without_movie }) catch return error.OutOfMemory;
    // every seed: a new game starts outside the Kokiri Shop, without Navi's flight and wake-up scene
    flow_edits.append(a, .{ .what = "New game start", .rel = faststart.opening_flow, .kind = .start_outside }) catch return error.OutOfMemory;
    // every seed: the Lost Woods ocarina game gives its three rewards for one won song
    flow_edits.append(a, .{ .what = "Lost Woods ocarina game", .rel = qol.memory_game_flow, .kind = .memory_game }) catch return error.OutOfMemory;
    // every seed: Dampé's gravedigging tour prize always comes out of the spot in front of the Hylian Shield grave
    // (the game's update has a copy of the flow of its own)
    for ([_][]const u8{ qol.dampe_flow, qol.dampe_flow_update }) |rel| {
        if (world.files.exists(rel)) flow_edits.append(a, .{ .what = "Dampé's gravedigging tour", .rel = rel, .kind = .dampe_prize_spot }) catch return error.OutOfMemory;
    }
    if (!st.is(.rainbow_bridge, "vanilla")) flow_edits.append(a, .{ .what = "Rainbow Bridge", .rel = qol.allsage_flow, .kind = .bridge_guard }) catch return error.OutOfMemory;
    if (st.flag(.skip_deku_talk) and !st.is(.open_forest, "open")) flow_edits.append(a, .{ .what = "Skip the Great Deku Tree's Talk", .rel = faststart.mido_flow, .kind = .deku_meeting }) catch return error.OutOfMemory;
    if (st.flag(.quick_chests)) flow_edits.append(a, .{ .what = "Chests Without Cutscene", .rel = faststart.chest_flow, .kind = .quick_chest }) catch return error.OutOfMemory;
    if (st.flag(.skip_epona_race)) flow_edits.append(a, .{ .what = "Skip Epona Race", .rel = faststart.epona_song_flow, .kind = .epona }) catch return error.OutOfMemory;
    for (flow_edits.items) |fe| {
        const orig = try patches.read(fe.rel);
        const new = (switch (fe.kind) {
            .stones_without_mask => hints.stonesWithoutMask(s, orig.data, progress),
            .opening_without_movie => faststart.openingWithoutMovie(s, orig.data, progress),
            .start_outside => faststart.startOutside(s, orig.data, progress),
            .memory_game => qol.memoryGameAllRewards(s, orig.data, progress),
            .dampe_prize_spot => qol.dampePrizeAtShieldGrave(s, orig.data, progress),
            .bridge_guard => qol.bridgeQuestGuard(s, orig.data, progress),
            .deku_meeting => faststart.completeDekuMeeting(s, orig.data, progress),
            .quick_chest => faststart.quickChest(s, orig.data, progress),
            .epona => faststart.eponaWithoutRace(s, orig.data, progress),
        }) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => return progress.fail(error.SettingFailed, "{s}: {s} is not as expected in this romfs ({s}); turn the setting off", .{ fe.what, fe.rel, progress.failureMessage() }),
            else => return err,
        };
        try patches.emitZs(fe.rel, orig, new);
        progress.log("{s}: {s} changed", .{ fe.what, fsmod.basename(fe.rel) });
        patches.endStep();
    }

    // Ocarinas found in chests: after the chest scenes' item guide, the display actor is swapped for the real Ocarina
    // and its tutorial shown (ocarina_handover.zig). After the flow edits, so Chests Without Cutscene is in place.
    const chest_ocarinas = try ocarinasInChests(a, world, plan, &cloner, locs, placed);
    if (chest_ocarinas.len > 0) {
        for (ocarina_handover.chest_flows) |rel| {
            if (!world.files.exists(rel)) continue;
            const orig = try patches.read(rel);
            const finished = ocarina_handover.finishChestOpenings(a, orig.data, chest_ocarinas, rel, progress) catch |err| switch (err) {
                error.NotAsExpected, error.InvalidData => {
                    progress.log("warning: {s} not changed ({s}); an Ocarina from a chest comes without its tutorial", .{ fsmod.basename(rel), progress.failureMessage() });
                    continue;
                },
                else => return err,
            };
            try patches.emitZs(rel, orig, finished);
            try rememberChangedFlow(a, &ocarina_changed_flows, rel, finished);
        }
        patches.endStep();
    }
    if (ocarina_changed_flows.items.len > 0) {
        const events = try storyskip.updateEventInfo(a, world, &patches, ocarina_changed_flows.items, progress);
        progress.log("Ocarinas: swap and tutorial added to {d} flows (event info updated for {d} events)", .{ ocarina_changed_flows.items.len, events.len });
        patches.endStep();
    }

    if (st.flag(.skip_story_scenes)) {
        // after the item edits: a skipped scene's item (read from the patched scene) is the randomized one
        try storyskip.patchStoryScenes(world, &patches, progress, &storyskip.skips, "Skip Cutscenes", false);
        patches.endStep();
    }
    if (st.flag(.skip_area_intros)) {
        // the intros whose arrival also advances a quest (the others count as played in the save data)
        try storyskip.patchAreaIntros(world, &patches, progress);
        patches.endStep();
    }
    if (st.flag(.skip_ganon_trials)) {
        // after the story / area skips, which change the same flow
        qol.patchGanonTrials(&patches, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => return progress.fail(error.SettingFailed, "Skip Ganon's Trials: Defeat_Ganon is not as expected ({s}); turn the setting off", .{progress.failureMessage()}),
            else => return err,
        };
        patches.endStep();
    }

    if (st.is(.shuffle_songs, "anywhere")) {
        const n = try pickups.patchSongModels(world, &patches, &restbl, progress);
        progress.log("Songs Anywhere: {d} songs show Sheik's harp in chests, gifts and shops", .{n});
        patches.endStep();
    }
    // world pickups and shelves: RSDB rows and size-table entries
    try cloner.finish();
    patches.endStep();

    if (st.flag(.bag_bombs_no_bracelet)) {
        // Bag bombs share one LiftableParam resource path; every pack that carries a copy must agree, otherwise
        // whichever pack loads first decides. Bomb flowers keep their own (bracelet) grade.
        for (bomb_packs) |rel| {
            if (!world.files.exists(rel)) continue;
            // the scratch memory is cleared after every pack (also the ones skipped below)
            defer patches.endStep();
            const orig = try patches.read(rel);
            const entry = (sarc.find(s, orig.data, bomb_lift_param) catch return error.InvalidData) orelse
                return progress.fail(error.NotAsExpected, "{s} has no {s}", .{ rel, bomb_lift_param });
            const sub = entry.data;
            const grade = (try byml.loadDict(s, sub)).getInt("LiftGrade") orelse continue;
            if (grade != bracelet_grade) continue;
            const new_sub = try byml.patchRootU32(s, sub, "LiftGrade", default_grade);
            var out: std.ArrayList(u8) = .empty;
            out.appendSlice(s, orig.data[0..entry.start]) catch return error.OutOfMemory;
            out.appendSlice(s, new_sub) catch return error.OutOfMemory;
            out.appendSlice(s, orig.data[entry.end..]) catch return error.OutOfMemory;
            try patches.emitZs(rel, orig, out.items);
        }
    }

    const bridge_ok = st.flag(.shuffle_ocarinas) and try qol.patchOcarinaBridge(world, &patches, progress);
    patches.endStep();

    // three ways to own a start item: a save-data default (IsGet + pouch count: songs, single items), the game's own
    // pouch action for ocarinas (it records which ocarina Link holds), or, for anything else (bags, ammo, rupees,
    // hearts, medallions, tokens...), the gift call at the end of the opening (faststart.giveAtStart)
    var start_by_event: std.ArrayList([]const u8) = .empty;
    var start_gifts: std.ArrayList([]const u8) = .empty;
    var start_items: std.ArrayList([]const u8) = .empty;
    var start_ids: std.ArrayList(usize) = .empty;
    for (plan.start_locs, 0..) |is_start, i| if (is_start) start_ids.append(a, i) catch return error.OutOfMemory;
    std.mem.sort(usize, start_ids.items, locs, struct {
        fn less(l: []world_mod.Location, x: usize, y: usize) bool {
            return std.mem.order(u8, l[x].id, l[y].id) == .lt;
        }
    }.less);
    // a progressive item handed over at the start can't branch: the first copy of a line is its first tier, the
    // next copy the second, and so on (nothing of the line is owned before the start)
    var start_copies = std.StringHashMap(usize).init(a);
    var start_check_items: std.ArrayList(ItemId) = .empty;
    for (start_ids.items) |i| {
        start_check_items.append(a, placed[i] orelse plan.fixed[i] orelse continue) catch return error.OutOfMemory;
    }
    // a test plan's start items, handed over the same ways, after the start checks' (a progressive one gives the
    // next tier after theirs)
    const test_start_items: []const ItemId = if (inputs.test_start) |t| t.items else &.{};
    const all_start_items = std.mem.concat(a, ItemId, &.{ start_check_items.items, test_start_items }) catch return error.OutOfMemory;
    for (all_start_items) |placed_item| {
        var item = placed_item;
        if (fill.progressiveChainOf(plan, placed_item)) |chain| {
            const slot = start_copies.getOrPut(chain.key) catch return error.OutOfMemory;
            if (!slot.found_existing) slot.value_ptr.* = 0;
            const tier = chain.tiers[@min(slot.value_ptr.*, chain.tiers.len - 1)];
            slot.value_ptr.* += 1;
            item = try items.intern(tier.key);
        }
        const actor = try requireActor(a, world, item, .event, progress);
        if (flows.contains(&faststart.start_by_event, actor)) {
            start_by_event.append(a, actor) catch return error.OutOfMemory;
        } else if (plan.grantable(item) catch |err| return mapFill(err)) {
            start_items.append(a, actor) catch return error.OutOfMemory;
        } else {
            start_gifts.append(a, actor) catch return error.OutOfMemory;
        }
    }
    // the base seed bag and quiver on every new save (faststart.base_bags_at_start), added silently like an ocarina
    for (faststart.base_bags_at_start) |bag| {
        if (world.actorExists(bag) and !flows.contains(start_by_event.items, bag)) start_by_event.append(a, bag) catch return error.OutOfMemory;
    }
    // the shelves' computed flags, each once, sorted
    std.mem.sort(gamedata.ShopPresence, shop_presences.items, {}, lessPresence);
    var unique: std.ArrayList(gamedata.ShopPresence) = .empty;
    for (shop_presences.items) |p| {
        if (unique.items.len > 0 and presenceEql(unique.items[unique.items.len - 1], p)) continue;
        unique.append(a, p) catch return error.OutOfMemory;
    }
    const test_changes: []const gamedata.Change = if (inputs.test_start) |t| t.changes else &.{};
    const gd_ok = gamedata.apply(s, world, &patches, st, progress, bridge_ok, start_items.items, unique.items, test_changes) catch |err| switch (err) {
        error.NotAsExpected => return progress.fail(error.SettingFailed, "Items Shuffled Per Shop: {s}; turn the setting off", .{progress.failureMessage()}),
        else => return err,
    };
    patches.endStep();
    if (start_by_event.items.len > 0 or start_gifts.items.len > 0) {
        defer patches.endStep();
        const rel = faststart.start_item_flow;
        // after Skip Opening Movie's edit of the same flow, if any
        const orig = try patches.read(rel);
        const new = faststart.giveAtStart(s, orig.data, start_by_event.items, start_gifts.items, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => return progress.fail(error.SettingFailed, "Start items: {s} is not as expected in this romfs ({s})", .{ rel, progress.failureMessage() }),
            else => return err,
        };
        try patches.emitZs(rel, orig, new);
        if (start_gifts.items.len > 0) {
            const doc = try evfl.read(s, new);
            _ = storyskip.updateEventInfo(s, world, &patches, &.{.{ .name = "OpeningEvent", .flowchart = doc.flowchart.? }}, progress) catch |err| switch (err) {
                error.NotAsExpected, error.InvalidData => return progress.fail(error.SettingFailed, "Start items: the opening's event info could not be updated ({s})", .{progress.failureMessage()}),
                else => return err,
            };
        }
        var all: std.ArrayList([]const u8) = .empty;
        all.appendSlice(a, start_by_event.items) catch return error.OutOfMemory;
        all.appendSlice(a, start_gifts.items) catch return error.OutOfMemory;
        progress.log("Start items handed over when a new game starts: {s}", .{std.mem.join(a, ", ", all.items) catch return error.OutOfMemory});
    }
    if (inputs.test_start) |test_start| if (test_start.warp != null or test_start.time_hour != null) {
        // after the start items' edit of the same flow, so the scene change comes after the items are handed over
        defer patches.endStep();
        const orig = try patches.read(teststart.opening_flow);
        const new = teststart.startAtTestSpawn(s, orig.data, test_start.warp, test_start.time_hour, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => return progress.fail(error.SettingFailed, "Test start: {s} is not as expected ({s})", .{ teststart.opening_flow, progress.failureMessage() }),
            else => return err,
        };
        try patches.emitZs(teststart.opening_flow, orig, new);
    };

    if (st.flag(.saria_song_ocarina)) {
        if (gd_ok) {
            try qol.patchSariaSong(world, &patches, progress, gamedata.saria_gate_old, gamedata.saria_gate_new);
        } else {
            progress.log("warning: could not add the ocarina save flag; Saria's Song still needs Zelda", .{});
        }
    }
    if (st.is(.open_forest, "open")) _ = try qol.patchOpenForestMido(&patches, progress);
    if (st.flag(.skip_child_zelda)) _ = try qol.patchKokiriSchedules(world, &patches, progress);
    if (st.is(.open_zora, "open")) _ = try qol.patchOpenZoraArrival(&patches, progress, gamedata.zora_open_quest_step);
    if (st.is(.open_door, "open") and !try door.patchOpenDoor(&patches, progress)) {
        return progress.fail(error.SettingFailed, "Door of Time: Open could not be applied to this romfs; set the Door of Time to Closed", .{});
    }
    if (!st.is(.shuffle_songs, "vanilla")) try qol.patchSongTeaching(world, &patches, progress);
    if (st.flag(.shuffle_weird_egg)) try qol.patchEggHatchGuard(&patches, progress);
    if (st.flag(.dodongo_bag_bombs) and !try qol.patchDodongoBagBombs(world, &patches, &restbl, progress)) {
        // the logic already counted bag bombs for the entrance, so the seed would not be safe
        return progress.fail(error.SettingFailed, "Dodongo's Cavern boulder not recognised in this romfs; turn off 'Bag Bombs Open Dodongo's Cavern'", .{});
    }
    if (st.flag(.anju_one_cucco)) try qol.patchAnju(world, &patches, progress, 1);
    if (st.flag(.big_poe_one)) _ = try qol.patchBigPoeOne(&patches, progress);
    // the small flow edits above each touch one or two files, so they share one step
    patches.endStep();

    if (st.flag(.skip_cutscenes)) {
        defer patches.endStep();
        // One shared component blocks skipping (opening, credits, title demos); switch it off.
        if (world.files.exists(skip_setting)) {
            const orig = try patches.read(skip_setting);
            const root = try byml.loadDict(s, orig.data);
            if (root.get("IsDisableSkip")) |v| {
                if (v.isTruthy()) {
                    try root.put(s, "IsDisableSkip", .{ .bool = false });
                    try patches.emit(skip_setting, orig.data, try byml.dumpDefault(s, .{ .dict = root }), null, false);
                }
            }
        } else {
            progress.log("warning: cutscene skip setting not found in this romfs; skipped", .{});
        }
    }

    // character gifts and minigames: the model they show and the lines that name the reward follow the shuffled item
    // (the list is used by both steps, so it is in the generation arena)
    const changed = npcrewards.changedLocations(a, plan, placed) catch return error.OutOfMemory;
    if (changed.len > 0) {
        _ = npcrewards.swapModels(world, &patches, changed, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => progress.log("warning: reward models left as they are ({s})", .{progress.failureMessage()}),
            else => return err,
        };
        patches.endStep();
        _ = npcrewards.writeText(world, &patches, changed, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => progress.log("warning: reward text left as it is ({s})", .{progress.failureMessage()}),
            else => return err,
        };
        patches.endStep();
    }

    // last of the flow edits, so every other change to DoorOfTime is in: the altar tells the bridge requirement
    textpatches.writeBridgeText(world, &patches, st, progress) catch |err| switch (err) {
        error.NotAsExpected, error.InvalidData => progress.log("warning: the Temple of Time altar couldn't show the bridge requirement ({s})", .{progress.failureMessage()}),
        else => return err,
    };
    patches.endStep();

    return writeFiles(gpa, a, world, &patches, &restbl, rt_rel, rt_dictionary, inputs.out_romfs, inputs.cache, progress);
}

fn mapFill(err: fill.FillError) PatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GameFiles => error.GameFiles,
        error.InvalidData => error.InvalidData,
        else => error.NotAsExpected,
    };
}

/// The order Python sorted the (name, condition, negated, owned) tuples in.
fn lessPresence(_: void, x: gamedata.ShopPresence, y: gamedata.ShopPresence) bool {
    switch (std.mem.order(u8, x.name, y.name)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, x.condition, y.condition)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (x.negated != y.negated) return !x.negated;
    return std.mem.order(u8, x.owned, y.owned) == .lt;
}

fn presenceEql(x: gamedata.ShopPresence, y: gamedata.ShopPresence) bool {
    return std.mem.eql(u8, x.name, y.name) and std.mem.eql(u8, x.condition, y.condition) and x.negated == y.negated and std.mem.eql(u8, x.owned, y.owned);
}

/// The edit of one placement: a chest's drop, a shelf's actor, a Skulltula's drop or a world pickup. `a` is the stage
/// file's scratch memory (the actor tree's edits); `keep` holds the shop flag names, which outlive the stage file.
fn patchActor(
    a: Allocator,
    keep: Allocator,
    world: *World,
    plan: *fill.Plan,
    cloner: *pickups.PickupCloner,
    shop_presences: *std.ArrayList(gamedata.ShopPresence),
    actor: *byml.Dict,
    edit: StageEdit,
    quick_vanilla: bool,
    refills: bool,
    progress: *Progress,
) PatchError!void {
    const loc = &world.locations.items[edit.loc];
    const item = edit.item;
    const name = world.items.name(item);
    switch (loc.kind) {
        .chest => {
            const dyn = try actor.ensureDict(a, "Dynamic");
            if (dyn.getString("GetEventName")) |ev| {
                if (flows.contains(&item_get_events, ev) and (item != loc.vanilla or quick_vanilla)) {
                    // the chest's own event hands out its vanilla item again (unsaved), so drop it; with Skip Cutscenes
                    // the vanilla sword also comes from the normal chest opening
                    _ = dyn.remove("GetEventName");
                }
            }
            if (fill.progressiveChainOf(plan, item)) |chain| {
                // the game's conditional chest makes one check (logic/progressive.zig): own the tier below the top
                // one -> the top one, else that tier below. Two tiers: exact. Three: the fill only puts a copy in a
                // chest the logic can't reach without the first tier
                const fallback = chain.chestFallbackTier();
                const top = &chain.tiers[chain.tiers.len - 1];
                try dyn.put(a, "Drop__DropActor", .{ .string = try chestShownActorOf(a, world, plan, cloner, fallback.key, progress) });
                try dyn.put(a, "Drop__CheckActor", .{ .string = fallback.pouch_actor });
                try dyn.put(a, "Drop__DropActor_Substitute", .{ .string = try chestShownActorOf(a, world, plan, cloner, top.key, progress) });
                return;
            }
            const needs = if (refills) fill.refillContainer(name) else null;
            if (needs) |container| {
                if (world.actorExists(container)) {
                    // the game's own conditional chest: owns CheckActor -> Substitute, else DropActor
                    const fallback = (try world.actorFor(a, fill.refill_fallback, .chest)) orelse return progress.fail(error.NotAsExpected, "no chest actor for {s}", .{fill.refill_fallback});
                    try dyn.put(a, "Drop__DropActor", .{ .string = fallback });
                    try dyn.put(a, "Drop__CheckActor", .{ .string = container });
                    try dyn.put(a, "Drop__DropActor_Substitute", .{ .string = try requireActor(a, world, item, .chest, progress) });
                    return;
                }
            }
            try dyn.put(a, "Drop__DropActor", .{ .string = try chestShownActorOf(a, world, plan, cloner, name, progress) });
            _ = dyn.remove("Drop__CheckActor");
            _ = dyn.remove("Drop__DropActor_Substitute");
        },
        .shop => {
            // a new shelf actor that sells the item once, at its price (pickups.zig, OotrR)
            const event_actor = try requireActor(a, world, item, .event, progress);
            const shelf_actor = try cloner.shopActor(event_actor, plan.shop_prices[edit.loc].?);
            // a big item (a Heart Container, a permanent upgrade) at half size on the shelf (pickups.shopShelfScale)
            const shelf_scale = try cloner.shopShelfScale(shelf_actor);
            try restOnOriginalModelBottom(a, cloner, actor, shelf_actor, shelf_scale, true);
            if (shelf_scale != 1.0) {
                const scale = try byml.Array.create(a);
                for (0..3) |_| try scale.append(a, .{ .float = @floatCast(shelf_scale) });
                try actor.put(a, "Scale", .{ .array = scale });
            }
            // an item whose model faces sideways (Sheik's harp for a song) turned to face the front (shopShelfTurn)
            // (a song is only on a shelf with Songs Anywhere; the check names the setting it belongs to)
            const shelf_turn = if (plan.st.is(.shuffle_songs, "anywhere")) cloner.shopShelfTurn(shelf_actor) else 0.0;
            if (shelf_turn != 0.0) {
                const rotation = try byml.Array.create(a);
                const old_rotation = actor.getArray("Rotate");
                for (0..3) |axis| {
                    var angle: f64 = 0.0;
                    if (old_rotation) |old| if (axis < old.items.items.len) {
                        angle = old.items.items[axis].asFloat() orelse 0.0;
                    };
                    if (axis == 1) angle += shelf_turn;
                    try rotation.append(a, .{ .float = @floatCast(angle) });
                }
                try actor.put(a, "Rotate", .{ .array = rotation });
            }
            try actor.put(a, "Gyaml", .{ .string = shelf_actor });
            // sold once: the shelf is gone once the item is owned (its IsGet flag; Plan.soldOnce)
            const owned = std.fmt.allocPrint(keep, "IsGet.{s}", .{event_actor}) catch return error.OutOfMemory;
            const presence = try byml.Dict.create(a);
            const story = actor.getDict("Presence");
            const story_flag = if (story) |s| s.getString("FlagName") orelse "" else "";
            if (story_flag.len > 0) {
                // a shelf shown under a story condition of its own (the Kokiri Shop's two copies of each shelf, before /
                // after the Deku Tree): a new computed flag keeps that condition AND not owned
                const neg = if (story.?.get("IsNegation")) |v| v.isTruthy() else false;
                const flag = std.fmt.allocPrint(keep, "Rando_Shop_{s}_{s}{s}", .{ event_actor, if (neg) "Not_" else "", story_flag }) catch return error.OutOfMemory;
                // story_flag is a string of the stage tree, which is freed after this stage file
                const condition = keep.dupe(u8, story_flag) catch return error.OutOfMemory;
                shop_presences.append(keep, .{ .name = flag, .condition = condition, .negated = neg, .owned = owned }) catch return error.OutOfMemory;
                try presence.put(a, "FlagName", .{ .string = flag });
                try presence.put(a, "IsCheckLazy", .{ .bool = false });
                try presence.put(a, "IsNegation", .{ .bool = false });
            } else {
                try presence.put(a, "FlagName", .{ .string = owned });
                try presence.put(a, "IsCheckLazy", .{ .bool = false });
                try presence.put(a, "IsNegation", .{ .bool = true });
            }
            try actor.put(a, "Presence", .{ .dict = presence });
        },
        .gs => {
            // a token-based pickup: floats like a token, is collected by touch, and sets the Skulltula's save flag when
            // collected (pickups.zig), consumables included
            const dyn = try actor.ensureDict(a, "Dynamic");
            try dyn.put(a, "Drop__DropActor", .{ .string = try cloner.tokenActor(try requireActor(a, world, item, .event, progress)) });
        },
        else => {
            // an unchanged vanilla pickup keeps its own actor (and its own A/walk-over behaviour)
            const world_actor = try requireActor(a, world, item, .world, progress);
            const placed_actor = try cloner.worldActor(world_actor, item != loc.vanilla);
            try restOnOriginalModelBottom(a, cloner, actor, placed_actor, 1.0, false);
            try actor.put(a, "Gyaml", .{ .string = placed_actor });
        },
    }
}

/// A shuffled shop shelf links to its board (Shop_Board_Bundle_*, the "x 10" sign under it: a Links entry of the
/// shelf, Name "Reference"). The shelf is hidden once its item is owned (its Presence, set in patchActor), but the
/// board is an actor of its own and stayed (test report, 0.7.5: the Echo Gem bought, its board left). Each such
/// board gets the shelf's Presence, so it goes with it.
/// A shelf without a link (the Kokiri Shop's before-the-Deku-Tree copies) has its board standing at the same spot as
/// an actor of its own, with the same story condition as the shelf had: the nearest such board within 0.75 m is
/// taken. `shop_presences` gives each computed shelf flag's story condition.
fn hideBoardsOfSoldShelves(a: Allocator, actors: *byml.Array, edits: []const StageEdit, world: *World, shop_presences: []const gamedata.ShopPresence) PatchError!void {
    for (actors.items.items) |shelf_value| {
        const shelf = shelf_value.asDict() orelse continue;
        const hash: u64 = @truncate(@as(u128, @bitCast(shelf.getInt("Hash") orelse 0)));
        var is_shuffled_shelf = false;
        for (edits) |edit| if (edit.hash == hash and world.locations.items[edit.loc].kind == .shop) {
            is_shuffled_shelf = true;
        };
        if (!is_shuffled_shelf) continue;
        const presence = shelf.getDict("Presence") orelse continue;
        var board_found = false;
        if (shelf.getArray("Links")) |links| for (links.items.items) |link_value| {
            const link = link_value.asDict() orelse continue;
            if (!std.mem.eql(u8, link.getString("Name") orelse "", "Reference")) continue;
            const target: u64 = @truncate(@as(u128, @bitCast(link.getInt("Dst") orelse continue)));
            for (actors.items.items) |board_value| {
                const board = board_value.asDict() orelse continue;
                const board_hash: u64 = @truncate(@as(u128, @bitCast(board.getInt("Hash") orelse 0)));
                if (board_hash != target) continue;
                if (!std.mem.startsWith(u8, board.getString("Gyaml") orelse "", "Shop_Board_")) continue;
                try board.put(a, "Presence", try (byml.Value{ .dict = presence }).clone(a));
                board_found = true;
            }
        };
        if (board_found) continue;

        // the story condition the shelf had before its sold-once flag (none: a shelf shown at all times)
        const shelf_flag = presence.getString("FlagName") orelse "";
        var story_condition: []const u8 = "";
        var story_negated = false;
        for (shop_presences) |p| if (std.mem.eql(u8, p.name, shelf_flag)) {
            story_condition = p.condition;
            story_negated = p.negated;
        };
        const shelf_pos = placementPosition(shelf) orelse continue;
        var nearest: ?*byml.Dict = null;
        var nearest_distance: f64 = 0.75;
        for (actors.items.items) |board_value| {
            const board = board_value.asDict() orelse continue;
            if (!std.mem.startsWith(u8, board.getString("Gyaml") orelse "", "Shop_Board_Bundle")) continue;
            const board_story = board.getDict("Presence");
            const board_flag = if (board_story) |bs| bs.getString("FlagName") orelse "" else "";
            const board_negated = if (board_story) |bs| (if (bs.get("IsNegation")) |v| v.isTruthy() else false) else false;
            if (!std.mem.eql(u8, board_flag, story_condition) or board_negated != story_negated) continue;
            const board_pos = placementPosition(board) orelse continue;
            const distance = @sqrt((board_pos[0] - shelf_pos[0]) * (board_pos[0] - shelf_pos[0]) +
                (board_pos[1] - shelf_pos[1]) * (board_pos[1] - shelf_pos[1]) +
                (board_pos[2] - shelf_pos[2]) * (board_pos[2] - shelf_pos[2]));
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest = board;
            }
        }
        if (nearest) |board| try board.put(a, "Presence", try (byml.Value{ .dict = presence }).clone(a));
    }
}

fn placementPosition(actor: *const byml.Dict) ?[3]f64 {
    const translate = actor.getArray("Translate") orelse return null;
    if (translate.items.items.len != 3) return null;
    return .{
        translate.items.items[0].asFloat() orelse return null,
        translate.items.items[1].asFloat() orelse return null,
        translate.items.items[2].asFloat() orelse return null,
    };
}

/// Moves a placement up or down so `new_actor`'s model rests where the placed actor's model did: by the difference
/// of their model bottoms (pickups.PickupCloner.modelBottom), times the placement's height scale. A placement that
/// keeps its actor, or a model without a known box, is left as it is. Only the height changes, along the world's
/// up axis (Translate's second value; the scenes stand items upright, turned only about that axis).
/// `new_scale`: the scale the new item gets on top of the placement's own (shop shelves: shopShelfScale).
/// `on_shelf`: a shop shelf, which adds the shelf-only corrections (pickups.shelfMeasuredLift).
fn restOnOriginalModelBottom(a: Allocator, cloner: *pickups.PickupCloner, actor: *byml.Dict, new_actor: []const u8, new_scale: f64, on_shelf: bool) PatchError!void {
    const old_actor = actor.getString("Gyaml") orelse return;
    if (std.mem.eql(u8, old_actor, new_actor)) return;
    const old_bottom = (try cloner.modelBottom(old_actor)) orelse return;
    const new_bottom = (try cloner.modelBottom(new_actor)) orelse return;
    const height_scale: f64 = if (actor.get("Scale")) |scale| switch (scale) {
        .array => |values| if (values.items.items.len == 3) values.items.items[1].asFloat() orelse 1.0 else 1.0,
        else => scale.asFloat() orelse 1.0,
    } else 1.0;
    // why the floor: a pickup is collected at its origin. The worn-armour models (Lens of Truth 0.92 m, Gauntlets
    // 1.17 m above their origin) would need their origin a metre under the surface, where Link can't reach it
    // (HEIGHTTEST1: the Lens in the Kokiri Forest stream couldn't be picked up). Lowered at most 0.35 m, such an item
    // floats a little instead.
    const max_lowering: f64 = 0.35;
    // plus, after that floor, the corrections measured in test seeds (pickups.measuredExtraLift)
    const box_lift = (@as(f64, old_bottom) - @as(f64, new_bottom) * new_scale) * height_scale;
    const measured = cloner.measuredExtraLift(new_actor) + if (on_shelf) cloner.shelfMeasuredLift(new_actor) else 0.0;
    const lift: f64 = @max(-max_lowering, box_lift) + measured * height_scale * new_scale;
    // why: a few millimetres are rounding between two models made to rest the same way; leave those placements alone
    if (@abs(lift) < 0.005) return;
    const translate = actor.getArray("Translate") orelse return;
    if (translate.items.items.len != 3) return;
    const height = translate.items.items[1].asFloat() orelse return;
    translate.items.items[1] = .{ .float = @floatCast(height + lift) };
    cloner.heights_moved += 1;
    if (@abs(lift) > @abs(cloner.largest_height_move)) cloner.largest_height_move = lift;
    _ = a;
}

/// `data` compressed with `dictionary`: through the file cache when there is one (the bytes are the same).
fn compressFile(allocator: Allocator, world: *World, cache: ?*filecache.FileCache, data: []const u8, dictionary: ?[]const u8) zstd.ZstdError![]u8 {
    if (cache) |c| return c.compress(allocator, &world.zs, data, dictionary);
    return world.zs.compress(allocator, data, dictionary);
}

/// Writes every changed file (compressed again with its dictionary) and the grown size table.
///
/// The files are compressed first, on several threads (compressor.zig; `gpa` must be thread-safe), then written one
/// by one in path order on this thread, with the size table updated as before. Compressing is most of a seed's time
/// and each file is compressed on its own, so the mod comes out the same as on one thread.
fn writeFiles(gpa: Allocator, a: Allocator, world: *World, patches: *patchset.PatchSet, restbl: *restbl_mod.Restbl, rt_rel: []const u8, rt_dictionary: ?[]const u8, out_romfs: []const u8, cache: ?*filecache.FileCache, progress: *Progress) WriteError![][]const u8 {
    var written: std.ArrayList([]const u8) = .empty;
    const s = patches.allocator;
    const paths = try patches.sortedPaths(a);

    // one job per compressed file, in path order (job_of[i]: the job of paths[i], or null for a file written as it is)
    var jobs: std.ArrayList(compressor.Job) = .empty;
    const job_of = a.alloc(?usize, paths.len) catch return error.OutOfMemory;
    for (paths, 0..) |rel, i| {
        const p = patches.current.get(rel).?;
        job_of[i] = null;
        if (!p.compressed) continue;
        job_of[i] = jobs.items.len;
        jobs.append(a, compressor.Job{ .data = p.data, .dictionary = p.dictionary }) catch return error.OutOfMemory;
    }
    // the compressed bytes are on `gpa`: each is freed once written, the rest here if writing stops early
    defer for (jobs.items) |j| if (j.out) |bytes| gpa.free(bytes);
    compressor.Compressor.run(gpa, &world.zs, cache, jobs.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return progress.fail(error.WriteFailed, "the mod's files could not be compressed ({s})", .{@errorName(err)}),
    };

    for (paths, 0..) |rel, i| {
        defer patches.endStep();
        const p = patches.current.get(rel).?;
        var bytes_out: []const u8 = p.data;
        if (job_of[i]) |k| {
            const job = &jobs.items[k];
            if (job.failure) |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return progress.fail(error.WriteFailed, "{s} could not be compressed", .{rel}),
            };
            bytes_out = job.out.?;
        }
        try writeOne(s, world, out_romfs, rel, bytes_out, progress);
        if (job_of[i]) |k| {
            gpa.free(jobs.items[k].out.?);
            jobs.items[k].out = null;
        }
        const key = if (std.mem.endsWith(u8, rel, ".zs")) rel[0 .. rel.len - 3] else rel;
        if (restbl.get(key)) |old| {
            const before = patches.original_len.get(rel).?;
            if (p.data.len > before) restbl.set(key, old + @as(u32, @intCast(p.data.len - before))) catch return error.OutOfMemory;
        }
        written.append(a, rel) catch return error.OutOfMemory;
    }
    defer patches.endStep();
    const table = restbl.serialize(s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData => return progress.fail(error.WriteFailed, "the size table could not be written", .{}),
    };
    const packed_table = compressFile(s, world, cache, table, rt_dictionary) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return progress.fail(error.WriteFailed, "the size table could not be compressed", .{}),
    };
    try writeOne(s, world, out_romfs, rt_rel, packed_table, progress);
    written.append(a, rt_rel) catch return error.OutOfMemory;
    return written.items;
}

fn writeOne(a: Allocator, world: *World, out_romfs: []const u8, rel: []const u8, data: []const u8, progress: *Progress) WriteError!void {
    var parts: std.ArrayList([]const u8) = .empty;
    parts.append(a, out_romfs) catch return error.OutOfMemory;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| parts.append(a, part) catch return error.OutOfMemory;
    const path = fsmod.join(a, parts.items) catch return error.OutOfMemory;
    world.fs.makePath(fsmod.dirname(path)) catch |err| return progress.fail(error.WriteFailed, "couldn't create the folder for {s} ({s})", .{ path, @errorName(err) });
    world.fs.writeAll(path, data) catch |err| return progress.fail(error.WriteFailed, "couldn't write {s} ({s})", .{ path, @errorName(err) });
}

/// The actor a chest drops for item key `key`. An item not drawn held up out of a chest gets a display actor of its
/// own (pickups.chestDisplayActor): an Ocarina (only in a chest with Shuffle Ocarinas; the check names the setting it
/// belongs to), or a song with Songs Anywhere (the harp, turning: pickups.songChestActor).
fn chestShownActorOf(a: Allocator, world: *World, plan: *fill.Plan, cloner: *pickups.PickupCloner, key: []const u8, progress: *Progress) PatchError![]const u8 {
    const chest_actor = (try world.actorFor(a, key, .chest)) orelse
        return progress.fail(error.NotAsExpected, "no actor for item {s} in chest context", .{key});
    if (std.mem.startsWith(u8, chest_actor, "Pouch_") and plan.st.flag(.shuffle_ocarinas)) {
        return (try cloner.chestDisplayActor(chest_actor["Pouch_".len..])) orelse chest_actor;
    }
    if (std.mem.startsWith(u8, chest_actor, "Item_Melody_") and plan.st.is(.shuffle_songs, "anywhere")) {
        return (try cloner.songChestActor(chest_actor)) orelse chest_actor;
    }
    return chest_actor;
}

/// The actor each tier of a progressive hand-over is given as, lowest first. A hand-over call creates the actor in
/// Link's hands: an Ocarina there gets the display actor chests use (issue #5: the worn Item_Ocarina_* actor crashed
/// the game when held up); a silent pouch add keeps the Item_ actor.
fn progressiveTierActors(a: Allocator, world: *World, cloner: *pickups.PickupCloner, hand_over: ProgressiveHandOver, progress: *Progress) PatchError![]const []const u8 {
    const tiers = hand_over.chain.tiers;
    const actors = a.alloc([]const u8, tiers.len) catch return error.OutOfMemory;
    for (tiers, 0..) |tier, t| {
        const event_actor = (try world.actorFor(a, tier.key, .event)) orelse
            return progress.fail(error.NotAsExpected, "no actor for {s} (a tier of {s})", .{ tier.key, hand_over.chain.display_name });
        actors[t] = event_actor;
        if (hand_over.held_up) {
            if (World.wornEquipmentBase(tier.key)) |worn_base| actors[t] = (try cloner.chestDisplayActor(worn_base)) orelse event_actor;
        }
    }
    return actors;
}
