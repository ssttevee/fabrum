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
//! It draws rectangles, borders, text and clips. Pictures (SVG paths,
//! bitmaps) are not drawn yet.
const std = @import("std");
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
/// With `damage`, drawing is clipped to those regions; the context keeps
/// what it had outside them.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: fabrum.layout.Surface, damage: ?[]const Rect) !void {
    _ = self;
    const cr: *Context = switch (surface) {
        .cairo => |c| @ptrCast(c),
        else => return error.UnsupportedSurface,
    };
    fabrum_cairo_save(cr);
    defer fabrum_cairo_restore(cr);
    if (damage) |regions| {
        var rects: [64 * 4]f64 = undefined;
        if (regions.len <= 64) {
            for (regions, 0..) |r, i| {
                rects[i * 4] = r.x;
                rects[i * 4 + 1] = r.y;
                rects[i * 4 + 2] = r.w;
                rects[i * 4 + 3] = r.h;
            }
            fabrum_cairo_clip_rects(cr, &rects, regions.len);
        } else {
            var bounds = regions[0];
            for (regions[1..]) |r| bounds = union_(bounds, r);
            fabrum_cairo_clip(cr, bounds.x, bounds.y, bounds.w, bounds.h);
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
        .scissor_start => {
            fabrum_cairo_save(cr);
            fabrum_cairo_clip(cr, box.x, box.y, box.w, box.h);
        },
        .scissor_end => fabrum_cairo_restore(cr),
        .rectangle => |r| {
            const radius = r.corner_radius.fitted(box.w, box.h);
            fabrum_cairo_fill_rect(cr, box.x, box.y, box.w, box.h, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left, r.color.r, r.color.g, r.color.b, r.color.a);
        },
        .border => |b| {
            const widths = b.widths;
            if (widths.left == 0 and widths.right == 0 and widths.top == 0 and widths.bottom == 0) return;
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
        .content => |content| if (Text.asTextContent(content)) |t| try renderText(cr, box, t),
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

    /// The pixel at (x, y) as straight R, G, B, A (Cairo keeps BGRA
    /// premultiplied in native byte order).
    pub fn pixel(self: *const Image, x: u32, y: u32) [4]u8 {
        var stride: c_int = 0;
        const data = fabrum_cairo_image_data(self.surface, &stride);
        const p = data[@as(usize, y) * @as(usize, @intCast(stride)) + @as(usize, x) * 4 ..][0..4];
        const word = std.mem.readInt(u32, p, .little);
        const a: u8 = @intCast(word >> 24);
        const r: u8 = @intCast((word >> 16) & 0xff);
        const g: u8 = @intCast((word >> 8) & 0xff);
        const b: u8 = @intCast(word & 0xff);
        return .{ r, g, b, a };
    }

    pub fn writePng(self: *const Image, path: [:0]const u8) error{WriteFailed}!void {
        if (!fabrum_cairo_image_write_png(self.surface, path.ptr)) return error.WriteFailed;
    }
};

extern fn fabrum_cairo_set_default_family(family: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_cairo_save(cr: *Context) callconv(.c) void;
extern fn fabrum_cairo_restore(cr: *Context) callconv(.c) void;
extern fn fabrum_cairo_clip(cr: *Context, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_cairo_clip_rects(cr: *Context, rects: [*]const f64, count: usize) callconv(.c) void;
extern fn fabrum_cairo_fill_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_stroke_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, line_width: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_measure(text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, w: *f64, h: *f64) callconv(.c) void;
extern fn fabrum_cairo_draw_text(cr: *Context, text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, x: f64, y: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_cairo_image_create(width: c_int, height: c_int, context_out: *?*anyopaque) callconv(.c) ?*anyopaque;
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
