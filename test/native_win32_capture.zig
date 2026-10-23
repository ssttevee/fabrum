//! Client reconstruction + bounded visible slices. Requires the desktop slot.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
extern fn png_probe([*:0]const u16, u32, u32, *u32, *u32, *[4]u8) bool;
extern fn destroy_on_capture(*anyopaque, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) bool;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
extern "user32" fn GetParent(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(*anyopaque, *Rect) callconv(.winapi) c_int;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const path = "win32-client-capture-test.png";
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-capture FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct { revision: bool = false };
    pub const Msg = union(enum) { rebuild, change, far_change, quit };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .rebuild => {},
            .change => state.revision = true,
            .far_change => state.revision = false,
            .quit => try ctx.quit(),
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("base", .{ .layout = .{ .axis = .y, .sizing = .grow(.{}) }, .background_color = .rgb(0, 0, 255) });
        defer ui.close();
        try app.widgets.button(ui, "native", .{ .label = "Native content", .sizing = .fixedXY(160, 40) });
        try app.widgets.scrollView(ui, "outer", .{ .horizontal = true, .sizing = .fixedXY(240, 140), .content = .{ .axis = .y } });
        try app.widgets.scrollView(ui, "inner", .{ .sizing = .fixedXY(180, 80) });
        try ui.open("red", .{ .layout = .{ .sizing = .fixedXY(160, 200000) }, .background_color = .rgb(255, 0, 0) });
        ui.close();
        ui.close();
        try ui.open("huge", .{ .layout = .{ .sizing = .fixedXY(2000000, 2000000) }, .background_color = if (state.revision) .rgb(0, 255, 0) else .rgb(0, 0, 255) });
        ui.close();
        ui.close();
        try ui.open("overlay", .{ .layout = .{ .sizing = .fixedXY(120, 220) }, .floating = .{ .mode = .root }, .background_color = .rgba(255, 0, 0, 128) });
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
    destroyed: bool = false,
    layer: usize = 0,
    presentations: usize = 0,
    observations: usize = 0,
    fn handle(self: *Probe, key: []const u8) app.native.Handle {
        return self.gui.handleOf(app.testing.rootInstance(Root).native(key)).?;
    }
    fn post(self: *Probe, comptime tag: std.meta.Tag(Root.Msg)) void {
        self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, tag), {}) catch @panic("post");
    }
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        if (self.destroyed) return;
        check(self.phase == 5, "completed all capture phases");
        self.done.store(true, .release);
        std.debug.print("native-win32-capture PASS (client reconstruction; no desktop capture)\n", .{});
    }
    fn destroyDuringCapture(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.destroyed = true;
        self.gui.deinit();
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        const auto = self.gui.automation();
        for (self.gui.runtime.scene().layers, 0..) |_, i| {
            const canvas = auto.canvasState(i) orelse return;
            if (canvas.visible and !canvas.presented) return;
        }
        const scale = @as(f64, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
        switch (self.phase) {
            0 => {
                var buffer: [128]u8 = undefined;
                check(std.mem.startsWith(u8, auto.describeHit(20, 20, &buffer), "canvas layer"), "upper canvas wins hit over native control");
                check(std.mem.startsWith(u8, auto.describeHit(140, 20, &buffer), "button "), "uncovered native control wins hit");
                check(std.mem.eql(u8, auto.describeHit(-5, -5, &buffer), "nothing"), "outside client hits nothing");
                const outer = self.handle("outer");
                for (self.gui.runtime.scene().containers) |container| if (container.handle == outer) {
                    for (container.slots) |slot| if (slot == .canvas) {
                        self.layer = slot.canvas;
                        break;
                    };
                };
                const canvas = auto.canvasState(self.layer).?;
                check(@as(f64, @floatFromInt(canvas.width)) <= 240 * scale and @as(f64, @floatFromInt(canvas.height)) <= 140 * scale, "two-million-point document allocates at most viewport-sized DIB");
                auto.snapshot(path, null) catch @panic("snapshot failed");
                var width: u32 = 0;
                var height: u32 = 0;
                var pixel: [4]u8 = undefined;
                check(png_probe(std.unicode.utf8ToUtf16LeStringLiteral(path), @intFromFloat(140 * scale), @intFromFloat(20 * scale), &width, &height, &pixel), "PNG decodes");
                check(pixel[3] == 255 and pixel[1] > 0, "snapshot includes native button pixels where base canvas is pure blue");
                var client: Rect = undefined;
                _ = GetClientRect(self.gui.hwnd(), &client);
                check(width == client.right and height == client.bottom, "default snapshot dimensions are physical client pixels");
                // Below the scroll viewport is blue root beneath red alpha.
                check(png_probe(std.unicode.utf8ToUtf16LeStringLiteral(path), @intFromFloat(10 * scale), @intFromFloat(200 * scale), &width, &height, &pixel), "overlay PNG pixel decodes");
                check(@abs(@as(i32, pixel[0]) - 127) <= 2 and pixel[1] == 0 and @abs(@as(i32, pixel[2]) - 128) <= 2 and pixel[3] == 255, "PNG composites red alpha over blue in native/canvas order");
                auto.snapshot(path, 2) catch @panic("scaled snapshot failed");
                check(png_probe(std.unicode.utf8ToUtf16LeStringLiteral(path), 0, 0, &width, &height, &pixel), "scaled PNG decodes");
                check(width == @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(client.right)) * 2 / scale))) and height == @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(client.bottom)) * 2 / scale))), "explicit snapshot scale is pixels per point");
                check(if (auto.snapshot(path, -1)) |_| false else |_| true, "invalid scale fails honestly");
                check(if (auto.snapshot("missing-capture-directory/output.png", null)) |_| false else |_| true, "PNG path failure is reported");
                platform.automation.scrollTo(outer, .init(10000, 20));
                self.phase = 1;
            },
            1 => {
                const canvas = auto.canvasState(self.layer).?;
                check(@as(f64, @floatFromInt(canvas.origin_x)) > 9000 * scale and @as(f64, @floatFromInt(canvas.origin_y)) >= 19 * scale, "visible slice follows nonzero horizontal and vertical offsets");
                const blue = auto.canvasPixel(self.layer, 10, canvas.height - 10).?;
                check(std.mem.eql(u8, &blue, &.{ 255, 0, 0, 255 }), "translated huge canvas preserves blue content pixels");
                self.presentations = canvas.presentations;
                self.post(.rebuild);
                self.phase = 2;
            },
            2 => {
                const canvas = auto.canvasState(self.layer).?;
                check(canvas.presentations == self.presentations, "unchanged scene does not redraw visible slice");
                self.observations += 1;
                if (self.observations < 5) return;
                self.post(.change);
                self.phase = 3;
            },
            3 => {
                const canvas = auto.canvasState(self.layer).?;
                if (canvas.presentations == self.presentations) return;
                const green = auto.canvasPixel(self.layer, 10, canvas.height - 10).?;
                check(std.mem.eql(u8, &green, &.{ 0, 255, 0, 255 }), "content change redraws the translated visible slice");
                auto.injectCanvasDeviceLoss(self.layer);
                auto.repaintCanvas(self.layer);
                self.phase = 4;
            },
            4 => {
                const canvas = auto.canvasState(self.layer).?;
                if (!canvas.presented or canvas.retry_attempts == 0) return;
                check(auto.canvasHasInk(self.layer), "bounded target recovers after injected loss");
                platform.automation.scrollTo(self.handle("outer"), .init(1500000, 100000));
                self.phase = 6;
            },
            6 => {
                const canvas = auto.canvasState(self.layer).?;
                check(canvas.origin_x > 1048576, "far-document slice is beyond finite damage history");
                self.presentations = canvas.presentations;
                self.post(.far_change);
                self.phase = 7;
            },
            7 => {
                const canvas = auto.canvasState(self.layer).?;
                if (canvas.presentations <= self.presentations) return;
                const blue = auto.canvasPixel(self.layer, 10, 10).?;
                check(std.mem.eql(u8, &blue, &.{ 255, 0, 0, 255 }), "far-document redraw fallback presents changed content beyond damage extent");
                const button = platform.automation.widgetHwnd(self.handle("native")).?;
                check(destroy_on_capture(button, destroyDuringCapture, self), "install native print reentry probe");
                check(if (auto.snapshot(path, null)) |_| false else |_| true, "destroying owner during native print returns SnapshotFailed");
                check(self.destroyed, "native print reentry actually destroyed app and HWND owner");
                self.done.store(true, .release);
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                std.debug.print("native-win32-capture PASS (client reconstruction and print reentry; no desktop capture)\n", .{});
                std.process.exit(0);
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
        check(false, "timed out waiting for capture phases");
    }
};
pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 capture regression", .width = 400, .height = 300 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
    std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
}
