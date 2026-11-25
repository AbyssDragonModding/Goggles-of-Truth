//! Character gifts and minigames show and name the item they really give.
//!
//! Models. A few gift flows show the reward with an actor of their own before handing it over (the hand-over itself
//! already gets the shuffled item through the location's event_refs): the Lost Woods target scrub's bullet bags, Darunia's
//! Goron Bracelet, Biggoron's sword and Zelda's letter. All are created by the event, so the actor's name in the flow's
//! actor table decides the model: it is renamed to the actor a chest would show for the placed item. Their
//! animations live in event files named after the original actor, so a renamed actor doesn't play them; none of those
//! calls waits for its end, so the scene goes on, with the item where it is bound. Two actors renamed to the same item
//! get different instance names (the engine tells event actors apart by name and instance name).
//!
//! Text. The lines that announce or describe a reward name it in highlight colour ("I'll give you a bigger
//! {Deku-seed bag}!"); the phrase, with its lead-in ("a bigger", "an extremely rare"), becomes "the {item}". The
//! game's two English archives have the same bytes for every one of these lines. A line that would get too long gets a
//! line break before the item. Locations that keep their vanilla item keep their text.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const sarc = @import("../formats/sarc.zig");
const msbt = @import("../formats/msbt.zig");
const bytes = @import("../core/bytes.zig");
const world_mod = @import("../game/world.zig");
const fill = @import("fill.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const progressive = @import("../logic/progressive.zig");
const progressive_flows = @import("progressive_flows.zig");
const logic = @import("../logic/logic.zig");
const Progress = @import("../core/Progress.zig");
const tables = @import("npc_tables.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const ItemId = logic.ItemId;
const Container = evfl.Container;

pub const Display = struct {
    location: []const u8,
    flow: []const u8,
    actor: []const u8,
    /// The scene shows its reward with the "important item" display (EventOpenPerformanceImportantMenu) instead of
    /// the normal item window. That display only knows the vanilla item's model (test report, DIGREWARD1: the Deku
    /// Tree handed over the Megaton Hammer but the display showed the Kokiri Emerald), so for another item it is
    /// replaced by the normal item window for the item the scene really gives.
    shows_important_item_display: bool = false,
};

pub const Line = struct {
    location: []const u8,
    /// message file (EventFlowMsg/<file>.msbt)
    file: []const u8,
    label: []const u8,
    old: []const u8,
    new: []const u8,
};

/// highlight colour on / off (as the game's own lines)
const highlight_on = "\x0e\x00\x00\x03\x00\x02\x00\x00\x00";
const highlight_off = "\x0e\x00\x00\x03\x00\x02\x00\xff\xff";
const page = "\x0e\x00\x00\x04\x00\x00\x00";
const item_marker = "\x01";
const line_width = 50;

/// Characters shown in `segment` (tags left out; UTF-8 lead bytes only).
fn visibleLen(segment: []const u8) usize {
    var n: usize = 0;
    var j: usize = 0;
    while (j < segment.len) {
        if (segment[j] == 0x0E and j + 7 <= segment.len) {
            const plen = std.mem.readInt(u16, segment[j + 5 ..][0..2], .little);
            j += 7 + plen;
            continue;
        }
        if ((segment[j] & 0xC0) != 0x80) n += 1;
        j += 1;
    }
    return n;
}

fn rfindBefore(haystack: []const u8, needle: []const u8, end: usize) ?usize {
    return std.mem.lastIndexOf(u8, haystack[0..end], needle);
}

/// If the line holding offset `at` is longer than line_width, break it at the last space before `at`.
fn wrap(allocator: Allocator, raw: []const u8, at: usize) error{OutOfMemory}![]const u8 {
    const nl = rfindBefore(raw, "\n", at);
    const pg = rfindBefore(raw, page, at);
    var start: usize = 0;
    if (nl != null or pg != null) {
        const best = @max(if (nl) |x| @as(isize, @intCast(x)) else -1, if (pg) |x| @as(isize, @intCast(x)) else -1);
        start = @intCast(best + 1);
    }
    var end: usize = raw.len - 1;
    if (std.mem.indexOfPos(u8, raw, at, "\n")) |e| end = @min(end, e);
    if (std.mem.indexOfPos(u8, raw, at, page)) |e| end = @min(end, e);
    if (visibleLen(raw[start..end]) <= line_width) return raw;
    const space = std.mem.lastIndexOfScalar(u8, raw[start..at], ' ') orelse return raw;
    const pos = start + space;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, raw[0..pos]);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, raw[pos + 1 ..]);
    return out.items;
}

