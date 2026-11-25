//! Message edits with their flow edits: the Business Scrubs' sale lines and the Temple of Time altar's bridge status.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const sarc = @import("../formats/sarc.zig");
const msbt = @import("../formats/msbt.zig");
const world_mod = @import("../game/world.zig");
const settings_mod = @import("../settings/settings.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const progressive_flows = @import("progressive_flows.zig");
const gamedata = @import("gamedata.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const Container = evfl.Container;
const NONE = evfl.NONE;

const color_on = "\x0e\x00\x00\x03\x00\x02\x00\x00\x00";
const color_off = "\x0e\x00\x00\x03\x00\x02\x00\xff\xff";

fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The sorted names of the message archives (Mals/*.sarc.zs).
fn messageArchives(allocator: Allocator, world: *World) PatchError![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const names = world.files.listDir(allocator, "Mals") catch return error.GameFiles;
    for (names) |n| if (std.mem.endsWith(u8, n, ".sarc.zs")) out.append(allocator, n) catch return error.OutOfMemory;
    return out.items;
}

/// Adds `new_texts` to message file `messages` in every UTF-8 language archive. Returns how many archives changed.
pub fn addToArchives(world: *World, patches: *patchset.PatchSet, messages: []const u8, new_texts: []const msbt.NewText, what: []const u8, progress: *Progress) PatchError!usize {
    var done: usize = 0;
    for (try messageArchives(patches.allocator, world)) |fname| {
        // one language at a time: an archive's original and rebuilt copy are freed before the next language
        // (a .nup has 16 languages, so holding them all made this the largest step of a seed)
        var file_arena = patches.fileArena();
        defer file_arena.deinit();
        const a = file_arena.allocator();
        const rel = std.fmt.allocPrint(a, "Mals/{s}", .{fname}) catch return error.OutOfMemory;
        const orig = try patches.readInto(a, rel);
        const entry = (try sarc.find(a, orig.data, messages)) orelse continue;
        if (!msbt.isUtf8(entry.data)) {
            progress.log("warning: {s} {s} text is not UTF-8; skipped for it", .{ fname, what });
            continue;
        }
        const msg = msbt.addTexts(a, entry.data, new_texts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidData => return progress.fail(error.NotAsExpected, "{s} in {s} is not as expected", .{ messages, fname }),
        };
        const archive = sarc.rebuild(a, orig.data, &.{.{ .name = messages, .data = msg }}, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidData,
        };
        try patches.emitZs(rel, orig, archive);
        done += 1;
    }
    return done;
}

// ===================================================================================== Business Scrub sale lines
// Each one-time scrub's purchase call (SimpleShopSub_Scrub_Business_OneTime in Enemy_Scrub_Business_Common) has a
// SellerMessageId naming its sale line in EventFlowMsg/Enemy_Event.msbt. The Hyrule Field and Death Mountain Crater
// scrubs share one line, so each shuffled scrub gets a line of its own: a new label "Rando_Scrub_<event>" in every
// language's Enemy_Event.msbt, and its purchase calls point at it. The line is the game's English Piece of Heart line
// with the item swapped in ("Ohhh, <item>! Shimmery glimmery! It's <price> rupees. Wanna buy it?"). It keeps the game's
// own colour and price tags (the price tag shows the call's Price, so changed prices read right). Like the hint
// stones, every language gets the English line.

const scrub_flow = "Event/EventFlow/Enemy_Scrub_Business_Common.bfevfl.zs";
const scrub_messages = "EventFlowMsg/Enemy_Event.msbt";
const scrub_message_file = "EventFlowMsg/Enemy_Event";
const scrub_template_language = "USen";
const scrub_template_label = "Enemy_Scrub_Business_Heart_01";
const scrub_template_item = "a " ++ color_on ++ "Piece of Heart" ++ color_off ++ ".";
const scrub_label_prefix = "Rando_Scrub_";

pub const Scrub = struct {
    /// its purchase events (the first names the new label)
    events: []const []const u8,
    item_name: []const u8,
};

fn saleLine(allocator: Allocator, template: []const u8, name: []const u8, progress: *Progress) PatchError![]const u8 {
    if (std.mem.count(u8, template, scrub_template_item) != 1) return progress.fail(error.NotAsExpected, "the Piece of Heart sale line is not as expected", .{});
    var item: std.ArrayList(u8) = .empty;
    item.appendSlice(allocator, color_on) catch return error.OutOfMemory;
    for (name) |c| if (c != 0) item.append(allocator, c) catch return error.OutOfMemory;
    item.appendSlice(allocator, color_off ++ "!") catch return error.OutOfMemory;
    return std.mem.replaceOwned(u8, allocator, template, scrub_template_item, item.items) catch error.OutOfMemory;
}

/// Adds each shuffled scrub's sale line in every language and points its purchase calls at it. Returns the number of
/// scrubs changed. NotAsExpected (with the reason) when the files aren't as expected: then nothing is written.
pub fn writeScrubText(world: *World, patches: *patchset.PatchSet, scrubs: []const Scrub, progress: *Progress) PatchError!usize {
    if (scrubs.len == 0) return 0;
    const a = patches.allocator;
    const archives = try messageArchives(a, world);
    std.mem.sort([]const u8, archives, {}, lessString);
    var template_fn: ?[]const u8 = null;
    for (archives) |n| if (template_fn == null and std.mem.startsWith(u8, n, scrub_template_language)) {
        template_fn = n;
    };
    const tfn = template_fn orelse return progress.fail(error.NotAsExpected, "no {s} message archive", .{scrub_template_language});
    const trel = std.fmt.allocPrint(a, "Mals/{s}", .{tfn}) catch return error.OutOfMemory;
    const tarc = try patches.read(trel);
    const tmsg = (try sarc.find(a, tarc.data, scrub_messages)) orelse return progress.fail(error.NotAsExpected, "no {s}", .{scrub_messages});
    const traw = try msbt.raw(a, tmsg.data);
    const template = traw.text(scrub_template_label) orelse return progress.fail(error.NotAsExpected, "no {s} line", .{scrub_template_label});

    var lines: std.ArrayList(msbt.NewText) = .empty;
    for (scrubs) |s| {
        const label = std.fmt.allocPrint(a, "{s}{s}", .{ scrub_label_prefix, s.events[0] }) catch return error.OutOfMemory;
        lines.append(a, .{ .label = label, .text = try saleLine(a, template, s.item_name, progress) }) catch return error.OutOfMemory;
    }

    // the flow first: if its events are not as expected, no text is written
    const orig = try patches.read(scrub_flow);
    var doc = try flows.readFlow(a, orig.data, "Enemy_Scrub_Business_Common", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no scrub flowchart", .{});
    for (scrubs) |s| {
        for (s.events) |ev| {
            // the last event of that name wins, as a Python dict built from the list
            var index: ?usize = null;
            for (fc.events.items, 0..) |e, k| if (std.mem.eql(u8, e.name, ev)) {
                index = k;
            };
            const e = if (index) |k| &fc.events.items[k] else return progress.fail(error.NotAsExpected, "{s} has no sale line in {s}", .{ ev, scrub_flow });
            const p = e.params() orelse return progress.fail(error.NotAsExpected, "{s} has no sale line in {s}", .{ ev, scrub_flow });
            if (!p.has("SellerMessageId")) return progress.fail(error.NotAsExpected, "{s} has no sale line in {s}", .{ ev, scrub_flow });
            const id = std.fmt.allocPrint(a, "{s}:{s}{s}", .{ scrub_message_file, scrub_label_prefix, s.events[0] }) catch return error.OutOfMemory;
            try p.put(a, "SellerMessageId", .{ .string = id });
            // a progressive item's copies of the sale (one per tier, progressive_flows.zig) say the same line
            for (fc.events.items) |*copy| {
                if (!progressive_flows.isCopyOf(copy.name, ev)) continue;
                const copy_params = copy.params() orelse continue;
                if (copy_params.has("SellerMessageId")) try copy_params.put(a, "SellerMessageId", .{ .string = id });
            }
        }
    }
    const new_flow = try flows.writeBack(a, &doc, "the scrub flow", progress);

    const done = try addToArchives(world, patches, scrub_messages, lines.items, "scrub", progress);
    if (done == 0) return progress.fail(error.NotAsExpected, "no message archive holds {s}", .{scrub_messages});
    try patches.emitZs(scrub_flow, orig, new_flow);
    progress.log("Business Scrubs: {d} sale lines name their item ({d} languages)", .{ scrubs.len, done });
    return scrubs.len;
}

// ====================================================================================== the altar's bridge status
// Reading the altar in the Temple of Time (DoorOfTime: Check_SpiritStoneBase) shows the inscription
// EventFlowMsg/SignboardWood:TempleOfTime_000, then ends. Both paths now go on to one more signboard message,
// Rando_BridgeStatus, e.g.
//
//     Rainbow Bridge to Ganon's Castle
//     Medallions: 2/4
//     Bow: 1/1    Light Arrows: 0/1
//
// The numbers are live. Before the message the flow counts, with the game's own GameDataActor actions, into three
// Int flags added to the save data (not saved): Rando_Bridge_Count (medallions or stones owned: +1 for each whose
// Rando_Have_<item> computed flag is true, the flags the bridge itself reads; or the token count, copied from
// PouchData.Item_Token_Gold.StockNum), Rando_Bridge_Bow and Rando_Bridge_LightArrows (0 or 1). The message shows an Int
// with the tag the token message uses. With Vanilla the message only says what Vanilla needs.

const bridge_flow = "Event/EventFlow/DoorOfTime.bfevfl.zs";
const bridge_entry = "Check_SpiritStoneBase";
const inscription = "EventFlowMsg/SignboardWood:TempleOfTime_000";
const bridge_messages = "EventFlowMsg/SignboardWood.msbt";
const bridge_label = "Rando_BridgeStatus";
const bridge_message_id = "EventFlowMsg/SignboardWood:" ++ bridge_label;

fn tagBytes(allocator: Allocator, group: u16, typ: u16, params: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, 0x0E);
    var raw: [6]u8 = undefined;
    std.mem.writeInt(u16, raw[0..2], group, .little);
    std.mem.writeInt(u16, raw[2..4], typ, .little);
    std.mem.writeInt(u16, raw[4..6], @intCast(params.len), .little);
    try out.appendSlice(allocator, &raw);
    try out.appendSlice(allocator, params);
    return out.items;
}

/// The tag that shows Int flag `name` (as Item_Token_Gold_SecondGetCaption shows UI_TokenGoldNumAfterGetting).
fn numberTag(allocator: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    var params: std.ArrayList(u8) = .empty;
    var len_raw: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_raw, @intCast(name.len), .little);
    try params.appendSlice(allocator, &len_raw);
    try params.appendSlice(allocator, name);
    try params.appendSlice(allocator, "\xff\xff\x01");
    return tagBytes(allocator, 2, 1, params.items);
}

fn haveFlag(allocator: Allocator, item_flag: []const u8) error{OutOfMemory}![]const u8 {
    const dot = std.mem.indexOfScalar(u8, item_flag, '.').?;
    return std.fmt.allocPrint(allocator, "Rando_Have_{s}", .{item_flag[dot + 1 ..]});
}

const Requirement = struct {
    what: []const u8,
    needed: i64,
    /// the Rando_Have flags to count (null: the token count)
    flags: ?[]const []const u8,
};

fn requirement(allocator: Allocator, st: *const settings_mod.Settings) error{OutOfMemory}!?Requirement {
    if (st.is(.rainbow_bridge, "medallions")) {
        const flags = try allocator.alloc([]const u8, gamedata.bridge_medallions.len);
        for (gamedata.bridge_medallions, 0..) |m, i| flags[i] = try haveFlag(allocator, m);
        return .{ .what = "Medallions", .needed = std.math.clamp(st.int(.bridge_medallions), 1, 6), .flags = flags };
    }
    if (st.is(.rainbow_bridge, "stones")) {
        const flags = try allocator.alloc([]const u8, gamedata.bridge_stones.len);
        for (gamedata.bridge_stones, 0..) |m, i| flags[i] = try haveFlag(allocator, m);
        return .{ .what = "Spiritual Stones", .needed = 3, .flags = flags };
    }
    if (st.is(.rainbow_bridge, "tokens")) return .{ .what = "Gold Skulltula Tokens", .needed = st.int(.bridge_tokens), .flags = null };
    return null;
}

/// The status line's raw UTF-8 text (with its terminator), and with Barren Dungeons a second page naming them
/// (`barren`: their names; a page break is the game's own tag 0:4).
fn bridgeMessage(allocator: Allocator, st: *const settings_mod.Settings, barren: []const []const u8) error{OutOfMemory}![]const u8 {
    const status = try bridgeStatus(allocator, st);
    if (barren.len == 0) return status;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, status[0 .. status.len - 1]); // without its terminator
    try out.appendSlice(allocator, try tagBytes(allocator, 0, 4, ""));
    try out.appendSlice(allocator, try tagBytes(allocator, 0, 3, "\x00\x00"));
    try out.appendSlice(allocator, if (barren.len == 1) "Barren Dungeon" else "Barren Dungeons");
    try out.appendSlice(allocator, try tagBytes(allocator, 0, 3, "\xff\xff"));
    // two names a line, so the box fits up to five dungeons on its three lines
    for (barren, 0..) |name, k| {
        try out.appendSlice(allocator, if (k % 2 == 0) "\n" else ", ");
        try out.appendSlice(allocator, name);
    }
    try out.append(allocator, 0);
    return out.items;
}

fn bridgeStatus(allocator: Allocator, st: *const settings_mod.Settings) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, try tagBytes(allocator, 0, 3, "\x00\x00"));
    try out.appendSlice(allocator, "Rainbow Bridge to Ganon's Castle");
    try out.appendSlice(allocator, try tagBytes(allocator, 0, 3, "\xff\xff"));
    try out.append(allocator, '\n');
    const req = (try requirement(allocator, st)) orelse {
        try out.appendSlice(allocator, "Finish the Shadow and Spirit Temples, then return\nhere to receive the Light Arrows.\x00");
        return out.items;
    };
    const ints = gamedata.bridge_status_ints;
    try out.appendSlice(allocator, req.what);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, try numberTag(allocator, ints[0]));
    try out.print(allocator, "/{d}\n", .{req.needed});
    try out.appendSlice(allocator, "Bow: ");
    try out.appendSlice(allocator, try numberTag(allocator, ints[1]));
    try out.appendSlice(allocator, "/1    Light Arrows: ");
    try out.appendSlice(allocator, try numberTag(allocator, ints[2]));
    try out.appendSlice(allocator, "/1\x00");
    return out.items;
}

/// DoorOfTime: after the altar's inscription, count and show the bridge status.
fn bridgeFlow(allocator: Allocator, data: []const u8, st: *const settings_mod.Settings, progress: *Progress) PatchError![]u8 {
    const req = try requirement(allocator, st);
    var doc = try flows.readFlow(allocator, data, "DoorOfTime", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no DoorOfTime flowchart", .{});
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, "RandoBridgeStatus")) return progress.fail(error.NotAsExpected, "the altar already shows the bridge status", .{});
    }
    const entry = fc.entryPoint(bridge_entry) orelse return progress.fail(error.NotAsExpected, "no {s} entry", .{bridge_entry});
    const reached = try fc.reach(allocator, entry.main_event);
    var talks: std.ArrayList(u16) = .empty;
    for (reached, 0..) |r, i| {
        if (!r) continue;
        const e = &fc.events.items[i];
        if (e.kind != .action or !std.mem.eql(u8, fc.actionName(e) orelse "", "EventTalk")) continue;
        const p = e.kind.action.params orelse continue;
        if (p.isString("MessageId", inscription)) talks.append(allocator, @intCast(i)) catch return error.OutOfMemory;
    }
    if (talks.items.len == 0) return progress.fail(error.NotAsExpected, "the altar's inscription is not in {s}", .{bridge_entry});

    // each inscription path is a straight line of actions / calls to its end: the status goes there
    var ends: std.ArrayList(u16) = .empty;
    for (talks.items) |t| {
        var i = t;
        var steps: usize = 0;
        while (true) {
            const e = &fc.events.items[i];
            if ((e.kind != .action and e.kind != .sub_flow) or steps > 20) return progress.fail(error.NotAsExpected, "the altar's inscription path branches", .{});
            const next = e.next().?;
            if (next == NONE) break;
            if (next >= fc.events.items.len) return progress.fail(error.NotAsExpected, "the altar's inscription path is broken", .{});
            i = next;
            steps += 1;
        }
        ends.append(allocator, i) catch return error.OutOfMemory;
    }

    const base = fc.events.items[talks.items[0]].kind.action;
    const talk_params = try base.params.?.clone(allocator);
    try talk_params.put(allocator, "MessageId", .{ .string = bridge_message_id });
    var next = try fc.addEvent(allocator, evfl.makeAction("RandoBridgeStatus_Talk", .{ base.actor, base.action }, NONE, talk_params));
    if (req) |r| {
        const set_aa = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataInt", progress);
        const add_aa = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerAddOrSubGameDataInt", progress);
        const q_aa = try flows.requireQuery(fc, allocator, "GameDataActor", "EventQueryIsGameDataBoolExp", progress);
        const ints = gamedata.bridge_status_ints;
        next = try counted(fc, allocator, add_aa, q_aa, ints[2], try haveFlag(allocator, gamedata.bridge_light_arrows), next, "Arrows");
        next = try counted(fc, allocator, add_aa, q_aa, ints[1], try haveFlag(allocator, gamedata.bridge_bow), next, "Bow");
        if (r.flags) |list| {
            var k = list.len;
            while (k > 0) {
                k -= 1;
                const suffix = std.fmt.allocPrint(allocator, "{d}", .{k}) catch return error.OutOfMemory;
                next = try counted(fc, allocator, add_aa, q_aa, ints[0], list[k], next, suffix);
            }
        } else {
            const copy_aa = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerCopyGameDataInt", progress);
            next = try fc.addEvent(allocator, evfl.makeAction("RandoBridgeStatus_Tokens", copy_aa, next, try Container.from(allocator, &.{
                .{ .name = "SrcGameDataName", .value = .{ .string = gamedata.token_count } },
                .{ .name = "SrcGameDataIndex", .value = .{ .int = -1 } },
                .{ .name = "DstGameDataName", .value = .{ .string = ints[0] } },
                .{ .name = "DstGameDataIndex", .value = .{ .int = -1 } },
            })));
        }
        var k = ints.len;
        while (k > 0) {
            k -= 1;
            const name = std.fmt.allocPrint(allocator, "RandoBridgeStatus_Reset{s}", .{ints[k]["Rando_Bridge_".len..]}) catch return error.OutOfMemory;
            next = try fc.addEvent(allocator, evfl.makeAction(name, set_aa, next, try Container.from(allocator, &.{
                .{ .name = "GameDataName", .value = .{ .string = ints[k] } },
                .{ .name = "Value", .value = .{ .int = 0 } },
                .{ .name = "Index", .value = .{ .int = -1 } },
            })));
        }
    }
    for (ends.items) |i| fc.events.items[i].nextPtr().?.* = next;
    return flows.writeBack(allocator, &doc, "the altar flow", progress);
}

/// If computed flag `flag` (case 0 = true): +1 to Int `name`; then `then`. Returns the new switch.
fn counted(fc: *evfl.Flowchart, allocator: Allocator, add_aa: [2]u16, q_aa: [2]u16, name: []const u8, flag: []const u8, then: u16, suffix: []const u8) PatchError!u16 {
    const add_name = std.fmt.allocPrint(allocator, "RandoBridgeStatus_Add{s}", .{suffix}) catch return error.OutOfMemory;
    const plus = try fc.addEvent(allocator, evfl.makeAction(add_name, add_aa, then, try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = name } },
        .{ .name = "Value", .value = .{ .int = 1 } },
        .{ .name = "Index", .value = .{ .int = -1 } },
    })));
    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = 0, .event = plus }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = 1, .event = then }) catch return error.OutOfMemory;
    const has_name = std.fmt.allocPrint(allocator, "RandoBridgeStatus_Has{s}", .{suffix}) catch return error.OutOfMemory;
    return fc.addEvent(allocator, .{ .name = has_name, .kind = .{ .switch_ = .{
        .actor = q_aa[0],
        .query = q_aa[1],
        .cases = cases,
        .params = try Container.from(allocator, &.{.{ .name = "GameDataName", .value = .{ .string = flag } }}),
    } } });
}

/// The altar's status line in every language, and the flow edit.
pub fn writeBridgeText(world: *World, patches: *patchset.PatchSet, st: *const settings_mod.Settings, barren_folders: []const []const u8, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const orig = try patches.read(bridge_flow);
    const new = try bridgeFlow(a, orig.data, st, progress);
    const barren = a.alloc([]const u8, barren_folders.len) catch return error.OutOfMemory;
    for (barren_folders, 0..) |folder, k| barren[k] = world.regionName(folder);
    const line = try bridgeMessage(a, st, barren);
    const done = try addToArchives(world, patches, bridge_messages, &.{.{ .label = bridge_label, .text = line }}, "altar", progress);
    if (done == 0) return progress.fail(error.NotAsExpected, "no message archive holds {s}", .{bridge_messages});
    try patches.emitZs(bridge_flow, orig, new);
    progress.log("Temple of Time altar: shows the Rainbow Bridge requirement{s} ({d} languages)", .{ if (barren.len > 0) " and the barren dungeons" else "", done });
}
