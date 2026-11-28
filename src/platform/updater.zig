//! Updates from GitHub: the launcher (src/launcher_flow.zig) asks GitHub for the newest release of the randomizer,
//! and when it is newer than this one, downloads the ZIP made for this system, unpacks it into the program's folder
//! and starts the new window. (Up to 0.8.1 the window had its own Updates card; since 0.8.2 only the launcher
//! updates. The window still calls `removeLeftovers` when it opens.)
//!
//! The releases (.github/workflows/build.yml) are named after the version (tag "0.8.0"), with one ZIP per system:
//! Goggles-of-Truth-<version>-<system>.zip, holding one folder Goggles-of-Truth-<version>-<system>/ with the window,
//! the command-line tool, the Raven library and the documents (on macOS: the .app and the command-line tool).
//!
//! Installing, with the program still running:
//!   1. the ZIP is downloaded and unpacked into <program folder>/.update (its size is checked against GitHub's)
//!   2. the names the release will replace are written to <program folder>/.update-journal (written to a .tmp file
//!      first, then renamed, so it is either whole or missing)
//!   3. each file and folder of the release takes the place of the one in the program folder; the one there is
//!      renamed to <name>.old-update first (a running program and its loaded library can be renamed on every system,
//!      not replaced or deleted on Windows). If a step fails, every name is put back.
//!   4. the programs get their execute permission back (ZIP unpacking doesn't keep it) on Linux and macOS
//!   5. the journal is deleted: the update is complete
//!   6. the new program starts; the old one closes. The next start deletes the .old-update files and .update.
//! If the computer stops between 2 and 5 (power cut, the program killed), the journal is still there at the next
//! start: `undoInterruptedInstall` puts every <name>.old-update back, so the old version is whole again.
//! What the player made (user_settings.toml, custom_presets.toml, cache, save_backups, crash_logs, error_log.txt,
//! seeds) is never in a release; a release entry with one of those names is skipped anyway (`kept_user_files`).
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
/// the list of names an install is replacing, in the program folder while it runs (see the top of the file)
pub const install_journal_name = ".update-journal";
const install_journal_temporary_name = install_journal_name ++ ".tmp";
/// locked for as long as an install runs, so another program starting meanwhile (the window opened by hand while
/// the launcher installs) neither undoes nor cleans up that install. The system drops the lock if the installing
/// program dies, so a lock never outlives it.
pub const install_lock_name = ".update-lock";

/// Takes the install lock: error.InstallFailed when another program is installing an update right now.
fn acquireInstallLock(allocator: Allocator, io: Io, app_folder: []const u8) UpdateError!Io.File {
    const path = std.fs.path.join(allocator, &.{ app_folder, install_lock_name }) catch return error.OutOfMemory;
    const file = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return error.InstallFailed;
    const locked = file.tryLock(io, .exclusive) catch |err| switch (err) {
        // a file system without locks: install without one (nothing else can tell either)
        error.FileLocksUnsupported => return file,
        else => {
            file.close(io);
            return error.InstallFailed;
        },
    };
    if (!locked) {
        file.close(io);
        return error.InstallFailed;
    }
    return file;
}

fn releaseInstallLock(allocator: Allocator, io: Io, app_folder: []const u8, file: Io.File) void {
    file.unlock(io);
    file.close(io);
    const path = std.fs.path.join(allocator, &.{ app_folder, install_lock_name }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Whether another program is installing an update into `app_folder` right now (holds the install lock).
pub fn installIsRunning(allocator: Allocator, io: Io, app_folder: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ app_folder, install_lock_name }) catch return false;
    defer allocator.free(path);
    // no lock file: no install. One that can't be opened (a folder this program can't write): this program couldn't
    // clean up there either, so it doesn't matter.
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return false;
    defer file.close(io);
    const locked = file.tryLock(io, .exclusive) catch return false;
    if (!locked) return true;
    file.unlock(io);
    return false;
}

/// What the player made, in the program folder: never replaced by an update, even if a release held the name.
pub const kept_user_files = [_][]const u8{
    "user_settings.toml",
    "custom_presets.toml",
    "cache",
    "save_backups",
    "crash_logs",
    "error_log.txt",
};

