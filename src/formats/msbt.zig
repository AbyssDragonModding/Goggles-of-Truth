//! MSBT message files (Mals/*.sarc.zs → *.msbt): labels and texts, read and rewritten.
//!
//! Texts are kept raw (with their control tags and terminator) for editing. `parse` decodes them to plain UTF-8
//! (tags removed) for names shown in the spoiler log.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const MsbtError = error{ InvalidData, OutOfMemory };

pub const Section = struct {
    magic: []const u8,
    offset: usize,
    size: usize,
};

/// The sections of a file, in order.
pub fn sections(allocator: Allocator, d: []const u8) MsbtError![]Section {
    if (d.len < 0x20) return error.InvalidData;
    const count = try bytes.u16At(d, 0xE);
    const out = allocator.alloc(Section, count) catch return error.OutOfMemory;
    var o: usize = 0x20;
    for (out) |*s| {
        s.* = Section{ .magic = try bytes.sliceAt(d, o, o + 4), .offset = o, .size = try bytes.u32At(d, o + 4) };
        o = bytes.alignUp(o + 0x10 + s.size, 16);
    }
    return out;
}

pub const Label = struct {
    name: []const u8,
    index: u32,
};

/// Labels (with their text index) and raw texts (terminator included). Slices point into `d`.
pub const Raw = struct {
    labels: std.ArrayList(Label),
    texts: std.ArrayList([]const u8),

    pub fn indexOf(self: *const Raw, label: []const u8) ?u32 {
        for (self.labels.items) |l| {
            if (std.mem.eql(u8, l.name, label)) return l.index;
        }
        return null;
    }

    /// The raw text of `label`, or null.
    pub fn text(self: *const Raw, label: []const u8) ?[]const u8 {
        const i = self.indexOf(label) orelse return null;
        if (i >= self.texts.items.len) return null;
        return self.texts.items[i];
    }
};

fn readLabels(allocator: Allocator, d: []const u8, base: usize, out: *std.ArrayList(Label)) MsbtError!void {
    const n = try bytes.u32At(d, base);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const count = try bytes.u32At(d, base + 4 + i * 8);
        var p = base + try bytes.u32At(d, base + 8 + i * 8);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const len = try bytes.u8At(d, p);
            const name = try bytes.sliceAt(d, p + 1, p + 1 + len);
            out.append(allocator, Label{ .name = name, .index = try bytes.u32At(d, p + 1 + len) }) catch return error.OutOfMemory;
            p += 5 + len;
        }
    }
}

pub fn raw(allocator: Allocator, d: []const u8) MsbtError!Raw {
    var out = Raw{ .labels = .empty, .texts = .empty };
    const secs = try sections(allocator, d);
    defer allocator.free(secs);
    for (secs) |s| {
        const base = s.offset + 0x10;
        if (std.mem.eql(u8, s.magic, "LBL1")) {
            try readLabels(allocator, d, base, &out.labels);
        } else if (std.mem.eql(u8, s.magic, "TXT2")) {
            const n = try bytes.u32At(d, base);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const start = try bytes.u32At(d, base + 4 + i * 4);
                const end: usize = if (i + 1 < n) try bytes.u32At(d, base + 8 + i * 4) else s.size;
                out.texts.append(allocator, try bytes.sliceAt(d, base + start, base + end)) catch return error.OutOfMemory;
            }
        }
    }
    return out;
}

/// True when the file's texts are UTF-8 (the byte at 0xC is 0); UTF-16 otherwise.
pub fn isUtf8(d: []const u8) bool {
    return d.len > 0xC and d[0xC] == 0;
}

/// Writes a TXT2 body for `texts`.
fn txt2Body(out: *bytes.Buffer, texts: []const []const u8) MsbtError!void {
    try out.appendU32(@intCast(texts.len));
    var off: u32 = @intCast(4 + 4 * texts.len);
    for (texts) |t| {
        try out.appendU32(off);
        off += @intCast(t.len);
    }
    for (texts) |t| try out.append(t);
}

pub const NewText = struct {
    label: []const u8,
    text: []const u8,
};

/// Replaces texts by label (each must exist); rebuilds TXT2 only.
pub fn setRaw(allocator: Allocator, d: []const u8, new_texts: []const NewText) MsbtError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r = try raw(arena, d);
    for (new_texts) |nt| {
        const i = r.indexOf(nt.label) orelse return error.InvalidData;
        r.texts.items[i] = nt.text;
    }
    return rebuild(allocator, d, null, r.texts.items);
}

/// The file with every section copied except LBL1 (when `lbl1` is given) and TXT2, which are replaced.
fn rebuild(allocator: Allocator, d: []const u8, lbl1: ?[]const u8, texts: []const []const u8) MsbtError![]u8 {
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const secs = try sections(tmp.allocator(), d);
    var out = bytes.Buffer.init(allocator);
    errdefer out.deinit();
    try out.append(d[0..0x20]);
    for (secs) |s| {
        var body = bytes.Buffer.init(tmp.allocator());
        if (std.mem.eql(u8, s.magic, "TXT2")) {
            try txt2Body(&body, texts);
        } else if (lbl1 != null and std.mem.eql(u8, s.magic, "LBL1")) {
            try body.append(lbl1.?);
        } else {
            try body.append(try bytes.sliceAt(d, s.offset + 0x10, s.offset + 0x10 + s.size));
        }
        try out.append(s.magic);
        try out.appendU32(@intCast(body.len()));
        try out.append(try bytes.sliceAt(d, s.offset + 8, s.offset + 0x10));
        try out.append(body.bytes());
        try out.alignWith(16, 0xAB);
    }
    bytes.putU32(out.bytes(), 0x12, @intCast(out.len()));
    return out.toOwnedSlice();
}

