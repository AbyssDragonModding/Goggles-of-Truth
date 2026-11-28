//! What the launcher does, whatever shows it (the splash screen of src/launcher_window.zig, or the console of
//! src/launcher.zig on the command-line only releases):
//!
//!   1. puts back an update that was interrupted last time, and deletes what the last update left behind
//!   2. asks GitHub for the newest release (platform/updater.zig) and compares it with this version
//!   3. when a newer one is out: downloads this system's ZIP, unpacks it into a temporary folder and puts its files in
//!      place of the installed ones, every replaced file kept until the swap is whole (a failure puts them all back).
//!      What the player made (user_settings.toml, cache, save_backups, crash_logs, error_log.txt) is never touched.
//!      When the folder can't be written, the launcher asks for administrator rights (platform/elevation.zig).
//!   4. starts the randomizer window: the updated one, or the installed one when there was no connection or the
//!      update failed. The command-line only releases (ARM Windows and Linux) have no window.
//!
//! Every step tells a `StatusReporter` where it is: a phase, a line for the player, and the download's bytes.
//!
//!   goggles_launcher                       check, update, start the window
//!   goggles_launcher --check-only          only say whether a newer release is out
//!   goggles_launcher --no-launch           check and update, but don't start the window
//!   goggles_launcher --pretend-version V   act as if version V were installed (testing: "0.8.0" finds the newest);
//!                                          debug builds only install an update with this option
//!   goggles_launcher --simulate            show a whole update (checking, downloading, unpacking, installing)
//!                                          slowly, without the network and without changing a file, then close
//!   goggles_launcher --install-only        (used by the launcher itself, with administrator rights) install the
//!                                          newer release and exit: 0 installed, 3 nothing newer, 1 failed

const std = @import("std");
const builtin = @import("builtin");
const version = @import("version.zig");
const updater = @import("platform/updater.zig");
const elevation = @import("platform/elevation.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Debug builds are made from source: an update would replace them with the release (see `--pretend-version`).
const debug_build = builtin.mode == .debug;

/// The exit codes of `--install-only`, read by the launcher that asked for administrator rights.
pub const InstallOnlyExitCode = enum(u8) {
    installed = 0,
    failed = 1,
    nothing_newer = 3,
};

pub const LaunchOptions = struct {
    check_only: bool = false,
    no_launch: bool = false,
    install_only: bool = false,
    simulate: bool = false,
    /// the version to act as installed instead of this one ("" = this one)
    pretend_version: []const u8 = "",

    /// The version the launcher acts as installed.
    pub fn installedVersion(self: LaunchOptions) []const u8 {
        return if (self.pretend_version.len > 0) self.pretend_version else version.version;
    }

    /// Whether the window is started at the end.
    pub fn startsWindow(self: LaunchOptions) bool {
        return !(self.check_only or self.no_launch or self.install_only or self.simulate);
    }
};

pub const ParseError = error{ UnknownOption, MissingValue, NotAVersion };

pub const usage =
    \\usage: goggles_launcher [--check-only] [--no-launch] [--simulate] [--pretend-version VERSION]
    \\
;

/// Reads the launcher's options (`arguments` without the program's own name).
pub fn parseLaunchOptions(arguments: []const []const u8) ParseError!LaunchOptions {
    var options = LaunchOptions{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--check-only")) {
            options.check_only = true;
        } else if (std.mem.eql(u8, argument, "--no-launch")) {
            options.no_launch = true;
        } else if (std.mem.eql(u8, argument, "--install-only")) {
            options.install_only = true;
        } else if (std.mem.eql(u8, argument, "--simulate")) {
            options.simulate = true;
        } else if (std.mem.eql(u8, argument, "--pretend-version")) {
            index += 1;
            if (index >= arguments.len) return error.MissingValue;
            _ = std.SemanticVersion.parse(arguments[index]) catch return error.NotAVersion;
            options.pretend_version = arguments[index];
        } else return error.UnknownOption;
    }
    return options;
}

/// Where the launcher is, for the splash screen's look (the console only prints the lines).
pub const Phase = enum {
    checking,
    up_to_date,
    /// GitHub couldn't be asked: the installed version starts
    offline,
    downloading,
    unpacking,
    installing,
    installed,
    waiting_for_administrator,
    /// something went wrong that the player should read; the installed version starts
    problem,
    starting,
    /// nothing more to do (the command-line only release, or an option that starts no window)
    finished,
};

