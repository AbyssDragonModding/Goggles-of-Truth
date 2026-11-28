//! The launcher's splash screen as ELM's model, messages and update (src/launcher_window.zig has the view and the
//! program around them). Pure: no Raven and no files here, so `zig build test` checks it on every system.

const std = @import("std");
const FixedString = @import("string").FixedString;
const flow = @import("launcher_flow.zig");

/// a line of the splash screen (longer ones are cut: the window is small)
pub const SplashText = FixedString(320);

// ---------------------------------------------------------------------------------------------------- the model

pub const SplashModel = struct {
    phase: flow.Phase = .checking,
    status_line: SplashText = SplashText.fromTruncate("Starting..."),
    detail_line: SplashText = SplashText.init(),
    /// the progress bar, 0..1
    progress: f32 = 0,
    /// set once the flow is done: the splash screen closes after `close_after_seconds`
    finished: bool = false,
    close_after_seconds: f64 = 0,
    exit_code: u8 = 0,
};

pub const SplashMessage = union(enum) {
    phase_changed: struct { phase: flow.Phase, line: SplashText },
    download_advanced: struct { received: u64, total: u64 },
    flow_finished: struct { exit_code: u8, needs_attention: bool },
};

/// How long the last line stays readable before the splash screen closes.
pub const close_delay_normal_seconds: f64 = 0.8;
pub const close_delay_problem_seconds: f64 = 6.0;

// --------------------------------------------------------------------------------------------------- the update

/// The next model after `message` (pure: no Raven, no files).
pub fn updateSplash(model: SplashModel, message: SplashMessage) SplashModel {
    var next = model;
    switch (message) {
        .phase_changed => |change| {
            next.phase = change.phase;
            next.status_line = capitalized(change.line);
            switch (change.phase) {
                // the line names the ZIP and its size; the splash screen says it shorter, the size shows below
                .downloading => {
                    next.status_line = SplashText.fromTruncate("Downloading the new version...");
                    next.progress = 0;
                    next.detail_line = SplashText.init();
                },
                // the download is whole from here on
                .unpacking, .installing, .installed => {
                    next.progress = 1;
                    next.detail_line = SplashText.init();
                },
                .problem, .offline => next.detail_line = SplashText.fromTruncate("Your settings and seeds are safe."),
                .waiting_for_administrator => next.detail_line = SplashText.fromTruncate("Answer the system's prompt to continue."),
                .checking, .up_to_date, .starting, .finished => next.detail_line = SplashText.init(),
            }
        },
        .download_advanced => |bytes| {
            if (bytes.total > 0) {
                const fraction = @as(f64, @floatFromInt(bytes.received)) / @as(f64, @floatFromInt(bytes.total));
                next.progress = @floatCast(@min(1.0, fraction));
                next.detail_line = SplashText.fmt("{d:.1} MB of {d:.1} MB ({d}%)", .{
                    megabytes(bytes.received), megabytes(bytes.total), @as(u32, @intFromFloat(@round(fraction * 100.0))),
                }) catch SplashText.init();
            } else {
                next.detail_line = SplashText.fmt("{d:.1} MB", .{megabytes(bytes.received)}) catch SplashText.init();
            }
        },
        .flow_finished => |end| {
            next.finished = true;
            next.exit_code = end.exit_code;
            next.close_after_seconds = if (end.needs_attention) close_delay_problem_seconds else close_delay_normal_seconds;
        },
    }
    return next;
}

fn megabytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

/// `line` with its first letter in capitals (the updater's lines start in lower case: "downloading ...").
fn capitalized(line: SplashText) SplashText {
    var result = line;
    if (result.length() > 0) result.sliceMut()[0] = std.ascii.toUpper(result.sliceMut()[0]);
    return result;
}

test "the splash screen follows the flow" {
    var model = SplashModel{};
    model = updateSplash(model, .{ .phase_changed = .{ .phase = .downloading, .line = SplashText.fromTruncate("downloading the release...") } });
    try std.testing.expectEqualStrings("Downloading the new version...", model.status_line.slice());
    model = updateSplash(model, .{ .download_advanced = .{ .received = 1024 * 1024, .total = 4 * 1024 * 1024 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), model.progress, 0.001);
    try std.testing.expectEqualStrings("1.0 MB of 4.0 MB (25%)", model.detail_line.slice());
    model = updateSplash(model, .{ .phase_changed = .{ .phase = .installing, .line = SplashText.fromTruncate("installing...") } });
    try std.testing.expectEqualStrings("Installing...", model.status_line.slice());
    try std.testing.expectEqual(@as(f32, 1), model.progress);
    try std.testing.expect(!model.finished);
    model = updateSplash(model, .{ .flow_finished = .{ .exit_code = 0, .needs_attention = false } });
    try std.testing.expect(model.finished);
    try std.testing.expectEqual(close_delay_normal_seconds, model.close_after_seconds);
}

test "a problem stays readable" {
    const model = updateSplash(.{}, .{ .flow_finished = .{ .exit_code = 1, .needs_attention = true } });
    try std.testing.expectEqual(close_delay_problem_seconds, model.close_after_seconds);
    try std.testing.expectEqual(@as(u8, 1), model.exit_code);
}
