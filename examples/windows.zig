//! Two views of one document, with independent component state per window.
//! Run with `zig build run-windows` on AppKit, GTK or Win32.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;

const Document = struct { count: i32 = 0 };

/// Application-owned operations. Components borrow this service; the
/// controller and document outlive every window that uses them.
const Commands = struct {
    ptr: *anyopaque,
    open: *const fn (*anyopaque) anyerror!void,
    changed: *const fn (*anyopaque) void,
};

pub const Editor = struct {
    pub const Props = struct { document: *Document };
    pub const State = struct { clicks: usize = 0 };
    pub const Msg = union(enum) { increment, new_window, close };

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Editor)) !void {
        switch (msg) {
            .increment => {
                ctx.props.document.count += 1;
                state.clicks += 1;
                if (ctx.tryUse(Commands)) |commands| commands.changed(commands.ptr);
            },
            .new_window => {
                const commands = ctx.use(Commands);
                try commands.open(commands.ptr);
            },
            .close => try ctx.close(),
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Editor);
        try ui.open(null, .{ .layout = .{
            .sizing = .grow(.{}),
            .axis = .y,
            .padding = .all(20),
            .child_gap = 12,
        } });
        defer ui.close();
        try ui.print(.{ .font_size = 24 }, "Document count: {d}", .{props.document.count});
        try ui.print(.{}, "Clicks in this window: {d}", .{state.clicks});
        try app.widgets.button(ui, "increment", .{ .label = "Increment document", .on_click = on.bind(.increment) });
        try app.widgets.button(ui, "new", .{
            .label = "New window",
            .on_click = on.bind(.new_window),
            .enabled = ui.tryUse(Commands) != null,
        });
        try app.widgets.button(ui, "close", .{ .label = "Close this window", .on_click = on.bind(.close) });
    }
};

const Controller = struct {
    const Host = app.platform.current.Application;
    host: Host,
    document: Document = .{},
    commands: Commands,
    ids: std.ArrayList(app.WindowId) = .empty,
    gpa: std.mem.Allocator,

    fn open(ptr: *anyopaque) !void {
        const self: *Controller = @ptrCast(@alignCast(ptr));
        // Reserve first so a successfully opened window is always tracked.
        try self.ids.ensureUnusedCapacity(self.gpa, 1);
        const id = try self.host.openWindow(Editor, .{ .document = &self.document }, .{
            .title = "Shared document",
            .width = 440,
            .height = 280,
        }, .{ .provide = &.{app.RootValue.of(&self.commands)} });
        self.ids.appendAssumeCapacity(id);
    }

    fn changed(ptr: *anyopaque) void {
        const self: *Controller = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        while (i < self.ids.items.len) {
            if (self.host.requestFrame(self.ids.items[i])) {
                i += 1;
            } else {
                _ = self.ids.swapRemove(i);
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const controller = try init.gpa.create(Controller);
    defer init.gpa.destroy(controller);
    controller.* = .{
        .host = undefined,
        .gpa = init.gpa,
        .commands = .{ .ptr = controller, .open = Controller.open, .changed = Controller.changed },
    };
    defer controller.ids.deinit(init.gpa);
    try controller.host.init(init.gpa, init.io, .{});
    defer controller.host.deinit();
    try Controller.open(controller);
    try Controller.open(controller);
    controller.host.run();
}

test "windows share document data while component state remains independent" {
    inline for (.{ app.testing.Widgets.native, app.testing.Widgets.drawn }) |widgets| {
        var document: Document = .{};
        var first: app.testing.Harness(.{}, Editor) = try .init(.{ .document = &document }, .{ .widgets = widgets });
        defer first.deinit();
        var second: app.testing.Harness(.{}, Editor) = try .init(.{ .document = &document }, .{ .widgets = widgets });
        defer second.deinit();
        try first.frame();
        try second.frame();
        try first.post(first.root().handler(Editor, .increment), {});
        try second.frame();
        try first.expectText("Document count: 1");
        try second.expectText("Document count: 1");
        try first.expectText("Clicks in this window: 1");
        try second.expectText("Clicks in this window: 0");
        try second.post(second.root().handler(Editor, .increment), {});
        try first.frame();
        try std.testing.expectEqual(2, document.count);
        try std.testing.expectEqual(1, first.state().clicks);
        try std.testing.expectEqual(1, second.state().clicks);
    }
}
