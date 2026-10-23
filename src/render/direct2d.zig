//! Direct2D/DirectWrite renderer for borrowed Win32 bridge targets.
//! The host owns BeginDraw/EndDraw and target presentation.
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

/// An opaque bridge target, owned by its Win32 host.
pub const Context = opaque {};

/// Measures text with DirectWrite, once per string and style.
const Measurer = struct {
    inner: fabrum.layout.text.CachedContext(struct {
        backend: *TextBackend,
        pub fn measureText(self: @This(), string: []const u8, style: Style) fabrum.layout.Content.MeasureError!Vec2 {
            var w: f64 = 0;
            var h: f64 = 0;
            const family = style.font_family orelse "";
            if (!fabrum_d2d_measure(self.backend, string.ptr, string.len, family.ptr, family.len, style.font_size, fontWeight(style.font_weight), style.letter_spacing, &w, &h)) return error.MeasureFailed;
            return .init(@floatCast(w), @floatCast(h));
        }

        pub fn deinit(self: *@This()) void {
            fabrum_d2d_text_destroy(self.backend);
            self.* = undefined;
        }
    }),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        const backend = fabrum_d2d_text_create() orelse return error.NoTextContext;
        errdefer fabrum_d2d_text_destroy(backend);
        return .{ .inner = try .init(allocator, .{ .backend = backend }) };
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

/// DirectWrite's weight for each of fabrum's.
fn fontWeight(weight: fabrum.layout.text.Weight) c_int {
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

/// The font family drawn text uses when a style names none: the Win32
/// platform sets the system UI font.
pub fn setDefaultFamily(self: *Renderer, family: []const u8) void {
    if (fabrum_d2d_set_default_family(self.text_context.inner.inner.backend, family.ptr, family.len)) self.text_context.inner.clear();
}

/// The surfaces it draws into: Direct2D bridge targets.
pub const surfaces: []const fabrum.layout.Surface.Kind = &.{.direct2d};

/// Draws commands into an active Direct2D draw session in fabrum coordinates.
/// With `damage`, drawing is clipped to those regions (their bounding
/// rectangle when there are more than 64). Does not clear the context; the
/// host prepares the background. Drawing state is preserved.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: fabrum.layout.Surface, damage: ?[]const Rect) !void {
    _ = self;
    const cr: *Context = switch (surface) {
        .direct2d => |c| @ptrCast(c),
        else => return error.UnsupportedSurface,
    };
    if (!fabrum_d2d_prepare(cr, commands.len)) return error.OutOfMemory;
    const saved = fabrum_d2d_scope(cr);
    defer fabrum_d2d_restore_scope(cr, saved);
    if (damage) |regions| {
        var rects: [64][4]f64 = undefined;
        // more regions than fit are drawn in one clip around them all
        if (regions.len <= rects.len) {
            for (regions, rects[0..regions.len]) |r, *out| out.* = .{ r.x, r.y, r.w, r.h };
            fabrum_d2d_clip_rects(cr, &rects, regions.len);
        } else {
            var bounds = regions[0];
            for (regions[1..]) |r| bounds = union_(bounds, r);
            const rect = [1][4]f64{.{ bounds.x, bounds.y, bounds.w, bounds.h }};
            fabrum_d2d_clip_rects(cr, &rect, 1);
        }
    }
    for (commands) |command| try renderCommand(command, cr);
    if (!fabrum_d2d_status(cr)) return error.DrawFailed;
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
            fabrum_d2d_save(cr);
            fabrum_d2d_clip_axes(cr, box.x, box.y, box.w, box.h, clip.horizontal, clip.vertical);
        },
        .scissor_end => fabrum_d2d_restore(cr),
        .rectangle => |r| {
            const radius = r.corner_radius.fitted(box.w, box.h);
            fabrum_d2d_fill_rect(cr, box.x, box.y, box.w, box.h, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left, r.color.r, r.color.g, r.color.b, r.color.a);
        },
        .border => |b| {
            const widths = b.widths;
            if (widths.isZero()) return;
            const c = b.color;
            if (widths.left == widths.right and widths.left == widths.top and widths.left == widths.bottom) {
                const radius = b.corner_radius.fitted(box.w, box.h);
                fabrum_d2d_stroke_rect(cr, box.x, box.y, box.w, box.h, radius.top_left, radius.top_right, radius.bottom_right, radius.bottom_left, widths.left, c.r, c.g, c.b, c.a);
            } else {
                // each edge as a strip inside the box
                if (widths.top > 0) fabrum_d2d_fill_rect(cr, box.x, box.y, box.w, widths.top, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.bottom > 0) fabrum_d2d_fill_rect(cr, box.x, box.y + box.h - widths.bottom, box.w, widths.bottom, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.left > 0) fabrum_d2d_fill_rect(cr, box.x, box.y, widths.left, box.h, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
                if (widths.right > 0) fabrum_d2d_fill_rect(cr, box.x + box.w - widths.right, box.y, widths.right, box.h, 0, 0, 0, 0, c.r, c.g, c.b, c.a);
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
                if (!fabrum_d2d_draw_bitmap(cr, source.data.ptr, source.width, source.height, source.stride, switch (source.format) {
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
        fabrum_d2d_draw_text(cr, t.context.inner.inner.backend, line.text.ptr, line.text.len, family.ptr, family.len, style.font_size, fontWeight(style.font_weight), style.letter_spacing, x, y, style.color.r, style.color.g, style.color.b, style.color.a);
        y += line.size.y;
    }
}

/// Text content for `string` in `style`, measured by this renderer.
pub fn text(self: *const Renderer, string: []const u8, style: Style) Text {
    return .initContext(string, style, self.text_context);
}

extern fn fabrum_d2d_set_default_family(backend: *TextBackend, family: [*]const u8, len: usize) callconv(.c) bool;
extern fn fabrum_d2d_save(cr: *Context) callconv(.c) void;
extern fn fabrum_d2d_restore(cr: *Context) callconv(.c) void;
extern fn fabrum_d2d_clip_axes(cr: *Context, x: f64, y: f64, w: f64, h: f64, horizontal: bool, vertical: bool) callconv(.c) void;
extern fn fabrum_d2d_clip(cr: *Context, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_d2d_clip_rects(cr: *Context, rects: [*]const [4]f64, count: usize) callconv(.c) void;
extern fn fabrum_d2d_fill_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_d2d_stroke_rect(cr: *Context, x: f64, y: f64, w: f64, h: f64, tl: f64, tr: f64, br: f64, bl: f64, line_width: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_d2d_measure(backend: *TextBackend, text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, w: *f64, h: *f64) callconv(.c) bool;
extern fn fabrum_d2d_draw_text(cr: *Context, backend: *TextBackend, text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, size: f64, weight: c_int, letter_spacing: f64, x: f64, y: f64, r: u8, g: u8, b: u8, a: u8) callconv(.c) void;
extern fn fabrum_d2d_draw_bitmap(cr: *Context, data: [*]const u8, width: u32, height: u32, stride: u32, format: u8, bx: f64, by: f64, bw: f64, bh: f64, x: f64, y: f64, w: f64, h: f64, smooth: bool, snap: bool) callconv(.c) bool;

const ImageTestCanvas = struct {
    renderer: Renderer,
    target: *Context,
    pub fn init(scale: f32, offset: Vec2) !@This() {
        const target = fabrum_d2d_image_create(32, 32, scale, offset.x, offset.y) orelse return error.NoContext;
        errdefer fabrum_d2d_target_destroy(target);
        return .{ .renderer = try .init(std.testing.allocator), .target = target };
    }
    pub fn deinit(self: *@This()) void {
        fabrum_d2d_target_destroy(self.target);
        self.renderer.deinit();
    }
    pub fn pixel(self: *const @This(), x: u32, y: u32) [4]u8 {
        const p = fabrum_d2d_image_data(self.target) + (@as(usize, y) * 32 + x) * 4;
        return .{ p[2], p[1], p[0], p[3] };
    }
    pub fn draw(self: *@This(), commands: []const RenderCommand, damage: ?[]const Rect) !void {
        if (!fabrum_d2d_image_begin(self.target)) return error.NoContext;
        self.renderer.render(commands, .{ .direct2d = self.target }, damage) catch |err| {
            _ = fabrum_d2d_image_end(self.target);
            return err;
        };
        if (!fabrum_d2d_image_end(self.target)) return error.DrawFailed;
    }
};
extern fn fabrum_d2d_image_create(w: u32, h: u32, scale: f32, x: f32, y: f32) callconv(.c) ?*Context;
extern fn fabrum_d2d_target_destroy(target: *Context) callconv(.c) void;
extern fn fabrum_d2d_image_begin(target: *Context) callconv(.c) bool;
extern fn fabrum_d2d_image_end(target: *Context) callconv(.c) bool;
extern fn fabrum_d2d_image_data(target: *Context) callconv(.c) [*]const u8;
extern fn fabrum_d2d_test_fail_end(target: *Context, device_loss: bool) callconv(.c) void;
extern fn fabrum_d2d_test_fail_create(target: *Context) callconv(.c) void;
extern fn fabrum_d2d_test_generation(target: *Context) callconv(.c) c_uint;
extern fn fabrum_d2d_target_recoverable(target: *Context) callconv(.c) bool;
extern fn fabrum_d2d_target_origin(target: *Context, x: f32, y: f32) callconv(.c) void;

test "bounded target draws a huge document slice with clipped origin and recovers" {
    var canvas = try ImageTestCanvas.init(1, .zero);
    defer canvas.deinit();
    fabrum_d2d_target_origin(canvas.target, -100000, -200000);
    const commands = [_]RenderCommand{
        .{ .bbox = .init(100004, 200006, 10, 8), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } },
        .{ .bbox = .init(0, 0, 200000, 400000), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } },
        .{ .bbox = .init(0, 0, 0, 0), .data = .scissor_end },
    };
    try canvas.draw(&commands, null);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, canvas.pixel(5, 7));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas.pixel(3, 7));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas.pixel(15, 15));
    fabrum_d2d_test_fail_end(canvas.target, true);
    try std.testing.expectError(error.DrawFailed, canvas.draw(&commands, null));
    try canvas.draw(&commands, null);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, canvas.pixel(5, 7));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas.pixel(3, 7));
}

