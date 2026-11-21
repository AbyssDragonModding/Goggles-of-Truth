//! The files a seed changes: each patch reads the latest version of a file and emits its new bytes.
//!
//! A file can be patched by several steps (the opening's event flow gets the new-game start, the start items and
//! the skipped movie): `read` returns an earlier step's output when there is one, else the game's original. At the
//! end every changed file is written to the mod folder, compressed again with its original dictionary, and the
//! resource size table grows by however much a file grew.

const std = @import("std");
const world_mod = @import("../game/world.zig");
const Allocator = std.mem.Allocator;

/// The failure modes of a patch. NotAsExpected: a game file isn't laid out as the patch expects (the Progress
/// failure message says what); the caller decides whether that stops the seed or only skips the setting.
pub const PatchError = error{
    NotAsExpected,
    InvalidData,
    GameFiles,
    OutOfMemory,
};

pub const Latest = struct {
    data: []const u8,
    /// the zstd dictionary the file was made with (null: not a .zs file, or no dictionary)
    dictionary: ?[]const u8,
};

pub const Patched = struct {
    data: []const u8,
    dictionary: ?[]const u8,
    /// false for the few files the game reads uncompressed (AINB logic modules, some .bgyml)
    compressed: bool,
};

/// Why two allocators: a patch step decompresses originals, parses them into trees and builds intermediate copies,
/// and none of that is needed once the step has emitted its files. Steps work in `allocator` (a scratch arena that
/// writePatches clears after each step), and `emit` copies the new bytes into `keep`, which lives until the mod is
/// written. Clearing the scratch arena between steps is what keeps memory use near the size of the largest step
/// instead of the sum of every step.
pub const PatchSet = struct {
    /// scratch for the current step: cleared by `endStep`, so nothing a later step needs may live here
    allocator: Allocator,
    /// the generation arena: the emitted files and anything that spans steps (PickupCloner state)
    keep: Allocator,
    scratch: *std.heap.ArenaAllocator,
    world: *world_mod.World,
    current: std.StringHashMap(Patched),
    /// size of each file's untouched original (for the size table)
    original_len: std.StringHashMap(usize),

    const Self = @This();

    /// The scratch arena's memory kept for the next step after `endStep` (more is given back to the system).
    const scratch_retain = 64 * 1024 * 1024;

    pub fn init(keep: Allocator, scratch: *std.heap.ArenaAllocator, world: *world_mod.World) Self {
        return Self{
            .allocator = scratch.allocator(),
            .keep = keep,
            .scratch = scratch,
            .world = world,
            .current = std.StringHashMap(Patched).init(keep),
            .original_len = std.StringHashMap(usize).init(keep),
        };
    }

    /// An arena for one file of a step that goes through many big files (a message archive per language): the
    /// caller deinits it once that file is emitted, so the step never holds every language's archive at once.
    pub fn fileArena(self: *Self) std.heap.ArenaAllocator {
        return std.heap.ArenaAllocator.init(self.scratch.child_allocator);
    }

    /// Like `read`, with an original's bytes allocated in `allocator` (a fileArena) instead of the step's scratch.
    pub fn readInto(self: *Self, allocator: Allocator, rel: []const u8) PatchError!Latest {
        if (self.current.get(rel)) |p| return Latest{ .data = p.data, .dictionary = p.dictionary };
        if (std.mem.endsWith(u8, rel, ".zs")) {
            const d = try self.world.readZs(allocator, rel);
            return Latest{ .data = d.data, .dictionary = d.dictionary };
        }
        const data = self.world.files.read(allocator, rel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GameFiles,
        };
        return Latest{ .data = data, .dictionary = null };
    }

    /// Frees everything the finished step allocated in `allocator`. Emitted files are not affected (they are in `keep`).
    pub fn endStep(self: *Self) void {
        _ = self.scratch.reset(.{ .retain_with_limit = scratch_retain });
    }

    /// The latest version of a file: an earlier patch's output if any, else the romfs original (decompressed, in the
    /// step's scratch memory: only valid until the step ends).
    pub fn read(self: *Self, rel: []const u8) PatchError!Latest {
        return self.readInto(self.allocator, rel);
    }

    /// Records a file's new bytes (compressed when written, unless `compressed` is false). `original` is the
    /// version the patch started from: the first time a file is emitted its length is kept for the size table.
    pub fn emit(self: *Self, rel: []const u8, original: []const u8, new: []const u8, dictionary: ?[]const u8, compressed: bool) PatchError!void {
        if (!self.original_len.contains(rel)) {
            const before = if (self.current.get(rel)) |p| p.data.len else original.len;
            const key = self.keep.dupe(u8, rel) catch return error.OutOfMemory;
            self.original_len.put(key, before) catch return error.OutOfMemory;
        }
        // `new` is usually in the step's scratch memory, which is cleared when the step ends: keep a copy. (A file
        // emitted again later leaves its older copy in `keep`; only a handful of files are patched more than once.)
        const data = self.keep.dupe(u8, new) catch return error.OutOfMemory;
        const slot = self.current.getOrPut(rel) catch return error.OutOfMemory;
        if (!slot.found_existing) slot.key_ptr.* = self.keep.dupe(u8, rel) catch return error.OutOfMemory;
        slot.value_ptr.* = Patched{ .data = data, .dictionary = dictionary, .compressed = compressed };
    }

    /// Like emit, for a .zs file (compressed with its dictionary).
    pub fn emitZs(self: *Self, rel: []const u8, original: Latest, new: []const u8) PatchError!void {
        return self.emit(rel, original.data, new, original.dictionary, true);
    }

    /// The changed files' paths, sorted.
    pub fn sortedPaths(self: *const Self, allocator: Allocator) error{OutOfMemory}![][]const u8 {
        const out = try allocator.alloc([]const u8, self.current.count());
        var it = self.current.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        std.mem.sort([]const u8, out, {}, lessString);
        return out;
    }
};

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
