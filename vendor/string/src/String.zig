//! A growable string that owns its bytes through an Allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const str = @import("str.zig");
const buffer = @import("buffer.zig");
const errors = @import("errors.zig");
const AnyString = @import("any_string.zig").AnyString;
const FixedString = @import("fixed_string.zig").FixedString;

const String = @This();

/// Whole allocation; `buf.len` is the capacity.
buf: []u8 = &.{},
len: usize = 0,
allocator: Allocator,

// ── Lifetime ───────────────────────────────────────────────────────────────

/// Empty string. Does not allocate.
pub fn init(a: Allocator) String {
    return .{ .allocator = a };
}
/// Empty string with exactly `n` bytes preallocated.
pub fn initCapacity(a: Allocator, n: usize) Allocator.Error!String {
    return .{ .allocator = a, .buf = try a.alloc(u8, n) };
}
/// Copy `s` into a new allocation.
pub fn from(a: Allocator, s: []const u8) Allocator.Error!String {
    var r = try initCapacity(a, s.len);
    r.appendAssumeCapacity(s);
    return r;
}
/// Formatted construction, sized exactly in one allocation.
pub fn fmt(a: Allocator, comptime f: []const u8, args: anytype) Allocator.Error!String {
    var r = init(a);
    try r.appendFmt(f, args);
    return r;
}
/// Free the buffer. The String is undefined afterwards.
pub fn deinit(self: *String) void {
    self.allocator.free(self.buf);
    self.* = undefined;
}
/// Deep copy using the same allocator.
pub fn clone(self: *const String) Allocator.Error!String {
    return from(self.allocator, self.slice());
}
/// Give the bytes to the caller (free with the same allocator) and reset
/// self to empty. The result is sized exactly to the length.
pub fn toOwnedSlice(self: *String) Allocator.Error![]u8 {
    const out = try self.allocator.realloc(self.buf, self.len);
    self.* = init(self.allocator);
    return out;
}
/// Same as toOwnedSlice, with a null terminator appended.
pub fn toOwnedSliceZ(self: *String) Allocator.Error![:0]u8 {
    const n = self.len;
    const out = try self.allocator.realloc(self.buf, n + 1);
    out[n] = 0;
    self.* = init(self.allocator);
    return out[0..n :0];
}

// ── Interface ──────────────────────────────────────────────────────────────

/// Shared-API handle. Don't move `self` while it is alive.
pub fn any(self: *String) AnyString {
    return .{ .heap = self };
}

// ── Access ─────────────────────────────────────────────────────────────────

pub fn slice(self: *const String) []const u8 {
    return self.buf[0..self.len];
}
pub fn sliceMut(self: *String) []u8 {
    return self.buf[0..self.len];
}
pub fn length(self: *const String) usize {
    return self.len;
}
pub fn capacity(self: *const String) usize {
    return self.buf.len;
}
pub fn remaining(self: *const String) usize {
    return self.buf.len - self.len;
}
pub fn isEmpty(self: *const String) bool {
    return self.len == 0;
}
pub fn at(self: *const String, i: usize) ?u8 {
    return if (i < self.len) self.buf[i] else null;
}

// ── Capacity ───────────────────────────────────────────────────────────────

/// Ensure `additional` more bytes fit without reallocating.
pub fn reserve(self: *String, additional: usize) Allocator.Error!void {
    const needed = std.math.add(usize, self.len, additional) catch return error.OutOfMemory;
    return self.ensureTotalCapacity(needed);
}
/// Ensure capacity >= n. Grows by ~1.5x to keep appends amortized O(1).
pub fn ensureTotalCapacity(self: *String, n: usize) Allocator.Error!void {
    if (self.buf.len >= n) return;
    var new_cap = self.buf.len;
    while (new_cap < n) new_cap +|= new_cap / 2 + 16;
    self.buf = try self.allocator.realloc(self.buf, new_cap);
}
/// Release unused capacity. Keeps the old buffer if the realloc fails.
pub fn shrinkToFit(self: *String) void {
    self.buf = self.allocator.realloc(self.buf, self.len) catch return;
}

// ── Mutation ───────────────────────────────────────────────────────────────

pub fn append(self: *String, s: []const u8) Allocator.Error!void {
    try self.reserve(s.len);
    self.appendAssumeCapacity(s);
}
pub fn appendChar(self: *String, c: u8) Allocator.Error!void {
    try self.reserve(1);
    self.buf[self.len] = c;
    self.len += 1;
}
/// Formats in one pass after sizing the output with std.fmt.count.
pub fn appendFmt(self: *String, comptime f: []const u8, args: anytype) Allocator.Error!void {
    const n = std.fmt.count(f, args);
    try self.reserve(n);
    _ = std.fmt.bufPrint(self.buf[self.len..], f, args) catch unreachable;
    self.len += n;
}
/// Append without growing. Asserts there is room.
pub fn appendAssumeCapacity(self: *String, s: []const u8) void {
    assert(s.len <= self.remaining());
    @memcpy(self.buf[self.len..][0..s.len], s);
    self.len += s.len;
}
pub fn insert(self: *String, i: usize, s: []const u8) Allocator.Error!void {
    assert(i <= self.len);
    try self.reserve(s.len);
    buffer.insertAt(self.buf, self.len, i, s);
    self.len += s.len;
}
pub fn remove(self: *String, start: usize, end: usize) void {
    self.len = buffer.removeRange(self.buf, self.len, start, end);
}
pub fn pop(self: *String) ?u8 {
    if (self.len == 0) return null;
    self.len -= 1;
    return self.buf[self.len];
}
pub fn truncate(self: *String, new_len: usize) void {
    assert(new_len <= self.len);
    self.len = new_len;
}
/// Length to 0, capacity kept.
pub fn clear(self: *String) void {
    self.len = 0;
}
/// Length to 0, buffer freed.
pub fn clearAndFree(self: *String) void {
    self.allocator.free(self.buf);
    self.buf = &.{};
    self.len = 0;
}
/// Replace every `old` (non-empty) with `new`. Returns the count replaced.
/// At most one reallocation.
pub fn replace(self: *String, old: []const u8, new: []const u8) Allocator.Error!usize {
    assert(old.len > 0);
    const new_len = str.replacedLen(self.slice(), old, new);
    try self.ensureTotalCapacity(new_len);
    const n = buffer.replaceInBuffer(self.buf, self.len, old, new);
    self.len = new_len;
    return n;
}
pub fn toUpper(self: *String) void {
    str.toUpperInPlace(self.sliceMut());
}
pub fn toLower(self: *String) void {
    str.toLowerInPlace(self.sliceMut());
}
pub fn reverse(self: *String) void {
    str.reverseInPlace(self.sliceMut());
}

