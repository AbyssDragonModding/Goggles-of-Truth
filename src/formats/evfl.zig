//! Event flows (Event/EventFlow/*.bfevfl): read into a document and write back in the game's own layout.
//!
//! Ported from rando/evfl.py, itself ported from Clawshot (https://github.com/hiKareeem/Clawshot,
//! src/clawshot/formats/evfl.py), MIT License, Copyright (c) 2026 Kareem Albaba and the Clawshot contributors.
//! The format notes (from the ZeldaMods wiki's BFEVFL page and the game's own files, version 0.4.0.0):
//!
//! - An event is 0x30 bytes. Besides the wiki's five types there are two more: 5 calls an entry point and branches
//!   on the value it returns (SubFlowSwitch), and 6 ends an entry point returning a 32-bit value (Return).
//! - An entry point's variable is 0x10 bytes: an 8-byte value, a u16 count (1), a u16 type (2 int, 3 bool, 4 float).
//!   An entry point without variables still owns an empty dictionary of 0x18 zero bytes.
//! - The string pool ("STR ") holds every name once, sorted by its bits read from the last byte's lowest bit (the
//!   order the radix-tree dictionaries compare in), after a 0x14-byte header.
//! - A file holds one flowchart or one timeline, never both.
//!
//! Writing reproduces the game's layout, so every flow in the game writes back byte-identical: header; flowchart
//! pointer array and dictionary; timeline pointer array and dictionary; the flowchart (header, actors, events,
//! entry point dictionary, entry points, then per event its cases or forks and parameters, per actor its parameters
//! and names, per entry point its sub-flow indices and variables) or the timeline; the string pool; the relocation
//! table. References between events, actors and entry points are indices, as in the file; NONE (0xFFFF) is none.
//!
//! Everything is allocated with the allocator given to `read` (use an arena).

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const EvflError = error{ InvalidData, OutOfMemory };

pub const NONE: u16 = 0xFFFF;
const magic = "BFEVFL\x00\x00";
const version = [4]u8{ 0, 4, 0, 0 };
const alignment_shift: u8 = 3;
const bool_true: u32 = 0x80000001;

// container item types
const T_ARGUMENT: u8 = 0;
const T_CONTAINER: u8 = 1;
const T_INT: u8 = 2;
const T_BOOL: u8 = 3;
const T_FLOAT: u8 = 4;
const T_STRING: u8 = 5;
const T_FLOAT_ARRAY: u8 = 9;
const T_ACTOR_IDENTIFIER: u8 = 12;

// event types
const E_ACTION: u8 = 0;
const E_SWITCH: u8 = 1;
const E_FORK: u8 = 2;
const E_JOIN: u8 = 3;
const E_SUB_FLOW: u8 = 4;
const E_SUB_FLOW_SWITCH: u8 = 5;
const E_RETURN: u8 = 6;

// ------------------------------------------------------------------------------------------------- the document

pub const ActorIdentifier = struct {
    name: []const u8,
    secondary_name: []const u8 = "",
};

/// A parameter value, keeping its container type.
pub const Param = union(enum) {
    argument: []const u8,
    container: *Container,
    int: i32,
    bool: bool,
    float: f32,
    string: []const u8,
    float_array: []f32,
    actor_identifier: ActorIdentifier,

    /// The text of a string or argument parameter (in the Python version an Argument was a str, so both compared
    /// equal to plain text).
    pub fn asString(self: Param) ?[]const u8 {
        return switch (self) {
            .string, .argument => |s| s,
            else => null,
        };
    }

    /// The number of an int or bool parameter (bool as 0/1).
    pub fn asInt(self: Param) ?i64 {
        return switch (self) {
            .int => |v| v,
            .bool => |v| @intFromBool(v),
            else => null,
        };
    }

    /// Equality as the Python version compared values: 1 == 1.0 == true, strings by content.
    pub fn looseEql(a: Param, b: Param) bool {
        const an = numberOf(a);
        const bn = numberOf(b);
        if (an != null and bn != null) return an.? == bn.?;
        return switch (a) {
            .string, .argument => |s| if (b.asString()) |t| std.mem.eql(u8, s, t) else false,
            .actor_identifier => |x| switch (b) {
                .actor_identifier => |y| std.mem.eql(u8, x.name, y.name) and std.mem.eql(u8, x.secondary_name, y.secondary_name),
                else => false,
            },
            .float_array => |x| switch (b) {
                .float_array => |y| std.mem.eql(f32, x, y),
                else => false,
            },
            .container => |x| switch (b) {
                .container => |y| x.looseEql(y),
                else => false,
            },
            else => false,
        };
    }

    fn numberOf(p: Param) ?f64 {
        return switch (p) {
            .int => |v| @floatFromInt(v),
            .bool => |v| if (v) 1 else 0,
            .float => |v| v,
            else => null,
        };
    }

    pub fn clone(self: Param, allocator: Allocator) EvflError!Param {
        return switch (self) {
            .container => |c| Param{ .container = try c.clone(allocator) },
            .float_array => |a| Param{ .float_array = allocator.dupe(f32, a) catch return error.OutOfMemory },
            else => self,
        };
    }
};

pub const Item = struct {
    name: []const u8,
    value: Param,
};

/// Parameters: an ordered list of named values (the order is written to the file).
pub const Container = struct {
    items: std.ArrayList(Item),

    const Self = @This();

    pub fn create(allocator: Allocator) EvflError!*Self {
        const self = allocator.create(Self) catch return error.OutOfMemory;
        self.* = Self{ .items = .empty };
        return self;
    }

    pub fn get(self: *const Self, name: []const u8) ?Param {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    pub fn getString(self: *const Self, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |p| p.asString() else null;
    }

    pub fn has(self: *const Self, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// True when parameter `name` is there and loosely equals `value`.
    pub fn is(self: *const Self, name: []const u8, value: Param) bool {
        const p = self.get(name) orelse return false;
        return Param.looseEql(p, value);
    }

    pub fn isString(self: *const Self, name: []const u8, value: []const u8) bool {
        const s = self.getString(name) orelse return false;
        return std.mem.eql(u8, s, value);
    }

    /// Sets `name` in place when it exists, else adds it at the end.
    pub fn put(self: *Self, allocator: Allocator, name: []const u8, value: Param) EvflError!void {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.name, name)) {
                item.value = value;
                return;
            }
        }
        self.items.append(allocator, Item{ .name = name, .value = value }) catch return error.OutOfMemory;
    }

    pub fn clone(self: *const Self, allocator: Allocator) EvflError!*Self {
        const copy = try Self.create(allocator);
        copy.items.ensureTotalCapacity(allocator, self.items.items.len) catch return error.OutOfMemory;
        for (self.items.items) |item| {
            copy.items.appendAssumeCapacity(Item{ .name = item.name, .value = try item.value.clone(allocator) });
        }
        return copy;
    }

    /// Same names with equal values, in any order (Python dict equality).
    pub fn looseEql(self: *const Self, other: *const Self) bool {
        if (self.items.items.len != other.items.items.len) return false;
        for (self.items.items) |item| {
            const v = other.get(item.name) orelse return false;
            if (!Param.looseEql(item.value, v)) return false;
        }
        return true;
    }

    /// Builds a container from (name, value) pairs.
    pub fn from(allocator: Allocator, pairs: []const Item) EvflError!*Self {
        const self = try Self.create(allocator);
        for (pairs) |pair| try self.put(allocator, pair.name, pair.value);
        return self;
    }
};

/// Clones optional parameters.
pub fn cloneParams(allocator: Allocator, params: ?*Container) EvflError!?*Container {
    return if (params) |p| try p.clone(allocator) else null;
}

