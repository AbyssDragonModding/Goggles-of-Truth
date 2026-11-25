//! Manual test checklist for a seed: checklist.xlsx, laid out for Google Sheets / Excel:
//!
//!   A-G   Seed info (version, seed, settings string, tester; A-B), setting totals (F-G), then the seed's settings:
//!         Category | Setting | Value | Expected In-Game | How to Test | Result | Notes
//!   H-I   empty spacer columns
//!   J-O   Check totals and then every randomized check, grouped by region:
//!         Region | Location | Vanilla Item | Randomized Item | Result | Notes
//!
//! Result is a dropdown: "Pass" (green), "Partial" (orange), "Fail" (red) or empty (untested). Testers export the
//! filled-in sheet as CSV for bug reports; that CSV keeps this layout, so results can be read by column position.

const std = @import("std");
const xlsx = @import("../formats/xlsx.zig");
const settings_mod = @import("../settings/settings.zig");
const world_mod = @import("../game/world.zig");
const fill = @import("fill.zig");
const fsmod = @import("../core/fs.zig");
const version_mod = @import("../version.zig");
const Allocator = std.mem.Allocator;
const World = world_mod.World;
const Settings = settings_mod.Settings;
const Key = settings_mod.Key;

const set_cols = [_][]const u8{ "Category", "Setting", "Value", "Expected In-Game", "How to Test", "Result", "Notes" };
const chk_cols = [_][]const u8{ "Region", "Location", "Vanilla Item", "Randomized Item", "Result", "Notes" };
/// empty columns between the two blocks
const gap = 2;
/// 0-based column of "Region" (column J)
const chk_start = set_cols.len + gap;
/// rows 1-5: seed info, setting totals and check totals
const info_rows = 5;
/// setting totals: labels in column F, numbers in G
const set_totals = 5;
/// row 7: column headers (row 6 is empty)
const header_row = info_rows + 2;

const Result = struct { value: []const u8, name: []const u8, color: []const u8 };
const results = [_]Result{
    .{ .value = "Pass", .name = "Passed", .color = "B7E1CD" },
    .{ .value = "Partial", .name = "Partial", .color = "F9CB9C" },
    .{ .value = "Fail", .name = "Failed", .color = "F4C7C3" },
};

const Test = struct { expected: []const u8, how: []const u8 };