// ── Allocating constructors (caller owns the result) ───────────────────────

/// All parts back to back, in one allocation.
pub fn concat(a: Allocator, parts: []const []const u8) Allocator.Error!String {
    return join(a, "", parts);
}
/// Parts separated by `sep`, in one allocation.
pub fn join(a: Allocator, sep: []const u8, parts: []const []const u8) Allocator.Error!String {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    if (parts.len > 1) total += sep.len * (parts.len - 1);
    var r = try initCapacity(a, total);
    for (parts, 0..) |p, i| {
        if (i > 0) r.appendAssumeCapacity(sep);
        r.appendAssumeCapacity(p);
    }
    return r;
}
/// `s` repeated `n` times.
pub fn repeat(a: Allocator, s: []const u8, n: usize) Allocator.Error!String {
    const total = std.math.mul(usize, s.len, n) catch return error.OutOfMemory;
    var r = try initCapacity(a, total);
    for (0..n) |_| r.appendAssumeCapacity(s);
    return r;
}
/// Collect `str.split` pieces into an array. Pieces point into `s`; free
/// only the outer array with `a.free`.
pub fn splitAlloc(a: Allocator, s: []const u8, delim: []const u8) Allocator.Error![][]const u8 {
    const out = try a.alloc([]const u8, str.count(s, delim) + 1);
    var it = str.split(s, delim);
    var i: usize = 0;
    while (it.next()) |piece| : (i += 1) out[i] = piece;
    return out;
}

// ── Interop ────────────────────────────────────────────────────────────────

/// std.Io.Writer that appends here; see AnyString.writer.
pub fn writer(self: *String) AnyString.Writer {
    return self.any().writer();
}
/// Copy into a stack string; fails if longer than N.
pub fn toFixedString(self: *const String, comptime N: usize) errors.OverflowError!FixedString(N) {
    return FixedString(N).from(self.slice());
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "growth and shrink" {
    var s = String.init(testing.allocator);
    defer s.deinit();
    for (0..100) |i| try s.appendFmt("{d},", .{i});
    try testing.expect(str.startsWith(s.slice(), "0,1,2,") and str.endsWith(s.slice(), "99,"));
    try testing.expect(s.capacity() >= s.length());
    s.shrinkToFit();
    try testing.expectEqual(s.length(), s.capacity());
    s.clearAndFree();
    try testing.expectEqual(@as(usize, 0), s.capacity());
}

test "ownership transfer" {
    const a = testing.allocator;
    var s = try String.from(a, "owned");
    var c = try s.clone();
    s.deinit();

    const owned = try c.toOwnedSlice();
    defer a.free(owned);
    try testing.expectEqualStrings("owned", owned);
    try testing.expect(c.isEmpty());
    c.deinit();

    var z = try String.from(a, "hi");
    const zs = try z.toOwnedSliceZ();
    defer a.free(zs);
    try testing.expectEqual(@as(u8, 0), zs[2]);
    z.deinit();
}

test "insert, remove, replace" {
    var h = try String.from(testing.allocator, "x y z");
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), try h.replace(" ", " and "));
    try testing.expectEqualStrings("x and y and z", h.slice());
    try h.insert(0, "(");
    try h.append(")");
    h.remove(1, 7);
    try testing.expectEqualStrings("(y and z)", h.slice());
}

test "allocating constructors" {
    const a = testing.allocator;
    var j = try String.join(a, ", ", &.{ "x", "y", "z" });
    defer j.deinit();
    try testing.expectEqualStrings("x, y, z", j.slice());

    var c = try String.concat(a, &.{ "ab", "cd" });
    defer c.deinit();
    try testing.expectEqualStrings("abcd", c.slice());

    var r = try String.repeat(a, "ab", 3);
    defer r.deinit();
    try testing.expectEqualStrings("ababab", r.slice());

    const parts = try String.splitAlloc(a, "a/b/c", "/");
    defer a.free(parts);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("c", parts[2]);

    var f = try String.fmt(a, "{s}-{d}", .{ "v", 2 });
    defer f.deinit();
    try testing.expectEqualStrings("v-2", f.slice());
}

test "demote to FixedString" {
    var j = try String.from(testing.allocator, "x, y, z");
    defer j.deinit();
    var fx = try j.toFixedString(16);
    try testing.expectEqualStrings("x, y, z", fx.slice());
    try testing.expectError(error.Overflow, j.toFixedString(3));
}

test "no leaks when allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: Allocator) !void {
            var s = String.init(a);
            defer s.deinit();
            try s.append("hello");
            try s.appendFmt(" {d}", .{12345});
            _ = try s.replace("l", "LLL");
            var j = try String.join(a, "/", &.{ s.slice(), "tail" });
            defer j.deinit();
        }
    }.run, .{});
}
