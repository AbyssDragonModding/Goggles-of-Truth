//! The game's files, read from an extracted romfs folder or straight from a .nup package.
//!
//! Everything the generator reads from the game goes through GameFiles, so both sources work the same way.
//! Paths are romfs-relative with "/" separators ("Pack/ZsDic.pack.zs"); "" is the romfs root. Nothing is ever
//! written to the source: the .nup is opened read-only and the mod is written to its own folder.
//!
//! A .nup holds a game's base and/or update packages, each with its own exefs and full romfs. Like Clawshot, the
//! newest base/update package of the one game in the file is used, and every file read is checked against the
//! SHA-256 stored in the package.

const std = @import("std");
const builtin = @import("builtin");
const nup = @import("../formats/nup.zig");
const fsmod = @import("../core/fs.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const Fs = fsmod.Fs;

pub const GameFilesError = error{
    /// The path is empty, missing, or not a romfs folder / .nup (the Progress failure message says which).
    NotAGame,
    /// The .nup is damaged or doesn't hold one game's romfs.
    InvalidPackage,
    /// A file inside the .nup failed its SHA-256 check.
    Damaged,
    /// A file isn't there.
    FileNotFound,
    ReadFailed,
    OutOfMemory,
};

pub const nup_magic = "NUP";
/// An update's title ID is the base's + 0x800; both share the application ID.
const application_id_mask: u64 = ~@as(u64, 0xFFF);

/// A romfs-relative path made canonical: "/" separators, no empty or "." parts. Allocated with `allocator`.
pub fn relPath(allocator: Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (out.items.len > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

/// A chosen or typed path made usable: no surrounding quotes or spaces, no file:// URL form, no \\?\ prefix,
/// the platform's separators and no trailing separator. Allocated with `allocator`.
pub fn cleanPath(allocator: Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var p = std.mem.trim(u8, path, " \t\r\n\x00");
    p = std.mem.trim(u8, p, "\"'");
    p = std.mem.trim(u8, p, " \t\r\n");
    var decoded: ?[]u8 = null;
    defer if (decoded) |d| allocator.free(d);
    if (p.len >= 7 and std.ascii.eqlIgnoreCase(p[0..7], "file://")) {
        // file:///D:/x or file:///home/x: drop the scheme and the host, decode %XX
        var rest = p[7..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..];
        const d = try percentDecode(allocator, rest);
        decoded = d;
        p = d;
        if (builtin.os.tag == .windows and p.len > 2 and p[0] == '/' and p[2] == ':') p = p[1..]; // /D:/x -> D:/x
    }
    if (std.mem.startsWith(u8, p, "\\\\?\\") or std.mem.startsWith(u8, p, "//?/")) p = p[4..];
    if (p.len == 0) return allocator.alloc(u8, 0);
    return normalizePath(allocator, p);
}

fn percentDecode(allocator: Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(allocator, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(allocator, s[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// Like os.path.normpath: the platform's separator, "." and "x/.." parts removed, no trailing separator.
pub fn normalizePath(allocator: Allocator, p: []const u8) error{OutOfMemory}![]u8 {
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var prefix_len: usize = 0;
    if (builtin.os.tag == .windows) {
        if (p.len >= 2 and p[1] == ':') prefix_len = 2; // drive
        if (p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/')) prefix_len = 2; // UNC
    }
    const absolute = p.len > prefix_len and (p[prefix_len] == '/' or p[prefix_len] == '\\');
    var it = std.mem.tokenizeAny(u8, p[prefix_len..], "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (p[0..prefix_len]) |c| try out.append(allocator, if (c == '/' or c == '\\') sep else c);
    if (absolute) try out.append(allocator, sep);
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(allocator, sep);
        try out.appendSlice(allocator, part);
    }
    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

/// True for a file that starts with the NUP magic (whatever its extension).
pub fn isNup(fs: Fs, path: []const u8) bool {
    if (!fs.isFile(path)) return false;
    var head: [3]u8 = undefined;
    const got = fs.readStart(path, &head) catch return false;
    return std.mem.eql(u8, got, nup_magic);
}

fn isRomfs(fs: Fs, allocator: Allocator, folder: []const u8) error{OutOfMemory}!bool {
    const dic = try fsmod.join(allocator, &.{ folder, "Pack", "ZsDic.pack.zs" });
    defer allocator.free(dic);
    const banc = try fsmod.join(allocator, &.{ folder, "Banc" });
    defer allocator.free(banc);
    return fs.isFile(dic) and fs.isDir(banc);
}

/// The romfs for a chosen folder: the folder itself, its "romfs" subfolder (a dump's game folder), or the romfs it
/// is inside (a folder dialog can hand back a subfolder such as romfs/Banc). Null when there is none.
pub fn findRomfs(fs: Fs, allocator: Allocator, chosen: []const u8) error{OutOfMemory}!?[]u8 {
    const cleaned = try cleanPath(allocator, chosen);
    defer allocator.free(cleaned);
    if (cleaned.len == 0 or !fs.isDir(cleaned)) return null;
    const folder = fs.absolute(allocator, cleaned) catch return null;
    defer allocator.free(folder);

    const sub = try fsmod.join(allocator, &.{ folder, "romfs" });
    if (try isRomfs(fs, allocator, sub) and !try isRomfs(fs, allocator, folder)) return sub;
    allocator.free(sub);

    var candidate: []const u8 = folder;
    var step: usize = 0;
    while (step < 4) : (step += 1) {
        if (try isRomfs(fs, allocator, candidate)) return try allocator.dupe(u8, candidate);
        const parent = std.fs.path.dirname(candidate) orelse break;
        if (parent.len == candidate.len) break;
        candidate = parent;
    }
    return null;
}

/// One entry of a .nup folder: its name and whether it is a folder.
const NupEntry = struct {
    name: []const u8,
    is_dir: bool,
};

/// The romfs and exefs of an extracted folder or of the newest base/update package in a .nup.
pub const GameFiles = struct {
    allocator: Allocator,
    fs: Fs,
    kind: Kind,
    /// what the user chose (folder or .nup), for messages
    path: []const u8,
    /// folder: the romfs folder
    romfs: []const u8 = "",
    /// .nup: the reader, the package used and the romfs tree (built at open, in `tree_arena`)
    reader: ?nup.Reader = null,
    package: ?nup.PackageInfo = null,
    title_id: [16]u8 = undefined,
    tree_arena: std.heap.ArenaAllocator,
    dirs: std.StringHashMap(std.ArrayList(NupEntry)),
    files: std.StringHashMap(u32),

    pub const Kind = enum { folder, nup };

    const Self = @This();

    /// GameFiles for a .nup, an extracted romfs folder, or a game folder holding "romfs". The returned value must
    /// stay where it is (call `deinit` when done); `progress` gets the failure message.
    pub fn open(allocator: Allocator, fs: Fs, chosen: []const u8, progress: *Progress) GameFilesError!*Self {
        const path = cleanPath(allocator, chosen) catch return error.OutOfMemory;
        defer allocator.free(path);
        if (path.len == 0) return progress.fail(error.NotAGame, "Choose your game: an extracted romfs folder or a .nup file.", .{});

        const self = allocator.create(Self) catch return error.OutOfMemory;
        self.* = Self{
            .allocator = allocator,
            .fs = fs,
            .kind = .folder,
            .path = "",
            .tree_arena = std.heap.ArenaAllocator.init(allocator),
            .dirs = std.StringHashMap(std.ArrayList(NupEntry)).init(allocator),
            .files = std.StringHashMap(u32).init(allocator),
        };
        errdefer self.deinit();
        const arena = self.tree_arena.allocator();
        self.path = arena.dupe(u8, path) catch return error.OutOfMemory;

        if (fs.isFile(path)) {
            if (!isNup(fs, path)) return progress.fail(error.NotAGame, "{s} is not a .nup package. Choose a .nup file or the extracted romfs folder.", .{path});
            self.kind = .nup;
            try self.openNup(progress);
            return self;
        }
        if (fs.isDir(path)) {
            const romfs = (findRomfs(fs, arena, path) catch return error.OutOfMemory) orelse
                return progress.fail(error.NotAGame, "That folder does not look like the game's extracted romfs\n(expected Pack/ZsDic.pack.zs and a Banc folder).", .{});
            self.romfs = romfs;
            return self;
        }
        return progress.fail(error.NotAGame, "{s} doesn't exist.", .{path});
    }

    pub fn deinit(self: *Self) void {
        if (self.reader) |*r| r.close();
        var it = self.dirs.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.dirs.deinit();
        self.files.deinit();
        self.tree_arena.deinit();
        self.allocator.destroy(self);
    }

    fn openNup(self: *Self, progress: *Progress) GameFilesError!void {
        self.reader = nup.Reader.open(self.allocator, self.fs.io, self.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return progress.fail(error.ReadFailed, "Couldn't open {s}.", .{self.path}),
            else => return progress.fail(error.InvalidPackage, "{s} is not a valid .nup: {s}", .{ self.path, @errorName(err) }),
        };
        const r = &self.reader.?;

        // the one game in the file: every base/update package shares an application ID
        var newest: ?nup.PackageInfo = null;
        var app_id: ?u64 = null;
        var count_newest: usize = 0;
        for (r.packages) |p| {
            if (p.kind != .base and p.kind != .update) continue;
            const id = p.title_id & application_id_mask;
            if (app_id != null and app_id.? != id) return progress.fail(error.InvalidPackage, "The .nup must hold one game's base or update package.", .{});
            app_id = id;
            if (newest == null or p.version > newest.?.version) {
                newest = p;
                count_newest = 1;
            } else if (p.version == newest.?.version) {
                count_newest += 1;
            }
        }
        const pkg = newest orelse return progress.fail(error.InvalidPackage, "The .nup must hold one game's base or update package.", .{});
        if (count_newest != 1 or pkg.romfs_dir == nup.no_dir) return progress.fail(error.InvalidPackage, "The .nup's newest package has no complete romfs.", .{});
        self.package = pkg;
        _ = std.fmt.bufPrint(&self.title_id, "{x:0>16}", .{pkg.title_id}) catch unreachable;
        try self.buildTree(pkg.romfs_dir, progress);
    }

    /// Indexes the romfs folder tree: {folder rel: entries} and {file rel: file index}.
    fn buildTree(self: *Self, top: u32, progress: *Progress) GameFilesError!void {
        const r = &self.reader.?;
        const arena = self.tree_arena.allocator();
        const seen = self.allocator.alloc(bool, r.dirs.len) catch return error.OutOfMemory;
        defer self.allocator.free(seen);
        @memset(seen, false);

        const Pending = struct { index: u32, prefix: []const u8 };
        var stack: std.ArrayList(Pending) = .empty;
        defer stack.deinit(self.allocator);
        stack.append(self.allocator, Pending{ .index = top, .prefix = "" }) catch return error.OutOfMemory;
        while (stack.pop()) |item| {
            if (seen[item.index]) return progress.fail(error.InvalidPackage, "The .nup's folder tree is damaged (a folder appears twice).", .{});
            seen[item.index] = true;
            var entries: std.ArrayList(NupEntry) = .empty;
            const d = r.dirs[item.index];
            var k: usize = 0;
            while (k < d.child_count) : (k += 1) {
                const ref = r.nodeRef(r.children[d.first_child + k]) catch
                    return progress.fail(error.InvalidPackage, "The .nup's folder tree is damaged (index out of range).", .{});
                // why: names come from the package and must never act as paths
                if (ref.name.len == 0 or std.mem.eql(u8, ref.name, ".") or std.mem.eql(u8, ref.name, "..") or
                    std.mem.indexOfAny(u8, ref.name, "/\\\x00") != null or !std.unicode.utf8ValidateSlice(ref.name))
                {
                    entries.deinit(self.allocator);
                    return progress.fail(error.InvalidPackage, "The .nup has an unsafe file name: {s}{s}", .{ item.prefix, ref.name });
                }
                entries.append(self.allocator, NupEntry{ .name = ref.name, .is_dir = ref.is_dir }) catch return error.OutOfMemory;
                const full = if (item.prefix.len == 0)
                    arena.dupe(u8, ref.name) catch return error.OutOfMemory
                else
                    std.fmt.allocPrint(arena, "{s}/{s}", .{ item.prefix, ref.name }) catch return error.OutOfMemory;
                if (ref.is_dir) {
                    stack.append(self.allocator, Pending{ .index = ref.index, .prefix = full }) catch return error.OutOfMemory;
                } else {
                    self.files.put(full, ref.index) catch return error.OutOfMemory;
                }
            }
            self.dirs.put(item.prefix, entries) catch return error.OutOfMemory;
        }
    }

    fn absolutePath(self: *const Self, allocator: Allocator, rel: []const u8) error{OutOfMemory}![]u8 {
        const clean = try relPath(allocator, rel);
        defer allocator.free(clean);
        if (clean.len == 0) return allocator.dupe(u8, self.romfs);
        return fsmod.join(allocator, &.{ self.romfs, clean });
    }

    /// The bytes of romfs file `rel` (checked against its SHA-256 in a .nup). Allocated with `allocator`.
    pub fn read(self: *const Self, allocator: Allocator, rel: []const u8) GameFilesError![]u8 {
        switch (self.kind) {
            .folder => {
                const abs = self.absolutePath(allocator, rel) catch return error.OutOfMemory;
                defer allocator.free(abs);
                return self.fs.readAll(allocator, abs) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.NotFound => error.FileNotFound,
                    else => error.ReadFailed,
                };
            },
            .nup => {
                const clean = relPath(allocator, rel) catch return error.OutOfMemory;
                defer allocator.free(clean);
                const index = self.files.get(clean) orelse return error.FileNotFound;
                return self.readIndex(allocator, index);
            },
        }
    }

    fn readIndex(self: *const Self, allocator: Allocator, index: u32) GameFilesError![]u8 {
        return self.reader.?.readFileVerified(allocator, index) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileChecksumMismatch, error.Corrupt => error.Damaged,
            else => error.ReadFailed,
        };
    }

    /// True if `rel` is a file.
    pub fn exists(self: *const Self, rel: []const u8) bool {
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        switch (self.kind) {
            .folder => {
                const abs = self.absolutePath(self.allocator, rel) catch return false;
                defer self.allocator.free(abs);
                return self.fs.isFile(abs);
            },
            .nup => {
                const clean = relPath(fba.allocator(), rel) catch return false;
                return self.files.contains(clean);
            },
        }
    }

    pub fn isDir(self: *const Self, rel: []const u8) bool {
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        switch (self.kind) {
            .folder => {
                const abs = self.absolutePath(self.allocator, rel) catch return false;
                defer self.allocator.free(abs);
                return self.fs.isDir(abs);
            },
            .nup => {
                const clean = relPath(fba.allocator(), rel) catch return false;
                return self.dirs.contains(clean);
            },
        }
    }

    /// The names in folder `rel`, sorted. The list and names are allocated with `allocator` (use an arena).
    pub fn listDir(self: *const Self, allocator: Allocator, rel: []const u8) GameFilesError![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        switch (self.kind) {
            .folder => {
                const abs = self.absolutePath(allocator, rel) catch return error.OutOfMemory;
                const found = self.fs.listDir(allocator, abs) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.FileNotFound,
                };
                for (found) |n| names.append(allocator, n) catch return error.OutOfMemory;
            },
            .nup => {
                const clean = relPath(allocator, rel) catch return error.OutOfMemory;
                const entries = self.dirs.get(clean) orelse return error.FileNotFound;
                for (entries.items) |e| names.append(allocator, e.name) catch return error.OutOfMemory;
            },
        }
        std.mem.sort([]const u8, names.items, {}, lessString);
        return names.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// The first name in folder `folder` starting with `prefix` (sorted), as "folder/name".
    pub fn find(self: *const Self, allocator: Allocator, folder: []const u8, prefix: []const u8) GameFilesError![]const u8 {
        const names = try self.listDir(allocator, folder);
        for (names) |n| {
            if (std.mem.startsWith(u8, n, prefix)) {
                return std.fmt.allocPrint(allocator, "{s}/{s}", .{ folder, n }) catch return error.OutOfMemory;
            }
        }
        return error.FileNotFound;
    }

    // ------------------------------------------------------------------------------------------------ exefs

    /// File index of exefs/<name> in the .nup, or null.
    fn exefsFile(self: *const Self, name: []const u8) ?u32 {
        const pkg = self.package orelse return null;
        if (pkg.exefs_dir == nup.no_dir) return null;
        const r = &self.reader.?;
        const d = r.dirs[pkg.exefs_dir];
        var k: usize = 0;
        while (k < d.child_count) : (k += 1) {
            const ref = r.nodeRef(r.children[d.first_child + k]) catch continue;
            if (!ref.is_dir and std.mem.eql(u8, ref.name, name)) return ref.index;
        }
        return null;
    }

    /// The bytes of exefs/<name> in the .nup, or null when it isn't there.
    pub fn exefsRead(self: *const Self, allocator: Allocator, name: []const u8) GameFilesError!?[]u8 {
        const index = self.exefsFile(name) orelse return null;
        return try self.readIndex(allocator, index);
    }
};

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "relPath" {
    const a = std.testing.allocator;
    const p = try relPath(a, "\\Pack//./ZsDic.pack.zs");
    defer a.free(p);
    try std.testing.expectEqualStrings("Pack/ZsDic.pack.zs", p);
}
