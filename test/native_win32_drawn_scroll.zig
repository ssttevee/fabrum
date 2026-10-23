//! Real canvas wheel dispatch across a drawn/native scrolling boundary.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Point = extern struct { x: i32, y: i32 };
extern "user32" fn GetWindowRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn ClientToScreen(Hwnd, *Point) callconv(.winapi) c_int;
extern "user32" fn WindowFromPoint(Point) callconv(.winapi) ?Hwnd;
extern "user32" fn GetDpiForWindow(Hwnd) callconv(.winapi) u32;
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn SystemParametersInfoW(u32, u32, *u32, u32) callconv(.winapi) c_int;
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-drawn-scroll FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct {};
    pub const Msg = union(enum) { quit };
    pub fn update(_: *State, _: Msg, ctx: *app.Update(@This())) !void {
        try ctx.quit();
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.open("root", .{ .layout = .{ .axis = .y, .padding = .all(20), .sizing = .grow(.{}) } });
        defer ui.close();
        try app.widgets.scrollView(ui, "native", .{ .sizing = .fixedXY(260, 200), .content = .{ .axis = .y } });
        defer ui.close();
        try ui.open("drawn", .{ .layout = .{ .axis = .y, .sizing = .fixedXY(220, 120) }, .scroll = .{ .y = true }, .background_color = .rgb(30, 70, 110) });
        try ui.open("paint", .{ .layout = .{ .sizing = .fixedXY(220, 600) }, .background_color = .rgb(90, 130, 170) });
        ui.close();
        ui.close();
        try ui.open("tail", .{ .layout = .{ .sizing = .fixedXY(220, 600) }, .background_color = .rgb(70, 110, 150) });
        ui.close();
    }
};
const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    phase: u8 = 0,
    canvas: Hwnd = undefined,
    point: Point = undefined,
    position: fabrum.Vec2 = undefined,
    lines: u32 = 0,
    fn drawn(self: *Probe) app.ScrollInfo {
        return self.gui.runtime.scrollInfo(app.testing.rootInstance(Root).element("drawn")).?;
    }
    fn ancestor(self: *Probe) f32 {
        return self.gui.runtime.reconciler().records.get(app.testing.rootInstance(Root).native("native")).?.scroll.y;
    }
    fn mouseResult(self: *Probe, delta: f32) app.MouseResult {
        const event: app.MouseEvent = .{ .position = self.position, .scroll_delta = .init(0, delta) };
        return self.gui.runtime.mouseResult(event) catch @panic("mouse result");
    }
    fn wheel(self: *Probe) void {
        const x: u16 = @bitCast(@as(i16, @intCast(self.point.x)));
        const y: u16 = @bitCast(@as(i16, @intCast(self.point.y)));
        const coordinates: u32 = @as(u32, x) | (@as(u32, y) << 16);
        const delta: u16 = @bitCast(@as(i16, -120));
        _ = SendMessageW(self.canvas, 0x020a, @as(usize, delta) << 16, @as(isize, @intCast(coordinates)));
    }
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        check(self.phase == 4, "termination before all phases completed");
        self.done.store(true, .release);
        std.debug.print("native-win32-drawn-scroll PASS (real canvas wheel, drawn priority, painted boundary bubbling; SPI lines={d})\n", .{self.lines});
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        switch (self.phase) {
            0 => {
                const handle = self.gui.handleOf(app.testing.rootInstance(Root).native("native")) orelse return;
                for (self.gui.runtime.scene().containers) |container| {
                    if (container.handle != handle) continue;
                    for (container.slots) |slot| {
                        if (slot != .canvas) continue;
                        const canvas = self.gui.automation().canvasState(slot.canvas) orelse continue;
                        if (!canvas.presented or !canvas.visible) continue;
                        const unit = self.gui.runtime.context().getUnitById(app.testing.rootInstance(Root).element("drawn")) orelse return;
                        self.position = app.testing.center(unit);
                        var host_point: Point = .{ .x = @intFromFloat(self.position.x * @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96), .y = @intFromFloat(self.position.y * @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96) };
                        check(ClientToScreen(self.gui.hwnd(), &host_point) != 0, "screen coordinate conversion");
                        var bounds: Rect = undefined;
                        check(GetWindowRect(canvas.hwnd, &bounds) != 0, "canvas bounds");
                        if (host_point.x < bounds.left or host_point.x >= bounds.right or host_point.y < bounds.top or host_point.y >= bounds.bottom) continue;
                        check(WindowFromPoint(host_point) == canvas.hwnd, "wheel point is visibly on canvas HWND");
                        self.canvas = canvas.hwnd;
                        self.point = host_point;
                        check(SystemParametersInfoW(0x0068, 0, &self.lines, 0) != 0, "read SPI wheel lines without changing settings");
                        check(self.drawn().offset.y == 0 and self.ancestor() == 0, "initial offsets");
                        self.wheel();
                        self.phase = 1;
                        return;
                    }
                }
            },
            1 => {
                check(self.drawn().offset.y > 0, "real wheel over canvas scrolls pure drawn content");
                check(self.ancestor() == 0, "drawn scroller consumes wheel before native ancestor");
                check(self.mouseResult(100000).scrolled, "deterministic injection reaches drawn limit");
                platform.App(Root).mouse(&self.gui, self.position.x, self.position.y, 0, 0, 0);
                self.phase = 2;
            },
            2 => {
                check(self.drawn().offset.y == self.drawn().max().y, "drawn scroller at lower boundary");
                const result = self.mouseResult(1);
                check(result.handled and !result.scrolled, "painted hover occupies pointer but absorbs no boundary scroll");
                check(self.ancestor() == 0, "runtime injection leaves native ancestor unchanged");
                self.wheel();
                self.phase = 3;
            },
            3 => {
                check(self.drawn().offset.y == self.drawn().max().y, "boundary wheel preserves drawn limit");
                check(if (self.lines == 0) self.ancestor() == 0 else self.ancestor() > 0, "unabsorbed painted canvas wheel bubbles to native ancestor respecting zero/page SPI");
                self.phase = 4;
                self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, .quit), {}) catch @panic("quit");
            },
            else => {},
        }
    }
    fn timer(self: *Probe) void {
        for (0..400) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            if (self.done.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        check(false, "timed out waiting for drawn scrolling phases");
    }
};
pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 drawn scroll regression", .width = 400, .height = 320 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
    check(probe.done.load(.acquire), "run returned without completion callback");
}
