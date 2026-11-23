//! custom_presets.toml: the presets a player saves from the window, next to the built-in ones.
//!
//! The file sits next to the program, beside user_settings.toml. Each custom preset is a name and a settings string
//! (the same text the window's Copy button gives), so a preset can be shared like any settings string. Applying one
//! sets every gameplay setting, like a built-in preset; Excluded Locations, Create Spoiler Log and Per-Seed Saves are
//! kept as they are (settings.applyGameplaySettings).
//!
//!     [custom_presets]
//!     names = ["My Race", "Chill"]
//!     settings = ["eJy...", "eJy..."]

const std = @import("std");
const settings_mod = @import("settings.zig");
const toml = @import("../formats/toml.zig");
const fsmod = @import("../core/fs.zig");
const Env = @import("../platform/Env.zig");
const Allocator = std.mem.Allocator;
const Settings = settings_mod.Settings;

pub const file_name = "custom_presets.toml";

/// A preset name longer than this is cut (it has to fit in the drop-down).
pub const max_name_length: usize = 40;

const header =
    \\# Goggles of Truth Randomizer: your saved presets.
    \\#
    \\# The window writes this file when you save or delete a preset. Each preset is a name and a settings string;
    \\# `names` and `settings` are read in pairs, in the same order. Delete this file to remove every saved preset.
    \\
;

pub const CustomPresetError = error{
    OutOfMemory,
    /// the name is empty, or the name of a built-in preset or of "Custom"
    InvalidPresetName,
};

/// One saved preset. Both texts are owned by the list's allocator.
pub const CustomPreset = struct {
    name: []const u8,
    settings_string: []const u8,
};

/// The saved presets, in the order they were first saved.
pub const CustomPresetList = struct {
    allocator: Allocator,
    presets: std.ArrayList(CustomPreset) = .empty,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.presets.items) |preset| self.freePreset(preset);
        self.presets.deinit(self.allocator);
    }

    fn freePreset(self: *Self, preset: CustomPreset) void {
        self.allocator.free(preset.name);
        self.allocator.free(preset.settings_string);
    }

    /// The index of the preset named `name` (compared exactly), or null.
    pub fn indexOfName(self: *const Self, name: []const u8) ?usize {
        for (self.presets.items, 0..) |preset, index| {
            if (std.mem.eql(u8, preset.name, name)) return index;
        }
        return null;
    }

    /// Saves `settings_string` under `name`: a preset with that name is replaced, otherwise a new one is added at
    /// the end. Returns the preset's index. The texts are copied.
    pub fn savePreset(self: *Self, name: []const u8, settings_string: []const u8) CustomPresetError!usize {
        try validatePresetName(name);
        const owned_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_name);
        const owned_string = self.allocator.dupe(u8, settings_string) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_string);
        const preset = CustomPreset{ .name = owned_name, .settings_string = owned_string };
        if (self.indexOfName(name)) |index| {
            self.freePreset(self.presets.items[index]);
            self.presets.items[index] = preset;
            return index;
        }
        self.presets.append(self.allocator, preset) catch return error.OutOfMemory;
        return self.presets.items.len - 1;
    }

    pub fn removePreset(self: *Self, index: usize) void {
        const removed = self.presets.orderedRemove(index);
        self.freePreset(removed);
    }
};

/// A custom preset may not be empty or take the name of a built-in preset or of "Custom" (the drop-down's entry for
/// settings no preset matches), so every name in the drop-down means one thing.
pub fn validatePresetName(name: []const u8) CustomPresetError!void {
    if (name.len == 0 or name.len > max_name_length) return error.InvalidPresetName;
    if (std.ascii.eqlIgnoreCase(name, "Custom")) return error.InvalidPresetName;
    for (settings_mod.presets) |built_in| {
        if (std.ascii.eqlIgnoreCase(name, built_in.name)) return error.InvalidPresetName;
    }
    // why: a line break or "|" (the drop-down's item separator) would break the list
    for (name) |c| if (c < 0x20 or c == '|') return error.InvalidPresetName;
}