pub const Actor = struct {
    name: []const u8,
    secondary_name: []const u8 = "",
    argument_name: []const u8 = "",
    actions: std.ArrayList([]const u8) = .empty,
    queries: std.ArrayList([]const u8) = .empty,
    params: ?*Container = null,
    /// Index of the entry point this actor belongs to.
    entry_point: u16 = NONE,
    cut_number: u8 = 1,
};

pub const Case = struct {
    value: u32,
    event: u16,
};

pub const ActionEvent = struct {
    actor: u16,
    action: u16,
    next: u16 = NONE,
    params: ?*Container = null,
};

pub const SwitchEvent = struct {
    actor: u16,
    query: u16,
    cases: std.ArrayList(Case) = .empty,
    params: ?*Container = null,
};

pub const ForkEvent = struct {
    join: u16,
    forks: std.ArrayList(u16) = .empty,
};

pub const JoinEvent = struct {
    next: u16 = NONE,
};

pub const SubFlowEvent = struct {
    /// "" for this file's own flowchart.
    flowchart: []const u8,
    entry_point: []const u8,
    next: u16 = NONE,
    params: ?*Container = null,
};

/// Type 5: calls flowchart:entry_point and branches on the value a ReturnEvent there gives.
pub const SubFlowSwitchEvent = struct {
    flowchart: []const u8,
    entry_point: []const u8,
    cases: std.ArrayList(Case) = .empty,
    params: ?*Container = null,
};

/// Type 6: ends the entry point, returning `value`.
pub const ReturnEvent = struct {
    value: u32,
};

pub const EventKind = union(enum) {
    action: ActionEvent,
    switch_: SwitchEvent,
    fork: ForkEvent,
    join: JoinEvent,
    sub_flow: SubFlowEvent,
    sub_flow_switch: SubFlowSwitchEvent,
    return_: ReturnEvent,
};

pub const Event = struct {
    name: []const u8,
    kind: EventKind,

    /// The `next` link of an action, join or sub-flow event, else null.
    pub fn nextPtr(self: *Event) ?*u16 {
        return switch (self.kind) {
            .action => |*a| &a.next,
            .join => |*j| &j.next,
            .sub_flow => |*s| &s.next,
            else => null,
        };
    }

    pub fn next(self: *const Event) ?u16 {
        return switch (self.kind) {
            .action => |a| a.next,
            .join => |j| j.next,
            .sub_flow => |s| s.next,
            else => null,
        };
    }

    /// The cases of a switch or sub-flow switch event, else null.
    pub fn casesPtr(self: *Event) ?*std.ArrayList(Case) {
        return switch (self.kind) {
            .switch_ => |*s| &s.cases,
            .sub_flow_switch => |*s| &s.cases,
            else => null,
        };
    }

    /// The parameters of the event kinds that have them.
    pub fn params(self: *const Event) ?*Container {
        return switch (self.kind) {
            .action => |a| a.params,
            .switch_ => |s| s.params,
            .sub_flow => |s| s.params,
            .sub_flow_switch => |s| s.params,
            else => null,
        };
    }

    /// Every event this one can lead to (cases, forks and join, or next).
    pub fn targets(self: *const Event, out: *std.ArrayList(u16), allocator: Allocator) EvflError!void {
        switch (self.kind) {
            .switch_ => |s| for (s.cases.items) |c| out.append(allocator, c.event) catch return error.OutOfMemory,
            .sub_flow_switch => |s| for (s.cases.items) |c| out.append(allocator, c.event) catch return error.OutOfMemory,
            .fork => |f| {
                out.appendSlice(allocator, f.forks.items) catch return error.OutOfMemory;
                out.append(allocator, f.join) catch return error.OutOfMemory;
            },
            .action => |a| out.append(allocator, a.next) catch return error.OutOfMemory,
            .join => |j| out.append(allocator, j.next) catch return error.OutOfMemory,
            .sub_flow => |s| out.append(allocator, s.next) catch return error.OutOfMemory,
            .return_ => {},
        }
    }

    /// True when this event can lead to `index`.
    pub fn leadsTo(self: *const Event, index: u16) bool {
        switch (self.kind) {
            .switch_ => |s| for (s.cases.items) |c| {
                if (c.event == index) return true;
            },
            .sub_flow_switch => |s| for (s.cases.items) |c| {
                if (c.event == index) return true;
            },
            .fork => |f| {
                if (f.join == index) return true;
                for (f.forks.items) |x| if (x == index) return true;
            },
            else => if (self.next()) |n| return n == index,
        }
        return false;
    }

    /// A deep copy (lists and parameters are new).
    pub fn clone(self: Event, allocator: Allocator) EvflError!Event {
        var copy = self;
        switch (copy.kind) {
            .action => |*a| a.params = try cloneParams(allocator, a.params),
            .switch_ => |*s| {
                s.cases = s.cases.clone(allocator) catch return error.OutOfMemory;
                s.params = try cloneParams(allocator, s.params);
            },
            .fork => |*f| f.forks = f.forks.clone(allocator) catch return error.OutOfMemory,
            .join, .return_ => {},
            .sub_flow => |*s| s.params = try cloneParams(allocator, s.params),
            .sub_flow_switch => |*s| {
                s.cases = s.cases.clone(allocator) catch return error.OutOfMemory;
                s.params = try cloneParams(allocator, s.params);
            },
        }
        return copy;
    }
};

pub const VariableValue = union(enum) {
    int: i64,
    bool: bool,
    float: f32,
};

pub const Variable = struct {
    name: []const u8,
    value: VariableValue,
};

pub const EntryPoint = struct {
    name: []const u8,
    main_event: u16 = NONE,
    sub_flow_events: std.ArrayList(u16) = .empty,
    variables: std.ArrayList(Variable) = .empty,

    pub fn hasSubFlowEvent(self: *const EntryPoint, index: u16) bool {
        return std.mem.indexOfScalar(u16, self.sub_flow_events.items, index) != null;
    }
};

