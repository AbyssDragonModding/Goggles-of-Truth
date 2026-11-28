//! Checks the window's pages (src/ui/pages/*.xml) against the setting table (src/settings/table.zig). Why: every
//! setting row is written out in its page's XML (AGENTS.md: every widget is defined in XML), while the table
//! holds what the generator reads (keys, options, defaults) and the same labels and tooltips. This test fails when
//! the two drift apart: a setting without its row, a row's control, label, tooltip, options or status badge that no
//! longer matches its setting. Part of the engine's tests (`zig build test`), so it needs no window.
//!
//! A setting row, as the pages write it (src/ui/App.zig finds the control and badge by these names):
//!
//!     <HBox Spacing="12">
//!       <Label Text="<label>" ... Tooltip="<tip>"/>                     (not for a switch: its Text is the label)
//!       <ComboBox Name="set_<key>" OnChanged="set.<key>" ... Items="<option labels>" Tooltip="<tip>"/>
//!       <StableBadge Name="badge_<key>" LabelName="badgelab_<key>"/>    (the badge of the setting's status)
//!     </HBox>
//!
//! Labels and option labels are the table's without their status notes ("(experimental)", "(0.8.0 feature)"): the
//! badge shows the status instead. A choice's badge is that of its default option (the window recolours it).

const std = @import("std");
const settings = @import("../settings/settings.zig");

/// Every page file, as layout.zig builds them into the window.
const pages = [_]struct { file: []const u8, xml: []const u8 }{
    .{ .file = "rom_options.xml", .xml = @embedFile("pages/rom_options.xml") },
    .{ .file = "world.xml", .xml = @embedFile("pages/world.xml") },
    .{ .file = "items.xml", .xml = @embedFile("pages/items.xml") },
    .{ .file = "dungeon_items.xml", .xml = @embedFile("pages/dungeon_items.xml") },
    .{ .file = "starting_inventory.xml", .xml = @embedFile("pages/starting_inventory.xml") },
    .{ .file = "hints.xml", .xml = @embedFile("pages/hints.xml") },
    .{ .file = "quality_of_life.xml", .xml = @embedFile("pages/quality_of_life.xml") },
    .{ .file = "exclusions.xml", .xml = @embedFile("pages/exclusions.xml") },
};

/// `text` as an XML attribute value is written in the pages (line breaks as &#10;).
fn escapedAttribute(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\n' => try out.appendSlice(allocator, "&#10;"),
        else => try out.append(allocator, c),
    };
    return out.items;
}

/// The page holding `needle` exactly once across all pages, or an error naming how often it was found.
const Found = struct { page: []const u8, file: []const u8, at: usize };

fn findOnce(needle: []const u8) !Found {
    var found: ?Found = null;
    var count: usize = 0;
    for (pages) |p| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, p.xml, from, needle)) |at| : (from = at + needle.len) {
            count += 1;
            found = .{ .page = p.xml, .file = p.file, .at = at };
        }
    }
    if (count != 1) {
        std.debug.print("src/ui/pages: {s} found {d} times (expected once)\n", .{ needle, count });
        return error.PageMismatch;
    }
    return found.?;
}

/// The setting row around `at`: from the <HBox before it to the </HBox> after it.
fn rowAround(page: []const u8, at: usize) []const u8 {
    const start = std.mem.lastIndexOf(u8, page[0..at], "<HBox") orelse 0;
    const end = std.mem.indexOfPos(u8, page, at, "</HBox>") orelse page.len;
    return page[start..end];
}

fn expectInRow(row: []const u8, key: []const u8, what: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, row, needle) != null) return;
    std.debug.print("src/ui/pages: the row of setting {s} has no {s} matching src/settings/table.zig:\n  expected {s}\n", .{ key, what, needle });
    return error.PageMismatch;
}

test "every setting's row in src/ui/pages matches src/settings/table.zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (&settings.specs) |*s| {
        const key = @tagName(s.key);
        var label_buffer: [512]u8 = undefined;
        const split = settings.splitStatus(&label_buffer, s.label);
        if (s.kind == .list) {
            // a list setting has a page of its own (Exclusions, Starting Inventory), titled by its tab, with its
            // status badge
            const title = try std.fmt.allocPrint(a, "Slot.Title=\"{s}\"", .{s.tab});
            const page = try findOnce(title);
            const badge = try std.fmt.allocPrint(a, "<{s}", .{settings.badgeWidgetName(split.status)});
            try expectInRow(page.page, key, "status badge on its page", badge);
            continue;
        }

        const control_tag = switch (s.kind) {
            .boolean => "Checkbox",
            .int => "SpinBox",
            .choice => "ComboBox",
            .list => unreachable,
        };
        const found = try findOnce(try std.fmt.allocPrint(a, "Name=\"set_{s}\"", .{key}));
        const row = rowAround(found.page, found.at);
        try expectInRow(row, key, "control", try std.fmt.allocPrint(a, "<{s} Name=\"set_{s}\"", .{ control_tag, key }));
        try expectInRow(row, key, "action", try std.fmt.allocPrint(a, "OnChanged=\"set.{s}\"", .{key}));
        try expectInRow(row, key, "label", try std.fmt.allocPrint(a, "Text=\"{s}\"", .{try escapedAttribute(a, split.text)}));
        try expectInRow(row, key, "tooltip", try std.fmt.allocPrint(a, "Tooltip=\"{s}\"", .{try escapedAttribute(a, s.tip)}));
        if (s.kind == .choice) {
            var items: std.ArrayList(u8) = .empty;
            for (s.options, 0..) |o, i| {
                if (i > 0) try items.append(a, '|');
                var option_buffer: [256]u8 = undefined;
                const option_label = settings.splitStatus(&option_buffer, o.label).text;
                // "|" separates the drop-down's items, so an option's own "|" is written "/"
                const without_bars = try std.mem.replaceOwned(u8, a, option_label, "|", "/");
                try items.appendSlice(a, try escapedAttribute(a, without_bars));
            }
            try expectInRow(row, key, "options", try std.fmt.allocPrint(a, "Items=\"{s}\"", .{items.items}));
        }
        const status = if (s.kind == .choice) settings.settingStatus(s.key, s.default.choice) else split.status;
        try expectInRow(row, key, "status badge", try std.fmt.allocPrint(a, "<{s} Name=\"badge_{s}\" LabelName=\"badgelab_{s}\"/>", .{
            settings.badgeWidgetName(status), key, key,
        }));
    }
}

test "no page still has a generated-part marker" {
    for (pages) |p| {
        if (std.mem.indexOf(u8, p.xml, "<!--@@") != null) {
            std.debug.print("src/ui/pages/{s}: a <!--@@...@@--> marker is left (nothing fills it in any more)\n", .{p.file});
            return error.PageMismatch;
        }
    }
}
