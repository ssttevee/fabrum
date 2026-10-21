//! Quartz renderer for fabrum.
//!
//! This renderer uses macOS Core Graphics (Quartz) to render layout commands.
//! It supports rectangles, borders, text, pictures (SVG paths and bitmaps),
//! and per-axis clipping.
//!
//! It is a `fabrum.layout` renderer for `.cg_context` surfaces: draw with
//! `fabrum.layout.draw(&renderer, commands, .cg_context, cg, damage)`, into
//! a context whose user space is fabrum's (top left, y down; see
//! `CGContext.flipCanvas` for views that aren't flipped).

const std = @import("std");
const fabrum = @import("../root.zig");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const BorderWidths = fabrum.layout.BorderWidths;
const LayoutContent = fabrum.layout.Content;

pub const content = @import("quartz/content.zig");

const Picture = content.Picture;
const CGImage = Picture.CGImage;

const Font = @import("quartz/text.zig").Font;

allocator: std.mem.Allocator,
text_context: content.Text.Context,

const Renderer = @This();

pub const CGContext = opaque {
    pub fn flipCanvas(self: *CGContext, height: f64) void {
        quartz_renderer_flip_canvas(self, height);
    }

    fn renderRectangle(cg_context: *CGContext, bbox: Rect, corner_radius: CornerRadius, color: Color) void {
        const cr = corner_radius.fitted(bbox.w, bbox.h);

        if (isAllZero(cr)) {
            quartz_renderer_fill_rect(
                cg_context,
                bbox.x,
                bbox.y,
                bbox.w,
                bbox.h,
                color.r,
                color.g,
                color.b,
                color.a,
            );
        } else {
            quartz_renderer_fill_rounded_rect(
                cg_context,
                bbox.x,
                bbox.y,
                bbox.w,
                bbox.h,
                cr.top_left,
                cr.top_right,
                cr.bottom_right,
                cr.bottom_left,
                color.r,
                color.g,
                color.b,
                color.a,
            );
        }
    }

    fn renderBorder(cg_context: *CGContext, bbox: Rect, b: RenderCommand.Data.Border) void {
        const bw = b.widths;
        const color = b.color;

        if (bw.isZero()) return;

        if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
            const half_width = bw.left / 2.0;
            const inset_bbox = Rect{
                .x = bbox.x + half_width,
                .y = bbox.y + half_width,
                .w = bbox.w - bw.left,
                .h = bbox.h - bw.top,
            };

            const cr = b.corner_radius.fitted(bbox.w, bbox.h);

            if (isAllZero(cr)) {
                quartz_renderer_stroke_rect(
                    cg_context,
                    inset_bbox.x,
                    inset_bbox.y,
                    inset_bbox.w,
                    inset_bbox.h,
                    bw.left,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            } else {
                const adjusted_cr = CornerRadius{
                    .top_left = @max(0, cr.top_left - half_width),
                    .top_right = @max(0, cr.top_right - half_width),
                    .bottom_right = @max(0, cr.bottom_right - half_width),
                    .bottom_left = @max(0, cr.bottom_left - half_width),
                };

                quartz_renderer_stroke_rounded_rect(
                    cg_context,
                    inset_bbox.x,
                    inset_bbox.y,
                    inset_bbox.w,
                    inset_bbox.h,
                    adjusted_cr.top_left,
                    adjusted_cr.top_right,
                    adjusted_cr.bottom_right,
                    adjusted_cr.bottom_left,
                    bw.left,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }
        } else {
            if (bw.top > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y,
                    bbox.w,
                    bw.top,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.bottom > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y + bbox.h - bw.bottom,
                    bbox.w,
                    bw.bottom,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.left > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y,
                    bw.left,
                    bbox.h,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.right > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x + bbox.w - bw.right,
                    bbox.y,
                    bw.right,
                    bbox.h,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }
        }
    }

    fn renderContent(self: *CGContext, bbox: Rect, c: *LayoutContent) !void {
        if (content.Text.asTextContent(c)) |text_content| {
            try self.renderText(bbox, text_content);
        } else if (Picture.asPictureContent(c)) |picture_content| {
            try self.renderPicture(bbox, picture_content);
        }
    }

    fn renderPicture(self: *CGContext, bbox: Rect, picture_content: *const Picture) !void {
        switch (picture_content.source) {
            .vector => |vector| try self.renderVectorPicture(bbox, vector, picture_content.style),
            .bitmap => |bitmap| self.renderBitmapPicture(bbox, bitmap, picture_content.style),
        }
    }

    fn renderVectorPicture(self: *CGContext, bbox: Rect, vector: Picture.Source.Vector, style: Picture.Style) !void {
        var scale_x: f32 = bbox.w / vector.viewbox.w;
        var scale_y: f32 = bbox.h / vector.viewbox.h;
        var offset_x: f32 = bbox.x;
        var offset_y: f32 = bbox.y;

        switch (style.fit_mode) {
            .contain, .cover => {
                // one scale for both axes, and the picture centered in the box
                const scale = if (style.fit_mode == .contain) @min(scale_x, scale_y) else @max(scale_x, scale_y);
                scale_x = scale;
                scale_y = scale;
                offset_x += (bbox.w - vector.viewbox.w * scale) / 2.0;
                offset_y += (bbox.h - vector.viewbox.h * scale) / 2.0;
            },
            .crop => {
                scale_x = 1.0;
                scale_y = 1.0;
            },
            .stretch => {},
        }

        offset_x -= vector.viewbox.x * scale_x;
        offset_y -= vector.viewbox.y * scale_y;

        quartz_renderer_draw_path(
            self,
            vector.path,
            offset_x,
            offset_y,
            scale_x,
            scale_y,
            style.color.r,
            style.color.g,
            style.color.b,
            style.color.a,
            0,
            0,
            0,
            0,
            0,
        );
    }

    fn renderBitmapPicture(self: *CGContext, bbox: Rect, bitmap: Picture.Source.Bitmap, style: Picture.Style) void {
        var draw_width: f32 = bitmap.width;
        var draw_height: f32 = bitmap.height;
        var offset_x: f32 = bbox.x;
        var offset_y: f32 = bbox.y;

        const scale_x = bbox.w / bitmap.width;
        const scale_y = bbox.h / bitmap.height;

        switch (style.fit_mode) {
            .contain, .cover => {
                // one scale for both axes, and the image centered in the box
                const scale = if (style.fit_mode == .contain) @min(scale_x, scale_y) else @max(scale_x, scale_y);
                draw_width = bitmap.width * scale;
                draw_height = bitmap.height * scale;
                offset_x += (bbox.w - draw_width) / 2.0;
                offset_y += (bbox.h - draw_height) / 2.0;
            },
            .crop => {
                offset_x += (bbox.w - bitmap.width) / 2.0;
                offset_y += (bbox.h - bitmap.height) / 2.0;
            },
            .stretch => {
                draw_width = bbox.w;
                draw_height = bbox.h;
            },
        }

        quartz_renderer_draw_image(
            self,
            bitmap.image,
            offset_x,
            offset_y,
            draw_width,
            draw_height,
        );
    }

    fn renderText(self: *CGContext, bbox: Rect, text_content: *const content.Text) !void {
        const font = Font.forStyle(text_content.style);
        defer font.deinit();

        var lines = text_content.linesWithSizes(bbox.w);
        var y_pos: f32 = bbox.y;
        while (try lines.next()) |line| {
            const x_pos = bbox.x + switch (text_content.style.alignment) {
                .left => 0,
                .center => (bbox.w - line.size.x) / 2,
                .right => bbox.w - line.size.x,
            };

            quartz_renderer_draw_text(
                self,
                line.text.ptr,
                line.text.len,
                x_pos,
                y_pos,
                font,
                text_content.style.color.r,
                text_content.style.color.g,
                text_content.style.color.b,
                text_content.style.color.a,
            );

            y_pos += line.size.y;
        }
    }
};

pub fn init(allocator: std.mem.Allocator) !Renderer {
    return .{
        .allocator = allocator,
        .text_context = try content.Text.Context.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.text_context.deinit();
    self.* = undefined;
}

/// The text content this renderer measures and draws, for
/// `fabrum.app.Runtime`'s `Config.Text`.
pub const Text = content.Text;

/// The surfaces it draws into: Core Graphics contexts.
pub const surfaces: []const fabrum.layout.Surface.Kind = &.{.cg_context};

/// Draws `commands` into `surface`, a `CGContextRef` in fabrum's
/// coordinates. With `damage`, drawing is clipped to those regions (their
/// bounding rectangle when there are more than 64). Does not clear the
/// context; the host prepares the background. Drawing state is preserved.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: fabrum.layout.Surface, damage: ?[]const fabrum.Rect) !void {
    const cg_context: *CGContext = switch (surface) {
        .cg_context => |cg| @ptrCast(cg),
        else => return error.UnsupportedSurface,
    };
    quartz_renderer_save_state(cg_context);
    defer quartz_renderer_restore_state(cg_context);
    if (damage) |regions| {
        var rects: [64]CGRect = undefined;
        // more regions than fit are drawn in one clip around them all
        if (regions.len <= rects.len) {
            for (regions, rects[0..regions.len]) |r, *out| out.* = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            quartz_renderer_clip_to_rects(cg_context, &rects, regions.len);
        } else {
            var bounds = regions[0];
            for (regions[1..]) |r| bounds = union_(bounds, r);
            quartz_renderer_clip_to_rect(cg_context, bounds.x, bounds.y, bounds.w, bounds.h);
        }
    }
    try self.renderCommands(commands, cg_context);
}

const CGRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };

