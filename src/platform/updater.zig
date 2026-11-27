//! Updates from GitHub: the window asks GitHub for the newest release of the randomizer, and when it is newer than
//! this one, downloads the ZIP made for this system, unpacks it into the program's folder and starts the new
//! program (src/ui/App.zig asks the player first).
//!
//! The releases (.github/workflows/build.yml) are named after the version (tag "0.8.0"), with one ZIP per system:
//! Goggles-of-Truth-<version>-<system>.zip, holding one folder Goggles-of-Truth-<version>-<system>/ with the window,
//! the command-line tool, the Raven library and the documents (on macOS: the .app and the command-line tool).
//!
//! Installing, with the program still running:
//!   1. the ZIP is downloaded and unpacked into <program folder>/.update
//!   2. each file and folder of the release takes the place of the one in the program folder; the one there is
//!      renamed to <name>.old-update first (a running program and its loaded library can be renamed on every system,
//!      not replaced or deleted on Windows). If a step fails, every name is put back.
//!   3. the programs get their execute permission back (ZIP unpacking doesn't keep it) on Linux and macOS
//!   4. the new program starts; the old one closes. The next start deletes the .old-update files and .update.
//! What the player made (user_settings.toml, custom_presets.toml, cache, save_backups, crash_logs, seeds) is never
//! in a release, so it is never touched.
//!
//! Agents.md: OS-specific choices (which ZIP, which files are programs) are kept here, in a platform module.

const std = @import("std");
const builtin = @import("builtin");
const version = @import("../version.zig");
const host = @import("host.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const repository = "AbyssDragonModding/Goggles-of-Truth";
pub const releases_page = "https://github.com/" ++ repository ++ "/releases";
const latest_release_api = "https://api.github.com/repos/" ++ repository ++ "/releases/latest";
/// GitHub's API wants a User-Agent: the program's name, nothing about the player
const user_agent = "Goggles-of-Truth-Randomizer/" ++ version.version;

/// the folder the release is downloaded and unpacked into, inside the program folder
pub const staging_folder_name = ".update";
/// what a replaced file or folder is renamed to until the next start deletes it
pub const replaced_suffix = ".old-update";

pub const UpdateError = error{
    /// no connection, GitHub didn't answer, or answered with an error
    NetworkFailed,
    /// GitHub's answer or the ZIP wasn't what a release looks like
    BadRelease,
    /// the files couldn't be written or moved (everything was put back)
    InstallFailed,
    OutOfMemory,
};

/// A release newer than this program, with the ZIP for this system.
pub const Release = struct {
    version: []const u8,
    /// the release's page on GitHub (its notes)
    page_url: []const u8,
    asset_name: []const u8,
    asset_url: []const u8,
    asset_size: u64,
};

/// The name the release workflow gives this system's ZIP (the part after the version), or null for a system whose
/// window isn't released (the ARM builds of Windows and Linux are command-line only).
pub fn releaseSystemName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x64" else null,
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x64" else null,
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "macos-x64",
            .aarch64 => "macos-arm64",
            else => null,
        },
        else => null,
    };
}

/// True when release `candidate` ("0.8.1", or "v0.8.1") is newer than `current`. A tag that isn't a version is
/// never newer.
pub fn isNewerVersion(candidate: []const u8, current: []const u8) bool {
    const trimmed = if (std.mem.startsWith(u8, candidate, "v")) candidate[1..] else candidate;
    const new = std.SemanticVersion.parse(trimmed) catch return false;
    const old = std.SemanticVersion.parse(current) catch return false;
    return std.SemanticVersion.order(new, old) == .gt;
}

const GitHubAsset = struct {
    name: []const u8 = "",
    browser_download_url: []const u8 = "",
    size: u64 = 0,
};

const GitHubRelease = struct {
    tag_name: []const u8 = "",
    html_url: []const u8 = "",
    draft: bool = false,
    prerelease: bool = false,
    assets: []const GitHubAsset = &.{},
};

