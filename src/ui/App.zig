//! The randomizer window, built with Raven (https://github.com/oscar-soirey/Raven) from src/ui/main.xml.
//!
//! The window finds the named widgets of the XML layout, fills them in and binds its actions (OnClicked / OnChanged /
//! OnActivated names). Scanning the game and generating a seed run on a worker thread; the worker posts its log lines
//! and results to a queue that a 0.1 s timer drains on the UI thread (Raven belongs to the thread that started it).

const std = @import("std");
const r = @import("raven");
const engine = @import("engine");
const layout = @import("layout.zig");
const TestSeedsTab = @import("TestSeedsTab.zig");
const SearchPicker = @import("SearchPicker.zig");
const themes = @import("themes.zig");
/// Debug builds (local builds) have the Test Seeds tab; release builds (the GitHub ones) don't (layout.zig).
pub const debug_build = layout.debug_build;
const wallpaper = @import("wallpaper.zig");
const Allocator = std.mem.Allocator;
const settings = engine.settings;
const Rng = engine.rng.Rng;
const Settings = settings.Settings;
const startinventory = settings.startinventory;
const Key = settings.Key;
const fsmod = engine.fs;

const App = @This();

pub const AppError = error{
    /// Raven could not start, or the layout could not be loaded (the message box says why)
    WindowFailed,
    OutOfMemory,
};

const max_log_lines = 400;

/// Settings that only mean something with another one's value: greyed out otherwise.
/// A setting only used while `other` is `value` (or `also`): its control is greyed out otherwise.
const Dependent = struct { key: Key, other: Key, value: []const u8, also: ?[]const u8 = null };
const dependents = [_]Dependent{
    // Rainbow Bridge Random may roll Medallions or Gold Skulltula Tokens, so their counts stay usable
    .{ .key = .bridge_medallions, .other = .rainbow_bridge, .value = "medallions", .also = "random" },
    .{ .key = .bridge_medallions_random, .other = .rainbow_bridge, .value = "medallions", .also = "random" },
    .{ .key = .bridge_tokens, .other = .rainbow_bridge, .value = "tokens", .also = "random" },
    .{ .key = .bridge_tokens_random, .other = .rainbow_bridge, .value = "tokens", .also = "random" },
    .{ .key = .key_ring_forest, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_fire, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_water, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_shadow, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_spirit, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_well, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_gtg, .other = .key_rings, .value = "choose" },
    .{ .key = .key_ring_ganon, .other = .key_rings, .value = "choose" },
};

// ------------------------------------------------------------------------------------------ the worker's queue

const MessageKind = enum { log, locations, items, catalog, done, failed, idle };

const Message = struct {
    kind: MessageKind,
    /// owned by the queue's allocator
    text: []u8 = &.{},
    /// "locations": the location names; "items": the item names (Item Restrictions); "done": seed, mod root, settings
    /// string
    list: [][]u8 = &.{},
    /// "catalog" (debug builds): the Test Seeds tab's names from the scanned game
    catalog: ?*CatalogBox = null,
};

