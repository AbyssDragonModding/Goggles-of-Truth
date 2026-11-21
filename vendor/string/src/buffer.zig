//! Package-internal mutation algorithms over a (buf, len) pair. Callers
//! guarantee capacity first, so nothing here can fail. Both FixedString and
//! String are built on these, which keeps their behavior identical.

const std = @import("std");
const assert = std.debug.assert;
const str = @import("str.zig");

/// Insert `s` at byte index `i`, shifting the tail right.
pub fn insertAt(buf: []u8, len: usize, i: usize, s: []const u8) void {
    assert(i <= len);
    assert(len + s.len <= buf.len);
    std.mem.copyBackwards(u8, buf[i + s.len .. len + s.len], buf[i..len]);
    @memcpy(buf[i..][0..s.len], s);
}

/// Delete `buf[start..end]`, shifting the tail left. Returns the new length.
pub fn removeRange(buf: []u8, len: usize, start: usize, end: usize) usize {
    assert(start <= end and end <= len);
    std.mem.copyForwards(u8, buf[start..], buf[end..len]);
    return len - (end - start);
}

/// Replace every non-overlapping `old` with `new` inside `buf[0..len]`.
/// `buf.len` must be at least `str.replacedLen(buf[0..len], old, new)`.
/// Returns the number of replacements.
///
/// Runs in place in one forward pass. When the result grows, the contents are
/// first shifted right by the total growth, so the write cursor can never
/// overtake the read cursor: after k of n replacements, w - r = k·Δ - n·Δ ≤ 0.
pub fn replaceInBuffer(buf: []u8, len: usize, old: []const u8, new: []const u8) usize {
    assert(old.len > 0);
    const n = str.count(buf[0..len], old);
    if (n == 0) return 0;
    const new_len = len - n * old.len + n * new.len;
    assert(new_len <= buf.len);

    const shift = new_len -| len;
    if (shift > 0) std.mem.copyBackwards(u8, buf[shift .. shift + len], buf[0..len]);

    const end = shift + len;
    var r: usize = shift; // read cursor
    var w: usize = 0; // write cursor, always <= r
    while (std.mem.findPos(u8, buf[0..end], r, old)) |pos| {
        std.mem.copyForwards(u8, buf[w..], buf[r..pos]);
        w += pos - r;
        @memcpy(buf[w..][0..new.len], new);
        w += new.len;
        r = pos + old.len;
    }
    std.mem.copyForwards(u8, buf[w..], buf[r..end]);
    return n;
}

/// Largest n <= max such that s[0..n] does not end mid-codepoint.
pub fn utf8Floor(s: []const u8, max: usize) usize {
    if (max >= s.len) return s.len;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "insertAt and removeRange" {
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..3], "ace");
    insertAt(&buf, 3, 1, "b");
    insertAt(&buf, 4, 3, "d");
    try testing.expectEqualStrings("abcde", buf[0..5]);
    const len = removeRange(&buf, 5, 1, 4);
    try testing.expectEqualStrings("ae", buf[0..len]);
}

test "replaceInBuffer matches std.mem.replaceOwned on random input" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    for (0..5000) |_| {
        var hay: [24]u8 = undefined;
        var old: [3]u8 = undefined;
        var new: [4]u8 = undefined;
        const hl = rnd.uintAtMost(usize, hay.len);
        const ol = 1 + rnd.uintAtMost(usize, old.len - 1);
        const nl = rnd.uintAtMost(usize, new.len);
        for (hay[0..hl]) |*c| c.* = "ab"[rnd.uintLessThan(usize, 2)];
        for (old[0..ol]) |*c| c.* = "ab"[rnd.uintLessThan(usize, 2)];
        @memset(new[0..nl], 'x');

        const expected = try std.mem.replaceOwned(u8, a, hay[0..hl], old[0..ol], new[0..nl]);
        defer a.free(expected);

        var buf: [96]u8 = undefined;
        @memcpy(buf[0..hl], hay[0..hl]);
        const want_len = str.replacedLen(hay[0..hl], old[0..ol], new[0..nl]);
        _ = replaceInBuffer(&buf, hl, old[0..ol], new[0..nl]);
        try testing.expectEqualStrings(expected, buf[0..want_len]);
    }
}

test "utf8Floor never splits a codepoint" {
    try testing.expectEqual(@as(usize, 1), utf8Floor("aé", 2));
    try testing.expectEqual(@as(usize, 3), utf8Floor("aéz", 3));
    try testing.expectEqual(@as(usize, 2), utf8Floor("ab", 10));
}
