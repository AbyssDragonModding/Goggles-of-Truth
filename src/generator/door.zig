//! Door of Time: Open.
//!
//! Ported from Clawshot (https://github.com/hiKareeem/Clawshot, src/clawshot/patch/door.py and patch/age.py), MIT
//! License, Copyright (c) 2026 Kareem Albaba and the Clawshot contributors.
//!
//! Setting Market_Child_TimeTempleDoor_Opened alone left the door shut (0.5.0 test seed 4): the door follows the Door of
//! Time quest, not that flag. Two edits open it:
//! - the door's logic module opens it from quest step Step06 on (after the stones and the Song of Time); its one
//!   "Step06" literal becomes "Ready", the quest's first step, so the door is open from the start. Same size, so its
//!   resource-size entry is unchanged;
//! - the child Master Sword pedestal's AI group (Market_Child_Static) used a module gated on that quest; it gets the
//!   ungated module Clawshot uses (from the Spirit Temple prefab), keeping the first-pull request and the sword.
//! Nothing is written to the save data.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const hash = @import("../core/hash.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;

const door_logic_rel = "Logic/Market_Common_f252.logic.module.ainb";
const door_logic_sha256 = "5b4152c4e56bf51b7f2400fbdd6a39e4b506f3104cee49a24f6f49e72eb4d6a4";
const placement = "Banc/Market/Market_Child_Static.bcett.byml.zs";
const draw_group: u64 = 11738513547087641325;
const draw_logic = "Logic/Module/Market_Child_Prefab/Market_Child_Prefab_e700.logic.module.ain";
const ungated_logic = "Logic/Module/SpiritTemple_Prefab/SpiritTemple_Prefab_5299.logic.module.ain";

const Binding = struct { id: []const u8, hash: u64, actor_type: []const u8 };
const draw_bindings = [_]Binding{
    .{ .id = "EventRequestActor_7fe2", .hash = 17385100471140562353, .actor_type = "EventRequestActor" },
    .{ .id = "EventRequestActor_0b2e", .hash = 2548516804884289836, .actor_type = "EventRequestActor" },
    .{ .id = "Obj_TimeTemple_MasterSword_A_01_e482", .hash = 1016238122178870176, .actor_type = "Obj_TimeTemple_MasterSword_A_01" },
};

fn doorLogic(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    const digest = hash.hexLower(hash.sha256(data));
    if (!std.mem.eql(u8, &digest, door_logic_sha256) or std.mem.count(u8, data, "Step06\x00") != 1) {
        return progress.fail(error.NotAsExpected, "the door's logic module is not the expected one", .{});
    }
    return std.mem.replaceOwned(u8, allocator, data, "Step06\x00", "Ready\x00\x00") catch error.OutOfMemory;
}

fn bindingOf(id: []const u8) ?Binding {
    for (draw_bindings) |b| if (std.mem.eql(u8, b.id, id)) return b;
    return null;
}

fn asU64(v: ?byml.Value) ?u64 {
    const n = (v orelse return null).asInt() orelse return null;
    return @truncate(@as(u128, @bitCast(n)));
}

fn openPedestal(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    const bad = "the child pedestal group is not as expected";
    const root = try byml.loadDict(allocator, data);
    var group: ?*byml.Dict = null;
    var found: usize = 0;
    if (root.getArray("AiGroups")) |groups| {
        for (groups.items.items) |g| {
            const d = g.asDict() orelse continue;
            if (asU64(d.get("Hash")) == draw_group) {
                group = d;
                found += 1;
            }
        }
    }
    if (found != 1 or !std.mem.eql(u8, group.?.getString("Logic") orelse "", draw_logic)) return progress.fail(error.NotAsExpected, bad, .{});
    const g = group.?;
    const refs = g.getArray("References") orelse return progress.fail(error.NotAsExpected, "the child pedestal references are not as expected", .{});
    if (refs.len() != draw_bindings.len) return progress.fail(error.NotAsExpected, "the child pedestal references are not as expected", .{});
    for (draw_bindings) |b| {
        var present = false;
        for (refs.items.items) |r| if (r.asDict()) |d| if (std.mem.eql(u8, d.getString("Id") orelse "", b.id)) {
            present = true;
        };
        if (!present) return progress.fail(error.NotAsExpected, "the child pedestal references are not as expected", .{});
    }
    const actors = root.getArray("Actors") orelse return progress.fail(error.NotAsExpected, bad, .{});
    for (refs.items.items) |r| {
        const ref = r.asDict() orelse return progress.fail(error.NotAsExpected, bad, .{});
        const id = ref.getString("Id").?;
        const b = bindingOf(id) orelse return progress.fail(error.NotAsExpected, bad, .{});
        var actor: ?*byml.Dict = null;
        var count: usize = 0;
        for (actors.items.items) |v| {
            const d = v.asDict() orelse continue;
            if ((asU64(d.get("Hash")) orelse 0) == b.hash) {
                actor = d;
                count += 1;
            }
        }
        if (!std.mem.eql(u8, ref.getString("Path") orelse "", id) or asU64(ref.get("Reference")) != b.hash or count != 1 or
            !std.mem.eql(u8, actor.?.getString("Gyaml") orelse "", b.actor_type))
        {
            return progress.fail(error.NotAsExpected, "the child pedestal actor {s} is not as expected", .{id});
        }
        if (std.mem.eql(u8, id, "EventRequestActor_7fe2")) {
            const dyn = actor.?.getDict("Dynamic");
            const ev = if (dyn) |d| d.getString("RequestEventName") orelse "" else "";
            if (!std.mem.eql(u8, ev, "Market_Child_DoorOfTime_Draw")) return progress.fail(error.NotAsExpected, "the first-pull request is not as expected", .{});
        }
    }
    try g.put(allocator, "Logic", .{ .string = ungated_logic });
    const new_refs = try byml.Array.create(allocator);
    for (refs.items.items) |r| {
        const id = r.dict.getString("Id").?;
        if (std.mem.eql(u8, id, "EventRequestActor_0b2e")) continue;
        const copy = (try r.clone(allocator)).dict;
        try copy.put(allocator, "Id", .{ .string = if (std.mem.eql(u8, id, "EventRequestActor_7fe2")) "EventRequestActor_7a32" else "CheckAttentionActor_8348" });
        try new_refs.append(allocator, .{ .dict = copy });
    }
    try g.put(allocator, "References", .{ .array = new_refs });
    return byml.dumpDefault(allocator, .{ .dict = root });
}

/// True when both edits were made.
pub fn patchOpenDoor(patches: *patchset.PatchSet, progress: *Progress) PatchError!bool {
    const a = patches.allocator;
    const logic_file = patches.read(door_logic_rel) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            progress.log("warning: Door of Time not opened ({s} couldn't be read)", .{door_logic_rel});
            return false;
        },
    };
    const new_logic = doorLogic(a, logic_file.data, progress) catch |err| switch (err) {
        error.NotAsExpected => {
            progress.log("warning: Door of Time not opened ({s})", .{progress.failureMessage()});
            return false;
        },
        else => return err,
    };
    const orig = try patches.read(placement);
    const new_placement = openPedestal(a, orig.data, progress) catch |err| switch (err) {
        error.NotAsExpected => {
            progress.log("warning: Door of Time not opened ({s})", .{progress.failureMessage()});
            return false;
        },
        else => return err,
    };
    try patches.emit(door_logic_rel, logic_file.data, new_logic, null, false);
    try patches.emitZs(placement, orig, new_placement);
    progress.log("Door of Time: Open (door logic and Master Sword pedestal changed)", .{});
    return true;
}