pub const Flowchart = struct {
    name: []const u8,
    actors: std.ArrayList(Actor) = .empty,
    events: std.ArrayList(Event) = .empty,
    entry_points: std.ArrayList(EntryPoint) = .empty,

    const Self = @This();

    pub fn entryPoint(self: *Self, name: []const u8) ?*EntryPoint {
        for (self.entry_points.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn event(self: *Self, index: u16) ?*Event {
        if (index >= self.events.items.len) return null;
        return &self.events.items[index];
    }

    /// Index of the event named `name`, or null.
    pub fn eventByName(self: *const Self, name: []const u8) ?u16 {
        for (self.events.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Adds an event at the end; returns its index.
    pub fn addEvent(self: *Self, allocator: Allocator, e: Event) EvflError!u16 {
        self.events.append(allocator, e) catch return error.OutOfMemory;
        return @intCast(self.events.items.len - 1);
    }

    /// The actor named `name` without a secondary name, or null.
    pub fn findActor(self: *const Self, name: []const u8) ?u16 {
        for (self.actors.items, 0..) |a, i| {
            if (std.mem.eql(u8, a.name, name) and a.secondary_name.len == 0) return @intCast(i);
        }
        return null;
    }

    /// Name of an action event's action (null for other events or a bad index).
    pub fn actionName(self: *const Self, e: *const Event) ?[]const u8 {
        const a = switch (e.kind) {
            .action => |a| a,
            else => return null,
        };
        if (a.actor >= self.actors.items.len) return null;
        const actor = self.actors.items[a.actor];
        if (a.action >= actor.actions.items.len) return null;
        return actor.actions.items[a.action];
    }

    /// Name of a switch event's query (null for other events or a bad index).
    pub fn queryName(self: *const Self, e: *const Event) ?[]const u8 {
        const s = switch (e.kind) {
            .switch_ => |s| s,
            else => return null,
        };
        if (s.actor >= self.actors.items.len) return null;
        const actor = self.actors.items[s.actor];
        if (s.query >= actor.queries.items.len) return null;
        return actor.queries.items[s.query];
    }

    /// Name of the actor an action or switch event uses.
    pub fn actorName(self: *const Self, e: *const Event) ?[]const u8 {
        const index = switch (e.kind) {
            .action => |a| a.actor,
            .switch_ => |s| s.actor,
            else => return null,
        };
        if (index >= self.actors.items.len) return null;
        return self.actors.items[index].name;
    }

    /// True for an action event `actor`.`action`.
    pub fn isAction(self: *const Self, e: *const Event, actor: []const u8, action: []const u8) bool {
        const a = self.actorName(e) orelse return false;
        const n = self.actionName(e) orelse return false;
        return std.mem.eql(u8, a, actor) and std.mem.eql(u8, n, action);
    }

    /// True for a switch event asking `actor`.`query`.
    pub fn isQuery(self: *const Self, e: *const Event, actor: []const u8, query: []const u8) bool {
        const a = self.actorName(e) orelse return false;
        const n = self.queryName(e) orelse return false;
        return std.mem.eql(u8, a, actor) and std.mem.eql(u8, n, query);
    }

    /// (actor index, action index) of `actor_name`.`action`, adding the action to the actor when it is missing.
    /// Null when the flow has no such actor.
    pub fn actionIndex(self: *Self, allocator: Allocator, actor_name: []const u8, action: []const u8) EvflError!?[2]u16 {
        const index = self.findActor(actor_name) orelse return null;
        const actor = &self.actors.items[index];
        for (actor.actions.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, action)) return .{ index, @intCast(i) };
        }
        actor.actions.append(allocator, action) catch return error.OutOfMemory;
        return .{ index, @intCast(actor.actions.items.len - 1) };
    }

    /// Like actionIndex, for a query.
    pub fn queryIndex(self: *Self, allocator: Allocator, actor_name: []const u8, query: []const u8) EvflError!?[2]u16 {
        const index = self.findActor(actor_name) orelse return null;
        const actor = &self.actors.items[index];
        for (actor.queries.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, query)) return .{ index, @intCast(i) };
        }
        actor.queries.append(allocator, query) catch return error.OutOfMemory;
        return .{ index, @intCast(actor.queries.items.len - 1) };
    }

    /// Every event reachable from `start` inside this flowchart (sub-flow calls are not followed). The result is a
    /// set over event indices (true = reachable), allocated with `allocator`.
    pub fn reach(self: *const Self, allocator: Allocator, start: u16) EvflError![]bool {
        const seen = allocator.alloc(bool, self.events.items.len) catch return error.OutOfMemory;
        @memset(seen, false);
        var stack: std.ArrayList(u16) = .empty;
        defer stack.deinit(allocator);
        stack.append(allocator, start) catch return error.OutOfMemory;
        while (stack.pop()) |i| {
            if (i >= self.events.items.len or seen[i]) continue;
            seen[i] = true;
            try self.events.items[i].targets(&stack, allocator);
        }
        return seen;
    }

    /// Indices of the events that can lead to `index` (in event order).
    pub fn predecessors(self: *const Self, allocator: Allocator, index: u16) EvflError![]u16 {
        var out: std.ArrayList(u16) = .empty;
        for (self.events.items, 0..) |*e, i| {
            if (e.leadsTo(index)) out.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};

pub const Clip = struct {
    start: f32,
    duration: f32,
    actor: u16,
    action: u16,
    /// the byte at 0xC
    unknown: u8 = 0,
    params: ?*Container = null,
};

pub const Trigger = struct {
    clip: u16,
    /// 1 enter, 2 leave
    type: u8,
};

pub const Cut = struct {
    start: f32,
    /// the u32 at 0x4
    unknown: u32,
    name: []const u8,
    params: ?*Container = null,
};

pub const Timeline = struct {
    name: []const u8,
    duration: f32,
    actors: std.ArrayList(Actor) = .empty,
    clips: std.ArrayList(Clip) = .empty,
    triggers: std.ArrayList(Trigger) = .empty,
    subtimelines: std.ArrayList([]const u8) = .empty,
    cuts: std.ArrayList(Cut) = .empty,
    params: ?*Container = null,
};

pub const Document = struct {
    name: []const u8,
    flowchart: ?*Flowchart = null,
    timeline: ?*Timeline = null,
};

// ------------------------------------------------------------------------------------------------------- reading

const Reader = struct {
    data: []const u8,
    allocator: Allocator,

    const Self = @This();

    fn u16At(self: *const Self, off: usize) EvflError!u16 {
        return bytes.u16At(self.data, off);
    }
    fn u32At(self: *const Self, off: usize) EvflError!u32 {
        return bytes.u32At(self.data, off);
    }
    fn ptr(self: *const Self, off: usize) EvflError!usize {
        const v = try bytes.u64At(self.data, off);
        if (v > self.data.len) return error.InvalidData;
        return @intCast(v);
    }

    /// The pascal string at `off` (a u16 length, then the bytes).
    fn string(self: *const Self, off: usize) EvflError![]const u8 {
        if (off == 0 or off >= self.data.len) return error.InvalidData;
        const n = try self.u16At(off);
        return bytes.sliceAt(self.data, off + 2, off + 2 + n);
    }

    /// The names of a dictionary ("DIC "), in entry order.
    fn dictionary(self: *const Self, off: usize) EvflError![][]const u8 {
        const head = try bytes.sliceAt(self.data, off, off + 4);
        if (!std.mem.eql(u8, head, "DIC ")) return error.InvalidData;
        const n = try self.u32At(off + 4);
        const out = self.allocator.alloc([]const u8, n) catch return error.OutOfMemory;
        for (out, 0..) |*name, i| name.* = try self.string(try self.ptr(off + 0x18 + 0x10 * i + 8));
        return out;
    }

    fn container(self: *const Self, off: usize) EvflError!?*Container {
        if (off == 0) return null;
        const v = try self.item(off);
        return switch (v) {
            .container => |c| c,
            else => error.InvalidData,
        };
    }

    fn item(self: *const Self, off: usize) EvflError!Param {
        const t = try bytes.u8At(self.data, off);
        const n = try self.u16At(off + 2);
        const p = off + 0x10;
        switch (t) {
            T_CONTAINER => {
                const names = try self.dictionary(try self.ptr(off + 8));
                if (names.len != n) return error.InvalidData;
                const c = try Container.create(self.allocator);
                c.items.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
                for (names, 0..) |name, i| {
                    c.items.appendAssumeCapacity(Item{ .name = name, .value = try self.item(try self.ptr(p + 8 * i)) });
                }
                return Param{ .container = c };
            },
            T_ARGUMENT => return Param{ .argument = try self.string(try self.ptr(p)) },
            T_STRING => return Param{ .string = try self.string(try self.ptr(p)) },
            T_INT => return Param{ .int = try bytes.i32At(self.data, p) },
            T_BOOL => {
                const raw = try self.u32At(p);
                if (raw != 0 and raw != bool_true) return error.InvalidData;
                return Param{ .bool = raw == bool_true };
            },
            T_FLOAT => return Param{ .float = try bytes.f32At(self.data, p) },
            T_FLOAT_ARRAY => {
                const values = self.allocator.alloc(f32, n) catch return error.OutOfMemory;
                for (values, 0..) |*v, i| v.* = try bytes.f32At(self.data, p + 4 * i);
                return Param{ .float_array = values };
            },
            T_ACTOR_IDENTIFIER => return Param{ .actor_identifier = .{
                .name = try self.string(try self.ptr(p)),
                .secondary_name = try self.string(try self.ptr(p + 8)),
            } },
            else => return error.InvalidData,
        }
    }

    fn nameList(self: *const Self, off: usize, n: usize) EvflError!std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        out.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
        var j: usize = 0;
        while (j < n) : (j += 1) out.appendAssumeCapacity(try self.string(try self.ptr(off + 8 * j)));
        return out;
    }

    fn actors(self: *const Self, off: usize, n: usize) EvflError!std.ArrayList(Actor) {
        var out: std.ArrayList(Actor) = .empty;
        out.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = off + 0x38 * i;
            out.appendAssumeCapacity(Actor{
                .name = try self.string(try self.ptr(a)),
                .secondary_name = try self.string(try self.ptr(a + 8)),
                .argument_name = try self.string(try self.ptr(a + 0x10)),
                .actions = try self.nameList(try self.ptr(a + 0x18), try self.u16At(a + 0x30)),
                .queries = try self.nameList(try self.ptr(a + 0x20), try self.u16At(a + 0x32)),
                .params = try self.container(try self.ptr(a + 0x28)),
                .entry_point = try self.u16At(a + 0x34),
                .cut_number = try bytes.u8At(self.data, a + 0x36),
            });
        }
        return out;
    }

    fn cases(self: *const Self, off: usize, n: usize) EvflError!std.ArrayList(Case) {
        var out: std.ArrayList(Case) = .empty;
        out.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out.appendAssumeCapacity(Case{ .value = try self.u32At(off + 8 * i), .event = try self.u16At(off + 8 * i + 4) });
        }
        return out;
    }

    fn event(self: *const Self, off: usize) EvflError!Event {
        const name = try self.string(try self.ptr(off));
        const t = try bytes.u8At(self.data, off + 8);
        const a = try self.u16At(off + 0xA);
        const b = try self.u16At(off + 0xC);
        const c = try self.u16At(off + 0xE);
        const p10 = try self.ptr(off + 0x10);
        const p18 = try self.ptr(off + 0x18);
        const p20 = try self.ptr(off + 0x20);
        const p28 = try self.ptr(off + 0x28);
        const kind: EventKind = switch (t) {
            E_ACTION => .{ .action = .{ .actor = b, .action = c, .next = a, .params = try self.container(p10) } },
            E_SWITCH => .{ .switch_ = .{ .actor = b, .query = c, .cases = try self.cases(p18, a), .params = try self.container(p10) } },
            E_FORK => blk: {
                var forks: std.ArrayList(u16) = .empty;
                forks.ensureTotalCapacity(self.allocator, a) catch return error.OutOfMemory;
                var i: usize = 0;
                while (i < a) : (i += 1) forks.appendAssumeCapacity(try self.u16At(p10 + 2 * i));
                break :blk .{ .fork = .{ .join = b, .forks = forks } };
            },
            E_JOIN => .{ .join = .{ .next = a } },
            E_SUB_FLOW => .{ .sub_flow = .{
                .flowchart = try self.string(p18),
                .entry_point = try self.string(p20),
                .next = a,
                .params = try self.container(p10),
            } },
            E_SUB_FLOW_SWITCH => .{ .sub_flow_switch = .{
                .flowchart = try self.string(p20),
                .entry_point = try self.string(p28),
                .cases = try self.cases(p18, a),
                .params = try self.container(p10),
            } },
            E_RETURN => .{ .return_ = .{ .value = @as(u32, b) | (@as(u32, c) << 16) } },
            else => return error.InvalidData,
        };
        return Event{ .name = name, .kind = kind };
    }

    fn entryPoints(self: *const Self, dic: usize, off: usize, n: usize) EvflError!std.ArrayList(EntryPoint) {
        const names: [][]const u8 = if (n > 0) try self.dictionary(dic) else &.{};
        if (names.len != n) return error.InvalidData;
        var out: std.ArrayList(EntryPoint) = .empty;
        out.ensureTotalCapacity(self.allocator, n) catch return error.OutOfMemory;
        for (names, 0..) |name, i| {
            const e = off + 0x20 * i;
            const subs = try self.ptr(e);
            const var_dic = try self.ptr(e + 8);
            const var_off = try self.ptr(e + 0x10);
            const nsub = try self.u16At(e + 0x18);
            const nvar = try self.u16At(e + 0x1A);
            const main = try self.u16At(e + 0x1C);
            var entry = EntryPoint{ .name = name, .main_event = main };
            entry.sub_flow_events.ensureTotalCapacity(self.allocator, nsub) catch return error.OutOfMemory;
            var j: usize = 0;
            while (j < nsub) : (j += 1) entry.sub_flow_events.appendAssumeCapacity(try self.u16At(subs + 2 * j));
            if (nvar > 0) {
                const var_names = try self.dictionary(var_dic);
                for (var_names, 0..) |var_name, k| {
                    const v = var_off + 0x10 * k;
                    const raw = try bytes.u64At(self.data, v);
                    const count = try self.u16At(v + 8);
                    const vt = try self.u16At(v + 10);
                    if (count != 1) return error.InvalidData;
                    const value: VariableValue = switch (vt) {
                        T_INT => .{ .int = @bitCast(raw) },
                        T_BOOL => .{ .bool = raw != 0 },
                        T_FLOAT => .{ .float = @bitCast(@as(u32, @truncate(raw))) },
                        else => return error.InvalidData,
                    };
                    entry.variables.append(self.allocator, Variable{ .name = var_name, .value = value }) catch return error.OutOfMemory;
                }
            }
            out.appendAssumeCapacity(entry);
        }
        return out;
    }

    fn flowchart(self: *const Self, off: usize) EvflError!*Flowchart {
        const head = try bytes.sliceAt(self.data, off, off + 4);
        if (!std.mem.eql(u8, head, "EVFL")) return error.InvalidData;
        const na = try self.u16At(off + 0x10);
        const ne = try self.u16At(off + 0x16);
        const nep = try self.u16At(off + 0x18);
        const fc = self.allocator.create(Flowchart) catch return error.OutOfMemory;
        fc.* = Flowchart{
            .name = try self.string(try self.ptr(off + 0x20)),
            .actors = try self.actors(try self.ptr(off + 0x28), na),
        };
        const events_at = try self.ptr(off + 0x30);
        fc.events.ensureTotalCapacity(self.allocator, ne) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < ne) : (i += 1) fc.events.appendAssumeCapacity(try self.event(events_at + 0x30 * i));
        fc.entry_points = try self.entryPoints(try self.ptr(off + 0x38), try self.ptr(off + 0x40), nep);
        return fc;
    }

    fn timeline(self: *const Self, off: usize) EvflError!*Timeline {
        const head = try bytes.sliceAt(self.data, off, off + 4);
        if (!std.mem.eql(u8, head, "TLIN")) return error.InvalidData;
        const na = try self.u16At(off + 0x14);
        const nclip = try self.u16At(off + 0x18);
        const nshot = try self.u16At(off + 0x1A);
        const nsub = try self.u16At(off + 0x1C);
        const ncut = try self.u16At(off + 0x1E);
        if (nshot != 0) return error.InvalidData; // the game's timelines have no oneshots
        const tl = self.allocator.create(Timeline) catch return error.OutOfMemory;
        tl.* = Timeline{
            .name = try self.string(try self.ptr(off + 0x20)),
            .duration = try bytes.f32At(self.data, off + 0x10),
            .actors = try self.actors(try self.ptr(off + 0x28), na),
        };
        const clips = try self.ptr(off + 0x30);
        var i: usize = 0;
        while (i < nclip) : (i += 1) {
            const c = clips + 0x18 * i;
            tl.clips.append(self.allocator, Clip{
                .start = try bytes.f32At(self.data, c),
                .duration = try bytes.f32At(self.data, c + 4),
                .actor = try self.u16At(c + 8),
                .action = try self.u16At(c + 0xA),
                .unknown = try bytes.u8At(self.data, c + 0xC),
                .params = try self.container(try self.ptr(c + 0x10)),
            }) catch return error.OutOfMemory;
        }
        const triggers = try self.ptr(off + 0x40);
        i = 0;
        while (i < 2 * @as(usize, nclip)) : (i += 1) {
            tl.triggers.append(self.allocator, Trigger{
                .clip = try self.u16At(triggers + 4 * i),
                .type = try bytes.u8At(self.data, triggers + 4 * i + 2),
            }) catch return error.OutOfMemory;
        }
        tl.subtimelines = try self.nameList(try self.ptr(off + 0x48), nsub);
        const cuts = try self.ptr(off + 0x50);
        i = 0;
        while (i < ncut) : (i += 1) {
            const c = cuts + 0x18 * i;
            tl.cuts.append(self.allocator, Cut{
                .start = try bytes.f32At(self.data, c),
                .unknown = try self.u32At(c + 4),
                .name = try self.string(try self.ptr(c + 8)),
                .params = try self.container(try self.ptr(c + 0x10)),
            }) catch return error.OutOfMemory;
        }
        tl.params = try self.container(try self.ptr(off + 0x58));
        return tl;
    }
};

