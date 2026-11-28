//! A test plan's start (core/testplan.zig), checked against the game and turned into patches.
//!
//! Where Link appears. A new game loads Kokiri Forest and then runs OpeningEvent:Opening_Introduction once (the
//! sequence Sequence/Opening.module sets it as the boot event). Its last step is an autosave, which the start items
//! already come before (faststart.giveAtStart). A test start adds, just before that autosave:
//!
//!     [EventWorldManagerController.EventTrigger_SetTime {TimeHour}]                       the time of day
//!     [GameDataActor.EventTriggerSetGameDataBool {Sequence_IsChildhood}]                  the age, see below
//!     GameSystemActor.EventReserveBancChange {NextBanc, NextStartPos | NextPosition, NextStartRot, BootEventName}
//!     -> the autosave
//!
//! The scene change is the game's own (Dm_SY_BancChangeGo:Event0 also reserves the change and then autosaves; the
//! Door of Time flow uses NextPosition + NextStartRot without a start spot to put Link in the Chamber of Sages).
//! BootEventName is an EventSetting row the game starts when the scene has loaded (DoorOfTime: SageRoom_MeetRauru).
//!
//! Age. Sequence/LoadBancImpl.module: on loading a scene whose GameBancParam has IsForceSwitchChildOrAdult, the game
//! sets Sequence_IsChildhood to the scene's IsChildWhenChangeBanc (child versions: true, inherited by the adult
//! versions, which set it false). Other scenes (dungeons, boss rooms) keep Sequence_IsChildhood as it is. So an age
//! is given by the scene's version (KokiriForest_Adult) where the scene has one, and by setting Sequence_IsChildhood
//! just before the change for the rest. Kokiri Forest's own load has already forced child by then, so the flag is
//! set after it.
//!
//! Rotation: NextStartRot is in degrees (the game's own time travel, Market_Child_Field_ChildToAdult, passes
//! [0, 90, 0]; OotrR's adult start copies it). The start spot table stores radians (StartPos.byml: Rot
//! [0, 1.570796, 0]), so an unnamed spot's direction is converted.
//!
//! The rest is save data (gamedata.apply's test changes): quest steps (Enum Step_<quest>), flags, and cutscenes as
//! seen or unseen (HavePlayedEvent.<event>). Start items are handed over like the start checks' (patches.zig).
//!
//! Tested in-game (TESTKIT1-3, 2026-11-25): the warp to a start spot, the adult version of a scene, the age flag for
//! a scene without one (Forest Temple), the time, start items and a cutscene marked unseen. Not tested yet: boot
//! events and positions given as coordinates.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const byml = @import("../formats/byml.zig");
const ainb = @import("../formats/ainb.zig");
const flows = @import("flows.zig");
const gamedata = @import("gamedata.zig");
const patchset = @import("patchset.zig");
const testplan = @import("../core/testplan.zig");
const world_mod = @import("../game/world.zig");
const fsmod = @import("../core/fs.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const Container = evfl.Container;
const World = world_mod.World;
const NONE = evfl.NONE;
const ItemId = @import("../logic/logic.zig").ItemId;

pub const opening_flow = "Event/EventFlow/OpeningEvent.bfevfl.zs";
const scene_param_folder = "Banc/GameBancParam";
const scene_param_suffix = ".game__banc__GameBancParam.bgyml";
const start_spot_table = "Banc/BancBasedResource/StartPos.byml.zs";
const childhood_flag = "Sequence_IsChildhood";
const played_prefix = "HavePlayedEvent.";
const quest_enum_prefix = "Step_";
/// what the added events' names start with (so a second edit of the opening is refused)
const added_prefix = "RandoTestStart";
/// the scene change's fade (Sequence_BancChangeFadePattern: 0 LoadingFade, 1 BlackFade; Dm_SY_BancChangeGo uses 1)
const fade_black: i32 = 1;

/// Where the opening sends Link.
pub const Warp = struct {
    /// a GameBancParam name ("KokiriForest_Adult")
    scene: []const u8,
    /// a start spot of the scene, or "" for `position`
    start_spot: []const u8,
    position: [3]f32,
    /// degrees around the vertical axis (NextStartRot's middle value)
    facing_degrees: f32,
    boot_event: []const u8,
    /// set Sequence_IsChildhood to this before the change (scenes without an age version), or null
    childhood: ?bool,
    /// Sequence_BancChangeFadePattern: 1 BlackFade (Dm_SY_BancChangeGo), 2 WhiteFade (the time travel)
    fade_pattern: i32 = fade_black,
};

/// An adult start that loads its own area (see "Starting Age: Adult"): Link is moved to `position` in it while the
/// screen is still black.
pub const InPlace = struct { position: [3]f32, facing_degrees: f32 };

/// The opening as startAtSpawn left it.
pub const SpawnResult = struct { data: []u8 };

/// A quest moved on by the game's own action (ChallengeSystemActor.EventExecuteProgressChallengeStep).
pub const QuestProgress = struct { quest: []const u8, step: []const u8 };

/// A Bool save flag set in the opening (GameDataActor.EventTriggerSetGameDataBool).
pub const FlagSet = struct { name: []const u8, value: bool };

/// What the opening does before its autosave, in this order: the time, quest steps, flags, equipment added and
/// equipped (as the Door of Time flow adds the Master Sword), then the scene change.
pub const OpeningStart = struct {
    warp: ?Warp = null,
    time_hour: ?u8 = null,
    quest_steps: []const QuestProgress = &.{},
    flags: []const FlagSet = &.{},
    /// actors added to the pouch and equipped (PouchSystemActor.EventTriggerAddOrRemovePouchContent, IsEquipDIrect)
    equip: []const []const u8 = &.{},
    /// the adult start (see "Starting Age: Adult"): the new game already loaded adult Castle Town; the introduction
    /// becomes the adult start's steps, with Link moved here
    in_place: ?InPlace = null,
    /// the medallions menu opens once, as after the Deku Tree (UISystemActor.EventOpenPerformanceImportantMenu, as
    /// Dm_Kokiri_0130 opens it), just before the autosave; not with `warp` (its scene change comes there)
    open_important_menu: bool = false,

    pub fn isEmpty(self: OpeningStart) bool {
        return self.warp == null and self.time_hour == null and self.quest_steps.len == 0 and self.flags.len == 0 and
            self.equip.len == 0 and self.in_place == null and !self.open_important_menu;
    }
};

// ------------------------------------------------------------------------------------- Starting Age: Adult
// As OotrR does it (src/oot_rando/patching/adult_start.py, MIT License, Copyright (c) 2026 Mozencaz): the opening
// moves the Sheik and Forest quests on (AllSage Step01: the first arrival's Sheik scenes count as played), marks the
// first trip to adult as made and adds the Master Sword as the Door of Time flow does. The Door of Time is opened
// (door.zig) and the save data has the rest (adult_start_changes). Every seed lets the pedestal turn Link back to
// child from his first trip to adult on and moves Sheik aside (pedestal.zig).
//
// Unlike OotrR, a new game never loads Kokiri Forest: the first area (Sequence/FormalSequence.root: Title.module's
// FirstBancParam, KokiriForest_Child) becomes adult Castle Town (firstAreaAdult), which makes Link adult as it loads
// (its GameBancParam: IsChildWhenInitializingScene false). Why: every version that changed scenes from Kokiri
// Forest showed child Link first (test reports: outside the Kokiri Shop, then "for a split second" during the
// fade), and those that changed while the screen was faded out stayed black. The opening then (adultInPlace):
// - Opening_LoadingKokiriForest closes the loading screen to black and ends (its fade-in and 2-second wait go;
//   Skip Opening Movie is on, so the Kokiri movie doesn't play);
// - Opening_Introduction keeps its first steps (Link takes part, the time is 6:00), then: the silent start items,
//   the adult start's quests and flags, Link (and Navi) moved to the LightPrelude spot of the Temple of Time (the
//   hall, facing the pedestal room, where the Prelude scene puts him), the Master Sword added and equipped, a
//   moment for the area, the fade-in, the start items with an item window, the medallions menu, the autosave.
// A test plan's own spawn keeps Kokiri Forest and changes scenes at the end of the opening, as for a child start.
pub const first_area_sequence = "Sequence/FormalSequence.root.ainb";
const first_area_param = "FirstBancParam";
const first_area_child = "Work/Banc/GameBancParam/KokiriForest_Child.game__banc__GameBancParam.gyml";
const first_area_adult = "Work/Banc/GameBancParam/Market_Adult.game__banc__GameBancParam.gyml";
/// the LightPrelude start spot (StartPos.byml), as `goggles_cli test-catalog` lists it
pub const adult_start_place = InPlace{ .position = .{ 84.751, 104.232, -34.0 }, .facing_degrees = 90 };
/// Navi next to Link, as faststart.startOutside places her
const navi_offset = [3]f32{ 0.6, 1.0, 0.4 };
pub const adult_start_quests = [_]QuestProgress{
    .{ .quest = "AllSage", .step = "Step01" },
    .{ .quest = "SageOfForest", .step = "Step02" },
};
pub const adult_start_flags = [_]FlagSet{.{ .name = "Market_Child_Firsttime_GotoAdult", .value = true }};
pub const adult_start_equip = [_][]const u8{"Weapon_Sword_Master"};

/// The game's first area as adult Castle Town (see "Starting Age: Adult").
pub fn firstAreaAdult(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    const r = ainb.repointStringConst(allocator, data, first_area_param, first_area_child, first_area_adult) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return progress.fail(error.NotAsExpected, "{s} is not as expected", .{first_area_sequence}),
    };
    if (r.count != 1) return progress.fail(error.NotAsExpected, "{s}: expected one first area, found {d}", .{ first_area_sequence, r.count });
    return r.data;
}

