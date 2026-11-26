//! Test plans: one TOML file that describes a test seed (`goggles_cli test <plan.test.toml>`).
//!
//! A plan says which seed to make (name, seed, settings, items kept away from chosen locations) and how a new game
//! starts in it: items at chosen locations,
//! where Link appears (scene, start spot or coordinates, age, an event that plays on arrival), the time of day, the
//! items he already owns, quest steps, save flags and which cutscenes count as seen. test_plans/TEMPLATE.test.toml
//! explains every key; `goggles_cli test-catalog` lists the names the game accepts.
//!
//! This file only reads and checks the plan's shape (types, required keys, duplicates). Whether a scene, start spot,
//! quest, flag or item exists is checked against the game by generator/teststart.zig.
//!
//! The plan's text is copied into the seed folder (`test_plan.toml`), so rebuilding the seed makes the same start
//! again. The placements also go into settings.txt ("Test placements:"), as they always have, because they decide
//! where items are and so which saves fit the seed.

const std = @import("std");
const toml = @import("../formats/toml.zig");
const seedinfo = @import("seedinfo.zig");
const fsmod = @import("fs.zig");
const Allocator = std.mem.Allocator;

/// The plan's file name inside a seed folder.
pub const file_name_in_seed_folder = "test_plan.toml";

pub const Age = enum { child, adult };

/// Where a new game puts Link (instead of outside the Kokiri Shop).
pub const Spawn = struct {
    /// a scene ("KokiriForest") or one age's version of it ("KokiriForest_Adult"), as `test-catalog` lists them
    scene: []const u8,
    /// a start spot of that scene by name; "" = the coordinates below, or the scene's default spot
    start_spot: []const u8 = "",
    /// exact coordinates in the scene (as the catalog's start spots show them); null = use the start spot
    position: ?[3]f32 = null,
    /// which way Link faces with `position`, in degrees around the vertical axis (0 = the scene's +Z)
    facing_degrees: f32 = 0,
    /// an event that starts as soon as the scene is loaded (an EventSetting row, e.g. "SageRoom_MeetRauru"); "" = none
    boot_event: []const u8 = "",
};

/// A save flag a new game starts with, by its name in the game's save data.
pub const FlagValue = union(enum) {
    boolean: bool,
    integer: i64,
    /// an Enum flag's value by name ("Step04")
    enum_value: []const u8,
};

pub const FlagSetting = struct {
    name: []const u8,
    value: FlagValue,
};

/// A quest (a "challenge": DoorOfTime, Get_StoneOfForest...) and the step a new game starts it at.
pub const QuestStep = struct {
    quest: []const u8,
    step: []const u8,
};

/// What a test seed changes about a new game, apart from the item placements.
pub const StartSetup = struct {
    /// null: Link's age isn't changed (child, unless the scene is an adult one)
    age: ?Age = null,
    /// null: the normal start outside the Kokiri Shop
    spawn: ?Spawn = null,
    /// 0-23; null: the normal time
    time_hour: ?u8 = null,
    /// items owned from the start, by the names the spoiler log uses (or item keys)
    items: []const []const u8 = &.{},
    quests: []const QuestStep = &.{},
    flags: []const FlagSetting = &.{},
    /// cutscenes that count as already seen (they won't play) / not seen yet (they play again), by event name
    seen_cutscenes: []const []const u8 = &.{},
    unseen_cutscenes: []const []const u8 = &.{},

    pub fn isEmpty(self: StartSetup) bool {
        return self.age == null and self.spawn == null and self.time_hour == null and self.items.len == 0 and
            self.quests.len == 0 and self.flags.len == 0 and self.seen_cutscenes.len == 0 and self.unseen_cutscenes.len == 0;
    }
};

pub const TestPlan = struct {
    /// the seed folder becomes GogglesOfTruth_<name>
    name: []const u8,
    /// "" = a random seed
    seed: []const u8 = "",
    /// "" = no settings string: the preset's or the user's settings
    settings_string: []const u8 = "",
    /// "" = no preset
    preset: []const u8 = "",
    /// [settings]: user_settings.toml keys changed on top of the settings above
    setting_overrides: []const toml.Entry = &.{},
    /// [place]: location = item
    placements: []const seedinfo.TestPlacement = &.{},
    /// [forbid]: location = item or [items], as Item Restrictions entries ("Location | Item"), added to the
    /// settings' own (settings.parseItemRestriction reads them)
    item_restrictions: []const []const u8 = &.{},
    start: StartSetup = .{},
};

