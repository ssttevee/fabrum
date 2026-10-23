//! Opt-in desktop coverage. PNG checks inspect the composed root source alpha;
//! they do not claim to measure desktop compositor output or DWM shadows.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const H = *anyopaque;
const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetWindowLongPtrW(H, c_int) callconv(.winapi) isize;
extern "user32" fn GetWindowRect(H, *Rect) callconv(.winapi) c_int;
extern "user32" fn ClientToScreen(H, *Point) callconv(.winapi) c_int;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?H;
extern "user32" fn SetForegroundWindow(H) callconv(.winapi) c_int;
extern "user32" fn SetWindowPos(H, ?H, i32, i32, i32, i32, u32) callconv(.winapi) c_int;
extern "user32" fn IsWindow(H) callconv(.winapi) c_int;
extern "user32" fn IsWindowVisible(H) callconv(.winapi) c_int;
extern "user32" fn WindowFromPoint(Point) callconv(.winapi) ?H;
extern "user32" fn GetAncestor(H, u32) callconv(.winapi) ?H;
extern "user32" fn GetDpiForWindow(H) callconv(.winapi) u32;
extern fn png_probe([*:0]const u16, u32, u32, *u32, *u32, *[4]u8) bool;
extern fn overlay_watch_clicks(H) bool;
extern fn overlay_clicks() u32;
extern fn overlay_click_at(i32, i32) bool;
extern fn overlay_restore_cursor() void;
const capture_path = "win32-overlay-source-test.png";

fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-overlays FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
const Page = struct {
    pub const Props = struct { guard: bool = false };
    pub const State = struct { count: usize = 0, guards: usize = 0, clear: bool = false };
    pub const Msg = union(enum) { increment, clear, closing: app.platform.CloseReason };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .increment => state.count += 1,
            .clear => state.clear = true,
            .closing => {
                state.guards += 1;
                if (state.guards == 1) try ctx.cancelClose() else try ctx.close();
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        if (props.guard) ui.guardClose(ui.messages(@This()).handler(.closing));
        if (state.clear) return;
        try ui.open("base", .{ .layout = .{ .sizing = .fixedXY(64, 64) }, .background_color = .rgba(255, 0, 0, 128) });
        ui.close();
        // Separate floating canvas: overlap must be source-over composed.
        try ui.open("over", .{ .layout = .{ .sizing = .fixedXY(32, 32) }, .floating = .{ .mode = .root }, .background_color = .rgba(0, 0, 255, 128) });
        ui.close();
    }
};
const Normal = platform.App(Page);
const Overlay = platform.Window(Page, .{ .decorations = .none, .background = .transparent, .level = .floating, .activation = .never, .pointer = .passthrough, .shadow = .none, .placement = .positioned });
const Borderless = platform.Window(Page, .{ .decorations = .none });
comptime {
    std.debug.assert(Normal == platform.Window(Page, .{}));
    std.debug.assert(Normal == platform.AppWith(Page, fabrum.render.Direct2D));
    std.debug.assert(Overlay == platform.WindowWith(Page, fabrum.render.Direct2D, Overlay.window_policy));
    std.debug.assert(Normal != Overlay and Overlay != Borderless);
}

