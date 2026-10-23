const std = @import("std");

// docs/guides/first-app.md, "Wire the build"
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const Platform = enum { native, gtk, none };
    const platform = b.option(Platform, "platform", "Window toolkit or custom host") orelse .native;
    const dependency = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = platform });
    const fabrum = dependency.module("fabrum");
    const exe = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum }},
        }),
    });
    if (target.result.os.tag == .windows and platform == .native)
        exe.win32_manifest = dependency.path("src/app/platform/win32/windows.manifest");
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run counter").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Test counter").dependOn(&b.addRunArtifact(tests).step);
}
// end-guide-snippet

// docs/guides/writing-a-renderer.md, "Let the application inject fabrum"
pub fn addRenderer(exe: *std.Build.Step.Compile, renderer: *std.Build.Module, fabrum: *std.Build.Module) void {
    renderer.addImport("fabrum", fabrum);
    exe.root_module.addImport("fabrum", fabrum);
    exe.root_module.addImport("my-renderer", renderer);
}
// end-guide-snippet

// docs/guides/writing-a-platform.md, "Inject the same module throughout the package"
pub fn addFabrum(platform: *std.Build.Module, fabrum: *std.Build.Module) void {
    platform.addImport("fabrum", fabrum);
    platform.import_table.get("my-renderer").?.addImport("fabrum", fabrum);
}
// end-guide-snippet
