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
};

pub const App = struct {
    /// kept for the Python version's updater (the compiled program doesn't update itself)
    auto_update: bool = true,
};

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
        .other => .other,
    };
}

/// Known keys with valid values on top of the defaults; a warning for everything else.
fn validate(allocator: Allocator, entries: []const toml.Entry, warnings: *std.ArrayList([]const u8), prefix: []const u8) error{OutOfMemory}!Settings {
    var st = Settings.defaults();
    for (entries) |e| {
        const name = settings_mod.currentName(e.key);
        if (settings_mod.isRetired(name)) continue; // now part of every seed, or removed
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
    }
    var app = App{};
    if (doc.table("app")) |t| if (t.get("auto_update")) |v| if (v == .bool) {
        app.auto_update = v.bool;
    };
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
    try out.appendSlice(allocator, "# Check GitHub for a newer version when the randomizer opens, pull it and restart (only in a git\n");
    try out.appendSlice(allocator, "# clone; a downloaded zip is never changed): true or false. Default: true\n");
    try out.print(allocator, "auto_update = {s}\n", .{if (app.auto_update) "true" else "false"});
    try out.appendSlice(allocator, "\n[paths]\n");
    try out.appendSlice(allocator, "# Your game (.nup file or extracted romfs folder) and the folder the mod is written to.\n");
    try out.appendSlice(allocator, "# Backslashes are written as \\\\ (or use single quotes: game = 'D:\\Games\\game.nup').\n");
    try out.appendSlice(allocator, "game = ");
    try tomlString(&out, allocator, paths.game);
    try out.appendSlice(allocator, "\noutput = ");
    try tomlString(&out, allocator, paths.output);
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
            .list => try out.appendSlice(allocator, "a list of location names as the Exclusions tab shows them"),
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

/// Writes the file (through a temporary file, so a crash never leaves half a file). The [app] options are kept as
/// they are in the file. Returns an error text, or null when it was saved.
pub fn save(allocator: Allocator, env: *const Env, st: *const Settings, paths: Paths) error{OutOfMemory}!?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try load(a, env);
    const text = try dumps(a, st, paths, loaded.app);
    const file = try path(a, env);
    env.fs.writeAtomic(a, file, text) catch |err| return try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    return null;
}
