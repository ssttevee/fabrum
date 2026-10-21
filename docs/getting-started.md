# Getting started

A first fabrum app from an empty directory to a window, on AppKit and GTK,
then the same component hosted without a window, and its tests. Everything
quoted here is in [`examples/`](../examples/), which `zig build examples`
builds and `zig build test` tests.

## Prerequisites

- Zig 0.17.0.
- For a window: macOS with the Xcode command line tools (the `native`
  platform is AppKit there), or GTK 4 with its development files and
  `pkg-config` (the `gtk` platform anywhere, and `native` on Linux). With
  Homebrew's GTK on macOS, put Homebrew's `pkgconf` first on `PATH` when
  building.
- For no window at all (`none`): nothing.

## A project

```sh
mkdir hello && cd hello
zig init
zig fetch --save git+https://github.com/ssttevee/fabrum
```

Replace `build.zig` with:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fabrum, built for the platform the app wants: `native` is AppKit on
    // macOS and GTK 4 on Linux; `gtk` is GTK 4 anywhere; `none` hosts
    // the runtime yourself with drawn widgets
    const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .native });

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fabrum", .module = fabrum.module("fabrum") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
```

To let `zig build -Dplatform=...` choose, declare the option yourself and
pass it on, as the Kitchen's `build.zig` does; fabrum's own default is
`native`.

## The component

`src/main.zig` is [`examples/counter.zig`](../examples/counter.zig). The
component first:

```zig
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const widgets = app.widgets;

/// A stateful component: `State` persists across frames, `Msg` is what
/// changes it in `update`, and `view` describes the screen from it.
pub const Counter = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { add: i32, reset };
    pub const Props = struct { step: i32 = 1 };

    pub fn update(state: *State, msg: Msg, _: *app.Update(Counter)) void {
        switch (msg) {
            .add => |amount| state.count += amount,
            .reset => state.count = 0,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        // messages bound to this instance, for the buttons to fire
        const on = ui.messages(Counter);
        // the platform's colors and font size, so drawn text matches the controls
        const theme = ui.use(app.native.Theme);

        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(16), .child_gap = 12, .child_alignment = .center } });
        defer ui.close();

        try ui.print(.{ .font_size = theme.font_size * 2, .color = theme.text }, "{d}", .{state.count});

        try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        try widgets.button(ui, "minus", .{ .label = "\u{2212}", .on_click = on.bind(.{ .add = -props.step }) });
        try widgets.button(ui, "plus", .{ .label = "+", .on_click = on.bind(.{ .add = props.step }) });
        try widgets.button(ui, "reset", .{ .label = "Reset", .on_click = on.bind(.reset), .enabled = state.count != 0 });
    }
};
```

A component is a namespace with `Props` and `view`. With a `State` it is
stateful, and may have a `Msg` and an `update`; `update` is the only place
state changes. Every frame the runtime calls `view` with the current state and
props, and the view describes the screen:

- `ui.open(key, container)` opens a box and `ui.close()` closes it; `defer`
  keeps them paired. `container` is the layout (`sizing`, `axis`, `padding`,
  `child_gap`, `child_alignment`), the look (`background_color`,
  `corner_radius`, `border`) and the events (`on_click`, `on_pointer`, focus).
  A key (a string, an integer, an enum) identifies an element across frames
  for hover, focus and events; `null` makes an anonymous box.
- `ui.print(style, fmt, args)` and `ui.text(string, style)` add text, drawn
  by fabrum on the platform's canvas.
- `widgets.button(ui, key, options)` declares a native button. The runtime
  reconciles native controls by key across frames: one `NSButton` is made
  for `"plus"` the first time and updated after, never remade.
- `ui.messages(Counter)` binds messages to this instance. `on.bind(.reset)`
  makes an `Action` (a `Handler(void)`) for a tag without payload;
  `on.bind(.{ .add = 1 })` binds a payload; `on.handler(.add)` would make a
  `Handler(i32)` for someone else to fire with a value.
- `ui.use(T)` reads a value provided to the tree. The runtime provides the
  platform's `app.native.Theme`, `app.Capabilities` and `app.Keymap`; apps
  provide their own with `Runtime.Options.provide` or `ui.provide`.

## The window

The rest of the file:

```zig
/// The window for this build's platform. Platforms without a toolkit have
/// no window: see `headless.zig` for hosting the runtime yourself.
const Gui = switch (app.platform.kind) {
    .appkit => app.platform.appkit.App(Counter),
    .gtk => app.platform.gtk.App(Counter),
    else => @compileError("examples/counter.zig needs a toolkit platform: build fabrum with -Dplatform=native (macOS) or -Dplatform=gtk"),
};

