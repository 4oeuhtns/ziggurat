const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // public module
    const mod = b.addModule("ziggurat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // build docs
    const lib = b.addLibrary(.{
        .name = "ziggurat",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API docs");
    docs_step.dependOn(&install_docs.step);

    // compiles tests and runs
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);

    // fuzz the tests, always in ReleaseSafe
    // (safety checks on; also Zig 0.16.0 can't fuzz in Debug).
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Fuzz tests in ReleaseSafe");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // runs benchmarks to compare speed
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/benchmarks.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ziggurat", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks (builds with ReleaseFast)");
    bench_step.dependOn(&run_bench.step);
}