/// The save data of an adult start. Not in OotrR's version:
/// - the Ganondorf scene of the first pull counts as seen, so pulling the sword again as child is plain time travel
///   (DoorOfTime:DoorOfTime_Draw takes the first-pull path, to Ganondorf and Rauru, until it has played); Rauru's
///   check is handed over at the start instead (fill.zig);
/// - the Kokiri boy at the forest exit is gone, so child Link, who first appears in the Temple of Time, can get into
///   Kokiri Forest (the logic counts on it);
/// - the door's own flag (door.zig opens the door itself).
pub const adult_start_changes = [_]gamedata.Change{
    .{ .kind = .bool_flag, .flag = "HavePlayedEvent.Dm_TimeTemple_0040" },
    .{ .kind = .bool_flag, .flag = gamedata.forest_exit, .bool_value = false },
    .{ .kind = .bool_flag, .flag = gamedata.door_opened_flag },
};

/// A test start ready to patch: everything in it exists in this game.
pub const Resolved = struct {
    warp: ?Warp = null,
    time_hour: ?u8 = null,
    items: []const ItemId = &.{},
    changes: []const gamedata.Change = &.{},
    /// what the seed's log says about the start, one line each
    summary: []const []const u8 = &.{},
};

pub const Outcome = union(enum) {
    ready: Resolved,
    /// why the plan can't be made with this game, for the tester
    problem: []const u8,
};

/// Checks `setup` against the game. Nothing is patched yet.
pub fn resolve(allocator: Allocator, world: *World, setup: *const testplan.StartSetup) PatchError!Outcome {
    var summary: std.ArrayList([]const u8) = .empty;
    var resolved = Resolved{ .time_hour = setup.time_hour };
    if (setup.time_hour) |hour| try appendLine(allocator, &summary, "time of day: {d}:00", .{hour});

    // the age alone, without a scene: Kokiri Forest's version for that age (Link starts there anyway)
    var spawn_request = setup.spawn;
    if (spawn_request == null and setup.age != null) spawn_request = .{ .scene = "KokiriForest" };
    if (spawn_request) |spawn| {
        switch (try resolveWarp(allocator, world, spawn, setup.age)) {
            .problem => |message| return .{ .problem = message },
            .ready => |warp| {
                resolved.warp = warp;
                const where = if (warp.start_spot.len > 0)
                    try std.fmt.allocPrint(allocator, "start spot {s}", .{warp.start_spot})
                else
                    try std.fmt.allocPrint(allocator, "position ({d:.2}, {d:.2}, {d:.2})", .{ warp.position[0], warp.position[1], warp.position[2] });
                try appendLine(allocator, &summary, "spawn: {s}, {s}{s}{s}", .{
                    warp.scene, where, if (warp.boot_event.len > 0) ", then event " else "", warp.boot_event,
                });
            },
        }
    }

    const probe = try gamedata.probeOf(world);
    var changes: std.ArrayList(gamedata.Change) = .empty;
    for (setup.quests) |quest| {
        const enum_name = if (std.mem.startsWith(u8, quest.quest, quest_enum_prefix)) quest.quest else try std.fmt.allocPrint(allocator, "{s}{s}", .{ quest_enum_prefix, quest.quest });
        const steps = probe.enumValueNames(enum_name) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[quests] no quest named {s} (quests.txt from `goggles_cli test-catalog` lists them)", .{quest.quest}) };
        const step = valueNamed(steps, quest.step) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[quests] {s} has no step {s}; its steps: {s}", .{ quest.quest, quest.step, try joinValueNames(allocator, steps) }) };
        try changes.append(allocator, .{ .kind = .enum_value, .flag = enum_name, .text = step });
        try appendLine(allocator, &summary, "quest {s} starts at {s}", .{ quest.quest, step });
    }
    for (setup.flags) |flag| {
        const kind = probe.flagKind(flag.name) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[flags] the save data has no flag {s} (names are case-sensitive)", .{flag.name}) };
        const change: gamedata.Change = switch (flag.value) {
            .boolean => |b| if (kind == .Bool) .{ .kind = .bool_flag, .flag = flag.name, .bool_value = b } else return .{ .problem = try wrongKind(allocator, flag.name, kind, "true/false") },
            .integer => |n| if (kind == .Int) .{ .kind = .int_flag, .flag = flag.name, .int_value = n } else return .{ .problem = try wrongKind(allocator, flag.name, kind, "a whole number") },
            .enum_value => |text| blk: {
                if (kind != .Enum) return .{ .problem = try wrongKind(allocator, flag.name, kind, "a quoted value name") };
                const values = probe.enumValueNames(flag.name).?;
                const value = valueNamed(values, text) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[flags] {s} has no value {s}; its values: {s}", .{ flag.name, text, try joinValueNames(allocator, values) }) };
                break :blk .{ .kind = .enum_value, .flag = flag.name, .text = value };
            },
        };
        try changes.append(allocator, change);
        try appendLine(allocator, &summary, "flag {s} = {s}", .{ flag.name, try flagValueText(allocator, flag.value) });
    }
    for ([_]struct { list: []const []const u8, seen: bool }{
        .{ .list = setup.seen_cutscenes, .seen = true },
        .{ .list = setup.unseen_cutscenes, .seen = false },
    }) |group| {
        for (group.list) |event| {
            const flag = if (std.mem.startsWith(u8, event, played_prefix)) event else try std.fmt.allocPrint(allocator, "{s}{s}", .{ played_prefix, event });
            if (probe.flagKind(flag) != .Bool) return .{ .problem = try std.fmt.allocPrint(allocator, "[cutscenes] the game keeps no \"seen\" flag for {s} (cutscenes.txt from `goggles_cli test-catalog` lists the ones it keeps)", .{event}) };
            try changes.append(allocator, .{ .kind = .bool_flag, .flag = flag, .bool_value = group.seen });
            try appendLine(allocator, &summary, "cutscene {s}: {s}", .{ event, if (group.seen) "seen" else "not seen" });
        }
    }
    resolved.changes = changes.items;

    var items: std.ArrayList(ItemId) = .empty;
    for (setup.items) |name| {
        const item = (try findItem(allocator, world, name)) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[start] items: no item named \"{s}\" (items.txt from `goggles_cli test-catalog` lists them)", .{name}) };
        try items.append(allocator, item);
    }
    resolved.items = items.items;
    if (items.items.len > 0) try appendLine(allocator, &summary, "start items: {s}", .{try std.mem.join(allocator, ", ", setup.items)});
    resolved.summary = summary.items;
    return .{ .ready = resolved };
}

