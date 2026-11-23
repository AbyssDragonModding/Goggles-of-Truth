//! A seed folder's settings.txt, read back: which release made it, its placement version, its seed and its settings
//! string. Rebuilding a seed makes it again from these, and per-seed saves compare them to know whether a folder's
//! stored saves still fit its mod.
//!
//! settings.txt since 0.7.4:            before 0.7.4 (no placement line):
//!     Goggles of Truth Randomizer 0.7.4    Goggles of Truth Randomizer 0.7.3
//!     Placement version: 0.7.3             Seed: ABCDEFGHJK
//!     Seed: ABCDEFGHJK                     Settings string: eNq...
//!     Settings string: eNq...
//!     Test placements: Kokiri Forest Chest 1=Bomb Bag; Kokiri Forest Chest 3=Goron Bracelet   (test seeds only)
//! Before 0.7.4 the release itself went into the seed's random stream, so an older file's placement version is its
//! release.

const std = @import("std");

pub const SeedInfo = struct {
    /// the release that made the folder ("0.7.4")
    release: []const u8,
    /// the release whose placements it has (version.zig)
    placement_version: []const u8,
    seed: []const u8,
    settings_string: []const u8,
    /// a test seed's chosen placements ("" for a normal seed), as written by formatTestPlacements
    test_placements: []const u8 = "",

    /// Two builds of a seed have the same items in the same places (so the same saves fit both).
    pub fn samePlacements(self: SeedInfo, other: SeedInfo) bool {
        return std.mem.eql(u8, self.placement_version, other.placement_version) and
            std.mem.eql(u8, self.seed, other.seed) and
            std.mem.eql(u8, self.settings_string, other.settings_string) and
            std.mem.eql(u8, self.test_placements, other.test_placements);
    }
};

/// A test seed's chosen placement (`goggles_cli generate --place "LOCATION=ITEM"`): the location is a location's
/// name as the spoiler log shows it (or its id), the item an item's name as the spoiler log shows it (or its key).
pub const TestPlacement = struct {
    location: []const u8,
    item: []const u8,
};

pub const TestPlacementError = error{ OutOfMemory, InvalidTestPlacement };

/// "LOCATION=ITEM" -> a TestPlacement (pointing into `text`).
pub fn parseTestPlacement(text: []const u8) TestPlacementError!TestPlacement {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidTestPlacement;
    const location = std.mem.trim(u8, text[0..equals], " \t");
    const item = std.mem.trim(u8, text[equals + 1 ..], " \t");
    if (location.len == 0 or item.len == 0 or std.mem.indexOfScalar(u8, item, '=') != null) return error.InvalidTestPlacement;
    if (std.mem.indexOfScalar(u8, location, ';') != null or std.mem.indexOfScalar(u8, item, ';') != null) return error.InvalidTestPlacement;
    return TestPlacement{ .location = location, .item = item };
}

/// The settings.txt form: "LOCATION=ITEM; LOCATION=ITEM" ("" for none).
pub fn formatTestPlacements(allocator: std.mem.Allocator, placements: []const TestPlacement) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (placements, 0..) |placement, i| {
        if (i > 0) try out.appendSlice(allocator, "; ");
        try out.print(allocator, "{s}={s}", .{ placement.location, placement.item });
    }
    return out.items;
}

/// Reads formatTestPlacements' text back.
pub fn parseTestPlacements(allocator: std.mem.Allocator, text: []const u8) TestPlacementError![]TestPlacement {
    var out: std.ArrayList(TestPlacement) = .empty;
    var parts = std.mem.splitScalar(u8, text, ';');
    while (parts.next()) |part| {
        if (std.mem.trim(u8, part, " \t").len == 0) continue;
        try out.append(allocator, try parseTestPlacement(part));
    }
    return out.items;
}

/// Reads settings.txt's text; null when it isn't one (no release line, seed or settings string). The returned
/// strings point into `text`.
pub fn parseSettingsText(text: []const u8) ?SeedInfo {
    var release: ?[]const u8 = null;
    var placement_version: ?[]const u8 = null;
    var seed: ?[]const u8 = null;
    var settings_string: ?[]const u8 = null;
    var test_placements: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (first_line) {
            first_line = false;
            // "<program name> <release>": the release is the last word
            const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return null;
            release = line[space + 1 ..];
            continue;
        }
        if (valueAfter(line, "Placement version:")) |v| placement_version = v;
        if (valueAfter(line, "Seed:")) |v| seed = v;
        if (valueAfter(line, "Settings string:")) |v| settings_string = v;
        if (valueAfter(line, "Test placements:")) |v| test_placements = v;
    }
    const release_text = release orelse return null;
    if (release_text.len == 0) return null;
    return SeedInfo{
        .release = release_text,
        .placement_version = placement_version orelse release_text,
        .seed = seed orelse return null,
        .settings_string = settings_string orelse return null,
        .test_placements = test_placements,
    };
}

fn valueAfter(line: []const u8, label: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, label)) return null;
    const value = std.mem.trim(u8, line[label.len..], " \t");
    return if (value.len > 0) value else null;
}

test "settings.txt read back, old and new" {
    const new_text = "Goggles of Truth Randomizer 0.7.4\r\nPlacement version: 0.7.3\r\nSeed: ABCDEFGHJK\r\nSettings string: eNqX\r\n";
    const old_text = "Goggles of Truth Randomizer 0.7.3\nSeed: ABCDEFGHJK\nSettings string: eNqX\n";
    const new_info = parseSettingsText(new_text).?;
    const old_info = parseSettingsText(old_text).?;
    try std.testing.expectEqualStrings("0.7.4", new_info.release);
    try std.testing.expectEqualStrings("0.7.3", new_info.placement_version);
    try std.testing.expectEqualStrings("0.7.3", old_info.placement_version);
    try std.testing.expectEqualStrings("ABCDEFGHJK", old_info.seed);
    try std.testing.expect(new_info.samePlacements(old_info));

    const other_placements = parseSettingsText("Goggles of Truth Randomizer 0.7.2\nSeed: ABCDEFGHJK\nSettings string: eNqX\n").?;
    try std.testing.expect(!new_info.samePlacements(other_placements));
    try std.testing.expect(parseSettingsText("") == null);
    try std.testing.expect(parseSettingsText("Goggles of Truth Randomizer 0.7.4\nSeed: X\n") == null);

    // a test seed is not the same seed as the normal one with that seed number and settings string
    const test_seed = parseSettingsText("Goggles of Truth Randomizer 0.7.4\nPlacement version: 0.7.3\nSeed: ABCDEFGHJK\nSettings string: eNqX\nTest placements: Kokiri Forest Chest 1=Bomb Bag\n").?;
    try std.testing.expectEqualStrings("Kokiri Forest Chest 1=Bomb Bag", test_seed.test_placements);
    try std.testing.expect(!test_seed.samePlacements(new_info));
}

test "test placements written and read back" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]TestPlacement{
        .{ .location = "Kokiri Forest Chest 1", .item = "Bomb Bag" },
        .{ .location = "Kokiri Forest Chest 3", .item = "Goron Bracelet" },
    };
    const text = try formatTestPlacements(a, &placements);
    try std.testing.expectEqualStrings("Kokiri Forest Chest 1=Bomb Bag; Kokiri Forest Chest 3=Goron Bracelet", text);
    const back = try parseTestPlacements(a, text);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("Goron Bracelet", back[1].item);
    try std.testing.expectError(error.InvalidTestPlacement, parseTestPlacement("no equals sign"));
    try std.testing.expectError(error.InvalidTestPlacement, parseTestPlacement("=Bomb Bag"));
}
