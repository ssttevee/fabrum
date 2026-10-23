const std = @import("std");
const abi = @import("../win32.zig");
const c = @import("win32_c");
const a = std.heap.page_allocator;
extern fn fabrum_d2d_target_create(?*anyopaque) ?*anyopaque;
extern fn fabrum_d2d_target_destroy(*anyopaque) void;
extern fn fabrum_d2d_target_resize(*anyopaque, u32, u32) bool;
extern fn fabrum_d2d_target_begin(*anyopaque) bool;
extern fn fabrum_d2d_target_end(*anyopaque) bool;
extern fn fabrum_d2d_target_recoverable(*anyopaque) bool;
extern fn fabrum_d2d_image_data(*anyopaque) ?[*]const u8;
extern fn fabrum_d2d_test_fail_end(*anyopaque, bool) void;
extern fn fabrum_d2d_test_fail_creates(*anyopaque, c_uint) void;
const frame_message = c.WM_APP + 1;
const task_message = c.WM_APP + 2;
const paint_message = c.WM_APP + 3;
/// The UI thread owns every HWND and object. Only frame requests and the
/// dispatcher queue are shared with workers; their synchronization is explicit.
const Window = struct {
    hwnd: c.HWND = null,
    host: abi.CHost,
    options: abi.COptions,
    layers: std.ArrayList(*Layer) = .empty,
    controls: std.ArrayList(*Control) = .empty,
    pending: std.atomic.Value(bool) = .init(false),
    closed: bool = false,
    // Native calls can synchronously send focus notifications while the runtime
    // is delivering an update. Queue them until the outer host callback returns.
    busy: bool = false,
    frame_again: bool = false,
    events: std.ArrayList(QueuedEvent) = .empty,
    buttons: c_uint = 0,
};
const Layer = struct {
    window: *Window,
    hwnd: c.HWND = null,
    index: c_uint,
    target: ?*anyopaque = null,
    paint_pending: bool = false,
    paint_width: usize = 0,
    paint_height: usize = 0,
    presented: bool = false,
    active: bool = false,
    retry_count: u8 = 0,
    retry_attempts: usize = 0,
    presentations: usize = 0,
    paint_attempts: usize = 0,
};
const Control = struct {
    window: *Window,
    hwnd: c.HWND = null,
    kind: abi.Kind,
    id: u64,
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 1,
    value: f64 = 0,
    writing: bool = false,
    composing: bool = false,
};
const Task = struct { call: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque };
var dispatcher: c.HWND = null;
var windows: std.ArrayList(*Window) = .empty;
var tasks: std.ArrayList(Task) = .empty;
const Mutex = struct {
    value: c.SRWLOCK = std.mem.zeroes(c.SRWLOCK),
    fn lock(self: *Mutex) void {
        c.AcquireSRWLockExclusive(&self.value);
    }
    fn unlock(self: *Mutex) void {
        c.ReleaseSRWLockExclusive(&self.value);
    }
};
var task_lock: Mutex = .{};
var registered = false;
fn w(p: *anyopaque) *Window {
    return @ptrCast(@alignCast(p));
}
fn control(p: *anyopaque) *Control {
    return @ptrCast(@alignCast(p));
}
fn wide(s: []const u8) [:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch @panic("invalid UTF-8 or out of memory");
}
fn str(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}
fn int(v: f64) c_int {
    return @intFromFloat(std.math.clamp(v, -2147483647, 2147483647));
}
fn send(h: c.HWND, msg: c.UINT, wp: usize, lp: isize) isize {
    return c.SendMessageW(h, msg, wp, lp);
}
fn emit(o: *Control, kind: abi.EventKind, value: f64) void {
    if (!o.writing) deliverEvent(o.window, o.id, kind, value, null);
}
fn textEvent(o: *Control) void {
    const n = c.GetWindowTextLengthW(o.hwnd);
    const b = a.allocSentinel(u16, @intCast(@max(n, 0)), 0) catch return;
    defer a.free(b);
    _ = c.GetWindowTextW(o.hwnd, b.ptr, @intCast(b.len + 1));
    const utf = std.unicode.utf16LeToUtf8Alloc(a, b) catch return;
    defer a.free(utf);
    deliverEvent(o.window, o.id, .text, 0, utf);
}
pub fn initialize() error{NativeCreateFailed}!void {
    if (registered) return;
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = str("FabrumWindow");
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    wc.hbrBackground = c.GetSysColorBrush(c.COLOR_WINDOW);
    _ = c.RegisterClassExW(&wc);
    wc.lpfnWndProc = layerProc;
    wc.lpszClassName = str("FabrumCanvas");
    wc.hbrBackground = null;
    _ = c.RegisterClassExW(&wc);
    wc.lpfnWndProc = dispatchProc;
    wc.lpszClassName = str("FabrumDispatcher");
    _ = c.RegisterClassExW(&wc);
    dispatcher = c.CreateWindowExW(0, str("FabrumDispatcher"), str(""), 0, 0, 0, 0, 0, null, null, c.GetModuleHandleW(null), null);
    if (dispatcher == null) return error.NativeCreateFailed;
    var ic = c.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(c.INITCOMMONCONTROLSEX), .dwICC = c.ICC_WIN95_CLASSES | c.ICC_PROGRESS_CLASS };
    _ = c.InitCommonControlsEx(&ic);
    registered = true;
}
fn dispatchProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (msg == task_message) {
        while (true) {
            task_lock.lock();
            const task = if (tasks.items.len > 0) tasks.orderedRemove(0) else null;
            task_lock.unlock();
            if (task) |t| t.call(t.ctx) else break;
        }
        return 0;
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn object(hwnd: c.HWND, comptime T: type) ?*T {
    const n = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    return if (n == 0) null else @ptrFromInt(@as(usize, @bitCast(n)));
}
fn windowProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = object(hwnd, Window) orelse return c.DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        frame_message => {
            self.pending.store(false, .release);
            if (self.busy) {
                self.frame_again = true;
                return 0;
            }
            if (!self.closed) {
                self.busy = true;
                defer {
                    self.busy = false;
                    flushEvents(self);
                    if (self.frame_again) {
                        self.frame_again = false;
                        request_frame(self);
                    }
                }
                var r: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &r);
                // Minimized windows have a zero viewport. Keep the last scene
                // until restore requests a frame with drawable dimensions.
                if (c.IsIconic(hwnd) != 0 or r.right <= 0 or r.bottom <= 0) return 0;
                const scale = dpi(hwnd);
                self.host.frame(self.host.ctx, @as(f64, @floatFromInt(r.right)) / scale, @as(f64, @floatFromInt(r.bottom)) / scale);
            }
            return 0;
        },
        c.WM_TIMER => {
            _ = c.KillTimer(hwnd, 1);
            request_frame(self);
            return 0;
        },
        c.WM_DPICHANGED => {
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            request_frame(self);
            return 0;
        },
        c.WM_SIZE => {
            if (wp == c.SIZE_MINIMIZED) for (self.layers.items) |l| {
                _ = c.KillTimer(l.hwnd, 1);
            };
            request_frame(self);
            return 0;
        },
        c.WM_CLOSE => {
            if (self.host.should_close(self.host.ctx, 0)) {
                const host = self.host;
                host.will_terminate(host.ctx);
                c.PostQuitMessage(0);
            }
            return 0;
        },
        c.WM_GETMINMAXINFO => {
            const mm: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            mm.ptMinTrackSize.x = int(self.options.min_width * dpi(hwnd));
            mm.ptMinTrackSize.y = int(self.options.min_height * dpi(hwnd));
            return 0;
        },
        c.WM_COMMAND => {
            const child: c.HWND = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (child != null) if (object(child, Control)) |o| {
                const code = (wp >> 16) & 0xffff;
                if (code == c.BN_CLICKED) {
                    switch (o.kind) {
                        .checkbox, .@"switch" => emit(o, .toggle, if (send(child, c.BM_GETCHECK, 0, 0) == c.BST_CHECKED) 1 else 0),
                        else => emit(o, .activate, 0),
                    }
                } else if (code == c.EN_CHANGE) {
                    if (!o.writing and !o.composing) textEvent(o);
                } else if (code == c.CBN_SELCHANGE) emit(o, .select, @floatFromInt(send(child, c.CB_GETCURSEL, 0, 0)));
            };
            return 0;
        },
        c.WM_HSCROLL, c.WM_VSCROLL => {
            const child: c.HWND = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (child != null) if (object(child, Control)) |o| {
                const n: f64 = @floatFromInt(send(child, c.TBM_GETPOS, 0, 0));
                emit(o, .number, o.min + n / 10000 * (o.max - o.min));
            };
            return 0;
        },
        c.WM_CHAR, c.WM_SYSCHAR => return 0,
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            if (keyEvent(self, msg, wp, lp)) return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn dpi(hwnd: c.HWND) f64 {
    return @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
}
fn signedWord(v: usize) f64 {
    return @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(v)))));
}
fn layerProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const l = object(hwnd, Layer) orelse return c.DefWindowProcW(hwnd, msg, wp, lp);
    const self = l.window;
    switch (msg) {
        c.WM_TIMER => {
            _ = c.KillTimer(hwnd, 1);
            if (l.active and c.IsIconic(self.hwnd) == 0) schedulePaint(l);
            return 0;
        },
        c.WM_CAPTURECHANGED, c.WM_CANCELMODE => {
            if (self.buttons != 0) {
                self.buttons = 0;
                self.host.cancel_pointer(self.host.ctx);
            }
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT, paint_message => {
            l.paint_pending = false;
            var ps: c.PAINTSTRUCT = undefined;
            const painting = msg == c.WM_PAINT;
            if (painting) _ = c.BeginPaint(hwnd, &ps);
            defer if (painting) {
                _ = c.EndPaint(hwnd, &ps);
            };
            if (!l.active or c.IsIconic(self.hwnd) != 0) return 0;
            l.paint_attempts += 1;
            l.presented = false;
            defer {
                if (l.presented) {
                    l.retry_count = 0;
                    _ = c.KillTimer(hwnd, 1);
                } else if ((if (l.target) |target| fabrum_d2d_target_recoverable(target) else true) and l.retry_count < 3) {
                    l.retry_count += 1;
                    l.retry_attempts += 1;
                    _ = c.SetTimer(hwnd, 1, 50 * @as(c.UINT, l.retry_count), null);
                }
            }
            var r: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &r);
            if (r.right > 0 and r.bottom > 0) {
                if (l.target == null) l.target = fabrum_d2d_target_create(hwnd);
                if (l.target) |target| {
                    if (!fabrum_d2d_target_resize(target, @intCast(r.right), @intCast(r.bottom))) {
                        std.log.err("win32: canvas resize failed", .{});
                        return 0;
                    }
                    if (fabrum_d2d_target_begin(target)) {
                        self.host.draw_layer(self.host.ctx, l.index, @ptrCast(target), @as(f64, @floatFromInt(r.right)) / dpi(hwnd), @as(f64, @floatFromInt(r.bottom)) / dpi(hwnd));
                        l.presented = fabrum_d2d_target_end(target);
                        if (!l.presented) std.log.err("win32: canvas presentation failed (Win32 error {d})", .{c.GetLastError()}) else {
                            l.presentations += 1;
                            l.paint_width = @intCast(r.right);
                            l.paint_height = @intCast(r.bottom);
                        }
                    } else std.log.err("win32: canvas begin failed", .{});
                } else std.log.err("win32: canvas target creation failed", .{});
            }
            return 0;
        },
        c.WM_NCHITTEST => {
            var pt = c.POINT{ .x = @intFromFloat(signedWord(@bitCast(lp))), .y = @intFromFloat(signedWord(@as(usize, @bitCast(lp)) >> 16)) };
            _ = c.ScreenToClient(hwnd, &pt);
            if (!self.host.hit_layer(self.host.ctx, l.index, @as(f64, @floatFromInt(pt.x)) / dpi(hwnd), @as(f64, @floatFromInt(pt.y)) / dpi(hwnd))) return c.HTTRANSPARENT;
            return c.HTCLIENT;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_MOUSEMOVE, c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            var pt = c.POINT{ .x = @intFromFloat(signedWord(@bitCast(lp))), .y = @intFromFloat(signedWord(@as(usize, @bitCast(lp)) >> 16)) };
            if (msg == c.WM_MOUSEWHEEL or msg == c.WM_MOUSEHWHEEL) _ = c.ScreenToClient(hwnd, &pt);
            if (msg == c.WM_LBUTTONDOWN) {
                self.buttons = 1;
                _ = c.SetCapture(hwnd);
                _ = c.SetFocus(hwnd);
            }
            if (msg == c.WM_LBUTTONUP) {
                self.buttons = 0;
                _ = c.ReleaseCapture();
            }
            const wheel = signedWord(wp >> 16) / 120;
            self.busy = true;
            defer {
                self.busy = false;
                flushEvents(self);
            }
            self.host.mouse(self.host.ctx, @intCast(l.index), @as(f64, @floatFromInt(pt.x)) / dpi(hwnd), @as(f64, @floatFromInt(pt.y)) / dpi(hwnd), self.buttons, if (msg == c.WM_MOUSEHWHEEL) wheel else 0, if (msg == c.WM_MOUSEWHEEL) -wheel else 0);
            return 0;
        },
        c.WM_CHAR, c.WM_SYSCHAR => return 0,
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => return windowProc(self.hwnd, msg, wp, lp),
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn request_frame(self: *Window) void {
    if (!self.pending.swap(true, .acq_rel)) {
        _ = c.PostMessageW(self.hwnd, frame_message, 0, 0);
    }
}
pub fn fabrum_win32_window_create(options: abi.COptions, host: abi.CHost) !*anyopaque {
    try initialize();
    const self = try a.create(Window);
    errdefer a.destroy(self);
    self.* = .{ .host = host, .options = options };
    const title = try std.unicode.utf8ToUtf16LeAllocZ(a, std.mem.span(options.title));
    defer a.free(title);
    var rect = c.RECT{ .left = 0, .top = 0, .right = int(options.width), .bottom = int(options.height) };
    _ = c.AdjustWindowRectEx(&rect, c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN, 0, 0);
    self.hwnd = c.CreateWindowExW(0, str("FabrumWindow"), title.ptr, c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN, c.CW_USEDEFAULT, c.CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, null, null, c.GetModuleHandleW(null), null);
    if (self.hwnd == null) return error.NativeCreateFailed;
    errdefer _ = c.DestroyWindow(self.hwnd);
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    try windows.append(a, self);
    return self;
}
pub fn fabrum_win32_window_release(p: *anyopaque) void {
    const self = w(p);
    for (self.layers.items) |l| {
        _ = c.KillTimer(l.hwnd, 1);
        if (l.target) |t| fabrum_d2d_target_destroy(t);
        a.destroy(l);
    }
    self.layers.deinit(a);
    self.controls.deinit(a);
    for (self.events.items) |e| if (e.text) |text| a.free(text);
    self.events.deinit(a);
    for (windows.items, 0..) |other, i| if (other == self) {
        _ = windows.swapRemove(i);
        break;
    };
    a.destroy(self);
}
pub fn fabrum_win32_present(p: *anyopaque) void {
    _ = c.ShowWindow(w(p).hwnd, c.SW_SHOW);
    request_frame(w(p));
}
pub fn fabrum_win32_run() noreturn {
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        var handled = false;
        for (dialogs.items) |d| {
            if (c.IsDialogMessageW(d.hwnd, &msg) != 0) {
                handled = true;
                break;
            }
        }
        if (handled) continue;
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
    std.process.exit(@intCast(msg.wParam));
}
pub fn fabrum_win32_request_frame(p: *anyopaque) void {
    request_frame(w(p));
}
pub fn fabrum_win32_run_on_main(callback: *const fn (?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
    task_lock.lock();
    tasks.append(a, .{ .call = callback, .ctx = ctx }) catch @panic("out of memory");
    task_lock.unlock();
    _ = c.PostMessageW(dispatcher, task_message, 0, 0);
}
pub fn fabrum_win32_cancel_main(ctx: *anyopaque) void {
    task_lock.lock();
    defer task_lock.unlock();
    var i: usize = 0;
    while (i < tasks.items.len) {
        if (tasks.items[i].ctx == ctx) _ = tasks.orderedRemove(i) else i += 1;
    }
}
pub fn fabrum_win32_quit() void {
    for (windows.items) |self| {
        if (self.host.should_close(self.host.ctx, 1)) {
            const host = self.host;
            host.will_terminate(host.ctx);
            c.PostQuitMessage(0);
            return;
        }
    }
}
pub fn fabrum_win32_quit_now() void {
    c.PostQuitMessage(0);
}
pub fn fabrum_win32_close_now(p: *anyopaque) void {
    const self = w(p);
    if (self.closed) return;
    self.closed = true;
    var i: usize = 0;
    while (i < dialogs.items.len) {
        if (dialogs.items[i].window == self) finishDialog(dialogs.items[i], -1) else i += 1;
    }
    _ = c.DestroyWindow(self.hwnd);
    self.hwnd = null;
}
pub fn fabrum_win32_create(p: *anyopaque, kind: abi.Kind, id: u64) ?*anyopaque {
    const self = w(p);
    const o = a.create(Control) catch return null;
    o.* = .{ .window = self, .kind = kind, .id = id };
    const class: [*:0]const u16 = switch (kind) {
        .button, .checkbox, .@"switch" => str("BUTTON"),
        .text_field, .text_area, .search_field, .secure_field => str("EDIT"),
        .label => str("STATIC"),
        .slider => str("msctls_trackbar32"),
        .progress, .spinner => str("msctls_progress32"),
        .dropdown => str("COMBOBOX"),
        else => {
            a.destroy(o);
            return null;
        },
    };
    const style: c.DWORD = @bitCast(@as(c_long, c.WS_CHILD | c.WS_VISIBLE | switch (kind) {
        .button => c.WS_TABSTOP | c.BS_PUSHBUTTON,
        .checkbox, .@"switch" => c.WS_TABSTOP | c.BS_AUTOCHECKBOX,
        .text_area => c.WS_TABSTOP | c.WS_BORDER | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.WS_VSCROLL,
        .text_field, .search_field => c.WS_TABSTOP | c.WS_BORDER | c.ES_AUTOHSCROLL,
        .secure_field => c.WS_TABSTOP | c.WS_BORDER | c.ES_PASSWORD | c.ES_AUTOHSCROLL,
        .slider => c.WS_TABSTOP | c.TBS_HORZ,
        .dropdown => c.WS_TABSTOP | c.CBS_DROPDOWNLIST | c.WS_VSCROLL,
        .progress, .spinner => c.PBS_MARQUEE,
        else => 0,
    }));
    o.hwnd = c.CreateWindowExW(0, class, str(""), style, 0, 0, 1, 1, self.hwnd, null, c.GetModuleHandleW(null), null);
    if (o.hwnd == null) {
        a.destroy(o);
        return null;
    }
    _ = c.SetWindowLongPtrW(o.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(o)));
    _ = send(o.hwnd, c.WM_SETFONT, @intFromPtr(c.GetStockObject(c.DEFAULT_GUI_FONT)), 1);
    _ = c.SetWindowSubclass(o.hwnd, controlProc, 1, @intFromPtr(o));
    self.controls.append(a, o) catch {
        _ = c.DestroyWindow(o.hwnd);
        a.destroy(o);
        return null;
    };
    return o;
}
fn controlProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM, _: usize, data: usize) callconv(.winapi) c.LRESULT {
    const o: *Control = @ptrFromInt(data);
    switch (msg) {
        c.WM_KEYDOWN => {
            if (wp == c.VK_TAB) {
                o.window.host.tab(o.window.host.ctx, if (c.GetKeyState(c.VK_SHIFT) < 0) 0 else 1);
                return 0;
            }
            if (wp == c.VK_RETURN and o.kind != .text_area) {
                emit(o, .submit, 0);
                if (!o.window.host.enter(o.window.host.ctx)) {}
                return 0;
            }
        },
        c.WM_SETFOCUS => emit(o, .focus, 1),
        c.WM_KILLFOCUS => emit(o, .focus, 0),
        c.WM_IME_STARTCOMPOSITION => o.composing = true,
        c.WM_IME_ENDCOMPOSITION => {
            o.composing = false;
            const result = c.DefSubclassProc(hwnd, msg, wp, lp);
            textEvent(o);
            emit(o, .composition_end, 0);
            return result;
        },
        else => {},
    }
    return c.DefSubclassProc(hwnd, msg, wp, lp);
}
pub fn fabrum_win32_destroy(p: *anyopaque) void {
    const o = control(p);
    for (o.window.controls.items, 0..) |other, i| if (other == o) {
        _ = o.window.controls.swapRemove(i);
        break;
    };
    if (!o.window.closed) _ = c.DestroyWindow(o.hwnd);
    a.destroy(o);
}
pub fn fabrum_win32_set_title(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const s = wide(bytes[0..len]);
    defer a.free(s);
    _ = c.SetWindowTextW(control(p).hwnd, s.ptr);
}
pub fn fabrum_win32_set_text(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const o = control(p);
    o.writing = true;
    defer o.writing = false;
    fabrum_win32_set_title(p, bytes, len);
}
pub fn fabrum_win32_set_enabled(p: *anyopaque, enabled: bool) void {
    _ = c.EnableWindow(control(p).hwnd, @intFromBool(enabled));
}
pub fn fabrum_win32_set_default(p: *anyopaque, default: bool) void {
    _ = send(control(p).hwnd, c.BM_SETSTYLE, if (default) c.BS_DEFPUSHBUTTON else c.BS_PUSHBUTTON, 1);
}
pub fn fabrum_win32_set_placeholder(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const s = wide(bytes[0..len]);
    defer a.free(s);
    _ = send(control(p).hwnd, c.EM_SETCUEBANNER, 0, @bitCast(@intFromPtr(s.ptr)));
}
pub fn fabrum_win32_set_range(p: *anyopaque, min: f64, max: f64) void {
    const o = control(p);
    o.min = min;
    o.max = max;
    _ = send(o.hwnd, c.TBM_SETRANGEMIN, 0, 0);
    _ = send(o.hwnd, c.TBM_SETRANGEMAX, 1, 10000);
}
pub fn fabrum_win32_set_increment(p: *anyopaque, step: f64) void {
    control(p).step = step;
}
pub fn fabrum_win32_set_bool(p: *anyopaque, on: bool) void {
    _ = send(control(p).hwnd, c.BM_SETCHECK, if (on) c.BST_CHECKED else c.BST_UNCHECKED, 0);
}
pub fn fabrum_win32_set_number(p: *anyopaque, value: f64) void {
    const o = control(p);
    o.value = value;
    _ = send(o.hwnd, c.TBM_SETPOS, 1, int(if (o.max > o.min) (value - o.min) / (o.max - o.min) * 10000 else 0));
}
pub fn fabrum_win32_set_progress(p: *anyopaque, value: f64, indeterminate: bool) void {
    const o = control(p);
    const style = c.GetWindowLongPtrW(o.hwnd, c.GWL_STYLE);
    _ = c.SetWindowLongPtrW(o.hwnd, c.GWL_STYLE, if (indeterminate) style | c.PBS_MARQUEE else style & ~@as(isize, c.PBS_MARQUEE));
    _ = send(o.hwnd, c.PBM_SETRANGE32, 0, 10000);
    _ = send(o.hwnd, c.PBM_SETPOS, @intCast(@max(int(value * 10000), 0)), 0);
    _ = send(o.hwnd, c.PBM_SETMARQUEE, @intFromBool(indeterminate), 30);
}
pub fn fabrum_win32_set_spinner_size(p: *anyopaque, _: bool) void {
    fabrum_win32_set_progress(p, 0, true);
}
pub fn fabrum_win32_set_items(p: *anyopaque, titles: [*]const [*]const u8, lengths: [*]const usize, count: usize) void {
    const h = control(p).hwnd;
    _ = send(h, c.CB_RESETCONTENT, 0, 0);
    for (0..count) |i| {
        const s = wide(titles[i][0..lengths[i]]);
        defer a.free(s);
        _ = send(h, c.CB_ADDSTRING, 0, @bitCast(@intFromPtr(s.ptr)));
    }
}
pub fn fabrum_win32_set_selection(p: *anyopaque, index: c_long) void {
    _ = send(control(p).hwnd, c.CB_SETCURSEL, @bitCast(@as(isize, index)), 0);
}
pub fn fabrum_win32_set_frame(p: *anyopaque, x: f64, y: f64, width: f64, height: f64) void {
    const o = control(p);
    const scale = dpi(o.window.hwnd);
    _ = c.SetWindowPos(o.hwnd, null, int(x * scale), int(y * scale), int(width * scale), int((height + @as(f64, if (o.kind == .dropdown) 200 else 0)) * scale), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}
pub fn fabrum_win32_fitting_size(p: *anyopaque, max_width: f64, width: *f64, height: *f64) void {
    const o = control(p);
    const n: f64 = @floatFromInt(c.GetWindowTextLengthW(o.hwnd));
    width.* = switch (o.kind) {
        .button => @max(75, n * 8 + 24),
        .checkbox, .@"switch" => n * 8 + 28,
        .label => @max(n * 8, 1),
        else => 160,
    };
    height.* = if (o.kind == .text_area) 100 else if (o.kind == .label) 20 else 26;
    if (max_width > 0) width.* = @min(max_width, width.*);
}
pub fn fabrum_win32_is_composing(p: *anyopaque) bool {
    return control(p).composing;
}
pub fn fabrum_win32_can_focus(p: *anyopaque) bool {
    const o = control(p);
    return o.kind != .label and o.kind != .progress and o.kind != .spinner and c.IsWindowEnabled(o.hwnd) != 0;
}
pub fn fabrum_win32_focus(p: *anyopaque, handle: ?*anyopaque, canvas: c_int) void {
    const self = w(p);
    _ = c.SetFocus(if (handle) |h| control(h).hwnd else if (canvas != 0 and self.layers.items.len > 0) self.layers.items[0].hwnd else self.hwnd);
}
pub fn fabrum_win32_arrange(p: *anyopaque, container: ?*anyopaque, slots: [*]const abi.CSlot, count: usize) void {
    const self = w(p);
    if (container != null) return;
    for (self.layers.items) |l| {
        l.active = false;
        _ = c.KillTimer(l.hwnd, 1);
        _ = c.ShowWindow(l.hwnd, c.SW_HIDE);
    }
    var r: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &r);
    for (0..count) |i| {
        const slot = slots[i];
        const hwnd = if (slot.widget) |h| control(h).hwnd else blk: {
            const index: usize = @intCast(slot.canvas);
            while (self.layers.items.len <= index) {
                const l = a.create(Layer) catch return;
                l.* = .{ .window = self, .index = @intCast(self.layers.items.len) };
                l.hwnd = c.CreateWindowExW(c.WS_EX_LAYERED, str("FabrumCanvas"), str(""), c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS, 0, 0, r.right, r.bottom, self.hwnd, null, c.GetModuleHandleW(null), null);
                if (l.hwnd == null) {
                    a.destroy(l);
                    return;
                }
                _ = c.SetWindowLongPtrW(l.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(l)));
                self.layers.append(a, l) catch {
                    _ = c.DestroyWindow(l.hwnd);
                    a.destroy(l);
                    return;
                };
            }
            const l = self.layers.items[index];
            l.active = true;
            _ = c.ShowWindow(l.hwnd, c.SW_SHOWNA);
            schedulePaint(l);
            _ = c.SetWindowPos(l.hwnd, null, 0, 0, r.right, r.bottom, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            break :blk l.hwnd;
        };
        _ = c.SetWindowPos(hwnd, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
}
pub fn fabrum_win32_damage_layer(p: *anyopaque, layer: c_uint, _: f64, _: f64, _: f64, _: f64) void {
    const self = w(p);
    if (layer < self.layers.items.len) schedulePaint(self.layers.items[layer]);
}
pub fn fabrum_win32_theme(_: *anyopaque, out: *abi.CTheme) void {
    out.* = .{ .accent = .{ 0, 0.47, 0.84, 1 }, .text = .{ 0, 0, 0, 1 }, .secondary_text = .{ 0.4, 0.4, 0.4, 1 }, .window_background = .{ 1, 1, 1, 1 }, .control_background = .{ 0.94, 0.94, 0.94, 1 }, .separator = .{ 0.8, 0.8, 0.8, 1 }, .focus_ring = .{ 0, 0.47, 0.84, 1 }, .font_size = 12, .control_height = 26, .full_keyboard_access = 1, .dark = 0 };
}
pub fn fabrum_win32_font_family(out: [*]u8, cap: usize) usize {
    const s = "Segoe UI";
    const n = @min(cap, s.len);
    @memcpy(out[0..n], s[0..n]);
    return n;
}
pub fn fabrum_win32_perform_click(p: *anyopaque) void {
    _ = send(control(p).hwnd, c.BM_CLICK, 0, 0);
}
pub fn fabrum_win32_type(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const s = wide(bytes[0..len]);
    defer a.free(s);
    _ = send(control(p).hwnd, c.EM_REPLACESEL, 1, @bitCast(@intFromPtr(s.ptr)));
}
pub fn fabrum_win32_text(p: *anyopaque, out: [*]u8, cap: usize) usize {
    const n = c.GetWindowTextLengthW(control(p).hwnd);
    const b = a.allocSentinel(u16, @intCast(@max(n, 0)), 0) catch return 0;
    defer a.free(b);
    _ = c.GetWindowTextW(control(p).hwnd, b.ptr, @intCast(b.len + 1));
    const utf = std.unicode.utf16LeToUtf8Alloc(a, b) catch return 0;
    defer a.free(utf);
    const len = @min(cap, utf.len);
    @memcpy(out[0..len], utf[0..len]);
    return len;
}
pub fn fabrum_win32_newline(p: *anyopaque) void {
    emit(control(p), .submit, 0);
}
pub fn fabrum_win32_slide(p: *anyopaque, value: f64) void {
    fabrum_win32_set_number(p, value);
    emit(control(p), .number, value);
}
pub fn fabrum_win32_select(p: *anyopaque, index: c_long) void {
    fabrum_win32_set_selection(p, index);
    emit(control(p), .select, @floatFromInt(index));
}
pub fn fabrum_win32_step(p: *anyopaque, steps: c_long) void {
    const o = control(p);
    fabrum_win32_slide(p, std.math.clamp(o.value + @as(f64, @floatFromInt(steps)) * o.step, o.min, o.max));
}
pub fn fabrum_win32_tab(p: *anyopaque, forward: c_int) void {
    const self = w(p);
    self.host.tab(self.host.ctx, forward);
}
pub fn fabrum_win32_resize(p: *anyopaque, width: f64, height: f64) void {
    const self = w(p);
    var r = c.RECT{ .left = 0, .top = 0, .right = int(width * dpi(self.hwnd)), .bottom = int(height * dpi(self.hwnd)) };
    _ = c.AdjustWindowRectEx(&r, c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN, 0, 0);
    _ = c.SetWindowPos(self.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, c.SWP_NOMOVE | c.SWP_NOZORDER);
}
const Dialog = struct { window: *Window, hwnd: c.HWND = null, default_index: usize = 0, button_count: usize = 0, callback: ?abi.IndexCallback = null, ctx: ?*anyopaque = null };
var dialogs: std.ArrayList(*Dialog) = .empty;
fn dialogProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const d = object(hwnd, Dialog) orelse return c.DefWindowProcW(hwnd, msg, wp, lp);
    if (msg == c.DM_GETDEFID) return @intCast((c.DC_HASDEFID << 16) | (100 + d.default_index));
    if (msg == c.DM_SETDEFID) {
        if (wp >= 100 and wp < 100 + d.button_count) d.default_index = wp - 100;
        return 0;
    }
    if (msg == c.WM_COMMAND) {
        const id = wp & 0xffff;
        if (id >= 100 and id < 100 + d.button_count) finishDialog(d, @intCast(id - 100)) else if (id == c.IDCANCEL) finishDialog(d, -1);
        return 0;
    }
    if (msg == c.WM_CLOSE or msg == c.WM_TIMER) {
        finishDialog(d, -1);
        return 0;
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn finishDialog(d: *Dialog, index: c_long) void {
    const callback = d.callback;
    const ctx = d.ctx;
    for (dialogs.items, 0..) |other, i| if (other == d) {
        _ = dialogs.swapRemove(i);
        break;
    };
    _ = c.DestroyWindow(d.hwnd);
    a.destroy(d);
    if (callback) |done| done(ctx, index);
}
fn dialog(p: *anyopaque, title: []const u8, text: []const u8, buttons: []const []const u8, callback: ?abi.IndexCallback, ctx: ?*anyopaque, timeout: c_uint, default_index: usize) void {
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = dialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpszClassName = str("FabrumDialog");
    wc.hbrBackground = c.GetSysColorBrush(c.COLOR_WINDOW);
    _ = c.RegisterClassExW(&wc);
    const d = a.create(Dialog) catch {
        if (callback) |done| done(ctx, -1);
        return;
    };
    d.* = .{ .window = w(p), .callback = callback, .ctx = ctx, .default_index = default_index, .button_count = buttons.len };
    const t = wide(title);
    defer a.free(t);
    const body = wide(text);
    defer a.free(body);
    d.hwnd = c.CreateWindowExW(c.WS_EX_DLGMODALFRAME, str("FabrumDialog"), t.ptr, c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU, c.CW_USEDEFAULT, c.CW_USEDEFAULT, 460, 200, w(p).hwnd, null, c.GetModuleHandleW(null), null);
    if (d.hwnd == null) {
        a.destroy(d);
        if (callback) |done| done(ctx, -1);
        return;
    }
    _ = c.SetWindowLongPtrW(d.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(d)));
    _ = c.CreateWindowExW(0, str("STATIC"), body.ptr, c.WS_CHILD | c.WS_VISIBLE, 20, 20, 410, 80, d.hwnd, null, c.GetModuleHandleW(null), null);
    for (buttons, 0..) |button, i| {
        const b = wide(button);
        defer a.free(b);
        const button_hwnd = c.CreateWindowExW(0, str("BUTTON"), b.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON, 20 + @as(c_int, @intCast(i)) * 130, 115, 120, 28, d.hwnd, null, c.GetModuleHandleW(null), null);
        _ = c.SetWindowLongPtrW(button_hwnd, c.GWLP_ID, @intCast(100 + i));
    }
    const default_button = c.GetDlgItem(d.hwnd, @intCast(100 + default_index));
    _ = send(default_button, c.BM_SETSTYLE, c.BS_DEFPUSHBUTTON, 1);
    _ = send(d.hwnd, c.DM_SETDEFID, 100 + default_index, 0);
    dialogs.append(a, d) catch @panic("out of memory");
    if (timeout > 0) _ = c.SetTimer(d.hwnd, 1, timeout, null);
    _ = c.ShowWindow(d.hwnd, c.SW_SHOW);
    _ = c.SetFocus(default_button);
}
pub fn fabrum_win32_message(p: *anyopaque, title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, _: c_int, timeout: c_uint) void {
    dialog(p, title[0..title_len], text[0..text_len], &.{"OK"}, null, null, timeout, 0);
}
pub fn fabrum_win32_confirm(p: *anyopaque, title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, buttons: [*]const [*]const u8, lengths: [*]const usize, count: usize, default_index: usize, _: c_int, done: abi.IndexCallback, ctx: ?*anyopaque) void {
    var items: [3][]const u8 = undefined;
    for (0..count) |i| items[i] = buttons[i][0..lengths[i]];
    dialog(p, title[0..title_len], text[0..text_len], items[0..count], done, ctx, 0, @min(default_index, count - 1));
}
pub fn fabrum_win32_answer_alert(p: *anyopaque, index: c_int) void {
    for (dialogs.items) |d| if (d.window == w(p)) {
        finishDialog(d, index);
        return;
    };
}
pub fn fabrum_win32_write_clipboard(bytes: [*]const u8, len: usize) void {
    const text = wide(bytes[0..len]);
    defer a.free(text);
    if (c.OpenClipboard(dispatcher) == 0) return;
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, (text.len + 1) * 2) orelse return;
    const dest = c.GlobalLock(mem) orelse {
        _ = c.GlobalFree(mem);
        return;
    };
    @memcpy(@as([*]u16, @ptrCast(@alignCast(dest)))[0 .. text.len + 1], text[0 .. text.len + 1]);
    _ = c.GlobalUnlock(mem);
    if (c.SetClipboardData(c.CF_UNICODETEXT, mem) == null) _ = c.GlobalFree(mem);
}
pub fn fabrum_win32_read_clipboard(done: abi.TextCallback, ctx: ?*anyopaque) void {
    if (c.OpenClipboard(dispatcher) == 0) {
        done(ctx, null, 0);
        return;
    }
    defer _ = c.CloseClipboard();
    const mem = c.GetClipboardData(c.CF_UNICODETEXT) orelse {
        done(ctx, null, 0);
        return;
    };
    const src = c.GlobalLock(mem) orelse {
        done(ctx, null, 0);
        return;
    };
    defer _ = c.GlobalUnlock(mem);
    const s: [*:0]const u16 = @ptrCast(@alignCast(src));
    const utf = std.unicode.utf16LeToUtf8Alloc(a, std.mem.span(s)) catch {
        done(ctx, null, 0);
        return;
    };
    defer a.free(utf);
    done(ctx, utf.ptr, utf.len);
}
pub fn fabrum_win32_set_label_style(p: *anyopaque, wrap: bool, selectable: bool, _: f64, _: bool) void {
    _ = selectable;
    const o = control(p);
    const style = c.GetWindowLongPtrW(o.hwnd, c.GWL_STYLE);
    _ = c.SetWindowLongPtrW(o.hwnd, c.GWL_STYLE, (style & ~@as(isize, c.SS_TYPEMASK)) | @as(isize, if (wrap) c.SS_LEFT else c.SS_LEFTNOWORDWRAP));
}
pub fn fabrum_win32_set_horizontal(_: *anyopaque, _: bool) void {
    unreachable;
}
pub fn fabrum_win32_set_message(_: *anyopaque, _: [*]const u8, _: usize) void {
    unreachable;
}
pub fn fabrum_win32_add_button(_: *anyopaque, _: [*]const u8, _: usize) void {
    unreachable;
}
pub fn fabrum_win32_show_alert(_: *anyopaque) void {
    unreachable;
}
pub fn fabrum_win32_place_menu_item(_: *anyopaque, _: [*]const u8, _: usize) void {
    unreachable;
}
pub fn fabrum_win32_set_key_equivalent(_: *anyopaque, _: [*]const u8, _: usize) void {
    unreachable;
}
pub fn fabrum_win32_set_scroll_axes(_: *anyopaque, _: bool, _: bool) void {
    unreachable;
}
pub fn fabrum_win32_set_content_size(_: *anyopaque, _: f64, _: f64) void {
    unreachable;
}
pub fn fabrum_win32_scroll_to(_: *anyopaque, _: f64, _: f64) void {
    unreachable;
}
pub fn fabrum_win32_snapshot(_: *anyopaque, _: [*:0]const u8, _: f64) bool {
    return false;
}
pub fn fabrum_win32_describe_focus(p: *anyopaque, out: [*]u8, cap: usize) usize {
    const self = w(p);
    const h = c.GetFocus();
    const s: []const u8 = blk: {
        if (h == self.hwnd) break :blk "window";
        for (self.controls.items) |o| if (o.hwnd == h) {
            break :blk @tagName(o.kind);
        };
        break :blk "canvas";
    };
    const n = @min(s.len, cap);
    @memcpy(out[0..n], s[0..n]);
    return n;
}
pub fn fabrum_win32_describe_hit(_: *anyopaque, _: f64, _: f64, _: [*]u8, _: usize) usize {
    return 0;
}
pub fn fabrum_win32_answer_popup(_: *anyopaque, _: c_long) bool {
    return false;
}
pub fn fabrum_win32_answer_open_panel(_: *anyopaque, _: ?[*:0]const u8) bool {
    return false;
}
pub fn fabrum_win32_choose_menu(_: *anyopaque, _: [*:0]const u8, _: [*:0]const u8) bool {
    return false;
}

pub fn nativeHwnd(p: *anyopaque) *anyopaque {
    return @ptrCast(w(p).hwnd.?);
}
pub fn scheduleFrame(p: *anyopaque, ms: c_uint) void {
    if (!w(p).closed) _ = c.SetTimer(w(p).hwnd, 1, ms, null);
}
pub fn cancelFrame(p: *anyopaque) void {
    if (!w(p).closed) _ = c.KillTimer(w(p).hwnd, 1);
}

const KeyEvent = @import("../../../app.zig").KeyEvent;
fn keyEvent(self: *Window, msg: c.UINT, vk: usize, lp: isize) bool {
    const key: KeyEvent.Key = switch (vk) {
        c.VK_TAB => .tab,
        c.VK_RETURN => .enter,
        c.VK_SPACE => .space,
        c.VK_ESCAPE => .escape,
        c.VK_BACK => .backspace,
        c.VK_DELETE => .delete,
        c.VK_INSERT => .insert,
        c.VK_LEFT => .left,
        c.VK_RIGHT => .right,
        c.VK_UP => .up,
        c.VK_DOWN => .down,
        c.VK_HOME => .home,
        c.VK_END => .end,
        c.VK_PRIOR => .page_up,
        c.VK_NEXT => .page_down,
        c.VK_SHIFT => .shift,
        c.VK_CONTROL => .control,
        c.VK_MENU => .alt,
        c.VK_LWIN, c.VK_RWIN => .super,
        c.VK_CAPITAL => .caps_lock,
        c.VK_F1...c.VK_F24 => .{ .f = @intCast(vk - c.VK_F1 + 1) },
        else => blk: {
            const char = c.MapVirtualKeyW(@intCast(vk), c.MAPVK_VK_TO_CHAR) & 0x7fffffff;
            break :blk if (char > 0 and char <= 0x10ffff) .{ .char = if (char >= 'A' and char <= 'Z') @intCast(char + 32) else @intCast(char) } else .unknown;
        },
    };
    const release = msg == c.WM_KEYUP or msg == c.WM_SYSKEYUP;
    var event = KeyEvent{ .key = key, .phase = if (release) .release else if ((@as(usize, @bitCast(lp)) & (1 << 30)) != 0) .repeat else .press, .modifiers = .{ .shift = c.GetKeyState(c.VK_SHIFT) < 0, .control = c.GetKeyState(c.VK_CONTROL) < 0, .alt = c.GetKeyState(c.VK_MENU) < 0, .super = c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0 } };
    if (vk >= 'A' and vk <= 'Z') event.physical = @fromBackingInt(@intCast(@backingInt(KeyEvent.Physical.key_a) + vk - 'A'));
    var state: [256]u8 = undefined;
    var utf16: [8]u16 = undefined;
    var utf8: [32]u8 = undefined;
    if (!release and c.GetKeyboardState(&state) != 0) {
        const count = c.ToUnicodeEx(@intCast(vk), @intCast((@as(usize, @bitCast(lp)) >> 16) & 0xff), &state, &utf16, utf16.len, 4, c.GetKeyboardLayout(0));
        if (count > 0) {
            const len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..@intCast(count)]) catch 0;
            if (len > 0 and utf8[0] >= 0x20) event.text = utf8[0..len];
        }
    }
    self.busy = true;
    defer {
        self.busy = false;
        flushEvents(self);
    }
    return self.host.key(self.host.ctx, &event);
}

