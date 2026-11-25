//! A small TOML reader for user_settings.toml: [tables], key = value lines, comments, basic "..." and literal '...'
//! strings, integers, decimal numbers (a test plan's coordinates), booleans and (multi-line) arrays. Anything else
//! (dates, inline tables, dotted keys, inf/nan) reads as `.other`, which the settings code treats as an invalid value.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TomlError = error{
    /// the file isn't TOML this reader understands; `line` says where
    Syntax,
    OutOfMemory,
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    /// a number with a decimal point or an exponent ("1.5", "-2e3"); a whole number is `.int`
    float: f64,
    bool: bool,
    array: []Value,
    other,

    /// The number, for an integer or a decimal number (a test plan's coordinates may be written either way).
    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .int => |n| @floatFromInt(n),
            .float => |x| x,
            else => null,
        };
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Table = struct {
    name: []const u8,
    entries: std.ArrayList(Entry),

    pub fn get(self: *const Table, key: []const u8) ?Value {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

pub const Document = struct {
    tables: std.ArrayList(Table),

    /// The table named `name` ("" for keys before the first [table]).
    pub fn table(self: *const Document, name: []const u8) ?*const Table {
        for (self.tables.items) |*t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }
};

const Parser = struct {
    allocator: Allocator,
    text: []const u8,
    pos: usize = 0,
    line: usize = 1,

    const Self = @This();

    fn peek(self: *Self) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn advance(self: *Self) void {
        if (self.pos < self.text.len) {
            if (self.text[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
    }

    /// Spaces and tabs (not line breaks).
    fn skipBlanks(self: *Self) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.advance();
        }
    }

    fn skipComment(self: *Self) void {
        if (self.peek() == '#') {
            while (self.peek()) |c| {
                if (c == '\n') break;
                self.advance();
            }
        }
    }

    /// Blanks, comments and line breaks (inside arrays).
    fn skipSpaceAndComments(self: *Self) void {
        while (true) {
            self.skipBlanks();
            self.skipComment();
            const c = self.peek() orelse return;
            if (c == '\n' or c == '\r') {
                self.advance();
                continue;
            }
            return;
        }
    }

    /// The rest of the line must be blank or a comment.
    fn endOfLine(self: *Self) TomlError!void {
        self.skipBlanks();
        self.skipComment();
        if (self.peek() == '\r') self.advance();
        if (self.peek()) |c| {
            if (c != '\n') return error.Syntax;
            self.advance();
        }
    }

    fn bareKey(self: *Self) TomlError![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
            self.advance();
        }
        if (self.pos == start) return error.Syntax;
        return self.text[start..self.pos];
    }

    fn key(self: *Self) TomlError![]const u8 {
        return switch (self.peek() orelse return error.Syntax) {
            '"' => self.basicString(),
            '\'' => self.literalString(),
            else => self.bareKey(),
        };
    }

    fn literalString(self: *Self) TomlError![]const u8 {
        self.advance(); // '
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\'') {
                const s = self.text[start..self.pos];
                self.advance();
                return s;
            }
            if (c == '\n') return error.Syntax;
            self.advance();
        }
        return error.Syntax;
    }

    fn basicString(self: *Self) TomlError![]const u8 {
        self.advance(); // "
        var out: std.ArrayList(u8) = .empty;
        while (self.peek()) |c| {
            switch (c) {
                '"' => {
                    self.advance();
                    return out.items;
                },
                '\n' => return error.Syntax,
                '\\' => {
                    self.advance();
                    const e = self.peek() orelse return error.Syntax;
                    self.advance();
                    switch (e) {
                        '"' => try self.push(&out, '"'),
                        '\\' => try self.push(&out, '\\'),
                        'n' => try self.push(&out, '\n'),
                        't' => try self.push(&out, '\t'),
                        'r' => try self.push(&out, '\r'),
                        'b' => try self.push(&out, 0x08),
                        'f' => try self.push(&out, 0x0C),
                        'u', 'U' => {
                            const n: usize = if (e == 'u') 4 else 8;
                            if (self.pos + n > self.text.len) return error.Syntax;
                            const cp = std.fmt.parseInt(u21, self.text[self.pos .. self.pos + n], 16) catch return error.Syntax;
                            for (0..n) |_| self.advance();
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(cp, &buf) catch return error.Syntax;
                            out.appendSlice(self.allocator, buf[0..len]) catch return error.OutOfMemory;
                        },
                        else => return error.Syntax,
                    }
                },
                else => {
                    try self.push(&out, c);
                    self.advance();
                },
            }
        }
        return error.Syntax;
    }

    fn push(self: *Self, out: *std.ArrayList(u8), c: u8) TomlError!void {
        out.append(self.allocator, c) catch return error.OutOfMemory;
    }

    fn value(self: *Self) TomlError!Value {
        const c = self.peek() orelse return error.Syntax;
        switch (c) {
            '"' => return Value{ .string = try self.basicString() },
            '\'' => return Value{ .string = try self.literalString() },
            '[' => return self.array(),
            else => {},
        }
        // a bare word up to the end of the value: a bool, an integer, or something else
        const start = self.pos;
        while (self.peek()) |x| {
            if (x == ',' or x == ']' or x == '#' or x == '\n' or x == '\r' or x == ' ' or x == '\t') break;
            self.advance();
        }
        const word = self.text[start..self.pos];
        if (word.len == 0) return error.Syntax;
        if (std.mem.eql(u8, word, "true")) return Value{ .bool = true };
        if (std.mem.eql(u8, word, "false")) return Value{ .bool = false };
        var digits: std.ArrayList(u8) = .empty;
        for (word) |x| if (x != '_') digits.append(self.allocator, x) catch return error.OutOfMemory;
        if (std.fmt.parseInt(i64, digits.items, 10)) |n| return Value{ .int = n } else |_| {}
        // a decimal number: digits with a '.' or an exponent (inf and nan are not numbers a test plan needs)
        const looks_decimal = std.mem.indexOfAny(u8, digits.items, ".eE") != null and
            std.mem.indexOfAny(u8, digits.items, "0123456789") != null and
            std.mem.indexOfAny(u8, digits.items, "iInN") == null;
        if (looks_decimal) {
            if (std.fmt.parseFloat(f64, digits.items)) |x| return Value{ .float = x } else |_| {}
        }
        return Value.other;
    }

    fn array(self: *Self) TomlError!Value {
        self.advance(); // [
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            self.skipSpaceAndComments();
            const c = self.peek() orelse return error.Syntax;
            if (c == ']') {
                self.advance();
                return Value{ .array = items.items };
            }
            items.append(self.allocator, try self.value()) catch return error.OutOfMemory;
            self.skipSpaceAndComments();
            const sep = self.peek() orelse return error.Syntax;
            if (sep == ',') {
                self.advance();
            } else if (sep != ']') {
                return error.Syntax;
            }
        }
    }
};

