//! The window's XML layout: src/ui/main.xml with every page of its TabView put in from its own file in
//! src/ui/pages (AGENTS.md: one XML file per page, every widget defined in XML). Every setting row is written out in
//! its page; src/ui/pagecheck.zig checks the rows against the setting table. Only the preset drop-down's items and
//! tooltip are filled in here (the presets are data of the setting table). The XML files are built into the
//! program.

const std = @import("std");
const string = @import("string");
const engine = @import("engine");
const settings = engine.settings;
const Allocator = std.mem.Allocator;

pub const main_xml = @embedFile("main.xml");
/// Debug builds (the local ones) have the Test Seeds tab; release builds (the GitHub ones) leave its marker empty.
pub const debug_build = @import("builtin").mode == .debug;
pub const widgets_xml = @embedFile("widgets.xml");

/// Why the window's layout could not be put together.
pub const LayoutError = error{
    OutOfMemory,
    /// main.xml has no <!--@@page ...@@--> marker for a page of `page_definitions`
    PageMarkerMissing,
    /// a marker name longer than its format buffer (the names are fixed in this file)
    NoSpaceLeft,
};

/// One page (tab) of the window, defined in its own file: src/ui/pages/<marker_name>.xml goes where main.xml has
/// <!--@@page <marker_name>@@-->.
pub const PageDefinition = struct {
    marker_name: []const u8,
    xml: []const u8,
};

/// Every page of the window, in tab order.
pub const page_definitions = [_]PageDefinition{
    .{ .marker_name = "rom_options", .xml = @embedFile("pages/rom_options.xml") },
    .{ .marker_name = "world", .xml = @embedFile("pages/world.xml") },
    .{ .marker_name = "items", .xml = @embedFile("pages/items.xml") },
    .{ .marker_name = "dungeon_items", .xml = @embedFile("pages/dungeon_items.xml") },
    .{ .marker_name = "starting_inventory", .xml = @embedFile("pages/starting_inventory.xml") },
    .{ .marker_name = "hints", .xml = @embedFile("pages/hints.xml") },
    .{ .marker_name = "quality_of_life", .xml = @embedFile("pages/quality_of_life.xml") },
    .{ .marker_name = "exclusions", .xml = @embedFile("pages/exclusions.xml") },
    .{ .marker_name = "test_seeds", .xml = if (debug_build) @embedFile("pages/test_seeds.xml") else "" },
};

/// main.xml with every page file put in at its marker. A page whose marker is missing is an error (the window
/// would silently lose a tab otherwise).
fn assemblePages(allocator: Allocator) LayoutError!string.String {
    var window_text = try string.String.from(allocator, main_xml);
    errdefer window_text.deinit();
    for (page_definitions) |page| {
        var marker_buf: [64]u8 = undefined;
        const page_marker = try std.fmt.bufPrint(&marker_buf, "<!--@@page {s}@@-->", .{page.marker_name});
        const replaced_count = try window_text.replace(page_marker, page.xml);
        if (replaced_count == 0) return error.PageMarkerMissing;
    }
    return window_text;
}
/// The app icon (title bar and task bar). The Windows .exe also carries it as GogglesRandoAppIcon.ico (app.rc).
pub const app_icon_png = @embedFile("GogglesRandoAppIcon.png");


pub const status_count = std.meta.tags(settings.Status).len;

/// The status badge widgets of widgets.xml, one per status.
pub fn badgeTag(status: settings.Status) []const u8 {
    return settings.badgeWidgetName(status);
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
pub fn badgeStyles() [status_count]BadgeStyle {
    var out: [status_count]BadgeStyle = undefined;
    for (std.meta.tags(settings.Status), 0..) |status, i| {
        // unreachable is proven: the longest tag, "ExperimentalBadge", makes a 32-byte needle, under the buffer's 64
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

/// The preset drop-down's items: "Custom" first, then the presets.
pub const preset_items = blk: {
    var items: [settings.presets.len + 1][]const u8 = undefined;
    items[0] = "Custom";
    for (settings.presets, 1..) |p, i| items[i] = p.name;
    break :blk items;
};

/// main.xml with its pages put in and its generated parts filled in. Allocated with `allocator`.
pub fn windowXml(allocator: Allocator) LayoutError![]u8 {
    var text = try assemblePages(allocator);
    defer text.deinit();

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
    try tip_text.append("Sets every gameplay setting for a seed difficulty, or for racing (Excluded Locations, Create Spoiler Log and Per-Seed Saves are kept).\n" ++
        "No experimental option is used. Change anything afterwards and the preset shows Custom. Your own saved presets (\u{2605}) are listed after these.\n\n");
    for (settings.presets, 0..) |p, i| {
        if (i > 0) try tip_text.append("\n\n");
        try tip_text.appendFmt("{s}: {s}", .{ p.name, p.tip });
    }
    var tip = string.String.init(allocator);
    defer tip.deinit();
    try appendAttr(&tip, tip_text.slice());
    _ = try text.replace("@@preset_tip@@", tip.slice());
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
