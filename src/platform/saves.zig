//! Per-seed saves: each seed keeps its own save slots, in Longshot and in Switch emulators.
//!
//! The game keeps all its save data in one folder per account:
//!     Longshot (Windows):   %APPDATA%\Longshot\save\<account id>\
//!     Longshot (Linux):     ~/.local/share/Longshot/save/<account id>/ (or $XDG_DATA_HOME, or ~/.config)
//!     emulators:            <NAND folder>/user/save/0000000000000000/<profile>/0400486024DEC000/
//!                           (<emulator user folder>/nand, unless its config/qt-config.ini sets nand_directory)
//! with the same files in each: option.sav (the game's options), account.sav (a small account-wide table), and the
//! six save slots slot_00 ... slot_05 (caption.sav + progress.sav each).
//!
//! Everything but option.sav belongs to a seed. The seed whose saves are in the game's folder is named in a marker
//! file there. Switching to another seed (after generating one, or with "Play This Seed"):
//!   1. the game's current slots and account.sav are copied into the seed that owns them:
//!      <seed folder>/saves/<account> (a folder Longshot and the emulators don't read); slots no seed owns are copied
//!      to save_backups/ instead;
//!   2. the game's slots are replaced by the new seed's stored ones, or emptied for a seed that has none (account.sav
//!      is then kept), and the marker names the new seed.
//! Nothing is deleted before it has been copied somewhere. option.sav is never touched. The game must be closed.
//!
//! Switching seeds on and off: Longshot skips mod folders starting with "." "-" "_" (longshot.zig); emulators of the
//! yuzu family load every folder in load/<title id>/, so a seed is switched off by moving it into
//! load/GogglesOfTruth_off/, which they don't read (it isn't a title id).

const std = @import("std");
const builtin = @import("builtin");
const fsmod = @import("../core/fs.zig");
const Env = @import("Env.zig");
const longshot = @import("longshot.zig");
const seedinfo = @import("../core/seedinfo.zig");
const Allocator = std.mem.Allocator;

pub const title_id = "0400486024DEC000";
pub const marker = "goggles_of_truth_seed.txt";
const store = "saves";
/// Stored saves carry the seed's settings.txt: a folder name used again for a different seed has a different one, and
/// its old saves aren't brought back. A rebuild of the same seed (same placements, a newer release) keeps them.
const identity = "seed_settings.txt";
const shared = [_][]const u8{ "option.sav", marker, identity };
pub const emu_off = "GogglesOfTruth_off";
pub const emulator_exes = [_][]const u8{ "yuzu", "suyu", "sudachi", "citron", "eden", "torzu", "lichii", "fritchii", "ryujinx", "ryubing" };

pub const SaveError = error{
    /// the game or emulator is running, a seed can't be found or moved, ... (the message says what)
    SaveFailed,
    OutOfMemory,
};

pub const TargetKind = enum {
    longshot,
    emulator,

    pub fn label(self: TargetKind) []const u8 {
        return switch (self) {
            .longshot => "Longshot",
            .emulator => "emulator",
        };
    }
};

pub const Target = struct {
    kind: TargetKind,
    /// where the seeds are (Longshot mods/, or load/<title id>/)
    mods: []const u8,
    save_dirs: []const []const u8,
    /// emulators: where switched-off seeds go
    off: []const u8 = "",
    /// emulators: the emulator's own folder, when it's portable
    exe_dir: []const u8 = "",
    /// a warning to show (the emulator reads its mods elsewhere)
    note: []const u8 = "",
};

/// Messages for the log, and the reason when a step fails.
pub const Messages = struct {
    allocator: Allocator,
    lines: std.ArrayList([]const u8) = .empty,
    failure: []const u8 = "",

    pub fn add(self: *Messages, comptime format: []const u8, args: anytype) SaveError!void {
        const line = std.fmt.allocPrint(self.allocator, format, args) catch return error.OutOfMemory;
        self.lines.append(self.allocator, line) catch return error.OutOfMemory;
    }

    pub fn fail(self: *Messages, comptime format: []const u8, args: anytype) SaveError {
        self.failure = std.fmt.allocPrint(self.allocator, format, args) catch return error.OutOfMemory;
        return error.SaveFailed;
    }
};

// ------------------------------------------------------------------------------------------------- where things are

