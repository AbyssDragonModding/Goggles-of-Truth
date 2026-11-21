//! NUP (NX Package) reader: a Zig port of a55uka/nup (https://github.com/a55uka/nup), MIT License,
//! Copyright (c) 2026 a55uka. Follows SPEC.md v1 and the library's format.py, read.py and access.py.
//!
//! A .nup holds one or more packages (base game, update, DLC), each with its own exefs and romfs folder tree.
//! Layout (all little-endian, reserved fields zero):
//!
//!   superblock  0x80   magic "NUP\x01", header size/version, TOC offset/size/SHA-256, blob offset, file size,
//!                      package count, flags, UUID, 32 reserved bytes
//!   TOC                header (0x30: "TOC\x01", counts, string pool offset/size), packages (0x40 each),
//!                      dirs (0x18 each), files (0x50 each), the children array (u32 node ids), the string pool
//!   blob               file extents (16-byte aligned), raw or zstd
//!
//! A child node id below dir_count is a folder (an index into dirs), else a file (id - dir_count). A folder's
//! children are sorted by their bytes, so a name is found by binary search.
//!
//! Reader conformance (SPEC §6.1): the superblock is validated, the TOC's SHA-256 is checked before anything in it
//! is trusted, every offset and size is bounds-checked, and unknown codecs and flags are refused. The file is read
//! on demand (positional reads), so a package of many gigabytes is never loaded whole.

const std = @import("std");
const bytes = @import("../core/bytes.zig");
const hash = @import("../core/hash.zig");
const zstd = @import("zstd.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ------------------------------------------------------------------------------------------------- format.py

pub const magic = "NUP\x01";
pub const toc_magic = "TOC\x01";
pub const header_size: usize = 0x80;
pub const package_record_size: usize = 0x40;
pub const dir_record_size: usize = 0x18;
pub const file_record_size: usize = 0x50;
pub const toc_header_size: usize = 0x30;
pub const extent_align: u64 = 16;
/// "no folder" (a package without exefs or romfs)
pub const no_dir: u32 = 0xFFFFFFFF;
pub const package_flag_standalone_update: u8 = 0x01;

pub const Codec = enum(u8) {
    raw = 0,
    zstd = 1,
};

pub const Kind = enum(u8) {
    base = 0,
    update = 1,
    addon = 2,
    addon_update = 3,
    system = 4,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .base => "base",
            .update => "update",
            .addon => "addon",
            .addon_update => "addon_update",
            .system => "system",
        };
    }
};

/// Meta TLV record types, numbered as SPEC.md §5 registers them. (The copy of format.py vendored with the Python
/// randomizer numbered them from 0 with `auto()`; it never read the meta block, so this follows the spec.)
/// Readers skip unknown types (0x0100-0x7FFF reserved, 0x8000-0xFFFF private to tools).
pub const Tlv = enum(u16) {
    npdm = 0x0001,
    nacp = 0x0002,
    icon = 0x0003,
    display_version = 0x0004,
    title_name = 0x0005,
    publisher = 0x0006,
    build_id = 0x0007,
    source_dump = 0x0008,
    localized_titles = 0x0009,
    localized_icons = 0x000A,
    _,
};

/// Malformed or nonconforming NUP data (fail closed), or a read that failed.
pub const NupError = error{
    /// A record or field could not be read (it runs past the data).
    InvalidData,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    Corrupt,
    TocChecksumMismatch,
    FileChecksumMismatch,
    UnknownCodec,
    UnknownFlags,
    OutOfBounds,
    ReadFailed,
    OutOfMemory,
};

pub const Superblock = struct {
    header_size: u16,
    header_version: u16,
    toc_offset: u64,
    toc_size: u64,
    toc_sha256: [32]u8,
    blob_offset: u64,
    file_size: u64,
    package_count: u32,
    flags: u32,
    uuid: [16]u8,
};

pub fn parseSuperblock(buf: []const u8) NupError!Superblock {
    if (buf.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, buf[0..3], magic[0..3])) return error.BadMagic;
    if (buf[3] != 1) return error.UnsupportedVersion;
    const sb = Superblock{
        .header_size = try bytes.u16At(buf, 4),
        .header_version = try bytes.u16At(buf, 6),
        .toc_offset = try bytes.u64At(buf, 8),
        .toc_size = try bytes.u64At(buf, 0x10),
        .toc_sha256 = buf[0x18..0x38].*,
        .blob_offset = try bytes.u64At(buf, 0x38),
        .file_size = try bytes.u64At(buf, 0x40),
        .package_count = try bytes.u32At(buf, 0x48),
        .flags = try bytes.u32At(buf, 0x4C),
        .uuid = buf[0x50..0x60].*,
    };
    if (sb.header_size < header_size) return error.Corrupt;
    for (buf[0x60..0x80]) |b| if (b != 0) return error.Corrupt; // reserved bytes not zero
    if (sb.flags != 0) return error.UnknownFlags;
    return sb;
}

