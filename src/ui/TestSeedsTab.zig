//! The window's Test Seeds tab (debug builds only; src/ui/pages/test_seeds.xml): a test plan as a form.
//!
//! The form is the model: the text fields and drop-downs are read when the plan is written, and the lists (setting
//! changes, placed and forbidden items, start items, quests, flags, cutscenes) are kept here. `planText` writes the
//! plan as test_plans/TEMPLATE.test.toml describes it; the Plan list shows it after every change; Save Plan writes
//! it to a .test.toml file and Load Plan fills the form from one (core/testplan.zig reads it, so a file the command
//! line accepts loads). Generate Test Seed hands the text to the window's worker, which makes the seed with
//! generator/testseed.zig, as `goggles_cli test` does.
//!
//! The drop-downs come from the game scan: the worker builds teststart.Catalog after scanning and sends it here
//! (`takeCatalog`). Each long or changing list is a SearchPicker (src/ui/SearchPicker.zig): a drop-down whose popup
//! has a search field, so typing narrows the list. A flag the scan didn't find, or a number, is typed in (Enter).

const std = @import("std");
const r = @import("raven");
const engine = @import("engine");
const App = @import("App.zig");
const Allocator = std.mem.Allocator;
const testplan = engine.testplan;
const toml = engine.toml;
const Catalog = engine.teststart.Catalog;
const SearchPicker = @import("SearchPicker.zig");

const TestSeedsTab = @This();

/// A row of the "Place and forbid items" list.
const ItemRow = struct {
    forbid: bool,
    location: []u8,
    item: []u8,
};

/// A row of the "Story" list.
const StoryRow = union(enum) {
    quest: struct { quest: []u8, step: []u8 },
    /// `value` as the plan writes it: true, false, a whole number or a quoted value name
    flag: struct { name: []u8, value: []u8 },
    seen: []u8,
    unseen: []u8,
};

const Base = enum(i32) { window = 0, settings_string = 1, beginner = 2, standard = 3, expert = 4, race = 5 };

gpa: Allocator,
// widgets (test_seeds.xml)
name_in: r.TextInput,
seed_in: r.TextInput,
base_in: r.ComboBox,
settings_string_in: r.TextInput,
override_in: r.TextInput,
override_list: r.ListView,
item_list: r.ListView,
age_in: r.ComboBox,
time_in: r.ComboBox,
pos_in: [3]r.TextInput,
facing_in: r.TextInput,
start_item_list: r.ListView,
story_list: r.ListView,
plan_list: r.ListView,
generate_btn: r.Widget,

// the search pickers (SearchPicker widgets; they share the window's popup)
locations: SearchPicker,
items: SearchPicker,
scenes_picker: SearchPicker,
/// "the exact position below" first, then the chosen scene's start spots (none: the scene's entrance)
spots_picker: SearchPicker,
boots: SearchPicker,
start_items: SearchPicker,
quests_picker: SearchPicker,
steps_picker: SearchPicker,
flags: SearchPicker,
/// the picked flag's values (true/false, or an Enum's value names); a number is typed in
flag_values: SearchPicker,
cutscenes: SearchPicker,

// the lists (owned)
overrides: std.ArrayList([]u8) = .empty,
item_rows: std.ArrayList(ItemRow) = .empty,
start_item_rows: std.ArrayList([]u8) = .empty,
story_rows: std.ArrayList(StoryRow) = .empty,

/// the scanned game's catalog and the pickers' labels (null until a scan)
catalog_arena: std.heap.ArenaAllocator,
catalog: ?Catalog = null,
/// the start spots of the chosen scene (spots_picker's rows after its first)
spots: []const engine.teststart.StartSpot = &.{},
/// set while the form is filled in from code (a loaded plan), so the change handlers don't rewrite the plan
filling: bool = false,

fn picker(gpa: Allocator, root: r.Widget, comptime base: [:0]const u8, placeholder: [:0]const u8, none_label: ?[:0]const u8, editable: bool) App.AppError!SearchPicker {
    return SearchPicker.init(gpa, try App.find(root, r.Widget, base), try App.find(root, r.Label, base ++ "_label"), placeholder, none_label, editable);
}

