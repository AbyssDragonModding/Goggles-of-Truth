//! Edits to the default save data (GameData/GameDataList), applied when a new file is started.
//!
//! GameData entries are keyed by MurmurHash3 (seed 0) of the flag name, e.g.
//! "KokiriForest_Npc_Kokiri_007_Child_Blocker_00". Plain Bool/Int defaults are changed directly; computed BoolExp
//! flags are formulas over other flags ([opcode, hash] lists in reverse Polish order).

const std = @import("std");
const byml = @import("../formats/byml.zig");
const hash = @import("../core/hash.zig");
const settings_mod = @import("../settings/settings.zig");
const world_mod = @import("../game/world.zig");
const logic = @import("../logic/logic.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const Settings = settings_mod.Settings;
const PatchError = patchset.PatchError;

const mm3 = hash.mm3;

// ---- opening flags
/// Kokiri boy at the forest exit
pub const forest_exit = "KokiriForest_Npc_Kokiri_007_Child_Blocker_00";
/// Mido in front of the Deku Tree
pub const forest_mido = "KokiriForest_Npc_Kokiri_Mido_Child_Blocker";
/// King Zora reads Ruto's letter and moves
pub const zora_open = [_][]const u8{ "HavePlayedEvent.Dm_Zora_0010", "Get_StoneOfWater_ReadRutoLetter", "Get_StoneOfWater_TalkedZoraAboutRutoLetter" };
/// King Zora's position and talk follow the Zora quest, not those flags: his pack reads
/// Get_StoneOfWater_IsAfter_Step06_Exp, and showing him the letter moves the quest to Step07 before Dm_Zora_0010.
pub const zora_open_quest_exp = "Get_StoneOfWater_IsAfter_Step06_Exp";
pub const zora_open_quest_step = "Step07";
/// Door of Time: Open (door.zig) opens the door from quest step Ready on. A new save starts the quest at NotReady,
/// so the door stayed shut for a player who went straight to the Temple of Time (0.5.0 test seed 5).
pub const door_quest_enum = "Step_DoorOfTime";
pub const door_quest_step = "Ready";
/// The door's own saved flag, set when the Song of Time opens it (DoorOfTime Event53); the door's logic module opens it
/// for this flag OR the quest step (Logic/Market_Common_f252: OperateORFixInputTrue). The quest step alone didn't do:
/// the DoorOfTime quest only runs once Goto_HyruleCastle is complete (RSDB Challenge DependFlagName), so with Zelda not
/// met yet the door stayed shut (0.8.3 test report: "check Zelda, this will allow the door to open"). The adult start
/// already set it.
pub const door_opened_flag = "Market_Child_TimeTempleDoor_Opened";
/// The Kakariko gate soldier sets this when shown Zelda's Letter.
pub const dmt_gate_open = "Npc_Hylia_Soldier_003_GateOpen";
/// Skip Epona Race: a horse is yours when its actor is in OwnedHorseList.ActorName (entry 0, as Ingo's race leaves
/// it). The game reads the list when a save loads, so the new save starts with it.
pub const epona_owned_list = "OwnedHorseList.ActorName";
pub const epona_actor = "Animal_Epona_Adult";

const QuestStep = struct { exp: []const u8, step: []const u8 };

/// Skip Child Zelda: quest progress is an Enum per challenge (found through a computed flag that reads it).
pub const skip_zelda_quests = [_]QuestStep{
    .{ .exp = "Goto_HyruleCastle_IsCompleted_Exp", .step = "Complete" },
    .{ .exp = "DoorOfTime_IsAfter_Step02_Exp", .step = "Step02" },
    .{ .exp = "Get_StoneOfFire_IsCompleted_Exp", .step = "KakarikoVillageNpc" },
};
/// ...and the quest's scenes count as already seen, so none of them (or the step it would set) plays later.
pub const skip_zelda_played = [_][]const u8{
    "Goto_HyruleCastle_EntryMarket", "HyruleCastle_Goto_HyruleCastle_MeetZelda", "Dm_HrlField_0000", "Dm_HrlField_0005",
    "Dm_HrlField_0010",              "Dm_HrlCastle_0005",                        "Dm_HrlCastle_0020", "Dm_HrlCastle_0030",
    "Dm_HrlCastle_0035",             "Dm_HrlCastle_0045",                        "Dm_HrlCastle_0050", "Dm_HrlCastle_0060",
    "Dm_MelodyGet_Zelda",            "Dm_HrlField_0020",
};
/// What Kaepora's flow sets on the way: the quest menu opens, the field entrance counts as reached, and the amiibo
/// pouch entry is handed out.
pub const skip_zelda_flags = [_][]const u8{ "UI_IsFinishChallengeMenuOpenEvent", "HyruleField_ArriveEntrance" };
pub const skip_zelda_items = [_][]const u8{"Pouch_Amiibo"};
/// Skip Kaepora Gaebora: his forced first talks, each started only while HavePlayedEvent.<scene> is False.
pub const kaepora_scenes = [_][]const u8{
    "Dm_LostWood_0000", "Dm_LostWood_0010", "Dm_HrlField_0000", "Dm_HrlField_0005", "Dm_HrlField_0010", "Dm_HrlField_0030",
    "Dm_HrlField_0040", "Dm_HrlField_0050", "Dm_HrlCastle_0000", "Dm_ZoraRiver_0000", "Dm_ZoraRiver_0005",
};
/// His first talk also moves Goto_HyruleCastle to Step02; the Market's entry event only fires at exactly that step.
pub const kaepora_quest = QuestStep{ .exp = "Goto_HyruleCastle_IsCompleted_Exp", .step = "Step02" };
/// Skip Saria's opening scene: her wake-up and walk count as seen, the door and talk flags she sets are on, and
/// the area banner's visit flag is on so the pause map still works.
pub const saria_intro = [_][]const u8{
    "HavePlayedEvent.Dm_Kokiri_0045", "HavePlayedEvent.Dm_Kokiri_0050", "HavePlayedEvent.Dm_Kokiri_0060",
    "KokiriForest_LinkHouseDoor_Open", "HaveTalked.Npc_Kokiri_Saria_Child", "IsVisitLocation.KokiriForest",
};
/// Skip the Great Deku Tree's Talk with Mido gone (Open Forest): the state his arrival talk leaves.
pub const deku_tree_talk_flags = [_][]const u8{ "HavePlayedEvent.Dm_Kokiri_0070", "KokiriForest_Meet_DekuTree_OpenDekuTreeMouth" };
const EnumStep = struct { name: []const u8, value: []const u8 };
pub const deku_tree_talk_steps = [_]EnumStep{
    .{ .name = "Step_Meet_DekuTree", .value = "Complete" },
    .{ .name = "Step_Get_StoneOfForest", .value = "GoInside" },
};

pub const pouch_struct = "PouchData";

/// Dungeon map / compass ownership: DungeonInfo.<dungeon>.IsGetMap / .IsGetCompass
pub const map_dungeons = [_][]const u8{
    "InsideTheDekuTree", "DodongoCavern", "InsideJabuJabuBelly", "ForestTemple",    "FireTemple",
    "WaterTemple",       "ShadowTemple",  "SpiritTemple",        "BottomOfTheWell", "IceCavern",
};

/// Saria's Song: the meadow trigger normally checks DoorOfTime_IsAfter_Step01_Exp (met Zelda). A new computed flag
/// "owns an ocarina" replaces that check (qol.patchSariaSong).
pub const saria_gate_old = "DoorOfTime_IsAfter_Step01_Exp";
pub const saria_gate_new = "Rando_HasOcarina_Exp";
pub const ocarina_flags = [_][]const u8{ "IsGet.Item_Ocarina_Fairy", "IsGet.Item_Ocarina_Time" };

/// First-arrival intro scenes whose arrival entry does nothing else (no quest step, flag or sub-flow): their "played"
/// flag only feeds the entrance check. (The others are skipped inside their arrival flow: storyskip.zig.)
pub const area_intros = [_][]const u8{
    "Dm_LakeHrl_0000",  "Dm_ZoraFountain_0000", "Dm_GanonCastle_0000", "Dm_LostWood_0010",   "Dm_Kakariko_0000",
    "Dm_Graveyard_0000", "Dm_HrlCastle_0000",   "Dm_Gerudo_0000",      "Dm_GerudoValley_0000", "Goto_ZoraRiver",
    "Goto_KakarikoWells", "Goto_FireTemple",    "Goto_SpritTemple",
};
/// Those intros are also where their areas are first "visited" (each opens its area's name banner), so skipping
/// them marks the areas as visited.
pub const area_intro_visits = [_][]const u8{
    "LakeHylia",    "ZoraFountain", "GanonCastle",  "KakarikoVillage", "Graveyard",  "HyruleCastle",
    "GerudoFortress", "GerudoValley", "ZoraRiver", "BottomOfTheWell", "FireTemple", "SpiritTemple",
};

// ---- Rainbow Bridge Requirement (GameDataPatcher.rainbowBridge)
pub const bridge_medallions = [_][]const u8{
    "IsGet.Item_Medal_Forest", "IsGet.Item_Medal_Fire", "IsGet.Item_Medal_Water",
    "IsGet.Item_Medal_Shadow", "IsGet.Item_Medal_Spirit", "IsGet.Item_Medal_Light",
};
pub const bridge_stones = [_][]const u8{ "IsGet.Item_Stone_Forest", "IsGet.Item_Stone_Fire", "IsGet.Item_Stone_Water" };
pub const bridge_bow = "IsGet.Weapon_Range_Bow";
pub const bridge_light_arrows = "IsGet.Item_Arrow_Light";
pub const token_count = "PouchData.Item_Token_Gold.StockNum";
/// the castle quest's own "past Step01" check
pub const bridge_quest_exp = "Defeat_Ganon_IsAfter_Step01_Exp";
/// the requirement + Bow + Light Arrows
pub const bridge_exp = "Rando_Bridge_Exp";
/// counted into by the altar's status line (bridgetext.zig)
/// the altar's counts: the requirement, the Bow, the Light Arrows, and a second requirement (All Tokens, Medallions &
/// Stones: its tokens)
pub const bridge_status_ints = [_][]const u8{ "Rando_Bridge_Count", "Rando_Bridge_Bow", "Rando_Bridge_LightArrows", "Rando_Bridge_Count2" };

/// What a Rainbow Bridge Requirement asks for (its Random rolled before, settings/randomize.zig): a Medallion count,
/// all three Spiritual Stones, a token count, or several at once (the "All" requirements). Null parts aren't asked.
pub const BridgeNeeds = struct {
    medallions: ?i64 = null,
    stones: bool = false,
    tokens: ?i64 = null,

    pub fn of(mode: []const u8, medallion_count: i64, tokens_needed: i64) BridgeNeeds {
        const all_tokens: i64 = 100;
        if (std.mem.eql(u8, mode, "medallions")) return .{ .medallions = medallion_count };
        if (std.mem.eql(u8, mode, "stones")) return .{ .stones = true };
        if (std.mem.eql(u8, mode, "tokens")) return .{ .tokens = tokens_needed };
        if (std.mem.eql(u8, mode, "all_tokens")) return .{ .tokens = all_tokens };
        if (std.mem.eql(u8, mode, "rewards")) return .{ .medallions = 6, .stones = true };
        if (std.mem.eql(u8, mode, "everything")) return .{ .medallions = 6, .stones = true, .tokens = all_tokens };
        return .{};
    }

    pub fn any(self: BridgeNeeds) bool {
        return self.medallions != null or self.stones or self.tokens != null;
    }
};
/// the longest computed flag in the game
pub const bridge_max_entries = 26;

/// Skip Ganon's Trials: each trial's barrier flag and its scene's played flag.
pub const ganon_trials = [_][]const u8{ "Forest", "Fire", "Water", "Shadow", "Spirit", "Light" };

// ------------------------------------------------------------------------------------------- the patcher

/// A save flag's kind, as GameDataList groups its rows.
pub const RowKind = enum { Bool, BoolExp, Int, Enum, Struct, String64Array, other };

const Row = struct {
    kind: RowKind,
    kind_name: []const u8,
    row: *byml.Dict,
};

fn rowKind(name: []const u8) RowKind {
    return std.meta.stringToEnum(RowKind, name) orelse .other;
}

pub const GameDataPatcher = struct {
    allocator: Allocator,
    progress: *Progress,
    rel: []const u8,
    original: []const u8,
    dictionary: ?[]const u8,
    version: u16,
    big_endian: bool,
    root: *byml.Dict,
    index: std.AutoHashMap(u64, Row),
    changed: usize = 0,

    const Self = @This();

    /// Reads the save data's defaults (`original`: GameData/GameDataList, decompressed). Allocate with an arena.
    pub fn init(allocator: Allocator, rel: []const u8, original: []const u8, dictionary: ?[]const u8, progress: *Progress) PatchError!Self {
        const doc = try byml.load(allocator, original);
        const root = (doc.root orelse return error.InvalidData).asDict() orelse return error.InvalidData;
        var self = Self{
            .allocator = allocator,
            .progress = progress,
            .rel = rel,
            .original = original,
            .dictionary = dictionary,
            .version = doc.version,
            .big_endian = doc.big_endian,
            .root = root,
            .index = std.AutoHashMap(u64, Row).init(allocator),
        };
        const data = root.getDict("Data") orelse return error.InvalidData;
        for (data.entries.items) |kind_entry| {
            const rows = kind_entry.value.asArray() orelse continue;
            for (rows.items.items) |r| {
                const row = r.asDict() orelse continue;
                const h = row.getInt("Hash") orelse continue;
                self.index.put(@truncate(@as(u128, @bitCast(h))), Row{ .kind = rowKind(kind_entry.key), .kind_name = kind_entry.key, .row = row }) catch return error.OutOfMemory;
            }
        }
        return self;
    }

    fn lookup(self: *const Self, name: []const u8) ?Row {
        return self.index.get(mm3(name));
    }

    /// The row of flag `name` if it is of kind `kind`; a warning otherwise.
    fn get(self: *Self, name: []const u8, kind: RowKind) ?*byml.Dict {
        const hit = self.lookup(name);
        if (hit == null or hit.?.kind != kind) {
            self.progress.log("warning: save flag {s} not found as {s}; skipped", .{ name, @tagName(kind) });
            return null;
        }
        return hit.?.row;
    }

    /// Like get, without the warning.
    fn find(self: *const Self, name: []const u8, kind: RowKind) ?*byml.Dict {
        const hit = self.lookup(name) orelse return null;
        return if (hit.kind == kind) hit.row else null;
    }

    pub fn hasFlag(self: *const Self, name: []const u8) bool {
        return self.lookup(name) != null;
    }

    /// The kind of save flag `name`, or null when the save data has no such flag (test plans check their flags).
    pub fn flagKind(self: *const Self, name: []const u8) ?RowKind {
        const hit = self.lookup(name) orelse return null;
        return hit.kind;
    }

    /// The value names of Enum flag `name` ("NotReady", "Ready", "Step01"... for a quest's Step_<quest>), or null when
    /// there is no such Enum.
    pub fn enumValueNames(self: *const Self, name: []const u8) ?[]const byml.Value {
        const row = self.find(name, .Enum) orelse return null;
        const raw = row.getArray("RawValues") orelse return null;
        return raw.items.items;
    }

    pub fn isBool(self: *const Self, name: []const u8) bool {
        return self.find(name, .Bool) != null;
    }

    pub fn setBool(self: *Self, name: []const u8, value: bool) PatchError!bool {
        const row = self.get(name, .Bool) orelse return false;
        const current = if (row.get("DefaultValue")) |v| v.isTruthy() else false;
        if (current != value) {
            try row.put(self.allocator, "DefaultValue", .{ .bool = value });
            self.changed += 1;
        }
        return true;
    }

    /// Starts String64Array `name` at `value` (an array row has one DefaultValue for all its entries).
    pub fn setStringArray(self: *Self, name: []const u8, value: []const u8) PatchError!bool {
        const row = self.get(name, .String64Array) orelse return false;
        const current = row.getString("DefaultValue") orelse "";
        if (!std.mem.eql(u8, current, value)) {
            try row.put(self.allocator, "DefaultValue", .{ .string = value });
            self.changed += 1;
        }
        return true;
    }

    pub fn setInt(self: *Self, name: []const u8, value: i64) PatchError!bool {
        const row = self.get(name, .Int) orelse return false;
        const current = row.get("DefaultValue") orelse byml.Value{ .int = 0 };
        if ((current.asInt() orelse 0) != value) {
            try row.put(self.allocator, "DefaultValue", current.sameIntType(value));
            self.changed += 1;
        }
        return true;
    }

    /// The first value pair of a computed flag (its element types are copied for new entries).
    fn template(row: *byml.Dict) ?*byml.Array {
        const values = row.getArray("Values") orelse return null;
        if (values.items.items.len == 0) return null;
        return values.items.items[0].asArray();
    }

    /// One [opcode, value] (or [opcode]) entry, with the element types of the template entry.
    fn entry(self: *Self, tmpl: *byml.Array, op: i64, value: ?byml.Value) PatchError!byml.Value {
        const a = try byml.Array.create(self.allocator);
        const op_type = tmpl.items.items[0];
        try a.append(self.allocator, op_type.sameIntType(op));
        if (value) |v| try a.append(self.allocator, v);
        return byml.Value{ .array = a };
    }

    /// A flag hash as a formula value. The game's formulas use one integer type for opcodes and hashes alike (the
    /// Python version took both from the first opcode), so the opcode's type is used.
    fn hashValue(tmpl: *byml.Array, name: []const u8) byml.Value {
        return tmpl.items.items[0].sameIntType(mm3(name));
    }

    /// Adds (or replaces) computed flag `name` = `values`, shaped like the template row's.
    fn putExp(self: *Self, shape: *byml.Dict, name: []const u8, values: []const byml.Value) PatchError!void {
        if (values.len > bridge_max_entries) return error.NotAsExpected;
        const list = try byml.Array.create(self.allocator);
        for (values) |v| try list.append(self.allocator, v);
        const h = mm3(name);
        if (self.index.get(h)) |hit| {
            try hit.row.put(self.allocator, "Values", .{ .array = list });
            return;
        }
        const row = try byml.Dict.create(self.allocator);
        try row.put(self.allocator, "Hash", (shape.get("Hash") orelse byml.Value{ .uint = 0 }).sameIntType(h));
        if (shape.get("ResetTypeValue")) |v| try row.put(self.allocator, "ResetTypeValue", v);
        if (shape.get("SaveFileIndex")) |v| try row.put(self.allocator, "SaveFileIndex", v);
        try row.put(self.allocator, "Values", .{ .array = list });
        const data = self.root.getDict("Data") orelse return error.InvalidData;
        const rows = data.getArray("BoolExp") orelse return error.InvalidData;
        try rows.append(self.allocator, .{ .dict = row });
        self.index.put(h, Row{ .kind = .BoolExp, .kind_name = "BoolExp", .row = row }) catch return error.OutOfMemory;
    }

    /// Rainbow Bridge Requirement. Logic/GanonCastle_Level_Field_00_Prefab (its multi-input links decoded):
    ///     areas Area_2dac / Area_99ec and the appear point exist while  Ready_Exp AND NOT Step01_Exp
    ///     the bridge scene (GanonCastle_Adult_Field_Rainbow) starts when Link is in both areas
    ///     the bridge exists when that scene has played, or once it sets its EventBoolEX1
    /// "IsAfter_X" means past step X. Zelda's Light Arrows scene (AllSage) sets Step01, so Ready_Exp turns on; the
    /// bridge scene sets Step02, so Step01_Exp turns the areas off again. So the requirement is OR-ed into Ready_Exp
    /// only; Step01_Exp stays the quest's own (0.6.1's first version replaced it: no bridge in-game).
    ///
    /// Computed flags are reverse Polish over [opcode, value]: 0 reads a Bool, 10 reads another computed flag, 3 AND,
    /// 4 OR, 5 NOT, 18 reads an Int and compares it "less than" the next constant (16), so "at least N" is
    /// NOT(Int < N). The game's own computed flags are at most 26 entries long; 0.6.1's first "3 of 6 medallions" was
    /// one flag of 123 entries and never came true in-game. So every flag here stays short, and the count is a
    /// chain of small flags:
    ///     Rando_Bridge_Medals_<k>_<i> = at least k of the first i medallions
    ///                                = <k of i-1> OR (<k-1 of i-1> AND medallion i)          (5 entries)
    ///     Rando_Bridge_Exp            = requirement AND Bow AND Light Arrows
    ///     Defeat_Ganon_IsAfter_Ready_Exp = its old value OR Rando_Bridge_Exp
    /// The bridge appears when every part of `needs` holds (an "All" requirement asks for several: each part's
    /// check, AND-ed together), and the Bow and the Light Arrows.
    pub fn rainbowBridge(self: *Self, needs: BridgeNeeds) PatchError!bool {
        const step01 = self.get("Defeat_Ganon_IsAfter_Step01_Exp", .BoolExp) orelse return false;
        const ready = self.get("Defeat_Ganon_IsAfter_Ready_Exp", .BoolExp) orelse return false;
        if (!needs.any()) return true;
        const tmpl = template(step01) orelse return error.InvalidData;

        // every flag it reads must exist
        var missing: std.ArrayList(u8) = .empty;
        const need_common = [_][]const u8{ bridge_bow, bridge_light_arrows };
        for (need_common) |f| if (self.find(f, .Bool) == null) try appendName(&missing, self.allocator, f);
        if (needs.medallions != null) for (bridge_medallions) |f| if (self.find(f, .Bool) == null) try appendName(&missing, self.allocator, f);
        if (needs.stones) for (bridge_stones) |f| if (self.find(f, .Bool) == null) try appendName(&missing, self.allocator, f);
        if (needs.tokens != null and self.find(token_count, .Int) == null) try appendName(&missing, self.allocator, token_count);
        if (missing.items.len > 0) {
            self.progress.log("warning: Rainbow Bridge: save flags not found ({s}); the bridge is left as it is", .{missing.items});
            return false;
        }

        var cond: std.ArrayList(byml.Value) = .empty;
        var parts: usize = 0;
        if (needs.medallions) |medallions| {
            parts += 1;
            const n: usize = @intCast(std.math.clamp(medallions, 1, 6));
            // ref[k][i]: the computed flag holding "at least k of the first i medallions"
            var ref: [7][7]?byml.Value = @splat(@splat(null));
            var i: usize = 1;
            while (i <= 6) : (i += 1) {
                const m = try self.have(step01, tmpl, bridge_medallions[i - 1]);
                var k: usize = 1;
                while (k <= @min(i, n)) : (k += 1) {
                    const name = std.fmt.allocPrint(self.allocator, "Rando_Bridge_Medals_{d}_{d}", .{ k, i }) catch return error.OutOfMemory;
                    var values: std.ArrayList(byml.Value) = .empty;
                    if (k == i) {
                        // all of the first i
                        if (k > 1) {
                            try appendValue(&values, self.allocator, ref[k - 1][i - 1].?);
                            try appendValue(&values, self.allocator, m);
                            try appendValue(&values, self.allocator, try self.entry(tmpl, 3, null));
                        } else {
                            try appendValue(&values, self.allocator, m);
                        }
                    } else if (k == 1) {
                        // any of the first i
                        try appendValue(&values, self.allocator, ref[1][i - 1].?);
                        try appendValue(&values, self.allocator, m);
                        try appendValue(&values, self.allocator, try self.entry(tmpl, 4, null));
                    } else {
                        try appendValue(&values, self.allocator, ref[k][i - 1].?);
                        try appendValue(&values, self.allocator, ref[k - 1][i - 1].?);
                        try appendValue(&values, self.allocator, m);
                        try appendValue(&values, self.allocator, try self.entry(tmpl, 3, null));
                        try appendValue(&values, self.allocator, try self.entry(tmpl, 4, null));
                    }
                    try self.putExp(step01, name, values.items);
                    ref[k][i] = try self.expRef(tmpl, name);
                }
            }
            try appendValue(&cond, self.allocator, ref[n][6].?);
        }
        if (needs.stones) {
            const a = try self.have(step01, tmpl, bridge_stones[0]);
            const b = try self.have(step01, tmpl, bridge_stones[1]);
            const c = try self.have(step01, tmpl, bridge_stones[2]);
            for ([_]byml.Value{ a, b, try self.entry(tmpl, 3, null), c, try self.entry(tmpl, 3, null) }) |v| try appendValue(&cond, self.allocator, v);
            // AND-ed with the part before (opcode 3), as the Bow and the Light Arrows are below
            if (parts > 0) try appendValue(&cond, self.allocator, try self.entry(tmpl, 3, null));
            parts += 1;
        }
        if (needs.tokens) |tokens| {
            // Opcode 16's number is a plain signed Int in the game's own flags ([16, 100] in ..._Collect100Tokens), not
            // the U64 of the other entries. 0.6.1's token bridge wrote a U64 and the bridge was there with 0 tokens.
            try appendValue(&cond, self.allocator, try self.entry(tmpl, 18, hashValue(tmpl, token_count)));
            try appendValue(&cond, self.allocator, try self.entry(tmpl, 16, .{ .int = @intCast(tokens) }));
            try appendValue(&cond, self.allocator, try self.entry(tmpl, 5, null));
            if (parts > 0) try appendValue(&cond, self.allocator, try self.entry(tmpl, 3, null));
            parts += 1;
        }
        try appendValue(&cond, self.allocator, try self.have(step01, tmpl, bridge_bow));
        try appendValue(&cond, self.allocator, try self.entry(tmpl, 3, null));
        try appendValue(&cond, self.allocator, try self.have(step01, tmpl, bridge_light_arrows));
        try appendValue(&cond, self.allocator, try self.entry(tmpl, 3, null));
        try self.putExp(step01, bridge_exp, cond.items);

        // Ready_Exp = its old value OR the requirement
        const old = ready.getArray("Values") orelse return error.InvalidData;
        const values = try byml.Array.create(self.allocator);
        for (old.items.items) |v| try values.append(self.allocator, try v.clone(self.allocator));
        try values.append(self.allocator, try self.expRef(tmpl, bridge_exp));
        try values.append(self.allocator, try self.entry(tmpl, 4, null));
        try ready.put(self.allocator, "Values", .{ .array = values });

        // the Temple of Time altar's status line counts into these (bridgetext.zig); not saved
        for (bridge_status_ints) |name| try self.addTempInt(name);
        self.changed += 1;
        return true;
    }

    fn expRef(self: *Self, tmpl: *byml.Array, name: []const u8) PatchError!byml.Value {
        return self.entry(tmpl, 10, hashValue(tmpl, name));
    }

    fn flagRef(self: *Self, tmpl: *byml.Array, name: []const u8) PatchError!byml.Value {
        return self.entry(tmpl, 0, hashValue(tmpl, name));
    }

    /// Owning item `IsGet.<item>`: its "got it" flag OR its pouch count above 0 (items given by a debug menu fill the
    /// pouch without the flag; the game's own "at least one" reads are `Int > 0`, opcode 19). One small computed
    /// flag per item, read with opcode 10.
    fn have(self: *Self, shape: *byml.Dict, tmpl: *byml.Array, name: []const u8) PatchError!byml.Value {
        const item = name[(std.mem.indexOfScalar(u8, name, '.') orelse return error.InvalidData) + 1 ..];
        const count = std.fmt.allocPrint(self.allocator, "PouchData.{s}.StockNum", .{item}) catch return error.OutOfMemory;
        if (self.find(count, .Int) == null) return self.flagRef(tmpl, name);
        const helper = std.fmt.allocPrint(self.allocator, "Rando_Have_{s}", .{item}) catch return error.OutOfMemory;
        try self.putExp(shape, helper, &.{
            try self.flagRef(tmpl, name),
            try self.entry(tmpl, 19, hashValue(tmpl, count)),
            try self.entry(tmpl, 16, .{ .int = 0 }),
            try self.entry(tmpl, 4, null),
        });
        return self.expRef(tmpl, helper);
    }

    /// Adds a saved Bool flag `name` starting at `default`, shaped like Bool `like` (or, with null, like the first
    /// Bool of the main save file that resets as the ones in progress.sav do, ResetTypeValue 8). Every saved Bool takes
    /// an eight-byte record in its save file, so that file's size and the offsets after it grow too (MetaData), as
    /// OotrR does (tracking_metadata.add_saved_flags, soul_adapter.build_item_files); without that the game reads the
    /// saves wrong. Returns false (nothing changed) when the flag already exists.
    pub fn addSavedBool(self: *Self, name: []const u8, default: bool, like: ?[]const u8) PatchError!bool {
        const h = mm3(name);
        if (self.index.contains(h)) return false;
        const data = self.root.getDict("Data") orelse return error.InvalidData;
        const rows = data.getArray("Bool") orelse return error.InvalidData;
        const tmpl: *byml.Dict = blk: {
            if (like) |l| break :blk self.get(l, .Bool) orelse return error.NotAsExpected;
            for (rows.items.items) |r| {
                const d = r.asDict() orelse continue;
                if ((d.getInt("SaveFileIndex") orelse -1) == 0 and (d.getInt("ResetTypeValue") orelse -1) == 8) break :blk d;
            }
            return error.NotAsExpected;
        };
        const row = (try (byml.Value{ .dict = tmpl }).clone(self.allocator)).dict;
        try row.put(self.allocator, "Hash", (tmpl.get("Hash") orelse byml.Value{ .uint = 0 }).sameIntType(h));
        try row.put(self.allocator, "DefaultValue", .{ .bool = default });
        try rows.append(self.allocator, .{ .dict = row });
        self.index.put(h, Row{ .kind = .Bool, .kind_name = "Bool", .row = row }) catch return error.OutOfMemory;

        const file: usize = @intCast(@max(0, tmpl.getInt("SaveFileIndex") orelse 0));
        const meta = self.root.getDict("MetaData") orelse return error.InvalidData;
        try growIndexed(meta, "SaveDataSize", file, 8);
        try growIndexed(meta, "SaveDataOffsetPos", file, 8);
        try growScalar(self.allocator, meta, "AllDataSaveSize", 8);
        try growScalar(self.allocator, meta, "AllDataSaveOffset", 8);
        self.changed += 1;
        return true;
    }

    /// Lists `actor` in the IsGet structure, so the game writes IsGet.<actor> whenever the item reaches the pouch
    /// (chests, pickups and gifts alike). Why: the native pouch code only records the names the structure holds (member
    /// murmur3(name) -> flag murmur3("IsGet." + name)); a new item missing from it is silently never recorded (OotrR,
    /// soul_adapter.build_item_files). The IsGet.<actor> flag itself must be added first (addSavedBool).
    pub fn addIsGetMember(self: *Self, actor: []const u8) PatchError!bool {
        const s = self.get("IsGet", .Struct) orelse return error.NotAsExpected;
        const members = s.getArray("DefaultValue") orelse return error.NotAsExpected;
        const h = mm3(actor);
        var shape: ?*byml.Dict = null;
        for (members.items.items) |m| {
            const d = m.asDict() orelse continue;
            if ((d.getInt("Hash") orelse -1) == h) return false;
            if (shape == null) shape = d;
        }
        const tmpl = shape orelse return error.NotAsExpected;
        var buf: [256]u8 = undefined;
        const flag = std.fmt.bufPrint(&buf, "IsGet.{s}", .{actor}) catch return error.NotAsExpected;
        const member = try byml.Dict.create(self.allocator);
        try member.put(self.allocator, "Hash", (tmpl.get("Hash") orelse byml.Value{ .uint = 0 }).sameIntType(h));
        try member.put(self.allocator, "Value", (tmpl.get("Value") orelse byml.Value{ .uint = 0 }).sameIntType(mm3(flag)));
        try members.append(self.allocator, .{ .dict = member });
        self.changed += 1;
        return true;
    }

    /// Adds Int flag `name` (0, not saved), shaped like the game's UI_TokenGoldNumAfterGetting.
    pub fn addTempInt(self: *Self, name: []const u8) PatchError!void {
        const h = mm3(name);
        if (self.index.contains(h)) return;
        const tmpl = self.get("UI_TokenGoldNumAfterGetting", .Int) orelse return error.NotAsExpected;
        const row = try byml.Dict.create(self.allocator);
        try row.put(self.allocator, "Hash", (tmpl.get("Hash") orelse byml.Value{ .uint = 0 }).sameIntType(h));
        try row.put(self.allocator, "DefaultValue", (tmpl.get("DefaultValue") orelse byml.Value{ .int = 0 }).sameIntType(0));
        if (tmpl.get("ResetTypeValue")) |v| try row.put(self.allocator, "ResetTypeValue", v);
        if (tmpl.get("SaveFileIndex")) |v| try row.put(self.allocator, "SaveFileIndex", v);
        const data = self.root.getDict("Data") orelse return error.InvalidData;
        const rows = data.getArray("Int") orelse return error.InvalidData;
        try rows.append(self.allocator, .{ .dict = row });
        self.index.put(h, Row{ .kind = .Int, .kind_name = "Int", .row = row }) catch return error.OutOfMemory;
        self.changed += 1;
    }

    /// Adds a new computed flag `name` = flag1 OR flag2 OR ... (plain Bools). Computed flags are not saved.
    pub fn addBoolExpAny(self: *Self, name: []const u8, flags: []const []const u8) PatchError!bool {
        const h = mm3(name);
        if (self.index.contains(h)) return false;
        for (flags) |f| if (self.get(f, .Bool) == null) return false;
        const shape = self.firstBoolExp() orelse return error.InvalidData;
        const tmpl = template(shape) orelse return error.InvalidData;
        var values: std.ArrayList(byml.Value) = .empty;
        try appendValue(&values, self.allocator, try self.flagRef(tmpl, flags[0]));
        for (flags[1..]) |f| {
            try appendValue(&values, self.allocator, try self.flagRef(tmpl, f));
            try appendValue(&values, self.allocator, try self.entry(tmpl, 4, null)); // 0 = read Bool, 4 = OR
        }
        try self.putExp(shape, name, values.items);
        self.changed += 1;
        return true;
    }

    fn firstBoolExp(self: *Self) ?*byml.Dict {
        const data = self.root.getDict("Data") orelse return null;
        const rows = data.getArray("BoolExp") orelse return null;
        if (rows.items.items.len == 0) return null;
        return rows.items.items[0].asDict();
    }

    /// Adds computed flag `name` = (story condition `cond`, NOT-ed if `negate`) AND NOT `owned` (an IsGet flag): the
    /// Presence of a shuffled shop shelf that already had a story condition of its own (the Kokiri Shop's stock
    /// before / after the Deku Tree). `cond` may be a Bool (opcode 0) or a computed flag (opcode 10).
    pub fn addShopPresence(self: *Self, name: []const u8, cond: []const u8, negate: bool, owned: []const u8) PatchError!bool {
        const hit = self.lookup(cond);
        if (hit == null or (hit.?.kind != .Bool and hit.?.kind != .BoolExp) or self.get(owned, .Bool) == null) {
            self.progress.log("warning: shop shelf condition {s} or {s} not found", .{ cond, owned });
            return false;
        }
        const shape = self.firstBoolExp() orelse return error.InvalidData;
        const tmpl = template(shape) orelse return error.InvalidData;
        var values: std.ArrayList(byml.Value) = .empty;
        try appendValue(&values, self.allocator, try self.entry(tmpl, if (hit.?.kind == .BoolExp) 10 else 0, hashValue(tmpl, cond)));
        if (negate) try appendValue(&values, self.allocator, try self.entry(tmpl, 5, null));
        try appendValue(&values, self.allocator, try self.flagRef(tmpl, owned));
        try appendValue(&values, self.allocator, try self.entry(tmpl, 5, null));
        try appendValue(&values, self.allocator, try self.entry(tmpl, 3, null));
        try self.putExp(shape, name, values.items);
        self.changed += 1;
        return true;
    }

    /// Starts challenge (quest) `exp_name` reads at `step`; the Enum is the one the computed flag reads.
    pub fn setQuestStep(self: *Self, exp_name: []const u8, step: []const u8) PatchError!bool {
        const exp = self.get(exp_name, .BoolExp) orelse return false;
        const first = template(exp) orelse return false;
        if (first.items.items.len < 2) return false;
        const enum_hash = first.items.items[1].asInt() orelse return false;
        const hit = self.index.get(@truncate(@as(u128, @bitCast(enum_hash))));
        if (hit == null or hit.?.kind != .Enum or !hasRawValue(hit.?.row, step)) {
            self.progress.log("warning: quest for {s} not recognised; skipped", .{exp_name});
            return false;
        }
        return self.setEnumRow(hit.?.row, step);
    }

    fn setEnumRow(self: *Self, row: *byml.Dict, value: []const u8) PatchError!bool {
        const current = row.get("DefaultValue") orelse byml.Value{ .uint = 0 };
        const new = current.sameIntType(mm3(value));
        if (!byml.Value.exactEql(current, new)) {
            try row.put(self.allocator, "DefaultValue", new);
            self.changed += 1;
        }
        return true;
    }

    /// Starts Enum `name` (a challenge's Step_<name>) at `value`.
    pub fn setEnum(self: *Self, name: []const u8, value: []const u8) PatchError!bool {
        const row = self.get(name, .Enum) orelse return false;
        if (!hasRawValue(row, value)) {
            self.progress.log("warning: {s} has no value {s}; skipped", .{ name, value });
            return false;
        }
        return self.setEnumRow(row, value);
    }

    fn hasRawValue(row: *byml.Dict, value: []const u8) bool {
        const raw = row.getArray("RawValues") orelse return false;
        for (raw.items.items) |v| {
            if (v.asString()) |s| if (std.mem.eql(u8, s, value)) return true;
        }
        return false;
    }

    /// The Int holding how many of `actor` the player has (PouchData.<actor>), or null.
    pub fn pouchCountRow(self: *const Self, actor: []const u8) ?*byml.Dict {
        const hit = self.lookup(pouch_struct) orelse return null;
        if (hit.kind != .Struct) return null;
        const members = hit.row.getArray("DefaultValue") orelse return null;
        const actor_hash = mm3(actor);
        var member_value: ?i128 = null;
        for (members.items.items) |m| {
            const md = m.asDict() orelse continue;
            if ((md.getInt("Hash") orelse -1) == actor_hash) {
                member_value = md.getInt("Value");
                break;
            }
        }
        const inner_hash = member_value orelse return null;
        const inner = self.index.get(@truncate(@as(u128, @bitCast(inner_hash)))) orelse return null;
        if (inner.kind != .Struct) return null;
        const inner_members = inner.row.getArray("DefaultValue") orelse return null;
        if (inner_members.items.items.len != 1) return null;
        const first = inner_members.items.items[0].asDict() orelse return null;
        const count_hash = first.getInt("Value") orelse return null;
        const count = self.index.get(@truncate(@as(u128, @bitCast(count_hash)))) orelse return null;
        return if (count.kind == .Int) count.row else null;
    }

    /// A new save already owns one `actor`: its IsGet flag, plus its pouch count for pouch items.
    pub fn grantItem(self: *Self, actor: []const u8) PatchError!bool {
        const flag = std.fmt.allocPrint(self.allocator, "IsGet.{s}", .{actor}) catch return error.OutOfMemory;
        const ok = try self.setBool(flag, true);
        if (self.pouchCountRow(actor)) |row| {
            const current = row.get("DefaultValue") orelse byml.Value{ .int = 0 };
            if ((current.asInt() orelse 0) < 1) {
                try row.put(self.allocator, "DefaultValue", current.sameIntType(1));
                self.changed += 1;
            }
        }
        return ok;
    }

    /// Emits the changed save data (nothing when nothing changed).
    pub fn finish(self: *Self, patches: *patchset.PatchSet) PatchError!void {
        if (self.changed == 0) return;
        const data = try byml.dump(self.allocator, .{ .dict = self.root }, self.version, self.big_endian);
        try patches.emit(self.rel, self.original, data, self.dictionary, true);
    }
};

/// meta[key][index] += by (an array of sizes, one per save file).
fn growIndexed(meta: *byml.Dict, key: []const u8, index: usize, by: i128) PatchError!void {
    const arr = meta.getArray(key) orelse return error.InvalidData;
    if (index >= arr.items.items.len) return error.InvalidData;
    const v = arr.items.items[index];
    arr.items.items[index] = v.sameIntType((v.asInt() orelse return error.InvalidData) + by);
}

/// meta[key] += by.
fn growScalar(allocator: Allocator, meta: *byml.Dict, key: []const u8, by: i128) PatchError!void {
    const v = meta.get(key) orelse return error.InvalidData;
    try meta.put(allocator, key, v.sameIntType((v.asInt() orelse return error.InvalidData) + by));
}

fn appendValue(list: *std.ArrayList(byml.Value), allocator: Allocator, v: byml.Value) PatchError!void {
    list.append(allocator, v) catch return error.OutOfMemory;
}

fn appendName(list: *std.ArrayList(u8), allocator: Allocator, name: []const u8) PatchError!void {
    if (list.items.len > 0) list.appendSlice(allocator, ", ") catch return error.OutOfMemory;
    list.appendSlice(allocator, name) catch return error.OutOfMemory;
}

// ------------------------------------------------------------------------------------- probes of the save data

/// The unchanged save data, read once per world, for questions the generator asks before patching
/// (does a flag exist, can a new save own an item). Kept in the World (`probe`).
pub const Probe = struct {
    arena: std.heap.ArenaAllocator,
    progress: Progress,
    patcher: GameDataPatcher,

    fn deinitOpaque(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The world's save-data probe (read on first use).
pub fn probeOf(world: *world_mod.World) PatchError!*GameDataPatcher {
    if (world.probe) |p| {
        const probe: *Probe = @ptrCast(@alignCast(p));
        return &probe.patcher;
    }
    const probe = world.gpa.create(Probe) catch return error.OutOfMemory;
    probe.arena = std.heap.ArenaAllocator.init(world.gpa);
    probe.progress = Progress.silent();
    errdefer {
        probe.arena.deinit();
        world.gpa.destroy(probe);
    }
    const a = probe.arena.allocator();
    const rel = try world.find(a, "GameData", "GameDataList");
    const d = try world.readZs(a, rel);
    probe.patcher = try GameDataPatcher.init(a, rel, d.data, d.dictionary, &probe.progress);
    world.probe = probe;
    world.probe_deinit = Probe.deinitOpaque;
    return &probe.patcher;
}

/// Does the save data have an IsGet.<actor> flag (set the first time the item is owned)?
pub fn isGetExists(world: *world_mod.World, actor: []const u8) PatchError!bool {
    const p = try probeOf(world);
    var buf: [256]u8 = undefined;
    const flag = std.fmt.bufPrint(&buf, "IsGet.{s}", .{actor}) catch return false;
    return p.hasFlag(flag);
}

/// Is `name` a plain Bool save flag?
pub fn boolExists(world: *world_mod.World, name: []const u8) PatchError!bool {
    const p = try probeOf(world);
    return p.isBool(name);
}

/// Can a new save own `actor` through its IsGet flag and a PouchData count (GameDataPatcher.grantItem)?
pub fn pouchEntryExists(world: *world_mod.World, actor: []const u8) PatchError!bool {
    const p = try probeOf(world);
    var buf: [256]u8 = undefined;
    const flag = std.fmt.bufPrint(&buf, "IsGet.{s}", .{actor}) catch return false;
    return p.hasFlag(flag) and p.pouchCountRow(actor) != null;
}

// --------------------------------------------------------------------------------------- the planned changes

pub const ChangeKind = enum { bool_flag, int_flag, quest, enum_value, string_array, item, new_exp };

/// One save-data edit for the seed's settings.
pub const Change = struct {
    kind: ChangeKind,
    flag: []const u8,
    bool_value: bool = true,
    int_value: i64 = 0,
    text: []const u8 = "",
    flags: []const []const u8 = &.{},
};

fn addChange(list: *std.ArrayList(Change), allocator: Allocator, change: Change) error{OutOfMemory}!void {
    try list.append(allocator, change);
}

fn played(allocator: Allocator, scene: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "HavePlayedEvent.{s}", .{scene});
}

/// The save-data edits for these settings, in the order they are applied.
pub fn plannedChanges(allocator: Allocator, st: *const Settings, ocarina_bridge_patched: bool) error{OutOfMemory}![]Change {
    var out: std.ArrayList(Change) = .empty;
    const forest_open_exit = st.is(.open_forest, "closed_deku") or st.is(.open_forest, "open");
    // Kokiri boy / invisible wall at the forest exit is gone
    if (forest_open_exit) try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = forest_exit, .bool_value = false });
    // Mido no longer blocks the path to the Deku Tree
    if (st.is(.open_forest, "open")) try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = forest_mido, .bool_value = false });
    if (st.is(.open_zora, "open")) {
        // King Zora has already read Ruto's letter and moved aside
        for (zora_open) |f| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = f });
        try addChange(&out, allocator, .{ .kind = .quest, .flag = zora_open_quest_exp, .text = zora_open_quest_step });
    }
    // Door of Time quest starts at the step the open door follows
    if (st.is(.open_door, "open") and !st.flag(.skip_child_zelda))
        try addChange(&out, allocator, .{ .kind = .enum_value, .flag = door_quest_enum, .text = door_quest_step });
    // and the door's own opened flag, so it is open before Zelda is met too
    if (st.is(.open_door, "open")) try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = door_opened_flag });
    // Kakariko's Death Mountain gate starts open
    if (st.is(.open_dmt, "open")) try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = dmt_gate_open });
    // a new save owns Epona (the horse list the race fills); Epona's Song calls her
    if (st.flag(.skip_epona_race)) try addChange(&out, allocator, .{ .kind = .string_array, .flag = epona_owned_list, .text = epona_actor });
    if (st.flag(.skip_story_scenes)) {
        for (area_intros) |ev| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try played(allocator, ev) });
        // the Lake Hylia intros are what put Kaepora on the lake for his optional ride
        try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = "Npc_Kaepora_LakeHrl_Appeared_FromValley" });
        for (area_intro_visits) |loc| {
            try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try std.fmt.allocPrint(allocator, "IsVisitLocation.{s}", .{loc}) });
        }
    }
    if (st.is(.maps_compasses, "start_with")) {
        for (map_dungeons) |d| {
            for ([_][]const u8{ "IsGetMap", "IsGetCompass" }) |f| {
                try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try std.fmt.allocPrint(allocator, "DungeonInfo.{s}.{s}", .{ d, f }) });
            }
        }
    }
    // Small Keys: Removed / Boss Keys: Removed. A dungeon's keys are in its DungeonInfo save entry: SmallKeyNum (held,
    // what the locked doors use), SmallKeyTotalNum (found) and IsGetBossKey. A new save starts with all of them, so
    // every door opens as if the keys were found (an extra key is harmless). As OotrR does
    // (key_adapter.start_dungeon_values).
    if (st.is(.small_keys, "remove")) {
        for (logic.key_dungeons) |d| {
            for ([_][]const u8{ "SmallKeyNum", "SmallKeyTotalNum" }) |f| {
                try addChange(&out, allocator, .{ .kind = .int_flag, .flag = try std.fmt.allocPrint(allocator, "DungeonInfo.{s}.{s}", .{ d.folder, f }), .int_value = d.keys });
            }
        }
    }
    if (st.is(.boss_keys, "remove")) {
        for (logic.key_dungeons) |d| {
            if (d.boss == null) continue;
            try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try std.fmt.allocPrint(allocator, "DungeonInfo.{s}.IsGetBossKey", .{d.folder}) });
        }
    }
    if (st.flag(.shuffle_ocarinas) and !ocarina_bridge_patched) {
        // Fallback when the bridge trigger couldn't be patched (qol.patchOcarinaBridge): mark Saria's goodbye as
        // seen so the trigger never fires. Side effect: Saria's forest schedule treats her as gone from the start.
        for ([_][]const u8{ "Dm_Kokiri_0150", "Dm_Kokiri_0155" }) |ev| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try played(allocator, ev) });
    }
    if (st.flag(.skip_child_zelda)) {
        for (skip_zelda_quests) |q| try addChange(&out, allocator, .{ .kind = .quest, .flag = q.exp, .text = q.step });
        for (skip_zelda_played) |ev| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try played(allocator, ev) });
        for (skip_zelda_flags) |f| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = f });
        for (skip_zelda_items) |actor| try addChange(&out, allocator, .{ .kind = .item, .flag = actor });
    }
    if (st.flag(.skip_kaepora)) {
        for (kaepora_scenes) |ev| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try played(allocator, ev) });
        for (skip_zelda_flags) |f| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = f });
        for (skip_zelda_items) |actor| try addChange(&out, allocator, .{ .kind = .item, .flag = actor });
        if (!st.flag(.skip_child_zelda)) try addChange(&out, allocator, .{ .kind = .quest, .flag = kaepora_quest.exp, .text = kaepora_quest.step });
    }
    // Hyrule Field uses a "first visit" light table (the sun pinned at one angle) until this flag is set, which
    // vanilla does in Saria's bridge goodbye after the Deku Tree. Leaving the forest early kept the sun frozen.
    if (forest_open_exit or st.flag(.shuffle_ocarinas) or st.flag(.skip_child_zelda))
        try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = "HyruleField_ChangeENV" });
    // every seed: a new game starts outside the shop (faststart.startOutside), Saria's wake-up already done
    for (saria_intro) |f| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = f });
    try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = "HavePlayedEvent.Dm_Kokiri_0030" });
    if (st.flag(.skip_deku_talk) and st.is(.open_forest, "open")) {
        for (deku_tree_talk_flags) |f| try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = f });
        for (deku_tree_talk_steps) |s| try addChange(&out, allocator, .{ .kind = .enum_value, .flag = s.name, .text = s.value });
    }
    if (st.flag(.skip_ganon_trials)) {
        for (ganon_trials) |t| {
            try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try std.fmt.allocPrint(allocator, "InsideGanonCastle_Dungeon_BarrierRemove_{s}", .{t}) });
            try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = try std.fmt.allocPrint(allocator, "HavePlayedEvent.InsideGanonCastle_Dungeon_BarrierRemove_{s}", .{t}) });
        }
        // no trial barriers left; the tower barrier is gone
        try addChange(&out, allocator, .{ .kind = .int_flag, .flag = "InsideGanonCastle_Dungeon_Barrier_Count", .int_value = 0 });
        try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = "InsideGanonCastle_IsAllBarrierClear" });
        // the barrier-dispel scene that follows the last trial: the tower's lift only works once it has played
        try addChange(&out, allocator, .{ .kind = .bool_flag, .flag = "HavePlayedEvent.Dm_InsideGanonCastle_0090" });
    }
    // true when you own the Fairy Ocarina or the Ocarina of Time (replaces the met-Zelda check)
    if (st.flag(.saria_song_ocarina)) try addChange(&out, allocator, .{ .kind = .new_exp, .flag = saria_gate_new, .flags = &ocarina_flags });
    return out.toOwnedSlice(allocator);
}

