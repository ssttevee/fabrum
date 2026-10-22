//! Cairo renderer for fabrum: the GTK platform's canvas, and a renderer for
//! any `cairo_t` on its own (an image surface, a PDF).
//!
//! It is a `fabrum.layout` renderer for `.cairo` surfaces: draw with
//! `fabrum.layout.draw(&renderer, commands, .cairo, cr, damage)`, into a
//! context whose user space is fabrum's (top left, y down, in points, which
//! Cairo's is already). Text is set with Pango, as GTK's labels are, so
//! drawn text measures and renders like the controls beside it; the GTK
//! platform gives it the toolkit's font family (`setDefaultFamily`).
//!
//! It draws rectangles, borders, text, shared bitmap images and clips.
const std = @import("std");
const builtin = @import("builtin");
const fabrum = @import("../root.zig");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const Vec2 = fabrum.Vec2;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const Style = fabrum.layout.text.Style;

allocator: std.mem.Allocator,
text_context: Text.Context,

const Renderer = @This();

/// A Cairo drawing context (`cairo_t`).
pub const Context = opaque {};

/// Measures text with Pango, once per string and style.
const Measurer = struct {
    inner: fabrum.layout.text.CachedContext(struct {
        pub fn measureText(_: @This(), string: []const u8, style: Style) fabrum.layout.Content.MeasureError!Vec2 {
            var w: f64 = 0;
            var h: f64 = 0;
            const family = style.font_family orelse "";
            fabrum_cairo_measure(string.ptr, string.len, family.ptr, family.len, style.font_size, pangoWeight(style.font_weight), style.letter_spacing, &w, &h);
            return .init(@floatCast(w), @floatCast(h));
        }

        pub fn deinit(self: *@This()) void {
            self.* = undefined;
        }
    }),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .inner = try .init(allocator, .{}) };
    }

    pub fn measureText(self: @This(), string: []const u8, style: Style) fabrum.layout.Content.MeasureError!Vec2 {
        return self.inner.measureText(string, style);
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

/// The text content this renderer measures and draws, for
/// `fabrum.app.Runtime`'s `Config.Text`.
pub const Text = fabrum.layout.text.Content(Measurer);

/// Pango's weight for each of fabrum's.
fn pangoWeight(weight: fabrum.layout.text.Weight) c_int {
    return switch (weight) {
        .ultralight => 200,
        .thin => 100,
        .light => 300,
        .regular => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
        .heavy => 800,
        .black => 900,
    };
}

pub fn init(allocator: std.mem.Allocator) !Renderer {
    return .{ .allocator = allocator, .text_context = try Text.Context.init(allocator) };
}

pub fn deinit(self: *Renderer) void {
    self.text_context.deinit();
    self.* = undefined;
}

/// The font family drawn text uses when a style names none: the GTK
/// platform sets the toolkit's.
pub fn setDefaultFamily(family: []const u8) void {
    fabrum_cairo_set_default_family(family.ptr, family.len);
}

/// The surfaces it draws into: Cairo contexts.
pub const surfaces: []const fabrum.layout.Surface.Kind = &.{.cairo};

/// Draws `commands` into `surface`, a `cairo_t` in fabrum's coordinates.
/// With `damage`, drawing is clipped to those regions (their bounding
/// rectangle when there are more than 64). Does not clear the context; the
/// host prepares the background. Drawing state is preserved.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: fabrum.layout.Surface, damage: ?[]const Rect) !void {
    _ = self;
    const cr: *Context = switch (surface) {
        .cairo => |c| @ptrCast(c),
        else => return error.UnsupportedSurface,
    };
    fabrum_cairo_save(cr);
    defer fabrum_cairo_restore(cr);
    if (damage) |regions| {
        var rects: [64][4]f64 = undefined;
        // more regions than fit are drawn in one clip around them all
        if (regions.len <= rects.len) {
            for (regions, rects[0..regions.len]) |r, *out| out.* = .{ r.x, r.y, r.w, r.h };
            fabrum_cairo_clip_rects(cr, &rects, regions.len);
        } else {
            var bounds = regions[0];
            for (regions[1..]) |r| bounds = union_(bounds, r);
            const rect = [1][4]f64{.{ bounds.x, bounds.y, bounds.w, bounds.h }};
            fabrum_cairo_clip_rects(cr, &rect, 1);
        }
    }
    for (commands) |command| try renderCommand(command, cr);
}

