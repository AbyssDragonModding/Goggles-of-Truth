//! BYML (version 7, little-endian; big-endian is read too): a type-preserving tree, read and written back.
//!
//! Every node keeps its exact BYML type, so a file that is read and written back without changes keeps its types:
//!   string 0xA0, binary 0xA1, array 0xC0, dictionary 0xC1, bool 0xD0, int (s32) 0xD1, float (f32) 0xD2,
//!   uint (u32) 0xD3, int64 0xD4, uint64 0xD5, double 0xD6, null 0xFF.
//!
//! Containers are pointers, so a sub-dictionary taken out of a tree and changed is changed in the tree (the way the
//! patches edit "Dynamic" parameters in place). All nodes are allocated with the allocator given to `load`: use an
//! arena and free the whole tree at once.

const std = @import("std");
const bytes = @import("../core/bytes.zig");

pub const BymlError = error{ InvalidData, OutOfMemory };
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    binary: []const u8,
    bool: bool,
    int: i32,
    float: f32,
    uint: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    null,
    array: *Array,
    dict: *Dict,

    /// The number, for any integer type (and bool, as 0/1), or null.
    pub fn asInt(self: Value) ?i128 {
        return switch (self) {
            .int => |v| v,
            .uint => |v| v,
            .int64 => |v| v,
            .uint64 => |v| v,
            .bool => |v| @intFromBool(v),
            else => null,
        };
    }

    /// The number, for any integer or floating-point type, or null.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |v| v,
            .double => |v| v,
            else => if (self.asInt()) |i| @floatFromInt(i) else null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asDict(self: Value) ?*Dict {
        return switch (self) {
            .dict => |d| d,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?*Array {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    /// Python-style truth: false, 0, "", empty containers and null are false.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .bool => |v| v,
            .string, .binary => |s| s.len > 0,
            .null => false,
            .array => |a| a.items.items.len > 0,
            .dict => |d| d.entries.items.len > 0,
            .float => |v| v != 0,
            .double => |v| v != 0,
            else => (self.asInt() orelse 0) != 0,
        };
    }

    /// Equality as the Python version compared values: numbers by value across types (1 == 1.0 == true),
    /// strings by content, containers by their contents.
    pub fn looseEql(a: Value, b: Value) bool {
        if (a.asInt() != null and b.asInt() != null) return a.asInt().? == b.asInt().?;
        if (a.asFloat() != null and b.asFloat() != null) return a.asFloat().? == b.asFloat().?;
        return switch (a) {
            .string => |s| if (b.asString()) |t| std.mem.eql(u8, s, t) else false,
            .binary => |s| switch (b) {
                .binary => |t| std.mem.eql(u8, s, t),
                else => false,
            },
            .null => b == .null,
            .array => |x| switch (b) {
                .array => |y| arraysEql(x, y, looseEql),
                else => false,
            },
            .dict => |x| switch (b) {
                .dict => |y| dictsEqlUnordered(x, y),
                else => false,
            },
            else => false,
        };
    }

    /// Type-exact equality (floats compared by their bits): two values that write the same bytes.
    pub fn exactEql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .binary => |s| std.mem.eql(u8, s, b.binary),
            .bool => |v| v == b.bool,
            .int => |v| v == b.int,
            .uint => |v| v == b.uint,
            .int64 => |v| v == b.int64,
            .uint64 => |v| v == b.uint64,
            .float => |v| @as(u32, @bitCast(v)) == @as(u32, @bitCast(b.float)),
            .double => |v| @as(u64, @bitCast(v)) == @as(u64, @bitCast(b.double)),
            .null => true,
            .array => |x| arraysEql(x, b.array, exactEql),
            .dict => |x| dictsEqlSorted(x, b.dict),
        };
    }

    /// A deep copy (containers are new; strings are shared, they are never changed in place).
    pub fn clone(self: Value, allocator: Allocator) BymlError!Value {
        switch (self) {
            .array => |a| {
                const copy = try Array.create(allocator);
                copy.items.ensureTotalCapacity(allocator, a.items.items.len) catch return error.OutOfMemory;
                for (a.items.items) |item| copy.items.appendAssumeCapacity(try item.clone(allocator));
                return Value{ .array = copy };
            },
            .dict => |d| {
                const copy = try Dict.create(allocator);
                copy.entries.ensureTotalCapacity(allocator, d.entries.items.len) catch return error.OutOfMemory;
                for (d.entries.items) |e| copy.entries.appendAssumeCapacity(.{ .key = e.key, .value = try e.value.clone(allocator) });
                return Value{ .dict = copy };
            },
            else => return self,
        }
    }

    /// The same kind of integer holding `n` (keeps a field's BYML type when its value changes).
    pub fn sameIntType(self: Value, n: i128) Value {
        return switch (self) {
            .uint => Value{ .uint = @truncate(@as(u128, @bitCast(n))) },
            .int64 => Value{ .int64 = @truncate(n) },
            .uint64 => Value{ .uint64 = @truncate(@as(u128, @bitCast(n))) },
            .bool => Value{ .bool = n != 0 },
            else => Value{ .int = @truncate(n) },
        };
    }
};