pub fn init(gpa: Allocator, root: r.Widget) App.AppError!TestSeedsTab {
    return .{
        .gpa = gpa,
        .name_in = try App.find(root, r.TextInput, "ts_name"),
        .seed_in = try App.find(root, r.TextInput, "ts_seed"),
        .base_in = try App.find(root, r.ComboBox, "ts_base"),
        .settings_string_in = try App.find(root, r.TextInput, "ts_settings_string"),
        .override_in = try App.find(root, r.TextInput, "ts_override_in"),
        .override_list = try App.find(root, r.ListView, "ts_override_list"),
        .item_list = try App.find(root, r.ListView, "ts_item_list"),
        .age_in = try App.find(root, r.ComboBox, "ts_age"),
        .time_in = try App.find(root, r.ComboBox, "ts_time"),
        .pos_in = .{
            try App.find(root, r.TextInput, "ts_pos_x"),
            try App.find(root, r.TextInput, "ts_pos_y"),
            try App.find(root, r.TextInput, "ts_pos_z"),
        },
        .facing_in = try App.find(root, r.TextInput, "ts_facing"),
        .start_item_list = try App.find(root, r.ListView, "ts_start_item_list"),
        .story_list = try App.find(root, r.ListView, "ts_story_list"),
        .plan_list = try App.find(root, r.ListView, "ts_plan_list"),
        .generate_btn = try App.find(root, r.Widget, "ts_generate"),
        .locations = try picker(gpa, root, "ts_loc", "Pick a location...", null, false),
        .items = try picker(gpa, root, "ts_item", "Pick an item...", null, false),
        .scenes_picker = try picker(gpa, root, "ts_scene", "Pick a scene...", "(normal start, outside the Kokiri Shop)", false),
        .spots_picker = try picker(gpa, root, "ts_spot", "Pick a start spot...", "(the scene's entrance)", false),
        .boots = try picker(gpa, root, "ts_boot", "Pick a boot event...", "(no boot event)", false),
        .start_items = try picker(gpa, root, "ts_start_item", "Pick an item...", null, false),
        .quests_picker = try picker(gpa, root, "ts_quest", "Pick a quest...", null, false),
        .steps_picker = try picker(gpa, root, "ts_step", "Its step...", null, false),
        .flags = try picker(gpa, root, "ts_flag", "Pick a flag (or type any name and press Enter)...", null, true),
        .flag_values = try picker(gpa, root, "ts_flag_value", "Its value (or type a number)...", null, true),
        .cutscenes = try picker(gpa, root, "ts_cut", "Pick a cutscene...", null, false),
        .catalog_arena = std.heap.ArenaAllocator.init(gpa),
    };
}

fn allPickers(self: *TestSeedsTab) [11]*SearchPicker {
    return .{ &self.locations, &self.items, &self.scenes_picker, &self.spots_picker, &self.boots, &self.start_items, &self.quests_picker, &self.steps_picker, &self.flags, &self.flag_values, &self.cutscenes };
}

pub fn deinit(self: *TestSeedsTab) void {
    self.clearLists();
    self.overrides.deinit(self.gpa);
    self.item_rows.deinit(self.gpa);
    self.start_item_rows.deinit(self.gpa);
    self.story_rows.deinit(self.gpa);
    for (self.allPickers()) |p| p.deinit();
    self.catalog_arena.deinit();
}

/// The actions of test_seeds.xml, and the pickers' callbacks.
pub fn bindActions(app: *App) void {
    const actions = [_]struct { name: [:0]const u8, f: fn (*App, ?r.Widget, [:0]const u8) void }{
        .{ .name = "ts.changed", .f = onChanged },
        .{ .name = "ts.override_add", .f = onOverrideAdd },
        .{ .name = "ts.override_remove", .f = onOverrideRemove },
        .{ .name = "ts.place_add", .f = onPlaceAdd },
        .{ .name = "ts.forbid_add", .f = onForbidAdd },
        .{ .name = "ts.item_remove", .f = onItemRemove },
        .{ .name = "ts.start_item_add", .f = onStartItemAdd },
        .{ .name = "ts.start_item_remove", .f = onStartItemRemove },
        .{ .name = "ts.quest_add", .f = onQuestAdd },
        .{ .name = "ts.flag_add", .f = onFlagAdd },
        .{ .name = "ts.cut_seen", .f = onCutSeen },
        .{ .name = "ts.cut_unseen", .f = onCutUnseen },
        .{ .name = "ts.story_remove", .f = onStoryRemove },
        .{ .name = "ts.load", .f = onLoad },
        .{ .name = "ts.save", .f = onSave },
        .{ .name = "ts.clear", .f = onClear },
        .{ .name = "ts.generate", .f = onGenerate },
    };
    inline for (actions) |action| r.actionBind(action.name, app, action.f);
    const self = tab(app);
    self.base_in.setSelected(@intFromEnum(Base.window));
    self.age_in.setSelected(0);
    self.time_in.setSelected(0);
    const popup = &app.search_popup;
    self.locations.bind(popup, app, null);
    self.items.bind(popup, app, null);
    self.scenes_picker.bind(popup, app, onScenePicked);
    self.spots_picker.bind(popup, app, onSpotPicked);
    self.boots.bind(popup, app, onPlanPicked);
    self.start_items.bind(popup, app, null);
    self.quests_picker.bind(popup, app, onQuestPicked);
    self.steps_picker.bind(popup, app, null);
    self.flags.bind(popup, app, onFlagPicked);
    self.flag_values.bind(popup, app, null);
    self.cutscenes.bind(popup, app, null);
    self.fillSpots(app);
    self.refreshPlan(app);
}

fn tab(app: *App) *TestSeedsTab {
    return &app.test_tab;
}

fn appOf(context: *anyopaque) *App {
    return @ptrCast(@alignCast(context));
}

// ------------------------------------------------------------------------------------------------ the catalog

