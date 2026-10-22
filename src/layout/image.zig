//! Renderer-independent bitmap content. Pixels and this value are borrowed
//! until command consumption finishes. Decode files outside layout; after
//! editing pixels in place, increment `revision` before the next frame.
const std = @import("std");
const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Image = @This();

source: Source,
style: Style = .{},
/// Changes to bytes at the same address must change this value. Neither
/// measurement nor damage tracking reads or hashes the pixel bytes.
revision: u64 = 0,
content: layout.Content = .{ .vtable = &vtable },

pub const Source = struct {
    data: []const u8,
    width: u32,
    height: u32,
    /// Bytes between rows, at least width * format.bytesPerPixel(). The
    /// buffer includes padding on every row, including the last.
    stride: u32,
    format: layout.PixelFormat,
    /// Source pixels per point; natural size is (width, height) / scale.
    /// For 1:1 crop placement this must equal the target surface's scale.
    scale: f32 = 1,

    pub fn validate(self: Source) error{InvalidImage}!void {
        if (self.width == 0 or self.height == 0 or
            !std.math.isFinite(self.scale) or self.scale <= 0 or
            @as(u64, self.stride) < @as(u64, self.width) * self.format.bytesPerPixel() or
            @as(u64, self.stride) * self.height > self.data.len)
            return error.InvalidImage;
        const size = self.pointSize();
        if (!std.math.isFinite(size.x) or !std.math.isFinite(size.y) or size.x <= 0 or size.y <= 0)
            return error.InvalidImage;
    }

    pub fn pointSize(self: Source) Vec2 {
        return .init(@as(f32, @floatFromInt(self.width)) / self.scale, @as(f32, @floatFromInt(self.height)) / self.scale);
    }

    /// Only the image bytes, excluding row padding. No alignment required.
    pub fn row(self: Source, y: u32) []const u8 {
        const start = @as(usize, y) * self.stride;
        return self.data[start..][0 .. @as(usize, self.width) * self.format.bytesPerPixel()];
    }
};

pub const FitMode = enum { contain, cover, crop, stretch };
pub const Sampling = enum {
    /// Select the nearest source pixel center without interpolation.
    /// Backends may resolve exact halfway ties differently.
    nearest,
    /// Interpolate premultiplied channels. The native filter may vary by
    /// backend; `sample` supplies bilinear filtering with clamped edges.
    smooth,
};

pub const Style = struct {
    fit_mode: FitMode = .contain,
    alignment: layout.Alignment = .center,
    sampling: Sampling = .smooth,
    /// Round the placed origin to the nearest device pixel. Size is kept
    /// unchanged to preserve the fit and aspect ratio. Clip to the box even
    /// if this shifts an edge outside it. Layout measurement is unchanged.
    snap_to_pixels: bool = false,
};

const vtable: layout.Content.VTable = .{
    .measure = measureFn,
    .fingerprint = fingerprintFn,
    .debug_name = "Image",
};

pub fn init(source: Source, style: Style) error{InvalidImage}!Image {
    try source.validate();
    return .{ .source = source, .style = style };
}

pub fn asImageContent(content: *const layout.Content) ?*const Image {
    if (content.vtable != &vtable) return null;
    return @fieldParentPtr("content", content);
}

/// Samples premultiplied RGBA channels (0...255) in source pixel-edge
/// coordinates: (0.5, 0.5) is the first pixel's center. Coordinates must
/// be finite and the source valid. Samples clamp at image edges. Backends
/// without a sampling selector can use this without duplicating filters.
pub fn sample(self: *const Image, x: f64, y: f64) [4]f64 {
    if (self.style.sampling == .nearest) return self.read(sampleIndex(@floor(x), self.source.width), sampleIndex(@floor(y), self.source.height));
    const cx = std.math.clamp(x - 0.5, 0, @as(f64, @floatFromInt(self.source.width - 1)));
    const cy = std.math.clamp(y - 0.5, 0, @as(f64, @floatFromInt(self.source.height - 1)));
    const x0: u32 = @intFromFloat(@floor(cx));
    const y0: u32 = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, self.source.width - 1);
    const y1 = @min(y0 + 1, self.source.height - 1);
    const fx = cx - @floor(cx);
    const fy = cy - @floor(cy);
    const tl = self.read(x0, y0);
    const tr = self.read(x1, y0);
    const bl = self.read(x0, y1);
    const br = self.read(x1, y1);
    var result: [4]f64 = undefined;
    for (&result, 0..) |*value, channel| {
        const upper = tl[channel] * (1 - fx) + tr[channel] * fx;
        const lower = bl[channel] * (1 - fx) + br[channel] * fx;
        value.* = upper * (1 - fy) + lower * fy;
    }
    return result;
}

