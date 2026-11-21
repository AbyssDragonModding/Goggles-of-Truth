//! The window's XML layout: src/ui/main.xml with its generated parts filled in from the setting table (the settings
//! cards, the preset list and tooltip, the Not Supported list). The XML files are built into the program.

const std = @import("std");
const string = @import("string");
const engine = @import("engine");
const settings = engine.settings;
const Allocator = std.mem.Allocator;

pub const main_xml = @embedFile("main.xml");
pub const widgets_xml = @embedFile("widgets.xml");
/// The app icon (title bar and task bar). The Windows .exe also carries it as GogglesRandoAppIcon.ico (app.rc).
pub const app_icon_png = @embedFile("GogglesRandoAppIcon.png");

pub const gold_hex = "#F5CC61";
pub const muted_hex = "#C7D1DBD9";

/// The status badge widgets of widgets.xml, one per status.
pub fn badgeTag(status: settings.Status) []const u8 {
    return switch (status) {
        .stable => "StableBadge",
        .testing => "TestingBadge",
        .experimental => "ExperimentalBadge",
    };
}

/// A badge's look as widgets.xml declares it (to recolour a drop-down's badge when another option is chosen).
pub const BadgeStyle = struct {
    text: []const u8,
    background: []const u8,
    foreground: []const u8,
};

/// The value of attribute `name` in the first tag at or after `from`, up to that tag's end.
fn attribute(xml: []const u8, from: usize, name: []const u8) ?[]const u8 {
    const tag_end = std.mem.indexOfScalarPos(u8, xml, from, '>') orelse return null;
    const tag = xml[from..tag_end];
    var search: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

/// Text / Background / Foreground of each status badge in widgets.xml.
pub fn badgeStyles() [3]BadgeStyle {
    var out: [3]BadgeStyle = undefined;
    for (std.meta.tags(settings.Status), 0..) |status, i| {
        var search: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&search, "<Widget Name=\"{s}\"", .{badgeTag(status)}) catch unreachable;
        const widget = std.mem.indexOf(u8, widgets_xml, needle) orelse 0;
        const badge = std.mem.indexOfPos(u8, widgets_xml, widget, "<Badge ") orelse widget;
        out[i] = .{
            .text = attribute(widgets_xml, badge, "Text") orelse "",
            .background = attribute(widgets_xml, badge, "Background") orelse "#2E9E5B",
            .foreground = attribute(widgets_xml, badge, "Foreground") orelse "#FFFFFF",
        };
    }
    return out;
}

/// A value for an XML attribute: escaped, line breaks kept.
fn appendAttr(out: *string.String, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.append("&amp;"),
            '<' => try out.append("&lt;"),
            '>' => try out.append("&gt;"),
            '"' => try out.append("&quot;"),
            '\n' => try out.append("&#10;"),
            else => try out.appendChar(c),
        }
    }
}

fn badgeXml(out: *string.String, status: settings.Status, key: []const u8) !void {
    try out.appendFmt("<{s} Name=\"badge_{s}\" LabelName=\"badgelab_{s}\"/>", .{ badgeTag(status), key, key });
}

/// One settings row: a switch for an on/off setting, a label and a spin box for a number, a label and a drop-down
/// for a choice. Each control is named set_<key> and fires the action set.<key>.
fn settingRow(out: *string.String, s: *const settings.Spec) !void {
    var buf: [512]u8 = undefined;
    const split = settings.splitStatus(&buf, s.label);
    const key = @tagName(s.key);
    switch (s.kind) {
        .boolean => {
            try out.appendFmt("<HBox Spacing=\"12\"><Checkbox Name=\"set_{s}\" Style=\"Switch\" Text=\"", .{key});
            try appendAttr(out, split.text);
            try out.append("\" Tooltip=\"");
            try appendAttr(out, s.tip);
            try out.appendFmt("\" OnChanged=\"set.{s}\" Slot.Fill=\"1\"/>", .{key});
            try badgeXml(out, split.status, key);
            try out.append("</HBox>");
        },
        .int => {
            try out.append("<HBox Spacing=\"12\"><Label Text=\"");
            try appendAttr(out, split.text);
            try out.append("\" TextSize=\"14\" Tooltip=\"");
            try appendAttr(out, s.tip);
            try out.appendFmt("\" Slot.Fill=\"1\" Slot.VAlign=\"Center\"/><SpinBox Name=\"set_{s}\" Tooltip=\"", .{key});
            try appendAttr(out, s.tip);
            try out.appendFmt("\" OnChanged=\"set.{s}\" Slot.Fill=\"0.4\"/>", .{key});
            try badgeXml(out, split.status, key);
            try out.append("</HBox>");
        },
        .choice => {
            try out.append("<HBox Spacing=\"12\"><Label Text=\"");
            try appendAttr(out, split.text);
            try out.append("\" TextSize=\"14\" Tooltip=\"");
            try appendAttr(out, s.tip);
            try out.appendFmt("\" Slot.Fill=\"1\" Slot.VAlign=\"Center\"/><ComboBox Name=\"set_{s}\" Items=\"", .{key});
            for (s.options, 0..) |o, i| {
                if (i > 0) try out.append("|");
                var obuf: [256]u8 = undefined;
                const label = settings.splitStatus(&obuf, o.label).text;
                // "|" separates the items
                for (label) |c| try appendAttr(out, if (c == '|') "/" else &[_]u8{c});
            }
            try out.append("\" Tooltip=\"");
            try appendAttr(out, s.tip);
            try out.appendFmt("\" OnChanged=\"set.{s}\" Slot.Fill=\"0.9\"/>", .{key});
            try badgeXml(out, settings.settingStatus(s.key, s.default.choice), key);
            try out.append("</HBox>");
        },
        .list => {},
    }
}

