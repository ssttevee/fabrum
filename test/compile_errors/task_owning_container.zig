const std = @import("std");
const app = @import("fabrum").app;

fn work(_: *app.Task, _: std.ArrayList(u8)) void {}

export fn invalidTask(ui: *app.Ui) void {
    ui.task("container", .{}, work, .{@as(std.ArrayList(u8), .empty)}, null) catch {};
}