/// Parses a decompressed .bfevfl. Strings point into `data`, which must outlive the document.
pub fn read(allocator: Allocator, data: []const u8) EvflError!Document {
    if (data.len < 0x48) return error.InvalidData;
    if (!std.mem.eql(u8, data[0..8], magic)) return error.InvalidData;
    if (!std.mem.eql(u8, data[8..12], &version)) return error.InvalidData;
    const bom = try bytes.u16At(data, 0xC);
    if (bom != 0xFEFF or data[0xE] != alignment_shift) return error.InvalidData;
    const size = try bytes.u32At(data, 0x1C);
    if (size != data.len) return error.InvalidData;
    const nfc = try bytes.u16At(data, 0x20);
    const ntl = try bytes.u16At(data, 0x22);
    if (nfc + ntl != 1) return error.InvalidData;

    const r = Reader{ .data = data, .allocator = allocator };
    const name_at = try r.u32At(0x10);
    if (name_at < 2) return error.InvalidData;
    var doc = Document{ .name = try r.string(name_at - 2) };
    if (nfc != 0) {
        doc.flowchart = try r.flowchart(try r.ptr(try r.ptr(0x28)));
    } else {
        doc.timeline = try r.timeline(try r.ptr(try r.ptr(0x38)));
    }
    return doc;
}