/// Receives every step: a phase with a line for the player, and the download's bytes. The calls come from the
/// thread running the flow (the splash screen's worker thread).
pub const StatusReporter = struct {
    context: ?*anyopaque,
    report_phase: *const fn (context: ?*anyopaque, phase: Phase, line: []const u8) void,
    report_download: *const fn (context: ?*anyopaque, received: u64, total: u64) void,

    pub fn phase(self: StatusReporter, new_phase: Phase, comptime format: []const u8, arguments: anytype) void {
        var buffer: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, format, arguments) catch buffer[0..];
        self.report_phase(self.context, new_phase, line);
    }

    /// updater.downloadAndInstall's lines ("Update: unpacking..."), as phases
    fn updaterLine(context: ?*anyopaque, line: []const u8) void {
        const self: *const StatusReporter = @ptrCast(@alignCast(context orelse return));
        const text = if (std.mem.startsWith(u8, line, "Update: ")) line["Update: ".len..] else line;
        const step: Phase = if (std.mem.startsWith(u8, text, "downloading"))
            .downloading
        else if (std.mem.startsWith(u8, text, "unpacking"))
            .unpacking
        else if (std.mem.startsWith(u8, text, "installing"))
            .installing
        else if (std.mem.startsWith(u8, text, "version"))
            .installed
        else
            .installing;
        self.report_phase(self.context, step, text);
    }

    fn downloadBytes(context: ?*anyopaque, received: u64, total: u64) void {
        const self: *const StatusReporter = @ptrCast(@alignCast(context orelse return));
        self.report_download(self.context, received, total);
    }
};

pub const UpdateOutcome = struct {
    install_only_exit_code: InstallOnlyExitCode,
    /// something went wrong that the player should read before the launcher closes
    needs_attention: bool = false,
};

/// Steps 1 to 3. `launcher_path` is this program (run again for administrator rights).
pub fn runUpdate(gpa: Allocator, io: Io, status: StatusReporter, options: LaunchOptions, launcher_path: []const u8, app_folder: []const u8) UpdateOutcome {
    if (options.simulate) return simulateUpdate(io, status, options);

    // 1. what the last update left behind
    if (updater.undoInterruptedInstall(gpa, io, app_folder)) {
        status.phase(.checking, "The last update was interrupted: the version you had before is back in place.", .{});
    }
    updater.removeLeftovers(gpa, io, app_folder);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const installed_version = options.installedVersion();

    // 2. a newer release?
    status.phase(.checking, "Checking for a newer version...", .{});
    const found = updater.findReleaseNewerThan(arena, io, installed_version) catch |err| {
        switch (err) {
            error.NetworkFailed => status.phase(.offline, "GitHub couldn't be reached (no internet connection?).{s}", .{fallbackNote(options)}),
            error.BadRelease => status.phase(.offline, "GitHub's answer wasn't what a release looks like.{s}", .{fallbackNote(options)}),
            error.InstallFailed, error.OutOfMemory => status.phase(.offline, "The update check failed ({s}).{s}", .{ @errorName(err), fallbackNote(options) }),
        }
        return .{ .install_only_exit_code = .failed };
    };
    const release = found orelse {
        status.phase(.up_to_date, "You have the newest version ({s}).", .{installed_version});
        return .{ .install_only_exit_code = .nothing_newer };
    };
    status.phase(.checking, "Version {s} is out (you have {s}).", .{ release.version, installed_version });
    if (options.check_only) return .{ .install_only_exit_code = .nothing_newer };
    if (debug_build and options.pretend_version.len == 0) {
        status.phase(.up_to_date, "Version {s} is out. This is a debug build made from source, so it doesn't update itself.", .{release.version});
        return .{ .install_only_exit_code = .nothing_newer };
    }

    // 3. install: by this launcher, or by a copy with administrator rights
    const access = elevation.folderWriteAccess(arena, io, app_folder) catch .writable;
    if (access == .writable or options.install_only) {
        const download_progress = updater.DownloadProgress{ .context = @constCast(@ptrCast(&status)), .report = StatusReporter.downloadBytes };
        updater.downloadAndInstallWithProgress(gpa, io, release, app_folder, StatusReporter.updaterLine, @constCast(@ptrCast(&status)), download_progress) catch |err| {
            status.phase(.problem, "The update couldn't be installed: {s}. Nothing was changed.{s}", .{ installFailureReason(err), fallbackNote(options) });
            return .{ .install_only_exit_code = .failed, .needs_attention = true };
        };
        status.phase(.installed, "Version {s} installed.", .{release.version});
        return .{ .install_only_exit_code = .installed };
    }
    if (access == .read_only) {
        status.phase(.problem, "The randomizer's folder is on a disk that can't be written, so the update can't be installed. Move the folder somewhere you can write, or download version {s} from {s}", .{ release.version, release.page_url });
        return .{ .install_only_exit_code = .failed, .needs_attention = true };
    }
    return installWithAdministratorRights(arena, io, status, options, launcher_path, release);
}

