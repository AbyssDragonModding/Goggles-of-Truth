//! Build script for the Goggles of Truth Randomizer.
//!
//!   zig build                         a release build (ReleaseFast) of the window and the command-line tool in
//!                                     zig-out/<system>, with the Raven library beside them
//!   zig build cli                     the command-line tool only (no window, no Raven needed)
//!   zig build run                     build and start the window
//!   zig build test                    unit tests of the engine (no game files needed)
//!   zig build -Doptimize=Debug        a debug build (only when debugging; every other build is a release build)
//!   zig build -Dtarget=x86_64-linux   cross-compile (x86_64/aarch64 for windows, linux and macos; the window needs a
//!                                     prebuilt Raven library, so aarch64 windows/linux get the command-line tool only)
//!
//! One folder per system: zig-out/windows, zig-out/linux, zig-out/macos (Intel) and zig-out/macos-aarch64 (Apple
//! Silicon), so builds for several systems can share one zig-out. Ship a folder as it is: the program finds the
//! Raven library next to itself.
//!
//! The engine (src/engine.zig: formats, world scan, logic, generator) has no Raven dependency, so the command-line
//! tool and the tests build for every target. zstd is compiled from vendor/zstd (C) for the target, so the program
//! has no runtime dependency other than the Raven shared library the window needs.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Agents.md: a plain `zig build` makes a release build (ReleaseFast). A debug build is only made when asked for:
    // `zig build -Doptimize=Debug`. `--release=safe` / `--release=small` still choose those modes.
    const optimize: std.builtin.Optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Debug, ReleaseSafe, ReleaseFast (the default) or ReleaseSmall",
    ) orelse switch (b.graph.release_mode) {
        .off, .any, .fast => .fast,
        .safe => .safe,
        .small => .small,
    };
    const t = target.result;

    // Release builds are the ones shipped: without debug information, which holds the source paths of the machine
    // that built them (the folder of this project and of Zig). Debug builds keep it for stack traces.
    const strip = b.option(bool, "strip", "Leave debug information out of the programs (default: on for release builds)") orelse
        (optimize != .debug);

    // ---- the engine: everything except the window
    const engine = engineModule(b, target, optimize);

    // ---- command-line tool (headless: generate, check, scan, vanilla test)
    const cli = b.addExecutable(.{
        .name = "goggles_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    // one folder per system, so cross-compiled builds don't overwrite each other
    const os_dir = if (t.cpu.arch == .x86_64) @tagName(t.os.tag) else b.fmt("{s}-{s}", .{ @tagName(t.os.tag), @tagName(t.cpu.arch) });
    const install_cli = b.addInstallArtifact(cli, .{
        .dest_dir = .{ .override = .{ .custom = os_dir } },
    });
    b.getInstallStep().dependOn(&install_cli.step);
    const cli_step = b.step("cli", "Build only the command-line tool");
    cli_step.dependOn(&install_cli.step);

    // ---- the window (needs the prebuilt Raven library for the *target*, not the host)
    const raven_lib = ravenLibraryFor(t);
    if (raven_lib) |lib| {
        // The window links the prebuilt Raven library, so it uses the ABI that library was built for; the
        // command-line tool stays as asked.
        // - Linux: Zig's default target is musl, but Raven is built against glibc (it loads libX11 and the Vulkan
        //   driver of the system), so the window is always a glibc program (a static musl CLI runs on any Linux).
        // - Windows: raven.lib is a MinGW (GNU) import library, which the MSVC ABI can't link ("raven.dll: bad file
        //   type"): with -Dtarget=x86_64-windows-msvc only the CLI was built. The window is always a GNU-ABI program.
        const window_needs_gnu_abi = (t.os.tag == .linux and t.abi.isMusl()) or (t.os.tag == .windows and t.abi != .gnu);
        const window_target = if (window_needs_gnu_abi) blk: {
            var query = target.query;
            query.abi = .gnu;
            break :blk b.resolveTargetQuery(query);
        } else target;
        const window_engine = if (window_target.result.abi == t.abi) engine else engineModule(b, window_target, optimize);
        const string = b.dependency("string", .{ .target = window_target, .optimize = optimize });

        // No `lib-dir` is given to the Raven package: it would also write that folder (a path on this machine) into
        // the program as a library search path. The program is linked against vendor/Raven/lib here instead, and
        // finds the library next to itself when it runs.
        const raven = b.dependency("raven", .{ .target = window_target, .optimize = optimize });
        const exe = b.addExecutable(.{
            .name = "goggles_of_truth_rando",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = window_target,
                .optimize = optimize,
                .strip = strip,
                .imports = &.{
                    .{ .name = "engine", .module = window_engine },
                    .{ .name = "raven", .module = raven.module("raven") },
                    .{ .name = "string", .module = string.module("string") },
                },
            }),
        });
        exe.root_module.addLibraryPath(b.path(lib.dir));
        // On Windows the window is a GUI program: it opens without a console window, in debug builds too.
        // -Dconsole=true gives it one (to see debug prints and stack traces while working on it).
        const console = b.option(bool, "console", "Windows: open a console window next to the randomizer window (for debugging)") orelse false;
        if (t.os.tag == .windows) exe.subsystem = if (console) .console else .windows;
        // The .exe's own icon (Explorer, shortcuts, the task bar). Zig compiles the .rc itself, so this works when
        // cross-compiling too. Linux and macOS programs have no icon of their own: the window sets it when it opens.
        if (t.os.tag == .windows) exe.root_module.addWin32ResourceFile(.{ .file = b.path("src/ui/app.rc") });
        // Linux and macOS look for the library next to the program; Windows always looks there first.
        switch (t.os.tag) {
            .linux => exe.root_module.addRPathSpecial("$ORIGIN"),
            .macos => exe.root_module.addRPathSpecial("@executable_path"),
            else => {},
        }

        // On macOS the window is an app bundle (the Dock and Finder show its icon, and it opens with a double
        // click): the program and the Raven library in Contents/MacOS, the icon in Contents/Resources. Elsewhere
        // the program sits in the system's folder.
        const exe_dir = if (t.os.tag == .macos) b.fmt("{s}/{s}.app/Contents/MacOS", .{ os_dir, app_name }) else os_dir;
        const install_step = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = exe_dir } },
        });

        // the shared library goes next to the program, under the name the program asks for when it starts
        const copy_lib = b.addInstallFileWithDir(
            b.path(b.pathJoin(&.{ lib.dir, lib.runtime_file })),
            .{ .custom = exe_dir },
            lib.runtime_name,
        );

        b.getInstallStep().dependOn(&install_step.step);
        b.getInstallStep().dependOn(&copy_lib.step);

        if (t.os.tag == .macos) {
            const contents = b.fmt("{s}/{s}.app/Contents", .{ os_dir, app_name });
            const plist = b.addWriteFiles().add("Info.plist", infoPlist(b, exe.name));
            const install_plist = b.addInstallFileWithDir(plist, .{ .custom = contents }, "Info.plist");
            const install_icon = b.addInstallFileWithDir(
                b.path("src/ui/GogglesRandoAppIcon.icns"),
                .{ .custom = b.fmt("{s}/Resources", .{contents}) },
                "AppIcon.icns",
            );
            b.getInstallStep().dependOn(&install_plist.step);
            b.getInstallStep().dependOn(&install_icon.step);
        }

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        const run_step = b.step("run", "Build and start the randomizer window");
        run_step.dependOn(&run_cmd.step);
    } else {
        std.log.warn("no prebuilt Raven library for {s}-{s}: only the command-line tool is built", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag),
        });
    }

    // ---- tests of the engine
    const tests = b.addTest(.{ .root_module = engine });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the engine's unit tests");
    test_step.dependOn(&run_tests.step);
}

