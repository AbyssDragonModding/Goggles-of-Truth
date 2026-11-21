//! RESTBL: the resource size table (System/Resource/ResourceSizeTable.*.rsizetable.zs).
//!
//! The game reserves memory for a file from this table, so a patched file that grew needs a bigger entry, and a new
//! file (a cloned actor pack) needs an entry of its own. Paths are found by name (the name table) or, for most, by
//! the CRC-32 of the path.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const hash = @import("../core/hash.zig");
const Allocator = std.mem.Allocator;

pub const RestblError = error{ InvalidData, OutOfMemory };

pub const Restbl = struct {
    allocator: Allocator,
    version: u32,
    /// size of a name entry's string field
    name_size: u32,
    crc: std.AutoHashMap(u32, u32),
    names: std.StringHashMap(u32),

    const Self = @This();

    /// Reads a decompressed table. Names are copied.
    pub fn parse(allocator: Allocator, data: []const u8) RestblError!Self {
        if (data.len < 0x16 or !std.mem.eql(u8, data[0..6], "RESTBL")) return error.InvalidData;
        var self = Self{
            .allocator = allocator,
            .version = try bytes.u32At(data, 6),
            .name_size = try bytes.u32At(data, 10),
            .crc = std.AutoHashMap(u32, u32).init(allocator),
            .names = std.StringHashMap(u32).init(allocator),
        };
        errdefer self.deinit();
        const crc_count = try bytes.u32At(data, 14);
        const name_count = try bytes.u32At(data, 18);
        var offset: usize = 0x16;
        var i: usize = 0;
        while (i < crc_count) : (i += 1) {
            const key = try bytes.u32At(data, offset + i * 8);
            const size = try bytes.u32At(data, offset + i * 8 + 4);
            self.crc.put(key, size) catch return error.OutOfMemory;
        }
        offset += crc_count * 8;
        i = 0;
        while (i < name_count) : (i += 1) {
            const p = offset + i * (self.name_size + 4);
            const field = try bytes.sliceAt(data, p, p + self.name_size);
            const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
            const name = allocator.dupe(u8, field[0..end]) catch return error.OutOfMemory;
            self.names.put(name, try bytes.u32At(data, p + self.name_size)) catch return error.OutOfMemory;
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.names.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.names.deinit();
        self.crc.deinit();
    }

    /// The size entry of `path`, or null.
    pub fn get(self: *const Self, path: []const u8) ?u32 {
        if (self.names.get(path)) |size| return size;
        return self.crc.get(hash.crc32(path));
    }

    /// True when the CRC of `path` is already taken (by `path` or another path).
    pub fn crcTaken(self: *const Self, path: []const u8) bool {
        return self.crc.contains(hash.crc32(path));
    }

    pub fn set(self: *Self, path: []const u8, size: u32) RestblError!void {
        if (self.names.getPtr(path)) |slot| {
            slot.* = size;
            return;
        }
        self.crc.put(hash.crc32(path), size) catch return error.OutOfMemory;
    }

    fn lessName(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// The table's bytes (entries sorted, as the game expects for its binary search).
    pub fn serialize(self: *const Self, allocator: Allocator) RestblError![]u8 {
        var out = bytes.Buffer.init(allocator);
        errdefer out.deinit();
        try out.append("RESTBL");
        try out.appendU32(self.version);
        try out.appendU32(self.name_size);
        try out.appendU32(@intCast(self.crc.count()));
        try out.appendU32(@intCast(self.names.count()));

        const keys = allocator.alloc(u32, self.crc.count()) catch return error.OutOfMemory;
        defer allocator.free(keys);
        var kit = self.crc.keyIterator();
        var k: usize = 0;
        while (kit.next()) |key| : (k += 1) keys[k] = key.*;
        std.mem.sort(u32, keys, {}, std.sort.asc(u32));
        for (keys) |key| {
            try out.appendU32(key);
            try out.appendU32(self.crc.get(key).?);
        }

        const names = allocator.alloc([]const u8, self.names.count()) catch return error.OutOfMemory;
        defer allocator.free(names);
        var nit = self.names.keyIterator();
        k = 0;
        while (nit.next()) |name| : (k += 1) names[k] = name.*;
        std.mem.sort([]const u8, names, {}, lessName);
        for (names) |name| {
            if (name.len > self.name_size) return error.InvalidData;
            try out.append(name);
            try out.appendZeros(self.name_size - name.len);
            try out.appendU32(self.names.get(name).?);
        }
        return out.toOwnedSlice();
    }
};
