const fabrum = @import("../root.zig");
const layout = @import("../layout.zig");

const Gravity = layout.Gravity;
const Vec2 = fabrum.Vec2;

const ChildAlignment = @This();

x: Gravity = .default,
y: Gravity = .default,

pub const top_left = init(.start, .start);
pub const top_center = init(.center, .start);
pub const top_right = init(.end, .start);

pub const center_left = init(.start, .center);
pub const center_center = init(.center, .center);
pub const center_right = init(.end, .center);

pub const bottom_left = init(.start, .end);
pub const bottom_center = init(.center, .end);
pub const bottom_right = init(.end, .end);

pub const left_top = top_left;
pub const left_center = center_left;
pub const left_bottom = bottom_left;

pub const center_top = top_center;
pub const center_bottom = bottom_center;

pub const right_top = top_right;
pub const right_center = center_right;
pub const right_bottom = bottom_right;

pub const center = center_center;

pub fn init(x: Gravity, y: Gravity) ChildAlignment {
    return .{ .x = x, .y = y };
}

pub fn axis(self: ChildAlignment, ax: Vec2.Axis) Gravity {
    return switch (ax) {
        inline else => |tag| @field(self, @tagName(tag)),
    };
}
