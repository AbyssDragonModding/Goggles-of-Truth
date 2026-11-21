//! The randomizer window, built with Raven (https://github.com/oscar-soirey/Raven) from src/ui/main.xml.
//!
//! The window finds the named widgets of the XML layout, fills them in and binds its actions (OnClicked / OnChanged /
//! OnActivated names). Scanning the game and generating a seed run on a worker thread; the worker posts its log lines
//! and results to a queue that a 0.1 s timer drains on the UI thread (Raven belongs to the thread that started it).

const std = @import("std");
const builtin = @import("builtin");
const r = @import("raven");
const engine = @import("engine");
const layout = @import("layout.zig");
const wallpaper = @import("wallpaper.zig");
const Allocator = std.mem.Allocator;
const settings = engine.settings;
const Settings = settings.Settings;
const Key = settings.Key;
const fsmod = engine.fs;

const App = @This();

pub const AppError = error{
    /// Raven could not start, or the layout could not be loaded (the message box says why)
    WindowFailed,
    OutOfMemory,
};

const accent = [3]f32{ 0.36, 0.80, 0.56 }; // Kokiri green
const muted = r.Color.rgba(0.78, 0.82, 0.86, 0.85);
const ok_green = r.Color.rgba(0.40, 0.86, 0.52, 1.0);
const bad_red = r.Color.rgba(0.96, 0.46, 0.44, 1.0);
const max_log_lines = 400;

/// Settings that only mean something with another one's value: greyed out otherwise.
const Dependent = struct { key: Key, other: Key, value: []const u8 };
const dependents = [_]Dependent{
    .{ .key = .bridge_medallions, .other = .rainbow_bridge, .value = "medallions" },
    .{ .key = .bridge_tokens, .other = .rainbow_bridge, .value = "tokens" },
};

// ------------------------------------------------------------------------------------------ the worker's queue

const MessageKind = enum { log, locations, done, failed, idle };

const Message = struct {
    kind: MessageKind,
    /// owned by the queue's allocator
    text: []u8 = &.{},
    /// "locations": the location names; "done": seed, mod root, settings string
    list: [][]u8 = &.{},
};

const Queue = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Message) = .empty,

    fn push(self: *Queue, message: Message) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.items.append(self.allocator, message) catch {}; // out of memory: the line is lost
    }

    fn pushText(self: *Queue, kind: MessageKind, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.push(.{ .kind = kind, .text = copy });
    }

    /// Takes every waiting message (the caller frees them with freeMessage).
    fn takeAll(self: *Queue, out: *std.ArrayList(Message)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(self.allocator, self.items.items) catch return;
        self.items.clearRetainingCapacity();
    }

    fn freeMessage(self: *Queue, m: Message) void {
        self.allocator.free(m.text);
        for (m.list) |s| self.allocator.free(s);
        self.allocator.free(m.list);
    }
};

/// The worker's Progress: every line goes to the queue.
fn queueLine(context: ?*anyopaque, line: []const u8) void {
    const queue: *Queue = @ptrCast(@alignCast(context.?));
    queue.pushText(.log, line);
}

// ------------------------------------------------------------------------------------------------- the state

gpa: Allocator,
io: std.Io,
env: engine.Env,
/// strings for Raven (zero-terminated), freed on every timer tick
frame: std.heap.ArenaAllocator,

window: r.Window,
root: r.Widget,
romfs_in: r.TextInput,
out_in: r.TextInput,
name_in: r.TextInput,
seed_in: r.TextInput,
hash_lab: r.Label,
game_lab: r.Label,
filter_in: r.TextInput,
excl_count: r.Label,
excl_list: r.ListView,
sstr_in: r.TextInput,
progress_bar: r.ProgressBar,
log: r.ListView,
preset_in: r.ComboBox,
preset_lab: r.Label,
saves_lab: r.Label,
seeds_list: r.ListView,
gen_btn: r.Widget,
/// per setting: its control (null for the excluded-locations list)
controls: [settings.key_count]?r.Widget = @splat(null),
badges: [settings.key_count]?struct { border: r.Border, label: r.Label } = @splat(null),
badge_styles: [3]layout.BadgeStyle,

st: Settings,
/// the excluded location names (owned)
excluded: std.array_hash_map.String(void) = .empty,
/// owned copies of the text fields' paths
game_path: []u8 = &.{},
out_path: []u8 = &.{},
seed_text: []u8 = &.{},
last_seed: []u8 = &.{},

/// true while the preset drop-down is set from code
syncing: bool = false,
/// nothing is saved until the window is filled in
loaded: bool = false,
save_warned: bool = false,
busy: bool = false,
phase: f32 = 0,

/// the last game check, with the path and modification time it was made for (checking hashes exefs/main)
check_arena: std.heap.ArenaAllocator,
check: ?engine.gamecheck.GameCheck = null,
check_key: []u8 = &.{},
check_mtime: ?i96 = null,

/// the scanned game (used and replaced only by the worker while `busy`)
world: ?*engine.world.World = null,
world_path: []u8 = &.{},
/// all location names from the scan, and the ones the filter shows
locations: [][]u8 = &.{},
visible: std.ArrayList(usize) = .empty,
filter: []u8 = &.{},
seed_rows: std.ArrayList([]u8) = .empty,

queue: Queue,
worker: ?std.Thread = null,

// ---------------------------------------------------------------------------------------------- helpers

/// `text` zero-terminated for Raven (valid until the next timer tick).
fn z(self: *App, text: []const u8) [:0]const u8 {
    return self.frame.allocator().dupeSentinel(u8, text, 0) catch "";
}

fn fmtZ(self: *App, comptime format: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(self.frame.allocator(), format, args, 0) catch "";
}

/// Replaces an owned string.
fn setOwned(self: *App, slot: *[]u8, text: []const u8) void {
    const copy = self.gpa.dupe(u8, text) catch return;
    self.gpa.free(slot.*);
    slot.* = copy;
}