/// What to look for in-game for a setting's value, or null when there is nothing to see.
fn settingTest(a: Allocator, key: Key, st: *const Settings) error{OutOfMemory}!?Test {
    const v = st.get(key);
    const on = v == .boolean and v.boolean;
    const c = if (v == .choice) v.choice else "";
    const is = struct {
        fn f(x: []const u8, y: []const u8) bool {
            return std.mem.eql(u8, x, y);
        }
    }.f;
    return switch (key) {
        .open_forest => if (is(c, "closed"))
            Test{ .expected = "Kokiri boy blocks the exit until the Deku Tree is beaten", .how = "Walk to the forest exit bridge before the Deku Tree" }
        else if (is(c, "closed_deku"))
            Test{ .expected = "Exit open from the start; Mido still asks for sword + shield", .how = "Leave the forest at once; talk to Mido without sword/shield" }
        else
            Test{ .expected = "Exit open and Mido gone", .how = "Leave the forest at once; walk straight to the Deku Tree" },
        .open_zora => if (is(c, "open")) Test{ .expected = "King Zora already moved aside; Fountain + Jabu-Jabu reachable without Ruto's Letter", .how = "Go behind King Zora as child without the letter" } else null,
        .open_door => if (is(c, "open")) Test{ .expected = "Door of Time starts open (Master Sword may still check story)", .how = "Enter the Temple of Time without stones / Song of Time; try the pedestal" } else null,
        .open_dmt => if (on)
            Test{ .expected = "Kakariko's Death Mountain gate is open for child Link and the Happy Mask Shop is open; Zelda's Letter isn't in the seed", .how = "As child, walk up the Kakariko path to Death Mountain; borrow the Keaton Mask" }
        else
            Test{ .expected = "The Kakariko gate soldier wants Zelda's Letter", .how = "Show him the letter as child" },
        .starting_age => if (is(c, "adult"))
            Test{ .expected = "A new game starts as adult Link on the platform in the Temple of Time, holding the Master Sword; Rauru's check is already yours; putting the sword back makes Link a child, who can walk out of the open Door of Time and into Kokiri Forest", .how = "Start a new save; put the Master Sword back; as child, walk to Kokiri Forest; pull the sword again" }
        else if (is(c, "random"))
            Test{ .expected = "A new game starts as the age the spoiler log names (\"This seed\")", .how = "Start a new save; compare with the spoiler log" }
        else
            null,
        .barren_dungeons => if (!is(c, "off")) Test{ .expected = "The Temple of Time altar names the barren dungeons (second page); their checks hold only rupees (and the dungeon's own keys when keys stay in their dungeons); the boss reward, boss Heart Container and song are elsewhere", .how = "Read the altar; open checks in a barren dungeon; compare with the spoiler log (\"This seed\")" } else null,
        .starting_inventory => if (st.startingInventory().len > 0) Test{ .expected = "A new save already owns the Starting Inventory (spoiler log, \"This seed\"); items with a window are handed over at the start (adult start: after the Master Sword pull); none of them is found again in the seed (a song with Song Locations may be)", .how = "Start a new save; check the pause menu; compare with the spoiler log" } else null,
        .skip_npc_dialogs => if (on) Test{ .expected = "Characters' long story talks go straight to their short line (Saria after the Deku Tree); talks that give items or move a quest still play", .how = "Talk to Saria and other Kokiri at each quest stage; talk to the characters who give checks" } else null,
        .skip_child_zelda => if (on) Test{ .expected = "New save already owns Zelda's, Malon's and Impa's items (see their Check rows); Malon and Talon are at Lon Lon Ranch; Hyrule Field has day and night; Zelda isn't in the courtyard", .how = "Start a new save, check the pause menu, then visit Lon Lon Ranch and Hyrule Castle" } else null,
        .shuffle_rewards => if (is(c, "reward"))
            Test{ .expected = "Bosses give a shuffled Spiritual Stone / Medallion", .how = "Beat a boss; compare with the spoiler" }
        else if (is(c, "anywhere"))
            Test{ .expected = "Bosses give random items; stones/medallions are found in other checks; the Door of Time still opens after the three child dungeons", .how = "Beat a boss; open a check holding a stone or medallion" }
        else
            null,
        .skip_epona_race => if (on) Test{ .expected = "A new save owns Epona: Epona's Song as adult calls her anywhere you can ride", .how = "Start a new save; as adult with Epona's Song, play it in Hyrule Field" } else null,
        .saria_song_ocarina => if (on)
            Test{ .expected = "Saria teaches her song in Sacred Forest Meadow with just an ocarina", .how = "With an ocarina and before meeting Zelda, walk up to Saria on the stump" }
        else
            Test{ .expected = "Saria's Song needs meeting Zelda first", .how = "Visit Saria before and after Zelda" },
        .shuffle_kokiri_sword => if (on) null else Test{ .expected = "Kokiri Sword is in its normal chest", .how = "Open the Kokiri Sword chest" },
        .shopsanity => if (!is(c, "off")) Test{
            .expected = try std.fmt.allocPrint(a, "Shop shelves sell randomized items once each, at the listed price ({s} per shop); every chosen shelf shows a real item", .{c}),
            .how = "Visit the Kokiri, Goron and Zora shops, the Market and Kakariko shops; buy a shuffled item; buy one in the Kokiri Shop before the Deku Tree and check it's still gone after",
        } else null,
        .shuffle_scrubs => if (on) Test{ .expected = "The four one-time Business Scrubs sell randomized items and name them", .how = "Buy from the Lost Woods stick and nut scrubs, the Hyrule Field and Crater heart scrubs" } else null,
        .shuffle_quest => if (on) Test{ .expected = "Zelda's Letter, the Light Arrows and Biggoron give randomized items", .how = "Meet Zelda; get the Light Arrows; finish the trade sequence" } else null,
        .shuffle_ocarinas => if (on) Test{ .expected = "No Saria goodbye / Fairy Ocarina on the forest bridge; ocarinas are found as checks", .how = "Beat the Deku Tree and cross the forest bridge; check the spoiler for both ocarinas" } else null,
        .shuffle_house => if (on) Test{ .expected = "All five Skulltula House rewards (10-50 tokens) are random; the two wallets are in chests (the first gives the Adult's Wallet, the second the Giant's Wallet)", .how = "Turn in 10 tokens at the Skulltula House; open a chest holding a wallet" } else null,
        .tokensanity => if (!is(c, "off")) Test{
            .expected = try std.fmt.allocPrint(a, "Gold Skulltulas drop randomized items ({s}); a drop floats like a token and is collected by touching it; the Skulltula only stays dead once its drop is collected, rupees and refills included (they float too)", .{c}),
            .how = "Kill a Gold Skulltula on a vine and touch its drop while climbing; kill one, leave without the drop, come back",
        } else null,
        .skip_cutscenes => if (on) Test{ .expected = "Every cutscene can be skipped (opening, credits too)", .how = "Press the skip button in the opening" } else null,
        .refill_needs_item => if (on) Test{ .expected = "Arrow / bomb / Bombchu / seed / nut / stick chests give a blue rupee without the Bow / Bomb Bag / Slingshot / a Deku Nut / a Deku Stick picked up first", .how = "Open a refill chest (see Check rows) before owning its item" } else null,
        .big_poe_one => if (on) Test{ .expected = "The Big Poe buyer gives his reward for a single Big Poe", .how = "Adult: catch one Big Poe in Hyrule Field, sell it in the Market ghost shop" } else null,
        .skip_kaepora => if (on) Test{ .expected = "Kaepora doesn't stop you outside Kokiri Forest, in the Lost Woods after Saria's Song, in Hyrule Field (also towards Lake Hylia), in front of Hyrule Castle or at Zora's River; the quest menu and the field music work", .how = "Leave Kokiri Forest, go back into the Lost Woods after Saria's Song, cross Hyrule Field towards the castle and Lake Hylia, go up Zora's River" } else null,
        .gs_any_time => if (on) Test{ .expected = "Night-only Gold Skulltulas are there by day; adult-only overworld ones are there for child Link too (same Skulltula, counts once)", .how = "By day: Kokiri Forest (House of Twins), Zora's River, Gerudo Valley, Lon Lon Ranch. As child: Kakariko, Death Mountain Trail, Goron City, Sacred Forest Meadow" } else null,
        .skip_ganon_trials => if (on) Test{ .expected = "Ganon's Castle: the six trial barriers are gone from the start; the tower is open", .how = "Debug menu: go into Ganon's Castle as adult; walk to the tower stairs in the middle room" } else null,
        .anju_one_cucco => if (on) Test{ .expected = "Anju's minigame finishes after returning 1 cucco", .how = "Kakariko, child: return one cucco to the pen" } else null,
        .bag_bombs_no_bracelet => if (on)
            Test{ .expected = "Bag bombs can be pulled out and thrown without the Goron Bracelet", .how = "Get a Bomb Bag before the bracelet; use a bomb" }
        else
            Test{ .expected = "Bombs need the Goron Bracelet (logic gives the bracelet first)", .how = "Check the bracelet is found before bombs are needed" },
        .skip_opening => if (on) Test{ .expected = "A new game skips the opening movie", .how = "Start a new save" } else null,
        .skip_deku_talk => if (on) Test{ .expected = "The Great Deku Tree's speech doesn't play; his mouth is open", .how = "Walk up to the Deku Tree (after showing Mido sword + shield unless Kokiri Forest is Open)" } else null,
        .skip_story_scenes => if (on) Test{ .expected = "Rauru, the sages' awakenings, Sheik/Zelda in the Temple of Time, the stone scenes Saria's bridge goodbye, the Kokiri Sword chest's sword swing, the rest of each post-boss scene chain, Sheik/Ruto/Nabooru before the adult temples and Ganon's Castle's trial scenes don't play; their items are given straight away. Area intros: First-arrival intros don't play: Kakariko, Graveyard, Hyrule Castle, Lake Hylia, Gerudo Valley/Fortress, Zora's River/Fountain, Ganon's Castle, Fire Temple / Well / Spirit Temple entrances; their maps work; Kaepora is at Lake Hylia. Also: Deku Tree, Dodongo's Cavern, Death Mountain Trail/Crater, Goron City, Zora's Domain, Lon Lon Ranch, Castle Town, Sacred Forest Meadow, Colossus, Ice Cavern, Shadow Temple, Training Ground, Water Temple, inside Ganon's Castle, with their quest steps kept", .how = "Open the Kokiri Sword chest, leave Kokiri Forest (Fairy Ocarina), pull the Master Sword (Rauru's item), beat a boss (stone / medallion item), enter Ganon's Castle and clear a trial; arrive in those areas for the first time on a new save; open the map there" } else null,
        .quick_chests => if (on) Test{ .expected = "Chests open without the camera move or Link's opening animation; Link holds the item up", .how = "Open a big chest and a small chest" } else null,
        .hint_distribution => if (!is(c, "none")) Test{
            .expected = try std.fmt.allocPrint(a, "Gossip Stones give the hints listed in the spoiler ({s})", .{c}),
            .how = "Talk to a few Gossip Stones and compare with spoiler.txt",
        } else null,
        .gossip_stones => if (is(c, "no_mask")) Test{ .expected = "Gossip Stones speak without the Mask of Truth, at any age", .how = "Talk to a stone as child and as adult without the mask" } else null,
        else => null,
    };
}

