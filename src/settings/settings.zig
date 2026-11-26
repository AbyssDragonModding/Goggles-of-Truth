//! Setting definitions (shared by the window, the command-line tool and the settings string), presets, the settings
//! string, and the test-status badges.
//!
//! The table itself is in table.zig. A setting's value is a `Value`; choice values always point at the option text
//! in the table, so a Settings struct never owns memory except the excluded-location list, which points at memory
//! its owner keeps (the window's list, or the generation arena).

const std = @import("std");
const table = @import("table.zig");
const Allocator = std.mem.Allocator;

pub const Key = table.Key;
pub const specs = table.specs;
pub const presets = table.presets;
pub const startinventory = @import("startinventory.zig");
pub const key_count = @typeInfo(Key).@"enum".field_names.len;

pub const Kind = enum { boolean, choice, int, list };

pub const Option = struct {
    value: []const u8,
    label: []const u8,
};

pub const Value = union(enum) {
    boolean: bool,
    choice: []const u8,
    int: i64,
    list: []const []const u8,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .boolean => |x| b == .boolean and b.boolean == x,
            .choice => |x| b == .choice and std.mem.eql(u8, x, b.choice),
            .int => |x| b == .int and b.int == x,
            .list => |x| b == .list and listsEql(x, b.list),
        };
    }
};

fn listsEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub const Spec = struct {
    key: Key,
    tab: []const u8,
    group: []const u8,
    label: []const u8,
    kind: Kind,
    options: []const Option = &.{},
    min: i64 = 0,
    max: i64 = 0,
    default: Value,
    tip: []const u8,

    /// The option `value`, as the table's own text (so it outlives any input), or null.
    pub fn option(self: *const Spec, value: []const u8) ?Option {
        for (self.options) |o| {
            if (std.mem.eql(u8, o.value, value)) return o;
        }
        return null;
    }

    pub fn optionIndex(self: *const Spec, value: []const u8) ?usize {
        for (self.options, 0..) |o, i| {
            if (std.mem.eql(u8, o.value, value)) return i;
        }
        return null;
    }
};

pub const KeyValue = struct {
    key: Key,
    value: Value,
};

pub const Preset = struct {
    name: []const u8,
    tip: []const u8,
    values: []const KeyValue,
};

// why: the setting table and the Key enum are written separately; a mismatch would read the wrong spec
comptime {
    for (specs, 0..) |s, i| {
        if (@intFromEnum(s.key) != i) @compileError("settings table out of order at " ++ @tagName(s.key));
    }
}

pub fn spec(key: Key) *const Spec {
    return &specs[@intFromEnum(key)];
}

/// The setting named `name` (as in user_settings.toml and the settings string), or null.
pub fn keyByName(name: []const u8) ?Key {
    return std.meta.stringToEnum(Key, name);
}

pub fn keyName(key: Key) []const u8 {
    return @tagName(key);
}

/// Settings that were renamed (old name, new name), and settings now part of every seed or removed.
pub const renamed = [_][2][]const u8{.{ "free_bombs", "bag_bombs_no_bracelet" }};
/// cache_files (Cache Compressed Files, 0.7.2) is always on since 0.7.3: an old user_settings.toml line is ignored.
pub const built_in = [_][]const u8{ "skip_saria_intro", "cache_files" };
pub const removed = [_][]const u8{"unrestricted_items"};

/// Settings merged into another (old name, new name): an old settings string or file with the old one on turns
/// the new one on. Skip Area Intro Cutscenes (skip_area_intros) is part of Skip Cutscenes since 0.8.0.
pub const merged = [_][2][]const u8{.{ "skip_area_intros", "skip_story_scenes" }};

/// The setting `name` was merged into (merged), or null.
pub fn mergedInto(name: []const u8) ?Key {
    for (merged) |m| {
        if (std.mem.eql(u8, m[0], name)) return keyByName(m[1]);
    }
    return null;
}

/// Turns on each setting an old, merged setting that was on went into (`merged_on`: the merged settings seen on).
pub fn applyMerged(st: *Settings, merged_on: []const Key) void {
    for (merged_on) |key| st.set(key, .{ .boolean = true });
}

