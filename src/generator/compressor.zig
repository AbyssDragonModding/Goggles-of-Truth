//! Compressing the mod's files on several threads.
//!
//! Compressing the patched files again (zstd level 16) is most of a seed's time, and each file is compressed on its
//! own, so the files are shared out over worker threads: each takes the next file not yet taken until none is left.
//! Every file still comes out exactly as it would on one thread (zstd's output doesn't depend on which thread or in
//! what order), and the caller writes them in its own fixed order afterwards, so a seed is byte for byte the same
//! whatever the number of threads.
//!
//! What may be shared between the threads: the zstd Context (its dictionaries are only read once `prepare` has
//! built the compression dictionaries; each compression makes its own zstd context), the file cache (it has a lock),
//! and the allocator, which must be thread-safe (the program's gpa is; an arena is not).

const std = @import("std");
const zstd = @import("../formats/zstd.zig");
const filecache = @import("filecache.zig");
const threads = @import("../core/threads.zig");
const Allocator = std.mem.Allocator;

/// One file to compress. `out` (allocated with the compressor's allocator) or `failure` is set once it's done.
pub const Job = struct {
    data: []const u8,
    dictionary: ?[]const u8,
    out: ?[]u8 = null,
    failure: ?zstd.ZstdError = null,
};

pub const Compressor = struct {
    /// thread-safe: the outputs are allocated from the worker threads
    gpa: Allocator,
    zs: *zstd.Context,
    cache: ?*filecache.FileCache,
    jobs: []Job,
    /// the index of the next job no thread has taken yet
    next: std.atomic.Value(usize) = .init(0),

    const Self = @This();

    /// Compresses every job (through the cache when there is one). Uses about 75% of the CPU cores
    /// (threads.targetThreadCount, AGENTS.md), never more threads than jobs; with one thread, or if no thread can be
    /// started, all of it runs on this one. Each working thread holds a level-16 zstd context (a few dozen MB).
    pub fn run(gpa: Allocator, zs: *zstd.Context, cache: ?*filecache.FileCache, jobs: []Job) zstd.ZstdError!void {
        // why: a compression dictionary is built on first use, which two threads must not do at the same time
        for (jobs) |j| try zs.prepare(j.dictionary);

        var self = Self{ .gpa = gpa, .zs = zs, .cache = cache, .jobs = jobs };
        const wanted_thread_count = @min(threads.targetThreadCount(), jobs.len);

        // this thread works too, so one fewer is started; without memory for the handles it all runs here
        const extra_thread_count = if (wanted_thread_count > 0) wanted_thread_count - 1 else 0;
        var no_worker_threads: [0]std.Thread = .{};
        const worker_threads: []std.Thread = gpa.alloc(std.Thread, extra_thread_count) catch no_worker_threads[0..];
        // freeing the empty fallback is a no-op (Allocator.free returns early for zero length)
        defer gpa.free(worker_threads);
        var started: usize = 0;
        while (started < worker_threads.len) : (started += 1) {
            worker_threads[started] = std.Thread.spawn(.{}, work, .{&self}) catch break;
        }
        work(&self);
        for (worker_threads[0..started]) |worker_thread| worker_thread.join();
    }

    fn work(self: *Self) void {
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.jobs.len) return;
            const j = &self.jobs[i];
            const result = if (self.cache) |c|
                c.compress(self.gpa, self.zs, j.data, j.dictionary)
            else
                self.zs.compress(self.gpa, j.data, j.dictionary);
            if (result) |bytes| {
                j.out = bytes;
            } else |err| {
                j.failure = err;
            }
        }
    }
};

test "threads give the same bytes as one" {
    const gpa = std.testing.allocator;
    // a zstd Context without game dictionaries: every job is plain zstd
    var zs = zstd.Context{ .allocator = gpa, .dictionaries = .empty };
    defer zs.deinit();

    var inputs: [12][]u8 = undefined;
    var jobs: [12]Job = undefined;
    for (&inputs, &jobs, 0..) |*input, *j, n| {
        input.* = try gpa.alloc(u8, 20000 + n * 3000);
        for (input.*, 0..) |*b, k| b.* = @truncate(k * 7 + n + k / 13);
        j.* = Job{ .data = input.*, .dictionary = null };
    }
    defer for (inputs) |input| gpa.free(input);

    try Compressor.run(gpa, &zs, null, &jobs);
    for (jobs) |j| {
        defer gpa.free(j.out.?);
        const one = try zs.compress(gpa, j.data, null);
        defer gpa.free(one);
        try std.testing.expectEqualSlices(u8, one, j.out.?);
    }
}