/// The release GitHub's "latest release" answer (`json`) describes, if it is newer than `current_version` and has
/// the ZIP for `system_name`; null otherwise.
pub fn newerReleaseFromJson(allocator: Allocator, json: []const u8, current_version: []const u8, system_name: []const u8) UpdateError!?Release {
    const parsed = std.json.parseFromSliceLeaky(GitHubRelease, allocator, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadRelease,
    };
    if (parsed.draft or parsed.prerelease) return null;
    if (!isNewerVersion(parsed.tag_name, current_version)) return null;
    const release_version = if (std.mem.startsWith(u8, parsed.tag_name, "v")) parsed.tag_name[1..] else parsed.tag_name;
    const wanted = std.fmt.allocPrint(allocator, "Goggles-of-Truth-{s}-{s}.zip", .{ release_version, system_name }) catch return error.OutOfMemory;
    for (parsed.assets) |asset| {
        if (!std.mem.eql(u8, asset.name, wanted)) continue;
        if (!std.mem.startsWith(u8, asset.browser_download_url, "https://github.com/" ++ repository ++ "/")) return error.BadRelease;
        return Release{
            .version = release_version,
            .page_url = if (parsed.html_url.len > 0) parsed.html_url else releases_page,
            .asset_name = asset.name,
            .asset_url = asset.browser_download_url,
            .asset_size = asset.size,
        };
    }
    return null;
}

/// Asks GitHub for the newest release: the one to install, or null when this program is the newest (or no ZIP is
/// made for this system). Takes a few seconds; run it away from the window's thread.
pub fn findNewerRelease(allocator: Allocator, io: Io) UpdateError!?Release {
    return findReleaseNewerThan(allocator, io, version.version);
}

/// The same, against another version than this program's.
pub fn findReleaseNewerThan(allocator: Allocator, io: Io, current_version: []const u8) UpdateError!?Release {
    const system_name = releaseSystemName() orelse return null;
    var body: Io.Writer.Allocating = .init(allocator);
    try fetch(allocator, io, latest_release_api, &body.writer, "application/vnd.github+json");
    // the release's texts point into the answer: it stays in `allocator`
    return newerReleaseFromJson(allocator, body.written(), current_version, system_name);
}

fn fetch(allocator: Allocator, io: Io, url: []const u8, out: *Io.Writer, accept: []const u8) UpdateError!void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = out,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &.{.{ .name = "accept", .value = accept }},
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NetworkFailed,
    };
    if (result.status != .ok) return error.NetworkFailed;
}

