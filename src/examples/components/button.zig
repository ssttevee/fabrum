const std = @import("std");
const fabrum = @import("fabrum");

const Button = @This();

id: fabrum.LayoutUnit.Id,
text: fabrum.TextContent,
look: Look.primary,
size: Size = .sm,
disabled: bool = false,
hovered: bool = false,
pressed: bool = false,

on_mouse_over_callback: ?*const fn (?*anyopaque) bool = null,
on_mouse_over_userdata: ?*anyopaque = null,
on_mouse_out_callback: ?*const fn (?*anyopaque) bool = null,
on_mouse_out_userdata: ?*anyopaque = null,
on_mouse_down_callback: ?*const fn (?*anyopaque) bool = null,
on_mouse_down_userdata: ?*anyopaque = null,
on_mouse_up_callback: ?*const fn (?*anyopaque) bool = null,
on_mouse_up_userdata: ?*anyopaque = null,

_prev_layout_unit_index: usize,

element: fabrum.Element = .{
    .vtable = &.{
        .layout = layoutFn,
    },
},

pub const Look = enum {
    primary,
    secondary,
    alert,
    outline,
    ghost,
    link,
};

pub const Size = enum {
    sm,
    md,
    lg,
};

fn layoutFn(el: *fabrum.Element, ctx: *fabrum.Context) void {
    const self: *Button = @fieldParentPtr("element", el);

    // TODO: add different container decls for looks and sizes
    el._prev_layout_unit_index = ctx.openContainer(.{ .layout = .{ .child_alignment = .center, .padding = .xy(24, 12) } });
    defer ctx.closeContainer(el._prev_layout_unit_index);

    ctx.appendContentId(self.id, &self.text.content);
}

fn setBoolAndGetEdge(prev: *bool, state: bool) ?enum { rising, falling } {
    if (prev.* == state) {
        return null;
    }

    defer prev.* = state;

    if (prev.*) {
        return .falling;
    }

    return .rising;
}

fn mouseFn(el: *fabrum.Element, ctx: *fabrum.Context, pos: fabrum.Vec2, pressed: bool, scroll: fabrum.Vec2) bool {
    const self: *Button = @fieldParentPtr("element", el);

    if (ctx.getUnitByIndex(self._prev_layout_unit_index)) |btn_unit| {
        // ignore disabled state

        var handled = false;
        const hovered = btn_unit.hovered(pos);
        if (setBoolAndGetEdge(&self.btn.hovered, hovered)) |edge| {
            // button hover state changed
            switch (edge) {
                .rising => if (self.btn.on_mouse_over_callback) |f| {
                    handled = f(self.btn.on_mouse_over_userdata) or handled;
                },
                .falling => if (self.btn.on_mouse_out_callback) |f| {
                    handled = f(self.btn.on_mouse_out_userdata) or handled;
                },
            }
        }

        if (setBoolAndGetEdge(&self.btn.pressed, hovered and pressed)) |edge| {
            // button hover state changed
            switch (edge) {
                .rising => if (self.btn.on_mouse_down_callback) |f| {
                    handled = f(self.btn.on_mouse_down_userdata) or handled;
                },
                .falling => if (self.btn.on_mouse_up_callback) |f| {
                    handled = f(self.btn.on_mouse_up_userdata) or handled;
                },
            }
        }

        if (hovered) {
            if (scroll.x < 0) {
                // scroll left
            } else if (scroll.x > 0) {
                // scroll right
            }

            if (scroll.y < 0) {
                // scroll up
            } else if (scroll.y > 0) {
                // scroll down
            }
        }

        return handled;
    }

    return false;
}
