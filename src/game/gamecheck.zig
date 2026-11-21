//! Game version check: only run on game versions the randomizer is known to work with.
//!
//! The randomizer edits data files whose layout can change between game updates, so a different version could
//! produce a broken mod. The check hashes the game's executable (exefs/main) with SHA-256 and compares it with
//! known_versions. The exefs folder is normally next to the romfs folder (<game>/exefs and <game>/romfs).
//! For a .nup the exefs inside the package the generator reads is checked.
//!
//! To add a version: dump its exefs, run `goggles_cli check <exefs folder or .nup>` and add the printed hash.

const std = @import("std");
const gamefiles = @import("gamefiles.zig");
const hash = @import("../core/hash.zig");
const fsmod = @import("../core/fs.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const Fs = fsmod.Fs;

pub const title_id = "0400486024dec000";

pub const KnownVersion = struct {
    sha256: []const u8,
    name: []const u8,
};

/// SHA-256 of exefs/main -> the version shown to the user.
pub const known_versions = [_]KnownVersion{
    .{ .sha256 = "7db9ddfda088c22d219ef13496decd7077c68cd67d4b37f53f4ac46a082768f2", .name = "v1.1.1" },
};

pub const Status = enum { ok, missing, wrong_game, unsupported };

/// The result of a check. `ok` only for a known version; `message` explains the result.
pub const GameCheck = struct {
    ok: bool,
    status: Status,
    message: []const u8,
    /// the exefs folder or the .nup that was checked
    source: []const u8 = "",
    /// hex SHA-256 of exefs/main, or "" when it couldn't be read
    sha256: []const u8 = "",
    version: []const u8 = "",
};

fn knownVersion(digest: []const u8) ?[]const u8 {
    for (known_versions) |v| {
        if (std.mem.eql(u8, v.sha256, digest)) return v.name;
    }
    return null;
}

/// Program ID from main.npdm's ACI0 section (as lower-case hex), or null if it can't be read.
fn titleIdOf(allocator: Allocator, npdm: []const u8) error{OutOfMemory}!?[]u8 {
    const i = std.mem.indexOf(u8, npdm, "ACI0") orelse return null;
    if (i + 0x18 > npdm.len) return null;
    const id = std.mem.readInt(u64, npdm[i + 0x10 ..][0..8], .little);
    return try std.fmt.allocPrint(allocator, "{x:0>16}", .{id});
}

/// The verdict for a title ID and exefs/main hash read from `source`. Strings are allocated with `allocator`.
fn verdict(allocator: Allocator, source: []const u8, tid: ?[]const u8, digest: []const u8) error{OutOfMemory}!GameCheck {
    if (tid) |t| {
        if (!std.mem.eql(u8, t, title_id)) {
            var upper_t: [16]u8 = undefined;
            var upper_e: [16]u8 = undefined;
            const message = try std.fmt.allocPrint(allocator, "This game is a different title (title ID {s}, expected {s}).", .{
                std.ascii.upperString(&upper_t, t[0..@min(t.len, 16)]), std.ascii.upperString(&upper_e, title_id),
            });
            return GameCheck{ .ok = false, .status = .wrong_game, .message = message, .source = source };
        }
    }
    const version = knownVersion(digest) orelse {
        const message = try std.fmt.allocPrint(allocator, "Sorry, this game version isn't supported. It may be outdated, or newer than this release " ++
            "of the randomizer. Please update the game and the randomizer to their latest versions.\n(SHA-256 of exefs/main: {s})", .{digest});
        return GameCheck{ .ok = false, .status = .unsupported, .message = message, .source = source, .sha256 = digest };
    };
    const message = try std.fmt.allocPrint(allocator, "Supported game version ({s}).", .{version});
    return GameCheck{ .ok = true, .status = .ok, .message = message, .source = source, .sha256 = digest, .version = version };
}

fn missing(allocator: Allocator, comptime format: []const u8, args: anytype, source: []const u8) error{OutOfMemory}!GameCheck {
    return GameCheck{ .ok = false, .status = .missing, .message = try std.fmt.allocPrint(allocator, format, args), .source = source };
}

/// Checks the exefs of the package a .nup's romfs is read from.
pub fn checkNup(allocator: Allocator, fs: Fs, path: []const u8) error{OutOfMemory}!GameCheck {
    var progress = Progress.silent();
    const files = gamefiles.GameFiles.open(allocator, fs, path, &progress) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return missing(allocator, "{s}", .{progress.failureMessage()}, path),
    };
    defer files.deinit();
    const npdm = files.exefsRead(allocator, "main.npdm") catch null;
    defer if (npdm) |n| allocator.free(n);
    const main = files.exefsRead(allocator, "main") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return missing(allocator, "exefs/main in {s} is damaged or unreadable.", .{path}, path),
    };
    const data = main orelse return missing(allocator, "The .nup has no exefs/main to check the game version with.", .{}, path);
    defer allocator.free(data);
    const digest = try allocator.dupe(u8, &hash.hexLower(hash.sha256(data)));
    const tid = if (npdm) |n| try titleIdOf(allocator, n) else null;
    return verdict(allocator, path, tid, digest);
}

