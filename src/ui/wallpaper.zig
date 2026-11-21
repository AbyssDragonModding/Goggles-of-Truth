//! The window's wallpaper: a procedural night-sky gradient with soft glows, made at start-up (no image files shipped).
//! The glass materials blur and refract it, which gives the frosted look.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Glow = struct {
    x: f64,
    y: f64,
    radius: f64,
    color: [3]f64,
};

const glows = [_]Glow{
    .{ .x = 0.18, .y = 0.22, .radius = 0.42, .color = .{ 34, 168, 116 } }, // forest green
    .{ .x = 0.84, .y = 0.18, .radius = 0.34, .color = .{ 214, 168, 64 } }, // gold
    .{ .x = 0.62, .y = 0.92, .radius = 0.46, .color = .{ 58, 92, 210 } }, // lake blue
    .{ .x = 0.05, .y = 0.95, .radius = 0.30, .color = .{ 120, 60, 170 } }, // twilight purple
};

fn appendU32Big(out: *std.ArrayList(u8), allocator: Allocator, v: u32) !void {
    var raw: [4]u8 = undefined;
    std.mem.writeInt(u32, &raw, v, .big);
    try out.appendSlice(allocator, &raw);
}

fn chunk(out: *std.ArrayList(u8), allocator: Allocator, tag: *const [4]u8, data: []const u8) !void {
    try appendU32Big(out, allocator, @intCast(data.len));
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    try appendU32Big(out, allocator, crc.final());
}

/// The wallpaper as a PNG file (RGB, 8 bits). Allocated with `allocator`.
pub fn png(allocator: Allocator, width: u32, height: u32) ![]u8 {
    // the pixel rows, each starting with filter type 0
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(allocator);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        try rows.append(allocator, 0);
        const v = @as(f64, @floatFromInt(y)) / h;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const u = @as(f64, @floatFromInt(x)) / w;
            var c = [3]f64{ 10 + 8 * v, 16 + 10 * (1 - v), 30 + 22 * v };
            for (glows) |g| {
                const dx = u - g.x;
                const dy = (v - g.y) * h / w;
                const d = @sqrt(dx * dx + dy * dy) / g.radius;
                const k = std.math.pow(f64, @max(0.0, 1.0 - d), 2) * 0.6;
                for (&c, g.color) |*ch, gc| ch.* = ch.* * (1 - k) + gc * k;
            }
            for (c) |ch| try rows.append(allocator, @intFromFloat(@min(255.0, @max(0.0, @trunc(ch)))));
        }
    }

    // zlib stream of the rows
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 1 << 16);
    defer compressed.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var c = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);
    try c.writer.writeAll(rows.items);
    try c.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8; // bit depth
    header[9] = 2; // RGB
    header[10] = 0;
    header[11] = 0;
    header[12] = 0;
    try chunk(&out, allocator, "IHDR", &header);
    try chunk(&out, allocator, "IDAT", compressed.written());
    try chunk(&out, allocator, "IEND", "");
    return out.toOwnedSlice(allocator);
}
