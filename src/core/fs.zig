//! File system helpers over std.Io, with one small error set.
//!
//! Paths are absolute or relative to the current folder, with the platform's separators (or "/", which Windows
//! also accepts). Every std error is mapped to FsError so callers have one short list of failure modes.

const std = @import("std");
const host = @import("../platform/host.zig");
const Io = std.Io;
const Dir = std.Io.Dir;

pub const FsError = error{
    NotFound,
    AccessDenied,
    AlreadyExists,
    IoFailed,
    OutOfMemory,
};

fn mapError(err: anyerror) FsError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.AccessDenied, error.PermissionDenied, error.FileBusy => error.AccessDenied,
        error.PathAlreadyExists => error.AlreadyExists,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailed,
    };
}

pub const Kind = enum { file, directory, other, missing };

pub const Fs = struct {
    io: Io,

    const Self = @This();

    pub fn init(io: Io) Self {
        return Self{ .io = io };
    }

    /// What is at `path` (following links).
    pub fn kindOf(self: Self, path: []const u8) Kind {
        if (path.len == 0) return .missing;
        const st = Dir.cwd().statFile(self.io, path, .{}) catch return .missing;
        return switch (st.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        };
    }

    pub fn isFile(self: Self, path: []const u8) bool {
        return self.kindOf(path) == .file;
    }

    pub fn isDir(self: Self, path: []const u8) bool {
        return self.kindOf(path) == .directory;
    }

    pub fn exists(self: Self, path: []const u8) bool {
        return self.kindOf(path) != .missing;
    }

    /// Modification time in nanoseconds, or null when the path can't be read.
    pub fn mtime(self: Self, path: []const u8) ?i96 {
        const st = Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return st.mtime.nanoseconds;
    }

    pub fn fileSize(self: Self, path: []const u8) ?u64 {
        const st = Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return st.size;
    }

    /// Sets a file's modification time to now (the cache keeps the files used last).
    pub fn touch(self: Self, path: []const u8) FsError!void {
        // through an open file: Zig 0.17's path version (Dir.setTimestampsNow) isn't implemented on Windows yet
        const file = Dir.cwd().openFile(self.io, path, .{ .mode = .read_write }) catch |err| return mapError(err);
        defer file.close(self.io);
        file.setTimestampsNow(self.io) catch |err| return mapError(err);
    }

    /// The whole file, allocated with `allocator`.
    pub fn readAll(self: Self, allocator: std.mem.Allocator, path: []const u8) FsError![]u8 {
        return Dir.cwd().readFileAlloc(self.io, path, allocator, .unlimited) catch |err| return mapError(err);
    }

    /// Up to `buffer.len` bytes from the start of a file.
    pub fn readStart(self: Self, path: []const u8, buffer: []u8) FsError![]u8 {
        const file = Dir.cwd().openFile(self.io, path, .{}) catch |err| return mapError(err);
        defer file.close(self.io);
        const n = file.readPositionalAll(self.io, buffer, 0) catch |err| return mapError(err);
        return buffer[0..n];
    }

    /// Writes `data` to `path`, replacing it; the folder must exist.
    pub fn writeAll(self: Self, path: []const u8, data: []const u8) FsError!void {
        Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch |err| return mapError(err);
    }

    /// Writes through a temporary file and a rename, so a crash never leaves half a file.
    pub fn writeAtomic(self: Self, allocator: std.mem.Allocator, path: []const u8, data: []const u8) FsError!void {
        const tmp = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch return error.OutOfMemory;
        defer allocator.free(tmp);
        try self.writeAll(tmp, data);
        try self.rename(tmp, path);
    }

    /// Creates a folder and every missing parent.
    pub fn makePath(self: Self, path: []const u8) FsError!void {
        Dir.cwd().createDirPath(self.io, path) catch |err| return mapError(err);
    }

    pub fn rename(self: Self, old_path: []const u8, new_path: []const u8) FsError!void {
        Dir.rename(Dir.cwd(), old_path, Dir.cwd(), new_path, self.io) catch |err| return mapError(err);
    }

    pub fn deleteFile(self: Self, path: []const u8) FsError!void {
        Dir.cwd().deleteFile(self.io, path) catch |err| return mapError(err);
    }

    /// Deletes a file or a whole folder.
    pub fn deleteTree(self: Self, path: []const u8) FsError!void {
        Dir.cwd().deleteTree(self.io, path) catch |err| return mapError(err);
    }

    /// Copies a file (its folder must exist).
    pub fn copyFile(self: Self, source: []const u8, dest: []const u8) FsError!void {
        Dir.copyFile(Dir.cwd(), source, Dir.cwd(), dest, self.io, .{}) catch |err| return mapError(err);
    }

    /// Copies a folder and everything inside it.
    pub fn copyTree(self: Self, allocator: std.mem.Allocator, source: []const u8, dest: []const u8) FsError!void {
        try self.makePath(dest);
        const names = try self.listDir(allocator, source);
        defer freeNames(allocator, names);
        for (names) |name| {
            const from = std.fs.path.join(allocator, &.{ source, name }) catch return error.OutOfMemory;
            defer allocator.free(from);
            const to = std.fs.path.join(allocator, &.{ dest, name }) catch return error.OutOfMemory;
            defer allocator.free(to);
            if (self.isDir(from)) {
                try self.copyTree(allocator, from, to);
            } else {
                try self.copyFile(from, to);
            }
        }
    }

    /// The names in a folder (unsorted), each allocated with `allocator`. Free with `freeNames`.
    pub fn listDir(self: Self, allocator: std.mem.Allocator, path: []const u8) FsError![][]u8 {
        var dir = Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| return mapError(err);
        defer dir.close(self.io);
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return mapError(err)) |entry| {
            const copy = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            names.append(allocator, copy) catch {
                allocator.free(copy);
                return error.OutOfMemory;
            };
        }
        return names.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// Like listDir, sorted by name.
    pub fn listDirSorted(self: Self, allocator: std.mem.Allocator, path: []const u8) FsError![][]u8 {
        const names = try self.listDir(allocator, path);
        sortNames(names);
        return names;
    }

    /// The absolute form of `path` (resolved against the current folder; ".." and "." removed).
    pub fn absolute(self: Self, allocator: std.mem.Allocator, path: []const u8) FsError![]u8 {
        const cwd = std.process.currentPathAlloc(self.io, allocator) catch return error.IoFailed;
        defer allocator.free(cwd);
        return std.fs.path.resolveAlloc(allocator, &.{ cwd, path }) catch return error.OutOfMemory;
    }
};

pub fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn sortNames(names: [][]u8) void {
    std.mem.sort([]u8, names, {}, lessThanName);
}

/// Joins path parts with the platform's separator.
pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) error{OutOfMemory}![]u8 {
    return std.fs.path.join(allocator, parts) catch return error.OutOfMemory;
}

/// The folder part of a path ("" when there is none).
pub fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Case-insensitive on Windows and macOS (their default file systems), exact elsewhere (platform/host.zig).
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (host.file_names_ignore_case) {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            const xs = if (x == '\\') '/' else std.ascii.toLower(x);
            const ys = if (y == '\\') '/' else std.ascii.toLower(y);
            if (xs != ys) return false;
        }
        return true;
    }
    return std.mem.eql(u8, a, b);
}

/// True when `inner` is `outer` itself or inside it (both absolute and resolved).
pub fn isInside(outer: []const u8, inner: []const u8) bool {
    if (inner.len < outer.len) return false;
    if (!samePath(outer, inner[0..outer.len])) return false;
    if (inner.len == outer.len) return true;
    const next = inner[outer.len];
    return next == '/' or next == '\\' or (outer.len > 0 and (outer[outer.len - 1] == '/' or outer[outer.len - 1] == '\\'));
}
