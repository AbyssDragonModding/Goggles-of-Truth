//! Gossip Stone hints.
//!
//! The hint kinds, their weights, the always/sometimes lists and the wording are Clawshot's
//! (https://github.com/hiKareeem/Clawshot, src/clawshot/data/hints.toml and generate/hints.py, MIT License,
//! Copyright (c) 2026 Kareem Albaba and the Clawshot contributors), which follow OoT Randomizer's Hints.py (MIT).
//! The method is re-done on this randomizer's logic:
//!
//! - Stones. Every talking stone is an Obj_GossipStone_A_01 placement whose Name (GOSSIP_<AREA>_<NN>) is also the
//!   label of its line in EventFlowMsg/GossipStone.msbt (one per language archive). Changing a stone's hint is
//!   changing that one message.
//! - Readable. A stone is read when its area is reachable (a stone placed in a grotto also needs the area's grotto
//!   requirement). With "Mask of Truth required", only as child holding the Mask of Truth, and then no hint names
//!   something needed to get the mask.
//! - Where it matters. A hint naming a location goes only on a stone readable with that location's item withheld, so a
//!   stone never needs the item it points at. Junk lines take the unreadable stones first.
//! - Way of the Hero ("woth"): a shuffled location whose item the seed can't be finished without.
//! - Barren ("foolish"): an area none of whose shuffled locations holds a required or major item.
//! - Item / always / sometimes / random: a location (or area) and its item. Own-dungeon keys, maps and compasses are
//!   never named.
//!
//! Only shuffled locations are hinted. The choices use their own random stream seeded from the seed, so placements
//! are never changed.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const evfl = @import("../formats/evfl.zig");
const sarc = @import("../formats/sarc.zig");
const msbt = @import("../formats/msbt.zig");
const logic = @import("../logic/logic.zig");
const world_mod = @import("../game/world.zig");
const fill = @import("fill.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const Rng = @import("../core/rng.zig").Rng;
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const ItemId = logic.ItemId;

const stone_actor = "Obj_GossipStone_A_01";
pub const gossip_flow = "Event/EventFlow/GossipStone.bfevfl.zs";
const gossip_messages = "EventFlowMsg/GossipStone.msbt";
const mask_of_truth_actor = "Armor_Child_Mask_Truth";
/// characters a row and rows a page; the game's own stone lines fit these
const hint_width = 60;
const hint_rows = 2;

pub const Kind = enum { always, woth, barren, item, sometimes, random, junk };

const Weight = struct { kind: Kind, weight: f64 };

const Distribution = struct {
    weights: []const Weight,
    dungeon_woth_limit: usize,
    dungeon_barren_limit: usize,
    always: bool,
};

/// OoT Randomizer data/Hints/balanced.json and strong.json (entrance hints left out), via Clawshot; "useless": every
/// stone a joke.
fn distribution(name: []const u8) Distribution {
    if (std.mem.eql(u8, name, "strong")) return .{
        .weights = &.{ .{ .kind = .woth, .weight = 3.0 }, .{ .kind = .barren, .weight = 3.0 }, .{ .kind = .item, .weight = 1.0 }, .{ .kind = .sometimes, .weight = 1.65 }, .{ .kind = .random, .weight = 2.0 } },
        .dungeon_woth_limit = 2,
        .dungeon_barren_limit = 1,
        .always = true,
    };
    if (std.mem.eql(u8, name, "useless")) return .{
        .weights = &.{.{ .kind = .junk, .weight = 1.0 }},
        .dungeon_woth_limit = 0,
        .dungeon_barren_limit = 0,
        .always = false,
    };
    return .{
        .weights = &.{ .{ .kind = .woth, .weight = 3.5 }, .{ .kind = .barren, .weight = 2.0 }, .{ .kind = .item, .weight = 5.0 }, .{ .kind = .sometimes, .weight = 4.5 }, .{ .kind = .random, .weight = 6.0 }, .{ .kind = .junk, .weight = 3.0 } },
        .dungeon_woth_limit = 2,
        .dungeon_barren_limit = 1,
        .always = true,
    };
}

/// OoT Randomizer's always / sometimes hint locations, by this randomizer's location names.
const always_names = [_][]const u8{
    "Song from Ocarina of Time", "HF Ocarina of Time", "DMT Biggoron", "Kak 30 Gold Skulltula Reward",
    "Kak 40 Gold Skulltula Reward", "Kak 50 Gold Skulltula Reward", "ZR Frogs Song Game",
};
const sometimes_names = [_][]const u8{
    "Song from Royal Familys Tomb", "Sheik in Forest",      "Sheik at Temple",          "Sheik in Crater",
    "Sheik in Ice Cavern",          "Sheik in Kakariko",    "Sheik at Colossus",        "Market Big Poe Bottle",
    "Kak 20 Gold Skulltula Reward", "Kak Anju as Child",    "GC Darunias Joy",          "LW Skull Kid",
    "LW Target in Woods",           "LH Lab Dive",          "HC Great Fairy Reward",    "OGC Great Fairy Reward",
    "ZR Frogs Bug Game",            "GF Horseback Archery",
};

const junk_lines = [_][]const u8{
    "They say this stone has nothing to tell you today.",
    "They say a stone never forgets, but it rarely remembers anything useful.",
    "They say the owl knows every road, if only he would stop talking about them.",
    "They say the Kokiri never grow up, but their pranks keep getting bigger.",
    "They say the cuccos remember every hero who ever struck one.",
    "They say Song of Time blocks are patient. Very, very patient.",
    "They say a hero who reads every stone has read too many stones.",
    "They say the Gold Skulltulas count every token you take.",
};

const Pair = struct { key: []const u8, value: []const u8 };

/// Hint areas: a location's dungeon, else its region (stage folder), else by its name. The remake keeps Lake Hylia in
/// the Hyrule Field stages, so its stage spots are hinted as Hyrule Field.
const area_names = [_]Pair{
    .{ .key = "KokiriForest", .value = "Kokiri Forest" },                 .{ .key = "LostWood", .value = "the Lost Woods" },
    .{ .key = "SacredForestMeadow", .value = "the Sacred Forest Meadow" }, .{ .key = "HyruleField", .value = "Hyrule Field" },
    .{ .key = "LonLonRanch", .value = "Lon Lon Ranch" },                  .{ .key = "Market", .value = "the Market" },
    .{ .key = "TimeTemple", .value = "the Temple of Time" },              .{ .key = "HyruleCastle", .value = "Hyrule Castle" },
    .{ .key = "OutsideGanonCastle", .value = "outside Ganon's Castle" },   .{ .key = "KakarikoVillage", .value = "Kakariko Village" },
    .{ .key = "Graveyard", .value = "the Graveyard" },                    .{ .key = "DeathMountainTrail", .value = "Death Mountain Trail" },
    .{ .key = "GoronCity", .value = "Goron City" },                       .{ .key = "DeathMountainCrater", .value = "Death Mountain Crater" },
    .{ .key = "ZoraRiver", .value = "Zora's River" },                     .{ .key = "ZoraDomain", .value = "Zora's Domain" },
    .{ .key = "ZoraFountain", .value = "Zora's Fountain" },               .{ .key = "LakeHylia", .value = "Lake Hylia" },
    .{ .key = "GerudoValley", .value = "Gerudo Valley" },                 .{ .key = "GerudoFortress", .value = "Gerudo's Fortress" },
    .{ .key = "HountedWasteland", .value = "the Haunted Wasteland" },      .{ .key = "DesertColossus", .value = "the Desert Colossus" },
    .{ .key = "InsideTheDekuTree", .value = "the Deku Tree" },            .{ .key = "DodongoCavern", .value = "Dodongo's Cavern" },
    .{ .key = "InsideJabuJabuBelly", .value = "Jabu-Jabu's Belly" },      .{ .key = "ForestTemple", .value = "the Forest Temple" },
    .{ .key = "FireTemple", .value = "the Fire Temple" },                 .{ .key = "WaterTemple", .value = "the Water Temple" },
    .{ .key = "ShadowTemple", .value = "the Shadow Temple" },             .{ .key = "SpiritTemple", .value = "the Spirit Temple" },
    .{ .key = "BottomOfTheWell", .value = "the Bottom of the Well" },     .{ .key = "IceCavern", .value = "the Ice Cavern" },
    .{ .key = "GerudoTrainingGround", .value = "the Gerudo Training Ground" }, .{ .key = "InsideGanonCastle", .value = "Ganon's Castle" },
    .{ .key = "GanonCastle", .value = "Ganon's Castle" },
};
const dungeon_areas = [_][]const u8{
    "InsideTheDekuTree", "DodongoCavern", "InsideJabuJabuBelly", "ForestTemple",  "FireTemple",
    "WaterTemple",       "ShadowTemple",  "SpiritTemple",        "BottomOfTheWell", "IceCavern",
    "GerudoTrainingGround", "InsideGanonCastle", "GanonCastle",
};
/// locations without a stage (events): exact names first, then name prefixes
const name_areas = [_]Pair{
    .{ .key = "Queen Gohma (Kokiri Emerald)", .value = "InsideTheDekuTree" }, .{ .key = "King Dodongo (Goron Ruby)", .value = "DodongoCavern" },
    .{ .key = "Barinade (Zora Sapphire)", .value = "InsideJabuJabuBelly" },   .{ .key = "Phantom Ganon (Forest Medallion)", .value = "ForestTemple" },
    .{ .key = "Volvagia (Fire Medallion)", .value = "FireTemple" },           .{ .key = "Morpha (Water Medallion)", .value = "WaterTemple" },
    .{ .key = "Bongo Bongo (Shadow Medallion)", .value = "ShadowTemple" },    .{ .key = "Twinrova (Spirit Medallion)", .value = "SpiritTemple" },
    .{ .key = "Rauru (Light Medallion)", .value = "TimeTemple" },             .{ .key = "Song from Impa", .value = "HyruleCastle" },
    .{ .key = "Song from Malon", .value = "LonLonRanch" },                    .{ .key = "Song from Saria", .value = "SacredForestMeadow" },
    .{ .key = "Song from Royal Familys Tomb", .value = "Graveyard" },         .{ .key = "Song from Windmill", .value = "KakarikoVillage" },
    .{ .key = "Song from Ocarina of Time", .value = "HyruleField" },          .{ .key = "Sheik in Forest", .value = "SacredForestMeadow" },
    .{ .key = "Sheik in Crater", .value = "DeathMountainCrater" },            .{ .key = "Sheik in Ice Cavern", .value = "IceCavern" },
    .{ .key = "Sheik in Kakariko", .value = "KakarikoVillage" },              .{ .key = "Sheik at Colossus", .value = "DesertColossus" },
    .{ .key = "Sheik at Temple", .value = "TimeTemple" },                     .{ .key = "King Zora Thawed", .value = "ZoraDomain" },
};
/// dungeon-name prefixes first, then the area prefixes
const prefix_areas = [_]Pair{
    .{ .key = "Dodongo Cavern ", .value = "DodongoCavern" }, .{ .key = "Fire Temple ", .value = "FireTemple" },
    .{ .key = "Forest Temple ", .value = "ForestTemple" },   .{ .key = "Lord Jabu-Jabu's Belly ", .value = "InsideJabuJabuBelly" },
    .{ .key = "Great Deku Tree ", .value = "InsideTheDekuTree" }, .{ .key = "Shadow Temple ", .value = "ShadowTemple" },
    .{ .key = "Spirit Temple ", .value = "SpiritTemple" },   .{ .key = "Water Temple ", .value = "WaterTemple" },
    .{ .key = "Kak ", .value = "KakarikoVillage" },          .{ .key = "DMT ", .value = "DeathMountainTrail" },
    .{ .key = "DMC ", .value = "DeathMountainCrater" },      .{ .key = "GC ", .value = "GoronCity" },
    .{ .key = "GF ", .value = "GerudoFortress" },            .{ .key = "Hideout ", .value = "GerudoFortress" },
    .{ .key = "HC ", .value = "HyruleCastle" },              .{ .key = "OGC ", .value = "OutsideGanonCastle" },
    .{ .key = "HF ", .value = "HyruleField" },               .{ .key = "LH ", .value = "LakeHylia" },
    .{ .key = "LLR ", .value = "LonLonRanch" },              .{ .key = "LW ", .value = "LostWood" },
    .{ .key = "Market ", .value = "Market" },                .{ .key = "ToT ", .value = "TimeTemple" },
    .{ .key = "ZD ", .value = "ZoraDomain" },                .{ .key = "ZF ", .value = "ZoraFountain" },
    .{ .key = "ZR ", .value = "ZoraRiver" },                 .{ .key = "Graveyard ", .value = "Graveyard" },
    .{ .key = "Colossus ", .value = "DesertColossus" },      .{ .key = "KF ", .value = "KokiriForest" },
    .{ .key = "SFM ", .value = "SacredForestMeadow" },       .{ .key = "GV ", .value = "GerudoValley" },
};
/// Stage folder -> area the label's middle part names
const label_areas = [_]Pair{
    .{ .key = "DEATH_MOUNTAIN_CRATER", .value = "DeathMountainCrater" }, .{ .key = "DEATH_MOUNTAIN_TRAIL", .value = "DeathMountainTrail" },
    .{ .key = "DESERT_COLOSSUS", .value = "DesertColossus" },           .{ .key = "DODONGO_CAVERN", .value = "DodongoCavern" },
    .{ .key = "GERUDO_VALLEY", .value = "GerudoValley" },               .{ .key = "GORON_CITY", .value = "GoronCity" },
    .{ .key = "GRAVEYARD", .value = "Graveyard" },                      .{ .key = "HYRULE_CASTLE", .value = "HyruleCastle" },
    .{ .key = "HYRULE_FIELD", .value = "HyruleField" },                 .{ .key = "HYRULE_MARKET", .value = "Market" },
    .{ .key = "KAKARIKO_VILLAGE", .value = "KakarikoVillage" },         .{ .key = "KOKIRI_FOREST", .value = "KokiriForest" },
    .{ .key = "LAKE_HYLIA", .value = "HyruleField" },                   .{ .key = "LOST_WOOD", .value = "LostWood" },
    .{ .key = "SACRED_FOREST_MEADOW", .value = "SacredForestMeadow" },  .{ .key = "ZORA_DOMAIN", .value = "ZoraDomain" },
    .{ .key = "ZORA_FOUNTAIN", .value = "ZoraFountain" },               .{ .key = "ZORA_RIVER", .value = "ZoraRiver" },
};

fn lookup(table: []const Pair, key: []const u8) ?[]const u8 {
    for (table) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
    return null;
}

/// Stones whose stage folder is not their area's but stand in the open (Lake Hylia is part of the Hyrule Field stages;
/// the Lost Woods bridge stone is also placed in the Kokiri Forest files). Any other such stone is in a grotto.
fn openAirElsewhere(folder: []const u8, middle: []const u8) bool {
    return (std.mem.eql(u8, folder, "HyruleField") and std.mem.eql(u8, middle, "LAKE_HYLIA")) or
        (std.mem.eql(u8, folder, "KokiriForest") and std.mem.eql(u8, middle, "LOST_WOOD"));
}

pub fn areaOf(loc: *const world_mod.Location) ?[]const u8 {
    if (loc.dungeon) |d| return d;
    if (loc.region) |r| return r;
    if (lookup(&name_areas, loc.name)) |a| return a;
    for (prefix_areas) |p| if (std.mem.startsWith(u8, loc.name, p.key)) return p.value;
    return null;
}

pub fn areaName(area: ?[]const u8) []const u8 {
    const a = area orelse return "somewhere";
    return lookup(&area_names, a) orelse a;
}

fn isDungeonArea(area: []const u8) bool {
    return flows.contains(&dungeon_areas, area);
}

/// Child Link can get the Mask of Truth: the Happy Mask Shop (Zelda's Letter shown at the Kakariko gate), the Skull
/// Kid (Saria's Song) and the Graveyard. An approximation: the logic doesn't model the mask quest itself.
fn maskOfTruth(s: *logic.State) bool {
    return s.is(.hf_child) and logic.maskShop(s) and logic.song(s, .Melody_SariaSong);
}

// ------------------------------------------------------------------------------------------------- stones

const Ages = world_mod.Ages;

const Stone = struct {
    label: []const u8,
    /// stage folder -> the ages it is placed for
    folders: std.ArrayList(struct { folder: []const u8, ages: Ages }),
};

/// Every talking stone, by label, sorted by label.
fn scanStones(allocator: Allocator, world: *World) PatchError![]Stone {
    var stones: std.ArrayList(Stone) = .empty;
    const banc = world.files.listDir(allocator, "Banc") catch return error.GameFiles;
    var tmp = std.heap.ArenaAllocator.init(world.gpa);
    defer tmp.deinit();
    for (banc) |folder| {
        const sub = std.fmt.allocPrint(allocator, "Banc/{s}", .{folder}) catch return error.OutOfMemory;
        if (!world.files.isDir(sub)) continue;
        const names = world.files.listDir(allocator, sub) catch return error.GameFiles;
        for (names) |fname| {
            if (!std.mem.endsWith(u8, fname, ".bcett.byml.zs")) continue;
            _ = tmp.reset(.retain_capacity);
            const t = tmp.allocator();
            const rel = std.fmt.allocPrint(t, "Banc/{s}/{s}", .{ folder, fname }) catch return error.OutOfMemory;
            const d = try world.readZs(t, rel);
            if (std.mem.indexOf(u8, d.data, stone_actor) == null) continue;
            const ages: Ages = if (std.mem.indexOf(u8, fname, "_Child_") != null)
                .{ .child = true }
            else if (std.mem.indexOf(u8, fname, "_Adult_") != null)
                .{ .adult = true }
            else
                .{ .child = true, .adult = true };
            const root = try byml.loadDict(t, d.data);
            const actors = root.getArray("Actors") orelse continue;
            for (actors.items.items) |v| {
                const a = v.asDict() orelse continue;
                if (!std.mem.eql(u8, a.getString("Gyaml") orelse "", stone_actor)) continue;
                const label_t = a.getString("Name") orelse continue;
                if (label_t.len == 0) continue;
                var stone: ?*Stone = null;
                for (stones.items) |*s| if (std.mem.eql(u8, s.label, label_t)) {
                    stone = s;
                };
                if (stone == null) {
                    stones.append(allocator, .{ .label = allocator.dupe(u8, label_t) catch return error.OutOfMemory, .folders = .empty }) catch return error.OutOfMemory;
                    stone = &stones.items[stones.items.len - 1];
                }
                const s = stone.?;
                var found = false;
                for (s.folders.items) |*f| if (std.mem.eql(u8, f.folder, folder)) {
                    f.ages.child = f.ages.child or ages.child;
                    f.ages.adult = f.ages.adult or ages.adult;
                    found = true;
                };
                if (!found) s.folders.append(allocator, .{ .folder = folder, .ages = ages }) catch return error.OutOfMemory;
            }
        }
    }
    std.mem.sort(Stone, stones.items, {}, struct {
        fn less(_: void, x: Stone, y: Stone) bool {
            return std.mem.order(u8, x.label, y.label) == .lt;
        }
    }.less);
    return stones.items;
}

/// Is stone `stone` readable in state `s`?
fn stoneReadable(stone: *const Stone, s: *logic.State, mask: bool) bool {
    if (mask and !(s.is(.hf_child) and maskOfTruth(s))) return false;
    const after = stone.label["GOSSIP_".len..];
    const middle = if (std.mem.lastIndexOfScalar(u8, after, '_')) |i| after[0..i] else after;
    for (stone.folders.items) |f| {
        if (std.mem.eql(u8, f.folder, "DodongoCavern")) {
            if ((s.is(.dmt_child) or s.is(.adult)) and (logic.bombs(s) or s.has(.Hammer))) return true;
            continue;
        }
        const region = logic.regionByName(f.folder) orelse continue;
        const label_area = lookup(&label_areas, middle);
        const grotto = !(label_area != null and std.mem.eql(u8, label_area.?, f.folder)) and !openAirElsewhere(f.folder, middle);
        inline for (.{ logic.Age.child, logic.Age.adult }) |age| {
            const has_age = if (age == .child) f.ages.child else f.ages.adult;
            if (has_age and logic.regionAccess(s, region, age) and (!grotto or logic.regionExtra(s, region, age))) return true;
        }
    }
    return false;
}

// -------------------------------------------------------------------------------------------------- choosing

pub const Hint = struct {
    label: []const u8,
    kind: Kind,
    area: ?[]const u8 = null,
    location: ?usize = null,
    item: ?ItemId = null,
    line: usize = 0,
};

/// Sweeps of the seed's placements, each with at most one location's item withheld (cached).
const Searches = struct {
    allocator: Allocator,
    filler: *fill.Filler,
    contents: []?ItemId,
    /// Each state has an allocation of its own: callers keep the pointer `get` returns (Chooser.full) while later
    /// searches add entries, and a map growing moves the values it holds, which would leave that pointer dangling.
    cache: std.AutoHashMap(usize, *logic.State),

    const none_key = std.math.maxInt(usize);

    fn get(self: *Searches, without: ?usize) PatchError!*logic.State {
        var key: usize = none_key;
        if (without) |w| {
            if (self.contents[w]) |item| {
                if (logic.isProgression(item)) key = w;
            }
        }
        const slot = self.cache.getOrPut(key) catch return error.OutOfMemory;
        if (!slot.found_existing) {
            const items = self.allocator.dupe(?ItemId, self.contents) catch return error.OutOfMemory;
            if (key != none_key) items[key] = null;
            const result = self.filler.sweep(&.{}, items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NotAsExpected,
            };
            const state = self.allocator.create(logic.State) catch return error.OutOfMemory;
            state.* = result.state;
            slot.value_ptr.* = state;
        }
        return slot.value_ptr.*;
    }

    fn won(self: *Searches, without: ?usize) PatchError!bool {
        return (try self.get(without)).is(.win);
    }
};

fn isMajor(world: *World, item: ItemId) bool {
    const name = world.items.name(item);
    return logic.isProgression(item) and std.mem.indexOfScalar(u8, name, '@') == null and !std.mem.eql(u8, name, "Token_Gold");
}

fn worthNaming(world: *World, item: ItemId) bool {
    const name = world.items.name(item);
    return std.mem.indexOfScalar(u8, name, '@') == null and !std.mem.eql(u8, name, "Token_Gold") and
        (logic.isProgression(item) or std.mem.startsWith(u8, name, "Heart_"));
}

const Chooser = struct {
    allocator: Allocator,
    world: *World,
    stones: []Stone,
    mask: bool,
    rng: Rng,
    searches: Searches,
    full: *logic.State,
    free: std.ArrayList(usize),
    hints: std.ArrayList(Hint),
    area: []?[]const u8,
    hinted_locations: std.AutoHashMap(usize, void),
    hinted_areas: std.StringHashMap(void),
    hinted_items: std.AutoHashMap(ItemId, void),
    dungeon_woth: usize = 0,
    dungeon_barren: usize = 0,
    limits: Distribution,
    required: std.ArrayList(usize),
    by_area: std.ArrayList(struct { area: []const u8, locs: std.ArrayList(usize) }),
    junk_order: [junk_lines.len]usize,

    const Self = @This();

    fn contents(self: *Self, loc: usize) ItemId {
        return self.searches.contents[loc].?;
    }

    /// Puts a hint on the first free stone readable with `location`'s item withheld (or the full state).
    fn place(self: *Self, kind: Kind, location: ?usize, area: ?[]const u8) PatchError!bool {
        const state = if (location) |l| try self.searches.get(l) else self.full;
        for (self.free.items, 0..) |stone, k| {
            if (stoneReadable(&self.stones[stone], state, self.mask)) {
                _ = self.free.orderedRemove(k);
                self.hints.append(self.allocator, .{
                    .label = self.stones[stone].label,
                    .kind = kind,
                    .area = area,
                    .location = location,
                    .item = if (location) |l| self.contents(l) else null,
                }) catch return error.OutOfMemory;
                return true;
            }
        }
        return false;
    }

    fn locationHint(self: *Self, kind: Kind, candidates_in: []const usize) PatchError!bool {
        var candidates: std.ArrayList(usize) = .empty;
        for (candidates_in) |l| {
            if (self.hinted_locations.contains(l)) continue;
            if (kind == .item and self.hinted_items.contains(self.contents(l))) continue;
            candidates.append(self.allocator, l) catch return error.OutOfMemory;
        }
        while (candidates.items.len > 0) {
            const l = candidates.orderedRemove(self.rng.below(candidates.items.len));
            self.hinted_locations.put(l, {}) catch return error.OutOfMemory;
            if (try self.place(kind, l, self.area[l])) {
                if (kind == .item) self.hinted_items.put(self.contents(l), {}) catch return error.OutOfMemory;
                return true;
            }
        }
        return false;
    }

    fn woth(self: *Self) PatchError!bool {
        var candidates: std.ArrayList(usize) = .empty;
        for (self.required.items) |l| {
            const a = self.area[l] orelse continue;
            if (self.hinted_areas.contains(a)) continue;
            if (isDungeonArea(a) and self.dungeon_woth >= self.limits.dungeon_woth_limit) continue;
            candidates.append(self.allocator, l) catch return error.OutOfMemory;
        }
        while (candidates.items.len > 0) {
            const l = candidates.orderedRemove(self.rng.below(candidates.items.len));
            if (try self.place(.woth, l, self.area[l])) {
                self.hinted_locations.put(l, {}) catch return error.OutOfMemory;
                self.hinted_areas.put(self.area[l].?, {}) catch return error.OutOfMemory;
                if (isDungeonArea(self.area[l].?)) self.dungeon_woth += 1;
                return true;
            }
        }
        return false;
    }

    fn barren(self: *Self) PatchError!bool {
        var areas: std.ArrayList([]const u8) = .empty;
        var weights: std.ArrayList(f64) = .empty;
        for (self.by_area.items) |entry| {
            if (self.hinted_areas.contains(entry.area)) continue;
            if (isDungeonArea(entry.area) and self.dungeon_barren >= self.limits.dungeon_barren_limit) continue;
            var useful = false;
            for (entry.locs.items) |l| {
                if (std.mem.indexOfScalar(usize, self.required.items, l) != null or isMajor(self.world, self.contents(l))) useful = true;
            }
            if (useful) continue;
            areas.append(self.allocator, entry.area) catch return error.OutOfMemory;
            weights.append(self.allocator, @floatFromInt(entry.locs.items.len)) catch return error.OutOfMemory;
        }
        if (areas.items.len == 0) return false;
        const a = areas.items[self.rng.weighted(weights.items)];
        if (!try self.place(.barren, null, a)) return false;
        self.hinted_areas.put(a, {}) catch return error.OutOfMemory;
        if (isDungeonArea(a)) self.dungeon_barren += 1;
        return true;
    }

    fn junk(self: *Self) PatchError!void {
        // the unreadable stones get the jokes first
        var pick: usize = 0;
        for (self.free.items, 0..) |stone, k| {
            if (!stoneReadable(&self.stones[stone], self.full, self.mask)) {
                pick = k;
                break;
            }
        }
        const stone = self.free.orderedRemove(pick);
        var n: usize = 0;
        for (self.hints.items) |h| if (h.kind == .junk) {
            n += 1;
        };
        self.hints.append(self.allocator, .{ .label = self.stones[stone].label, .kind = .junk, .line = self.junk_order[n % self.junk_order.len] }) catch return error.OutOfMemory;
    }
};

/// One Hint per stone, in label order. `filler` is the seed's successful fill.
pub fn choose(allocator: Allocator, world: *World, plan: *fill.Plan, filler: *fill.Filler, seed: []const u8, distribution_name: []const u8, mask: bool) PatchError![]Hint {
    const dist = distribution(distribution_name);
    const stones = try scanStones(allocator, world);
    if (stones.len == 0) return &.{};

    const seed_text = std.fmt.allocPrint(allocator, "ootr-remake hints {s}", .{seed}) catch return error.OutOfMemory;
    var c = Chooser{
        .allocator = allocator,
        .world = world,
        .stones = stones,
        .mask = mask,
        .rng = Rng.fromText(seed_text),
        .searches = .{
            .allocator = allocator,
            .filler = filler,
            .contents = filler.contents() catch return error.OutOfMemory,
            .cache = std.AutoHashMap(usize, *logic.State).init(allocator),
        },
        .full = undefined,
        .free = .empty,
        .hints = .empty,
        .area = allocator.alloc(?[]const u8, world.locations.items.len) catch return error.OutOfMemory,
        .hinted_locations = std.AutoHashMap(usize, void).init(allocator),
        .hinted_areas = std.StringHashMap(void).init(allocator),
        .hinted_items = std.AutoHashMap(ItemId, void).init(allocator),
        .limits = dist,
        .required = .empty,
        .by_area = .empty,
        .junk_order = undefined,
    };
    c.full = try c.searches.get(null);
    for (0..stones.len) |i| c.free.append(allocator, i) catch return error.OutOfMemory;
    c.rng.shuffle(usize, c.free.items);

    // the shuffled locations that got a placement, in plan order
    var shuffled: std.ArrayList(usize) = .empty;
    for (plan.shuffled.items) |l| if (filler.placed[l] != null) shuffled.append(allocator, l) catch return error.OutOfMemory;
    @memset(c.area, null);
    for (shuffled.items) |l| c.area[l] = areaOf(&world.locations.items[l]);

    if (try c.searches.won(null)) {
        for (shuffled.items) |l| {
            const item = c.contents(l);
            if (!logic.isProgression(item) or std.mem.indexOfScalar(u8, world.items.name(item), '@') != null) continue;
            if (!try c.searches.won(l)) c.required.append(allocator, l) catch return error.OutOfMemory;
        }
    }
    var before_mask = std.AutoHashMap(usize, void).init(allocator);
    if (mask and maskOfTruth(c.full)) {
        for (shuffled.items) |l| {
            if (logic.isProgression(c.contents(l)) and !maskOfTruth(try c.searches.get(l))) before_mask.put(l, {}) catch return error.OutOfMemory;
        }
        var kept: std.ArrayList(usize) = .empty;
        for (c.required.items) |l| if (!before_mask.contains(l)) kept.append(allocator, l) catch return error.OutOfMemory;
        c.required = kept;
    }
    for (shuffled.items) |l| {
        const a = c.area[l] orelse continue;
        var found = false;
        for (c.by_area.items) |*e| if (std.mem.eql(u8, e.area, a)) {
            e.locs.append(allocator, l) catch return error.OutOfMemory;
            found = true;
        };
        if (!found) {
            var locs: std.ArrayList(usize) = .empty;
            locs.append(allocator, l) catch return error.OutOfMemory;
            c.by_area.append(allocator, .{ .area = a, .locs = locs }) catch return error.OutOfMemory;
        }
    }
    std.mem.sort(@TypeOf(c.by_area.items[0]), c.by_area.items, {}, struct {
        fn less(_: void, x: @TypeOf(c.by_area.items[0]), y: @TypeOf(c.by_area.items[0])) bool {
            return std.mem.order(u8, x.area, y.area) == .lt;
        }
    }.less);

    var named: std.ArrayList(usize) = .empty;
    for (shuffled.items) |l| {
        if (worthNaming(world, c.contents(l)) and !before_mask.contains(l)) named.append(allocator, l) catch return error.OutOfMemory;
    }
    var always: std.ArrayList(usize) = .empty;
    var sometimes: std.ArrayList(usize) = .empty;
    var majors: std.ArrayList(usize) = .empty;
    for (always_names) |n| for (named.items) |l| if (std.mem.eql(u8, world.locations.items[l].name, n)) always.append(allocator, l) catch return error.OutOfMemory;
    for (sometimes_names) |n| for (named.items) |l| if (std.mem.eql(u8, world.locations.items[l].name, n)) sometimes.append(allocator, l) catch return error.OutOfMemory;
    for (named.items) |l| if (isMajor(world, c.contents(l))) majors.append(allocator, l) catch return error.OutOfMemory;
    for (&c.junk_order, 0..) |*j, i| j.* = i;
    c.rng.shuffle(usize, &c.junk_order);

    if (dist.always) {
        for (always.items) |l| {
            if (c.free.items.len > 0 and !c.hinted_locations.contains(l)) {
                c.hinted_locations.put(l, {}) catch return error.OutOfMemory;
                _ = try c.place(.always, l, c.area[l]);
            }
        }
    }
    // the hint kinds by weight, in name order; a kind that runs out is dropped
    var kinds: std.ArrayList(Weight) = .empty;
    for (dist.weights) |w| if (w.weight > 0) kinds.append(allocator, w) catch return error.OutOfMemory;
    std.mem.sort(Weight, kinds.items, {}, struct {
        fn less(_: void, x: Weight, y: Weight) bool {
            return std.mem.order(u8, @tagName(x.kind), @tagName(y.kind)) == .lt;
        }
    }.less);
    while (c.free.items.len > 0 and kinds.items.len > 0) {
        var weights: std.ArrayList(f64) = .empty;
        for (kinds.items) |k| weights.append(allocator, k.weight) catch return error.OutOfMemory;
        const pick = c.rng.weighted(weights.items);
        const ok = switch (kinds.items[pick].kind) {
            .woth => try c.woth(),
            .barren => try c.barren(),
            .item => try c.locationHint(.item, majors.items),
            .sometimes => try c.locationHint(.sometimes, sometimes.items),
            .random => try c.locationHint(.random, named.items),
            .junk => blk: {
                try c.junk();
                break :blk true;
            },
            .always => false,
        };
        if (!ok) _ = kinds.orderedRemove(pick);
    }
    while (c.free.items.len > 0) try c.junk();

    std.mem.sort(Hint, c.hints.items, {}, struct {
        fn less(_: void, x: Hint, y: Hint) bool {
            return std.mem.order(u8, x.label, y.label) == .lt;
        }
    }.less);
    return c.hints.items;
}

/// The hint's sentence. `marked`: names between \x01 and \x02 (shown in the highlight colour).
pub fn text(allocator: Allocator, world: *World, hint: Hint, marked: bool) error{OutOfMemory}![]const u8 {
    if (hint.kind == .junk) return junk_lines[hint.line];
    const open: []const u8 = if (marked) "\x01" else "";
    const close: []const u8 = if (marked) "\x02" else "";
    const area = areaName(hint.area);
    const item = if (hint.item) |i| try world.itemNameById(allocator, i) else "";
    const location = if (hint.location) |l| world.locations.items[l].name else "";
    return switch (hint.kind) {
        .always, .sometimes, .random => std.fmt.allocPrint(allocator, "They say {s}{s}{s} holds the {s}{s}{s}.", .{ open, location, close, open, item, close }),
        .woth => std.fmt.allocPrint(allocator, "They say {s}{s}{s} holds something the hero cannot do without.", .{ open, area, close }),
        .barren => std.fmt.allocPrint(allocator, "They say searching {s}{s}{s} would only waste the hero's time.", .{ open, area, close }),
        .item => std.fmt.allocPrint(allocator, "They say {s}{s}{s} hides the {s}{s}{s}.", .{ open, area, close, open, item, close }),
        .junk => unreachable,
    };
}

// --------------------------------------------------------------------------------------------------- writing

fn tag(allocator: Allocator, group: u16, typ: u16, params: []const u8) error{OutOfMemory}![]u8 {
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

/// The tags a UTF-8 message opens with (its colour, size and voice), and the group-0 ones among them.
fn leadTags(allocator: Allocator, raw: []const u8) error{OutOfMemory}!struct { lead: []const u8, style: []const u8 } {
    var lead: std.ArrayList(u8) = .empty;
    var style: std.ArrayList(u8) = .empty;
    var j: usize = 0;
    while (j + 7 <= raw.len and raw[j] == 0x0E) {
        const group = std.mem.readInt(u16, raw[j + 1 ..][0..2], .little);
        const plen = std.mem.readInt(u16, raw[j + 5 ..][0..2], .little);
        const end = @min(raw.len, j + 7 + plen);
        try lead.appendSlice(allocator, raw[j..end]);
        if (group == 0) try style.appendSlice(allocator, raw[j..end]);
        j += 7 + plen;
    }
    return .{ .lead = lead.items, .style = style.items };
}

fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| if (c != 0x01 and c != 0x02 and (c & 0xC0) != 0x80) {
        n += 1;
    };
    return n;
}

/// The sentence broken into rows of at most `width` characters (markers not counted).
fn rows(allocator: Allocator, sentence: []const u8, width: usize) error{OutOfMemory}![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var row: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, sentence, " \t\n");
    while (words.next()) |word| {
        var candidate: std.ArrayList(u8) = .empty;
        if (row.items.len > 0) {
            try candidate.appendSlice(allocator, row.items);
            try candidate.append(allocator, ' ');
        }
        try candidate.appendSlice(allocator, word);
        if (row.items.len > 0 and visibleLen(candidate.items) > width) {
            try out.append(allocator, row.items);
            candidate = .empty;
            try candidate.appendSlice(allocator, word);
        }
        row = candidate;
    }
    if (row.items.len > 0) try out.append(allocator, row.items);
    return out.items;
}

