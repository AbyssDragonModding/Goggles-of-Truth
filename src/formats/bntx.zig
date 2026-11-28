//! BNTX texture archives (UI/Layout2Archive/*.bntx.zs): finding one texture's image data and the place of each of its
//! blocks in it, so blocks can be rewritten in place.
//!
//! Read from the remake's Title archive (the layout's pictures): a "BNTX" file whose platform header ("Ounc", the
//! Switch 2) holds the texture count at 0x24 and the address of a table of BRTI (texture info) addresses at 0x28. Each
//! BRTI gives the texture's format, size, mip count, block height (the low 3 bits of its size-range word) and the
//! address of its mip offsets, which are absolute file offsets into the BRTD data block.
//!
//! Image data is block linear, as on the Switch: GOBs of 512 bytes (64 bytes x 8 rows), stacked `block height` GOBs
//! tall, row by row of such stacks. Inside a GOB the Switch 2 orders its 16-byte elements differently from the Switch:
//! element (x, y) of the GOB's 4 x 8 is at bits y0, y1, x0, y2, x1 of its index (lowest first), where the Switch has
//! y0, x0, y1, y2, x1. Found by trying every order on the title logo (Title Logo_USEU_00): this one gives the smoothest
//! picture (95.8% of neighbouring empty blocks alike, the Switch's 90.3%), and blocks written with the Switch's order
//! showed as broken letters (test report, 0.8.4). A compressed texture's "pixels" here are its 4x4 blocks (16 bytes
//! each for ASTC 4x4).
//! Only what the title-screen edit needs is supported: 2D textures, one array layer, mip level 0.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const Allocator = std.mem.Allocator;

pub const BntxError = error{InvalidData};

const file_magic = "BNTX";
const texture_info_magic = "BRTI";
const texture_count_offset = 0x24;
const texture_info_table_offset = 0x28;

/// BNTX format words (high byte: the type, low byte: the encoding): ASTC 4x4 is type 0x2d.
pub const format_astc_4x4_type: u32 = 0x2d;

/// One texture's level-0 image: where it is and how it is laid out.
pub const Texture = struct {
    name: []const u8,
    format: u32,
    width: u32,
    height: u32,
    /// GOBs per block (2^block_height_log2)
    block_height_gobs: u32,
    mip_count: u32,
    /// absolute offset of mip level 0 in the file
    data_offset: usize,
    data_size: usize,

    /// The texture's width and height in compression blocks (4x4 for ASTC 4x4).
    pub fn blocksWide(self: Texture) u32 {
        return (self.width + 3) / 4;
    }
    pub fn blocksHigh(self: Texture) u32 {
        return (self.height + 3) / 4;
    }

    /// The file offset of block (`block_x`, `block_y`) of a texture with 16-byte blocks.
    pub fn blockOffset(self: Texture, block_x: u32, block_y: u32) usize {
        return self.data_offset + blockLinearOffset(block_x, block_y, self.blocksWide(), self.block_height_gobs);
    }
};

/// The offset of element (`x`, `y`) in a block-linear image `width_elements` wide, of 16-byte elements, with blocks
/// `block_height_gobs` GOBs tall (the Switch 2's order inside a GOB, see above).
pub fn blockLinearOffset(x: u32, y: u32, width_elements: u32, block_height_gobs: u32) usize {
    const bytes_per_element = 16;
    const gob_width_bytes = 64;
    const gob_height_rows = 8;
    const gob_size = 512;
    const x_bytes: usize = @as(usize, x) * bytes_per_element;
    const width_in_gobs: usize = (@as(usize, width_elements) * bytes_per_element + gob_width_bytes - 1) / gob_width_bytes;
    const block_rows: usize = gob_height_rows * @as(usize, block_height_gobs);
    const yy: usize = y;
    const gob_address = (yy / block_rows) * gob_size * block_height_gobs * width_in_gobs +
        (x_bytes / gob_width_bytes) * gob_size * block_height_gobs +
        ((yy % block_rows) / gob_height_rows) * gob_size;
    const x_in_gob = (x_bytes % gob_width_bytes) / bytes_per_element; // 0..3
    const y_in_gob = yy % gob_height_rows; // 0..7
    const element_in_gob = (y_in_gob & 1) | ((y_in_gob >> 1) & 1) << 1 | (x_in_gob & 1) << 2 | (y_in_gob >> 2) << 3 | (x_in_gob >> 1) << 4;
    return gob_address + element_in_gob * bytes_per_element;
}