/// What happens instead of the update, for the end of a problem's line.
fn fallbackNote(options: LaunchOptions) []const u8 {
    return if (options.startsWindow()) " Starting the version you have." else "";
}

fn installFailureReason(err: updater.UpdateError) []const u8 {
    return switch (err) {
        error.NetworkFailed => "the download failed or stopped early (no internet connection?)",
        error.BadRelease => "the download isn't a release of the randomizer for this system",
        error.InstallFailed => "the files couldn't be replaced (is another copy of the randomizer open?)",
        error.OutOfMemory => "out of memory",
    };
}

/// The folder needs administrator rights: the launcher runs again with them (`--install-only`) and waits.
fn installWithAdministratorRights(arena: Allocator, io: Io, status: StatusReporter, options: LaunchOptions, launcher_path: []const u8, release: updater.Release) UpdateOutcome {
    status.phase(.waiting_for_administrator, "The randomizer's folder needs administrator rights to be updated: the system asks you for them now.", .{});
    var arguments: std.ArrayList([]const u8) = .empty;
    arguments.append(arena, "--install-only") catch return .{ .install_only_exit_code = .failed };
    if (options.pretend_version.len > 0) {
        arguments.appendSlice(arena, &.{ "--pretend-version", options.pretend_version }) catch return .{ .install_only_exit_code = .failed };
    }
    const result = elevation.runWithAdministratorRights(arena, io, launcher_path, arguments.items) catch {
        status.phase(.problem, "Out of memory.{s}", .{fallbackNote(options)});
        return .{ .install_only_exit_code = .failed, .needs_attention = true };
    };
    switch (result) {
        .finished => |code| {
            if (code == @intFromEnum(InstallOnlyExitCode.installed)) {
                status.phase(.installed, "Version {s} installed.", .{release.version});
                return .{ .install_only_exit_code = .installed };
            }
            if (code == @intFromEnum(InstallOnlyExitCode.nothing_newer)) return .{ .install_only_exit_code = .nothing_newer };
            status.phase(.problem, "The update with administrator rights didn't finish (cancelled, or it failed). Nothing was changed.{s}", .{fallbackNote(options)});
        },
        .declined => status.phase(.problem, "No administrator rights: the update wasn't installed.{s}", .{fallbackNote(options)}),
        .unavailable => |text| {
            var explanation = text;
            defer explanation.deinit();
            status.phase(.problem, "{s}", .{explanation.slice()});
        },
    }
    return .{ .install_only_exit_code = .failed, .needs_attention = true };
}