/// The Test Seeds tab's catalog and the arena that holds it, on its way from the worker.
const CatalogBox = struct {
    arena: std.heap.ArenaAllocator,
    catalog: engine.teststart.Catalog,
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
        if (m.catalog) |box| {
            box.arena.deinit();
            self.allocator.destroy(box);
        }
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
longshot_in: r.TextInput,
emulator_in: r.TextInput,
emulator_game_in: r.TextInput,
name_in: r.TextInput,
seed_in: r.TextInput,
hash_lab: r.Label,
game_lab: r.Label,
excl_count: r.Label,
excl_list: r.ListView,
/// the location to exclude, and the location and item of a new Item Restrictions rule (SearchPicker)
excl_picker: SearchPicker,
restrict_loc_picker: SearchPicker,
restrict_item_picker: SearchPicker,
restrict_list: r.ListView,
restrict_count: r.Label,
/// the Starting Inventory's item picker (SearchPicker): picking an entry adds a copy
start_item_picker: SearchPicker,
start_chosen_list: r.ListView,
start_count: r.Label,
sstr_in: r.TextInput,
progress_bar: r.ProgressBar,
log: r.ListView,
/// the Seed preset picker: "Custom", the built-in presets, then the saved ones (SearchPicker)
preset_picker: SearchPicker,
/// the window's theme (General Settings; themes.zig), saved to user_settings.toml
theme_picker: SearchPicker,
theme_index: usize = 0,
/// the Goggles of Truth theme's background (null if it couldn't be made)
wallpaper_texture: ?r.Texture = null,
/// the popup every SearchPicker of the window opens (made once from widgets.xml's SearchPopup)
search_popup: SearchPicker.Popup,
/// the location and item pickers' labels (zero-terminated copies of `locations` and `item_names`)
picker_arena: std.heap.ArenaAllocator,
preset_lab: r.Label,
preset_name_in: r.TextInput,
saves_lab: r.Label,
seeds_list: r.ListView,
gen_btn: r.Widget,
/// per setting: its control (null for the excluded-locations list)
controls: [settings.key_count]?r.Widget = @splat(null),
badges: [settings.key_count]?struct { border: r.Border, label: r.Label } = @splat(null),
badge_styles: [layout.status_count]layout.BadgeStyle,

st: Settings,
/// the presets the player saved (custom_presets.toml); the drop-down lists them after the built-in ones
custom_presets: engine.custompresets.CustomPresetList,
/// each saved preset's settings, read once from its settings string when the drop-down is filled (cached: the
/// drop-down is matched against them on every settings change). Allocated in `custom_preset_arena`.
custom_preset_settings: std.ArrayList(Settings) = .empty,
custom_preset_arena: std.heap.ArenaAllocator,
/// the excluded location names (owned)
excluded: std.array_hash_map.String(void) = .empty,
/// Item Restrictions: "Location | Item" entries, in the order they were added (owned; kept here like the excluded
/// locations, so the setting's list never points into a freed arena)
restrictions: std.ArrayList([]u8) = .empty,
/// the item drop-down's names, index for index (owned; from the last scan)
item_names: [][]u8 = &.{},
/// the Test Seeds tab (debug builds only)
test_tab: if (debug_build) TestSeedsTab else void,
/// Starting Inventory: copies per entry of settings/startinventory.zig (kept here, like the excluded locations, so
/// the setting's list never points into a freed arena; currentSettings puts it back)
start_counts: startinventory.Counts = @splat(0),
/// the entry each row of the starting items list shows
start_chosen_rows: [startinventory.entries.len]usize = @splat(0),
start_chosen_count: usize = 0,
/// owned copies of the text fields' paths
game_path: []u8 = &.{},
out_path: []u8 = &.{},
/// Launch Game's paths (platform/launcher.zig): "" = found from the output folder
longshot_path: []u8 = &.{},
emulator_path: []u8 = &.{},
emulator_game_path: []u8 = &.{},
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
seed_rows: std.ArrayList([]u8) = .empty,

queue: Queue,
worker: ?std.Thread = null,

// ---------------------------------------------------------------------------------------------- helpers

/// `text` zero-terminated for Raven (valid until the next timer tick).
pub fn z(self: *App, text: []const u8) [:0]const u8 {
    return self.frame.allocator().dupeSentinel(u8, text, 0) catch "";
}

pub fn fmtZ(self: *App, comptime format: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(self.frame.allocator(), format, args, 0) catch "";
}

/// The frame arena (strings for Raven, valid until the next timer tick).
pub fn frameAllocator(self: *App) Allocator {
    return self.frame.allocator();
}

/// The window's settings as a settings string, allocated with `allocator`.
pub fn settingsString(self: *App, allocator: Allocator) error{OutOfMemory}![]const u8 {
    const st = try self.currentSettings(allocator);
    return settings.toString(allocator, &st);
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

pub fn writeFmt(self: *App, comptime format: []const u8, args: anytype) void {
    self.write(self.fmtZ(format, args));
}

fn messageBox(self: *App, title: []const u8, text: []const u8) void {
    _ = r.messageBox(self.window, self.z(title), self.z(text), .ok);
}

fn color(rgba: [4]f32) r.Color {
    return r.Color.rgba(rgba[0], rgba[1], rgba[2], rgba[3]);
}

/// A SearchPicker of widgets.xml: its field is `base`, the text in it `base`_label.
fn searchPicker(gpa: Allocator, root: r.Widget, comptime base: [:0]const u8, placeholder: [:0]const u8) AppError!SearchPicker {
    return SearchPicker.init(gpa, try find(root, r.Widget, base), try find(root, r.Label, base ++ "_label"), placeholder, null, false);
}

pub fn find(root: r.Widget, comptime T: type, name: [:0]const u8) AppError!T {
    const w = root.find(name) orelse return fail("src/ui/main.xml has no widget named {s}", .{name});
    if (T == r.Widget) return w;
    return w.as(T) orelse fail("the widget {s} in src/ui/main.xml is not a {s}", .{ name, @typeName(T) });
}

var fail_text: [1024]u8 = undefined;
var fail_len: usize = 0;

/// Keeps the reason a window step failed (shown in a message box by `run`).
pub fn fail(comptime format: []const u8, args: anytype) AppError {
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
    var wallpaper_texture: ?r.Texture = null;
    if (wallpaper.png(gpa, 640, 420)) |png| {
        defer gpa.free(png);
        if (r.Texture.create(png)) |tex| wallpaper_texture = tex else |_| {}
    } else |_| {}
    // the default theme until user_settings.toml is read (App.bind applies the saved one)
    themes.applyTheme(themes.themes[0], wallpaper_texture);
    // the widgets main.xml uses (status badges): declared once in src/ui/widgets.xml
    if (r.xmlRegisterWidgets(layout.widgets_xml) < 1) return fail("src/ui/widgets.xml could not be loaded: {s}", .{ravenError()});

    const xml = layout.windowXml(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PageMarkerMissing, error.NoSpaceLeft => return fail("A page of the window layout (src/ui/pages) could not be put into src/ui/main.xml: {s}", .{@errorName(err)}),
    };
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
        .longshot_in = try find(root, r.TextInput, "longshot_in"),
        .emulator_in = try find(root, r.TextInput, "emulator_in"),
        .emulator_game_in = try find(root, r.TextInput, "emulator_game_in"),
        .name_in = try find(root, r.TextInput, "name_in"),
        .seed_in = try find(root, r.TextInput, "seed_in"),
        .hash_lab = try find(root, r.Label, "hash_lab"),
        .game_lab = try find(root, r.Label, "game_lab"),
        .excl_count = try find(root, r.Label, "excl_count"),
        .excl_list = try find(root, r.ListView, "excl_list"),
        .excl_picker = try searchPicker(gpa, root, "excl_loc", "Pick a location to exclude..."),
        .restrict_loc_picker = try searchPicker(gpa, root, "restrict_loc", "Pick a location..."),
        .restrict_item_picker = try searchPicker(gpa, root, "restrict_item", "Pick an item..."),
        .restrict_list = try find(root, r.ListView, "restrict_list"),
        .restrict_count = try find(root, r.Label, "restrict_count"),
        .start_item_picker = try searchPicker(gpa, root, "start_item_pick", "Pick an item to add..."),
        .start_chosen_list = try find(root, r.ListView, "start_chosen_list"),
        .start_count = try find(root, r.Label, "start_count"),
        .sstr_in = try find(root, r.TextInput, "sstr_in"),
        .progress_bar = try find(root, r.ProgressBar, "progress"),
        .log = try find(root, r.ListView, "log"),
        .preset_picker = try searchPicker(gpa, root, "preset_in", "Custom"),
        .theme_picker = try searchPicker(gpa, root, "theme_in", themes.themes[0].label),
        .wallpaper_texture = wallpaper_texture,
        .search_popup = SearchPicker.Popup.init(gpa, window) catch return fail("widgets.xml's SearchPopup couldn't be made", .{}),
        .picker_arena = std.heap.ArenaAllocator.init(gpa),
        .preset_lab = try find(root, r.Label, "preset_lab"),
        .preset_name_in = try find(root, r.TextInput, "preset_name_in"),
        .saves_lab = try find(root, r.Label, "saves_lab"),
        .seeds_list = try find(root, r.ListView, "seeds_list"),
        .gen_btn = try find(root, r.Widget, "generate"),
        .test_tab = if (debug_build) try TestSeedsTab.init(gpa, root) else {},
        .badge_styles = layout.badgeStyles(),
        .st = Settings.defaults(),
        .custom_presets = engine.custompresets.CustomPresetList.init(gpa),
        .custom_preset_arena = std.heap.ArenaAllocator.init(gpa),
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
    self.clearRestrictions();
    self.restrictions.deinit(self.gpa);
    if (debug_build) self.test_tab.deinit();
    self.freeItemNames();
    self.gpa.free(self.game_path);
    self.gpa.free(self.out_path);
    self.gpa.free(self.longshot_path);
    self.gpa.free(self.emulator_path);
    self.gpa.free(self.emulator_game_path);
    self.gpa.free(self.seed_text);
    self.gpa.free(self.last_seed);
    self.gpa.free(self.check_key);
    self.gpa.free(self.world_path);
    self.freeLocations();
    for ([_]*SearchPicker{ &self.excl_picker, &self.restrict_loc_picker, &self.restrict_item_picker, &self.preset_picker, &self.start_item_picker, &self.theme_picker }) |p| p.deinit();
    self.search_popup.deinit();
    self.picker_arena.deinit();
    for (self.seed_rows.items) |s| self.gpa.free(s);
    self.seed_rows.deinit(self.gpa);
    if (self.world) |w| w.deinit();
    for (self.queue.items.items) |m| self.queue.freeMessage(m);
    self.queue.items.deinit(self.gpa);
    self.check_arena.deinit();
    self.custom_presets.deinit();
    self.custom_preset_settings.deinit(self.gpa);
    self.custom_preset_arena.deinit();
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
    // a debug build (the Test Seeds tab, not in the GitHub releases) says so after the name at the top
    if (debug_build) (try find(self.root, r.Label, "app_title")).setText("Goggles of Truth Randomizer (Debug Build)");

    // user_settings.toml
    var load_arena = std.heap.ArenaAllocator.init(self.gpa);
    defer load_arena.deinit();
    const loaded = engine.usersettings.load(load_arena.allocator(), &self.env) catch return error.OutOfMemory;
    self.st = loaded.settings;
    for (loaded.settings.excluded()) |n| self.addExcluded(n);
    self.st.set(.excluded_locations, .{ .list = &.{} });
    self.takeRestrictions(&loaded.settings);
    self.takeStartingInventory(&loaded.settings);
    self.setOwned(&self.game_path, loaded.paths.game);
    self.setOwned(&self.out_path, loaded.paths.output);
    self.romfs_in.setText(self.z(self.game_path));
    self.out_in.setText(self.z(self.out_path));
    self.setOwned(&self.longshot_path, loaded.paths.longshot);
    self.setOwned(&self.emulator_path, loaded.paths.emulator);
    self.setOwned(&self.emulator_game_path, loaded.paths.emulator_game);
    self.longshot_in.setText(self.z(self.longshot_path));
    self.emulator_in.setText(self.z(self.emulator_path));
    self.emulator_game_in.setText(self.z(self.emulator_game_path));

    // custom_presets.toml
    var preset_messages: std.ArrayList([]const u8) = .empty;
    const saved_presets = engine.custompresets.load(self.gpa, load_arena.allocator(), &self.env, &preset_messages) catch return error.OutOfMemory;
    self.custom_presets.deinit();
    self.custom_presets = saved_presets;
    self.fillPresetCombo();

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
        .{ .name = "rando.browse.longshot", .f = onBrowseLaunchPath },
        .{ .name = "rando.browse.emulator", .f = onBrowseLaunchPath },
        .{ .name = "rando.browse.emugame", .f = onBrowseLaunchPath },
        .{ .name = "rando.path.longshot", .f = onPathChanged },
        .{ .name = "rando.path.emulator", .f = onPathChanged },
        .{ .name = "rando.path.emugame", .f = onPathChanged },
        .{ .name = "rando.launch_game", .f = onLaunchGame },
        .{ .name = "rando.path.romfs", .f = onPathChanged },
        .{ .name = "rando.path.out", .f = onPathChanged },
        .{ .name = "rando.path.name", .f = onPathChanged },
        .{ .name = "rando.path.seed", .f = onPathChanged },
        .{ .name = "rando.save_preset", .f = onSavePreset },
        .{ .name = "rando.delete_preset", .f = onDeletePreset },
        .{ .name = "rando.refresh_seeds", .f = onRefreshSeeds },
        .{ .name = "rando.play_selected", .f = onPlaySelected },
        .{ .name = "rando.rebuild_selected", .f = onRebuildSelected },
        .{ .name = "rando.play_seed", .f = onPlaySeed },
        .{ .name = "rando.toggle_excluded", .f = onToggleExcluded },
        .{ .name = "rando.restrict_add", .f = onRestrictAdd },
        .{ .name = "rando.restrict_remove", .f = onRestrictRemove },
        .{ .name = "rando.restrict_clear", .f = onRestrictClear },
        .{ .name = "rando.start_remove", .f = onStartRemove },
        .{ .name = "rando.start_clear", .f = onStartClear },
    };
    inline for (actions) |action| r.actionBind(action.name, self, action.f);
    // the Randomize buttons: everything, each tab, each card (a setting group); bound from the setting table
    r.actionBind(randomize_all_action, self, onRandomize);
    inline for (settings.specs) |s| {
        r.actionBind(randomize_tab_prefix ++ s.tab, self, onRandomize);
        r.actionBind(randomize_group_prefix ++ s.tab ++ "/" ++ s.group, self, onRandomize);
    }
    self.search_popup.bind();
    self.excl_picker.bind(&self.search_popup, self, onExcludePicked);
    self.restrict_loc_picker.bind(&self.search_popup, self, null);
    self.restrict_item_picker.bind(&self.search_popup, self, null);
    self.preset_picker.bind(&self.search_popup, self, onPresetPicked);
    self.start_item_picker.bind(&self.search_popup, self, onStartItemPicked);
    self.start_item_picker.setItems(&start_picker_labels, &start_picker_values);
    self.theme_picker.bind(&self.search_popup, self, onThemePicked);
    self.theme_picker.setItems(&themes.theme_labels, &themes.theme_values);
    if (themes.indexOfTheme(loaded.app.theme)) |index| {
        self.theme_index = index;
    } else {
        self.writeFmt("user_settings.toml: unknown theme \"{s}\"; using {s}.", .{ loaded.app.theme, themes.themes[0].label });
    }
    self.theme_picker.pick(self.theme_index);
    self.applyWindowTheme();
    if (debug_build) TestSeedsTab.bindActions(self);

    for (&settings.specs) |*s| {
        if (s.kind == .list) continue;
        const key = @tagName(s.key);
        const name = self.fmtZ("set_{s}", .{key});
        const w = self.root.find(name) orelse return fail("src/ui/main.xml has no widget named {s}", .{name});
        self.controls[@backingInt(s.key)] = w;
        const border = try find(self.root, r.Border, self.fmtZ("badge_{s}", .{key}));
        const label = try find(self.root, r.Label, self.fmtZ("badgelab_{s}", .{key}));
        self.badges[@backingInt(s.key)] = .{ .border = border, .label = label };
        // one function for every setting: the action's name says which (set.<key>)
        r.actionBind(self.fmtZ("set.{s}", .{key}), self, onSetting);
        try self.showSetting(s);
    }
    self.updateDependent();
    self.updateExcludedCount();
    self.fillRestrictions();
    self.fillStartingInventory();
    self.loaded = true;
    self.refreshString();
    self.write("Ready. Pick your romfs and an output folder, then Generate.");
    for (loaded.messages) |m| self.write(m);
    for (preset_messages.items) |m| self.write(m);
    // what the launcher's last update left behind (the replaced files), or an interrupted one put back
    engine.updater.removeLeftovers(self.gpa, self.io, self.env.app_dir);
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
    const w = self.controls[@backingInt(s.key)] orelse return;
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
        const w = self.controls[@backingInt(d.key)] orelse continue;
        const also = if (d.also) |v| self.st.is(d.other, v) else false;
        w.setEnabled(self.st.is(d.other, d.value) or also);
    }
}