/// True when `name` (an entry of the program folder) is something the player made (`kept_user_files`).
pub fn isKeptUserFile(name: []const u8) bool {
    for (kept_user_files) |kept| {
        if (host.file_names_ignore_case) {
            if (std.ascii.eqlIgnoreCase(name, kept)) return true;
        } else if (std.mem.eql(u8, name, kept)) return true;
    }
    return false;
}

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

/// The name the release workflow gives this system's ZIP (the part after the version), or null for a system that
/// has no release. The ARM builds of Windows and Linux are command-line only ("-cli"): the window is never built
/// there, so only the launcher asks for those.
pub fn releaseSystemName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "windows-x64",
            .aarch64 => "windows-arm64-cli",
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64-cli",
            else => null,
        },
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

/// Where the download is, for a progress bar (the launcher's splash screen): called as the ZIP's bytes arrive.
pub const DownloadProgress = struct {
    context: ?*anyopaque,
    /// `received` bytes of `total` (GitHub's size of the ZIP; 0 when it gave none)
    report: *const fn (context: ?*anyopaque, received: u64, total: u64) void,
};

/// Counts the ZIP's bytes on their way to the file (an `Io.Writer.Hashed` "hasher": it sees every byte written).
const DownloadByteCounter = struct {
    received: u64 = 0,
    total: u64,
    listener: ?DownloadProgress,

    pub fn update(self: *DownloadByteCounter, bytes: []const u8) void {
        self.received += bytes.len;
        if (self.listener) |listener| listener.report(listener.context, self.received, self.total);
    }
};

/// Downloads `release`'s ZIP and puts it in place of this program's files in `app_folder` (see the top of the file).
/// `progress` gets a line per step. After it returns, `startProgram` starts the new program.
pub fn downloadAndInstall(allocator: Allocator, io: Io, release: Release, app_folder: []const u8, progress: *const fn (context: ?*anyopaque, line: []const u8) void, context: ?*anyopaque) UpdateError!void {
    return downloadAndInstallWithProgress(allocator, io, release, app_folder, progress, context, null);
}

/// `downloadAndInstall`, also telling `download_progress` how much of the ZIP has arrived.
pub fn downloadAndInstallWithProgress(allocator: Allocator, io: Io, release: Release, app_folder: []const u8, progress: *const fn (context: ?*anyopaque, line: []const u8) void, context: ?*anyopaque, download_progress: ?DownloadProgress) UpdateError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    // first of all, so nothing else touches the folder's update files meanwhile
    const install_lock = try acquireInstallLock(a, io, app_folder);
    defer releaseInstallLock(a, io, app_folder, install_lock);
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
        // the bytes pass the counter on their way to the file (its small buffer keeps the reports frequent)
        var counter_buffer: [16 * 1024]u8 = undefined;
        var counted = Io.Writer.Hashed(DownloadByteCounter).initHasher(&file_writer.interface, .{
            .total = release.asset_size,
            .listener = download_progress,
        }, &counter_buffer);
        try fetch(allocator, io, release.asset_url, &counted.writer, "application/octet-stream");
        counted.writer.flush() catch return error.InstallFailed;
        file_writer.interface.flush() catch return error.InstallFailed;
    }
    // a download that stopped early (the connection dropped) is never unpacked
    if (release.asset_size > 0) {
        const downloaded = cwd.statFile(io, zip_path, .{}) catch return error.InstallFailed;
        if (downloaded.size != release.asset_size) return error.NetworkFailed;
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
    const names = try releaseEntriesToInstall(a, io, release_folder);
    if (names.len == 0) return error.BadRelease;

    // 2.-3. move it in, keeping the replaced files until the next start (the journal lists them meanwhile)
    progress(context, "Update: installing...");
    try replaceProgramFiles(a, io, release_folder, app_folder, names);

    // 4. execute permissions
    if (Io.File.Permissions.has_executable_bit) markProgramsExecutable(a, io, app_folder);

    // 5. complete: an interrupted start no longer undoes it
    const journal = std.fs.path.join(a, &.{ app_folder, install_journal_name }) catch return error.OutOfMemory;
    cwd.deleteFile(io, journal) catch {};
    progress(context, std.fmt.allocPrint(a, "Update: version {s} installed.", .{release.version}) catch "Update: installed.");
}