/// A UTF-8 stone message saying `sentence` in the look of the stone's original line.
fn stoneLine(allocator: Allocator, original: []const u8, sentence: []const u8) error{OutOfMemory}![]const u8 {
    const tags = try leadTags(allocator, original);
    const page_break = try tag(allocator, 0, 4, "");
    const highlight = try tag(allocator, 0, 3, "\x00\x00");
    const reset = try tag(allocator, 0, 3, "\xff\xff");
    const lines = try rows(allocator, sentence, hint_width);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, tags.lead);
    var i: usize = 0;
    while (i < lines.len) : (i += hint_rows) {
        if (i > 0) {
            try out.appendSlice(allocator, page_break);
            try out.appendSlice(allocator, tags.style);
        }
        const end = @min(lines.len, i + hint_rows);
        for (lines[i..end], 0..) |line, k| {
            if (k > 0) try out.append(allocator, '\n');
            for (line) |ch| {
                switch (ch) {
                    0x01 => try out.appendSlice(allocator, highlight),
                    0x02 => try out.appendSlice(allocator, reset),
                    else => try out.append(allocator, ch),
                }
            }
        }
    }
    try out.append(allocator, 0);
    return out.items;
}

/// Every language archive's stone lines (English sentences, like the item names the spoiler uses).
pub fn writeText(world: *World, patches: *patchset.PatchSet, hints: []const Hint, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    var done: usize = 0;
    const names = world.files.listDir(a, "Mals") catch return error.GameFiles;
    for (names) |fname| {
        if (!std.mem.endsWith(u8, fname, ".sarc.zs")) continue;
        // one language at a time: its archive and rebuilt copy are freed before the next (a .nup has 16 languages)
        var file_arena = patches.fileArena();
        defer file_arena.deinit();
        const la = file_arena.allocator();
        const rel = std.fmt.allocPrint(la, "Mals/{s}", .{fname}) catch return error.OutOfMemory;
        const orig = try patches.readInto(la, rel);
        const entry = (try sarc.find(la, orig.data, gossip_messages)) orelse continue;
        if (!msbt.isUtf8(entry.data)) {
            progress.log("warning: {s} stone text is not UTF-8; hints skipped for it", .{fname});
            continue;
        }
        const r = try msbt.raw(la, entry.data);
        var new: std.ArrayList(msbt.NewText) = .empty;
        for (hints) |h| {
            const original = r.text(h.label) orelse continue;
            const sentence = try text(la, world, h, true);
            new.append(la, .{ .label = h.label, .text = try stoneLine(la, original, sentence) }) catch return error.OutOfMemory;
        }
        if (new.items.len == 0) continue;
        const msg = try msbt.setRaw(la, entry.data, new.items);
        const archive = sarc.rebuild(la, orig.data, &.{.{ .name = gossip_messages, .data = msg }}, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidData,
        };
        try patches.emitZs(rel, orig, archive);
        done += 1;
    }
    progress.log("Hints: {d} stones written in {d} languages", .{ hints.len, done });
}