/// The texture named `name` in BNTX file `data`, or null when the file has none by that name.
pub fn findTexture(data: []const u8, name: []const u8) BntxError!?Texture {
    if (data.len < 0x40 or !std.mem.eql(u8, data[0..4], file_magic)) return error.InvalidData;
    const count = try bytes.u32At(data, texture_count_offset);
    const table = std.math.cast(usize, try bytes.u64At(data, texture_info_table_offset)) orelse return error.InvalidData;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const info = std.math.cast(usize, try bytes.u64At(data, table + i * 8)) orelse return error.InvalidData;
        if (!std.mem.eql(u8, try bytes.sliceAt(data, info, info + 4), texture_info_magic)) return error.InvalidData;
        const name_at = std.math.cast(usize, try bytes.u64At(data, info + 0x60)) orelse return error.InvalidData;
        const name_len = try bytes.u16At(data, name_at);
        const texture_name = try bytes.sliceAt(data, name_at + 2, name_at + 2 + name_len);
        if (!std.mem.eql(u8, texture_name, name)) continue;
        const mip_table = std.math.cast(usize, try bytes.u64At(data, info + 0x70)) orelse return error.InvalidData;
        const texture = Texture{
            .name = texture_name,
            .format = try bytes.u32At(data, info + 0x1C),
            .width = try bytes.u32At(data, info + 0x24),
            .height = try bytes.u32At(data, info + 0x28),
            .block_height_gobs = @as(u32, 1) << @intCast((try bytes.u32At(data, info + 0x34)) & 7),
            .mip_count = try bytes.u16At(data, info + 0x16),
            .data_offset = std.math.cast(usize, try bytes.u64At(data, mip_table)) orelse return error.InvalidData,
            .data_size = try bytes.u32At(data, info + 0x50),
        };
        if (texture.data_offset + texture.data_size > data.len) return error.InvalidData;
        return texture;
    }
    return null;
}

test "block linear offsets follow the Switch 2 GOB layout" {
    // inside the first GOB: y0 is bit 0 of the element index, y1 bit 1, x0 bit 2, y2 bit 3, x1 bit 4
    try std.testing.expectEqual(@as(usize, 0), blockLinearOffset(0, 0, 366, 16));
    try std.testing.expectEqual(@as(usize, 16), blockLinearOffset(0, 1, 366, 16));
    try std.testing.expectEqual(@as(usize, 32), blockLinearOffset(0, 2, 366, 16));
    try std.testing.expectEqual(@as(usize, 64), blockLinearOffset(1, 0, 366, 16));
    try std.testing.expectEqual(@as(usize, 128), blockLinearOffset(0, 4, 366, 16));
    try std.testing.expectEqual(@as(usize, 256), blockLinearOffset(2, 0, 366, 16));
    try std.testing.expectEqual(@as(usize, 496), blockLinearOffset(3, 7, 366, 16));
    // the next GOB down in the same block, then the next GOB column (a whole block of 16 GOBs further)
    try std.testing.expectEqual(@as(usize, 512), blockLinearOffset(0, 8, 366, 16));
    try std.testing.expectEqual(@as(usize, 512 * 16), blockLinearOffset(4, 0, 366, 16));
    // the next row of blocks: past all 92 GOB columns of 16 GOBs (the Title logo text: 366 blocks wide)
    try std.testing.expectEqual(@as(usize, 512 * 16 * 92), blockLinearOffset(0, 128, 366, 16));
}
