const std = @import("std");
const app = @import("fabrum").app;

fn work(_: *app.Task) std.AutoHashMapUnmanaged(u32, u32) {
    return .empty;
}

export fn invalidTask(ui: *app.Ui) void {
    ui.task("container", .{}, work, .{}, @as(app.Handler(std.AutoHashMapUnmanaged(u32, u32)), undefined)) catch {};
}
