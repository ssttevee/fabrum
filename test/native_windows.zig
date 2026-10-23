//! Opt-in desktop integration smoke test. Requires an actual native event loop.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.current;

const Workers = struct {
    started: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(usize) = .init(0),

    fn work(task: *app.Task, self: *Workers) error{Canceled}!void {
        _ = self.started.fetchAdd(1, .release);
        defer _ = self.stopped.fetchAdd(1, .release);
        while (true) try std.Io.sleep(task.io, .fromSeconds(60), .awake);
    }
};

fn Page(comptime identity: u8) type {
    return struct {
        const Self = @This();
        pub const State = struct {
            count: usize = 0,
            guards: usize = 0,
            reason: app.platform.CloseReason = .window,
            marker: u8 = identity,
            asking: bool = false,
        };
        pub const Props = struct { guard: bool = true, workers: *Workers };
        pub const Msg = union(enum) { click, closing: app.platform.CloseReason, approve, cancel, ask, inform, answered: ?usize, finished: error{Canceled}!void };
        pub fn update(state: *State, msg: Msg, ctx: *app.Update(Self)) !void {
            switch (msg) {
                .click => state.count += 1,
                .closing => |reason| {
                    state.guards += 1;
                    state.reason = reason;
                },
                .approve => switch (state.reason) {
                    .window => try ctx.close(),
                    .quit => try ctx.quit(),
                },
                .cancel => try ctx.cancelClose(),
                .ask => {
                    try ctx.confirm(.{ .title = "Pending window reply", .text = "The test closes this window while this dialog is open." }, ctx.handler(.answered));
                    state.asking = true;
                },
                .answered => state.asking = false,
                .inform => try ctx.message(.{ .title = "Window notification", .text = "This notification closes with its window." }),
                .finished => {},
            }
        }
        pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
            const on = ui.messages(Self);
            try ui.task("worker", .{}, Workers.work, .{props.workers}, on.handler(.finished));
            if (props.guard) ui.guardClose(on.handler(.closing));
            try ui.open(null, .{ .layout = .{ .axis = .y, .padding = .all(20), .child_gap = 12 } });
            defer ui.close();
            try ui.print(.{}, "Window {d}: {d}", .{ identity, state.count });
            try app.widgets.button(ui, "increment", .{ .label = "Increment", .on_click = on.bind(.click) });
        }
    };
}
const A = Page(1);
const B = Page(2);

