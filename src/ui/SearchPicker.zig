//! A drop-down whose list you can search (the SearchPicker widget of widgets.xml). Why not Raven's ComboBox: the
//! Raven library in vendor/Raven/lib has no searchable drop-down (its Zig bindings describe one the prebuilt library
//! doesn't export).
//!
//! The picker shows like a drop-down: a field with the chosen row and a ▾. Clicking it opens the shared `Popup`
//! right under it: a search field (with the keyboard focus) over the list. When the window has no room for it under
//! the field, it opens above instead, flipped: the search field next to the field, the list over the search field. Typing narrows the list as you type, Up
//! and Down move in it, Enter or a click picks a row and closes the popup, Escape or a click outside closes it. An
//! editable picker also takes a typed text that is no row (Enter), for names the list doesn't know.
//!
//! The popup's list is virtual (Raven asks for the rows it shows), so lists of thousands of rows stay fast. The
//! popup is made once from widgets.xml's SearchPopup (a widget made while the window runs, as AGENTS.md allows).

const std = @import("std");
const r = @import("raven");
const themes = @import("themes.zig");
const Allocator = std.mem.Allocator;

const SearchPicker = @This();

/// the space between the field and its popup
const popup_gap: f32 = 2;
/// widgets.xml's SearchPopup: its padding, the search field, the spacing and the list's MinHeight (260)
const popup_usual_height: f32 = 330;

/// the row standing for "none" in the popup's rows
const none_row = std.math.maxInt(usize);

face: r.Widget,
label: r.Label,
placeholder: [:0]const u8,
/// shown first and meaning "none" (null: no such row)
none_label: ?[:0]const u8 = null,
/// a typed text that is no row is kept (Enter in the popup)
editable: bool = false,
labels: []const [:0]const u8 = &.{},
/// what each row stands for (the plan's name for it), index for index with `labels`
values: []const []const u8 = &.{},
/// the picked row's source index (null: none, nothing, or a typed text)
chosen: ?usize = null,
/// an editable picker's typed text (owned; "" when a row is picked)
typed: []u8 = &.{},
gpa: Allocator,
popup: ?*Popup = null,
/// called after the user picks a row or enters a text (with `context`)
on_change: ?*const fn (*anyopaque) void = null,
context: ?*anyopaque = null,

pub fn init(gpa: Allocator, face: r.Widget, label: r.Label, placeholder: [:0]const u8, none_label: ?[:0]const u8, editable: bool) SearchPicker {
    return .{ .gpa = gpa, .face = face, .label = label, .placeholder = placeholder, .none_label = none_label, .editable = editable };
}

/// Connects the field to the shared popup. `self` must stay where it is from now on.
pub fn bind(self: *SearchPicker, popup: *Popup, context: *anyopaque, on_change: ?*const fn (*anyopaque) void) void {
    self.popup = popup;
    self.context = context;
    self.on_change = on_change;
    self.face.setEventCallback(self, onFaceEvent);
    self.showChoice();
}

pub fn deinit(self: *SearchPicker) void {
    self.gpa.free(self.typed);
}

/// New rows (the strings stay the caller's): nothing is picked.
pub fn setItems(self: *SearchPicker, labels: []const [:0]const u8, values: []const []const u8) void {
    std.debug.assert(labels.len == values.len);
    self.labels = labels;
    self.values = values;
    self.clear();
}

/// Nothing picked, nothing typed.
pub fn clear(self: *SearchPicker) void {
    self.chosen = null;
    self.setTypedText("");
    self.showChoice();
}

/// The picked row's value, or null.
pub fn selected(self: *const SearchPicker) ?[]const u8 {
    return if (self.chosen) |i| self.values[i] else null;
}

/// The picked row's source index, or null.
pub fn chosenIndex(self: *const SearchPicker) ?usize {
    return self.chosen;
}

/// An editable picker's typed text, trimmed ("" when a row is picked or nothing was typed).
pub fn typedText(self: *const SearchPicker) []const u8 {
    return std.mem.trim(u8, self.typed, " \t");
}

/// Picks the row whose value is `value` (from code: the change callback isn't called). False when there is none.
pub fn select(self: *SearchPicker, value: []const u8) bool {
    for (self.values, 0..) |v, i| {
        if (!std.mem.eql(u8, v, value)) continue;
        self.pick(i);
        return true;
    }
    return false;
}

/// Picks source row `index`, or none (null), from code.
pub fn pick(self: *SearchPicker, index: ?usize) void {
    self.chosen = index;
    self.setTypedText("");
    self.showChoice();
}