/// Downloads `release`'s ZIP and puts it in place of this program's files in `app_folder` (see the top of the file).
/// `progress` gets a line per step. After it returns, `startProgram` starts the new program.
pub fn downloadAndInstall(allocator: Allocator, io: Io, release: Release, app_folder: []const u8, progress: *const fn (context: ?*anyopaque, line: []const u8) void, context: ?*anyopaque) UpdateError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const staging = std.fs.path.join(a, &.{ app_folder, staging_folder_name }) catch return error.OutOfMemory;
    cwd.deleteTree(io, staging) catch {};
    cwd.createDirPath(io, staging) catch return error.InstallFailed;

    // 1. download
    progress(context, std.fmt.allocPrint(a, "Update: downloading {s} ({d} KB)...", .{ release.asset_name, release.asset_size / 1024 }) catch "Update: downloading...");
    const zip_path = std.fs.path.join(a, &.{ staging, release.asset_name }) catch return error.OutOfMemory;
    {
        const zip_file = cwd.createFile(io, zip_path, .{}) catch return error.InstallFailed;
        defer zip_file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = zip_file.writer(io, &buffer);
        try fetch(allocator, io, release.asset_url, &file_writer.interface, "application/octet-stream");
        file_writer.interface.flush() catch return error.InstallFailed;
    }

    // unpack
    progress(context, "Update: unpacking...");
    const unpacked = std.fs.path.join(a, &.{ staging, "unpacked" }) catch return error.OutOfMemory;
    cwd.createDirPath(io, unpacked) catch return error.InstallFailed;
    {
        const zip_file = cwd.openFile(io, zip_path, .{}) catch return error.InstallFailed;
        defer zip_file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_reader = zip_file.reader(io, &buffer);
        var unpacked_dir = cwd.openDir(io, unpacked, .{}) catch return error.InstallFailed;
        defer unpacked_dir.close(io);
        std.zip.extract(unpacked_dir, &file_reader, .{}) catch return error.BadRelease;
    }
    // the release's one folder (Goggles-of-Truth-<version>-<system>)
    const release_folder_name = std.fmt.allocPrint(a, "Goggles-of-Truth-{s}-{s}", .{ release.version, releaseSystemName() orelse return error.BadRelease }) catch return error.OutOfMemory;
    const release_folder = std.fs.path.join(a, &.{ unpacked, release_folder_name }) catch return error.OutOfMemory;
    const names = try listNames(a, io, release_folder);
    if (names.len == 0) return error.BadRelease;

    // 2. move it in, keeping the replaced files until the next start
    progress(context, "Update: installing...");
    try replaceProgramFiles(a, io, release_folder, app_folder, names);

    // 3. execute permissions
    if (Io.File.Permissions.has_executable_bit) markProgramsExecutable(a, io, app_folder);
    progress(context, std.fmt.allocPrint(a, "Update: version {s} installed.", .{release.version}) catch "Update: installed.");
}

fn listNames(allocator: Allocator, io: Io, folder: []const u8) UpdateError![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return error.BadRelease;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return error.BadRelease) |entry| {
        names.append(allocator, allocator.dupe(u8, entry.name) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }
    return names.items;
}

/// Moves every entry `names` of `release_folder` into `app_folder`, the entry there renamed to <name>.old-update
/// first. On a failure every name is put back as it was.
fn replaceProgramFiles(allocator: Allocator, io: Io, release_folder: []const u8, app_folder: []const u8, names: []const []const u8) UpdateError!void {
    const cwd = Io.Dir.cwd();
    const Moved = struct { target: []const u8, kept_old: ?[]const u8 };
    var moved: std.ArrayList(Moved) = .empty;
    errdefer {
        // put everything back, newest first
        var i = moved.items.len;
        while (i > 0) {
            i -= 1;
            const m = moved.items[i];
            cwd.deleteTree(io, m.target) catch {};
            if (m.kept_old) |old| Io.Dir.rename(cwd, old, cwd, m.target, io) catch {};
        }
    }
    for (names) |name| {
        const source = std.fs.path.join(allocator, &.{ release_folder, name }) catch return error.OutOfMemory;
        const target = std.fs.path.join(allocator, &.{ app_folder, name }) catch return error.OutOfMemory;
        const old = std.fmt.allocPrint(allocator, "{s}{s}", .{ target, replaced_suffix }) catch return error.OutOfMemory;
        var kept_old: ?[]const u8 = null;
        if (pathExists(io, target)) {
            cwd.deleteTree(io, old) catch {};
            Io.Dir.rename(cwd, target, cwd, old, io) catch return error.InstallFailed;
            kept_old = old;
        }
        Io.Dir.rename(cwd, source, cwd, target, io) catch {
            if (kept_old) |o| Io.Dir.rename(cwd, o, cwd, target, io) catch {};
            return error.InstallFailed;
        };
        moved.append(allocator, .{ .target = target, .kept_old = kept_old }) catch return error.OutOfMemory;
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

/// The programs a release holds (ZIP unpacking drops their execute permission on Linux and macOS).
fn markProgramsExecutable(allocator: Allocator, io: Io, app_folder: []const u8) void {
    const programs = [_][]const u8{ "goggles_of_truth_rando", "goggles_cli" };
    for (programs) |program| {
        const path = std.fs.path.join(allocator, &.{ app_folder, program }) catch continue;
        setExecutable(io, path);
    }
    if (host.runs_from_app_bundle) {
        // the window inside the .app (Contents/MacOS holds the program and its library)
        const macos_folder = std.fs.path.join(allocator, &.{ app_folder, app_bundle_name, "Contents", "MacOS" }) catch return;
        const names = listNames(allocator, io, macos_folder) catch return;
        for (names) |name| {
            const path = std.fs.path.join(allocator, &.{ macos_folder, name }) catch continue;
            setExecutable(io, path);
        }
    }
}

/// build.zig's app_name: the macOS app bundle
const app_bundle_name = version.name ++ ".app";

fn setExecutable(io: Io, path: []const u8) void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    file.setPermissions(io, Io.File.Permissions.fromMode(0o755)) catch {};
}

/// Deletes what an update left behind: the replaced files (<name>.old-update) and the download folder. Called when
/// the program starts; quiet when there is nothing.
pub fn removeLeftovers(allocator: Allocator, io: Io, app_folder: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const staging = std.fs.path.join(a, &.{ app_folder, staging_folder_name }) catch return;
    cwd.deleteTree(io, staging) catch {};
    const names = listNames(a, io, app_folder) catch return;
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, replaced_suffix)) continue;
        const path = std.fs.path.join(a, &.{ app_folder, name }) catch continue;
        cwd.deleteTree(io, path) catch {};
    }
}

