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

/// How pixels are laid out in a `Surface.pixels` buffer: 4 bytes each,
/// with color premultiplied by alpha, so that a pixel of an overlay
/// composites over what is under it as `out = overlay + under * (1 - alpha)`.
pub const PixelFormat = enum {
    /// Bytes R, G, B, A.
    rgba8_premultiplied,
    /// Bytes B, G, R, A, as Windows, Core Graphics and Cairo usually want.
    bgra8_premultiplied,

    pub const bytes_per_pixel = 4;
};

/// What a renderer draws into. Coordinates are fabrum's: points from the
/// top left, y down.
pub const Surface = union(enum) {
    /// Memory the renderer rasterizes into, one pixel per point.
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
        /// that write whole pixels.
        data: []u8,
        width: u32,
        height: u32,
        /// Bytes from the start of one row to the start of the next; at
        /// least `width * 4`.
        stride: u32,
        format: PixelFormat,

        /// A tightly packed buffer of `width` by `height` pixels.
        pub fn packed_(data: []u8, width: u32, height: u32, format: PixelFormat) Pixels {
            std.debug.assert(data.len >= @as(usize, width) * height * PixelFormat.bytes_per_pixel);
            return .{ .data = data, .width = width, .height = height, .stride = width * PixelFormat.bytes_per_pixel, .format = format };
        }

        /// The bytes of row `y`, `width` pixels long.
        pub fn row(self: Pixels, y: u32) []u8 {
            const start = @as(usize, y) * self.stride;
            return self.data[start..][0 .. @as(usize, self.width) * PixelFormat.bytes_per_pixel];
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
/// border's four edges, ignoring corner radii and content, into
/// `rgba8_premultiplied` pixels, with clipping and damage.
pub const TestRenderer = struct {
    /// Text that draws nothing.
    pub const Text = @import("text.zig").HeuristicContent;
    pub const surfaces: []const Surface.Kind = &.{.pixels};

    renders: usize = 0,

    pub fn render(self: *TestRenderer, commands: []const RenderCommand, surface: Surface, damage: ?[]const Rect) !void {
        self.renders += 1;
        const pixels = surface.pixels;
        const whole: [1]Rect = .{.init(0, 0, @floatFromInt(pixels.width), @floatFromInt(pixels.height))};
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

    /// Composites `color` over the pixels of `rect`, rounded to the
    /// nearest pixel edges, or clears them if `color` is null.
    fn fill(pixels: Surface.Pixels, rect: Rect, color: ?fabrum.Color) void {
        const w: f32 = @floatFromInt(pixels.width);
        const h: f32 = @floatFromInt(pixels.height);
        const x0: u32 = @intFromFloat(std.math.clamp(@round(rect.x), 0, w));
        const y0: u32 = @intFromFloat(std.math.clamp(@round(rect.y), 0, h));
        const x1: u32 = @intFromFloat(std.math.clamp(@round(rect.x + rect.w), 0, w));
        const y1: u32 = @intFromFloat(std.math.clamp(@round(rect.y + rect.h), 0, h));
        for (y0..y1) |y| {
            const row = pixels.row(@intCast(y));
            for (x0..x1) |x| {
                const p = row[x * 4 ..][0..4];
                const c = color orelse {
                    p.* = .{ 0, 0, 0, 0 };
                    continue;
                };
                const a: u32 = c.a;
                const src = [4]u32{ @as(u32, c.r) * a / 255, @as(u32, c.g) * a / 255, @as(u32, c.b) * a / 255, a };
                for (p, src) |*d, v| d.* = @intCast(v + @as(u32, d.*) * (255 - a) / 255);
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