// --------------------------------------------------------------------------------------------------- read.py

pub const PackageInfo = struct {
    index: usize,
    title_id: u64,
    kind: Kind,
    version: u32,
    flags: u8,
    root_dir: u32,
    exefs_dir: u32,
    romfs_dir: u32,
    meta_offset: u64,
    meta_size: u32,

    /// "major.minor.micro" of the version number, into `buffer`.
    pub fn versionString(self: PackageInfo, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ self.version >> 16, (self.version >> 8) & 0xFF, self.version & 0xFF }) catch "";
    }
};

pub const DirInfo = struct {
    name: []const u8,
    first_child: u32,
    child_count: u32,
};

pub const FileInfo = struct {
    name: []const u8,
    size: u64,
    sha256: [32]u8,
    extent_offset: u64,
    extent_size: u64,
    codec: Codec,
};

/// A child reference: a folder or a file, and its index in that array.
pub const NodeRef = struct {
    is_dir: bool,
    index: u32,
    name: []const u8,
};

pub const Reader = struct {
    allocator: Allocator,
    io: Io,
    file: Io.File,
    superblock: Superblock,
    /// the TOC bytes (names point into it)
    toc: []u8,
    packages: []PackageInfo,
    dirs: []DirInfo,
    files: []FileInfo,
    children: []u32,

    const Self = @This();

    /// Opens and validates a .nup. On any failure the file is closed again.
    pub fn open(allocator: Allocator, io: Io, path: []const u8) NupError!Self {
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.ReadFailed;
        errdefer file.close(io);

        var head: [header_size]u8 = undefined;
        const got = file.readPositionalAll(io, &head, 0) catch return error.ReadFailed;
        if (got < header_size) return error.Truncated;
        const sb = try parseSuperblock(&head);
        const real_size = (file.stat(io) catch return error.ReadFailed).size;
        if (sb.file_size != real_size) return error.Corrupt;
        if (sb.toc_offset < header_size) return error.Corrupt;
        if (sb.blob_offset < sb.toc_offset + sb.toc_size) return error.Corrupt; // blob region overlaps TOC
        if (sb.blob_offset % extent_align != 0) return error.Corrupt;
        if (sb.toc_offset + sb.toc_size > real_size) return error.OutOfBounds;

        const toc = allocator.alloc(u8, @intCast(sb.toc_size)) catch return error.OutOfMemory;
        errdefer allocator.free(toc);
        const toc_got = file.readPositionalAll(io, toc, sb.toc_offset) catch return error.ReadFailed;
        if (toc_got != toc.len) return error.Truncated;
        // why: nothing in the TOC is trusted before its checksum matches
        if (!std.mem.eql(u8, &hash.sha256(toc), &sb.toc_sha256)) return error.TocChecksumMismatch;

        var self = Self{
            .allocator = allocator,
            .io = io,
            .file = file,
            .superblock = sb,
            .toc = toc,
            .packages = &.{},
            .dirs = &.{},
            .files = &.{},
            .children = &.{},
        };
        errdefer self.freeTables();
        try self.parseToc();
        try self.checkBounds();
        return self;
    }

    fn freeTables(self: *Self) void {
        self.allocator.free(self.packages);
        self.allocator.free(self.dirs);
        self.allocator.free(self.files);
        self.allocator.free(self.children);
    }

    pub fn close(self: *Self) void {
        self.freeTables();
        self.allocator.free(self.toc);
        self.file.close(self.io);
    }

    fn poolString(pool: []const u8, off: u32, len: u32) NupError![]const u8 {
        if (@as(u64, off) + len > pool.len) return error.OutOfBounds;
        return pool[off .. off + len];
    }

    fn parseToc(self: *Self) NupError!void {
        const toc = self.toc;
        if (toc.len < toc_header_size or !std.mem.eql(u8, toc[0..4], toc_magic)) return error.BadMagic;
        const pkg_count = try bytes.u32At(toc, 4);
        const dir_count = try bytes.u64At(toc, 8);
        const file_count = try bytes.u64At(toc, 0x10);
        const pool_off = try bytes.u64At(toc, 0x18);
        const pool_size = try bytes.u64At(toc, 0x20);
        if (pkg_count != self.superblock.package_count) return error.Corrupt;
        const need = toc_header_size + pkg_count * package_record_size + dir_count * dir_record_size + file_count * file_record_size;
        if (toc.len < need) return error.Truncated;
        if (pool_off + pool_size > toc.len or pool_off < need) return error.OutOfBounds;
        const pool = toc[@intCast(pool_off)..@intCast(pool_off + pool_size)];

        var pos: usize = toc_header_size;
        self.packages = self.allocator.alloc(PackageInfo, pkg_count) catch return error.OutOfMemory;
        for (self.packages, 0..) |*p, i| {
            const kind_raw = toc[pos + 0x18];
            if (kind_raw > @intFromEnum(Kind.system)) return error.Corrupt;
            if (try bytes.u16At(toc, pos + 0x1A) != 0 or try bytes.u32At(toc, pos + 0x1C) != 0) return error.Corrupt;
            p.* = PackageInfo{
                .index = i,
                .title_id = try bytes.u64At(toc, pos),
                .root_dir = try bytes.u32At(toc, pos + 8),
                .exefs_dir = try bytes.u32At(toc, pos + 0xC),
                .romfs_dir = try bytes.u32At(toc, pos + 0x10),
                .version = try bytes.u32At(toc, pos + 0x14),
                .kind = @enumFromInt(kind_raw),
                .flags = toc[pos + 0x19],
                .meta_offset = try bytes.u64At(toc, pos + 0x20),
                .meta_size = try bytes.u32At(toc, pos + 0x28),
            };
            pos += package_record_size;
        }

        self.dirs = self.allocator.alloc(DirInfo, @intCast(dir_count)) catch return error.OutOfMemory;
        for (self.dirs) |*d| {
            d.* = DirInfo{
                .name = try poolString(pool, try bytes.u32At(toc, pos), try bytes.u32At(toc, pos + 4)),
                .first_child = try bytes.u32At(toc, pos + 8),
                .child_count = try bytes.u32At(toc, pos + 0xC),
            };
            pos += dir_record_size;
        }

        self.files = self.allocator.alloc(FileInfo, @intCast(file_count)) catch return error.OutOfMemory;
        for (self.files) |*f| {
            const codec_raw = toc[pos + 0x40];
            const codec_flags = toc[pos + 0x41];
            const size = try bytes.u64At(toc, pos + 8);
            const ext_off = try bytes.u64At(toc, pos + 0x10);
            const ext_size = try bytes.u64At(toc, pos + 0x18);
            if (codec_raw > @intFromEnum(Codec.zstd)) return error.UnknownCodec;
            if (codec_flags != 0) return error.UnknownFlags;
            if (size == 0 and (ext_off != 0 or ext_size != 0 or codec_raw != 0)) return error.Corrupt; // zero-size file with an extent
            if (size != 0 and ext_size == 0) return error.Corrupt; // nonzero size, empty extent
            f.* = FileInfo{
                .name = try poolString(pool, try bytes.u32At(toc, pos), try bytes.u32At(toc, pos + 4)),
                .size = size,
                .sha256 = toc[pos + 0x20 ..][0..32].*,
                .extent_offset = ext_off,
                .extent_size = ext_size,
                .codec = @enumFromInt(codec_raw),
            };
            pos += file_record_size;
        }

        // the children array fills the gap between the file records and the string pool
        const slot_end: usize = @intCast(pool_off);
        if ((slot_end - pos) % 4 != 0) return error.Corrupt;
        const count = (slot_end - pos) / 4;
        self.children = self.allocator.alloc(u32, count) catch return error.OutOfMemory;
        for (self.children, 0..) |*c, i| c.* = try bytes.u32At(toc, pos + i * 4);
    }

    fn checkBounds(self: *Self) NupError!void {
        const file_size = self.superblock.file_size;
        const blob_start = self.superblock.blob_offset;
        for (self.files) |f| {
            if (f.size == 0) continue;
            if (f.extent_offset < blob_start or f.extent_offset + f.extent_size > file_size) return error.OutOfBounds;
            if (f.extent_offset % extent_align != 0) return error.Corrupt;
        }
        var used: u64 = 0;
        for (self.dirs) |d| {
            if (@as(u64, d.first_child) + d.child_count > self.children.len) return error.OutOfBounds;
            used += d.child_count;
        }
        if (used != self.children.len) return error.Corrupt; // every child slot belongs to exactly one folder
        var has_base = false;
        for (self.packages) |p| {
            if (p.root_dir >= self.dirs.len) return error.OutOfBounds;
            if (p.exefs_dir != no_dir and p.exefs_dir >= self.dirs.len) return error.OutOfBounds;
            if (p.romfs_dir != no_dir and p.romfs_dir >= self.dirs.len) return error.OutOfBounds;
            if (p.meta_size != 0 and p.meta_offset + p.meta_size > file_size) return error.OutOfBounds;
            if (p.flags & ~package_flag_standalone_update != 0) return error.UnknownFlags;
            if (p.kind == .base) has_base = true;
        }
        // SPEC §3.1.2: an update needs a base in the same container, or the standalone_update flag
        for (self.packages) |p| {
            if (p.kind == .update and !has_base and (p.flags & package_flag_standalone_update) == 0) return error.Corrupt;
        }
    }

    pub fn dirCount(self: *const Self) usize {
        return self.dirs.len;
    }

    pub fn nodeName(self: *const Self, ref: NodeRef) []const u8 {
        return if (ref.is_dir) self.dirs[ref.index].name else self.files[ref.index].name;
    }

    /// Reads one file's bytes (decompressed), allocated with `allocator`. The size is checked; use
    /// `readFileVerified` to check the SHA-256 too.
    pub fn readFile(self: *const Self, allocator: Allocator, file_index: usize) NupError![]u8 {
        if (file_index >= self.files.len) return error.OutOfBounds;
        const f = self.files[file_index];
        if (f.size == 0) return allocator.alloc(u8, 0) catch return error.OutOfMemory;
        const extent = allocator.alloc(u8, @intCast(f.extent_size)) catch return error.OutOfMemory;
        const n = self.file.readPositionalAll(self.io, extent, f.extent_offset) catch {
            allocator.free(extent);
            return error.ReadFailed;
        };
        if (n != extent.len) {
            allocator.free(extent);
            return error.Truncated;
        }
        const data = switch (f.codec) {
            .raw => extent,
            .zstd => blk: {
                defer allocator.free(extent);
                break :blk zstd.decompressPlain(allocator, extent) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Corrupt,
                };
            },
        };
        if (data.len != f.size) {
            allocator.free(data);
            return error.Corrupt;
        }
        return data;
    }

    /// Like readFile, and checks the file against the SHA-256 stored in the package.
    pub fn readFileVerified(self: *const Self, allocator: Allocator, file_index: usize) NupError![]u8 {
        const data = try self.readFile(allocator, file_index);
        if (!std.mem.eql(u8, &hash.sha256(data), &self.files[file_index].sha256)) {
            allocator.free(data);
            return error.FileChecksumMismatch;
        }
        return data;
    }

    // ------------------------------------------------------------------------------------------- access.py

    /// The first package matching the filters given (null: any).
    pub fn findPackage(self: *const Self, kind: ?Kind, title_id: ?u64, version: ?u32) ?PackageInfo {
        for (self.packages) |p| {
            if (kind != null and p.kind != kind.?) continue;
            if (title_id != null and p.title_id != title_id.?) continue;
            if (version != null and p.version != version.?) continue;
            return p;
        }
        return null;
    }

    /// The children of folder `dir_index`, in their stored (sorted) order. Allocated with `allocator`.
    pub fn childrenOf(self: *const Self, allocator: Allocator, dir_index: u32) NupError![]NodeRef {
        if (dir_index >= self.dirs.len) return error.OutOfBounds;
        const d = self.dirs[dir_index];
        const out = allocator.alloc(NodeRef, d.child_count) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        for (out, 0..) |*ref, k| ref.* = try self.nodeRef(self.children[d.first_child + k]);
        return out;
    }

    /// The child with node id `id` (a folder below dir_count, else a file).
    pub fn nodeRef(self: *const Self, id: u32) NupError!NodeRef {
        if (id < self.dirs.len) return NodeRef{ .is_dir = true, .index = id, .name = self.dirs[id].name };
        const file_index = id - @as(u32, @intCast(self.dirs.len));
        if (file_index >= self.files.len) return error.OutOfBounds;
        return NodeRef{ .is_dir = false, .index = file_index, .name = self.files[file_index].name };
    }

    /// The child named `name` of folder `dir_index`, by binary search (children are sorted by their bytes).
    pub fn findChild(self: *const Self, dir_index: u32, name: []const u8) NupError!?NodeRef {
        if (dir_index >= self.dirs.len) return error.OutOfBounds;
        const d = self.dirs[dir_index];
        var lo: usize = 0;
        var hi: usize = d.child_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const ref = try self.nodeRef(self.children[d.first_child + mid]);
            switch (std.mem.order(u8, ref.name, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return ref,
            }
        }
        return null;
    }

    /// Walks a "/"-separated path from the package's root folder (empty parts are skipped).
    pub fn resolvePath(self: *const Self, pkg: PackageInfo, rel_path: []const u8) NupError!?NodeRef {
        var current = NodeRef{ .is_dir = true, .index = pkg.root_dir, .name = self.dirs[pkg.root_dir].name };
        var parts = std.mem.splitScalar(u8, rel_path, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (!current.is_dir) return null;
            current = (try self.findChild(current.index, part)) orelse return null;
        }
        return current;
    }

    /// The package's meta block (allocated with `allocator`), or an empty slice when it has none.
    pub fn metaBlock(self: *const Self, allocator: Allocator, pkg: PackageInfo) NupError![]u8 {
        const block = allocator.alloc(u8, pkg.meta_size) catch return error.OutOfMemory;
        if (pkg.meta_size == 0) return block;
        const n = self.file.readPositionalAll(self.io, block, pkg.meta_offset) catch {
            allocator.free(block);
            return error.ReadFailed;
        };
        if (n != block.len) {
            allocator.free(block);
            return error.Truncated;
        }
        return block;
    }
};

