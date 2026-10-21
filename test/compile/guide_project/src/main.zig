const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const widgets = app.widgets;

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

const Window = struct {
    const Gui = switch (app.platform.kind) {
        .appkit => app.platform.appkit.App(Counter),
        .gtk => app.platform.gtk.App(Counter),
        else => @compileError("This program needs AppKit or GTK; use a custom host for none"),
    };

    pub fn main(init: std.process.Init) !void {
        const gui = try init.gpa.create(Gui);
        try gui.init(init.gpa, init.io, .{ .step = 1 }, .{ .title = "Counter", .width = 320, .height = 200 }, .{});
        gui.run();
    }
};

test "guide counter increments without a window" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{ .step = 2 }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Add");
    try h.expectText("Count: 2");
    try std.testing.expectEqual(2, h.state().count);
}

pub fn main(init: std.process.Init) !void {
    try Window.main(init);
}

test "window entry point compiles" {
    if (comptime app.platform.kind == .appkit or app.platform.kind == .gtk) _ = &main;
}