test "Direct2D device loss recreates target and preserves drawing coordinates" {
    var canvas = try ImageTestCanvas.init(2, .init(3, 4));
    defer canvas.deinit();
    const commands = [_]RenderCommand{.{ .bbox = .init(1, 1, 4, 4), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } }};
    try canvas.draw(&.{.{ .bbox = .init(10, 10, 2, 2), .data = .{ .rectangle = .{ .color = .white, .corner_radius = .{} } } }}, null);
    const generation = fabrum_d2d_test_generation(canvas.target);
    // Repeated loss must discard every device resource each time.
    for (0..2) |_| {
        fabrum_d2d_test_fail_end(canvas.target, true);
        try std.testing.expectError(error.DrawFailed, canvas.draw(&commands, null));
        try std.testing.expect(fabrum_d2d_target_recoverable(canvas.target));
        fabrum_d2d_test_fail_create(canvas.target);
        try std.testing.expectError(error.NoContext, canvas.draw(&commands, null));
        try std.testing.expect(fabrum_d2d_target_recoverable(canvas.target));
        try canvas.draw(&commands, &.{.init(1, 1, 4, 4)});
        try std.testing.expect(!fabrum_d2d_target_recoverable(canvas.target));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, canvas.pixel(6, 7));
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, canvas.pixel(2, 2));
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, canvas.pixel(24, 25));
    }
    try std.testing.expectEqual(generation + 2, fabrum_d2d_test_generation(canvas.target));
    // Ordinary failures must remain distinguishable and must not recreate.
    fabrum_d2d_test_fail_end(canvas.target, false);
    try std.testing.expectError(error.DrawFailed, canvas.draw(&commands, null));
    try std.testing.expect(!fabrum_d2d_target_recoverable(canvas.target));
    try canvas.draw(&commands, null);
    try std.testing.expectEqual(generation + 2, fabrum_d2d_test_generation(canvas.target));
}
test "Direct2D renderer contract" {
    comptime fabrum.layout.checkRenderer(Renderer);
}
test "Direct2D bitmap sources" {
    try @import("image_tests.zig").sources(ImageTestCanvas);
}
test "Direct2D bitmap sampling" {
    try @import("image_tests.zig").sampling(ImageTestCanvas);
}
test "Direct2D bitmap placement" {
    try @import("image_tests.zig").placement(ImageTestCanvas);
}
test "Direct2D bitmap clipping" {
    try @import("image_tests.zig").clipping(ImageTestCanvas);
}
test "Direct2D bitmap damage" {
    try @import("image_tests.zig").damage(ImageTestCanvas);
}

