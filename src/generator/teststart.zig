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
/// the events giveOnArrival adds
const arrival_prefix = "RandoAdultArrival";
/// the gift call the game's NPC and check flows use (faststart.giveAtStart hands the start items over with it)
const gift_flow = "GetPouchContent";
const gift_entry = "GetPouchContentByActorName";
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

/// Where an adult start's gifts go: `entry` of `flowchart` (file `flow`), an event the game itself boots on arriving
/// in adult Castle Town, which giveOnArrival turns into: play `scene`, fade in, hand the gifts over, autosave.
pub const Arrival = struct { flow: []const u8, flowchart: []const u8, entry: []const u8, scene: []const u8 };

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
    /// the adult start's layout (see "Starting Age: Adult"): no child opening; the change boots `arrival.scene`
    arrival: ?Arrival = null,
    /// the change boots `arrival.entry` instead (it has gifts to hand over after the scene: giveOnArrival)
    arrival_boots_entry: bool = false,

    pub fn isEmpty(self: OpeningStart) bool {
        return self.warp == null and self.time_hour == null and self.quest_steps.len == 0 and self.flags.len == 0 and self.equip.len == 0;
    }
};

// ------------------------------------------------------------------------------------- Starting Age: Adult
// As OotrR does it (src/oot_rando/patching/adult_start.py, MIT License, Copyright (c) 2026 Mozencaz): the new game
// still loads Kokiri Forest, then the opening moves the Sheik and Forest quests to Step01 (without AllSage past Ready
// Sheik stands by the pedestal and blocks putting the sword back), marks the first trip to adult as made, and
// changes to adult Castle Town with the game's own time-travel values (Market_Child_Field_ChildToAdult: the
// platform in the Temple of Time, NextStartRot [0, 90, 0], white fade), starting Dm_TimeTemple_0085 (Link at the
// pedestal). The Master Sword is added and equipped as the Door of Time flow does. The Door of Time is opened
// (door.zig) and the save data has the rest (adultStartChanges).
//
// So that a new game doesn't show child Link first (test report, FEAT_ADULT1: he appeared outside the Kokiri Shop,
// got the start items' windows, then warped), the adult start (OpeningStart.arrival) also:
// - leaves out Kokiri Forest's fade-in (Opening_LoadingKokiriForest's EventEventFadeIn), so the screen stays black;
// - cuts the opening's introduction after its Meet_DekuTree step, as OotrR does (its anchor, OpeningEvent:Event8):
//   the start outside the shop, Navi, the camera and the fade-in don't play; the silent start items (ocarinas, the
//   base bags) and the adult start's steps follow at once, then the scene change and the autosave;
// - hands the start items that show an item window (Skip Child Zelda's checks, Rauru's check...) over after the
//   sword pull instead. The change then boots AllSage:Market_Adult_AllSage_Start, the event the game itself boots
//   on the first arrival as adult (DoorOfTime:Event96), so its RSDB rows already exist; giveOnArrival makes that
//   entry play Dm_TimeTemple_0085 (the scene the change boots without gifts), fade in, hand the gifts over and
//   autosave, and addArrivalScene lists the scene in its GameAnalyzedEventInfo row (patches.zig lists the gift
//   flow). The adult start's save data has already made the native first-arrival scenes count as done, and
//   nothing else boots that entry once the Door of Time's first pull is skipped (adult_start_changes).
//   Why not a new entry of OpeningEvent with new RSDB rows (0.8.0-dev f45e6fb): a new game stayed on a black
//   screen (test report, FEAT_ADULT1); its scene had no fade-in after it (FadeInTypeEventEnd), and new event rows
//   had never been tried in-game.
pub const adult_start_warp = Warp{
    .scene = "Market_Adult",
    .start_spot = "",
    .position = .{ 137.2084, 106.1201, -34.0 },
    .facing_degrees = 90,
    .boot_event = "Dm_TimeTemple_0085",
    .childhood = false,
    .fade_pattern = 2,
};
pub const adult_start_quests = [_]QuestProgress{
    .{ .quest = "AllSage", .step = "Step01" },
    .{ .quest = "SageOfForest", .step = "Step01" },
};
pub const adult_start_flags = [_]FlagSet{.{ .name = "Market_Child_Firsttime_GotoAdult", .value = true }};
pub const adult_start_equip = [_][]const u8{"Weapon_Sword_Master"};
pub const adult_start_arrival = Arrival{
    .flow = "Event/EventFlow/AllSage.bfevfl.zs",
    .flowchart = "AllSage",
    .entry = "Market_Adult_AllSage_Start",
    .scene = "Dm_TimeTemple_0085",
};
/// the time travel's fade (white, FadePattern 2), as the native scene transitions after it end (AllSage:Event9)
const arrival_fade_in_type: i32 = 2;

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
    .{ .kind = .bool_flag, .flag = "Market_Child_TimeTempleDoor_Opened" },
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

    // the adult layout: the change boots the arrival entry when it hands gifts over (giveOnArrival)
    var warp_boot: []const u8 = if (start.warp) |w| w.boot_event else "";
    if (start.arrival) |arrival| {
        if (namedRun(fc, "RandoStartGift") != null) return progress.fail(error.NotAsExpected, "an adult start's gifts belong to its arrival, not the opening", .{});
        warp_boot = if (start.arrival_boots_entry) arrival.entry else arrival.scene;
    }

    // built from the autosave backwards: each new event leads to the one added before it
    var next: u16 = save.?;
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
    if (start.arrival != null) {
        try adultLayout(allocator, fc, next, progress);
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

/// The adult layout (see "Starting Age: Adult"): `chain` is the adult start's steps up to the autosave.
fn adultLayout(allocator: Allocator, fc: *evfl.Flowchart, chain: u16, progress: *Progress) PatchError!void {
    // the introduction is cut after its Meet_DekuTree step (OotrR's anchor)
    var anchor: ?u16 = null;
    var anchors: usize = 0;
    for (fc.events.items, 0..) |*e, i| {
        if (!fc.isAction(e, "ChallengeSystemActor", "EventExecuteProgressChallengeStep")) continue;
        const p = e.params() orelse continue;
        if (!p.isString("ChallengeName", "Meet_DekuTree")) continue;
        anchor = @intCast(i);
        anchors += 1;
    }
    if (anchors != 1) return progress.fail(error.NotAsExpected, "expected one Meet_DekuTree step in the opening, found {d}", .{anchors});

    // after it: the silent start items, then the adult start's steps
    var head = chain;
    if (namedRun(fc, "RandoStartItem")) |items| {
        fc.events.items[items.last].nextPtr().?.* = chain;
        head = items.first;
    }
    fc.events.items[anchor.?].nextPtr().?.* = head;

    // Kokiri Forest isn't faded in: the screen stays black until the change
    const loading = fc.entryPoint("Opening_LoadingKokiriForest") orelse return progress.fail(error.NotAsExpected, "no Opening_LoadingKokiriForest entry", .{});
    const reached = try fc.reach(allocator, loading.main_event);
    var fade: ?u16 = null;
    for (reached, 0..) |r, i| {
        if (r and fc.isAction(&fc.events.items[i], "UISystemActor", "EventEventFadeIn")) fade = @intCast(i);
    }
    const fade_in = fade orelse return progress.fail(error.NotAsExpected, "Kokiri Forest's fade-in is not in the opening", .{});
    const after = fc.events.items[fade_in].next() orelse NONE;
    for (try fc.predecessors(allocator, fade_in)) |p| {
        const link = fc.events.items[p].nextPtr() orelse return progress.fail(error.NotAsExpected, "Kokiri Forest's fade-in is reached by a branch", .{});
        link.* = after;
    }
}

/// The arrival flow (`data`, Arrival.flow) with its entry now: play the scene, fade in, hand `gifts` over (one each,
/// with their item window), autosave. The entry's native events stay in the file, unreached.
pub fn giveOnArrival(allocator: Allocator, data: []const u8, arrival: Arrival, gifts: []const []const u8, progress: *Progress) PatchError![]u8 {
    if (gifts.len == 0) return progress.fail(error.NotAsExpected, "no gifts to hand over on arrival", .{});
    var doc = try flows.readFlow(allocator, data, arrival.flowchart, progress);
    const fc = try flows.expectFlowchart(&doc, arrival.flowchart, progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, arrival_prefix)) return progress.fail(error.NotAsExpected, "{s} already hands start items over", .{arrival.flowchart});
    }
    const entry = fc.entryPoint(arrival.entry) orelse return progress.fail(error.NotAsExpected, "{s} has no {s} entry", .{ arrival.flowchart, arrival.entry });

    // built from the end backwards: each new event leads to the one added before it
    try flows.ensureSystemActor(fc, allocator, "GameSystemActor", arrival.flow, progress);
    const save_aa = try flows.requireAction(fc, allocator, "GameSystemActor", "EventTriggerRequestAutoSave", progress);
    var next = try fc.addEvent(allocator, evfl.makeAction(arrival_prefix ++ "_Save", save_aa, NONE, null));
    var gift_events: std.ArrayList(u16) = .empty;
    var k = gifts.len;
    while (k > 0) {
        k -= 1;
        const name = std.fmt.allocPrint(allocator, "{s}_Gift{d}", .{ arrival_prefix, k }) catch return error.OutOfMemory;
        next = try fc.addEvent(allocator, evfl.makeSubFlow(name, gift_flow, gift_entry, next, try Container.from(allocator, &.{
            .{ .name = "ActorName", .value = .{ .string = gifts[k] } },
        })));
        gift_events.append(allocator, next) catch return error.OutOfMemory;
    }
    // the scene ends with the time travel's white fade-in; the fade-in after it is AllSage's own (Event97), so the
    // item windows never show on a faded screen
    try flows.ensureSystemActor(fc, allocator, "UISystemActor", arrival.flow, progress);
    const fade_aa = try flows.requireAction(fc, allocator, "UISystemActor", "EventEventFadeIn", progress);
    next = try fc.addEvent(allocator, evfl.makeAction(arrival_prefix ++ "_FadeIn", fade_aa, next, try Container.from(allocator, &.{
        .{ .name = "Length", .value = .{ .int = 1 } },
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
    })));
    const transition_aa = try flows.requireAction(fc, allocator, "EventSystemActor", "EventTransition", progress);
    next = try fc.addEvent(allocator, evfl.makeAction(arrival_prefix ++ "_Scene", transition_aa, next, try Container.from(allocator, &.{
        .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        .{ .name = "SpecialEventActionType", .value = .{ .int = 1 } },
        .{ .name = "EventName", .value = .{ .string = arrival.scene } },
        .{ .name = "FadeInTypeEventEnd", .value = .{ .int = arrival_fade_in_type } },
    })));
    entry.main_event = next;
    // the entry lists the gift calls it reaches (a missing one hung the game: flows.listReachedCalls)
    try flows.listReachedCalls(allocator, fc, gift_events.items);
    return flows.writeBack(allocator, &doc, "AllSage (adult start arrival)", progress);
}