/// `raw` with fragment `old` replaced by `new` (the marker byte = the highlighted item name), or null if `old` isn't
/// there exactly once.
fn newLine(allocator: Allocator, raw: []const u8, old: []const u8, new: []const u8, name: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.mem.count(u8, raw, old) != 1) return null;
    var item: std.ArrayList(u8) = .empty;
    try item.appendSlice(allocator, highlight_on);
    for (name) |c| if (c != 0) try item.append(allocator, c);
    try item.appendSlice(allocator, highlight_off);
    const replacement = try std.mem.replaceOwned(u8, allocator, new, item_marker, item.items);
    const out = try std.mem.replaceOwned(u8, allocator, raw, old, replacement);
    const at = std.mem.indexOf(u8, out, item.items) orelse return out;
    return try wrap(allocator, out, at);
}

pub const Changed = struct {
    location: []const u8,
    item: ItemId,
};

/// The gift locations whose item isn't the vanilla one: the shuffled ones in plan order, then the other placed ones
/// (forced placements, such as a test seed's --place) in location order. Without those, a test seed that forced an
/// item onto a gift kept the vanilla model and text (DIGREWARD1: the Deku Tree's scene was never changed).
pub fn changedLocations(allocator: Allocator, plan: *fill.Plan, placed: []const ?ItemId) error{OutOfMemory}![]Changed {
    var out: std.ArrayList(Changed) = .empty;
    for (plan.shuffled.items) |i| try appendIfChangedGift(allocator, &out, plan, placed, i);
    for (placed, 0..) |_, i| {
        if (plan.is_shuffled[i]) continue;
        try appendIfChangedGift(allocator, &out, plan, placed, i);
    }
    return out.items;
}

fn appendIfChangedGift(allocator: Allocator, out: *std.ArrayList(Changed), plan: *fill.Plan, placed: []const ?ItemId, i: usize) error{OutOfMemory}!void {
    const loc = plan.location(i);
    var listed = false;
    for (tables.display) |d| if (std.mem.eql(u8, d.location, loc.name)) {
        listed = true;
    };
    for (tables.lines) |l| if (std.mem.eql(u8, l.location, loc.name)) {
        listed = true;
    };
    if (!listed) return;
    const item = placed[i] orelse return;
    if (item != loc.vanilla) try out.append(allocator, .{ .location = loc.name, .item = item });
}