fn arraysEql(x: *Array, y: *Array, comptime eql: fn (Value, Value) bool) bool {
    if (x.items.items.len != y.items.items.len) return false;
    for (x.items.items, y.items.items) |a, b| {
        if (!eql(a, b)) return false;
    }
    return true;
}

fn dictsEqlUnordered(x: *Dict, y: *Dict) bool {
    if (x.entries.items.len != y.entries.items.len) return false;
    for (x.entries.items) |e| {
        const other = y.get(e.key) orelse return false;
        if (!Value.looseEql(e.value, other)) return false;
    }
    return true;
}

fn dictsEqlSorted(x: *Dict, y: *Dict) bool {
    if (x.entries.items.len != y.entries.items.len) return false;
    for (x.entries.items) |e| {
        const other = y.get(e.key) orelse return false;
        if (!Value.exactEql(e.value, other)) return false;
    }
    return true;
}

pub const Array = struct {
    items: std.ArrayList(Value),

    const Self = @This();

    pub fn create(allocator: Allocator) BymlError!*Self {
        const self = allocator.create(Self) catch return error.OutOfMemory;
        self.* = Self{ .items = .empty };
        return self;
    }

    pub fn append(self: *Self, allocator: Allocator, value: Value) BymlError!void {
        self.items.append(allocator, value) catch return error.OutOfMemory;
    }

    pub fn len(self: *const Self) usize {
        return self.items.items.len;
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// A dictionary that keeps the order its keys were read or added in (BYML writes them sorted anyway).
pub const Dict = struct {
    entries: std.ArrayList(Entry),

    const Self = @This();

    pub fn create(allocator: Allocator) BymlError!*Self {
        const self = allocator.create(Self) catch return error.OutOfMemory;
        self.* = Self{ .entries = .empty };
        return self;
    }

    pub fn get(self: *const Self, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn getPtr(self: *Self, key: []const u8) ?*Value {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.value;
        }
        return null;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn getString(self: *const Self, key: []const u8) ?[]const u8 {
        return if (self.get(key)) |v| v.asString() else null;
    }

    pub fn getInt(self: *const Self, key: []const u8) ?i128 {
        return if (self.get(key)) |v| v.asInt() else null;
    }

    pub fn getDict(self: *const Self, key: []const u8) ?*Dict {
        return if (self.get(key)) |v| v.asDict() else null;
    }

    pub fn getArray(self: *const Self, key: []const u8) ?*Array {
        return if (self.get(key)) |v| v.asArray() else null;
    }

    /// Sets `key` (in place when it exists, else at the end).
    pub fn put(self: *Self, allocator: Allocator, key: []const u8, value: Value) BymlError!void {
        if (self.getPtr(key)) |slot| {
            slot.* = value;
            return;
        }
        self.entries.append(allocator, Entry{ .key = key, .value = value }) catch return error.OutOfMemory;
    }

    /// Removes `key`; true when it was there.
    pub fn remove(self: *Self, key: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// The dictionary at `key`, made (empty) when it isn't there (Python's setdefault(key, {})).
    pub fn ensureDict(self: *Self, allocator: Allocator, key: []const u8) BymlError!*Dict {
        if (self.getDict(key)) |d| return d;
        const d = try Dict.create(allocator);
        try self.put(allocator, key, Value{ .dict = d });
        return d;
    }

    /// The array at `key`, made (empty) when it isn't there.
    pub fn ensureArray(self: *Self, allocator: Allocator, key: []const u8) BymlError!*Array {
        if (self.getArray(key)) |a| return a;
        const a = try Array.create(allocator);
        try self.put(allocator, key, Value{ .array = a });
        return a;
    }
};

// ------------------------------------------------------------------------------------------------------- reading

pub const Document = struct {
    root: ?Value,
    version: u16,
    big_endian: bool,
};

const Reader = struct {
    data: []const u8,
    big: bool,
    keys: [][]const u8,
    strings: [][]const u8,
    allocator: Allocator,
    depth: usize = 0,

    const Self = @This();

    fn u32At(self: *const Self, offset: usize) BymlError!u32 {
        const v = try bytes.u32At(self.data, offset);
        return if (self.big) @byteSwap(v) else v;
    }

    fn u64At(self: *const Self, offset: usize) BymlError!u64 {
        const v = try bytes.u64At(self.data, offset);
        return if (self.big) @byteSwap(v) else v;
    }

    fn count(self: *const Self, offset: usize) BymlError!u32 {
        return bytes.u24At(self.data, offset + 1, self.big);
    }

    fn stringTable(self: *Self, offset: usize) BymlError![][]const u8 {
        if (offset == 0) return &.{};
        const n = try self.count(offset);
        const out = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
        for (out, 0..) |*s, i| {
            const at = offset + try self.u32At(offset + 4 + i * 4);
            s.* = try bytes.cStringAt(self.data, at);
        }
        return out;
    }

    fn value(self: *Self, node_type: u8, offset: usize) BymlError!Value {
        return switch (node_type) {
            0xC0, 0xC1, 0xA1 => self.node(node_type, try self.u32At(offset)),
            0xA0 => blk: {
                const index = try self.u32At(offset);
                if (index >= self.strings.len) return error.InvalidData;
                break :blk Value{ .string = self.strings[index] };
            },
            0xD0 => Value{ .bool = (try self.u32At(offset)) != 0 },
            0xD1 => Value{ .int = @bitCast(try self.u32At(offset)) },
            0xD2 => Value{ .float = @bitCast(try self.u32At(offset)) },
            0xD3 => Value{ .uint = try self.u32At(offset) },
            0xD4 => Value{ .int64 = @bitCast(try self.u64At(try self.u32At(offset))) },
            0xD5 => Value{ .uint64 = try self.u64At(try self.u32At(offset)) },
            0xD6 => Value{ .double = @bitCast(try self.u64At(try self.u32At(offset))) },
            0xFF => Value.null,
            else => error.InvalidData,
        };
    }

    fn node(self: *Self, node_type: u8, offset: usize) BymlError!Value {
        // a malformed file could point a container at itself
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 256) return error.InvalidData;

        if (node_type == 0xA1) {
            const n = try self.u32At(offset);
            return Value{ .binary = try bytes.sliceAt(self.data, offset + 4, offset + 4 + n) };
        }
        const actual = try bytes.u8At(self.data, offset);
        const n = try self.count(offset);
        if (actual == 0xC0) {
            const types = try bytes.sliceAt(self.data, offset + 4, offset + 4 + n);
            const values_at = offset + 4 + bytes.alignUp(n, 4);
            const array = try Array.create(self.allocator);
            array.items.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
            for (types, 0..) |t, i| array.items.appendAssumeCapacity(try self.value(t, values_at + i * 4));
            return Value{ .array = array };
        }
        if (actual == 0xC1) {
            const dict = try Dict.create(self.allocator);
            dict.entries.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const entry_at = offset + 4 + i * 8;
                const key_index = try bytes.u24At(self.data, entry_at, self.big);
                if (key_index >= self.keys.len) return error.InvalidData;
                const t = try bytes.u8At(self.data, entry_at + 3);
                dict.entries.appendAssumeCapacity(Entry{ .key = self.keys[key_index], .value = try self.value(t, entry_at + 4) });
            }
            return Value{ .dict = dict };
        }
        return error.InvalidData;
    }
};

/// Reads a BYML file. Strings point into `data`, which must outlive the tree.
pub fn load(allocator: Allocator, data: []const u8) BymlError!Document {
    if (data.len < 16) return error.InvalidData;
    var big: bool = undefined;
    if (data[0] == 'Y' and data[1] == 'B') {
        big = false;
    } else if (data[0] == 'B' and data[1] == 'Y') {
        big = true;
    } else return error.InvalidData;

    var r = Reader{ .data = data, .big = big, .keys = &.{}, .strings = &.{}, .allocator = allocator };
    const version_raw = try bytes.u16At(data, 2);
    const version = if (big) @byteSwap(version_raw) else version_raw;
    r.keys = try r.stringTable(try r.u32At(4));
    r.strings = try r.stringTable(try r.u32At(8));
    const root_offset = try r.u32At(12);
    if (root_offset == 0) return Document{ .root = null, .version = version, .big_endian = big };
    const root = try r.node(try bytes.u8At(data, root_offset), root_offset);
    return Document{ .root = root, .version = version, .big_endian = big };
}

/// Reads a BYML file whose root must be a dictionary.
pub fn loadDict(allocator: Allocator, data: []const u8) BymlError!*Dict {
    const doc = try load(allocator, data);
    const root = doc.root orelse return error.InvalidData;
    return root.asDict() orelse error.InvalidData;
}

/// Overwrites a top-level 32-bit integer in place (same size). Returns a patched copy.
pub fn patchRootU32(allocator: Allocator, data: []const u8, key: []const u8, new_value: u32) BymlError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var r = Reader{ .data = data, .big = data.len > 1 and data[0] == 'B', .keys = &.{}, .strings = &.{}, .allocator = arena.allocator() };
    r.keys = try r.stringTable(try r.u32At(4));
    const root_offset = try r.u32At(12);
    if (try bytes.u8At(data, root_offset) != 0xC1) return error.InvalidData;
    const n = try r.count(root_offset);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry_at = root_offset + 4 + i * 8;
        const key_index = try bytes.u24At(data, entry_at, r.big);
        if (key_index < r.keys.len and std.mem.eql(u8, r.keys[key_index], key)) {
            const t = data[entry_at + 3];
            if (t != 0xD1 and t != 0xD3) return error.InvalidData;
            const out = allocator.dupe(u8, data) catch return error.OutOfMemory;
            const v = if (r.big) @byteSwap(new_value) else new_value;
            bytes.putU32(out, entry_at + 4, v);
            return out;
        }
    }
    return error.InvalidData;
}