// ------------------------------------------------------------------------------------------------------- writing

/// Bit `i` of a name as the dictionaries count them: from the lowest bit of the last byte.
fn bitOf(key: []const u8, i: usize) u1 {
    const k = i >> 3;
    if (k >= key.len) return 0;
    return @truncate(key[key.len - 1 - k] >> @intCast(i & 7));
}

pub const DictionaryEntry = struct {
    bit: u32,
    left: u16,
    right: u16,
};

/// The radix-tree entries (bit index, child for 0, child for 1) of a dictionary of `names`, root first.
/// Each name is inserted in order as in a PATRICIA tree: it hangs below the last node that tests a lower bit than
/// the first bit in which it differs from the name its search ends at. The root tests no bit (0xFFFFFFFF).
pub fn dictionaryEntries(allocator: Allocator, names: []const []const u8) EvflError![]DictionaryEntry {
    const n = names.len + 1;
    const keys = allocator.alloc([]const u8, n) catch return error.OutOfMemory;
    defer allocator.free(keys);
    const bits = allocator.alloc(i64, n) catch return error.OutOfMemory;
    defer allocator.free(bits);
    const children = allocator.alloc([2]u16, n) catch return error.OutOfMemory;
    defer allocator.free(children);
    keys[0] = "";
    bits[0] = -1;
    children[0] = .{ 0, 0 };

    for (names, 1..) |key, index| {
        var prev: usize = 0;
        var cur: usize = children[0][0];
        while (bits[prev] < bits[cur]) {
            prev = cur;
            cur = children[cur][bitOf(key, @intCast(bits[cur]))];
        }
        const other = keys[cur];
        const limit = 8 * @max(key.len, other.len);
        var differ: ?usize = null;
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (bitOf(key, i) != bitOf(other, i)) {
                differ = i;
                break;
            }
        }
        const d = differ orelse return error.InvalidData; // the same name twice
        prev = 0;
        cur = children[0][0];
        while (bits[prev] < bits[cur] and bits[cur] < @as(i64, @intCast(d))) {
            prev = cur;
            cur = children[cur][bitOf(key, @intCast(bits[cur]))];
        }
        const side = bitOf(key, d);
        keys[index] = key;
        bits[index] = @intCast(d);
        children[index] = if (side == 1) .{ @intCast(cur), @intCast(index) } else .{ @intCast(index), @intCast(cur) };
        const slot: usize = if (prev != 0) bitOf(key, @intCast(bits[prev])) else 0;
        children[prev][slot] = @intCast(index);
    }

    const out = allocator.alloc(DictionaryEntry, n) catch return error.OutOfMemory;
    for (out, 0..) |*e, i| {
        e.* = DictionaryEntry{
            .bit = @truncate(@as(u64, @bitCast(bits[i]))),
            .left = children[i][0],
            .right = children[i][1],
        };
    }
    return out;
}

/// The string pool's sort key: the bits of `s` read from the lowest bit of its last byte.
fn bitKey(allocator: Allocator, s: []const u8) EvflError![]u8 {
    const out = allocator.alloc(u8, s.len) catch return error.OutOfMemory;
    for (s, 0..) |byte, i| out[s.len - 1 - i] = @bitReverse(byte);
    return out;
}

const PoolString = struct {
    text: []const u8,
    key: []const u8,
};

fn lessPool(_: void, a: PoolString, b: PoolString) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

