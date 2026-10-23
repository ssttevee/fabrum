const std = @import("std");

/// fabrum's `platform` option; see `fabrum.app.platform.Option`.
pub const Platform = enum { native, gtk, qt, sdl, none };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option(Platform, "platform", "What hosts fabrum.app: native (the default: AppKit on macOS), gtk, qt, sdl, or none for the app's own host with drawn widgets") orelse .native;
    const quartz = b.option(bool, "quartz", "Include fabrum.render.Quartz, to draw into CGContexts with any platform on macOS. The AppKit platform always has it, as its canvas; elsewhere it is off unless asked for, so none links nothing") orelse false;
    const cairo = b.option(bool, "cairo", "Include fabrum.render.Cairo, to draw into cairo_t contexts with any platform (links Cairo and Pango through pkg-config). The GTK platform always has it, as its canvas") orelse false;
    const direct2d = b.option(bool, "direct2d", "Include Direct2D on Windows; native Windows always includes it") orelse false;
    const features: Features = .init(platform, quartz, cairo, direct2d, target);

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
    if (features.win32) mod_tests.win32_manifest = b.path("src/app/platform/win32/windows.manifest");

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
    if (features.gtk) {
        const invalid_window = b.addObject(.{
            .name = "compile-error-overlay-window",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/compile_errors/overlay_window_gtk.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fabrum", .module = mod }},
            }),
        });
        invalid_window.expect_errors = .{ .contains = "window policy 'activation' is unsupported by the built-in 'gtk' host" };
        test_step.dependOn(&invalid_window.step);
    }
    addExamples(b, test_step, mod, features, target, optimize);
    const palette_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/app/platform/win32/palette.zig"), .target = target, .optimize = optimize }) });
    b.step("test-win32-palette", "Test Win32 color policy without a desktop").dependOn(&b.addRunArtifact(palette_tests).step);

    // Explicit opt-in: this executable opens native windows and exercises
    // their event loop, input routing, close guards and teardown.
    const window_tests = b.step("test-windows", "Run native multi-window integration tests (requires a desktop)");
    const win32_overlays = if (features.win32) b.addExecutable(.{
        .name = "native-win32-overlay-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/native_win32_overlays.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = mod }},
        }),
        .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
    }) else null;
    if (win32_overlays) |exe| {
        exe.root_module.addCSourceFiles(.{ .files = &.{ "test/win32_png_probe.cpp", "test/win32_overlay_probe.cpp" }, .language = .cpp, .flags = &.{"-std=c++17"} });
        b.step("build-win32-overlays", "Compile Win32 overlay regressions without opening windows").dependOn(&exe.step);
    }
    if (features.appkit or features.gtk or features.win32) {
        const exe = b.addExecutable(.{
            .name = "native-window-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/native_windows.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fabrum", .module = mod }},
            }),
        });
        const single = b.addExecutable(.{
            .name = "native-single-window-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/native_single_window.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fabrum", .module = mod }},
            }),
        });
        if (features.win32) {
            exe.win32_manifest = b.path("src/app/platform/win32/windows.manifest");
            single.win32_manifest = b.path("src/app/platform/win32/windows.manifest");
        }
        const run = b.addRunArtifact(exe);
        const single_run = b.addRunArtifact(single);
        run.step.dependOn(&single_run.step);
        if (features.win32) {
            var previous: *std.Build.Step = &single_run.step;
            const text_test = b.addExecutable(.{
                .name = "native-win32-text-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_text.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            b.step("build-win32-text", "Compile native text entry and synthetic IME regressions without opening windows").dependOn(&text_test.step);
            const text_run = b.addRunArtifact(text_test);
            b.step("test-win32-text", "Run text services and synthetic IME regressions (requires a desktop)").dependOn(&text_run.step);
            const text_suite_run = b.addRunArtifact(text_test);
            text_suite_run.step.dependOn(previous);
            previous = &text_suite_run.step;
            const rendering_test = b.addExecutable(.{
                .name = "native-win32-rendering-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_rendering.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            const rendering_run = b.addRunArtifact(rendering_test);
            rendering_run.step.dependOn(previous);
            previous = &rendering_run.step;
            const rendering_step = b.step("test-win32-rendering", "Run Win32 layer pixels, HWND ordering and recovery tests (requires a desktop)");
            rendering_step.dependOn(&rendering_run.step);
            b.step("build-win32-rendering", "Compile Win32 rendering regressions without opening windows").dependOn(&rendering_test.step);
            const capture_test = b.addExecutable(.{
                .name = "native-win32-capture-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_capture.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            capture_test.root_module.addCSourceFiles(.{ .files = &.{"test/win32_png_probe.cpp"}, .language = .cpp, .flags = &.{"-std=c++17"} });
            b.step("build-win32-capture", "Compile client capture and bounded canvas regressions without opening windows").dependOn(&capture_test.step);
            b.step("test-win32-capture", "Run client capture and bounded canvas regressions (requires a desktop)").dependOn(&b.addRunArtifact(capture_test).step);
            const capture_suite = b.addRunArtifact(capture_test);
            capture_suite.step.dependOn(previous);
            previous = &capture_suite.step;
            const scrolling_test = b.addExecutable(.{
                .name = "native-win32-scrolling-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_scrolling.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            const scrolling_run = b.addRunArtifact(scrolling_test);
            scrolling_run.step.dependOn(previous);
            previous = &scrolling_run.step;
            b.step("test-win32-scrolling", "Run Win32 native scrolling geometry and lifecycle tests (requires a desktop)").dependOn(&scrolling_run.step);
            b.step("build-win32-scrolling", "Compile Win32 native scrolling regression without opening windows").dependOn(&scrolling_test.step);
            const drawn_scroll_test = b.addExecutable(.{
                .name = "native-win32-drawn-scroll-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_drawn_scroll.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            const drawn_scroll_run = b.addRunArtifact(drawn_scroll_test);
            drawn_scroll_run.step.dependOn(previous);
            previous = &drawn_scroll_run.step;
            b.step("test-win32-drawn-scroll", "Run Win32 drawn/native canvas wheel bubbling regression (requires a desktop)").dependOn(&drawn_scroll_run.step);
            const services_test = b.addExecutable(.{
                .name = "native-win32-services-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_services.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            b.step("build-win32-services", "Compile Win32 chooser and popup service regressions").dependOn(&services_test.step);
            b.step("test-win32-services", "Run Win32 chooser and popup service regressions (requires a desktop)").dependOn(&b.addRunArtifact(services_test).step);
            const services_suite = b.addRunArtifact(services_test);
            services_suite.step.dependOn(previous);
            previous = &services_suite.step;
            const metrics_test = b.addExecutable(.{
                .name = "native-win32-metrics-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_metrics.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            b.step("build-win32-metrics", "Compile Win32 native sizing and label regressions").dependOn(&metrics_test.step);
            b.step("test-win32-metrics", "Run Win32 native sizing and label regressions (requires a desktop)").dependOn(&b.addRunArtifact(metrics_test).step);
            const metrics_suite = b.addRunArtifact(metrics_test);
            metrics_suite.step.dependOn(previous);
            previous = &metrics_suite.step;
            const theme_test = b.addExecutable(.{
                .name = "native-win32-theme-tests",
                .root_module = b.createModule(.{ .root_source_file = b.path("test/native_win32_theme.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "fabrum", .module = mod }} }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            b.step("build-win32-theme", "Compile Win32 palette, font and theme refresh regression").dependOn(&theme_test.step);
            b.step("test-win32-theme", "Run Win32 theme/font regression (requires a desktop)").dependOn(&b.addRunArtifact(theme_test).step);
            const theme_suite = b.addRunArtifact(theme_test);
            theme_suite.step.dependOn(previous);
            previous = &theme_suite.step;
            const controls_test = b.addExecutable(.{
                .name = "native-win32-controls-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/native_win32_controls.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "fabrum", .module = mod }},
                }),
                .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
            });
            const controls_run = b.addRunArtifact(controls_test);
            // The targeted command runs only controls. Sequence the desktop
            // suite through a separate run step so opt-in targets stay focused.
            const controls_step = b.step("test-win32-controls", "Run Win32 native control notification and lifecycle tests (requires a desktop)");
            b.step("build-win32-controls", "Compile Win32 native controls regression without opening windows").dependOn(&controls_test.step);
            const controls_suite_run = b.addRunArtifact(controls_test);
            controls_suite_run.step.dependOn(previous);
            previous = &controls_suite_run.step;
            var controls_previous: *std.Build.Step = &controls_run.step;
            for ([_][]const u8{ "--response-close", "--response-quit", "--modal-stack" }) |arg| {
                const response_run = b.addRunArtifact(controls_test);
                response_run.addArg(arg);
                response_run.step.dependOn(controls_previous);
                controls_previous = &response_run.step;
                const response_suite_run = b.addRunArtifact(controls_test);
                response_suite_run.addArg(arg);
                response_suite_run.step.dependOn(previous);
                previous = &response_suite_run.step;
            }
            controls_step.dependOn(controls_previous);
            for ([_]bool{ false, true }) |guarded| {
                const close_options = b.addOptions();
                close_options.addOption(bool, "guarded", guarded);
                const close_test = b.addExecutable(.{
                    .name = if (guarded) "native-win32-guarded-close-test" else "native-win32-close-test",
                    .root_module = b.createModule(.{
                        .root_source_file = b.path("test/native_win32_close.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{.{ .name = "fabrum", .module = mod }},
                    }),
                    .win32_manifest = b.path("src/app/platform/win32/windows.manifest"),
                });
                close_test.root_module.addOptions("close_options", close_options);
                const close_run = b.addRunArtifact(close_test);
                close_run.step.dependOn(previous);
                previous = &close_run.step;
            }
            const overlay_suite = b.addRunArtifact(win32_overlays.?);
            overlay_suite.step.dependOn(previous);
            previous = &overlay_suite.step;
            run.step.dependOn(previous);
        }
        window_tests.dependOn(&run.step);
    } else {
        window_tests.dependOn(&b.addFail("test-windows requires -Dplatform=native on macOS or Windows, or -Dplatform=gtk").step);
    }

    const overlay_tests = b.step("test-overlays", "Run native overlay integration tests (requires a desktop)");
    if (win32_overlays) |exe| {
        overlay_tests.dependOn(&b.addRunArtifact(exe).step);
    } else if (features.appkit or features.gtk) {
        const exe = b.addExecutable(.{
            .name = "native-overlay-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/native_overlays.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "fabrum", .module = mod }},
            }),
        });
        overlay_tests.dependOn(&b.addRunArtifact(exe).step);
    } else {
        overlay_tests.dependOn(&b.addFail("test-overlays requires -Dplatform=native on macOS or Windows, or -Dplatform=gtk").step);
    }

    // the snippets in docs/ that aren't quoted from examples/, as tests
    const doc_snippets = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/compile/doc_snippets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(doc_snippets).step);

    const guide_docs = b.addOptions();
    guide_docs.addOption([]const u8, "README", @embedFile("docs/guides/README.md"));
    guide_docs.addOption([]const u8, "components", @embedFile("docs/guides/components.md"));
    guide_docs.addOption([]const u8, "concurrency", @embedFile("docs/guides/concurrency.md"));
    guide_docs.addOption([]const u8, "custom_content", @embedFile("docs/guides/custom-content.md"));
    guide_docs.addOption([]const u8, "first_app", @embedFile("docs/guides/first-app.md"));
    guide_docs.addOption([]const u8, "hosting", @embedFile("docs/guides/hosting.md"));
    guide_docs.addOption([]const u8, "layout", @embedFile("docs/guides/layout.md"));
    guide_docs.addOption([]const u8, "services", @embedFile("docs/guides/services.md"));
    guide_docs.addOption([]const u8, "testing", @embedFile("docs/guides/testing.md"));
    guide_docs.addOption([]const u8, "timers_and_animation", @embedFile("docs/guides/timers-and-animation.md"));
    guide_docs.addOption([]const u8, "widgets_and_input", @embedFile("docs/guides/widgets-and-input.md"));
    guide_docs.addOption([]const u8, "writing_a_platform", @embedFile("docs/guides/writing-a-platform.md"));
    guide_docs.addOption([]const u8, "writing_a_renderer", @embedFile("docs/guides/writing-a-renderer.md"));

    const guide_snippets = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/compile/guide_snippets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = mod }},
    }) });
    guide_snippets.root_module.addOptions("guide_docs", guide_docs);
    test_step.dependOn(&b.addRunArtifact(guide_snippets).step);

    // Exercise the first-app build as a consumer, using this checkout instead
    // of fetching it. Toolkit entry points compile but never open a window.
    const guide_project = b.addSystemCommand(&.{
        b.graph.zig_exe,                        "build",                              "test",      "--build-file",
        "test/compile/guide_project/build.zig", b.fmt("-Dplatform={t}", .{platform}), "--summary", "all",
    });
    test_step.dependOn(&guide_project.step);
}

/// The programs in `examples/`: `zig build examples` builds them all into
/// `zig-out/bin`, `zig build run-<name>` runs one, and `zig build test`
/// runs their tests, so they can't rot. Examples that need a window are
/// only built with a toolkit platform; their tests run everywhere.
fn addExamples(b: *std.Build, test_step: *std.Build.Step, mod: *std.Build.Module, features: Features, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const examples_step = b.step("examples", "Build the examples in examples/ into zig-out/bin");
    const has_window = features.appkit or features.gtk or features.win32;
    const examples = [_]struct { name: []const u8, source: []const u8, needs_window: bool = false }{
        .{ .name = "counter", .source = "examples/counter.zig", .needs_window = true },
        .{ .name = "windows", .source = "examples/windows.zig", .needs_window = true },
        .{ .name = "overlay", .source = "examples/overlay.zig", .needs_window = true },
        .{ .name = "tasks", .source = "examples/tasks.zig" },
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
        if (std.mem.eql(u8, example.name, "overlay") and !features.appkit and !features.gtk and !features.win32) continue;
        const exe = b.addExecutable(.{ .name = example.name, .root_module = module });
        if (features.win32) exe.win32_manifest = b.path("src/app/platform/win32/windows.manifest");
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
    win32: bool,
    direct2d: bool,
    /// `fabrum.render.Quartz`: always with AppKit, whose canvas it is, and
    /// on macOS when asked for. Off otherwise, so that `none` links nothing
    /// and cross-builds for macOS without the SDK's frameworks.
    quartz: bool,
    /// `fabrum.render.Cairo`: always with GTK, whose canvas it is, and
    /// when asked for.
    cairo: bool,

    fn init(platform: Platform, quartz: bool, cairo: bool, direct2d: bool, target: std.Build.ResolvedTarget) Features {
        const macos = target.result.os.tag == .macos;
        const appkit = platform == .native and macos;
        const gtk = platform == .gtk or (platform == .native and target.result.os.tag == .linux);
        const windows = target.result.os.tag == .windows;
        const win32 = platform == .native and windows;
        return .{ .platform = platform, .appkit = appkit, .gtk = gtk, .win32 = win32, .direct2d = win32 or (direct2d and windows), .quartz = appkit or (quartz and macos), .cairo = gtk or cairo };
    }

    fn options(self: Features, b: *std.Build) *std.Build.Step.Options {
        const o = b.addOptions();
        o.addOption([]const u8, "platform", @tagName(self.platform));
        o.addOption(bool, "quartz", self.quartz);
        o.addOption(bool, "cairo", self.cairo);
        o.addOption(bool, "direct2d", self.direct2d);
        return o;
    }

    /// Adds the sources and system libraries of the features to `mod`.
    /// `none` on its own links nothing.
    fn addSources(self: Features, b: *std.Build, mod: *std.Build.Module) void {
        if (self.win32) {
            mod.link_libc = true;
            const bindings = b.addTranslateC(.{
                .root_source_file = b.path("src/app/platform/win32/windows.h"),
                .target = mod.resolved_target.?,
                .optimize = mod.optimize.?,
            });
            mod.addImport("win32_c", bindings.createModule());
            mod.addCSourceFiles(.{
                .root = b.path("src/app/platform/win32"),
                .files = &.{"file_dialog.cpp"},
                .language = .cpp,
                .flags = &.{ "-std=c++17", "-fexceptions" },
            });
            mod.link_libcpp = true;
            for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "imm32", "ole32", "uuid", "dwmapi", "uxtheme" }) |lib|
                mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
        }
        if (self.direct2d) {
            mod.addCSourceFiles(.{
                .root = b.path("src/render/direct2d"),
                .files = &.{"direct2d.cpp"},
                .language = .cpp,
                .flags = &.{ "-std=c++17", "-fexceptions" },
            });
            mod.link_libcpp = true;
            for ([_][]const u8{ "d2d1", "dwrite", "user32", "gdi32", "windowscodecs", "ole32", "uuid" }) |lib|
                mod.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
        }
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
        .{ .name = "task-context", .source = "task_without_context.zig", .platform = .none, .expect = "app task: first parameter must be *app.Task" },
        .{ .name = "task-container", .source = "task_owning_container.zig", .platform = .none, .expect = "pass a slice or borrow a synchronized object with a single pointer instead" },
        .{ .name = "task-map", .source = "task_owning_map.zig", .platform = .none, .expect = "pass a slice or borrow a synchronized object with a single pointer instead" },
        .{ .name = "task-arena", .source = "task_owning_arena.zig", .platform = .none, .expect = "pass a slice or borrow a synchronized object with a single pointer instead" },
        .{ .name = "appkit-widget-on-none", .source = "appkit_widget_on_none.zig", .platform = .none, .expect = "fabrum.app.platform.appkit isn't in this build: fabrum's platform is .none (option .none); check `fabrum.app.platform.kind` before using it" },
        // a renderer used with a surface it doesn't accept
        .{ .name = "surface", .source = "wrong_surface.zig", .platform = .none, .expect = "fabrum: the renderer wrong_surface.PixelsOnly doesn't draw into .cg_context surfaces; it accepts .pixels" },
        // Quartz outside AppKit only when asked for
        .{ .name = "quartz", .source = "quartz_not_built.zig", .platform = .none, .target = macos, .expect = "fabrum.render.Quartz isn't available: build fabrum with -Dquartz=true (`.quartz = true`) to draw with it on the none platform" },
        .{ .name = "overlay-floating", .source = "overlay_floating_gtk.zig", .platform = .none, .expect = "window policy 'level' is unsupported by the built-in 'gtk' host" },
        .{ .name = "overlay-activation", .source = "overlay_never_gtk.zig", .platform = .none, .expect = "window policy 'activation' is unsupported by the built-in 'gtk' host" },
        .{ .name = "overlay-placement", .source = "overlay_positioned_gtk.zig", .platform = .none, .expect = "window policy 'placement' is unsupported by the built-in 'gtk' host" },
        .{ .name = "overlay-shadow", .source = "overlay_shadow_gtk.zig", .platform = .none, .expect = "window policy 'shadow' is unsupported by the built-in 'gtk' host" },
        .{ .name = "overlay-pointer-decorations", .source = "overlay_pointer_decorations_gtk.zig", .platform = .none, .expect = "window policy 'pointer = passthrough' requires 'decorations = none' on the built-in 'gtk' host" },
        .{ .name = "overlay-no-host", .source = "overlay_none_host.zig", .platform = .none, .expect = "window policy 'decorations' is unsupported by the built-in 'none' host" },
    };
    for (cases) |case| {
        const program = objectWithFabrum(b, b.fmt("compile-error-{s}", .{case.name}), b.fmt("test/compile_errors/{s}", .{case.source}), case.platform, case.target orelse target, optimize);
        // `contains` matches the end of an error's line
        program.expect_errors = .{ .contains = case.expect };
        test_step.dependOn(&program.step);
    }

    // Native Windows is supported, so its namespace must compile successfully.
    const windows = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows });
    const decorated_transparent = objectWithFabrum(b, "compile-error-win32-decorated-transparent", "test/compile_errors/overlay_transparent_decorated_win32.zig", .native, windows, optimize);
    decorated_transparent.expect_errors = .{ .contains = "transparent Win32 windows require decorations = none" };
    test_step.dependOn(&decorated_transparent.step);
    const native_windows = objectWithFabrum(b, "native-windows", "test/compile/native_windows.zig", .native, windows, optimize);
    test_step.dependOn(&native_windows.step);
    const policy_checks = b.step("check-win32-policies", "Compile Win32 policy type identity and expected invalid policy diagnostics without a desktop");
    policy_checks.dependOn(&native_windows.step);
    policy_checks.dependOn(&decorated_transparent.step);

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
    const features: Features = .init(platform, false, false, false, target);
    fabrum.addOptions("fabrum_options", features.options(b));
    features.addSources(b, fabrum);
    addSegmentation(b, fabrum, target, optimize);
    const root = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = fabrum }},
    });
    // COFF cannot combine the Zig and multiple C++ units into one object.
    // A static archive still checks compilation without needing an entry point.
    if (features.win32) return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root });
    return b.addObject(.{ .name = name, .root_module = root });
}
