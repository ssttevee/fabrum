const root = @import("root.zig");
const Vec2 = root.Vec2;

const Rect = @This();

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

    return .init(l, t, r - l, b - t);
}

pub fn initVecs(pt1: Vec2, pt2: Vec2) Rect {
    return .initTLBR(pt1.x, pt1.y, pt2.x, pt2.y);
}

pub fn contains(self: Rect, pt: Vec2) bool {
    return pt.x >= self.x and pt.x < self.x + self.w and pt.y >= self.y and pt.y < self.y + self.h;
}