/// The engine module (src/engine.zig) for a target: zstd (C) compiled for it, and the string library.
fn engineModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const zstd = buildZstd(b, target, optimize);
    const string = b.dependency("string", .{ .target = target, .optimize = optimize });
    const engine = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine.addImport("string", string.module("string"));
    engine.addIncludePath(b.path("vendor/zstd/lib"));
    engine.linkLibrary(zstd);
    return engine;
}

/// The name of the macOS app bundle (and of the app in the Dock and Finder).
const app_name = version_info.name;
const version_info = @import("src/version.zig");

/// Info.plist of the macOS app bundle: which program in Contents/MacOS to start, its icon (Contents/Resources/
/// AppIcon.icns) and its version (the randomizer's, from src/version.zig).
fn infoPlist(b: *std.Build, executable: []const u8) []const u8 {
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIconFile</key>
        \\    <string>AppIcon</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.abyssdragonmodding.gogglesoftruthrando</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>{s}</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{ executable, app_name, app_name, version_info.version, version_info.version });
}

const RavenLibrary = struct {
    /// the folder linked against (`lib-dir` of the Raven package)
    dir: []const u8,
    /// the file in `dir` the program loads when it starts
    runtime_file: []const u8,
    /// the name it must have next to the program: the name the library gives itself, which the linker records in
    /// the program (Linux: its soname libraven.so.0; macOS: its install name @rpath/libraven.0.dylib)
    runtime_name: []const u8,
};