fn isSlotName(n: []const u8) bool {
    if (!std.mem.startsWith(u8, n, "slot_") or n.len == 5) return false;
    for (n[5..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn looksLikeSave(allocator: Allocator, env: *const Env, d: []const u8) bool {
    const names = env.fs.listDir(allocator, d) catch return false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "option.sav") or std.mem.eql(u8, n, "account.sav") or isSlotName(n)) return true;
    }
    return false;
}

fn accountDirs(allocator: Allocator, env: *const Env, parents: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (parents) |p| {
        const names = env.fs.listDirSorted(allocator, p) catch continue;
        for (names) |n| {
            const d = try fsmod.join(allocator, &.{ p, n });
            if (env.fs.isDir(d) and looksLikeSave(allocator, env, d)) try out.append(allocator, d);
        }
    }
    return out.items;
}

pub fn longshotSaveDirs(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const []const u8 {
    if (builtin.os.tag == .windows) {
        const root = try fsmod.join(allocator, &.{ try env.roamingAppData(allocator), "Longshot", "save" });
        return accountDirs(allocator, env, &.{root});
    }
    const data = try env.xdgData(allocator);
    const conf = try env.xdgConfig(allocator);
    // Longshot's docs (docs/user/saves.md): ${XDG_DATA_HOME:-~/.local/share}/longshot/save on Linux; the launcher's
    // docs also name longshot/user/save
    return accountDirs(allocator, env, &.{
        try fsmod.join(allocator, &.{ data, "longshot", "save" }),
        try fsmod.join(allocator, &.{ data, "longshot", "user", "save" }),
        try fsmod.join(allocator, &.{ data, "Longshot", "save" }),
        try fsmod.join(allocator, &.{ conf, "Longshot", "save" }),
    });
}

/// The emulator's user folder if `out` is its load/<title id> folder, else null.
pub fn emulatorUserDir(allocator: Allocator, env: *const Env, out: []const u8) ?[]const u8 {
    const abs = env.fs.absolute(allocator, out) catch return null;
    if (!std.ascii.eqlIgnoreCase(fsmod.basename(abs), title_id)) return null;
    const load = fsmod.dirname(abs);
    if (!std.ascii.eqlIgnoreCase(fsmod.basename(load), "load")) return null;
    return fsmod.dirname(load);
}

/// A folder setting (nand_directory, load_directory) from the emulator's config/qt-config.ini, or null.
fn emulatorDirSetting(allocator: Allocator, env: *const Env, user: []const u8, setting: []const u8) ?[]const u8 {
    for ([_][]const u8{ "qt-config.ini", "config.ini" }) |cfg| {
        const path = fsmod.join(allocator, &.{ user, "config", cfg }) catch return null;
        const data = env.fs.readAll(allocator, path) catch continue;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (!std.mem.startsWith(u8, line, setting)) continue;
            const rest = std.mem.trimStart(u8, line[setting.len..], " \t");
            if (rest.len == 0 or rest[0] != '=') continue;
            const value = std.mem.trim(u8, std.mem.trim(u8, rest[1..], " \t"), "\"");
            if (value.len == 0) continue;
            return @import("../game/gamefiles.zig").normalizePath(allocator, value) catch null;
        }
    }
    return null;
}

/// The emulator's NAND folder: its qt-config.ini can move it anywhere, else <user>/nand.
fn emulatorNandDir(allocator: Allocator, env: *const Env, user: []const u8) error{OutOfMemory}![]const u8 {
    return emulatorDirSetting(allocator, env, user, "nand_directory") orelse fsmod.join(allocator, &.{ user, "nand" });
}

/// A warning if the emulator reads its mods from another load folder than <user>/load.
fn emulatorLoadNote(allocator: Allocator, env: *const Env, user: []const u8) error{OutOfMemory}![]const u8 {
    const load = emulatorDirSetting(allocator, env, user, "load_directory") orelse return "";
    const own = try fsmod.join(allocator, &.{ user, "load" });
    const load_abs = env.fs.absolute(allocator, load) catch load;
    if (fsmod.samePath(load_abs, own)) return "";
    return std.fmt.allocPrint(allocator, "this emulator reads its mods from {s}, not from this folder: use {s} as the output folder", .{
        load, try fsmod.join(allocator, &.{ load, title_id }),
    });
}