/// `--simulate`: the steps of an update from this version to a made-up next one, slowly enough to watch, with a
/// made-up download of 4.8 MB. Nothing is downloaded, written or started.
fn simulateUpdate(io: Io, status: StatusReporter, options: LaunchOptions) UpdateOutcome {
    const pause = struct {
        fn milliseconds(io_: Io, count: i64) void {
            io_.sleep(.fromMilliseconds(count), .awake) catch {};
        }
    };
    const installed_version = options.installedVersion();
    const parsed = std.SemanticVersion.parse(installed_version) catch std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
    var next_buffer: [64]u8 = undefined;
    const next_version = std.fmt.bufPrint(&next_buffer, "{d}.{d}.{d}", .{ parsed.major, parsed.minor, parsed.patch + 1 }) catch "next";

    status.phase(.checking, "Simulation (nothing is downloaded or changed). Checking for a newer version...", .{});
    pause.milliseconds(io, 1500);
    status.phase(.checking, "Version {s} is out (you have {s}).", .{ next_version, installed_version });
    pause.milliseconds(io, 1200);

    const total: u64 = 4_925_481;
    status.phase(.downloading, "downloading Goggles-of-Truth-{s}-{s}.zip ({d} KB)...", .{ next_version, updater.releaseSystemName() orelse "system", total / 1024 });
    const steps: u64 = 120;
    var step: u64 = 1;
    while (step <= steps) : (step += 1) {
        pause.milliseconds(io, 45);
        status.report_download(status.context, total * step / steps, total);
    }
    status.phase(.unpacking, "unpacking...", .{});
    pause.milliseconds(io, 1500);
    status.phase(.installing, "installing...", .{});
    pause.milliseconds(io, 1500);
    status.phase(.installed, "Version {s} installed (simulated: your files weren't changed).", .{next_version});
    pause.milliseconds(io, 1500);
    return .{ .install_only_exit_code = .installed };
}

/// Step 4: starts the randomizer window. True when it was started.
pub fn startWindow(arena: Allocator, io: Io, status: StatusReporter, app_folder: []const u8) bool {
    const command = (updater.windowStartCommand(arena, app_folder) catch null) orelse {
        status.phase(.finished, "This download of the randomizer is the command-line tool only (goggles_cli): run it from a terminal.", .{});
        return false;
    };
    const window_path = command[command.len - 1];
    if (!updater.pathIsThere(io, window_path)) {
        status.phase(.problem, "The randomizer isn't next to the launcher ({s} is missing). Download it again from {s}", .{ window_path, updater.releases_page });
        return false;
    }
    status.phase(.starting, "Starting the randomizer...", .{});
    var child = std.process.spawn(io, .{
        .argv = command,
        .cwd = .{ .path = app_folder },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        status.phase(.problem, "The randomizer couldn't be started ({s}).", .{@errorName(err)});
        return false;
    };
    // macOS' `open` returns once the app is open; the window itself keeps running after the launcher closes
    if (updater.window_start_command_waits) _ = child.wait(io) catch {};
    return true;
}

test "the launcher's options" {
    const plain = try parseLaunchOptions(&.{});
    try std.testing.expect(!plain.check_only and !plain.no_launch and !plain.install_only and !plain.simulate);
    try std.testing.expect(plain.startsWindow());
    try std.testing.expectEqualStrings(version.version, plain.installedVersion());
    const testing = try parseLaunchOptions(&.{ "--check-only", "--pretend-version", "0.8.0" });
    try std.testing.expect(testing.check_only and !testing.startsWindow());
    try std.testing.expectEqualStrings("0.8.0", testing.installedVersion());
    try std.testing.expect((try parseLaunchOptions(&.{"--simulate"})).simulate);
    try std.testing.expectError(error.MissingValue, parseLaunchOptions(&.{"--pretend-version"}));
    try std.testing.expectError(error.NotAVersion, parseLaunchOptions(&.{ "--pretend-version", "old" }));
    try std.testing.expectError(error.UnknownOption, parseLaunchOptions(&.{"--fast"}));
}

test "the updater's lines become phases" {
    const Recorder = struct {
        last: Phase = .checking,
        fn onPhase(context: ?*anyopaque, phase: Phase, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.last = phase;
        }
        fn onDownload(_: ?*anyopaque, _: u64, _: u64) void {}
    };
    var recorder = Recorder{};
    const status = StatusReporter{ .context = &recorder, .report_phase = Recorder.onPhase, .report_download = Recorder.onDownload };
    StatusReporter.updaterLine(@constCast(@ptrCast(&status)), "Update: unpacking...");
    try std.testing.expectEqual(Phase.unpacking, recorder.last);
    StatusReporter.updaterLine(@constCast(@ptrCast(&status)), "Update: version 0.8.2 installed.");
    try std.testing.expectEqual(Phase.installed, recorder.last);
}

test {
    _ = updater;
    _ = elevation;
}