pub const PlanError = error{ OutOfMemory, InvalidPlan };

/// Why a plan was refused (set when parse returns error.InvalidPlan).
pub const Problem = struct {
    message: []const u8 = "",
};

/// Reads a plan. Strings point into `text` or are allocated with `allocator` (use an arena). On error.InvalidPlan,
/// `problem.message` says what is wrong, in words a tester can act on.
pub fn parse(allocator: Allocator, text: []const u8, problem: *Problem) PlanError!TestPlan {
    var bad_line: usize = 0;
    const doc = toml.parse(allocator, text, &bad_line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return refuse(allocator, problem, "line {d} is not TOML this program reads (strings need quotes; tables are [name])", .{bad_line}),
    };
    const known_tables = [_][]const u8{ "", "settings", "place", "forbid", "start", "quests", "flags", "cutscenes" };
    for (doc.tables.items) |t| {
        if (!isListed(&known_tables, t.name)) return refuse(allocator, problem, "unknown table [{s}] (known: [settings], [place], [forbid], [start], [quests], [flags], [cutscenes])", .{t.name});
    }

    const top = doc.table("").?;
    try refuseUnknownKeys(allocator, problem, top, "", &.{ "name", "seed", "settings_string", "preset" });
    var plan = TestPlan{ .name = try requiredString(allocator, problem, top, "", "name") };
    if (!isValidSeedName(plan.name)) return refuse(allocator, problem, "name = \"{s}\": use letters, digits, '-' and '_' only (it becomes the folder name)", .{plan.name});
    plan.seed = try optionalString(allocator, problem, top, "", "seed") orelse "";
    plan.settings_string = try optionalString(allocator, problem, top, "", "settings_string") orelse "";
    plan.preset = try optionalString(allocator, problem, top, "", "preset") orelse "";

    if (doc.table("settings")) |t| plan.setting_overrides = t.entries.items;

    if (doc.table("place")) |t| {
        const placements = allocator.alloc(seedinfo.TestPlacement, t.entries.items.len) catch return error.OutOfMemory;
        for (t.entries.items, 0..) |entry, i| {
            if (entry.value != .string) return refuse(allocator, problem, "[place] \"{s}\": the item must be a quoted name", .{entry.key});
            const text_form = std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value.string }) catch return error.OutOfMemory;
            placements[i] = seedinfo.parseTestPlacement(text_form) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidTestPlacement => return refuse(allocator, problem, "[place] \"{s}\" = \"{s}\": names can't contain '=' or ';'", .{ entry.key, entry.value.string }),
            };
            for (placements[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.location, placements[i].location)) return refuse(allocator, problem, "[place] \"{s}\" is listed twice", .{entry.key});
            }
        }
        plan.placements = placements;
    }

    if (doc.table("forbid")) |t| plan.item_restrictions = try readForbidTable(allocator, problem, t);

    if (doc.table("start")) |t| try readStartTable(allocator, problem, t, &plan.start);

    if (doc.table("quests")) |t| {
        const quests = allocator.alloc(QuestStep, t.entries.items.len) catch return error.OutOfMemory;
        for (t.entries.items, 0..) |entry, i| {
            if (entry.value != .string) return refuse(allocator, problem, "[quests] {s}: the step must be a quoted name such as \"Step02\" or \"Complete\"", .{entry.key});
            quests[i] = .{ .quest = entry.key, .step = entry.value.string };
        }
        plan.start.quests = quests;
    }

    if (doc.table("flags")) |t| {
        const flags = allocator.alloc(FlagSetting, t.entries.items.len) catch return error.OutOfMemory;
        for (t.entries.items, 0..) |entry, i| {
            const value: FlagValue = switch (entry.value) {
                .bool => |b| .{ .boolean = b },
                .int => |n| .{ .integer = n },
                .string => |s| .{ .enum_value = s },
                else => return refuse(allocator, problem, "[flags] \"{s}\": the value must be true/false, a whole number or a quoted value name", .{entry.key}),
            };
            flags[i] = .{ .name = entry.key, .value = value };
        }
        plan.start.flags = flags;
    }

    if (doc.table("cutscenes")) |t| {
        try refuseUnknownKeys(allocator, problem, t, "cutscenes", &.{ "seen", "unseen" });
        plan.start.seen_cutscenes = try optionalStringList(allocator, problem, t, "cutscenes", "seen");
        plan.start.unseen_cutscenes = try optionalStringList(allocator, problem, t, "cutscenes", "unseen");
        for (plan.start.seen_cutscenes) |seen| {
            if (isListed(plan.start.unseen_cutscenes, seen)) return refuse(allocator, problem, "[cutscenes] {s} is both seen and unseen", .{seen});
        }
    }
    return plan;
}

