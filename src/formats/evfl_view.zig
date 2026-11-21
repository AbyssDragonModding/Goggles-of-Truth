//! A read-only view of an event flow plus the file offsets of its parameters, for patching a file in place.
//!
//! This is the older, simpler reader (rando/formats.py EvflFile). The world scan records where an item parameter
//! lives (its file offset), and the generator re-points that one string later without rewriting the file: the new
//! string is appended at the end and the pointer, already in the relocation table, gets the new offset.
//! For structural edits (new events) use evfl.zig instead.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const ViewError = error{ InvalidData, OutOfMemory };

pub const Value = union(enum) {
    string: []const u8,
    /// an argument name (container type 0)
    argument: []const u8,
    int: i32,
    bool: bool,
    float: f32,
    dict: *Params,
    /// arrays and actor identifiers: present, but never compared
    other,
};

/// A parameter dictionary, with the offsets of its string and int values.
pub const Params = struct {
    names: [][]const u8,
    values: []Value,
    /// For each value: the offset of its string pointer (string types) or its int (int type), else null.
    offsets: []?usize,

    const Self = @This();

    pub fn get(self: *const Self, name: []const u8) ?Value {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.values[i];
        }
        return null;
    }

    pub fn getString(self: *const Self, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// An int parameter (Python's isinstance(x, int) also took bools, so bools count as 0/1).
    pub fn getInt(self: *const Self, name: []const u8) ?i64 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .int => |x| x,
            .bool => |b| @intFromBool(b),
            else => null,
        };
    }

    pub fn isString(self: *const Self, name: []const u8, expected: []const u8) bool {
        const s = self.getString(name) orelse return false;
        return std.mem.eql(u8, s, expected);
    }

    /// The offset of string parameter `name`'s pointer field, or null.
    pub fn stringOffset(self: *const Self, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name) and (self.values[i] == .string)) return self.offsets[i];
        }
        return null;
    }

    /// The offset of int parameter `name`'s value, or null.
    pub fn intOffset(self: *const Self, name: []const u8) ?usize {
        for (self.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name) and self.values[i] == .int) return self.offsets[i];
        }
        return null;
    }
};

pub const Case = struct {
    value: u32,
    target: u32,
};

pub const EventType = enum(u8) { action = 0, switch_ = 1, fork = 2, join = 3, sub_flow = 4, other = 255 };

pub const Event = struct {
    index: usize,
    name: []const u8,
    type: EventType,
    /// file offset of the event record
    offset: usize,
    actor: ?[]const u8 = null,
    action: ?[]const u8 = null,
    query: ?[]const u8 = null,
    next: ?u16 = null,
    join: ?u16 = null,
    cases: []Case = &.{},
    forks: []u16 = &.{},
    params: ?*Params = null,
    /// sub-flow calls
    flowchart: ?[]const u8 = null,
    entry: ?[]const u8 = null,
    /// the entry points that reach this event
    entry_points: std.ArrayList([]const u8) = .empty,

    pub fn reachedFrom(self: *const Event, prefix: []const u8) bool {
        for (self.entry_points.items) |e| {
            if (std.mem.startsWith(u8, e, prefix)) return true;
        }
        return false;
    }

    pub fn reachedFromExactly(self: *const Event, name: []const u8) bool {
        for (self.entry_points.items) |e| {
            if (std.mem.eql(u8, e, name)) return true;
        }
        return false;
    }
};

pub const Flowchart = struct {
    name: []const u8,
    events: []Event,
    entry_points: [][]const u8,
};