fn union_(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return .init(x0, y0, @max(a.x + a.w, b.x + b.w) - x0, @max(a.y + a.h, b.y + b.h) - y0);
}

/// Draws commands already taken from a layout, such as one canvas layer of
/// a window that interleaves drawn content with native views.
pub fn renderCommands(self: *Renderer, commands: []const RenderCommand, cg_context: *CGContext) !void {
    for (commands) |cmd| try self.renderCommand(cmd, cg_context);
}

/// Draws one command.
pub fn renderCommand(self: *Renderer, cmd: RenderCommand, cg_context: *CGContext) !void {
    _ = self;
    switch (cmd.data) {
        .scissor_start => |clip| {
            quartz_renderer_save_state(cg_context);
            quartz_renderer_clip_axes(cg_context, cmd.bbox.x, cmd.bbox.y, cmd.bbox.w, cmd.bbox.h, clip.horizontal, clip.vertical);
        },
        .scissor_end => {
            quartz_renderer_restore_state(cg_context);
        },
        .rectangle => |r| {
            cg_context.renderRectangle(cmd.bbox, r.corner_radius, r.color);
        },
        .border => |b| {
            cg_context.renderBorder(cmd.bbox, b);
        },
        .content => |c| {
            try cg_context.renderContent(cmd.bbox, c);
        },
    }
}

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.layout.text.Style) content.Text {
    return .initContext(s, style, self.text_context);
}