/// The scanned game's names (built on the worker): the pickers are filled from them.
pub fn takeCatalog(self: *TestSeedsTab, app: *App, catalog_arena: std.heap.ArenaAllocator, catalog: Catalog) void {
    self.catalog_arena.deinit();
    self.catalog_arena = catalog_arena;
    self.catalog = catalog;
    const a = self.catalog_arena.allocator();

    const location_labels = zList(a, catalog.locations) catch return;
    self.locations.setItems(location_labels, catalog.locations);
    const item_names = a.alloc([]const u8, catalog.items.len) catch return;
    for (catalog.items, 0..) |item, i| item_names[i] = item.name;
    const item_labels = zList(a, item_names) catch return;
    self.items.setItems(item_labels, item_names);
    self.start_items.setItems(item_labels, item_names);
    self.boots.setItems(eventLabels(a, catalog.events) catch return, eventIds(a, catalog.events) catch return);
    self.cutscenes.setItems(eventLabels(a, catalog.cutscenes) catch return, eventIds(a, catalog.cutscenes) catch return);

    const quest_names = a.alloc([]const u8, catalog.quests.len) catch return;
    for (catalog.quests, 0..) |quest, i| quest_names[i] = quest.name;
    self.quests_picker.setItems(zList(a, quest_names) catch return, quest_names);
    self.fillSteps();

    const scene_labels = a.alloc([:0]const u8, catalog.scenes.len) catch return;
    const scene_names = a.alloc([]const u8, catalog.scenes.len) catch return;
    for (catalog.scenes, 0..) |scene, i| {
        scene_names[i] = scene.name;
        scene_labels[i] = (if (scene.forced_age) |age| std.fmt.allocPrintSentinel(a, "{s}   ({s} only)", .{ scene.name, @tagName(age) }, 0) else a.dupeSentinel(u8, scene.name, 0)) catch return;
    }
    self.scenes_picker.setItems(scene_labels, scene_names);
    self.fillSpots(app);

    const flag_labels = a.alloc([:0]const u8, catalog.flags.len) catch return;
    const flag_names = a.alloc([]const u8, catalog.flags.len) catch return;
    for (catalog.flags, 0..) |flag, i| {
        flag_names[i] = flag.name;
        flag_labels[i] = switch (flag.kind) {
            .boolean => std.fmt.allocPrintSentinel(a, "{s}   (true/false)", .{flag.name}, 0),
            .integer => std.fmt.allocPrintSentinel(a, "{s}   (number)", .{flag.name}, 0),
            .enumeration => std.fmt.allocPrintSentinel(a, "{s}   ({d} values)", .{ flag.name, flag.values.len }, 0),
        } catch return;
    }
    self.flags.setItems(flag_labels, flag_names);
    self.fillFlagValues();
    self.refreshPlan(app);
    app.writeFmt("Test Seeds: {d} scenes, {d} boot events, {d} quests, {d} flags and {d} cutscenes from the game.", .{
        catalog.scenes.len, catalog.events.len, catalog.quests.len, catalog.flags.len, catalog.cutscenes.len,
    });
}

/// `names` zero-terminated for Raven (in `a`).
fn zList(a: Allocator, names: []const []const u8) error{OutOfMemory}![]const [:0]const u8 {
    const out = try a.alloc([:0]const u8, names.len);
    for (names, 0..) |name, i| out[i] = try a.dupeSentinel(u8, name, 0);
    return out;
}

fn eventLabels(a: Allocator, rows: []const engine.teststart.EventRow) error{OutOfMemory}![]const [:0]const u8 {
    const out = try a.alloc([:0]const u8, rows.len);
    for (rows, 0..) |row, i| out[i] = try std.fmt.allocPrintSentinel(a, "{s}   ({s})", .{ row.id, row.flow }, 0);
    return out;
}

fn eventIds(a: Allocator, rows: []const engine.teststart.EventRow) error{OutOfMemory}![]const []const u8 {
    const out = try a.alloc([]const u8, rows.len);
    for (rows, 0..) |row, i| out[i] = row.id;
    return out;
}

fn scenes(self: *const TestSeedsTab) []const Catalog.Scene {
    return if (self.catalog) |c| c.scenes else &.{};
}

fn chosenScene(self: *const TestSeedsTab) ?*const Catalog.Scene {
    const index = self.scenes_picker.chosenIndex() orelse return null;
    return &self.scenes()[index];
}

/// spots_picker's first row (after "the scene's entrance"): the position typed below
const spot_position_index = 0;

/// spots_picker: the scene's entrance (none), the exact position, then the chosen scene's start spots.
fn fillSpots(self: *TestSeedsTab, app: *App) void {
    _ = app;
    self.spots = if (self.chosenScene()) |scene| scene.spots else &.{};
    const a = self.catalog_arena.allocator();
    const labels = a.alloc([:0]const u8, self.spots.len + 1) catch return;
    const values = a.alloc([]const u8, self.spots.len + 1) catch return;
    labels[spot_position_index] = "(the exact position below)";
    values[spot_position_index] = "";
    for (self.spots, 0..) |spot, i| {
        labels[i + 1] = std.fmt.allocPrintSentinel(a, "{s}   [{d:.2}, {d:.2}, {d:.2}]", .{
            if (spot.name.len > 0) spot.name else "(unnamed spot: written as its position)", spot.position[0], spot.position[1], spot.position[2],
        }, 0) catch return;
        values[i + 1] = spot.name;
    }
    self.spots_picker.setItems(labels, values);
}

/// The start spot picked (null: the entrance or the exact position).
fn chosenSpot(self: *const TestSeedsTab) ?engine.teststart.StartSpot {
    const index = self.spots_picker.chosenIndex() orelse return null;
    if (index == spot_position_index or index - 1 >= self.spots.len) return null;
    return self.spots[index - 1];
}

fn fillSteps(self: *TestSeedsTab) void {
    const quest = self.chosenQuest() orelse return self.steps_picker.setItems(&.{}, &.{});
    const a = self.catalog_arena.allocator();
    self.steps_picker.setItems(zList(a, quest.steps) catch return, quest.steps);
    if (quest.steps.len > 0) self.steps_picker.pick(0);
}