const Probe = struct {
    gui: platform.Application,
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    normal: app.WindowId,
    overlay: app.WindowId,
    old_hwnd: ?H = null,
    foreground: ?H = null,
    phase: u8 = 0,
    turns: usize = 0,
    terminated: usize = 0,
    fn options(self: *Probe, comptime W: type) W.InitOptions {
        return .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } };
    }
    fn terminatedWindow(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.terminated += 1;
        if (self.phase == 9 and self.gui.windows.count() == 0) {
            check(self.terminated == 3, "all windows terminate exactly once");
            self.done.store(true, .release);
            std.debug.print("native-win32-overlays PASS (root source alpha, real mouse routing, native policy flags, lifecycle; DWM shadow appearance not measured)\n", .{});
        }
    }
    fn flag(w: anytype, expected: []const u8) void {
        var buffer: [1024]u8 = undefined;
        const description = w.automation().describeWindow(&buffer);
        if (std.mem.indexOf(u8, description, expected) == null) {
            std.debug.print("window flags: {s}; expected {s}\n", .{ description, expected });
            check(false, "describeWindow disagrees with requested native policy");
        }
    }
    fn post(w: *Overlay, comptime tag: std.meta.Tag(Page.Msg)) void {
        w.runtime.post(app.testing.rootInstance(Page).handler(Page, tag), {}) catch @panic("post");
    }
    fn pixel(w: *Overlay, x: u32, y: u32) [4]u8 {
        var width: u32 = 0;
        var height: u32 = 0;
        var color: [4]u8 = undefined;
        const wide = std.unicode.utf8ToUtf16LeStringLiteral(capture_path);
        const dpi = GetDpiForWindow(w.hwnd());
        check(png_probe(wide, x * dpi / 96, y * dpi / 96, &width, &height, &color), "decode composed root PNG independently through WIC");
        return color;
    }
    fn snapshot(w: *Overlay) void {
        w.automation().snapshot(capture_path, 1) catch @panic("snapshot composed root");
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        self.turns += 1;
        const normal = self.gui.get(Normal, self.normal) orelse @panic("normal disappeared");
        const maybe_overlay = self.gui.get(Overlay, self.overlay);
        if (self.phase < 8) {
            const w = maybe_overlay orelse @panic("overlay disappeared");
            check(self.gui.get(Normal, self.overlay) == null and self.gui.get(Overlay, self.normal) == null, "policy-aware typed lookup");
            check(self.gui.window(Page, self.overlay) == null, "legacy lookup rejects nondefault policy");
            switch (self.phase) {
                0 => {
                    check(IsWindowVisible(w.hwnd()) == 0, "creation stays hidden across event-loop turns");
                    if (self.turns < 4) return;
                    const frame = w.automation().windowFrame();
                    check(frame[0] == 80 and frame[1] == 80, "position and frame use physical outer-window pixels");
                    const ex: usize = @bitCast(GetWindowLongPtrW(w.hwnd(), -20));
                    check(ex & 0x08080028 == 0x08080028, "native NOACTIVATE/LAYERED/TRANSPARENT/TOPMOST bits");
                    const style: usize = @bitCast(GetWindowLongPtrW(w.hwnd(), -16));
                    check(style & 0x00c00000 == 0, "borderless removes native caption");
                    for ([_][]const u8{ "visible=0", "decorated=0", "transparent=1", "floating=1", "passthrough=1", "shadowless=1" }) |expected| flag(w, expected);
                    const count = self.gui.windows.count();
                    const records = self.gui.records.items.len;
                    if (self.gui.open(Overlay, .{}, .{ .title = "Missing position", .visible = false }, self.options(Overlay))) |_| {
                        check(false, "positioned policy accepted missing coordinates");
                    } else |err| check(err == error.InvalidWindowPosition, "specific invalid-position error");
                    check(self.gui.windows.count() == count and self.gui.records.items.len == records, "failed creation leaves registry unchanged");
                    for (0..8) |i| {
                        if (w.backend.backend().create(@intCast(100 + i), &.{ .label = .{ .text = "Unsupported native child" } }, &.none, null)) |_| {
                            check(false, "transparent host silently accepted native HWND control");
                        } else |err| check(err == error.TransparentNativeControlsUnsupported, "specific transparent/native rejection");
                    }
                    _ = SetForegroundWindow(normal.hwnd());
                    self.foreground = GetForegroundWindow();
                    check(self.foreground == normal.hwnd(), "foreground control established for nonactivation test");
                    check(self.gui.show(self.overlay), "show accepts live ID");
                    self.phase = 1;
                },
                1 => {
                    check(IsWindowVisible(w.hwnd()) != 0 and GetForegroundWindow() == self.foreground, "show does not activate overlay");
                    if (w.runtime.rootState(Page) == null) return;
                    post(w, .increment);
                    self.phase = 2;
                },
                2 => {
                    if (w.runtime.rootState(Page).?.count != 1) return;
                    snapshot(w);
                    const empty = pixel(w, 100, 100);
                    const base = pixel(w, 48, 48);
                    const over = pixel(w, 16, 16);
                    check(empty[3] == 0, "whole root clear pixels retain zero alpha");
                    check(base[3] >= 126 and base[3] <= 130 and base[2] > 240, "single canvas retains half alpha and red channel");
                    check(over[3] >= 190 and over[3] <= 194 and over[0] > over[2] and over[2] > 40, "two translucent canvases compose source-over into root alpha");
                    check(self.gui.hide(self.overlay), "hide accepts live ID");
                    self.phase = 3;
                },
                3 => {
                    check(IsWindowVisible(w.hwnd()) == 0 and w.runtime.rootState(Page).?.count == 1, "hide preserves mounted component state");
                    check(self.gui.present(self.overlay), "present hidden overlay");
                    self.phase = 4;
                },
                4 => {
                    check(IsWindowVisible(w.hwnd()) != 0 and w.runtime.rootState(Page).?.count == 1, "present restores visibility without remount");
                    check(GetForegroundWindow() == self.foreground, "present never activates");
                    var point: Point = .{ .x = 16, .y = 16 };
                    check(ClientToScreen(normal.hwnd(), &point) != 0, "normal client screen coordinates");
                    check(SetWindowPos(w.hwnd(), null, point.x - 16, point.y - 16, 0, 0, 0x15) != 0, "position overlay above foreground control");
                    check(overlay_watch_clicks(normal.hwnd()), "observe actual underlying WM_LBUTTONDOWN");
                    const hit = WindowFromPoint(point) orelse @panic("hit test");
                    check(GetAncestor(hit, 2) == normal.hwnd(), "whole layered window passes through over painted pixels");
                    check(overlay_click_at(point.x, point.y), "send actual mouse input through overlay");
                    self.phase = 5;
                },
                5 => {
                    if (overlay_clicks() == 0) return;
                    overlay_restore_cursor();
                    check(GetForegroundWindow() == self.foreground, "actual click leaves overlay nonactive");
                    post(w, .clear);
                    check(SetWindowPos(w.hwnd(), null, 0, 0, 240, 180, 0x16) != 0, "resize layered root without activation");
                    self.phase = 6;
                    self.turns = 0;
                },
                6 => {
                    if (!w.runtime.rootState(Page).?.clear or self.turns < 4) return;
                    snapshot(w);
                    check(pixel(w, 16, 16)[3] == 0 and pixel(w, 200, 140)[3] == 0, "clear plus resize removes stale root/layer pixels");
                    self.old_hwnd = w.hwnd();
                    check(self.gui.close(self.overlay), "guarded close enqueued");
                    self.phase = 7;
                },
                7 => {
                    if (w.runtime.rootState(Page).?.guards == 0) return;
                    check(w.runtime.rootState(Page).?.guards == 1 and self.terminated == 0, "first close guard veto keeps overlay alive");
                    check(self.gui.close(self.overlay), "second guarded close enqueued");
                    self.phase = 8;
                },
                else => unreachable,
            }
        } else if (self.phase == 8) {
            if (maybe_overlay != null) return;
            check(self.terminated == 1 and IsWindow(self.old_hwnd.?) == 0, "teardown callback exactly once after native HWND destruction");
            check(!self.gui.show(self.overlay) and !self.gui.hide(self.overlay) and !self.gui.close(self.overlay) and !self.gui.present(self.overlay), "stale IDs rejected by all lifecycle operations");
            const replacement = self.gui.open(Borderless, .{}, .{ .title = "Replacement", .visible = false }, self.options(Borderless)) catch @panic("replacement");
            check(replacement != self.overlay and self.gui.get(Borderless, self.overlay) == null, "replacement cannot revive stale ID");
            self.phase = 9;
            self.gui.quit();
        }
    }
    fn timer(self: *Probe) void {
        for (0..240) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            if (self.done.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        std.debug.print("native-win32-overlays FAIL: bounded timeout phase={d}\n", .{self.phase});
        std.process.exit(1);
    }
};
pub fn main(init: std.process.Init) !void {
    const self = try init.gpa.create(Probe);
    self.* = .{ .gui = undefined, .io = init.io, .normal = @fromBackingInt(0), .overlay = @fromBackingInt(0) };
    try self.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    self.normal = try self.gui.open(Normal, .{}, .{ .title = "Overlay input target", .width = 400, .height = 300 }, self.options(Normal));
    self.overlay = try self.gui.open(Overlay, .{ .guard = true }, .{ .title = "Hidden transparent overlay", .width = 180, .height = 140, .min_width = 1, .min_height = 1, .visible = false, .position = .{ .x = 80, .y = 80 } }, self.options(Overlay));
    try self.workers.concurrent(init.io, Probe.timer, .{self});
    self.gui.run();
}
