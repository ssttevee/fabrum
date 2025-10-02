const Vec2 = @This();

x: f32,
y: f32,

pub const Axis = enum {
    x,
    y,

    pub fn cross(self: Axis) Axis {
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

pub fn eql(self: Vec2, other: Vec2) bool {
    return self.x == other.x and self.y == other.y;
}

pub fn axis(self: Vec2, ax: Axis) f32 {
    return switch (ax) {
        .x => self.x,
        .y => self.y,
    };
}