fn chosenQuest(self: *const TestSeedsTab) ?*const Catalog.Quest {
    const quests = if (self.catalog) |c| c.quests else return null;
    const index = self.quests_picker.chosenIndex() orelse return null;
    return &quests[index];
}

// ---------------------------------------------------------------------------------------- the pickers' changes

fn onScenePicked(context: *anyopaque) void {
    const app = appOf(context);
    const self = tab(app);
    if (self.filling) return;
    self.fillSpots(app);
    self.refreshPlan(app);
}

/// Picking a start spot fills in its position and facing (shown for reference; the plan names a named spot).
fn onSpotPicked(context: *anyopaque) void {
    const app = appOf(context);
    const self = tab(app);
    if (self.filling) return;
    if (self.chosenSpot()) |spot| {
        for (self.pos_in, 0..) |input, i| input.setText(app.fmtZ("{d:.3}", .{spot.position[i]}));
        self.facing_in.setText(app.fmtZ("{d:.1}", .{std.math.radiansToDegrees(spot.facing_radians)}));
    }
    self.refreshPlan(app);
}

fn onPlanPicked(context: *anyopaque) void {
    const app = appOf(context);
    if (!tab(app).filling) tab(app).refreshPlan(app);
}

fn onQuestPicked(context: *anyopaque) void {
    tab(appOf(context)).fillSteps();
}

fn onFlagPicked(context: *anyopaque) void {
    tab(appOf(context)).fillFlagValues();
}

// ------------------------------------------------------------------------------------------------- the handlers

fn onChanged(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    tab(app).refreshPlan(app);
}

fn onOverrideAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const line = std.mem.trim(u8, self.override_in.getText(), " \t");
    if (std.mem.indexOfScalar(u8, line, '=') == null) {
        app.write("Test Seeds: a setting change is a user_settings.toml line, such as shuffle_scrubs = true");
        return;
    }
    appendOwned(self.gpa, &self.overrides, line);
    self.override_in.setText("");
    self.refreshLists(app);
}

fn onOverrideRemove(app: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    if (removedRow(sender, self.overrides.items.len)) |row| self.gpa.free(self.overrides.orderedRemove(row));
    self.refreshLists(app);
}

fn onPlaceAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    tab(app).addItemRow(app, false);
}

fn onForbidAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    tab(app).addItemRow(app, true);
}

fn addItemRow(self: *TestSeedsTab, app: *App, forbid: bool) void {
    const location = self.locations.selected() orelse return app.write("Test Seeds: pick a location first (scan the game to fill the list).");
    const item = self.items.selected() orelse return app.write("Test Seeds: pick an item first.");
    if (!forbid) {
        // [place] holds one item per location: a new one replaces the old
        for (self.item_rows.items, 0..) |row, i| {
            if (!row.forbid and std.mem.eql(u8, row.location, location)) {
                freeItemRow(self.gpa, self.item_rows.orderedRemove(i));
                break;
            }
        }
    }
    self.addItemRowNamed(forbid, location, item);
    self.refreshLists(app);
}

fn addItemRowNamed(self: *TestSeedsTab, forbid: bool, location: []const u8, item: []const u8) void {
    const location_copy = self.gpa.dupe(u8, location) catch return;
    const item_copy = self.gpa.dupe(u8, item) catch return self.gpa.free(location_copy);
    self.item_rows.append(self.gpa, .{ .forbid = forbid, .location = location_copy, .item = item_copy }) catch {
        self.gpa.free(location_copy);
        self.gpa.free(item_copy);
    };
}

fn onItemRemove(app: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    if (removedRow(sender, self.item_rows.items.len)) |row| freeItemRow(self.gpa, self.item_rows.orderedRemove(row));
    self.refreshLists(app);
}

fn onStartItemAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const item = self.start_items.selected() orelse return app.write("Test Seeds: pick an item first (scan the game to fill the list).");
    appendOwned(self.gpa, &self.start_item_rows, item);
    self.refreshLists(app);
}

fn onStartItemRemove(app: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    if (removedRow(sender, self.start_item_rows.items.len)) |row| self.gpa.free(self.start_item_rows.orderedRemove(row));
    self.refreshLists(app);
}

fn onQuestAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const quest = self.chosenQuest() orelse return app.write("Test Seeds: pick a quest first (scan the game to fill the list).");
    const step = self.steps_picker.selected() orelse return app.write("Test Seeds: pick the quest's step.");
    self.setQuest(quest.name, step);
    self.refreshLists(app);
}

/// One step per quest: setting a quest again replaces its step.
fn setQuest(self: *TestSeedsTab, quest: []const u8, step: []const u8) void {
    for (self.story_rows.items, 0..) |row, i| {
        if (row == .quest and std.mem.eql(u8, row.quest.quest, quest)) {
            freeStoryRow(self.gpa, self.story_rows.orderedRemove(i));
            break;
        }
    }
    const quest_copy = self.gpa.dupe(u8, quest) catch return;
    const step_copy = self.gpa.dupe(u8, step) catch return self.gpa.free(quest_copy);
    self.story_rows.append(self.gpa, .{ .quest = .{ .quest = quest_copy, .step = step_copy } }) catch {
        self.gpa.free(quest_copy);
        self.gpa.free(step_copy);
    };
}