/// Adds a line to the log list (the oldest go once there are too many).
pub fn write(self: *App, line: []const u8) void {
    _ = self.log.addItem(self.z(line));
    var n = self.log.getItemCount();
    if (n > max_log_lines) {
        self.log.removeItem(0);
        n -= 1;
    }
    self.log.scrollToItem(n - 1);
}

fn writeFmt(self: *App, comptime format: []const u8, args: anytype) void {
    self.write(self.fmtZ(format, args));
}

fn messageBox(self: *App, title: []const u8, text: []const u8) void {
    _ = r.messageBox(self.window, self.z(title), self.z(text), .ok);
}

fn color(rgba: [4]f32) r.Color {
    return r.Color.rgba(rgba[0], rgba[1], rgba[2], rgba[3]);
}

fn find(root: r.Widget, comptime T: type, name: [:0]const u8) AppError!T {
    const w = root.find(name) orelse return fail("src/ui/main.xml has no widget named {s}", .{name});
    if (T == r.Widget) return w;
    return w.as(T) orelse fail("the widget {s} in src/ui/main.xml is not a {s}", .{ name, @typeName(T) });
}

var fail_text: [1024]u8 = undefined;
var fail_len: usize = 0;

/// Keeps the reason a window step failed (shown in a message box by `run`).
fn fail(comptime format: []const u8, args: anytype) AppError {
    const text = std.fmt.bufPrint(&fail_text, format, args) catch fail_text[0..];
    fail_len = text.len;
    return error.WindowFailed;
}

fn ravenError() []const u8 {
    const e = r.errorGetLast() orelse return "unknown error";
    return if (e.detail.len > 0) e.detail else @tagName(e.code);
}

// ----------------------------------------------------------------------------------------- start and stop

/// Opens the window and runs it until it is closed.
pub fn run(gpa: Allocator, io: std.Io, env: engine.Env) AppError!void {
    r.init(.vulkan) catch return fail("Raven could not start (a Vulkan driver is required).", .{});
    defer r.shutdown();
    r.lookSet(.raven_glass_dark);
    r.themeSetDark(true);
    r.themeSetAccent(accent[0], accent[1], accent[2]);
    r.themeSetMaterial(.frosted_glass);
    if (wallpaper.png(gpa, 640, 420)) |png| {
        defer gpa.free(png);
        if (r.Texture.create(png)) |tex| r.themeSetWallpaper(tex) else |_| {}
    } else |_| {}
    // the widgets main.xml uses (status badges): declared once in src/ui/widgets.xml
    if (r.xmlRegisterWidgets(layout.widgets_xml) < 1) return fail("src/ui/widgets.xml could not be loaded: {s}", .{ravenError()});

    const xml = layout.windowXml(gpa) catch return error.OutOfMemory;
    defer gpa.free(xml);
    const window = r.Window.createFromXml(xml) catch return fail("The window layout (src/ui/main.xml) could not be loaded: {s}", .{ravenError()});
    const root = window.getContent() orelse return fail("The window layout (src/ui/main.xml) has no content.", .{});
    // Raven sets a window icon on Windows and X11 (elsewhere this does nothing). A missing icon isn't worth stopping
    // for: the window keeps the default one.
    if (r.imageDecode(gpa, layout.app_icon_png)) |icon| {
        defer icon.deinit(gpa);
        window.setIcon(icon.pixels, icon.width, icon.height);
    } else |_| {}

    const app = gpa.create(App) catch return error.OutOfMemory;
    defer gpa.destroy(app);
    app.* = App{
        .gpa = gpa,
        .io = io,
        .env = env,
        .frame = std.heap.ArenaAllocator.init(gpa),
        .window = window,
        .root = root,
        .romfs_in = try find(root, r.TextInput, "romfs_in"),
        .out_in = try find(root, r.TextInput, "out_in"),
        .name_in = try find(root, r.TextInput, "name_in"),
        .seed_in = try find(root, r.TextInput, "seed_in"),
        .hash_lab = try find(root, r.Label, "hash_lab"),
        .game_lab = try find(root, r.Label, "game_lab"),
        .filter_in = try find(root, r.TextInput, "filter_in"),
        .excl_count = try find(root, r.Label, "excl_count"),
        .excl_list = try find(root, r.ListView, "excl_list"),
        .sstr_in = try find(root, r.TextInput, "sstr_in"),
        .progress_bar = try find(root, r.ProgressBar, "progress"),
        .log = try find(root, r.ListView, "log"),
        .preset_in = try find(root, r.ComboBox, "preset_in"),
        .preset_lab = try find(root, r.Label, "preset_lab"),
        .saves_lab = try find(root, r.Label, "saves_lab"),
        .seeds_list = try find(root, r.ListView, "seeds_list"),
        .gen_btn = try find(root, r.Widget, "generate"),
        .badge_styles = layout.badgeStyles(),
        .st = Settings.defaults(),
        .check_arena = std.heap.ArenaAllocator.init(gpa),
        .queue = .{ .allocator = gpa, .io = io },
    };
    defer app.deinit();
    try app.bind();
    window.show();
    _ = r.Timer.create(0.1, true, app, App.poll);
    while (r.waitFrame(-1.0)) {}
    if (app.worker) |t| t.join();
}

fn deinit(self: *App) void {
    var it = self.excluded.iterator();
    while (it.next()) |e| self.gpa.free(e.key_ptr.*);
    self.excluded.deinit(self.gpa);
    self.gpa.free(self.game_path);
    self.gpa.free(self.out_path);
    self.gpa.free(self.seed_text);
    self.gpa.free(self.last_seed);
    self.gpa.free(self.check_key);
    self.gpa.free(self.world_path);
    self.gpa.free(self.filter);
    self.freeLocations();
    self.visible.deinit(self.gpa);
    for (self.seed_rows.items) |s| self.gpa.free(s);
    self.seed_rows.deinit(self.gpa);
    if (self.world) |w| w.deinit();
    for (self.queue.items.items) |m| self.queue.freeMessage(m);
    self.queue.items.deinit(self.gpa);
    self.check_arena.deinit();
    self.frame.deinit();
}

