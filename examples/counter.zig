//! A counter with the platform's own controls: push buttons from
//! `app.widgets` (an `NSButton` on macOS, a `GtkButton` with GTK) around
//! text that fabrum draws. It runs in a window on the AppKit platform
//! (`-Dplatform=native` on macOS) and on the GTK platform
//! (`-Dplatform=gtk`); its tests run on every platform, without a window,
//! against `app.testing.Harness`.
//!
//!     zig build examples && ./zig-out/bin/counter
//!     zig build run-counter
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

/// The window for this build's platform. Platforms without a toolkit have
/// no window: see `headless.zig` for hosting the runtime yourself.
const Gui = switch (app.platform.kind) {
    .appkit => app.platform.appkit.App(Counter),
    .gtk => app.platform.gtk.App(Counter),
    .win32 => app.platform.win32.App(Counter),
    else => @compileError("examples/counter.zig needs a toolkit platform: build fabrum with -Dplatform=native (macOS or Windows) or -Dplatform=gtk"),
};

pub fn main(init: std.process.Init) !void {
    // `run` never returns, so the app lives as long as the process
    const gui = try init.gpa.create(Gui);
    try gui.init(init.gpa, init.io, .{ .step = 1 }, .{ .title = "Counter", .width = 320, .height = 200 }, .{});
    gui.run();
}

// The harness runs the component in a runtime with a fixed viewport, and
// drives it as a user would. Native widgets live in a fake tree
// (`Harness.tree`), on every platform, so the tests need no window.

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
