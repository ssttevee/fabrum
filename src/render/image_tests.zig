//! Shared pixel assertions for the context renderers. Each supplies a
//! 32x32 offscreen canvas; tests do not open a window or compare snapshots.
const std = @import("std");
const testing = std.testing;
const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Rect = fabrum.Rect;

fn bitmap(image: *layout.Image, box: Rect) layout.RenderCommand {
    return .{ .bbox = box, .data = .{ .content = &image.content } };
}

fn rectangle(box: Rect, color: fabrum.Color) layout.RenderCommand {
    return .{ .bbox = box, .data = .{ .rectangle = .{ .color = color, .corner_radius = .{} } } };
}

fn near(expected: [4]u8, actual: [4]u8, tolerance: u8) !void {
    for (expected, actual) |a, b| {
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(a)), @as(f32, @floatFromInt(b)), @as(f32, @floatFromInt(tolerance)));
    }
}

pub fn sources(comptime Canvas: type) !void {
    var canvas = try Canvas.init(1, .zero);
    defer canvas.deinit();
    var image = try layout.Image.init(.{ .data = &.{ 0, 64, 99, 128, 255, 99 }, .width = 2, .height = 2, .stride = 3, .format = .gray8 }, .{ .fit_mode = .crop, .sampling = .nearest });
    try canvas.draw(&.{bitmap(&image, .init(4, 6, 2, 2))}, null);
    try near(.{ 0, 0, 0, 255 }, canvas.pixel(4, 6), 0);
    try near(.{ 64, 64, 64, 255 }, canvas.pixel(5, 6), 0);
    try near(.{ 128, 128, 128, 255 }, canvas.pixel(4, 7), 0);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(5, 7), 0);
    // Empty damage at a fractional origin must remain empty when snapping.
    try canvas.draw(&.{rectangle(.init(0, 0, 32, 32), .white)}, &.{.init(4.3, 6.3, 0, 0)});
    try near(.{ 0, 0, 0, 255 }, canvas.pixel(4, 6), 0);
    try canvas.draw(&.{rectangle(.init(0, 0, 32, 32), .white)}, &.{});
    try near(.{ 0, 0, 0, 255 }, canvas.pixel(4, 6), 0);
    const many: [65]Rect = @splat(.init(4.3, 6.3, 0.1, 0.1));
    try canvas.draw(&.{rectangle(.init(0, 0, 32, 32), .white)}, &many);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(4, 6), 0);
    try near(.{ 64, 64, 64, 255 }, canvas.pixel(5, 6), 0);
    inline for (.{ layout.PixelFormat.rgba8_premultiplied, .bgra8_premultiplied }) |format| {
        image.source = .{ .data = if (format == .rgba8_premultiplied) &.{ 128, 64, 0, 128, 99 } else &.{ 0, 64, 128, 128, 99 }, .width = 1, .height = 1, .stride = 5, .format = format };
        image.style.fit_mode = .stretch;
        try canvas.draw(&.{ rectangle(.init(0, 0, 32, 32), .white), bitmap(&image, .init(4, 6, 4, 4)) }, null);
        try near(.{ 255, 191, 127, 255 }, canvas.pixel(5, 7), 1);
    }
    image.source.stride = 0;
    try testing.expectError(error.InvalidImage, canvas.draw(&.{bitmap(&image, .init(0, 0, 1, 1))}, null));
    image.source.stride = 5;
    try canvas.draw(&.{bitmap(&image, .zero)}, null);
}

pub fn sampling(comptime Canvas: type) !void {
    var canvas = try Canvas.init(1, .zero);
    defer canvas.deinit();
    var image = try layout.Image.init(.{ .data = &.{ 0, 255 }, .width = 2, .height = 1, .stride = 2, .format = .gray8 }, .{ .fit_mode = .stretch, .sampling = .nearest });
    const commands = [_]layout.RenderCommand{ rectangle(.init(0, 0, 32, 32), .white), bitmap(&image, .init(0, 0, 4, 4)) };
    try canvas.draw(&commands, null);
    try near(.{ 0, 0, 0, 255 }, canvas.pixel(0, 1), 0);
    try near(.{ 0, 0, 0, 255 }, canvas.pixel(1, 1), 0);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(2, 1), 0);
    image.style.sampling = .smooth;
    try canvas.draw(&commands, null);
    const left = canvas.pixel(1, 1)[0];
    const right = canvas.pixel(2, 1)[0];
    try testing.expect(left > 0 and left < right and right < 255);
    image.source = .{ .data = &.{ 128, 0, 0, 128, 0, 0, 0, 0 }, .width = 2, .height = 1, .stride = 8, .format = .rgba8_premultiplied };
    var transparent = try Canvas.init(1, .zero);
    defer transparent.deinit();
    try transparent.draw(commands[1..], null);
    const a = transparent.pixel(1, 1);
    const b = transparent.pixel(2, 1);
    // Red and alpha stay equal through interpolation towards transparency;
    // straight-color interpolation would introduce dark fringes here.
    try testing.expect(a[3] > b[3] and b[3] > 0 and a[3] < 128);
    try near(.{ a[3], 0, 0, a[3] }, a, 1);
    try near(.{ b[3], 0, 0, b[3] }, b, 1);
}