fn emulatorSaveDirs(allocator: Allocator, env: *const Env, user: []const u8) error{OutOfMemory}![]const []const u8 {
    const base = try fsmod.join(allocator, &.{ try emulatorNandDir(allocator, env, user), "user", "save", "0000000000000000" });
    var out: std.ArrayList([]const u8) = .empty;
    const profiles = env.fs.listDirSorted(allocator, base) catch return out.items;
    for (profiles) |prof| {
        const pdir = try fsmod.join(allocator, &.{ base, prof });
        const titles = env.fs.listDir(allocator, pdir) catch continue;
        for (titles) |t| {
            if (std.ascii.eqlIgnoreCase(t, title_id)) try out.append(allocator, try fsmod.join(allocator, &.{ pdir, t }));
        }
    }
    return out.items;
}

/// The save target for output folder `out`, or null if it isn't a Longshot or emulator mods folder.
pub fn targetFor(allocator: Allocator, env: *const Env, out: []const u8) error{OutOfMemory}!?Target {
    if (out.len == 0) return null;
    const abs = env.fs.absolute(allocator, out) catch return null;
    if (longshot.isModsFolder(allocator, env, out)) {
        return Target{ .kind = .longshot, .mods = abs, .save_dirs = try longshotSaveDirs(allocator, env) };
    }
    const user = emulatorUserDir(allocator, env, out) orelse return null;
    // portable emulators keep "user" next to the program
    const exe_dir = if (std.ascii.eqlIgnoreCase(fsmod.basename(user), "user")) fsmod.dirname(user) else "";
    return Target{
        .kind = .emulator,
        .mods = abs,
        .save_dirs = try emulatorSaveDirs(allocator, env, user),
        .off = try fsmod.join(allocator, &.{ fsmod.dirname(abs), emu_off }),
        .exe_dir = exe_dir,
        .note = try emulatorLoadNote(allocator, env, user),
    };
}

// ----------------------------------------------------------------------------------------------------- seeds

pub fn isSeed(name: []const u8) bool {
    return longshot.isSeedName(std.mem.trimStart(u8, name, "_"));
}

/// GogglesOfTruth_X for "_GogglesOfTruth_X" or "_GogglesOfTruth_X (2)".
pub fn seedName(folder_name: []const u8) []const u8 {
    const s = std.mem.trimStart(u8, folder_name, "_");
    if (std.mem.endsWith(u8, s, ")")) {
        if (std.mem.lastIndexOf(u8, s, " (")) |i| {
            const digits = s[i + 2 .. s.len - 1];
            var all = digits.len > 0;
            for (digits) |c| if (!std.ascii.isDigit(c)) {
                all = false;
            };
            if (all) return s[0..i];
        }
    }
    return s;
}

pub const Seed = struct {
    name: []const u8,
    folder: []const u8,
    on: bool,
    mtime: i96,
};

/// Every seed in the target, newest first.
pub fn seeds(allocator: Allocator, env: *const Env, target: Target) error{OutOfMemory}![]Seed {
    var found: std.ArrayList(Seed) = .empty;
    const places = [_]struct { dir: []const u8, on: bool }{ .{ .dir = target.mods, .on = true }, .{ .dir = target.off, .on = false } };
    for (places) |place| {
        if (place.dir.len == 0) continue;
        const names = env.fs.listDir(allocator, place.dir) catch continue;
        for (names) |n| {
            const p = try fsmod.join(allocator, &.{ place.dir, n });
            if (!env.fs.isDir(p) or !isSeed(n)) continue;
            try found.append(allocator, .{
                .name = seedName(n),
                .folder = p,
                .on = place.on and !longshot.isSwitchedOff(n),
                .mtime = env.fs.mtime(p) orelse 0,
            });
        }
    }
    std.mem.sort(Seed, found.items, {}, struct {
        fn newer(_: void, x: Seed, y: Seed) bool {
            return x.mtime > y.mtime;
        }
    }.newer);
    return found.items;
}

/// The folder of seed `name` (switched on or off), or null.
pub fn seedFolder(allocator: Allocator, env: *const Env, target: Target, name: []const u8) error{OutOfMemory}!?[]const u8 {
    var found: ?[]const u8 = null;
    for (try seeds(allocator, env, target)) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (s.on) return s.folder;
        if (found == null) found = s.folder;
    }
    return found;
}