pub fn svgPicture(allocator: std.mem.Allocator, svg_data: []const u8) !Picture {
    return Picture.fromSVG(allocator, svg_data);
}

pub fn bitmapPicture(image_ref: *CGImage, width: f32, height: f32, owns_image: bool) Picture {
    return Picture.fromCGImage(image_ref, width, height, owns_image);
}

pub fn bitmapPictureFromCGImage(image_ref: *CGImage, owns_image: bool) Picture {
    const width = cgimage_get_width(image_ref);
    const height = cgimage_get_height(image_ref);
    return Picture.fromCGImage(image_ref, @floatCast(width), @floatCast(height), owns_image);
}

fn isAllZero(cr: CornerRadius) bool {
    return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
}

const CGFloat = f64;
pub const CGPath = @import("quartz/content/picture/svg.zig").CGPath;

extern fn quartz_renderer_flip_canvas(self: *CGContext, height: CGFloat) callconv(.c) void;

extern fn quartz_renderer_save_state(context: *CGContext) void;
extern fn quartz_renderer_restore_state(context: *CGContext) void;
extern fn quartz_renderer_clip_axes(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, horizontal: bool, vertical: bool) void;
extern fn quartz_renderer_clip_to_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) void;
extern fn quartz_renderer_clip_to_rects(context: *CGContext, rects: [*]const CGRect, count: usize) void;
extern fn quartz_renderer_fill_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_fill_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_draw_text(context: *CGContext, text: [*]const u8, text_len: usize, x: CGFloat, y: CGFloat, font: *const Font, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_draw_path(context: *CGContext, path: *const CGPath, x: CGFloat, y: CGFloat, scale_x: CGFloat, scale_y: CGFloat, fill_r: u8, fill_g: u8, fill_b: u8, fill_a: u8, stroke_r: u8, stroke_g: u8, stroke_b: u8, stroke_a: u8, stroke_width: CGFloat) void;
extern fn quartz_renderer_draw_image(context: *CGContext, image: *CGImage, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) void;

extern fn cgimage_get_width(image: *CGImage) CGFloat;
extern fn cgimage_get_height(image: *CGImage) CGFloat;

test {
    std.testing.refAllDecls(@This());
}

test "it is a renderer for Core Graphics contexts" {
    comptime fabrum.layout.checkRenderer(Renderer);
    try std.testing.expect(fabrum.layout.accepts(Renderer, .cg_context));
    try std.testing.expect(!fabrum.layout.accepts(Renderer, .pixels));
}

test "it draws into a bitmap context, with no window and no AppKit" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    const width = 64;
    const height = 32;
    var pixels: [width * height * 4]u8 = @splat(0);
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.NoColorSpace;
    defer CGColorSpaceRelease(space);
    // premultiplied RGBA
    const cg = CGBitmapContextCreate(&pixels, width, height, 8, width * 4, space, 1) orelse return error.NoContext;
    defer CGContextRelease(cg);
    cg.flipCanvas(height);

    var label = renderer.text("W", .{ .font_size = 20, .color = .rgb(0, 0, 255) });
    const commands = [_]RenderCommand{
        .{ .bbox = .init(0, 0, 32, 32), .data = .{ .rectangle = .{ .color = .rgb(255, 0, 0), .corner_radius = .{} } } },
        .{ .bbox = .init(36, 4, 24, 24), .data = .{ .content = &label.content } },
    };
    try fabrum.layout.draw(&renderer, &commands, .cg_context, cg, null);

    // the rectangle fills the left half, top to bottom
    const Pixel = struct {
        fn at(p: []const u8, x: usize, y: usize) [4]u8 {
            // bitmap rows run from the top
            return p[(y * width + x) * 4 ..][0..4].*;
        }
    };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, Pixel.at(&pixels, 2, 2));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, Pixel.at(&pixels, 30, 30));
    // the text is blue ink on the right
    var blue: usize = 0;
    for (0..height) |y| for (36..width) |x| {
        const p = Pixel.at(&pixels, x, y);
        if (p[2] > 200 and p[0] < 50 and p[3] > 200) blue += 1;
    };
    try std.testing.expect(blue > 20);
}

