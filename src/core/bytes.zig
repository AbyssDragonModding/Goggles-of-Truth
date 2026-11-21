//! Little-endian reading and writing helpers shared by every binary format.
//!
//! Reads are bounds-checked: a read past the end of the data returns error.InvalidData instead of crashing, so a
//! damaged or unexpected game file fails cleanly.

const std = @import("std");

pub const ReadError = error{InvalidData};

pub fn u8At(data: []const u8, offset: usize) ReadError!u8 {
    if (offset >= data.len) return error.InvalidData;
    return data[offset];
}

pub fn u16At(data: []const u8, offset: usize) ReadError!u16 {
    if (offset + 2 > data.len) return error.InvalidData;
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

pub fn u32At(data: []const u8, offset: usize) ReadError!u32 {
    if (offset + 4 > data.len) return error.InvalidData;
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

pub fn i32At(data: []const u8, offset: usize) ReadError!i32 {
    if (offset + 4 > data.len) return error.InvalidData;
    return std.mem.readInt(i32, data[offset..][0..4], .little);
}

pub fn u64At(data: []const u8, offset: usize) ReadError!u64 {
    if (offset + 8 > data.len) return error.InvalidData;
    return std.mem.readInt(u64, data[offset..][0..8], .little);
}

pub fn f32At(data: []const u8, offset: usize) ReadError!f32 {
    return @bitCast(try u32At(data, offset));
}

/// A 24-bit little- or big-endian number (BYML node counts and key indices).
pub fn u24At(data: []const u8, offset: usize, big_endian: bool) ReadError!u32 {
    if (offset + 3 > data.len) return error.InvalidData;
    const b0: u32 = data[offset];
    const b1: u32 = data[offset + 1];
    const b2: u32 = data[offset + 2];
    if (big_endian) return (b0 << 16) | (b1 << 8) | b2;
    return b0 | (b1 << 8) | (b2 << 16);
}

/// The bytes of `data[start..end]`, or error.InvalidData when that range is outside the data.
pub fn sliceAt(data: []const u8, start: usize, end: usize) ReadError![]const u8 {
    if (start > end or end > data.len) return error.InvalidData;
    return data[start..end];
}

/// A zero-terminated string starting at `offset` (the terminator is not included).
pub fn cStringAt(data: []const u8, offset: usize) ReadError![]const u8 {
    if (offset > data.len) return error.InvalidData;
    const end = std.mem.indexOfScalarPos(u8, data, offset, 0) orelse return error.InvalidData;
    return data[offset..end];
}

pub fn putU16(data: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, data[offset..][0..2], value, .little);
}

pub fn putU32(data: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, data[offset..][0..4], value, .little);
}

pub fn putI32(data: []u8, offset: usize, value: i32) void {
    std.mem.writeInt(i32, data[offset..][0..4], value, .little);
}

pub fn putU64(data: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, data[offset..][0..8], value, .little);
}

/// `n` rounded up to a multiple of `alignment` (a power of two).
pub fn alignUp(n: usize, alignment: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}

/// A growable output buffer with little-endian append helpers. Owns its bytes through `allocator`.
pub const Buffer = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .list = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.list.deinit(self.allocator);
    }

    pub fn len(self: *const Self) usize {
        return self.list.items.len;
    }

    pub fn bytes(self: *const Self) []u8 {
        return self.list.items;
    }

    pub fn append(self: *Self, data: []const u8) error{OutOfMemory}!void {
        try self.list.appendSlice(self.allocator, data);
    }

    pub fn appendByte(self: *Self, value: u8) error{OutOfMemory}!void {
        try self.list.append(self.allocator, value);
    }

    pub fn appendZeros(self: *Self, count: usize) error{OutOfMemory}!void {
        try self.list.appendNTimes(self.allocator, 0, count);
    }

    pub fn appendU16(self: *Self, value: u16) error{OutOfMemory}!void {
        var raw: [2]u8 = undefined;
        std.mem.writeInt(u16, &raw, value, .little);
        try self.append(&raw);
    }

    pub fn appendU32(self: *Self, value: u32) error{OutOfMemory}!void {
        var raw: [4]u8 = undefined;
        std.mem.writeInt(u32, &raw, value, .little);
        try self.append(&raw);
    }

    pub fn appendI32(self: *Self, value: i32) error{OutOfMemory}!void {
        try self.appendU32(@bitCast(value));
    }

    pub fn appendU64(self: *Self, value: u64) error{OutOfMemory}!void {
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, value, .little);
        try self.append(&raw);
    }

    /// Pads with `fill` bytes until the length is a multiple of `alignment`.
    pub fn alignWith(self: *Self, alignment: usize, fill: u8) error{OutOfMemory}!void {
        while (self.list.items.len % alignment != 0) try self.list.append(self.allocator, fill);
    }

    pub fn alignTo(self: *Self, alignment: usize) error{OutOfMemory}!void {
        try self.alignWith(alignment, 0);
    }

    /// Reserves `size` zero bytes and returns their offset.
    pub fn reserve(self: *Self, size: usize) error{OutOfMemory}!usize {
        const offset = self.list.items.len;
        try self.appendZeros(size);
        return offset;
    }

    pub fn putU16(self: *Self, offset: usize, value: u16) void {
        std.mem.writeInt(u16, self.list.items[offset..][0..2], value, .little);
    }

    pub fn putU32(self: *Self, offset: usize, value: u32) void {
        std.mem.writeInt(u32, self.list.items[offset..][0..4], value, .little);
    }

    pub fn putU64(self: *Self, offset: usize, value: u64) void {
        std.mem.writeInt(u64, self.list.items[offset..][0..8], value, .little);
    }

    /// Hands the bytes over to the caller (allocated with this buffer's allocator).
    pub fn toOwnedSlice(self: *Self) error{OutOfMemory}![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }
};

test "read helpers stay in bounds" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(u16, 0x0201), try u16At(&data, 0));
    try std.testing.expectEqual(@as(u32, 0x05040302), try u32At(&data, 1));
    try std.testing.expectError(error.InvalidData, u32At(&data, 2));
    try std.testing.expectEqual(@as(u32, 0x010203), try u24At(&data, 0, true));
}