fn readStartTable(allocator: Allocator, problem: *Problem, t: *const toml.Table, start: *StartSetup) PlanError!void {
    const keys = [_][]const u8{ "age", "scene", "start_spot", "position", "facing", "boot_event", "time", "items" };
    try refuseUnknownKeys(allocator, problem, t, "start", &keys);
    if (try optionalString(allocator, problem, t, "start", "age")) |age_text| {
        start.age = std.meta.stringToEnum(Age, age_text) orelse return refuse(allocator, problem, "[start] age = \"{s}\": use \"child\" or \"adult\"", .{age_text});
    }
    const scene = try optionalString(allocator, problem, t, "start", "scene");
    const start_spot = try optionalString(allocator, problem, t, "start", "start_spot");
    const boot_event = try optionalString(allocator, problem, t, "start", "boot_event");
    var position: ?[3]f32 = null;
    if (t.get("position")) |v| {
        const numbers = if (v == .array) v.array else return refuse(allocator, problem, "[start] position must be [x, y, z]", .{});
        if (numbers.len != 3) return refuse(allocator, problem, "[start] position must have three numbers [x, y, z]", .{});
        var xyz: [3]f32 = undefined;
        for (numbers, 0..) |n, k| xyz[k] = @floatCast(n.asNumber() orelse return refuse(allocator, problem, "[start] position must be numbers [x, y, z]", .{}));
        position = xyz;
    }
    var facing: f32 = 0;
    if (t.get("facing")) |v| facing = @floatCast(v.asNumber() orelse return refuse(allocator, problem, "[start] facing must be a number of degrees", .{}));
    if (scene) |scene_name| {
        if (start_spot != null and position != null) return refuse(allocator, problem, "[start] give start_spot or position, not both", .{});
        start.spawn = .{
            .scene = scene_name,
            .start_spot = start_spot orelse "",
            .position = position,
            .facing_degrees = facing,
            .boot_event = boot_event orelse "",
        };
    } else if (start_spot != null or position != null or boot_event != null or t.get("facing") != null) {
        return refuse(allocator, problem, "[start] start_spot, position, facing and boot_event need a scene", .{});
    }
    if (t.get("time")) |v| {
        const hour = if (v == .int) v.int else return refuse(allocator, problem, "[start] time must be an hour from 0 to 23", .{});
        if (hour < 0 or hour > 23) return refuse(allocator, problem, "[start] time = {d}: use an hour from 0 to 23", .{hour});
        start.time_hour = @intCast(hour);
    }
    start.items = try optionalStringList(allocator, problem, t, "start", "items");
}