fn setTypedText(self: *SearchPicker, text: []const u8) void {
    const copy = self.gpa.dupe(u8, text) catch return;
    self.gpa.free(self.typed);
    self.typed = copy;
}

/// Sets the field's text colour again after the window's theme changed.
pub fn refreshColors(self: *SearchPicker) void {
    self.showChoice();
}

/// A choice is drawn in the theme's text colour (the colour the placeholder set is removed).
fn showValueColor(self: *SearchPicker) void {
    self.label.widget().clearColor(.text);
}

/// The field: the chosen row, the typed text, or the placeholder.
fn showChoice(self: *SearchPicker) void {
    if (self.chosen) |i| {
        self.label.setText(self.labels[i]);
        self.showValueColor();
    } else if (self.typed.len > 0) {
        const z = std.fmt.allocPrintSentinel(self.gpa, "{s}", .{self.typed}, 0) catch return;
        defer self.gpa.free(z);
        self.label.setText(z);
        self.showValueColor();
    } else if (self.none_label) |none| {
        self.label.setText(none);
        self.showValueColor();
    } else {
        self.label.setText(self.placeholder);
        self.label.setColor(themes.codeColors().placeholder);
    }
}

/// A click on the field opens the popup under it.
fn onFaceEvent(self: *SearchPicker, _: r.Widget, event: r.Event) bool {
    if (event.type != .mouse_down or event.button != .left) return false;
    if (self.popup) |popup| popup.open(self);
    return true;
}

/// Called by the popup when the user picked a row (`index`; null: the none row) or entered `typed`.
fn finish(self: *SearchPicker, index: ?usize, typed: []const u8) void {
    self.chosen = index;
    self.setTypedText(if (index == null) typed else "");
    self.showChoice();
    if (self.on_change) |f| f(self.context.?);
}

