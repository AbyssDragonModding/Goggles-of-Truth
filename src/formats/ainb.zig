//! Small, careful edits of AINB logic modules (Logic/*.logic.module.ainb): constant inputs and node names.
//!
//! Only what the patches need: an input entry is 16 bytes (name offset, link (0xFFFF = constant), flags, value);
//! names and string constants live in the string pool (its offset is at 0x24), the last section of the file.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const AinbError = error{ InvalidData, OutOfMemory };

/// Offsets of the values of constant (unlinked) int inputs named `param_name` holding `value`.
pub fn constOffsets(allocator: Allocator, data: []const u8, param_name: []const u8, value: i32) AinbError![]usize {
    var hits: std.ArrayList(usize) = .empty;
    errdefer hits.deinit(allocator);
    const pool = try bytes.u32At(data, 0x24);
    const target = findCString(data, param_name, pool) orelse return hits.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const name_off = target - pool;
    if (pool < 16) return hits.toOwnedSlice(allocator) catch return error.OutOfMemory;
    var o: usize = 0x74;
    while (o < pool - 16) : (o += 4) {
        const n = try bytes.u32At(data, o);
        const link = try bytes.u32At(data, o + 4);
        const flags = try bytes.u32At(data, o + 8);
        const v = try bytes.i32At(data, o + 12);
        // why: a constant input is unlinked (0xFFFF) and has one of the two "constant" flag values
        if ((n & 0x7FFFFFFF) == name_off and link == 0xFFFF and (flags == 0x01800000 or flags == 0x00800000) and v == value) {
            hits.append(allocator, o + 12) catch return error.OutOfMemory;
        }
    }
    return hits.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Offset of `name` followed by a zero byte, searched from `from`.
fn findCString(data: []const u8, name: []const u8, from: usize) ?usize {
    var start = from;
    while (std.mem.indexOfPos(u8, data, start, name)) |at| {
        if (at + name.len < data.len and data[at + name.len] == 0) return at;
        start = at + 1;
    }
    return null;
}

/// Offset (inside the string pool) of the whole string `s` (preceded and followed by a zero), or null.
fn poolStringOffset(data: []const u8, pool: usize, s: []const u8) ?usize {
    if (pool == 0) return null;
    var start = pool;
    while (std.mem.indexOfPos(u8, data, start, s)) |at| {
        if (at > 0 and data[at - 1] == 0 and at + s.len < data.len and data[at + s.len] == 0) return at - pool;
        start = at + 1;
    }
    return null;
}

pub const Repointed = struct {
    data: []u8,
    count: usize,
};

/// Points every constant string input `param_name` == `old` at `new` (appended to the string pool, the last
/// section). Returns the new bytes and how many inputs changed (0: the data is returned unchanged, copied).
pub fn repointStringConst(allocator: Allocator, data: []const u8, param_name: []const u8, old: []const u8, new: []const u8) AinbError!Repointed {
    const pool = try bytes.u32At(data, 0x24);
    const unchanged = Repointed{ .data = allocator.dupe(u8, data) catch return error.OutOfMemory, .count = 0 };
    if (data.len == 0 or data[data.len - 1] != 0) return unchanged;
    const old_off = poolStringOffset(data, pool, old) orelse return unchanged;
    const hits = try constOffsets(allocator, data, param_name, @intCast(old_off));
    defer allocator.free(hits);
    if (hits.len == 0) return unchanged;
    allocator.free(unchanged.data);

    var out = bytes.Buffer.init(allocator);
    errdefer out.deinit();
    try out.append(data);
    const new_off: i32 = @intCast(out.len() - pool);
    try out.append(new);
    try out.appendByte(0);
    for (hits) |h| bytes.putI32(out.bytes(), h, new_off);
    return Repointed{ .data = try out.toOwnedSlice(), .count = hits.len };
}

/// File offset of node `i` (the node table follows 0x18-byte commands).
pub fn nodeOffset(data: []const u8, i: usize) AinbError!usize {
    return 0x74 + @as(usize, try bytes.u32At(data, 0x0C)) * 0x18 + i * 0x3C;
}

/// The type name of node `i`.
pub fn nodeName(data: []const u8, i: usize) AinbError![]const u8 {
    const pool = try bytes.u32At(data, 0x24);
    const off = try bytes.u32At(data, (try nodeOffset(data, i)) + 8);
    return bytes.cStringAt(data, pool + off);
}
