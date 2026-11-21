//! SARC archives (.pack, .sarc): read, and rebuild with files replaced or added.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const hash = @import("../core/hash.zig");

/// Reading only fails on malformed data.
pub const ReadError = error{ InvalidData, OutOfMemory };

pub const SarcError = error{
    InvalidData,
    /// A replacement names a file the archive doesn't have.
    MissingEntry,
    OutOfMemory,
};

/// One file of an archive. `name` and `data` point into the archive's bytes.
pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    /// Absolute offsets of the data inside the archive.
    start: usize,
    end: usize,
};

/// A file to write into an archive.
pub const NewFile = struct {
    name: []const u8,
    data: []const u8,
};

const Header = struct {
    big_endian: bool,
    header_len: usize,
    data_offset: usize,
    node_count: usize,
    multiplier: u32,
    names_offset: usize,
};

fn readU16(data: []const u8, offset: usize, big: bool) ReadError!u16 {
    const v = try bytes.u16At(data, offset);
    return if (big) @byteSwap(v) else v;
}

fn readU32(data: []const u8, offset: usize, big: bool) ReadError!u32 {
    const v = try bytes.u32At(data, offset);
    return if (big) @byteSwap(v) else v;
}

fn readHeader(data: []const u8) ReadError!Header {
    if (data.len < 0x14 or !std.mem.eql(u8, data[0..4], "SARC")) return error.InvalidData;
    // byte order mark: FF FE read little-endian is 0xFEFF
    const big = !(data[6] == 0xFF and data[7] == 0xFE);
    const header_len = try readU16(data, 4, big);
    const data_offset = try readU32(data, 0xC, big);
    const sfat: usize = header_len;
    const node_count = try readU16(data, sfat + 6, big);
    const multiplier = try readU32(data, sfat + 8, big);
    return Header{
        .big_endian = big,
        .header_len = header_len,
        .data_offset = data_offset,
        .node_count = node_count,
        .multiplier = multiplier,
        .names_offset = sfat + 0xC + @as(usize, node_count) * 16 + 8,
    };
}

/// Every named file of the archive, in archive order. Entries without a name are left out.
/// The caller frees the list (not the entries, which point into `data`).
pub fn list(allocator: std.mem.Allocator, data: []const u8) ReadError!std.ArrayList(Entry) {
    const h = try readHeader(data);
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < h.node_count) : (i += 1) {
        const node = h.header_len + 0xC + i * 16;
        const attr = try readU32(data, node + 4, h.big_endian);
        const start = try readU32(data, node + 8, h.big_endian);
        const end = try readU32(data, node + 12, h.big_endian);
        if (attr & 0x01000000 == 0) continue; // unnamed file: nothing in the game reads one
        const name_at = h.names_offset + @as(usize, attr & 0xFFFF) * 4;
        const name = try bytes.cStringAt(data, name_at);
        const abs_start = h.data_offset + start;
        const abs_end = h.data_offset + end;
        const file_data = try bytes.sliceAt(data, abs_start, abs_end);
        out.append(allocator, Entry{ .name = name, .data = file_data, .start = abs_start, .end = abs_end }) catch
            return error.OutOfMemory;
    }
    return out;
}