/// Renames the display actors of `changed` locations to their placed item's model. Returns how many.
pub fn swapModels(world: *World, patches: *patchset.PatchSet, changed: []const Changed, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    // the flows to change, in name order
    var flow_names: std.ArrayList([]const u8) = .empty;
    for (changed) |c| {
        for (tables.display) |d| {
            if (std.mem.eql(u8, d.location, c.location) and !flows.contains(flow_names.items, d.flow)) flow_names.append(a, d.flow) catch return error.OutOfMemory;
        }
    }
    std.mem.sort([]const u8, flow_names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    var done: usize = 0;
    for (flow_names.items) |flow| {
        const rel = try world.find(a, "Event/EventFlow", flow);
        const orig = try patches.read(rel);
        var doc = try flows.readFlow(a, orig.data, flow, progress);
        const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "{s} has no flowchart", .{flow});
        for (changed) |c| {
            for (tables.display) |d| {
                if (!std.mem.eql(u8, d.location, c.location) or !std.mem.eql(u8, d.flow, flow)) continue;
                const new_name = (try world.handedOutActorForId(a, c.item, .chest)) orelse return progress.fail(error.NotAsExpected, "no actor for {s}", .{world.items.name(c.item)});
                var hit: ?usize = null;
                var count: usize = 0;
                for (fc.actors.items, 0..) |actor, k| if (std.mem.eql(u8, actor.name, d.actor)) {
                    hit = k;
                    count += 1;
                };
                if (count != 1) return progress.fail(error.NotAsExpected, "{s}: expected one {s} actor, found {d}", .{ flow, d.actor, count });
                const actor = &fc.actors.items[hit.?];
                var secondary = actor.secondary_name;
                var k: usize = 2;
                while (takenBy(fc, hit.?, new_name, secondary)) : (k += 1) {
                    secondary = std.fmt.allocPrint(a, "{s}_{d}", .{ if (actor.secondary_name.len > 0) actor.secondary_name else "Rando", k }) catch return error.OutOfMemory;
                }
                actor.name = new_name;
                actor.secondary_name = secondary;
                if (d.shows_important_item_display) {
                    const given_actor = (try world.handedOutActorForId(a, c.item, .event)) orelse return progress.fail(error.NotAsExpected, "no event actor for {s}", .{world.items.name(c.item)});
                    const window = try replaceImportantItemDisplayWithItemWindow(a, fc, flow, given_actor, progress);
                    if (progressive.chainOfProgressiveItem(world.items.name(c.item))) |chain| {
                        // a progressive item: the window shows the tier just handed over (the highest one owned)
                        const tier_actors = a.alloc([]const u8, chain.tiers.len) catch return error.OutOfMemory;
                        for (chain.tiers, 0..) |tier, t| {
                            tier_actors[t] = (try world.actorFor(a, tier.key, .event)) orelse return progress.fail(error.NotAsExpected, "no event actor for {s}", .{tier.key});
                        }
                        try progressive_flows.branchEvent(a, fc, window, "ActorName", .{
                            .item_offset = 0,
                            .chain = chain,
                            .tier_actors = tier_actors,
                            .shows_item_only = true,
                        }, flow, progress);
                    }
                }
                done += 1;
            }
        }
        const out = try flows.writeBack(a, &doc, flow, progress);
        try patches.emitZs(rel, orig, out);
    }
    if (done > 0) progress.log("Character gifts: {d} reward models show the shuffled item", .{done});
    return done;
}

const important_item_display_action = "EventOpenPerformanceImportantMenu";
/// The game's item hand-over flow and its entry that opens the normal "You got ..." window for an actor
/// (SetForGetWindow, then OpenGetWindow; dump: Event/EventFlow/GetPouchContent.bfevfl).
const item_window_flow = "GetPouchContent";
const item_window_entry = "DisplayGetByActorName";

/// Replaces the scene's one important-item display with the normal item window for `given_actor`, in place: every
/// event that led to the display now reaches the window, which goes on where the display went on.
fn replaceImportantItemDisplayWithItemWindow(allocator: Allocator, fc: *evfl.Flowchart, flow: []const u8, given_actor: []const u8, progress: *Progress) PatchError!u16 {
    var display_event: ?usize = null;
    var count: usize = 0;
    for (fc.events.items, 0..) |e, k| {
        const action = switch (e.kind) {
            .action => |act| act,
            else => continue,
        };
        const actor = fc.actors.items[action.actor];
        if (action.action >= actor.actions.items.len) continue;
        if (!std.mem.eql(u8, actor.actions.items[action.action], important_item_display_action)) continue;
        display_event = k;
        count += 1;
    }
    if (count != 1) return progress.fail(error.NotAsExpected, "{s}: expected one {s}, found {d}", .{ flow, important_item_display_action, count });
    const old = &fc.events.items[display_event.?];
    const go_on = old.next() orelse evfl.NONE;
    const params = try Container.from(allocator, &.{
        .{ .name = "ActorName", .value = .{ .string = given_actor } },
    });
    old.* = evfl.makeSubFlow(old.name, item_window_flow, item_window_entry, go_on, params);
    return @intCast(display_event.?);
}

fn takenBy(fc: *const evfl.Flowchart, except: usize, name: []const u8, secondary: []const u8) bool {
    for (fc.actors.items, 0..) |a, i| {
        if (i == except) continue;
        if (std.mem.eql(u8, a.name, name) and std.mem.eql(u8, a.secondary_name, secondary)) return true;
    }
    return false;
}