/// Makes `name` the only seed the game loads. Returns its folder.
pub fn switchOn(allocator: Allocator, env: *const Env, target: Target, name: []const u8, msg: *Messages) SaveError![]const u8 {
    var folder = (try seedFolder(allocator, env, target, name)) orelse return msg.fail("seed {s} not found in {s}", .{ name, target.mods });
    const want = try fsmod.join(allocator, &.{ target.mods, name });
    if (!fsmod.samePath(folder, want)) {
        if (env.fs.exists(want)) return msg.fail("can't switch {s} on: {s} already exists", .{ name, want });
        env.fs.rename(folder, want) catch |err| return msg.fail("couldn't move {s} (close the game first): {s}", .{ folder, @errorName(err) });
        folder = want;
    }
    const left = switch (target.kind) {
        .longshot => blk: {
            _ = try longshot.switchOffOtherSeeds(allocator, env, target.mods, name);
            break :blk try longshot.activeSeeds(allocator, env, target.mods, name);
        },
        .emulator => try switchOffEmulatorSeeds(allocator, env, target, name),
    };
    if (left.len > 0) {
        return msg.fail("these seeds couldn't be switched off (close the game first): {s}", .{std.mem.join(allocator, ", ", left) catch return error.OutOfMemory});
    }
    return folder;
}

/// Moves every other seed out of load/<title id> into load/GogglesOfTruth_off. Returns the ones that failed.
pub fn switchOffEmulatorSeeds(allocator: Allocator, env: *const Env, target: Target, keep: []const u8) error{OutOfMemory}![]const []const u8 {
    var failed: std.ArrayList([]const u8) = .empty;
    const names = env.fs.listDirSorted(allocator, target.mods) catch return failed.items;
    for (names) |n| {
        const p = try fsmod.join(allocator, &.{ target.mods, n });
        if (std.mem.eql(u8, n, keep) or !isSeed(n) or !env.fs.isDir(p)) continue;
        env.fs.makePath(target.off) catch {};
        var dest = try fsmod.join(allocator, &.{ target.off, n });
        var i: usize = 2;
        while (env.fs.exists(dest)) : (i += 1) dest = try fsmod.join(allocator, &.{ target.off, try std.fmt.allocPrint(allocator, "{s} ({d})", .{ n, i }) });
        env.fs.rename(p, dest) catch try failed.append(allocator, n);
    }
    return failed.items;
}

// ------------------------------------------------------------------------------------- the game must be closed

/// The names of running programs (lower case), or null when they can't be listed.
fn processNames(allocator: Allocator, env: *const Env) ?[][]const u8 {
    const argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "tasklist", "/FO", "CSV", "/NH" } else &.{ "ps", "-A", "-o", "comm=" };
    const result = std.process.run(allocator, env.fs.io, .{ .argv = argv, .stdout_limit = .limited(16 << 20) }) catch return null;
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var name: []const u8 = undefined;
        if (builtin.os.tag == .windows) {
            if (line[0] != '"') continue;
            const end = std.mem.indexOf(u8, line, "\",\"") orelse line.len;
            name = std.mem.trim(u8, line[0..end], "\"");
        } else {
            name = fsmod.basename(line);
        }
        out.append(allocator, std.ascii.allocLowerString(allocator, name) catch return null) catch return null;
    }
    return out.items;
}

/// The name of a running game/emulator program that could have the saves open, "" if none, null if unknown.
pub fn gameRunning(allocator: Allocator, env: *const Env, target: Target) ?[]const u8 {
    const names = processNames(allocator, env) orelse return null;
    var exes: std.ArrayList([]const u8) = .empty;
    if (target.kind == .emulator and target.exe_dir.len > 0) {
        if (env.fs.listDir(allocator, target.exe_dir)) |found| {
            for (found) |n| {
                const lower = std.ascii.allocLowerString(allocator, n) catch continue;
                if (std.mem.endsWith(u8, lower, ".exe")) exes.append(allocator, lower) catch {};
            }
        } else |_| {}
    }
    for (names) |n| {
        switch (target.kind) {
            .longshot => if (std.mem.startsWith(u8, n, "longshot") and std.mem.indexOf(u8, n, "launcher") == null) return n,
            .emulator => {
                for (exes.items) |e| if (std.mem.eql(u8, e, n)) return n;
                const stem = n[0 .. std.mem.indexOfScalar(u8, n, '.') orelse n.len];
                const base = stem[0 .. std.mem.indexOfScalar(u8, stem, '-') orelse stem.len];
                for (emulator_exes) |e| if (std.mem.eql(u8, e, base)) return n;
            },
        }
    }
    return "";
}