/// Region order on the sheet: roughly the order a run visits them. Keys are stage folders (display names come from
/// the game's own text); the extra keys are for event checks whose area has no stage folder of its own here.
const region_order = [_][]const u8{
    "KokiriForest",        "LostWood",          "SacredForestMeadow", "InsideTheDekuTree", "HyruleField",       "Market",
    "TimeTemple",          "HyruleCastle",      "LonLonRanch",        "KakarikoVillage",   "Graveyard",         "DeathMountainTrail",
    "GoronCity",           "DeathMountainCrater", "DodongoCavern",    "ZoraRiver",         "ZoraDomain",        "ZoraFountain",
    "InsideJabuJabuBelly", "LakeHylia",         "BottomOfTheWell",    "IceCavern",         "ForestTemple",      "FireTemple",
    "WaterTemple",         "ShadowTemple",      "GerudoValley",       "GerudoFortress",    "GerudoTrainingGround", "HountedWasteland",
    "DesertColossus",      "SpiritTemple",      "GanonCastle",        "InsideGanonCastle",
};

const Pair = struct { key: []const u8, value: []const u8 };
const extra_region_names = [_]Pair{
    .{ .key = "TimeTemple", .value = "Temple of Time" }, .{ .key = "LonLonRanch", .value = "Lon Lon Ranch" }, .{ .key = "LakeHylia", .value = "Lake Hylia" },
};
/// event checks (no stage of their own) -> region, by exact name first, then by name prefix
const event_region = [_]Pair{
    .{ .key = "Song from Impa", .value = "HyruleCastle" },                   .{ .key = "Song from Malon", .value = "LonLonRanch" },
    .{ .key = "Song from Saria", .value = "SacredForestMeadow" },            .{ .key = "Song from Royal Familys Tomb", .value = "Graveyard" },
    .{ .key = "Song from Windmill", .value = "KakarikoVillage" },            .{ .key = "Song from Ocarina of Time", .value = "HyruleField" },
    .{ .key = "Sheik in Forest", .value = "SacredForestMeadow" },            .{ .key = "Sheik in Crater", .value = "DeathMountainCrater" },
    .{ .key = "Sheik in Ice Cavern", .value = "IceCavern" },                 .{ .key = "Sheik in Kakariko", .value = "KakarikoVillage" },
    .{ .key = "Sheik at Colossus", .value = "DesertColossus" },              .{ .key = "Sheik at Temple", .value = "TimeTemple" },
    .{ .key = "Queen Gohma (Kokiri Emerald)", .value = "InsideTheDekuTree" }, .{ .key = "King Dodongo (Goron Ruby)", .value = "DodongoCavern" },
    .{ .key = "Barinade (Zora Sapphire)", .value = "InsideJabuJabuBelly" },   .{ .key = "Phantom Ganon (Forest Medallion)", .value = "ForestTemple" },
    .{ .key = "Volvagia (Fire Medallion)", .value = "FireTemple" },          .{ .key = "Morpha (Water Medallion)", .value = "WaterTemple" },
    .{ .key = "Bongo Bongo (Shadow Medallion)", .value = "ShadowTemple" },   .{ .key = "Twinrova (Spirit Medallion)", .value = "SpiritTemple" },
    .{ .key = "Rauru (Light Medallion)", .value = "TimeTemple" },
};
const event_prefix = [_]Pair{
    .{ .key = "HF ", .value = "HyruleField" },         .{ .key = "HC ", .value = "HyruleCastle" },     .{ .key = "GC ", .value = "GoronCity" },
    .{ .key = "LW ", .value = "LostWood" },            .{ .key = "Market ", .value = "Market" },       .{ .key = "Kak ", .value = "KakarikoVillage" },
    .{ .key = "GF ", .value = "GerudoFortress" },      .{ .key = "Hideout ", .value = "GerudoFortress" }, .{ .key = "ZD ", .value = "ZoraDomain" },
    .{ .key = "ZR ", .value = "ZoraRiver" },           .{ .key = "ZF ", .value = "ZoraFountain" },     .{ .key = "ToT ", .value = "TimeTemple" },
    .{ .key = "LLR ", .value = "LonLonRanch" },        .{ .key = "LH ", .value = "LakeHylia" },        .{ .key = "Graveyard ", .value = "Graveyard" },
    .{ .key = "DMT ", .value = "DeathMountainTrail" }, .{ .key = "DMC ", .value = "DeathMountainCrater" }, .{ .key = "OGC ", .value = "GanonCastle" },
    .{ .key = "Colossus ", .value = "DesertColossus" },
};

