//! Helpers shared by the event-flow patches (faststart, qol, storyskip, hints, ...).

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const Progress = @import("../core/Progress.zig");
const PatchError = @import("patchset.zig").PatchError;
const Allocator = std.mem.Allocator;

pub fn contains(list: []const []const u8, s: []const u8) bool {
    return indexOf(list, s) != null;
}

pub fn indexOf(list: []const []const u8, s: []const u8) ?usize {
    for (list, 0..) |x, i| if (std.mem.eql(u8, x, s)) return i;
    return null;
}

/// The document's flowchart, which must be named `name`.
pub fn expectFlowchart(doc: *evfl.Document, name: []const u8, progress: *Progress) PatchError!*evfl.Flowchart {
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} flowchart not found", .{name});
    if (!std.mem.eql(u8, fc.name, name)) return progress.fail(error.NotAsExpected, "{s} flowchart not found", .{name});
    return fc;
}

/// True when every (name, value) of `wanted` is a parameter of `params` with a loosely equal value.
pub fn paramsMatch(params: ?*evfl.Container, wanted: []const evfl.Item) bool {
    if (wanted.len == 0) return true;
    const p = params orelse return false;
    for (wanted) |w| if (!p.is(w.name, w.value)) return false;
    return true;
}

/// The index of the one action event `actor`.`action` whose parameters include `wanted`.
pub fn findOneAction(fc: *const evfl.Flowchart, actor: []const u8, action: []const u8, wanted: []const evfl.Item, progress: *Progress) PatchError!u16 {
    var hit: ?u16 = null;
    var count: usize = 0;
    for (fc.events.items, 0..) |*e, i| {
        if (e.kind != .action or !fc.isAction(e, actor, action)) continue;
        if (!paramsMatch(e.kind.action.params, wanted)) continue;
        hit = @intCast(i);
        count += 1;
    }
    if (count != 1) return progress.fail(error.NotAsExpected, "expected one {s}.{s}, found {d}", .{ actor, action, count });
    return hit.?;
}

/// (actor, action) indices of `actor`.`action`, adding the action to the actor when it is missing; refused when the
/// flow has no such actor.
pub fn requireAction(fc: *evfl.Flowchart, allocator: Allocator, actor: []const u8, action: []const u8, progress: *Progress) PatchError![2]u16 {
    return (try fc.actionIndex(allocator, actor, action)) orelse progress.fail(error.NotAsExpected, "actor {s} not in {s}", .{ actor, fc.name });
}

/// Like requireAction, for a query.
pub fn requireQuery(fc: *evfl.Flowchart, allocator: Allocator, actor: []const u8, query: []const u8, progress: *Progress) PatchError![2]u16 {
    return (try fc.queryIndex(allocator, actor, query)) orelse progress.fail(error.NotAsExpected, "actor {s} not in {s}", .{ actor, fc.name });
}

/// An entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13). Adds each of
/// `added` to every entry point that now reaches it.
pub fn listReachedCalls(allocator: Allocator, fc: *evfl.Flowchart, added: []const u16) PatchError!void {
    for (fc.entry_points.items) |*ep| {
        const reached = try fc.reach(allocator, ep.main_event);
        for (added) |i| {
            if (i < reached.len and reached[i] and !ep.hasSubFlowEvent(i)) {
                ep.sub_flow_events.append(allocator, i) catch return error.OutOfMemory;
            }
        }
    }
}

/// Like listReachedCalls, for every sub flow call (and sub flow switch) an entry point reaches, in event order.
pub fn listAllReachedCalls(allocator: Allocator, fc: *evfl.Flowchart) PatchError!void {
    for (fc.entry_points.items) |*ep| {
        const reached = try fc.reach(allocator, ep.main_event);
        for (reached, 0..) |r, i| {
            if (!r) continue;
            const kind = fc.events.items[i].kind;
            if ((kind == .sub_flow or kind == .sub_flow_switch) and !ep.hasSubFlowEvent(@intCast(i))) {
                ep.sub_flow_events.append(allocator, @intCast(i)) catch return error.OutOfMemory;
            }
        }
    }
}

/// Writes the changed document, checking it reads back; `what` names it in the failure message.
pub fn writeBack(allocator: Allocator, doc: *const evfl.Document, what: []const u8, progress: *Progress) PatchError![]u8 {
    return evfl.writeChecked(allocator, doc) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidData => progress.fail(error.NotAsExpected, "{s}: the written flow does not read back as the changed flow", .{what}),
    };
}

/// Parses a flow, mapping a parse failure to NotAsExpected with a message.
pub fn readFlow(allocator: Allocator, data: []const u8, what: []const u8, progress: *Progress) PatchError!evfl.Document {
    return evfl.read(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidData => progress.fail(error.NotAsExpected, "{s} is not a readable event flow", .{what}),
    };
}