// ---------------------------------------------------------------------------------------------------- the swap

/// The seed named in a save folder's marker, or null.
pub fn owner(allocator: Allocator, env: *const Env, save_dir: []const u8) ?[]const u8 {
    const path = fsmod.join(allocator, &.{ save_dir, marker }) catch return null;
    const data = env.fs.readAll(allocator, path) catch return null;
    const name = std.mem.trim(u8, data, " \t\r\n");
    return if (name.len > 0) name else null;
}

fn seedFiles(allocator: Allocator, env: *const Env, d: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const names = env.fs.listDir(allocator, d) catch return out.items;
    for (names) |n| {
        var is_shared = false;
        for (shared) |s| if (std.mem.eql(u8, s, n)) {
            is_shared = true;
        };
        if (!is_shared) try out.append(allocator, n);
    }
    return out.items;
}

fn hasProgress(allocator: Allocator, env: *const Env, d: []const u8) error{OutOfMemory}!bool {
    for (try seedFiles(allocator, env, d)) |n| {
        if (!isSlotName(n)) continue;
        const p = try fsmod.join(allocator, &.{ d, n });
        if (!env.fs.isDir(p)) continue;
        const inside = env.fs.listDir(allocator, p) catch continue;
        if (inside.len > 0) return true;
    }
    return false;
}

fn removeAny(env: *const Env, p: []const u8) void {
    if (env.fs.isDir(p)) env.fs.deleteTree(p) catch {} else env.fs.deleteFile(p) catch {};
}

fn copyItems(allocator: Allocator, env: *const Env, src: []const u8, dst: []const u8, names: []const []const u8, msg: *Messages) SaveError!void {
    env.fs.makePath(dst) catch |err| return msg.fail("couldn't create {s}: {s}", .{ dst, @errorName(err) });
    for (names) |n| {
        const s = try fsmod.join(allocator, &.{ src, n });
        const t = try fsmod.join(allocator, &.{ dst, n });
        removeAny(env, t);
        if (env.fs.isDir(s)) {
            env.fs.copyTree(allocator, s, t) catch |err| return msg.fail("couldn't copy {s}: {s}", .{ s, @errorName(err) });
        } else {
            env.fs.copyFile(s, t) catch |err| return msg.fail("couldn't copy {s}: {s}", .{ s, @errorName(err) });
        }
    }
}

fn storeDir(allocator: Allocator, env: *const Env, target: Target, seed: []const u8, save_dir: []const u8) error{OutOfMemory}!?[]const u8 {
    const folder = (try seedFolder(allocator, env, target, seed)) orelse return null;
    return try fsmod.join(allocator, &.{ folder, store, fsmod.basename(save_dir) });
}

/// settings.txt of the seed folder that holds `store_dir` (<seed>/saves/<account>).
fn identityOf(allocator: Allocator, env: *const Env, store_dir: []const u8) []const u8 {
    const path = fsmod.join(allocator, &.{ fsmod.dirname(fsmod.dirname(store_dir)), "settings.txt" }) catch return "";
    return env.fs.readAll(allocator, path) catch "";
}

/// Do saves stored with settings.txt `recorded` fit the seed folder's settings.txt now (`current`)? They do when both
/// builds place the items the same way (same placement version, seed and settings string), even if a later release
/// rebuilt the seed with fixes. A text that can't be read is compared as it is.
fn savesFitSeed(recorded: []const u8, current: []const u8) bool {
    const recorded_info = seedinfo.parseSettingsText(recorded) orelse return std.mem.eql(u8, recorded, current);
    const current_info = seedinfo.parseSettingsText(current) orelse return std.mem.eql(u8, recorded, current);
    return recorded_info.samePlacements(current_info);
}