extern fn fabrum_d2d_prepare(target: *Context, commands: usize) callconv(.c) bool;

extern fn fabrum_d2d_scope(target: *Context) callconv(.c) usize;
extern fn fabrum_d2d_restore_scope(target: *Context, saved: usize) callconv(.c) void;

test "DirectWrite measures and draws Unicode text" {
    var canvas = try ImageTestCanvas.init(1, .zero);
    defer canvas.deinit();
    const size = try canvas.renderer.text_context.measureText("Hello", .{ .font_size = 13 });
    try std.testing.expect(size.x > 20 and size.x < 60);
    try std.testing.expect(size.y > 10 and size.y < 24);
    const unicode_size = try canvas.renderer.text_context.measureText("É漢🙂", .{});
    try std.testing.expect(unicode_size.x > 0 and unicode_size.y > 0);
    var label = canvas.renderer.text("Hi", .{ .font_size = 16, .color = .white });
    try canvas.draw(&.{.{ .bbox = .init(0, 0, 32, 32), .data = .{ .content = &label.content } }}, null);
    var nontransparent: usize = 0;
    for (0..32) |y| for (0..32) |x| {
        if (canvas.pixel(@intCast(x), @intCast(y))[3] != 0) {
            nontransparent += 1;
        }
    };
    try std.testing.expect(nontransparent > 10);
}

extern fn fabrum_d2d_status(target: *Context) callconv(.c) bool;

const TextBackend = opaque {};
extern fn fabrum_d2d_text_create() callconv(.c) ?*TextBackend;
extern fn fabrum_d2d_text_destroy(backend: *TextBackend) callconv(.c) void;