const WarpOutcome = union(enum) { ready: Warp, problem: []const u8 };

fn resolveWarp(allocator: Allocator, world: *World, spawn: testplan.Spawn, age: ?testplan.Age) PatchError!WarpOutcome {
    const scenes = try sceneNames(allocator, world);
    // the scene as written, else its version for the age asked for (child when none)
    const age_suffix = if (age == .adult) "_Adult" else "_Child";
    const versioned = try std.fmt.allocPrint(allocator, "{s}{s}", .{ spawn.scene, age_suffix });
    const scene = if (isListed(scenes, spawn.scene)) spawn.scene else if (isListed(scenes, versioned)) versioned else {
        return .{ .problem = try std.fmt.allocPrint(allocator, "[start] no scene named {s}; scenes: {s}", .{ spawn.scene, try std.mem.join(allocator, ", ", try sceneFamilies(allocator, scenes)) }) };
    };

    const rule = try ageRule(allocator, world, scene);
    var childhood: ?bool = null;
    if (rule.forced) |scene_age| {
        if (age != null and age.? != scene_age) {
            return .{ .problem = try std.fmt.allocPrint(allocator, "[start] {s} is always {s}; for {s} use its {s} version or leave out the _Child/_Adult ending", .{ scene, @tagName(scene_age), @tagName(age.?), @tagName(age.?) }) };
        }
    } else if (age) |wanted| {
        childhood = wanted == .child;
    }

    const spots = try startSpots(allocator, world, scene);
    var warp = Warp{
        .scene = scene,
        .start_spot = "",
        .position = .{ 0, 0, 0 },
        .facing_degrees = spawn.facing_degrees,
        .boot_event = spawn.boot_event,
        .childhood = childhood,
    };
    if (spawn.position) |position| {
        warp.position = position;
    } else if (spawn.start_spot.len > 0) {
        const spot = findSpot(spots, spawn.start_spot) orelse return .{ .problem = try std.fmt.allocPrint(allocator, "[start] {s} has no start spot {s}; its spots: {s}", .{ scene, spawn.start_spot, try spotNames(allocator, spots) }) };
        warp.start_spot = spot.name;
    } else {
        // neither: the scene's entrance spot when it has one, else its unnamed default, else its first
        const chosen = findSpot(spots, "EntrancePos") orelse findSpot(spots, "") orelse (if (spots.len > 0) spots[0] else null) orelse
            return .{ .problem = try std.fmt.allocPrint(allocator, "[start] {s} has no start spots; give a position", .{scene}) };
        if (chosen.name.len > 0) {
            warp.start_spot = chosen.name;
        } else {
            // an unnamed spot can't be asked for by name: its coordinates and direction instead
            warp.position = chosen.position;
            warp.facing_degrees = std.math.radiansToDegrees(chosen.facing_radians);
        }
    }

    if (spawn.boot_event.len > 0 and !try bootEventExists(allocator, world, spawn.boot_event)) {
        return .{ .problem = try std.fmt.allocPrint(allocator, "[start] boot_event: the game has no event {s} (boot_events.txt from `goggles_cli test-catalog` lists them)", .{spawn.boot_event}) };
    }
    return .{ .ready = warp };
}

// ------------------------------------------------------------------------------------------------- game tables

/// The scenes' GameBancParam names ("KokiriForest_Child", "ForestTemple"...), sorted.
pub fn sceneNames(allocator: Allocator, world: *World) PatchError![]const []const u8 {
    const files = world.files.listDir(allocator, scene_param_folder) catch return error.GameFiles;
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        if (std.mem.endsWith(u8, file, scene_param_suffix)) try out.append(allocator, file[0 .. file.len - scene_param_suffix.len]);
    }
    return out.items;
}

/// Scene names without their _Child/_Adult ending, each once (for messages).
fn sceneFamilies(allocator: Allocator, scenes: []const []const u8) PatchError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (scenes) |scene| {
        const family = familyOf(scene);
        if (!isListed(out.items, family)) try out.append(allocator, family);
    }
    return out.items;
}

fn familyOf(scene: []const u8) []const u8 {
    for ([_][]const u8{ "_Child", "_Adult" }) |suffix| {
        if (std.mem.endsWith(u8, scene, suffix)) return scene[0 .. scene.len - suffix.len];
    }
    return scene;
}

pub const AgeRule = struct {
    /// the age the scene always gives Link, or null when it keeps his age
    forced: ?testplan.Age,
};

/// The scene's age rule (LoadBancImpl: IsForceSwitchChildOrAdult and IsChildWhenChangeBanc), with the values a
/// param doesn't set taken from its "$parent" (adult versions inherit from the child ones).
pub fn ageRule(allocator: Allocator, world: *World, scene: []const u8) PatchError!AgeRule {
    var forces: ?bool = null;
    var child: ?bool = null;
    var current: []const u8 = scene;
    var depth: usize = 0;
    // a parent chain is one or two long in the game; four stops a loop
    while (depth < 4) : (depth += 1) {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ scene_param_folder, current, scene_param_suffix });
        const data = world.files.read(allocator, rel) catch return error.GameFiles;
        const param = byml.loadDict(allocator, data) catch return error.InvalidData;
        if (forces == null) if (param.get("IsForceSwitchChildOrAdult")) |v| {
            forces = v.isTruthy();
        };
        if (child == null) if (param.get("IsChildWhenChangeBanc")) |v| {
            child = v.isTruthy();
        };
        const parent_path = param.getString("$parent") orelse break;
        const base = fsmod.basename(parent_path);
        const parent_suffix = ".game__banc__GameBancParam.gyml";
        if (!std.mem.endsWith(u8, base, parent_suffix)) break;
        current = base[0 .. base.len - parent_suffix.len];
    }
    // a scene that doesn't say is a child scene (the child versions leave IsChildWhenChangeBanc out)
    if (forces orelse false) return .{ .forced = if (child orelse true) .child else .adult };
    return .{ .forced = null };
}

