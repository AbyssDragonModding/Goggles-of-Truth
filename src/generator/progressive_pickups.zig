//! Progressive items lying in the world (freestanding spots, rupee spots, boss Heart Container spots and Gold
//! Skulltula drops: fill.isGroundSpot) and on shop shelves. New here (not in OotrR or Clawshot).
//!
//! A world pickup can't choose what it gives: the game's item get (Event/EventFlow/Dm_SY_Get, a resident event that
//! the pickup itself plays) adds the pickup's own pouch item (PouchContentGuestPerformer.EventTriggerAddOwnToPouch),
//! and nothing in it can tell one pickup from another. Chests choose through their AI (Drop__CheckActor), which a
//! pickup has no part of. A shelf sells its own pouch item too (DisplayShop). What every item get does run at its end
//! is ActionGuide:ActionGuide {ActorName} (Dm_SY_Get calls it after Default_Get, Dm_SY_Get_WithoutPlayer after its
//! add), the hook keyitems.zig already uses, and every purchase ActionGuide:ActionGuideForShop (DisplayShop, after the
//! purchase's autosave). So the item is a stand-in that the hook turns into the next tier:
//!
//! - Ground: each upgrade line with a copy on the ground gets its own item, "Progressive <line>"
//!   (progressive.Chain.ground_pickup_item, "Item_Prog_<line>"), shared by all its copies there. Its world pickup is
//!   built like any other (pickups.worldActor: a rupee's body), with PlayGetEventManyTimes, so the second copy's item
//!   get plays too. The hook clears its IsGet flag once applied, so the next copy sets it again.
//! - Shelves: each shelf selling a progressive item gets its own item, "Item_PS<n>_<line>" (Shelf). Why not the
//!   line's: a bought shelf is hidden by its item's IsGet flag (patches.zig), so that flag must stay set and be the
//!   shelf's alone. The hook marks it applied in a saved flag of its own instead, "RandoProgApplied.<item>", as the
//!   key rings are (keyitems.zig).
//!
//! Each item is a new key item with the first tier's model (pickups.PickupCloner.keyItem), a saved IsGet.<item> flag
//! listed in the IsGet structure (the game sets it when the item reaches the pouch, gamedata.addIsGetMember) and its
//! texts. Both ActionGuide entries first check every such item (an entry's own copy of the checks):
//!
//!       IsGet.<item>?                  (GameDataActor.EventQueryIsGameDataBool, case 0: true)
//!         yes -> ground: IsGet.<item> = false | shelf: RandoProgApplied.<item>? yes -> next item; no -> set it
//!             -> own <item>? (pouch query) -> yes: remove it (Num -1, as the game removes the Weird Egg)
//!             -> the same pouch queries as the event flows (progressive_flows.zig), highest tier down:
//!                own tier n-1? -> give tier n ... else give tier 1
//!             -> give = PouchSystemActor.EventTriggerAddOrRemovePouchContent {Actor=<tier>, Num=1} and
//!                GetPouchContent:DisplayGetByActorName {ActorName=<tier>}: the game's own Fairy Ocarina scene does
//!                exactly that (Dm_Kokiri_0155), and the chests show their item's window by it. Not a hand-over
//!                call: that creates the item in Link's hands, which crashed with an Ocarina (issue #5)
//!             -> an Ocarina: ActionGuide:OpenActionGuideSceenForOcarina, its tutorial (as ocarina_handover.zig)
//!             -> the next item's check
//!         no  -> the next item's check
//!       ... -> the entry's original first event
//!
//! The player sees "Progressive <line>" held up or bought, then the window of the tier it became. An item got where
//! no item get runs is given at the next one. Every tier is exact whatever order the copies are found in, so the fill
//! treats these spots like event hand-overs (fill.canGiveProgressive). Not tested in-game yet.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const msbt = @import("../formats/msbt.zig");
const progressive = @import("../logic/progressive.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const pickups = @import("pickups.zig");
const gamedata = @import("gamedata.zig");
const flows = @import("flows.zig");
const textpatches = @import("textpatches.zig");
const keyitems = @import("keyitems.zig");
const fill = @import("fill.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const ItemId = @import("../logic/logic.zig").ItemId;
const Container = evfl.Container;

/// The ActionGuide entries the checks go in front of: every item get's end, and every purchase's
const hooked_entries = [_]struct { name: []const u8, suffix: []const u8 }{
    .{ .name = "ActionGuide", .suffix = "" },
    .{ .name = "ActionGuideForShop", .suffix = "_Shop" },
};
const ocarina_tutorial_entry = "OpenActionGuideSceenForOcarina";
const gift_window_flow = "GetPouchContent";
/// shows the item window of an item just added (Dm_Kokiri_0155, Dm_SY_Treasurebox)
const gift_window_entry = "DisplayGetByActorName";
const pouch_actor_name = "PouchSystemActor";
const owns_query = "EventQueryIsExistInPouch";
const add_or_remove_action = "EventTriggerAddOrRemovePouchContent";
/// the pouch query's cases (dump: MiniGame_BombchuBowling Event76)
const case_owned: u32 = 0;
const case_not_owned: u32 = 1;
/// a GameData Bool switch takes case 0 when the flag is true (keyitems.boolSwitch, the game's own flows)
const case_true: u32 = 0;
const case_false: u32 = 1;
/// the prefix of every event added here (keyitems.zig's are "RandoKey")
const added_prefix = "RandoProg";
/// the saved flag that marks a shelf's item as applied ("RandoProgApplied.Item_PS1_Hookshot")
const applied_prefix = "RandoProgApplied.";
/// the IsGet flag every new item's own flag is shaped like (keyitems.zig uses the same)
const isget_template = "IsGet.Item_Medal_Forest";
const item_messages = "ActorMsg/PouchContent.msbt";
/// "Item_Prog_Hookshot" -> "Hookshot": a line's short name in the shelf items' names
const ground_item_prefix = "Item_Prog_";

/// One shop shelf selling a progressive item, and the item made for it.
pub const Shelf = struct {
    /// the shelf's location index
    location: usize,
    line: *const progressive.Chain,
    /// "Item_PS<n>_<line>" (n counts the seed's progressive shelves from 1, in location order)
    item: []const u8,
};

/// What this seed needs: the lines with a copy on the ground, and the shelves selling one.
pub const Needs = struct {
    /// in progressive.chains order
    ground_lines: []const *const progressive.Chain,
    /// in location order
    shelves: []const Shelf,

    /// The item shelf location `location` sells for its progressive item, or null.
    pub fn shelfItemAt(self: *const Needs, location: usize) ?[]const u8 {
        for (self.shelves) |s| if (s.location == location) return s.item;
        return null;
    }

    pub fn count(self: *const Needs) usize {
        return self.ground_lines.len + self.shelves.len;
    }
};

/// The stand-in items this seed needs (`placed`: per location, the item placed there).
pub fn needsOf(allocator: Allocator, world: *const World, placed: []const ?ItemId) PatchError!Needs {
    var on_ground: [progressive.chains.len]bool = @splat(false);
    var shelves: std.ArrayList(Shelf) = .empty;
    for (placed, 0..) |maybe, i| {
        const item = maybe orelse continue;
        const chain = progressive.chainOfProgressiveItem(world.items.name(item)) orelse continue;
        const loc = &world.locations.items[i];
        if (fill.isGroundSpot(loc)) {
            for (&progressive.chains, 0..) |*line, k| {
                if (line == chain) on_ground[k] = true;
            }
        } else if (loc.kind == .shop) {
            const name = try shelfItemName(allocator, shelves.items.len + 1, chain);
            shelves.append(allocator, .{ .location = i, .line = chain, .item = name }) catch return error.OutOfMemory;
        }
    }
    var lines: std.ArrayList(*const progressive.Chain) = .empty;
    for (&progressive.chains, 0..) |*line, k| {
        if (on_ground[k]) lines.append(allocator, line) catch return error.OutOfMemory;
    }
    return .{ .ground_lines = lines.items, .shelves = shelves.items };
}

/// "Item_PS<n>_<line>": kept within pickups.max_key_item_name (a longer generated item crashed its item get).
fn shelfItemName(allocator: Allocator, n: usize, line: *const progressive.Chain) PatchError![]const u8 {
    const stem = line.ground_pickup_item[ground_item_prefix.len..];
    const name = std.fmt.allocPrint(allocator, "Item_PS{d}_{s}", .{ n, stem }) catch return error.OutOfMemory;
    if (name.len > pickups.max_key_item_name) return error.NotAsExpected;
    return name;
}

/// One stand-in item the hook checks.
const StandIn = struct {
    item: []const u8,
    line: *const progressive.Chain,
    /// a shelf's: applied once, by its own saved flag; a ground item's: its IsGet flag is cleared
    once: bool,
    /// the item actor of each tier, lowest first
    tier_actors: []const []const u8,
};

/// Builds every stand-in item of `needs`: its pack and RSDB rows (through `cloner`, before any pickup or shelf is
/// cloned from it), its saved flags, its texts and the ActionGuide checks that give the next tier. Runs after
/// keyitems.build (both add to ActionGuide). Returns how many were made.
pub fn build(world: *World, patches: *patchset.PatchSet, cloner: *pickups.PickupCloner, needs: Needs, progress: *Progress) PatchError!usize {
    if (needs.count() == 0) return 0;
    const a = patches.allocator;
    var stand_ins: std.ArrayList(StandIn) = .empty;
    for (needs.ground_lines) |line| {
        stand_ins.append(a, .{ .item = line.ground_pickup_item, .line = line, .once = false, .tier_actors = try tierActorsOf(a, world, line, progress) }) catch return error.OutOfMemory;
    }
    for (needs.shelves) |s| {
        stand_ins.append(a, .{ .item = s.item, .line = s.line, .once = true, .tier_actors = try tierActorsOf(a, world, s.line, progress) }) catch return error.OutOfMemory;
    }
    for (stand_ins.items) |s| {
        try cloner.keyItem(s.item, s.line.ground_pickup_model);
        // its pickup or shelf gets the same height, shelf scale and model box as the first tier's own pickup or
        // shelf: the item actor the old code built those from (the Fairy Ocarina's Item_ actor too, though the model
        // is lent by its Pouch_ actor)
        try cloner.restLike(s.item, s.tier_actors[0]);
    }
    try addFlags(world, patches, stand_ins.items, progress);
    try addTexts(world, patches, stand_ins.items, progress);
    const orig = try patches.read(keyitems.action_guide_flow);
    const hooked = try addHook(a, orig.data, stand_ins.items, progress);
    try patches.emitZs(keyitems.action_guide_flow, orig, hooked);
    return stand_ins.items.len;
}

fn tierActorsOf(allocator: Allocator, world: *World, line: *const progressive.Chain, progress: *Progress) PatchError![]const []const u8 {
    const actors = allocator.alloc([]const u8, line.tiers.len) catch return error.OutOfMemory;
    for (line.tiers, 0..) |tier, t| {
        // the real item (an Ocarina's Item_ actor too: it is added silently, never created in Link's hands)
        actors[t] = (try world.actorFor(allocator, tier.key, .event)) orelse
            return progress.fail(error.NotAsExpected, "no item actor for {s}", .{tier.key});
    }
    return actors;
}

/// IsGet.<item> for every stand-in item (and its IsGet structure entry, so the game sets it on every get), and a
/// shelf item's applied flag.
fn addFlags(world: *World, patches: *patchset.PatchSet, stand_ins: []const StandIn, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const rel = try world.find(a, "GameData", "GameDataList");
    const original = try patches.read(rel);
    var gd = try gamedata.GameDataPatcher.init(a, rel, original.data, original.dictionary, progress);
    for (stand_ins) |s| {
        const flag = try isGetFlagOf(a, s.item);
        if (!try gd.addSavedBool(flag, false, isget_template)) return progress.fail(error.NotAsExpected, "the save data already has {s}", .{flag});
        if (!try gd.addIsGetMember(s.item)) return progress.fail(error.NotAsExpected, "the IsGet structure already has {s}", .{s.item});
        if (s.once) {
            const applied = try appliedFlagOf(a, s.item);
            if (!try gd.addSavedBool(applied, false, null)) return progress.fail(error.NotAsExpected, "the save data already has {s}", .{applied});
        }
    }
    try gd.finish(patches);
}

fn isGetFlagOf(allocator: Allocator, item: []const u8) PatchError![]const u8 {
    return fmt(allocator, "IsGet.{s}", .{item});
}

fn appliedFlagOf(allocator: Allocator, item: []const u8) PatchError![]const u8 {
    return fmt(allocator, "{s}{s}", .{ applied_prefix, item });
}

/// The item's name, description and get message in every language (English everywhere, like the hints). Without
/// them the item window has no text and never closes (OotrR, keyitems.addTexts).
fn addTexts(world: *World, patches: *patchset.PatchSet, stand_ins: []const StandIn, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    var texts: std.ArrayList(msbt.NewText) = .empty;
    for (stand_ins) |s| {
        const pairs = [_][2][]const u8{
            .{ "Name", s.line.display_name },
            .{ "Caption", "Becomes the next one you don't have yet." },
            .{ "GetMessage", try fmt(a, "You got a {s}!", .{s.line.display_name}) },
            // never empty: the get window shows every item's caption as a second box
            // (GetPouchContent:DefaultGetMessage), and with an empty one the game softlocked (test report, PROGFINAL1)
            .{ "GetCaption", "It becomes the next one you don't have yet." },
        };
        for (pairs) |p| {
            texts.append(a, .{ .label = try fmt(a, "{s}_{s}", .{ s.item, p[0] }), .text = p[1] }) catch return error.OutOfMemory;
        }
    }
    const done = try textpatches.addToArchives(world, patches, item_messages, texts.items, "progressive pickups", progress);
    if (done == 0) return progress.fail(error.NotAsExpected, "no message archive holds {s}", .{item_messages});
}

fn fmt(allocator: Allocator, comptime format: []const u8, args: anytype) PatchError![]const u8 {
    return std.fmt.allocPrint(allocator, format, args) catch error.OutOfMemory;
}

/// The indices of the actions and queries the hook uses, added to the flow's actors where missing.
const HookCalls = struct {
    is_bool: [2]u16,
    set_bool: [2]u16,
    owns: [2]u16,
    add_or_remove: [2]u16,
    fade_in: [2]u16,
};

/// Puts the checks of every stand-in item in front of each hooked ActionGuide entry (the module comment shows them).
fn addHook(allocator: Allocator, data: []const u8, stand_ins: []const StandIn, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "ActionGuide", progress);
    const fc = try flows.expectFlowchart(&doc, "ActionGuide", progress);
    for (fc.events.items) |e| {
        if (std.mem.startsWith(u8, e.name, added_prefix)) return progress.fail(error.NotAsExpected, "ActionGuide already has the progressive pickup checks", .{});
    }
    if (fc.entryPoint(ocarina_tutorial_entry) == null) return progress.fail(error.NotAsExpected, "ActionGuide has no {s} entry", .{ocarina_tutorial_entry});
    // GameDataActor and PouchSystemActor are already in the flow with their parameters (a named actor without them
    // crashed the game, OotrR); only their missing actions and queries are added
    const calls = HookCalls{
        .is_bool = try flows.requireQuery(fc, allocator, "GameDataActor", "EventQueryIsGameDataBool", progress),
        .set_bool = try flows.requireAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataBool", progress),
        .owns = try flows.requireQuery(fc, allocator, pouch_actor_name, owns_query, progress),
        .add_or_remove = try flows.requireAction(fc, allocator, pouch_actor_name, add_or_remove_action, progress),
        .fade_in = try flows.requireAction(fc, allocator, "UISystemActor", "EventEventFadeIn", progress),
    };

    var added_calls: std.ArrayList(u16) = .empty;
    for (hooked_entries) |hooked| {
        const entry = fc.entryPoint(hooked.name) orelse return progress.fail(error.NotAsExpected, "ActionGuide has no {s} entry", .{hooked.name});
        if (entry.main_event == evfl.NONE) return progress.fail(error.NotAsExpected, "ActionGuide's {s} entry is empty", .{hooked.name});
        var following = entry.main_event;
        var k: usize = stand_ins.len;
        while (k > 0) {
            k -= 1;
            following = try addCheck(allocator, fc, calls, stand_ins[k], hooked.suffix, following, &added_calls);
        }
        // `entry` still points into the entry list: addCheck only adds events
        entry.main_event = following;
    }
    // an entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13)
    try flows.listReachedCalls(allocator, fc, added_calls.items);
    return flows.writeBack(allocator, &doc, "ActionGuide (progressive pickups)", progress);
}

/// One stand-in item's check in one entry (event names end in `suffix`), leading to `following` either way; returns
/// its first event.
fn addCheck(allocator: Allocator, fc: *evfl.Flowchart, calls: HookCalls, s: StandIn, suffix: []const u8, following: u16, added_calls: *std.ArrayList(u16)) PatchError!u16 {
    const tiers = s.line.tiers;
    if (s.tier_actors.len != tiers.len) return error.NotAsExpected;
    const stem = s.item["Item_".len..];
    const is_ocarina = world_mod.World.wornEquipmentBase(tiers[0].key) != null;

    // each tier's give: add silently, show its window, fade back in, an Ocarina's tutorial; then `following`
    const gives = allocator.alloc(u16, tiers.len) catch return error.OutOfMemory;
    for (tiers, 0..) |_, t| {
        var after_window = following;
        if (is_ocarina) {
            after_window = try fc.addEvent(allocator, evfl.makeSubFlow(try fmt(allocator, "{s}Tutorial_{s}{d}{s}", .{ added_prefix, stem, t + 1, suffix }), "ActionGuide", ocarina_tutorial_entry, following, null));
            added_calls.append(allocator, after_window) catch return error.OutOfMemory;
        }
        // Why the fade-in: the window of a few items fades the screen out, as their own get scene goes on after it
        // (GetPouchContent:OpenGetWindow_EarlyFadeOut, Event60 cases 9 and 10: the Golden Gauntlets). Bought in the
        // Bazaar the screen stayed black until the shop menu was left (test report, PROGFINAL1). The game's own fade-in
        // parameters (151 flows)
        after_window = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "{s}FadeIn_{s}{d}{s}", .{ added_prefix, stem, t + 1, suffix }), calls.fade_in, after_window, try Container.from(allocator, &.{
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
            .{ .name = "Length", .value = .{ .int = 1 } },
        })));
        const window = try fc.addEvent(allocator, evfl.makeSubFlow(try fmt(allocator, "{s}Window_{s}{d}{s}", .{ added_prefix, stem, t + 1, suffix }), gift_window_flow, gift_window_entry, after_window, try Container.from(allocator, &.{
            .{ .name = "ActorName", .value = .{ .string = s.tier_actors[t] } },
        })));
        added_calls.append(allocator, window) catch return error.OutOfMemory;
        // the parameters of the game's own silent add (Dm_Kokiri_0155 Event68)
        gives[t] = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "{s}Give_{s}{d}{s}", .{ added_prefix, stem, t + 1, suffix }), calls.add_or_remove, window, try Container.from(allocator, &.{
            .{ .name = "Num", .value = .{ .int = 1 } },
            .{ .name = "IsSetMessageTargetActorName", .value = .{ .bool = true } },
            .{ .name = "Actor", .value = .{ .string = s.tier_actors[t] } },
        })));
    }

    // the tier checks, built from the bottom one up: own tier t -> give tier t + 1, else the check below
    var tier_choice: u16 = gives[0];
    for (1..tiers.len) |t| {
        tier_choice = try pouchSwitch(allocator, fc, calls.owns, try fmt(allocator, "{s}Owns_{s}{d}{s}", .{ added_prefix, stem, t, suffix }), tiers[t - 1].pouch_actor, gives[t], tier_choice);
    }

    // the stand-in item out of the pouch when it is there (so a later copy is added again, and the menu doesn't list
    // it); asked first, as the game only removes what Link has
    const remove = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "{s}Remove_{s}{s}", .{ added_prefix, stem, suffix }), calls.add_or_remove, tier_choice, try Container.from(allocator, &.{
        .{ .name = "Num", .value = .{ .int = -1 } },
        .{ .name = "IsSetMessageTargetActorName", .value = .{ .bool = true } },
        .{ .name = "Actor", .value = .{ .string = s.item } },
    })));
    const held = try pouchSwitch(allocator, fc, calls.owns, try fmt(allocator, "{s}Held_{s}{s}", .{ added_prefix, stem, suffix }), s.item, remove, tier_choice);

    const got_flag = try isGetFlagOf(allocator, s.item);
    // a ground item: its IsGet cleared for the next copy. A shelf's: marked applied (its IsGet hides the shelf)
    const mark_flag = if (s.once) try appliedFlagOf(allocator, s.item) else got_flag;
    const mark = try fc.addEvent(allocator, evfl.makeAction(try fmt(allocator, "{s}Mark_{s}{s}", .{ added_prefix, stem, suffix }), calls.set_bool, held, try Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = mark_flag } },
        .{ .name = "Value", .value = .{ .bool = s.once } },
        .{ .name = "Index", .value = .{ .int = -1 } },
    })));
    const apply = if (s.once)
        try boolSwitch(allocator, fc, calls.is_bool, try fmt(allocator, "{s}Applied_{s}{s}", .{ added_prefix, stem, suffix }), mark_flag, following, mark)
    else
        mark;
    return boolSwitch(allocator, fc, calls.is_bool, try fmt(allocator, "{s}Got_{s}{s}", .{ added_prefix, stem, suffix }), got_flag, apply, following);
}