/// GossipStone flow where every Mask of Truth question on the way to the stone's line sends each answer where the
/// needed one went (has it, wears it), so stones speak without the mask.
pub fn stonesWithoutMask(allocator: Allocator, data: []const u8, progress: *Progress) PatchError![]u8 {
    var doc = try flows.readFlow(allocator, data, "GossipStone", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "GossipStone: no flowchart", .{});
    var gates: std.ArrayList(u16) = .empty;
    var queries: std.ArrayList([]const u8) = .empty;
    for (fc.events.items, 0..) |*e, i| {
        if (e.kind != .switch_) continue;
        const p = e.kind.switch_.params orelse continue;
        var mentions = false;
        for (p.items.items) |it| if (it.value.asString()) |s| if (std.mem.eql(u8, s, mask_of_truth_actor)) {
            mentions = true;
        };
        if (!mentions) continue;
        gates.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        queries.append(allocator, fc.queryName(e) orelse "") catch return error.OutOfMemory;
    }
    std.mem.sort([]const u8, queries.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    if (queries.items.len != 2 or !std.mem.eql(u8, queries.items[0], "EventQueryIsExistInPouch") or !std.mem.eql(u8, queries.items[1], "EventQueryPlayerIsEquipArmor")) {
        return progress.fail(error.NotAsExpected, "GossipStone: Mask of Truth questions not as expected", .{});
    }
    for (gates.items) |g| {
        const e = &fc.events.items[g];
        var target: ?u16 = null;
        for (e.kind.switch_.cases.items) |cs| if (cs.value == 0) {
            target = cs.event;
        };
        const t = target orelse return progress.fail(error.NotAsExpected, "GossipStone: {s} has no 'yes' case", .{e.name});
        for (e.kind.switch_.cases.items) |*cs| cs.event = t;
    }
    return flows.writeBack(allocator, &doc, "GossipStone", progress);
}
