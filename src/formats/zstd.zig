//! zstd with the game's dictionaries (Pack/ZsDic.pack.zs), over the vendored C library (vendor/zstd).
//!
//! Almost every file of the romfs ends in .zs: a zstd frame made with one of the dictionaries in ZsDic.pack.zs
//! (a SARC of .zsdic files). The frame header names the dictionary by its ID, so decompressing looks it up; writing
//! a patched file uses the dictionary the original was made with (its name is kept with the file).

const std = @import("std");
const sarc = @import("sarc.zig");

pub const ZstdError = error{
    InvalidData,
    UnknownDictionary,
    CompressFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------------------------------- the C API
// Declared by hand (the few functions used), so no C header translation is needed at build time.
const ZSTD_DCtx = opaque {};
const ZSTD_CCtx = opaque {};
const ZSTD_DDict = opaque {};
const ZSTD_CDict = opaque {};

const ZSTD_inBuffer = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const ZSTD_outBuffer = extern struct { dst: ?*anyopaque, size: usize, pos: usize };

extern fn ZSTD_createDCtx() ?*ZSTD_DCtx;
extern fn ZSTD_freeDCtx(dctx: ?*ZSTD_DCtx) usize;
extern fn ZSTD_createCCtx() ?*ZSTD_CCtx;
extern fn ZSTD_freeCCtx(cctx: ?*ZSTD_CCtx) usize;
extern fn ZSTD_createDDict(dict: ?*const anyopaque, size: usize) ?*ZSTD_DDict;
extern fn ZSTD_freeDDict(ddict: ?*ZSTD_DDict) usize;
extern fn ZSTD_createCDict(dict: ?*const anyopaque, size: usize, level: c_int) ?*ZSTD_CDict;
extern fn ZSTD_freeCDict(cdict: ?*ZSTD_CDict) usize;
extern fn ZSTD_getDictID_fromDict(dict: ?*const anyopaque, size: usize) c_uint;
extern fn ZSTD_getDictID_fromFrame(src: ?*const anyopaque, size: usize) c_uint;
extern fn ZSTD_getFrameContentSize(src: ?*const anyopaque, size: usize) c_ulonglong;
extern fn ZSTD_DCtx_reset(dctx: ?*ZSTD_DCtx, reset: c_int) usize;
extern fn ZSTD_DCtx_refDDict(dctx: ?*ZSTD_DCtx, ddict: ?*const ZSTD_DDict) usize;
extern fn ZSTD_decompressStream(dctx: ?*ZSTD_DCtx, output: *ZSTD_outBuffer, input: *ZSTD_inBuffer) usize;
extern fn ZSTD_compressBound(size: usize) usize;
extern fn ZSTD_compressCCtx(cctx: ?*ZSTD_CCtx, dst: ?*anyopaque, cap: usize, src: ?*const anyopaque, size: usize, level: c_int) usize;
extern fn ZSTD_compress_usingCDict(cctx: ?*ZSTD_CCtx, dst: ?*anyopaque, cap: usize, src: ?*const anyopaque, size: usize, cdict: ?*const ZSTD_CDict) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_versionNumber() c_uint;

/// The zstd library's version (1.5.7 is 10507). A newer library may compress the same data differently, so the
/// file cache keys on it.
pub fn libraryVersion() u32 {
    return ZSTD_versionNumber();
}

const content_size_unknown: c_ulonglong = std.math.maxInt(c_ulonglong);
const content_size_error: c_ulonglong = std.math.maxInt(c_ulonglong) - 1;
const reset_session_only: c_int = 1;

/// The compression level of patched files (as the Python version wrote them).
pub const level: c_int = 16;

/// Decompresses one plain zstd stream (no dictionary), allocated with `allocator`.
pub fn decompressPlain(allocator: std.mem.Allocator, src: []const u8) ZstdError![]u8 {
    return decompressWith(allocator, src, null);
}

/// Compresses without a dictionary.
pub fn compressPlain(allocator: std.mem.Allocator, src: []const u8) ZstdError![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeCCtx(cctx);
    const out = allocator.alloc(u8, ZSTD_compressBound(src.len)) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    const n = ZSTD_compressCCtx(cctx, out.ptr, out.len, src.ptr, src.len, level);
    if (ZSTD_isError(n) != 0) return error.CompressFailed;
    return allocator.realloc(out, n) catch out[0..n];
}

/// Decompresses with a dictionary (or none). Streams, so frames without a content size work too.
fn decompressWith(allocator: std.mem.Allocator, src: []const u8, ddict: ?*ZSTD_DDict) ZstdError![]u8 {
    const dctx = ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeDCtx(dctx);
    if (ddict) |d| {
        if (ZSTD_isError(ZSTD_DCtx_refDDict(dctx, d)) != 0) return error.InvalidData;
    }

    const size_hint = ZSTD_getFrameContentSize(src.ptr, src.len);
    if (size_hint == content_size_error) return error.InvalidData;
    var capacity: usize = if (size_hint == content_size_unknown) @max(src.len * 4, 4096) else @intCast(size_hint);
    if (capacity == 0) capacity = 1;

    var out = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var input = ZSTD_inBuffer{ .src = src.ptr, .size = src.len, .pos = 0 };
    var written: usize = 0;
    while (true) {
        var output = ZSTD_outBuffer{ .dst = out.ptr + written, .size = out.len - written, .pos = 0 };
        const ret = ZSTD_decompressStream(dctx, &output, &input);
        if (ZSTD_isError(ret) != 0) return error.InvalidData;
        written += output.pos;
        if (ret == 0 and input.pos == input.size) break; // every frame finished and all input used
        if (written == out.len) {
            out = allocator.realloc(out, out.len * 2) catch return error.OutOfMemory;
        } else if (input.pos == input.size and output.pos == 0) {
            return error.InvalidData; // truncated frame: no input left and nothing more comes out
        }
    }
    return allocator.realloc(out, written) catch out[0..written];
}

/// One dictionary of ZsDic.pack.zs.
const Dictionary = struct {
    name: []const u8,
    id: u32,
    data: []const u8,
    ddict: *ZSTD_DDict,
    cdict: ?*ZSTD_CDict, // made on first use: building a compression dictionary is slow
};

/// The game's dictionaries, loaded from the romfs.
pub const Context = struct {
    allocator: std.mem.Allocator,
    dictionaries: std.ArrayList(Dictionary),

    const Self = @This();

    /// `zsdic_pack`: the bytes of Pack/ZsDic.pack.zs (compressed, as read from the romfs).
    pub fn init(allocator: std.mem.Allocator, zsdic_pack: []const u8) ZstdError!Self {
        var self = Self{ .allocator = allocator, .dictionaries = .empty };
        errdefer self.deinit();

        const archive = try decompressPlain(allocator, zsdic_pack);
        defer allocator.free(archive);
        var entries = sarc.list(allocator, archive) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidData,
        };
        defer entries.deinit(allocator);

        for (entries.items) |entry| {
            const name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            errdefer allocator.free(name);
            const data = allocator.dupe(u8, entry.data) catch return error.OutOfMemory;
            errdefer allocator.free(data);
            const ddict = ZSTD_createDDict(data.ptr, data.len) orelse return error.InvalidData;
            const id: u32 = ZSTD_getDictID_fromDict(data.ptr, data.len);
            self.dictionaries.append(allocator, Dictionary{
                .name = name,
                .id = id,
                .data = data,
                .ddict = ddict,
                .cdict = null,
            }) catch {
                _ = ZSTD_freeDDict(ddict);
                return error.OutOfMemory;
            };
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.dictionaries.items) |d| {
            _ = ZSTD_freeDDict(d.ddict);
            if (d.cdict) |c| _ = ZSTD_freeCDict(c);
            self.allocator.free(d.name);
            self.allocator.free(d.data);
        }
        self.dictionaries.deinit(self.allocator);
    }

    fn byId(self: *Self, id: u32) ?*Dictionary {
        for (self.dictionaries.items) |*d| {
            if (d.id == id) return d;
        }
        return null;
    }

    fn byName(self: *Self, name: []const u8) ?*Dictionary {
        for (self.dictionaries.items) |*d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub const Decompressed = struct {
        data: []u8,
        /// The name of the dictionary the frame was made with (owned by the Context), or null for none.
        dictionary: ?[]const u8,
    };

    /// Decompresses a .zs file, with the dictionary its frame names.
    pub fn decompress(self: *Self, allocator: std.mem.Allocator, src: []const u8) ZstdError!Decompressed {
        const id: u32 = ZSTD_getDictID_fromFrame(src.ptr, src.len);
        if (id == 0) {
            return Decompressed{ .data = try decompressPlain(allocator, src), .dictionary = null };
        }
        const dict = self.byId(id) orelse return error.UnknownDictionary;
        return Decompressed{ .data = try decompressWith(allocator, src, dict.ddict), .dictionary = dict.name };
    }

    /// Builds the compression dictionary for `dictionary` now (null: none, nothing to do). Compressing from several
    /// threads at once is safe once every dictionary they use is prepared: a prepared one is only read (zstd allows
    /// one CDict to be used by many threads).
    pub fn prepare(self: *Self, dictionary: ?[]const u8) ZstdError!void {
        const name = dictionary orelse return;
        const dict = self.byName(name) orelse return error.UnknownDictionary;
        if (dict.cdict == null) dict.cdict = ZSTD_createCDict(dict.data.ptr, dict.data.len, level);
        if (dict.cdict == null) return error.OutOfMemory;
    }

    /// Compresses a patched file with the dictionary its original used (null: none).
    pub fn compress(self: *Self, allocator: std.mem.Allocator, data: []const u8, dictionary: ?[]const u8) ZstdError![]u8 {
        const name = dictionary orelse return compressPlain(allocator, data);
        const dict = self.byName(name) orelse return error.UnknownDictionary;

        // The compression dictionary is built once, on first use. Several threads compress at once only after
        // `prepare` has built every dictionary they use (compressor.zig), so this never runs on two threads at once.
        if (dict.cdict == null) dict.cdict = ZSTD_createCDict(dict.data.ptr, dict.data.len, level);
        const cdict = dict.cdict orelse return error.OutOfMemory;

        const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
        defer _ = ZSTD_freeCCtx(cctx);
        const out = allocator.alloc(u8, ZSTD_compressBound(data.len)) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        const n = ZSTD_compress_usingCDict(cctx, out.ptr, out.len, data.ptr, data.len, cdict);
        if (ZSTD_isError(n) != 0) return error.CompressFailed;
        return allocator.realloc(out, n) catch out[0..n];
    }
};

test "plain round trip" {
    const allocator = std.testing.allocator;
    const text = "the quick brown fox jumps over the lazy dog, the quick brown fox";
    const packed_bytes = try compressPlain(allocator, text);
    defer allocator.free(packed_bytes);
    const back = try decompressPlain(allocator, packed_bytes);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(text, back);
}
