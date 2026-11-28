//! goggles_launcher on the command-line only releases (ARM Windows and Linux, where Raven has no library): the
//! launcher's steps (src/launcher_flow.zig) shown as lines in the console. Every release with the window uses the
//! splash screen of src/launcher_window.zig instead; build.zig picks one of the two.

const std = @import("std");
const version = @import("version.zig");
const flow = @import("launcher_flow.zig");
const Io = std.Io;

/// The console lines the player reads.
const ConsoleStatus = struct {
    writer: *Io.Writer,
    /// the last download percentage printed (a line per 10 %)
    last_tenth: u64 = 0,

    fn reporter(self: *ConsoleStatus) flow.StatusReporter {
        return .{ .context = self, .report_phase = onPhase, .report_download = onDownload };
    }

    fn onPhase(context: ?*anyopaque, _: flow.Phase, line: []const u8) void {
        const self: *ConsoleStatus = @ptrCast(@alignCast(context.?));
        self.writer.print("{s}\n", .{line}) catch {};
        self.writer.flush() catch {};
    }

    fn onDownload(context: ?*anyopaque, received: u64, total: u64) void {
        const self: *ConsoleStatus = @ptrCast(@alignCast(context.?));
        if (total == 0) return;
        const tenth = received * 10 / total;
        if (tenth == self.last_tenth) return;
        self.last_tenth = tenth;
        self.writer.print("  {d}% ({d} of {d} KB)\n", .{ tenth * 10, received / 1024, total / 1024 }) catch {};
        self.writer.flush() catch {};
    }
};

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var console = ConsoleStatus{ .writer = &stdout_writer.interface };
    const status = console.reporter();

    const all_arguments = init.minimal.args.toSlice(arena) catch return 1;
    const options = flow.parseLaunchOptions(if (all_arguments.len > 1) all_arguments[1..] else &.{}) catch |err| {
        status.phase(.problem, "{s}: {s}", .{ @errorName(err), flow.usage });
        return 2;
    };
    const launcher_path = std.process.executablePathAlloc(io, arena) catch {
        status.phase(.problem, "The launcher couldn't find its own folder.", .{});
        return 1;
    };
    const app_folder = std.fs.path.dirname(launcher_path) orelse ".";
    status.phase(.checking, "{s} launcher (version {s})", .{ version.name, options.installedVersion() });

    const outcome = flow.runUpdate(init.gpa, io, status, options, launcher_path, app_folder);
    if (options.install_only) return @intFromEnum(outcome.install_only_exit_code);
    if (!options.startsWindow()) return 0;
    const started = flow.startWindow(arena, io, status, app_folder);
    if (outcome.needs_attention or !started) waitBeforeClosing(io, status);
    return if (started) 0 else 1;
}

/// Keeps the console open long enough to read a problem: until Enter when the player can press it, else a few
/// seconds.
fn waitBeforeClosing(io: Io, status: flow.StatusReporter) void {
    const stdin = Io.File.stdin();
    const interactive = stdin.isTty(io) catch false;
    if (interactive) {
        status.phase(.finished, "Press Enter to close.", .{});
        var buffer: [256]u8 = undefined;
        var reader = stdin.readerStreaming(io, &buffer);
        _ = reader.interface.takeDelimiter('\n') catch {};
    } else {
        io.sleep(.fromSeconds(5), .awake) catch {};
    }
}

test {
    _ = flow;
    _ = @import("launcher_splash_model.zig");
}