/// The flag picked in the list (null: "the flag typed below").
fn pickedFlag(self: *const TestSeedsTab) ?*const Catalog.Flag {
    const name = self.flags.selected() orelse return null;
    const all = if (self.catalog) |c| c.flags else return null;
    for (all) |*flag| {
        if (std.mem.eql(u8, flag.name, name)) return flag;
    }
    return null;
}

const bool_names = [_][]const u8{ "true", "false" };
const bool_labels = [_][:0]const u8{ "true", "false" };

/// flag_values: true/false or the picked Enum flag's value names; nothing for a number or a typed flag.
fn fillFlagValues(self: *TestSeedsTab) void {
    const flag = self.pickedFlag() orelse return self.flag_values.setItems(&.{}, &.{});
    switch (flag.kind) {
        .boolean => {
            self.flag_values.setItems(&bool_labels, &bool_names);
            self.flag_values.pick(0);
        },
        .enumeration => {
            self.flag_values.setItems(zList(self.catalog_arena.allocator(), flag.values) catch return, flag.values);
            if (flag.values.len > 0) self.flag_values.pick(0);
        },
        // typed in
        .integer => self.flag_values.setItems(&.{}, &.{}),
    }
}

/// Set: the flag picked (or typed) with the value picked (or typed).
fn onFlagAdd(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const value = self.flag_values.selected() orelse self.flag_values.typedText();
    if (self.pickedFlag()) |flag| {
        if (flag.kind == .integer and (std.fmt.parseInt(i64, value, 10) catch null) == null) return app.writeFmt("Test Seeds: {s} takes a whole number (type it as its value).", .{flag.name});
        if (value.len == 0) return app.write("Test Seeds: pick or type the flag's value.");
        self.setFlag(flag.name, value);
    } else {
        // a flag the scan didn't find, typed in
        const name = std.mem.trim(u8, self.flags.typedText(), "\"");
        if (name.len == 0 or value.len == 0) return app.write("Test Seeds: pick or type a flag, and its value (true/false, a whole number or a value name).");
        self.setFlag(name, value);
    }
    self.refreshLists(app);
}

/// `value` as typed: true/false and whole numbers stay as they are, anything else is a value name (quoted).
fn setFlag(self: *TestSeedsTab, name: []const u8, value: []const u8) void {
    for (self.story_rows.items, 0..) |row, i| {
        if (row == .flag and std.mem.eql(u8, row.flag.name, name)) {
            freeStoryRow(self.gpa, self.story_rows.orderedRemove(i));
            break;
        }
    }
    const unquoted = std.mem.trim(u8, value, "\"");
    const literal = std.mem.eql(u8, unquoted, "true") or std.mem.eql(u8, unquoted, "false") or
        (std.fmt.parseInt(i64, unquoted, 10) catch null) != null;
    const value_text = if (literal) self.gpa.dupe(u8, unquoted) catch return else quoted(self.gpa, unquoted) catch return;
    const name_copy = self.gpa.dupe(u8, name) catch return self.gpa.free(value_text);
    self.story_rows.append(self.gpa, .{ .flag = .{ .name = name_copy, .value = value_text } }) catch {
        self.gpa.free(name_copy);
        self.gpa.free(value_text);
    };
}

fn onCutSeen(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    tab(app).addCutscene(app, true);
}

fn onCutUnseen(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    tab(app).addCutscene(app, false);
}

fn addCutscene(self: *TestSeedsTab, app: *App, seen: bool) void {
    const id = self.cutscenes.selected() orelse return app.write("Test Seeds: pick a cutscene first (scan the game to fill the list).");
    self.setCutscene(id, seen);
    self.refreshLists(app);
}

/// A cutscene is seen or unseen, never both: setting it again replaces it.
fn setCutscene(self: *TestSeedsTab, id: []const u8, seen: bool) void {
    for (self.story_rows.items, 0..) |row, i| {
        const existing = switch (row) {
            .seen, .unseen => |name| name,
            else => continue,
        };
        if (std.mem.eql(u8, existing, id)) {
            freeStoryRow(self.gpa, self.story_rows.orderedRemove(i));
            break;
        }
    }
    const copy = self.gpa.dupe(u8, id) catch return;
    self.story_rows.append(self.gpa, if (seen) .{ .seen = copy } else .{ .unseen = copy }) catch self.gpa.free(copy);
}

fn onStoryRemove(app: *App, sender: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    if (removedRow(sender, self.story_rows.items.len)) |row| freeStoryRow(self.gpa, self.story_rows.orderedRemove(row));
    self.refreshLists(app);
}

fn onClear(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    self.clearForm(app);
    self.refreshLists(app);
}

fn clearForm(self: *TestSeedsTab, app: *App) void {
    self.filling = true;
    defer self.filling = false;
    self.clearLists();
    for ([_]r.TextInput{ self.name_in, self.seed_in, self.settings_string_in, self.override_in, self.facing_in, self.pos_in[0], self.pos_in[1], self.pos_in[2] }) |input| input.setText("");
    self.base_in.setSelected(@intFromEnum(Base.window));
    self.age_in.setSelected(0);
    self.time_in.setSelected(0);
    for (self.allPickers()) |p| p.clear();
    self.fillSpots(app);
    self.fillSteps();
    self.fillFlagValues();
}