/// A switch on the pouch query: owns `pouch_actor` -> `when_owned`, else `when_not`.
fn pouchSwitch(allocator: Allocator, fc: *evfl.Flowchart, query: [2]u16, name: []const u8, pouch_actor: []const u8, when_owned: u16, when_not: u16) PatchError!u16 {
    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = case_owned, .event = when_owned }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = case_not_owned, .event = when_not }) catch return error.OutOfMemory;
    return fc.addEvent(allocator, .{ .name = name, .kind = .{ .switch_ = .{
        .actor = query[0],
        .query = query[1],
        .cases = cases,
        .params = try Container.from(allocator, &.{
            .{ .name = "Actor", .value = .{ .string = pouch_actor } },
            .{ .name = "Num", .value = .{ .int = 1 } },
        }),
    } } });
}

/// A switch on saved Bool `flag`: `when_true` (case 0) or `when_false` (case 1).
fn boolSwitch(allocator: Allocator, fc: *evfl.Flowchart, query: [2]u16, name: []const u8, flag: []const u8, when_true: u16, when_false: u16) PatchError!u16 {
    var cases: std.ArrayList(evfl.Case) = .empty;
    cases.append(allocator, .{ .value = case_true, .event = when_true }) catch return error.OutOfMemory;
    cases.append(allocator, .{ .value = case_false, .event = when_false }) catch return error.OutOfMemory;
    return fc.addEvent(allocator, .{ .name = name, .kind = .{ .switch_ = .{
        .actor = query[0],
        .query = query[1],
        .cases = cases,
        .params = try Container.from(allocator, &.{
            .{ .name = "GameDataName", .value = .{ .string = flag } },
            .{ .name = "Index", .value = .{ .int = -1 } },
        }),
    } } });
}

