//! Sizing represents how to resolve the size of the unit within a layout.
const std = @import("std");

const root = @import("root.zig");
const Range = root.Range;
const Vec2 = root.Vec2;

const Sizing = @This();

width: Dimension = .default,
height: Dimension = .default,

/// Dimension represents how to resolve the size of the unit in a particular axis.
pub const Dimension = struct {
    // NOTE: a union was not used here for better initialization ergonomics
    mode: Mode,
    value: union {
        range: Range,
        number: f32,
    },

    pub const Mode = enum {
        fit,
        grow,
        percent,
        fixed,
    };

    pub const default = Dimension.fit(.{});

    pub fn eql(self: Dimension, other: Dimension) bool {
        if (self.mode != other.mode) {
            return false;
        }

        return switch (self.mode) {
            .fit, .grow => self.value.range.eql(other.value.range),
            .percent, .fixed => self.value.number == other.value.number,
        };
    }

    pub fn fit(range: Range) Dimension {
        return .{ .mode = .fit, .value = .{ .range = range } };
    }

    pub fn grow(range: Range) Dimension {
        return .{ .mode = .grow, .value = .{ .range = range } };
    }

    pub fn percent(pct: f32) Dimension {
        std.debug.assert(pct >= 0.0 and pct <= 1.0);
        return .{ .mode = .percent, .value = .{ .number = pct } };
    }

    pub fn fixed(value: f32) Dimension {
        return .{ .mode = .fixed, .value = .{ .number = value } };
    }

    fn intrinsic(self: Dimension) f32 {
        return switch (self.mode) {
            .fit => self.value.range.min,
            .grow => self.value.range.min,
            .percent => if (self.value.number > 0) std.math.inf(f32) else 0,
            .fixed => self.value.number,
        };
    }

    pub fn clamp(self: Dimension, current: f32, available: f32) f32 {
        return switch (self.mode) {
            .percent => available * self.value.number,
            .fixed => self.value.number,
            inline .fit, .grow => self.value.range.clamp(current),
        };
    }
};

pub const default = both(.default);

pub fn init(w: Dimension, h: Dimension) Sizing {
    return .{ .width = w, .height = h };
}

fn both(dim: Dimension) Sizing {
    return .init(dim, dim);
}

pub fn fit(min_max: Range) Sizing {
    return both(.fit(min_max));
}

pub fn fitXY(x: Range, y: Range) Sizing {
    return init(.fit(x), .fit(y));
}

pub fn grow(min_max: Range) Sizing {
    return both(.grow(min_max));
}

pub fn growXY(x: Range, y: Range) Sizing {
    return init(.grow(x), .grow(y));
}

pub fn fixed(size: f32) Sizing {
    return both(.fixed(size));
}

pub fn fixedXY(x: f32, y: f32) Sizing {
    return init(.fixed(x), .fixed(y));
}

/// Range between 0 - 1
pub fn percent(pct: f32) Sizing {
    return both(.percent(pct));
}

/// Range between 0 - 1
pub fn percentXY(x: f32, y: f32) Sizing {
    return init(.percent(x), .percent(y));
}

pub fn intrinsic(self: Sizing) Vec2 {
    return .init(self.width.intrinsic(), self.height.intrinsic());
}

pub inline fn axisDimension(self: Sizing, axis: Vec2.Axis) Dimension {
    return switch (axis) {
        .x => self.width,
        .y => self.height,
    };
}

pub fn clamp(self: Sizing, size: Vec2, available: Vec2) Vec2 {
    return .init(
        self.width.clamp(size.x, available.x),
        self.height.clamp(size.y, available.y),
    );
}

pub fn eql(self: Sizing, other: Sizing) bool {
    return self.width.eql(other.width) and self.height.eql(other.height);
}
