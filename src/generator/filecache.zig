//! The file cache (Cache Compressed Files): compressed mod files kept between seeds.
//!
//! Most of a seed's time goes to compressing the patched files again (zstd level 16 with the game's dictionaries);
//! reading the game, from a .nup or an extracted romfs, is a small part of it. Many patched files come out the same
//! from one seed to the next with the same settings: the message archive of every language, most event flows and
//! stage files. So every compressed file is also stored in `<program folder>/cache/zs`, named by the SHA-256 of
//! what it was made from, and when the same uncompressed bytes come up again the stored file is used instead.
//!
//! The mod is byte for byte the same with or without the cache: a file is only taken from the cache when it
//! decompresses to exactly the bytes it stands for (so a damaged or foreign file is never used, it's made again),
//! and the key includes everything else that decides the compressed bytes (the level, the dictionary and the zstd
//! library's version). Nothing here can make a seed fail: if the cache can't be read or written, files are
//! compressed as without it, and `warning` says why.

const std = @import("std");
const zstd = @import("../formats/zstd.zig");
const fsmod = @import("../core/fs.zig");
const hash = @import("../core/hash.zig");
const Allocator = std.mem.Allocator;
const Fs = fsmod.Fs;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The cache's folder inside the program's folder.
pub const folder_name = "cache";
/// Its compressed files, in a subfolder so later kinds of cached data get their own.
const zs_folder = "zs";
/// Files smaller than this compress in about a millisecond, about what a cache lookup costs: they aren't cached.
pub const min_size: usize = 32 * 1024;
/// The cache is kept under this size; when it grows past it, the files used longest ago are deleted until it is
/// back under three quarters of it (so it isn't trimmed again on every seed).
pub const size_limit: u64 = 1024 * 1024 * 1024;
/// Raised when the key's layout changes, so old files are never mistaken for new ones.
const key_version = "1";

pub const FileCache = struct {
    fs: Fs,
    /// <program folder>/cache/zs
    dir: []const u8,
    /// files taken from the cache / compressed and stored
    hits: usize = 0,
    misses: usize = 0,
    /// files in the cache that didn't match what their name stands for (made again)
    replaced: usize = 0,
    /// set once the folder can't be made or a file can't be written: the cache is left alone for the rest of the
    /// seed and this says why (for the log)
    warning: ?[]const u8 = null,
    warning_buffer: [600]u8 = undefined,
    made_dir: bool = false,
    /// Files are compressed on several threads at once (compressor.zig): the counters, the warning, making the
    /// folder and storing a file happen under this lock. Reading and checking a cached file, and compressing,
    /// don't need it, so the threads still work side by side.
    lock: std.Io.Mutex = .init,

    const Self = @This();

    /// A cache in `<app_dir>/cache/zs`. Nothing is created until the first file is stored.
    pub fn init(allocator: Allocator, fs: Fs, app_dir: []const u8) error{OutOfMemory}!Self {
        return Self{
            .fs = fs,
            .dir = try fsmod.join(allocator, &.{ app_dir, folder_name, zs_folder }),
        };
    }

    /// `data` compressed with `dictionary` (null: none), as `zs.compress` makes it: from the cache when it holds
    /// this file, else compressed and stored. Allocated with `allocator`.
    /// Safe to call from several threads at once.
    pub fn compress(self: *Self, allocator: Allocator, zs: *zstd.Context, data: []const u8, dictionary: ?[]const u8) zstd.ZstdError![]u8 {
        if (data.len < min_size or self.isOff()) return zs.compress(allocator, data, dictionary);

        const key = keyOf(data, dictionary);
        const hex = hash.hexLower(key);
        const name = std.fmt.allocPrint(allocator, "{s}.zs", .{hex}) catch return error.OutOfMemory;
        defer allocator.free(name);
        const path = fsmod.join(allocator, &.{ self.dir, name }) catch return error.OutOfMemory;
        defer allocator.free(path);

        if (self.fs.readAll(allocator, path)) |cached| {
            if (try matches(allocator, zs, cached, data, dictionary)) {
                self.count(&self.hits);
                // why: trimming deletes the files used longest ago, so a file in use is marked as just used
                self.fs.touch(path) catch {};
                return cached;
            }
            allocator.free(cached);
            self.count(&self.replaced);
            // deleted, so the new copy can take its name (store never replaces a file that's there)
            self.removeDamaged(path);
        } else |_| {}

        self.count(&self.misses);
        const out = try zs.compress(allocator, data, dictionary);
        self.store(allocator, path, out);
        return out;
    }

    fn isOff(self: *Self) bool {
        self.lock.lockUncancelable(self.fs.io);
        defer self.lock.unlock(self.fs.io);
        return self.warning != null;
    }

    fn count(self: *Self, counter: *usize) void {
        self.lock.lockUncancelable(self.fs.io);
        defer self.lock.unlock(self.fs.io);
        counter.* += 1;
    }

    fn removeDamaged(self: *Self, path: []const u8) void {
        self.lock.lockUncancelable(self.fs.io);
        defer self.lock.unlock(self.fs.io);
        self.fs.deleteFile(path) catch {};
    }

    fn store(self: *Self, allocator: Allocator, path: []const u8, compressed: []const u8) void {
        self.lock.lockUncancelable(self.fs.io);
        defer self.lock.unlock(self.fs.io);
        if (self.warning != null) return;
        // why: two files of one seed can be the same (the US and EU English text): the first one stored is enough,
        // and replacing it could fail while another thread is reading it
        if (self.fs.isFile(path)) return;
        if (!self.made_dir) {
            self.fs.makePath(self.dir) catch |err| {
                self.setWarning("couldn't create", err);
                return;
            };
            self.made_dir = true;
        }
        // through a temporary file: a seed stopped halfway never leaves half a file under a real name
        self.fs.writeAtomic(allocator, path, compressed) catch |err| {
            self.setWarning("couldn't write to", err);
        };
    }

    /// Keeps why the cache stopped (in the cache's own buffer: the step's memory is cleared after each file).
    fn setWarning(self: *Self, what: []const u8, err: fsmod.FsError) void {
        self.warning = std.fmt.bufPrint(&self.warning_buffer, "{s} {s} ({s})", .{ what, self.dir, @errorName(err) }) catch "the cache folder couldn't be used";
    }

    /// Deletes the files used longest ago while the cache is over `size_limit`, and any temporary file left by a
    /// seed that was stopped. Only worth calling after files were stored (`misses > 0`).
    pub fn trim(self: *Self, allocator: Allocator) void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const names = self.fs.listDir(a, self.dir) catch return;
        const Entry = struct { path: []const u8, size: u64, mtime: i96 };
        var entries: std.ArrayList(Entry) = .empty;
        var total: u64 = 0;
        for (names) |n| {
            const p = fsmod.join(a, &.{ self.dir, n }) catch return;
            if (std.mem.endsWith(u8, n, ".tmp")) {
                self.fs.deleteFile(p) catch {};
                continue;
            }
            if (!std.mem.endsWith(u8, n, ".zs")) continue;
            const size = self.fs.fileSize(p) orelse continue;
            const mtime = self.fs.mtime(p) orelse continue;
            entries.append(a, Entry{ .path = p, .size = size, .mtime = mtime }) catch return;
            total += size;
        }
        if (total <= size_limit) return;

        const lessByTime = struct {
            fn less(_: void, x: Entry, y: Entry) bool {
                return x.mtime < y.mtime;
            }
        }.less;
        std.mem.sort(Entry, entries.items, {}, lessByTime);
        const target = size_limit / 4 * 3;
        for (entries.items) |e| {
            if (total <= target) break;
            self.fs.deleteFile(e.path) catch continue;
            total -= e.size;
        }
    }
};