fn regionKey(loc: *const world_mod.Location) []const u8 {
    if (loc.region) |r| return r;
    for (event_region) |p| if (std.mem.eql(u8, p.key, loc.name)) return p.value;
    for (event_prefix) |p| if (std.mem.startsWith(u8, loc.name, p.key)) return p.value;
    return "Other";
}

fn regionRank(key: []const u8) usize {
    for (region_order, 0..) |r, i| if (std.mem.eql(u8, r, key)) return i;
    return region_order.len;
}

/// Natural order of names (numbers compared as numbers, letters ignoring case).
fn naturalLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const an = std.fmt.parseInt(u64, a[i..ie], 10) catch 0;
            const bn = std.fmt.parseInt(u64, b[j..je], 10) catch 0;
            if (an != bn) return an < bn;
            i = ie;
            j = je;
            continue;
        }
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[j]);
        if (x != y) return x < y;
        i += 1;
        j += 1;
    }
    return a.len - i < b.len - j;
}

const CheckRow = struct {
    rank: usize,
    name: []const u8,
    cells: [4][]const u8,
};

fn valueText(a: Allocator, spec: *const settings_mod.Spec, v: settings_mod.Value) error{OutOfMemory}![]const u8 {
    return switch (v) {
        .boolean => |b| if (b) "On" else "Off",
        .choice => |c| if (spec.option(c)) |o| o.label else c,
        .list => |l| if (l.len > 0) try std.mem.join(a, ", ", l) else "(none)",
        .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
    };
}

