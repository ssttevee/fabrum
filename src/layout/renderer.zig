//! Renderers: what draws render commands, and the surfaces they draw into.
//!
//! fabrum never imports a renderer. A renderer is a type, usually in its
//! own package, that provides:
//!
//! ```zig
//! /// Its text: a `layout.text.Content(...)` type that measures text as
//! /// the renderer draws it, for `app.Config.Text`.
//! pub const Text = ...;
//! /// The kinds of surface it draws into.
//! pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
//! /// Draws `commands` into `surface`. With `damage`, only those regions
//! /// are redrawn: each is cleared, for pixel surfaces, and every command
//! /// that touches it is drawn clipped to it; everything else is left as it
//! /// was. Null redraws everything.
//! pub fn render(self: *@This(), commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void
//! ```
//!
//! A renderer draws each command inside its box, give or take
//! `Damage.margin` points for anti-aliasing and glyphs that overhang their
//! line, so that redrawing the regions `Damage` reports is enough. Borders
//! are drawn inside the box.
//!
//! Apps draw through `draw`, which checks at compile time that the renderer
//! accepts the kind of surface: drawing into one it doesn't accept is a
//! compile error, not a failure at run time.
const std = @import("std");

const fabrum = @import("../root.zig");
const Rect = fabrum.Rect;
const RenderCommand = @import("render_command.zig");

/// How pixels are laid out in a `Surface.pixels` buffer.
///
/// The 4-byte formats carry color premultiplied by alpha, so that a pixel
/// of an overlay composites over what is under it as `out = overlay +
/// under * (1 - alpha)`; a cleared pixel is transparent. `gray8` has no
/// alpha: it is an opaque gray level, as e-ink framebuffers are, where a
/// cleared pixel is white and coverage shades towards the color's gray.
pub const PixelFormat = enum {
    /// Bytes R, G, B, A.
    rgba8_premultiplied,
    /// Bytes B, G, R, A, as Windows, Core Graphics and Cairo usually want.
    bgra8_premultiplied,
    /// One byte per pixel: 0 is black, 255 is white, opaque. For
    /// grayscale displays such as e-ink. A color's gray level is its
    /// luma (Rec. 601), and anti-aliased coverage blends it with white.
    gray8,

    /// How many bytes one pixel takes.
    pub fn bytesPerPixel(self: PixelFormat) u32 {
        return switch (self) {
            .rgba8_premultiplied, .bgra8_premultiplied => 4,
            .gray8 => 1,
        };
    }

    /// Whether pixels have an alpha channel, so a cleared pixel is
    /// transparent rather than white.
    pub fn hasAlpha(self: PixelFormat) bool {
        return self != .gray8;
    }

    /// The gray level of a straight (not premultiplied) color over white,
    /// for `gray8`: its luma, blended with white by its alpha.
    pub fn grayOf(color: fabrum.Color) u8 {
        const luma: u32 = (299 * @as(u32, color.r) + 587 * @as(u32, color.g) + 114 * @as(u32, color.b)) / 1000;
        const a: u32 = color.a;
        return @intCast((luma * a + 255 * (255 - a) + 127) / 255);
    }
};

