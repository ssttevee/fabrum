const std = @import("std");

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

/// Returns the radii scaled down uniformly so that adjacent corners don't
/// overlap within a `w` x `h` box, matching CSS `border-radius` behavior.
pub fn fitted(self: CornerRadius, w: f32, h: f32) CornerRadius {
    const scale = @min(
        @min(fitRatio(w, self.top_left + self.top_right), fitRatio(w, self.bottom_left + self.bottom_right)),
        @min(fitRatio(h, self.top_left + self.bottom_left), fitRatio(h, self.top_right + self.bottom_right)),
    );
    if (scale >= 1) return self;

    return .{
        .top_left = self.top_left * scale,
        .top_right = self.top_right * scale,
        .bottom_left = self.bottom_left * scale,
        .bottom_right = self.bottom_right * scale,
    };
}

fn fitRatio(length: f32, radii_sum: f32) f32 {
    return if (radii_sum > 0) length / radii_sum else 1;
}

test "CornerRadius.fitted leaves radii that fit unchanged" {
    const cr = uniform(10).fitted(100, 40);
    try std.testing.expectEqual(uniform(10), cr);
}

test "CornerRadius.fitted scales overlapping radii proportionally" {
    // pill: radius 50 on a 100x40 box must shrink to half the height
    const pill = uniform(50).fitted(100, 40);
    try std.testing.expectApproxEqAbs(20, pill.top_left, 1e-4);
    try std.testing.expectApproxEqAbs(20, pill.bottom_right, 1e-4);

    // uneven: the tightest edge decides the shared scale factor
    const uneven = (CornerRadius{ .top_left = 60, .top_right = 20 }).fitted(40, 100);
    try std.testing.expectApproxEqAbs(30, uneven.top_left, 1e-4);
    try std.testing.expectApproxEqAbs(10, uneven.top_right, 1e-4);
    try std.testing.expectEqual(0, uneven.bottom_left);
}