const Smoke = struct {
    gui: platform.Application,
    io: std.Io,
    worker: std.Io.Group = .init,
    stop: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    a: app.WindowId,
    b: app.WindowId,
    stale: app.WindowId,
    phase: u8 = 0,
    opened: bool = false,
    terminated: usize = 0,
    workers: Workers = .{},

    fn terminatedWindow(ptr: ?*anyopaque) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr.?));
        self.terminated += 1;
        if (self.phase != 8 or self.gui.windows.count() != 0) return;
        check(self.terminated == 3, "window teardown count mismatch");
        check(self.workers.stopped.load(.acquire) == 3, "window tasks were not joined before teardown callback");
        self.stop.store(true, .release);
        std.debug.print("native-windows PASS\n", .{});
    }

    fn timer(self: *Smoke) void {
        for (0..240) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            if (self.stop.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        self.timed_out.store(true, .release);
        platform.automation.runOnMain(tick, self);
    }
    fn fail(message: []const u8) noreturn {
        std.debug.print("native-windows FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
    fn check(ok: bool, message: []const u8) void {
        if (!ok) fail(message);
    }
    fn post(comptime Root: type, window: *platform.App(Root), comptime tag: std.meta.Tag(Root.Msg)) void {
        window.runtime.post(app.testing.rootInstance(Root).handler(Root, tag), {}) catch fail("posting message");
    }
    fn click(comptime Root: type, window: *platform.App(Root)) bool {
        const handle = window.handleOf(app.testing.rootInstance(Root).native("increment")) orelse return false;
        platform.automation.click(handle);
        return true;
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr.?));
        if (self.stop.load(.acquire)) return;
        self.pending.store(false, .release);
        if (self.timed_out.load(.acquire)) fail("timed out waiting for native lifecycle");
        const wa = self.gui.window(A, self.a);
        const wb = self.gui.window(B, self.b);
        switch (self.phase) {
            0 => {
                if (!self.opened) {
                    self.opened = true;
                    self.a = self.gui.openWindow(A, .{ .guard = false, .workers = &self.workers }, .{ .title = "Smoke A", .width = 300, .height = 180 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } }) catch fail("open A from empty application");
                    self.b = self.gui.openWindow(B, .{ .workers = &self.workers }, .{ .title = "Smoke B", .width = 300, .height = 180 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } }) catch fail("open B");
                    return;
                }
                const a = wa orelse return;
                const b = wb orelse return;
                _ = a.runtime.rootState(A) orelse return;
                _ = b.runtime.rootState(B) orelse return;
                if (self.workers.started.load(.acquire) != 2) return;
                check(self.gui.window(B, self.a) == null, "wrong root cast accepted");
                check(self.gui.window(A, self.b) == null, "wrong root cast accepted");
                if (!click(A, a)) return;
                self.phase = 1;
            },
            1 => {
                const a = wa orelse fail("A disappeared");
                const b = wb orelse fail("B disappeared");
                if (a.runtime.rootState(A).?.count != 1) return;
                check(b.runtime.rootState(B).?.count == 0, "click leaked across windows");
                post(A, a, .ask);
                post(B, b, .inform);
                self.phase = 9;
            },
            9 => {
                const a = wa orelse fail("A disappeared before pending dialog close");
                if (!a.runtime.rootState(A).?.asking) return;
                check(self.gui.close(self.a), "close A rejected");
                self.phase = 2;
            },
            2 => {
                if (wa != null) return;
                check(self.workers.stopped.load(.acquire) == 1, "closing A did not join its task");
                const b = wb orelse fail("closing A destroyed B");
                if (!click(B, b)) return;
                self.stale = self.a;
                self.a = self.gui.openWindow(A, .{ .workers = &self.workers }, .{ .title = "Smoke A reopened", .width = 300, .height = 180 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } }) catch fail("reopen A");
                check(self.a != self.stale, "window generation reused");
                check(!self.gui.close(self.stale), "stale close accepted");
                check(!self.gui.present(self.stale), "stale present accepted");
                check(!self.gui.requestFrame(self.stale), "stale redraw accepted");
                self.phase = 3;
            },
            3 => {
                const a = wa orelse return;
                const b = wb orelse fail("B disappeared");
                _ = a.runtime.rootState(A) orelse return;
                if (self.workers.started.load(.acquire) != 3) return;
                if (b.runtime.rootState(B).?.count != 1) return;
                self.gui.quit();
                self.phase = 4;
            },
            4 => {
                const a = wa orelse fail("quit destroyed A before approval");
                const b = wb orelse fail("quit destroyed B before approval");
                if (a.runtime.rootState(A).?.guards == 0) return;
                check(b.runtime.rootState(B).?.guards == 0, "quit guards were not serialized");
                post(A, a, .cancel);
                self.phase = 5;
            },
            5 => {
                if (self.gui.windows.quitting) return;
                check(wa != null and wb != null, "cancelled quit destroyed windows");
                self.gui.quit();
                self.phase = 6;
            },
            6 => {
                const a = wa orelse fail("A disappeared before approval");
                if (a.runtime.rootState(A).?.guards < 2) return;
                post(A, a, .approve);
                self.phase = 7;
            },
            7 => {
                const b = wb orelse fail("B disappeared before approval");
                if (b.runtime.rootState(B).?.guards == 0) return;
                check(wa != null, "quit destroyed A before B approval");
                post(B, b, .approve);
                self.phase = 8;
            },
            8 => {},
            else => unreachable,
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const self = try init.gpa.create(Smoke);
    self.* = .{ .gui = undefined, .io = init.io, .a = @fromBackingInt(0), .b = @fromBackingInt(0), .stale = @fromBackingInt(0) };
    try self.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    try self.worker.concurrent(init.io, Smoke.timer, .{self});
    self.gui.run();
}
