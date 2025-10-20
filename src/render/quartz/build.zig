const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fabrum_dep = b.dependency("fabrum", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("fabrum-renderer-quartz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{
                .name = "fabrum",
                .module = fabrum_dep.module("fabrum"),
            },
        },
    });

    mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "text.m",
        },
        .language = .objective_c,
        .flags = &.{
            "-fobjc-arc",
        },
    });

    mod.linkFramework("Cocoa", .{});

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