pub const StartSpot = struct {
    name: []const u8,
    position: [3]f32,
    facing_radians: f32,
};

/// The scene's start spots (StartPos.byml: scene -> spot -> {Trans, Rot}), in the table's order.
pub fn startSpots(allocator: Allocator, world: *World, scene: []const u8) PatchError![]const StartSpot {
    return spotsIn(allocator, try startSpotTable(allocator, world), scene);
}

/// Like startSpots, from a start spot table already read (the catalog reads it once for every scene).
fn spotsIn(allocator: Allocator, table: *byml.Dict, scene: []const u8) PatchError![]const StartSpot {
    const spots = table.getDict(scene) orelse return &.{};
    var out: std.ArrayList(StartSpot) = .empty;
    for (spots.entries.items) |entry| {
        const spot = entry.value.asDict() orelse continue;
        try out.append(allocator, .{
            .name = entry.key,
            .position = vector(spot.getArray("Trans")),
            .facing_radians = vector(spot.getArray("Rot"))[1],
        });
    }
    return out.items;
}

fn startSpotTable(allocator: Allocator, world: *World) PatchError!*byml.Dict {
    const file = world.readZs(allocator, start_spot_table) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidData => return error.InvalidData,
        else => return error.GameFiles,
    };
    return byml.loadDict(allocator, file.data) catch error.InvalidData;
}

fn vector(array: ?*byml.Array) [3]f32 {
    var out = [3]f32{ 0, 0, 0 };
    const values = array orelse return out;
    for (values.items.items, 0..) |v, k| {
        if (k >= 3) break;
        out[k] = @floatCast(v.asFloat() orelse 0);
    }
    return out;
}

fn findSpot(spots: []const StartSpot, name: []const u8) ?StartSpot {
    for (spots) |spot| if (std.mem.eql(u8, spot.name, name)) return spot;
    return null;
}

fn spotNames(allocator: Allocator, spots: []const StartSpot) PatchError![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (spots) |spot| try names.append(allocator, if (spot.name.len > 0) spot.name else "(unnamed)");
    return std.mem.join(allocator, ", ", names.items);
}

/// The EventSetting rows (each event the game can start by name), as (row id, flow file).
pub const EventRow = struct { id: []const u8, flow: []const u8 };

pub fn eventRows(allocator: Allocator, world: *World) PatchError![]const EventRow {
    const rows = try tableRows(allocator, world, "EventSetting");
    var out: std.ArrayList(EventRow) = .empty;
    for (rows) |row_value| {
        const row = row_value.asDict() orelse continue;
        const id = row.getString("__RowId") orelse continue;
        const flow = fsmod.basename(row.getString("FlowchartFileName") orelse "");
        try out.append(allocator, .{ .id = id, .flow = if (std.mem.indexOfScalar(u8, flow, '.')) |dot| flow[0..dot] else flow });
    }
    return out.items;
}

fn bootEventExists(allocator: Allocator, world: *World, name: []const u8) PatchError!bool {
    for (try eventRows(allocator, world)) |row| if (std.mem.eql(u8, row.id, name)) return true;
    return false;
}

/// The rows of RSDB table `prefix` (e.g. "EventSetting" for RSDB/EventSetting.Product.111.rstbl.byml.zs).
fn tableRows(allocator: Allocator, world: *World, prefix: []const u8) PatchError![]const byml.Value {
    const dotted = try std.fmt.allocPrint(allocator, "{s}.", .{prefix});
    const rel = try world.find(allocator, "RSDB", dotted);
    const file = try world.readZs(allocator, rel);
    const doc = byml.load(allocator, file.data) catch return error.InvalidData;
    const root = doc.root orelse return error.InvalidData;
    return switch (root) {
        .array => |rows| rows.items.items,
        else => error.InvalidData,
    };
}

/// The quests (RSDB Challenge rows, whose ids are paths: "Work/Challenge/DoorOfTime.game__challenge__Challenge.gyml"
/// is quest DoorOfTime), in the table's order.
pub fn questNames(allocator: Allocator, world: *World) PatchError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try tableRows(allocator, world, "Challenge")) |row_value| {
        const row = row_value.asDict() orelse continue;
        const file = fsmod.basename(row.getString("__RowId") orelse continue);
        try out.append(allocator, if (std.mem.indexOfScalar(u8, file, '.')) |dot| file[0..dot] else file);
    }
    return out.items;
}

// ----------------------------------------------------------------------------------------------- names, values

/// The Enum value named `name` (any letter case), as the game writes it.
fn valueNamed(values: []const byml.Value, name: []const u8) ?[]const u8 {
    for (values) |v| {
        const s = v.asString() orelse continue;
        if (std.ascii.eqlIgnoreCase(s, name)) return s;
    }
    return null;
}

fn joinValueNames(allocator: Allocator, values: []const byml.Value) PatchError![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (values) |v| try names.append(allocator, v.asString() orelse continue);
    return std.mem.join(allocator, ", ", names.items);
}

fn wrongKind(allocator: Allocator, name: []const u8, kind: gamedata.RowKind, wanted: []const u8) PatchError![]const u8 {
    const what = switch (kind) {
        .Bool => "true/false",
        .Int => "a whole number",
        .Enum => "a quoted value name",
        else => "a kind of flag a test plan can't set",
    };
    return std.fmt.allocPrint(allocator, "[flags] {s} takes {s}, not {s}", .{ name, what, wanted });
}

fn flagValueText(allocator: Allocator, value: testplan.FlagValue) PatchError![]const u8 {
    return switch (value) {
        .boolean => |b| if (b) "true" else "false",
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .enum_value => |s| s,
    };
}

/// The item with key or name `name` (as the spoiler log shows it; any letter case). An item no check holds (not in
/// the item table yet) is found by its key when the game has its Item_<key> actor.
pub fn findItem(allocator: Allocator, world: *World, name: []const u8) PatchError!?ItemId {
    if (world.items.lookup(name)) |id| return id;
    for (0..world.items.count()) |i| {
        const id: ItemId = @intCast(i);
        if (std.ascii.eqlIgnoreCase(world.items.name(id), name)) return id;
        if (std.ascii.eqlIgnoreCase(try world.itemNameById(allocator, id), name)) return id;
    }
    const actor = try std.fmt.allocPrint(allocator, "Item_{s}", .{name});
    if (world.actorExists(actor)) return try world.items.intern(name);
    return null;
}

fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