const Writer = struct {
    allocator: Allocator,
    buf: bytes.Buffer,
    relocations: std.ArrayList(usize),
    /// string -> the pointer fields that point at it (filled in when the pool is written)
    string_fields: std.array_hash_map.String(std.ArrayList(usize)),

    const Self = @This();

    fn pos(self: *const Self) usize {
        return self.buf.len();
    }

    fn alignTo(self: *Self, a: usize) EvflError!void {
        try self.buf.alignTo(a);
    }

    fn reserve(self: *Self, size: usize) EvflError!usize {
        return self.buf.reserve(size);
    }

    fn put8(self: *Self, off: usize, v: u8) void {
        self.buf.bytes()[off] = v;
    }

    fn put16(self: *Self, off: usize, v: u16) void {
        self.buf.putU16(off, v);
    }

    fn put32(self: *Self, off: usize, v: u32) void {
        self.buf.putU32(off, v);
    }

    /// A pointer field, listed for relocation (null or not, as the game's files do for array fields).
    fn pointer(self: *Self, field: usize, target: usize) EvflError!void {
        self.buf.putU64(field, target);
        self.relocations.append(self.allocator, field) catch return error.OutOfMemory;
    }

    /// An optional object's pointer: relocated only when it is set.
    fn optional(self: *Self, field: usize, target: usize) EvflError!void {
        if (target != 0) try self.pointer(field, target);
    }

    /// A pointer to `s` in the string pool, filled in when the pool is written.
    fn string(self: *Self, field: usize, s: []const u8) EvflError!void {
        const slot = self.string_fields.getOrPut(self.allocator, s) catch return error.OutOfMemory;
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        slot.value_ptr.append(self.allocator, field) catch return error.OutOfMemory;
        self.relocations.append(self.allocator, field) catch return error.OutOfMemory;
    }

    fn inlineString(self: *Self, s: []const u8) EvflError!usize {
        if (s.len > 0xFFFF) return error.InvalidData;
        const off = self.pos();
        try self.buf.appendU16(@intCast(s.len));
        try self.buf.append(s);
        try self.buf.appendByte(0);
        return off;
    }

    fn itemHeader(self: *Self, off: usize, t: u8, n: u16) void {
        self.put8(off, t);
        self.put8(off + 1, 0);
        self.put16(off + 2, n);
        self.put32(off + 4, 0);
    }

    fn dictionary(self: *Self, names: []const []const u8) EvflError!usize {
        try self.alignTo(8);
        const off = try self.reserve(0x18 + 0x10 * names.len);
        @memcpy(self.buf.bytes()[off..][0..4], "DIC ");
        self.put32(off + 4, @intCast(names.len));
        const entries = try dictionaryEntries(self.allocator, names);
        defer self.allocator.free(entries);
        for (entries, 0..) |e, i| {
            const at = off + 8 + 0x10 * i;
            self.put32(at, e.bit);
            self.put16(at + 4, e.left);
            self.put16(at + 6, e.right);
            try self.string(at + 8, if (i == 0) "" else names[i - 1]);
        }
        return off;
    }

    fn item(self: *Self, value: Param) EvflError!usize {
        try self.alignTo(8);
        const off = self.pos();
        switch (value) {
            .container => |c| {
                _ = try self.reserve(0x10 + 8 * c.items.items.len);
                self.itemHeader(off, T_CONTAINER, @intCast(c.items.items.len));
                const names = self.allocator.alloc([]const u8, c.items.items.len) catch return error.OutOfMemory;
                defer self.allocator.free(names);
                for (c.items.items, 0..) |it, i| names[i] = it.name;
                try self.pointer(off + 8, try self.dictionary(names));
                for (c.items.items, 0..) |it, i| try self.pointer(off + 0x10 + 8 * i, try self.item(it.value));
            },
            .argument, .string => |s| {
                _ = try self.reserve(0x18);
                self.itemHeader(off, if (value == .argument) T_ARGUMENT else T_STRING, 1);
                try self.pointer(off + 0x10, try self.inlineString(s));
            },
            .actor_identifier => |id| {
                _ = try self.reserve(0x20);
                self.itemHeader(off, T_ACTOR_IDENTIFIER, 2);
                try self.pointer(off + 0x10, try self.inlineString(id.name));
                try self.alignTo(2);
                try self.pointer(off + 0x18, try self.inlineString(id.secondary_name));
            },
            .float_array => |values| {
                _ = try self.reserve(0x10);
                self.itemHeader(off, T_FLOAT_ARRAY, @intCast(values.len));
                for (values) |v| try self.buf.appendU32(@bitCast(v));
            },
            .bool => |v| {
                _ = try self.reserve(0x18);
                self.itemHeader(off, T_BOOL, 1);
                self.put32(off + 0x10, if (v) bool_true else 0);
            },
            .int => |v| {
                _ = try self.reserve(0x18);
                self.itemHeader(off, T_INT, 1);
                self.put32(off + 0x10, @bitCast(v));
            },
            .float => |v| {
                _ = try self.reserve(0x18);
                self.itemHeader(off, T_FLOAT, 1);
                self.put32(off + 0x10, @bitCast(v));
            },
        }
        try self.alignTo(8);
        return off;
    }

    fn container(self: *Self, field: usize, params: ?*Container) EvflError!void {
        if (params) |p| try self.pointer(field, try self.item(Param{ .container = p }));
    }

    fn u16Array(self: *Self, field: usize, values: []const u16) EvflError!void {
        try self.alignTo(8);
        const off = if (values.len > 0) self.pos() else 0;
        for (values) |v| try self.buf.appendU16(v);
        try self.pointer(field, off);
    }

    fn caseArray(self: *Self, field: usize, cases: []const Case) EvflError!void {
        try self.alignTo(8);
        const off = if (cases.len > 0) self.pos() else 0;
        for (cases) |c| {
            try self.buf.appendU32(c.value);
            try self.buf.appendU16(c.event);
            try self.buf.appendU16(0);
        }
        try self.pointer(field, off);
    }

    fn stringArray(self: *Self, field: usize, strings: []const []const u8) EvflError!void {
        try self.alignTo(8);
        const off = if (strings.len > 0) try self.reserve(8 * strings.len) else 0;
        for (strings, 0..) |s, i| try self.string(off + 8 * i, s);
        try self.pointer(field, off);
    }

    fn actorHeaders(self: *Self, count: usize) EvflError!usize {
        return if (count > 0) try self.reserve(0x38 * count) else 0;
    }

    fn actorFields(self: *Self, a: usize, actor: *const Actor) EvflError!void {
        self.put16(a + 0x30, @intCast(actor.actions.items.len));
        self.put16(a + 0x32, @intCast(actor.queries.items.len));
        self.put16(a + 0x34, actor.entry_point);
        self.put8(a + 0x36, actor.cut_number);
        self.put8(a + 0x37, 0);
        try self.string(a, actor.name);
        try self.string(a + 8, actor.secondary_name);
        try self.string(a + 0x10, actor.argument_name);
    }

    /// Each actor's fields, then its parameters and action and query name arrays.
    fn actorData(self: *Self, off: usize, actors: []const Actor) EvflError!void {
        for (actors, 0..) |*actor, i| {
            const a = off + 0x38 * i;
            try self.actorFields(a, actor);
            try self.container(a + 0x28, actor.params);
            try self.stringArray(a + 0x18, actor.actions.items);
            try self.stringArray(a + 0x20, actor.queries.items);
        }
    }

    fn eventHeader(self: *Self, off: usize, t: u8, a: u16, b: u16, c: u16) void {
        self.put8(off + 8, t);
        self.put8(off + 9, 0);
        self.put16(off + 0xA, a);
        self.put16(off + 0xC, b);
        self.put16(off + 0xE, c);
    }

    fn event(self: *Self, off: usize, e: *const Event) EvflError!void {
        try self.string(off, e.name);
        switch (e.kind) {
            .action => |a| {
                self.eventHeader(off, E_ACTION, a.next, a.actor, a.action);
                try self.container(off + 0x10, a.params);
            },
            .switch_ => |s| {
                self.eventHeader(off, E_SWITCH, @intCast(s.cases.items.len), s.actor, s.query);
                try self.caseArray(off + 0x18, s.cases.items);
                try self.container(off + 0x10, s.params);
            },
            .fork => |f| {
                self.eventHeader(off, E_FORK, @intCast(f.forks.items.len), f.join, 0);
                try self.u16Array(off + 0x10, f.forks.items);
            },
            .join => |j| self.eventHeader(off, E_JOIN, j.next, 0, 0),
            .sub_flow => |s| {
                self.eventHeader(off, E_SUB_FLOW, s.next, 0, 0);
                try self.container(off + 0x10, s.params);
                try self.string(off + 0x18, s.flowchart);
                try self.string(off + 0x20, s.entry_point);
            },
            .sub_flow_switch => |s| {
                self.eventHeader(off, E_SUB_FLOW_SWITCH, @intCast(s.cases.items.len), 0, 0);
                try self.caseArray(off + 0x18, s.cases.items);
                try self.container(off + 0x10, s.params);
                try self.string(off + 0x20, s.flowchart);
                try self.string(off + 0x28, s.entry_point);
            },
            .return_ => |r| {
                self.put8(off + 8, E_RETURN);
                self.put8(off + 9, 0);
                self.put16(off + 0xA, 0);
                self.put32(off + 0xC, r.value);
            },
        }
    }

    /// The sub-flow event indices, then the variables' dictionary (zeros when there are none) and values.
    fn entryPointData(self: *Self, off: usize, entry: *const EntryPoint) EvflError!void {
        try self.u16Array(off, entry.sub_flow_events.items);
        try self.alignTo(8);
        if (entry.variables.items.len > 0) {
            const names = self.allocator.alloc([]const u8, entry.variables.items.len) catch return error.OutOfMemory;
            defer self.allocator.free(names);
            for (entry.variables.items, 0..) |v, i| names[i] = v.name;
            try self.pointer(off + 8, try self.dictionary(names));
            const values = try self.reserve(0x10 * entry.variables.items.len);
            for (entry.variables.items, 0..) |v, i| {
                const at = values + 0x10 * i;
                const raw: u64, const t: u16 = switch (v.value) {
                    .int => |x| .{ @bitCast(x), T_INT },
                    .bool => |x| .{ @intFromBool(x), T_BOOL },
                    .float => |x| .{ @as(u32, @bitCast(x)), T_FLOAT },
                };
                self.buf.putU64(at, raw);
                self.put16(at + 8, 1);
                self.put16(at + 10, t);
                self.put32(at + 12, 0);
            }
            try self.pointer(off + 0x10, values);
        } else {
            _ = try self.reserve(0x18);
            try self.pointer(off + 0x10, 0);
        }
    }

    fn actionCounts(actors: []const Actor) [2]u16 {
        var actions: usize = 0;
        var queries: usize = 0;
        for (actors) |a| {
            actions += a.actions.items.len;
            queries += a.queries.items.len;
        }
        return .{ @intCast(actions), @intCast(queries) };
    }

    fn flowchart(self: *Self, fc: *const Flowchart) EvflError!usize {
        const off = try self.reserve(0x48);
        @memcpy(self.buf.bytes()[off..][0..4], "EVFL");
        const counts = actionCounts(fc.actors.items);
        self.put16(off + 0x10, @intCast(fc.actors.items.len));
        self.put16(off + 0x12, counts[0]);
        self.put16(off + 0x14, counts[1]);
        self.put16(off + 0x16, @intCast(fc.events.items.len));
        self.put16(off + 0x18, @intCast(fc.entry_points.items.len));
        try self.string(off + 0x20, fc.name);
        const actors = try self.actorHeaders(fc.actors.items.len);
        try self.pointer(off + 0x28, actors);
        const events = if (fc.events.items.len > 0) try self.reserve(0x30 * fc.events.items.len) else 0;
        try self.pointer(off + 0x30, events);
        const ep_names = self.allocator.alloc([]const u8, fc.entry_points.items.len) catch return error.OutOfMemory;
        defer self.allocator.free(ep_names);
        for (fc.entry_points.items, 0..) |e, i| ep_names[i] = e.name;
        try self.pointer(off + 0x38, try self.dictionary(ep_names));
        const entries = if (fc.entry_points.items.len > 0) try self.reserve(0x20 * fc.entry_points.items.len) else 0;
        try self.pointer(off + 0x40, entries);
        for (fc.entry_points.items, 0..) |e, i| {
            const at = entries + 0x20 * i + 0x18;
            self.put16(at, @intCast(e.sub_flow_events.items.len));
            self.put16(at + 2, @intCast(e.variables.items.len));
            self.put16(at + 4, e.main_event);
            self.put16(at + 6, 0);
        }
        for (fc.events.items, 0..) |*e, i| try self.event(events + 0x30 * i, e);
        try self.actorData(actors, fc.actors.items);
        for (fc.entry_points.items, 0..) |*e, i| try self.entryPointData(entries + 0x20 * i, e);
        return off;
    }

    /// The actors' parameters and name arrays come first, then the timeline and its arrays.
    fn timeline(self: *Self, tl: *const Timeline) EvflError!usize {
        const ActorPlace = struct { params: usize, actions: usize, action_fields: usize, queries: usize, query_fields: usize };
        const places = self.allocator.alloc(ActorPlace, tl.actors.items.len) catch return error.OutOfMemory;
        defer self.allocator.free(places);
        for (tl.actors.items, 0..) |actor, i| {
            try self.alignTo(8);
            const params = if (actor.params) |p| try self.item(Param{ .container = p }) else 0;
            try self.alignTo(8);
            const actions = if (actor.actions.items.len > 0) self.pos() else 0;
            const action_fields = try self.reserve(8 * actor.actions.items.len);
            try self.alignTo(8);
            const queries = if (actor.queries.items.len > 0) self.pos() else 0;
            const query_fields = try self.reserve(8 * actor.queries.items.len);
            places[i] = ActorPlace{ .params = params, .actions = actions, .action_fields = action_fields, .queries = queries, .query_fields = query_fields };
        }
        try self.alignTo(8);
        const off = try self.reserve(0x60);
        @memcpy(self.buf.bytes()[off..][0..4], "TLIN");
        self.put32(off + 0x10, @bitCast(tl.duration));
        self.put16(off + 0x14, @intCast(tl.actors.items.len));
        self.put16(off + 0x16, actionCounts(tl.actors.items)[0]);
        self.put16(off + 0x18, @intCast(tl.clips.items.len));
        self.put16(off + 0x1A, 0);
        self.put16(off + 0x1C, @intCast(tl.subtimelines.items.len));
        self.put16(off + 0x1E, @intCast(tl.cuts.items.len));
        try self.string(off + 0x20, tl.name);
        const actors = try self.actorHeaders(tl.actors.items.len);
        try self.pointer(off + 0x28, actors);
        for (tl.actors.items, 0..) |*actor, i| {
            const a = actors + 0x38 * i;
            const place = places[i];
            try self.actorFields(a, actor);
            for (actor.actions.items, 0..) |name, j| try self.string(place.action_fields + 8 * j, name);
            for (actor.queries.items, 0..) |name, j| try self.string(place.query_fields + 8 * j, name);
            try self.pointer(a + 0x18, place.actions);
            try self.pointer(a + 0x20, place.queries);
            try self.optional(a + 0x28, place.params);
        }
        const clips = if (tl.clips.items.len > 0) try self.reserve(0x18 * tl.clips.items.len) else 0;
        try self.pointer(off + 0x30, clips);
        try self.pointer(off + 0x38, 0); // oneshots: none in the game's timelines
        try self.stringArray(off + 0x48, tl.subtimelines.items);
        if (tl.triggers.items.len != 2 * tl.clips.items.len) return error.InvalidData;
        try self.alignTo(8);
        const triggers = if (tl.triggers.items.len > 0) self.pos() else 0;
        for (tl.triggers.items) |trig| {
            try self.buf.appendU16(trig.clip);
            try self.buf.appendByte(trig.type);
            try self.buf.appendByte(0);
        }
        try self.pointer(off + 0x40, triggers);
        try self.alignTo(8);
        const cuts = if (tl.cuts.items.len > 0) try self.reserve(0x18 * tl.cuts.items.len) else 0;
        try self.pointer(off + 0x50, cuts);
        for (tl.clips.items, 0..) |clip, i| {
            const c = clips + 0x18 * i;
            self.put32(c, @bitCast(clip.start));
            self.put32(c + 4, @bitCast(clip.duration));
            self.put16(c + 8, clip.actor);
            self.put16(c + 0xA, clip.action);
            self.put8(c + 0xC, clip.unknown);
            try self.container(c + 0x10, clip.params);
        }
        for (tl.cuts.items, 0..) |cut, i| {
            const c = cuts + 0x18 * i;
            self.put32(c, @bitCast(cut.start));
            self.put32(c + 4, cut.unknown);
            try self.string(c + 8, cut.name);
            try self.container(c + 0x10, cut.params);
        }
        try self.container(off + 0x58, tl.params);
        return off;
    }

    /// Writes the pool and fills in every string pointer. Returns (pool offset, offset of each string).
    fn stringPool(self: *Self) EvflError!struct { offset: usize, where: std.StringHashMap(usize) } {
        try self.alignTo(8);
        const off = try self.reserve(0x14);
        var sorted: std.ArrayList(PoolString) = .empty;
        defer sorted.deinit(self.allocator);
        for (self.string_fields.keys()) |s| {
            if (s.len == 0) continue;
            sorted.append(self.allocator, PoolString{ .text = s, .key = try bitKey(self.allocator, s) }) catch return error.OutOfMemory;
        }
        std.mem.sort(PoolString, sorted.items, {}, lessPool);
        @memcpy(self.buf.bytes()[off..][0..4], "STR ");
        self.put32(off + 0x10, @intCast(sorted.items.len));

        var where = std.StringHashMap(usize).init(self.allocator);
        where.put("", try self.inlineString("")) catch return error.OutOfMemory;
        try self.alignTo(2);
        for (sorted.items) |p| {
            where.put(p.text, try self.inlineString(p.text)) catch return error.OutOfMemory;
            try self.alignTo(2);
        }
        var it = self.string_fields.iterator();
        while (it.next()) |entry| {
            const at = where.get(entry.key_ptr.*).?;
            for (entry.value_ptr.items) |field| self.buf.putU64(field, at);
        }
        return .{ .offset = off, .where = where };
    }

    fn relocationTable(self: *Self, data_end: usize) EvflError!usize {
        try self.alignTo(8);
        const off = self.pos();
        const sorted = self.allocator.dupe(usize, self.relocations.items) catch return error.OutOfMemory;
        defer self.allocator.free(sorted);
        std.mem.sort(usize, sorted, {}, std.sort.asc(usize));
        // unique
        var unique: std.ArrayList(usize) = .empty;
        defer unique.deinit(self.allocator);
        for (sorted) |v| {
            if (unique.items.len == 0 or unique.items[unique.items.len - 1] != v) unique.append(self.allocator, v) catch return error.OutOfMemory;
        }
        const Rel = struct { base: u32, mask: u32 };
        var entries: std.ArrayList(Rel) = .empty;
        defer entries.deinit(self.allocator);
        var i: usize = 0;
        while (i < unique.items.len) {
            const base = unique.items[i];
            var mask: u32 = 0;
            while (i < unique.items.len and unique.items[i] < base + 8 * 32) : (i += 1) {
                mask |= @as(u32, 1) << @intCast((unique.items[i] - base) / 8);
            }
            entries.append(self.allocator, Rel{ .base = @intCast(base), .mask = mask }) catch return error.OutOfMemory;
        }
        try self.buf.append("RELT");
        try self.buf.appendU32(@intCast(off));
        try self.buf.appendU32(1);
        try self.buf.appendU32(0);
        try self.buf.appendU64(0);
        try self.buf.appendU32(0);
        try self.buf.appendU32(@intCast(data_end));
        try self.buf.appendU32(0);
        try self.buf.appendU32(@intCast(entries.items.len));
        for (entries.items) |e| {
            try self.buf.appendU32(e.base);
            try self.buf.appendU32(e.mask);
        }
        return off;
    }
};