fn union_(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return .init(x0, y0, @max(a.x + a.w, b.x + b.w) - x0, @max(a.y + a.h, b.y + b.h) - y0);
}

fn renderCommand(command: RenderCommand, cr: *Context) !void {
    const box = command.bbox;
    switch (command.data) {
        .scissor_start => |clip| {
            fabrum_cairo_save(cr);
            fabrum_cairo_clip_axes(cr, box.x, box.y, box.w, box.h, clip.horizontal, clip.vertical);
        },
        .scissor_end => fabrum_cairo_restore(cr),
        .rectangle => |r| {
            const radius = r.corner_radius.fitted(box.w, box.h);
            fabrum_cairo_fill_rect(cr, box.x, box.y, box.w, box.h, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left, r.color.r, r.color.g, r.color.b, r.color.a);
        },
        .border => |b| {
            const widths = b.widths;
            if (widths.isZero()) return;
            const c = b.color;
            if (widths.left == widths.right and widths.left == widths.top and widths.left == widths.bottom) {
                const radius = b.corner_radius.fitted(box.w, box.h);
                fabrum_cairo_stroke_rect(cr, box.x, box.y, box.w, box.h, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left, widths.left, c.r, c.g, c.b, c.a);
            } else {
                // each edge as a strip inside the box
                if (widths.top > 0) fabrum_cairo_fill_rect(cr, box.x, box.y, box.w, widths.top, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.bottom > 0) fabrum_cairo_fill_rect(cr, box.x, box.y + box.h - widths.bottom, box.w, widths.bottom, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.left > 0) fabrum_cairo_fill_rect(cr, box.x, box.y, widths.left, box.h, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.right > 0) fabrum_cairo_fill_rect(cr, box.x + box.w - widths.right, box.y, widths.right, box.h, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
            }
        },
        .content => |content| {
            if (Text.asTextContent(content)) |t| {
                try renderText(cr, box, t);
            } else if (fabrum.layout.Image.asImageContent(content)) |image| {
                try image.source.validate();
                const source = image.source;
                if (source.width > std.math.maxInt(c_int) or source.height > std.math.maxInt(c_int)) return error.ImageTooLarge;
                var unsnapped = image.*;
                unsnapped.style.snap_to_pixels = false;
                const placed = unsnapped.placement(box, 1) orelse return;
                if (!fabrum_cairo_draw_bitmap(cr, source.data.ptr, source.width, source.height, source.stride, switch (source.format) {
                    .rgba8_premultiplied => 0,
                    .bgra8_premultiplied => 1,
                    .gray8 => 2,
                }, box.x, box.y, box.w, box.h, placed.x, placed.y, placed.w, placed.h, image.style.sampling == .smooth, image.style.snap_to_pixels)) return error.DrawImageFailed;
            }
        },
    }
}

fn renderText(cr: *Context, box: Rect, t: *const Text) !void {
    const style = t.style;
    const family = style.font_family orelse "";
    var lines = t.linesWithSizes(box.w);
    var y = box.y;
    while (try lines.next()) |line| {
        const x = box.x + switch (style.alignment) {
            .left => 0,
            .center => (box.w - line.size.x) / 2,
            .right => box.w - line.size.x,
        };
        fabrum_cairo_draw_text(cr, line.text.ptr, line.text.len, family.ptr, family.len, style.font_size, pangoWeight(style.font_weight), style.letter_spacing, x, y, style.color.r, style.color.g, style.color.b, style.color.a);
        y += line.size.y;
    }
}

/// Text content for `string` in `style`, measured by this renderer.
pub fn text(self: *const Renderer, string: []const u8, style: Style) Text {
    return .initContext(string, style, self.text_context);
}

/// An ARGB32 bitmap with a Cairo context over it, for tests and snapshots.
pub const Image = struct {
    surface: *anyopaque,
    context: *Context,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) error{NoContext}!Image {
        var context: ?*anyopaque = null;
        const surface = fabrum_cairo_image_create(@intCast(width), @intCast(height), &context) orelse return error.NoContext;
        return .{ .surface = surface, .context = @ptrCast(context orelse return error.NoContext), .width = width, .height = height };
    }

    pub fn deinit(self: *Image) void {
        fabrum_cairo_image_destroy(self.surface, self.context);
        self.* = undefined;
    }

    /// The pixel at (x, y) as premultiplied R, G, B, A (Cairo keeps BGRA
    /// premultiplied in native byte order).
    pub fn pixel(self: *const Image, x: u32, y: u32) [4]u8 {
        var stride: c_int = 0;
        const data = fabrum_cairo_image_data(self.surface, &stride);
        const p = data[@as(usize, y) * @as(usize, @intCast(stride)) + @as(usize, x) * 4 ..][0..4];
        const word = std.mem.readInt(u32, p, builtin.cpu.arch.endian());
        const a: u8 = @truncate(word >> 24);
        const r: u8 = @truncate(word >> 16);
        const g: u8 = @truncate(word >> 8);
        const b: u8 = @truncate(word);
        return .{ r, g, b, a };
    }

    pub fn writePng(self: *const Image, path: [:0]const u8) error{WriteFailed}!void {
        if (!fabrum_cairo_image_write_png(self.surface, path.ptr)) return error.WriteFailed;
    }
};

