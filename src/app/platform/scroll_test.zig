//! Regression for the native canvas callback's scroll-consumption contract.
const std = @import("std");
const app = @import("../../app.zig");

pub const Root = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open("scroll", .{ .layout = .{ .sizing = .fixedXY(100, 100), .axis = .y }, .scroll = .{} });
        defer ui.close();
        try ui.open("paint", .{ .layout = .{ .sizing = .fixedXY(100, 300) }, .background_color = .white });
        ui.close();
    }
};

pub fn check(comptime Gui: type, comptime mouse: anytype) !void {
    const tree = try app.testing.NativeTree.create(std.testing.allocator);
    defer tree.destroy();
    var gui: Gui = undefined;
    try gui.init(std.testing.allocator, std.testing.io, .{}, .{ .title = "Scroll routing", .visible = false }, .{ .watchdog_ms = null });
    defer gui.deinit();
    // Exercise host dispatch with a scene, without presenting native canvases.
    gui.runtime.reconciler().backend = tree.backend();
    _ = try gui.runtime.frame(Root, .{}, .init(200, 200), .zero);
    // Painted content owns pointer input but cannot consume upward scrolling
    // at the top. A native ancestor must receive that wheel event.
    try std.testing.expect(mouse(&gui, 0, 20, 20, 0, 0, 0));
    try std.testing.expect(!mouse(&gui, 0, 20, 20, 0, 0, -10));
    try std.testing.expect(mouse(&gui, 0, 20, 20, 0, 0, 1000));
    _ = try gui.runtime.frame(Root, .{}, .init(200, 200), .zero);
    try std.testing.expect(!mouse(&gui, 0, 20, 20, 0, 0, 10));
    try std.testing.expect(mouse(&gui, 0, 20, 20, 0, 0, -10));
}
