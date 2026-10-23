# Build your first app

Use this guide to start a Zig 0.17.0 project with a toolkit window. On macOS,
`native` selects AppKit; on Linux it selects GTK 4, and on Windows Win32. `gtk` selects GTK 4
explicitly. Install the Xcode command line tools for AppKit, or GTK 4 and
its development files and `pkg-config` for GTK. On Homebrew, put
`/opt/homebrew/bin` first on `PATH` so its `pkgconf` can resolve GTK's
private requirements. The full build matrix is in the
[platform reference](../platforms.md).

## Create the project

In a new directory, run:

```sh
mkdir counter
cd counter
zig init
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
```

Use the Zig 0.17.0 executable for all these commands. `zig init` supplies
`build.zig.zon`, including your package's own fingerprint. `zig fetch
--save` adds a `fabrum` entry to its `dependencies`, with a URL and a
content hash. Keep those generated values; there is no universal hash to
paste into a guide. Fetching `#trunk` chooses a revision now; committing the
resulting manifest pins the fetched content. Fetch again deliberately when
updating fabrum. Keep your app's `src` in the manifest's `paths`.

## Wire the build

Replace `build.zig` with a file starting with `const std = @import("std");`,
followed by this function:

```zig
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
```

The option belongs to your application: declaring it is what makes
`zig build -Dplatform=gtk` work. Forward it to `b.dependency`, then import
that dependency's `fabrum` module into the executable. Supplying only a
module name without the import gives a `no module named 'fabrum'` error.
Do not ask a renderer or another package to construct a second fabrum;
[inject the same module](writing-a-renderer.md#let-the-application-inject-fabrum).

This build exposes `none` for headless tests. A window executable still
needs a toolkit; use the [hosting guide](hosting.md) to make a `none`
executable. `qt`, `sdl` and native web hosts are not
implemented and fail at compile time with a remedy message.

## Write the component

Replace `src/main.zig` with a file that declares `std`, `fabrum`, `app`
and `widgets` as described in the [example conventions](README.md#read-and-run-the-examples),
then add this component:

```zig
const Counter = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { add };
    pub const Props = struct { step: i32 = 1 };

    pub fn update(state: *State, _: Msg, ctx: *app.Update(Counter)) void {
        state.count += ctx.props.step;
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("counter", .{ .layout = .{ .axis = .y, .child_gap = 8, .padding = .all(16) } });
        defer ui.close();
        try ui.print(.{}, "Count: {d}", .{state.count});
        try widgets.button(ui, "add", .{ .label = "Add", .on_click = ui.messages(Counter).bind(.add) });
    }
};
```

`State` persists between frames. The button queues an `.add` message;
`update` changes the state; `view` describes the next frame. Changing props
does not reinitialize state. A real widget needs a stable key: `"add"`
identifies this button across frames. The `defer` closes the column even
when adding text or a child fails.

## Open a window

Add this namespace after `Counter`:

```zig
const Window = struct {
    const Gui = switch (app.platform.kind) {
        .appkit => app.platform.appkit.App(Counter),
        .gtk => app.platform.gtk.App(Counter),
        .win32 => app.platform.win32.App(Counter),
        else => @compileError("This program needs AppKit, GTK or Win32; use a custom host for none"),
    };

    pub fn main(init: std.process.Init) !void {
        const gui = try init.gpa.create(Gui);
        try gui.init(init.gpa, init.io, .{ .step = 1 }, .{ .title = "Counter", .width = 320, .height = 200 }, .{});
        gui.run();
    }
};
```

Finally add the file-scope entry point
`pub fn main(init: std.process.Init) !void { try Window.main(init); }`.
The [complete fixture](../../test/compile/guide_project/src/main.zig)
contains the imports, component, namespace, entry point and tests together.

The compile-time switch chooses `appkit.App(Counter)`, `gtk.App(Counter)` or `win32.App(Counter)`.
All take the allocator, I/O, root props, window options and initialization
options. Allocate the `App` at a stable address: callbacks keep its address.
`run` does not return; clean up application-owned services with
`on_terminate` when needed, after runtime tasks have been canceled and joined.
See [shutdown](concurrency.md#shut-down-in-lifetime-order).

Run it from the new project's directory:

```sh
zig build run
zig build run -Dplatform=gtk
```

Choose one command for your toolkit. With Homebrew GTK, run the second as
`PATH=/opt/homebrew/bin:$PATH zig build run -Dplatform=gtk`. A missing
framework or `gtk4` pkg-config failure is a development-environment problem;
resolve it before changing the component.

## Test the first interaction

Add this test to the same file:

```zig
test "guide counter increments without a window" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{ .step = 2 }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Add");
    try h.expectText("Count: 2");
    try std.testing.expectEqual(2, h.state().count);
}
```

Run `zig build test`, or `zig build test -Dplatform=none`. The latter
links no GUI toolkit for this project. The harness measures text, delivers
input and runs the runtime, but creates no window. Using `.drawn` makes
`click("Add")` find drawn text on every build; native widgets are tested
through their native IDs, as shown in [testing](testing.md).

Next, split the view into [components](components.md), or give it a
[responsive layout](layout.md).