/// The data of file `name`, or null.
pub fn find(allocator: std.mem.Allocator, data: []const u8, name: []const u8) ReadError!?Entry {
    var entries = try list(allocator, data);
    defer entries.deinit(allocator);
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// The largest power of two (at most `cap`) dividing `n`.
fn powerOfTwoDividing(n: usize, cap: usize) usize {
    var a: usize = 1;
    while (a < cap and n % (a * 2) == 0) a *= 2;
    return a;
}

const Pending = struct {
    name: []const u8,
    data: []const u8,
    hash: u32,
};

fn lessByHash(_: void, a: Pending, b: Pending) bool {
    return a.hash < b.hash;
}

/// Rebuilds a little-endian SARC with files replaced (`replace`, each must exist) and added (`add`).
/// Existing files keep their alignment; the archive-wide file alignment is worked out from the original offsets.
pub fn rebuild(allocator: std.mem.Allocator, data: []const u8, replace: []const NewFile, add: []const NewFile) SarcError![]u8 {
    const h = try readHeader(data);
    if (h.big_endian) return error.InvalidData; // only little-endian archives are written

    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(allocator);
    const used = allocator.alloc(bool, replace.len) catch return error.OutOfMemory;
    defer allocator.free(used);
    @memset(used, false);

    // keep every file, taking replacements in its place
    var gcd: usize = 0;
    var i: usize = 0;
    while (i < h.node_count) : (i += 1) {
        const node = h.header_len + 0xC + i * 16;
        const attr = try readU32(data, node + 4, false);
        const start = try readU32(data, node + 8, false);
        const end = try readU32(data, node + 12, false);
        const name = try bytes.cStringAt(data, h.names_offset + @as(usize, attr & 0xFFFF) * 4);
        // std.math.gcd needs one of its numbers to be non-zero (Python's math.gcd(0, 0) is 0), and the first file
        // starts at 0: an offset of 0 divides by anything, so it doesn't change the alignment and is skipped.
        if (start != 0) gcd = std.math.gcd(gcd, @as(usize, start));
        var file_data = try bytes.sliceAt(data, h.data_offset + start, h.data_offset + end);
        for (replace, 0..) |r, k| {
            if (std.mem.eql(u8, r.name, name)) {
                file_data = r.data;
                used[k] = true;
            }
        }
        pending.append(allocator, Pending{ .name = name, .data = file_data, .hash = hash.sarcNameHash(name, h.multiplier) }) catch
            return error.OutOfMemory;
    }
    for (used) |u| {
        if (!u) return error.MissingEntry;
    }
    for (add) |a| {
        pending.append(allocator, Pending{ .name = a.name, .data = a.data, .hash = hash.sarcNameHash(a.name, h.multiplier) }) catch
            return error.OutOfMemory;
    }

    // archive-wide file alignment (8 for packs) and the alignment of the data section's start
    const file_align: usize = if (gcd != 0) @max(4, powerOfTwoDividing(gcd, 0x80)) else 8;
    const data_align: usize = @max(4, powerOfTwoDividing(h.data_offset, 0x2000));

    // the game finds files by binary search over the name hashes
    std.mem.sort(Pending, pending.items, {}, lessByHash);

    // name table
    var names = bytes.Buffer.init(allocator);
    defer names.deinit();
    const name_index = allocator.alloc(u32, pending.items.len) catch return error.OutOfMemory;
    defer allocator.free(name_index);
    for (pending.items, 0..) |p, k| {
        name_index[k] = @intCast(names.len() / 4);
        try names.append(p.name);
        try names.appendByte(0);
        try names.alignTo(4);
    }

    const sfat_size = 0xC + pending.items.len * 16;
    const sfnt_offset = 0x14 + sfat_size;
    const new_data_offset = bytes.alignUp(sfnt_offset + 8 + names.len(), data_align);

    var body = bytes.Buffer.init(allocator);
    defer body.deinit();
    var nodes = bytes.Buffer.init(allocator);
    defer nodes.deinit();
    for (pending.items, 0..) |p, k| {
        try body.alignTo(file_align);
        const start = body.len();
        try body.append(p.data);
        try nodes.appendU32(p.hash);
        try nodes.appendU32(0x01000000 | name_index[k]);
        try nodes.appendU32(@intCast(start));
        try nodes.appendU32(@intCast(body.len()));
    }

    var out = bytes.Buffer.init(allocator);
    errdefer out.deinit();
    try out.append(data[0..0x14]);
    try out.append("SFAT");
    try out.appendU16(0xC);
    try out.appendU16(@intCast(pending.items.len));
    try out.appendU32(h.multiplier);
    try out.append(nodes.bytes());
    try out.append("SFNT");
    try out.appendU16(8);
    try out.appendU16(0);
    try out.append(names.bytes());
    try out.appendZeros(new_data_offset - out.len());
    try out.append(body.bytes());
    out.putU32(0x8, @intCast(out.len()));
    out.putU32(0xC, @intCast(new_data_offset));
    return out.toOwnedSlice();
}
