const CornerRadius = @This();

top_left: f32 = 0,
top_right: f32 = 0,
bottom_left: f32 = 0,
bottom_right: f32 = 0,

pub fn uniform(v: f32) CornerRadius {
    return .{
        .top_left = v,
        .top_right = v,
        .bottom_left = v,
        .bottom_right = v,
    };
}