fn putText(sheet: *xlsx.Sheet, row: usize, col: usize, text: []const u8) error{OutOfMemory}!void {
    const c = try sheet.cell(row, col);
    if (text.len > 0 and text[0] == '=') {
        c.value = .{ .formula = text[1..] };
    } else if (text.len > 0) {
        c.value = .{ .text = text };
    }
}

/// Rows 1-5 of a block: count, passed, partial, failed, untested (formulas over the block's Result column).
fn putTotals(a: Allocator, sheet: *xlsx.Sheet, label: []const u8, count: usize, label_col: usize, result_col: usize) error{OutOfMemory}!void {
    var buf: [4]u8 = undefined;
    const rc = try a.dupe(u8, xlsx.columnName(&buf, result_col));
    const vc = try a.dupe(u8, xlsx.columnName(&buf, label_col + 1));
    const range = try std.fmt.allocPrint(a, "{s}{d}:{s}{d}", .{ rc, header_row + 1, rc, header_row + @max(count, 1) });
    try putText(sheet, 0, label_col, label);
    (try sheet.cell(0, label_col + 1)).value = .{ .number = @intCast(count) };
    for (results, 1..) |r, i| {
        try putText(sheet, i, label_col, r.name);
        (try sheet.cell(i, label_col + 1)).value = .{ .formula = try std.fmt.allocPrint(a, "COUNTIF({s},\"{s}\")", .{ range, r.value }) };
    }
    try putText(sheet, 4, label_col, "Untested");
    (try sheet.cell(4, label_col + 1)).value = .{ .formula = try std.fmt.allocPrint(a, "{s}1-{s}2-{s}3-{s}4", .{ vc, vc, vc, vc }) };
}