/// The decompressed .bfevfl bytes of `doc`, laid out as the game's files are. Allocated with `allocator`.
pub fn write(allocator: Allocator, doc: *const Document) EvflError![]u8 {
    if ((doc.flowchart == null) == (doc.timeline == null)) return error.InvalidData;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w = Writer{
        .allocator = arena,
        .buf = bytes.Buffer.init(allocator),
        .relocations = .empty,
        .string_fields = .empty,
    };
    errdefer w.buf.deinit();

    _ = try w.reserve(0x48);
    @memcpy(w.buf.bytes()[0..8], magic);
    @memcpy(w.buf.bytes()[8..12], &version);
    w.put16(0xC, 0xFEFF);
    w.put8(0xE, alignment_shift);
    w.put8(0xF, 0);
    w.put16(0x20, @intFromBool(doc.flowchart != null));
    w.put16(0x22, @intFromBool(doc.timeline != null));

    var block: usize = 0;
    if (doc.flowchart) |fc| {
        const flowcharts = try w.reserve(8);
        try w.pointer(0x28, flowcharts);
        try w.pointer(0x30, try w.dictionary(&.{fc.name}));
        try w.pointer(0x38, 0);
        try w.pointer(0x40, try w.dictionary(&.{}));
        block = try w.flowchart(fc);
        try w.pointer(flowcharts, block);
    } else if (doc.timeline) |tl| {
        try w.pointer(0x28, 0);
        try w.pointer(0x30, try w.dictionary(&.{}));
        const timelines = try w.reserve(8);
        try w.pointer(0x38, timelines);
        try w.pointer(0x40, try w.dictionary(&.{tl.name}));
        block = try w.timeline(tl);
        try w.pointer(timelines, block);
    }
    // the header points at the file name's characters (below), unrelocated
    const slot = w.string_fields.getOrPut(arena, doc.name) catch return error.OutOfMemory;
    if (!slot.found_existing) slot.value_ptr.* = .empty;

    const pool = try w.stringPool();
    const data_end = w.pos();
    w.put32(block + 4, @intCast(pool.offset - block));
    const relocation = try w.relocationTable(data_end);
    if (block > 0xFFFF) return error.InvalidData;
    w.put32(0x10, @intCast(pool.where.get(doc.name).? + 2));
    w.put16(0x14, 0);
    w.put16(0x16, @intCast(block));
    w.put32(0x18, @intCast(relocation));
    w.put32(0x1C, @intCast(w.pos()));
    return w.buf.toOwnedSlice();
}