/// The one popup every picker opens: a search field over the list, under the clicked field (or flipped above it).
pub const Popup = struct {
    gpa: Allocator,
    window: r.Window,
    content: r.Widget,
    input: r.TextInput,
    list: r.ListView,
    /// the box holding the search field and the list (their order flips with the popup)
    stack: r.Widget,
    /// open above the field: the list first, the search field last
    flipped: bool = false,
    /// the picker the popup is open for
    owner: ?*SearchPicker = null,
    /// the source index of each row shown (`none_row` for the none row)
    visible: std.ArrayList(usize) = .empty,
    /// set while the field or list is changed from code, so their callbacks don't run
    syncing: bool = false,

    /// Makes the popup's widgets from widgets.xml's SearchPopup (registered before the window's layout).
    pub fn init(gpa: Allocator, window: r.Window) error{PopupNotMade}!Popup {
        const content = r.Widget.createFromXml("<SearchPopup InputName=\"search_popup_input\" ListName=\"search_popup_list\"/>") catch return error.PopupNotMade;
        const input = (content.find("search_popup_input") orelse return error.PopupNotMade).as(r.TextInput) orelse return error.PopupNotMade;
        const list = (content.find("search_popup_list") orelse return error.PopupNotMade).as(r.ListView) orelse return error.PopupNotMade;
        const stack = input.widget().getParent() orelse return error.PopupNotMade;
        return .{ .gpa = gpa, .window = window, .content = content, .input = input, .list = list, .stack = stack };
    }

    /// Connects the popup's field and list. `self` must stay where it is from now on.
    pub fn bind(self: *Popup) void {
        self.input.setChangedCallback(self, onTyped);
        self.input.setCommittedCallback(self, onEnter);
        self.input.widget().setEventCallback(self, onKey);
        self.list.setSelectionChangedCallback(self, onRowClicked);
    }

    pub fn deinit(self: *Popup) void {
        self.visible.deinit(self.gpa);
    }

    /// Opens under `picker`'s field (above it, flipped, when the window has no room under it), as wide as it, with
    /// every row listed and the picked one selected.
    fn open(self: *Popup, picker: *SearchPicker) void {
        self.owner = picker;
        const rect = picker.face.getRect();
        self.content.setMinSize(rect.width, 0);
        self.syncing = true;
        const typed_z = std.fmt.allocPrintSentinel(self.gpa, "{s}", .{picker.typed}, 0) catch null;
        self.input.setText(typed_z orelse "");
        if (typed_z) |t| self.gpa.free(t);
        self.syncing = false;
        self.refilter(picker.typed);
        const popup_height = self.height();
        const window_height = if (self.window.getContent()) |root| root.getRect().height else 0;
        const below_y = rect.y + rect.height + popup_gap;
        const above_y = rect.y - popup_gap - popup_height;
        const room_below = window_height - below_y;
        const room_above = rect.y - popup_gap;
        // under the field when it fits there; otherwise above when it fits there, or else on the roomier side
        const open_above = window_height > 0 and room_below < popup_height and (room_above >= popup_height or room_above > room_below);
        self.setFlipped(open_above);
        r.popupOpen(self.window, self.content, rect.x, if (open_above) @max(above_y, 0) else below_y, self, onClosed);
        self.input.widget().focus();
    }

    /// The popup's height: as laid out, or its usual height before it was ever shown.
    fn height(self: *Popup) f32 {
        const desired = self.content.getDesiredSize().height;
        return if (desired > 0) desired else popup_usual_height;
    }

    /// Puts the search field under the list (flipped) or over it.
    fn setFlipped(self: *Popup, flipped: bool) void {
        if (self.flipped == flipped) return;
        self.flipped = flipped;
        const field = self.input.widget();
        self.stack.removeChild(field);
        _ = self.stack.insertChild(field, if (flipped) 1 else 0);
    }

    fn close(self: *Popup) void {
        r.popupClose(self.content, 0);
    }

    fn onClosed(self: *Popup, _: r.Widget, _: i32) void {
        self.owner = null;
    }

    /// The owner's rows containing `filter` (any case), the none row first; the picked row (or the first match)
    /// selected.
    fn refilter(self: *Popup, filter: []const u8) void {
        const picker = self.owner orelse return;
        self.visible.clearRetainingCapacity();
        const text = std.mem.trim(u8, filter, " \t");
        if (picker.none_label != null and text.len == 0) self.visible.append(self.gpa, none_row) catch return;
        for (picker.labels, 0..) |label, i| {
            if (text.len > 0 and std.ascii.findIgnoreCase(label, text) == null) continue;
            self.visible.append(self.gpa, i) catch return;
        }
        self.syncing = true;
        defer self.syncing = false;
        self.list.setVirtualItems(@intCast(self.visible.items.len), self, rowText);
        var row: i32 = if (self.visible.items.len > 0 and text.len > 0) 0 else -1;
        for (self.visible.items, 0..) |source, i| {
            const is_picked = if (picker.chosen) |c| source == c else (source == none_row and picker.typed.len == 0);
            if (is_picked) row = @intCast(i);
        }
        self.list.setSelected(row);
        if (row >= 0) self.list.scrollToItem(row);
    }

    fn rowText(self: *Popup, _: r.ListView, row: i32) ?[:0]const u8 {
        const picker = self.owner orelse return null;
        if (row < 0 or row >= self.visible.items.len) return null;
        const source = self.visible.items[@intCast(row)];
        if (source == none_row) return picker.none_label;
        return picker.labels[source];
    }

    fn onTyped(self: *Popup, _: r.TextInput, text: [:0]const u8) void {
        if (self.syncing) return;
        self.refilter(text);
    }

    /// Up and Down move in the list, Escape closes (Enter is onEnter).
    fn onKey(self: *Popup, _: r.Widget, event: r.Event) bool {
        if (event.type != .key_down) return false;
        switch (event.key) {
            .down, .up => {
                const count: i32 = @intCast(self.visible.items.len);
                if (count == 0) return true;
                var row = self.list.getSelected();
                row = if (event.key == .down) @min(row + 1, count - 1) else @max(row - 1, 0);
                self.syncing = true;
                defer self.syncing = false;
                self.list.setSelected(row);
                self.list.scrollToItem(row);
                return true;
            },
            .escape => {
                self.close();
                return true;
            },
            else => return false,
        }
    }

    /// Enter: the selected row; with nothing selected, an editable picker takes the typed text.
    fn onEnter(self: *Popup, _: r.TextInput, text: [:0]const u8) void {
        const picker = self.owner orelse return;
        const row = self.list.getSelected();
        if (row >= 0 and row < self.visible.items.len) {
            self.choose(picker, self.visible.items[@intCast(row)], "");
        } else if (picker.editable and std.mem.trim(u8, text, " \t").len > 0) {
            self.choose(picker, none_row, text);
        }
    }

    fn onRowClicked(self: *Popup, _: r.ListView, row: i32) void {
        if (self.syncing or row < 0 or row >= self.visible.items.len) return;
        const picker = self.owner orelse return;
        self.choose(picker, self.visible.items[@intCast(row)], "");
    }

    fn choose(self: *Popup, picker: *SearchPicker, source: usize, typed: []const u8) void {
        self.close();
        picker.finish(if (source == none_row) null else source, typed);
    }
};