fn sampleIndex(value: f64, size: u32) u32 {
    return @intFromFloat(std.math.clamp(value, 0, @as(f64, @floatFromInt(size - 1))));
}

fn read(self: *const Image, x: u32, y: u32) [4]f64 {
    const row = self.source.row(y);
    if (self.source.format == .gray8) {
        const g: f64 = @floatFromInt(row[x]);
        return .{ g, g, g, 255 };
    }
    const p = row[@as(usize, x) * 4 ..][0..4];
    const r = if (self.source.format == .rgba8_premultiplied) p[0] else p[2];
    const b = if (self.source.format == .rgba8_premultiplied) p[2] else p[0];
    return .{ @floatFromInt(r), @floatFromInt(p[1]), @floatFromInt(b), @floatFromInt(p[3]) };
}

/// The image rectangle in points, before clipping to `box`. Renderers use
/// this shared geometry and clip to both the box and active scissors.
/// Empty/invalid boxes or sources draw nothing. `device_scale` must be
/// positive and finite, including when snapping is disabled.
pub fn placement(self: *const Image, box: Rect, device_scale: f32) ?Rect {
    self.source.validate() catch return null;
    if (!std.math.isFinite(device_scale) or device_scale <= 0 or
        !std.math.isFinite(box.x) or !std.math.isFinite(box.y) or
        !std.math.isFinite(box.w) or !std.math.isFinite(box.h) or box.w <= 0 or box.h <= 0) return null;
    const natural = self.source.pointSize();
    const size: Vec2 = switch (self.style.fit_mode) {
        .contain, .cover => blk: {
            const sx = box.w / natural.x;
            const sy = box.h / natural.y;
            const factor = if (self.style.fit_mode == .contain) @min(sx, sy) else @max(sx, sy);
            break :blk .init(natural.x * factor, natural.y * factor);
        },
        .crop => natural,
        .stretch => .init(box.w, box.h),
    };
    var x = box.x + aligned(box.w - size.x, self.style.alignment.x);
    var y = box.y + aligned(box.h - size.y, self.style.alignment.y);
    if (self.style.snap_to_pixels) {
        x = @round(x * device_scale) / device_scale;
        y = @round(y * device_scale) / device_scale;
    }
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or
        !std.math.isFinite(size.x) or !std.math.isFinite(size.y) or size.x <= 0 or size.y <= 0) return null;
    return .init(x, y, size.x, size.y);
}

fn aligned(extra: f32, gravity: layout.Gravity) f32 {
    return extra * switch (gravity) {
        .start => @as(f32, 0),
        .center => @as(f32, 0.5),
        .end => @as(f32, 1),
    };
}

fn measureFn(content: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
    const self = asImageContent(content).?;
    self.source.validate() catch return error.MeasureFailed;
    inline for (.{ constraints.max_width, constraints.max_height }) |limit| {
        if (limit) |value| if (!std.math.isFinite(value) or value < 0) return error.MeasureFailed;
    }
    const natural = self.source.pointSize();
    // Missing limits use the natural size, never floatMax or infinity.
    // With just one limit, uniform fits derive the other axis from it.
    const width = constraints.max_width orelse natural.x;
    const height = constraints.max_height orelse natural.y;
    const size: Vec2 = switch (self.style.fit_mode) {
        .contain, .cover => blk: {
            if (width == 0 or height == 0) break :blk .zero;
            const sx = width / natural.x;
            const sy = height / natural.y;
            const factor = if (constraints.max_width == null) sy else if (constraints.max_height == null) sx else if (self.style.fit_mode == .contain) @min(sx, sy) else @max(sx, sy);
            break :blk .init(natural.x * factor, natural.y * factor);
        },
        .crop => constraints.clamp(natural),
        .stretch => .init(width, height),
    };
    if (!std.math.isFinite(size.x) or !std.math.isFinite(size.y)) return error.MeasureFailed;
    return size;
}

fn fingerprintFn(content: *const layout.Content) u64 {
    const self = asImageContent(content).?;
    var hasher = std.hash.Wyhash.init(0);
    // Hash fields rather than struct bytes (which can include padding),
    // and source identity rather than potentially large image data.
    inline for (.{ @intFromPtr(self.source.data.ptr), self.source.data.len, self.source.width, self.source.height, self.source.stride, self.source.format, @as(u32, @bitCast(self.source.scale)), self.revision, self.style.fit_mode, self.style.alignment.x, self.style.alignment.y, self.style.sampling, self.style.snap_to_pixels }) |value| {
        std.hash.autoHash(&hasher, value);
    }
    return hasher.final();
}