/// Writes checklist.xlsx in the mod folder.
pub fn write(a: Allocator, world: *World, plan: *fill.Plan, filler: *fill.Filler, mod_root: []const u8, seed: []const u8, sstr: []const u8, fs: fsmod.Fs) (error{ OutOfMemory, WriteFailed })!void {
    const st = plan.st;
    const contents = filler.contents() catch return error.OutOfMemory;
    var sheet = xlsx.Sheet.init(a, "Checklist");

    // the settings rows
    var set_rows: std.ArrayList([7][]const u8) = .empty;
    for (&settings_mod.specs) |*s| {
        const t = try settingTest(a, s.key, st);
        try set_rows.append(a, .{
            try std.fmt.allocPrint(a, "{s} \u{b7} {s}", .{ s.tab, s.group }),
            s.label,
            try valueText(a, s, st.get(s.key)),
            if (t) |x| x.expected else "",
            if (t) |x| x.how else "",
            "",
            "",
        });
    }

    // the check rows: every shuffled location's item, in region order, then by name
    var chk_rows: std.ArrayList(CheckRow) = .empty;
    for (plan.shuffled.items) |i| {
        const loc = &world.locations.items[i];
        const item = contents[i] orelse continue;
        var name = try world.itemNameById(a, item);
        if (loc.kind == .shop) {
            name = if (item == loc.vanilla or world.items.isJunk(item)) "(normal shop goods)" else try std.fmt.allocPrint(a, "{s} ({d} rupees)", .{ name, plan.shop_prices[i].? });
        }
        if (st.flag(.refill_needs_item) and loc.kind == .chest) {
            if (fill.refillContainer(world.items.name(item))) |need| {
                const short = if (std.mem.startsWith(u8, need, "Item_")) need["Item_".len..] else need;
                name = try std.fmt.allocPrint(a, "{s} (Blue Rupee without the {s})", .{ name, try world.itemName(a, short) });
            }
        }
        const key = regionKey(loc);
        const region_name = world.region_text.get(key) orelse blk: {
            for (extra_region_names) |p| if (std.mem.eql(u8, p.key, key)) break :blk p.value;
            break :blk world.regionName(key);
        };
        try chk_rows.append(a, .{ .rank = regionRank(key), .name = loc.name, .cells = .{ region_name, loc.name, try world.itemNameById(a, loc.vanilla), name } });
    }
    std.mem.sort(CheckRow, chk_rows.items, {}, struct {
        fn less(_: void, x: CheckRow, y: CheckRow) bool {
            if (x.rank != y.rank) return x.rank < y.rank;
            return naturalLess(x.name, y.name);
        }
    }.less);

    // rows 1-5: seed info and the totals of both blocks
    const info = [_][2][]const u8{ .{ "Version", version_mod.version }, .{ "Seed", seed }, .{ "Settings String", sstr }, .{ "Emulator / Tester", "" } };
    for (info, 0..) |row, i| {
        try putText(&sheet, i, 0, row[0]);
        try putText(&sheet, i, 1, row[1]);
    }
    try putTotals(a, &sheet, "Settings", set_rows.items.len, set_totals, 5);
    try putTotals(a, &sheet, "Checks", chk_rows.items.len, chk_start, chk_start + 4);
    for (set_cols, 0..) |h, c| try putText(&sheet, header_row - 1, c, h);
    for (chk_cols, 0..) |h, c| try putText(&sheet, header_row - 1, chk_start + c, h);
    for (set_rows.items, 0..) |row, r| for (row, 0..) |text, c| try putText(&sheet, header_row + r, c, text);
    for (chk_rows.items, 0..) |row, r| for (row.cells, 0..) |text, c| try putText(&sheet, header_row + r, chk_start + c, text);
    // the grid covers both blocks to the longest one
    const last_row = header_row + @max(set_rows.items.len, chk_rows.items.len);
    _ = try sheet.cell(last_row - 1, chk_start + chk_cols.len - 1);

    // ---- styles
    const label_fill = "DCE6F1";
    for (0..info_rows) |r| {
        for ([_]usize{ 0, set_totals, chk_start }) |c| {
            if (r == info_rows - 1 and c == 0) continue; // the seed info has one row fewer than the totals
            const cell = try sheet.cell(r, c);
            cell.style.font = .bold;
            cell.style.fill = label_fill;
        }
    }
    (try sheet.cell(3, 1)).style.fill = "FFF8DC"; // Emulator / Tester: for the tester to fill in
    for (0..set_cols.len) |c| try headerStyle(&sheet, c);
    for (0..chk_cols.len) |c| try headerStyle(&sheet, chk_start + c);

    var prev_cat: []const u8 = "";
    for (set_rows.items, 0..) |row, r| {
        const new_cat = !std.mem.eql(u8, row[0], prev_cat);
        for (0..set_cols.len) |c| {
            const cell = try sheet.cell(header_row + r, c);
            cell.style.alignment = if (c == 3 or c == 4 or c == 6) .wrap_top else .top;
            if (new_cat) cell.style.top_border = true;
        }
        prev_cat = row[0];
    }
    const bands = [_][]const u8{ "FFFFFF", "EEF2F7" };
    var band: usize = 1;
    var prev_region: []const u8 = "";
    for (chk_rows.items, 0..) |row, r| {
        const new_region = !std.mem.eql(u8, row.cells[0], prev_region);
        if (new_region) band ^= 1;
        for (0..chk_cols.len) |c| {
            const cell = try sheet.cell(header_row + r, chk_start + c);
            cell.style.fill = bands[band];
            cell.style.alignment = if (c == 5) .wrap_top else .top;
            if (new_region) cell.style.top_border = true;
        }
        if (new_region) (try sheet.cell(header_row + r, chk_start)).style.font = .bold;
        prev_region = row.cells[0];
    }

    // the Result dropdowns, centred, coloured by value
    var buf: [4]u8 = undefined;
    const chk_result = try a.dupe(u8, xlsx.columnName(&buf, chk_start + 4));
    const result_cols = [_]struct { col: usize, name: []const u8, last: usize }{
        .{ .col = 5, .name = "F", .last = header_row + set_rows.items.len },
        .{ .col = chk_start + 4, .name = chk_result, .last = header_row + chk_rows.items.len },
    };
    var values: [results.len][]const u8 = undefined;
    for (results, 0..) |r, i| values[i] = r.value;
    for (result_cols) |rc| {
        var r: usize = header_row - 1;
        while (r < rc.last) : (r += 1) (try sheet.cell(r, rc.col)).style.alignment = .center;
        const range = try std.fmt.allocPrint(a, "{s}{d}:{s}{d}", .{ rc.name, header_row + 1, rc.name, @max(rc.last, header_row + 1) });
        try sheet.validations.append(a, .{ .range = range, .values = &values, .prompt_title = "Result", .prompt = "Pass, Partial, Fail, or leave empty if not tested yet" });
        for (results) |res| try sheet.conditional.append(a, .{ .range = range, .equals = res.value, .color = res.color });
    }

    const widths = [_]f64{ 30, 34, 22, 46, 46, 11, 36, 3, 3 };
    for (widths, 0..) |w, c| try sheet.setWidth(c, w);
    const chk_widths = [_]f64{ 24, 44, 26, 40, 11, 40 };
    for (chk_widths, 0..) |w, c| try sheet.setWidth(chk_start + c, w);
    sheet.freeze_row = header_row + 1;
    const first = try a.dupe(u8, xlsx.columnName(&buf, chk_start));
    const last = try a.dupe(u8, xlsx.columnName(&buf, chk_start + chk_cols.len - 1));
    sheet.auto_filter = try std.fmt.allocPrint(a, "{s}{d}:{s}{d}", .{ first, header_row, last, @max(header_row + chk_rows.items.len, header_row) });

    const data = try xlsx.write(a, &sheet);
    fs.makePath(mod_root) catch return error.WriteFailed;
    const path = fsmod.join(a, &.{ mod_root, "checklist.xlsx" }) catch return error.OutOfMemory;
    fs.writeAll(path, data) catch return error.WriteFailed;
}

fn headerStyle(sheet: *xlsx.Sheet, col: usize) error{OutOfMemory}!void {
    const cell = try sheet.cell(header_row - 1, col);
    cell.style.font = .bold_white;
    cell.style.fill = "1F3A5F";
}