fn clearLists(self: *TestSeedsTab) void {
    for (self.overrides.items) |line| self.gpa.free(line);
    self.overrides.clearRetainingCapacity();
    for (self.item_rows.items) |row| freeItemRow(self.gpa, row);
    self.item_rows.clearRetainingCapacity();
    for (self.start_item_rows.items) |item| self.gpa.free(item);
    self.start_item_rows.clearRetainingCapacity();
    for (self.story_rows.items) |row| freeStoryRow(self.gpa, row);
    self.story_rows.clearRetainingCapacity();
}

// ----------------------------------------------------------------------------------------------- lists and plan

/// The lists' rows from the model, then the plan.
fn refreshLists(self: *TestSeedsTab, app: *App) void {
    self.override_list.clearItems();
    for (self.overrides.items) |line| _ = self.override_list.addItem(app.z(line));
    self.item_list.clearItems();
    for (self.item_rows.items) |row| {
        _ = self.item_list.addItem(app.fmtZ("{s}  {s}  {s}  {s}", .{ if (row.forbid) "Forbid" else "Place ", row.item, if (row.forbid) "at" else "at", row.location }));
    }
    self.start_item_list.clearItems();
    for (self.start_item_rows.items) |item| _ = self.start_item_list.addItem(app.z(item));
    self.story_list.clearItems();
    for (self.story_rows.items) |row| {
        _ = self.story_list.addItem(switch (row) {
            .quest => |q| app.fmtZ("Quest     {s} = {s}", .{ q.quest, q.step }),
            .flag => |f| app.fmtZ("Flag      {s} = {s}", .{ f.name, f.value }),
            .seen => |id| app.fmtZ("Seen      {s}", .{id}),
            .unseen => |id| app.fmtZ("Unseen    {s}", .{id}),
        });
    }
    self.refreshPlan(app);
}

fn refreshPlan(self: *TestSeedsTab, app: *App) void {
    if (self.filling) return;
    self.plan_list.clearItems();
    const text = self.planText(app, app.frameAllocator()) catch return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| _ = self.plan_list.addItem(app.z(line));
}