/// A choice setting's badge follows its chosen option ("Scarce" is Experimental, "Balanced" Stable).
fn updateBadge(self: *App, key: Key) void {
    if (settings.spec(key).kind != .choice) return;
    const badge = self.badges[@backingInt(key)] orelse return;
    const style = self.badge_styles[@backingInt(settings.settingStatus(key, self.st.choice(key)))];
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
    const restrictions = try allocator.alloc([]const u8, self.restrictions.items.len);
    for (self.restrictions.items, 0..) |entry, i| restrictions[i] = try allocator.dupe(u8, entry);
    st.set(.item_restrictions, .{ .list = restrictions });
    st.set(.starting_inventory, .{ .list = try startinventory.listOf(allocator, &self.start_counts) });
    return st;
}

fn applySettings(self: *App, st: Settings) void {
    self.st = st;
    self.clearExcluded();
    for (st.excluded()) |n| self.addExcluded(n);
    self.st.set(.excluded_locations, .{ .list = &.{} });
    self.takeRestrictions(&st);
    self.takeStartingInventory(&st);
    for (&settings.specs) |*s| self.showSetting(s) catch {};
    self.updateDependent();
    self.fillExclusions();
    self.fillRestrictions();
    self.fillStartingInventory();
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
    self.syncing = true;
    self.preset_picker.pick(self.presetIndexFor(st));
    self.syncing = false;
    self.preset_lab.setText(if (self.save()) "Saved to user_settings.toml" else "Couldn't save user_settings.toml");
}