/// [forbid]: "Location" = "Item" or ["Item", ...] -> one "Location | Item" entry per item (the Item Restrictions
/// setting's form; '|' is its separator, so names can't hold one).
fn readForbidTable(allocator: Allocator, problem: *Problem, t: *const toml.Table) PlanError![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    for (t.entries.items) |*entry| {
        const items: []const toml.Value = switch (entry.value) {
            .string => (&entry.value)[0..1],
            .array => |a| a,
            else => return refuse(allocator, problem, "[forbid] \"{s}\": give a quoted item name or a list of them", .{entry.key}),
        };
        if (items.len == 0) return refuse(allocator, problem, "[forbid] \"{s}\": the list is empty", .{entry.key});
        for (items) |item| {
            if (item != .string) return refuse(allocator, problem, "[forbid] \"{s}\": item names must be quoted", .{entry.key});
            if (std.mem.indexOfScalar(u8, entry.key, '|') != null or std.mem.indexOfScalar(u8, item.string, '|') != null) {
                return refuse(allocator, problem, "[forbid] \"{s}\": names can't contain '|'", .{entry.key});
            }
            const text = std.fmt.allocPrint(allocator, "{s} | {s}", .{ entry.key, item.string }) catch return error.OutOfMemory;
            entries.append(allocator, text) catch return error.OutOfMemory;
        }
    }
    return entries.items;
}

fn refuse(allocator: Allocator, problem: *Problem, comptime fmt: []const u8, args: anytype) PlanError {
    problem.message = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
    return error.InvalidPlan;
}

fn refuseUnknownKeys(allocator: Allocator, problem: *Problem, t: *const toml.Table, table_name: []const u8, known: []const []const u8) PlanError!void {
    for (t.entries.items, 0..) |entry, i| {
        if (!isListed(known, entry.key)) {
            if (table_name.len == 0) return refuse(allocator, problem, "unknown key {s} at the top of the plan", .{entry.key});
            return refuse(allocator, problem, "unknown key {s} in [{s}]", .{ entry.key, table_name });
        }
        for (t.entries.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.key, entry.key)) return refuse(allocator, problem, "{s} is given twice", .{entry.key});
        }
    }
}

fn optionalString(allocator: Allocator, problem: *Problem, t: *const toml.Table, table_name: []const u8, key: []const u8) PlanError!?[]const u8 {
    const v = t.get(key) orelse return null;
    if (v != .string) return refuse(allocator, problem, "{s}{s}{s} must be a quoted text", .{ if (table_name.len > 0) "[" else "", table_name, key });
    return v.string;
}

fn requiredString(allocator: Allocator, problem: *Problem, t: *const toml.Table, table_name: []const u8, key: []const u8) PlanError![]const u8 {
    const v = try optionalString(allocator, problem, t, table_name, key) orelse return refuse(allocator, problem, "the plan needs {s} = \"...\"", .{key});
    if (v.len == 0) return refuse(allocator, problem, "{s} can't be empty", .{key});
    return v;
}

fn optionalStringList(allocator: Allocator, problem: *Problem, t: *const toml.Table, table_name: []const u8, key: []const u8) PlanError![]const []const u8 {
    const v = t.get(key) orelse return &.{};
    const items = if (v == .array) v.array else return refuse(allocator, problem, "[{s}] {s} must be a list such as [\"A\", \"B\"]", .{ table_name, key });
    const out = allocator.alloc([]const u8, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        out[i] = if (item == .string) item.string else return refuse(allocator, problem, "[{s}] {s} must list quoted names", .{ table_name, key });
    }
    return out;
}