/// A timestamp for backup folder names (UTC): YYYYMMDD-HHMMSS.
fn stamp(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const u8 {
    const now = std.Io.Timestamp.now(env.fs.io, .real).toSeconds();
    const secs: u64 = @intCast(@max(now, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// Puts `new_seed`'s save slots into the game, after storing the ones there now. The lines say what happened.
pub fn switchSaves(allocator: Allocator, env: *const Env, target: Target, new_seed: []const u8, msg: *Messages) SaveError!void {
    if (target.save_dirs.len == 0) {
        return msg.add("no {s} save folder yet (the game hasn't saved): {s} starts with new saves", .{ target.kind.label(), new_seed });
    }
    if (gameRunning(allocator, env, target)) |running| {
        if (running.len > 0) return msg.fail("{s} is running; close it first, so its saves can be switched", .{running});
    }
    const backups = try fsmod.join(allocator, &.{ env.app_dir, "save_backups" });
    const when = try stamp(allocator, env);
    for (target.save_dirs) |d| try switchSaveFolder(allocator, env, target, d, new_seed, backups, when, msg);
}

/// Rebuilding `seed` (the same seed made again with fixes, the same placements): its saves stay. The game's slots
/// are never emptied or moved away for it:
///   - slots that are already `seed`'s stay as they are;
///   - slots no seed owns are most likely the ones being played with it: they stay in the game too and become
///     `seed`'s (a copy goes to save_backups first, in case they were another seed's);
///   - slots of another seed are stored with that seed, and `seed`'s stored ones come back, as when switching
///     seeds (nothing is deleted before it is copied).
pub fn keepSavesForRebuild(allocator: Allocator, env: *const Env, target: Target, seed: []const u8, msg: *Messages) SaveError!void {
    if (target.save_dirs.len == 0) return msg.add("no {s} save folder yet: nothing to keep", .{target.kind.label()});
    if (gameRunning(allocator, env, target)) |running| {
        if (running.len > 0) return msg.fail("{s} is running; close it first, so its saves stay with {s}", .{ running, seed });
    }
    const backups = try fsmod.join(allocator, &.{ env.app_dir, "save_backups" });
    const when = try stamp(allocator, env);
    for (target.save_dirs) |d| {
        const account = fsmod.basename(d);
        const old = owner(allocator, env, d);
        if (old != null and std.mem.eql(u8, old.?, seed)) {
            try msg.add("{s}: {s}'s saves stay in the game", .{ account, seed });
            continue;
        }
        if (old == null) {
            const items = try seedFiles(allocator, env, d);
            if (try hasProgress(allocator, env, d)) {
                const copy = try fsmod.join(allocator, &.{ backups, try std.fmt.allocPrint(allocator, "{s} before rebuilding {s} {s}", .{ when, seed, account }) });
                try copyItems(allocator, env, d, copy, items, msg);
                try msg.add("{s}: the game's slots stay in the game as {s}'s (a copy is in {s})", .{ account, seed, copy });
            }
            try writeMarker(allocator, env, d, seed, msg);
            continue;
        }
        try switchSaveFolder(allocator, env, target, d, seed, backups, when, msg);
    }
}

fn writeMarker(allocator: Allocator, env: *const Env, save_dir: []const u8, seed: []const u8, msg: *Messages) SaveError!void {
    const marker_path = try fsmod.join(allocator, &.{ save_dir, marker });
    const text = try std.fmt.allocPrint(allocator, "{s}\n", .{seed});
    env.fs.writeAll(marker_path, text) catch |err| return msg.fail("couldn't write {s}: {s}", .{ marker_path, @errorName(err) });
}

/// One save folder of switchSaves: store the slots there with the seed that owns them, then bring `new_seed`'s.
fn switchSaveFolder(allocator: Allocator, env: *const Env, target: Target, d: []const u8, new_seed: []const u8, backups: []const u8, when: []const u8, msg: *Messages) SaveError!void {
    const account = fsmod.basename(d);
    const old = owner(allocator, env, d);
    if (old != null and std.mem.eql(u8, old.?, new_seed)) {
        return msg.add("{s}: already {s}'s saves", .{ account, new_seed });
    }
    // 1. store what's there now
    const items = try seedFiles(allocator, env, d);
    var dest: ?[]const u8 = if (old) |o| try storeDir(allocator, env, target, o, d) else null;
    var to_backup = false;
    if (dest == null and try hasProgress(allocator, env, d)) {
        dest = try fsmod.join(allocator, &.{ backups, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ when, old orelse "unassigned", account }) });
        to_backup = true;
    }
    if (dest != null and items.len > 0) {
        const dst = dest.?;
        if (env.fs.isDir(dst) and (try seedFiles(allocator, env, dst)).len > 0) {
            // why: an older stored copy of that seed's saves is moved aside, never deleted: the game folder may hold
            // fewer slots than it (or none), and a slot only in the older copy would be lost
            const older = try fsmod.join(allocator, &.{ backups, try std.fmt.allocPrint(allocator, "{s} {s} (older stored saves) {s}", .{ when, old orelse "unassigned", account }) });
            env.fs.makePath(backups) catch {};
            env.fs.rename(dst, older) catch |err| return msg.fail("couldn't move {s}: {s}", .{ dst, @errorName(err) });
            try msg.add("{s}: the older stored saves of {s} were moved to {s}", .{ account, old orelse "no seed", older });
        }
        try copyItems(allocator, env, d, dst, items, msg);
        if (!to_backup) {
            const id_path = try fsmod.join(allocator, &.{ dst, identity });
            env.fs.writeAll(id_path, identityOf(allocator, env, dst)) catch |err| return msg.fail("couldn't write {s}: {s}", .{ id_path, @errorName(err) });
        }
        try msg.add("{s}: saves of {s} kept in {s}", .{ account, old orelse "no seed", dst });
    }
    // 2. bring in the new seed's (or empty slots)
    const src = try storeDir(allocator, env, target, new_seed, d);
    var stored: []const []const u8 = if (src != null and env.fs.isDir(src.?)) try seedFiles(allocator, env, src.?) else &.{};
    if (stored.len > 0) {
        const id_path = try fsmod.join(allocator, &.{ src.?, identity });
        // no record: trust it
        const same = if (env.fs.readAll(allocator, id_path)) |recorded| savesFitSeed(recorded, identityOf(allocator, env, src.?)) else |_| true;
        if (!same) {
            const stale = try fsmod.join(allocator, &.{ backups, try std.fmt.allocPrint(allocator, "{s} {s} (older seed of that name) {s}", .{ when, new_seed, account }) });
            env.fs.makePath(backups) catch {};
            env.fs.rename(src.?, stale) catch |err| return msg.fail("couldn't move {s}: {s}", .{ src.?, @errorName(err) });
            try msg.add("{s}: {s}'s stored saves are from another seed of the same name; moved to {s}", .{ account, new_seed, stale });
            stored = &.{};
        }
    }
    for (items) |n| {
        var in_stored = false;
        for (stored) |stored_name| if (std.mem.eql(u8, stored_name, n)) {
            in_stored = true;
        };
        if (in_stored or isSlotName(n)) removeAny(env, try fsmod.join(allocator, &.{ d, n }));
    }
    if (stored.len > 0) {
        try copyItems(allocator, env, src.?, d, stored, msg);
        try msg.add("{s}: {s}'s saves restored", .{ account, new_seed });
    } else {
        try msg.add("{s}: new saves for {s} (empty slots)", .{ account, new_seed });
    }
    try writeMarker(allocator, env, d, new_seed, msg);
}

/// Switches `name` on (and every other seed off) and gives it its own saves.
pub fn play(allocator: Allocator, env: *const Env, target: Target, name: []const u8, msg: *Messages) SaveError!void {
    if (gameRunning(allocator, env, target)) |running| {
        if (running.len > 0) return msg.fail("{s} is running; close it first", .{running});
    }
    _ = try switchOn(allocator, env, target, name, msg);
    try switchSaves(allocator, env, target, name, msg);
}

test "seed names" {
    try std.testing.expectEqualStrings("GogglesOfTruth_X", seedName("_GogglesOfTruth_X (2)"));
    try std.testing.expectEqualStrings("GogglesOfTruth_X", seedName("GogglesOfTruth_X"));
    try std.testing.expect(isSlotName("slot_03"));
    try std.testing.expect(!isSlotName("slot_x"));
}

/// Test helper: a file with `text` at `folder`/`name` (folders made as needed).
fn writeTestFile(allocator: Allocator, env: *const Env, folder: []const u8, name: []const u8, text: []const u8) !void {
    const path = try fsmod.join(allocator, &.{ folder, name });
    try env.fs.makePath(fsmod.dirname(path));
    try env.fs.writeAll(path, text);
}

fn readTestFile(allocator: Allocator, env: *const Env, folder: []const u8, name: []const u8) ?[]const u8 {
    const path = fsmod.join(allocator, &.{ folder, name }) catch return null;
    return env.fs.readAll(allocator, path) catch null;
}

test "a rebuild keeps the seed's saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fsmod.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    var environ = std.process.Environ.Map.init(a);
    const env = Env{ .environ = &environ, .fs = fsmod.Fs.init(std.testing.io), .app_dir = root };
    const mods = try fsmod.join(a, &.{ root, "mods" });
    const game_saves = try fsmod.join(a, &.{ root, "save", "0000000000000001" });
    const save_dirs = [_][]const u8{game_saves};
    const target = Target{ .kind = .emulator, .mods = mods, .save_dirs = &save_dirs };
    const seed = "GogglesOfTruth_REBUILT";
    const other = "GogglesOfTruth_OTHER";
    const settings_text = "Goggles of Truth Randomizer 0.7.4\nPlacement version: 0.7.3\nSeed: REBUILT\nSettings string: eNqX\n";
    try writeTestFile(a, &env, try fsmod.join(a, &.{ mods, seed }), "settings.txt", settings_text);
    try writeTestFile(a, &env, try fsmod.join(a, &.{ mods, other }), "settings.txt", "Goggles of Truth Randomizer 0.7.4\nPlacement version: 0.7.3\nSeed: OTHER\nSettings string: eNqY\n");

    // 1. slots no seed owns (a seed copied in by hand and played): they stay in the game, now the seed's
    try writeTestFile(a, &env, game_saves, "slot_00/progress.sav", "my playthrough");
    try writeTestFile(a, &env, game_saves, "account.sav", "account");
    var msg = Messages{ .allocator = a };
    try keepSavesForRebuild(a, &env, target, seed, &msg);
    try std.testing.expectEqualStrings("my playthrough", readTestFile(a, &env, game_saves, "slot_00/progress.sav").?);
    try std.testing.expectEqualStrings(seed, owner(a, &env, game_saves).?);
    try std.testing.expect(env.fs.isDir(try fsmod.join(a, &.{ root, "save_backups" })));

    // 2. the seed's own slots: untouched
    try keepSavesForRebuild(a, &env, target, seed, &msg);
    try std.testing.expectEqualStrings("my playthrough", readTestFile(a, &env, game_saves, "slot_00/progress.sav").?);

    // 3. another seed's slots in the game: stored with that seed, and the rebuilt seed's stored slots come back
    //    (stored by an older release with the same placements: they still fit)
    try writeTestFile(a, &env, game_saves, marker, other ++ "\n");
    const stored = try fsmod.join(a, &.{ mods, seed, "saves", "0000000000000001" });
    try env.fs.deleteTree(try fsmod.join(a, &.{ game_saves, "slot_00" }));
    try writeTestFile(a, &env, game_saves, "slot_01/progress.sav", "other seed's save");
    try writeTestFile(a, &env, stored, "slot_00/progress.sav", "my playthrough");
    try writeTestFile(a, &env, stored, identity, "Goggles of Truth Randomizer 0.7.3\nSeed: REBUILT\nSettings string: eNqX\n");
    try keepSavesForRebuild(a, &env, target, seed, &msg);
    try std.testing.expectEqualStrings("my playthrough", readTestFile(a, &env, game_saves, "slot_00/progress.sav").?);
    try std.testing.expect(readTestFile(a, &env, game_saves, "slot_01/progress.sav") == null);
    const other_stored = try fsmod.join(a, &.{ mods, other, "saves", "0000000000000001" });
    try std.testing.expectEqualStrings("other seed's save", readTestFile(a, &env, other_stored, "slot_01/progress.sav").?);
    try std.testing.expectEqualStrings(seed, owner(a, &env, game_saves).?);

    // 4. storing never deletes an older stored copy: the game has no slots of OTHER now, OTHER's stored slot_01 is
    //    moved to save_backups instead of being replaced by nothing
    try writeTestFile(a, &env, game_saves, marker, other ++ "\n");
    try env.fs.deleteTree(try fsmod.join(a, &.{ game_saves, "slot_00" }));
    try switchSaves(a, &env, target, seed, &msg);
    const backup_names = try env.fs.listDir(a, try fsmod.join(a, &.{ root, "save_backups" }));
    var older_copy_found = false;
    for (backup_names) |n| {
        if (std.mem.indexOf(u8, n, "older stored saves") == null) continue;
        const folder = try fsmod.join(a, &.{ root, "save_backups", n });
        if (readTestFile(a, &env, folder, "slot_01/progress.sav")) |text| older_copy_found = std.mem.eql(u8, text, "other seed's save");
    }
    try std.testing.expect(older_copy_found);
}
