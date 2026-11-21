const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const str = @import("str.zig");
const buffer = @import("buffer.zig");
const errors = @import("errors.zig");
const String = @import("String.zig");

const OverflowError = errors.OverflowError;
const Error = errors.Error;

/// A non-owning handle to either kind of string. Cheap to copy (two words
/// plus a tag). It points at the original, so the original must outlive it
/// and must not move while the handle is in use.
pub const AnyString = union(enum) {
    fixed: FixedRef,
    heap: *String,

    /// Type-erased view of any FixedString(N): its whole buffer plus a pointer
    /// to its length. All FixedString mutation logic lives here, so it is
    /// compiled once rather than once per N.
    pub const FixedRef = struct {
        buf: []u8,
        len: *usize,

        pub fn slice(self: FixedRef) []const u8 {
            return self.buf[0..self.len.*];
        }
        pub fn sliceMut(self: FixedRef) []u8 {
            return self.buf[0..self.len.*];
        }
        pub fn length(self: FixedRef) usize {
            return self.len.*;
        }
        pub fn capacity(self: FixedRef) usize {
            return self.buf.len;
        }
        pub fn remaining(self: FixedRef) usize {
            return self.buf.len - self.len.*;
        }

        pub fn append(self: FixedRef, s: []const u8) OverflowError!void {
            if (s.len > self.remaining()) return error.Overflow;
            @memcpy(self.buf[self.len.*..][0..s.len], s);
            self.len.* += s.len;
        }
        pub fn appendChar(self: FixedRef, c: u8) OverflowError!void {
            if (self.remaining() == 0) return error.Overflow;
            self.buf[self.len.*] = c;
            self.len.* += 1;
        }
        pub fn appendFmt(self: FixedRef, comptime f: []const u8, args: anytype) OverflowError!void {
            const out = std.fmt.bufPrint(self.buf[self.len.*..], f, args) catch return error.Overflow;
            self.len.* += out.len;
        }
        pub fn insert(self: FixedRef, i: usize, s: []const u8) OverflowError!void {
            assert(i <= self.len.*);
            if (s.len > self.remaining()) return error.Overflow;
            buffer.insertAt(self.buf, self.len.*, i, s);
            self.len.* += s.len;
        }
        pub fn remove(self: FixedRef, start: usize, end: usize) void {
            self.len.* = buffer.removeRange(self.buf, self.len.*, start, end);
        }
        pub fn pop(self: FixedRef) ?u8 {
            if (self.len.* == 0) return null;
            self.len.* -= 1;
            return self.buf[self.len.*];
        }
        pub fn truncate(self: FixedRef, new_len: usize) void {
            assert(new_len <= self.len.*);
            self.len.* = new_len;
        }
        pub fn clear(self: FixedRef) void {
            self.len.* = 0;
        }
        pub fn replace(self: FixedRef, old: []const u8, new: []const u8) OverflowError!usize {
            assert(old.len > 0);
            const new_len = str.replacedLen(self.slice(), old, new);
            if (new_len > self.buf.len) return error.Overflow;
            const n = buffer.replaceInBuffer(self.buf, self.len.*, old, new);
            self.len.* = new_len;
            return n;
        }
    };

    // ── Access ─────────────────────────────────────────────────────────────

    /// View of the current contents. Invalidated by the next mutation.
    pub fn slice(self: AnyString) []const u8 {
        return switch (self) {
            inline else => |p| p.slice(),
        };
    }
    /// Mutable view of the current contents.
    pub fn sliceMut(self: AnyString) []u8 {
        return switch (self) {
            inline else => |p| p.sliceMut(),
        };
    }
    /// Current length in bytes.
    pub fn length(self: AnyString) usize {
        return self.slice().len;
    }
    /// Bytes that fit without overflow (fixed) or reallocation (heap).
    pub fn capacity(self: AnyString) usize {
        return switch (self) {
            inline else => |p| p.capacity(),
        };
    }
    /// capacity - length.
    pub fn remaining(self: AnyString) usize {
        return self.capacity() - self.length();
    }
    /// True if length is 0.
    pub fn isEmpty(self: AnyString) bool {
        return self.length() == 0;
    }
    /// Byte at `i`, or null if out of bounds.
    pub fn at(self: AnyString, i: usize) ?u8 {
        const s = self.slice();
        return if (i < s.len) s[i] else null;
    }
    /// True if this handle points at a FixedString.
    pub fn isFixed(self: AnyString) bool {
        return self == .fixed;
    }

    // ── Comparison ─────────────────────────────────────────────────────────

    pub fn eql(self: AnyString, other: []const u8) bool {
        return str.eql(self.slice(), other);
    }
    pub fn eqlIgnoreCase(self: AnyString, other: []const u8) bool {
        return str.eqlIgnoreCase(self.slice(), other);
    }
    pub fn compare(self: AnyString, other: []const u8) std.math.Order {
        return str.compare(self.slice(), other);
    }
    pub fn startsWith(self: AnyString, prefix: []const u8) bool {
        return str.startsWith(self.slice(), prefix);
    }
    pub fn endsWith(self: AnyString, suffix: []const u8) bool {
        return str.endsWith(self.slice(), suffix);
    }

    // ── Searching ──────────────────────────────────────────────────────────

    pub fn indexOf(self: AnyString, needle: []const u8) ?usize {
        return str.indexOf(self.slice(), needle);
    }
    pub fn lastIndexOf(self: AnyString, needle: []const u8) ?usize {
        return str.lastIndexOf(self.slice(), needle);
    }
    pub fn indexOfScalar(self: AnyString, c: u8) ?usize {
        return str.indexOfScalar(self.slice(), c);
    }
    pub fn indexOfAny(self: AnyString, set: []const u8) ?usize {
        return str.indexOfAny(self.slice(), set);
    }
    pub fn contains(self: AnyString, needle: []const u8) bool {
        return str.contains(self.slice(), needle);
    }
    pub fn count(self: AnyString, needle: []const u8) usize {
        return str.count(self.slice(), needle);
    }

    // ── Slicing (views are invalidated by the next mutation) ───────────────

    pub fn substr(self: AnyString, start: usize, end: usize) ?[]const u8 {
        return str.substr(self.slice(), start, end);
    }
    pub fn trim(self: AnyString) []const u8 {
        return str.trim(self.slice());
    }
    pub fn trimLeft(self: AnyString) []const u8 {
        return str.trimLeft(self.slice());
    }
    pub fn trimRight(self: AnyString) []const u8 {
        return str.trimRight(self.slice());
    }
    pub fn trimChars(self: AnyString, set: []const u8) []const u8 {
        return str.trimChars(self.slice(), set);
    }

    // ── Iteration ──────────────────────────────────────────────────────────

    pub fn split(self: AnyString, delim: []const u8) str.SplitIterator {
        return str.split(self.slice(), delim);
    }
    pub fn tokenize(self: AnyString, set: []const u8) str.TokenIterator {
        return str.tokenize(self.slice(), set);
    }
    pub fn lines(self: AnyString) str.LineIterator {
        return str.lines(self.slice());
    }
    pub fn codepoints(self: AnyString) error{InvalidUtf8}!std.unicode.Utf8Iterator {
        return str.codepoints(self.slice());
    }

    // ── Parsing / inspection ───────────────────────────────────────────────

    pub fn parseInt(self: AnyString, comptime T: type, base: u8) std.fmt.ParseIntError!T {
        return str.parseInt(T, self.slice(), base);
    }
    pub fn parseFloat(self: AnyString, comptime T: type) std.fmt.ParseFloatError!T {
        return str.parseFloat(T, self.slice());
    }
    pub fn isAscii(self: AnyString) bool {
        return str.isAscii(self.slice());
    }
    pub fn isValidUtf8(self: AnyString) bool {
        return str.isValidUtf8(self.slice());
    }
    pub fn utf8Len(self: AnyString) !usize {
        return str.utf8Len(self.slice());
    }
    pub fn hash(self: AnyString) u64 {
        return str.hash(self.slice());
    }

    // ── Mutation: fixed fails with Overflow, heap with OutOfMemory ─────────

    pub fn append(self: AnyString, s: []const u8) Error!void {
        switch (self) {
            inline else => |p| try p.append(s),
        }
    }
    pub fn appendChar(self: AnyString, c: u8) Error!void {
        switch (self) {
            inline else => |p| try p.appendChar(c),
        }
    }
    pub fn appendFmt(self: AnyString, comptime f: []const u8, args: anytype) Error!void {
        switch (self) {
            inline else => |p| try p.appendFmt(f, args),
        }
    }
    pub fn insert(self: AnyString, i: usize, s: []const u8) Error!void {
        switch (self) {
            inline else => |p| try p.insert(i, s),
        }
    }
    pub fn remove(self: AnyString, start: usize, end: usize) void {
        switch (self) {
            inline else => |p| p.remove(start, end),
        }
    }
    pub fn pop(self: AnyString) ?u8 {
        return switch (self) {
            inline else => |p| p.pop(),
        };
    }
    pub fn truncate(self: AnyString, new_len: usize) void {
        switch (self) {
            inline else => |p| p.truncate(new_len),
        }
    }
    pub fn clear(self: AnyString) void {
        switch (self) {
            inline else => |p| p.clear(),
        }
    }
    /// Replace every `old` (non-empty) with `new`. Returns the count replaced.
    pub fn replace(self: AnyString, old: []const u8, new: []const u8) Error!usize {
        return switch (self) {
            inline else => |p| try p.replace(old, new),
        };
    }
    pub fn toUpper(self: AnyString) void {
        str.toUpperInPlace(self.sliceMut());
    }
    pub fn toLower(self: AnyString) void {
        str.toLowerInPlace(self.sliceMut());
    }
    pub fn reverse(self: AnyString) void {
        str.reverseInPlace(self.sliceMut());
    }

    // ── Interop ────────────────────────────────────────────────────────────

    /// Copy the contents into a new heap String.
    pub fn toString(self: AnyString, a: Allocator) Allocator.Error!String {
        return String.from(a, self.slice());
    }

    /// A std.Io.Writer that appends to this string. Store the result in a
    /// `var` and write through `&w.interface`; don't move it after that.
    /// A fixed string that runs out of room fails with error.WriteFailed.
    pub fn writer(self: AnyString) Writer {
        return Writer.init(self);
    }

    pub const Writer = struct {
        target: AnyString,
        interface: std.Io.Writer,

        pub fn init(target: AnyString) Writer {
            return .{
                .target = target,
                .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            };
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                self.target.append(bytes) catch return error.WriteFailed;
                n += bytes.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| {
                self.target.append(pattern) catch return error.WriteFailed;
                n += pattern.len;
            }
            return n;
        }
    };
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const FixedString = @import("fixed_string.zig").FixedString;

test "one function, both backings" {
    const helper = struct {
        fn shout(s: AnyString) Error!void {
            s.toUpper();
            try s.append("!");
        }
    };

    var f = try FixedString(8).from("hey");
    var h = try String.from(testing.allocator, "hello");
    defer h.deinit();

    try helper.shout(f.any());
    try helper.shout(h.any());
    try testing.expectEqualStrings("HEY!", f.slice());
    try testing.expectEqualStrings("HELLO!", h.slice());

    const fa = f.any();
    try testing.expect(fa.isFixed() and fa.startsWith("HE") and fa.capacity() == 8);
    try testing.expectError(error.Overflow, fa.append("too long"));
    try testing.expectEqualStrings("HEY!", fa.slice());
    try testing.expect(h.any().contains("LL"));
    try testing.expectEqual(@as(?u8, 'H'), h.any().at(0));
}

test "replace and insert through the interface" {
    var f = try FixedString(16).from("a b c");
    var h = try String.from(testing.allocator, "a b c");
    defer h.deinit();
    for ([_]AnyString{ f.any(), h.any() }) |s| {
        try testing.expectEqual(@as(usize, 2), try s.replace(" ", "--"));
        try s.insert(0, "[");
        try s.appendChar(']');
        try testing.expectEqualStrings("[a--b--c]", s.slice());
    }
}

test "writer prints into either backing" {
    var h = String.init(testing.allocator);
    defer h.deinit();
    var hw = h.writer();
    try hw.interface.print("{s}={d}", .{ "w", 640 });
    try hw.interface.splatByteAll('-', 3);
    try testing.expectEqualStrings("w=640---", h.slice());

    var f = FixedString(4).init();
    var fw = f.writer();
    try testing.expectError(error.WriteFailed, fw.interface.print("{d}", .{123456}));
}