fn isListed(list: []const []const u8, name: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

/// A folder name the game and every OS accept: letters, digits, '-' and '_'.
fn isValidSeedName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// The plan stored in a seed folder (made by `goggles_cli test`), or null for a seed without one.
pub fn readFromSeedFolder(allocator: Allocator, fs: fsmod.Fs, seed_folder: []const u8) error{OutOfMemory}!?[]const u8 {
    const path = try fsmod.join(allocator, &.{ seed_folder, file_name_in_seed_folder });
    if (!fs.isFile(path)) return null;
    return fs.readAll(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // a plan that can't be read is like none: the seed is rebuilt with the normal start (the caller says so)
        else => null,
    };
}

test "a full plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem = Problem{};
    const plan = try parse(a,
        \\name = "HOOKSHOT1"
        \\preset = "Standard"
        \\[settings]
        \\shuffle_ocarinas = true
        \\[place]
        \\"Kokiri Forest Chest 1" = "Hookshot"
        \\[forbid]
        \\"LW Deku Scrub Nut Upgrade" = ["Bomb Bag", "Progressive Bomb Bag"]
        \\"KF Chest 1" = "Hookshot"
        \\[start]
        \\age = "adult"
        \\scene = "KakarikoVillage"
        \\position = [10, 105.5, -3.25]
        \\facing = 90
        \\boot_event = "SomeEvent"
        \\time = 20
        \\items = ["Bow", "Hover Boots"]
        \\[quests]
        \\DoorOfTime = "Step04"
        \\[flags]
        \\"HyruleField_ChangeENV" = true
        \\"DungeonInfo.ForestTemple.SmallKeyNum" = 3
        \\[cutscenes]
        \\seen = ["Dm_Kokiri_0070"]
        \\unseen = ["Dm_Kokiri_0150"]
    , &problem);
    try std.testing.expectEqualStrings("HOOKSHOT1", plan.name);
    try std.testing.expectEqual(@as(usize, 1), plan.setting_overrides.len);
    try std.testing.expectEqualStrings("Hookshot", plan.placements[0].item);
    try std.testing.expectEqual(@as(usize, 3), plan.item_restrictions.len);
    try std.testing.expectEqualStrings("LW Deku Scrub Nut Upgrade | Progressive Bomb Bag", plan.item_restrictions[1]);
    try std.testing.expectEqual(Age.adult, plan.start.age.?);
    const spawn = plan.start.spawn.?;
    try std.testing.expectEqualStrings("KakarikoVillage", spawn.scene);
    try std.testing.expectEqual(@as(f32, 105.5), spawn.position.?[1]);
    try std.testing.expectEqual(@as(f32, 90), spawn.facing_degrees);
    try std.testing.expectEqual(@as(u8, 20), plan.start.time_hour.?);
    try std.testing.expectEqual(@as(usize, 2), plan.start.items.len);
    try std.testing.expectEqualStrings("Step04", plan.start.quests[0].step);
    try std.testing.expectEqual(@as(i64, 3), plan.start.flags[1].value.integer);
    try std.testing.expectEqualStrings("Dm_Kokiri_0150", plan.start.unseen_cutscenes[0]);
    try std.testing.expect(!plan.start.isEmpty());
}

test "plans with mistakes are refused with a reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, says: []const u8 }{
        .{ .text = "seed = \"X\"", .says = "needs name" },
        .{ .text = "name = \"bad name\"", .says = "letters, digits" },
        .{ .text = "name = \"A\"\n[start]\nage = \"old\"", .says = "child" },
        .{ .text = "name = \"A\"\n[start]\nposition = [1, 2, 3]", .says = "need a scene" },
        .{ .text = "name = \"A\"\n[start]\nscene = \"X\"\nstart_spot = \"S\"\nposition = [1, 2, 3]", .says = "not both" },
        .{ .text = "name = \"A\"\n[start]\nscene = \"X\"\nposition = [1, 2]", .says = "three numbers" },
        .{ .text = "name = \"A\"\n[start]\ntime = 24", .says = "0 to 23" },
        .{ .text = "name = \"A\"\n[start]\nspawn = \"X\"", .says = "unknown key spawn" },
        .{ .text = "name = \"A\"\n[teleport]", .says = "unknown table" },
        .{ .text = "name = \"A\"\n[place]\n\"L\" = \"I\"\n\"L\" = \"J\"", .says = "twice" },
        .{ .text = "name = \"A\"\n[forbid]\n\"L\" = 3", .says = "quoted item name" },
        .{ .text = "name = \"A\"\n[cutscenes]\nseen = [\"X\"]\nunseen = [\"X\"]", .says = "both seen and unseen" },
        .{ .text = "name = \"A\"\n[flags]\n\"F\" = [1]", .says = "true/false" },
    };
    for (cases) |case| {
        var problem = Problem{};
        try std.testing.expectError(error.InvalidPlan, parse(a, case.text, &problem));
        if (std.mem.indexOf(u8, problem.message, case.says) == null) {
            std.debug.print("plan {s}\n  said: {s}\n  expected: {s}\n", .{ case.text, problem.message, case.says });
            return error.TestUnexpectedResult;
        }
    }
}