const QueuedEvent = struct { id: u64, kind: abi.EventKind, number: f64, text: ?[]u8 = null };
/// Close guards enter through the application coordinator as well as the
/// window procedure. Both must defer synchronous native notifications until
/// the runtime has finished delivering the guard's update.
pub fn enterRuntime(p: *anyopaque) bool {
    const self = w(p);
    const was_busy = self.busy;
    self.busy = true;
    return was_busy;
}
pub fn leaveRuntime(p: *anyopaque, was_busy: bool) void {
    const self = w(p);
    self.busy = was_busy;
    if (!was_busy) {
        flushEvents(self);
        if (self.frame_again) {
            self.frame_again = false;
            request_frame(self);
        }
    }
}
fn deliverEvent(self: *Window, id: u64, kind: abi.EventKind, number: f64, text: ?[]const u8) void {
    if (self.closed) return;
    if (self.busy) {
        const owned = if (text) |t| a.dupe(u8, t) catch @panic("out of memory") else null;
        self.events.append(a, .{ .id = id, .kind = kind, .number = number, .text = owned }) catch @panic("out of memory");
        return;
    }
    self.busy = true;
    self.host.event(self.host.ctx, id, kind, number, if (text) |t| t.ptr else null, if (text) |t| t.len else 0);
    self.busy = false;
    flushEvents(self);
}
fn flushEvents(self: *Window) void {
    if (self.busy or self.closed) return;
    self.busy = true;
    defer self.busy = false;
    while (self.events.items.len > 0) {
        const event = self.events.orderedRemove(0);
        defer if (event.text) |t| a.free(t);
        self.host.event(self.host.ctx, event.id, event.kind, event.number, if (event.text) |t| t.ptr else null, if (event.text) |t| t.len else 0);
    }
}

