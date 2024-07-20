const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig build test
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // zig build docs
    const docs_step = b.step("docs", "Generate documentation");
    const lib = b.addStaticLibrary(.{
        .name = "npy-out",
        .root_source_file = b.path("src/npy-out.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // zig build exapmles
    const examples_step = b.step("examples", "Build examples");
    const lib_mod = b.addModule("npy-out", .{ .root_source_file = b.path("src/npy-out.zig") });
    inline for (.{
        "array",
        "sensor",
    }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        const install_example = b.addInstallArtifact(example, .{});
        example.root_module.addImport("npy-out", lib_mod);
        examples_step.dependOn(&install_example.step);
    }

    // zig build all
    const all_step = b.step("all", "Build everything and run all tests");
    all_step.dependOn(test_step);
    all_step.dependOn(docs_step);
    all_step.dependOn(examples_step);
}
