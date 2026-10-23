//! Native child geometry and retained upload pixels; no desktop compositor capture.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetWindowRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn SystemParametersInfoW(u32, u32, *u32, u32) callconv(.winapi) c_int;
extern "user32" fn GetParent(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn IsChild(Hwnd, Hwnd) callconv(.winapi) c_int;
extern "user32" fn IsWindow(Hwnd) callconv(.winapi) c_int;
extern "user32" fn SetFocus(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn GetFocus() callconv(.winapi) ?Hwnd;
extern "user32" fn GetDpiForWindow(Hwnd) callconv(.winapi) u32;
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-scrolling FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
fn rect(hwnd: Hwnd) Rect {
    var result: Rect = undefined;
    check(GetWindowRect(hwnd, &result) != 0, "HWND geometry available");
    return result;
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct { short: bool = false, outside: bool = false, removed: bool = false, enlarged: bool = false, text: [32]u8 = undefined, text_len: usize = 0 };
    pub const Msg = union(enum) { shrink, reparent, remove, quit, enlarge, rebuild, typed: []const u8 };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .enlarge => state.enlarged = true,
            .rebuild => {},
            .typed => |text| {
                state.text_len = @min(text.len, state.text.len);
                @memcpy(state.text[0..state.text_len], text[0..state.text_len]);
            },
            .shrink => state.short = true,
            .reparent => {
                state.outside = true;
                state.removed = true;
            },
            .remove => state.removed = true,
            .quit => try ctx.quit(),
        }
    }
    fn marker(ui: *app.Ui, state: *const State) !void {
        try app.widgets.textField(ui, "marker", .{ .text = state.text[0..state.text_len], .on_change = ui.messages(Root).handler(.typed), .sizing = .fixedXY(140, 32) });
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("root", .{ .layout = .{ .axis = .y, .padding = .all(20), .child_gap = 10, .sizing = .grow(.{}) } });
        defer ui.close();
        if (!state.removed) {
            try app.widgets.scrollView(ui, "outer", .{ .horizontal = true, .sizing = .fixedXY(240, if (state.enlarged) 240 else 180), .content = .{ .axis = .y, .padding = .all(8), .child_gap = 6 } });
            if (!state.outside) try marker(ui, state);
            if (!state.short) {
                try ui.open("blue", .{ .layout = .{ .sizing = .fixedXY(220, 80) }, .background_color = .rgb(0, 0, 255) });
                ui.close();
                try app.widgets.scrollView(ui, "inner", .{ .sizing = .fixedXY(200, 100) });
                try app.widgets.button(ui, "inner-button", .{ .label = "Nested", .sizing = .fixedXY(140, 30) });
                try ui.open("red", .{ .layout = .{ .sizing = .fixedXY(180, 300) }, .background_color = .rgb(255, 0, 0) });
                ui.close();
                ui.close();
                try ui.open("tail", .{ .layout = .{ .sizing = .fixedXY(700, 400) }, .background_color = .rgb(0, 255, 0) });
                ui.close();
            }
            ui.close();
        }
        if (state.outside) try marker(ui, state);
    }
};
const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    phase: u8 = 0,
    marker_handle: app.native.Handle = undefined,
    marker_hwnd: Hwnd = undefined,
    outer_hwnd: Hwnd = undefined,
    baseline: Rect = undefined,
    inner_baseline: Rect = undefined,
    moved: Rect = undefined,
    wheel_lines: u32 = 3,
    wheel_chars: u32 = 3,
    original_layer_count: usize = 0,
    fn scale(self: *Probe) f64 {
        return @as(f64, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
    }
    fn scroll(self: *Probe, key: []const u8) fabrum.Vec2 {
        return self.gui.runtime.reconciler().records.get(app.testing.rootInstance(Root).native(key)).?.scroll;
    }
    fn checkOuterOffset(self: *Probe) void {
        const current = rect(self.marker_hwnd);
        const offset = self.scroll("outer");
        check(@abs(@as(f64, offset.y) * self.scale() - @as(f64, @floatFromInt(self.baseline.top - current.top))) <= 1, "runtime retains actual vertical native offset");
        check(@abs(@as(f64, offset.x) * self.scale() - @as(f64, @floatFromInt(self.baseline.left - current.left))) <= 1, "runtime retains actual horizontal native offset");
    }
    fn checkEnd(self: *Probe) void {
        var client: Rect = undefined;
        check(GetClientRect(self.outer_hwnd, &client) != 0, "scroll viewport client geometry");
        const record = self.gui.runtime.reconciler().records.get(app.testing.rootInstance(Root).native("outer")).?;
        const expected = @max(0, @as(f64, record.content.?.y) - @as(f64, @floatFromInt(client.bottom)) / self.scale());
        check(@abs(@as(f64, record.scroll.y) - expected) <= 1 / self.scale(), "end clamps to content minus actual viewport");
        self.checkOuterOffset();
    }
    fn checkContainerPixels(self: *Probe, key: []const u8, anchor_key: []const u8, dy: f32, expected: [4]u8) void {
        const container_handle = self.handle(key).?;
        const anchor_id = app.testing.rootInstance(Root).native(anchor_key);
        const anchor = self.gui.runtime.reconciler().records.get(anchor_id).?;
        const document = GetParent(self.hwnd(anchor_key).?).?;
        const document_rect = rect(document);
        const local_x = @as(f64, anchor.frame.?.x + 16) * self.scale();
        const local_y = @as(f64, anchor.frame.?.y + dy) * self.scale();
        var matched = false;
        var found_container = false;
        for (self.gui.runtime.scene().containers) |container| {
            if (container.handle != container_handle) continue;
            found_container = true;
            for (container.slots) |slot| {
                if (slot != .canvas) continue;
                const canvas = self.gui.automation().canvasState(slot.canvas).?;
                check(GetParent(canvas.hwnd) == document, "canvas slot has its exact container document parent");
                const canvas_rect = rect(canvas.hwnd);
                check(canvas_rect.left - document_rect.left == canvas.origin_x and canvas_rect.top - document_rect.top == canvas.origin_y, "canvas origin expresses the visible document slice");
                const x = @as(i32, @intFromFloat(@round(local_x))) - canvas.origin_x;
                const y = @as(i32, @intFromFloat(@round(local_y))) - canvas.origin_y;
                if (x < 0 or y < 0 or x >= canvas.width or y >= canvas.height) return; // intentionally outside the visible slice
                const pixel = self.gui.automation().canvasPixel(slot.canvas, @intCast(x), @intCast(y)) orelse continue;
                matched = matched or std.mem.eql(u8, &pixel, &expected);
            }
        }
        check(found_container and matched, "expected color at exact container content coordinate");
    }
    fn checkPixels(self: *Probe) void {
        self.checkContainerPixels("outer", "marker", 58, .{ 255, 0, 0, 255 }); // blue after field + gap
        self.checkContainerPixels("inner", "inner-button", 50, .{ 0, 0, 255, 255 }); // red after nested button
        self.checkContainerPixels("outer", "inner", 126, .{ 0, 255, 0, 255 }); // green after nested viewport + gap
    }
    fn handle(self: *Probe, key: []const u8) ?app.native.Handle {
        return self.gui.handleOf(app.testing.rootInstance(Root).native(key));
    }
    fn hwnd(self: *Probe, key: []const u8) ?Hwnd {
        return platform.automation.widgetHwnd(self.handle(key) orelse return null);
    }
    fn post(self: *Probe, comptime tag: std.meta.Tag(Root.Msg)) void {
        self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, tag), {}) catch @panic("post");
    }
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        check(self.phase == 10, "termination before all scroll phases completed");
        self.done.store(true, .release);
        std.debug.print("native-win32-scrolling PASS (HWND geometry and upload pixels; no desktop capture)\n", .{});
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        switch (self.phase) {
            0 => {
                const outer = self.hwnd("outer") orelse return;
                const marker = self.hwnd("marker") orelse return;
                const inner_button = self.hwnd("inner-button") orelse return;
                const inner = self.hwnd("inner") orelse return;
                check(IsChild(outer, marker) != 0 and IsChild(inner, inner_button) != 0 and IsChild(outer, inner) != 0, "mixed nested controls belong to their scroll container");
                self.marker_handle = self.handle("marker").?;
                self.marker_hwnd = marker;
                self.outer_hwnd = outer;
                self.baseline = rect(marker);
                _ = SystemParametersInfoW(0x0068, 0, &self.wheel_lines, 0);
                _ = SystemParametersInfoW(0x006c, 0, &self.wheel_chars, 0);
                self.inner_baseline = rect(inner_button);
                const scene = self.gui.runtime.scene();
                self.original_layer_count = scene.layers.len;
                check(scene.containers.len == 2, "nested scene containers retained");
                var painted: usize = 0;
                var colors: u8 = 0;
                for (scene.layers, 0..) |layer, i| {
                    if (layer.offset.x == 0 and layer.offset.y == 0) continue;
                    if (self.gui.automation().canvasState(i)) |canvas| {
                        if (!canvas.presented) return;
                        check(IsChild(outer, canvas.hwnd) != 0, "container canvas HWND must be clipped by container ancestry");
                        if (self.gui.automation().canvasHasInk(i)) painted += 1;
                        var y: usize = 8;
                        while (y < canvas.height) : (y += 16) {
                            var x: usize = 8;
                            while (x < canvas.width) : (x += 16) {
                                const pixel = self.gui.automation().canvasPixel(i, x, y) orelse continue;
                                if (std.mem.eql(u8, &pixel, &.{ 255, 0, 0, 255 })) colors |= 1;
                                if (std.mem.eql(u8, &pixel, &.{ 0, 0, 255, 255 })) colors |= 2;
                                if (std.mem.eql(u8, &pixel, &.{ 0, 255, 0, 255 })) colors |= 4;
                            }
                        }
                    }
                }
                if (painted < 1) return;
                check(colors & 1 == 1, "visible outer upload pixels preserve blue content coordinates");
                self.checkPixels();
                platform.automation.typeText(self.marker_handle, "retained text");
                var typed_buffer: [64]u8 = undefined;
                check(std.mem.eql(u8, platform.automation.fieldText(self.marker_handle, &typed_buffer), "retained text"), "typing initial text");
                platform.automation.scrollTo(self.handle("outer").?, .init(0, 60));
                self.phase = 1;
            },
            1 => {
                self.checkPixels();
                self.checkOuterOffset();
                const now = rect(self.marker_hwnd);
                const dpi_scale = self.scale();
                check(@abs((self.baseline.top - now.top) - @as(i32, @intFromFloat(@round(60 * dpi_scale)))) <= 1, "programmatic scroll moves native child by logical offset");
                const nested = rect(self.hwnd("inner-button").?);
                check(nested.top - self.inner_baseline.top == now.top - self.baseline.top, "outer scrolling moves nested content by same offset");
                self.moved = nested;
                platform.automation.scrollTo(self.handle("inner").?, .init(0, 40));
                self.phase = 2;
            },
            2 => {
                self.checkPixels();
                check(@abs(self.moved.top - rect(self.hwnd("inner-button").?).top - @as(i32, @intFromFloat(@round(40 * self.scale())))) <= 1, "nested scrolling moves inner content exactly forty points");
                check(@abs(self.scroll("inner").y - 40) < 0.01, "runtime retains nested programmatic offset");
                check(rect(self.marker_hwnd).top == self.baseline.top - @as(i32, @intFromFloat(@round(60 * @as(f64, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96))), "nested scrolling preserves outer offset");
                self.moved = rect(self.marker_hwnd);
                self.inner_baseline = rect(self.hwnd("inner-button").?);
                const delta: u16 = @bitCast(@as(i16, -120));
                _ = SendMessageW(self.hwnd("inner").?, 0x020a, @as(usize, delta) << 16, 0);
                self.phase = 20;
            },
            20 => {
                check(if (self.wheel_lines == 0) rect(self.hwnd("inner-button").?).top == self.inner_baseline.top else rect(self.hwnd("inner-button").?).top < self.inner_baseline.top, "nested wheel respects system settings and scrolls its own content");
                check(@abs(@as(f64, self.scroll("inner").y - 40) * self.scale() - @as(f64, @floatFromInt(self.inner_baseline.top - rect(self.hwnd("inner-button").?).top))) <= 1, "runtime retains actual nested wheel offset");
                check(rect(self.marker_hwnd).top == self.moved.top, "nested wheel preserves outer offset");
                _ = SendMessageW(self.outer_hwnd, 0x0115, 1, 0); // WM_VSCROLL / SB_LINEDOWN
                self.phase = 3;
            },
            3 => {
                self.checkOuterOffset();
                check(rect(self.marker_hwnd).top < self.moved.top, "native scrollbar line down moves content");
                self.moved = rect(self.marker_hwnd);
                const delta: u16 = @bitCast(@as(i16, -120));
                _ = SendMessageW(self.marker_hwnd, 0x020a, @as(usize, delta) << 16, 0); // wheel over native child
                self.phase = 4;
            },
            4 => {
                self.checkOuterOffset();
                check(if (self.wheel_lines == 0) rect(self.marker_hwnd).top == self.moved.top else rect(self.marker_hwnd).top < self.moved.top, "wheel over native child respects system settings");
                self.moved = rect(self.marker_hwnd);
                _ = SendMessageW(self.marker_hwnd, 0x020e, @as(usize, 120) << 16, 0); // positive WM_MOUSEHWHEEL moves right
                self.phase = 21;
            },
            21 => {
                self.checkOuterOffset();
                check(if (self.wheel_chars == 0) rect(self.marker_hwnd).left == self.moved.left else rect(self.marker_hwnd).left < self.moved.left, "positive horizontal wheel respects system settings");
                // A large configured step may already have reached the end.
                // Start Shift-wheel independently from the left edge.
                platform.automation.scrollTo(self.handle("outer").?, .init(0, self.scroll("outer").y));
                self.moved = rect(self.marker_hwnd);
                const delta: u16 = @bitCast(@as(i16, -120));
                _ = SendMessageW(self.marker_hwnd, 0x020a, (@as(usize, delta) << 16) | 4, 0); // Shift + wheel down
                self.phase = 22;
            },
            22 => {
                self.checkOuterOffset();
                check(if (self.wheel_chars == 0) rect(self.marker_hwnd).left == self.moved.left else rect(self.marker_hwnd).left < self.moved.left, "Shift wheel down respects system horizontal settings");
                check(rect(self.marker_hwnd).top == self.moved.top, "Shift wheel preserves vertical offset");
                platform.automation.scrollTo(self.handle("outer").?, .init(0, 100000));
                self.gui.automation().resize(540, 360);
                self.phase = 5;
            },
            5 => {
                self.checkEnd();
                self.moved = rect(self.marker_hwnd);
                platform.automation.scrollTo(self.handle("outer").?, .init(0, 200000));
                self.post(.rebuild);
                self.phase = 23;
            },
            23 => {
                self.checkEnd();
                check(rect(self.marker_hwnd).top == self.moved.top, "further scrolling and unrelated rebuild preserve clamped end");
                self.post(.enlarge);
                self.phase = 24;
            },
            24 => {
                if (rect(self.outer_hwnd).bottom - rect(self.outer_hwnd).top < @as(i32, @intFromFloat(230 * self.scale()))) return;
                self.checkEnd();
                check(rect(self.marker_hwnd).top > self.moved.top, "growing actual viewport clamps scroll end upward");
                self.post(.shrink);
                self.phase = 6;
            },
            6 => {
                if (self.handle("inner") != null) return;
                check(@abs(rect(self.marker_hwnd).top - self.baseline.top) <= 1, "content shrink clamps offset back to zero");
                _ = SetFocus(self.marker_hwnd);
                check(GetFocus() == self.marker_hwnd, "native field accepts focus before reparent");
                self.post(.reparent);
                self.phase = 7;
            },
            7 => {
                if (IsChild(self.outer_hwnd, self.marker_hwnd) != 0) return;
                check(self.handle("marker").? == self.marker_handle, "reparent preserves native control handle");
                check(GetParent(self.marker_hwnd) == self.gui.hwnd(), "reparent restores host ownership");
                var buffer: [64]u8 = undefined;
                check(std.mem.eql(u8, platform.automation.fieldText(self.marker_handle, &buffer), "retained text"), "reparent preserves text state");
                check(GetFocus() == self.marker_hwnd, "reparent preserves keyboard focus while old container is removed");
                self.phase = 8;
            },
            8 => {
                if (self.handle("outer") != null) return;
                check(IsWindow(self.outer_hwnd) == 0, "removed container HWND destroyed");
                check(IsWindow(self.marker_hwnd) != 0, "reparented child survives container removal");
                check(self.gui.runtime.scene().containers.len == 0, "removed container leaves no scene slots");
                for (0..self.original_layer_count) |i| {
                    if (self.gui.automation().canvasState(i)) |canvas| {
                        check(IsWindow(canvas.hwnd) != 0 and IsChild(self.gui.hwnd(), canvas.hwnd) != 0, "pooled canvas HWND survives under live host ancestry");
                        if (i >= self.gui.runtime.scene().layers.len) check(!canvas.visible, "unused container canvas is hidden after teardown");
                    }
                }
                self.phase = 9;
            },
            9 => {
                self.phase = 10;
                self.post(.quit);
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
        check(false, "timed out waiting for scrolling phases");
    }
};
pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 scrolling regression", .width = 400, .height = 300 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
