//! user_settings.toml: the randomizer window's saved settings and paths.
//!
//! The file sits next to the program. The window loads it when it opens and saves it whenever something changes.
//! Deleting it resets everything to the defaults. It's plain TOML, so it can also be edited by hand while the window
//! is closed: every setting is listed with its allowed values, and an unknown or invalid value falls back to the
//! default (the window's log says which). The file is the same as the Python version's, so both read each other's.
//!
//! Before 0.5.0 the window kept this in ~/.ootr_remake.json. That file is read once if user_settings.toml doesn't
//! exist yet, and is left where it is.

const std = @import("std");
const settings_mod = @import("settings.zig");
const toml = @import("../formats/toml.zig");
const fsmod = @import("../core/fs.zig");
const Env = @import("../platform/Env.zig");
const Allocator = std.mem.Allocator;
const Settings = settings_mod.Settings;

pub const file_name = "user_settings.toml";

const header =
    \\# Goggles of Truth Randomizer: your settings.
    \\#
    \\# The randomizer window loads this file when it opens and saves it whenever you change something.
    \\# Delete this file to reset everything to the defaults.
    \\# You can also edit it by hand while the window is closed. Every setting below lists its allowed values;
    \\# an unknown or invalid value is ignored and the default is used (the window's log says which).
    \\
;

pub const Paths = struct {
    /// the .nup or the romfs folder
    game: []const u8 = "",
    /// the output folder
    output: []const u8 = "",
    /// Launch Game (platform/launcher.zig): the Longshot game folder or program ("" = the game next to the output
    /// folder), the emulator program or its folder ("" = a portable emulator's own), and the game file the emulator
    /// boots ("" = the emulator opens without one)
    longshot: []const u8 = "",
    emulator: []const u8 = "",
    emulator_game: []const u8 = "",
};

pub const App = struct {
    /// the window's theme (src/ui/themes.zig names them; an unknown one is the default, and the window's log says so)
    theme: []const u8 = default_theme,
};

/// the randomizer's own theme (src/ui/themes.zig default_value)
pub const default_theme = "goggles_of_truth";

pub const Loaded = struct {
    settings: Settings,
    paths: Paths,
    app: App,
    /// lines for the window's log
    messages: []const []const u8,
};

pub fn path(allocator: Allocator, env: *const Env) error{OutOfMemory}![]const u8 {
    return fsmod.join(allocator, &.{ env.app_dir, file_name });
}

/// Python's repr() of a value, for the warnings.
fn reprToml(allocator: Allocator, v: toml.Value) error{OutOfMemory}![]const u8 {
    return switch (v) {
        .string => |s| std.fmt.allocPrint(allocator, "'{s}'", .{s}),
        .int => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |x| std.fmt.allocPrint(allocator, "{d}", .{x}),
        .bool => |b| if (b) "True" else "False",
        .array => "[...]",
        .other => "(unreadable)",
    };
}

fn reprValue(allocator: Allocator, v: settings_mod.Value) error{OutOfMemory}![]const u8 {
    return switch (v) {
        .boolean => |b| if (b) "True" else "False",
        .int => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .choice => |c| std.fmt.allocPrint(allocator, "'{s}'", .{c}),
        .list => "[]",
    };
}

fn tomlInput(allocator: Allocator, v: toml.Value) error{OutOfMemory}!settings_mod.Input {
    return switch (v) {
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .bool => |b| .{ .boolean = b },
        .array => |items| blk: {
            const list = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |item, i| {
                if (item != .string) break :blk .other;
                list[i] = item.string;
            }
            break :blk .{ .list = list };
        },
        // no setting takes a decimal number
        .float, .other => .other,
    };
}

/// Known keys with valid values on top of the defaults; a warning for everything else.
fn validate(allocator: Allocator, entries: []const toml.Entry, warnings: *std.ArrayList([]const u8), prefix: []const u8) error{OutOfMemory}!Settings {
    return applyOverrides(allocator, Settings.defaults(), entries, warnings, prefix);
}