fn freeLocations(self: *App) void {
    for (self.locations) |n| self.gpa.free(n);
    self.gpa.free(self.locations);
    self.locations = &.{};
}

/// The version shown under the title.
fn subtitle(self: *App) [:0]const u8 {
    return self.fmtZ("Switch 2 remake edition  \u{b7}  v{s}  \u{b7}  your game, your mod", .{engine.version.version});
}

/// Finds the setting controls, fills everything in and binds the actions.
fn bind(self: *App) AppError!void {
    (try find(self.root, r.Label, "subtitle")).setText(self.subtitle());

    // user_settings.toml
    var load_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer load_arena.deinit();
    const loaded = engine.usersettings.load(load_arena.allocator(), &self.env) catch return error.OutOfMemory;
    self.st = loaded.settings;
    for (loaded.settings.excluded()) |n| self.addExcluded(n);
    self.st.set(.excluded_locations, .{ .list = &.{} });
    self.setOwned(&self.game_path, loaded.paths.game);
    self.setOwned(&self.out_path, loaded.paths.output);
    self.romfs_in.setText(self.z(self.game_path));
    self.out_in.setText(self.z(self.out_path));

    const actions = [_]struct { name: [:0]const u8, f: fn (*App, ?r.Widget, [:0]const u8) void }{
        .{ .name = "rando.open_folder", .f = onOpenFolder },
        .{ .name = "rando.generate", .f = onGenerate },
        .{ .name = "rando.scan", .f = onScan },
        .{ .name = "rando.random_seed", .f = onRandomSeed },
        .{ .name = "rando.clear_excluded", .f = onClearExcluded },
        .{ .name = "rando.import_string", .f = onImportString },
        .{ .name = "rando.copy_string", .f = onCopyString },
        .{ .name = "rando.reset", .f = onReset },
        .{ .name = "rando.browse.nup", .f = onBrowseNup },
        .{ .name = "rando.longshot", .f = onLongshot },
        .{ .name = "rando.browse.romfs", .f = onBrowseFolder },
        .{ .name = "rando.browse.out", .f = onBrowseFolder },
        .{ .name = "rando.path.romfs", .f = onPathChanged },
        .{ .name = "rando.path.out", .f = onPathChanged },
        .{ .name = "rando.path.name", .f = onPathChanged },
        .{ .name = "rando.path.seed", .f = onPathChanged },
        .{ .name = "rando.preset", .f = onPreset },
        .{ .name = "rando.filter", .f = onFilter },
        .{ .name = "rando.refresh_seeds", .f = onRefreshSeeds },
        .{ .name = "rando.play_selected", .f = onPlaySelected },
        .{ .name = "rando.play_seed", .f = onPlaySeed },
        .{ .name = "rando.toggle_excluded", .f = onToggleExcluded },
    };
    inline for (actions) |action| r.actionBind(action.name, self, action.f);

    for (&settings.specs) |*s| {
        if (s.kind == .list) continue;
        const key = @tagName(s.key);
        const name = self.fmtZ("set_{s}", .{key});
        const w = self.root.find(name) orelse return fail("src/ui/main.xml has no widget named {s}", .{name});
        self.controls[@intFromEnum(s.key)] = w;
        const border = try find(self.root, r.Border, self.fmtZ("badge_{s}", .{key}));
        const label = try find(self.root, r.Label, self.fmtZ("badgelab_{s}", .{key}));
        self.badges[@intFromEnum(s.key)] = .{ .border = border, .label = label };
        // one function for every setting: the action's name says which (set.<key>)
        r.actionBind(self.fmtZ("set.{s}", .{key}), self, onSetting);
        try self.showSetting(s);
    }
    self.updateDependent();
    self.updateExcludedCount();
    self.loaded = true;
    self.refreshString();
    self.write("Ready. Pick your romfs and an output folder, then Generate.");
    for (loaded.messages) |m| self.write(m);
    if (std.mem.trim(u8, self.out_path, " \t").len == 0) {
        self.useLongshot(true); // first start with Longshot installed: use its mods folder
    } else {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        if (engine.longshot.newerBuild(arena.allocator(), &self.env, self.out_path) catch null) |newer| {
            // Longshot was updated into a new version folder: follow it
            self.writeFmt("Longshot was updated to {s}, so seeds now go to its mods folder. Seeds in the old folder ({s}) aren't loaded by the new version.", .{ newer.name, self.out_path });
            self.useLongshot(false);
        }
    }
    _ = self.verifyGame();
    self.fillSeeds();
}

/// Shows a setting's value in its control.
fn showSetting(self: *App, s: *const settings.Spec) AppError!void {
    const w = self.controls[@intFromEnum(s.key)] orelse return;
    switch (s.kind) {
        .boolean => (w.as(r.Checkbox) orelse return fail("set_{s} is not a switch", .{@tagName(s.key)})).setChecked(self.st.flag(s.key)),
        .int => {
            const spin = w.as(r.SpinBox) orelse return fail("set_{s} is not a spin box", .{@tagName(s.key)});
            spin.setRange(@floatFromInt(s.min), @floatFromInt(s.max));
            spin.setStep(1);
            spin.setDecimals(0);
            spin.setValue(@floatFromInt(self.st.int(s.key)));
        },
        .choice => {
            const combo = w.as(r.ComboBox) orelse return fail("set_{s} is not a drop-down", .{@tagName(s.key)});
            combo.setSelected(@intCast(s.optionIndex(self.st.choice(s.key)) orelse 0));
            self.updateBadge(s.key);
        },
        .list => {},
    }
}

