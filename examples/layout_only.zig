//! `fabrum.layout` on its own, without `fabrum.app`: a layout is declared
//! on a `Context`, computed, and read back as boxes and render commands.
//! Builds with any `-Dplatform`, for any target, and links nothing.
//!
//!     zig build run-layout-only
const std = @import("std");
const Io = std.Io;
const fabrum = @import("fabrum");
const layout = fabrum.layout;

/// Text measured by Latin-character heuristics: enough to see the layout
/// work without a font. A renderer provides the real thing.
const Text = layout.text.HeuristicContent;

/// A header bar of fixed height over a panel that takes the rest, in a
/// column; the header holds a round badge beside its title. The names are
/// the unit IDs, to find the boxes by afterwards.
fn declare(ctx: *layout.Context, title: *Text, body: *Text) !void {
    ctx.begin(.{ .sizing = .fixedXY(320, 160), .axis = .y, .padding = .all(10), .child_gap = 10 });
    defer ctx.end();

    const header = try ctx.openContainerId(.fromString("header"), .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(32) }, .padding = .x(8), .child_gap = 8, .child_alignment = .center_left },
        .background_color = .rgb(60, 90, 160),
        .corner_radius = .uniform(6),
    });
    {
        const badge = try ctx.openContainer(.{ .layout = .{ .sizing = .fixed(16) }, .background_color = .white, .corner_radius = .uniform(8) });
        ctx.closeContainer(badge);
        try ctx.appendContent(&title.content);
    }
    ctx.closeContainer(header);

    const panel = try ctx.openContainerId(.fromString("panel"), .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(8) },
        .background_color = .white,
        .border = .{ .color = .gray(200), .widths = .outside(1) },
    });
    defer ctx.closeContainer(panel);
    try ctx.appendContent(&body.content);
}

/// The texts of the layout. A text asks for no more than its ancestors'
/// width (`Content.limit`): the panel has no bound of its own (it grows),
/// so the body is measured under the root's less the paddings on the way,
/// and wraps at the width the panel finally gives it.
fn texts(title: *Text, body: *Text) void {
    title.* = .init("Hello, layout", .{ .font_size = 16, .color = .white });
    body.* = .init("Text wraps within the width its container gives it.", .{ .font_size = 13 });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var out_buffer: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &out_buffer);
    const out = &stdout.interface;

    // allocates once, for up to `units` units; a layout is rebuilt in it every frame
    var ctx: layout.Context = try .init(gpa, .{ .units = 64 });
    defer ctx.deinit(gpa);

    var title: Text = undefined;
    var body: Text = undefined;
    texts(&title, &body);
    try declare(&ctx, &title, &body);
    try ctx.computeLayout();

    for ([_][]const u8{ "header", "panel" }) |id| {
        const box = ctx.getUnitByStringId(id).?.bbox;
        try out.print("{s}: {d:.0}x{d:.0} at {d:.0},{d:.0}\n", .{ id, box.w, box.h, box.x, box.y });
    }

    // what a renderer draws, in paint order
    var commands = ctx.renderCommands();
    while (commands.next()) |command| {
        const box = command.bbox;
        try out.print("  {t} {d:.0}x{d:.0} at {d:.0},{d:.0}\n", .{ command.data, box.w, box.h, box.x, box.y });
    }
    try out.flush();
}

test "the header is fixed, the panel grows, and the body wraps inside it" {
    var ctx: layout.Context = try .init(std.testing.allocator, .{ .units = 64 });
    defer ctx.deinit(std.testing.allocator);
    var title: Text = undefined;
    var body: Text = undefined;
    texts(&title, &body);
    try declare(&ctx, &title, &body);
    try ctx.computeLayout();

    // the column's children fill its width and share its height: the
    // header keeps its 32 points, the panel takes what is left
    try std.testing.expectEqual(fabrum.Rect.init(10, 10, 300, 32), ctx.getUnitByStringId("header").?.bbox);
    const panel = ctx.getUnitByStringId("panel").?;
    try std.testing.expectEqual(fabrum.Rect.init(10, 52, 300, 98), panel.bbox);

    // the body is the panel's child, wrapped under its inner width into
    // more than one line
    const body_box = ctx.getUnitByIndex(panel.children.items[0]).?.bbox;
    try std.testing.expect(body_box.w <= panel.bbox.w - 16);
    try std.testing.expect(body_box.h >= 2 * 13 * 1.2);
}