/// What a renderer draws into. Coordinates are fabrum's: points from the
/// top left, y down.
pub const Surface = union(enum) {
    /// Memory the renderer rasterizes into, `Pixels.scale` pixels per
    /// point.
    pixels: Pixels,
    /// A Core Graphics context (`CGContextRef`) whose user space is
    /// fabrum's: origin at the top left, y down, in points. Hosts drawing
    /// into a view that isn't flipped flip the context first.
    cg_context: *anyopaque,

    pub const Kind = std.meta.Tag(Surface);

    /// What a surface of `kind` is given as.
    pub fn Target(comptime kind: Kind) type {
        return @FieldType(Surface, @tagName(kind));
    }

    pub const Pixels = struct {
        /// At least `stride * height` bytes, 4-byte aligned for renderers
        /// that write whole 4-byte pixels.
        data: []u8,
        /// In pixels.
        width: u32,
        height: u32,
        /// Bytes from the start of one row to the start of the next; at
        /// least `width * format.bytesPerPixel()`.
        stride: u32,
        format: PixelFormat,
        /// Device pixels per point: 2 on a Retina display, 1 on an e-ink
        /// panel. Commands and damage are in points; renderers scale them.
        scale: f32 = 1,

        /// A tightly packed buffer of `width` by `height` pixels, one per
        /// point.
        pub fn packed_(data: []u8, width: u32, height: u32, format: PixelFormat) Pixels {
            return packedScaled(data, width, height, format, 1);
        }

        /// A tightly packed buffer of `width` by `height` pixels, `scale`
        /// of them per point.
        pub fn packedScaled(data: []u8, width: u32, height: u32, format: PixelFormat, scale: f32) Pixels {
            std.debug.assert(data.len >= @as(usize, width) * height * format.bytesPerPixel());
            return .{ .data = data, .width = width, .height = height, .stride = width * format.bytesPerPixel(), .format = format, .scale = scale };
        }

        /// The bytes of row `y`, `width` pixels long.
        pub fn row(self: Pixels, y: u32) []u8 {
            const start = @as(usize, y) * self.stride;
            return self.data[start..][0 .. @as(usize, self.width) * self.format.bytesPerPixel()];
        }

        /// The size of the surface in points.
        pub fn pointSize(self: Pixels) fabrum.Vec2 {
            return .init(@as(f32, @floatFromInt(self.width)) / self.scale, @as(f32, @floatFromInt(self.height)) / self.scale);
        }
    };
};

/// Checks at compile time that `R` has the renderer interface described
/// above, with an error that says what is missing.
pub fn checkRenderer(comptime R: type) void {
    const name = @typeName(R);
    if (!@hasDecl(R, "Text")) @compileError("fabrum: the renderer " ++ name ++ " has no `pub const Text`, the text content it measures and draws");
    if (!@hasDecl(R.Text, "asTextContent") or !@hasDecl(R.Text, "Context"))
        @compileError("fabrum: " ++ name ++ ".Text is not a `fabrum.layout.text.Content(...)` type");
    if (!@hasDecl(R, "surfaces")) @compileError("fabrum: the renderer " ++ name ++ " has no `pub const surfaces: []const fabrum.layout.Surface.Kind`");
    _ = @as([]const Surface.Kind, R.surfaces);
    if (!@hasDecl(R, "render")) @compileError("fabrum: the renderer " ++ name ++ " has no `pub fn render`");
    const info = @typeInfo(@TypeOf(R.render)).@"fn";
    const expected = [_]type{ *R, []const RenderCommand, Surface, ?[]const Rect };
    const signature = "pub fn render(self: *" ++ name ++ ", commands: []const fabrum.layout.RenderCommand, surface: fabrum.layout.Surface, damage: ?[]const fabrum.Rect) !void";
    if (info.param_types.len != expected.len) @compileError("fabrum: the renderer's render must be `" ++ signature ++ "`");
    for (info.param_types, expected) |actual, wanted| {
        if (actual != wanted) @compileError("fabrum: the renderer's render must be `" ++ signature ++ "`");
    }
}

/// Whether the renderer `R` draws into surfaces of `kind`.
pub fn accepts(comptime R: type, comptime kind: Surface.Kind) bool {
    return std.mem.findScalar(Surface.Kind, R.surfaces, kind) != null;
}

/// Draws `commands` into the surface of `kind` given by `target`, with
/// `renderer` (a pointer to a renderer), redrawing only `damage` if it
/// isn't null. A renderer that doesn't accept `kind` is a compile error.
///
/// ```zig
/// try fabrum.layout.draw(&renderer, commands, .pixels, .packed_(buffer, 800, 600, .rgba8_premultiplied), damage);
/// ```
pub fn draw(renderer: anytype, commands: []const RenderCommand, comptime kind: Surface.Kind, target: Surface.Target(kind), damage: ?[]const Rect) !void {
    const R = @typeInfo(@TypeOf(renderer)).pointer.child;
    comptime checkRenderer(R);
    if (comptime !accepts(R, kind)) {
        comptime var list: []const u8 = "";
        inline for (R.surfaces, 0..) |accepted, i| list = list ++ (if (i > 0) ", ." else ".") ++ @tagName(accepted);
        @compileError("fabrum: the renderer " ++ @typeName(R) ++ " doesn't draw into ." ++ @tagName(kind) ++ " surfaces; it accepts " ++ list);
    }
    return renderer.render(commands, @unionInit(Surface, @tagName(kind), target), damage);
}