/// The entries of the unpacked release to move into the program folder: all of them except what the player makes
/// (`kept_user_files`; a release never holds those, this keeps it that way).
fn releaseEntriesToInstall(allocator: Allocator, io: Io, release_folder: []const u8) UpdateError![]const []const u8 {
    const all = try listNames(allocator, io, release_folder);
    var kept: std.ArrayList([]const u8) = .empty;
    for (all) |name| {
        if (isKeptUserFile(name)) continue;
        kept.append(allocator, name) catch return error.OutOfMemory;
    }
    return kept.items;
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

/// Writes the install journal: `names`, one per line, into <app_folder>/.update-journal, through a .tmp file renamed
/// into place so the journal is never half-written.
fn writeInstallJournal(allocator: Allocator, io: Io, app_folder: []const u8, names: []const []const u8) UpdateError!void {
    const cwd = Io.Dir.cwd();
    const temporary = std.fs.path.join(allocator, &.{ app_folder, install_journal_temporary_name }) catch return error.OutOfMemory;
    const journal = std.fs.path.join(allocator, &.{ app_folder, install_journal_name }) catch return error.OutOfMemory;
    const text = std.mem.join(allocator, "\n", names) catch return error.OutOfMemory;
    cwd.writeFile(io, .{ .sub_path = temporary, .data = text }) catch return error.InstallFailed;
    Io.Dir.rename(cwd, temporary, cwd, journal, io) catch {
        cwd.deleteFile(io, temporary) catch {};
        return error.InstallFailed;
    };
}

fn deleteInstallJournal(allocator: Allocator, io: Io, app_folder: []const u8) void {
    const journal = std.fs.path.join(allocator, &.{ app_folder, install_journal_name }) catch return;
    Io.Dir.cwd().deleteFile(io, journal) catch {};
}

/// Moves every entry `names` of `release_folder` into `app_folder`, the entry there renamed to <name>.old-update
/// first. On a failure every name is put back as it was and the journal is deleted. On success the journal stays:
/// `downloadAndInstall` deletes it once the programs are ready to start.
fn replaceProgramFiles(allocator: Allocator, io: Io, release_folder: []const u8, app_folder: []const u8, names: []const []const u8) UpdateError!void {
    const cwd = Io.Dir.cwd();
    try writeInstallJournal(allocator, io, app_folder, names);
    errdefer deleteInstallJournal(allocator, io, app_folder);
    const Moved = struct { target: []const u8, kept_old: ?[]const u8 };
    var moved: std.ArrayList(Moved) = .empty;
    errdefer {
        // put everything back, newest first
        var i = moved.items.len;
        while (i > 0) {
            i -= 1;
            const m = moved.items[i];
            cwd.deleteTree(io, m.target) catch {};
            if (m.kept_old) |old| moveProgramFile(allocator, io, old, m.target) catch {};
        }
    }
    for (names) |name| {
        const source = std.fs.path.join(allocator, &.{ release_folder, name }) catch return error.OutOfMemory;
        const target = std.fs.path.join(allocator, &.{ app_folder, name }) catch return error.OutOfMemory;
        const old = std.fmt.allocPrint(allocator, "{s}{s}", .{ target, replaced_suffix }) catch return error.OutOfMemory;
        var kept_old: ?[]const u8 = null;
        if (pathExists(io, target)) {
            cwd.deleteTree(io, old) catch {};
            moveProgramFile(allocator, io, target, old) catch return error.InstallFailed;
            kept_old = old;
        }
        moveProgramFile(allocator, io, source, target) catch {
            if (kept_old) |o| moveProgramFile(allocator, io, o, target) catch {};
            return error.InstallFailed;
        };
        moved.append(allocator, .{ .target = target, .kept_old = kept_old }) catch return error.OutOfMemory;
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

const MoveError = error{ MoveFailed, OutOfMemory };

/// Renames the file or folder `from` to `to` (`to` must not exist), also while it is a running program or a loaded
/// library. On Windows that needs MoveFileExW: Zig's rename opens the file for writing first, which Windows refuses
/// for a running .exe or a loaded .dll (the window's raven.dll, or the launcher's own), so before 0.8.2 an update
/// could never move them aside. Linux and macOS rename running files as any other.
fn moveProgramFile(allocator: Allocator, io: Io, from: []const u8, to: []const u8) MoveError!void {
    if (host.host_system != .windows) {
        Io.Dir.rename(Io.Dir.cwd(), from, Io.Dir.cwd(), to, io) catch return error.MoveFailed;
        return;
    }
    const from_wide = try windowsLongPath(allocator, from);
    defer allocator.free(from_wide);
    const to_wide = try windowsLongPath(allocator, to);
    defer allocator.free(to_wide);
    if (windows_file_api.MoveFileExW(from_wide.ptr, to_wide.ptr, move_file_write_through) == 0) return error.MoveFailed;
}

/// MOVEFILE_WRITE_THROUGH: return once the move is on the disk (the install journal counts on it)
const move_file_write_through: u32 = 0x8;

const windows_file_api = if (host.host_system == .windows) struct {
    extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: [*:0]const u16, flags: u32) callconv(.winapi) c_int;
} else struct {};

/// `path` for a Windows file function: UTF-16, with the \\?\ prefix when it is a long absolute path (past the old
/// 260-character limit).
fn windowsLongPath(allocator: Allocator, path: []const u8) MoveError![:0]u16 {
    const long_absolute = path.len >= 240 and path.len > 2 and path[1] == ':';
    const prefixed = if (long_absolute)
        std.fmt.allocPrint(allocator, "\\\\?\\{s}", .{path}) catch return error.OutOfMemory
    else
        allocator.dupe(u8, path) catch return error.OutOfMemory;
    defer allocator.free(prefixed);
    if (long_absolute) std.mem.replaceScalar(u8, prefixed, '/', '\\');
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, prefixed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.MoveFailed,
    };
}

/// The programs a release holds (ZIP unpacking drops their execute permission on Linux and macOS).
fn markProgramsExecutable(allocator: Allocator, io: Io, app_folder: []const u8) void {
    const programs = [_][]const u8{ "goggles_of_truth_rando", "goggles_cli", launcher_program_name };
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
pub const app_bundle_name = version.name ++ ".app";

/// The launcher's program file (build.zig), without .exe.
pub const launcher_program_name = "goggles_launcher";

/// Whether the release for this system has the window (the ARM builds of Windows and Linux are command-line only).
pub const release_has_window: bool = switch (builtin.os.tag) {
    .windows, .linux => builtin.cpu.arch == .x86_64,
    .macos => builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64,
    else => false,
};

/// How the window of the release in `app_folder` is started: the program and its arguments. On macOS the .app is
/// opened with `open` (so it starts like a double click in Finder); elsewhere the program next to the launcher.
/// Null on a system whose release has no window.
pub fn windowStartCommand(allocator: Allocator, app_folder: []const u8) error{OutOfMemory}!?[]const []const u8 {
    if (!release_has_window) return null;
    return switch (host.host_system) {
        .macos => try allocator.dupe([]const u8, &.{ "open", try std.fs.path.join(allocator, &.{ app_folder, app_bundle_name }) }),
        .windows => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ app_folder, "goggles_of_truth_rando.exe" })}),
        .other_unix => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ app_folder, "goggles_of_truth_rando" })}),
    };
}

