//! `zig build run-example`

const std = @import("std");
const string = @import("string");

const FixedString = string.FixedString;
const String = string.String;
const AnyString = string.AnyString;

/// Works on stack and heap strings alike.
fn normalizePath(s: AnyString) string.Error!void {
    _ = try s.replace("\\", "/");
    while (s.endsWith("/")) _ = s.pop();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // Stack: fixed capacity, no allocator.
    var name = try FixedString(64).from("C:\\assets\\meshes\\");
    try normalizePath(name.any());

    // Heap: grows as needed.
    var report = String.init(a);
    defer report.deinit();
    try report.appendFmt("path  = {s}\n", .{name.slice()});

    // Shared read-only API through either backing.
    var it = name.any().split("/");
    while (it.next()) |part| try report.appendFmt("  part: {s}\n", .{part});

    // std.Io.Writer adapter.
    var w = report.writer();
    try w.interface.print("bytes = {d}, utf8 = {}\n", .{ report.length(), report.any().isValidUtf8() });

    // Overflow is an error, not a crash, and leaves the string unchanged.
    var tiny = try FixedString(4).from("abc");
    tiny.append("def") catch |err| try report.appendFmt("tiny  = {s} ({s})\n", .{ tiny.slice(), @errorName(err) });

    std.debug.print("{s}", .{report.slice()});
}
