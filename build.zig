const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`.
pub const Platform = enum { native, gtk, qt, sdl, none };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "What hosts fabrum.app: native (the default: AppKit on macOS), gtk, qt, sdl, or none for the app's own host with drawn widgets") orelse .native;
    const quartz = b.option(bool, "quartz", "Include fabrum.render.Quartz, to draw into CGContexts with any platform on macOS. The AppKit platform always has it, as its canvas; elsewhere it is off unless asked for, so none links nothing") orelse false;
    const cairo = b.option(bool, "cairo", "Include fabrum.render.Cairo, to draw into cairo_t contexts with any platform (links Cairo and Pango through pkg-config). The GTK platform always has it, as its canvas") orelse false;
    const features: Features = .init(platform, quartz, cairo, target);

    // Library / module
    const mod = b.addModule("fabrum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("fabrum_options", features.options(b));
    features.addSources(b, mod);
    addSegmentation(b, mod, target, optimize);

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
    addExamples(b, test_step, mod, features, target, optimize);

    // the snippets in docs/ that aren't quoted from examples/, as tests
    const doc_snippets = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/compile/doc_snippets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(doc_snippets).step);
}

/// The programs in `examples/`: `zig build examples` builds them all into
/// `zig-out/bin`, `zig build run-<name>` runs one, and `zig build test`
/// runs their tests, so they can't rot. Examples that need a window are
/// only built with a toolkit platform; their tests run everywhere.
fn addExamples(b: *std.Build, test_step: *std.Build.Step, mod: *std.Build.Module, features: Features, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const examples_step = b.step("examples", "Build the examples in examples/ into zig-out/bin");
    const has_window = features.appkit or features.gtk;
    const examples = [_]struct { name: []const u8, source: []const u8, needs_window: bool = false }{
        .{ .name = "counter", .source = "examples/counter.zig", .needs_window = true },
        .{ .name = "headless", .source = "examples/headless.zig" },
        .{ .name = "layout-only", .source = "examples/layout_only.zig" },
    };
    for (examples) |example| {
        const module = b.createModule(.{
            .root_source_file = b.path(example.source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = mod }},
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);

        if (example.needs_window and !has_window) continue;
        const exe = b.addExecutable(.{ .name = example.name, .root_module = module });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{example.name}), b.fmt("Build and run examples/{s}", .{std.fs.path.basename(example.source)})).dependOn(&run.step);
    }
}

/// What goes into one `fabrum` module: its platform, and the renderers
/// that come with fabrum.
const Features = struct {
    platform: Platform,
    /// AppKit, for `native` on macOS.
    appkit: bool,
    /// GTK 4, for `gtk` anywhere and `native` on Linux.
    gtk: bool,
    /// `fabrum.render.Quartz`: always with AppKit, whose canvas it is, and
    /// on macOS when asked for. Off otherwise, so that `none` links nothing
    /// and cross-builds for macOS without the SDK's frameworks.
    quartz: bool,
    /// `fabrum.render.Cairo`: always with GTK, whose canvas it is, and
    /// when asked for.
    cairo: bool,

    fn init(platform: Platform, quartz: bool, cairo: bool, target: std.Build.ResolvedTarget) Features {
        const macos = target.result.os.tag == .macos;
        const appkit = platform == .native and macos;
        const gtk = platform == .gtk or (platform == .native and target.result.os.tag == .linux);
        return .{ .platform = platform, .appkit = appkit, .gtk = gtk, .quartz = appkit or (quartz and macos), .cairo = gtk or cairo };
    }

    fn options(self: Features, b: *std.Build) *std.Build.Step.Options {
        const o = b.addOptions();
        o.addOption([]const u8, "platform", @tagName(self.platform));
        o.addOption(bool, "quartz", self.quartz);
        o.addOption(bool, "cairo", self.cairo);
        return o;
    }

    /// Adds the sources and system libraries of the features to `mod`.
    /// `none` on its own links nothing.
    fn addSources(self: Features, b: *std.Build, mod: *std.Build.Module) void {
        if (self.quartz) {
            // plain C: Core Graphics and Core Text, and Core Foundation,
            // which both are built on; no AppKit, so it draws without a window
            mod.addCSourceFiles(.{
                .root = b.path("src/render/quartz"),
                .files = &.{ "text.c", "draw.c" },
                .language = .c,
            });
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("CoreGraphics", .{});
            mod.linkFramework("CoreText", .{});
        }
        if (self.appkit) {
            mod.addCSourceFiles(.{
                .root = b.path("src/app/platform/appkit"),
                .files = &.{"shell.m"},
                .language = .objective_c,
                .flags = &.{"-fobjc-arc"},
            });
            mod.linkFramework("AppKit", .{});
            // UTType, for the file chooser's filters
            mod.linkFramework("UniformTypeIdentifiers", .{});
        }
        // Cairo, Pango and GTK come through pkg-config (with Homebrew's
        // GTK on macOS, Homebrew's pkgconf must be first on PATH, so the
        // private requirements of its .pc files resolve). Each library is
        // named once: gtk4 brings pangocairo and cairo with it, and dyld
        // refuses a dylib linked twice.
        if (self.cairo) {
            mod.addCSourceFiles(.{
                .root = b.path("src/render/cairo"),
                .files = &.{"draw.c"},
                .language = .c,
            });
            mod.link_libc = true;
            if (!self.gtk) mod.linkSystemLibrary("pangocairo", .{ .use_pkg_config = .force });
        }
        if (self.gtk) {
            mod.addCSourceFiles(.{
                .root = b.path("src/app/platform/gtk"),
                .files = &.{"shell.c"},
                .language = .c,
            });
            mod.link_libc = true;
            mod.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
        }
    }
};

/// Gives `mod` zg's grapheme and word segmentation (UAX #29), fabrum's one
/// external dependency: `app.TextEditor` moves and deletes by grapheme and
/// by word with it. Only code that edits text pulls its tables in.
fn addSegmentation(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
    mod.addImport("Graphemes", zg.module("Graphemes"));
    mod.addImport("Words", zg.module("Words"));
}

/// Programs that must not compile, with the error they must give: they
/// check fabrum's compile-time errors, which no test can reach at run time.
fn addCompileErrorTests(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // as in `fabrum.app.platform.remedy`
    const remedy = "build fabrum with -Dplatform=none (`.platform = .none`) to host the app yourself with drawn widgets";
    const linux = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });
    const macos = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const cases = [_]struct { name: []const u8, source: []const u8, platform: Platform, target: ?std.Build.ResolvedTarget = null, expect: []const u8 }{
        // platforms that don't exist yet say so as soon as `fabrum.app` is used
        .{ .name = "qt", .source = "app_on_platform.zig", .platform = .qt, .expect = "fabrum: the qt platform is not implemented yet; " ++ remedy },
        .{ .name = "sdl", .source = "app_on_platform.zig", .platform = .sdl, .expect = "fabrum: the sdl platform is not implemented yet; " ++ remedy },
        .{ .name = "native-windows", .source = "app_on_platform.zig", .platform = .native, .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows }), .expect = "fabrum: the native platform of windows (win32) is not implemented yet; " ++ remedy },
        // a renderer used with a surface it doesn't accept
        .{ .name = "surface", .source = "wrong_surface.zig", .platform = .none, .expect = "fabrum: the renderer wrong_surface.PixelsOnly doesn't draw into .cg_context surfaces; it accepts .pixels" },
        // Quartz outside AppKit only when asked for
        .{ .name = "quartz", .source = "quartz_not_built.zig", .platform = .none, .target = macos, .expect = "fabrum.render.Quartz isn't available: build fabrum with -Dquartz=true (`.quartz = true`) to draw with it on the none platform" },
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
    const features: Features = .init(platform, false, false, target);
    fabrum.addOptions("fabrum_options", features.options(b));
    features.addSources(b, fabrum);
    addSegmentation(b, fabrum, target, optimize);
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