/// The current name of a setting that may have been renamed.
pub fn currentName(name: []const u8) []const u8 {
    for (renamed) |r| {
        if (std.mem.eql(u8, r[0], name)) return r[1];
    }
    return name;
}

pub fn isRetired(name: []const u8) bool {
    for (built_in) |n| if (std.mem.eql(u8, n, name)) return true;
    for (removed) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// One seed's settings.
pub const Settings = struct {
    values: [key_count]Value,

    const Self = @This();

    pub fn defaults() Self {
        var self: Self = undefined;
        for (specs, 0..) |s, i| self.values[i] = s.default;
        return self;
    }

    pub fn get(self: *const Self, key: Key) Value {
        return self.values[@intFromEnum(key)];
    }

    pub fn set(self: *Self, key: Key, value: Value) void {
        self.values[@intFromEnum(key)] = value;
    }

    pub fn flag(self: *const Self, key: Key) bool {
        return switch (self.get(key)) {
            .boolean => |b| b,
            else => false,
        };
    }

    pub fn choice(self: *const Self, key: Key) []const u8 {
        return switch (self.get(key)) {
            .choice => |c| c,
            else => "",
        };
    }

    /// True when choice setting `key` is `value`.
    pub fn is(self: *const Self, key: Key, value: []const u8) bool {
        return std.mem.eql(u8, self.choice(key), value);
    }

    pub fn int(self: *const Self, key: Key) i64 {
        return switch (self.get(key)) {
            .int => |n| n,
            else => 0,
        };
    }

    /// Starting Inventory: entry ids, one per copy (startinventory.zig)
    pub fn startingInventory(self: *const Self) []const []const u8 {
        return switch (self.get(.starting_inventory)) {
            .list => |l| l,
            else => &.{},
        };
    }

    pub fn excluded(self: *const Self) []const []const u8 {
        return switch (self.get(.excluded_locations)) {
            .list => |l| l,
            else => &.{},
        };
    }

    /// Item Restrictions: "Location | Item" entries (parseItemRestriction reads one)
    pub fn itemRestrictions(self: *const Self) []const []const u8 {
        return switch (self.get(.item_restrictions)) {
            .list => |l| l,
            else => &.{},
        };
    }

    pub fn isExcluded(self: *const Self, name: []const u8) bool {
        for (self.excluded()) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// One Item Restrictions entry: `item` is never placed at `location` (both as the spoiler log names them).
pub const ItemRestriction = struct {
    location: []const u8,
    item: []const u8,
};

/// The separator of an Item Restrictions entry ("LW Deku Scrub Nut Upgrade | Bomb Bag"). Why '|': no location or
/// item name uses it, while '@' is in own-dungeon item keys and '=' separates test placements.
pub const item_restriction_separator = '|';

/// "Location | Item" -> its two names (trimmed, pointing into `entry`), or null when either is missing.
pub fn parseItemRestriction(entry: []const u8) ?ItemRestriction {
    const at = std.mem.indexOfScalar(u8, entry, item_restriction_separator) orelse return null;
    const location = std.mem.trim(u8, entry[0..at], " \t");
    const item = std.mem.trim(u8, entry[at + 1 ..], " \t");
    if (location.len == 0 or item.len == 0 or std.mem.indexOfScalar(u8, item, item_restriction_separator) != null) return null;
    return .{ .location = location, .item = item };
}

/// The entry text of a restriction, allocated with `allocator`.
pub fn formatItemRestriction(allocator: Allocator, restriction: ItemRestriction) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{s} {c} {s}", .{ restriction.location, item_restriction_separator, restriction.item });
}

test "item restriction entries" {
    const r = parseItemRestriction("  LW Deku Scrub Nut Upgrade |Bomb Bag ").?;
    try std.testing.expectEqualStrings("LW Deku Scrub Nut Upgrade", r.location);
    try std.testing.expectEqualStrings("Bomb Bag", r.item);
    try std.testing.expect(parseItemRestriction("no separator") == null);
    try std.testing.expect(parseItemRestriction(" | Bomb Bag") == null);
    try std.testing.expect(parseItemRestriction("A | B | C") == null);
    const text = try formatItemRestriction(std.testing.allocator, r);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("LW Deku Scrub Nut Upgrade | Bomb Bag", text);
}

// ------------------------------------------------------------------------------------- values from outside

/// A value read from user_settings.toml or the settings string's JSON, before it is checked.
pub const Input = union(enum) {
    boolean: bool,
    int: i64,
    string: []const u8,
    list: []const []const u8,
    /// anything else (a float, a table, a mixed list): never valid
    other,
};

/// The checked value of `input` for setting `key`, or null when it isn't allowed. Choice values are returned as the
/// table's own text; a list keeps pointing at the input's strings.
pub fn checkInput(key: Key, input: Input) ?Value {
    const s = spec(key);
    switch (s.kind) {
        .boolean => return if (input == .boolean) Value{ .boolean = input.boolean } else null,
        .choice => {
            if (input != .string) return null;
            const o = s.option(input.string) orelse return null;
            return Value{ .choice = o.value };
        },
        .int => {
            if (input != .int) return null;
            if (input.int < s.min or input.int > s.max) return null;
            return Value{ .int = input.int };
        },
        .list => return if (input == .list) Value{ .list = input.list } else null,
    }
}

/// Applies an older settings file's quirks: before 0.5.0's price settings the scrub setting held the price
/// ("off", "low", "regular", "random"). Returns true when `input` was such a value (and was applied).
pub fn applyLegacyScrubs(st: *Settings, input: Input, scrub_prices_given: bool) bool {
    if (input != .string) return false;
    const old = input.string;
    const known = [_][]const u8{ "off", "low", "regular", "random" };
    for (known) |k| {
        if (std.mem.eql(u8, k, old)) {
            st.set(.shuffle_scrubs, .{ .boolean = !std.mem.eql(u8, old, "off") });
            if (!std.mem.eql(u8, old, "off") and !scrub_prices_given) {
                if (spec(.scrub_prices).option(old)) |o| st.set(.scrub_prices, .{ .choice = o.value });
            }
            return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------------------------------------- presets

pub fn findPreset(name: []const u8) ?*const Preset {
    for (&presets) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// `st` with preset `name` applied (Excluded Locations, Item Restrictions, Create Spoiler Log and Per-Seed Saves are
/// kept).
pub fn applyPreset(st: Settings, preset: *const Preset) Settings {
    var out = st;
    for (preset.values) |kv| out.set(kv.key, kv.value);
    return out;
}

/// The settings a preset leaves alone: they decide what is excluded and where and how things are written, not how
/// the seed plays.
pub const non_gameplay_keys = [_]Key{ .excluded_locations, .item_restrictions, .create_spoiler, .per_seed_saves };

pub fn isGameplayKey(key: Key) bool {
    for (non_gameplay_keys) |k| if (k == key) return false;
    return true;
}

/// `st` with every gameplay setting taken from `source` (a saved custom preset); the others are kept.
pub fn applyGameplaySettings(st: Settings, source: *const Settings) Settings {
    var out = st;
    for (std.meta.tags(Key)) |key| {
        if (isGameplayKey(key)) out.set(key, source.get(key));
    }
    return out;
}

/// Whether two settings play the same: every gameplay setting is equal.
pub fn sameGameplaySettings(a: *const Settings, b: *const Settings) bool {
    for (std.meta.tags(Key)) |key| {
        if (isGameplayKey(key) and !Value.eql(a.get(key), b.get(key))) return false;
    }
    return true;
}

/// Name of the preset `st` matches exactly, or null (custom).
pub fn matchingPreset(st: *const Settings) ?[]const u8 {
    for (presets) |p| {
        var all_match = true;
        for (p.values) |kv| {
            if (!Value.eql(st.get(kv.key), kv.value)) {
                all_match = false;
                break;
            }
        }
        if (all_match) return p.name;
    }
    return null;
}

// why: every preset must set every gameplay setting, and only to options that exist
comptime {
    @setEvalBranchQuota(100000);
    for (presets) |p| {
        var count: usize = 0;
        for (p.values) |kv| {
            const s = specs[@intFromEnum(kv.key)];
            if (s.kind == .choice) {
                var found = false;
                for (s.options) |o| {
                    if (std.mem.eql(u8, o.value, kv.value.choice)) found = true;
                }
                if (!found) @compileError("preset " ++ p.name ++ " has an unknown option for " ++ @tagName(kv.key));
            }
            count += 1;
        }
        // the ones that aren't gameplay: Excluded Locations, Item Restrictions, Create Spoiler Log, Per-Seed Saves
        for (p.values) |kv| {
            for (non_gameplay_keys) |k| if (k == kv.key) @compileError("preset " ++ p.name ++ " sets " ++ @tagName(k));
        }
        if (count != key_count - non_gameplay_keys.len) @compileError("preset " ++ p.name ++ " doesn't set every gameplay setting");
    }
}

// ---------------------------------------------------------------------------------------------- test status

/// A setting's state, shown as a badge in the window. `new_feature`: added in the release being made and still being
/// tested by its developer (label note "(0.8.0 feature)"); it wins over the other notes, so new work stands out.
pub const Status = enum { stable, testing, experimental, new_feature };

/// The label note that marks a setting of the release being made (Status.new_feature).
pub const new_feature_note = "0.8.0 feature";

pub const SplitStatus = struct {
    text: []const u8,
    status: Status,
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

fn isStatusNote(text: []const u8) bool {
    return containsIgnoreCase(text, "experimental") or containsIgnoreCase(text, "testing") or containsIgnoreCase(text, "not working") or
        containsIgnoreCase(text, new_feature_note);
}

/// "Skip Area Intro Cutscenes" and .testing for "Skip Area Intro Cutscenes (needs further testing)".
/// "testing" anywhere in a note means In Testing (partly confirmed in-game); otherwise "experimental" or
/// "not working" means Experimental; no such note means Stable. A note inside other text
/// ("Remove (replaced by junk, experimental)") keeps the rest: "Remove (replaced by junk)".
/// The text is written into `buffer`.
pub fn splitStatus(buffer: []u8, text: []const u8) SplitStatus {
    var status: Status = .stable;
    var out = std.ArrayList(u8).initBuffer(buffer);
    var i: usize = 0;
    while (i < text.len) {
        // a "(...)" without nested parentheses whose inside names a status
        if (text[i] == '(') {
            if (std.mem.indexOfAnyPos(u8, text, i + 1, "()")) |close| {
                if (text[close] == ')' and isStatusNote(text[i + 1 .. close])) {
                    const note = text[i + 1 .. close];
                    if (containsIgnoreCase(note, new_feature_note)) {
                        status = .new_feature;
                    } else if (status == .new_feature) {
                        // a 0.8.0 feature keeps its badge whatever else its notes say
                    } else if (containsIgnoreCase(note, "testing")) {
                        status = .testing;
                    } else if (status == .stable) {
                        status = .experimental;
                    }
                    // drop the whitespace before the note
                    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) out.items.len -= 1;
                    // keep the note's parts that aren't status words
                    var kept: usize = 0;
                    var parts = std.mem.splitScalar(u8, note, ',');
                    while (parts.next()) |part| {
                        if (isStatusNote(part)) continue;
                        out.appendSliceBounded(if (kept == 0) " (" else ", ") catch {};
                        out.appendSliceBounded(std.mem.trim(u8, part, " \t")) catch {};
                        kept += 1;
                    }
                    if (kept > 0) out.appendBounded(')') catch {};
                    i = close + 1;
                    continue;
                }
            }
        }
        out.appendBounded(text[i]) catch {};
        i += 1;
    }
    return SplitStatus{ .text = std.mem.trim(u8, out.items, " \t\n"), .status = status };
}

/// The status of setting `key`; for a choice setting, of its option `value` (or the setting's own note).
/// The status badge widget of src/ui/widgets.xml for `status` (the window shows it beside each setting; the page
/// check test, src/ui/pagecheck.zig, checks each row has the right one).
pub fn badgeWidgetName(status: Status) []const u8 {
    return switch (status) {
        .stable => "StableBadge",
        .testing => "TestingBadge",
        .experimental => "ExperimentalBadge",
        .new_feature => "NewFeatureBadge",
    };
}

pub fn settingStatus(key: Key, value: ?[]const u8) Status {
    var buffer: [512]u8 = undefined;
    const s = spec(key);
    const own = splitStatus(&buffer, s.label).status;
    if (s.kind == .choice) {
        if (value) |v| {
            const label = if (s.option(v)) |o| o.label else "";
            const opt = splitStatus(&buffer, label).status;
            if (opt != .stable) return opt;
        }
    }
    return own;
}

// ------------------------------------------------------------------------------------------ settings string

/// Settings that only decide where things are written, not what the seed is: left out of the settings string.
const not_in_string = [_]Key{.per_seed_saves};

fn lessKeyName(_: void, a: Key, b: Key) bool {
    return std.mem.order(u8, @tagName(a), @tagName(b)) == .lt;
}

/// A JSON string as Python's json.dumps writes it (ASCII only: other characters as \uXXXX).
fn writeJsonString(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, '"');
    var view = std.unicode.Utf8View.init(s) catch std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (cp >= 0x20 and cp < 0x7F) {
                    try out.append(allocator, @intCast(cp));
                } else if (cp < 0x10000) {
                    try out.print(allocator, "\\u{x:0>4}", .{cp});
                } else {
                    const v = cp - 0x10000;
                    try out.print(allocator, "\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
                }
            },
        }
    }
    try out.append(allocator, '"');
}

/// The settings string: the settings that differ from the defaults, as sorted compact JSON, zlib-compressed and
/// URL-safe base64 without padding. Allocated with `allocator`.
pub fn toString(allocator: Allocator, st: *const Settings) error{OutOfMemory}![]u8 {
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(allocator);
    for (specs) |s| {
        if (std.mem.indexOfScalar(Key, &not_in_string, s.key) != null) continue;
        if (!Value.eql(st.get(s.key), s.default)) try keys.append(allocator, s.key);
    }
    std.mem.sort(Key, keys.items, {}, lessKeyName);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '{');
    for (keys.items, 0..) |key, i| {
        if (i > 0) try json.append(allocator, ',');
        try writeJsonString(&json, allocator, @tagName(key));
        try json.append(allocator, ':');
        switch (st.get(key)) {
            .boolean => |b| try json.appendSlice(allocator, if (b) "true" else "false"),
            .int => |n| try json.print(allocator, "{d}", .{n}),
            .choice => |c| try writeJsonString(&json, allocator, c),
            .list => |l| {
                try json.append(allocator, '[');
                for (l, 0..) |item, k| {
                    if (k > 0) try json.append(allocator, ',');
                    try writeJsonString(&json, allocator, item);
                }
                try json.append(allocator, ']');
            },
        }
    }
    try json.append(allocator, '}');

    const compressed = try zlibCompress(allocator, json.items);
    defer allocator.free(compressed);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(compressed.len));
    _ = encoder.encode(out, compressed);
    return out;
}

fn zlibCompress(allocator: Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 256);
    errdefer aw.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var c = std.compress.flate.Compress.init(&aw.writer, window, .zlib, .best) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub const StringError = error{ InvalidString, OutOfMemory };

/// Reads a settings string. Unknown settings and invalid values are ignored (the defaults stay); the excluded
/// location names are allocated with `allocator` (use an arena).
pub fn fromString(allocator: Allocator, text: []const u8) StringError!Settings {
    const s = std.mem.trim(u8, text, " \t\r\n");
    // accept padded and unpadded strings
    const unpadded = std.mem.trimEnd(u8, s, "=");
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(unpadded) catch return error.InvalidString;
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    decoder.decode(raw, unpadded) catch return error.InvalidString;

    var in: std.Io.Reader = .fixed(raw);
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    defer out.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, window);
    _ = d.reader.streamRemaining(&out.writer) catch return error.InvalidString;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{}) catch return error.InvalidString;
    // the parsed tree is kept: excluded location names point into it
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidString,
    };

    var st = Settings.defaults();
    var it = object.iterator();
    var legacy_scrubs: ?Input = null;
    var merged_on: std.ArrayList(Key) = .empty;
    while (it.next()) |entry| {
        const name = currentName(entry.key_ptr.*);
        const input = try jsonInput(allocator, entry.value_ptr.*);
        if (mergedInto(name)) |target| {
            if (input == .boolean and input.boolean) try merged_on.append(allocator, target);
            continue;
        }
        const key = keyByName(name) orelse continue;
        if (key == .shuffle_scrubs and input == .string) {
            legacy_scrubs = input;
            continue;
        }
        if (checkInput(key, input)) |v| st.set(key, v);
    }
    if (legacy_scrubs) |input| _ = applyLegacyScrubs(&st, input, object.contains("scrub_prices"));
    // after the rest, so an old setting that was on wins over its new setting's default
    applyMerged(&st, merged_on.items);
    return st;
}

