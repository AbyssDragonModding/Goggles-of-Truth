//! Read-only operations over `[]const u8`, plus a few in-place byte
//! transforms. FixedString, String and AnyString all forward here.

const std = @import("std");

pub const whitespace: []const u8 = &std.ascii.whitespace;

// ── Comparison ─────────────────────────────────────────────────────────────

/// Byte-wise equality.
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// ASCII case-insensitive equality. Non-ASCII bytes must match exactly.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Lexicographic byte ordering.
pub fn compare(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// True if `s` begins with `prefix`.
pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

/// True if `s` ends with `suffix`.
pub fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

// ── Searching ──────────────────────────────────────────────────────────────

/// Byte index of the first occurrence of `needle`.
pub fn indexOf(s: []const u8, needle: []const u8) ?usize {
    return std.mem.find(u8, s, needle);
}

/// Byte index of the last occurrence of `needle`.
pub fn lastIndexOf(s: []const u8, needle: []const u8) ?usize {
    return std.mem.findLast(u8, s, needle);
}

/// Byte index of the first byte equal to `c`.
pub fn indexOfScalar(s: []const u8, c: u8) ?usize {
    return std.mem.findScalar(u8, s, c);
}

/// Byte index of the first byte that appears in `set`.
pub fn indexOfAny(s: []const u8, set: []const u8) ?usize {
    return std.mem.findAny(u8, s, set);
}

/// True if `needle` occurs anywhere in `s`.
pub fn contains(s: []const u8, needle: []const u8) bool {
    return indexOf(s, needle) != null;
}

/// Number of non-overlapping occurrences of `needle`. Empty needle → 0.
pub fn count(s: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    return std.mem.count(u8, s, needle);
}

// ── Slicing (views, no allocation) ─────────────────────────────────────────

/// `s[start..end]`, or null if the range is out of bounds or reversed.
pub fn substr(s: []const u8, start: usize, end: usize) ?[]const u8 {
    if (start > end or end > s.len) return null;
    return s[start..end];
}

/// Strip ASCII whitespace from both ends.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, whitespace);
}

/// Strip leading ASCII whitespace.
pub fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, whitespace);
}

/// Strip trailing ASCII whitespace.
pub fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, whitespace);
}

/// Strip any bytes in `set` from both ends.
pub fn trimChars(s: []const u8, set: []const u8) []const u8 {
    return std.mem.trim(u8, s, set);
}

// ── Iteration ──────────────────────────────────────────────────────────────

pub const SplitIterator = std.mem.SplitIterator(u8, .sequence);
pub const TokenIterator = std.mem.TokenIterator(u8, .any);

/// Pieces between each `delim` (asserted non-empty). Keeps empty pieces:
/// "a,,b" → "a", "", "b".
pub fn split(s: []const u8, delim: []const u8) SplitIterator {
    return std.mem.splitSequence(u8, s, delim);
}

/// Runs of bytes not in `set`. Skips empty pieces: "a,,b" → "a", "b".
pub fn tokenize(s: []const u8, set: []const u8) TokenIterator {
    return std.mem.tokenizeAny(u8, s, set);
}

/// Lines split on '\n' with a trailing '\r' removed. A final newline does
/// not produce an extra empty line.
pub fn lines(s: []const u8) LineIterator {
    return .{ .inner = std.mem.splitScalar(u8, s, '\n') };
}

pub const LineIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.inner.index) |i| {
            if (i == self.inner.buffer.len) {
                self.inner.index = null;
                return null;
            }
        }
        const line = self.inner.next() orelse return null;
        return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    }
};

/// Iterator over UTF-8 codepoints. Fails if `s` is not valid UTF-8.
pub fn codepoints(s: []const u8) error{InvalidUtf8}!std.unicode.Utf8Iterator {
    const view = try std.unicode.Utf8View.init(s);
    return view.iterator();
}

// ── Parsing / inspection ───────────────────────────────────────────────────

