//! Launch Game: starts Longshot or the emulator that the output folder belongs to, so the seed just made can be
//! played with one click.
//!
//! Which program: the output folder decides (saves.targetFor):
//!   - a Longshot game's mods folder -> Longshot: the program in the Longshot path set in the window (the game
//!     folder or the program itself), else the one next to the mods folder (<game folder>/longshot.exe);
//!   - an emulator's load/0400486024DEC000 folder -> the emulator: the program in the emulator path set in the
//!     window (the program, or its folder), else the one next to a portable emulator's user folder. With an emulator
//!     game file set (the game's .nsp/.xci or folder the emulator boots), the emulator starts that game directly.
//!
//! Anything else (a plain output folder) can't be launched: neither knows to load a mod from there.
//! The program starts in its own folder, detached: closing the randomizer doesn't close the game.

const std = @import("std");
const fsmod = @import("../core/fs.zig");
const Env = @import("Env.zig");
const host = @import("host.zig");
const saves = @import("saves.zig");
const Allocator = std.mem.Allocator;

/// Where the programs are, as set in the window (user_settings.toml [paths]); "" = find it from the output folder.
pub const LaunchPaths = struct {
    /// the Longshot game folder, or the Longshot program
    longshot: []const u8 = "",
    /// the emulator program (or .app on macOS), or its folder
    emulator: []const u8 = "",
    /// optional: the game the emulator boots (its .nsp/.xci file or game folder)
    emulator_game: []const u8 = "",
};

pub const LaunchPlan = struct {
    kind: saves.TargetKind,
    /// the program and its arguments
    argv: []const []const u8,
    /// the folder it starts in (its own)
    working_dir: []const u8,
    /// for the log: the program that is started
    program: []const u8,
    /// a note for the log ("" for none)
    note: []const u8 = "",
};

pub const PlanResult = union(enum) {
    ready: LaunchPlan,
    /// why nothing can be launched, for a message box
    problem: []const u8,
};

/// Program names of Longshot, per system (the first one found is used).
const longshot_programs: []const []const u8 = switch (host.host_system) {
    .windows => &.{"longshot.exe"},
    .macos => &.{ "Longshot.app", "longshot" },
    // Longshot's docs (docs/user/advanced.md): the game is bin/longshot, with a `longshot` launcher beside bin
    .other_unix => &.{ "longshot", "bin/longshot", "Longshot", "longshot.x86_64" },
};

/// Is `name` (lower case) a program file on this system?
fn isProgramName(name: []const u8) bool {
    return switch (host.host_system) {
        .windows => std.mem.endsWith(u8, name, ".exe"),
        .macos => std.mem.endsWith(u8, name, ".app") or std.mem.indexOfScalar(u8, name, '.') == null,
        .other_unix => std.mem.endsWith(u8, name, ".appimage") or std.mem.indexOfScalar(u8, name, '.') == null,
    };
}

/// The emulator family name of a program file ("yuzu" for yuzu.exe or yuzu-cmd.exe, "eden" for
/// Eden-x86_64.AppImage), and whether the name is exactly the family's main program.
const EmulatorMatch = struct { family: []const u8, main_program: bool };

fn emulatorFamily(allocator: Allocator, file_name: []const u8) error{OutOfMemory}!?EmulatorMatch {
    const lower = try std.ascii.allocLowerString(allocator, file_name);
    if (!isProgramName(lower)) return null;
    const stem = lower[0 .. std.mem.indexOfScalar(u8, lower, '.') orelse lower.len];
    const base = stem[0 .. std.mem.indexOfAny(u8, stem, "-_ ") orelse stem.len];
    for (saves.emulator_exes) |family| {
        if (std.mem.eql(u8, base, family)) return EmulatorMatch{ .family = family, .main_program = std.mem.eql(u8, stem, family) };
    }
    return null;
}

/// The emulator program in `folder`: the family's main program before a helper (yuzu.exe before yuzu-cmd.exe).
fn findEmulatorIn(allocator: Allocator, env: *const Env, folder: []const u8) error{OutOfMemory}!?[]const u8 {
    const names = env.fs.listDirSorted(allocator, folder) catch return null;
    var fallback: ?[]const u8 = null;
    for (names) |name| {
        const match = (try emulatorFamily(allocator, name)) orelse continue;
        const full = try fsmod.join(allocator, &.{ folder, name });
        if (match.main_program) return full;
        // why: helpers like yuzu-cmd or yuzu-room aren't the window; only take one when nothing else is there
        const lower = try std.ascii.allocLowerString(allocator, name);
        if (fallback == null and std.mem.indexOf(u8, lower, "cmd") == null and std.mem.indexOf(u8, lower, "room") == null) fallback = full;
    }
    return fallback;
}