extern fn fabrum_cairo_set_default_family(family: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_cairo_save(cr: *Context) callconv(.c) void;
extern fn fabrum_cairo_restore(cr: *Context) callconv(.c) void;
extern fn fabrum_cairo_clip_axes(cr: *Context, x: f64, y: f64, w: f64, h: f64, horizontal: bool, vertical: bool) callconv(.c) void;
extern fn fabrum_cairo_clip(cr: *Context, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_cairo_clip_rects(cr: *Context, rects: [*]const [4]f64, count: usize) callconv(.c) void;
extern fn fabrum_cairo_fill_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_stroke_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, line_width: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_measure(text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, w: *f64, h: *f64) callconv(.c) void;
extern fn fabrum_cairo_draw_text(cr: *Context, text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, x: f64, y: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_image_create(width: c_int, height: c_int, context_out: *?*anyopaque) callconv(.c) ?*anyopaque;
extern fn fabrum_cairo_draw_bitmap(cr: *Context, data: [*]const u8, width: u32, height: u32, stride: u32, format: u8, bx: f64, by: f64, bw: f64, bh: f64, x: f64, y: f64, w: f64, h: f64, smooth: bool, snap: bool) callconv(.c) bool;
extern fn fabrum_cairo_image_data(surface: *anyopaque, stride_out: *c_int) callconv(.c) [*]const u8;
extern fn fabrum_cairo_image_write_png(surface: *anyopaque, path: [*:0]const u8) callconv(.c) bool;
extern fn fabrum_cairo_image_destroy(surface: *anyopaque, context: *anyopaque) callconv(.c) void;

test "it is a renderer for Cairo contexts" {
    comptime fabrum.layout.checkRenderer(Renderer);
    try std.testing.expect(fabrum.layout.accepts(Renderer, .cairo));
    try std.testing.expect(!fabrum.layout.accepts(Renderer, .pixels));
}

test "it draws into an image surface, with no window and no GTK" {
    const gpa = std.testing.allocator;
    var renderer: Renderer = try .init(gpa);
    defer renderer.deinit();
    var image: Image = try .init(64, 32);
    defer image.deinit();

    var label = renderer.text("W", .{ .font_size = 20, .color = .rgb(0, 0, 255) });
    const commands = [_]RenderCommand{
        .{ .bbox = .init(0, 0, 32, 32), .data = .{ .rectangle = .{ .color = .rgb(255, 0, 0), .corner_radius = .{} } } },
        .{ .bbox = .init(36, 4, 24, 24), .data = .{ .content = &label.content } },
    };
    try fabrum.layout.draw(&renderer, &commands, .cairo, image.context, null);

    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, image.pixel(2, 2));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, image.pixel(30, 30));
    var blue: usize = 0;
    for (0..32) |y| for (36..64) |x| {
        const p = image.pixel(@intCast(x), @intCast(y));
        if (p[2] > 200 and p[0] < 50 and p[3] > 200) blue += 1;
    };
    try std.testing.expect(blue > 20);
    // the text measures as it draws: one line, a few pixels wide and tall
    const size = try renderer.text_context.measureText("Hello", .{ .font_size = 13 });
    try std.testing.expect(size.x > 20 and size.x < 60);
    try std.testing.expect(size.y > 10 and size.y < 24);
}

test "scissors preserve the unrestricted axis and restore nested clips" {
    var renderer: Renderer = try .init(std.testing.allocator);
    defer renderer.deinit();
    for ([_]bool{ false, true }) |horizontal| {
        var image: Image = try .init(32, 32);
        defer image.deinit();
        const commands = [_]RenderCommand{
            .{ .bbox = .init(0, 0, 32, 32), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } },
            .{ .bbox = .init(8, 8, 16, 16), .data = .{ .scissor_start = .{ .horizontal = horizontal, .vertical = !horizontal } } },
            .{ .bbox = .init(0, 0, 32, 32), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } },
            .{ .bbox = .zero, .data = .scissor_end },
            .{ .bbox = .zero, .data = .scissor_end },
        };
        try fabrum.layout.draw(&renderer, &commands, .cairo, image.context, null);
        for (0..32) |y| for (0..32) |x| {
            const inside = if (horizontal) x >= 8 and x < 24 else y >= 8 and y < 24;
            try std.testing.expectEqual(@as(u8, if (inside) 255 else 0), image.pixel(@intCast(x), @intCast(y))[3]);
        };
        try renderCommand(.{ .bbox = .init(0, 0, 2, 2), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } }, image.context);
        try std.testing.expectEqual(255, image.pixel(0, 0)[3]);
    }
}