/// Writes `doc` and checks that the result reads back and writes the same bytes again (the Python version compared
/// the read-back document with the changed one; a stable round trip checks the same thing). Allocated with
/// `allocator`; on a mismatch returns error.InvalidData.
pub fn writeChecked(allocator: Allocator, doc: *const Document) EvflError![]u8 {
    const out = try write(allocator, doc);
    errdefer allocator.free(out);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const back = try read(arena_state.allocator(), out);
    const again = try write(arena_state.allocator(), &back);
    if (!std.mem.eql(u8, out, again)) return error.InvalidData;
    return out;
}

// --------------------------------------------------------------------------------------------- building helpers

/// A new action event.
pub fn makeAction(name: []const u8, actor_action: [2]u16, next: u16, params: ?*Container) Event {
    return Event{ .name = name, .kind = .{ .action = .{ .actor = actor_action[0], .action = actor_action[1], .next = next, .params = params } } };
}

/// A new sub-flow call.
pub fn makeSubFlow(name: []const u8, flowchart_name: []const u8, entry_point: []const u8, next: u16, params: ?*Container) Event {
    return Event{ .name = name, .kind = .{ .sub_flow = .{ .flowchart = flowchart_name, .entry_point = entry_point, .next = next, .params = params } } };
}

test "dictionary of one name" {
    const entries = try dictionaryEntries(std.testing.allocator, &.{"Event"});
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), entries[0].bit);
}