/// The preset drop-down: "Custom", the built-in presets, then the saved ones (with a star). Each saved preset's
/// settings are read here once, so matching them on every change doesn't parse a settings string.
fn fillPresetCombo(self: *App) void {
    _ = self.custom_preset_arena.reset(.retain_capacity);
    self.custom_preset_settings.clearRetainingCapacity();
    self.syncing = true;
    defer self.syncing = false;
    const a = self.custom_preset_arena.allocator();
    const count = layout.preset_items.len + self.custom_presets.presets.items.len;
    const labels = a.alloc([:0]const u8, count) catch return;
    for (layout.preset_items, 0..) |name, i| labels[i] = a.dupeSentinel(u8, name, 0) catch return;
    var shown: usize = layout.preset_items.len;
    for (self.custom_presets.presets.items) |preset| {
        // custompresets.load and onSavePreset only keep settings strings that read, so the fallback is never used
        const saved_settings = settings.fromString(a, preset.settings_string) catch Settings.defaults();
        // why: the picker's rows and this list must stay index for index, so stop adding both at once
        self.custom_preset_settings.append(self.gpa, saved_settings) catch break;
        labels[shown] = std.fmt.allocPrintSentinel(a, "\u{2605} {s}", .{preset.name}, 0) catch break;
        shown += 1;
    }
    self.preset_picker.setItems(labels[0..shown], labels[0..shown]);
    self.preset_picker.pick(0);
}

/// The drop-down index for `st`: a built-in preset it matches, else a saved one, else 0 ("Custom").
fn presetIndexFor(self: *App, st: *const Settings) usize {
    if (settings.matchingPreset(st)) |name| {
        for (layout.preset_items, 0..) |item, index| {
            if (std.mem.eql(u8, item, name)) return index;
        }
    }
    for (self.custom_preset_settings.items, 0..) |*saved_settings, custom_index| {
        if (settings.sameGameplaySettings(st, saved_settings)) return layout.preset_items.len + custom_index;
    }
    return 0;
}

/// The saved preset chosen in the drop-down, or null (Custom or a built-in preset).
fn selectedCustomPresetIndex(self: *App) ?usize {
    const index = self.preset_picker.chosenIndex() orelse return null;
    if (index < layout.preset_items.len) return null;
    const custom_index: usize = index - layout.preset_items.len;
    if (custom_index >= self.custom_preset_settings.items.len) return null;
    return custom_index;
}

fn onPresetPicked(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    const index = self.preset_picker.chosenIndex() orelse return;
    // "Custom", or set from code
    if (self.syncing or index == 0) return;
    const st = self.currentSettings(self.frame.allocator()) catch return;
    if (index < layout.preset_items.len) {
        const name = layout.preset_items[index];
        const preset = settings.findPreset(name) orelse return;
        self.applySettings(settings.applyPreset(st, preset));
        self.writeFmt("Preset {s} applied.", .{name});
        return;
    }
    const custom_index = self.selectedCustomPresetIndex() orelse return;
    const saved = self.custom_presets.presets.items[custom_index];
    // the name box shows it, so Save Preset updates this preset
    self.preset_name_in.setText(self.z(saved.name));
    self.applySettings(settings.applyGameplaySettings(st, &self.custom_preset_settings.items[custom_index]));
    self.writeFmt("Your preset {s} applied.", .{saved.name});
}

fn onSavePreset(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const name = std.mem.trim(u8, self.preset_name_in.getText(), " \t");
    engine.custompresets.validatePresetName(name) catch {
        self.messageBox("Save preset", "Type a name for your preset first (up to 40 characters, without |). It can't be Custom or the name of a built-in preset (Beginner, Standard, Expert, Race).");
        return;
    };
    const a = self.frame.allocator();
    const st = self.currentSettings(a) catch return;
    const settings_string = settings.toString(a, &st) catch return;
    const existed = self.custom_presets.indexOfName(name) != null;
    _ = self.custom_presets.savePreset(name, settings_string) catch {
        self.write("Couldn't save the preset (out of memory).");
        return;
    };
    self.storeCustomPresets();
    self.fillPresetCombo();
    self.settingsChanged(&st);
    if (existed) self.writeFmt("Your preset {s} updated.", .{name}) else self.writeFmt("Your preset {s} saved.", .{name});
}

fn onDeletePreset(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const custom_index = self.selectedCustomPresetIndex() orelse {
        self.messageBox("Delete preset", "Choose one of your saved presets (marked with a star) in the Seed preset list first. The built-in presets can't be deleted.");
        return;
    };
    const name = self.z(self.custom_presets.presets.items[custom_index].name);
    self.custom_presets.removePreset(custom_index);
    self.storeCustomPresets();
    self.fillPresetCombo();
    self.preset_name_in.setText("");
    const st = self.currentSettings(self.frame.allocator()) catch return;
    self.settingsChanged(&st);
    self.writeFmt("Your preset {s} deleted.", .{name});
}

/// Writes custom_presets.toml (the log says when it can't).
fn storeCustomPresets(self: *App) void {
    const failure = engine.custompresets.save(self.frame.allocator(), &self.env, &self.custom_presets) catch {
        self.write("Couldn't save custom_presets.toml (out of memory).");
        return;
    };
    if (failure) |reason| self.writeFmt("Couldn't save custom_presets.toml: {s}", .{reason});
}

const randomize_all_action = "rando.randomize.all";
/// + a tab's name (settings Spec.tab): its Randomize This Tab button
const randomize_tab_prefix = "rando.randomize.tab.";
/// + "<tab>/<group>": a card's Randomize button
const randomize_group_prefix = "rando.randomize.group.";

