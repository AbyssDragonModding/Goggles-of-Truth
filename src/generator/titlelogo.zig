//! Title Screen Subtitle (on by default): "Goggles of Truth Randomizer" in purple under the title screen's logo. New here (not in OotrR or
//! Clawshot); the idea comes from the LinkleConversion mod, whose title screen has a line of its own under the logo.
//!
//! The title layout (UI/Layout2Archive/Title...blarc, Title_00.buil) has no text box: the logo is pictures only. The
//! English logo (shield, sword and gold words) is the picture Logo_USEU_00, 1664 x 1280, shown 1.5 times its size
//! (pane P_Logo_00: 2496 x 1920 in the 3840 x 2160 layout). Two texture archives in UI/Layout2Archive hold it, with the
//! same pixels: Common...bntx.zs, loaded at start-up, whose copy the title screen shows, and Title...bntx.zs, whose copy
//! didn't show when changed alone (test reports, 0.8.4: a line there, then every empty block made purple, changed
//! nothing on screen while Longshot's log showed the file loaded). Both copies get the line, so the two stay alike.
//! The picture is ASTC 4x4 (sRGB). The line goes under the words at a place measured on the title screen
//! (english_logo_placement), one block per pixel of the line's picture (formats/astc.zig solidBlock: each block one
//! colour, purple with the pixel's coverage as its alpha, so the letters' edges are soft): one-colour blocks, as the
//! game's own empty areas are, because 2-colour blocks drawn first never showed. The archives keep their size, so no resource size changes. A logo picture of another size is left as it is,
//! with a warning. Other languages' logos (Japanese, Korean, Chinese) are left as they are.
//!
//! Cost: Common...bntx.zs is about 65 MB (244 MB unpacked), so every seed carries a copy of it. The line is the same
//! in every seed, so the file cache (filecache.zig) compresses it once and reuses it after that.
//!
//! The letters: title_subtitle.pgm, the line set in Hylia Serif Beta (a fan-made font after the Zelda titles' lettering,
//! by Omni Jacala, http://artsyomni.com/hyliaserif; THIRD_PARTY.md), already at the logo's block grid: 293 x 18
//! pixels, one byte of coverage (0..255) each, as a binary greyscale PGM ("P5"). Only this picture of the one line is
//! kept, not the font. It was made once, by drawing the line in the font 400 pixels high, cropping it to its ink and
//! scaling it to 18 pixels high (an area average).

const std = @import("std");
const bntx = @import("../formats/bntx.zig");
const astc = @import("../formats/astc.zig");
const patchset = @import("patchset.zig");
const Progress = @import("../core/Progress.zig");
const World = @import("../game/world.zig").World;
const PatchError = patchset.PatchError;

pub const subtitle = "Goggles of Truth Randomizer";
const texture_folder = "UI/Layout2Archive";
/// the archives holding the logo, Common's first (the one shown)
const texture_archive_prefixes = [_][]const u8{ "Common.", "Title." };
const texture_archive_suffix = ".bntx.zs";
const logo_texture = "Logo_USEU_00";

/// a bright purple, fully opaque
const subtitle_color = astc.Rgba{ .r = 176, .g = 92, .b = 255, .a = 255 };
/// Where the line goes in the logo's picture (416 x 320 blocks of 4 x 4 texels), measured on the title screen (test
/// report, 0.8.4; one block is about 1.55 screen pixels in a 1280-wide game window): "OCARINA OF TIME" ends at block
/// row 244, the shield's bottom at row 276, the sword's blade runs down to its tip at column 24, row 292, and the
/// menu's first line ("Continue") starts at row 316. The line, 18 block rows tall (293 wide), goes in rows 282..299, centred on
/// column 220 (the logo's middle is about 208), so it starts right of the blade and ends clear of the menu. Drawn first
/// in the empty strip at the very bottom (rows 304..319, one block per font pixel), it was too small to read and
/// touched "Continue".
pub const Placement = struct {
    /// the line's top block row
    top_block: u32,
    /// the block column the line is centred on
    center_block: u32,
};
const english_logo_placement = Placement{ .top_block = 282, .center_block = 220 };
/// the picture the placement was measured on
const english_logo_width = 1664;
const english_logo_height = 1280;

