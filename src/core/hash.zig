//! The hashes the game files use (and a few the randomizer uses itself).

const std = @import("std");

/// MurmurHash3 x86 32-bit (seed 0): the key of every save-data flag in GameData/GameDataList and of AINB node names.
pub fn mm3(name: []const u8) u32 {
    const c1: u32 = 0xCC9E2D51;
    const c2: u32 = 0x1B873593;
    var h: u32 = 0;
    const block_count = name.len / 4;

    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        var k = std.mem.readInt(u32, name[i * 4 ..][0..4], .little);
        k *%= c1;
        k = std.math.rotl(u32, k, 15);
        k *%= c2;
        h ^= k;
        h = std.math.rotl(u32, h, 13);
        h = h *% 5 +% 0xE6546B64;
    }

    const tail = name[block_count * 4 ..];
    if (tail.len > 0) {
        var k: u32 = 0;
        for (tail, 0..) |byte, shift| k |= @as(u32, byte) << @intCast(8 * shift);
        k *%= c1;
        k = std.math.rotl(u32, k, 15);
        k *%= c2;
        h ^= k;
    }

    h ^= @truncate(name.len);
    h ^= h >> 16;
    h *%= 0x85EBCA6B;
    h ^= h >> 13;
    h *%= 0xC2B2AE35;
    h ^= h >> 16;
    return h;
}

/// The name hash of a SARC archive entry. Bytes above 0x7F count as negative (signed char), as in the game's tools.
pub fn sarcNameHash(name: []const u8, multiplier: u32) u32 {
    var h: u32 = 0;
    for (name) |byte| {
        const signed: i32 = if (byte < 0x80) byte else @as(i32, byte) - 0x100;
        h = h *% multiplier +% @as(u32, @bitCast(signed));
    }
    return h;
}

/// CRC-32 (zlib's), used by the resource size table for paths without a name entry.
pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// SHA-256 of `data`.
pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

/// Lower-case hexadecimal of a digest.
pub fn hexLower(digest: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xF];
    }
    return out;
}

/// A 64-bit seed for a PRNG stream, from the SHA-256 of a text (the first 8 bytes, little-endian).
/// Every random choice of a seed comes from a stream seeded this way, so a seed is the same on every platform.
pub fn seedFromText(text: []const u8) u64 {
    const digest = sha256(text);
    return std.mem.readInt(u64, digest[0..8], .little);
}

test "mm3 matches the game's flag hashes" {
    // the reference value is MurmurHash3_x86_32("hello", seed 0)
    try std.testing.expectEqual(@as(u32, 0x248BFA47), mm3("hello"));
    try std.testing.expectEqual(@as(u32, 0), mm3(""));
}