/// A test flow: ActionGuide's two hooked entries (a wait each), the Ocarina tutorial entry, and the actors the hook
/// uses.
fn testActionGuide(a: Allocator) ![]u8 {
    var fc = evfl.Flowchart{ .name = "ActionGuide" };
    for ([_][]const u8{ "GameSystemActor", "GameDataActor", pouch_actor_name, "UISystemActor" }) |name| {
        var actor = evfl.Actor{ .name = name, .params = try Container.create(a) };
        if (std.mem.eql(u8, name, "GameSystemActor")) try actor.actions.append(a, "EventWait");
        try fc.actors.append(a, actor);
    }
    const entries = [_][]const u8{ hooked_entries[0].name, hooked_entries[1].name, ocarina_tutorial_entry };
    for (entries, 0..) |entry, i| {
        _ = try fc.addEvent(a, evfl.makeAction(try std.fmt.allocPrint(a, "Event{d}", .{i}), .{ 0, 0 }, evfl.NONE, try Container.from(a, &.{.{ .name = "Frames", .value = .{ .int = 1 } }})));
        try fc.entry_points.append(a, .{ .name = entry, .main_event = @intCast(i) });
    }
    const doc = evfl.Document{ .name = "ActionGuide", .flowchart = &fc };
    return evfl.write(a, &doc);
}