// ------------------------------------------------------------------------------------------------------- writing

fn typeOf(v: Value) u8 {
    return switch (v) {
        .string => 0xA0,
        .binary => 0xA1,
        .array => 0xC0,
        .dict => 0xC1,
        .bool => 0xD0,
        .int => 0xD1,
        .float => 0xD2,
        .uint => 0xD3,
        .int64 => 0xD4,
        .uint64 => 0xD5,
        .double => 0xD6,
        .null => 0xFF,
    };
}

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A structural hash, equal for values that are `exactEql` (for de-duplicating identical sub-trees).
fn structuralHash(v: Value, hasher: *std.hash.Wyhash) void {
    hasher.update(&[_]u8{typeOf(v)});
    switch (v) {
        .string, .binary => |s| hasher.update(s),
        .bool => |b| hasher.update(&[_]u8{@intFromBool(b)}),
        .int => |x| hasher.update(std.mem.asBytes(&x)),
        .uint => |x| hasher.update(std.mem.asBytes(&x)),
        .int64 => |x| hasher.update(std.mem.asBytes(&x)),
        .uint64 => |x| hasher.update(std.mem.asBytes(&x)),
        .float => |x| hasher.update(std.mem.asBytes(&x)),
        .double => |x| hasher.update(std.mem.asBytes(&x)),
        .null => {},
        .array => |a| for (a.items.items) |item| structuralHash(item, hasher),
        .dict => |d| {
            // order-independent: combine the entries' hashes with a sum
            var sum: u64 = 0;
            for (d.entries.items) |e| {
                var h = std.hash.Wyhash.init(0);
                h.update(e.key);
                structuralHash(e.value, &h);
                sum +%= h.final();
            }
            hasher.update(std.mem.asBytes(&sum));
        },
    }
}

