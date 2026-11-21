const std = @import("std");
const Allocator = std.mem.Allocator;

const str = @import("str.zig");
const buffer = @import("buffer.zig");
const errors = @import("errors.zig");
const String = @import("String.zig");
const AnyString = @import("any_string.zig").AnyString;

const OverflowError = errors.OverflowError;

/// A string stored inline with a comptime capacity of N bytes. Lives wherever
/// its owner lives (stack, struct field, global) and never allocates.
/// Mutations are delegated to `AnyString.FixedRef`, which is not generic, so
/// each new N only adds a handful of thin wrappers.
pub fn FixedString(comptime N: usize) type {
    return struct {
        const Self = @This();
        pub const max_len: usize = N;

        buf: [N]u8 = undefined,
        len: usize = 0,

        // ── Construction ───────────────────────────────────────────────────

        /// Empty string.
        pub fn init() Self {
            return .{};
        }
        /// Copy `s`; fails if it is longer than N.
        pub fn from(s: []const u8) OverflowError!Self {
            var r: Self = .{};
            try r.append(s);
            return r;
        }
        /// Copy as much of `s` as fits, cut back so no UTF-8 codepoint is split.
        pub fn fromTruncate(s: []const u8) Self {
            var r: Self = .{};
            const n = buffer.utf8Floor(s, N);
            @memcpy(r.buf[0..n], s[0..n]);
            r.len = n;
            return r;
        }
        /// Formatted construction, e.g. `FixedString(16).fmt("{d}px", .{w})`.
        pub fn fmt(comptime f: []const u8, args: anytype) OverflowError!Self {
            var r: Self = .{};
            try r.appendFmt(f, args);
            return r;
        }

        // ── Interface ──────────────────────────────────────────────────────

        /// Type-erased handle used by AnyString.
        pub fn ref(self: *Self) AnyString.FixedRef {
            return .{ .buf = &self.buf, .len = &self.len };
        }
        /// Shared-API handle. Don't move `self` while it is alive.
        pub fn any(self: *Self) AnyString {
            return .{ .fixed = self.ref() };
        }

        // ── Access ─────────────────────────────────────────────────────────

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn sliceMut(self: *Self) []u8 {
            return self.buf[0..self.len];
        }
        pub fn length(self: *const Self) usize {
            return self.len;
        }
        pub fn capacity(_: *const Self) usize {
            return N;
        }
        pub fn remaining(self: *const Self) usize {
            return N - self.len;
        }
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
        pub fn at(self: *const Self, i: usize) ?u8 {
            return if (i < self.len) self.buf[i] else null;
        }
        /// Null-terminated view. Needs one spare byte, so fails when full.
        /// Invalidated by the next mutation.
        pub fn cStr(self: *Self) OverflowError![:0]const u8 {
            if (self.len >= N) return error.Overflow;
            self.buf[self.len] = 0;
            return self.buf[0..self.len :0];
        }

        // ── Mutation ───────────────────────────────────────────────────────

        pub fn append(self: *Self, s: []const u8) OverflowError!void {
            return self.ref().append(s);
        }
        pub fn appendChar(self: *Self, c: u8) OverflowError!void {
            return self.ref().appendChar(c);
        }
        pub fn appendFmt(self: *Self, comptime f: []const u8, args: anytype) OverflowError!void {
            return self.ref().appendFmt(f, args);
        }
        pub fn insert(self: *Self, i: usize, s: []const u8) OverflowError!void {
            return self.ref().insert(i, s);
        }
        pub fn remove(self: *Self, start: usize, end: usize) void {
            self.ref().remove(start, end);
        }
        pub fn pop(self: *Self) ?u8 {
            return self.ref().pop();
        }
        pub fn truncate(self: *Self, new_len: usize) void {
            self.ref().truncate(new_len);
        }
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
        /// Replace every `old` (non-empty) with `new`. Returns the count replaced.
        pub fn replace(self: *Self, old: []const u8, new: []const u8) OverflowError!usize {
            return self.ref().replace(old, new);
        }
        pub fn toUpper(self: *Self) void {
            str.toUpperInPlace(self.sliceMut());
        }
        pub fn toLower(self: *Self) void {
            str.toLowerInPlace(self.sliceMut());
        }
        pub fn reverse(self: *Self) void {
            str.reverseInPlace(self.sliceMut());
        }

        // ── Interop ────────────────────────────────────────────────────────

        /// std.Io.Writer that appends here; see AnyString.writer.
        pub fn writer(self: *Self) AnyString.Writer {
            return self.any().writer();
        }
        /// Promote to a heap String.
        pub fn toString(self: *const Self, a: Allocator) Allocator.Error!String {
            return String.from(a, self.slice());
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "build, edit, overflow is atomic" {
    var s = try FixedString(8).from("abc");
    try s.append("de");
    try s.appendChar('!');
    try testing.expectEqualStrings("abcde!", s.slice());
    try testing.expectError(error.Overflow, s.append("xyz"));
    try testing.expectEqualStrings("abcde!", s.slice());
    try testing.expectEqual(@as(usize, 2), s.remaining());

    try s.insert(0, ">");
    try testing.expectEqualStrings(">abcde!", s.slice());
    s.remove(1, 3);
    try testing.expectEqualStrings(">cde!", s.slice());
    try testing.expectEqual(@as(?u8, '!'), s.pop());
    s.toUpper();
    try testing.expectEqualStrings(">CDE", s.slice());
    s.reverse();
    try testing.expectEqualStrings("EDC>", s.slice());
    s.truncate(2);
    try testing.expectEqualStrings("ED", s.slice());

    const z = try s.cStr();
    try testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
    var full = try FixedString(2).from("ab");
    try testing.expectError(error.Overflow, full.cStr());
}

test "fmt and fromTruncate" {
    var f = try FixedString(16).fmt("{d}x{d}", .{ 1920, 1080 });
    try testing.expectEqualStrings("1920x1080", f.slice());
    try testing.expectError(error.Overflow, FixedString(4).fmt("{d}", .{123456}));

    const t = FixedString(2).fromTruncate("aé"); // 'é' is 2 bytes
    try testing.expectEqualStrings("a", t.slice());
}

test "replace: shrink, grow, overlap, overflow" {
    var s = try FixedString(32).from("a-b-c");
    try testing.expectEqual(@as(usize, 2), try s.replace("-", "::"));
    try testing.expectEqualStrings("a::b::c", s.slice());
    try testing.expectEqual(@as(usize, 2), try s.replace("::", ""));
    try testing.expectEqualStrings("abc", s.slice());

    var o = try FixedString(32).from("aaaaa");
    try testing.expectEqual(@as(usize, 2), try o.replace("aa", "b"));
    try testing.expectEqualStrings("bba", o.slice());

    var small = try FixedString(5).from("a.b");
    try testing.expectError(error.Overflow, small.replace(".", "...."));
    try testing.expectEqualStrings("a.b", small.slice());
}

test "zero capacity" {
    var s = FixedString(0).init();
    try testing.expect(s.isEmpty());
    try testing.expectError(error.Overflow, s.appendChar('x'));
}

test "promote to String" {
    var f = try FixedString(8).from("stack");
    var h = try f.toString(testing.allocator);
    defer h.deinit();
    try testing.expectEqualStrings("stack", h.slice());
}