pub const MetaRecord = struct {
    type: Tlv,
    payload: []const u8,
};

/// Every (type, payload) record of a meta block, in order, duplicates kept (payloads point into `block`).
/// The block ends when the next record header would run past its end.
pub fn metaRecords(allocator: Allocator, block: []const u8) NupError![]MetaRecord {
    var out: std.ArrayList(MetaRecord) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos + 8 <= block.len) {
        const t = try bytes.u16At(block, pos);
        const size = try bytes.u32At(block, pos + 4);
        if (pos + 8 + size > block.len) return error.OutOfBounds;
        out.append(allocator, MetaRecord{ .type = @enumFromInt(t), .payload = block[pos + 8 .. pos + 8 + size] }) catch return error.OutOfMemory;
        pos += 8 + size;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// The payload of the last record of type `t`, or null.
pub fn metaValue(records: []const MetaRecord, t: Tlv) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (records) |r| {
        if (r.type == t) found = r.payload;
    }
    return found;
}

/// The 32-byte build ID (ModuleId of exefs/main), or null when the package has none.
pub fn buildId(records: []const MetaRecord) NupError!?[32]u8 {
    const payload = metaValue(records, .build_id) orelse return null;
    if (payload.len != 32) return error.Corrupt;
    return payload[0..32].*;
}