/// Whether the launcher waits for `windowStartCommand` (macOS' `open` returns once the app is open; elsewhere the
/// command is the window itself, which keeps running).
pub const window_start_command_waits: bool = host.host_system == .macos;

/// The file `windowStartCommand` starts (the program, or the .app on macOS), to see whether it is there.
pub fn windowProgramPath(allocator: Allocator, app_folder: []const u8) error{OutOfMemory}!?[]const u8 {
    const command = (try windowStartCommand(allocator, app_folder)) orelse return null;
    return command[command.len - 1];
}

/// Whether a file or folder is at `path`.
pub fn pathIsThere(io: Io, path: []const u8) bool {
    return pathExists(io, path);
}

fn setExecutable(io: Io, path: []const u8) void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);
    file.setPermissions(io, Io.File.Permissions.fromMode(0o755)) catch {};
}

/// Puts the old version back after an install that was interrupted (the journal is still there, see the top of the
/// file): every listed name with a <name>.old-update gets it back. Names without one are left as they are (new in
/// the release, or not reached yet: a rename is whole or not done, never half). True when there was such an install.
/// An install that is still running in another program (`installIsRunning`) is left alone.
pub fn undoInterruptedInstall(allocator: Allocator, io: Io, app_folder: []const u8) bool {
    if (installIsRunning(allocator, io, app_folder)) return false;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const journal = std.fs.path.join(a, &.{ app_folder, install_journal_name }) catch return false;
    const text = cwd.readFileAlloc(io, journal, a, .limited(1024 * 1024)) catch return false;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |name| {
        // only plain names of the program folder: this file writes the journal, but a path is never trusted
        const is_plain_name = std.mem.indexOfAny(u8, name, "/\\") == null and
            !std.mem.eql(u8, name, "..") and !std.mem.eql(u8, name, ".");
        if (!is_plain_name) continue;
        const target = std.fs.path.join(a, &.{ app_folder, name }) catch continue;
        const old = std.fmt.allocPrint(a, "{s}{s}", .{ target, replaced_suffix }) catch continue;
        if (!pathExists(io, old)) continue;
        cwd.deleteTree(io, target) catch {};
        moveProgramFile(a, io, old, target) catch {};
    }
    cwd.deleteFile(io, journal) catch {};
    return true;
}

