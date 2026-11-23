//! Longshot (https://git.magicbean.dev/MagicBeanDev/Longshot): find its game builds and their mods folder.
//!
//! Longshot runs the game natively on PC. Its launcher builds the game from your own .nup into a game folder,
//! <builds>/<track>/<version> (Games/Longshot/stable/v3.1.1 in your user folder by default; track: stable, nightly
//! or a pull request), and lists every build in builds.json, in the launcher's home (LongshotLauncher's
//! Core/LauncherHome.cs):
//!     Windows: %LOCALAPPDATA%\LongshotLauncher\builds.json
//!     Linux:   ${XDG_DATA_HOME:-~/.local/share}/longshot/launcher/builds.json
//!     both:    $LONGSHOT_LAUNCHER_HOME/builds.json when that is set
//! (0.7.3 and before looked in ~/.local/share/LongshotLauncher on Linux, which the launcher never uses, and only
//! one folder deep under ~/Games/Longshot: Linux users had to choose the mods folder by hand.)
//! Each entry has "folder", "name", "nup" and "default". The launcher's settings.json next to it has "nup" too.
//!
//! Mods go in the game folder's "mods" folder, one folder per mod with a romfs folder inside: exactly what the
//! randomizer writes. Longshot loads every mod in that folder, sorted by name, and skips a folder whose name starts
//! with ".", "-" or "_". Two seeds at once would mix, so writing a seed there renames the older randomizer seeds to
//! "_<name>" (they stay, only switched off).

const std = @import("std");
const builtin = @import("builtin");
const fsmod = @import("../core/fs.zig");
const Env = @import("Env.zig");
const Allocator = std.mem.Allocator;

pub const mod_prefix = "GogglesOfTruth_";
/// seeds made before the 0.6.0 rename
pub const seed_prefixes = [_][]const u8{ mod_prefix, "OoTR_Remake_" };
pub const off_prefixes = [_][]const u8{ ".", "-", "_" };

