//! Quality-of-life patches that are not tied to item placement.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const sarc = @import("../formats/sarc.zig");
const restbl = @import("../formats/restbl.zig");
const pickups = @import("pickups.zig");
const evfl = @import("../formats/evfl.zig");
const evfl_view = @import("../formats/evfl_view.zig");
const ainb = @import("../formats/ainb.zig");
const bytes = @import("../core/bytes.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const gamedata = @import("gamedata.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const PatchSet = patchset.PatchSet;
const World = world_mod.World;
const Container = evfl.Container;
const NONE = evfl.NONE;

fn view(allocator: Allocator, data: []const u8, rel: []const u8, progress: *Progress) PatchError!evfl_view.View {
    return evfl_view.View.init(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidData => progress.fail(error.NotAsExpected, "{s} is not a readable event flow", .{rel}),
    };
}

/// Emits a view-patched flow after checking it still parses.
fn emitView(patches: *PatchSet, rel: []const u8, original: patchset.Latest, v: *const evfl_view.View, progress: *Progress) PatchError!void {
    v.check(patches.allocator) catch return progress.fail(error.NotAsExpected, "{s}: the patched flow doesn't parse", .{rel});
    const out = patches.allocator.dupe(u8, v.bytesView()) catch return error.OutOfMemory;
    try patches.emitZs(rel, original, out);
}

// --- Anju's cucco minigame -------------------------------------------------------------
// The fence count is compared against a constant 7 in the minigame's logic module (compare node: Int_A = 7, Int_B =
// live fence count). Anju's event flow also keeps a "cuccos remaining" counter that starts at 7 and is compared with
// 7 for her dialogue.
const anju_ainb = "Logic/MiniGame_CatchCucco_c69b.logic.module.ainb";
const anju_flow = "Event/EventFlow/Minigame_CatchCucco.bfevfl.zs";
const anju_flow_110 = "Event/EventFlow/Minigame_CatchCucco.110.bfevfl.zs";
const anju_counter = "Npc_Hylia_049_Child_HowManyCuccos";

pub fn patchAnju(world: *World, patches: *PatchSet, progress: *Progress, cuccos: i32) PatchError!void {
    const a = patches.allocator;
    if (!world.files.exists(anju_ainb)) {
        progress.log("warning: Anju minigame logic not found; skipped", .{});
        return;
    }
    const orig = try patches.read(anju_ainb);
    const hits = try ainb.constOffsets(a, orig.data, "Int_A", 7);
    if (hits.len != 1) {
        progress.log("warning: Anju minigame check not recognised ({d} matches); skipped", .{hits.len});
        return;
    }
    const new = a.dupe(u8, orig.data) catch return error.OutOfMemory;
    bytes.putI32(new, hits[0], cuccos);
    try patches.emit(anju_ainb, orig.data, new, null, false);

    for ([_][]const u8{ anju_flow, anju_flow_110 }) |rel| {
        if (!world.files.exists(rel)) continue;
        const data = try patches.read(rel);
        var v = try view(a, data.data, rel, progress);
        var n: usize = 0;
        for (v.flowcharts) |fc| {
            for (fc.events) |*e| {
                const p = e.params orelse continue;
                if (!p.isString("GameDataName", anju_counter) or (p.getInt("Value") orelse -1) != 7) continue;
                const is_set = std.mem.eql(u8, e.action orelse "", "EventTriggerSetGameDataInt");
                const is_query = std.mem.eql(u8, e.query orelse "", "EventQueryIsGameDataInt");
                if (!is_set and !is_query) continue;
                const off = p.intOffset("Value") orelse continue;
                v.setIntParam(off, cuccos);
                n += 1;
            }
        }
        if (n > 0) try emitView(patches, rel, data, &v, progress);
    }
}

// --- Saria's Song ------------------------------------------------------------------------
// Two child-meadow logic modules start the song scene (and move Saria for it) only when DoorOfTime_IsAfter_Step01_Exp
// (met Zelda) is true; they are re-pointed to "owns an ocarina".
const saria_ainbs = [_][]const u8{
    "Logic/SacredForestMeadow_Child_Prefab_3265.logic.module.ainb",
    "Logic/SacredForestMeadow_Child_Prefab_bbc3.logic.module.ainb",
};

pub fn patchSariaSong(world: *World, patches: *PatchSet, progress: *Progress, old_flag: []const u8, new_flag: []const u8) PatchError!void {
    for (saria_ainbs) |rel| {
        if (!world.files.exists(rel)) {
            progress.log("warning: {s} not found; Saria's Song still needs Zelda", .{rel});
            continue;
        }
        const orig = try patches.read(rel);
        const r = try ainb.repointStringConst(patches.allocator, orig.data, "GameDataNameBoolExp", old_flag, new_flag);
        if (r.count != 1) {
            progress.log("warning: Saria's Song check in {s} not recognised ({d} matches); skipped", .{ rel, r.count });
            continue;
        }
        try patches.emit(rel, orig.data, r.data, null, false);
    }
}

// --- Dodongo's Cavern boulder and bag bombs ------------------------------------------------------
// Read with the decrypted dump (Pack/Actor/*.pack.txt, Logic/DeathMountainTrail_Child_Prefab_ffa7.ainb.txt):
// - The boulder (Obj_DeathMtTrail_BrokenRock_A_01) is a cracked rock without a life: it has the cracked rocks'
//   attack target shape ("Tgt"), death procedure (CrackObjectCommon) and fracture, but explosions don't hurt it. Only
//   its cutscene (Dm_DeathMtTrail_0010, started by the bomb flower's fruit) breaks it, with EventTriggerRequestDeath.
// - Every bombable rock in the game is a child of WallCrack: its ActorParam's "$parent" is
//   Work/Actor/WallCrack.engine__actor__ActorParam.gyml, it overrides a few components (Obj_Goron_BrokenRock_A_01:
//   model, physics, destruction and links only) and inherits the rest, among them the life (LifeParam WallCrack:
//   MaxLife 6, hurt only by bomb-type and hammer attacks), the blackboard, the drops and the perception emitter. Its
//   pack holds the WallCrack files those use, and WallCrack's ActorParam itself.
// Patch: the boulder becomes a WallCrack child the same way. Its ActorParam gets that "$parent" (every component it
// has stays its own; it inherits only the ones it lacks), and every file of the WallCrack pack its pack lacks is
// copied in unchanged. A bag bomb's explosion then breaks it like any cracked rock, when it explodes. The boulder's
// own logic (node 7, ActorLogicDeathProcComplete, Dead -> nodes 12, 11, 8) moves Get_StoneOfFire to DungeonStart,
// as after the cutscene, and its NoRespawn save flag keeps it broken. The bomb flower's cutscene is unchanged: it
// switches the boulder's death during events off first and breaks it itself.
//
// History (0.7.4): a graph patch first removed the boulder as soon as a bag bomb was next to it, before the bomb
// went off. Then the boulder got only WallCrack's LifeRef and GameParameterTableRef: the game crashed creating it
// when Death Mountain Trail loaded (Longshot: an access violation in BaseProcCreateAndDeleteThread), as the life
// needs the components it comes with. Before 0.7.4, a bag bomb started the bomb flower's cutscene, which softlocked.
const dodongo_boulder = "Obj_DeathMtTrail_BrokenRock_A_01";
const dodongo_boulder_pack = "Pack/Actor/Obj_DeathMtTrail_BrokenRock_A_01.pack.zs";
const dodongo_boulder_param = "Actor/Obj_DeathMtTrail_BrokenRock_A_01.engine__actor__ActorParam.bgyml";
const bombable_rock_pack = "Pack/Actor/WallCrack.pack.zs";
const bombable_rock_param = "Actor/WallCrack.engine__actor__ActorParam.bgyml";
const bombable_rock_parent = "Work/Actor/WallCrack.engine__actor__ActorParam.gyml";

fn findInPack(allocator: Allocator, pack: []const u8, name: []const u8) PatchError!?[]const u8 {
    const entry = sarc.find(allocator, pack, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return if (entry) |e| e.data else null;
}

pub fn patchDodongoBagBombs(world: *World, patches: *PatchSet, resource_sizes: *restbl.Restbl, progress: *Progress) PatchError!bool {
    if (!world.files.exists(dodongo_boulder_pack) or !world.files.exists(bombable_rock_pack)) {
        progress.log("warning: Dodongo's Cavern boulder or the cracked-rock actor not found; bag bombs still can't open it", .{});
        return false;
    }
    const a = patches.allocator;
    const boulder_raw = try patches.read(dodongo_boulder_pack);
    const rock_raw = try patches.read(bombable_rock_pack);

    const param_bytes = (try findInPack(a, boulder_raw.data, dodongo_boulder_param)) orelse {
        progress.log("warning: {s} has no ActorParam; bag-bomb patch skipped", .{dodongo_boulder});
        return false;
    };
    const param = try byml.loadDict(a, param_bytes);
    const components = param.getDict("Components") orelse {
        progress.log("warning: {s}'s ActorParam has no Components; bag-bomb patch skipped", .{dodongo_boulder});
        return false;
    };
    // why: only the boulder as the dump shows it: a cracked rock's death, no parent and no life of its own
    const death = components.getString("DeathRef") orelse "";
    const is_expected_boulder = std.mem.indexOf(u8, death, "CrackObjectCommon") != null and
        !param.contains("$parent") and !components.contains("LifeRef");
    if (!is_expected_boulder) {
        progress.log("warning: {s} isn't as expected (no cracked-rock death, or a parent or life already); bag-bomb patch skipped", .{dodongo_boulder});
        return false;
    }
    if (try findInPack(a, rock_raw.data, bombable_rock_param) == null) {
        progress.log("warning: the cracked-rock pack has no {s}; bag-bomb patch skipped", .{bombable_rock_param});
        return false;
    }
    try param.put(a, "$parent", .{ .string = bombable_rock_parent });
    const version = if (param_bytes.len >= 4) std.mem.readInt(u16, param_bytes[2..4], if (param_bytes[0] == 'B') .big else .little) else 7;
    const new_param = try byml.dump(a, .{ .dict = param }, version, false);

    // every WallCrack file the boulder's pack lacks (what its inherited components read, and the parent itself)
    const rock_files = sarc.list(a, rock_raw.data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    var added: std.ArrayList(sarc.NewFile) = .empty;
    for (rock_files.items) |file| {
        if (try findInPack(a, boulder_raw.data, file.name) != null) continue;
        added.append(a, .{ .name = file.name, .data = file.data }) catch return error.OutOfMemory;
    }
    const new_pack = sarc.rebuild(a, boulder_raw.data, &.{.{ .name = dodongo_boulder_param, .data = new_param }}, added.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    try patches.emitZs(dodongo_boulder_pack, boulder_raw, new_pack);

    // why: a WallCrack child needs WallCrack's memory (its ActorInfo InstanceHeapSize: 130,080 bytes, the Goron City
    // rocks 114,624; the boulder had 97,640). Without it the game overran the boulder's memory creating it, a crash
    // loading Death Mountain Trail (an access violation in BaseProcCreateAndDeleteThread)
    if (!try pickups.raiseActorMemoryToFit(world, patches, dodongo_boulder, "WallCrack")) {
        progress.log("warning: no ActorInfo row for {s} or WallCrack; bag-bomb patch skipped", .{dodongo_boulder});
        return false;
    }

    // the resource size table lists files inside packs too: the bigger ActorParam needs a bigger entry (the copied
    // files are the WallCrack pack's own, already listed with their sizes)
    if (resource_sizes.get(dodongo_boulder_param)) |listed_size| {
        if (new_param.len > param_bytes.len) {
            const grown = listed_size + @as(u32, @intCast(new_param.len - param_bytes.len));
            resource_sizes.set(dodongo_boulder_param, grown) catch return error.OutOfMemory;
        }
    }
    return true;
}

// --- Songs: the teaching sub-flow also hands out the vanilla song -------------------------------
// Dm_SY_Ocarina's LearningOcarinaPlayAuto / ...ForSeek entries add the song being taught (by MelodyType) with
// EventTriggerAddOrRemovePouchContent, on top of each song event's own give node. With songs shuffled, those adds are
// set to 0 so a song location only gives its randomized item.
const song_teach_flow = "Event/EventFlow/Dm_SY_Ocarina.bfevfl.zs";
const song_teach_flow_110 = "Event/EventFlow/Dm_SY_Ocarina.110.bfevfl.zs";
const taught_songs = [_][]const u8{
    "Item_Melody_ZeldaLullaby",   "Item_Melody_EponaSong",     "Item_Melody_SariaSong",     "Item_Melody_SunSong",
    "Item_Melody_TimeSong",       "Item_Melody_StormSong",     "Item_Melody_ForestMinuet",  "Item_Melody_FireBolero",
    "Item_Melody_WaterSerenade",  "Item_Melody_SpiritRequiem", "Item_Melody_ShadowNocturne", "Item_Melody_LightPrelude",
};

pub fn patchSongTeaching(world: *World, patches: *PatchSet, progress: *Progress) PatchError!void {
    var n: usize = 0;
    for ([_][]const u8{ song_teach_flow, song_teach_flow_110 }) |rel| {
        if (!world.files.exists(rel)) continue;
        const data = try patches.read(rel);
        var v = try view(patches.allocator, data.data, rel, progress);
        for (v.flowcharts) |fc| {
            for (fc.events) |*e| {
                const p = e.params orelse continue;
                if (!std.mem.eql(u8, e.action orelse "", "EventTriggerAddOrRemovePouchContent")) continue;
                const actor = p.getString("Actor") orelse continue;
                if (!flows.contains(&taught_songs, actor) or (p.getInt("Num") orelse -1) != 1) continue;
                const off = p.intOffset("Num") orelse continue;
                if (!e.reachedFrom("LearningOcarina")) continue;
                v.setIntParam(off, 0);
                n += 1;
            }
        }
        // (as in the Python version, the count is shared by both files)
        if (n > 0) try emitView(patches, rel, data, &v, progress);
    }
    if (n < taught_songs.len) {
        progress.log("warning: only {d} of {d} song-teaching gifts found; some songs may also be given vanilla", .{ n, taught_songs.len });
    }
}

// --- Open Zora's Fountain: the first arrival keeps King Zora moved -------------------------------
// Open Zora starts the Zora quest at Step07 (gamedata.zora_open_quest_step). But the first arrival in Zora's Domain
// (Dm_SY_BancChangeArrive:Goto_ZoraDomain) sets the quest to Step03 (Step03_Impa if Impa told you about it), and
// ProgressChallengeStep also moves backwards: King Zora was back in front of Jabu-Jabu's door after leaving the
// dungeon (0.4.3 report), a softlock. Those two steps become Step07.
const zora_arrive_flow = "Event/EventFlow/Dm_SY_BancChangeArrive.bfevfl.zs";
const zora_arrive_entry = "Goto_ZoraDomain";
const zora_arrive_steps = [_][]const u8{ "Step03", "Step03_Impa" };

pub fn patchOpenZoraArrival(patches: *PatchSet, progress: *Progress, step: []const u8) PatchError!bool {
    const data = try patches.read(zora_arrive_flow);
    var v = try view(patches.allocator, data.data, zora_arrive_flow, progress);
    var offsets: std.ArrayList(usize) = .empty;
    for (v.flowcharts) |fc| {
        for (fc.events) |*e| {
            if (!std.mem.eql(u8, e.action orelse "", "EventExecuteProgressChallengeStep")) continue;
            if (!e.reachedFromExactly(zora_arrive_entry)) continue;
            const p = e.params orelse continue;
            if (!p.isString("ChallengeName", "Get_StoneOfWater")) continue;
            const s = p.getString("StepName") orelse continue;
            if (!flows.contains(&zora_arrive_steps, s)) continue;
            offsets.append(patches.allocator, p.stringOffset("StepName").?) catch return error.OutOfMemory;
        }
    }
    if (offsets.items.len != zora_arrive_steps.len) {
        progress.log("warning: Zora's Domain arrival not recognised ({d} matches); King Zora may move back in front of Jabu-Jabu", .{offsets.items.len});
        return false;
    }
    for (offsets.items) |off| try v.setStringParam(off, step);
    try emitView(patches, zora_arrive_flow, data, &v, progress);
    return true;
}

// --- Open forest: Mido has already let you pass -------------------------------------------------
// Clearing Mido's blocker flag only removes his invisible wall. Where he stands comes from his AI schedule: he guards
// the path until Meet_DekuTree reaches Step02, which his own flow does after the sword-and-shield check (then
// Step03). The opening cutscene starts that quest at Step01; with Open forest it starts it at Step03 instead, the
// state right after Mido steps aside. The Deku Tree scene (Dm_Kokiri_0075) still completes it.
const opening_flow = "Event/EventFlow/OpeningEvent.bfevfl.zs";

pub fn patchOpenForestMido(patches: *PatchSet, progress: *Progress) PatchError!bool {
    const data = try patches.read(opening_flow);
    var v = try view(patches.allocator, data.data, opening_flow, progress);
    var hit: ?usize = null;
    var count: usize = 0;
    for (v.flowcharts) |fc| {
        for (fc.events) |*e| {
            if (!std.mem.eql(u8, e.action orelse "", "EventExecuteProgressChallengeStep")) continue;
            const p = e.params orelse continue;
            if (p.isString("ChallengeName", "Meet_DekuTree") and p.isString("StepName", "Step01")) {
                hit = p.stringOffset("StepName");
                count += 1;
            }
        }
    }
    if (count != 1) {
        progress.log("warning: opening quest step not recognised ({d} matches); Mido may still block the Deku Tree", .{count});
        return false;
    }
    try v.setStringParam(hit.?, "Step03");
    try emitView(patches, opening_flow, data, &v, progress);
    return true;
}

// --- Shuffle Ocarinas: no goodbye on the forest bridge ---------------------------------------------
// Saria's goodbye (which gives the Fairy Ocarina) is requested by the bridge area trigger only while Dm_Kokiri_0150
// hasn't been played. That check now reads Dm_Kokiri_0045 instead, the greeting outside Link's house that always
// plays first, so the trigger never fires. (Marking 0150 as seen also made Saria's schedule treat her as gone.)
const ocarina_bridge_ainb = "Logic/KokiriForest_Child_Level_All_02_ddcd.logic.module.ainb";

pub fn patchOcarinaBridge(world: *World, patches: *PatchSet, progress: *Progress) PatchError!bool {
    if (!world.files.exists(ocarina_bridge_ainb)) return false;
    const orig = try patches.read(ocarina_bridge_ainb);
    const r = try ainb.repointStringConst(patches.allocator, orig.data, "EventName", "Dm_Kokiri_0150", "Dm_Kokiri_0045");
    if (r.count != 1) {
        progress.log("note: forest bridge trigger not recognised ({d} matches); marking Saria's goodbye as seen instead", .{r.count});
        return false;
    }
    try patches.emit(ocarina_bridge_ainb, orig.data, r.data, null, false);
    return true;
}

// --- Weird Egg: only hatch when you have it -----------------------------------------------------
// Goto_HyruleCastle "Step03_01_Npc_Navi_StepStart" (query 129) always runs :EggHatch, which removes the egg and gives
// the Wake-Up Cucco. The flow's unreachable pouch query (event 41, "IsExistInPouch Item_AlarmCucco") is re-used as
// "has the Weird Egg?": yes -> the normal hatch (35), no -> skip the hatch but still advance the quest step (38).
const egg_flow = "Event/EventFlow/Goto_HyruleCastle.bfevfl.zs";

pub fn patchEggHatchGuard(patches: *PatchSet, progress: *Progress) PatchError!void {
    const data = try patches.read(egg_flow);
    var v = try view(patches.allocator, data.data, egg_flow, progress);
    const ok = blk: {
        if (v.flowcharts.len == 0) break :blk false;
        const evs = v.flowcharts[0].events;
        if (evs.len <= 129) break :blk false;
        const q = &evs[41];
        const sel = &evs[129];
        const hatch = &evs[35];
        const step = &evs[38];
        const qp = q.params orelse break :blk false;
        if (!std.mem.eql(u8, q.query orelse "", "EventQueryIsExistInPouch") or !qp.isString("Actor", "Item_AlarmCucco")) break :blk false;
        if (q.entry_points.items.len != 0) break :blk false;
        if (!std.mem.eql(u8, sel.query orelse "", "EventQueryPlayerCheckSelectedItem")) break :blk false;
        if (!std.mem.eql(u8, hatch.entry orelse "", "EggHatch")) break :blk false;
        if (!std.mem.eql(u8, step.action orelse "", "EventExecuteProgressChallengeStep")) break :blk false;
        if (q.cases.len != 2) break :blk false;
        const v0 = @min(q.cases[0].value, q.cases[1].value);
        const v1 = @max(q.cases[0].value, q.cases[1].value);
        if (v0 != 0 or v1 != 1) break :blk false;
        // only unreachable events (leftover Malon dialogue) may point at it
        for (evs) |*e| {
            var points = e.next != null and e.next.? == 41;
            for (e.cases) |c| if (c.target == 41) {
                points = true;
            };
            if (points and e.entry_points.items.len > 0) break :blk false;
        }
        break :blk true;
    };
    if (!ok) {
        progress.log("warning: egg hatch event not recognised; the Cucco may hatch without the Weird Egg", .{});
        return;
    }
    const evs = v.flowcharts[0].events;
    try v.setStringParam(evs[41].params.?.stringOffset("Actor").?, "Item_WeirdEgg");
    try v.setCaseTargets(&evs[41], &.{ 0, 1 }, &.{ 38, 35 });
    var values: std.ArrayList(u32) = .empty;
    var targets: std.ArrayList(u32) = .empty;
    for (evs[129].cases) |c| {
        values.append(patches.allocator, c.value) catch return error.OutOfMemory;
        targets.append(patches.allocator, 41) catch return error.OutOfMemory;
    }
    try v.setCaseTargets(&evs[129], values.items, targets.items);
    try emitView(patches, egg_flow, data, &v, progress);
}

// --- Dungeon items in small chests -------------------------------------------------------------------------
// Only the big chest's opening credits a dungeon's map, compass or boss key. Dm_SY_Treasurebox's entry
// Success_AddContent asks EventQueryTreasureBoxIsDungeonCommonItemInside (by the item's actor name) what the chest
// holds: 0 map, 1 compass, 2 boss key, 3 small key, 4 anything else. For 0-2 it shows the item's get text, runs
// EventGetDungeonMap / Compass / BossKey and opens the pick-up window. Dm_SY_TreasureboxSmall's own item step only adds
// to the pouch: a boss key from a small chest left the boss door shut, a map or compass left the pause map blank.
//
// The same question and steps are added inside the small chest's flow, in front of its own "can it go in the pouch"
// check (EventQueryCanAddToPorch): maps, compasses and boss keys take the new steps; small keys and every other item
// go on exactly as before. Nothing calls into another flow file.
//
// NOTE: in the Python version (0.6.2, local) this step raised an AttributeError: the module defines _flow_targets
// twice with swapped arguments, so its _reach() failed. This port walks the flow as the code meant to.
const small_tbox_flow = "Event/EventFlow/Dm_SY_TreasureboxSmall.bfevfl.zs";
const big_tbox_flow = "Event/EventFlow/Dm_SY_Treasurebox.bfevfl.zs";
const small_tbox_entries = [_][]const u8{ "ItemDisplay", "ItemDisplayNoSpace" };
const big_tbox_entry = "Success_AddContent";
const dungeon_item_query = "EventQueryTreasureBoxIsDungeonCommonItemInside";
const dungeon_item_actions = [_][]const u8{ "EventGetDungeonMap", "EventGetDungeonCompass", "EventGetDungeonBossKey" };

const ChainStep = struct {
    actor: []const u8,
    action: []const u8,
    params: ?*Container,
};

const BigChestSteps = struct {
    query_params: ?*Container,
    text: evfl.SubFlowEvent,
    chains: [3][]ChainStep,
};

fn caseTarget(cases: []const evfl.Case, value: u32) ?u16 {
    var found: ?u16 = null;
    for (cases) |c| if (c.value == value) {
        found = c.event;
    };
    return found;
}

/// The question, the get-text call and the steps per case from the big chest's Success_AddContent.
fn bigChestSteps(allocator: Allocator, big: *evfl.Flowchart, progress: *Progress) PatchError!BigChestSteps {
    const entry = big.entryPoint(big_tbox_entry) orelse return progress.fail(error.NotAsExpected, "the big chest has no {s}", .{big_tbox_entry});
    const q1 = big.event(entry.main_event) orelse return progress.fail(error.NotAsExpected, "the big chest's item step is missing", .{});
    if (!std.mem.eql(u8, big.queryName(q1) orelse "", dungeon_item_query)) {
        return progress.fail(error.NotAsExpected, "the big chest's item step does not start with {s}", .{dungeon_item_query});
    }
    const text_i = caseTarget(q1.kind.switch_.cases.items, 0) orelse return progress.fail(error.NotAsExpected, "the big chest's dungeon item steps are not as expected", .{});
    const text = big.event(text_i) orelse return progress.fail(error.NotAsExpected, "the big chest's dungeon item steps are not as expected", .{});
    if (text.kind != .sub_flow) return progress.fail(error.NotAsExpected, "the big chest's dungeon item steps are not as expected", .{});
    const q2 = big.event(text.kind.sub_flow.next) orelse return progress.fail(error.NotAsExpected, "the big chest's dungeon item steps are not as expected", .{});
    if (!std.mem.eql(u8, big.queryName(q2) orelse "", dungeon_item_query)) return progress.fail(error.NotAsExpected, "the big chest's dungeon item steps are not as expected", .{});

    var out = BigChestSteps{ .query_params = try evfl.cloneParams(allocator, q1.kind.switch_.params), .text = text.kind.sub_flow, .chains = undefined };
    for (dungeon_item_actions, 0..) |action, case| {
        var steps: std.ArrayList(ChainStep) = .empty;
        var i: u16 = caseTarget(q2.kind.switch_.cases.items, @intCast(case)) orelse return progress.fail(error.NotAsExpected, "the {s} steps are not as expected", .{action});
        while (i < big.events.items.len) {
            const e = &big.events.items[i];
            if (e.kind != .action) return progress.fail(error.NotAsExpected, "unexpected step {s} after the {s}", .{ e.name, action });
            const actor = big.actors.items[e.kind.action.actor];
            steps.append(allocator, ChainStep{
                .actor = actor.name,
                .action = actor.actions.items[e.kind.action.action],
                .params = try evfl.cloneParams(allocator, e.kind.action.params),
            }) catch return error.OutOfMemory;
            i = e.kind.action.next;
        }
        if (steps.items.len == 0 or !std.mem.eql(u8, steps.items[0].action, action) or
            !std.mem.eql(u8, steps.items[steps.items.len - 1].action, "EventTriggerRequestOpenPickUpWindow"))
        {
            return progress.fail(error.NotAsExpected, "the {s} steps are not as expected", .{action});
        }
        out.chains[case] = steps.items;
    }
    return out;
}

const SmallChestResult = struct { data: []u8, checks: usize };

/// Dm_SY_TreasureboxSmall with the dungeon item steps added in front of its pouch check.
fn smallChestDungeonItems(allocator: Allocator, data: []const u8, big_data: []const u8, progress: *Progress) PatchError!SmallChestResult {
    var doc = try flows.readFlow(allocator, data, "Dm_SY_TreasureboxSmall", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no small chest flowchart", .{});
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoDungeonItem")) return progress.fail(error.NotAsExpected, "small chest flow already changed", .{});
    }
    const big_doc = try flows.readFlow(allocator, big_data, "Dm_SY_Treasurebox", progress);
    const big = big_doc.flowchart orelse return progress.fail(error.NotAsExpected, "no big chest flowchart", .{});
    const steps = try bigChestSteps(allocator, big, progress);

    const starter = fc.findActor("TreasureBox_EventStarter") orelse return progress.fail(error.NotAsExpected, "actor TreasureBox_EventStarter not in the small chest flow", .{});
    const query = (try fc.queryIndex(allocator, "TreasureBox_EventStarter", dungeon_item_query)).?[1];

    // the pouch checks the item steps reach
    var checks: std.ArrayList(u16) = .empty;
    for (small_tbox_entries) |name| {
        const ep = fc.entryPoint(name) orelse return progress.fail(error.NotAsExpected, "the small chest has no {s} entry", .{name});
        const reached = try fc.reach(allocator, ep.main_event);
        for (reached, 0..) |r, i| {
            if (!r) continue;
            const e = &fc.events.items[i];
            if (e.kind == .switch_ and std.mem.eql(u8, fc.queryName(e) orelse "", "EventQueryCanAddToPorch")) {
                if (std.mem.indexOfScalar(u16, checks.items, @intCast(i)) == null) checks.append(allocator, @intCast(i)) catch return error.OutOfMemory;
            }
        }
    }
    if (checks.items.len == 0) return progress.fail(error.NotAsExpected, "the small chest's pouch check was not found", .{});
    std.mem.sort(u16, checks.items, {}, std.sort.asc(u16));

    var added: std.ArrayList(u16) = .empty;
    var calls: std.ArrayList(u16) = .empty;
    for (checks.items, 0..) |check, n| {
        const q1_name = std.fmt.allocPrint(allocator, "RandoDungeonItem{d}_Is", .{n}) catch return error.OutOfMemory;
        const q1 = try fc.addEvent(allocator, .{ .name = q1_name, .kind = .{ .switch_ = .{ .actor = starter, .query = query, .params = try evfl.cloneParams(allocator, steps.query_params) } } });
        try added.append(allocator, q1);
        const say_name = std.fmt.allocPrint(allocator, "RandoDungeonItem{d}_Text", .{n}) catch return error.OutOfMemory;
        const say = try fc.addEvent(allocator, evfl.makeSubFlow(say_name, steps.text.flowchart, steps.text.entry_point, NONE, try evfl.cloneParams(allocator, steps.text.params)));
        try added.append(allocator, say);
        try calls.append(allocator, say);
        const q2_name = std.fmt.allocPrint(allocator, "RandoDungeonItem{d}_Which", .{n}) catch return error.OutOfMemory;
        const q2 = try fc.addEvent(allocator, .{ .name = q2_name, .kind = .{ .switch_ = .{ .actor = starter, .query = query, .params = try evfl.cloneParams(allocator, steps.query_params) } } });
        try added.append(allocator, q2);

        var firsts: [3]u16 = undefined;
        for (steps.chains, 0..) |chain, case| {
            var prev: ?u16 = null;
            for (chain, 0..) |s, k| {
                const aa = (try fc.actionIndex(allocator, s.actor, s.action)) orelse return progress.fail(error.NotAsExpected, "actor {s} not in the small chest flow", .{s.actor});
                const name = std.fmt.allocPrint(allocator, "RandoDungeonItem{d}_{d}_{d}", .{ n, case, k }) catch return error.OutOfMemory;
                const idx = try fc.addEvent(allocator, evfl.makeAction(name, aa, NONE, try evfl.cloneParams(allocator, s.params)));
                try added.append(allocator, idx);
                if (prev) |p| fc.events.items[p].kind.action.next = idx else firsts[case] = idx;
                prev = idx;
            }
        }
        try setCases(allocator, &fc.events.items[q1], &.{ .{ 0, say }, .{ 1, say }, .{ 2, say }, .{ 3, check }, .{ 4, check } });
        fc.events.items[say].kind.sub_flow.next = q2;
        try setCases(allocator, &fc.events.items[q2], &.{ .{ 0, firsts[0] }, .{ 1, firsts[1] }, .{ 2, firsts[2] }, .{ 3, check }, .{ 4, check } });

        // everything that led to the pouch check now asks the question first
        for (fc.events.items, 0..) |*e, i| {
            if (std.mem.indexOfScalar(u16, added.items, @intCast(i)) != null) continue;
            switch (e.kind) {
                .switch_ => |*s| for (s.cases.items) |*c| {
                    if (c.event == check) c.event = q1;
                },
                .sub_flow_switch => |*s| for (s.cases.items) |*c| {
                    if (c.event == check) c.event = q1;
                },
                .fork => |*f| {
                    for (f.forks.items) |*t| if (t.* == check) {
                        t.* = q1;
                    };
                    if (f.join == check) return progress.fail(error.NotAsExpected, "a join leads to the pouch check", .{});
                },
                .action => |*x| if (x.next == check) {
                    x.next = q1;
                },
                .join => |*x| if (x.next == check) {
                    x.next = q1;
                },
                .sub_flow => |*x| if (x.next == check) {
                    x.next = q1;
                },
                .return_ => {},
            }
        }
        for (fc.entry_points.items) |*ep| {
            if (ep.main_event == check) ep.main_event = q1;
        }
    }
    try flows.listReachedCalls(allocator, fc, calls.items);
    const out = try flows.writeBack(allocator, &doc, "Dm_SY_TreasureboxSmall", progress);
    return SmallChestResult{ .data = out, .checks = checks.items.len };
}

fn setCases(allocator: Allocator, e: *evfl.Event, pairs: []const [2]u16) PatchError!void {
    const cases = &e.kind.switch_.cases;
    cases.clearRetainingCapacity();
    for (pairs) |p| cases.append(allocator, .{ .value = p[0], .event = p[1] }) catch return error.OutOfMemory;
}

pub fn patchSmallChestDungeonItems(patches: *PatchSet, progress: *Progress) PatchError!usize {
    const orig = try patches.read(small_tbox_flow);
    const big = try patches.read(big_tbox_flow);
    const result = smallChestDungeonItems(patches.allocator, orig.data, big.data, progress) catch |err| switch (err) {
        error.NotAsExpected, error.InvalidData => {
            progress.log("warning: dungeon items in small chests stay uncredited ({s})", .{progress.failureMessage()});
            return 0;
        },
        else => return err,
    };
    try patches.emitZs(small_tbox_flow, orig, result.data);
    progress.log("Small chests: maps, compasses and boss keys now count for their dungeon ({d} item steps)", .{result.checks});
    return result.checks;
}

// --- Skip Child Zelda: the Kokiri stay where they are before the Hyrule Castle trip ---------------------------
// Every child Kokiri's AI schedule ends with a condition on Goto_HyruleCastle_IsCompleted_Exp: their spots after
// you've met Zelda. Skip Child Zelda completes that quest on a new save, so Mido walked off his post while his
// invisible wall stayed: the Deku Tree couldn't be reached (0.4.0 report). Dropping that condition keeps the Kokiri on
// their Deku Tree quest schedules.
const kokiri_schedules = "Component/AIScheduleParam";
const castle_done_exp = "Goto_HyruleCastle_IsCompleted_Exp";

pub fn patchKokiriSchedules(world: *World, patches: *PatchSet, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    const names = world.files.listDir(a, kokiri_schedules) catch return error.GameFiles;
    var n: usize = 0;
    var mido = false;
    for (names) |fname| {
        if (std.mem.startsWith(u8, fname, "Npc_Kokiri_Mido_Child")) mido = true;
        if (!std.mem.startsWith(u8, fname, "Npc_Kokiri_") or std.mem.indexOf(u8, fname, "_Child.") == null) continue;
        const rel = std.fmt.allocPrint(a, "{s}/{s}", .{ kokiri_schedules, fname }) catch return error.OutOfMemory;
        const orig = try patches.read(rel);
        const root = try byml.loadDict(a, orig.data);
        const conds = root.getArray("ConditionalSchedule") orelse continue;
        const keep = try byml.Array.create(a);
        for (conds.items.items) |c| {
            const flag = if (c.asDict()) |d| d.getString("ConditionFlag") orelse "" else "";
            if (!std.mem.eql(u8, flag, castle_done_exp)) try keep.append(a, c);
        }
        if (keep.len() != conds.len()) {
            try root.put(a, "ConditionalSchedule", .{ .array = keep });
            try patches.emit(rel, orig.data, try byml.dumpDefault(a, .{ .dict = root }), null, false);
            n += 1;
        }
    }
    if (!mido) progress.log("warning: Mido's schedule not found; he may leave his post with Skip Child Zelda", .{});
    progress.log("Skip Child Zelda: {d} Kokiri schedules keep their before-the-castle spots", .{n});
    return n;
}

// --- Big Poe buyer needs only 1 Big Poe ---------------------------------------------------------------------
// The adult Market ghost shop gives 100 points per Big Poe. His reward (the check, Event329's Bottle) comes with the
// sale that brings the points to 500: before each sale the flow compares GhostShop_CouponNum with 400, and "equal"
// leads to the reward sale (seven such checks, one per way into a sale and its messages). Comparing them with 0
// makes the first sale the reward sale. Why not the 900 check (0.7.5 and before): that is the later 1000-point
// step, which gives no item, so one sale gave nothing and he still asked for 500 points (EPONAPOE1).
const ghost_shop_flow = "Event/EventFlow/Npc_Hylia_048_BottleShop.bfevfl.zs";
const ghost_shop_reward_points_before_sale: i64 = 400;
const ghost_shop_reward_checks_expected: usize = 7;

pub fn patchBigPoeOne(patches: *PatchSet, progress: *Progress) PatchError!bool {
    const data = try patches.read(ghost_shop_flow);
    var v = try view(patches.allocator, data.data, ghost_shop_flow, progress);
    var hits: std.ArrayList(usize) = .empty;
    for (v.flowcharts) |fc| {
        for (fc.events) |*e| {
            if (!std.mem.eql(u8, e.query orelse "", "EventQueryIsGameDataInt")) continue;
            const p = e.params orelse continue;
            if (!p.isString("GameDataName", "GhostShop_CouponNum") or (p.getInt("Value") orelse -1) != ghost_shop_reward_points_before_sale) continue;
            const off = p.intOffset("Value") orelse continue;
            hits.append(patches.allocator, off) catch return error.OutOfMemory;
        }
    }
    if (hits.items.len != ghost_shop_reward_checks_expected) {
        progress.log("warning: Big Poe buyer's 400-point checks not as expected ({d} of {d}); he still wants five", .{ hits.items.len, ghost_shop_reward_checks_expected });
        return false;
    }
    for (hits.items) |off| v.setIntParam(off, 0);
    try emitView(patches, ghost_shop_flow, data, &v, progress);
    progress.log("Big Poe buyer: one Big Poe is enough for his reward", .{});
    return true;
}

// --- Gold Skulltulas day and night, any age ----------------------------------------------------------
// A night-only Gold Skulltula is an ordinary Enemy_Skulltula_Gold placement with Enemy_Skulltula_Gold_Nocturnal =
// true; without it the Skulltula is always there. Every night-only Skulltula is also in an AiGroup running
// Gimmick_Nighttime_Skulltula_Gold_Appear (it reads the time of day); those groups are dropped too. An adult-only one
// is placed only in the area's Adult stage file(s); a copy with the same instance hash (its save flag) in the area's
// Child_Static file is the same Skulltula for child Link. Copied only when the placement has no Links and the area
// has a child stage file.
const gs_nocturnal = "Enemy_Skulltula_Gold_Nocturnal";
const gs_night_module = "Gimmick_Nighttime_Skulltula_Gold_Appear";

pub fn patchGsAnyTime(world: *World, patches: *PatchSet, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const Copy = struct { rel: []const u8, actor: byml.Value };
    var copies: std.ArrayList(Copy) = .empty;
    var skipped: std.ArrayList(u8) = .empty;
    var rels = std.StringHashMap(void).init(a);
    for (world.locations.items) |*loc| {
        if (loc.kind != .gs) continue;
        for (loc.stage_refs) |r| rels.put(r.rel, {}) catch return error.OutOfMemory;
        if (loc.dungeon != null or !loc.ages.only(false, true)) continue;
        const first = loc.stage_refs[0];
        const region = loc.region.?;
        const child = std.fmt.allocPrint(a, "Banc/{s}/{s}_Child_Static.bcett.byml.zs", .{ region, region }) catch return error.OutOfMemory;
        const root = try byml.loadDict(a, (try patches.read(first.rel)).data);
        var actor: ?*byml.Dict = null;
        if (root.getArray("Actors")) |actors| {
            for (actors.items.items) |v| {
                const d = v.asDict() orelse continue;
                if (@as(u64, @truncate(@as(u128, @bitCast(d.getInt("Hash") orelse 0)))) == first.hash) {
                    actor = d;
                    break;
                }
            }
        }
        const links = if (actor) |d| if (d.get("Links")) |l| l.isTruthy() else false else false;
        if (actor == null or links or !world.files.exists(child)) {
            if (skipped.items.len > 0) skipped.appendSlice(a, ", ") catch return error.OutOfMemory;
            skipped.appendSlice(a, loc.name) catch return error.OutOfMemory;
            continue;
        }
        // after the item edits: the copy carries the shuffled drop
        copies.append(a, Copy{ .rel = child, .actor = try (byml.Value{ .dict = actor.? }).clone(a) }) catch return error.OutOfMemory;
        rels.put(child, {}) catch return error.OutOfMemory;
    }

    var sorted: std.ArrayList([]const u8) = .empty;
    var it = rels.keyIterator();
    while (it.next()) |k| sorted.append(a, k.*) catch return error.OutOfMemory;
    std.mem.sort([]const u8, sorted.items, {}, lessString);

    var night: usize = 0;
    var added: usize = 0;
    var groups_dropped: usize = 0;
    for (sorted.items) |rel| {
        const orig = try patches.read(rel);
        const doc = try byml.load(a, orig.data);
        const root = (doc.root orelse return error.InvalidData).asDict() orelse return error.InvalidData;
        const actors = try root.ensureArray(a, "Actors");
        var changed = false;
        for (copies.items) |c| {
            if (!std.mem.eql(u8, c.rel, rel)) continue;
            changed = true;
            const h = c.actor.dict.getInt("Hash") orelse 0;
            var have = false;
            for (actors.items.items) |v| {
                if (v.asDict()) |d| if ((d.getInt("Hash") orelse -1) == h) {
                    have = true;
                };
            }
            if (!have) {
                try actors.append(a, c.actor);
                added += 1;
            }
        }
        if (root.getArray("AiGroups")) |groups| {
            const keep = try byml.Array.create(a);
            for (groups.items.items) |g| {
                const logic_name = if (g.asDict()) |d| d.getString("Logic") orelse "" else "";
                if (std.mem.indexOf(u8, logic_name, gs_night_module) == null) try keep.append(a, g);
            }
            if (keep.len() != groups.len()) {
                groups_dropped += groups.len() - keep.len();
                try root.put(a, "AiGroups", .{ .array = keep });
                changed = true;
            }
        }
        for (actors.items.items) |v| {
            const d = v.asDict() orelse continue;
            if (!std.mem.eql(u8, d.getString("Gyaml") orelse "", "Enemy_Skulltula_Gold")) continue;
            const dyn = d.getDict("Dynamic") orelse continue;
            const noct = dyn.get(gs_nocturnal) orelse continue;
            if (!noct.isTruthy()) continue;
            _ = dyn.remove(gs_nocturnal);
            night += 1;
            changed = true;
        }
        if (changed) try patches.emitZs(rel, orig, try byml.dump(a, .{ .dict = root }, doc.version, false));
    }
    if (skipped.items.len > 0) {
        progress.log("Gold Skulltulas any time: {d} night-only placements now always there, {d} adult-only Skulltulas copied for child Link, {d} night-time logic groups removed; not copied: {s}", .{ night, added, groups_dropped, skipped.items });
    } else {
        progress.log("Gold Skulltulas any time: {d} night-only placements now always there, {d} adult-only Skulltulas copied for child Link, {d} night-time logic groups removed", .{ night, added, groups_dropped });
    }
}

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

// --- Dampé's gravedigging tour: the prize always at one dig spot ----------------------------------------------
// Npc_Hylia_Dampe_001 (dump): each tour dig ends in a lottery (Event219, EventQueryMiniGameDiggingHoleLottery). Its
// "something hard is buried here" results (cases 6 and 7) lead, while the prize isn't dug up yet
// (GraveYard_DiggingHoleTour_Drop_HeartPiece false), to Dampé asking for extra rupees and digging the prize ("Graveyard
// Dampe Gravedigging Tour") out at the nearest of three "big hit" spots; once it is dug up they give rupees. The roll
// is rare (95% rupees at a hit spot), so a player could dig every spot and never see the check (test report,
// DIGREWARD1). Now the spot in front of the Hylian Shield grave (Soil_BigHit_B: the soil 5.3 m in front of the
// tombstone above the Hylian Shield chest, the 2nd of the lower five in the right column on the pause map) always
// leads to the prize while it isn't dug up, and the other spots' "something hard" results give rupees, so the check
// is always at that one spot. The spot is read from the dig's own preparation switch (Event433,
// EventQueryMiniGameDiggingHoleFindNearPoint), whose case for Soil_BigHit_B is the dug spot's number.
pub const dampe_flow = "Event/EventFlow/Npc_Hylia_Dampe_001.bfevfl.zs";
pub const dampe_tour_location = "Graveyard Dampe Gravedigging Tour";
// The prize the dig brings up out of the hole (EventMiniGameDiggingHoleAdventActor, asked for as Obj_Heart_Piece) can
// only be an actor Dampé holds (his ActorHolderParam: the rupees, a rock and this one), and it plays its own rise out
// of the hole (ASInfo AutoPlayASName Act_Dig). Two tries with the placed item's own actors there showed nothing until
// the item was handed over (test reports, DIGREWARD1), so this actor stays and takes the placed item's model
// (pickups.PickupCloner.dressInModelOf; confirmed in-game with the Megaton Hammer and the Hookshot, DIGTEST2/3).
// Only Dampé's dig uses it (dump: no other pack or flow names it).
pub const dampe_dig_prize_actor = "Obj_Heart_Piece_Digging_Hole";
pub const dampe_flow_update = "Event/EventFlow/Npc_Hylia_Dampe_001.110.bfevfl.zs";
const dampe_actor = "Npc_Hylia_Dampe_001";
const dampe_prize_spot_soil = "Soil_BigHit_B";
const dampe_dig_lottery_event = "Event219";
const dampe_dig_spot_switch_event = "Event433";
const dampe_lottery_prize_results = [_]u32{ 6, 7 };
const dampe_find_dug_spot_query = "EventQueryMiniGameDiggingHoleFindNearPoint";

pub fn dampePrizeAtShieldGrave(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, dampe_actor, progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    if (fc.eventByName("RandoDampe_PrizeSpot") != null) return progress.fail(error.NotAsExpected, "Dampé's tour already changed", .{});

    const lottery = fc.eventByName(dampe_dig_lottery_event) orelse return progress.fail(error.NotAsExpected, "no dig lottery", .{});
    if (!fc.isQuery(&fc.events.items[lottery], dampe_actor, "EventQueryMiniGameDiggingHoleLottery")) return progress.fail(error.NotAsExpected, "dig lottery not as expected", .{});

    // the prize result: a switch on the prize flag, prize when not yet dug up (case 1), rupees when it is (case 0)
    var prize_check: ?u16 = null;
    var rupees_for_prize_result = [_]u16{ NONE, NONE };
    for (dampe_lottery_prize_results, 0..) |result, k| {
        const target = caseTarget(fc.events.items[lottery].kind.switch_.cases.items, result) orelse return progress.fail(error.NotAsExpected, "dig lottery has no result {d}", .{result});
        const check = &fc.events.items[target];
        if (!fc.isQuery(check, "GameDataActor", "EventQueryIsGameDataBool")) return progress.fail(error.NotAsExpected, "prize result {d} not as expected", .{result});
        const p = check.kind.switch_.params orelse return progress.fail(error.NotAsExpected, "prize result {d} not as expected", .{result});
        if (!p.isString("GameDataName", "GraveYard_DiggingHoleTour_Drop_HeartPiece")) return progress.fail(error.NotAsExpected, "prize result {d} not as expected", .{result});
        rupees_for_prize_result[k] = caseTarget(check.kind.switch_.cases.items, 0) orelse return progress.fail(error.NotAsExpected, "prize result {d} not as expected", .{result});
        if (prize_check == null) prize_check = target;
    }

    // the dug spot's number for the prize spot, and every spot number the dig knows
    const spot_switch = fc.eventByName(dampe_dig_spot_switch_event) orelse return progress.fail(error.NotAsExpected, "no dig spot switch", .{});
    const spots = &fc.events.items[spot_switch];
    if (!fc.isQuery(spots, dampe_actor, dampe_find_dug_spot_query)) return progress.fail(error.NotAsExpected, "dig spot switch not as expected", .{});
    var prize_spot: ?u32 = null;
    for (spots.kind.switch_.cases.items) |c| {
        const e = &fc.events.items[c.event];
        const p = switch (e.kind) {
            .sub_flow => |sf| sf.params orelse continue,
            else => continue,
        };
        if (p.isString("SoilInstanceName", dampe_prize_spot_soil)) prize_spot = c.value;
    }
    const prize_spot_number = prize_spot orelse return progress.fail(error.NotAsExpected, "no {s} dig spot", .{dampe_prize_spot_soil});

    // only one event leads to the lottery (a short wait after the dig's preparation)
    var before: ?usize = null;
    var leading: usize = 0;
    for (fc.events.items, 0..) |*e, k| if (e.leadsTo(lottery)) {
        before = k;
        leading += 1;
    };
    if (leading != 1 or fc.events.items[before.?].kind != .action) return progress.fail(error.NotAsExpected, "dig lottery reached from {d} events", .{leading});

    // a new switch on the dug spot: the prize spot goes to the prize check, every other spot to the lottery
    const query = try flows.requireQuery(fc, allocator, dampe_actor, dampe_find_dug_spot_query, progress);
    var cases: std.ArrayList(evfl.Case) = .empty;
    for (spots.kind.switch_.cases.items) |c| {
        const target = if (c.value == prize_spot_number) prize_check.? else lottery;
        cases.append(allocator, .{ .value = c.value, .event = target }) catch return error.OutOfMemory;
    }
    const spot_check = try fc.addEvent(allocator, .{ .name = "RandoDampe_PrizeSpot", .kind = .{ .switch_ = .{ .actor = query[0], .query = query[1], .cases = cases } } });
    fc.events.items[before.?].kind.action.next = spot_check;

    // the lottery's "something hard" results give rupees, as they do once the prize is dug up
    for (fc.events.items[lottery].kind.switch_.cases.items) |*c| {
        for (dampe_lottery_prize_results, 0..) |result, k| {
            if (c.value == result) c.event = rupees_for_prize_result[k];
        }
    }
    return flows.writeBack(allocator, &doc, dampe_actor, progress);
}

// --- Lost Woods ocarina game: every reward in one round ------------------------------------------------------
// Npc_SkullKid_Child_02: each won round raises the song length kept in
// Minigame_SkullKidSession_CurrentGradeSoundNumForSession and pays one reward. Below 6 (the first round): set it to 6,
// a Blue Rupee, its rupee display closed. At 6: set it to 8, a Red Rupee. At 8: Minigame_SkullKidSession_IsGetHeartPiece
// decides between the Piece of Heart (the check, "LW Ocarina Memory Game") and a Blue Rupee. Now the first won round
// sets 8 and goes on from its Blue Rupee to a copy of the Red Rupee and then to that check, so one song gives all
// three; a round won later is the third one.
pub const memory_game_flow = "Event/EventFlow/Npc_SkullKid_Child_02.bfevfl.zs";
const memory_grade = "Minigame_SkullKidSession_CurrentGradeSoundNumForSession";
const memory_got = "Minigame_SkullKidSession_IsGetHeartPiece";

fn isMemoryReward(e: *const evfl.Event, actor: ?[]const u8) bool {
    if (e.kind != .sub_flow) return false;
    const s = e.kind.sub_flow;
    if (!std.mem.eql(u8, s.flowchart, "Dm_SY_GetInEvent") or !std.mem.eql(u8, s.entry_point, "GetInEvent_NotTurn_NotNpc")) return false;
    const name = actor orelse return true;
    const p = s.params orelse return false;
    return p.isString("ActorName", name);
}

/// The first event from `start` on (along plain next links, at most 6) that is a reward of `actor`.
fn followToReward(fc: *const evfl.Flowchart, start: u16, actor: []const u8) ?u16 {
    var i: u16 = start;
    var steps: usize = 0;
    while (steps < 6) : (steps += 1) {
        if (i >= fc.events.items.len) return null;
        const e = &fc.events.items[i];
        if (isMemoryReward(e, actor)) return i;
        i = e.next() orelse return null;
    }
    return null;
}

pub fn memoryGameAllRewards(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "Npc_SkullKid_Child_02", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoMemory")) return progress.fail(error.NotAsExpected, "ocarina game flow already changed", .{});
    }

    var at6: std.ArrayList(u16) = .empty;
    var at8: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |*e, i| {
        if (!fc.isAction(e, "GameDataActor", "EventTriggerSetGameDataInt")) continue;
        const p = e.kind.action.params orelse continue;
        if (!p.isString("GameDataName", memory_grade)) continue;
        if (p.is("Value", .{ .int = 6 })) at6.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        if (p.is("Value", .{ .int = 8 })) at8.append(allocator, @intCast(i)) catch return error.OutOfMemory;
    }
    if (at6.items.len != 1 or at8.items.len != 1) {
        return progress.fail(error.NotAsExpected, "song-length steps not as expected ({d} at 6, {d} at 8)", .{ at6.items.len, at8.items.len });
    }
    const first = at6.items[0];
    const blue = followToReward(fc, first, "Obj_Rupee_Blue") orelse return progress.fail(error.NotAsExpected, "round rewards not as expected", .{});
    const red = followToReward(fc, at8.items[0], "Obj_Rupee_Red") orelse return progress.fail(error.NotAsExpected, "round rewards not as expected", .{});
    const blue_close = fc.events.items[blue].next().?;
    const red_close = fc.events.items[red].next().?;
    const blue_close_e = fc.event(blue_close) orelse return progress.fail(error.NotAsExpected, "rupee displays not as expected", .{});
    const red_close_e = fc.event(red_close) orelse return progress.fail(error.NotAsExpected, "rupee displays not as expected", .{});
    if (!fc.isAction(blue_close_e, "UISystemActor", "EventCloseRupeeDisplay") or !fc.isAction(red_close_e, "UISystemActor", "EventCloseRupeeDisplay")) {
        return progress.fail(error.NotAsExpected, "rupee displays not as expected", .{});
    }
    // the third round's choice: already given -> Blue Rupee, else the check
    var last: ?u16 = null;
    var last_count: usize = 0;
    for (fc.events.items, 0..) |*e, i| {
        if (e.kind != .switch_) continue;
        if (!std.mem.eql(u8, fc.queryName(e) orelse "", "EventQueryIsGameDataBool")) continue;
        const p = e.kind.switch_.params orelse continue;
        if (!p.isString("GameDataName", memory_got)) continue;
        const cases = e.kind.switch_.cases.items;
        if (cases.len != 2) continue;
        var all_rewards = true;
        for (cases) |c| {
            const t = fc.event(c.event) orelse {
                all_rewards = false;
                continue;
            };
            if (!isMemoryReward(t, null)) all_rewards = false;
        }
        if (!all_rewards) continue;
        last = @intCast(i);
        last_count += 1;
    }
    if (last_count != 1) return progress.fail(error.NotAsExpected, "Piece of Heart choice not as expected ({d})", .{last_count});
    const preds = try fc.predecessors(allocator, blue_close);
    if (preds.len != 1 or preds[0] != blue) return progress.fail(error.NotAsExpected, "the first round's rupee display is reached from elsewhere", .{});

    try fc.events.items[first].kind.action.params.?.put(allocator, "Value", .{ .int = 8 });
    var red_copy = try fc.events.items[red].clone(allocator);
    red_copy.name = "RandoMemoryRedRupee";
    const new_red = try fc.addEvent(allocator, red_copy);
    var close_copy = try fc.events.items[red_close].clone(allocator);
    close_copy.name = "RandoMemoryRedRupeeClose";
    const new_close = try fc.addEvent(allocator, close_copy);
    fc.events.items[new_close].nextPtr().?.* = last.?;
    fc.events.items[new_red].nextPtr().?.* = new_close;
    fc.events.items[blue_close].nextPtr().?.* = new_red;
    try flows.listReachedCalls(allocator, fc, &.{new_red});
    return flows.writeBack(allocator, &doc, "Npc_SkullKid_Child_02", progress);
}

// --- Skip Ganon's Trials: the quest step the last barrier gives ---------------------------------------------
// With every trial done in the save data (gamedata.ganon_trials), the barrier-removal entries never run, and the last
// one is also what moves the Defeat_Ganon quest from Step03 to Step04. The quest can't start at Step04 in the save:
// Step01 and up is what makes the rainbow bridge appear. So the two entries that give Step03 when you first see the
// tower barrier go on to Step04 right after it.
const defeat_ganon_flow = "Event/EventFlow/Defeat_Ganon.bfevfl.zs";

pub fn patchGanonTrials(patches: *PatchSet, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const orig = try patches.read(defeat_ganon_flow);
    var doc = try flows.readFlow(a, orig.data, "Defeat_Ganon", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    var hits: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |*e, i| {
        if (!fc.isAction(e, "ChallengeSystemActor", "EventExecuteProgressChallengeStep")) continue;
        const p = e.kind.action.params orelse continue;
        if (p.isString("ChallengeName", "Defeat_Ganon") and p.isString("StepName", "Step03")) hits.append(a, @intCast(i)) catch return error.OutOfMemory;
    }
    if (hits.items.len != 2) return progress.fail(error.NotAsExpected, "expected 2 Defeat_Ganon Step03 events, found {d}", .{hits.items.len});
    for (hits.items, 0..) |i, k| {
        const old = fc.events.items[i].kind.action;
        const params = try old.params.?.clone(a);
        try params.put(a, "StepName", .{ .string = "Step04" });
        const name = std.fmt.allocPrint(a, "RandoTrials_Step04_{d}", .{k}) catch return error.OutOfMemory;
        const new = try fc.addEvent(a, evfl.makeAction(name, .{ old.actor, old.action }, old.next, params));
        fc.events.items[i].kind.action.next = new;
    }
    const data = try flows.writeBack(a, &doc, "Defeat_Ganon", progress);
    try patches.emitZs(defeat_ganon_flow, orig, data);
    progress.log("Skip Ganon's Trials: the Defeat_Ganon quest goes on to Step04 when you first see the tower barrier", .{});
}

// --- Malon and Talon: their later visits wait until the first one is over --------------------------------
// Child Malon first waits at Hyrule Castle (her placement shows until Goto_HyruleCastle is past Step03_02, the talk
// with Zelda), with Talon asleep by the castle wall. After each dungeon, SubEvent_GetEponaSong:GetEponaSong_StepCheck
// (called from Dm_SY_BancChange_EscapeDungeon) sends her on: with the Goron Ruby she is back at the castle, sitting
// with Talon by the crates (IsMalonAppear_HyruleCastleSecondTime); with the Zora Sapphire too, in the Market
// (IsMalonAppear_Market). The game takes for granted that Zelda was met long before the Ruby; in a seed the Ruby can
// come first, and then the first visit and the later one both showed: two Malons and two Talons at the castle (test
// report, seed FBRZU9NLY4). So the step check now sets either flag only once the castle quest is past Step03_02: a
// switch on Malon's own first-visit flag takes the set's place. Before that she stays at her first visit, and the
// next dungeon's step check moves her on as the game would.
pub const malon_step_flow = "Event/EventFlow/SubEvent_GetEponaSong.bfevfl.zs";
/// the condition of Malon's first castle placement (HyruleCastle_Static, IsNegation): past it, the first visit is over
const malon_first_visit_over_exp = "Goto_HyruleCastle_IsAfter_Step03_02_Exp";
/// the flags the step check sets for Malon's later visits
const malon_later_visit_flags = [_][]const u8{ "IsMalonAppear_HyruleCastleSecondTime", "IsMalonAppear_Market" };

pub fn malonLaterVisitsGuard(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "SubEvent_GetEponaSong", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    if (fc.findActor("GameDataActor") == null) return progress.fail(error.NotAsExpected, "SubEvent_GetEponaSong has no GameDataActor", .{});
    const query = (try fc.queryIndex(allocator, "GameDataActor", "EventQueryIsGameDataBoolExp")) orelse
        return progress.fail(error.NotAsExpected, "SubEvent_GetEponaSong has no flag check to model the switch on", .{});
    for (malon_later_visit_flags) |flag| {
        // the one event that turns the visit on (Value true; the others clear it)
        var hits: std.ArrayList(u16) = .empty;
        for (fc.events.items, 0..) |*e, i| {
            if (!fc.isAction(e, "GameDataActor", "EventTriggerSetGameDataBool")) continue;
            const p = e.kind.action.params orelse continue;
            if (!p.isString("GameDataName", flag)) continue;
            const value = p.get("Value") orelse continue;
            if (value != .bool or !value.bool) continue;
            hits.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        }
        if (hits.items.len != 1) return progress.fail(error.NotAsExpected, "expected 1 event turning {s} on, found {d}", .{ flag, hits.items.len });
        const i = hits.items[0];
        // the set moves to the end; the switch takes its place. A bool check answers 0 for true; false goes nowhere,
        // so the flow ends there as it would after the set.
        const set_event = fc.events.items[i];
        const moved = try fc.addEvent(allocator, set_event);
        var cases: std.ArrayList(evfl.Case) = .empty;
        cases.append(allocator, .{ .value = 0, .event = moved }) catch return error.OutOfMemory;
        const name = std.fmt.allocPrint(allocator, "RandoMalon_FirstVisitOver_{s}", .{flag}) catch return error.OutOfMemory;
        fc.events.items[i] = .{ .name = name, .kind = .{ .switch_ = .{
            .actor = query[0],
            .query = query[1],
            .cases = cases,
            .params = try Container.from(allocator, &.{.{ .name = "GameDataName", .value = .{ .string = malon_first_visit_over_exp } }}),
        } } };
    }
    return flows.writeBack(allocator, &doc, "SubEvent_GetEponaSong", progress);
}

// --- Rainbow Bridge Requirement: keep the castle quest from going back -------------------------------------
// The bridge's own event moves the castle quest to Step02, and the quest goes on inside the castle. With a bridge
// requirement other than vanilla, the bridge can appear before Zelda's Light Arrows scene, and that scene (AllSage)
// then sets the quest to Step01, behind where it already is. So AllSage now sets Step01 only while the quest is still
// before it: a switch on the quest's own Step01 check (gamedata.bridge_quest_exp).
pub const allsage_flow = "Event/EventFlow/AllSage.bfevfl.zs";

pub fn bridgeQuestGuard(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "AllSage", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    var hits: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |*e, i| {
        if (!fc.isAction(e, "ChallengeSystemActor", "EventExecuteProgressChallengeStep")) continue;
        const p = e.kind.action.params orelse continue;
        if (p.isString("ChallengeName", "Defeat_Ganon") and p.isString("StepName", "Step01")) hits.append(allocator, @intCast(i)) catch return error.OutOfMemory;
    }
    if (hits.items.len != 1) return progress.fail(error.NotAsExpected, "expected 1 Defeat_Ganon Step01 event in AllSage, found {d}", .{hits.items.len});
    const i = hits.items[0];
    if (fc.findActor("GameDataActor") == null) return progress.fail(error.NotAsExpected, "AllSage has no GameDataActor", .{});
    const q = (try fc.queryIndex(allocator, "GameDataActor", "EventQueryIsGameDataBoolExp")).?;
    // the step moves to the end; the switch takes its place
    const step = fc.events.items[i];
    const moved = try fc.addEvent(allocator, step);
    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = 0, .event = moved }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = 1, .event = step.kind.action.next }) catch return error.OutOfMemory;
    fc.events.items[i] = .{ .name = "RandoBridge_QuestPastStep01", .kind = .{ .switch_ = .{
        .actor = q[0],
        .query = q[1],
        .cases = cases,
        .params = try Container.from(allocator, &.{.{ .name = "GameDataName", .value = .{ .string = gamedata.bridge_quest_exp } }}),
    } } };
    return flows.writeBack(allocator, &doc, "AllSage", progress);
}
