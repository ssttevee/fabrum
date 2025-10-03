const std = @import("std");
const fabrum = @import("fabrum");

const Container = @This();

children: []const *const fabrum.Element,
element: fabrum.Element = .{
    .vtable = &.{
        .layout = layoutFn,
    },
},

pub const Props = struct {
    children: []const *const fabrum.Element,
};

pub fn init(props: Props) Container {
    return .{
        .children = props.children,
    };
}

fn layoutFn(el: *const fabrum.Element, ctx: *fabrum.Context) void {
    const self: *const Container = @fieldParentPtr("element", el);

    const idx = ctx.openContainer(.{
        .corner_radius = .uniform(16),
        .border = .{
            .color = .gray(127),
            .widths = .{},
        },
    });
    defer ctx.closeContainer(idx);

    for (self.children) |child| {
        child.layout(ctx);
    }
}
