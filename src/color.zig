const Color = @This();

r: u8,
g: u8,
b: u8,
a: u8,

pub const black = rgb(0, 0, 0);
pub const white = rgb(255, 255, 255);

pub const transparent = rgba(0, 0, 0, 0);

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return rgba(r, g, b, 255);
}

pub fn gray(v: u8) Color {
    return rgb(v, v, v);
}

pub fn isTransparent(self: Color) bool {
    return self.a == 0;
}
