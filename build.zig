const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`.
pub const Platform = enum { native, gtk, qt, headless };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "The toolkit fabrum.app.platform uses: native (default: AppKit on macOS), gtk, qt or headless") orelse .native;

    const options = b.addOptions();
    options.addOption([]const u8, "platform", @tagName(platform));

    // Library / module
    const mod = b.addModule("fabrum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("fabrum_options", options);
    addPlatform(b, mod, platform, target);

    // Coverage flag detection: zig build test -Dcoverage
    const code_coverage_requested = b.option(bool, "coverage", "Run tests under kcov") orelse false;

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

/// Adds the sources and system libraries of the toolkit `platform` means on
/// `target` to the `fabrum` module. Only AppKit exists so far; the others
/// need nothing until they are written.
fn addPlatform(b: *std.Build, mod: *std.Build.Module, platform: Platform, target: std.Build.ResolvedTarget) void {
    const appkit = platform == .native and target.result.os.tag == .macos;
    if (!appkit) return;
    mod.addCSourceFiles(.{
        .root = b.path("src/app/platform/appkit"),
        .files = &.{"shell.m"},
        .language = .objective_c,
        .flags = &.{"-fobjc-arc"},
    });
    mod.linkFramework("AppKit", .{});
}
