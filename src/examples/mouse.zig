const std = @import("std");
const fabrum = @import("fabrum");

const Button = @import("components/button.zig");

const App = struct {
    btn: Button,

    element: fabrum.Element = .{
        .vtable = &.{
            .layout = layoutFn,
        },
    },

    fn layoutFn(elem: *const fabrum.Element, ctx: *fabrum.Context) void {
        const self: *const App = @fieldParentPtr("element", elem);

        self.btn.element.layout(ctx);

        self.element.children = &.{&self.btn.element};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var app = App{
        .btn = .{
            .id = .fromStringComptime("btn"),
            .text = "Hello",
        },
    };

    const ctx = try fabrum.Context.init(allocator, .{});
    while (true) {
        var render_commands = ctx.layoutElements(
            .{ .sizing = .fixedXY(500, 400), .child_alignment = .center },
            &.{
                &app.element,
            },
        );

        _ = &render_commands; // try renderer.render(&render_commands);

        // source position and pressed state from your platform
        app.element.handleMouse(ctx, .zero, false, .zero);
    }
}