/// What a compressed file is named by: everything that decides its bytes. `zs.compress` gives the same output for
/// the same data, level, dictionary and library version, so equal keys mean an equal file.
fn keyOf(data: []const u8, dictionary: ?[]const u8) [32]u8 {
    var h = Sha256.init(.{});
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "goggles-zs-cache {s}|level {d}|zstd {d}|dict ", .{ key_version, zstd.level, zstd.libraryVersion() }) catch unreachable;
    h.update(head);
    // why: the length goes first, so a dictionary name can never run into the data and make two inputs look alike
    var len_buf: [8]u8 = undefined;
    const dict_name = dictionary orelse "";
    std.mem.writeInt(u64, &len_buf, dict_name.len, .little);
    h.update(&len_buf);
    h.update(dict_name);
    h.update(if (dictionary == null) "\x00" else "\x01");
    std.mem.writeInt(u64, &len_buf, data.len, .little);
    h.update(&len_buf);
    h.update(data);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Does `cached` decompress to exactly `data`, with the same dictionary? (Decompressing takes a few milliseconds,
/// far less than compressing at level 16.)
fn matches(allocator: Allocator, zs: *zstd.Context, cached: []const u8, data: []const u8, dictionary: ?[]const u8) error{OutOfMemory}!bool {
    const back = zs.decompress(allocator, cached) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false, // damaged, or made with a dictionary this game doesn't have
    };
    defer allocator.free(back.data);
    const same_dictionary = if (dictionary) |d|
        (if (back.dictionary) |b| std.mem.eql(u8, d, b) else false)
    else
        back.dictionary == null;
    return same_dictionary and std.mem.eql(u8, back.data, data);
}

test "keyOf tells the dictionary and the data apart" {
    const a = keyOf("abc", null);
    const b = keyOf("abc", "");
    const c = keyOf("abc", "zs.zsdic");
    const d = keyOf("abcd", "zs.zsdic");
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &b, &c));
    try std.testing.expect(!std.mem.eql(u8, &c, &d));
    const c2 = keyOf("abc", "zs.zsdic");
    try std.testing.expectEqualSlices(u8, &c, &c2);
}
