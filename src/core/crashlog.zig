//! Crash logs: when the program crashes (a Zig panic, or a crash the system reports: an invalid memory access, an
//! illegal instruction, a stack overflow), a report is written to crash_logs/crash_<date>_<time>.txt next to the
//! program, before the program stops. The report names the program, its version and build, the system, what went
//! wrong and where (the stack trace, with file names and lines when the debug info is there: the .pdb next to the
//! program on Windows). A player attaches that file to a bug report.
//!
//! How it is hooked in: the program's root file (src/main.zig, src/cli.zig) declares
//!
//!     pub const panic = std.debug.FullPanic(engine.crashlog.onPanic);
//!     pub const debug = struct { pub const handleSegfault = engine.crashlog.onSegfault; };
//!     pub const std_options: std.Options = .{ .enable_segfault_handler = true };
//!
//! and calls `install` once it knows the program's folder. Release builds (ReleaseFast) have no segfault handler of
//! their own, hence std_options. After the report, Zig's own handler still prints the crash to the terminal and
//! stops the program.

const std = @import("std");
const builtin = @import("builtin");
const version = @import("../version.zig");
const Io = std.Io;

pub const folder_name = "crash_logs";

/// the folder the program keeps its files in (Env.app_dir), copied: a crash may come after its owner is gone
var app_folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
var app_folder_len: usize = 0;
/// "window" or "command-line tool"
var program_kind: []const u8 = "program";
/// Called after the report is written, with its path (the window shows a message box). Runs while crashing: it must
/// not depend on anything that may be broken.
var after_report: ?*const fn (report_path: []const u8) void = null;
/// set by the first crash: a crash while writing the report doesn't write another
var already_crashing = std.atomic.Value(bool).init(false);

/// Turns the crash reports on: they go to `<app_folder>/crash_logs`.
pub fn install(app_folder: []const u8, kind: []const u8, on_report_written: ?*const fn (report_path: []const u8) void) void {
    const len = @min(app_folder.len, app_folder_buffer.len);
    @memcpy(app_folder_buffer[0..len], app_folder[0..len]);
    app_folder_len = len;
    program_kind = kind;
    after_report = on_report_written;
}

/// The panic handler (std.debug.FullPanic): the report, then Zig's own handler.
pub fn onPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    @branchHint(.cold);
    writeReport("Panic", message, .{ .first_address = first_trace_address orelse @returnAddress() });
    std.debug.defaultPanic(message, first_trace_address);
}

/// The crash handler for what the system reports (root.debug.handleSegfault): the report, then Zig's own handler.
pub fn onSegfault(address: ?usize, name: []const u8, context: ?std.debug.CpuContextPtr) noreturn {
    @branchHint(.cold);
    var what_buffer: [128]u8 = undefined;
    const what = if (address) |a|
        std.fmt.bufPrint(&what_buffer, "{s} at address 0x{x}", .{ name, a }) catch name
    else
        name;
    writeReport("Crash", what, .{ .context = context, .allow_unsafe_unwind = true });
    std.debug.defaultHandleSegfault(address, name, context);
}

fn writeReport(kind: []const u8, what: []const u8, unwind: std.debug.StackUnwindOptions) void {
    if (app_folder_len == 0) return;
    if (already_crashing.swap(true, .seq_cst)) return;
    const io = std.Options.debug_io;
    const app_folder = app_folder_buffer[0..app_folder_len];

    const stamp = DateTime.fromSeconds(Io.Timestamp.now(io, .real).toSeconds());
    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const folder = std.fmt.bufPrint(&folder_buffer, "{s}{c}{s}", .{ app_folder, std.fs.path.sep, folder_name }) catch return;
    Io.Dir.cwd().createDirPath(io, folder) catch return;
    // a second crash in the same second (another program of the randomizer) gets _2, _3...: no report is replaced
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = undefined;
    var file: Io.File = undefined;
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (attempt > 99) return;
        var suffix_buffer: [8]u8 = undefined;
        const suffix = if (attempt == 1) "" else std.fmt.bufPrint(&suffix_buffer, "_{d}", .{attempt}) catch return;
        path = std.fmt.bufPrint(&path_buffer, "{s}{c}crash_{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}{s}.txt", .{
            folder, std.fs.path.sep, stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second, suffix,
        }) catch return;
        file = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return,
        };
        break;
    }
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const w = &file_writer.interface;
    writeReportText(w, kind, what, stamp, unwind) catch {};
    w.flush() catch {};
    if (after_report) |show| show(path);
}

fn writeReportText(w: *Io.Writer, kind: []const u8, what: []const u8, stamp: DateTime, unwind: std.debug.StackUnwindOptions) Io.Writer.Error!void {
    try w.print("{s} crash report\n", .{version.name});
    try w.writeAll("Attach this file to your bug report (GitHub issue or Discord).\n\n");
    try w.print("Version:  {s} ({s} build)\n", .{ version.version, @tagName(builtin.mode) });
    try w.print("Program:  {s}\n", .{program_kind});
    try w.print("System:   {s} {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try w.print("Time:     {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC\n\n", .{ stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second });
    try w.print("{s}: {s}\n\nWhere:\n", .{ kind, what });
    std.debug.writeCurrentStackTrace(unwind, .{ .writer = w, .mode = .no_color }) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
    };
}

/// A UTC date and time of day, from seconds since 1970.
const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    fn fromSeconds(seconds_since_1970: i64) DateTime {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds_since_1970, 0)) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = @as(u8, month_day.day_index) + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
        };
    }
};

test "a date from seconds since 1970" {
    const d = DateTime.fromSeconds(1_795_000_000); // November 2026
    try std.testing.expectEqual(@as(u16, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 11), d.month);
}