const ImageTestCanvas = struct {
    renderer: Renderer,
    image: Image,
    const Self = @This();

    pub fn init(scale: f32, offset: fabrum.Vec2) !Self {
        var image: Image = try .init(32, 32);
        errdefer image.deinit();
        cairo_translate(image.context, offset.x, offset.y);
        cairo_scale(image.context, scale, scale);
        return .{ .renderer = try .init(std.testing.allocator), .image = image };
    }
    pub fn deinit(self: *Self) void {
        self.image.deinit();
        self.renderer.deinit();
    }
    pub fn pixel(self: *const Self, x: u32, y: u32) [4]u8 {
        return self.image.pixel(x, y);
    }
    pub fn draw(self: *Self, commands: []const RenderCommand, damage: ?[]const Rect) !void {
        try self.renderer.render(commands, .{ .cairo = self.image.context }, damage);
    }
};

extern fn cairo_scale(context: *Context, sx: f64, sy: f64) callconv(.c) void;
extern fn cairo_translate(context: *Context, tx: f64, ty: f64) callconv(.c) void;

test "shared bitmap sources" {
    try @import("image_tests.zig").sources(ImageTestCanvas);
}

test "shared bitmap sampling" {
    try @import("image_tests.zig").sampling(ImageTestCanvas);
}

test "shared bitmap placement" {
    try @import("image_tests.zig").placement(ImageTestCanvas);
}

test "shared bitmap clipping" {
    try @import("image_tests.zig").clipping(ImageTestCanvas);
}

test "shared bitmap damage" {
    try @import("image_tests.zig").damage(ImageTestCanvas);
}

extern fn cairo_surface_set_device_scale(surface: *anyopaque, sx: f64, sy: f64) callconv(.c) void;
extern fn cairo_surface_set_device_offset(surface: *anyopaque, x: f64, y: f64) callconv(.c) void;

test "bitmap snapping includes Cairo surface device scale and offset" {
    var canvas = try ImageTestCanvas.init(1, .zero);
    defer canvas.deinit();
    cairo_surface_set_device_scale(canvas.image.surface, 2, 2);
    cairo_surface_set_device_offset(canvas.image.surface, 0.25, 0.25);
    var image = try fabrum.layout.Image.init(.{ .data = &.{ 10, 20, 30, 40 }, .width = 4, .height = 1, .stride = 4, .format = .gray8, .scale = 2 }, .{ .fit_mode = .crop, .sampling = .nearest, .alignment = .top_left, .snap_to_pixels = true });
    try canvas.draw(&.{.{ .bbox = .init(1.2, 2.2, 3, 3), .data = .{ .content = &image.content } }}, null);
    try std.testing.expectEqual([4]u8{ 10, 10, 10, 255 }, canvas.pixel(3, 5));
    try std.testing.expectEqual([4]u8{ 40, 40, 40, 255 }, canvas.pixel(6, 5));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas.pixel(7, 5));
}
