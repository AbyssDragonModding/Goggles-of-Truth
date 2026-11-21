//! A minimal .xlsx writer: one sheet of text, numbers and formulas, with cell styles, column widths, frozen rows, an
//! auto-filter, list validations and "equals" conditional fills. Enough for the seed checklist; the ZIP is stored
//! (no compression), which every spreadsheet program reads.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const Font = enum { normal, bold, bold_white };
pub const Fill = struct {
    /// RRGGBB, or null for none
    color: ?[]const u8 = null,
};
pub const Align = enum { none, top, wrap_top, center };

pub const Style = struct {
    font: Font = .normal,
    fill: ?[]const u8 = null,
    top_border: bool = false,
    alignment: Align = .none,

    fn eql(a: Style, b: Style) bool {
        const fills_equal = if (a.fill == null or b.fill == null) a.fill == null and b.fill == null else std.mem.eql(u8, a.fill.?, b.fill.?);
        return a.font == b.font and fills_equal and a.top_border == b.top_border and a.alignment == b.alignment;
    }
};

pub const Value = union(enum) {
    empty,
    text: []const u8,
    number: i64,
    /// without the leading "="
    formula: []const u8,
};

pub const Cell = struct {
    value: Value = .empty,
    style: Style = .{},
};

pub const Validation = struct {
    /// "F8:F40"
    range: []const u8,
    /// the allowed values
    values: []const []const u8,
    prompt_title: []const u8,
    prompt: []const u8,
};

pub const ConditionalFill = struct {
    range: []const u8,
    equals: []const u8,
    color: []const u8,
};

pub const Sheet = struct {
    allocator: Allocator,
    name: []const u8,
    rows: std.ArrayList(std.ArrayList(Cell)),
    /// column letter -> width
    widths: std.ArrayList(struct { column: usize, width: f64 }),
    /// rows above this one stay in view (1-based row of the first scrolling row), 0 for none
    freeze_row: usize = 0,
    auto_filter: []const u8 = "",
    validations: std.ArrayList(Validation),
    conditional: std.ArrayList(ConditionalFill),

    const Self = @This();

    pub fn init(allocator: Allocator, name: []const u8) Self {
        return Self{ .allocator = allocator, .name = name, .rows = .empty, .widths = .empty, .validations = .empty, .conditional = .empty };
    }

    /// The cell at (row, column), 0-based; the sheet grows to hold it.
    pub fn cell(self: *Self, row: usize, column: usize) error{OutOfMemory}!*Cell {
        while (self.rows.items.len <= row) try self.rows.append(self.allocator, .empty);
        const r = &self.rows.items[row];
        while (r.items.len <= column) try r.append(self.allocator, .{});
        return &r.items[column];
    }

    pub fn setWidth(self: *Self, column: usize, width: f64) error{OutOfMemory}!void {
        try self.widths.append(self.allocator, .{ .column = column, .width = width });
    }
};

/// "A", "B", ..., "Z", "AA", ... for a 0-based column.
pub fn columnName(buffer: *[4]u8, column: usize) []const u8 {
    var n = column + 1;
    var len: usize = 0;
    var tmp: [4]u8 = undefined;
    while (n > 0) {
        const r = (n - 1) % 26;
        tmp[len] = @intCast('A' + r);
        len += 1;
        n = (n - 1) / 26;
    }
    for (0..len) |i| buffer[i] = tmp[len - 1 - i];
    return buffer[0..len];
}

fn escape(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) error{OutOfMemory}!void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => {
                // control characters aren't allowed in XML (except tab, line feed, carriage return)
                if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') continue;
                try out.append(allocator, c);
            },
        }
    }
}

const Styles = struct {
    list: std.ArrayList(Style),
    fills: std.ArrayList([]const u8),

    fn index(self: *Styles, allocator: Allocator, s: Style) error{OutOfMemory}!usize {
        for (self.list.items, 0..) |x, i| if (Style.eql(x, s)) return i;
        try self.list.append(allocator, s);
        if (s.fill) |f| {
            var known = false;
            for (self.fills.items) |x| if (std.mem.eql(u8, x, f)) {
                known = true;
            };
            if (!known) try self.fills.append(allocator, f);
        }
        return self.list.items.len - 1;
    }

    fn fillIndex(self: *const Styles, color: ?[]const u8) usize {
        const c = color orelse return 0;
        for (self.fills.items, 0..) |x, i| if (std.mem.eql(u8, x, c)) return i + 2; // 0 none, 1 gray125
        return 0;
    }
};

