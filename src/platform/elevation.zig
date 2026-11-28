//! Administrator rights for the launcher's updates (src/launcher.zig): whether the program folder can be written,
//! and running the launcher again with administrator rights when it can't (an install in C:\Program Files, /opt or
//! /Applications owned by another user).
//!
//! Each system has its own way, all kept in this file (Agents.md section 3: OS-specific code in a platform module):
//!   - Windows: ShellExecuteExW with the "runas" verb, which shows the system's administrator prompt (UAC), then
//!     waits for that copy of the launcher and reads its exit code.
//!   - macOS: osascript's `do shell script ... with administrator privileges`, the system's password prompt.
//!   - Linux: pkexec (polkit), the desktop's password prompt. Without pkexec, or when it can't ask (no polkit agent),
//!     the launcher tells the player the command to run with sudo instead.
//! The copy with administrator rights only installs (`--install-only`): the window is started by the launcher the
//! player started, so it doesn't run as administrator.

const std = @import("std");
const builtin = @import("builtin");
const String = @import("string").String;
const host = @import("host.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FolderWriteAccess = enum {
    /// the launcher can write the folder itself
    writable,
    /// the folder belongs to the system or another user: administrator rights can write it
    needs_administrator,
    /// the folder can't be written at all (a read-only disk or mount): administrator rights don't help
    read_only,
};

/// The file written (and deleted at once) to try the folder.
const write_probe_name = ".goggles-launcher-write-test";

/// Whether `folder` can be written, found by creating and deleting a small file in it.
pub fn folderWriteAccess(allocator: Allocator, io: Io, folder: []const u8) error{OutOfMemory}!FolderWriteAccess {
    var probe_path = try String.from(allocator, folder);
    defer probe_path.deinit();
    try probe_path.appendChar(std.fs.path.sep);
    try probe_path.append(write_probe_name);
    const cwd = Io.Dir.cwd();
    const probe = cwd.createFile(io, probe_path.slice(), .{}) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .needs_administrator,
        error.ReadOnlyFileSystem => .read_only,
        // anything else (a full disk, a vanished folder): asking for rights won't fix it, the install reports it
        else => .writable,
    };
    probe.close(io);
    cwd.deleteFile(io, probe_path.slice()) catch {};
    return .writable;
}

pub const ElevatedRunResult = union(enum) {
    /// the copy with administrator rights ran and exited with this code
    finished: u8,
    /// the player said no to the system's prompt (or closed it)
    declined,
    /// this system has no way the launcher can ask; the text says what the player can do instead
    unavailable: String,
};

