//! Seeded random streams. Every random choice of a seed comes from one of these, seeded from the seed's text
//! (std.Random.DefaultPrng, the same on every platform), so a seed always comes out the same.

const std = @import("std");
const hash = @import("hash.zig");

pub const Rng = struct {
    prng: std.Random.DefaultPrng,

    const Self = @This();

    pub fn init(seed: u64) Self {
        return Self{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// A stream seeded from the SHA-256 of `text`.
    pub fn fromText(text: []const u8) Self {
        return init(hash.seedFromText(text));
    }

    pub fn random(self: *Self) std.Random {
        return self.prng.random();
    }

    /// A 64-bit number (to seed another stream).
    pub fn next(self: *Self) u64 {
        return self.prng.next();
    }

    /// A float in [0, 1).
    pub fn float(self: *Self) f64 {
        return self.random().float(f64);
    }

    /// A number in [0, n). `n` must be above 0.
    pub fn below(self: *Self, n: usize) usize {
        return self.random().uintLessThan(usize, n);
    }

    /// A number in [lo, hi] (both included).
    pub fn intRange(self: *Self, lo: i64, hi: i64) i64 {
        return self.random().intRangeAtMost(i64, lo, hi);
    }

    pub fn shuffle(self: *Self, comptime T: type, items: []T) void {
        self.random().shuffle(T, items);
    }

    /// An index into `weights`, each chosen with a chance proportional to its weight.
    pub fn weighted(self: *Self, weights: []const f64) usize {
        var total: f64 = 0;
        for (weights) |w| total += w;
        var r = self.float() * total;
        for (weights, 0..) |w, i| {
            if (r < w) return i;
            r -= w;
        }
        return weights.len - 1;
    }
};
