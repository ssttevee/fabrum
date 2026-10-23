//! Deterministic upload pixels plus HWND visibility/order/geometry. This does
//! not claim to capture the desktop compositor or other applications' windows.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
extern "user32" fn GetWindow(*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetClassNameW(*anyopaque, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn ShowWindow(*anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn IsIconic(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn IsWindowVisible(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
extern "user32" fn GetClientRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-rendering FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct { overlay: bool = true };
    pub const Msg = union(enum) { remove, quit };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .remove => state.overlay = false,
            .quit => try ctx.quit(),
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("base", .{ .layout = .{ .sizing = .grow(.{}) }, .background_color = .rgb(0, 0, 255) });
        defer ui.close();
        try app.widgets.button(ui, "native", .{ .label = "Native below overlay", .sizing = .fixedXY(160, 40) });
        if (state.overlay) {
            try ui.open("overlay", .{ .layout = .{ .sizing = .fixedXY(120, 80) }, .floating = .{ .mode = .root }, .background_color = .rgba(255, 0, 0, 128) });
            ui.close();
        }
    }
};
const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    phase: u8 = 0,
    original_width: usize = 0,
    restore_presentations: usize = 0,
    failure_attempts: usize = 0,
    observations: usize = 0,
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        check(self.phase == 12, "window terminated before rendering checks finished");
        self.done.store(true, .release);
        std.debug.print("native-win32-rendering PASS (upload pixels and HWND state; no desktop capture)\n", .{});
    }
    fn post(self: *Probe, comptime tag: std.meta.Tag(Root.Msg)) void {
        self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, tag), {}) catch @panic("post");
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        const auto = self.gui.automation();
        const base = auto.canvasState(0) orelse return;
        const over = auto.canvasState(1) orelse return;
        switch (self.phase) {
            0 => {
                if (!base.presented or !over.presented) return;
                check(base.visible and over.visible, "both layers must be visible");
                const scale: f64 = @as(f64, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
                const p: usize = @intFromFloat(20 * scale);
                const rgba = auto.canvasPixel(1, p, p) orelse return;
                check(rgba[0] == 0 and rgba[1] == 0 and rgba[2] >= 127 and rgba[2] <= 129 and rgba[3] >= 127 and rgba[3] <= 129, "overlay must retain premultiplied half-alpha red");
                const clear = auto.canvasPixel(1, @intFromFloat(200 * scale), p) orelse return;
                check(std.mem.eql(u8, &clear, &.{ 0, 0, 0, 0 }), "overlay outside shape must stay transparent");
                const blue = auto.canvasPixel(0, p, p) orelse return;
                check(std.mem.eql(u8, &blue, &.{ 255, 0, 0, 255 }), "drawn base must stay opaque blue");
                const native_hwnd = GetWindow(over.hwnd, 2) orelse @panic("native sibling missing"); // GW_HWNDNEXT
                var class: [64]u16 = undefined;
                const n = GetClassNameW(native_hwnd, &class, class.len);
                check(n == 6 and std.mem.eql(u16, class[0..6], &.{ 'B', 'u', 't', 't', 'o', 'n' }), "overlay must be above native button");
                check(GetWindow(native_hwnd, 2) == base.hwnd, "native button must be above base canvas");
                check(IsWindowVisible(native_hwnd) != 0, "native button must be visible");
                var native_rect: Rect = undefined;
                var overlay_rect: Rect = undefined;
                check(GetWindowRect(native_hwnd, &native_rect) != 0 and GetWindowRect(over.hwnd, &overlay_rect) != 0, "child geometry");
                check(native_rect.left < overlay_rect.left + @as(i32, @intFromFloat(120 * scale)) and native_rect.right > overlay_rect.left and native_rect.top < overlay_rect.top + @as(i32, @intFromFloat(80 * scale)) and native_rect.bottom > overlay_rect.top, "alpha shape must overlap the native button");
                self.original_width = over.width;
                auto.resize(600, 400);
                self.phase = 1;
            },
            1 => {
                if (!over.presented or over.width == self.original_width) return;
                var rect: Rect = undefined;
                check(GetClientRect(self.gui.hwnd(), &rect) != 0, "client geometry");
                check(over.width == @as(usize, @intCast(rect.right)) and over.height == @as(usize, @intCast(rect.bottom)), "resized upload must match client pixels");
                auto.injectCanvasDeviceLoss(1);
                self.phase = 2;
            },
            2 => {
                if (over.retry_attempts == 0) return;
                self.phase = 3;
            },
            3 => {
                if (!over.presented) return;
                check(over.retries == 0 and auto.canvasHasInk(1), "static scene must recover without another runtime frame");
                self.restore_presentations = over.presentations;
                _ = ShowWindow(self.gui.hwnd(), 6); // SW_MINIMIZE
                self.phase = 4;
            },
            4 => {
                check(IsIconic(self.gui.hwnd()) != 0, "window must minimize");
                _ = ShowWindow(self.gui.hwnd(), 9); // SW_RESTORE
                var rect: Rect = undefined;
                check(GetWindowRect(self.gui.hwnd(), &rect) != 0, "window geometry");
                const dpi = GetDpiForWindow(self.gui.hwnd());
                _ = SendMessageW(self.gui.hwnd(), 0x02e0, dpi | (dpi << 16), @bitCast(@intFromPtr(&rect))); // same-monitor DPI notification
                self.phase = 5;
            },
            5 => {
                if (!over.presented or over.presentations <= self.restore_presentations or IsIconic(self.gui.hwnd()) != 0) return;
                check(over.visible and auto.canvasHasInk(1), "restore/DPI notification must keep overlay painted");
                self.failure_attempts = over.paint_attempts;
                auto.failCanvasCreates(1, 100);
                auto.injectCanvasDeviceLoss(1);
                self.phase = 6;
            },
            6 => {
                if (over.paint_attempts < self.failure_attempts + 4) return;
                check(over.paint_attempts == self.failure_attempts + 4 and over.retries == 3 and !over.presented, "exactly three retries must follow device loss");
                self.failure_attempts = over.paint_attempts;
                self.observations = 0;
                self.phase = 7;
            },
            7 => {
                check(over.paint_attempts == self.failure_attempts, "exhausted retries must stop scheduling paints");
                self.observations += 1;
                if (self.observations < 20) return;
                auto.failCanvasCreates(1, 0);
                auto.repaintCanvas(1);
                self.phase = 8;
            },
            8 => {
                if (!over.presented) return;
                check(over.retries == 0, "independent invalidation must recover after retry exhaustion");
                auto.failCanvasCreates(1, 100);
                auto.injectCanvasDeviceLoss(1);
                self.phase = 9;
            },
            9 => {
                if (over.retries == 0) return;
                check(over.retries < 3, "overlay removal must occur before retry exhaustion");
                self.post(.remove);
                self.phase = 10;
            },
            10 => {
                if (over.visible) return;
                check(base.visible and auto.canvasHasInk(0), "removing overlay must preserve base");
                self.failure_attempts = over.paint_attempts;
                self.observations = 0;
                self.phase = 11;
            },
            11 => {
                check(!over.visible and over.paint_attempts == self.failure_attempts, "removed overlay must cancel pending retry and remain idle");
                self.observations += 1;
                if (self.observations < 20) return;
                self.post(.quit);
                self.phase = 12;
            },
            else => {},
        }
    }
    fn timer(self: *Probe) void {
        for (0..240) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            if (self.done.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        check(false, "timed out waiting for rendering phases");
    }
};
pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 rendering regression", .width = 400, .height = 240 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