/// Runs `program` with `arguments` and administrator rights, after the system's prompt, and waits for it.
/// The result's `unavailable` text belongs to the caller (`allocator`).
pub fn runWithAdministratorRights(allocator: Allocator, io: Io, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!ElevatedRunResult {
    return switch (host.host_system) {
        .windows => runElevatedWindows(allocator, program, arguments),
        .macos => runElevatedMacos(allocator, io, program, arguments),
        .other_unix => runElevatedLinux(allocator, io, program, arguments),
    };
}

/// What to type in a terminal to run the update with administrator rights by hand (Linux and macOS).
pub fn manualAdministratorCommand(allocator: Allocator, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!String {
    var command = try String.from(allocator, "sudo ");
    errdefer command.deinit();
    try appendShellQuoted(&command, program);
    for (arguments) |argument| {
        try command.appendChar(' ');
        try appendShellQuoted(&command, argument);
    }
    return command;
}

/// Appends `text` in single quotes for a POSIX shell ('it'\''s' for a quote inside).
fn appendShellQuoted(out: *String, text: []const u8) error{OutOfMemory}!void {
    try out.appendChar('\'');
    for (text) |character| {
        if (character == '\'') try out.append("'\\''") else try out.appendChar(character);
    }
    try out.appendChar('\'');
}

// --------------------------------------------------------------------------------------------------------- Windows

/// SHELLEXECUTEINFOW (shellapi.h).
const ShellExecuteInfoW = extern struct {
    cbSize: u32,
    fMask: u32,
    hwnd: ?*anyopaque,
    lpVerb: ?[*:0]const u16,
    lpFile: ?[*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShow: c_int,
    hInstApp: ?*anyopaque,
    lpIDList: ?*anyopaque,
    lpClass: ?[*:0]const u16,
    hkeyClass: ?*anyopaque,
    dwHotKey: u32,
    hIconOrMonitor: ?*anyopaque,
    hProcess: ?*anyopaque,
};

/// SEE_MASK_NOCLOSEPROCESS: keep the started process' handle (to wait for it)
const see_mask_no_close_process: u32 = 0x00000040;
/// SEE_MASK_NOASYNC: finish starting before returning (the launcher waits anyway)
const see_mask_no_async: u32 = 0x00000100;
const sw_show_normal: c_int = 1;
const infinite_wait: u32 = 0xFFFFFFFF;
/// ERROR_CANCELLED: the player said no to the administrator prompt
const error_cancelled: u32 = 1223;

const windows_api = if (host.host_system == .windows) struct {
    extern "shell32" fn ShellExecuteExW(info: *ShellExecuteInfoW) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(process: *anyopaque, exit_code: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
} else struct {};

/// The command line of `arguments` for ShellExecuteExW: each one in double quotes, a quote inside doubled by a
/// backslash (the rules of CommandLineToArgvW for arguments without trailing backslashes).
fn windowsParameters(allocator: Allocator, arguments: []const []const u8) error{OutOfMemory}!String {
    var parameters = String.init(allocator);
    errdefer parameters.deinit();
    for (arguments, 0..) |argument, index| {
        if (index > 0) try parameters.appendChar(' ');
        try parameters.appendChar('"');
        for (argument) |character| {
            if (character == '"') try parameters.append("\\\"") else try parameters.appendChar(character);
        }
        try parameters.appendChar('"');
    }
    return parameters;
}

fn runElevatedWindows(allocator: Allocator, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!ElevatedRunResult {
    if (host.host_system != .windows) unreachable; // why: only called on Windows (runWithAdministratorRights)
    var parameters = try windowsParameters(allocator, arguments);
    defer parameters.deinit();
    const program_wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, program) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return .{ .unavailable = try String.from(allocator, "The launcher's path couldn't be passed to Windows.") },
    };
    defer allocator.free(program_wide);
    const parameters_wide = std.unicode.wtf8ToWtf16LeAllocZ(allocator, parameters.slice()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return .{ .unavailable = try String.from(allocator, "The update's options couldn't be passed to Windows.") },
    };
    defer allocator.free(parameters_wide);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("runas");

    var info = ShellExecuteInfoW{
        .cbSize = @sizeOf(ShellExecuteInfoW),
        .fMask = see_mask_no_close_process | see_mask_no_async,
        .hwnd = null,
        .lpVerb = verb,
        .lpFile = program_wide.ptr,
        .lpParameters = parameters_wide.ptr,
        .lpDirectory = null,
        .nShow = sw_show_normal,
        .hInstApp = null,
        .lpIDList = null,
        .lpClass = null,
        .hkeyClass = null,
        .dwHotKey = 0,
        .hIconOrMonitor = null,
        .hProcess = null,
    };
    if (windows_api.ShellExecuteExW(&info) == 0) {
        if (windows_api.GetLastError() == error_cancelled) return .declined;
        return .{ .unavailable = try String.from(allocator, "Windows couldn't start the launcher as administrator. Right-click the launcher and choose \"Run as administrator\", or move the randomizer's folder somewhere you can write (your Documents, for example).") };
    }
    const process = info.hProcess orelse return .{ .finished = 0 };
    defer _ = windows_api.CloseHandle(process);
    _ = windows_api.WaitForSingleObject(process, infinite_wait);
    var exit_code: u32 = 1;
    if (windows_api.GetExitCodeProcess(process, &exit_code) == 0) exit_code = 1;
    return .{ .finished = @truncate(exit_code) };
}

// ----------------------------------------------------------------------------------------------------------- macOS

/// Appends `text` as an AppleScript string literal ("..." with \ and " escaped).
fn appendAppleScriptString(out: *String, text: []const u8) error{OutOfMemory}!void {
    try out.appendChar('"');
    for (text) |character| {
        if (character == '"' or character == '\\') try out.appendChar('\\');
        try out.appendChar(character);
    }
    try out.appendChar('"');
}

/// The AppleScript that runs the command with the system's password prompt:
/// do shell script (quoted form of "<program>") & " " & (quoted form of "<argument>") ... with administrator privileges
fn macosAdministratorScript(allocator: Allocator, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!String {
    var script = try String.from(allocator, "do shell script (quoted form of ");
    errdefer script.deinit();
    try appendAppleScriptString(&script, program);
    try script.append(")");
    for (arguments) |argument| {
        try script.append(" & \" \" & (quoted form of ");
        try appendAppleScriptString(&script, argument);
        try script.append(")");
    }
    try script.append(" with administrator privileges");
    return script;
}

fn runElevatedMacos(allocator: Allocator, io: Io, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!ElevatedRunResult {
    var script = try macosAdministratorScript(allocator, program, arguments);
    defer script.deinit();
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/osascript", "-e", script.slice() },
        .stdin = .ignore,
    }) catch return .{ .unavailable = try manualCommandText(allocator, program, arguments) };
    const term = child.wait(io) catch return .{ .unavailable = try manualCommandText(allocator, program, arguments) };
    return switch (term) {
        // osascript exits with 1 both when the player cancels the prompt and when the command fails; the launcher
        // checks the folder afterwards either way
        .exited => |code| .{ .finished = code },
        else => .{ .finished = 1 },
    };
}

// ----------------------------------------------------------------------------------------------------------- Linux

/// pkexec's exit codes when it didn't run the program (polkit docs): 126 the player dismissed the prompt or
/// wasn't allowed, 127 no polkit agent could ask
const pkexec_dismissed: u8 = 126;
const pkexec_not_authorized: u8 = 127;

fn runElevatedLinux(allocator: Allocator, io: Io, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!ElevatedRunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "pkexec");
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, arguments);
    var child = std.process.spawn(io, .{ .argv = argv.items, .stdin = .inherit }) catch
        return .{ .unavailable = try manualCommandText(allocator, program, arguments) };
    const term = child.wait(io) catch return .{ .unavailable = try manualCommandText(allocator, program, arguments) };
    return switch (term) {
        .exited => |code| switch (code) {
            pkexec_dismissed => .declined,
            pkexec_not_authorized => .{ .unavailable = try manualCommandText(allocator, program, arguments) },
            else => .{ .finished = code },
        },
        else => .{ .finished = 1 },
    };
}

/// The explanation when the system's prompt can't be used: the command to type in a terminal.
fn manualCommandText(allocator: Allocator, program: []const u8, arguments: []const []const u8) error{OutOfMemory}!String {
    var command = try manualAdministratorCommand(allocator, program, arguments);
    defer command.deinit();
    return String.fmt(allocator, "The system's password prompt isn't available. To install the update, open a terminal and run:\n  {s}\nor move the randomizer's folder somewhere you can write (your home folder, for example).", .{command.slice()});
}

test "Windows parameters are quoted" {
    var parameters = try windowsParameters(std.testing.allocator, &.{ "--install-only", "--pretend-version", "0.8.0" });
    defer parameters.deinit();
    try std.testing.expectEqualStrings("\"--install-only\" \"--pretend-version\" \"0.8.0\"", parameters.slice());
}

test "the macOS prompt script quotes the path" {
    var script = try macosAdministratorScript(std.testing.allocator, "/Applications/Goggles \"Rando\"/goggles_launcher", &.{"--install-only"});
    defer script.deinit();
    try std.testing.expectEqualStrings(
        "do shell script (quoted form of \"/Applications/Goggles \\\"Rando\\\"/goggles_launcher\") & \" \" & (quoted form of \"--install-only\") with administrator privileges",
        script.slice(),
    );
}

test "the sudo command quotes the path" {
    var command = try manualAdministratorCommand(std.testing.allocator, "/opt/it's here/goggles_launcher", &.{"--install-only"});
    defer command.deinit();
    try std.testing.expectEqualStrings("sudo '/opt/it'\\''s here/goggles_launcher' '--install-only'", command.slice());
}

test "every function compiles" {
    std.testing.refAllDecls(@This());
}
