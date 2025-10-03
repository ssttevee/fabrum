const root = @import("root.zig");

const Context = root.Context;
const Vec2 = root.Vec2;

const Element = @This();

/// Convenience field that's meant to be updated during `layout`.
///
/// If populated, `handleMouse` will automatically propagate to children.
///
/// If it's not convenient to populate it (i.e. dynamic children), it is
/// perfectly valid to manually call `handleMouse` on the children in an
/// overridden implementation.
children: []const *Element = &.{},
vtable: *const VTable,

pub const VTable = struct {
    /// adds units to the current layout
    layout: *const fn (self: *Element, ctx: *Context) void,
    /// Mouse state handler. If true is returned, then propagation stops.
    handleMouse: ?*const fn (self: *Element, ctx: *Context, pos: Vec2, pressed: bool, scroll: Vec2) bool,
};

pub fn layout(self: *Element, ctx: *Context) void {
    self.vtable.layout(self, ctx);
}

pub fn handleMouse(self: *Element, ctx: *Context, pos: Vec2, pressed: bool, scroll: Vec2) bool {
    for (self.children) |child| {
        if (child.handleMouse(ctx, pos, pressed, scroll)) {
            return true;
        }
    }

    if (self.vtable.handleMouse) |f| return f(self, ctx, pos, pressed, scroll);

    return false;
}