/// The prebuilt Raven library in vendor/Raven/lib for a target, or null when there is none.
fn ravenLibraryFor(t: std.Target) ?RavenLibrary {
    return switch (t.os.tag) {
        // links raven.lib (the import library), runs with raven.dll
        .windows => if (t.cpu.arch == .x86_64)
            RavenLibrary{ .dir = "vendor/Raven/lib/windows-x64", .runtime_file = "raven.dll", .runtime_name = "raven.dll" }
        else
            null,
        .linux => if (t.cpu.arch == .x86_64)
            RavenLibrary{ .dir = "vendor/Raven/lib/linux-x64", .runtime_file = "libraven.so", .runtime_name = "libraven.so.0" }
        else
            null,
        // a universal library (x86_64 and arm64 in one file), despite the folder's name
        .macos => if (t.cpu.arch == .x86_64 or t.cpu.arch == .aarch64)
            RavenLibrary{ .dir = "vendor/Raven/lib/macos-x64", .runtime_file = "libraven.dylib", .runtime_name = "libraven.0.dylib" }
        else
            null,
        else => null,
    };
}

/// zstd 1.5.7 (vendor/zstd, BSD licence) as a static library: compression and decompression with dictionaries.
/// The x86-64 assembly decoder is left out (ZSTD_DISABLE_ASM), so the same C builds for every target.
fn buildZstd(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "zstd",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            // zstd is always built optimized: a debug zstd makes scanning the game many times slower
            .optimize = if (optimize == .debug) .fast else optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(b.path("vendor/zstd/lib"));
    lib.root_module.addCMacro("ZSTD_DISABLE_ASM", "1");
    lib.root_module.addCMacro("ZSTD_MULTITHREAD_SUPPORT_DEFAULT", "0");
    lib.root_module.addCMacro("XXH_NAMESPACE", "ZSTD_");
    lib.root_module.addCSourceFiles(.{
        .root = b.path("vendor/zstd/lib"),
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/pool.c",
            "common/threading.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "compress/fse_compress.c",
            "compress/hist.c",
            "compress/huf_compress.c",
            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",
            "compress/zstd_compress_sequences.c",
            "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",
            "compress/zstd_fast.c",
            "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",
            "compress/zstd_opt.c",
            "compress/zstd_preSplit.c",
            "compress/zstdmt_compress.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",
            "decompress/zstd_decompress_block.c",
        },
        .flags = &.{"-std=c99"},
    });
    return lib;
}