/// `base` with each known key in `entries` set to its value (when valid); a warning for everything else. A test plan's
/// [settings] table changes a few settings this way on top of the user's own or a preset's.
pub fn applyOverrides(allocator: Allocator, base: Settings, entries: []const toml.Entry, warnings: *std.ArrayList([]const u8), prefix: []const u8) error{OutOfMemory}!Settings {
    var st = base;
    var merged_on: std.ArrayList(settings_mod.Key) = .empty;
    for (entries) |e| {
        const name = settings_mod.currentName(e.key);
        if (settings_mod.isRetired(name)) continue; // now part of every seed, or removed
        if (settings_mod.mergedInto(name)) |target| {
            // e.g. Skip Area Intro Cutscenes = true: Skip Cutscenes, which has the area intros since 0.8.0
            if (e.value == .bool and e.value.bool) try merged_on.append(allocator, target);
            continue;
        }
        const key = settings_mod.keyByName(name) orelse {
            try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s}unknown setting '{s}' ignored (removed in this version, or misspelled)", .{ prefix, e.key }));
            continue;
        };
        const value = settings_mod.checkInput(key, try tomlInput(allocator, e.value)) orelse {
            try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s} = {s} is not allowed; using the default ({s})", .{
                prefix, name, try reprToml(allocator, e.value), try reprValue(allocator, settings_mod.spec(key).default),
            }));
            continue;
        };
        st.set(key, value);
    }
    settings_mod.applyMerged(&st, merged_on.items);
    return st;
}

/// Loads the settings, paths and app options. Never fails on a broken file: it gives the defaults and a message.
/// Everything is allocated with `allocator` (use an arena that lives as long as the settings).
pub fn load(allocator: Allocator, env: *const Env) error{OutOfMemory}!Loaded {
    var messages: std.ArrayList([]const u8) = .empty;
    const file = try path(allocator, env);
    if (!env.fs.isFile(file)) {
        if (try loadOldJson(allocator, env, &messages)) |loaded| return loaded;
        return Loaded{ .settings = Settings.defaults(), .paths = .{}, .app = .{}, .messages = messages.items };
    }
    const text = env.fs.readAll(allocator, file) catch |err| {
        try messages.append(allocator, try std.fmt.allocPrint(allocator, "user_settings.toml couldn't be read ({s}); using the defaults. It is replaced with the current settings when the window opens.", .{@errorName(err)}));
        return Loaded{ .settings = Settings.defaults(), .paths = .{}, .app = .{}, .messages = messages.items };
    };
    var bad_line: usize = 0;
    const doc = toml.parse(allocator, text, &bad_line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            try messages.append(allocator, try std.fmt.allocPrint(allocator, "user_settings.toml couldn't be read (line {d} is not valid TOML); using the defaults. It is replaced with the current settings when the window opens.", .{bad_line}));
            return Loaded{ .settings = Settings.defaults(), .paths = .{}, .app = .{}, .messages = messages.items };
        },
    };
    var paths = Paths{};
    if (doc.table("paths")) |p| {
        if (p.get("game")) |v| if (v == .string) {
            paths.game = v.string;
        };
        if (p.get("output")) |v| if (v == .string) {
            paths.output = v.string;
        };
        if (p.get("longshot")) |v| if (v == .string) {
            paths.longshot = v.string;
        };
        if (p.get("emulator")) |v| if (v == .string) {
            paths.emulator = v.string;
        };
        if (p.get("emulator_game")) |v| if (v == .string) {
            paths.emulator_game = v.string;
        };
    }
    var app = App{};
    if (doc.table("app")) |t| {
        // `auto_update` (the window's own update check, up to 0.8.1) is no longer used: updates are the launcher's
        // job. Files that still have it load as before; it's left out the next time the file is written.
        if (t.get("theme")) |v| if (v == .string) {
            app.theme = v.string;
        };
    }
    const entries = if (doc.table("settings")) |t| t.entries.items else &.{};
    const st = try validate(allocator, entries, &messages, "user_settings.toml: ");
    return Loaded{ .settings = st, .paths = paths, .app = app, .messages = messages.items };
}

