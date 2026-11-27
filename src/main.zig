//! Goggles of Truth Randomizer (an OoT remake randomizer mod): the window.
//!
//! Opens the generator window (src/ui/App.zig). If the window can't open (no Vulkan driver, a broken layout), the
//! reason is shown in a message box and written to error_log.txt next to the program. A crash writes a report to
//! crash_logs next to the program (core/crashlog.zig) and says so in a message box.

const std = @import("std");
const r = @import("raven");
const engine = @import("engine");
const App = @import("ui/App.zig");

pub const panic = std.debug.FullPanic(engine.crashlog.onPanic);
pub const debug = struct {
    pub const handleSegfault = engine.crashlog.onSegfault;
};
pub const std_options: std.Options = .{ .enable_segfault_handler = true };

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const exe_dir = std.process.executableDirPathAlloc(io, init.arena.allocator()) catch ".";
    const app_dir = bundleFolder(exe_dir);
    const env = engine.Env{ .environ = init.environ_map, .fs = engine.fs.Fs.init(io), .app_dir = app_dir };
    engine.crashlog.install(app_dir, "window", showCrashReport);

    App.run(gpa, io, env) catch |err| {
        const reason = if (App.failureMessage().len > 0) App.failureMessage() else @errorName(err);
        reportFailure(init.arena.allocator(), env, reason);
        return 1;
    };
    return 0;
}

/// The folder the program keeps its files in (user_settings.toml, save_backups, error_log.txt): the folder of the
/// program, except on macOS when it runs from "Goggles of Truth Randomizer.app/Contents/MacOS". Files written inside
/// an .app would break its code signature and be lost when the .app is replaced by a new version, so they go next to
/// the .app instead, the same place they have next to the program on Windows and Linux.
fn bundleFolder(exe_dir: []const u8) []const u8 {
    if (!engine.host.runs_from_app_bundle) return exe_dir;
    const contents = std.fs.path.dirname(exe_dir) orelse return exe_dir; // .../X.app/Contents
    const bundle = std.fs.path.dirname(contents) orelse return exe_dir; // .../X.app
    const is_bundle = std.mem.eql(u8, std.fs.path.basename(exe_dir), "MacOS") and
        std.mem.eql(u8, std.fs.path.basename(contents), "Contents") and
        std.mem.endsWith(u8, bundle, ".app");
    if (!is_bundle) return exe_dir;
    return std.fs.path.dirname(bundle) orelse exe_dir;
}

/// Writes the reason to error_log.txt and shows it (a message box when Raven is up, else stderr).
fn reportFailure(allocator: std.mem.Allocator, env: engine.Env, reason: []const u8) void {
    const log = std.fs.path.join(allocator, &.{ env.app_dir, "error_log.txt" }) catch "error_log.txt";
    env.fs.writeAll(log, reason) catch {};
    const text = std.fmt.allocPrintSentinel(allocator, "The randomizer couldn't open:\n{s}\n\nThe details were saved to:\n{s}", .{ reason, log }, 0) catch return;
    std.debug.print("{s}\n", .{text});
    // Raven may not have started (no Vulkan): its message box needs no window
    _ = r.messageBox(null, "Goggles of Truth Randomizer", text, .ok);
}

/// Tells the player where the crash report went (core/crashlog.zig; runs while crashing, so only a fixed buffer).
fn showCrashReport(report_path: []const u8) void {
    var buffer: [std.fs.max_path_bytes + 256]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buffer, "The randomizer crashed and has to close.\n\nA crash report was saved to:\n{s}\n\nPlease attach it to your bug report.", .{report_path}, 0) catch return;
    std.debug.print("{s}\n", .{text});
    _ = r.messageBox(null, "Goggles of Truth Randomizer", text, .ok);
}
