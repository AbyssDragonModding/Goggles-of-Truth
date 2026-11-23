//! How many threads the randomizer's parallel work uses.
//!
//! Agents.md: use about 75% of the CPU cores and leave about 25% free, so the computer stays responsive while a seed
//! is made. There is no fixed upper limit: a bigger computer gets more threads. Every parallel step asks here
//! instead of choosing its own number.

const std = @import("std");

/// The share of the CPU cores the randomizer's parallel work may use.
pub const core_share: f32 = 0.75;

/// About 75% of the CPU cores, at least 1. One core (or a count the system can't report) gives 1.
pub fn targetThreadCount() usize {
    const cpu_core_count: usize = std.Thread.getCpuCount() catch 1;
    return threadCountForCores(cpu_core_count);
}

/// The thread count for `cpu_core_count` cores: max(1, floor(cores * 0.75)). Kept apart from the core query so
/// the formula can be tested.
pub fn threadCountForCores(cpu_core_count: usize) usize {
    const share_of_cores: f32 = @as(f32, @floatFromInt(cpu_core_count)) * core_share;
    const whole_threads: usize = @intFromFloat(share_of_cores);
    return @max(1, whole_threads);
}

test "about 75% of the cores, at least one" {
    try std.testing.expectEqual(@as(usize, 1), threadCountForCores(0));
    try std.testing.expectEqual(@as(usize, 1), threadCountForCores(1));
    try std.testing.expectEqual(@as(usize, 1), threadCountForCores(2));
    try std.testing.expectEqual(@as(usize, 3), threadCountForCores(4));
    try std.testing.expectEqual(@as(usize, 6), threadCountForCores(8));
    try std.testing.expectEqual(@as(usize, 12), threadCountForCores(16));
    try std.testing.expectEqual(@as(usize, 48), threadCountForCores(64));
}
