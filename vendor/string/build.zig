const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module. Consumers get it with:
    //   const string = b.dependency("string", .{}).module("string");
    const mod = b.addModule("string", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // zig build run-example
    const example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "string", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("run-example", "Build and run examples/basic.zig");
    example_step.dependOn(&run_example.step);

    // zig build docs  →  zig-out/docs/index.html
    const docs_obj = b.addLibrary(.{
        .name = "string",
        .linkage = .static,
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);

    // zig build check  (fast compile-only, for editor integration)
    const check = b.step("check", "Type-check the library and example");
    check.dependOn(&tests.step);
    check.dependOn(&example.step);
}