fn sheetXml(allocator: Allocator, sheet: *const Sheet, styles: *Styles) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">");
    if (sheet.freeze_row > 1) {
        var buf: [4]u8 = undefined;
        try out.print(allocator, "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"{d}\" topLeftCell=\"{s}{d}\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>", .{ sheet.freeze_row - 1, columnName(&buf, 0), sheet.freeze_row });
    }
    if (sheet.widths.items.len > 0) {
        try out.appendSlice(allocator, "<cols>");
        for (sheet.widths.items) |w| try out.print(allocator, "<col min=\"{d}\" max=\"{d}\" width=\"{d}\" customWidth=\"1\"/>", .{ w.column + 1, w.column + 1, w.width });
        try out.appendSlice(allocator, "</cols>");
    }
    try out.appendSlice(allocator, "<sheetData>");
    for (sheet.rows.items, 1..) |row, r| {
        try out.print(allocator, "<row r=\"{d}\">", .{r});
        for (row.items, 0..) |c, col| {
            var buf: [4]u8 = undefined;
            const ref = columnName(&buf, col);
            const s = try styles.index(allocator, c.style);
            switch (c.value) {
                .empty => if (s != 0) try out.print(allocator, "<c r=\"{s}{d}\" s=\"{d}\"/>", .{ ref, r, s }),
                .number => |n| try out.print(allocator, "<c r=\"{s}{d}\" s=\"{d}\"><v>{d}</v></c>", .{ ref, r, s, n }),
                .text => |t| {
                    try out.print(allocator, "<c r=\"{s}{d}\" s=\"{d}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">", .{ ref, r, s });
                    try escape(&out, allocator, t);
                    try out.appendSlice(allocator, "</t></is></c>");
                },
                .formula => |f| {
                    try out.print(allocator, "<c r=\"{s}{d}\" s=\"{d}\"><f>", .{ ref, r, s });
                    try escape(&out, allocator, f);
                    try out.appendSlice(allocator, "</f></c>");
                },
            }
        }
        try out.appendSlice(allocator, "</row>");
    }
    try out.appendSlice(allocator, "</sheetData>");
    if (sheet.auto_filter.len > 0) try out.print(allocator, "<autoFilter ref=\"{s}\"/>", .{sheet.auto_filter});
    for (sheet.conditional.items, 0..) |cf, i| {
        try out.print(allocator, "<conditionalFormatting sqref=\"{s}\"><cfRule type=\"cellIs\" dxfId=\"{d}\" priority=\"{d}\" operator=\"equal\"><formula>&quot;", .{ cf.range, i, i + 1 });
        try escape(&out, allocator, cf.equals);
        try out.appendSlice(allocator, "&quot;</formula></cfRule></conditionalFormatting>");
    }
    if (sheet.validations.items.len > 0) {
        try out.print(allocator, "<dataValidations count=\"{d}\">", .{sheet.validations.items.len});
        for (sheet.validations.items) |v| {
            try out.appendSlice(allocator, "<dataValidation type=\"list\" allowBlank=\"1\" showInputMessage=\"1\" showErrorMessage=\"1\" promptTitle=\"");
            try escape(&out, allocator, v.prompt_title);
            try out.appendSlice(allocator, "\" prompt=\"");
            try escape(&out, allocator, v.prompt);
            try out.print(allocator, "\" sqref=\"{s}\"><formula1>&quot;", .{v.range});
            for (v.values, 0..) |x, i| {
                if (i > 0) try out.append(allocator, ',');
                try escape(&out, allocator, x);
            }
            try out.appendSlice(allocator, "&quot;</formula1></dataValidation>");
        }
        try out.appendSlice(allocator, "</dataValidations>");
    }
    try out.appendSlice(allocator, "</worksheet>");
    return out.items;
}

fn stylesXml(allocator: Allocator, styles: *const Styles, conditional: []const ConditionalFill) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">");
    try out.appendSlice(allocator, "<fonts count=\"3\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font></fonts>");
    try out.print(allocator, "<fills count=\"{d}\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>", .{styles.fills.items.len + 2});
    for (styles.fills.items) |f| try out.print(allocator, "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF{s}\"/><bgColor indexed=\"64\"/></patternFill></fill>", .{f});
    try out.appendSlice(allocator, "</fills>");
    try out.appendSlice(allocator, "<borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top style=\"thin\"><color rgb=\"FF8DA2BC\"/></top><bottom/><diagonal/></border></borders>");
    try out.appendSlice(allocator, "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>");
    try out.print(allocator, "<cellXfs count=\"{d}\">", .{styles.list.items.len});
    for (styles.list.items) |s| {
        const font: usize = @intFromEnum(s.font);
        const fill = styles.fillIndex(s.fill);
        const border: usize = @intFromBool(s.top_border);
        try out.print(allocator, "<xf numFmtId=\"0\" fontId=\"{d}\" fillId=\"{d}\" borderId=\"{d}\" xfId=\"0\"", .{ font, fill, border });
        if (font != 0) try out.appendSlice(allocator, " applyFont=\"1\"");
        if (fill != 0) try out.appendSlice(allocator, " applyFill=\"1\"");
        if (border != 0) try out.appendSlice(allocator, " applyBorder=\"1\"");
        switch (s.alignment) {
            .none => try out.appendSlice(allocator, "/>"),
            .top => try out.appendSlice(allocator, " applyAlignment=\"1\"><alignment vertical=\"top\"/></xf>"),
            .wrap_top => try out.appendSlice(allocator, " applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"),
            .center => try out.appendSlice(allocator, " applyAlignment=\"1\"><alignment horizontal=\"center\" vertical=\"center\"/></xf>"),
        }
    }
    try out.appendSlice(allocator, "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>");
    try out.print(allocator, "<dxfs count=\"{d}\">", .{conditional.len});
    for (conditional) |c| try out.print(allocator, "<dxf><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF{s}\"/><bgColor rgb=\"FF{s}\"/></patternFill></fill></dxf>", .{ c.color, c.color });
    try out.appendSlice(allocator, "</dxfs></styleSheet>");
    return out.items;
}