const Pending = struct {
    field: usize,
    value: Value,
};

const Written = struct {
    value: Value,
    offset: u32,
};

const Writer = struct {
    allocator: Allocator,
    big: bool,
    out: bytes.Buffer,
    key_index: std.StringHashMap(u32),
    string_index: std.StringHashMap(u32),
    pending: std.ArrayList(Pending),
    seen: std.AutoHashMap(u64, std.ArrayList(Written)),

    const Self = @This();

    fn put32(self: *Self, offset: usize, v: u32) void {
        self.out.putU32(offset, if (self.big) @byteSwap(v) else v);
    }

    fn append32(self: *Self, v: u32) BymlError!void {
        try self.out.appendU32(if (self.big) @byteSwap(v) else v);
    }

    fn append24(self: *Self, v: u32) BymlError!void {
        if (self.big) {
            try self.out.append(&[_]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) });
        } else {
            try self.out.append(&[_]u8{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16) });
        }
    }

    fn collect(self: *Self, v: Value, keys: *std.StringHashMap(void), strings: *std.StringHashMap(void)) BymlError!void {
        switch (v) {
            .dict => |d| for (d.entries.items) |e| {
                keys.put(e.key, {}) catch return error.OutOfMemory;
                try self.collect(e.value, keys, strings);
            },
            .array => |a| for (a.items.items) |item| try self.collect(item, keys, strings),
            .string => |s| strings.put(s, {}) catch return error.OutOfMemory,
            else => {},
        }
    }

    /// A string table; returns its offset (0 when empty).
    fn stringTable(self: *Self, list: []const []const u8) BymlError!u32 {
        if (list.len == 0) return 0;
        try self.out.alignTo(4);
        const start = self.out.len();
        try self.out.appendByte(0xC2);
        try self.append24(@intCast(list.len));
        var offset: u32 = @intCast(4 + 4 * (list.len + 1));
        for (list) |s| {
            try self.append32(offset);
            offset += @intCast(s.len + 1);
        }
        try self.append32(offset);
        for (list) |s| {
            try self.out.append(s);
            try self.out.appendByte(0);
        }
        return @intCast(start);
    }

    /// Writes an inline value (or a zero placeholder for out-of-line data, queued in `pending`).
    fn inlineValue(self: *Self, v: Value) BymlError!void {
        switch (v) {
            .bool => |b| try self.append32(@intFromBool(b)),
            .int => |x| try self.append32(@bitCast(x)),
            .float => |x| try self.append32(@bitCast(x)),
            .uint => |x| try self.append32(x),
            .string => |s| try self.append32(self.string_index.get(s).?),
            .null => try self.append32(0),
            else => {
                self.pending.append(self.allocator, Pending{ .field = self.out.len(), .value = v }) catch return error.OutOfMemory;
                try self.append32(0);
            },
        }
    }

    fn lessEntry(self: *Self, a: Entry, b: Entry) bool {
        return self.key_index.get(a.key).? < self.key_index.get(b.key).?;
    }

    fn container(self: *Self, v: Value) BymlError!u32 {
        try self.out.alignTo(4);
        const start: u32 = @intCast(self.out.len());
        switch (v) {
            .array => |a| {
                try self.out.appendByte(0xC0);
                try self.append24(@intCast(a.items.items.len));
                for (a.items.items) |item| try self.out.appendByte(typeOf(item));
                try self.out.alignTo(4);
                for (a.items.items) |item| try self.inlineValue(item);
            },
            .dict => |d| {
                const sorted = self.allocator.dupe(Entry, d.entries.items) catch return error.OutOfMemory;
                defer self.allocator.free(sorted);
                std.mem.sort(Entry, sorted, self, lessEntry);
                try self.out.appendByte(0xC1);
                try self.append24(@intCast(sorted.len));
                for (sorted) |e| {
                    try self.append24(self.key_index.get(e.key).?);
                    try self.out.appendByte(typeOf(e.value));
                    try self.inlineValue(e.value);
                }
            },
            else => unreachable,
        }
        return start;
    }

    /// The offset of an identical container already written, else writes it.
    fn sharedContainer(self: *Self, v: Value) BymlError!u32 {
        var hasher = std.hash.Wyhash.init(0);
        structuralHash(v, &hasher);
        const h = hasher.final();
        const slot = self.seen.getOrPut(h) catch return error.OutOfMemory;
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        for (slot.value_ptr.items) |w| {
            if (Value.exactEql(w.value, v)) return w.offset;
        }
        const offset = try self.container(v);
        // `container` may have grown the map: look the slot up again before appending
        const list = self.seen.getPtr(h).?;
        list.append(self.allocator, Written{ .value = v, .offset = offset }) catch return error.OutOfMemory;
        return offset;
    }
};