/// A renderer for tests: fills each rectangle command's box, and each
/// border's four edges, ignoring corner radii and content, into pixels
/// of any format and scale, with clipping and damage.
pub const TestRenderer = struct {
    /// Text that draws nothing.
    pub const Text = @import("text.zig").HeuristicContent;
    pub const surfaces: []const Surface.Kind = &.{.pixels};

    renders: usize = 0,

    pub fn render(self: *TestRenderer, commands: []const RenderCommand, surface: Surface, damage: ?[]const Rect) !void {
        self.renders += 1;
        const pixels = surface.pixels;
        const size = pixels.pointSize();
        const whole: [1]Rect = .{.init(0, 0, size.x, size.y)};
        for (damage orelse &whole) |region| {
            fill(pixels, region, null);
            var clips: [16]Rect = undefined;
            var depth: usize = 0;
            for (commands) |command| {
                const clip = if (depth > 0) intersect(clips[depth - 1], region) else region;
                switch (command.data) {
                    .scissor_start => |cut| {
                        const box = command.bbox;
                        const huge = 1e9;
                        clips[depth] = intersect(.init(
                            if (cut.horizontal) box.x else -huge,
                            if (cut.vertical) box.y else -huge,
                            if (cut.horizontal) box.w else 2 * huge,
                            if (cut.vertical) box.h else 2 * huge,
                        ), clip);
                        depth += 1;
                    },
                    .scissor_end => depth -= 1,
                    .rectangle => |r| fill(pixels, intersect(command.bbox, clip), r.color),
                    .border => |b| {
                        const box = command.bbox;
                        const w = b.widths;
                        for ([_]Rect{
                            .init(box.x, box.y, box.w, w.top),
                            .init(box.x, box.y + box.h - w.bottom, box.w, w.bottom),
                            .init(box.x, box.y, w.left, box.h),
                            .init(box.x + box.w - w.right, box.y, w.right, box.h),
                        }) |edge| fill(pixels, intersect(edge, clip), b.color);
                    },
                    .content => {},
                }
            }
        }
    }

    /// Composites `color` over the pixels of `rect` (in points), rounded
    /// to the nearest pixel edges, or clears them if `color` is null.
    fn fill(pixels: Surface.Pixels, rect: Rect, color: ?fabrum.Color) void {
        const s = pixels.scale;
        const w: f32 = @floatFromInt(pixels.width);
        const h: f32 = @floatFromInt(pixels.height);
        const x0: u32 = @intFromFloat(std.math.clamp(@round(rect.x * s), 0, w));
        const y0: u32 = @intFromFloat(std.math.clamp(@round(rect.y * s), 0, h));
        const x1: u32 = @intFromFloat(std.math.clamp(@round((rect.x + rect.w) * s), 0, w));
        const y1: u32 = @intFromFloat(std.math.clamp(@round((rect.y + rect.h) * s), 0, h));
        for (y0..y1) |y| {
            const row = pixels.row(@intCast(y));
            for (x0..x1) |x| {
                switch (pixels.format) {
                    .gray8 => {
                        const p = &row[x];
                        const c = color orelse {
                            p.* = 255;
                            continue;
                        };
                        // the color's gray over what is there, by its alpha
                        const a: u32 = c.a;
                        const gray: u32 = PixelFormat.grayOf(c.withAlpha(255));
                        p.* = @intCast((gray * a + @as(u32, p.*) * (255 - a) + 127) / 255);
                    },
                    .rgba8_premultiplied, .bgra8_premultiplied => {
                        const p = row[x * 4 ..][0..4];
                        const c = color orelse {
                            p.* = .{ 0, 0, 0, 0 };
                            continue;
                        };
                        const a: u32 = c.a;
                        const r: u32 = @as(u32, c.r) * a / 255;
                        const g: u32 = @as(u32, c.g) * a / 255;
                        const b: u32 = @as(u32, c.b) * a / 255;
                        const src = if (pixels.format == .rgba8_premultiplied) [4]u32{ r, g, b, a } else [4]u32{ b, g, r, a };
                        for (p, src) |*d, v| d.* = @intCast(v + @as(u32, d.*) * (255 - a) / 255);
                    },
                }
            }
        }
    }

    fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .init(x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0));
    }
};