fn jsonInput(allocator: Allocator, v: std.json.Value) error{OutOfMemory}!Input {
    return switch (v) {
        .bool => |b| Input{ .boolean = b },
        .integer => |n| Input{ .int = n },
        .string => |s| Input{ .string = s },
        .array => |a| blk: {
            const list = try allocator.alloc([]const u8, a.items.len);
            for (a.items, 0..) |item, i| {
                if (item != .string) break :blk Input.other;
                list[i] = item.string;
            }
            break :blk Input{ .list = list };
        },
        else => Input.other,
    };
}

test "settings string round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = Settings.defaults();
    st.set(.open_forest, .{ .choice = "open" });
    st.set(.bridge_tokens, .{ .int = 40 });
    st.set(.excluded_locations, .{ .list = &.{ "KF Chest 1", "Zelda \u{e9}" } });
    const text = try toString(a, &st);
    const back = try fromString(a, text);
    try std.testing.expect(back.is(.open_forest, "open"));
    try std.testing.expectEqual(@as(i64, 40), back.int(.bridge_tokens));
    try std.testing.expectEqual(@as(usize, 2), back.excluded().len);
    try std.testing.expectEqualStrings("Zelda \u{e9}", back.excluded()[1]);
}

test "output-only settings stay out of the settings string" {
    // why: the settings string is part of every seed's random stream, so turning per-seed saves off must never
    // change the seed
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = Settings.defaults();
    var changed = Settings.defaults();
    changed.set(.per_seed_saves, .{ .boolean = false });
    try std.testing.expectEqualStrings(try toString(a, &defaults), try toString(a, &changed));
}