/// The hash bucket of a label (LBL1 is a hash table).
fn labelBucket(label: []const u8, buckets: usize) usize {
    var h: u32 = 0;
    for (label) |c| h = h *% 0x492 +% c;
    return h % buckets;
}

/// Labels added (or replaced in place when they exist). Only files whose sections are LBL1 and TXT2 are supported
/// (all EventFlowMsg files of the remake).
pub fn addTexts(allocator: Allocator, d: []const u8, new_texts: []const NewText) MsbtError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const secs = try sections(arena, d);
    if (secs.len != 2) return error.InvalidData;
    var lbl_section: ?Section = null;
    var has_txt = false;
    for (secs) |s| {
        if (std.mem.eql(u8, s.magic, "LBL1")) lbl_section = s;
        if (std.mem.eql(u8, s.magic, "TXT2")) has_txt = true;
    }
    const lbl = lbl_section orelse return error.InvalidData;
    if (!has_txt) return error.InvalidData;

    var r = try raw(arena, d);

    // the buckets, read so that rebuilding them gives back the same bytes
    const base = lbl.offset + 0x10;
    const bucket_count = try bytes.u32At(d, base);
    const buckets = arena.alloc(std.ArrayList(Label), bucket_count) catch return error.OutOfMemory;
    for (buckets, 0..) |*b, i| {
        b.* = .empty;
        const count = try bytes.u32At(d, base + 4 + i * 8);
        var p = base + try bytes.u32At(d, base + 8 + i * 8);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const len = try bytes.u8At(d, p);
            b.append(arena, Label{ .name = try bytes.sliceAt(d, p + 1, p + 1 + len), .index = try bytes.u32At(d, p + 1 + len) }) catch return error.OutOfMemory;
            p += 5 + len;
        }
    }
    const original_body = try bytes.sliceAt(d, base, base + lbl.size);
    if (!std.mem.eql(u8, try lbl1Body(arena, buckets), original_body)) return error.InvalidData;

    for (new_texts) |nt| {
        if (r.indexOf(nt.label)) |i| {
            r.texts.items[i] = nt.text;
            continue;
        }
        const index: u32 = @intCast(r.texts.items.len);
        r.texts.append(arena, nt.text) catch return error.OutOfMemory;
        r.labels.append(arena, Label{ .name = nt.label, .index = index }) catch return error.OutOfMemory;
        if (bucket_count == 0) return error.InvalidData;
        buckets[labelBucket(nt.label, bucket_count)].append(arena, Label{ .name = nt.label, .index = index }) catch return error.OutOfMemory;
    }
    return rebuild(allocator, d, try lbl1Body(arena, buckets), r.texts.items);
}

fn lbl1Body(allocator: Allocator, buckets: []const std.ArrayList(Label)) MsbtError![]u8 {
    var head = bytes.Buffer.init(allocator);
    var names = bytes.Buffer.init(allocator);
    try head.appendU32(@intCast(buckets.len));
    const start = 4 + 8 * buckets.len;
    for (buckets) |b| {
        try head.appendU32(@intCast(b.items.len));
        try head.appendU32(@intCast(start + names.len()));
        for (b.items) |l| {
            try names.appendByte(@intCast(l.name.len));
            try names.append(l.name);
            try names.appendU32(l.index);
        }
    }
    try head.append(names.bytes());
    return head.bytes();
}

/// {label: plain text} with control tags removed and spaces trimmed. Allocated with `allocator` (use an arena).
pub fn parse(allocator: Allocator, d: []const u8) MsbtError!std.StringHashMap([]const u8) {
    if (d.len < 8 or !std.mem.eql(u8, d[0..8], "MsgStdBn")) return error.InvalidData;
    const utf8 = isUtf8(d);
    const r = try raw(allocator, d);
    var out = std.StringHashMap([]const u8).init(allocator);
    for (r.labels.items) |l| {
        if (l.index >= r.texts.items.len) continue;
        const t = try plainText(allocator, r.texts.items[l.index], utf8);
        out.put(l.name, t) catch return error.OutOfMemory;
    }
    return out;
}

/// A raw text without its tags, as UTF-8, trimmed.
fn plainText(allocator: Allocator, text: []const u8, utf8: bool) MsbtError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var j: usize = 0;
    if (utf8) {
        while (j < text.len) {
            const c = text[j];
            if (c == 0x0E) {
                const plen = bytes.u16At(text, j + 5) catch break;
                j += 7 + plen;
                continue;
            }
            if (c == 0x0F) {
                j += 5;
                continue;
            }
            if (c == 0) break;
            out.append(allocator, c) catch return error.OutOfMemory;
            j += 1;
        }
    } else {
        while (j + 1 < text.len) {
            const c = std.mem.readInt(u16, text[j..][0..2], .little);
            if (c == 0x0E) {
                const plen = bytes.u16At(text, j + 6) catch break;
                j += 8 + plen;
                continue;
            }
            if (c == 0x0F) {
                j += 6;
                continue;
            }
            if (c == 0) break;
            var buf: [4]u8 = undefined;
            // a lone surrogate half becomes U+FFFD, as Python's "replace" decoding did
            const encoded_character: []const u8 = if (std.unicode.utf8Encode(c, &buf)) |n| buf[0..n] else |_| "\u{FFFD}";
            out.appendSlice(allocator, encoded_character) catch return error.OutOfMemory;
            j += 2;
        }
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
}