test "image measurement stays finite, respects density and fits every mode" {
    const testing = std.testing;
    const bytes: [200]u8 = @splat(0);
    var image = try Image.init(.{ .data = &bytes, .width = 20, .height = 10, .stride = 20, .format = .gray8, .scale = 2 }, .{});
    try testing.expectEqual(Vec2.init(10, 5), try image.content.measure(.{}));
    try testing.expectEqual(Vec2.init(40, 20), try image.content.measure(.init(40, 40)));
    try testing.expectEqual(Vec2.init(40, 20), try image.content.measure(.init(40, null)));
    try testing.expectEqual(Vec2.init(80, 40), try image.content.measure(.init(null, 40)));
    image.style.fit_mode = .cover;
    try testing.expectEqual(Vec2.init(80, 40), try image.content.measure(.init(40, 40)));
    image.style.fit_mode = .crop;
    try testing.expectEqual(Vec2.init(4, 5), try image.content.measure(.init(4, 40)));
    image.style.fit_mode = .stretch;
    try testing.expectEqual(Vec2.init(40, 5), try image.content.measure(.init(40, null)));
    try testing.expectError(error.MeasureFailed, image.content.measure(.init(-1, null)));
    inline for (std.meta.tags(FitMode)) |mode| {
        image.style.fit_mode = mode;
        const empty = try image.content.measure(.init(0, 0));
        try testing.expectEqual(Vec2.zero, empty);
        try testing.expectEqual(@as(?Rect, null), image.placement(.zero, 1));
    }
}

test "image placement aligns overflow and snaps only its origin" {
    const testing = std.testing;
    const bytes: [8]u8 = @splat(0);
    var image = try Image.init(.{ .data = &bytes, .width = 4, .height = 2, .stride = 4, .format = .gray8 }, .{});
    try testing.expectEqual(Rect.init(10, 25, 20, 10), image.placement(.init(10, 20, 20, 20), 1).?);
    image.style.fit_mode = .cover;
    image.style.alignment = .bottom_right;
    try testing.expectEqual(Rect.init(-10, 20, 40, 20), image.placement(.init(10, 20, 20, 20), 1).?);
    image.style.fit_mode = .crop;
    image.style.snap_to_pixels = true;
    try testing.expectEqual(Rect.init(0.5, 1, 4, 2), image.placement(.init(0.3, 0.8, 4, 2), 2).?);
}

test "image rejects invalid buffers, density and dimensions without overflow" {
    const testing = std.testing;
    const bytes: [8]u8 = @splat(0);
    const source: Source = .{ .data = &bytes, .width = 2, .height = 2, .stride = 4, .format = .gray8 };
    try source.validate();
    var bad = source;
    bad.stride = 1;
    try testing.expectError(error.InvalidImage, bad.validate());
    bad = source;
    bad.data = bytes[0..7];
    try testing.expectError(error.InvalidImage, bad.validate());
    inline for (.{ @as(f32, 0), -1, std.math.nan(f32), std.math.inf(f32) }) |scale| {
        bad = source;
        bad.scale = scale;
        try testing.expectError(error.InvalidImage, Image.init(bad, .{}));
    }
    bad = source;
    bad.width = 0;
    try testing.expectError(error.InvalidImage, bad.validate());
    bad.width = std.math.maxInt(u32);
    bad.height = std.math.maxInt(u32);
    bad.stride = std.math.maxInt(u32);
    bad.format = .rgba8_premultiplied;
    try testing.expectError(error.InvalidImage, bad.validate());
}

test "image damage is stable until revision or rendering inputs change" {
    const testing = std.testing;
    var bytes: [8]u8 = @splat(0);
    var image = try Image.init(.{ .data = &bytes, .width = 4, .height = 2, .stride = 4, .format = .gray8 }, .{});
    var damage: layout.Damage = .{};
    defer damage.deinit(testing.allocator);
    const commands = [_]layout.RenderCommand{.{ .bbox = .init(2, 2, 4, 2), .data = .{ .content = &image.content } }};
    _ = try damage.update(testing.allocator, &commands, .init(20, 20));
    try testing.expectEqual(0, (try damage.update(testing.allocator, &commands, .init(20, 20))).len);
    bytes[0] = 255;
    image.revision += 1;
    try testing.expect((try damage.update(testing.allocator, &commands, .init(20, 20))).len > 0);
    try testing.expectEqual(0, (try damage.update(testing.allocator, &commands, .init(20, 20))).len);
    inline for (.{ "fit_mode", "alignment", "sampling", "snap_to_pixels" }) |field| {
        const before = image.content.fingerprint();
        @field(image.style, field) = switch (comptime std.meta.stringToEnum(std.meta.FieldEnum(Style), field).?) {
            .fit_mode => .cover,
            .alignment => .bottom_right,
            .sampling => .nearest,
            .snap_to_pixels => true,
        };
        try testing.expect(before != image.content.fingerprint());
    }
}