fn appendLine(allocator: Allocator, lines: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) PatchError!void {
    try lines.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

// --------------------------------------------------------------------------------------------- the opening edit

/// OpeningEvent with `start` just before its autosave (see the top of the file). Refused when it is empty or the
/// opening already has a start added.
pub fn startAtSpawn(allocator: Allocator, data: []const u8, start: OpeningStart, progress: *Progress) PatchError!SpawnResult {
    if (start.isEmpty()) return progress.fail(error.NotAsExpected, "nothing to add to the opening", .{});
    var doc = try evfl.read(allocator, data);
    const fc = try flows.expectFlowchart(&doc, "OpeningEvent", progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, added_prefix)) return progress.fail(error.NotAsExpected, "a start is already in the opening", .{});
    }

    // the one autosave, reached from one event: the opening's own last step, or the last start item (an added pouch
    // action, or a gift's sub flow call)
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
    if (before.len != 1 or fc.events.items[before[0]].nextPtr() == null) {
        return progress.fail(error.NotAsExpected, "the opening's autosave is not reached by one event", .{});
    }

    const warp_boot: []const u8 = if (start.warp) |w| w.boot_event else "";

    // built from the autosave backwards: each new event leads to the one added before it
    var next: u16 = save.?;
    if (start.open_important_menu and start.warp == null) {
        try flows.ensureSystemActor(fc, allocator, "UISystemActor", opening_flow, progress);
        const menu_aa = try flows.requireAction(fc, allocator, "UISystemActor", "EventOpenPerformanceImportantMenu", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_MedallionsMenu", menu_aa, next, try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        })));
    }
    // the adult start: its start items move out of the introduction's end (faststart.giveAtStart put them before the
    // autosave) into its own order; the ones with an item window come after the fade-in
    const items_run: ?Run = if (start.in_place != null) namedRun(fc, "RandoStartItem") else null;
    if (start.in_place != null) {
        if (namedRun(fc, "RandoStartGift")) |gifts| {
            fc.events.items[gifts.last].nextPtr().?.* = next;
            next = gifts.first;
        }
        try flows.ensureSystemActor(fc, allocator, "UISystemActor", opening_flow, progress);
        const fade_aa = try flows.requireAction(fc, allocator, "UISystemActor", "EventEventFadeIn", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_FadeIn", fade_aa, next, try Container.from(allocator, &.{
            .{ .name = "Length", .value = .{ .int = 1 } },
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        })));
        // a moment for the area around the new spot, as faststart.startOutside waits
        const wait_aa = try flows.requireAction(fc, allocator, "EventSystemActor", "EventWait", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_Wait", wait_aa, next, try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "Frames", .value = .{ .int = 30 } },
        })));
    }
    if (start.warp) |w| {
        const change_aa = try flows.requireAction(fc, allocator, "GameSystemActor", "EventReserveBancChange", progress);
        const position = allocator.alloc(f32, 3) catch return error.OutOfMemory;
        @memcpy(position, &w.position);
        const rotation = allocator.alloc(f32, 3) catch return error.OutOfMemory;
        rotation[0] = 0;
        rotation[1] = w.facing_degrees;
        rotation[2] = 0;
        var params: std.ArrayList(evfl.Item) = .empty;
        params.appendSlice(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "NextBanc", .value = .{ .string = w.scene } },
            .{ .name = "NextStartPos", .value = .{ .string = w.start_spot } },
            .{ .name = "NextPosition", .value = .{ .float_array = position } },
            .{ .name = "NextStartRot", .value = .{ .float_array = rotation } },
            .{ .name = "FadePattern", .value = .{ .int = w.fade_pattern } },
        }) catch return error.OutOfMemory;
        if (warp_boot.len > 0) params.append(allocator, .{ .name = "BootEventName", .value = .{ .string = warp_boot } }) catch return error.OutOfMemory;
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_Warp", change_aa, next, try Container.from(allocator, params.items)));
        if (w.childhood) |is_child| next = try setFlag(fc, allocator, "Age", childhood_flag, is_child, next, progress);
    }
    var k = start.equip.len;
    while (k > 0) {
        k -= 1;
        try flows.ensureSystemActor(fc, allocator, "PouchSystemActor", opening_flow, progress);
        const pouch_aa = try flows.requireAction(fc, allocator, "PouchSystemActor", "EventTriggerAddOrRemovePouchContent", progress);
        const name = std.fmt.allocPrint(allocator, "{s}_Equip{d}", .{ added_prefix, k }) catch return error.OutOfMemory;
        // as DoorOfTime:Event115 adds the Master Sword
        next = try fc.addEvent(allocator, evfl.makeAction(name, pouch_aa, next, try Container.from(allocator, &.{
            .{ .name = "Num", .value = .{ .int = 1 } },
            .{ .name = "IsSetMessageTargetActorName", .value = .{ .bool = true } },
            .{ .name = "Actor", .value = .{ .string = start.equip[k] } },
            .{ .name = "IsEquipDIrect", .value = .{ .bool = true } },
        })));
    }
    if (start.in_place) |place| {
        // Link and Navi to the adult start's spot (before the sword: it is equipped where he stands)
        const link_pos = allocator.alloc(f32, 3) catch return error.OutOfMemory;
        const navi_pos = allocator.alloc(f32, 3) catch return error.OutOfMemory;
        for (0..3) |i| {
            link_pos[i] = place.position[i];
            navi_pos[i] = place.position[i] + navi_offset[i];
        }
        const navi_aa = try flows.requireAction(fc, allocator, "Npc_Navi", "EventTriggerNaviWarpToTargetPosAndRot", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_Navi", navi_aa, next, try Container.from(allocator, &.{
            .{ .name = "Position", .value = .{ .float_array = navi_pos } },
            .{ .name = "ClothWarpMode", .value = .{ .int = -1 } },
            .{ .name = "YAngle", .value = .{ .float = place.facing_degrees } },
        })));
        const link_aa = try flows.requireAction(fc, allocator, "Player_Event", "EventPlayerWarpToTargetPosAndRot", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_Link", link_aa, next, try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "UseDemoWait", .value = .{ .bool = true } },
            .{ .name = "YAngle", .value = .{ .float = place.facing_degrees } },
            .{ .name = "Position", .value = .{ .float_array = link_pos } },
            .{ .name = "ASCommand", .value = .{ .string = "EvtWait" } },
        })));
    }
    k = start.flags.len;
    while (k > 0) {
        k -= 1;
        const suffix = std.fmt.allocPrint(allocator, "Flag{d}", .{k}) catch return error.OutOfMemory;
        next = try setFlag(fc, allocator, suffix, start.flags[k].name, start.flags[k].value, next, progress);
    }
    k = start.quest_steps.len;
    while (k > 0) {
        k -= 1;
        const step_aa = try flows.requireAction(fc, allocator, "ChallengeSystemActor", "EventExecuteProgressChallengeStep", progress);
        const name = std.fmt.allocPrint(allocator, "{s}_Quest{d}", .{ added_prefix, k }) catch return error.OutOfMemory;
        next = try fc.addEvent(allocator, evfl.makeAction(name, step_aa, next, try Container.from(allocator, &.{
            .{ .name = "ChallengeName", .value = .{ .string = start.quest_steps[k].quest } },
            .{ .name = "StepName", .value = .{ .string = start.quest_steps[k].step } },
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        })));
    }
    if (start.time_hour) |hour| {
        // the opening already has this actor (Event9 sets 6:00); the added call comes later, so it wins
        const time_aa = try flows.requireAction(fc, allocator, "EventWorldManagerController", "EventTrigger_SetTime", progress);
        next = try fc.addEvent(allocator, evfl.makeAction(added_prefix ++ "_Time", time_aa, next, try Container.from(allocator, &.{
            .{ .name = "TimeHour", .value = .{ .int = hour } },
        })));
    }
    if (start.in_place != null) {
        if (items_run) |items| {
            fc.events.items[items.last].nextPtr().?.* = next;
            next = items.first;
        }
        try adultInPlace(allocator, fc, next, progress);
        return .{ .data = try flows.writeBack(allocator, &doc, "OpeningEvent (adult start)", progress) };
    }
    fc.events.items[before[0]].nextPtr().?.* = next;
    return .{ .data = try flows.writeBack(allocator, &doc, "OpeningEvent (start)", progress) };
}