test "colors are sRGB, whatever the context's color space" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();

    // the same blue rectangle and text into an sRGB bitmap and a Display
    // P3 one: the bytes are the color's own in sRGB, and converted in P3,
    // as a tagged color is (device RGB would write the raw bytes to both,
    // and show a different blue on a P3 display)
    const width = 32;
    const height = 16;
    var srgb_pixels: [width * height * 4]u8 = @splat(0);
    var p3_pixels: [width * height * 4]u8 = @splat(0);
    const blue: Color = .rgb(0, 122, 255);
    var label = renderer.text("W", .{ .font_size = 14, .color = blue });
    const commands = [_]RenderCommand{
        .{ .bbox = .init(0, 0, 16, 16), .data = .{ .rectangle = .{ .color = blue, .corner_radius = .{} } } },
        .{ .bbox = .init(16, 0, 16, 16), .data = .{ .content = &label.content } },
    };
    for ([_]*const anyopaque{ kCGColorSpaceSRGB, kCGColorSpaceDisplayP3 }, [_]*[width * height * 4]u8{ &srgb_pixels, &p3_pixels }) |name, pixels| {
        const space = CGColorSpaceCreateWithName(name) orelse return error.NoColorSpace;
        defer CGColorSpaceRelease(space);
        const cg = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, 1) orelse return error.NoContext;
        defer CGContextRelease(cg);
        cg.flipCanvas(height);
        try fabrum.layout.draw(&renderer, &commands, .cg_context, cg, null);
    }
    try std.testing.expectEqual([4]u8{ 0, 122, 255, 255 }, srgb_pixels[(4 * width + 4) * 4 ..][0..4].*);
    const p3 = p3_pixels[(4 * width + 4) * 4 ..][0..4].*;
    try std.testing.expect(p3[0] != 0 or p3[1] != 122 or p3[2] != 255);
    try std.testing.expectEqual(255, p3[3]);
    // the text's ink converts the same way: the most opaque blue pixel of
    // the glyph has the rectangle's bytes in each bitmap
    for ([_]*const [width * height * 4]u8{ &srgb_pixels, &p3_pixels }) |pixels| {
        var ink: ?[4]u8 = null;
        for (0..height) |y| for (16..width) |x| {
            const p = pixels[(y * width + x) * 4 ..][0..4].*;
            const bluest = if (ink) |i| p[2] >= i[2] else true;
            if (p[3] == 255 and bluest) ink = p;
        };
        try std.testing.expectEqual(pixels[(4 * width + 4) * 4 ..][0..4].*, ink.?);
    }
}

