const BorderWidths = @This();

left: f32 = 0,
right: f32 = 0,
top: f32 = 0,
bottom: f32 = 0,

/// Adds a divider between each child.
between_children: f32 = 0,

pub fn isZero(self: BorderWidths) bool {
    return self.left == 0 and self.right == 0 and self.top == 0 and self.bottom == 0;
}

pub fn any(self: BorderWidths) bool {
    return !self.isZero() or self.between_children != 0;
}