/// A run of added events named <prefix>0, <prefix>1, ... (faststart.giveAtStart chains them in that order).
const Run = struct { first: u16, last: u16 };

fn namedRun(fc: *evfl.Flowchart, prefix: []const u8) ?Run {
    var first: ?u16 = null;
    var last: ?u16 = null;
    var last_number: usize = 0;
    var count: usize = 0;
    for (fc.events.items, 0..) |e, i| {
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        const number = std.fmt.parseInt(usize, e.name[prefix.len..], 10) catch continue;
        count += 1;
        if (number == 0) first = @intCast(i);
        if (last == null or number > last_number) {
            last = @intCast(i);
            last_number = number;
        }
    }
    if (count == 0) return null;
    return .{ .first = first orelse return null, .last = last orelse return null };
}

/// The adult start in its own area (see "Starting Age: Adult"): the loading entry ends on its black loading screen
/// close, and the introduction goes from its time step to `chain` (the adult start's steps up to the autosave). The
/// introduction's other events stay in the file, unreached.
fn adultInPlace(allocator: Allocator, fc: *evfl.Flowchart, chain: u16, progress: *Progress) PatchError!void {
    const loading = fc.entryPoint("Opening_LoadingKokiriForest") orelse return progress.fail(error.NotAsExpected, "no Opening_LoadingKokiriForest entry", .{});
    const close = try onlyReached(allocator, fc, loading.main_event, "UISystemActor", "EventLoadingFadeOut", "the loading screen close", progress);
    fc.events.items[close].nextPtr().?.* = NONE;

    const intro = fc.entryPoint("Opening_Introduction") orelse return progress.fail(error.NotAsExpected, "no Opening_Introduction entry", .{});
    const time = try onlyReached(allocator, fc, intro.main_event, "EventWorldManagerController", "EventTrigger_SetTime", "the introduction's time step", progress);
    fc.events.items[time].nextPtr().?.* = chain;
}

/// The one action `actor`.`action` reached from `start` (`what` names it in the error).
fn onlyReached(allocator: Allocator, fc: *evfl.Flowchart, start: u16, actor: []const u8, action: []const u8, what: []const u8, progress: *Progress) PatchError!u16 {
    const reached = try fc.reach(allocator, start);
    var found: ?u16 = null;
    var count: usize = 0;
    for (reached, 0..) |r, i| {
        if (r and fc.isAction(&fc.events.items[i], actor, action)) {
            found = @intCast(i);
            count += 1;
        }
    }
    if (count != 1) return progress.fail(error.NotAsExpected, "expected one {s} in the opening, found {d}", .{ what, count });
    return found.?;
}

/// GameDataActor.EventTriggerSetGameDataBool {name = value} -> `then`. Returns the new event.
fn setFlag(fc: *evfl.Flowchart, allocator: Allocator, suffix: []const u8, name: []const u8, value: bool, then: u16, progress: *Progress) PatchError!u16 {
    try flows.ensureSystemActor(fc, allocator, "GameDataActor", opening_flow, progress);
    const set_aa = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataBool", progress);
    const event_name = std.fmt.allocPrint(allocator, "{s}_{s}", .{ added_prefix, suffix }) catch return error.OutOfMemory;
    return fc.addEvent(allocator, evfl.makeAction(event_name, set_aa, then, try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = name } },
        .{ .name = "Index", .value = .{ .int = -1 } },
        .{ .name = "Value", .value = .{ .bool = value } },
    })));
}

// ---------------------------------------------------------------------------------------------------- catalog

/// The names a test plan can use, read from this game: the window's Test Seeds tab offers them in its pickers and
/// `goggles_cli test-catalog` writes them out (writeCatalog). Every string is a copy in memory from the allocator,
/// so the catalog outlives the scanned game (the window keeps it after opening another game).
pub const Catalog = struct {
    pub const Scene = struct {
        name: []const u8,
        /// the age Link takes in it, or null when he keeps the plan's
        forced_age: ?testplan.Age,
        spots: []const StartSpot,
    };
    pub const Quest = struct {
        name: []const u8,
        steps: []const []const u8,
    };
    pub const Item = struct {
        /// as the spoiler log names it
        name: []const u8,
        key: []const u8,
    };
    /// A save flag a test plan can set ([flags]): true/false, a whole number, or one of an Enum's value names.
    pub const Flag = struct {
        name: []const u8,
        kind: FlagKind,
        /// an Enum flag's value names, in order (empty for the others)
        values: []const []const u8,
    };
    pub const FlagKind = enum { boolean, integer, enumeration };

    scenes: []const Scene,
    /// boot_event candidates: every EventSetting row and its flow
    events: []const EventRow,
    quests: []const Quest,
    /// the cutscenes (Dm_ events) the game remembers as played
    cutscenes: []const EventRow,
    locations: []const []const u8,
    items: []const Item,
    /// sorted by name (flagNames)
    flags: []const Flag,
};

pub fn buildCatalog(allocator: Allocator, world: *World) PatchError!Catalog {
    const scene_names = try sceneNames(allocator, world);
    const spot_table = try startSpotTable(allocator, world);
    const scenes = try allocator.alloc(Catalog.Scene, scene_names.len);
    for (scene_names, 0..) |scene, i| {
        const spots = try allocator.dupe(StartSpot, try spotsIn(allocator, spot_table, scene));
        for (spots) |*spot| spot.name = try allocator.dupe(u8, spot.name);
        scenes[i] = .{
            .name = try allocator.dupe(u8, scene),
            .forced_age = (try ageRule(allocator, world, scene)).forced,
            .spots = spots,
        };
    }

    const events = try allocator.dupe(EventRow, try eventRows(allocator, world));
    for (events) |*row| row.* = .{ .id = try allocator.dupe(u8, row.id), .flow = try allocator.dupe(u8, row.flow) };
    const probe = try gamedata.probeOf(world);
    var quests: std.ArrayList(Catalog.Quest) = .empty;
    for (try questNames(allocator, world)) |quest| {
        const enum_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ quest_enum_prefix, quest });
        const values = probe.enumValueNames(enum_name) orelse continue;
        var steps: std.ArrayList([]const u8) = .empty;
        for (values) |v| try steps.append(allocator, try allocator.dupe(u8, v.asString() orelse continue));
        try quests.append(allocator, .{ .name = try allocator.dupe(u8, quest), .steps = steps.items });
    }

    // the game keeps a "played" flag for nearly every event; the Dm_ ones are its cutscenes
    var cutscenes: std.ArrayList(EventRow) = .empty;
    var listed = std.StringHashMap(void).init(allocator);
    for (events) |row| {
        if (listed.contains(row.id) or !std.mem.startsWith(u8, row.id, "Dm_")) continue;
        const flag = try std.fmt.allocPrint(allocator, "{s}{s}", .{ played_prefix, row.id });
        if (probe.flagKind(flag) != .Bool) continue;
        listed.put(row.id, {}) catch return error.OutOfMemory;
        try cutscenes.append(allocator, row);
    }

    const locations = try allocator.alloc([]const u8, world.locations.items.len);
    for (world.locations.items, 0..) |loc, i| locations[i] = try allocator.dupe(u8, loc.name);
    const items = try allocator.alloc(Catalog.Item, world.items.count());
    for (items, 0..) |*item, i| {
        const id: ItemId = @intCast(i);
        item.* = .{ .name = try allocator.dupe(u8, try world.itemNameById(allocator, id)), .key = try allocator.dupe(u8, world.items.name(id)) };
    }
    return .{
        .scenes = scenes,
        .events = events,
        .quests = quests.items,
        .cutscenes = cutscenes.items,
        .locations = locations,
        .items = items,
        .flags = try settableFlags(allocator, world, events),
    };
}

