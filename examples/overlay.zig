//! Run `zig build run-overlay` on AppKit, or
//! `zig build run-overlay -Dplatform=gtk` for the explicitly reduced GTK variant.
const std = @import("std");
const app = @import("fabrum").app;

pub const Badge = struct {
    pub const Props = struct { label: []const u8 };
    pub fn view(ui: *app.Ui, props: Props) !void {
        // Leave the window's remaining pixels transparent.
        try ui.open(null, .{
            .layout = .{ .padding = .all(20) },
            .background_color = .rgb(35, 70, 130),
            .corner_radius = .uniform(16),
        });
        defer ui.close();
        try ui.text(props.label, .{ .font_size = 24, .color = .white });
    }
};

// These are separate named policies: GTK does not promise floating,
// nonactivation, global positioning, or suppression of compositor shadows.
const appkit_overlay: app.WindowPolicy = .{
    .decorations = .none,
    .background = .transparent,
    .level = .floating,
    .activation = .never,
    .pointer = .passthrough,
    .shadow = .none,
    .placement = .positioned,
};
const gtk_transparent_badge: app.WindowPolicy = .{
    .decorations = .none,
    .background = .transparent,
    .pointer = .passthrough,
};
const Gui = app.platform.current;
const Overlay = Gui.Window(Badge, switch (app.platform.kind) {
    .appkit => appkit_overlay,
    .gtk => gtk_transparent_badge,
    else => @compileError("overlay example requires AppKit or GTK"),
});

const Controls = struct {
    pub const Props = struct { host: *Gui.Application, overlay: app.WindowId };
    pub const State = struct {};
    pub const Msg = union(enum) { show, hide, quit };
    pub fn update(_: *State, msg: Msg, ctx: *app.Update(Controls)) void {
        const props = ctx.props;
        switch (msg) {
            .show => _ = props.host.show(props.overlay),
            .hide => _ = props.host.hide(props.overlay),
            .quit => props.host.quit(),
        }
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        const on = ui.messages(Controls);
        try ui.open(null, .{ .layout = .{ .axis = .y, .padding = .all(20), .child_gap = 12 } });
        defer ui.close();
        try ui.text("The badge passes pointer input to windows beneath it.", .{});
        try app.widgets.button(ui, "show", .{ .label = "Show badge", .on_click = on.bind(.show) });
        try app.widgets.button(ui, "hide", .{ .label = "Hide badge", .on_click = on.bind(.hide) });
        try app.widgets.button(ui, "quit", .{ .label = "Quit", .on_click = on.bind(.quit) });
    }
};

pub fn main(init: std.process.Init) !void {
    const host = try init.gpa.create(Gui.Application);
    defer init.gpa.destroy(host);
    try host.init(init.gpa, init.io, .{});
    defer host.deinit();
    const label = if (app.platform.kind == .appkit) "Floating AppKit overlay" else "GTK transparent badge";
    const overlay = try host.open(Overlay, .{ .label = label }, .{
        .title = label,
        .width = 400,
        .height = 240,
        .visible = false,
        .position = if (app.platform.kind == .appkit) .{ .x = 80, .y = 80 } else null,
    }, .{});
    _ = try host.openWindow(Controls, .{ .host = host, .overlay = overlay }, .{
        .title = "Overlay controls",
        .width = 480,
        .height = 280,
    }, .{});
    _ = host.show(overlay);
    host.run();
}