// ---------------------------------------------------------------------------------------- the line's picture
const subtitle_picture_file = @embedFile("title_subtitle.pgm");
/// coverage below this is left out: those blocks keep what the logo had there (the faint smoke under it)
const min_coverage = 24;

/// A greyscale picture: coverage[y * width + x], 0 (none) .. 255 (full ink).
pub const Coverage = struct { width: u32, height: u32, coverage: []const u8 };

/// Reads a binary PGM ("P5", maximum value 255, no comments).
fn readPgm(file: []const u8) error{InvalidData}!Coverage {
    var fields: [4][]const u8 = undefined;
    var at: usize = 0;
    for (&fields) |*field| {
        while (at < file.len and std.ascii.isWhitespace(file[at])) at += 1;
        const start = at;
        while (at < file.len and !std.ascii.isWhitespace(file[at])) at += 1;
        field.* = file[start..at];
    }
    at += 1; // the one whitespace byte after the maximum value
    if (!std.mem.eql(u8, fields[0], "P5") or !std.mem.eql(u8, fields[3], "255")) return error.InvalidData;
    const width = std.fmt.parseInt(u32, fields[1], 10) catch return error.InvalidData;
    const height = std.fmt.parseInt(u32, fields[2], 10) catch return error.InvalidData;
    if (at + @as(usize, width) * height != file.len) return error.InvalidData;
    return .{ .width = width, .height = height, .coverage = file[at..] };
}

pub fn subtitlePicture() Coverage {
    // why unreachable: the file is built into the program and a test reads it, so it can't be malformed here
    return readPgm(subtitle_picture_file) catch unreachable;
}

// ------------------------------------------------------------------------------------------- the drawing

pub const DrawError = error{NoRoom};

/// Draws `picture` into texture `texture` of BNTX file `data` (changed in place) at `placement`, one block per pixel.
/// Its inked blocks replace what was there (the faint smoke under the logo); the blocks around its letters are left as
/// they are. error.NoRoom (and `data` unchanged) when it doesn't fit in the texture there.
pub fn drawSubtitle(data: []u8, texture: bntx.Texture, picture: Coverage, placement: Placement) DrawError!void {
    if (picture.width / 2 > placement.center_block) return error.NoRoom;
    const left = placement.center_block - picture.width / 2;
    if (left + picture.width > texture.blocksWide() or placement.top_block + picture.height > texture.blocksHigh()) return error.NoRoom;
    for (0..picture.height) |y| for (0..picture.width) |x| {
        const coverage = picture.coverage[y * picture.width + x];
        if (coverage < min_coverage) continue;
        var color = subtitle_color;
        color.a = coverage;
        blockAt(data, texture, @intCast(left + x), @intCast(placement.top_block + y)).* = astc.solidBlock(color);
    };
}

fn blockAt(data: []u8, texture: bntx.Texture, bx: u32, by: u32) *[astc.block_size]u8 {
    const at = texture.blockOffset(bx, by);
    return data[at..][0..astc.block_size];
}

/// Every seed: the subtitle under the English title logo, in each archive holding it. An archive whose picture isn't as
/// expected is left as it is, with a warning.
pub fn patchTitleSubtitle(world: *World, patches: *patchset.PatchSet, progress: *Progress) PatchError!void {
    const a = patches.allocator;
    const names = world.files.listDir(a, texture_folder) catch {
        progress.log("warning: title screen: {s} not found; no subtitle", .{texture_folder});
        return;
    };
    var drawn: usize = 0;
    for (texture_archive_prefixes) |prefix| {
        var rel: ?[]const u8 = null;
        for (names) |n| {
            if (std.mem.startsWith(u8, n, prefix) and std.mem.endsWith(u8, n, texture_archive_suffix)) {
                rel = std.fmt.allocPrint(a, "{s}/{s}", .{ texture_folder, n }) catch return error.OutOfMemory;
            }
        }
        const archive = rel orelse {
            progress.log("warning: title screen: no {s}..{s} texture archive", .{ prefix, texture_archive_suffix });
            continue;
        };
        if (try drawInArchive(patches, archive, progress)) drawn += 1;
    }
    if (drawn > 0) progress.log("Title screen: \"{s}\" under the logo ({d} texture archives)", .{ subtitle, drawn });
}

