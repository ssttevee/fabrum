//! Positive coverage for the native Windows namespace and renderer contract.
const fabrum = @import("fabrum");
const std = @import("std");

const Root = struct {
    pub const Props = struct {};
    pub fn view(ui: *fabrum.app.Ui, _: Props) !void {
        try fabrum.app.widgets.button(ui, "button", .{ .label = "Windows" });
    }
};

comptime {
    std.debug.assert(fabrum.app.platform.kind == .win32);
    std.debug.assert(fabrum.app.platform.implemented(.win32));
    const host = fabrum.app.platform.win32;
    const Gui = host.App(Root);
    std.debug.assert(Gui == host.Window(Root, .{}));
    std.debug.assert(Gui == host.WindowWith(Root, fabrum.render.Direct2D, .{}));
    const Borderless = host.Window(Root, .{ .decorations = .none });
    const Transparent = host.Window(Root, .{ .decorations = .none, .background = .transparent });
    const Floating = host.Window(Root, .{ .level = .floating });
    const Nonactivating = host.Window(Root, .{ .activation = .never });
    const Passthrough = host.Window(Root, .{ .decorations = .none, .pointer = .passthrough });
    const Positioned = host.Window(Root, .{ .placement = .positioned });
    const Shadowless = host.Window(Root, .{ .shadow = .none });
    const descriptors = .{ Gui, Borderless, Transparent, Floating, Nonactivating, Passthrough, Positioned, Shadowless };
    for (descriptors, 0..) |A, i| {
        for (descriptors, 0..) |B, j| std.debug.assert((A == B) == (i == j));
    }
    _ = &Gui.init;
    _ = &Gui.deinit;
    _ = &Gui.run;
    _ = &host.Application.init;
    _ = &host.Application.run;
    fabrum.layout.checkRenderer(fabrum.render.Direct2D);
}