/// ~/.ootr_remake.json from before 0.5.0, read once if there is no user_settings.toml.
fn loadOldJson(allocator: Allocator, env: *const Env, messages: *std.ArrayList([]const u8)) error{OutOfMemory}!?Loaded {
    const old = try fsmod.join(allocator, &.{ env.home(), ".ootr_remake.json" });
    const data = env.fs.readAll(allocator, old) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch return null;
    if (root != .object) return null;
    var entries: std.ArrayList(toml.Entry) = .empty;
    if (root.object.get("settings")) |s| if (s == .object) {
        var it = s.object.iterator();
        while (it.next()) |e| try entries.append(allocator, .{ .key = e.key_ptr.*, .value = try jsonToToml(allocator, e.value_ptr.*) });
    };
    var warnings: std.ArrayList([]const u8) = .empty;
    const st = try validate(allocator, entries.items, &warnings, "");
    var paths = Paths{};
    if (root.object.get("romfs")) |v| if (v == .string) {
        paths.game = v.string;
    };
    if (root.object.get("out")) |v| if (v == .string) {
        paths.output = v.string;
    };
    try messages.append(allocator, try std.fmt.allocPrint(allocator, "Settings taken over from {s} (saved to user_settings.toml from now on).", .{old}));
    try messages.appendSlice(allocator, warnings.items);
    return Loaded{ .settings = st, .paths = paths, .app = .{}, .messages = messages.items };
}

fn jsonToToml(allocator: Allocator, v: std.json.Value) error{OutOfMemory}!toml.Value {
    return switch (v) {
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .int = n },
        .string => |s| .{ .string = s },
        .array => |a| blk: {
            const items = try allocator.alloc(toml.Value, a.items.len);
            for (a.items, 0..) |item, i| items[i] = try jsonToToml(allocator, item);
            break :blk .{ .array = items };
        },
        else => .other,
    };
}