/// The subtitle drawn into the logo of texture archive `archive`; false (with a warning) when it can't be.
fn drawInArchive(patches: *patchset.PatchSet, archive: []const u8, progress: *Progress) PatchError!bool {
    // its own scratch memory: Common's archive is 244 MB unpacked, freed once its patched copy is handed over
    var file_arena = patches.fileArena();
    defer file_arena.deinit();
    const a = file_arena.allocator();
    const orig = try patches.readInto(a, archive);
    const data = a.dupe(u8, orig.data) catch return error.OutOfMemory;
    const texture = (bntx.findTexture(data, logo_texture) catch null) orelse {
        progress.log("warning: title screen: {s} not found in {s}", .{ logo_texture, archive });
        return false;
    };
    // the placement was measured on this picture: another size would put the line somewhere else
    const as_measured = texture.width == english_logo_width and texture.height == english_logo_height;
    if (texture.format >> 8 != bntx.format_astc_4x4_type or texture.mip_count != 1 or !as_measured) {
        progress.log("warning: title screen: {s} in {s} is not the expected kind of picture", .{ logo_texture, archive });
        return false;
    }
    drawSubtitle(data, texture, subtitlePicture(), english_logo_placement) catch {
        progress.log("warning: title screen: the line doesn't fit under the logo in {s}", .{archive});
        return false;
    };
    try patches.emitZs(archive, orig, data);
    return true;
}

test "the line's picture is a valid PGM of the measured size" {
    const picture = try readPgm(subtitle_picture_file);
    try std.testing.expectEqual(@as(u32, 293), picture.width);
    try std.testing.expectEqual(@as(u32, 18), picture.height);
    var inked: usize = 0;
    for (picture.coverage) |c| inked += @intFromBool(c >= min_coverage);
    try std.testing.expect(inked > 1000);
    try std.testing.expectError(error.InvalidData, readPgm("P5\n2 2\n255\n\x00"));
}

test "the subtitle is drawn at its placement, inked blocks only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the English logo's size: 416 x 320 blocks (104 GOB columns of 16-byte blocks, 20 rows of 16-GOB blocks)
    const texture = bntx.Texture{ .name = "test", .format = 0x2d06, .width = 1664, .height = 1280, .block_height_gobs = 16, .mip_count = 1, .data_offset = 0, .data_size = 104 * 512 * 16 * 3 };
    const data = try a.alloc(u8, texture.data_size);
    @memset(data, 0);
    const clear = astc.solidBlock(.{ .r = 255, .g = 255, .b = 255, .a = 0 });
    for (0..320) |by| for (0..416) |bx| {
        blockAt(data, texture, @intCast(bx), @intCast(by)).* = clear;
    };
    try drawSubtitle(data, texture, subtitlePicture(), english_logo_placement);
    var written: usize = 0;
    var opaque_blocks: usize = 0;
    var min_x: usize = 416;
    var max_x: usize = 0;
    for (0..320) |by| for (0..416) |bx| {
        const block = blockAt(data, texture, @intCast(bx), @intCast(by));
        if (std.mem.eql(u8, &clear, block)) continue;
        written += 1;
        min_x = @min(min_x, bx);
        max_x = @max(max_x, bx);
        const color = astc.solidColor(block).?;
        try std.testing.expectEqual(subtitle_color.r, color.r);
        try std.testing.expect(color.a >= min_coverage);
        opaque_blocks += @intFromBool(color.a == 255);
        // only in the placement's rows
        try std.testing.expect(by >= 282 and by < 282 + 18);
    };
    try std.testing.expect(written > 1000 and opaque_blocks > 300);
    // right of the sword's blade (column 24 at its tip, about 65 at row 282) and inside the picture
    try std.testing.expect(min_x > 65 and max_x < 416);

    // a placement past the picture's edge: nothing is drawn
    try std.testing.expectError(error.NoRoom, drawSubtitle(data, texture, subtitlePicture(), .{ .top_block = 310, .center_block = 220 }));
}
