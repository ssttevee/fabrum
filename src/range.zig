const std = @import("std");

pub const Range = @This();

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