/// A TOML basic string (a JSON string is a valid one: same escapes), keeping non-ASCII text as it is.
fn tomlString(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => if (c < 0x20) try out.print(allocator, "\\u{x:0>4}", .{c}) else try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn tomlValue(out: *std.ArrayList(u8), allocator: Allocator, v: settings_mod.Value) error{OutOfMemory}!void {
    switch (v) {
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| try out.print(allocator, "{d}", .{n}),
        .choice => |c| try tomlString(out, allocator, c),
        .list => |l| {
            if (l.len == 0) return out.appendSlice(allocator, "[]");
            try out.appendSlice(allocator, "[\n");
            for (l) |s| {
                try out.appendSlice(allocator, "    ");
                try tomlString(out, allocator, s);
                try out.appendSlice(allocator, ",\n");
            }
            try out.append(allocator, ']');
        },
    }
}

/// The file's text.
pub fn dumps(allocator: Allocator, st: *const Settings, paths: Paths, app: App) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, header);
    try out.appendSlice(allocator, "[app]\n");
    try out.appendSlice(allocator, "# The window's theme, chosen on the General Settings tab: \"goggles_of_truth\" or one of Raven's looks (\"raven_dark\",\n");
    try out.appendSlice(allocator, "# \"raven_light\", \"raven_glass_dark\", \"windows_light\", \"macos_dark\", \"gnome_light\", \"native_dark\"...). Default: \"goggles_of_truth\"\n");
    try out.appendSlice(allocator, "theme = ");
    try tomlString(&out, allocator, app.theme);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "\n[paths]\n");
    try out.appendSlice(allocator, "# Your game (.nup file or extracted romfs folder) and the folder the mod is written to.\n");
    try out.appendSlice(allocator, "# Backslashes are written as \\\\ (or use single quotes: game = 'D:\\Games\\game.nup').\n");
    try out.appendSlice(allocator, "game = ");
    try tomlString(&out, allocator, paths.game);
    try out.appendSlice(allocator, "\noutput = ");
    try tomlString(&out, allocator, paths.output);
    try out.appendSlice(allocator, "\n# Launch Game: the Longshot game folder (or its program), the emulator's program (or its folder) and the\n");
    try out.appendSlice(allocator, "# game file the emulator starts. Leave empty to use the ones the output folder belongs to.\n");
    try out.appendSlice(allocator, "longshot = ");
    try tomlString(&out, allocator, paths.longshot);
    try out.appendSlice(allocator, "\nemulator = ");
    try tomlString(&out, allocator, paths.emulator);
    try out.appendSlice(allocator, "\nemulator_game = ");
    try tomlString(&out, allocator, paths.emulator_game);
    try out.appendSlice(allocator, "\n\n[settings]\n");
    const preset = settings_mod.matchingPreset(st);
    try out.print(allocator, "# Preset these settings match: {s}. (Informational: a preset is applied from the window.)\n", .{preset orelse "none (custom)"});

    var section_tab: []const u8 = "";
    var section_group: []const u8 = "";
    for (settings_mod.specs) |s| {
        if (!std.mem.eql(u8, s.tab, section_tab) or !std.mem.eql(u8, s.group, section_group)) {
            section_tab = s.tab;
            section_group = s.group;
            try out.print(allocator, "\n# ---- {s}: {s}\n", .{ s.tab, s.group });
        }
        try out.print(allocator, "# {s}: ", .{s.label});
        switch (s.kind) {
            .boolean => try out.appendSlice(allocator, "true or false"),
            .choice => for (s.options, 0..) |o, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.print(allocator, "\"{s}\" ({s})", .{ o.value, o.label });
            },
            .int => try out.print(allocator, "a whole number from {d} to {d}", .{ s.min, s.max }),
            .list => try out.appendSlice(allocator, switch (s.key) {
                .starting_inventory => "a list of item keys, one per copy (\"Hookshot\" twice is the Longshot; items.txt from `goggles_cli test-catalog` names them)",
                .item_restrictions => "a list of \"Location | Item\" pairs with the spoiler log's names: that item is never placed at that location",
                else => "a list of location names as the Exclusions tab shows them",
            }),
        }
        try out.appendSlice(allocator, ". Default: ");
        var default_text: std.ArrayList(u8) = .empty;
        try tomlValue(&default_text, allocator, s.default);
        std.mem.replaceScalar(u8, default_text.items, '\n', ' ');
        try out.appendSlice(allocator, default_text.items);
        try out.print(allocator, "\n{s} = ", .{@tagName(s.key)});
        try tomlValue(&out, allocator, st.get(s.key));
        try out.append(allocator, '\n');
    }
    return out.items;
}

/// Writes the file (through a temporary file, so a crash never leaves half a file), with the [app] options the
/// window sets (`app`: the theme and the update check). Returns an error text, or null when it was saved.
pub fn save(allocator: Allocator, env: *const Env, st: *const Settings, paths: Paths, app: App) error{OutOfMemory}!?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try dumps(a, st, paths, app);
    const file = try path(a, env);
    env.fs.writeAtomic(a, file, text) catch |err| return try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    return null;
}

test "Skip Area Intro Cutscenes from an older file turns on Skip Cutscenes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;
    // the window wrote every setting, so the old file has Skip Cutscenes off too, before or after it
    const entries = [_]toml.Entry{
        .{ .key = "skip_area_intros", .value = .{ .bool = true } },
        .{ .key = "skip_story_scenes", .value = .{ .bool = false } },
    };
    const st = try applyOverrides(a, Settings.defaults(), &entries, &warnings, "");
    try std.testing.expect(st.flag(.skip_story_scenes));
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    const off = [_]toml.Entry{.{ .key = "skip_area_intros", .value = .{ .bool = false } }};
    try std.testing.expect(!(try applyOverrides(a, Settings.defaults(), &off, &warnings, "")).flag(.skip_story_scenes));
}