// ------------------------------------------------------------------------------------------------ settings

fn onSetting(self: *App, sender: ?r.Widget, action: [:0]const u8) void {
    const name = action["set.".len..];
    const key = settings.keyByName(name) orelse return;
    const s = settings.spec(key);
    const w = sender orelse return;
    switch (s.kind) {
        .boolean => self.st.set(key, .{ .boolean = (w.as(r.Checkbox) orelse return).isChecked() }),
        .int => {
            const v = @round((w.as(r.SpinBox) orelse return).getValue());
            self.st.set(key, .{ .int = std.math.clamp(@as(i64, @intFromFloat(v)), s.min, s.max) });
        },
        .choice => {
            const i = (w.as(r.ComboBox) orelse return).getSelected();
            if (i < 0 or i >= s.options.len) return;
            self.st.set(key, .{ .choice = s.options[@intCast(i)].value });
        },
        .list => return,
    }
    self.updateBadge(key);
    self.updateDependent();
    self.refreshString();
}

fn updateDependent(self: *App) void {
    for (dependents) |d| {
        const w = self.controls[@intFromEnum(d.key)] orelse continue;
        w.setEnabled(self.st.is(d.other, d.value));
    }
}

/// A choice setting's badge follows its chosen option ("Scarce" is Experimental, "Balanced" Stable).
fn updateBadge(self: *App, key: Key) void {
    if (settings.spec(key).kind != .choice) return;
    const badge = self.badges[@intFromEnum(key)] orelse return;
    const style = self.badge_styles[@intFromEnum(settings.settingStatus(key, self.st.choice(key)))];
    const bg = layout.rgba(style.background);
    const fg = layout.rgba(style.foreground);
    badge.border.setBackground(r.Color.rgba(bg[0], bg[1], bg[2], 1.0));
    badge.label.setText(self.z(style.text));
    badge.label.setColor(r.Color.rgba(fg[0], fg[1], fg[2], 1.0));
}

/// The settings with the excluded locations, sorted. The names are allocated with `allocator`.
fn currentSettings(self: *App, allocator: Allocator) error{OutOfMemory}!Settings {
    var st = self.st;
    const names = try allocator.alloc([]const u8, self.excluded.count());
    for (self.excluded.keys(), 0..) |k, i| names[i] = try allocator.dupe(u8, k);
    std.mem.sort([]const u8, names, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    st.set(.excluded_locations, .{ .list = names });
    return st;
}

fn applySettings(self: *App, st: Settings) void {
    self.st = st;
    self.clearExcluded();
    for (st.excluded()) |n| self.addExcluded(n);
    self.st.set(.excluded_locations, .{ .list = &.{} });
    for (&settings.specs) |*s| self.showSetting(s) catch {};
    self.updateDependent();
    self.fillExclusions();
    self.refreshString();
}

/// Every settings change ends here: the settings string, the preset and the saved file follow it.
fn refreshString(self: *App) void {
    const a = self.frame.allocator();
    const st = self.currentSettings(a) catch return;
    const text = settings.toString(a, &st) catch return;
    self.sstr_in.setText(self.z(text));
    self.rerollUsedSeed();
    self.settingsChanged(&st);
}

/// After any change: show which preset matches and save user_settings.toml.
fn settingsChanged(self: *App, st: *const Settings) void {
    if (!self.loaded) return;
    const preset = settings.matchingPreset(st) orelse "Custom";
    self.syncing = true;
    for (layout.preset_items, 0..) |p, i| {
        if (std.mem.eql(u8, p, preset)) self.preset_in.setSelected(@intCast(i));
    }
    self.syncing = false;
    self.preset_lab.setText(if (self.save()) "Saved to user_settings.toml" else "Couldn't save user_settings.toml");
}

fn onPreset(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const combo = (sender orelse return).as(r.ComboBox) orelse return;
    const index = combo.getSelected();
    // "Custom", or set from code
    if (self.syncing or index <= 0 or index >= layout.preset_items.len) return;
    const name = layout.preset_items[@intCast(index)];
    const preset = settings.findPreset(name) orelse return;
    const st = self.currentSettings(self.frame.allocator()) catch return;
    self.applySettings(settings.applyPreset(st, preset));
    self.writeFmt("Preset {s} applied.", .{name});
}

fn onReset(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.applySettings(Settings.defaults());
}

/// Has a seed already been written with this seed number (this session, or a folder in the output folder)?
fn seedUsed(self: *App, seed: []const u8) bool {
    if (std.mem.eql(u8, seed, self.last_seed)) return true;
    const a = self.frame.allocator();
    const out = std.mem.trim(u8, self.out_in.getText(), " \t");
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ engine.longshot.mod_prefix, seed }) catch return false;
    // switched-off seeds are "_<name>" or "_<name> (2)"
    const off = fsmod.join(a, &.{ out, engine.saves.emu_off }) catch return false;
    for ([_][]const u8{ out, off }) |folder| {
        const names = self.env.fs.listDir(a, folder) catch continue;
        for (names) |n| {
            if (std.mem.eql(u8, engine.saves.seedName(n), name)) return true;
        }
    }
    return false;
}

/// Changed settings with an already-used seed number would overwrite that seed: roll a new number.
fn rerollUsedSeed(self: *App) void {
    if (!self.loaded) return;
    const seed = std.mem.trim(u8, self.seed_in.getText(), " \t");
    if (seed.len == 0 or !self.seedUsed(seed)) return;
    const old = self.z(seed);
    self.randomSeed();
    self.writeFmt("Settings changed: new seed number {s} (seed {s} is already made).", .{ self.seed_text, old });
}

fn onImportString(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const st = settings.fromString(arena.allocator(), self.sstr_in.getText()) catch {
        self.messageBox("Invalid settings string", "That settings string couldn't be read.");
        return;
    };
    self.applySettings(st);
    self.write("Settings imported.");
}