/// The folders whose files name save flags (most flags are named in event flows; the rest in logic modules,
/// sequences, AI schedules and the scenes' area files). Each Banc scene folder is read too.
const flag_name_folders = [_][]const u8{ "Event/EventFlow", "Logic", "Sequence", "Component/AIScheduleParam" };

/// Every save flag a test plan can set, by name. Why read so many files: the save data keeps flags only by hash
/// (murmur3), so names are found by hashing every name-like string in the game's files and keeping those the
/// save data has, plus the names the game builds itself ("HavePlayedEvent.<event>", "IsGet.<actor>").
fn settableFlags(allocator: Allocator, world: *World, events: []const EventRow) PatchError![]const Catalog.Flag {
    const probe = try gamedata.probeOf(world);
    var candidates = std.StringHashMap(void).init(allocator);
    defer candidates.deinit();
    var scratch = std.heap.ArenaAllocator.init(world.gpa);
    defer scratch.deinit();

    var folders: std.ArrayList([]const u8) = .empty;
    try folders.appendSlice(allocator, &flag_name_folders);
    const scene_folders = world.files.listDir(allocator, "Banc") catch &.{};
    for (scene_folders) |scene| try folders.append(allocator, try std.fmt.allocPrint(allocator, "Banc/{s}", .{scene}));
    // "Group.<scene>.Field" names (DungeonInfo.ForestTemple.SmallKeyNum): the game builds them for every scene, so
    // each group and field seen in a file is tried with every scene
    var scene_patterns = std.StringHashMap(void).init(allocator);
    defer scene_patterns.deinit();

    for (folders.items) |folder| {
        // the listing in `allocator`, each file's data in `scratch` (reset for every file)
        const kept = world.files.listDir(allocator, folder) catch continue;
        for (kept) |name| {
            if (!std.mem.endsWith(u8, name, ".zs")) continue;
            _ = scratch.reset(.retain_capacity);
            const rel = try std.fmt.allocPrint(scratch.allocator(), "{s}/{s}", .{ folder, name });
            const data = world.readZs(scratch.allocator(), rel) catch continue;
            try collectNameLikeStrings(allocator, data.data, &candidates, &scene_patterns, probe);
        }
    }
    // a field no file writes out in full (DungeonInfo.<scene>.SmallKeyNum) isn't found: the Test Seeds tab and
    // [flags] still take any name typed in
    var buf: [256]u8 = undefined;
    var patterns = scene_patterns.keyIterator();
    while (patterns.next()) |pattern| {
        const dot = std.mem.indexOfScalar(u8, pattern.*, '.').?;
        for (scene_folders) |scene| {
            const name = std.fmt.bufPrint(&buf, "{s}.{s}.{s}", .{ pattern.*[0..dot], scene, pattern.*[dot + 1 ..] }) catch continue;
            try addCandidate(allocator, &candidates, probe, name);
        }
    }
    for (events) |row| try addCandidate(allocator, &candidates, probe, try std.fmt.allocPrint(allocator, "{s}{s}", .{ played_prefix, row.id }));
    var actors = world.actor_packs.keyIterator();
    while (actors.next()) |actor| try addCandidate(allocator, &candidates, probe, try std.fmt.allocPrint(allocator, "IsGet.{s}", .{actor.*}));

    var flags: std.ArrayList(Catalog.Flag) = .empty;
    var it = candidates.keyIterator();
    while (it.next()) |name| {
        const kind: Catalog.FlagKind = switch (probe.flagKind(name.*) orelse continue) {
            .Bool => .boolean,
            .Int => .integer,
            .Enum => .enumeration,
            else => continue,
        };
        var values: std.ArrayList([]const u8) = .empty;
        if (kind == .enumeration) {
            for (probe.enumValueNames(name.*) orelse &.{}) |v| try values.append(allocator, try allocator.dupe(u8, v.asString() orelse continue));
        }
        try flags.append(allocator, .{ .name = name.*, .kind = kind, .values = values.items });
    }
    std.mem.sort(Catalog.Flag, flags.items, {}, struct {
        fn less(_: void, x: Catalog.Flag, y: Catalog.Flag) bool {
            return std.ascii.orderIgnoreCase(x.name, y.name) == .lt;
        }
    }.less);
    return flags.items;
}

/// Adds every run of name characters (letters, digits, '_', '.', '$', '-') in `data` that the save data knows as a
/// settable flag. Names are copied with `allocator`.
/// A run "Group.Middle.Field" also adds "Group.Field" to `scene_patterns` (see settableFlags).
fn collectNameLikeStrings(allocator: Allocator, data: []const u8, candidates: *std.StringHashMap(void), scene_patterns: *std.StringHashMap(void), probe: *gamedata.GameDataPatcher) PatchError!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= data.len) : (i += 1) {
        const in_name = i < data.len and (std.ascii.isAlphanumeric(data[i]) or data[i] == '_' or data[i] == '.' or data[i] == '$' or data[i] == '-');
        if (in_name) continue;
        const run = data[start..i];
        start = i + 1;
        if (run.len < 4 or run.len > 120) continue;
        if (std.mem.count(u8, run, ".") == 2) {
            const first = std.mem.indexOfScalar(u8, run, '.').?;
            const last = std.mem.lastIndexOfScalar(u8, run, '.').?;
            if (first > 0 and last + 1 < run.len) {
                var buf: [128]u8 = undefined;
                const pattern = std.fmt.bufPrint(&buf, "{s}.{s}", .{ run[0..first], run[last + 1 ..] }) catch continue;
                if (!scene_patterns.contains(pattern)) scene_patterns.put(try allocator.dupe(u8, pattern), {}) catch return error.OutOfMemory;
            }
        }
        if (candidates.contains(run)) continue;
        try addCandidate(allocator, candidates, probe, run);
    }
}

fn addCandidate(allocator: Allocator, candidates: *std.StringHashMap(void), probe: *gamedata.GameDataPatcher, name: []const u8) PatchError!void {
    const kind = probe.flagKind(name) orelse return;
    if (kind != .Bool and kind != .Int and kind != .Enum) return;
    if (candidates.contains(name)) return;
    candidates.put(try allocator.dupe(u8, name), {}) catch return error.OutOfMemory;
}

