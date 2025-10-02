const root = @import("root.zig");

const Rect = root.Rect;
const Content = root.Content;
const Color = root.Color;
const CornerRadius = root.CornerRadius;
const BorderWidths = root.BorderWidths;

const RenderCommand = @This();

bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
z_index: i16 = 0,
element_id: u64 = 0,
data: Data,

pub const Data = union(enum) {
    rectangle: Rectangle,
    border: Border,
    content: *Content,
    scissor_start: ScissorStart,
    scissor_end: void,

    pub const Rectangle = struct {
        color: Color,
        corner_radius: CornerRadius,
    };

    pub const Border = struct {
        color: Color,
        widths: BorderWidths,
        corner_radius: CornerRadius,
    };

    pub const ScissorStart = struct {
        horizontal: bool,
        vertical: bool,
    };
};

pub const Iterator = struct {
    vtable: *const VTable,

    const VTable = struct {
        next: *const fn (*Iterator) ?RenderCommand,
    };

    pub fn next(self: *Iterator) ?RenderCommand {
        return self.vtable.next(self);
    }
};