/// A Randomize button: random values for every setting it covers that the buttons may change
/// (settings/randomize.zig: Stable and In Testing only, never the lists, General Settings or Logic Rules).
fn onRandomize(self: *App, _: ?r.Widget, action: [:0]const u8) void {
    const name: []const u8 = action;
    const scope: settings.randomize.Scope = if (std.mem.eql(u8, name, randomize_all_action))
        .all
    else if (std.mem.startsWith(u8, name, randomize_group_prefix)) blk: {
        const rest = name[randomize_group_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
        break :blk .{ .group = .{ .tab = rest[0..slash], .group = rest[slash + 1 ..] } };
    } else if (std.mem.startsWith(u8, name, randomize_tab_prefix))
        .{ .tab = name[randomize_tab_prefix.len..] }
    else
        return;
    var raw: [8]u8 = undefined;
    self.io.random(&raw);
    var rng = Rng.init(std.mem.readInt(u64, &raw, .little));
    const a = self.frame.allocator();
    var st = self.currentSettings(a) catch return;
    const changed = settings.randomize.randomizeSettings(&st, &rng, scope);
    self.applySettings(st);
    const what: []const u8 = switch (scope) {
        .all => "every gameplay setting",
        .tab => |tab| std.fmt.allocPrint(a, "the {s} tab", .{tab}) catch "the tab",
        .group => |g| std.fmt.allocPrint(a, "{s}", .{g.group}) catch "the card",
    };
    self.writeFmt("Randomized {s}: {d} settings changed (Experimental options and Logic Rules are left alone).", .{ what, changed });
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

/// The excluded locations, in the order they were excluded (double-click one to include it again).
fn fillExclusions(self: *App) void {
    self.excl_list.clearItems();
    for (self.excluded.keys()) |name| _ = self.excl_list.addItem(self.z(name));
    self.updateExcludedCount();
}

/// Picking a location excludes it; the picker is cleared for the next one.
fn onExcludePicked(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    const name = self.excl_picker.selected() orelse return;
    if (self.excluded.contains(name)) {
        self.writeFmt("{s} is already excluded.", .{name});
    } else {
        self.addExcluded(name);
        self.fillExclusions();
        self.refreshString();
    }
    self.excl_picker.clear();
}

fn onToggleExcluded(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const list = (sender orelse return).as(r.ListView) orelse return;
    const index = list.getSelected();
    if (index < 0 or index >= self.excluded.count()) return;
    self.removeExcluded(self.excluded.keys()[@intCast(index)]);
    self.fillExclusions();
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

// ------------------------------------------------------------------------------------- item restrictions

/// Moves the Item Restrictions of `st` into `restrictions` (the setting itself stays empty in `self.st`).
fn takeRestrictions(self: *App, st: *const Settings) void {
    self.clearRestrictions();
    for (st.itemRestrictions()) |entry| self.addRestriction(entry);
    self.st.set(.item_restrictions, .{ .list = &.{} });
}

fn addRestriction(self: *App, entry: []const u8) void {
    for (self.restrictions.items) |existing| if (std.mem.eql(u8, existing, entry)) return;
    const copy = self.gpa.dupe(u8, entry) catch return;
    self.restrictions.append(self.gpa, copy) catch self.gpa.free(copy);
}

fn clearRestrictions(self: *App) void {
    for (self.restrictions.items) |entry| self.gpa.free(entry);
    self.restrictions.clearRetainingCapacity();
}

fn freeItemNames(self: *App) void {
    for (self.item_names) |n| self.gpa.free(n);
    self.gpa.free(self.item_names);
    self.item_names = &.{};
}

fn fillRestrictions(self: *App) void {
    self.restrict_list.clearItems();
    for (self.restrictions.items) |entry| _ = self.restrict_list.addItem(self.z(entry));
    const n = self.restrictions.items.len;
    self.restrict_count.setText(if (n == 0) self.z("No rules") else self.fmtZ("{d} rule{s}", .{ n, if (n == 1) "" else "s" }));
}

/// The location and item pickers from the last scan's names.
fn fillLocationPickers(self: *App) void {
    const a = self.picker_arena.allocator();
    const labels = a.alloc([:0]const u8, self.locations.len) catch return;
    for (self.locations, 0..) |name, i| labels[i] = a.dupeSentinel(u8, name, 0) catch return;
    self.excl_picker.setItems(labels, @ptrCast(self.locations));
    self.restrict_loc_picker.setItems(labels, @ptrCast(self.locations));
}

fn fillRestrictionItems(self: *App) void {
    const a = self.picker_arena.allocator();
    const labels = a.alloc([:0]const u8, self.item_names.len) catch return;
    for (self.item_names, 0..) |name, i| labels[i] = a.dupeSentinel(u8, name, 0) catch return;
    self.restrict_item_picker.setItems(labels, @ptrCast(self.item_names));
}

/// Forbid: the picked item at the picked location.
fn onRestrictAdd(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const location = self.restrict_loc_picker.selected() orelse {
        self.write("Item restrictions: pick a location first (scan the game on the General Settings tab to fill the list).");
        return;
    };
    const item = self.restrict_item_picker.selected() orelse {
        self.write("Item restrictions: pick an item first.");
        return;
    };
    const restriction = settings.ItemRestriction{ .location = location, .item = item };
    const entry = settings.formatItemRestriction(self.frame.allocator(), restriction) catch return;
    self.addRestriction(entry);
    self.fillRestrictions();
    self.refreshString();
}

fn onRestrictRemove(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const list = (sender orelse return).as(r.ListView) orelse return;
    const index = list.getSelected();
    if (index < 0 or index >= self.restrictions.items.len) return;
    self.gpa.free(self.restrictions.orderedRemove(@intCast(index)));
    self.fillRestrictions();
    self.refreshString();
}

fn onRestrictClear(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.clearRestrictions();
    self.fillRestrictions();
    self.refreshString();
}

// ------------------------------------------------------------------------------------- starting inventory

fn startGroupHeading(group: startinventory.Group) []const u8 {
    return switch (group) {
        .equipment => "Equipment",
        .items => "Items",
        .upgrades => "Upgrades",
        .songs => "Songs",
        .hearts => "Hearts",
    };
}

/// Moves the Starting Inventory of `st` into `start_counts` (the setting itself stays empty in `self.st`).
fn takeStartingInventory(self: *App, st: *const Settings) void {
    self.start_counts = startinventory.countsOf(st.startingInventory());
    self.st.set(.starting_inventory, .{ .list = &.{} });
}

/// "Hookshot / Longshot  (1 of 2: Hookshot)" for a tiered entry, "Empty Bottle  x2" for a repeated one.
fn startEntryText(self: *App, entry_index: usize) [:0]const u8 {
    const entry = &startinventory.entries[entry_index];
    const n = self.start_counts[entry_index];
    if (n == 0) return self.fmtZ("      {s}", .{entry.label});
    if (entry.tiers.len > 1) {
        const tier = tierLabel(entry, n - 1);
        return self.fmtZ("{s}  ({d} of {d}: {s})", .{ entry.label, n, entry.max, tier });
    }
    if (entry.max > 1) return self.fmtZ("{s}  x{d}", .{ entry.label, n });
    return self.z(entry.label);
}

/// Tier `tier_index` of a tiered entry as the window names it: that part of the entry's label, which names the
/// tiers in order, separated by " / " ("Hookshot / Longshot": 1 -> "Longshot").
fn tierLabel(entry: *const startinventory.Entry, tier_index: usize) []const u8 {
    var parts = std.mem.splitSequence(u8, entry.label, " / ");
    var at: usize = 0;
    while (parts.next()) |part| : (at += 1) {
        if (at == tier_index) return part;
    }
    return entry.itemOfCopy(tier_index);
}

/// The item picker's rows: every Starting Inventory entry with its group, so typing "songs" finds the songs.
const start_picker_labels = blk: {
    @setEvalBranchQuota(20000);
    var labels: [startinventory.entries.len][:0]const u8 = undefined;
    for (startinventory.entries, 0..) |e, i| labels[i] = e.label ++ "   (" ++ startGroupHeading(e.group) ++ ")";
    break :blk labels;
};
const start_picker_values = blk: {
    var values: [startinventory.entries.len][]const u8 = undefined;
    for (start_picker_labels, 0..) |label, i| values[i] = label;
    break :blk values;
};

/// The starting items list (what is chosen) and its count.
fn fillStartingInventory(self: *App) void {
    self.start_chosen_list.clearItems();
    self.start_chosen_count = 0;
    var copies: usize = 0;
    for (self.start_counts, 0..) |n, i| {
        if (n == 0) continue;
        copies += n;
        self.start_chosen_rows[self.start_chosen_count] = i;
        self.start_chosen_count += 1;
        _ = self.start_chosen_list.addItem(self.startEntryText(i));
    }
    self.start_count.setText(if (copies == 0) "Nothing chosen" else self.fmtZ("{d} item{s} at the start", .{ copies, if (copies == 1) "" else "s" }));
}

/// Picking an item adds a copy (a tiered item its next tier); the picker is cleared for the next one.
fn onStartItemPicked(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    const entry_index = self.start_item_picker.chosenIndex() orelse return;
    self.start_item_picker.clear();
    const entry = &startinventory.entries[entry_index];
    if (self.start_counts[entry_index] >= entry.max) {
        self.writeFmt("Starting Inventory: {s} is already at its most ({d}).", .{ entry.label, entry.max });
        return;
    }
    self.start_counts[entry_index] += 1;
    self.fillStartingInventory();
    self.refreshString();
}

fn onStartRemove(self: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const list = (sender orelse return).as(r.ListView) orelse return;
    const row = list.getSelected();
    if (row < 0 or row >= self.start_chosen_count) return;
    const entry_index = self.start_chosen_rows[@intCast(row)];
    if (self.start_counts[entry_index] == 0) return;
    self.start_counts[entry_index] -= 1;
    self.fillStartingInventory();
    self.refreshString();
}

fn onStartClear(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    self.start_counts = @splat(0);
    self.fillStartingInventory();
    self.refreshString();
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

const PathField = enum { game, output, name, seed, longshot, emulator, emulator_game };

fn onPathChanged(self: *App, sender: ?r.Widget, action: [:0]const u8) void {
    const input = (sender orelse return).as(r.TextInput) orelse return;
    const field: PathField = if (std.mem.endsWith(u8, action, ".romfs")) .game else if (std.mem.endsWith(u8, action, ".out")) .output else if (std.mem.endsWith(u8, action, ".seed")) .seed else if (std.mem.endsWith(u8, action, ".longshot")) .longshot else if (std.mem.endsWith(u8, action, ".emulator")) .emulator else if (std.mem.endsWith(u8, action, ".emugame")) .emulator_game else .name;
    self.pathChanged(field, input.getText());
}

fn pathChanged(self: *App, field: PathField, text: []const u8) void {
    switch (field) {
        .game => self.setOwned(&self.game_path, text),
        .output => self.setOwned(&self.out_path, text),
        .seed => self.setOwned(&self.seed_text, text),
        .longshot => self.setOwned(&self.longshot_path, text),
        .emulator => self.setOwned(&self.emulator_path, text),
        .emulator_game => self.setOwned(&self.emulator_game_path, text),
        .name => {},
    }
    if (field == .output) self.fillSeeds();
    if (field == .game) _ = self.verifyGame();
    const is_saved_path = switch (field) {
        .game, .output, .longshot, .emulator, .emulator_game => true,
        .name, .seed => false,
    };
    if (is_saved_path and self.loaded) _ = self.save();
}

/// Browse buttons of the Launch Game card: the Longshot game folder, the emulator program, the emulator's game file.
fn onBrowseLaunchPath(self: *App, _: ?r.Widget, action: [:0]const u8) void {
    const a = self.frame.allocator();
    if (std.mem.endsWith(u8, action, ".longshot")) {
        const current = std.mem.trim(u8, self.longshot_path, " \t");
        const folder = r.fileDialogSelectFolder(.{
            .parent = self.window,
            .title = "Select the Longshot game folder (with longshot.exe and the mods folder)",
            .directory = if (self.env.fs.isDir(current)) self.z(current) else null,
        });
        const chosen = engine.gamefiles.cleanPath(a, folder) catch return;
        if (chosen.len == 0) return;
        self.longshot_in.setText(self.z(chosen));
        self.pathChanged(.longshot, chosen);
        return;
    }
    const is_emulator = std.mem.endsWith(u8, action, ".emulator");
    const current = std.mem.trim(u8, if (is_emulator) self.emulator_path else self.emulator_game_path, " \t");
    const folder = if (self.env.fs.isDir(current)) current else fsmod.dirname(current);
    const program_filters = [_]r.FileFilter{
        .{ .name = "Programs", .patterns = engine.host.program_file_patterns.ptr },
        .{ .name = "All files", .patterns = "*" },
    };
    const game_filters = [_]r.FileFilter{
        .{ .name = "Switch games (*.nsp, *.xci, *.nca)", .patterns = "*.nsp;*.xci;*.nca" },
        .{ .name = "All files", .patterns = "*" },
    };
    const path = r.fileDialogOpen(.{
        .parent = self.window,
        .title = if (is_emulator) "Select the emulator program" else "Select the game file the emulator starts",
        .directory = if (folder.len > 0 and self.env.fs.isDir(folder)) self.z(folder) else null,
        .filters = if (is_emulator) &program_filters else &game_filters,
    }) orelse return;
    if (path.len == 0) return;
    if (is_emulator) {
        self.emulator_in.setText(path);
        self.pathChanged(.emulator, path);
    } else {
        self.emulator_game_in.setText(path);
        self.pathChanged(.emulator_game, path);
    }
}

/// Launch Game: starts Longshot or the emulator the output folder belongs to (platform/launcher.zig).
fn onLaunchGame(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const out = std.mem.trim(u8, self.out_path, " \t");
    const plan = switch (engine.launcher.planLaunch(a, &self.env, out, .{
        .longshot = self.longshot_path,
        .emulator = self.emulator_path,
        .emulator_game = self.emulator_game_path,
    }) catch return) {
        .ready => |ready| ready,
        .problem => |problem| {
            self.messageBox("Launch Game", problem);
            return;
        },
    };
    if (engine.saves.targetFor(a, &self.env, out) catch null) |target| {
        if (engine.saves.gameRunning(a, &self.env, target)) |running| {
            if (running.len > 0) {
                self.messageBox("Launch Game", self.fmtZ("{s} is already running.", .{running}));
                return;
            }
        }
    }
    if (plan.note.len > 0) self.write(plan.note);
    engine.launcher.launch(&self.env, plan) catch {
        self.messageBox("Launch Game", self.fmtZ("{s} couldn't be started.", .{plan.program}));
        return;
    };
    self.writeFmt("Launch Game: started {s} ({s}).", .{ plan.program, plan.kind.label() });
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
        c = themes.codeColors().success;
    } else if (g.status == .missing) {
        text = self.z(g.message);
        c = themes.codeColors().muted;
    } else {
        const first_line = g.message[0 .. std.mem.indexOfScalar(u8, g.message, '\n') orelse g.message.len];
        text = self.z(first_line);
        c = themes.codeColors().danger;
    }
    self.game_lab.setText(text);
    self.game_lab.setColor(c);
    self.hash_lab.setText(self.fmtZ("exefs/main SHA-256: {s}", .{if (g.sha256.len > 0) g.sha256 else "-"}));
    self.hash_lab.setColor(if (g.sha256.len > 0) c else themes.codeColors().muted);
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
        self.messageBox("Output", "The output folder doesn't exist yet.\nChoose one on the General Settings tab, or generate a seed first.");
        return;
    }
    const opener: []const u8 = engine.host.folder_opener_command;
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

/// The mod folder name to write: "" (named after the seed, which is new) as it is; a chosen name that is already a
/// folder in the output folder gets " (2)", " (3)"... so a new seed never overwrites the earlier one. Null when
/// out of memory.
fn unusedModName(self: *App, allocator: Allocator, out: []const u8, chosen_name: []const u8) ?[]const u8 {
    if (chosen_name.len == 0) return chosen_name;
    var candidate: []const u8 = chosen_name;
    var copy_number: usize = 2;
    while (true) : (copy_number += 1) {
        const folder = fsmod.join(allocator, &.{ out, candidate }) catch return null;
        if (!self.env.fs.exists(folder)) break;
        candidate = std.fmt.allocPrint(allocator, "{s} ({d})", .{ chosen_name, copy_number }) catch return null;
    }
    if (candidate.ptr != chosen_name.ptr) self.writeFmt("Mod folder {s} already exists: writing {s} instead.", .{ chosen_name, candidate });
    return candidate;
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
    kind: enum { scan, generate, test_seed },
    game: []const u8,
    request: engine.generator.Request,
    /// test_seed: the plan's text (in the job's arena); `request` then holds the base settings and the folders
    plan_text: []const u8 = "",
};

/// The Test Seeds tab's Generate Test Seed: the plan made into GogglesOfTruth_<name> on the worker, with the
/// window's settings standing in for a plan without a settings string (generator/testseed.zig, as `goggles_cli
/// test` does with user_settings.toml).
pub fn startTestSeed(self: *App, plan_text: []const u8) void {
    const paths = self.checkPaths(true) orelse return;
    if (!self.requireGame()) return;
    const st = self.currentSettings(self.frame.allocator()) catch return;
    self.setOwned(&self.game_path, paths.game);
    self.setOwned(&self.out_path, paths.out);
    _ = self.save();
    self.startJobWithPlan(.test_seed, paths.game, .{ .game_path = paths.game, .out_dir = paths.out, .settings = st }, plan_text);
}

fn startJob(self: *App, kind: @FieldType(Job, "kind"), game: []const u8, request: ?engine.generator.Request) void {
    self.startJobWithPlan(kind, game, request, "");
}

fn startJobWithPlan(self: *App, kind: @FieldType(Job, "kind"), game: []const u8, request: ?engine.generator.Request, plan_text: []const u8) void {
    if (self.busy) return;
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .app = self, .arena = std.heap.ArenaAllocator.init(self.gpa), .kind = kind, .game = "", .request = undefined };
    const a = job.arena.allocator();
    job.game = a.dupe(u8, game) catch return self.jobFailed(job);
    job.plan_text = a.dupe(u8, plan_text) catch return self.jobFailed(job);
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
        const restrictions = a.alloc([]const u8, req.settings.itemRestrictions().len) catch return self.jobFailed(job);
        for (req.settings.itemRestrictions(), 0..) |entry, i| restrictions[i] = a.dupe(u8, entry) catch return self.jobFailed(job);
        copy.settings.set(.item_restrictions, .{ .list = restrictions });
        // a rebuilt test seed's chosen placements, too
        const placements = a.alloc(engine.seedinfo.TestPlacement, req.test_placements.len) catch return self.jobFailed(job);
        for (req.test_placements, 0..) |placement, i| placements[i] = .{
            .location = a.dupe(u8, placement.location) catch return self.jobFailed(job),
            .item = a.dupe(u8, placement.item) catch return self.jobFailed(job),
        };
        copy.test_placements = placements;
        job.request = copy;
    }
    self.busy = true;
    self.gen_btn.setEnabled(false);
    if (debug_build) self.test_tab.setBusy(true);
    self.worker = std.Thread.spawn(.{}, workerMain, .{job}) catch {
        self.busy = false;
        self.gen_btn.setEnabled(true);
        if (debug_build) self.test_tab.setBusy(false);
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
    if (itemNamesForRestrictions(self.gpa, w)) |item_names| self.queue.push(.{ .kind = .items, .list = item_names }) else |_| {}
    if (debug_build) {
        // the Test Seeds tab's drop-downs: every string copied, so they outlive this game (teststart.buildCatalog)
        const box = self.gpa.create(CatalogBox) catch return true;
        box.arena = std.heap.ArenaAllocator.init(self.gpa);
        if (engine.teststart.buildCatalog(box.arena.allocator(), w)) |catalog| {
            box.catalog = catalog;
            self.queue.push(.{ .kind = .catalog, .catalog = box });
        } else |err| {
            box.arena.deinit();
            self.gpa.destroy(box);
            self.queue.pushText(.log, self.fmtWorker("Test Seeds: the game's names couldn't be read ({s})", .{@errorName(err)}));
        }
    }
    self.queue.pushText(.log, self.fmtWorker("Found {d} item locations.", .{w.locations.items.len}));
    return true;
}

/// The drop-down's items for Item Restrictions: every check's own item except junk, and the Progressive lines, by
/// the names the spoiler log uses, sorted, each once. Allocated with `allocator`.
fn itemNamesForRestrictions(allocator: Allocator, w: *engine.world.World) error{OutOfMemory}![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (w.locations.items) |l| {
        const key = w.items.name(l.vanilla);
        if (engine.world.isJunkName(key)) continue;
        const display_name = try w.itemNameById(arena.allocator(), l.vanilla);
        if ((try seen.getOrPut(arena.allocator(), display_name)).found_existing) continue;
        try names.append(allocator, try allocator.dupe(u8, display_name));
    }
    for (engine.progressive.chains) |chain| {
        if ((try seen.getOrPut(arena.allocator(), chain.display_name)).found_existing) continue;
        try names.append(allocator, try allocator.dupe(u8, chain.display_name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, x: []u8, y: []u8) bool {
            return std.ascii.orderIgnoreCase(x, y) == .lt;
        }
    }.less);
    return names.toOwnedSlice(allocator);
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
        .test_seed => {
            const a = job.arena.allocator();
            var problem = engine.testseed.Problem{};
            const prepared = engine.testseed.prepare(a, self.env.fs, job.plan_text, job.request.settings, job.request.game_path, job.request.out_dir, &problem) catch |err| {
                self.queue.pushText(.failed, if (err == error.InvalidPlan) self.fmtWorker("test plan: {s}", .{problem.message}) else @errorName(err));
                return;
            };
            for (prepared.notes) |note| self.queue.pushText(.log, note);
            const result = engine.generator.generate(self.gpa, a, &self.env, prepared.request, self.world, &progress) catch |err| {
                self.queue.pushText(.failed, if (progress.failureMessage().len > 0) progress.failureMessage() else @errorName(err));
                return;
            };
            self.queue.pushText(.log, self.fmtWorker("Test seed {s} written to {s}. Start a NEW game in it to get the test start.", .{ result.seed, result.mod_root }));
            const list = self.gpa.alloc([]u8, 3) catch return;
            list[0] = self.gpa.dupe(u8, result.seed) catch &.{};
            list[1] = self.gpa.dupe(u8, result.mod_root) catch &.{};
            list[2] = self.gpa.dupe(u8, result.settings_string) catch &.{};
            self.queue.push(.{ .kind = .done, .list = list });
        },
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
    // why: every Generate makes a new seed. A seed number that was already made (this session, or a seed folder in
    // the output folder) gets a new random number instead, so the earlier seed's mod is never overwritten. A number
    // typed in that wasn't made yet (someone else's seed, say) is used as it is.
    const typed_seed = std.mem.trim(u8, self.seed_in.getText(), " \t");
    if (typed_seed.len > 0 and self.seedUsed(typed_seed)) {
        const old_seed = self.z(typed_seed);
        self.randomSeed();
        self.writeFmt("New seed number {s} (seed {s} is already made).", .{ self.seed_text, old_seed });
    }
    const seed = std.mem.trim(u8, self.seed_in.getText(), " \t");
    const name = self.unusedModName(a, paths.out, std.mem.trim(u8, self.name_in.getText(), " \t")) orelse return;
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
                // the pickers drop their rows first: the old names and labels go
                self.excl_picker.setItems(&.{}, &.{});
                self.restrict_loc_picker.setItems(&.{}, &.{});
                self.restrict_item_picker.setItems(&.{}, &.{});
                _ = self.picker_arena.reset(.retain_capacity);
                self.freeLocations();
                self.locations = self.gpa.dupe([]u8, m.list) catch &.{};
                // the names now belong to the window: the message must not free them
                for (m.list) |*n| n.* = &.{};
                self.fillLocationPickers();
                self.fillRestrictionItems();
                self.fillExclusions();
            },
            .catalog => if (debug_build) {
                if (m.catalog) |box| {
                    self.test_tab.takeCatalog(self, box.arena, box.catalog);
                    // the arena now belongs to the tab: the message frees an empty one in its place
                    box.arena = std.heap.ArenaAllocator.init(self.gpa);
                }
            },
            .items => {
                self.freeItemNames();
                self.item_names = self.gpa.dupe([]u8, m.list) catch &.{};
                // the names now belong to the window: the message must not free them
                for (m.list) |*n| n.* = &.{};
                self.fillRestrictionItems();
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
                if (debug_build) self.test_tab.setBusy(false);
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

/// Rebuild Seed: makes the selected seed again with this release (its own seed number, settings string and
/// folder), so a fix reaches a seed already being played: the items stay where they were and its saves still fit.
/// The window's own settings aren't used, except Per-Seed Saves (not part of a settings string).
fn onRebuildSelected(self: *App, _: ?r.Widget, _: [:0]const u8) void {
    const index = self.seeds_list.getSelected();
    if (self.busy) return;
    if (index < 0 or index >= self.seed_rows.items.len) {
        self.messageBox("Rebuild Seed", "Choose a seed in the list first.");
        return;
    }
    const paths = self.checkPaths(true) orelse return;
    if (!self.requireGame()) return;
    const a = self.frame.allocator();
    const target = (engine.saves.targetFor(a, &self.env, paths.out) catch null) orelse return;
    const seed_name = a.dupe(u8, self.seed_rows.items[@intCast(index)]) catch return;
    const folder = (engine.saves.seedFolder(a, &self.env, target, seed_name) catch null) orelse {
        self.messageBox("Rebuild Seed", "That seed's folder wasn't found; click Refresh.");
        return;
    };
    const info = switch (engine.generator.checkRebuild(a, self.env.fs, folder) catch return) {
        .ready => |ready| ready,
        .not_a_seed => {
            self.messageBox("Rebuild Seed", self.fmtZ("{s} has no readable settings.txt, so it can't be made again.", .{folder}));
            return;
        },
        .other_placements => |other| {
            const explanation = engine.generator.placementMismatchMessage(a, seed_name, other) catch return;
            self.messageBox("Rebuild Seed", self.fmtZ("{s}", .{explanation}));
            return;
        },
    };
    var st = engine.settings.fromString(a, info.settings_string) catch {
        self.messageBox("Rebuild Seed", "That seed's settings string can't be read by this version.");
        return;
    };
    st.set(.per_seed_saves, self.st.get(.per_seed_saves));
    const test_placements = engine.seedinfo.parseTestPlacements(a, info.test_placements) catch {
        self.messageBox("Rebuild Seed", "That seed's test placements can't be read.");
        return;
    };
    // why: a switched-off seed is switched on first, so the rebuild goes into its own folder (with its stored
    // saves) and not into a new one next to it
    var msg = engine.saves.Messages{ .allocator = a };
    const active_folder = engine.saves.switchOn(a, &self.env, target, seed_name, &msg) catch {
        self.messageBox("Rebuild Seed", if (msg.failure.len > 0) msg.failure else "The seed couldn't be switched on.");
        self.fillSeeds();
        return;
    };
    self.writeFmt("Rebuilding {s} (seed {s}, made by {s}) with {s}: same items and places, this version's fixes.", .{ seed_name, info.seed, info.release, engine.version.version });
    self.setOwned(&self.game_path, paths.game);
    self.setOwned(&self.out_path, paths.out);
    _ = self.save();
    self.startJob(.generate, paths.game, .{
        .game_path = paths.game,
        .out_dir = fsmod.dirname(active_folder),
        .settings = st,
        .seed = info.seed,
        .mod_name = fsmod.basename(active_folder),
        .exefs = "",
        .test_placements = test_placements,
        .rebuild = true,
    });
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

// ------------------------------------------------------------------------------------------------- theme

fn onThemePicked(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    const index = self.theme_picker.chosenIndex() orelse return;
    if (index == self.theme_index) return;
    self.theme_index = index;
    self.applyWindowTheme();
    if (self.loaded) _ = self.save();
}

/// Applies the chosen theme, then sets again what the code colours itself with the theme's colours.
fn applyWindowTheme(self: *App) void {
    themes.applyTheme(themes.themes[self.theme_index], self.wallpaper_texture);
    for ([_]*SearchPicker{ &self.excl_picker, &self.restrict_loc_picker, &self.restrict_item_picker, &self.preset_picker, &self.start_item_picker, &self.theme_picker }) |p| p.refreshColors();
    if (debug_build) for (self.test_tab.allPickers()) |p| p.refreshColors();
    _ = self.verifyGame();
}

// ---------------------------------------------------------------------------------------- user_settings.toml

/// Writes user_settings.toml. True when it was saved.
fn save(self: *App) bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = self.currentSettings(a) catch return false;
    const err = engine.usersettings.save(a, &self.env, &st, .{
        .game = self.game_path,
        .output = self.out_path,
        .longshot = self.longshot_path,
        .emulator = self.emulator_path,
        .emulator_game = self.emulator_game_path,
    }, .{ .theme = themes.themes[self.theme_index].value }) catch return false;
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