fn findLongshotIn(allocator: Allocator, env: *const Env, folder: []const u8) error{OutOfMemory}!?[]const u8 {
    for (longshot_programs) |name| {
        const full = try fsmod.join(allocator, &.{ folder, name });
        if (env.fs.exists(full)) return full;
    }
    return null;
}

/// A configured path that is the program itself (a file, or a macOS .app), or the folder it is in.
fn programFromSetting(allocator: Allocator, env: *const Env, setting: []const u8, kind: saves.TargetKind) error{OutOfMemory}!?[]const u8 {
    const trimmed = std.mem.trim(u8, setting, " \t\"");
    if (trimmed.len == 0) return null;
    const is_app_bundle = host.host_system == .macos and std.ascii.endsWithIgnoreCase(trimmed, ".app");
    if (env.fs.isFile(trimmed) or (is_app_bundle and env.fs.isDir(trimmed))) return try allocator.dupe(u8, trimmed);
    if (!env.fs.isDir(trimmed)) return null;
    return switch (kind) {
        .longshot => try findLongshotIn(allocator, env, trimmed),
        .emulator => try findEmulatorIn(allocator, env, trimmed),
    };
}

/// The program, arguments and folder to launch for output folder `out_dir`, or why there is none.
pub fn planLaunch(allocator: Allocator, env: *const Env, out_dir: []const u8, paths: LaunchPaths) error{OutOfMemory}!PlanResult {
    const out = std.mem.trim(u8, out_dir, " \t");
    const target = (try saves.targetFor(allocator, env, out)) orelse return .{
        .problem = "The output folder isn't a Longshot mods folder or an emulator's load/0400486024DEC000 folder, so neither would load the seed from there. Choose one as the output folder first (the Longshot button finds Longshot's).",
    };
    var note: []const u8 = "";
    const program: []const u8 = switch (target.kind) {
        .longshot => blk: {
            // the game folder holds the mods folder: its program is the one that loads this seed
            const own_game_folder = fsmod.dirname(target.mods);
            const own_program = try findLongshotIn(allocator, env, own_game_folder);
            if (try programFromSetting(allocator, env, paths.longshot, .longshot)) |configured| {
                if (own_program != null and !fsmod.samePath(fsmod.dirname(configured), own_game_folder)) {
                    note = try std.fmt.allocPrint(allocator, "note: the Longshot path set ({s}) isn't the game whose mods folder is the output folder ({s}); that game won't load this seed", .{ configured, own_game_folder });
                }
                break :blk configured;
            }
            if (paths.longshot.len > 0) {
                return .{ .problem = try std.fmt.allocPrint(allocator, "No Longshot program was found at the Longshot path:\n{s}\n\nChoose the Longshot game folder (the one with longshot.exe and the mods folder) or the program itself, or clear the field to use the game next to the output folder.", .{paths.longshot}) };
            }
            break :blk own_program orelse return .{
                .problem = try std.fmt.allocPrint(allocator, "No Longshot program was found next to the output folder (in {s}). Set the Longshot path to the game folder or the program.", .{own_game_folder}),
            };
        },
        .emulator => blk: {
            if (try programFromSetting(allocator, env, paths.emulator, .emulator)) |configured| break :blk configured;
            if (paths.emulator.len > 0) {
                return .{ .problem = try std.fmt.allocPrint(allocator, "No emulator program was found at the emulator path:\n{s}\n\nChoose the emulator's program (yuzu, Eden, Citron, Lichii, Ryujinx...) or the folder it is in.", .{paths.emulator}) };
            }
            if (target.exe_dir.len > 0) {
                if (try findEmulatorIn(allocator, env, target.exe_dir)) |portable| break :blk portable;
            }
            return .{ .problem = "The emulator program wasn't found (only a portable emulator, with its user folder next to the program, is found by itself). Set the emulator path to its program or the folder it is in." };
        },
    };

    var argv: std.ArrayList([]const u8) = .empty;
    const is_app_bundle = host.host_system == .macos and std.ascii.endsWithIgnoreCase(program, ".app");
    if (is_app_bundle) try argv.appendSlice(allocator, &.{ "open", "-a", program });
    if (!is_app_bundle) try argv.append(allocator, program);
    const game = std.mem.trim(u8, paths.emulator_game, " \t\"");
    if (target.kind == .emulator and game.len > 0) {
        if (!env.fs.exists(game)) return .{ .problem = try std.fmt.allocPrint(allocator, "The emulator game file wasn't found:\n{s}", .{game}) };
        if (is_app_bundle) try argv.append(allocator, "--args");
        // why: Ryujinx (and Ryubing) take the game as their only argument; the yuzu family wants -g <game>
        const family = (try emulatorFamily(allocator, fsmod.basename(program))) orelse EmulatorMatch{ .family = "", .main_program = false };
        const takes_bare_path = std.mem.eql(u8, family.family, "ryujinx") or std.mem.eql(u8, family.family, "ryubing");
        if (!takes_bare_path) try argv.append(allocator, "-g");
        try argv.append(allocator, game);
    }
    return .{ .ready = .{
        .kind = target.kind,
        .argv = argv.items,
        .working_dir = fsmod.dirname(program),
        .program = program,
        .note = note,
    } };
}