fn onCopyString(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.refreshString();
    r.clipboardSetText(self.z(self.sstr_in.getText()));
    self.write("Settings string copied to clipboard.");
}

// ---------------------------------------------------------------------------------------------- exclusions

fn addExcluded(self: *App, name: []const u8) void {
    if (self.excluded.contains(name)) return;
    const copy = self.gpa.dupe(u8, name) catch return;
    self.excluded.put(self.gpa, copy, {}) catch self.gpa.free(copy);
}

fn removeExcluded(self: *App, name: []const u8) void {
    const index = self.excluded.getIndex(name) orelse return;
    const key = self.excluded.keys()[index];
    self.excluded.orderedRemoveAt(index);
    self.gpa.free(key);
}

fn clearExcluded(self: *App) void {
    for (self.excluded.keys()) |k| self.gpa.free(k);
    self.excluded.clearRetainingCapacity();
}

fn onFilter(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const input = (sender orelse return).as(r.TextInput) orelse return;
    const lower = std.ascii.allocLowerString(self.gpa, input.getText()) catch return;
    self.gpa.free(self.filter);
    self.filter = lower;
    self.fillExclusions();
}

fn excludedText(self: *App, name: []const u8) [:0]const u8 {
    return self.fmtZ("{s}{s}", .{ if (self.excluded.contains(name)) "\u{2716}  " else "      ", name });
}

fn fillExclusions(self: *App) void {
    self.visible.clearRetainingCapacity();
    self.excl_list.clearItems();
    for (self.locations, 0..) |n, i| {
        if (self.filter.len > 0 and std.ascii.findIgnoreCase(n, self.filter) == null) continue;
        self.visible.append(self.gpa, i) catch return;
        _ = self.excl_list.addItem(self.excludedText(n));
    }
    self.updateExcludedCount();
}

fn onToggleExcluded(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const list = (sender orelse return).as(r.ListView) orelse return;
    const index = list.getSelected();
    if (index < 0 or index >= self.visible.items.len) return;
    const name = self.locations[self.visible.items[@intCast(index)]];
    if (self.excluded.contains(name)) self.removeExcluded(name) else self.addExcluded(name);
    self.excl_list.setItemText(index, self.excludedText(name));
    self.updateExcludedCount();
    self.refreshString();
}

fn onClearExcluded(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.clearExcluded();
    self.fillExclusions();
    self.refreshString();
}

fn updateExcludedCount(self: *App) void {
    self.excl_count.setText(self.fmtZ("{d} excluded", .{self.excluded.count()}));
}

// ------------------------------------------------------------------------------------------------- paths

fn onBrowseFolder(self: *App, _: ?r.Widget, action: [:0]const u8) void {
    const is_romfs = std.mem.endsWith(u8, action, ".romfs");
    const current = if (is_romfs) self.game_path else self.out_path;
    const a = self.frame.allocator();
    const path = r.fileDialogSelectFolder(.{
        .parent = self.window,
        .title = if (is_romfs) "Select the extracted romfs folder" else "Select the output folder",
        .directory = if (self.env.fs.isDir(current)) self.z(current) else null,
    });
    var chosen = engine.gamefiles.cleanPath(a, path) catch return;
    if (chosen.len > 0 and is_romfs) {
        // e.g. romfs/Banc chosen, or the game folder
        if (engine.gamefiles.findRomfs(self.env.fs, a, chosen) catch null) |found| chosen = found;
    }
    if (chosen.len == 0) return;
    if (is_romfs) self.romfs_in.setText(self.z(chosen)) else self.out_in.setText(self.z(chosen));
    self.pathChanged(if (is_romfs) .game else .output, chosen);
}

fn onBrowseNup(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const current = std.mem.trim(u8, self.game_path, " \t");
    const folder = if (self.env.fs.isDir(current)) current else fsmod.dirname(current);
    const filters = [_]r.FileFilter{
        .{ .name = "Game package (*.nup)", .patterns = "*.nup" },
        .{ .name = "All files", .patterns = "*" },
    };
    const path = r.fileDialogOpen(.{
        .parent = self.window,
        .title = "Select your game's .nup file",
        .directory = if (folder.len > 0 and self.env.fs.isDir(folder)) self.z(folder) else null,
        .filters = &filters,
    }) orelse return;
    if (path.len == 0) return;
    self.romfs_in.setText(path);
    self.pathChanged(.game, path);
}

const PathField = enum { game, output, name, seed };

fn onPathChanged(self: *App, sender: ?r.Widget, action: [:0]const u8) void {
    const input = (sender orelse return).as(r.TextInput) orelse return;
    const field: PathField = if (std.mem.endsWith(u8, action, ".romfs")) .game else if (std.mem.endsWith(u8, action, ".out")) .output else if (std.mem.endsWith(u8, action, ".seed")) .seed else .name;
    self.pathChanged(field, input.getText());
}

fn pathChanged(self: *App, field: PathField, text: []const u8) void {
    switch (field) {
        .game => self.setOwned(&self.game_path, text),
        .output => self.setOwned(&self.out_path, text),
        .seed => self.setOwned(&self.seed_text, text),
        .name => {},
    }
    if (field == .output) self.fillSeeds();
    if (field == .game) _ = self.verifyGame();
    if ((field == .game or field == .output) and self.loaded) _ = self.save();
}

