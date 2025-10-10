const std = @import("std");
const tvg = @import("thorvg");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const thorvg_dependency = b.dependencyFromBuildZig(tvg, .{
    //     .target = target,
    //     .optimize = optimize,
    //     .savers = &[_]tvg.FileSaver{.all},
    // });

    // Library / module
    const mod = b.addModule("fabrum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // mod.addImport("thorvg", thorvg_dependency.module("thorvg"));

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.addModule("hello", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "fabrum",
                    .module = mod,
                },
            },
        }),
    });
    // exe.root_module.addImport("thorvg", thorvg_dependency.module("thorvg"));

    b.installArtifact(exe);

    // Simple run step: zig build run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run hello world SVG demo");
    run_step.dependOn(&run_exe.step);

    // Coverage flag detection
    const code_coverage_requested = blk: {
        if (b.args) |args| {
            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "--coverage")) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const test_step = b.step("test", "Run tests");
    if (code_coverage_requested) {
        const kcov = b.addSystemCommand(&.{ "kcov", "coverage" });
        kcov.addArtifactArg(mod_tests);
        kcov.step.dependOn(&mod_tests.step);
        test_step.dependOn(&kcov.step);
    } else {
        const run_mod_tests = b.addRunArtifact(mod_tests);
        test_step.dependOn(&run_mod_tests.step);
    }
}