pub const ShopPresence = struct {
    name: []const u8,
    condition: []const u8,
    negated: bool,
    owned: []const u8,
};

/// Applies the seed's save-data edits. `start_items`: actors a new save already owns (Skip Child Zelda);
/// `shop_presences`: computed flags for shuffled shelves with a story condition; `test_changes`: a test plan's quest
/// steps, flags and cutscenes (applied last). Returns false when the Saria gate
/// flag or the bridge could not be made (the caller warns).
pub fn apply(allocator: Allocator, world: *world_mod.World, patches: *patchset.PatchSet, st: *const Settings, progress: *Progress, ocarina_bridge_patched: bool, start_items: []const []const u8, shop_presences: []const ShopPresence, test_changes: []const Change) PatchError!bool {
    const rel = try world.find(allocator, "GameData", "GameDataList");
    const original = try patches.read(rel);
    var gd = try GameDataPatcher.init(allocator, rel, original.data, original.dictionary, progress);
    var ok = true;
    for (shop_presences) |p| {
        // the shelf's Presence already names this flag: without it the shelf would be broken
        if (!try gd.addShopPresence(p.name, p.condition, p.negated, p.owned)) {
            return progress.fail(error.NotAsExpected, "shop shelf condition {s} could not be made", .{p.name});
        }
    }
    for (start_items) |actor| {
        if (!try gd.grantItem(actor)) progress.log("warning: could not give {s} at the start", .{actor});
    }
    // a test plan's changes come last, so they win over what the settings set (teststart.zig checked each one)
    const settings_changes = try plannedChanges(allocator, st, ocarina_bridge_patched);
    const all_changes = std.mem.concat(allocator, Change, &.{ settings_changes, test_changes }) catch return error.OutOfMemory;
    for (all_changes) |c| {
        switch (c.kind) {
            .bool_flag => _ = try gd.setBool(c.flag, c.bool_value),
            .int_flag => _ = try gd.setInt(c.flag, c.int_value),
            .quest => _ = try gd.setQuestStep(c.flag, c.text),
            .enum_value => _ = try gd.setEnum(c.flag, c.text),
            .string_array => _ = try gd.setStringArray(c.flag, c.text),
            .item => _ = try gd.grantItem(c.flag),
            .new_exp => ok = (try gd.addBoolExpAny(c.flag, c.flags)) or gd.hasFlag(c.flag),
        }
    }
    if (!st.is(.rainbow_bridge, "vanilla")) {
        if (!try gd.rainbowBridge(BridgeNeeds.of(st.choice(.rainbow_bridge), st.int(.bridge_medallions), st.int(.bridge_tokens)))) ok = false;
    }
    try gd.finish(patches);
    return ok;
}