const ZipEntry = struct { name: []const u8, data: []const u8, offset: u32, crc: u32 };

/// A stored (uncompressed) ZIP of the given files.
fn zip(allocator: Allocator, files: []const struct { name: []const u8, data: []const u8 }) error{OutOfMemory}![]u8 {
    var out = bytes.Buffer.init(allocator);
    var entries: std.ArrayList(ZipEntry) = .empty;
    for (files) |f| {
        const crc = std.hash.Crc32.hash(f.data);
        try entries.append(allocator, .{ .name = f.name, .data = f.data, .offset = @intCast(out.len()), .crc = crc });
        try out.appendU32(0x04034b50); // local file header
        try out.appendU16(20); // version needed
        try out.appendU16(0); // flags
        try out.appendU16(0); // stored
        try out.appendU16(0); // time
        try out.appendU16(0x21); // date: 1980-01-01
        try out.appendU32(crc);
        try out.appendU32(@intCast(f.data.len));
        try out.appendU32(@intCast(f.data.len));
        try out.appendU16(@intCast(f.name.len));
        try out.appendU16(0);
        try out.append(f.name);
        try out.append(f.data);
    }
    const directory = out.len();
    for (entries.items) |e| {
        try out.appendU32(0x02014b50); // central directory header
        try out.appendU16(20);
        try out.appendU16(20);
        try out.appendU16(0);
        try out.appendU16(0);
        try out.appendU16(0);
        try out.appendU16(0x21);
        try out.appendU32(e.crc);
        try out.appendU32(@intCast(e.data.len));
        try out.appendU32(@intCast(e.data.len));
        try out.appendU16(@intCast(e.name.len));
        try out.appendU16(0);
        try out.appendU16(0);
        try out.appendU16(0);
        try out.appendU16(0);
        try out.appendU32(0);
        try out.appendU32(e.offset);
        try out.append(e.name);
    }
    const directory_size = out.len() - directory;
    try out.appendU32(0x06054b50); // end of central directory
    try out.appendU16(0);
    try out.appendU16(0);
    try out.appendU16(@intCast(entries.items.len));
    try out.appendU16(@intCast(entries.items.len));
    try out.appendU32(@intCast(directory_size));
    try out.appendU32(@intCast(directory));
    try out.appendU16(0);
    return out.toOwnedSlice();
}

/// The .xlsx bytes of one sheet. Allocate with an arena.
pub fn write(allocator: Allocator, sheet: *const Sheet) error{OutOfMemory}![]u8 {
    var styles = Styles{ .list = .empty, .fills = .empty };
    _ = try styles.index(allocator, .{}); // style 0: the default
    const sheet_xml = try sheetXml(allocator, sheet, &styles);
    const styles_xml = try stylesXml(allocator, &styles, sheet.conditional.items);
    var workbook: std.ArrayList(u8) = .empty;
    try workbook.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"");
    try escape(&workbook, allocator, sheet.name);
    try workbook.appendSlice(allocator, "\" sheetId=\"1\" r:id=\"rId1\"/></sheets>");
    if (sheet.auto_filter.len > 0) {
        try workbook.appendSlice(allocator, "<definedNames><definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">'");
        try escape(&workbook, allocator, sheet.name);
        try workbook.print(allocator, "'!{s}</definedName></definedNames>", .{sheet.auto_filter});
    }
    try workbook.appendSlice(allocator, "</workbook>");
    return zip(allocator, &.{
        .{ .name = "[Content_Types].xml", .data = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>" },
        .{ .name = "_rels/.rels", .data = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>" },
        .{ .name = "xl/workbook.xml", .data = workbook.items },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>" },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet_xml },
        .{ .name = "xl/styles.xml", .data = styles_xml },
    });
}

test "column names" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("A", columnName(&buf, 0));
    try std.testing.expectEqualStrings("Z", columnName(&buf, 25));
    try std.testing.expectEqualStrings("AA", columnName(&buf, 26));
}