pub const LaunchError = error{LaunchFailed};

/// Starts the plan's program, detached (its output isn't read). The error name says why it failed.
pub fn launch(env: *const Env, plan: LaunchPlan) LaunchError!void {
    _ = std.process.spawn(env.fs.io, .{
        .argv = plan.argv,
        .cwd = .{ .path = plan.working_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.LaunchFailed;
}

test "the output folder picks the program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fsmod.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    var environ = std.process.Environ.Map.init(a);
    const env = Env{ .environ = &environ, .fs = fsmod.Fs.init(std.testing.io), .app_dir = root };
    const program_suffix = switch (host.host_system) {
        .windows => ".exe",
        .macos => ".app",
        .other_unix => ".AppImage",
    };

    // a Longshot game folder: its program is next to the mods folder
    const game = try fsmod.join(a, &.{ root, "Longshot" });
    const mods = try fsmod.join(a, &.{ game, "mods" });
    try env.fs.makePath(mods);
    try env.fs.writeAll(try fsmod.join(a, &.{ game, "longshot_version.txt" }), "version=v3.1.1\n");
    try env.fs.writeAll(try fsmod.join(a, &.{ game, longshot_programs[0] }), "");
    const longshot_plan = (try planLaunch(a, &env, mods, .{})).ready;
    try std.testing.expectEqual(saves.TargetKind.longshot, longshot_plan.kind);
    try std.testing.expectEqualStrings(longshot_programs[0], fsmod.basename(longshot_plan.program));

    // a portable emulator: the main program, not its command-line helper, and the game booted with -g
    const emulator = try fsmod.join(a, &.{ root, "Eden" });
    const load = try fsmod.join(a, &.{ emulator, "user", "load", saves.title_id });
    try env.fs.makePath(load);
    try env.fs.writeAll(try fsmod.join(a, &.{ emulator, "eden-cmd" ++ program_suffix }), "");
    try env.fs.writeAll(try fsmod.join(a, &.{ emulator, "eden" ++ program_suffix }), "");
    const game_file = try fsmod.join(a, &.{ root, "game.nsp" });
    try env.fs.writeAll(game_file, "");
    const emulator_plan = (try planLaunch(a, &env, load, .{ .emulator_game = game_file })).ready;
    try std.testing.expectEqual(saves.TargetKind.emulator, emulator_plan.kind);
    try std.testing.expectEqualStrings("eden" ++ program_suffix, fsmod.basename(emulator_plan.program));
    try std.testing.expectEqualStrings("-g", emulator_plan.argv[emulator_plan.argv.len - 2]);
    try std.testing.expectEqualStrings(game_file, emulator_plan.argv[emulator_plan.argv.len - 1]);

    // a plain folder: nothing to launch
    try std.testing.expect((try planLaunch(a, &env, root, .{})) == .problem);
    // a Longshot path that holds no Longshot: refused, not guessed
    try std.testing.expect((try planLaunch(a, &env, mods, .{ .longshot = emulator })) == .problem);
}

test "emulator program names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program_suffix = switch (host.host_system) {
        .windows => ".exe",
        .macos => ".app",
        .other_unix => ".AppImage",
    };
    const main = (try emulatorFamily(a, "Eden" ++ program_suffix)).?;
    try std.testing.expectEqualStrings("eden", main.family);
    try std.testing.expect(main.main_program);
    const helper = (try emulatorFamily(a, "yuzu-cmd" ++ program_suffix)).?;
    try std.testing.expectEqualStrings("yuzu", helper.family);
    try std.testing.expect(!helper.main_program);
    try std.testing.expect((try emulatorFamily(a, "notepad" ++ program_suffix)) == null);
    try std.testing.expect((try emulatorFamily(a, "yuzu.ini")) == null);
}
