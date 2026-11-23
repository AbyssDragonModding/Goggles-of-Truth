//! What differs between the operating systems the randomizer runs on (Windows, Linux, macOS), in one place.
//!
//! Agents.md: OS-specific code is kept inside the platform modules. The rest of the program asks here instead of
//! checking `builtin.os.tag` itself, so every difference between the systems can be found and changed in this file
//! (and in Env.zig, longshot.zig and saves.zig, which are platform modules too).

const std = @import("std");
const builtin = @import("builtin");

/// The operating systems the program is built for, as far as the program's behaviour differs between them.
pub const HostSystem = enum { windows, macos, other_unix };

pub const host_system: HostSystem = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .macos,
    else => .other_unix,
};

/// The separator the system writes between folder names: '\' on Windows, '/' elsewhere.
pub const native_path_separator: u8 = if (host_system == .windows) '\\' else '/';

/// Whether paths start with a drive letter ("D:") or a network share ("\\server") instead of a single "/".
pub const paths_have_drive_prefix: bool = host_system == .windows;

/// Whether the default file system ignores letter case in names (Windows' NTFS and macOS' APFS do; Linux' don't),
/// so "D:/Games" and "d:/games" are the same folder.
pub const file_names_ignore_case: bool = host_system == .windows or host_system == .macos;

/// Whether the window runs from a macOS application bundle (X.app/Contents/MacOS), whose own folder must not be
/// written to.
pub const runs_from_app_bundle: bool = host_system == .macos;

/// The program that opens a folder in the system's file manager.
pub const folder_opener_command: []const u8 = switch (host_system) {
    .windows => "explorer",
    .macos => "open",
    .other_unix => "xdg-open",
};

/// The file dialog pattern of program files (Launch Game's emulator Browse).
pub const program_file_patterns: [:0]const u8 = switch (host_system) {
    .windows => "*.exe",
    .macos => "*.app",
    .other_unix => "*",
};

test "the separator matches the drive prefix rule" {
    try std.testing.expectEqual(paths_have_drive_prefix, native_path_separator == '\\');
}
