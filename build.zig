const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // build and install a static library
    const lib = b.addStaticLibrary(.{
        .name = "npy-out",
        .root_source_file = b.path("src/npy-out.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // set up a `zig build test` step to run unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