pub fn path(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const u8 {
    return fsmod.join(allocator, &.{ env.app_dir, file_name });
}

/// The saved presets (an empty list when there is no file). Unreadable entries are skipped and named in `messages`
/// (lines for the window's log, allocated with `message_allocator`).
pub fn load(allocator: Allocator, message_allocator: Allocator, env: *const Env, messages: *std.ArrayList([]const u8)) error{OutOfMemory}!CustomPresetList {
    var list = CustomPresetList.init(allocator);
    errdefer list.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = try path(a, env);
    if (!env.fs.isFile(file)) return list;
    const text = env.fs.readAll(a, file) catch |err| {
        try messages.append(message_allocator, try std.fmt.allocPrint(message_allocator, "{s} couldn't be read ({s}); no saved presets.", .{ file_name, @errorName(err) }));
        return list;
    };
    var bad_line: usize = 0;
    const doc = toml.parse(a, text, &bad_line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            try messages.append(message_allocator, try std.fmt.allocPrint(message_allocator, "{s} couldn't be read (line {d} is not valid TOML); no saved presets.", .{ file_name, bad_line }));
            return list;
        },
    };
    const table = doc.table("custom_presets") orelse return list;
    const names = arrayOf(table.get("names"));
    const strings = arrayOf(table.get("settings"));
    const pair_count = @min(names.len, strings.len);
    for (0..pair_count) |index| {
        if (names[index] != .string or strings[index] != .string) continue;
        const name = names[index].string;
        const settings_string = strings[index].string;
        // why: a settings string from an older or newer version may not read; skip it rather than lose the others
        _ = settings_mod.fromString(a, settings_string) catch {
            try messages.append(message_allocator, try std.fmt.allocPrint(message_allocator, "{s}: preset '{s}' has a settings string this version can't read; skipped.", .{ file_name, name }));
            continue;
        };
        _ = list.savePreset(name, settings_string) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPresetName => {
                try messages.append(message_allocator, try std.fmt.allocPrint(message_allocator, "{s}: preset name '{s}' can't be used; skipped.", .{ file_name, name }));
            },
        };
    }
    return list;
}

fn arrayOf(value: ?toml.Value) []const toml.Value {
    const v = value orelse return &.{};
    return if (v == .array) v.array else &.{};
}

/// The file's text for `list`.
pub fn dumps(allocator: Allocator, list: *const CustomPresetList) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    try out.appendSlice(allocator, "\n[custom_presets]\nnames = [");
    for (list.presets.items, 0..) |preset, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try appendTomlString(&out, allocator, preset.name);
    }
    try out.appendSlice(allocator, "]\nsettings = [");
    for (list.presets.items, 0..) |preset, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try appendTomlString(&out, allocator, preset.settings_string);
    }
    try out.appendSlice(allocator, "]\n");
    return out.toOwnedSlice(allocator);
}

/// A basic TOML string: quotes and backslashes escaped (validatePresetName keeps control characters out).
fn appendTomlString(out: *std.ArrayList(u8), allocator: Allocator, text: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, '"');
    for (text) |c| {
        if (c == '"' or c == '\\') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    try out.append(allocator, '"');
}

/// Writes the file (through a temporary file). Returns an error text (allocated with `allocator`), or null.
pub fn save(allocator: Allocator, env: *const Env, list: *const CustomPresetList) error{OutOfMemory}!?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try dumps(a, list);
    const file = try path(a, env);
    env.fs.writeAtomic(a, file, text) catch |err| return try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    return null;
}

test "presets survive a save and a load" {
    const gpa = std.testing.allocator;
    var list = CustomPresetList.init(gpa);
    defer list.deinit();
    var st = Settings.defaults();
    st.set(.open_door, .{ .choice = "open" });
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const string = try settings_mod.toString(arena.allocator(), &st);
    _ = try list.savePreset("My \"Race\"", string);
    _ = try list.savePreset("Chill", string);
    // saving under an existing name replaces it
    try std.testing.expectEqual(@as(usize, 1), try list.savePreset("Chill", string));

    const text = try dumps(arena.allocator(), &list);
    const doc = try toml.parse(arena.allocator(), text, null);
    const names = arrayOf(doc.table("custom_presets").?.get("names"));
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("My \"Race\"", names[0].string);
}

test "built-in and empty names are refused" {
    try std.testing.expectError(error.InvalidPresetName, validatePresetName(""));
    try std.testing.expectError(error.InvalidPresetName, validatePresetName("race"));
    try std.testing.expectError(error.InvalidPresetName, validatePresetName("Custom"));
    try std.testing.expectError(error.InvalidPresetName, validatePresetName("a|b"));
    try validatePresetName("My Race");
}