test "the presets only use options that aren't experimental" {
    // why: a preset is a one-click choice for players who may not read every tooltip, so it must only pick
    // options that are known to work in-game
    for (presets) |p| {
        for (p.values) |kv| {
            const value_name: ?[]const u8 = if (kv.value == .choice) kv.value.choice else null;
            const status = settingStatus(kv.key, value_name);
            const turned_on = switch (kv.value) {
                .boolean => |b| b,
                else => true,
            };
            if (status == .experimental and turned_on) {
                std.debug.print("preset {s}: {s} is experimental\n", .{ p.name, @tagName(kv.key) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "a custom preset carries the gameplay settings only" {
    var source = Settings.defaults();
    source.set(.open_forest, .{ .choice = "open" });
    source.set(.create_spoiler, .{ .boolean = false });
    const applied = applyGameplaySettings(Settings.defaults(), &source);
    try std.testing.expect(applied.is(.open_forest, "open"));
    try std.testing.expect(applied.flag(.create_spoiler));
    try std.testing.expect(sameGameplaySettings(&applied, &source));
}

test "split status" {
    var buf: [256]u8 = undefined;
    const a = splitStatus(&buf, "Skip Area Intro Cutscenes (needs further testing)");
    try std.testing.expectEqualStrings("Skip Area Intro Cutscenes", a.text);
    try std.testing.expectEqual(Status.testing, a.status);
    const b = splitStatus(&buf, "Remove (replaced by junk, experimental)");
    try std.testing.expectEqualStrings("Remove (replaced by junk)", b.text);
    try std.testing.expectEqual(Status.experimental, b.status);
}
