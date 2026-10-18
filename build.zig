const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`.
pub const Platform = enum { native, gtk, qt, sdl, none };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "What hosts fabrum.app: native (the default: AppKit on macOS), gtk, qt, sdl, or none for the app's own host with drawn widgets") orelse .native;

    // Library / module
    const mod = b.addModule("fabrum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("fabrum_options", platformOptions(b, platform));
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

    addCompileErrorTests(b, test_step, target, optimize);
}

fn platformOptions(b: *std.Build, platform: Platform) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "platform", @tagName(platform));
    return options;
}

/// Adds the sources and system libraries of the platform `platform` means
/// on `target` to the `fabrum` module. Only AppKit needs any so far; `none`
/// links nothing.
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

/// Programs that must not compile, with the error they must give: they
/// check fabrum's compile-time errors, which no test can reach at run time.
fn addCompileErrorTests(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // as in `fabrum.app.platform.remedy`
    const remedy = "build fabrum with -Dplatform=none (`.platform = .none`) to host the app yourself with drawn widgets";
    const linux = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });
    const cases = [_]struct { name: []const u8, source: []const u8, platform: Platform, target: ?std.Build.ResolvedTarget = null, expect: []const u8 }{
        // platforms that don't exist yet say so as soon as `fabrum.app` is used
        .{ .name = "gtk", .source = "app_on_platform.zig", .platform = .gtk, .expect = "fabrum: the gtk platform is not implemented yet; " ++ remedy },
        .{ .name = "qt", .source = "app_on_platform.zig", .platform = .qt, .expect = "fabrum: the qt platform is not implemented yet; " ++ remedy },
        .{ .name = "sdl", .source = "app_on_platform.zig", .platform = .sdl, .expect = "fabrum: the sdl platform is not implemented yet; " ++ remedy },
        .{ .name = "native-linux", .source = "app_on_platform.zig", .platform = .native, .target = linux, .expect = "fabrum: the native platform of linux (gtk) is not implemented yet; " ++ remedy },
        // a renderer used with a surface it doesn't accept
        .{ .name = "surface", .source = "wrong_surface.zig", .platform = .none, .expect = "fabrum: the renderer wrong_surface.PixelsOnly doesn't draw into .cg_context surfaces; it accepts .pixels" },
    };
    for (cases) |case| {
        const program = objectWithFabrum(b, b.fmt("compile-error-{s}", .{case.name}), b.fmt("test/compile_errors/{s}", .{case.source}), case.platform, case.target orelse target, optimize);
        // `contains` matches the end of an error's line
        program.expect_errors = .{ .contains = case.expect };
        test_step.dependOn(&program.step);
    }

    // layout alone builds for any OS with `none`, and links nothing
    for ([_]std.Build.ResolvedTarget{ linux, b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows }) }) |other| {
        const program = objectWithFabrum(b, b.fmt("layout-only-{t}", .{other.result.os.tag}), "test/compile/layout_only.zig", .none, other, optimize);
        test_step.dependOn(&program.step);
    }
}

/// An object file built from `source`, which imports a `fabrum` built for
/// `platform`.
fn objectWithFabrum(b: *std.Build, name: []const u8, source: []const u8, platform: Platform, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const fabrum = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    fabrum.addOptions("fabrum_options", platformOptions(b, platform));
    addPlatform(b, fabrum, platform, target);
    return b.addObject(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum }},
        }),
    });
}