pub const LocalizedRecord = struct {
    /// BCP-47 tag, lowercase
    lang: []const u8,
    /// UTF-8 title (localized titles) or image bytes (localized icons)
    data: []const u8,
};

/// Decodes a localized titles / icons payload (SPEC §5.1): lang_len u8, lang, data_len u32, data, repeated.
pub fn decodeLocalized(allocator: Allocator, payload: []const u8) NupError![]LocalizedRecord {
    var out: std.ArrayList(LocalizedRecord) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < payload.len) {
        const lang_len = payload[pos];
        if (lang_len == 0) return error.Corrupt;
        const lang = try bytes.sliceAt(payload, pos + 1, pos + 1 + lang_len);
        const data_len = try bytes.u32At(payload, pos + 1 + lang_len);
        const data_at = pos + 1 + lang_len + 4;
        const data = try bytes.sliceAt(payload, data_at, data_at + data_len);
        out.append(allocator, LocalizedRecord{ .lang = lang, .data = data }) catch return error.OutOfMemory;
        pos = data_at + data_len;
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

test "superblock rejects bad magic" {
    var buf: [header_size]u8 = @splat(0);
    try std.testing.expectError(error.BadMagic, parseSuperblock(&buf));
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u16, buf[4..6], header_size, .little);
    _ = try parseSuperblock(&buf);
}