/// Points the output folder at the Longshot game's mods folder. `quiet` (the first start): say nothing when Longshot
/// isn't found.
fn useLongshot(self: *App, quiet: bool) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const builds = engine.longshot.findBuilds(a, &self.env) catch return;
    if (builds.len == 0) {
        if (!quiet) self.messageBox("Longshot", "No Longshot game was found.\n\nBuild the game with the Longshot launcher first, or choose its mods folder with Browse (the mods folder goes next to longshot.exe in the game folder).");
        return;
    }
    const b = builds[0];
    const mods = b.mods(a) catch return;
    self.env.fs.makePath(mods) catch |err| {
        self.writeFmt("Longshot: couldn't create {s}: {s}", .{ mods, @errorName(err) });
        return;
    };
    self.out_in.setText(self.z(mods));
    self.pathChanged(.output, mods);
    self.writeFmt("Longshot: seeds go to {s} (game {s}). Older randomizer seeds there are switched off when you generate a new one.", .{ mods, b.name });
    if (builds.len > 1) {
        var others: std.ArrayList(u8) = .empty;
        for (builds[1..], 0..) |x, i| {
            if (i > 0) others.appendSlice(a, "; ") catch return;
            others.appendSlice(a, x.folder) catch return;
        }
        self.writeFmt("  Other Longshot games found (choose their mods folder with Browse to use one): {s}", .{others.items});
    }
    if (std.mem.trim(u8, self.game_path, " \t").len == 0) {
        const nup = if (b.nup.len > 0 and self.env.fs.isFile(b.nup)) b.nup else engine.longshot.launcherNup(a, &self.env) catch "";
        if (nup.len > 0) {
            self.romfs_in.setText(self.z(nup));
            self.pathChanged(.game, nup);
            self.writeFmt("Longshot: game file taken from the Longshot launcher: {s}", .{nup});
        }
    }
}

fn onLongshot(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.useLongshot(false);
}

/// Hashes exefs/main (in the .nup, or next to the romfs folder) and shows the result (green = supported). The result
/// is kept for the same path and modification time, so typing in the field doesn't hash the file again and again.
fn verifyGame(self: *App) engine.gamecheck.GameCheck {
    const a = self.frame.allocator();
    const romfs = engine.gamefiles.cleanPath(a, self.romfs_in.getText()) catch "";
    const mtime = self.env.fs.mtime(romfs);
    if (self.check == null or !std.mem.eql(u8, self.check_key, romfs) or self.check_mtime != mtime) {
        _ = self.check_arena.reset(.retain_capacity);
        self.check = engine.gamecheck.check(self.check_arena.allocator(), self.env.fs, "", romfs) catch
            engine.gamecheck.GameCheck{ .ok = false, .status = .missing, .message = "Couldn't read the exefs." };
        self.setOwned(&self.check_key, romfs);
        self.check_mtime = mtime;
    }
    const g = self.check.?;
    var text: [:0]const u8 = undefined;
    var c: r.Color = undefined;
    if (g.ok) {
        const where = if (engine.gamefiles.isNup(self.env.fs, romfs)) "  (from the .nup)" else "  (exefs found next to the romfs folder)";
        text = self.fmtZ("{s}{s}", .{ g.message, where });
        c = ok_green;
    } else if (g.status == .missing) {
        text = self.z(g.message);
        c = muted;
    } else {
        const first_line = g.message[0 .. std.mem.indexOfScalar(u8, g.message, '\n') orelse g.message.len];
        text = self.z(first_line);
        c = bad_red;
    }
    self.game_lab.setText(text);
    self.game_lab.setColor(c);
    self.hash_lab.setText(self.fmtZ("exefs/main SHA-256: {s}", .{if (g.sha256.len > 0) g.sha256 else "-"}));
    self.hash_lab.setColor(if (g.sha256.len > 0) c else muted);
    return g;
}

fn requireGame(self: *App) bool {
    const g = self.verifyGame();
    if (!g.ok) self.messageBox(if (g.status != .missing) "Game version not supported" else "exefs not found", g.message);
    return g.ok;
}

fn onOpenFolder(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const out = std.mem.trim(u8, self.out_in.getText(), " \t");
    if (out.len == 0 or !self.env.fs.isDir(out)) {
        self.messageBox("Output", "The output folder doesn't exist yet.\nChoose one on the ROM Options tab, or generate a seed first.");
        return;
    }
    const opener: []const u8 = switch (builtin.os.tag) {
        .windows => "explorer",
        .macos => "open",
        else => "xdg-open",
    };
    _ = std.process.spawn(self.io, .{ .argv = &.{ opener, out }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        self.messageBox("Output", self.fmtZ("Couldn't open the folder:\n{s}", .{@errorName(err)}));
    };
}

fn randomSeed(self: *App) void {
    var buf: [10]u8 = undefined;
    const s = engine.generator.randomSeed(self.io, &buf);
    self.seed_in.setText(self.z(s));
    self.setOwned(&self.seed_text, s);
}

fn onRandomSeed(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.randomSeed();
}

const CheckedPaths = struct { game: []const u8, out: []const u8 };

/// The game and output paths if they are usable (a message box says what is wrong otherwise).
fn checkPaths(self: *App, need_out: bool) ?CheckedPaths {
    const a = self.frame.allocator();
    const romfs = engine.gamefiles.cleanPath(a, self.romfs_in.getText()) catch return null;
    const out = a.dupe(u8, std.mem.trim(u8, self.out_in.getText(), " \t")) catch return null;
    const is_nup = engine.gamefiles.isNup(self.env.fs, romfs);
    const found = engine.gamefiles.findRomfs(self.env.fs, a, romfs) catch null;
    if (!is_nup and (romfs.len == 0 or !self.env.fs.isDir(romfs) or found == null)) {
        self.messageBox("Game", "Choose your game's .nup file or its extracted romfs folder.\n(A romfs folder holds Pack/ZsDic.pack.zs and a Banc folder.)");
        return null;
    }
    if (need_out) {
        if (out.len == 0) {
            self.messageBox("Output", "Choose an output folder.");
            return null;
        }
        if (!is_nup) {
            const game_abs = self.env.fs.absolute(a, found.?) catch return null;
            const out_abs = self.env.fs.absolute(a, out) catch return null;
            if (fsmod.isInside(game_abs, out_abs)) {
                self.messageBox("Output", "The output folder must not be inside the romfs folder.");
                return null;
            }
        }
    }
    return .{ .game = romfs, .out = out };
}

// --------------------------------------------------------------------------------------------- background

const Job = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    kind: enum { scan, generate },
    game: []const u8,
    request: engine.generator.Request,
};

