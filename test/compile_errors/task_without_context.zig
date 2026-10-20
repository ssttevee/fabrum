const std = @import("std");
const app = @import("fabrum").app;

fn read(_: std.Io) u32 {
    return 1;
}

export fn invalidTask(ui: *app.Ui) void {
    ui.task("read", read, .{}, @as(app.Handler(u32), undefined)) catch {};
}
