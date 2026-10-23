//! Desktop regression. Compile separately; running requires an interactive desktop.
//! GDI with each HWND's installed font is the measurement oracle. The DPI
//! notification below is same-monitor only, not a cross-monitor simulation.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Size = extern struct { x: i32, y: i32 };
const LogFont = extern struct {
    height: i32,
    width: i32,
    escapement: i32,
    orientation: i32,
    weight: i32,
    italic: u8,
    underline: u8,
    strikeout: u8,
    charset: u8,
    out_precision: u8,
    clip_precision: u8,
    quality: u8,
    pitch: u8,
    face: [32]u16,
};
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetDpiForWindow(Hwnd) callconv(.winapi) u32;
extern "user32" fn GetWindowRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetGuiResources(*anyopaque, u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "user32" fn GetWindowTextW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn GetParent(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn GetDC(Hwnd) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(Hwnd, *anyopaque) callconv(.winapi) c_int;
extern "user32" fn DrawTextW(*anyopaque, [*]const u16, c_int, *Rect, u32) callconv(.winapi) c_int;
extern "user32" fn GetFocus() callconv(.winapi) ?Hwnd;
extern "user32" fn SetFocus(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn IsWindow(Hwnd) callconv(.winapi) c_int;
extern "user32" fn OpenClipboard(?Hwnd) callconv(.winapi) c_int;
extern "user32" fn CloseClipboard() callconv(.winapi) c_int;
extern "user32" fn GetClipboardData(u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(*anyopaque) callconv(.winapi) c_int;
extern "gdi32" fn SelectObject(*anyopaque, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn GetObjectW(*anyopaque, c_int, *LogFont) callconv(.winapi) c_int;
extern "gdi32" fn GetTextColor(*anyopaque) callconv(.winapi) u32;

var diagnostic_phase: std.atomic.Value(u8) = .init(0);
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-metrics FAIL phase={d}: {s}\n", .{ diagnostic_phase.load(.acquire), message });
        std.process.exit(1);
    }
}
fn font(hwnd: Hwnd) *anyopaque {
    const value = SendMessageW(hwnd, 0x0031, 0, 0); // WM_GETFONT
    check(value != 0, "native HWND must have an installed font");
    return @ptrFromInt(@as(usize, @bitCast(value)));
}
fn fontHeight(hwnd: Hwnd) i32 {
    var lf: LogFont = undefined;
    check(GetObjectW(font(hwnd), @sizeOf(LogFont), &lf) == @sizeOf(LogFont), "installed HFONT is a live GDI font");
    return @intCast(@abs(lf.height));
}
fn textIs(hwnd: Hwnd, expected: []const u16) bool {
    var buffer: [512]u16 = undefined;
    const count = GetWindowTextW(hwnd, &buffer, buffer.len);
    return count >= 0 and std.mem.eql(u16, buffer[0..@intCast(count)], expected);
}
fn nativeText(hwnd: Hwnd, text: []const u8, width: ?f32) fabrum.Vec2 {
    return nativeTextMode(hwnd, text, width, width != null);
}
fn nativeTextMode(hwnd: Hwnd, text: []const u8, width: ?f32, wrap: bool) fabrum.Vec2 {
    var buffer: [512]u16 = undefined;
    const count = std.unicode.utf8ToUtf16Le(&buffer, text) catch @panic("test UTF8");
    const dc = GetDC(hwnd) orelse @panic("GetDC");
    defer _ = ReleaseDC(hwnd, dc);
    const old = SelectObject(dc, font(hwnd)) orelse @panic("SelectObject");
    defer _ = SelectObject(dc, old);
    var r: Rect = .{ .left = 0, .top = 0, .right = if (width) |v| @intFromFloat(v) else 0, .bottom = 0 };
    check(DrawTextW(dc, &buffer, @intCast(count), &r, 0x400 | 0x800 | @as(u32, if (wrap) (if (width != null) 0x10 else 0) else 0x20)) > 0, "DrawText native metric oracle"); // CALCRECT|NOPREFIX; wrap without width preserves explicit newlines
    return .init(@floatFromInt(r.right - r.left), @floatFromInt(r.bottom - r.top));
}
fn labelColor(hwnd: Hwnd) u32 {
    const dc = GetDC(hwnd) orelse @panic("label DC");
    defer _ = ReleaseDC(hwnd, dc);
    _ = SendMessageW(GetParent(hwnd).?, 0x0138, @intFromPtr(dc), @bitCast(@intFromPtr(hwnd))); // read-only Edit also uses WM_CTLCOLORSTATIC
    return GetTextColor(dc);
}
const sample = "AΩ😀Z";
const paragraph = "Wide WWW narrow iii Unicode Ω café words wrap across several lines";
const multiline = "First line\r\nSecond Ω line";
const selected_paragraph = sample ++ " " ++ paragraph;
fn ideal(hwnd: Hwnd) Size {
    var result: Size = .{ .x = 0, .y = 0 };
    check(SendMessageW(hwnd, 0x1601, 0, @bitCast(@intFromPtr(&result))) != 0 and result.x > 0 and result.y > 0, "BCM_GETIDEALSIZE supplies actual native button metrics");
    return result;
}
fn windowRect(hwnd: Hwnd) Rect {
    var result: Rect = undefined;
    check(GetWindowRect(hwnd, &result) != 0, "native window bounds");
    return result;
}
fn editLayout(hwnd: Hwnd, wraps: bool) void {
    check(SendMessageW(hwnd, 0x00d4, 0, 0) == 0, "label native left/right edit margins are zero"); // EM_GETMARGINS
    var formatting: Rect = undefined;
    _ = SendMessageW(hwnd, 0x00b2, 0, @bitCast(@intFromPtr(&formatting))); // EM_GETRECT
    var client: Rect = undefined;
    check(GetClientRect(hwnd, &client) != 0, "edit client bounds");
    check(formatting.left == 0 and formatting.right == client.right and formatting.top >= 0 and formatting.bottom <= client.bottom, "native formatting rectangle uses the measured label width");
    const lines = SendMessageW(hwnd, 0x00ba, 0, 0);
    check(if (wraps) lines > 1 else lines == 1, "native edit line count reflects wrap mode");
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct { scenario: u8 = 0 };
    pub const Msg = union(enum) { scenario: u8, quit };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .scenario => |n| state.scenario = n,
            .quit => try ctx.quit(),
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("root", .{ .layout = .{ .axis = .y, .child_gap = 4, .sizing = .grow(.{}) } });
        defer ui.close();
        try app.widgets.textField(ui, "anchor", .{ .text = "focus anchor", .sizing = .fixedXY(200, 30) });
        if (state.scenario == 4) return;
        try app.widgets.label(ui, "narrow", .{ .text = "iiiiiiii", .wrap = false, .sizing = .{} });
        try app.widgets.label(ui, "wide", .{ .text = "WWWWWWWW", .wrap = false, .sizing = .{} });
        try app.widgets.label(ui, "unicode", .{ .text = sample, .wrap = false, .sizing = .{} });
        try app.widgets.label(ui, "newline", .{ .text = multiline, .wrap = state.scenario != 6, .sizing = .{} });
        try app.widgets.label(ui, "newline-nowrap", .{ .text = multiline, .wrap = false, .sizing = .{} });
        try app.widgets.label(ui, "newline-constrained", .{ .text = multiline, .wrap = state.scenario != 6, .sizing = .{ .width = .fixed(40) } });
        try app.widgets.label(ui, "newline-nowrap-constrained", .{ .text = multiline, .wrap = false, .sizing = .{ .width = .fixed(40) } });
        try app.widgets.label(ui, "wrap", .{ .text = paragraph, .wrap = state.scenario != 6, .font_size = if (state.scenario == 6) null else if (state.scenario >= 1) 24 else 12, .sizing = .{ .width = .fixed(180) } });
        try app.widgets.label(ui, "select", .{ .text = if (state.scenario >= 5) selected_paragraph else if (state.scenario == 3) sample ++ " updated" else sample, .selectable = state.scenario >= 2 and state.scenario != 6, .secondary = state.scenario == 1 or state.scenario == 3, .font_size = if (state.scenario == 6) null else if (state.scenario >= 1) 24 else 12, .wrap = state.scenario == 8, .sizing = .fixedXY(280, 48) });
        try app.widgets.button(ui, "button-narrow", .{ .label = "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii" });
        try app.widgets.button(ui, "button-wide", .{ .label = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" });
        try app.widgets.radioGroup(ui, "radio-row", .{ .items = &.{ "Narrow iii", "Wide WWW", "Unicode Ω" }, .selected = 0, .horizontal = true });
        try app.widgets.radioGroup(ui, "radio-column", .{ .items = &.{ "Narrow iii", "Wide WWW", "Unicode Ω" }, .selected = 0 });
    }
};
const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    pending: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    phase: u8 = 0,
    label_handle: app.native.Handle = undefined,
    anchor: Hwnd = undefined,
    selected_hwnd: Hwnd = undefined,
    primary_color: u32 = 0,
    initial_wrap: f32 = 0,
    dpi_font_height: i32 = 0,
    default_font_height: i32 = 0,
    completed: bool = false,
    original_label_hwnd: Hwnd = undefined,
    gdi_baseline: u32 = 0,
    gdi_last: u32 = 0,
    stable_ticks: u8 = 0,
    cycles: u8 = 0,
    fn handle(self: *Probe, key: []const u8) ?app.native.Handle {
        return self.gui.handleOf(app.testing.rootInstance(Root).native(key));
    }
    fn hwnd(self: *Probe, key: []const u8) ?Hwnd {
        return platform.automation.widgetHwnd(self.handle(key) orelse return null);
    }
    fn post(self: *Probe, msg: Root.Msg) void {
        switch (msg) {
            inline else => |payload, tag| self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, tag), payload) catch @panic("post"),
        }
    }
    fn size(self: *Probe, key: []const u8, width: ?f32) fabrum.Vec2 {
        return self.gui.backend.backend().measure(self.handle(key).?, .{ .max_width = width });
    }
    fn metric(self: *Probe, key: []const u8, text: []const u8, width: ?f32) fabrum.Vec2 {
        const scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
        const expected = nativeText(self.hwnd(key).?, text, if (width) |v| v * scale else null);
        const actual = self.size(key, width);
        check(@abs(actual.x * scale - expected.x) <= 2 and @abs(actual.y * scale - expected.y) <= 2, "backend label size agrees with installed-font GDI metrics");
        if (width != null and std.mem.eql(u8, key, "wrap")) {
            var frame: Rect = undefined;
            check(GetWindowRect(self.hwnd(key).?, &frame) != 0, "laid-out label rectangle");
            check(@abs(@as(f32, @floatFromInt(frame.bottom - frame.top)) - expected.y) <= 2, "layout propagates wrapped native height to actual HWND");
        }
        return actual;
    }
    fn focused(self: *Probe, key: []const u8) bool {
        const entry = self.gui.runtime.focused() orelse return false;
        return entry.native == app.testing.rootInstance(Root).native(key);
    }
    fn checkSelection(self: *Probe) void {
        var start: u32 = 99;
        var end: u32 = 99;
        _ = SendMessageW(self.hwnd("select").?, 0x00b0, @intFromPtr(&start), @bitCast(@intFromPtr(&end))); // EM_GETSEL
        check(start == 1 and end == 4, "UTF16 selection survives style/rebuild");
    }
    fn composites(self: *Probe) void {
        const scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
        for ([_][]const u8{ "radio-row", "radio-column" }, 0..) |key, direction| {
            const group_handle = self.handle(key).?;
            const parent = self.hwnd(key).?;
            const parent_rect = windowRect(parent);
            var aggregate: Size = .{ .x = 0, .y = 0 };
            var previous: ?Rect = null;
            for (0..3) |i| {
                const part = platform.automation.widgetPartHwnd(group_handle, i) orelse @panic("radio part");
                const first = platform.automation.widgetPartHwnd(group_handle, 0).?;
                check(font(part) == font(first), "composite radio children borrow one shared live font");
                check(fontHeight(part) == fontHeight(self.anchor), "radio child uses current system control font");
                _ = fontHeight(part);
                const wanted = ideal(part);
                const frame = windowRect(part);
                check(frame.bottom - frame.top == wanted.y, "radio child height agrees with native ideal size");
                if (direction == 0) {
                    check(frame.right - frame.left == wanted.x and frame.top == parent_rect.top, "row child uses native width and common top");
                    if (previous) |p| check(frame.left == p.right, "radio row child geometry is contiguous");
                    aggregate.x += wanted.x;
                    aggregate.y = @max(aggregate.y, wanted.y);
                } else {
                    check(frame.left == parent_rect.left and frame.right == parent_rect.right, "column child fills native group width");
                    if (previous) |p| check(frame.top == p.bottom, "radio column child geometry is contiguous");
                    aggregate.x = @max(aggregate.x, wanted.x);
                    aggregate.y += wanted.y;
                }
                previous = frame;
            }
            const measured = self.size(key, null);
            check(@abs(measured.x * scale - @as(f32, @floatFromInt(aggregate.x))) <= 2 and @abs(measured.y * scale - @as(f32, @floatFromInt(aggregate.y))) <= 2, "radio aggregate fitting size agrees with native child ideal metrics");
        }
    }
    fn settledGdi(self: *Probe) ?u32 {
        const count = GetGuiResources(GetCurrentProcess(), 0);
        check(count > 0, "process GDI object count available");
        self.stable_ticks = if (count == self.gdi_last) self.stable_ticks + 1 else 0;
        self.gdi_last = count;
        return if (self.stable_ticks >= 3) count else null;
    }
    fn constrainedNewlines(self: *Probe, wraps: bool) void {
        const scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
        for ([_][]const u8{ "newline-constrained", "newline-nowrap-constrained" }, 0..) |key, i| {
            const word_wrap = wraps and i == 0;
            // Nonwrapping labels retain explicit newlines, so their oracle
            // omits both SINGLELINE and WORDBREAK even with finite constraints.
            const expected = nativeTextMode(self.hwnd(key).?, multiline, if (word_wrap) 40 * scale else null, true);
            const actual = self.size(key, 40);
            check(@abs(actual.x * scale - @min(40 * scale, expected.x)) <= 2 and @abs(actual.y * scale - expected.y) <= 2, "finite-width CRLF metrics agree with multiline GDI in both wrap modes");
            const lines = SendMessageW(self.hwnd(key).?, 0x00ba, 0, 0);
            check(if (word_wrap) lines > 2 else lines == 2, "finite-width native CRLF layout reflects word-wrap mode");
            const frame = windowRect(self.hwnd(key).?);
            check(@abs(@as(f32, @floatFromInt(frame.bottom - frame.top)) - expected.y) <= 2, "finite-width CRLF intrinsic height reaches actual HWND");
        }
    }
    fn terminate(ctx: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        check(self.phase == 19 and self.completed and self.cycles == 8, "all metric/lifecycle phases must complete before termination");
        check(IsWindow(self.anchor) == 0 and IsWindow(self.selected_hwnd) == 0, "teardown destroys surviving controls");
        check(!self.done.swap(true, .acq_rel), "termination exactly once");
        std.debug.print("native-win32-metrics PASS (8 font lifecycle cycles; same-monitor DPI only)\n", .{});
    }
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ctx.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        diagnostic_phase.store(self.phase, .release);
        const state = self.gui.runtime.rootState(Root) orelse return;
        switch (self.phase) {
            0 => {
                self.anchor = self.hwnd("anchor") orelse return;
                if (self.hwnd("select") == null) return;
                const narrow = self.metric("narrow", "iiiiiiii", null);
                const wide = self.metric("wide", "WWWWWWWW", null);
                check(wide.x > narrow.x, "equal-length glyph strings have different native widths");
                _ = self.metric("unicode", sample, null);
                self.default_font_height = fontHeight(self.hwnd("unicode").?);
                const one_line = self.metric("wrap", paragraph, null);
                const wrapped = self.metric("wrap", paragraph, 180);
                check(wrapped.y > one_line.y and wrapped.x <= 180, "constrained text wraps rather than clipping measured height");
                editLayout(self.hwnd("wrap").?, true);
                const newline_hwnd = self.hwnd("newline").?;
                const newline_expected = nativeTextMode(newline_hwnd, multiline, null, true);
                const newline_actual = self.size("newline", null);
                const newline_scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
                check(@abs(newline_actual.y * newline_scale - newline_expected.y) <= 2, "unconstrained wrapping label preserves explicit CRLF intrinsic height");
                check(SendMessageW(newline_hwnd, 0x00ba, 0, 0) == 2, "native EDIT lays out both explicit lines");
                const no_wrap = self.size("newline-nowrap", null);
                check(@abs(no_wrap.y * newline_scale - newline_expected.y) <= 2 and SendMessageW(self.hwnd("newline-nowrap").?, 0x00ba, 0, 0) == 2, "nonwrapping multiline label measures actual explicit lines");
                self.constrainedNewlines(true);
                self.initial_wrap = wrapped.y;
                const bn = self.size("button-narrow", null);
                const bw = self.size("button-wide", null);
                const en = nativeText(self.hwnd("button-narrow").?, "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii", null);
                const ew = nativeText(self.hwnd("button-wide").?, "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW", null);
                const scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
                check(@abs((bw.x - bn.x) * scale - (ew.x - en.x)) <= 3, "button size delta follows actual glyph widths with equal native padding");
                self.label_handle = self.handle("select").?;
                self.original_label_hwnd = self.hwnd("select").?;
                check(!self.gui.backend.backend().canFocus(self.label_handle), "ordinary label is absent from focus chain");
                self.primary_color = labelColor(self.hwnd("select").?);
                self.composites();
                for ([_][]const u8{ "button-narrow", "button-wide" }) |key| {
                    const expected = ideal(self.hwnd(key).?);
                    const measured = self.size(key, null);
                    check(@abs(measured.x * scale - @as(f32, @floatFromInt(expected.x))) <= 2 and @abs(measured.y * scale - @as(f32, @floatFromInt(expected.y))) <= 2, "button absolute width and height agree with native ideal metrics");
                }
                self.post(.{ .scenario = 1 });
                self.phase = 1;
            },
            1 => {
                if (state.scenario != 1) return;
                check(self.handle("select").? == self.label_handle, "style update preserves native handle");
                check(self.hwnd("select").? == self.original_label_hwnd, "font and secondary updates preserve original label HWND");
                const expected: i32 = @intCast((24 * GetDpiForWindow(self.gui.hwnd()) + 36) / 72);
                check(fontHeight(self.hwnd("select").?) == expected, "custom point size reaches actual HWND font at window DPI");
                check(labelColor(self.hwnd("select").?) != self.primary_color, "secondary update changes native text color");
                check(self.metric("wrap", paragraph, 180).y > self.initial_wrap, "larger font updates wrapped intrinsic size");
                self.post(.{ .scenario = 2 });
                self.phase = 2;
            },
            2 => {
                if (state.scenario != 2) return;
                check(self.handle("select").? == self.label_handle, "selectable transition preserves runtime native handle");
                check(self.hwnd("select").? == self.original_label_hwnd, "enabling selection preserves original label HWND");
                check(self.gui.backend.backend().canFocus(self.label_handle), "selectable label joins native focus chain");
                _ = SetFocus(self.hwnd("select").?);
                self.phase = 3;
            },
            3 => {
                const field = self.hwnd("select").?;
                if (GetFocus() != field or !self.focused("select")) return;
                check(textIs(field, std.unicode.utf8ToUtf16LeStringLiteral(sample)), "selectable transition preserves Unicode label text");
                _ = SendMessageW(field, 0x00b1, 1, 4); // select Ω and supplementary-plane emoji
                self.checkSelection();
                _ = SendMessageW(field, 0x0301, 0, 0); // WM_COPY
                if (OpenClipboard(self.gui.hwnd()) == 0) return; // clipboard may briefly be busy
                const data = GetClipboardData(13) orelse @panic("Unicode clipboard");
                const ptr: [*:0]const u16 = @ptrCast(@alignCast(GlobalLock(data) orelse @panic("clipboard lock")));
                const copied = std.mem.eql(u16, std.mem.span(ptr), std.unicode.utf8ToUtf16LeStringLiteral("Ω😀"));
                _ = GlobalUnlock(data);
                _ = CloseClipboard();
                check(copied, "copy returns selected Unicode characters, not bytes or whole label");
                _ = SendMessageW(field, 0x0102, 'x', 0); // WM_CHAR
                check(textIs(field, std.unicode.utf8ToUtf16LeStringLiteral(sample)), "typing cannot mutate read-only label");
                self.checkSelection();
                _ = SendMessageW(field, 0x0300, 0, 0); // WM_CUT
                check(textIs(field, std.unicode.utf8ToUtf16LeStringLiteral(sample)), "cut cannot mutate read-only label");
                self.checkSelection();
                _ = SendMessageW(field, 0x0302, 0, 0); // WM_PASTE
                check(textIs(field, std.unicode.utf8ToUtf16LeStringLiteral(sample)), "selectable label stays read-only under typing/cut/paste");
                self.checkSelection();
                self.selected_hwnd = field;
                self.post(.{ .scenario = 3 });
                self.phase = 4;
            },
            4 => {
                if (state.scenario != 3) return;
                check(self.handle("select").? == self.label_handle and self.hwnd("select").? == self.selected_hwnd, "selectable styling preserves handle and HWND");
                check(GetFocus() == self.selected_hwnd and self.focused("select"), "styling preserves native and runtime focus");
                self.checkSelection();
                check(textIs(self.selected_hwnd, std.unicode.utf8ToUtf16LeStringLiteral(sample ++ " updated")), "controlled text update reaches HWND without resetting selection");
                check(labelColor(self.selected_hwnd) != self.primary_color, "selectable label receives secondary styling");
                self.dpi_font_height = fontHeight(self.selected_hwnd);
                var r: Rect = undefined;
                check(GetWindowRect(self.gui.hwnd(), &r) != 0, "DPI suggested rectangle");
                const dpi = GetDpiForWindow(self.gui.hwnd());
                _ = SendMessageW(self.gui.hwnd(), 0x02e0, dpi | (dpi << 16), @bitCast(@intFromPtr(&r)));
                self.phase = 5;
            },
            5 => {
                check(fontHeight(self.hwnd("select").?) == self.dpi_font_height, "same-monitor DPI notification leaves point font scaled consistently");
                _ = self.metric("wrap", paragraph, 180);
                check(GetFocus() == self.hwnd("select").? and self.focused("select"), "DPI notification preserves native/runtime focus");
                self.checkSelection();
                self.post(.{ .scenario = 4 });
                self.phase = 6;
            },
            6 => {
                if (state.scenario != 4 or self.handle("select") != null) return;
                check(IsWindow(self.selected_hwnd) == 0, "removed selectable HWND is destroyed");
                check(!self.focused("select"), "removed label leaves no stale runtime focus");
                _ = SetFocus(self.anchor);
                self.post(.{ .scenario = 5 });
                self.phase = 7;
            },
            7 => {
                if (state.scenario != 5 or self.hwnd("select") == null) return;
                check(self.hwnd("anchor").? == self.anchor and GetFocus() == self.anchor and self.focused("anchor"), "rebuilding labels preserves unrelated control HWND and focus");
                self.selected_hwnd = self.hwnd("select").?;
                check(textIs(self.selected_hwnd, std.unicode.utf8ToUtf16LeStringLiteral(selected_paragraph)), "rebuilt selectable text initialized");
                _ = self.metric("unicode", sample, null);
                _ = self.metric("wrap", paragraph, 180);
                _ = SetFocus(self.selected_hwnd);
                self.phase = 8;
            },
            8 => {
                if (GetFocus() != self.selected_hwnd or !self.focused("select")) return;
                self.label_handle = self.handle("select").?;
                self.post(.{ .scenario = 6 });
                self.phase = 9;
            },
            9 => {
                if (state.scenario != 6) return;
                check(self.handle("select").? == self.label_handle and self.hwnd("select").? == self.selected_hwnd, "restoring plain styling preserves native identity");
                check(!self.gui.backend.backend().canFocus(self.label_handle) and !self.focused("select"), "removing selectability removes runtime focus eligibility");
                check(fontHeight(self.selected_hwnd) == self.default_font_height, "clearing custom font restores actual system control font");
                check(labelColor(self.selected_hwnd) == self.primary_color, "clearing secondary restores primary text color");
                // wrap=false must ignore the width constraint for line count;
                // the returned width may still be clipped to that constraint.
                const one_line = nativeText(self.hwnd("wrap").?, paragraph, null);
                const measured = self.size("wrap", 180);
                const scale = @as(f32, @floatFromInt(GetDpiForWindow(self.gui.hwnd()))) / 96;
                check(@abs(measured.y * scale - one_line.y) <= 2, "wrap update restores single-line native measurement");
                editLayout(self.hwnd("wrap").?, false);
                const newline_expected = nativeTextMode(self.hwnd("newline").?, multiline, null, true);
                const newline_actual = self.size("newline", null);
                check(@abs(newline_actual.y * scale - newline_expected.y) <= 2 and SendMessageW(self.hwnd("newline").?, 0x00ba, 0, 0) == 2, "disabling word wrap preserves explicit newline intrinsic and native lines");
                self.constrainedNewlines(false);
                self.post(.{ .scenario = 7 });
                self.phase = 10;
            },
            10 => {
                if (state.scenario != 7) return;
                _ = self.metric("wrap", paragraph, 180);
                editLayout(self.hwnd("wrap").?, true);
                self.constrainedNewlines(true);
                self.post(.{ .scenario = 4 });
                self.phase = 11;
            },
            11 => {
                if (state.scenario != 4 or self.handle("select") != null) return;
                self.gdi_baseline = self.settledGdi() orelse return;
                self.post(.{ .scenario = 5 });
                self.phase = 12;
            },
            12 => {
                if (state.scenario != 5 or self.hwnd("select") == null) return;
                self.composites();
                self.post(.{ .scenario = 0 });
                self.phase = 13;
            },
            13 => {
                if (state.scenario != 0) return;
                self.composites();
                const expected: i32 = @intCast((12 * GetDpiForWindow(self.gui.hwnd()) + 36) / 72);
                check(fontHeight(self.hwnd("select").?) == expected, "font replacement cycle installs smaller point font");
                self.post(.{ .scenario = 3 });
                self.phase = 14;
            },
            14 => {
                if (state.scenario != 3) return;
                // Rebuild every owned font, including composite borrowers,
                // at the current monitor DPI without claiming a monitor move.
                _ = SendMessageW(self.gui.hwnd(), 0x001a, 0, 0); // WM_SETTINGCHANGE
                self.composites();
                const expected: i32 = @intCast((24 * GetDpiForWindow(self.gui.hwnd()) + 36) / 72);
                check(fontHeight(self.hwnd("select").?) == expected, "font replacement and settings refresh install live larger point font");
                self.post(.{ .scenario = 4 });
                self.stable_ticks = 0;
                self.phase = 15;
            },
            15 => {
                if (state.scenario != 4 or self.handle("select") != null) return;
                const count = self.settledGdi() orelse return;
                check(count <= self.gdi_baseline, "repeated font replacement and removal returns to settled GDI baseline");
                self.cycles += 1;
                self.post(.{ .scenario = 5 });
                self.phase = if (self.cycles == 8) 16 else 12;
            },
            16 => {
                if (state.scenario != 5 or self.hwnd("select") == null) return;
                self.composites();
                self.selected_hwnd = self.hwnd("select").?;
                _ = SetFocus(self.selected_hwnd);
                self.phase = 17;
            },
            17 => {
                if (GetFocus() != self.selected_hwnd or !self.focused("select")) return;
                self.label_handle = self.handle("select").?;
                _ = SendMessageW(self.selected_hwnd, 0x00b1, 1, 4); // select Ω😀 before replacing the focused HWND
                self.checkSelection();
                self.post(.{ .scenario = 8 });
                self.phase = 18;
            },
            18, 19 => {
                const wraps = self.phase == 18;
                if (state.scenario != (if (wraps) @as(u8, 8) else 9)) return;
                const replacement = self.hwnd("select").?;
                check(replacement != self.selected_hwnd and IsWindow(self.selected_hwnd) == 0, "focused wrap transition replaces and destroys previous HWND");
                check(self.handle("select").? == self.label_handle, "focused wrap transition preserves widget handle");
                check(textIs(replacement, std.unicode.utf8ToUtf16LeStringLiteral(selected_paragraph)), "focused wrap transition preserves full Unicode text");
                self.checkSelection();
                check(GetFocus() == replacement and self.focused("select"), "focused wrap transition preserves native and runtime focus");
                editLayout(replacement, wraps);
                self.selected_hwnd = replacement;
                if (wraps) {
                    self.post(.{ .scenario = 9 });
                    self.phase = 19;
                    return;
                }
                self.completed = true;
                self.post(.quit);
            },
            else => {},
        }
    }
    fn timer(self: *Probe) void {
        for (0..1000) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            // Remain alive after termination to catch a hung native shutdown.
            if (!self.done.load(.acquire) and !self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        check(false, "bounded watchdog expired before process shutdown");
    }
};
pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 native metrics regression", .width = 680, .height = 640 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
