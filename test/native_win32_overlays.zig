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
extern "user32" fn GetFocus() callconv(.winapi) ?H;
extern "user32" fn SetForegroundWindow(H) callconv(.winapi) c_int;
extern "user32" fn SetWindowPos(H, ?H, i32, i32, i32, i32, u32) callconv(.winapi) c_int;
extern "user32" fn IsWindow(H) callconv(.winapi) c_int;
extern "user32" fn IsWindowVisible(H) callconv(.winapi) c_int;
extern "user32" fn WindowFromPoint(Point) callconv(.winapi) ?H;
extern "user32" fn GetAncestor(H, u32) callconv(.winapi) ?H;
extern "user32" fn GetDpiForWindow(H) callconv(.winapi) u32;
extern fn png_probe([*:0]const u16, u32, u32, *u32, *u32, *[4]u8) bool;
extern fn overlay_clicks() u32;
extern fn overlay_click_at(i32, i32) bool;
extern fn overlay_restore_cursor() void;
extern fn overlay_target_main(usize) void;
extern fn overlay_start_target(i32, i32) ?H;
extern fn overlay_stop_target() bool;
extern fn overlay_verify_timeout_cleanup(i32, i32) bool;
const capture_path = "win32-overlay-source-test.png";

fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-overlays FAIL: {s}\n", .{message});
        overlay_restore_cursor();
        _ = overlay_stop_target();
        std.process.exit(1);
    }
}
const Page = struct {
    pub const Props = struct { guard: bool = false };
    pub const State = struct { count: usize = 0, guards: usize = 0, clear: bool = false, remove_overlay: bool = false };
    pub const Msg = union(enum) { increment, clear, remove_overlay, restore, closing: app.platform.CloseReason };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .increment => state.count += 1,
            .clear => state.clear = true,
            .remove_overlay => state.remove_overlay = true,
            .restore => {
                state.clear = false;
                state.remove_overlay = false;
            },
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
        if (!state.remove_overlay) {
            try ui.open("over", .{ .layout = .{ .sizing = .fixedXY(32, 32) }, .floating = .{ .mode = .root }, .background_color = .rgba(0, 0, 255, 128) });
            ui.close();
        }
    }
};
const Normal = platform.App(Page);
const Overlay = platform.Window(Page, .{ .decorations = .none, .background = .transparent, .level = .floating, .activation = .never, .pointer = .passthrough, .shadow = .none, .placement = .positioned });
const Borderless = platform.Window(Page, .{ .decorations = .none });
const Never = platform.Window(Page, .{ .activation = .never });
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
    focus: ?H = null,
    phase: u8 = 0,
    turns: usize = 0,
    terminated: usize = 0,
    target: ?H = null,
    retry_attempts: usize = 0,
    uploads: usize = 0,
    live_uploads: usize = 0,
    original_width: usize = 0,
    original_height: usize = 0,
    fn options(self: *Probe, comptime W: type) W.InitOptions {
        return .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } };
    }
    fn terminatedWindow(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.terminated += 1;
        if (self.phase == 9 and self.gui.windows.count() == 0) {
            check(self.terminated == 4, "all windows terminate exactly once");
            std.Io.Dir.cwd().deleteFile(self.io, capture_path) catch {};
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
        _ = w;
        check(png_probe(wide, x, y, &width, &height, &color), "decode composed root PNG independently through WIC");
        return color;
    }
    fn edgePixel() [4]u8 {
        var width: u32 = 0;
        var height: u32 = 0;
        var color: [4]u8 = undefined;
        const wide = std.unicode.utf8ToUtf16LeStringLiteral(capture_path);
        check(png_probe(wide, 0, 0, &width, &height, &color) and width > 2 and height > 2, "resized PNG dimensions available");
        check(png_probe(wide, width - 2, height - 2, &width, &height, &color), "sample newly exposed resized edge in PNG coordinates");
        return color;
    }
    fn snapshot(w: *Overlay) void {
        w.automation().snapshot(capture_path, 1) catch @panic("snapshot composed root");
    }
    fn livePixel(w: *Overlay, x: usize, y: usize) [4]u8 {
        const root = w.automation().rootPixels() orelse @panic("root has no successfully uploaded pixels");
        const state = w.automation().rootCompositionState();
        check(state.presented and root.uploads == state.uploads and root.stride >= root.width * 4, "borrowed live pixels belong to successful root upload generation");
        const dpi = GetDpiForWindow(w.hwnd());
        const px = x * dpi / 96;
        const py = y * dpi / 96;
        check(px < root.width and py < root.height, "live sample fits physical root DIB");
        return root.pixels[py * root.stride + px * 4 ..][0..4].*;
    }
    fn liveClear(w: *Overlay, width: usize, height: usize) void {
        const root = w.automation().rootPixels() orelse @panic("clear root not uploaded");
        check(root.width == width and root.height == height and root.stride >= width * 4, "live root dimensions and stride reflect successful upload");
        for (0..height) |y| for (0..width) |x| {
            check(root.pixels[y * root.stride + x * 4 + 3] == 0, "every live root pixel clears, including previously painted pixels and resized edges");
        };
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        self.turns += 1;
        const normal = self.gui.get(Normal, self.normal) orelse @panic("normal disappeared");
        const maybe_overlay = self.gui.get(Overlay, self.overlay);
        if (self.phase < 8 or self.phase >= 10) {
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
                    const never_id = self.gui.open(Never, .{}, .{ .title = "Never activate native alert probe", .visible = false }, self.options(Never)) catch @panic("never probe");
                    const never = self.gui.get(Never, never_id).?;
                    if (never.backend.backend().create(200, &.{ .alert = .{ .title = "Must not open", .message = "No native modal activation", .buttons = &.{"OK"} } }, &.none, null)) |_| {
                        check(false, "never_activate accepted declarative native modal alert");
                    } else |err| check(err == error.NonactivatingNativeAlertUnsupported, "specific nonactivating native alert error");
                    check(IsWindowVisible(never.hwnd()) == 0, "rejected native alert leaves hidden owner hidden");
                    check(self.gui.close(never_id), "close never_activate probe");
                    for (0..8) |i| {
                        if (w.backend.backend().create(@intCast(100 + i), &.{ .label = .{ .text = "Unsupported native child" } }, &.none, null)) |_| {
                            check(false, "transparent host silently accepted native HWND control");
                        } else |err| check(err == error.TransparentNativeControlsUnsupported, "specific transparent/native rejection");
                    }
                    _ = SetForegroundWindow(normal.hwnd());
                    self.foreground = GetForegroundWindow();
                    self.focus = GetFocus();
                    check(self.foreground == normal.hwnd(), "foreground control established for nonactivation test");
                    check(self.gui.show(self.overlay), "show accepts live ID");
                    self.phase = 1;
                },
                1 => {
                    check(IsWindowVisible(w.hwnd()) != 0 and GetForegroundWindow() == self.foreground and GetFocus() == self.focus, "show preserves foreground and keyboard focus");
                    if (w.runtime.rootState(Page) == null) return;
                    post(w, .increment);
                    self.phase = 2;
                },
                2 => {
                    if (w.runtime.rootState(Page).?.count != 1) return;
                    snapshot(w);
                    const live_base = livePixel(w, 48, 48);
                    const live_over = livePixel(w, 16, 16);
                    check(livePixel(w, 100, 100)[3] == 0, "live uploaded root clear area retains alpha zero");
                    check(live_base[0] == 0 and live_base[1] == 0 and live_base[2] >= 126 and live_base[2] <= 130 and live_base[3] >= 126 and live_base[3] <= 130, "actual uploaded root stores premultiplied half-red");
                    check(live_over[0] >= 126 and live_over[0] <= 130 and live_over[1] == 0 and live_over[2] >= 62 and live_over[2] <= 66 and live_over[3] >= 190 and live_over[3] <= 194, "actual uploaded root composes overlapping canvases in premultiplied BGRA");
                    const live = w.automation().rootPixels().?;
                    self.live_uploads = live.uploads;
                    self.original_width = live.width;
                    self.original_height = live.height;
                    const empty = pixel(w, 100, 100);
                    const base = pixel(w, 48, 48);
                    const over = pixel(w, 16, 16);
                    check(empty[3] == 0, "whole root clear pixels retain zero alpha");
                    check(base[3] >= 126 and base[3] <= 130 and base[2] > 240, "single canvas retains half alpha and red channel");
                    check(over[3] >= 190 and over[3] <= 194 and over[0] >= 168 and over[0] <= 172 and over[1] == 0 and over[2] >= 83 and over[2] <= 87, "two translucent canvases encode straight BGRA approximately 170,0,85,192");
                    post(w, .remove_overlay);
                    self.phase = 10;
                    self.turns = 0;
                },
                10 => {
                    if (!w.runtime.rootState(Page).?.remove_overlay or self.turns < 4) return;
                    snapshot(w);
                    const removed = pixel(w, 16, 16);
                    check(removed[3] >= 126 and removed[3] <= 130 and removed[2] > 240 and removed[0] == 0, "removed floating canvas no longer contributes root pixels");
                    const live = livePixel(w, 16, 16);
                    check(live[0] == 0 and live[2] >= 126 and live[2] <= 130 and live[3] >= 126 and live[3] <= 130 and w.automation().rootCompositionState().uploads > self.live_uploads, "floating layer removal advances successful root upload and removes blue pixels");
                    self.live_uploads = w.automation().rootCompositionState().uploads;
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
                    check(GetForegroundWindow() == self.foreground and GetFocus() == self.focus, "present preserves foreground and keyboard focus");
                    var point: Point = .{ .x = 16, .y = 16 };
                    check(ClientToScreen(normal.hwnd(), &point) != 0, "normal client screen coordinates");
                    self.target = overlay_start_target(point.x - 16, point.y - 16) orelse @panic("cross-process target");
                    _ = SetForegroundWindow(self.target.?);
                    self.foreground = GetForegroundWindow();
                    check(self.foreground == self.target, "separate process owns foreground before click");
                    check(SetWindowPos(w.hwnd(), null, point.x - 16, point.y - 16, 0, 0, 0x15) != 0, "position overlay above foreground control");
                    const hit = WindowFromPoint(point) orelse @panic("hit test");
                    check(GetAncestor(hit, 2) == self.target, "whole layered window passes through to another process over painted pixels");
                    check(overlay_click_at(point.x, point.y), "send actual mouse input through overlay");
                    self.phase = 5;
                },
                5 => {
                    if (overlay_clicks() == 0) return;
                    overlay_restore_cursor();
                    check(GetForegroundWindow() == self.foreground, "actual click leaves overlay nonactive");
                    check(overlay_stop_target(), "cross-process input helper terminates and is reaped");
                    check(overlay_verify_timeout_cleanup(80, 80), "unresponsive input helper is killed by Job close and reaped after timeout");
                    post(w, .clear);
                    self.phase = 6;
                    self.turns = 0;
                },
                6 => {
                    if (!w.runtime.rootState(Page).?.clear or self.turns < 4) return;
                    liveClear(w, self.original_width, self.original_height);
                    check(w.automation().rootCompositionState().uploads > self.live_uploads, "populated to empty scene advances root upload without resize");
                    self.live_uploads = w.automation().rootCompositionState().uploads;
                    snapshot(w);
                    check(pixel(w, 16, 16)[3] == 0 and edgePixel()[3] == 0, "clear without resize removes old pixels from capture too");
                    check(SetWindowPos(w.hwnd(), null, 0, 0, 240, 180, 0x16) != 0, "resize already clear layered root without activation");
                    self.phase = 15;
                    self.turns = 0;
                },
                15 => {
                    if (self.turns < 4) return;
                    liveClear(w, 240, 180);
                    check(w.automation().rootCompositionState().uploads > self.live_uploads, "clear resize advances successful root upload");
                    snapshot(w);
                    check(edgePixel()[3] == 0, "resized clear edge remains transparent in PNG");
                    post(w, .restore);
                    self.phase = 16;
                    self.turns = 0;
                },
                16 => {
                    if (w.runtime.rootState(Page).?.clear or self.turns < 4) return;
                    check(livePixel(w, 16, 16)[0] >= 126, "restore populated layered composition before independent retry injection");
                    const before = w.automation().rootCompositionState();
                    check(before.presented, "root was presented before injecting independent upload failure");
                    self.retry_attempts = before.retry_attempts;
                    self.uploads = before.uploads;
                    w.automation().failRootCompositions(1);
                    check(!w.automation().rootCompositionState().presented and w.automation().rootPixels() == null, "root upload failure invalidates root presentation and pixel probe independently of healthy layers");
                    self.phase = 11;
                },
                11 => {
                    const state = w.automation().rootCompositionState();
                    if (!state.presented) return;
                    check(state.retry_attempts == self.retry_attempts + 1 and state.uploads > self.uploads and state.retries == 0, "single failed root upload recovers on independent timer without scene mutation");
                    check(livePixel(w, 16, 16)[0] >= 126 and w.automation().rootPixels().?.uploads == state.uploads, "timer recovery exposes actual newly uploaded populated root pixels");
                    self.retry_attempts = state.retry_attempts;
                    self.uploads = state.uploads;
                    w.automation().failRootCompositions(4);
                    self.phase = 12;
                    self.turns = 0;
                },
                12 => {
                    if (self.turns < 12) return;
                    const state = w.automation().rootCompositionState();
                    check(!state.presented and w.automation().rootPixels() == null and state.retries == 3 and state.retry_attempts == self.retry_attempts + 3 and state.uploads == self.uploads, "persistent root failure exhausts exactly three bounded retries without claiming presentation");
                    self.phase = 13;
                    self.turns = 0;
                },
                13 => {
                    if (self.turns < 6) {
                        // State changes force fresh runtime frames whose view
                        // and layer arrangement stay identical. These must not
                        // reset the exhausted root retry budget.
                        post(w, .increment);
                        return;
                    }
                    const state = w.automation().rootCompositionState();
                    check(!state.presented and state.retry_attempts == self.retry_attempts + 3 and state.uploads == self.uploads, "exhausted root timer stops retrying");
                    w.automation().armRootCompositionFailures(1);
                    post(w, .remove_overlay);
                    self.phase = 14;
                },
                14 => {
                    const state = w.automation().rootCompositionState();
                    if (!state.presented) return;
                    check(state.uploads > self.uploads and state.retries == 0 and state.retry_attempts == self.retry_attempts + 4, "fresh layer removal resets exhausted budget and recovers after one new transient failure");
                    const live = livePixel(w, 16, 16);
                    check(live[0] == 0 and live[2] >= 126 and live[2] <= 130 and live[3] >= 126 and live[3] <= 130, "recovered root contains actual composition after floating layer removal");
                    self.old_hwnd = w.hwnd();
                    check(self.gui.close(self.overlay), "guarded close enqueued");
                    self.phase = 7;
                },
                7 => {
                    if (w.runtime.rootState(Page).?.guards == 0) return;
                    check(w.runtime.rootState(Page).?.guards == 1 and self.terminated == 1, "first close guard veto keeps overlay alive");
                    check(self.gui.close(self.overlay), "second guarded close enqueued");
                    self.phase = 8;
                },
                else => unreachable,
            }
        } else if (self.phase == 8) {
            if (maybe_overlay != null) return;
            check(self.terminated == 2 and IsWindow(self.old_hwnd.?) == 0, "teardown callback exactly once after native HWND destruction");
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
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    if (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--overlay-input-target")) return error.InvalidTestArgument;
        overlay_target_main(try std.fmt.parseInt(usize, args.next() orelse return error.InvalidTestArgument, 10));
        return;
    }
    std.Io.Dir.cwd().deleteFile(init.io, capture_path) catch {};
    const self = try init.gpa.create(Probe);
    self.* = .{ .gui = undefined, .io = init.io, .normal = @fromBackingInt(0), .overlay = @fromBackingInt(0) };
    try self.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    self.normal = try self.gui.open(Normal, .{}, .{ .title = "Overlay input target", .width = 400, .height = 300 }, self.options(Normal));
    self.overlay = try self.gui.open(Overlay, .{ .guard = true }, .{ .title = "Hidden transparent overlay", .width = 180, .height = 140, .min_width = 1, .min_height = 1, .visible = false, .position = .{ .x = 80, .y = 80 } }, self.options(Overlay));
    try self.workers.concurrent(init.io, Probe.timer, .{self});
    self.gui.run();
}