fn startJob(self: *App, kind: @FieldType(Job, "kind"), game: []const u8, request: ?engine.generator.Request) void {
    if (self.busy) return;
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .app = self, .arena = std.heap.ArenaAllocator.init(self.gpa), .kind = kind, .game = "", .request = undefined };
    const a = job.arena.allocator();
    job.game = a.dupe(u8, game) catch return self.jobFailed(job);
    if (request) |req| {
        var copy = req;
        copy.game_path = job.game;
        copy.out_dir = a.dupe(u8, req.out_dir) catch return self.jobFailed(job);
        if (req.seed) |s| copy.seed = a.dupe(u8, s) catch return self.jobFailed(job);
        if (req.mod_name) |m| copy.mod_name = a.dupe(u8, m) catch return self.jobFailed(job);
        // the excluded names live in the job's arena too
        const names = a.alloc([]const u8, req.settings.excluded().len) catch return self.jobFailed(job);
        for (req.settings.excluded(), 0..) |n, i| names[i] = a.dupe(u8, n) catch return self.jobFailed(job);
        copy.settings.set(.excluded_locations, .{ .list = names });
        job.request = copy;
    }
    self.busy = true;
    self.gen_btn.setEnabled(false);
    self.worker = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        self.busy = false;
        self.gen_btn.setEnabled(true);
        self.write("ERROR: the worker thread could not be started");
        return self.jobFailed(job);
    };
}

fn jobFailed(self: *App, job: *Job) void {
    job.arena.deinit();
    self.gpa.destroy(job);
}

/// Opens (or re-uses) the scanned game. Runs on the worker.
fn ensureWorld(self: *App, game: []const u8, progress: *engine.Progress) bool {
    if (self.world != null and std.mem.eql(u8, self.world_path, game)) return true;
    if (self.world) |w| {
        w.deinit(); // release the previous .nup
        self.world = null;
    }
    if (engine.gamefiles.isNup(self.env.fs, game)) self.queue.pushText(.log, self.fmtWorker("Reading the game from {s}", .{game}));
    self.world = engine.world.World.init(self.gpa, self.env.fs, game, progress) catch |err| {
        self.queue.pushText(.failed, if (progress.failureMessage().len > 0) progress.failureMessage() else @errorName(err));
        return false;
    };
    const path_copy = self.gpa.dupe(u8, game) catch return false;
    self.gpa.free(self.world_path);
    self.world_path = path_copy;

    // the location names, sorted, for the exclusion list
    const w = self.world.?;
    const names = self.gpa.alloc([]u8, w.locations.items.len) catch return true;
    for (w.locations.items, 0..) |l, i| names[i] = self.gpa.dupe(u8, l.name) catch return true;
    std.mem.sort([]u8, names, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    self.queue.push(.{ .kind = .locations, .list = names });
    self.queue.pushText(.log, self.fmtWorker("Found {d} item locations.", .{w.locations.items.len}));
    return true;
}

var worker_text: [512]u8 = undefined;

/// A short formatted line on the worker (it doesn't touch the UI thread's frame arena).
fn fmtWorker(_: *App, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&worker_text, format, args) catch worker_text[0..];
}

fn workerMain(job: *Job) void {
    const self = job.app;
    defer {
        self.queue.push(.{ .kind = .idle });
        job.arena.deinit();
        self.gpa.destroy(job);
    }
    var progress = engine.Progress{ .context = &self.queue, .write_fn = queueLine };
    if (!self.ensureWorld(job.game, &progress)) return;
    switch (job.kind) {
        .scan => self.queue.pushText(.log, "Scan complete."),
        .generate => {
            const result = engine.generator.generate(self.gpa, job.arena.allocator(), &self.env, job.request, self.world, &progress) catch |err| {
                self.queue.pushText(.failed, if (progress.failureMessage().len > 0) progress.failureMessage() else @errorName(err));
                return;
            };
            const list = self.gpa.alloc([]u8, 3) catch return;
            list[0] = self.gpa.dupe(u8, result.seed) catch &.{};
            list[1] = self.gpa.dupe(u8, result.mod_root) catch &.{};
            list[2] = self.gpa.dupe(u8, result.settings_string) catch &.{};
            self.queue.push(.{ .kind = .done, .list = list });
        },
    }
}

fn onScan(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const paths = self.checkPaths(false) orelse return;
    if (!self.requireGame()) return;
    self.startJob(.scan, paths.game, null);
}

fn onGenerate(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const paths = self.checkPaths(true) orelse return;
    if (!self.requireGame()) return;
    const a = self.frame.allocator();
    const st = self.currentSettings(a) catch return;
    const seed = std.mem.trim(u8, self.seed_in.getText(), " \t");
    const name = std.mem.trim(u8, self.name_in.getText(), " \t");
    self.setOwned(&self.game_path, paths.game);
    self.setOwned(&self.out_path, paths.out);
    _ = self.save();
    self.startJob(.generate, paths.game, .{
        .game_path = paths.game,
        .out_dir = paths.out,
        .settings = st,
        .seed = if (seed.len > 0) a.dupe(u8, seed) catch return else null,
        .mod_name = if (name.len > 0) a.dupe(u8, name) catch return else null,
        .exefs = "",
    });
}