/// Parses `text`. Strings point into `text` or are allocated with `allocator` (use an arena). On a syntax error,
/// `error_line` (when given) gets the line number.
pub fn parse(allocator: Allocator, text: []const u8, error_line: ?*usize) TomlError!Document {
    var p = Parser{ .allocator = allocator, .text = text };
    var doc = Document{ .tables = .empty };
    doc.tables.append(allocator, .{ .name = "", .entries = .empty }) catch return error.OutOfMemory;
    var current: usize = 0;
    errdefer if (error_line) |l| {
        l.* = p.line;
    };
    // a UTF-8 byte order mark is allowed
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) p.pos = 3;
    while (true) {
        p.skipSpaceAndComments();
        const c = p.peek() orelse break;
        if (c == '[') {
            p.advance();
            p.skipBlanks();
            const name = try p.key();
            p.skipBlanks();
            if (p.peek() != ']') return error.Syntax;
            p.advance();
            try p.endOfLine();
            current = doc.tables.items.len;
            for (doc.tables.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) {
                current = i;
            };
            if (current == doc.tables.items.len) doc.tables.append(allocator, .{ .name = name, .entries = .empty }) catch return error.OutOfMemory;
            continue;
        }
        const k = try p.key();
        p.skipBlanks();
        if (p.peek() != '=') return error.Syntax;
        p.advance();
        p.skipBlanks();
        const v = try p.value();
        try p.endOfLine();
        doc.tables.items[current].entries.append(allocator, .{ .key = k, .value = v }) catch return error.OutOfMemory;
    }
    return doc;
}

test "settings file subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\# comment
        \\[paths]
        \\game = "D:\\Games\\x.nup"
        \\output = 'C:\out'
        \\[settings]
        \\open_dmt = true
        \\bridge_tokens = 40
        \\excluded_locations = [
        \\    "A",   # first
        \\    "B",
        \\]
    , null);
    const paths = doc.table("paths").?;
    try std.testing.expectEqualStrings("D:\\Games\\x.nup", paths.get("game").?.string);
    try std.testing.expectEqualStrings("C:\\out", paths.get("output").?.string);
    const st = doc.table("settings").?;
    try std.testing.expect(st.get("open_dmt").?.bool);
    try std.testing.expectEqual(@as(i64, 40), st.get("bridge_tokens").?.int);
    try std.testing.expectEqual(@as(usize, 2), st.get("excluded_locations").?.array.len);
}

test "decimal numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\position = [12.5, -3, 1e2]
        \\facing = -90.25
        \\bad = 1.2.3
    , null);
    const root = doc.table("").?;
    const position = root.get("position").?.array;
    try std.testing.expectEqual(@as(f64, 12.5), position[0].asNumber().?);
    try std.testing.expectEqual(@as(i64, -3), position[1].int);
    try std.testing.expectEqual(@as(f64, 100), position[2].float);
    try std.testing.expectEqual(@as(f64, -90.25), root.get("facing").?.float);
    try std.testing.expect(root.get("bad").? == .other);
}