/// Lists the arrival's scene in its entry's GameAnalyzedEventInfo row (ChildEventList: the scenes an event plays).
/// The row is the game's own (Arrival.entry); the gift flow goes in its SubFlowList through
/// storyskip.updateEventInfo, as for every changed flow.
pub fn addArrivalScene(allocator: Allocator, world: *World, patches: *patchset.PatchSet, arrival: Arrival, progress: *Progress) PatchError!void {
    const rel = try world.find(allocator, "RSDB", "GameAnalyzedEventInfo.");
    const original = try patches.read(rel);
    const doc = byml.load(allocator, original.data) catch return error.InvalidData;
    const rows = switch (doc.root orelse return error.InvalidData) {
        .array => |r| r,
        else => return error.InvalidData,
    };
    for (rows.items.items) |r| {
        const row = r.asDict() orelse continue;
        if (!std.mem.eql(u8, row.getString("__RowId") orelse "", arrival.entry)) continue;
        const scenes = try row.ensureArray(allocator, "ChildEventList");
        for (scenes.items.items) |v| if (v.asString()) |listed| if (std.mem.eql(u8, listed, arrival.scene)) return;
        try scenes.append(allocator, .{ .string = arrival.scene });
        const out = byml.dump(allocator, doc.root, doc.version, doc.big_endian) catch return error.OutOfMemory;
        return patches.emitZs(rel, original, out);
    }
    return progress.fail(error.NotAsExpected, "GameAnalyzedEventInfo has no {s} row", .{arrival.entry});
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

/// Writes the names a test plan can use into `out_folder`: scenes.txt, start_spots.txt, boot_events.txt,
/// quests.txt, cutscenes.txt, locations.txt and items.txt. Returns the files written.
pub fn writeCatalog(allocator: Allocator, world: *World, fs: fsmod.Fs, out_folder: []const u8) PatchError![]const []const u8 {
    fs.makePath(out_folder) catch return error.GameFiles;
    var written: std.ArrayList([]const u8) = .empty;
    const header = "# Made by goggles_cli test-catalog from this game. Names for test plans (test_plans/TEMPLATE.test.toml).\n";

    const scenes = try sceneNames(allocator, world);
    const spot_table = try startSpotTable(allocator, world);
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# scene    age (\"either\": Link keeps the age the plan gives)    start spots\n\n");
        for (scenes) |scene| {
            const rule = try ageRule(allocator, world, scene);
            const spots = try spotsIn(allocator, spot_table, scene);
            try text.print(allocator, "{s}    {s}    {d}\n", .{ scene, if (rule.forced) |age| @tagName(age) else "either", spots.len });
        }
        try writeCatalogFile(allocator, fs, out_folder, "scenes.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [scene]  start_spot    position [x, y, z]    facing (degrees)\n");
        for (scenes) |scene| {
            const spots = try spotsIn(allocator, spot_table, scene);
            if (spots.len == 0) continue;
            try text.print(allocator, "\n[{s}]\n", .{scene});
            for (spots) |spot| {
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
    const events = try eventRows(allocator, world);
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# boot_event    the event flow it is in\n\n");
        for (events) |row| try text.print(allocator, "{s}    {s}\n", .{ row.id, row.flow });
        try writeCatalogFile(allocator, fs, out_folder, "boot_events.txt", text.items, &written);
    }
    const probe = try gamedata.probeOf(world);
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [quests] quest = \"step\": a quest and its steps, in order\n\n");
        for (try questNames(allocator, world)) |quest| {
            const enum_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ quest_enum_prefix, quest });
            const steps = probe.enumValueNames(enum_name) orelse continue;
            try text.print(allocator, "{s}    {s}\n", .{ quest, try joinValueNames(allocator, steps) });
        }
        try writeCatalogFile(allocator, fs, out_folder, "quests.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        // the game keeps a "played" flag for nearly every event; the Dm_ ones are its cutscenes
        try text.appendSlice(allocator, "# [cutscenes] seen / unseen: the cutscenes (Dm_ events) the game remembers as played\n");
        try text.appendSlice(allocator, "# (most other events in boot_events.txt have a played flag too and can be listed the same way)\n\n");
        var listed = std.StringHashMap(void).init(allocator);
        for (events) |row| {
            if (listed.contains(row.id) or !std.mem.startsWith(u8, row.id, "Dm_")) continue;
            const flag = try std.fmt.allocPrint(allocator, "{s}{s}", .{ played_prefix, row.id });
            if (probe.flagKind(flag) != .Bool) continue;
            listed.put(row.id, {}) catch return error.OutOfMemory;
            try text.print(allocator, "{s}    {s}\n", .{ row.id, row.flow });
        }
        try writeCatalogFile(allocator, fs, out_folder, "cutscenes.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# [place] \"location\" = \"item\": every location (whether it is shuffled depends on the settings)\n\n");
        for (world.locations.items) |loc| try text.print(allocator, "{s}\n", .{loc.name});
        try writeCatalogFile(allocator, fs, out_folder, "locations.txt", text.items, &written);
    }
    {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(allocator, header);
        try text.appendSlice(allocator, "# item name (for [place] and [start] items)    its key (also accepted)\n\n");
        for (0..world.items.count()) |i| {
            const id: ItemId = @intCast(i);
            try text.print(allocator, "{s}    {s}\n", .{ try world.itemNameById(allocator, id), world.items.name(id) });
        }
        try writeCatalogFile(allocator, fs, out_folder, "items.txt", text.items, &written);
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
