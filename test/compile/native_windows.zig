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
    _ = &Gui.init;
    _ = &Gui.deinit;
    _ = &Gui.run;
    _ = &host.Application.init;
    _ = &host.Application.run;
    fabrum.layout.checkRenderer(fabrum.render.Direct2D);
}