/// Rewrites the reward lines of `changed` locations in every language archive. Returns the lines changed.
pub fn writeText(world: *World, patches: *patchset.PatchSet, changed: []const Changed, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    const Edit = struct { line: Line, item_name: []const u8 };
    var edits: std.ArrayList(Edit) = .empty;
    var files_used: std.ArrayList([]const u8) = .empty;
    for (changed) |c| {
        for (tables.lines) |l| {
            if (!std.mem.eql(u8, l.location, c.location)) continue;
            edits.append(a, .{ .line = l, .item_name = try world.itemNameById(a, c.item) }) catch return error.OutOfMemory;
            if (!flows.contains(files_used.items, l.file)) files_used.append(a, l.file) catch return error.OutOfMemory;
        }
    }
    if (edits.items.len == 0) return 0;
    std.mem.sort([]const u8, files_used.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    var total: usize = 0;
    var missed: std.ArrayList([]const u8) = .empty;
    const archives = world.files.listDir(a, "Mals") catch return error.GameFiles;
    for (archives) |fname| {
        if (!std.mem.endsWith(u8, fname, ".sarc.zs")) continue;
        // one language at a time: its archive and rebuilt copy are freed before the next (a .nup has 16 languages)
        var file_arena = patches.fileArena();
        defer file_arena.deinit();
        const la = file_arena.allocator();
        const rel = std.fmt.allocPrint(la, "Mals/{s}", .{fname}) catch return error.OutOfMemory;
        const orig = try patches.readInto(la, rel);
        var replace: std.ArrayList(sarc.NewFile) = .empty;
        for (files_used.items) |mfile| {
            const path = std.fmt.allocPrint(la, "EventFlowMsg/{s}.msbt", .{mfile}) catch return error.OutOfMemory;
            const entry = try sarc.find(la, orig.data, path);
            if (entry == null or !msbt.isUtf8(entry.?.data)) {
                try addMissed(a, &missed, try std.fmt.allocPrint(a, "{s} ({s})", .{ mfile, fname }));
                continue;
            }
            const r = try msbt.raw(la, entry.?.data);
            var lines: std.ArrayList(msbt.NewText) = .empty;
            for (edits.items) |e| {
                if (!std.mem.eql(u8, e.line.file, mfile)) continue;
                // an earlier edit of the same label is built on
                var current: ?[]const u8 = null;
                for (lines.items) |l| if (std.mem.eql(u8, l.label, e.line.label)) {
                    current = l.text;
                };
                const raw = current orelse r.text(e.line.label);
                const line = if (raw) |x| try newLine(la, x, e.line.old, e.line.new, e.item_name) else null;
                const new_text = line orelse {
                    try addMissed(a, &missed, try std.fmt.allocPrint(a, "{s} {s}:{s}", .{ e.line.location, mfile, e.line.label }));
                    continue;
                };
                var replaced = false;
                for (lines.items) |*l| if (std.mem.eql(u8, l.label, e.line.label)) {
                    l.text = new_text;
                    replaced = true;
                };
                if (!replaced) lines.append(la, .{ .label = e.line.label, .text = new_text }) catch return error.OutOfMemory;
            }
            if (lines.items.len > 0) {
                replace.append(la, .{ .name = path, .data = try msbt.addTexts(la, entry.?.data, lines.items) }) catch return error.OutOfMemory;
                total += lines.items.len;
            }
        }
        if (replace.items.len > 0) {
            const archive = sarc.rebuild(la, orig.data, replace.items, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidData,
            };
            try patches.emitZs(rel, orig, archive);
        }
    }
    std.mem.sort([]const u8, missed.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (missed.items) |m| progress.log("warning: reward text not as expected, left as it is: {s}", .{m});
    if (total > 0) progress.log("Character gifts: {d} reward lines name the shuffled item", .{total});
    return total;
}

fn addMissed(allocator: Allocator, missed: *std.ArrayList([]const u8), text: []const u8) error{OutOfMemory}!void {
    if (!flows.contains(missed.items, text)) try missed.append(allocator, text);
}