/// `<game>/exefs` for a romfs at `<game>/romfs` (or for the game folder itself), or null.
pub fn defaultExefs(allocator: Allocator, fs: Fs, romfs_choice: []const u8) error{OutOfMemory}!?[]u8 {
    const cleaned = try gamefiles.cleanPath(allocator, romfs_choice);
    defer allocator.free(cleaned);
    if (cleaned.len == 0) return null;
    const found = try gamefiles.findRomfs(fs, allocator, cleaned);
    defer if (found) |f| allocator.free(f);
    const romfs = fs.absolute(allocator, found orelse cleaned) catch return null;
    defer allocator.free(romfs);
    const parent_exefs = try fsmod.join(allocator, &.{ fsmod.dirname(romfs), "exefs" });
    defer allocator.free(parent_exefs);
    const inner_exefs = try fsmod.join(allocator, &.{ romfs, "exefs" });
    defer allocator.free(inner_exefs);
    // a folder holding main wins; else any exefs folder
    for ([_][]const u8{ parent_exefs, inner_exefs }) |candidate| {
        const main = try fsmod.join(allocator, &.{ candidate, "main" });
        defer allocator.free(main);
        if (fs.isFile(main)) return try allocator.dupe(u8, candidate);
    }
    for ([_][]const u8{ parent_exefs, inner_exefs }) |candidate| {
        if (fs.isDir(candidate)) return try allocator.dupe(u8, candidate);
    }
    return null;
}

/// Checks a game: `romfs_choice` may be a .nup (its own exefs is checked), else the exefs folder `exefs_choice`
/// (or the one next to the romfs folder when that is empty). Strings in the result are allocated with `allocator`
/// (use an arena).
pub fn check(allocator: Allocator, fs: Fs, exefs_choice: []const u8, romfs_choice: []const u8) error{OutOfMemory}!GameCheck {
    const romfs = try gamefiles.cleanPath(allocator, romfs_choice);
    if (romfs.len > 0 and gamefiles.isNup(fs, romfs)) return checkNup(allocator, fs, romfs);

    var exefs = try gamefiles.cleanPath(allocator, exefs_choice);
    if (exefs.len == 0) exefs = (try defaultExefs(allocator, fs, romfs)) orelse "";
    if (exefs.len == 0) {
        const found = try gamefiles.findRomfs(fs, allocator, romfs);
        if (romfs.len > 0 and found == null) {
            return missing(allocator, "{s} is not the game's romfs folder (it holds Banc, Event, Pack, RSDB...). " ++
                "Choose the romfs folder or the game's .nup file.", .{romfs}, "");
        }
        const where = if (found) |f| fsmod.dirname(f) else "the romfs folder's parent";
        return missing(allocator, "exefs folder not found in {s}. Extract the exefs from your game the same way as the romfs " ++
            "and keep both side by side (<game>/romfs and <game>/exefs), or choose the game's .nup file.", .{where}, "");
    }
    const main = try fsmod.join(allocator, &.{ exefs, "main" });
    if (!fs.isFile(main)) return missing(allocator, "No 'main' file in {s}. Choose the game's extracted exefs folder.", .{exefs}, exefs);

    const data = fs.readAll(allocator, main) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return missing(allocator, "Couldn't read the exefs: {s}", .{@errorName(err)}, exefs),
    };
    defer allocator.free(data);
    const digest = try allocator.dupe(u8, &hash.hexLower(hash.sha256(data)));
    const npdm_path = try fsmod.join(allocator, &.{ exefs, "main.npdm" });
    const npdm = fs.readAll(allocator, npdm_path) catch null;
    defer if (npdm) |n| allocator.free(n);
    const tid = if (npdm) |n| try titleIdOf(allocator, n) else null;
    return verdict(allocator, exefs, tid, digest);
}