/// Parse an integer. `base` 0 auto-detects 0x / 0o / 0b prefixes.
pub fn parseInt(comptime T: type, s: []const u8, base: u8) std.fmt.ParseIntError!T {
    return std.fmt.parseInt(T, s, base);
}

/// Parse a float.
pub fn parseFloat(comptime T: type, s: []const u8) std.fmt.ParseFloatError!T {
    return std.fmt.parseFloat(T, s);
}

/// True if every byte is < 0x80.
pub fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

/// True if `s` is well-formed UTF-8.
pub fn isValidUtf8(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

/// Number of codepoints. Fails on invalid UTF-8.
pub fn utf8Len(s: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(s);
}

/// 64-bit Wyhash of the bytes. Stable within one build, not across versions.
pub fn hash(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

// ── In-place transforms on mutable bytes ───────────────────────────────────

/// ASCII uppercase in place.
pub fn toUpperInPlace(s: []u8) void {
    for (s) |*c| c.* = std.ascii.toUpper(c.*);
}

/// ASCII lowercase in place.
pub fn toLowerInPlace(s: []u8) void {
    for (s) |*c| c.* = std.ascii.toLower(c.*);
}

/// Reverse bytes in place. Scrambles multi-byte UTF-8 sequences.
pub fn reverseInPlace(s: []u8) void {
    std.mem.reverse(u8, s);
}

/// Length `s` would have after replacing every `old` with `new`.
pub fn replacedLen(s: []const u8, old: []const u8, new: []const u8) usize {
    const n = count(s, old);
    return s.len - n * old.len + n * new.len;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "search, compare, trim" {
    try testing.expectEqual(@as(?usize, 2), indexOf("abcabc", "ca"));
    try testing.expectEqual(@as(?usize, 3), lastIndexOf("abcabc", "abc"));
    try testing.expectEqual(@as(usize, 2), count("aaaa", "aa"));
    try testing.expectEqual(@as(usize, 0), count("abc", ""));
    try testing.expectEqualStrings("hi", trim("  hi\t\n"));
    try testing.expectEqualStrings("hi  ", trimLeft("  hi  "));
    try testing.expectEqualStrings("xhix", trimChars("--xhix--", "-"));
    try testing.expectEqual(@as(?[]const u8, null), substr("abc", 2, 5));
    try testing.expect(eqlIgnoreCase("Hello", "hELLO"));
    try testing.expectEqual(std.math.Order.lt, compare("abc", "abd"));
}

test "split, tokenize, lines" {
    var it = split("a,,b", ",");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expect(it.next() == null);

    var tk = tokenize("a,,b", ",");
    try testing.expectEqualStrings("a", tk.next().?);
    try testing.expectEqualStrings("b", tk.next().?);
    try testing.expect(tk.next() == null);

    var ln = lines("one\r\ntwo\n\nthree\n");
    try testing.expectEqualStrings("one", ln.next().?);
    try testing.expectEqualStrings("two", ln.next().?);
    try testing.expectEqualStrings("", ln.next().?);
    try testing.expectEqualStrings("three", ln.next().?);
    try testing.expect(ln.next() == null);

    var empty = lines("");
    try testing.expect(empty.next() == null);
}

test "utf8 and parsing" {
    try testing.expectEqual(@as(usize, 5), try utf8Len("héllo"));
    try testing.expect(!isAscii("héllo"));
    try testing.expect(!isValidUtf8("\xff"));
    var cp = try codepoints("aé");
    try testing.expectEqual(@as(u21, 'a'), cp.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 'é'), cp.nextCodepoint().?);
    try testing.expectError(error.InvalidUtf8, codepoints("\xff"));
    try testing.expectEqual(@as(i32, -42), try parseInt(i32, "-42", 10));
    try testing.expectEqual(@as(u8, 255), try parseInt(u8, "0xff", 0));
    try testing.expectApproxEqAbs(@as(f32, 1.5), try parseFloat(f32, "1.5"), 1e-6);
}
