//! Requires a coordinated desktop. Synthetic WM_IME_* coverage supplies strings
//! without an installed IME; it does not establish actual candidate selection UI.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
extern "user32" fn GetWindow(Hwnd, u32) callconv(.winapi) ?Hwnd;
extern "user32" fn GetClassNameW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn EnumThreadWindows(u32, *const fn (Hwnd, isize) callconv(.winapi) c_int, isize) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "user32" fn GetDlgItem(Hwnd, c_int) callconv(.winapi) ?Hwnd;
extern "user32" fn GetFocus() callconv(.winapi) ?Hwnd;
extern "user32" fn IsWindow(Hwnd) callconv(.winapi) c_int;
extern "user32" fn IsWindowEnabled(Hwnd) callconv(.winapi) c_int;
extern "user32" fn IsWindowVisible(Hwnd) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PostMessageW(Hwnd, u32, usize, isize) callconv(.winapi) c_int;
extern "user32" fn GetWindowLongW(Hwnd, c_int) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn SetWindowTextW(Hwnd, [*:0]const u16) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(Hwnd) callconv(.winapi) u32;
extern "user32" fn ClientToScreen(Hwnd, *Point) callconv(.winapi) c_int;
extern "imm32" fn ImmGetContext(Hwnd) callconv(.winapi) ?Hwnd;
extern "imm32" fn ImmReleaseContext(Hwnd, Hwnd) callconv(.winapi) c_int;
extern "imm32" fn ImmGetCandidateWindow(Hwnd, u32, *Candidate) callconv(.winapi) c_int;
const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Candidate = extern struct { index: u32, style: u32, point: Point, area: Rect };
const literal = std.unicode.utf8ToUtf16LeStringLiteral;
const Case = enum { selection, cancel, max_bytes, multiline, password, numeric, url, email, close_before, close_active, queue };
var probe: *Probe = undefined;
var replies: usize = 0;
fn check(ok: bool, why: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-text FAIL phase={d} step={d}: {s}\n", .{ probe.phase, probe.step, why });
        std.process.exit(1);
    }
}
const Root = struct {
    pub const Props = struct {};
    pub const State = struct {
        requests: usize = 0,
        replies: usize = 0,
        result: ?[]u8 = null,
        editor: app.TextEditor = .{},
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.result) |s| gpa.free(s);
            self.editor.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { request: Case, answer: ?[]const u8, input: app.TextInput, pasted: ?[]const u8, prepare, reset };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .request => |which| {
                state.requests += 1;
                if (which == .close_before) try ctx.close();
                var title = "Edit résumé 資料".*;
                var initial = "A😀日本Z".*;
                try ctx.systemText(.{ .title = &title, .initial = &initial, .max_len = if (which == .max_bytes) 4 else 0, .flags = .{
                    .multiline = which == .multiline,
                    .password = which == .password,
                    .numeric = which == .numeric,
                    .url = which == .url,
                    .email = which == .email,
                } }, ctx.handler(.answer));
                @memset(&title, 'X');
                @memset(&initial, 'x');
            },
            .answer => |value| {
                replies += 1;
                state.replies += 1;
                if (state.result) |old| ctx.gpa.free(old);
                state.result = if (value) |s| try ctx.gpa.dupe(u8, s) else null;
            },
            .prepare => {
                try state.editor.setText(ctx.gpa, "A😀e\u{301}Z");
                _ = try state.editor.apply(ctx.gpa, .{ .select = .{ .anchor = 8, .head = 1 } }, .{});
            },
            .reset => try state.editor.setText(ctx.gpa, "external"),
            .input => |input| {
                _ = try ctx.editText(&state.editor, input, .{ .single_line = true }, ctx.handler(.pasted));
            },
            .pasted => {},
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("root", .{ .layout = .{ .axis = .y, .padding = .all(20), .sizing = .grow(.{}) } });
        defer ui.close();
        try app.widgets.scrollView(ui, "scroll", .{ .sizing = .fixedXY(320, 180), .content = .{ .axis = .y } });
        defer ui.close();
        try ui.open(null, .{ .layout = .{ .sizing = .fixedXY(300, 80) } });
        ui.close();
        try app.drawn.textEditor(ui, "editor", &state.editor, .{ .single_line = true, .sizing = .fixedXY(270, 40), .on_input = ui.messages(Root).handler(.input) });
        try ui.open(null, .{ .layout = .{ .sizing = .fixedXY(300, 500) } });
        ui.close();
    }
};
const Search = struct { owner: Hwnd, found: ?Hwnd = null, count: usize = 0 };
fn search(hwnd: Hwnd, value: isize) callconv(.winapi) c_int {
    const s: *Search = @ptrFromInt(@as(usize, @bitCast(value)));
    if (GetWindow(hwnd, 4) != s.owner or IsWindowVisible(hwnd) == 0) return 1;
    var name: [128]u16 = undefined;
    const n = GetClassNameW(hwnd, &name, name.len);
    if (n != 17 or !std.mem.eql(u16, name[0..17], literal("FabrumTextRequest"))) return 1;
    s.found = hwnd;
    s.count += 1;
    return 1;
}
fn dialog(owner: Hwnd) ?Hwnd {
    var s: Search = .{ .owner = owner };
    _ = EnumThreadWindows(GetCurrentThreadId(), search, @bitCast(@intFromPtr(&s)));
    check(s.count <= 1, "one active text request per owner");
    return s.found;
}
fn textIs(hwnd: Hwnd, expected: []const u16) bool {
    var buffer: [256]u16 = undefined;
    const n = GetWindowTextW(hwnd, &buffer, buffer.len);
    return n >= 0 and std.mem.eql(u16, buffer[0..@intCast(n)], expected);
}
fn key(hwnd: Hwnd, vk: usize) void {
    check(PostMessageW(hwnd, 0x100, vk, 0) != 0, "post keydown");
    check(PostMessageW(hwnd, 0x101, vk, 0) != 0, "post keyup");
}
const Probe = struct {
    gui: platform.Application,
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    phase: usize = 0,
    step: usize = 0,
    quiet: usize = 0,
    a: app.WindowId = @fromBackingInt(0),
    b: app.WindowId = @fromBackingInt(0),
    before: usize = 0,
    owner_hwnd: ?Hwnd = null,
    placement_checked: bool = false,
    fn open(self: *Probe) app.WindowId {
        return self.gui.openWindow(Root, .{}, .{ .title = "Win32 text regression", .width = 440, .height = 280 }, .{ .watchdog_ms = null }) catch @panic("open");
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        if (self.a == @as(app.WindowId, @fromBackingInt(0))) {
            self.a = self.open();
            self.b = self.open();
            return;
        }
        const a = self.gui.window(Root, self.a);
        const b = self.gui.window(Root, self.b).?;
        const cases = std.enums.values(Case);
        if (self.phase < cases.len) {
            const which = cases[self.phase];
            switch (self.step) {
                0 => {
                    const window = a orelse {
                        self.a = self.open();
                        return;
                    };
                    _ = window.runtime.rootState(Root) orelse return;
                    self.before = replies;
                    self.owner_hwnd = window.hwnd();
                    self.step = 1;
                    window.runtime.post(app.testing.rootInstance(Root).handler(Root, .request), which) catch @panic("request");
                },
                1 => {
                    if (which == .close_before) {
                        if (a != null or IsWindow(self.owner_hwnd.?) != 0) return;
                        check(replies == self.before, "queued owner close disposes reply without update");
                        self.step = 4;
                        return;
                    }
                    const window = a orelse @panic("owner closed early");
                    const d = dialog(window.hwnd()) orelse return;
                    check(IsWindowEnabled(window.hwnd()) == 0, "text entry disables owner");
                    check(IsWindowEnabled(b.hwnd()) != 0, "unrelated owner stays enabled");
                    const edit = GetDlgItem(d, 100).?;
                    check(GetFocus() == edit, "native text field initially focused");
                    check(textIs(d, literal("Edit résumé 資料")), "borrowed caption copied");
                    check(textIs(edit, literal("A😀日本Z")), "borrowed Unicode initial text copied");
                    var start: u32 = 0;
                    var end: u32 = 0;
                    _ = SendMessageW(edit, 0xb0, @intFromPtr(&start), @bitCast(@intFromPtr(&end)));
                    check(start == 0 and end == 6, "initial selection uses UTF16 code units");
                    const style: u32 = @bitCast(GetWindowLongW(edit, -16));
                    check((style & 4 != 0) == (which == .multiline), "multiline native style");
                    check((style & 0x20 != 0) == (which == .password), "password native style");
                    check((style & 0x2000 != 0) == (which == .numeric), "numeric native style");
                    if (which == .close_active or which == .queue) {
                        self.step = 2;
                        b.runtime.post(app.testing.rootInstance(Root).handler(Root, .request), .selection) catch @panic("queue B");
                    } else if (which == .cancel) {
                        key(edit, 0x1b);
                        self.step = 3;
                    } else if (which == .max_bytes) {
                        check(SetWindowTextW(edit, literal("😀x")) != 0, "set UTF8 over byte limit");
                        _ = SendMessageW(d, 0x111, 1, 0);
                        check(dialog(window.hwnd()) != null and replies == self.before, "over-limit UTF8 result stays open without truncation");
                        _ = SetWindowTextW(edit, literal("😀"));
                        _ = SendMessageW(d, 0x111, 1, 0);
                        self.step = 3;
                    } else {
                        const result = if (which == .multiline) literal("日本\r\n😀") else literal("résumé😀");
                        _ = SetWindowTextW(edit, result);
                        _ = SendMessageW(d, 0x111, 1, 0);
                        self.step = 3;
                    }
                },
                2 => {
                    if (b.runtime.rootState(Root).?.requests == 0) return;
                    check(dialog(b.hwnd()) == null, "global active slot prevents unrelated request opening over text entry");
                    if (which == .close_active) {
                        check(self.gui.close(self.a), "close active owner");
                    } else {
                        _ = SendMessageW(dialog(a.?.hwnd()).?, 0x111, 2, 0);
                    }
                    self.step = 5;
                },
                3 => {
                    const window = a.?;
                    const state = window.runtime.rootState(Root).?;
                    if (replies == self.before) return;
                    check(replies == self.before + 1, "exactly one text callback");
                    if (which == .cancel) check(state.result == null, "Escape replies null") else {
                        const expected = if (which == .max_bytes) "😀" else if (which == .multiline) "日本\r\n😀" else "résumé😀";
                        check(state.result != null and std.mem.eql(u8, state.result.?, expected), "accepted native text round-trips UTF8");
                    }
                    check(IsWindowEnabled(window.hwnd()) != 0 and dialog(window.hwnd()) == null, "owner reenabled and dialog retired");
                    self.before = replies;
                    self.step = 4;
                },
                4 => {
                    check(replies == self.before, "no duplicate or late callback");
                    self.quiet += 1;
                    if (self.quiet < 3) return;
                    self.quiet = 0;
                    self.phase += 1;
                    self.step = 0;
                },
                5 => {
                    const d = dialog(b.hwnd()) orelse return;
                    if (which == .close_active) {
                        check(a == null and IsWindow(self.owner_hwnd.?) == 0, "closed active owner detached and native HWND retired");
                        check(replies == self.before, "active owner close disposes callback");
                    } else check(replies == self.before + 1, "first request answered before queued request starts");
                    _ = SetWindowTextW(GetDlgItem(d, 100).?, literal("queued"));
                    _ = SendMessageW(d, 0x111, 1, 0);
                    self.step = 6;
                },
                6 => {
                    const expected = self.before + @as(usize, if (which == .close_active) 1 else 2);
                    if (replies < expected) return;
                    check(replies == expected and std.mem.eql(u8, b.runtime.rootState(Root).?.result.?, "queued"), "queue resumes once with isolated reply");
                    self.before = replies;
                    self.step = 4;
                },
                else => unreachable,
            }
            return;
        }
        const window = a orelse {
            self.a = self.open();
            return;
        };
        const state = window.runtime.rootState(Root) orelse return;
        switch (self.step) {
            0 => {
                window.runtime.post(app.testing.rootInstance(Root).handler(Root, .prepare), {}) catch @panic("prepare");
                window.runtime.focusMove(.next);
                platform.automation.scrollTo(window.handleOf(app.testing.rootInstance(Root).native("scroll")).?, .init(0, 40));
                self.step = 1;
            },
            1 => {
                if (!std.mem.eql(u8, state.editor.text.items, "A😀e\u{301}Z")) return;
                const native_scroll = window.runtime.reconciler().records.get(app.testing.rootInstance(Root).native("scroll")).?.scroll.y;
                check(native_scroll == 40, "candidate placement tested with nonzero native document scroll");
                check(window.automation().composition("に😀", 2, false), "synthetic native composition message starts");
                check(state.editor.composing() and std.mem.eql(u8, state.editor.text.items, "A😀e\u{301}Z"), "preedit does not change committed model");
                self.step = 2;
            },
            2 => {
                const focus = window.runtime.focused().?;
                const geometry = window.runtime.core.textGeometry(focus.unit).?;
                check(std.mem.eql(u8, geometry.text, "Aに😀Z"), "drawn geometry displays selection replaced by marked text");
                check(state.editor.displayCaret() == 4, "UTF16 cursor inside surrogate maps to valid UTF8 grapheme boundary");
                const hwnd = GetFocus().?;
                if (ImmGetContext(hwnd)) |himc| {
                    defer _ = ImmReleaseContext(hwnd, himc);
                    var candidate: Candidate = undefined;
                    if (ImmGetCandidateWindow(himc, 0, &candidate) != 0) {
                        check(candidate.style == 0x80, "candidate excludes caret rectangle");
                        var actual = candidate.point;
                        _ = ClientToScreen(hwnd, &actual);
                        const unit = window.runtime.context().getUnitById(.fromInt(focus.unit)).?;
                        const pad = unit.data.container.layout.padding;
                        const scroll = window.runtime.core.scrolls.get(focus.unit).?.offset;
                        const caret = geometry.input_caret.?;
                        const scale = @as(f32, @floatFromInt(GetDpiForWindow(hwnd))) / 96;
                        var expected = Point{ .x = @intFromFloat((unit.bbox.x + pad.left - scroll.x + caret.x) * scale), .y = @intFromFloat((unit.bbox.y + pad.top - scroll.y + caret.y + caret.h) * scale) };
                        _ = ClientToScreen(window.hwnd(), &expected);
                        if (@abs(actual.x - expected.x) > 2 or @abs(actual.y - expected.y) > 2) std.debug.print("placement actual={d},{d} expected={d},{d} unit={any} caret={any} scroll={any}\n", .{ actual.x, actual.y, expected.x, expected.y, unit.bbox, caret, scroll });
                        check(@abs(actual.x - expected.x) <= 2 and @abs(actual.y - expected.y) <= 2, "candidate placement maps document coordinates through native scroll canvas");
                        self.placement_checked = true;
                    } else std.debug.print("native-win32-text COVERAGE UNAVAILABLE: ImmGetCandidateWindow failed; native candidate placement not validated\n", .{});
                } else std.debug.print("native-win32-text COVERAGE UNAVAILABLE: ImmGetContext returned null; native candidate placement not validated\n", .{});
                window.automation().cancelComposition();
                check(!state.editor.composing() and state.editor.selection.anchor == 8 and state.editor.selection.head == 1, "native cancel preserves original reverse selection");
                check(window.automation().composition("にほん", 3, false), "new marked session after cancellation");
                check(window.automation().composition("日本", 2, true), "synthetic composition commit");
                check(std.mem.eql(u8, state.editor.text.items, "A日本Z") and !state.editor.composing(), "one committed replacement without duplicate characters");
                check(window.automation().composition("仮", 1, false), "second composition");
                const field = window.runtime.context().getUnitById(.fromInt(focus.unit)).?;
                const point = app.testing.center(field);
                platform.App(Root).mouse(window, point.x, point.y, 1, 0, 0);
                platform.App(Root).mouse(window, point.x, point.y, 0, 0, 0);
                check(!state.editor.composing(), "same-editor pointer selection cancels editor preedit");
                check(window.automation().composition("LATE", 4, true), "dispatch late result after pointer selection");
                check(std.mem.eql(u8, state.editor.text.items, "A日本Z"), "cancelled native composition cannot commit at new pointer selection");
                check(window.automation().composition("仮", 1, false), "fresh composition after pointer cancellation");
                window.runtime.post(app.testing.rootInstance(Root).handler(Root, .reset), {}) catch @panic("reset");
                self.step = 3;
            },
            3 => {
                if (!std.mem.eql(u8, state.editor.text.items, "external")) return;
                check(!state.editor.composing(), "external text change cancels preedit");
                self.done.store(true, .release);
                self.gui.options.quit_on_last_window_closed = true;
                self.gui.quit();
                std.debug.print("native-win32-text PASS (11 text service cases, synthetic WM_IME messages; real installed IME behavior untested)\n", .{});
                std.debug.print("native-win32-text IMM placement coverage: {s}\n", .{if (self.placement_checked) "queried and asserted" else "UNAVAILABLE (not validated)"});
            },
            else => unreachable,
        }
    }
    fn timer(self: *Probe) void {
        for (0..1500) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            if (self.done.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        check(false, "timed out waiting for text phases");
    }
};
pub fn main(init: std.process.Init) !void {
    probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