pub fn placement(comptime Canvas: type) !void {
    var canvas = try Canvas.init(1, .zero);
    defer canvas.deinit();
    const data = [_]u8{ 10, 20, 30, 40, 10, 20, 30, 40 };
    var image = try layout.Image.init(.{ .data = &data, .width = 4, .height = 2, .stride = 4, .format = .gray8 }, .{ .sampling = .nearest, .alignment = .bottom_right });
    const background = rectangle(.init(0, 0, 32, 32), .white);
    image.style.fit_mode = .contain;
    try canvas.draw(&.{ background, bitmap(&image, .init(4, 4, 4, 4)) }, null);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(4, 5), 0);
    try near(.{ 10, 10, 10, 255 }, canvas.pixel(4, 6), 0);
    image.style.fit_mode = .cover;
    try canvas.draw(&.{ background, bitmap(&image, .init(4, 4, 2, 2)) }, null);
    try near(.{ 30, 30, 30, 255 }, canvas.pixel(4, 4), 0);
    try near(.{ 40, 40, 40, 255 }, canvas.pixel(5, 5), 0);
    image.style.fit_mode = .crop;
    try canvas.draw(&.{ background, bitmap(&image, .init(4, 4, 2, 2)) }, null);
    try near(.{ 30, 30, 30, 255 }, canvas.pixel(4, 4), 0);
    image.style.fit_mode = .stretch;
    try canvas.draw(&.{ background, bitmap(&image, .init(4, 4, 4, 4)) }, null);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(8, 4), 0);
    try near(.{ 255, 255, 255, 255 }, canvas.pixel(4, 8), 0);
    try near(.{ 40, 40, 40, 255 }, canvas.pixel(7, 7), 0);

    // Snapping includes the target's scale and fractional translation.
    var scaled = try Canvas.init(2, .init(0.25, 0.25));
    defer scaled.deinit();
    image.source.scale = 2;
    image.style = .{ .fit_mode = .crop, .sampling = .nearest, .alignment = .top_left, .snap_to_pixels = true };
    try scaled.draw(&.{bitmap(&image, .init(1.2, 2.2, 3, 3))}, null);
    try near(.{ 10, 10, 10, 255 }, scaled.pixel(3, 5), 0);
    try near(.{ 40, 40, 40, 255 }, scaled.pixel(6, 6), 0);
    try near(.{ 0, 0, 0, 0 }, scaled.pixel(7, 6), 0);
}

pub fn clipping(comptime Canvas: type) !void {
    var canvas = try Canvas.init(1, .zero);
    defer canvas.deinit();
    var image = try layout.Image.init(.{ .data = &.{80}, .width = 1, .height = 1, .stride = 1, .format = .gray8 }, .{ .fit_mode = .stretch });
    const commands = [_]layout.RenderCommand{
        .{ .bbox = .init(10, 0, 10, 1), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = false } } },
        .{ .bbox = .init(0, 12, 1, 8), .data = .{ .scissor_start = .{ .horizontal = false, .vertical = true } } },
        bitmap(&image, .init(2, 2, 28, 28)),
        .{ .data = .scissor_end },
        .{ .data = .scissor_end },
        rectangle(.init(15, 15, 12, 12), .rgb(255, 0, 0)),
    };
    try canvas.draw(&commands, null);
    try near(.{ 80, 80, 80, 255 }, canvas.pixel(11, 13), 0);
    try near(.{ 255, 0, 0, 255 }, canvas.pixel(16, 16), 0);
    try near(.{ 0, 0, 0, 0 }, canvas.pixel(9, 13), 0);
    try near(.{ 0, 0, 0, 0 }, canvas.pixel(11, 11), 0);
    try near(.{ 0, 0, 0, 0 }, canvas.pixel(20, 13), 0);
    try near(.{ 0, 0, 0, 0 }, canvas.pixel(11, 20), 0);
}

pub fn damage(comptime Canvas: type) !void {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var partial = try Canvas.init(scale, .zero);
        defer partial.deinit();
        var full = try Canvas.init(scale, .zero);
        defer full.deinit();
        var tracker: layout.Damage = .{};
        defer tracker.deinit(testing.allocator);
        var bytes = [_]u8{ 128, 32, 0, 128, 0, 0, 96, 192, 0, 0, 0, 0, 255, 255, 255, 255 };
        var image = try layout.Image.init(.{ .data = &bytes, .width = 2, .height = 2, .stride = 8, .format = .rgba8_premultiplied }, .{ .fit_mode = .cover });
        const viewport: fabrum.Vec2 = .init(32 / scale, 32 / scale);
        for (0..9) |frame| {
            var commands = [_]layout.RenderCommand{
                rectangle(.init(0, 0, 32, 32), .rgb(20, 40, 60)),
                .{ .bbox = .init(3, 4, 15, 16), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } },
                bitmap(&image, .init(1.3, 2.2, 10.5, 12.7)),
                .{ .data = .scissor_end },
                rectangle(.init(9, 9, 5, 4), .rgba(240, 20, 30, 160)),
            };
            if (frame >= 2) {
                bytes[0] = 20;
                image.revision = 1;
            }
            if (frame >= 3) image.style.sampling = .nearest;
            if (frame >= 4) image.style.snap_to_pixels = true;
            if (frame >= 5) commands[2].bbox.x = 6.8;
            if (frame >= 6) commands[1].bbox.w = 8;
            if (frame >= 7) image.style.fit_mode = .crop;
            const draw_commands = if (frame == 8) commands[0..1] else &commands;
            const regions = try tracker.update(testing.allocator, draw_commands, viewport);
            if (frame == 1) try testing.expectEqual(0, regions.len);
            if (frame == 2) try testing.expect(regions.len > 0);
            try partial.draw(draw_commands, if (frame == 0) null else regions);
            try full.draw(draw_commands, null);
            for (0..32) |y| for (0..32) |x| {
                const expected = full.pixel(@intCast(x), @intCast(y));
                const actual = partial.pixel(@intCast(x), @intCast(y));
                if (!std.meta.eql(expected, actual)) std.debug.print("image damage: scale {d} frame {d} pixel {d},{d}\n", .{ scale, frame, x, y });
                try testing.expectEqual(expected, actual);
            };
        }
    }
}
