//! ASTC 4x4 blocks (128 bits each): telling a fully transparent block apart, and writing a block of one colour, for
//! text drawn into a texture (the title screen's subtitle).
//!
//! From the ASTC specification (Khronos Data Format Specification, ASTC chapter), bits counted from the least
//! significant bit of byte 0:
//! - a void-extent block (one colour for the whole block) has bits 0..8 = 0x1FC; bit 9 clear means LDR, and its colour
//!   is four 16-bit UNORM values R, G, B, A at bits 64..127;
//! - extent coordinates all ones mean the colour has no extent (bits 12..63), and bits 10..11 are reserved and set.
//! Only these one-colour blocks are written: a 2-colour block with per-texel weights (mode 0x042, endpoint mode 12)
//! drawn as the subtitle didn't show in Longshot (test report, 0.8.4), and the game's own empty areas use void-extent
//! blocks, which every decoder reads.

const std = @import("std");

pub const block_size = 16;
pub const block_texels = 4;

const void_extent_marker: u128 = 0x1FC;
const void_extent_marker_mask: u128 = 0x1FF;
const void_extent_hdr_bit: u128 = 1 << 9;
/// bits 10..11 of a void-extent block are reserved and set
const void_extent_reserved_bits: u128 = 0b11 << 10;
/// the four 13-bit extent coordinates all ones: no extent
const void_extent_no_extent: u128 = ((1 << 52) - 1) << 12;

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

fn blockBits(block: *const [block_size]u8) u128 {
    return std.mem.readInt(u128, block, .little);
}

/// True for an LDR void-extent block whose alpha is zero: the whole 4x4 area is fully transparent.
pub fn isFullyTransparent(block: *const [block_size]u8) bool {
    const bits = blockBits(block);
    if (bits & void_extent_marker_mask != void_extent_marker) return false;
    if (bits & void_extent_hdr_bit != 0) return false;
    const alpha: u16 = @truncate(bits >> 112);
    return alpha == 0;
}

/// A void-extent block: the whole 4x4 area one colour (each channel 0..255, stored as 16-bit UNORM, value * 257).
/// No extent coordinates (all ones), as the game's own empty blocks.
pub fn solidBlock(color: Rgba) [block_size]u8 {
    var bits: u128 = void_extent_marker | void_extent_reserved_bits | void_extent_no_extent;
    const channels = [4]u8{ color.r, color.g, color.b, color.a };
    for (channels, 0..) |value, i| bits |= @as(u128, @as(u16, value) * 257) << @intCast(64 + 16 * i);
    var out: [block_size]u8 = undefined;
    std.mem.writeInt(u128, &out, bits, .little);
    return out;
}

/// The colour of a void-extent block (the high byte of each 16-bit channel), or null for any other block.
pub fn solidColor(block: *const [block_size]u8) ?Rgba {
    const bits = blockBits(block);
    if (bits & void_extent_marker_mask != void_extent_marker or bits & void_extent_hdr_bit != 0) return null;
    const channel = struct {
        fn of(b: u128, i: u7) u8 {
            return @truncate(b >> (64 + 16 * i + 8));
        }
    }.of;
    return .{ .r = channel(bits, 0), .g = channel(bits, 1), .b = channel(bits, 2), .a = channel(bits, 3) };
}

test "a solid block reads back as its colour and is recognised as transparent only at alpha 0" {
    const purple = Rgba{ .r = 176, .g = 92, .b = 255, .a = 255 };
    const block = solidBlock(purple);
    try std.testing.expectEqual(purple, solidColor(&block).?);
    try std.testing.expect(!isFullyTransparent(&block));
    const clear = solidBlock(.{ .r = 255, .g = 255, .b = 255, .a = 0 });
    try std.testing.expect(isFullyTransparent(&clear));
    // bit for bit the game's own empty block (the most common block of Logo_USEU_00): white, alpha 0, no extent
    try std.testing.expectEqual(@as(u128, 0x0000FFFF_FFFFFFFF_FFFFFFFF_FFFFFDFC), std.mem.readInt(u128, &clear, .little));
}

test "transparent void-extent blocks are recognised" {
    // void extent, LDR, no extent coordinates (all ones), colour RGBA16 = (0, 0, 0, 0)
    var bits: u128 = 0x1FC | (0b11 << 10);
    bits |= @as(u128, (1 << 52) - 1) << 12;
    var block: [16]u8 = undefined;
    std.mem.writeInt(u128, &block, bits, .little);
    try std.testing.expect(isFullyTransparent(&block));
    // the same with alpha 0xFFFF: opaque
    std.mem.writeInt(u128, &block, bits | (@as(u128, 0xFFFF) << 112), .little);
    try std.testing.expect(!isFullyTransparent(&block));
}