/// The plan the form says, as test_plans/TEMPLATE.test.toml describes it.
pub fn planText(self: *TestSeedsTab, app: *App, a: Allocator) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const name = std.mem.trim(u8, self.name_in.getText(), " \t");
    try out.print(a, "# Made in the Test Seeds tab of the randomizer window.\nname = {s}\n", .{try quoted(a, if (name.len > 0) name else "TEST1")});
    const seed = std.mem.trim(u8, self.seed_in.getText(), " \t");
    if (seed.len > 0) try out.print(a, "seed = {s}\n", .{try quoted(a, seed)});

    const base: Base = std.enums.fromInt(Base, self.base_in.getSelected()) orelse .window;
    const typed_string = std.mem.trim(u8, self.settings_string_in.getText(), " \t");
    const settings_string: []const u8 = switch (base) {
        // the window's settings go in as their settings string, so the plan makes the same seed anywhere
        .window => try app.settingsString(a),
        else => typed_string,
    };
    if (settings_string.len > 0) try out.print(a, "settings_string = {s}\n", .{try quoted(a, settings_string)});
    const preset: ?[]const u8 = switch (base) {
        .beginner => "Beginner",
        .standard => "Standard",
        .expert => "Expert",
        .race => "Race",
        else => null,
    };
    if (preset) |p| try out.print(a, "preset = \"{s}\"\n", .{p});

    if (self.overrides.items.len > 0) {
        try out.appendSlice(a, "\n[settings]\n");
        for (self.overrides.items) |line| try out.print(a, "{s}\n", .{line});
    }

    var placed = false;
    for (self.item_rows.items) |row| {
        if (row.forbid) continue;
        if (!placed) try out.appendSlice(a, "\n[place]\n");
        placed = true;
        try out.print(a, "{s} = {s}\n", .{ try quoted(a, row.location), try quoted(a, row.item) });
    }
    // [forbid]: one line per location, its items as a list
    var forbid_written = false;
    for (self.item_rows.items, 0..) |row, i| {
        if (!row.forbid) continue;
        var earlier = false;
        for (self.item_rows.items[0..i]) |other| {
            if (other.forbid and std.mem.eql(u8, other.location, row.location)) earlier = true;
        }
        if (earlier) continue;
        if (!forbid_written) try out.appendSlice(a, "\n[forbid]\n");
        forbid_written = true;
        try out.print(a, "{s} = [", .{try quoted(a, row.location)});
        var first = true;
        for (self.item_rows.items[i..]) |other| {
            if (!other.forbid or !std.mem.eql(u8, other.location, row.location)) continue;
            try out.print(a, "{s}{s}", .{ if (first) "" else ", ", try quoted(a, other.item) });
            first = false;
        }
        try out.appendSlice(a, "]\n");
    }

    var start: std.ArrayList(u8) = .empty;
    switch (self.age_in.getSelected()) {
        1 => try start.appendSlice(a, "age = \"child\"\n"),
        2 => try start.appendSlice(a, "age = \"adult\"\n"),
        else => {},
    }
    if (self.chosenScene()) |scene| {
        try start.print(a, "scene = {s}\n", .{try quoted(a, scene.name)});
        const spot = self.chosenSpot();
        if (spot != null and spot.?.name.len > 0) {
            try start.print(a, "start_spot = {s}\n", .{try quoted(a, spot.?.name)});
        } else if (self.spots_picker.chosenIndex() != null) {
            // the exact position (an unnamed spot fills the fields in)
            var xyz: [3][]const u8 = undefined;
            var complete = true;
            for (self.pos_in, 0..) |input, k| {
                xyz[k] = std.mem.trim(u8, input.getText(), " \t");
                if ((std.fmt.parseFloat(f64, xyz[k]) catch null) == null) complete = false;
            }
            if (complete) {
                try start.print(a, "position = [{s}, {s}, {s}]\n", .{ xyz[0], xyz[1], xyz[2] });
                const facing = std.mem.trim(u8, self.facing_in.getText(), " \t");
                if ((std.fmt.parseFloat(f64, facing) catch null) != null) try start.print(a, "facing = {s}\n", .{facing});
            } else {
                try start.appendSlice(a, "# position: fill in x, y and z\n");
            }
        }
        if (self.boots.selected()) |boot| try start.print(a, "boot_event = {s}\n", .{try quoted(a, boot)});
    } else if (self.boots.selected() != null) {
        try start.appendSlice(a, "# boot_event needs a scene\n");
    }
    const time_row = self.time_in.getSelected();
    if (time_row >= 1 and time_row <= 24) try start.print(a, "time = {d}\n", .{time_row - 1});
    if (self.start_item_rows.items.len > 0) {
        try start.appendSlice(a, "items = [");
        for (self.start_item_rows.items, 0..) |item, i| try start.print(a, "{s}{s}", .{ if (i > 0) ", " else "", try quoted(a, item) });
        try start.appendSlice(a, "]\n");
    }
    if (start.items.len > 0) try out.print(a, "\n[start]\n{s}", .{start.items});

    var quests_written = false;
    var flags_written = false;
    for (self.story_rows.items) |row| if (row == .quest) {
        if (!quests_written) try out.appendSlice(a, "\n[quests]\n");
        quests_written = true;
        try out.print(a, "{s} = {s}\n", .{ try quoted(a, row.quest.quest), try quoted(a, row.quest.step) });
    };
    for (self.story_rows.items) |row| if (row == .flag) {
        if (!flags_written) try out.appendSlice(a, "\n[flags]\n");
        flags_written = true;
        try out.print(a, "{s} = {s}\n", .{ try quoted(a, row.flag.name), row.flag.value });
    };
    var seen: std.ArrayList(u8) = .empty;
    var unseen: std.ArrayList(u8) = .empty;
    for (self.story_rows.items) |row| switch (row) {
        .seen => |id| try seen.print(a, "{s}{s}", .{ if (seen.items.len > 0) ", " else "", try quoted(a, id) }),
        .unseen => |id| try unseen.print(a, "{s}{s}", .{ if (unseen.items.len > 0) ", " else "", try quoted(a, id) }),
        else => {},
    };
    if (seen.items.len > 0 or unseen.items.len > 0) {
        try out.appendSlice(a, "\n[cutscenes]\n");
        if (seen.items.len > 0) try out.print(a, "seen = [{s}]\n", .{seen.items});
        if (unseen.items.len > 0) try out.print(a, "unseen = [{s}]\n", .{unseen.items});
    }
    return out.items;
}