pub const View = struct {
    allocator: Allocator,
    data: std.ArrayList(u8),
    flowcharts: []Flowchart,

    const Self = @This();

    /// Reads `src` (copied: the view patches its own bytes). Allocate with an arena.
    pub fn init(allocator: Allocator, src: []const u8) ViewError!Self {
        var self = Self{ .allocator = allocator, .data = .empty, .flowcharts = &.{} };
        self.data.appendSlice(allocator, src) catch return error.OutOfMemory;
        if (src.len < 0x30 or !std.mem.eql(u8, src[0..6], "BFEVFL")) return error.InvalidData;
        const d = self.data.items;
        const count = try bytes.u16At(d, 0x20);
        const list = try self.ptrAt(0x28);
        const fcs = allocator.alloc(Flowchart, count) catch return error.OutOfMemory;
        for (fcs, 0..) |*fc, i| fc.* = try self.flowchart(try self.ptrAt(list + i * 8));
        self.flowcharts = fcs;
        return self;
    }

    pub fn bytesView(self: *const Self) []const u8 {
        return self.data.items;
    }

    fn ptrAt(self: *const Self, off: usize) ViewError!usize {
        const v = try bytes.u64At(self.data.items, off);
        if (v > self.data.items.len) return error.InvalidData;
        return @intCast(v);
    }

    fn str(self: *const Self, p: usize) ViewError!?[]const u8 {
        if (p == 0) return null;
        const n = try bytes.u16At(self.data.items, p);
        return try bytes.sliceAt(self.data.items, p + 2, p + 2 + n);
    }

    fn strOrEmpty(self: *const Self, p: usize) ViewError![]const u8 {
        return (try self.str(p)) orelse "";
    }

    /// The names of a dictionary.
    fn dic(self: *const Self, p: usize) ViewError![][]const u8 {
        if (p == 0) return &.{};
        const n = try bytes.u32At(self.data.items, p + 4);
        const out = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
        for (out, 0..) |*name, i| name.* = try self.strOrEmpty(try self.ptrAt(p + 8 + (i + 1) * 0x10 + 8));
        return out;
    }

    fn container(self: *const Self, p: usize) ViewError!?Value {
        if (p == 0) return null;
        const d = self.data.items;
        const t = try bytes.u8At(d, p);
        const n = try bytes.u16At(d, p + 2);
        if (t == 1) {
            const names = try self.dic(try self.ptrAt(p + 8));
            if (names.len < n) return error.InvalidData;
            const params = self.allocator.create(Params) catch return error.OutOfMemory;
            params.* = Params{
                .names = names[0..n],
                .values = self.allocator.alloc(Value, n) catch return error.OutOfMemory,
                .offsets = self.allocator.alloc(?usize, n) catch return error.OutOfMemory,
            };
            for (0..n) |i| {
                const ip = try self.ptrAt(p + 0x10 + i * 8);
                params.values[i] = (try self.container(ip)) orelse .other;
                params.offsets[i] = null;
                if (ip != 0) {
                    const it = try bytes.u8At(d, ip);
                    if (it == 5 or it == 6 or it == 2) params.offsets[i] = ip + 0x10;
                }
            }
            return Value{ .dict = params };
        }
        const v = p + 0x10;
        return switch (t) {
            0 => Value{ .argument = try self.strOrEmpty(try self.ptrAt(v)) },
            2 => Value{ .int = try bytes.i32At(d, v) },
            3 => Value{ .bool = (try bytes.u32At(d, v)) != 0 },
            4 => Value{ .float = try bytes.f32At(d, v) },
            5, 6 => Value{ .string = try self.strOrEmpty(try self.ptrAt(v)) },
            else => Value.other,
        };
    }

    fn flowchart(self: *const Self, fp: usize) ViewError!Flowchart {
        const d = self.data.items;
        const na = try bytes.u16At(d, fp + 0x10);
        const ne = try bytes.u16At(d, fp + 0x16);
        const nep = try bytes.u16At(d, fp + 0x18);
        const actors_p = try self.ptrAt(fp + 0x28);
        const events_p = try self.ptrAt(fp + 0x30);
        const ep_dic = try self.ptrAt(fp + 0x38);
        const ep_p = try self.ptrAt(fp + 0x40);

        const ActorNames = struct { name: []const u8, actions: [][]const u8, queries: [][]const u8 };
        const actors = self.allocator.alloc(ActorNames, na) catch return error.OutOfMemory;
        for (actors, 0..) |*a, i| {
            const ap = actors_p + i * 0x38;
            const acts = try self.ptrAt(ap + 0x18);
            const qs = try self.ptrAt(ap + 0x20);
            const nact = try bytes.u16At(d, ap + 0x30);
            const nq = try bytes.u16At(d, ap + 0x32);
            a.name = try self.strOrEmpty(try self.ptrAt(ap));
            a.actions = self.allocator.alloc([]const u8, nact) catch return error.OutOfMemory;
            for (a.actions, 0..) |*s, k| s.* = try self.strOrEmpty(try self.ptrAt(acts + k * 8));
            a.queries = self.allocator.alloc([]const u8, nq) catch return error.OutOfMemory;
            for (a.queries, 0..) |*s, k| s.* = try self.strOrEmpty(try self.ptrAt(qs + k * 8));
        }

        const events = self.allocator.alloc(Event, ne) catch return error.OutOfMemory;
        for (events, 0..) |*e, i| {
            const p = events_p + i * 0x30;
            const et = try bytes.u8At(d, p + 8);
            e.* = Event{
                .index = i,
                .name = try self.strOrEmpty(try self.ptrAt(p)),
                .type = switch (et) {
                    0 => .action,
                    1 => .switch_,
                    2 => .fork,
                    3 => .join,
                    4 => .sub_flow,
                    else => .other,
                },
                .offset = p,
            };
            switch (et) {
                0, 1 => {
                    const ai = try bytes.u16At(d, p + 0xC);
                    const actor: ?ActorNames = if (ai < actors.len) actors[ai] else null;
                    e.actor = if (actor) |a| a.name else null;
                    const sub = try bytes.u16At(d, p + 0xE);
                    if (et == 0) {
                        e.next = try bytes.u16At(d, p + 0xA);
                        if (actor) |a| e.action = if (sub < a.actions.len) a.actions[sub] else return error.InvalidData;
                    } else {
                        if (actor) |a| e.query = if (sub < a.queries.len) a.queries[sub] else return error.InvalidData;
                        const nc = try bytes.u16At(d, p + 0xA);
                        const cp = try self.ptrAt(p + 0x18);
                        e.cases = self.allocator.alloc(Case, nc) catch return error.OutOfMemory;
                        for (e.cases, 0..) |*c, k| c.* = Case{ .value = try bytes.u32At(d, cp + k * 8), .target = try bytes.u32At(d, cp + k * 8 + 4) };
                    }
                    if (try self.container(try self.ptrAt(p + 0x10))) |v| e.params = if (v == .dict) v.dict else null;
                },
                2 => {
                    const nf = try bytes.u16At(d, p + 0xA);
                    const fp2 = try self.ptrAt(p + 0x10);
                    e.join = try bytes.u16At(d, p + 0xC);
                    e.forks = self.allocator.alloc(u16, nf) catch return error.OutOfMemory;
                    for (e.forks, 0..) |*f, k| f.* = try bytes.u16At(d, fp2 + k * 2);
                },
                3 => e.next = try bytes.u16At(d, p + 0xA),
                4 => {
                    e.next = try bytes.u16At(d, p + 0xA);
                    if (try self.container(try self.ptrAt(p + 0x10))) |v| e.params = if (v == .dict) v.dict else null;
                    e.flowchart = try self.str(try self.ptrAt(p + 0x18));
                    e.entry = try self.str(try self.ptrAt(p + 0x20));
                },
                else => {},
            }
        }

        // which entry points reach each event (for readable context, and the patches that check it)
        const entry_names = try self.dic(ep_dic);
        var seen = self.allocator.alloc(bool, events.len) catch return error.OutOfMemory;
        var stack: std.ArrayList(usize) = .empty;
        for (entry_names, 0..) |name, k| {
            if (k >= nep) break;
            const main = try bytes.u16At(d, ep_p + k * 0x20 + 0x1C);
            @memset(seen, false);
            stack.clearRetainingCapacity();
            stack.append(self.allocator, main) catch return error.OutOfMemory;
            while (stack.pop()) |i| {
                if (i >= events.len or seen[i]) continue;
                seen[i] = true;
                const e = &events[i];
                e.entry_points.append(self.allocator, name) catch return error.OutOfMemory;
                if (e.next) |n| stack.append(self.allocator, n) catch return error.OutOfMemory;
                for (e.cases) |c| stack.append(self.allocator, c.target) catch return error.OutOfMemory;
                for (e.forks) |f| stack.append(self.allocator, f) catch return error.OutOfMemory;
                if (e.join) |j| stack.append(self.allocator, j) catch return error.OutOfMemory;
            }
        }
        return Flowchart{
            .name = try self.strOrEmpty(try self.ptrAt(fp + 0x20)),
            .events = events,
            .entry_points = entry_names,
        };
    }

    /// Overwrites an int parameter in place (same size).
    pub fn setIntParam(self: *Self, field_offset: usize, value: i32) void {
        bytes.putI32(self.data.items, field_offset, value);
    }

    /// Rewrites a switch event's case targets in place: each case whose value is in `values` gets `targets[k]`.
    pub fn setCaseTargets(self: *Self, event: *const Event, values: []const u32, targets: []const u32) ViewError!void {
        const cp = try self.ptrAt(event.offset + 0x18);
        for (0..event.cases.len) |k| {
            const value = try bytes.u32At(self.data.items, cp + k * 8);
            for (values, targets) |v, t| {
                if (v == value) bytes.putU32(self.data.items, cp + k * 8 + 4, t);
            }
        }
    }

    /// Re-points one string parameter to a new string appended at the end of the file. The pointer field is
    /// already in the relocation table, so only its value changes.
    pub fn setStringParam(self: *Self, field_offset: usize, value: []const u8) ViewError!void {
        const a = self.allocator;
        while (self.data.items.len % 8 != 0) self.data.append(a, 0) catch return error.OutOfMemory;
        const off = self.data.items.len;
        var len_raw: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_raw, @intCast(value.len), .little);
        self.data.appendSlice(a, &len_raw) catch return error.OutOfMemory;
        self.data.appendSlice(a, value) catch return error.OutOfMemory;
        self.data.append(a, 0) catch return error.OutOfMemory;
        bytes.putU64(self.data.items, field_offset, off);
        while (self.data.items.len % 8 != 0) self.data.append(a, 0) catch return error.OutOfMemory;
        bytes.putU32(self.data.items, 0x1C, @intCast(self.data.items.len)); // header: file size
    }

    /// Checks the patched bytes still parse.
    pub fn check(self: *const Self, allocator: Allocator) ViewError!void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try View.init(arena.allocator(), self.data.items);
    }
};
