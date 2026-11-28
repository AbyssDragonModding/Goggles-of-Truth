//! The Lake Hylia tree's vines take the Longshot once the Longshot is owned, wherever it was found.
//!
//! Why: an invisible wall that only blocks the Hookshot and Longshot (FldObj_AirWall_Hookshot, in Hyrule Field's
//! child and adult stage files at the Lake Hylia tree) is there while WaterTemple_Room07_00 is false (its Presence,
//! IsNegation). The game sets that flag when the Water Temple's Longshot chest is opened
//! (Logic/WaterTemple_Level_Room_07_Prefab_aa21: ActorLogicTreasureBox Obj_TBox_A_02_07f0 -> TriggerGameDataSetBoolTrue),
//! so with the Longshot found anywhere else the vines never latched (report from another randomizer's developer: the
//! Lake Hylia tree Gold Skulltula; a save latches with only that flag turned on, and doesn't with only it off).
//!
//! The wall's Presence now reads the Longshot's own saved IsGet flag instead (the flag the game sets whenever the
//! Longshot reaches the pouch, as bought shop shelves use theirs), so it goes when the Longshot is got from any spot,
//! and stays for a player who only has the Hookshot, as the game intends. Not setting WaterTemple_Room07_00 at the
//! start: it also moves the Water Temple room's dungeon progress (TriggerDungeonRoomStepForward). The flag is left
//! as it is, so opening the Longshot chest still does what it did. Not tested in-game yet.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const PatchError = patchset.PatchError;
const PatchSet = patchset.PatchSet;
const World = world_mod.World;

/// the stage files with the wall (child and adult Hyrule Field, which holds Lake Hylia)
const stage_files = [_][]const u8{
    "Banc/HyruleField/HyruleField_Child_Dynamic.bcett.byml.zs",
    "Banc/HyruleField/HyruleField_Adult_Dynamic.bcett.byml.zs",
};
const wall_actor = "FldObj_AirWall_Hookshot";
/// the game's condition: set by opening the Water Temple's Longshot chest
const longshot_chest_flag = "WaterTemple_Room07_00";
/// the condition it gets: the Longshot owned
const longshot_owned_flag = "IsGet.Item_Longshot";

/// Points each wall's Presence at the Longshot's IsGet flag. Returns how many walls were changed (one per stage file;
/// a note when one isn't found, as the game files may differ).
pub fn patch(world: *World, patches: *PatchSet, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    var changed: usize = 0;
    for (stage_files) |rel| {
        if (!world.files.exists(rel)) continue;
        const orig = try patches.read(rel);
        const root = byml.loadDict(a, orig.data) catch return error.InvalidData;
        const actors = root.getArray("Actors") orelse return error.InvalidData;
        var in_file: usize = 0;
        for (actors.items.items) |value| {
            const actor = value.asDict() orelse continue;
            if (!std.mem.eql(u8, actor.getString("Gyaml") orelse "", wall_actor)) continue;
            const presence = actor.getDict("Presence") orelse continue;
            if (!std.mem.eql(u8, presence.getString("FlagName") orelse "", longshot_chest_flag)) continue;
            // IsNegation stays true: the wall is there while the Longshot is NOT owned
            try presence.put(a, "FlagName", .{ .string = longshot_owned_flag });
            in_file += 1;
        }
        if (in_file == 0) {
            progress.log("note: no Longshot wall at the Lake Hylia tree in {s}; left as it is", .{rel});
            continue;
        }
        try patches.emitZs(rel, orig, try byml.dumpDefault(a, .{ .dict = root }));
        changed += in_file;
    }
    return changed;
}