// UpdateLayeredWindow owns canvas presentation. A new layered child has no
// visible bitmap, so Windows may never generate its initial WM_PAINT. Schedule
// presentation explicitly, after the runtime has finished constructing scene.
fn schedulePaint(layer: *Layer) void {
    if (layer.paint_pending) return;
    layer.paint_pending = true;
    _ = c.PostMessageW(layer.hwnd, paint_message, 0, 0);
}

/// Reads the alpha channel of the bitmap last successfully uploaded to the
/// layered HWND. This proves bitmap production and upload, not desktop composition.
pub fn canvasHasInk(p: *anyopaque, index: usize) bool {
    const self = w(p);
    if (index >= self.layers.items.len) return false;
    const layer = self.layers.items[index];
    if (!layer.presented) return false;
    const pixels = fabrum_d2d_image_data(layer.target orelse return false) orelse return false;
    for (0..layer.paint_width * layer.paint_height) |i| if (pixels[i * 4 + 3] != 0) return true;
    return false;
}

pub const CanvasState = struct {
    hwnd: *anyopaque,
    visible: bool,
    presented: bool,
    width: usize,
    height: usize,
    retries: u8,
    retry_attempts: usize,
    presentations: usize,
    paint_attempts: usize,
};
pub fn canvasState(p: *anyopaque, index: usize) ?CanvasState {
    const self = w(p);
    if (index >= self.layers.items.len) return null;
    const l = self.layers.items[index];
    return .{ .hwnd = l.hwnd.?, .visible = c.IsWindowVisible(l.hwnd) != 0, .presented = l.presented, .width = l.paint_width, .height = l.paint_height, .retries = l.retry_count, .retry_attempts = l.retry_attempts, .presentations = l.presentations, .paint_attempts = l.paint_attempts };
}
/// Premultiplied BGRA in physical pixels, from the last successful upload.
pub fn canvasPixel(p: *anyopaque, index: usize, x: usize, y: usize) ?[4]u8 {
    const self = w(p);
    if (index >= self.layers.items.len) return null;
    const l = self.layers.items[index];
    if (!l.presented or x >= l.paint_width or y >= l.paint_height) return null;
    const pixels = fabrum_d2d_image_data(l.target orelse return null) orelse return null;
    return pixels[(y * l.paint_width + x) * 4 ..][0..4].*;
}
pub fn injectCanvasDeviceLoss(p: *anyopaque, index: usize) void {
    const self = w(p);
    if (index >= self.layers.items.len) return;
    const l = self.layers.items[index];
    fabrum_d2d_test_fail_end(l.target orelse return, true);
    schedulePaint(l);
}
pub fn failCanvasCreates(p: *anyopaque, index: usize, count: u32) void {
    const self = w(p);
    if (index >= self.layers.items.len) return;
    fabrum_d2d_test_fail_creates(self.layers.items[index].target orelse return, count);
}