/// The UI thread's pump: the working bar, and the worker's messages.
fn poll(self: *App, _: r.Timer) void {
    _ = self.frame.reset(.retain_capacity);
    if (self.busy) {
        // a gentle back-and-forth "working" bar
        self.phase += 0.08;
        self.progress_bar.setValue(0.5 + 0.5 * @sin(self.phase));
    }
    var messages: std.ArrayList(Message) = .empty;
    defer messages.deinit(self.gpa);
    self.queue.takeAll(&messages);
    for (messages.items) |m| {
        defer self.queue.freeMessage(m);
        switch (m.kind) {
            .log => self.write(m.text),
            .locations => {
                self.freeLocations();
                self.locations = self.gpa.dupe([]u8, m.list) catch &.{};
                // the names now belong to the window: the message must not free them
                for (m.list) |*n| n.* = &.{};
                self.fillExclusions();
            },
            .done => {
                const seed = m.list[0];
                self.seed_in.setText(self.z(seed));
                self.setOwned(&self.last_seed, seed);
                self.setOwned(&self.seed_text, seed);
                self.progress_bar.setValue(1.0);
                self.writeFmt("Seed {s} written to {s}", .{ seed, m.list[1] });
                self.messageBox("Mod created", self.fmtZ("{s}\n\nSettings string:\n{s}", .{ m.list[1], m.list[2] }));
                self.fillSeeds();
            },
            .failed => {
                const first_line = m.text[0 .. std.mem.indexOfScalar(u8, m.text, '\n') orelse m.text.len];
                self.writeFmt("ERROR: {s}", .{first_line});
                self.progress_bar.setValue(0.0);
                self.messageBox("Generation failed", m.text[0..@min(m.text.len, 2000)]);
            },
            .idle => {
                self.busy = false;
                self.gen_btn.setEnabled(true);
            },
        }
    }
}

// --------------------------------------------------------------------------------------- seeds and saves

fn fillSeeds(self: *App) void {
    self.seeds_list.clearItems();
    for (self.seed_rows.items) |s| self.gpa.free(s);
    self.seed_rows.clearRetainingCapacity();
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const out = std.mem.trim(u8, self.out_path, " \t");
    const target = (if (out.len > 0) engine.saves.targetFor(a, &self.env, out) catch null else null) orelse {
        self.saves_lab.setText("Choose a Longshot mods folder or an emulator's load/0400486024DEC000 folder as the output folder to see its seeds.");
        return;
    };
    var owners: std.ArrayList([]const u8) = .empty;
    for (target.save_dirs) |d| if (engine.saves.owner(a, &self.env, d)) |o| owners.append(a, o) catch {};
    const where = if (target.save_dirs.len > 0) std.mem.join(a, ", ", target.save_dirs) catch "" else "none yet (the game hasn't saved)";
    const text = std.fmt.allocPrint(a, "{s} seeds in {s}.  Game saves: {s}", .{ target.kind.label(), out, where }) catch return;
    if (target.note.len > 0) {
        self.saves_lab.setText(self.fmtZ("WARNING: {s}.  {s}", .{ target.note, text }));
    } else {
        self.saves_lab.setText(self.z(text));
    }
    const list = engine.saves.seeds(a, &self.env, target) catch return;
    for (list) |s| {
        var owned = false;
        for (owners.items) |o| if (std.mem.eql(u8, o, s.name)) {
            owned = true;
        };
        const mark = self.fmtZ("{s}{s}{s}", .{ if (s.on) "\u{25b6} " else "    ", if (owned) "\u{2605} " else "    ", s.name });
        _ = self.seeds_list.addItem(mark);
        self.seed_rows.append(self.gpa, self.gpa.dupe(u8, s.name) catch continue) catch {};
    }
}

fn onRefreshSeeds(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.fillSeeds();
}

fn onPlaySelected(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.playSeed(self.seeds_list.getSelected());
}

fn onPlaySeed(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const list = (sender orelse return).as(r.ListView) orelse return;
    self.playSeed(list.getSelected());
}

fn playSeed(self: *App, index: i32) void {
    if (self.busy or index < 0 or index >= self.seed_rows.items.len) return;
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const target = (engine.saves.targetFor(a, &self.env, std.mem.trim(u8, self.out_path, " \t")) catch null) orelse return;
    const name = a.dupe(u8, self.seed_rows.items[@intCast(index)]) catch return;
    var msg = engine.saves.Messages{ .allocator = a };
    const result = if (self.st.flag(.per_seed_saves))
        engine.saves.play(a, &self.env, target, name, &msg)
    else blk: {
        _ = engine.saves.switchOn(a, &self.env, target, name, &msg) catch |err| break :blk err;
        msg.add("Per-Seed Saves is off: saves not changed", .{}) catch {};
        break :blk {};
    };
    result catch {
        self.messageBox("Play This Seed", if (msg.failure.len > 0) msg.failure else "The seed couldn't be switched on.");
        self.fillSeeds();
        return;
    };
    self.writeFmt("Playing {s} (every other seed switched off)", .{name});
    for (msg.lines.items) |line| self.writeFmt("Per-seed saves: {s}", .{line});
    self.fillSeeds();
    const joined = std.mem.join(a, "\n", msg.lines.items) catch "";
    self.messageBox("Play This Seed", self.fmtZ("{s} is switched on.\n\n{s}", .{ name, joined }));
}

// ---------------------------------------------------------------------------------------- user_settings.toml

/// Writes user_settings.toml. True when it was saved.
fn save(self: *App) bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = self.currentSettings(a) catch return false;
    const err = engine.usersettings.save(a, &self.env, &st, .{ .game = self.game_path, .output = self.out_path }) catch return false;
    if (err) |e| {
        if (!self.save_warned) {
            self.save_warned = true;
            self.writeFmt("Couldn't save user_settings.toml: {s}", .{e});
        }
        return false;
    }
    return true;
}

/// The reason the window couldn't open (for the message box `main` shows).
pub fn failureMessage() []const u8 {
    return fail_text[0..fail_len];
}
