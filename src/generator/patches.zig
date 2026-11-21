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
const door = @import("door.zig");
const pickups = @import("pickups.zig");
const flows = @import("flows.zig");
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
/// normal chest event instead, and so does the vanilla sword chest with Skip Story Scenes.
const item_get_events = [_][]const u8{"Get_StoneOfForest_GetSword"};

const StageEdit = struct {
    hash: u64,
    loc: usize,
    item: ItemId,
};

const EventEdit = struct {
    offset: usize,
    value: union(enum) { actor: []const u8, price: i64 },
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

    // Skip Story Scenes: the Kokiri Sword chest uses the normal chest opening even with the sword in it; its sword scene
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
            for (loc.event_refs) |r| try appendTo(EventEdit, &event_edits, a, r.rel, .{ .offset = r.offset, .value = .{ .actor = actor } });
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
        }
        if (hits != edits.len) return progress.fail(error.NotAsExpected, "{s}: expected {d} actors, patched {d}", .{ rel, edits.len, hits });
        try patches.emitZs(rel, orig, try byml.dumpDefault(s, .{ .dict = root }));
        patches.endStep();
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

    // Business Scrubs: the price of each shuffled scrub's purchase calls
    for (plan.shuffled.items) |i| {
        const price = plan.scrub_prices[i] orelse continue;
        for (locs[i].price_refs) |r| try appendTo(EventEdit, &event_edits, a, r.rel, .{ .offset = r.offset, .value = .{ .price = price } });
    }
    for (try sortedKeys(std.ArrayList(EventEdit), a, &event_edits)) |rel| {
        const orig = try patches.read(rel);
        var v = evfl_view.View.init(s, orig.data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidData => return progress.fail(error.NotAsExpected, "{s} is not a readable event flow", .{rel}),
        };
        for (event_edits.get(rel).?.items) |e| {
            switch (e.value) {
                .price => |p| v.setIntParam(e.offset, @intCast(p)),
                .actor => |actor| try v.setStringParam(e.offset, actor),
            }
        }
        v.check(s) catch return progress.fail(error.NotAsExpected, "{s}: the patched flow doesn't parse", .{rel});
        try patches.emitZs(rel, orig, v.bytesView()); // emit keeps its own copy
        patches.endStep();
    }

    if (inputs.hint_list.len > 0) {
        try hints.writeText(world, &patches, inputs.hint_list, progress);
        patches.endStep();
    }

    // Business Scrubs: a sale line of its own for each shuffled scrub, naming the item it sells
    var scrubs: std.ArrayList(textpatches.Scrub) = .empty;
    for (plan.shuffled.items) |i| {
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
        kind: enum { stones_without_mask, opening_without_movie, start_outside, memory_game, bridge_guard, deku_meeting, quick_chest, epona },
    };
    var flow_edits: std.ArrayList(FlowEdit) = .empty;
    if (st.is(.gossip_stones, "no_mask")) flow_edits.append(a, .{ .what = "Gossip Stones: No Mask of Truth", .rel = hints.gossip_flow, .kind = .stones_without_mask }) catch return error.OutOfMemory;
    if (st.flag(.skip_opening)) flow_edits.append(a, .{ .what = "Skip Opening Movie", .rel = faststart.opening_flow, .kind = .opening_without_movie }) catch return error.OutOfMemory;
    // every seed: a new game starts outside the Kokiri Shop, without Navi's flight and wake-up scene
    flow_edits.append(a, .{ .what = "New game start", .rel = faststart.opening_flow, .kind = .start_outside }) catch return error.OutOfMemory;
    // every seed: the Lost Woods ocarina game gives its three rewards for one won song
    flow_edits.append(a, .{ .what = "Lost Woods ocarina game", .rel = qol.memory_game_flow, .kind = .memory_game }) catch return error.OutOfMemory;
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

    if (st.flag(.skip_story_scenes)) {
        // after the item edits: a skipped scene's item (read from the patched scene) is the randomized one
        try storyskip.patchStoryScenes(world, &patches, progress, &storyskip.skips, "Skip Story Scenes", false);
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
    for (start_ids.items) |i| {
        const item = placed[i] orelse plan.fixed[i] orelse continue;
        const actor = try requireActor(a, world, item, .event, progress);
        if (flows.contains(&faststart.start_by_event, actor)) {
            start_by_event.append(a, actor) catch return error.OutOfMemory;
        } else if (plan.grantable(item) catch |err| return mapFill(err)) {
            start_items.append(a, actor) catch return error.OutOfMemory;
        } else {
            start_gifts.append(a, actor) catch return error.OutOfMemory;
        }
    }
    // the shelves' computed flags, each once, sorted
    std.mem.sort(gamedata.ShopPresence, shop_presences.items, {}, lessPresence);
    var unique: std.ArrayList(gamedata.ShopPresence) = .empty;
    for (shop_presences.items) |p| {
        if (unique.items.len > 0 and presenceEql(unique.items[unique.items.len - 1], p)) continue;
        unique.append(a, p) catch return error.OutOfMemory;
    }
    const gd_ok = gamedata.apply(s, world, &patches, st, progress, bridge_ok, start_items.items, unique.items) catch |err| switch (err) {
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
    if (st.flag(.dodongo_bag_bombs) and !try qol.patchDodongoBagBombs(world, &patches, progress)) {
        // the logic already counted bag bombs for the entrance, so the seed would not be safe
        return progress.fail(error.SettingFailed, "Dodongo's Cavern boulder logic not recognised in this romfs; turn off 'Bag Bombs Open Dodongo's Cavern'", .{});
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

    return writeFiles(a, world, &patches, &restbl, rt_rel, rt_dictionary, inputs.out_romfs, progress);
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
                    // the chest's own event hands out its vanilla item again (unsaved), so drop it; with Skip Story Scenes
                    // the vanilla sword also comes from the normal chest opening
                    _ = dyn.remove("GetEventName");
                }
            }
            if (fill.progressiveUpgrade(name)) |up| {
                if (world.actorExists(up.bigger) and world.actorExists(up.biggest)) {
                    try dyn.put(a, "Drop__DropActor", .{ .string = up.bigger });
                    try dyn.put(a, "Drop__CheckActor", .{ .string = up.bigger });
                    try dyn.put(a, "Drop__DropActor_Substitute", .{ .string = up.biggest });
                    return;
                }
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
            try dyn.put(a, "Drop__DropActor", .{ .string = try requireActor(a, world, item, .chest, progress) });
            _ = dyn.remove("Drop__CheckActor");
            _ = dyn.remove("Drop__DropActor_Substitute");
        },
        .shop => {
            // a new shelf actor that sells the item once, at its price (pickups.zig, OotrR)
            const event_actor = try requireActor(a, world, item, .event, progress);
            try actor.put(a, "Gyaml", .{ .string = try cloner.shopActor(event_actor, plan.shop_prices[edit.loc].?) });
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
            try actor.put(a, "Gyaml", .{ .string = try cloner.worldActor(world_actor, item != loc.vanilla) });
        },
    }
}

/// Writes every changed file (compressed again with its dictionary) and the grown size table.
fn writeFiles(a: Allocator, world: *World, patches: *patchset.PatchSet, restbl: *restbl_mod.Restbl, rt_rel: []const u8, rt_dictionary: ?[]const u8, out_romfs: []const u8, progress: *Progress) WriteError![][]const u8 {
    var written: std.ArrayList([]const u8) = .empty;
    // each file's compressed bytes are written and then freed: they are never all in memory at once
    const s = patches.allocator;
    for (try patches.sortedPaths(a)) |rel| {
        defer patches.endStep();
        const p = patches.current.get(rel).?;
        const bytes_out = if (p.compressed) world.zs.compress(s, p.data, p.dictionary) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return progress.fail(error.WriteFailed, "{s} could not be compressed", .{rel}),
        } else p.data;
        try writeOne(s, world, out_romfs, rel, bytes_out, progress);
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
    const packed_table = world.zs.compress(s, table, rt_dictionary) catch |err| switch (err) {
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
