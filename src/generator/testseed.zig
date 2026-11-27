//! Test seeds from a test plan's text (core/testplan.zig), shared by `goggles_cli test` and the window's Test Seeds
//! tab (debug builds), so both make the same seed from the same plan.
//!
//! `prepare` reads the plan and works out everything the generator needs: the settings (the plan's settings string,
//! else the caller's base settings; then its preset, [settings] and [forbid] on top), the seed folder's name
//! (GogglesOfTruth_<name>), the seed number and whether making it again is a rebuild. A rebuild keeps the folder's
//! saves: the seed, settings and placements are the same, only the start changed, and a start only applies to new
//! games.

const std = @import("std");
const Allocator = std.mem.Allocator;
const settings_mod = @import("../settings/settings.zig");
const usersettings = @import("../settings/usersettings.zig");
const testplan = @import("../core/testplan.zig");
const seedinfo = @import("../core/seedinfo.zig");
const fsmod = @import("../core/fs.zig");
const longshot = @import("../platform/longshot.zig");
const generator = @import("generator.zig");
const Settings = settings_mod.Settings;

pub const PrepareError = error{ OutOfMemory, InvalidPlan };

/// What `prepare` worked out. Strings point into the plan text or memory from the allocator.
pub const Prepared = struct {
    plan: testplan.TestPlan,
    request: generator.Request,
    /// lines to show before generating (a remade folder, a rebuild)
    notes: []const []const u8,
};

/// Why `prepare` refused (set on error.InvalidPlan), in words a tester can act on.
pub const Problem = struct {
    message: []const u8 = "",
};

/// The generator request for `plan_text`. `base` stands in when the plan has no settings string (the window's
/// settings, or user_settings.toml for the command line); its Per-Seed Saves is kept either way.
pub fn prepare(allocator: Allocator, fs: fsmod.Fs, plan_text: []const u8, base: Settings, game_path: []const u8, out_dir: []const u8, problem: *Problem) PrepareError!Prepared {
    var plan_problem = testplan.Problem{};
    const plan = testplan.parse(allocator, plan_text, &plan_problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPlan => return refuse(problem, plan_problem.message),
    };

    // settings: the plan's settings string, else the base; then the plan's preset and [settings] on top
    var st = base;
    if (plan.settings_string.len > 0) {
        st = settings_mod.fromString(allocator, plan.settings_string) catch return refuse(problem, "settings_string can't be read by this version");
        st.set(.per_seed_saves, base.get(.per_seed_saves));
    }
    if (plan.preset.len > 0) {
        const preset = settings_mod.findPreset(plan.preset) orelse
            return refuse(problem, try std.fmt.allocPrint(allocator, "no built-in preset named {s} (Beginner, Standard, Expert, Race)", .{plan.preset}));
        st = settings_mod.applyPreset(st, preset);
    }
    var warnings: std.ArrayList([]const u8) = .empty;
    st = try usersettings.applyOverrides(allocator, st, plan.setting_overrides, &warnings, "");
    // a test only means something with the settings it names: a setting that didn't apply stops it
    if (warnings.items.len > 0) return refuse(problem, try std.fmt.allocPrint(allocator, "[settings] {s}", .{warnings.items[0]}));
    // [forbid] adds to the settings' own Item Restrictions (it goes into the settings string, so a rebuild keeps it)
    if (plan.item_restrictions.len > 0) {
        var restrictions: std.ArrayList([]const u8) = .empty;
        try restrictions.appendSlice(allocator, st.itemRestrictions());
        for (plan.item_restrictions) |entry| {
            for (restrictions.items) |existing| {
                if (std.mem.eql(u8, existing, entry)) break;
            } else try restrictions.append(allocator, entry);
        }
        st.set(.item_restrictions, .{ .list = restrictions.items });
    }

    const mod_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ longshot.mod_prefix, plan.name });
    const folder = try fsmod.join(allocator, &.{ out_dir, mod_name });
    var notes: std.ArrayList([]const u8) = .empty;
    // the plan's seed made before and switched off since (another seed made after it renamed it _GogglesOfTruth_<name>):
    // switched back on, so it is made again in its own folder with its saves, not as a second copy beside it (test
    // report: _GogglesOfTruth_UNDERWATER1, "(2)", "(3)" piling up in the mods folder)
    const switched_off = try fsmod.join(allocator, &.{ out_dir, try std.fmt.allocPrint(allocator, "_{s}", .{mod_name}) });
    if (!fs.exists(folder) and fs.isDir(switched_off)) {
        if (fs.rename(switched_off, folder)) {
            try notes.append(allocator, try std.fmt.allocPrint(allocator, "{s} was switched off: switched back on to make it again", .{mod_name}));
        } else |_| {}
    }
    var seed: ?[]const u8 = if (plan.seed.len > 0) plan.seed else null;
    var rebuild = false;
    switch (try generator.checkRebuild(allocator, fs, folder)) {
        .not_a_seed => {},
        .other_placements => |info| {
            try notes.append(allocator, try std.fmt.allocPrint(allocator, "note: {s} was made by {s}, whose placements differ; it is made anew", .{ mod_name, info.release }));
        },
        .ready => |info| {
            if (seed == null) seed = info.seed;
            const settings_string = try settings_mod.toString(allocator, &st);
            const placements_text = try seedinfo.formatTestPlacements(allocator, plan.placements);
            rebuild = std.mem.eql(u8, seed.?, info.seed) and std.mem.eql(u8, settings_string, info.settings_string) and
                std.mem.eql(u8, placements_text, info.test_placements);
            try notes.append(allocator, if (rebuild)
                try std.fmt.allocPrint(allocator, "{s} exists with the same seed, settings and placements: rebuilt, its saves kept (a changed start only shows in a new game)", .{mod_name})
            else
                try std.fmt.allocPrint(allocator, "{s} exists with other settings or placements: made anew with its seed {s}", .{ mod_name, seed.? }));
        },
    }

    return .{
        .plan = plan,
        .request = .{
            .game_path = game_path,
            .out_dir = out_dir,
            .settings = st,
            .seed = seed,
            .mod_name = mod_name,
            .test_placements = plan.placements,
            .test_plan_text = plan_text,
            .rebuild = rebuild,
        },
        .notes = notes.items,
    };
}

fn refuse(problem: *Problem, message: []const u8) PrepareError {
    problem.message = message;
    return error.InvalidPlan;
}

test "a plan's settings, forbid list and folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a folder that doesn't exist: never a seed folder, so nothing is read
    const fs = fsmod.Fs.init(std.testing.io);
    var problem = Problem{};
    const prepared = try prepare(a, fs,
        \\name = "UNIT1"
        \\seed = "S1"
        \\[settings]
        \\shuffle_scrubs = true
        \\[forbid]
        \\"KF Chest 1" = "Hookshot"
    , Settings.defaults(), "game", "no such folder (unit test)", &problem);
    try std.testing.expectEqualStrings("GogglesOfTruth_UNIT1", prepared.request.mod_name.?);
    try std.testing.expectEqualStrings("S1", prepared.request.seed.?);
    try std.testing.expect(prepared.request.settings.flag(.shuffle_scrubs));
    try std.testing.expectEqualStrings("KF Chest 1 | Hookshot", prepared.request.settings.itemRestrictions()[0]);
    try std.testing.expectError(error.InvalidPlan, prepare(a, fs, "name = \"A\"\n[settings]\nno_such = true", Settings.defaults(), "g", "o", &problem));
    try std.testing.expect(problem.message.len > 0);
}