/// Deletes what an update left behind: the replaced files (<name>.old-update) and the download folder, after putting
/// an interrupted install back (`undoInterruptedInstall`). Called when the program starts; quiet when there is
/// nothing.
pub fn removeLeftovers(allocator: Allocator, io: Io, app_folder: []const u8) void {
    // another program is installing an update: its files aren't leftovers yet
    if (installIsRunning(allocator, io, app_folder)) return;
    _ = undoInterruptedInstall(allocator, io, app_folder);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const staging = std.fs.path.join(a, &.{ app_folder, staging_folder_name }) catch return;
    cwd.deleteTree(io, staging) catch {};
    const journal_temporary = std.fs.path.join(a, &.{ app_folder, install_journal_temporary_name }) catch return;
    cwd.deleteFile(io, journal_temporary) catch {};
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

test "what the player made is never replaced" {
    try std.testing.expect(isKeptUserFile("user_settings.toml"));
    try std.testing.expect(isKeptUserFile("save_backups"));
    try std.testing.expect(isKeptUserFile("error_log.txt"));
    try std.testing.expect(!isKeptUserFile("goggles_cli"));
    try std.testing.expect(!isKeptUserFile("README.md"));
}

test "an interrupted install is put back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", a);
    // goggles_cli was replaced (the new one in place, the old one kept), raven.dll not reached yet, and the player's
    // settings sit beside them
    try tmp.dir.writeFile(io, .{ .sub_path = "goggles_cli", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "goggles_cli" ++ replaced_suffix, .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "raven.dll", .data = "old library" });
    try tmp.dir.writeFile(io, .{ .sub_path = "user_settings.toml", .data = "mine" });
    try tmp.dir.writeFile(io, .{ .sub_path = install_journal_name, .data = "goggles_cli\nraven.dll\n../outside\n" });
    try std.testing.expect(undoInterruptedInstall(std.testing.allocator, io, folder));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFileAlloc(io, "goggles_cli", a, .limited(64)));
    try std.testing.expectEqualStrings("old library", try tmp.dir.readFileAlloc(io, "raven.dll", a, .limited(64)));
    try std.testing.expectEqualStrings("mine", try tmp.dir.readFileAlloc(io, "user_settings.toml", a, .limited(64)));
    try std.testing.expect(!pathExists(io, try std.fs.path.join(a, &.{ folder, install_journal_name })));
    // nothing interrupted: nothing to do
    try std.testing.expect(!undoInterruptedInstall(std.testing.allocator, io, folder));
}

test "an install that is still running is left alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "goggles_cli", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "goggles_cli" ++ replaced_suffix, .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = install_journal_name, .data = "goggles_cli" });
    const lock = try acquireInstallLock(a, io, folder);
    try std.testing.expect(installIsRunning(std.testing.allocator, io, folder));
    try std.testing.expect(!undoInterruptedInstall(std.testing.allocator, io, folder));
    removeLeftovers(std.testing.allocator, io, folder);
    try std.testing.expectEqualStrings("new", try tmp.dir.readFileAlloc(io, "goggles_cli", a, .limited(64)));
    try std.testing.expect(pathExists(io, try std.fs.path.join(a, &.{ folder, "goggles_cli" ++ replaced_suffix })));
    // a second install can't start meanwhile
    try std.testing.expectError(error.InstallFailed, acquireInstallLock(a, io, folder));
    releaseInstallLock(a, io, folder, lock);
    try std.testing.expect(!installIsRunning(std.testing.allocator, io, folder));
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