pub fn main(init: std.process.Init) !void {
    // `run` never returns, so the app lives as long as the process
    const gui = try init.gpa.create(Gui);
    try gui.init(init.gpa, init.io, .{ .step = 1 }, .{ .title = "Counter", .width = 320, .height = 200 }, .{});
    gui.run();
}
```

`app.platform.kind` is the platform this build resolved to, known at compile
time, so a program picks its toolkit's `App` with a `switch`. `App(Root)`
owns the runtime, the canvas's renderer (Quartz on AppKit, Cairo on GTK) and
the native backend; `init` takes the allocator, the `std.Io`, the root
props, the window (`title`, `width`, `height`, `min_width`, `min_height`,
`dark`) and `InitOptions` (`provide` for root values, `context` for the
layout's capacity, `on_terminate`). `run` opens the window and runs the
toolkit's event loop; it does not return.

```sh
zig build run                                        # macOS: AppKit
PATH=/opt/homebrew/bin:$PATH zig build run -Dplatform=gtk   # GTK 4, with the option passed through
```

(The second line assumes your `build.zig` forwards a `platform` option; in
the fabrum checkout itself, `zig build run-counter -Dplatform=gtk` does.)

## Without a window

The `none` platform has no window: your program is the host. It runs the
runtime's frames on its own clock, feeds it input, and takes render commands
and damage regions out for a renderer to draw. The core of
[`examples/headless.zig`](../examples/headless.zig):

```zig
/// The runtime with the default text, `layout.text.HeuristicContent`. A
/// host with a renderer passes the renderer's: `.{ .Text = Renderer.Text }`.
const Runtime = app.Runtime(.{});
```

```zig
    /// Runs the frames that are due, then prints what the last one drew
    /// and which regions changed since the previous print.
    fn frames(self: *Host) !void {
        var ran: usize = 0;
        while (self.rt.nextFrame()) |due| {
            // null means wait for input; a later time means wait until then
            if (due.nanoseconds > self.now.nanoseconds or ran == 4) break;
            _ = try self.rt.frame(Root, .{}, viewport, self.now);
            self.now = self.now.addDuration(.fromMilliseconds(16));
            ran += 1;
        }
        if (ran == 0) return;

        try self.out.print("frame at {d} ms: {d} render commands\n", .{ @divTrunc(self.now.nanoseconds, std.time.ns_per_ms), self.rt.commands().len });
        for (self.rt.commands()) |command| try printCommand(self.out, command);

        // what a renderer must redraw, and how an e-ink host should show it
        const damage = try self.rt.damage();
        try self.out.print("  damage ({t} refresh):", .{self.rt.refresh()});
        for (damage) |r| try self.out.print(" {d:.0}x{d:.0}@{d:.0},{d:.0}", .{ r.w, r.h, r.x, r.y });
        try self.out.writeAll("\n");
    }
```

Without a native backend, `app.widgets` are drawn by fabrum, so the same
widget calls work. A real host replaces the printing with
`fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, damage)` and a
renderer package such as fabrum-renderer-z2d; see
[platforms.md](platforms.md) for the whole contract and
[renderers.md](renderers.md) for the renderer.

```sh
zig build run-headless -Dplatform=none
```

## Tests

`app.testing.Harness` runs a component in a runtime with a fixed viewport and
no window, on every platform, and drives it as a user would. The counter's
tests:

```zig
test "the buttons count, as native widgets" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    try h.expectText("0");

    const root = h.root();
    try h.clickNative(root.native("plus"));
    try h.clickNative(root.native("plus"));
    try h.expectText("2");
    try std.testing.expectEqual(2, h.state().count);

    try h.clickNative(root.native("minus"));
    try std.testing.expectEqual(1, h.state().count);

    // the Reset button is disabled at zero, and enabled otherwise
    try std.testing.expect((try h.expectWidget(root.native("reset"))).spec.button.enabled);
    try h.clickNative(root.native("reset"));
    try h.expectText("0");
    try std.testing.expect(!(try h.expectWidget(root.native("reset"))).spec.button.enabled);
}

test "the same component with drawn widgets, as on the none platform" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{ .step = 5 }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();

    // drawn buttons are text in a box, so they are clicked by their label
    try h.click("+");
    try h.click("+");
    try h.expectText("10");
    try h.click("Reset");
    try h.expectText("0");
}
```

Native widgets live in a fake tree (`h.tree`, an `app.testing.NativeTree`)
that records what fabrum made of them; `clickNative`, `typeText`, `slide`,
`selectNative` and the rest drive them, and `expectWidget` reads their spec.
Drawn elements are clicked by their text (`click`) or by key
(`clickElement(h.root().element("plus"))`). Every input is followed by a
frame, so queries always see the result. Time stands still unless
`h.advance(duration)` moves it.

```sh
zig build test
```

For blocking work, use `try ctx.run(function, args, handler)` from
`update`, or `try ui.task(key, .{}, function, args, handler)` in `view`. Only
the task function receives `*app.Task` with I/O. The harness queues tasks;
`h.runTasks()` executes them and `h.completeTask(key, function, result)`
fakes a result. See [Concurrency](app.md#concurrency) and the tested
[`tasks.zig`](../examples/tasks.zig) example.

## Where next

- [app.md](app.md) for everything the runtime does: messages and handlers,
  contexts, the widget set, input, focus, scrolling, text editing, dialogs
  and menus, timers, capabilities, refresh hints and the harness.
- [layout.md](layout.md) for the layout engine, with or without `app`.
- [platforms.md](platforms.md) and [renderers.md](renderers.md) for hosting
  the runtime yourself.
- [examples.md](examples.md) for the Kitchen and OpenEtcher, real programs
  that show the API at scale.
