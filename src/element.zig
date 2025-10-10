const std = @import("std");
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
    /// called when a new element is introduced to the tree for setting up state and callbacks.
    handleMount: ?*const fn (self: *Element, platform: *Platform) void = null,
    // /// called before `layout` for recreating
    // update: *const fn (self: *Element, ctx: *Context) void,
    /// adds units to the current layout
    layout: *const fn (self: *Element, ctx: *Context) void,
    /// Mouse state handler. If true is returned, then propagation stops.
    handleMouse: ?*const fn (self: *Element, mouse_event: MouseEvent, ctx: *Context, dirty_out: *bool) bool = null,
};

pub const Platform = struct {
    vtable: *const Platform.VTable,

    pub const VTable = struct {
        redraw: *const fn (self: *Platform) void,
    };

    pub fn redraw(self: *Platform) void {
        self.vtable.redraw(self);
    }
};

pub const MouseEvent = struct {
    /// where the mouse is relative to the top left of the window
    position: Vec2,
    /// bitmask of all the buttons that are depressed
    pressed: std.StaticBitSet(8),
    /// The amount scrolled in each direction.
    ///
    /// X means right and Y means down, negative mean left and up respectively.
    ///
    /// The magnitude per scroll unit depends on the platform and hardware.
    scroll_delta: Vec2,
};

pub fn handleMount(self: *Element, platform: *Platform) void {
    if (self.vtable.handleMount) |f| f(self, platform);
}

pub fn layout(self: *Element, ctx: *Context) void {
    self.vtable.layout(self, ctx);
}

pub fn handleMouse(self: *Element, mouse_event: MouseEvent, ctx: *Context, dirty_out: *bool) bool {
    for (self.children) |child| {
        if (child.handleMouse(mouse_event, ctx, dirty_out)) {
            return true;
        }
    }

    if (self.vtable.handleMouse) |f| return f(self, mouse_event, ctx, dirty_out);

    return false;
}