pub fn isSeedName(name: []const u8) bool {
    for (seed_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

pub fn isSwitchedOff(name: []const u8) bool {
    for (off_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

pub const Build = struct {
    name: []const u8,
    folder: []const u8,
    nup: []const u8 = "",
    default: bool = false,

    pub fn mods(self: Build, allocator: Allocator) error{OutOfMemory}![]const u8 {
        return fsmod.join(allocator, &.{ self.folder, "mods" });
    }
};

/// The launcher's home folders to read, the one it uses first (see the top of this file).
fn launcherDirs(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (env.get("LONGSHOT_LAUNCHER_HOME")) |home_override| try out.append(allocator, try allocator.dupe(u8, home_override));
    if (builtin.os.tag == .windows) {
        const local = try env.localAppData(allocator);
        try out.append(allocator, try fsmod.join(allocator, &.{ local, "LongshotLauncher" }));
        return out.items;
    }
    const data = try env.xdgData(allocator);
    const conf = try env.xdgConfig(allocator);
    try out.append(allocator, try fsmod.join(allocator, &.{ data, "longshot", "launcher" }));
    // older guesses, harmless when they don't exist
    try out.append(allocator, try fsmod.join(allocator, &.{ data, "LongshotLauncher" }));
    try out.append(allocator, try fsmod.join(allocator, &.{ conf, "LongshotLauncher" }));
    return out.items;
}

fn readJson(allocator: Allocator, env: *const Env, path: []const u8) ?std.json.Value {
    const data = env.fs.readAll(allocator, path) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return null;
    return parsed;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// A Longshot game folder: the launcher writes longshot_version.txt there, next to the game.
pub fn isGameFolder(allocator: Allocator, env: *const Env, folder: []const u8) bool {
    if (folder.len == 0) return false;
    const marker = fsmod.join(allocator, &.{ folder, "longshot_version.txt" }) catch return false;
    return env.fs.isFile(marker);
}

/// Natural order of folder names (numbers compared as numbers), as the Python version sorted versions.
fn naturalLess(_: void, a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ad = std.ascii.isDigit(a[i]);
        const bd = std.ascii.isDigit(b[j]);
        if (ad and bd) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const an = std.fmt.parseInt(u64, a[i..ie], 10) catch 0;
            const bn = std.fmt.parseInt(u64, b[j..je], 10) catch 0;
            if (an != bn) return an < bn;
            i = ie;
            j = je;
            continue;
        }
        if (a[i] != b[j]) return a[i] < b[j];
        i += 1;
        j += 1;
    }
    return a.len - i < b.len - j;
}

/// Every Longshot game folder found, the launcher's default build first. Allocated with `allocator` (an arena).
pub fn findBuilds(allocator: Allocator, env: *const Env) error{OutOfMemory}![]Build {
    var builds: std.ArrayList(Build) = .empty;
    var scan: std.ArrayList([]const u8) = .empty;
    try scan.append(allocator, try fsmod.join(allocator, &.{ env.home(), "Games", "Longshot" }));

    for (try launcherDirs(allocator, env)) |d| {
        if (readJson(allocator, env, try fsmod.join(allocator, &.{ d, "builds.json" }))) |data| {
            if (data == .object) {
                if (data.object.get("builds")) |list| if (list == .array) for (list.array.items) |e| {
                    if (e != .object) continue;
                    const folder = jsonString(e.object, "folder") orelse continue;
                    const name = jsonString(e.object, "name") orelse fsmod.basename(folder);
                    const default = if (e.object.get("default")) |v| v == .bool and v.bool else false;
                    try addBuild(allocator, env, &builds, .{
                        .name = if (name.len > 0) name else fsmod.basename(folder),
                        .folder = folder,
                        .nup = jsonString(e.object, "nup") orelse "",
                        .default = default,
                    });
                };
            }
        }
        if (readJson(allocator, env, try fsmod.join(allocator, &.{ d, "settings.json" }))) |data| {
            if (data == .object) if (jsonString(data.object, "buildsFolder")) |bf| if (bf.len > 0) try scan.append(allocator, bf);
        }
    }
    // builds the launcher doesn't list (portable, or made with the command line tools), newest version first:
    // <builds>/<track>/<version> as the launcher makes them, and <builds>/<version> as older ones and the builder's
    // --out did
    for (scan.items) |root| {
        for (try sortedFolderNamesNewestFirst(allocator, env, root)) |n| {
            const folder = try fsmod.join(allocator, &.{ root, n });
            if (isGameFolder(allocator, env, folder)) {
                try addBuild(allocator, env, &builds, .{ .name = n, .folder = folder });
                continue;
            }
            for (try sortedFolderNamesNewestFirst(allocator, env, folder)) |version| {
                try addBuild(allocator, env, &builds, .{ .name = version, .folder = try fsmod.join(allocator, &.{ folder, version }) });
            }
        }
    }
    // stable: the launcher's order, default first
    var out: std.ArrayList(Build) = .empty;
    for (builds.items) |b| if (b.default) try out.append(allocator, b);
    for (builds.items) |b| if (!b.default) try out.append(allocator, b);
    return out.items;
}

fn sortedFolderNamesNewestFirst(allocator: Allocator, env: *const Env, root: []const u8) error{OutOfMemory}![][]u8 {
    const names = env.fs.listDir(allocator, root) catch return &.{};
    std.mem.sort([]u8, names, {}, struct {
        fn more(_: void, x: []u8, y: []u8) bool {
            return naturalLess({}, y, x);
        }
    }.more);
    return names;
}

fn addBuild(allocator: Allocator, env: *const Env, builds: *std.ArrayList(Build), b: Build) error{OutOfMemory}!void {
    const key = env.fs.absolute(allocator, b.folder) catch b.folder;
    for (builds.items) |x| {
        const other = env.fs.absolute(allocator, x.folder) catch x.folder;
        if (fsmod.samePath(key, other)) return;
    }
    if (isGameFolder(allocator, env, b.folder)) try builds.append(allocator, b);
}

/// The .nup the launcher was given (its settings.json), if that file still exists, else "".
pub fn launcherNup(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const u8 {
    for (try launcherDirs(allocator, env)) |d| {
        if (readJson(allocator, env, try fsmod.join(allocator, &.{ d, "settings.json" }))) |data| {
            if (data == .object) if (jsonString(data.object, "nup")) |n| if (env.fs.isFile(n)) return n;
        }
    }
    for (try findBuilds(allocator, env)) |b| {
        if (b.nup.len > 0 and env.fs.isFile(b.nup)) return b.nup;
    }
    return "";
}

/// The version in a game folder's longshot_version.txt ("v3.0.0-rc.4"), or "".
pub fn gameVersion(allocator: Allocator, env: *const Env, folder: []const u8) []const u8 {
    const path = fsmod.join(allocator, &.{ folder, "longshot_version.txt" }) catch return "";
    const data = env.fs.readAll(allocator, path) catch return "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "version=")) return std.mem.trim(u8, line["version=".len..], " \t\r");
    }
    return "";
}

/// "v3.0.0-rc.4" as numbers; a release sorts after its own release candidates. Null if unreadable.
const VersionKey = struct {
    major: u64,
    minor: u64,
    patch: u64,
    release: bool,
    pre_name: []const u8,
    pre_number: u64,

    fn less(a: VersionKey, b: VersionKey) bool {
        if (a.major != b.major) return a.major < b.major;
        if (a.minor != b.minor) return a.minor < b.minor;
        if (a.patch != b.patch) return a.patch < b.patch;
        if (a.release != b.release) return !a.release;
        switch (std.ascii.orderIgnoreCase(a.pre_name, b.pre_name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return a.pre_number < b.pre_number;
    }
};

fn versionKey(v: []const u8) ?VersionKey {
    var s = v;
    if (s.len > 0 and s[0] == 'v') s = s[1..];
    var parts: [3]u64 = undefined;
    var rest = s;
    for (&parts, 0..) |*p, i| {
        var end: usize = 0;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        if (end == 0) return null;
        p.* = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
        rest = rest[end..];
        if (i < 2) {
            if (rest.len == 0 or rest[0] != '.') return null;
            rest = rest[1..];
        }
    }
    var key = VersionKey{ .major = parts[0], .minor = parts[1], .patch = parts[2], .release = true, .pre_name = "", .pre_number = 0 };
    if (rest.len > 1 and rest[0] == '-' and std.ascii.isAlphabetic(rest[1])) {
        var end: usize = 1;
        while (end < rest.len and std.ascii.isAlphabetic(rest[end])) end += 1;
        key.release = false;
        key.pre_name = rest[1..end];
        var num = rest[end..];
        if (num.len > 0 and num[0] == '.') num = num[1..];
        var nend: usize = 0;
        while (nend < num.len and std.ascii.isDigit(num[nend])) nend += 1;
        key.pre_number = if (nend > 0) std.fmt.parseInt(u64, num[0..nend], 10) catch 0 else 0;
    }
    return key;
}

/// True if `path` is a Longshot game folder's mods folder.
pub fn isModsFolder(allocator: Allocator, env: *const Env, path: []const u8) bool {
    if (path.len == 0) return false;
    const abs = env.fs.absolute(allocator, path) catch return false;
    return std.ascii.eqlIgnoreCase(fsmod.basename(abs), "mods") and isGameFolder(allocator, env, fsmod.dirname(abs));
}

/// The launcher's default build if `out` is the mods folder of an older Longshot version, else null. The launcher
/// puts each version in its own folder, so after a Longshot update the saved folder is stale.
pub fn newerBuild(allocator: Allocator, env: *const Env, out: []const u8) error{OutOfMemory}!?Build {
    if (!isModsFolder(allocator, env, out)) return null;
    const builds = try findBuilds(allocator, env);
    if (builds.len == 0 or !builds[0].default) return null;
    const new = builds[0];
    const new_mods = env.fs.absolute(allocator, try new.mods(allocator)) catch return null;
    const out_abs = env.fs.absolute(allocator, out) catch return null;
    if (fsmod.samePath(new_mods, out_abs)) return null;
    const old_v = versionKey(gameVersion(allocator, env, fsmod.dirname(out_abs))) orelse return null;
    const new_v = versionKey(gameVersion(allocator, env, new.folder)) orelse return null;
    return if (VersionKey.less(old_v, new_v)) new else null;
}

pub const Renamed = struct { old: []const u8, new: []const u8 };

/// Renames every other randomizer seed in `mods_dir` to _<name>, so Longshot loads only `keep`.
pub fn switchOffOtherSeeds(allocator: Allocator, env: *const Env, mods_dir: []const u8, keep: []const u8) error{OutOfMemory}![]Renamed {
    var done: std.ArrayList(Renamed) = .empty;
    const names = env.fs.listDirSorted(allocator, mods_dir) catch return done.items;
    for (names) |n| {
        if (std.mem.eql(u8, n, keep) or !isSeedName(n)) continue;
        const from = try fsmod.join(allocator, &.{ mods_dir, n });
        if (!env.fs.isDir(from)) continue;
        var new: []const u8 = try std.fmt.allocPrint(allocator, "_{s}", .{n});
        var i: usize = 2;
        while (env.fs.exists(try fsmod.join(allocator, &.{ mods_dir, new }))) : (i += 1) {
            new = try std.fmt.allocPrint(allocator, "_{s} ({d})", .{ n, i });
        }
        // e.g. the game is running and has it open: left as it is
        env.fs.rename(from, try fsmod.join(allocator, &.{ mods_dir, new })) catch continue;
        try done.append(allocator, .{ .old = n, .new = new });
    }
    return done.items;
}

/// Other randomizer seeds still switched on in `mods_dir` (renaming them failed).
pub fn activeSeeds(allocator: Allocator, env: *const Env, mods_dir: []const u8, keep: []const u8) error{OutOfMemory}![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const names = env.fs.listDir(allocator, mods_dir) catch return out.items;
    for (names) |n| {
        if (!isSeedName(n) or std.mem.eql(u8, n, keep)) continue;
        if (env.fs.isDir(try fsmod.join(allocator, &.{ mods_dir, n }))) try out.append(allocator, n);
    }
    return out.items;
}

test "version keys" {
    const a = versionKey("v3.0.0-rc.4").?;
    const b = versionKey("v3.0.0").?;
    const c = versionKey("v3.0.1-rc.1").?;
    try std.testing.expect(VersionKey.less(a, b));
    try std.testing.expect(VersionKey.less(b, c));
    try std.testing.expect(naturalLess({}, "v2.9", "v2.10"));
}

test "Longshot builds are found the way the launcher lays them out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fsmod.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.resolve(a, &.{root});
    var environ = std.process.Environ.Map.init(a);
    try environ.put("HOME", home);
    try environ.put("USERPROFILE", home);
    try environ.put("XDG_DATA_HOME", try fsmod.join(a, &.{ home, "data" }));
    try environ.put("LOCALAPPDATA", try fsmod.join(a, &.{ home, "local" }));
    const env = Env{ .environ = &environ, .fs = fsmod.Fs.init(std.testing.io), .app_dir = home };

    // a build only in the default builds folder, two levels down: <builds>/<track>/<version>
    const scanned = try fsmod.join(a, &.{ home, "Games", "Longshot", "stable", "v3.1.1" });
    try env.fs.makePath(try fsmod.join(a, &.{ scanned, "mods" }));
    try env.fs.writeAll(try fsmod.join(a, &.{ scanned, "longshot_version.txt" }), "version=v3.1.1\n");
    // a build somewhere else, only listed in the launcher's builds.json (LONGSHOT_LAUNCHER_HOME on every system)
    const listed = try fsmod.join(a, &.{ home, "Elsewhere", "v3.2.0" });
    try env.fs.makePath(listed);
    try env.fs.writeAll(try fsmod.join(a, &.{ listed, "longshot_version.txt" }), "version=v3.2.0\n");
    const launcher_home = try fsmod.join(a, &.{ home, "launcher" });
    try env.fs.makePath(launcher_home);
    var json: std.ArrayList(u8) = .empty;
    try json.print(a, "{{\"format\":1,\"builds\":[{{\"name\":\"v3.2.0\",\"folder\":{f},\"default\":true}}]}}", .{std.json.fmt(listed, .{})});
    try env.fs.writeAll(try fsmod.join(a, &.{ launcher_home, "builds.json" }), json.items);
    try environ.put("LONGSHOT_LAUNCHER_HOME", launcher_home);

    const builds = try findBuilds(a, &env);
    try std.testing.expectEqual(@as(usize, 2), builds.len);
    try std.testing.expectEqualStrings("v3.2.0", builds[0].name); // the launcher's default first
    try std.testing.expectEqualStrings("v3.1.1", builds[1].name);
    try std.testing.expect(isModsFolder(a, &env, try fsmod.join(a, &.{ scanned, "mods" })));
}