/// Starts the program at `program_path` (the updated window), detached. The caller then closes itself.
pub fn startProgram(io: Io, program_path: []const u8) UpdateError!void {
    _ = std.process.spawn(io, .{
        .argv = &.{program_path},
        .cwd = .{ .path = std.fs.path.dirname(program_path) orelse "." },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.InstallFailed;
}

test "a newer release is found for this system's ZIP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"tag_name":"0.9.0","html_url":"https://github.com/AbyssDragonModding/Goggles-of-Truth/releases/tag/0.9.0",
        \\ "draft":false,"prerelease":false,"assets":[
        \\  {"name":"Goggles-of-Truth-0.9.0-linux-x64.zip","size":10,
        \\   "browser_download_url":"https://github.com/AbyssDragonModding/Goggles-of-Truth/releases/download/0.9.0/Goggles-of-Truth-0.9.0-linux-x64.zip"},
        \\  {"name":"Goggles-of-Truth-0.9.0-windows-x64.zip","size":20,
        \\   "browser_download_url":"https://github.com/AbyssDragonModding/Goggles-of-Truth/releases/download/0.9.0/Goggles-of-Truth-0.9.0-windows-x64.zip"}]}
    ;
    const found = (try newerReleaseFromJson(a, json, "0.8.0", "windows-x64")).?;
    try std.testing.expectEqualStrings("0.9.0", found.version);
    try std.testing.expectEqual(@as(u64, 20), found.asset_size);
    // the same version, an older one, and a system without a ZIP: nothing to install
    try std.testing.expectEqual(@as(?Release, null), try newerReleaseFromJson(a, json, "0.9.0", "windows-x64"));
    try std.testing.expectEqual(@as(?Release, null), try newerReleaseFromJson(a, json, "1.0.0", "windows-x64"));
    try std.testing.expectEqual(@as(?Release, null), try newerReleaseFromJson(a, json, "0.8.0", "macos-arm64"));
}

test "versions compare as versions" {
    try std.testing.expect(isNewerVersion("0.8.1", "0.8.0"));
    try std.testing.expect(isNewerVersion("v0.10.0", "0.9.9"));
    try std.testing.expect(!isNewerVersion("0.8.0", "0.8.0"));
    try std.testing.expect(!isNewerVersion("latest", "0.8.0"));
}

test "every function compiles" {
    std.testing.refAllDecls(@This());
}