test "the hook gives the next tier of a ground pickup, highest owned first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();
    const data = try testActionGuide(a);

    const strength = progressive.chainOfProgressiveItem("Progressive_Strength").?;
    const ocarina = progressive.chainOfProgressiveItem("Progressive_Ocarina").?;
    const strength_actors = [_][]const u8{ "Item_Gauntlet_Goron", "Item_Gauntlet_Silver", "Item_Gauntlet_Gold" };
    const ocarina_actors = [_][]const u8{ "Item_Ocarina_Fairy", "Item_Ocarina_Time" };
    const out = try addHook(a, data, &.{
        .{ .item = ocarina.ground_pickup_item, .line = ocarina, .once = false, .tier_actors = &ocarina_actors },
        .{ .item = strength.ground_pickup_item, .line = strength, .once = false, .tier_actors = &strength_actors },
    }, &progress);
    const result = (try evfl.read(a, out)).flowchart.?;
    const events = result.events.items;
    const entry = result.entry_points.items[0];

    // first: got the Progressive Ocarina? (the items in the order given)
    const got_ocarina = events[entry.main_event];
    try std.testing.expect(result.isQuery(&got_ocarina, "GameDataActor", "EventQueryIsGameDataBool"));
    try std.testing.expectEqualStrings("IsGet.Item_Prog_Ocarina", got_ocarina.params().?.getString("GameDataName").?);
    // not got -> the Strength check -> not got -> the entry's original wait
    const got_strength = events[got_ocarina.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("IsGet.Item_Prog_Strength", got_strength.params().?.getString("GameDataName").?);
    try std.testing.expectEqualStrings("Event0", events[got_strength.kind.switch_.cases.items[1].event].name);

    // got -> clear the flag -> held? -> remove -> own the Silver Gauntlets? (the highest check first)
    const clear = events[got_strength.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("IsGet.Item_Prog_Strength", clear.params().?.getString("GameDataName").?);
    try std.testing.expect(!clear.params().?.get("Value").?.bool);
    const held = events[clear.kind.action.next];
    try std.testing.expectEqualStrings("Item_Prog_Strength", held.params().?.getString("Actor").?);
    const remove = events[held.kind.switch_.cases.items[0].event];
    try std.testing.expectEqual(@as(i32, -1), remove.params().?.get("Num").?.int);
    const owns_silver = events[remove.kind.action.next];
    try std.testing.expectEqual(remove.kind.action.next, held.kind.switch_.cases.items[1].event);
    try std.testing.expectEqualStrings("Armor_Adult_Gauntlet_Silver", owns_silver.params().?.getString("Actor").?);
    const give_gold = events[owns_silver.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("Item_Gauntlet_Gold", give_gold.params().?.getString("Actor").?);
    const window_gold = events[give_gold.kind.action.next];
    try std.testing.expectEqualStrings(gift_window_entry, window_gold.kind.sub_flow.entry_point);
    try std.testing.expectEqualStrings("Item_Gauntlet_Gold", window_gold.params().?.getString("ActorName").?);
    const fade_in = events[window_gold.kind.sub_flow.next];
    try std.testing.expect(result.isAction(&fade_in, "UISystemActor", "EventEventFadeIn"));
    try std.testing.expectEqualStrings("Event0", events[fade_in.kind.action.next].name);
    const owns_bracelet = events[owns_silver.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Armor_Child_Gauntlet_Goron", owns_bracelet.params().?.getString("Actor").?);
    const give_bracelet = events[owns_bracelet.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Item_Gauntlet_Goron", give_bracelet.params().?.getString("Actor").?);

    // an Ocarina's window leads to its tutorial, then on to the Strength check
    const clear_ocarina = events[got_ocarina.kind.switch_.cases.items[0].event];
    const held_ocarina = events[clear_ocarina.kind.action.next];
    const owns_fairy = events[held_ocarina.kind.switch_.cases.items[1].event];
    const give_time = events[owns_fairy.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("Item_Ocarina_Time", give_time.params().?.getString("Actor").?);
    const tutorial = events[events[events[give_time.kind.action.next].kind.sub_flow.next].kind.action.next];
    try std.testing.expectEqualStrings(ocarina_tutorial_entry, tutorial.kind.sub_flow.entry_point);
    try std.testing.expectEqual(got_ocarina.kind.switch_.cases.items[1].event, tutorial.kind.sub_flow.next);

    // the entry lists every call it now reaches
    for (entry.sub_flow_events.items) |listed| try std.testing.expect(events[listed].kind == .sub_flow);
    try std.testing.expectEqual(@as(usize, 2 + 2 + 3), entry.sub_flow_events.items.len);
    // the shop entry has its own copy of the checks, ending in its own first event
    const shop_entry = result.entry_points.items[1];
    const shop_got = events[shop_entry.main_event];
    try std.testing.expect(std.mem.endsWith(u8, shop_got.name, "_Shop"));
    const shop_got_strength = events[shop_got.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("Event1", events[shop_got_strength.kind.switch_.cases.items[1].event].name);
}

test "a shelf's item is applied once, by its own flag, and keeps its IsGet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var progress = Progress.silent();
    const data = try testActionGuide(a);

    const hookshot = progressive.chainOfProgressiveItem("Progressive_Hookshot").?;
    const name = try shelfItemName(a, 1, hookshot);
    try std.testing.expectEqualStrings("Item_PS1_Hookshot", name);
    const actors = [_][]const u8{ "Item_Hookshot", "Item_Longshot" };
    const out = try addHook(a, data, &.{.{ .item = name, .line = hookshot, .once = true, .tier_actors = &actors }}, &progress);
    const result = (try evfl.read(a, out)).flowchart.?;
    const events = result.events.items;

    // got it? -> applied? yes -> the entry's first event; no -> mark applied (true) -> held? ...
    const got = events[result.entry_points.items[1].main_event];
    try std.testing.expectEqualStrings("IsGet.Item_PS1_Hookshot", got.params().?.getString("GameDataName").?);
    const applied = events[got.kind.switch_.cases.items[0].event];
    try std.testing.expectEqualStrings("RandoProgApplied.Item_PS1_Hookshot", applied.params().?.getString("GameDataName").?);
    try std.testing.expectEqualStrings("Event1", events[applied.kind.switch_.cases.items[0].event].name);
    const mark = events[applied.kind.switch_.cases.items[1].event];
    try std.testing.expectEqualStrings("RandoProgApplied.Item_PS1_Hookshot", mark.params().?.getString("GameDataName").?);
    try std.testing.expect(mark.params().?.get("Value").?.bool);
    const held = events[mark.kind.action.next];
    try std.testing.expectEqualStrings("Item_PS1_Hookshot", held.params().?.getString("Actor").?);
}

test "shelf item names stay short enough for the game" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (&progressive.chains) |*line| {
        const name = try shelfItemName(arena.allocator(), 999, line);
        try std.testing.expect(name.len <= pickups.max_key_item_name);
    }
}