/// Writes a tree as BYML (little-endian unless `big_endian`). Identical sub-trees are written once, as Nintendo's
/// tools do; children follow their parents breadth-first. Returns bytes allocated with `allocator`.
pub fn dump(allocator: Allocator, root: ?Value, version: u16, big_endian: bool) BymlError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w = Writer{
        .allocator = arena,
        .big = big_endian,
        .out = bytes.Buffer.init(allocator),
        .key_index = std.StringHashMap(u32).init(arena),
        .string_index = std.StringHashMap(u32).init(arena),
        .pending = .empty,
        .seen = std.AutoHashMap(u64, std.ArrayList(Written)).init(arena),
    };
    errdefer w.out.deinit();

    // key and string tables, sorted by their bytes
    var key_set = std.StringHashMap(void).init(arena);
    var string_set = std.StringHashMap(void).init(arena);
    if (root) |r| try w.collect(r, &key_set, &string_set);
    const keys = arena.alloc([]const u8, key_set.count()) catch return error.OutOfMemory;
    var kit = key_set.keyIterator();
    var k: usize = 0;
    while (kit.next()) |key| : (k += 1) keys[k] = key.*;
    std.mem.sort([]const u8, keys, {}, lessBytes);
    const strings = arena.alloc([]const u8, string_set.count()) catch return error.OutOfMemory;
    var sit = string_set.keyIterator();
    k = 0;
    while (sit.next()) |s| : (k += 1) strings[k] = s.*;
    std.mem.sort([]const u8, strings, {}, lessBytes);
    for (keys, 0..) |key, i| w.key_index.put(key, @intCast(i)) catch return error.OutOfMemory;
    for (strings, 0..) |s, i| w.string_index.put(s, @intCast(i)) catch return error.OutOfMemory;

    try w.out.appendZeros(16);
    const key_table = try w.stringTable(keys);
    const string_table = try w.stringTable(strings);

    var root_offset: u32 = 0;
    if (root) |r| {
        if (r != .array and r != .dict) return error.InvalidData;
        root_offset = try w.container(r);
    }

    // breadth-first: containers and binary data, then the 64-bit values
    var deferred: std.ArrayList(Pending) = .empty;
    var i: usize = 0;
    while (i < w.pending.items.len) : (i += 1) {
        const p = w.pending.items[i];
        const offset: u32 = switch (p.value) {
            .array, .dict => try w.sharedContainer(p.value),
            .binary => |data| blk: {
                try w.out.alignTo(4);
                const at: u32 = @intCast(w.out.len());
                try w.append32(@intCast(data.len));
                try w.out.append(data);
                break :blk at;
            },
            else => {
                deferred.append(arena, p) catch return error.OutOfMemory;
                continue;
            },
        };
        w.put32(p.field, offset);
    }

    // 64-bit values, each distinct one written once
    var seen64 = std.AutoHashMap(u72, u32).init(arena);
    for (deferred.items) |p| {
        const raw: u64 = switch (p.value) {
            .int64 => |x| @bitCast(x),
            .uint64 => |x| x,
            .double => |x| @bitCast(x),
            else => unreachable,
        };
        const key: u72 = (@as(u72, typeOf(p.value)) << 64) | raw;
        const offset = if (seen64.get(key)) |o| o else blk: {
            try w.out.alignTo(8);
            const at: u32 = @intCast(w.out.len());
            try w.out.appendU64(if (big_endian) @byteSwap(raw) else raw);
            seen64.put(key, at) catch return error.OutOfMemory;
            break :blk at;
        };
        w.put32(p.field, offset);
    }
    try w.out.alignTo(4);

    const out = w.out.bytes();
    if (big_endian) {
        out[0] = 'B';
        out[1] = 'Y';
        std.mem.writeInt(u16, out[2..4], version, .big);
    } else {
        out[0] = 'Y';
        out[1] = 'B';
        std.mem.writeInt(u16, out[2..4], version, .little);
    }
    w.put32(4, key_table);
    w.put32(8, string_table);
    w.put32(12, root_offset);
    return w.out.toOwnedSlice();
}

/// Writes a tree as little-endian BYML version 7 (what most patches write).
pub fn dumpDefault(allocator: Allocator, root: Value) BymlError![]u8 {
    return dump(allocator, root, 7, false);
}

test "round trip keeps types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try Dict.create(a);
    try root.put(a, "Name", .{ .string = "Hookshot" });
    try root.put(a, "Count", .{ .uint = 3 });
    try root.put(a, "Big", .{ .uint64 = 11738513547087641325 });
    try root.put(a, "Flag", .{ .bool = true });
    const list = try root.ensureArray(a, "List");
    try list.append(a, .{ .float = 1.5 });
    try list.append(a, .{ .int = -2 });

    const data = try dumpDefault(a, .{ .dict = root });
    const back = try loadDict(a, data);
    try std.testing.expect(Value.exactEql(.{ .dict = root }, .{ .dict = back }));
    try std.testing.expectEqual(@as(?i128, 11738513547087641325), back.getInt("Big"));
    const again = try dumpDefault(a, .{ .dict = back });
    try std.testing.expectEqualSlices(u8, data, again);
}