const CGColorSpace = opaque {};
extern const kCGColorSpaceSRGB: *const anyopaque;
extern const kCGColorSpaceDisplayP3: *const anyopaque;
extern fn CGColorSpaceCreateWithName(name: *const anyopaque) callconv(.c) ?*CGColorSpace;
extern fn CGColorSpaceRelease(space: *CGColorSpace) callconv(.c) void;
extern fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: *CGColorSpace, info: u32) callconv(.c) ?*CGContext;
extern fn CGContextRelease(context: *CGContext) callconv(.c) void;

test "scissors preserve the unrestricted axis and restore nested clips" {
    var renderer: Renderer = try .init(std.testing.allocator);
    defer renderer.deinit();
    const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.NoColorSpace;
    defer CGColorSpaceRelease(space);
    for ([_]bool{ false, true }) |horizontal| {
        var pixels: [32 * 32 * 4]u8 = @splat(0);
        const cg = CGBitmapContextCreate(&pixels, 32, 32, 8, 32 * 4, space, 1) orelse return error.NoContext;
        defer CGContextRelease(cg);
        cg.flipCanvas(32);
        const commands = [_]RenderCommand{
            .{ .bbox = .init(0, 0, 32, 32), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } },
            .{ .bbox = .init(8, 8, 16, 16), .data = .{ .scissor_start = .{ .horizontal = horizontal, .vertical = !horizontal } } },
            .{ .bbox = .init(0, 0, 32, 32), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } },
            .{ .bbox = .zero, .data = .scissor_end },
            .{ .bbox = .zero, .data = .scissor_end },
        };
        try fabrum.layout.draw(&renderer, &commands, .cg_context, cg, null);
        for (0..32) |y| for (0..32) |x| {
            const inside = if (horizontal) x >= 8 and x < 24 else y >= 8 and y < 24;
            try std.testing.expectEqual(@as(u8, if (inside) 255 else 0), pixels[(y * 32 + x) * 4 + 3]);
        };
        // Both saves were restored: a later draw reaches the corner.
        try renderer.renderCommand(.{ .bbox = .init(0, 0, 2, 2), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } }, cg);
        try std.testing.expectEqual(255, pixels[3]);
    }
}
