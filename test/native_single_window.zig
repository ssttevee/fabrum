//! Desktop regression: standalone ctx.quit must defer teardown and join tasks.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.current;

const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    timer_group: std.Io.Group = .init,
    started: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    calls: usize = 0,

    fn worker(task: *app.Task, self: *Probe) error{Canceled}!void {
        self.started.store(true, .release);
        defer self.stopped.store(true, .release);
        while (true) try std.Io.sleep(task.io, .fromSeconds(60), .awake);
    }
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (self.calls != 1 or !self.stopped.load(.acquire)) fail("termination must run once after task cancellation");
        self.done.store(true, .release);
        std.debug.print("native-single-window PASS\n", .{});
    }
    fn timer(self: *Probe) void {
        for (0..200) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            if (self.done.load(.acquire)) return;
            platform.automation.runOnMain(tick, self);
        }
        fail("standalone quit timed out");
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        if (self.done.load(.acquire) or !self.started.load(.acquire)) return;
        const handle = self.gui.handleOf(app.testing.rootInstance(Root).native("quit")) orelse return;
        platform.automation.click(handle);
    }
};
const Root = struct {
    const Self = @This();
    pub const Props = struct { probe: *Probe };
    pub const State = struct {};
    pub const Msg = union(enum) { quit, finished: error{Canceled}!void };
    pub fn update(_: *State, msg: Msg, ctx: *app.Update(Self)) !void {
        switch (msg) {
            .quit => {
                try ctx.quit();
                try ctx.quit();
            },
            .finished => {},
        }
    }
    pub fn view(ui: *app.Ui, _: *const State, props: Props) !void {
        const on = ui.messages(Self);
        try ui.task("worker", .{}, Probe.worker, .{props.probe}, on.handler(.finished));
        try app.widgets.button(ui, "quit", .{ .label = "Quit", .on_click = on.bind(.quit) });
    }
};
fn fail(message: []const u8) noreturn {
    std.debug.print("native-single-window FAIL: {s}\n", .{message});
    std.process.exit(1);
}
pub fn main(init: std.process.Init) !void {
    const self = try init.gpa.create(Probe);
    self.* = .{ .gui = undefined, .io = init.io };
    try self.gui.init(init.gpa, init.io, .{ .probe = self }, .{ .title = "Standalone quit smoke" }, .{ .watchdog_ms = 37, .on_terminate = .{ .ctx = self, .call = Probe.terminate } });
    if (self.gui.runtime.core.watchdog_ms != 37) fail("window initialization lost watchdog budget");
    try self.timer_group.concurrent(init.io, Probe.timer, .{self});
    self.gui.run();
}
