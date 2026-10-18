//! Lays out two boxes with `fabrum.layout` alone, to check that it builds
//! for any OS with the `none` platform.
const std = @import("std");
const layout = @import("fabrum").layout;

export fn fabrum_layout_only(width: f32, height: f32) f32 {
    var buffer: [1 << 20]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const gpa = fba.allocator();
    var ctx = layout.Context.init(gpa, .{ .units = 16 }) catch return -1;
    defer ctx.deinit(gpa);
    ctx.begin(.{ .sizing = .fixedXY(width, height) });
    const row = ctx.openContainer(.{ .layout = .{ .sizing = .grow(.{}), .child_gap = 4 } }) catch return -1;
    ctx.closeContainer(ctx.openContainer(.{ .layout = .{ .sizing = .grow(.{}) } }) catch return -1);
    ctx.closeContainer(ctx.openContainer(.{ .layout = .{ .sizing = .grow(.{}) } }) catch return -1);
    ctx.closeContainer(row);
    ctx.end();
    ctx.computeLayout() catch return -1;
    return ctx.get(3).bbox.x;
}