test "draw checks the renderer and draws into the surface it accepts" {
    comptime checkRenderer(TestRenderer);
    try std.testing.expect(accepts(TestRenderer, .pixels));
    try std.testing.expect(!accepts(TestRenderer, .cg_context));

    var buffer: [4 * 4 * 4]u8 align(4) = @splat(0xaa);
    const commands = [_]RenderCommand{
        .{ .bbox = .init(1, 1, 2, 2), .data = .{ .rectangle = .{ .color = .rgba(255, 0, 0, 128), .corner_radius = .{} } } },
    };
    var renderer: TestRenderer = .{};
    try draw(&renderer, &commands, .pixels, .packed_(&buffer, 4, 4, .rgba8_premultiplied), null);
    // cleared, then the half-transparent red premultiplied
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buffer[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, buffer[(1 * 4 + 1) * 4 ..][0..4]);

    // with damage, only the damaged region is redrawn
    @memset(&buffer, 0xaa);
    try draw(&renderer, &commands, .pixels, .packed_(&buffer, 4, 4, .rgba8_premultiplied), &.{.init(0, 0, 2, 2)});
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, buffer[(1 * 4 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, buffer[(2 * 4 + 2) * 4 ..][0..4]);
    try std.testing.expectEqual(2, renderer.renders);
}

test "gray8 surfaces are opaque gray levels, cleared to white" {
    try std.testing.expectEqual(1, PixelFormat.gray8.bytesPerPixel());
    try std.testing.expectEqual(255, PixelFormat.grayOf(.white));
    try std.testing.expectEqual(0, PixelFormat.grayOf(.black));
    // half-transparent black over white
    try std.testing.expectEqual(128, PixelFormat.grayOf(.rgba(0, 0, 0, 127)));
    try std.testing.expectEqual(76, PixelFormat.grayOf(.rgb(255, 0, 0)));

    var buffer: [4 * 4]u8 = @splat(7);
    const commands = [_]RenderCommand{
        .{ .bbox = .init(1, 1, 2, 2), .data = .{ .rectangle = .{ .color = .black, .corner_radius = .{} } } },
    };
    var renderer: TestRenderer = .{};
    try draw(&renderer, &commands, .pixels, .packed_(&buffer, 4, 4, .gray8), null);
    try std.testing.expectEqual(255, buffer[0]);
    try std.testing.expectEqual(0, buffer[1 * 4 + 1]);
}

test "scaled surfaces hold scale pixels per point" {
    var buffer: [8 * 8]u8 = @splat(7);
    const commands = [_]RenderCommand{
        .{ .bbox = .init(1, 1, 2, 2), .data = .{ .rectangle = .{ .color = .black, .corner_radius = .{} } } },
    };
    var renderer: TestRenderer = .{};
    const pixels: Surface.Pixels = .packedScaled(&buffer, 8, 8, .gray8, 2);
    try std.testing.expectEqual(fabrum.Vec2.init(4, 4), pixels.pointSize());
    try draw(&renderer, &commands, .pixels, pixels, null);
    // the box's 2 points are 4 pixels
    try std.testing.expectEqual(255, buffer[1 * 8 + 1]);
    try std.testing.expectEqual(0, buffer[2 * 8 + 2]);
    try std.testing.expectEqual(0, buffer[5 * 8 + 5]);
    try std.testing.expectEqual(255, buffer[6 * 8 + 6]);
    // damage in points: redrawing the point (0,0)-(2,2) clears the pixels (0,0)-(4,4) alone
    @memset(&buffer, 7);
    try draw(&renderer, &commands, .pixels, pixels, &.{.init(0, 0, 2, 2)});
    try std.testing.expectEqual(0, buffer[3 * 8 + 3]);
    try std.testing.expectEqual(7, buffer[4 * 8 + 4]);
}