/// `text` as a TOML string.
fn quoted(a: Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

// ----------------------------------------------------------------------------------------------- load and save

const plan_filters = [_]r.FileFilter{
    .{ .name = "Test plans (*.test.toml)", .patterns = "*.test.toml" },
    .{ .name = "TOML files (*.toml)", .patterns = "*.toml" },
    .{ .name = "All files", .patterns = "*" },
};

fn onSave(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const a = app.frameAllocator();
    const text = self.planText(app, a) catch return;
    const name = std.mem.trim(u8, self.name_in.getText(), " \t");
    const path = r.fileDialogSave(.{
        .parent = app.window,
        .title = "Save the test plan",
        .file_name = app.fmtZ("{s}.test.toml", .{if (name.len > 0) name else "TEST1"}),
        .filters = &plan_filters,
        .default_extension = "toml",
    });
    if (path.len == 0) return;
    app.env.fs.writeAll(path, text) catch |err| return app.writeFmt("ERROR: the plan couldn't be saved to {s} ({s})", .{ path, @errorName(err) });
    app.writeFmt("Test plan saved: {s}", .{path});
}

fn onLoad(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const path = r.fileDialogOpen(.{ .parent = app.window, .title = "Load a test plan", .filters = &plan_filters }) orelse return;
    if (path.len == 0) return;
    const a = app.frameAllocator();
    const text = app.env.fs.readAll(a, path) catch |err| return app.writeFmt("ERROR: {s} can't be read ({s})", .{ path, @errorName(err) });
    var problem = testplan.Problem{};
    const plan = testplan.parse(a, text, &problem) catch |err| switch (err) {
        error.OutOfMemory => return,
        error.InvalidPlan => return app.writeFmt("ERROR: {s}: {s}", .{ path, problem.message }),
    };
    self.fillFromPlan(app, a, plan);
    self.refreshLists(app);
    app.writeFmt("Test plan loaded: {s}", .{path});
}

/// The form from a plan that core/testplan.zig read. Names the scanned game doesn't list are still kept (the
/// lists hold text); a scene or boot event it doesn't list is left out with a note.
fn fillFromPlan(self: *TestSeedsTab, app: *App, a: Allocator, plan: testplan.TestPlan) void {
    self.clearForm(app);
    self.filling = true;
    defer self.filling = false;
    self.name_in.setText(app.z(plan.name));
    self.seed_in.setText(app.z(plan.seed));
    self.settings_string_in.setText(app.z(plan.settings_string));
    const base: Base = if (std.mem.eql(u8, plan.preset, "Beginner")) .beginner else if (std.mem.eql(u8, plan.preset, "Standard")) .standard else if (std.mem.eql(u8, plan.preset, "Expert")) .expert else if (std.mem.eql(u8, plan.preset, "Race")) .race else if (plan.settings_string.len > 0) .settings_string else .window;
    self.base_in.setSelected(@intFromEnum(base));
    for (plan.setting_overrides) |entry| {
        const line = std.fmt.allocPrint(a, "{s} = {s}", .{ entry.key, tomlValueText(a, entry.value) catch return }) catch return;
        appendOwned(self.gpa, &self.overrides, line);
    }
    for (plan.placements) |placement| self.addItemRowNamed(false, placement.location, placement.item);
    for (plan.item_restrictions) |entry| {
        const restriction = engine.settings.parseItemRestriction(entry) orelse continue;
        self.addItemRowNamed(true, restriction.location, restriction.item);
    }

    const start = plan.start;
    self.age_in.setSelected(if (start.age) |age| (if (age == .child) 1 else 2) else 0);
    self.time_in.setSelected(if (start.time_hour) |hour| @as(i32, hour) + 1 else 0);
    if (start.spawn) |spawn| {
        if (self.scenes_picker.select(spawn.scene)) {
            self.fillSpots(app);
            if (spawn.start_spot.len > 0) {
                _ = self.spots_picker.select(spawn.start_spot);
            } else if (spawn.position) |xyz| {
                self.spots_picker.pick(spot_position_index);
                for (self.pos_in, 0..) |input, k| input.setText(app.fmtZ("{d}", .{xyz[k]}));
                self.facing_in.setText(app.fmtZ("{d}", .{spawn.facing_degrees}));
            }
            if (spawn.boot_event.len > 0 and !self.boots.select(spawn.boot_event)) {
                app.writeFmt("Test Seeds: boot event {s} isn't in the scanned game's list (scan the game, then load again)", .{spawn.boot_event});
            }
        } else {
            app.writeFmt("Test Seeds: scene {s} isn't in the scanned game's list (scan the game, then load again)", .{spawn.scene});
        }
    }
    for (start.items) |item| appendOwned(self.gpa, &self.start_item_rows, item);
    for (start.quests) |quest| self.setQuest(quest.quest, quest.step);
    for (start.flags) |flag| {
        const value = switch (flag.value) {
            .boolean => |b| if (b) "true" else "false",
            .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch return,
            .enum_value => |v| v,
        };
        self.setFlag(flag.name, value);
    }
    for (start.seen_cutscenes) |id| self.setCutscene(id, true);
    for (start.unseen_cutscenes) |id| self.setCutscene(id, false);
}

/// A [settings] value as user_settings.toml writes it.
fn tomlValueText(a: Allocator, value: toml.Value) error{OutOfMemory}![]const u8 {
    return switch (value) {
        .string => |s| quoted(a, s),
        .int => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |x| std.fmt.allocPrint(a, "{d}", .{x}),
        .bool => |b| if (b) "true" else "false",
        .array => |items| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.append(a, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try tomlValueText(a, item));
            }
            try out.append(a, ']');
            break :blk out.items;
        },
        .other => "\"\"",
    };
}

// --------------------------------------------------------------------------------------------------- generate

fn onGenerate(app: *App, _: ?r.Widget, _: [:0]const u8) void {
    const self = tab(app);
    const text = self.planText(app, app.frameAllocator()) catch return;
    if (std.mem.trim(u8, self.name_in.getText(), " \t").len == 0) return app.write("Test Seeds: give the test seed a name first.");
    app.startTestSeed(text);
}

/// The Generate Test Seed button follows the window's own (off while the worker runs).
pub fn setBusy(self: *TestSeedsTab, busy: bool) void {
    self.generate_btn.setEnabled(!busy);
}

// ------------------------------------------------------------------------------------------------------ helpers

fn appendOwned(gpa: Allocator, list: *std.ArrayList([]u8), text: []const u8) void {
    const copy = gpa.dupe(u8, text) catch return;
    list.append(gpa, copy) catch gpa.free(copy);
}

/// The double-clicked row of a list with `count` rows, or null.
fn removedRow(sender: ?r.Widget, count: usize) ?usize {
    const list = (sender orelse return null).as(r.ListView) orelse return null;
    const row = list.getSelected();
    if (row < 0 or row >= count) return null;
    return @intCast(row);
}

fn freeItemRow(gpa: Allocator, row: ItemRow) void {
    gpa.free(row.location);
    gpa.free(row.item);
}

fn freeStoryRow(gpa: Allocator, row: StoryRow) void {
    switch (row) {
        .quest => |q| {
            gpa.free(q.quest);
            gpa.free(q.step);
        },
        .flag => |f| {
            gpa.free(f.name);
            gpa.free(f.value);
        },
        .seen, .unseen => |id| gpa.free(id),
    }
}
