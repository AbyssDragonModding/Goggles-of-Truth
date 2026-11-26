//! The adult Master Sword pedestal works from Link's first trip to adult on, and Sheik stands aside from it.
//!
//! Read with the decrypted dump (Logic/Market_Adult_Prefab_89da.logic.module.ainb.txt, _7f43, Banc/Market/
//! Market_Adult_Static, AIScheduleParam/Npc_Hylia_Sheik_Adult):
//! - Putting the sword back (Market_Adult_Field_AdultToChild) is the pedestal's attention actor
//!   (Obj_TimeTemple_MasterSword_A_01_b347), which its logic module deletes until SageOfForest_IsCompleted_Exp: in the
//!   remake, adult Link can't go back to child until the Forest Temple is done. The randomizer's logic counts on
//!   changing age whenever Link has been adult (as in the original game and every OoT randomizer), so a seed could
//!   need a child check before the Forest Temple. The module's one flag becomes AllSage_IsAfter_Ready_Exp: true from
//!   the first arrival as adult on (AllSage:Market_Adult_AllSage_Start moves AllSage to Step01; an adult start sets
//!   it too).
//! - Sheik stands behind the pedestal with her arms folded (her default schedule) until she teaches the Prelude of
//!   Light (Market_Adult_GetLightPrelude deletes her, module _7f43). In the original game she and a working pedestal
//!   never meet, as the Prelude scene removes her when the pedestal comes back; with the pedestal working early, her
//!   talk prompt would sit on the sword's. She is moved to the doorway of the pedestal room, opposite the spot where
//!   Link arrives as adult (DestinationAnchor AdultStartPosition, mirrored across the room's middle, z = -34), with
//!   the two anchors she links to (AnchorAction1, AnchorAction2: in front of the pedestal; her schedule walks her
//!   back to them, so moving her alone left her there, test report). Nothing else links to them. Her talk (hints)
//!   and the Prelude scene are unchanged, so the Forest Temple and the Prelude play as before.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const ainb = @import("../formats/ainb.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const World = @import("../game/world.zig").World;
const PatchError = patchset.PatchError;

const pedestal_logic = "Logic/Market_Adult_Prefab_89da.logic.module.ainb";
const pedestal_flag_param = "GameDataNameBoolExp";
const pedestal_flag_old = "SageOfForest_IsCompleted_Exp";
const pedestal_flag_new = "AllSage_IsAfter_Ready_Exp";

const temple_placement = "Banc/Market/Market_Adult_Static.bcett.byml.zs";
/// Sheik and the anchors her schedule uses, each with its actor type, all moved to the same spot
const MovedActor = struct { hash: u64, gyaml: []const u8 };
const sheik_and_anchors = [_]MovedActor{
    .{ .hash = 0x250B05BD040DD847, .gyaml = "Npc_Hylia_Sheik_Adult" },
    .{ .hash = 0x2AC75CE579320040, .gyaml = "AnchorAction1" },
    .{ .hash = 0x7DA944BD4DC71802, .gyaml = "AnchorAction2" },
};
/// the pedestal room's doorway, across from AdultStartPosition (120.50, 105.68, -26.70)
const sheik_new_spot = [3]f64{ 120.5, 105.68, -41.3 };

/// Both edits; a warning (and false) for one this game doesn't match, which the generator reports.
pub fn patchAdultPedestal(world: *World, patches: *patchset.PatchSet, progress: *Progress) PatchError!bool {
    var ok = true;
    if (!world.files.exists(pedestal_logic)) {
        progress.log("warning: {s} not found; adult Link still can't go back to child before the Forest Temple", .{pedestal_logic});
        ok = false;
    } else {
        const orig = try patches.read(pedestal_logic);
        const r = try ainb.repointStringConst(patches.allocator, orig.data, pedestal_flag_param, pedestal_flag_old, pedestal_flag_new);
        if (r.count != 1) {
            progress.log("warning: the adult pedestal's check in {s} not recognised ({d} matches); left as it is", .{ pedestal_logic, r.count });
            ok = false;
        } else {
            try patches.emit(pedestal_logic, orig.data, r.data, null, false);
        }
    }
    if (!try moveSheikAside(patches, progress)) ok = false;
    return ok;
}

fn moveSheikAside(patches: *patchset.PatchSet, progress: *Progress) PatchError!bool {
    const a = patches.allocator;
    const orig = try patches.read(temple_placement);
    const root = byml.loadDict(a, orig.data) catch return error.InvalidData;
    const actors = root.getArray("Actors") orelse return error.InvalidData;
    var moved: usize = 0;
    for (actors.items.items) |v| {
        const actor = v.asDict() orelse continue;
        const h: u64 = @truncate(@as(u128, @bitCast(actor.getInt("Hash") orelse continue)));
        for (sheik_and_anchors) |wanted| {
            if (h != wanted.hash) continue;
            if (!std.mem.eql(u8, actor.getString("Gyaml") orelse "", wanted.gyaml)) continue;
            const translate = actor.getArray("Translate") orelse continue;
            if (translate.items.items.len != 3) continue;
            for (sheik_new_spot, 0..) |coordinate, i| translate.items.items[i] = .{ .float = @floatCast(coordinate) };
            moved += 1;
        }
    }
    // all three or none: Sheik moved without her anchors walks back to the pedestal
    if (moved != sheik_and_anchors.len) {
        progress.log("warning: Sheik's place in the Temple of Time not recognised; she stays by the pedestal", .{});
        return false;
    }
    try patches.emitZs(temple_placement, orig, try byml.dumpDefault(a, .{ .dict = root }));
    return true;
}
