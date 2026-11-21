//! Where the engine reports what it is doing ("Scanning stages: Market (12/40)", warnings...) and why it failed.
//!
//! The window passes one that queues the lines for its log; the command-line tool prints them. Failures carry a
//! readable message: a function that fails with a reason calls `fail`, which keeps the message and returns the
//! error, and the caller shows `failureMessage()`.

const std = @import("std");

const Progress = @This();

context: ?*anyopaque,
write_fn: *const fn (context: ?*anyopaque, line: []const u8) void,
/// The message of the last `fail` (empty when there is none).
failure: [2048]u8 = undefined,
failure_len: usize = 0,

/// A Progress that prints every line to stderr.
pub fn stderrPrinter() Progress {
    return Progress{ .context = null, .write_fn = printLine };
}

/// A Progress that drops every line (probing the game data without logging).
pub fn silent() Progress {
    return Progress{ .context = null, .write_fn = dropLine };
}

fn printLine(context: ?*anyopaque, line: []const u8) void {
    _ = context;
    std.debug.print("{s}\n", .{line});
}

fn dropLine(context: ?*anyopaque, line: []const u8) void {
    _ = context;
    _ = line;
}

/// Reports one line. Lines longer than 4 KiB are cut.
pub fn log(self: *Progress, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format, args) catch blk: {
        const cut = "...";
        @memcpy(buffer[buffer.len - cut.len ..], cut);
        break :blk buffer[0..];
    };
    self.write_fn(self.context, line);
}

/// Keeps a failure message and returns `err`, so a caller can write `return progress.fail(error.X, "...", .{})`.
pub fn fail(self: *Progress, err: anytype, comptime format: []const u8, args: anytype) @TypeOf(err) {
    self.setFailure(format, args);
    return err;
}

/// Keeps a failure message without returning an error.
/// The new message may quote the previous one (`failureMessage()`): it is formatted aside, then copied in.
pub fn setFailure(self: *Progress, comptime format: []const u8, args: anytype) void {
    var buffer: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    @memcpy(self.failure[0..text.len], text);
    self.failure_len = text.len;
}

/// The message of the last `fail`, or "" when no failure was recorded.
pub fn failureMessage(self: *const Progress) []const u8 {
    return self.failure[0..self.failure_len];
}

pub fn clearFailure(self: *Progress) void {
    self.failure_len = 0;
}
