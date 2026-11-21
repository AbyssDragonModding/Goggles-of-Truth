//! What the program needs to know about where it runs: the environment variables, the user's folders and the
//! program's own folder. Passed explicitly to the code that looks for Longshot, emulator saves and the settings file.

const std = @import("std");
const builtin = @import("builtin");
const fsmod = @import("../core/fs.zig");
const Allocator = std.mem.Allocator;

const Env = @This();

environ: *const std.process.Environ.Map,
fs: fsmod.Fs,
/// the folder holding the executable (user_settings.toml and save_backups go here)
app_dir: []const u8,

pub fn get(self: *const Env, name: []const u8) ?[]const u8 {
    const v = self.environ.get(name) orelse return null;
    return if (v.len > 0) v else null;
}

/// The user's home folder.
pub fn home(self: *const Env) []const u8 {
    if (builtin.os.tag == .windows) {
        if (self.get("USERPROFILE")) |h| return h;
    }
    return self.get("HOME") orelse ".";
}

/// %LOCALAPPDATA% (Windows), or the home's AppData\Local.
pub fn localAppData(self: *const Env, allocator: Allocator) error{OutOfMemory}![]const u8 {
    if (self.get("LOCALAPPDATA")) |p| return allocator.dupe(u8, p);
    return fsmod.join(allocator, &.{ self.home(), "AppData", "Local" });
}

/// %APPDATA% (Windows), or the home's AppData\Roaming.
pub fn roamingAppData(self: *const Env, allocator: Allocator) error{OutOfMemory}![]const u8 {
    if (self.get("APPDATA")) |p| return allocator.dupe(u8, p);
    return fsmod.join(allocator, &.{ self.home(), "AppData", "Roaming" });
}

/// $XDG_DATA_HOME, or ~/.local/share.
pub fn xdgData(self: *const Env, allocator: Allocator) error{OutOfMemory}![]const u8 {
    if (self.get("XDG_DATA_HOME")) |p| return allocator.dupe(u8, p);
    return fsmod.join(allocator, &.{ self.home(), ".local", "share" });
}

/// $XDG_CONFIG_HOME, or ~/.config.
pub fn xdgConfig(self: *const Env, allocator: Allocator) error{OutOfMemory}![]const u8 {
    if (self.get("XDG_CONFIG_HOME")) |p| return allocator.dupe(u8, p);
    return fsmod.join(allocator, &.{ self.home(), ".config" });
}
