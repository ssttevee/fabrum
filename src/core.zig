const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const Axis = enum {
        x,
        y,

        pub fn other(self: Axis) Axis {
            return switch (self) {
                .x => .y,
                .y => .x,
            };
        }
    };

    pub const zero = init(0, 0);

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn addValues(self: Vec2, x: f32, y: f32) Vec2 {
        return init(self.x + x, self.y + y);
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return self.addValues(other.x, other.y);
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return init(self.x - other.x, self.y - other.y);
    }

    pub fn isZero(self: Vec2) bool {
        return self.x == 0 and self.y == 0;
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub const zero = init(0, 0, 0, 0);

    pub fn init(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        };
    }

    pub fn initSize(w: f32, h: f32) Rect {
        return init(0, 0, w, h);
    }

    pub fn initTLBR(x1: f32, y1: f32, x2: f32, y2: f32) Rect {
        const t = @min(y1, y2);
        const l = @min(x1, x2);
        const b = @max(y1, y2);
        const r = @max(x1, x2);

        return .init(l, t, @intCast(r - l), @intCast(b - t));
    }

    pub fn initVecs(pt1: Vec2, pt2: Vec2) Rect {
        return .initTLBR(pt1.x, pt1.y, pt2.x, pt2.y);
    }

    pub fn contains(self: Rect, pt: Vec2) bool {
        return pt.x >= self.x and pt.x < self.x + self.w and pt.y >= self.y and pt.y < self.y + self.h;
    }
};

pub const Range = struct {
    /// The smallest final size of the element on this axis will be this value in pixels.
    min: f32 = 0,

    /// The largest final size of the element on this axis will be this value in pixels.
    max: f32 = std.math.inf(f32),

    pub fn clamp(self: Range, value: f32) f32 {
        return std.math.clamp(value, self.min, self.max);
    }

    pub fn eql(self: Range, other: Range) bool {
        return self.min == other.min and self.max == other.max;
    }
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black = rgb(0, 0, 0);
    pub const white = rgb(255, 255, 255);

    pub const transparent = rgba(0, 0, 0, 0);

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return rgb(r, g, b, 255);
    }
};
