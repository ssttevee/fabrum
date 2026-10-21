const std = @import("std");
const app = @import("fabrum").app;

fn work(_: *app.Task) std.heap.ArenaAllocator {
    return .init(std.heap.page_allocator);
}

export fn invalidTask(ui: *app.Ui) void {
    ui.task("container", .{}, work, .{}, @as(app.Handler(std.heap.ArenaAllocator), undefined)) catch {};
}