/// Writes the names a test plan can use into `out_folder`: scenes.txt, start_spots.txt, boot_events.txt,
/// quests.txt, cutscenes.txt, locations.txt, items.txt and flags.txt. Returns the files written.
pub fn writeCatalog(allocator: Allocator, world: *World, fs: fsmod.Fs, out_folder: []const u8) PatchError![]const []const u8 {
    fs.makePath(out_folder) catch return error.GameFiles;
    var written: std.ArrayList([]const u8) = .empty;
    const header = "# Made by goggles_cli test-catalog from this game. Names for test plans (test_plans/TEMPLATE.test.toml).\n";
    const catalog = try buildCatalog(allocator, world);
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# scene    age (\"either\": Link keeps the age the plan gives)    start spots\n\n");
        for (catalog.scenes) |scene| {
            try text.print(allocator, "{s}    {s}    {d}\n", .{ scene.name, if (scene.forced_age) |age| @tagName(age) else "either", scene.spots.len });
        }
        try writeCatalogFile(allocator, fs, out_folder, "scenes.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [scene]  start_spot    position [x, y, z]    facing (degrees)\n");
        for (catalog.scenes) |scene| {
            if (scene.spots.len == 0) continue;
            try text.print(allocator, "\n[{s}]\n", .{scene.name});
            for (scene.spots) |spot| {
                try text.print(allocator, "{s}    [{d:.3}, {d:.3}, {d:.3}]    {d:.1}\n", .{
                    if (spot.name.len > 0) spot.name else "(unnamed: use its position)",
                    spot.position[0],
                    spot.position[1],
                    spot.position[2],
                    std.math.radiansToDegrees(spot.facing_radians),
                });
            }
        }
        try writeCatalogFile(allocator, fs, out_folder, "start_spots.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# boot_event    the event flow it is in\n\n");
        for (catalog.events) |row| try text.print(allocator, "{s}    {s}\n", .{ row.id, row.flow });
        try writeCatalogFile(allocator, fs, out_folder, "boot_events.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [quests] quest = \"step\": a quest and its steps, in order\n\n");
        for (catalog.quests) |quest| try text.print(allocator, "{s}    {s}\n", .{ quest.name, try std.mem.join(allocator, ", ", quest.steps) });
        try writeCatalogFile(allocator, fs, out_folder, "quests.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [cutscenes] seen / unseen: the cutscenes (Dm_ events) the game remembers as played\n");
        try text.appendSlice(allocator, "# (most other events in boot_events.txt have a played flag too and can be listed the same way)\n\n");
        for (catalog.cutscenes) |row| try text.print(allocator, "{s}    {s}\n", .{ row.id, row.flow });
        try writeCatalogFile(allocator, fs, out_folder, "cutscenes.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [place] \"location\" = \"item\": every location (whether it is shuffled depends on the settings)\n\n");
        for (catalog.locations) |name| try text.print(allocator, "{s}\n", .{name});
        try writeCatalogFile(allocator, fs, out_folder, "locations.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# item name (for [place] and [start] items)    its key (also accepted)\n\n");
        for (catalog.items) |item| try text.print(allocator, "{s}    {s}\n", .{ item.name, item.key });
        try writeCatalogFile(allocator, fs, out_folder, "items.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [flags] \"flag\" = value: the save flags whose names were found in the game's files\n");
        try text.appendSlice(allocator, "# flag    true/false, a whole number, or one of the listed value names\n\n");
        for (catalog.flags) |flag| switch (flag.kind) {
            .boolean => try text.print(allocator, "{s}    true/false\n", .{flag.name}),
            .integer => try text.print(allocator, "{s}    a whole number\n", .{flag.name}),
            .enumeration => try text.print(allocator, "{s}    {s}\n", .{ flag.name, try std.mem.join(allocator, ", ", flag.values) }),
        };
        try writeCatalogFile(allocator, fs, out_folder, "flags.txt", text.items, &written);
    }
    return written.items;
}

fn writeCatalogFile(allocator: Allocator, fs: fsmod.Fs, folder: []const u8, name: []const u8, text: []const u8, written: *std.ArrayList([]const u8)) PatchError!void {
    const path = try fsmod.join(allocator, &.{ folder, name });
    fs.writeAll(path, text) catch return error.GameFiles;
    try written.append(allocator, path);
}

// --------------------------------------------------------------------------------------------------------- tests

test "the test start goes before the opening's autosave" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();

    // a small opening: Navi talks (0) -> autosave (1)
    var opening = evfl.Flowchart{ .name = "OpeningEvent" };
    const fc = &opening;
    var game_system = evfl.Actor{ .name = "GameSystemActor", .params = try Container.create(a) };
    try game_system.actions.append(a, "EventTriggerRequestAutoSave");
    try fc.actors.append(a, game_system);
    var world_manager = evfl.Actor{ .name = "EventWorldManagerController", .params = try Container.create(a) };
    try world_manager.actions.append(a, "EventTrigger_SetTime");
    try fc.actors.append(a, world_manager);
    _ = try fc.addEvent(a, evfl.makeAction("Event10", .{ 1, 0 }, 1, null));
    _ = try fc.addEvent(a, evfl.makeAction("Event12", .{ 0, 0 }, evfl.NONE, null));
    try fc.entry_points.append(a, .{ .name = "Opening_Introduction", .main_event = 0 });
    const doc = evfl.Document{ .name = "OpeningEvent", .flowchart = fc };
    const original = try evfl.write(a, &doc);

    const warp = Warp{
        .scene = "ForestTemple",
        .start_spot = "",
        .position = .{ 1, 2, 3 },
        .facing_degrees = 90,
        .boot_event = "SomeEvent",
        .childhood = false,
    };
    const patched = (try startAtSpawn(a, original, .{ .warp = warp, .time_hour = 20 }, &progress)).data;
    const back = try evfl.read(a, patched);
    const out = back.flowchart.?;
    // Event10 -> time -> age -> warp -> autosave
    var at = out.events.items[0].kind.action.next;
    const expected = [_][]const u8{ "RandoTestStart_Time", "RandoTestStart_Age", "RandoTestStart_Warp", "Event12" };
    for (expected) |name| {
        try std.testing.expectEqualStrings(name, out.events.items[at].name);
        if (out.events.items[at].kind.action.next == evfl.NONE) break;
        at = out.events.items[at].kind.action.next;
    }
    const warp_event = out.events.items[out.events.items[out.events.items[out.events.items[0].kind.action.next].kind.action.next].kind.action.next];
    const params = warp_event.params().?;
    try std.testing.expect(params.isString("NextBanc", "ForestTemple"));
    try std.testing.expect(params.isString("BootEventName", "SomeEvent"));
    try std.testing.expect(out.findActor("GameDataActor") != null);
    // a second edit is refused
    try std.testing.expectError(error.NotAsExpected, startAtSpawn(a, patched, .{ .warp = warp }, &progress));
}

test "Enum values are matched in any letter case" {
    const values = [_]byml.Value{ .{ .string = "NotReady" }, .{ .string = "Complete" } };
    try std.testing.expectEqualStrings("Complete", valueNamed(&values, "complete").?);
    try std.testing.expect(valueNamed(&values, "Step01") == null);
    try std.testing.expectEqualStrings("KokiriForest", familyOf("KokiriForest_Adult"));
    try std.testing.expectEqualStrings("ForestTemple", familyOf("ForestTemple"));
}
