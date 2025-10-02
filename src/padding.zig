//! Padding represents the space around an unit.
const root = @import("root.zig");

const Vec2 = root.Vec2;

const Padding = @This();

left: f32 = 0,
right: f32 = 0,
top: f32 = 0,
bottom: f32 = 0,

pub inline fn h(self: Padding) f32 {
    return self.left + self.right;
}

pub inline fn v(self: Padding) f32 {
    return self.top + self.bottom;
}

pub inline fn sumAxis(self: Padding, axis: Vec2.Axis) f32 {
    return switch (axis) {
        .x => self.h(),
        .y => self.v(),
    };
}

pub inline fn toVec(self: Padding) Vec2 {
    return .init(self.h(), self.v());
}

pub inline fn topLeft(self: Padding) Vec2 {
    return .init(self.left, self.top);
}

pub fn init(left: f32, right: f32, top: f32, bottom: f32) Padding {
    return .{
        .left = left,
        .right = right,
        .top = top,
        .bottom = bottom,
    };
}

pub inline fn all(padding: f32) Padding {
    return .{
        .left = padding,
        .right = padding,
        .top = padding,
        .bottom = padding,
    };
}

pub inline fn x(x_pad: f32) Padding {
    return .{
        .left = x_pad,
        .right = x_pad,
    };
}

pub inline fn y(y_pad: f32) Padding {
    return .{
        .top = y_pad,
        .bottom = y_pad,
    };
}

pub inline fn xy(x_pad: f32, y_pad: f32) Padding {
    return .{
        .left = x_pad,
        .right = x_pad,
        .top = y_pad,
        .bottom = y_pad,
    };
}