fn card(out: *string.String, title: []const u8, body: []const u8, top: u32, bottom: u32) !void {
    try out.appendFmt("<Border Material=\"FrostedGlass\" CornerRadius=\"16\" Padding=\"18,14,18,16\" Shadow=\"18,0,4\" Slot.Auto=\"true\" Slot.Padding=\"6,{d},6,{d}\"><VBox Spacing=\"10\"><Label Text=\"", .{ top, bottom });
    try appendAttr(out, title);
    try out.appendFmt("\" TextSize=\"16\" Color=\"{s}\"/>", .{gold_hex});
    try out.append(body);
    try out.append("</VBox></Border>");
}

/// The cards of one settings tab: one card per group.
fn settingsXml(allocator: Allocator, out: *string.String, tab: []const u8) !void {
    var group: []const u8 = "";
    var rows = string.String.init(allocator);
    defer rows.deinit();
    var first = true;
    for (&settings.specs) |*s| {
        if (!std.mem.eql(u8, s.tab, tab) or s.kind == .list) continue;
        if (!std.mem.eql(u8, s.group, group)) {
            if (group.len > 0) {
                try card(out, group, rows.slice(), if (first and !std.mem.eql(u8, tab, "ROM Options")) 10 else 0, 0);
                first = false;
                rows.clear();
            }
            group = s.group;
        }
        try settingRow(&rows, s);
    }
    if (group.len > 0) try card(out, group, rows.slice(), if (first and !std.mem.eql(u8, tab, "ROM Options")) 10 else 0, 0);
}

fn unsupportedXml(out: *string.String) !void {
    for (settings.unsupported) |u| {
        try out.append("<Label Text=\"");
        try appendAttr(out, "\u{2022}  ");
        try appendAttr(out, u.name);
        try out.append("\" TextSize=\"14\"/><Label Text=\"");
        try appendAttr(out, u.why);
        try out.appendFmt("\" TextSize=\"13\" Color=\"{s}\" Wrap=\"true\" Slot.Padding=\"20,0,0,6\"/>", .{muted_hex});
    }
}

/// The preset drop-down's items: "Custom" first, then the presets.
pub const preset_items = blk: {
    var items: [settings.presets.len + 1][]const u8 = undefined;
    items[0] = "Custom";
    for (settings.presets, 1..) |p, i| items[i] = p.name;
    break :blk items;
};

/// main.xml with its generated parts filled in. Allocated with `allocator`.
pub fn windowXml(allocator: Allocator) ![]u8 {
    var text = try string.String.from(allocator, main_xml);
    defer text.deinit();

    const tabs = [_][]const u8{ "World", "Items", "Dungeon Items", "Hints", "Quality of Life", "ROM Options", "Exclusions" };
    for (tabs) |tab| {
        var marker_buf: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "<!--@@settings {s}@@-->", .{tab});
        var cards = string.String.init(allocator);
        defer cards.deinit();
        try settingsXml(allocator, &cards, tab);
        _ = try text.replace(marker, cards.slice());
    }

    var items = string.String.init(allocator);
    defer items.deinit();
    var joined = string.String.init(allocator);
    defer joined.deinit();
    for (preset_items, 0..) |p, i| {
        if (i > 0) try joined.append("|");
        try joined.append(p);
    }
    try appendAttr(&items, joined.slice());
    _ = try text.replace("@@preset_items@@", items.slice());

    var tip_text = string.String.init(allocator);
    defer tip_text.deinit();
    try tip_text.append("Sets every gameplay setting for a seed difficulty (Excluded Locations and Create Spoiler Log are kept).\n" ++
        "Only options confirmed in-game are used. Change anything afterwards and the preset shows Custom.\n\n");
    for (settings.presets, 0..) |p, i| {
        if (i > 0) try tip_text.append("\n\n");
        try tip_text.appendFmt("{s}: {s}", .{ p.name, p.tip });
    }
    var tip = string.String.init(allocator);
    defer tip.deinit();
    try appendAttr(&tip, tip_text.slice());
    _ = try text.replace("@@preset_tip@@", tip.slice());

    var unsupported = string.String.init(allocator);
    defer unsupported.deinit();
    try unsupportedXml(&unsupported);
    _ = try text.replace("<!--@@unsupported@@-->", unsupported.slice());
    return text.toOwnedSlice();
}

/// "#RRGGBB" or "#RRGGBBAA" as 0..1 floats.
pub fn rgba(hex: []const u8) [4]f32 {
    const h = std.mem.trimStart(u8, hex, "#");
    var out = [4]f32{ 0, 0, 0, 1 };
    var i: usize = 0;
    while (i < 4 and i * 2 + 2 <= h.len) : (i += 1) {
        const v = std.fmt.parseInt(u8, h[i * 2 .. i * 2 + 2], 16) catch 0;
        out[i] = @as(f32, @floatFromInt(v)) / 255.0;
    }
    return out;
}
