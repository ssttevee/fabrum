const std = @import("std");
const abi = @import("../win32.zig");
const c = @import("win32_c");
const a = std.heap.page_allocator;
const services = @import("services.zig");
const theme = @import("theme.zig");
const platform = @import("../../../app.zig").platform;
extern fn fabrum_d2d_target_create(?*anyopaque) ?*anyopaque;
extern fn fabrum_d2d_target_destroy(*anyopaque) void;
extern fn fabrum_d2d_target_resize(*anyopaque, u32, u32) bool;
extern fn fabrum_d2d_target_begin(*anyopaque) bool;
extern fn fabrum_d2d_target_end(*anyopaque) bool;
extern fn fabrum_d2d_target_recoverable(*anyopaque) bool;
extern fn fabrum_d2d_image_data(*anyopaque) ?[*]const u8;
extern fn fabrum_d2d_test_fail_end(*anyopaque, bool) void;
extern fn fabrum_d2d_test_fail_creates(*anyopaque, c_uint) void;
extern fn fabrum_file_dialog_shutdown() void;
const frame_message = c.WM_APP + 1;
const task_message = c.WM_APP + 2;
const paint_message = c.WM_APP + 3;
/// The UI thread owns every HWND and object. Only frame requests and the
/// dispatcher queue are shared with workers; their synchronization is explicit.
const Window = struct {
    hwnd: c.HWND = null,
    host: abi.CHost,
    options: abi.COptions,
    palette: theme.colors.Palette = undefined,
    theme_test: ?struct { system: theme.colors.Palette, high_contrast: bool } = null,
    dialog_font_points: f64 = 0,
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
    menu: c.HMENU = null,
    next_command: usize = 1000,
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
    document: c.HWND = null,
    horizontal: bool = false,
    vertical: bool = true,
    content_width: f64 = 0,
    content_height: f64 = 0,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    parts: std.ArrayList(c.HWND) = .empty,
    selection: c_long = -1,
    enabled: bool = true,
    title: []const u8 = "",
    message: []const u8 = "",
    menu_group: ?[]const u8 = null,
    key: []const u8 = "",
    command: usize = 0,
    alert_buttons: std.ArrayList([]const u8) = .empty,
    dialog: ?*Dialog = null,
    answered: bool = false,
    font: c.HFONT = null,
    font_size: f64 = 0,
    wrap: bool = false,
    selectable: bool = false,
    secondary: bool = false,
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
    // Synthetic HWND messages can reach a disabled control even though Windows
    // suppresses physical input. Apply the same rule at the event boundary.
    if (!o.enabled and ((o.kind == .radio_group and kind == .select) or (o.kind == .stepper and kind == .number))) return;
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
    wc.lpfnWndProc = scrollProc;
    wc.lpszClassName = str("FabrumScroll");
    wc.hbrBackground = c.GetSysColorBrush(c.COLOR_WINDOW);
    _ = c.RegisterClassExW(&wc);
    wc.lpfnWndProc = compoundProc;
    wc.lpszClassName = str("FabrumCompound");
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
// A viewport owns a document HWND. Native children and canvas layers share
// document coordinates; moving the document implements scrolling and the
// viewport's child clipping applies equally to both kinds of child.
fn updateScroll(o: *Control, requested_x: f64, requested_y: f64) void {
    if (o.document == null or o.writing) return;
    o.writing = true;
    const scale = dpi(o.hwnd);
    // Solve scrollbar visibility from the borderless viewport's outer size.
    // Starting with neither bar lets shrinking remove both without hiding and
    // showing existing bars on every wheel event.
    var outer: c.RECT = undefined;
    _ = c.GetWindowRect(o.hwnd, &outer);
    var horizontal = false;
    var vertical = false;
    const bar_width = c.GetSystemMetricsForDpi(c.SM_CXVSCROLL, c.GetDpiForWindow(o.hwnd));
    const bar_height = c.GetSystemMetricsForDpi(c.SM_CYHSCROLL, c.GetDpiForWindow(o.hwnd));
    for (0..3) |_| {
        horizontal = o.horizontal and o.content_width * scale > @as(f64, @floatFromInt(outer.right - outer.left - (if (vertical) bar_width else 0)));
        vertical = o.vertical and o.content_height * scale > @as(f64, @floatFromInt(outer.bottom - outer.top - (if (horizontal) bar_height else 0)));
    }
    _ = c.ShowScrollBar(o.hwnd, c.SB_HORZ, @intFromBool(horizontal));
    _ = c.ShowScrollBar(o.hwnd, c.SB_VERT, @intFromBool(vertical));
    var r: c.RECT = undefined;
    _ = c.GetClientRect(o.hwnd, &r);
    const width = @as(f64, @floatFromInt(r.right)) / scale;
    const height = @as(f64, @floatFromInt(r.bottom)) / scale;
    const x = if (o.horizontal and std.math.isFinite(requested_x)) std.math.clamp(requested_x, 0, @max(0, o.content_width - width)) else 0;
    const y = if (o.vertical and std.math.isFinite(requested_y)) std.math.clamp(requested_y, 0, @max(0, o.content_height - height)) else 0;
    const changed = x != o.scroll_x or y != o.scroll_y;
    o.scroll_x = x;
    o.scroll_y = y;
    var info = std.mem.zeroes(c.SCROLLINFO);
    info.cbSize = @sizeOf(c.SCROLLINFO);
    info.fMask = c.SIF_RANGE | c.SIF_PAGE | c.SIF_POS;
    info.nMax = @max(0, (if (o.horizontal) int(o.content_width * scale) else r.right) - 1);
    info.nPage = @intCast(@max(0, r.right));
    info.nPos = int(x * scale);
    _ = c.SetScrollInfo(o.hwnd, c.SB_HORZ, &info, 1);
    info.nMax = @max(0, (if (o.vertical) int(o.content_height * scale) else r.bottom) - 1);
    info.nPage = @intCast(@max(0, r.bottom));
    info.nPos = int(y * scale);
    _ = c.SetScrollInfo(o.hwnd, c.SB_VERT, &info, 1);
    _ = c.SetWindowPos(o.document, null, -int(x * scale), -int(y * scale), @max(r.right, int(o.content_width * scale)), @max(r.bottom, int(o.content_height * scale)), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    o.writing = false;
    if (changed) {
        const self = o.window;
        self.events.append(a, .{ .id = o.id, .kind = .number, .number = x, .scroll_y = y }) catch @panic("out of memory");
        flushEvents(self);
    }
}
fn scrollProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (labelColor(msg, wp, lp)) |result| return result;
    if (msg == c.WM_ERASEBKGND) {
        for (windows.items) |window| for (window.controls.items) |o| {
            if (o.kind == .scroll_view and (o.hwnd == hwnd or o.document == hwnd)) return theme.erase(hwnd, @ptrFromInt(wp), window.palette.background);
        };
    }
    const o = object(hwnd, Control) orelse {
        // Documents forward notifications from native controls to the host.
        if (msg == c.WM_COMMAND or msg == c.WM_HSCROLL or msg == c.WM_VSCROLL or msg == c.WM_MOUSEWHEEL or msg == c.WM_MOUSEHWHEEL)
            return send(c.GetParent(hwnd), msg, wp, lp);
        return c.DefWindowProcW(hwnd, msg, wp, lp);
    };
    switch (msg) {
        c.WM_SIZE => {
            updateScroll(o, o.scroll_x, o.scroll_y);
            return 0;
        },
        c.WM_COMMAND => return windowProc(o.window.hwnd, msg, wp, lp),
        c.WM_HSCROLL, c.WM_VSCROLL => {
            if (lp != 0) return windowProc(o.window.hwnd, msg, wp, lp);
            const horizontal = msg == c.WM_HSCROLL;
            var info = std.mem.zeroes(c.SCROLLINFO);
            info.cbSize = @sizeOf(c.SCROLLINFO);
            info.fMask = c.SIF_ALL;
            _ = c.GetScrollInfo(hwnd, if (horizontal) c.SB_HORZ else c.SB_VERT, &info);
            const old = if (horizontal) o.scroll_x else o.scroll_y;
            const page = @as(f64, @floatFromInt(info.nPage)) / dpi(hwnd);
            const next = switch (wp & 0xffff) {
                c.SB_LINEUP => old - 40,
                c.SB_LINEDOWN => old + 40,
                c.SB_PAGEUP => old - page,
                c.SB_PAGEDOWN => old + page,
                c.SB_TOP => 0,
                c.SB_BOTTOM => @as(f64, @floatFromInt(info.nMax)) / dpi(hwnd),
                c.SB_THUMBPOSITION, c.SB_THUMBTRACK => @as(f64, @floatFromInt(info.nTrackPos)) / dpi(hwnd),
                else => old,
            };
            updateScroll(o, if (horizontal) next else o.scroll_x, if (horizontal) o.scroll_y else next);
            return 0;
        },
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            const horizontal = msg == c.WM_MOUSEHWHEEL or (wp & c.MK_SHIFT) != 0;
            if ((horizontal and !o.horizontal) or (!horizontal and !o.vertical)) return send(c.GetParent(hwnd), msg, wp, lp);
            var units: c.UINT = 3;
            _ = c.SystemParametersInfoW(if (horizontal) c.SPI_GETWHEELSCROLLCHARS else c.SPI_GETWHEELSCROLLLINES, 0, &units, 0);
            var r: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &r);
            const page = @as(f64, @floatFromInt(if (horizontal) r.right else r.bottom)) / dpi(hwnd);
            const step = if (units == std.math.maxInt(c.UINT)) page else @as(f64, @floatFromInt(units)) * 40;
            const delta = signedWord(wp >> 16) / 120 * step * @as(f64, if (msg == c.WM_MOUSEHWHEEL) 1 else -1);
            const offset = if (horizontal) o.scroll_x else o.scroll_y;
            const limit = @max(0, (if (horizontal) o.content_width else o.content_height) - page);
            if ((delta < 0 and offset <= 0) or (delta > 0 and offset >= limit)) return send(c.GetParent(hwnd), msg, wp, lp);
            updateScroll(o, o.scroll_x + (if (horizontal) delta else 0), o.scroll_y + (if (horizontal) 0 else delta));
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
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
    if (labelColor(msg, wp, lp)) |result| return result;
    const self = object(hwnd, Window) orelse {
        // A closed wrapper can leave its detached native owner alive until a
        // modal stack returns. A second close must not let DefWindowProc destroy
        // that HWND while native code still owns it.
        if (msg == c.WM_CLOSE) return 0;
        return c.DefWindowProcW(hwnd, msg, wp, lp);
    };
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
        c.WM_ERASEBKGND => return theme.erase(hwnd, @ptrFromInt(wp), self.palette.background),
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED, c.WM_SYSCOLORCHANGE => {
            refreshTheme(self);
            for (self.controls.items) |o| updateFont(o);
            request_frame(self);
            return 0;
        },
        c.WM_DPICHANGED => {
            for (self.controls.items) |o| updateFont(o);
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
            if (lp == 0) {
                for (self.controls.items) |o| if (o.kind == .menu_item and o.command == (wp & 0xffff) and o.enabled) {
                    emit(o, .activate, 0);
                    return 0;
                };
            }
            const child: c.HWND = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (child != null) if (object(child, Control)) |o| {
                const code = (wp >> 16) & 0xffff;
                if (code == c.BN_CLICKED) {
                    switch (o.kind) {
                        .checkbox, .@"switch" => emit(o, .toggle, if (send(child, c.BM_GETCHECK, 0, 0) == c.BST_CHECKED) 1 else 0),
                        else => emit(o, .activate, 0),
                    }
                } else if (code == c.EN_CHANGE) {
                    if (o.kind != .label and !o.writing and !o.composing) textEvent(o);
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
            // A drawn descendant gets first refusal. Input callbacks may
            // change the scene, so forward only if this layer still belongs
            // to the same live document after the callback returns.
            const parent = c.GetParent(hwnd);
            const consumed = self.host.mouse(self.host.ctx, @intCast(l.index), @as(f64, @floatFromInt(pt.x)) / dpi(hwnd), @as(f64, @floatFromInt(pt.y)) / dpi(hwnd), self.buttons, if (msg == c.WM_MOUSEHWHEEL) wheel else 0, if (msg == c.WM_MOUSEWHEEL) -wheel else 0);
            if (!consumed and !self.closed and (msg == c.WM_MOUSEWHEEL or msg == c.WM_MOUSEHWHEEL) and parent != self.hwnd and c.IsWindow(parent) != 0 and c.GetParent(hwnd) == parent) _ = send(parent, msg, wp, lp);
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
    refreshTheme(self);
    try windows.append(a, self);
    return self;
}
pub fn fabrum_win32_window_release(p: *anyopaque) void {
    const self = w(p);
    _ = services.cancelOwner(p);
    for (self.layers.items) |l| {
        _ = c.KillTimer(l.hwnd, 1);
        // An active native service can temporarily retain the detached owner
        // HWND. Its children must not outlive the Layer data stored in them.
        if (c.IsWindow(l.hwnd) != 0) _ = c.DestroyWindow(l.hwnd);
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
    services.shutdown();
    fabrum_file_dialog_shutdown();
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
fn detachChildren(self: *Window) void {
    // A native modal loop can retain the owner HWND after its runtime closes.
    // Remove every native route to application allocations before cancellation,
    // focus changes or destruction can reenter window procedures.
    for (self.layers.items) |l| {
        l.active = false;
        _ = c.KillTimer(l.hwnd, 1);
        _ = c.SetWindowLongPtrW(l.hwnd, c.GWLP_USERDATA, 0);
    }
    for (self.controls.items) |o| {
        _ = c.RemoveWindowSubclass(o.hwnd, controlProc, 1);
        _ = c.SetWindowLongPtrW(o.hwnd, c.GWLP_USERDATA, 0);
        for (o.parts.items) |part| {
            _ = c.RemoveWindowSubclass(part, controlProc, 1);
            _ = c.SetWindowLongPtrW(part, c.GWLP_USERDATA, 0);
        }
        if (o.document != null) _ = c.SetWindowLongPtrW(o.document, c.GWLP_USERDATA, 0);
    }
}
pub fn fabrum_win32_close_now(p: *anyopaque) void {
    const self = w(p);
    if (self.closed) return;
    self.closed = true;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    detachChildren(self);
    const deferred = services.cancelOwner(p);
    var i: usize = 0;
    while (i < dialogs.items.len) {
        if (dialogs.items[i].window == self) finishDialog(dialogs.items[i], -1) else i += 1;
    }
    if (deferred) {
        // Keep the native owner stable until its modal stack unwinds. Hiding
        // an owner also changes the visibility of its owned common dialog.
        _ = c.EnableWindow(self.hwnd, 0);
    } else _ = c.DestroyWindow(self.hwnd);
    self.hwnd = null;
}
pub fn fabrum_win32_create(p: *anyopaque, kind: abi.Kind, id: u64) ?*anyopaque {
    const self = w(p);
    const o = a.create(Control) catch return null;
    o.* = .{ .window = self, .kind = kind, .id = id };
    if (kind == .menu_item or kind == .alert) {
        if (kind == .menu_item) {
            if (self.next_command > 0xffff) {
                a.destroy(o);
                return null;
            }
            o.command = self.next_command;
            self.next_command += 1;
        }
        self.controls.append(a, o) catch {
            a.destroy(o);
            return null;
        };
        return o;
    }
    const class: [*:0]const u16 = switch (kind) {
        .button, .checkbox, .@"switch" => str("BUTTON"),
        .text_field, .text_area, .search_field, .secure_field => str("EDIT"),
        .label => str("EDIT"),
        .scroll_view => str("FabrumScroll"),
        .radio_group, .stepper => str("FabrumCompound"),
        .slider => str("msctls_trackbar32"),
        .progress, .spinner => str("msctls_progress32"),
        .dropdown => str("COMBOBOX"),
        else => {
            a.destroy(o);
            return null;
        },
    };
    const style: c.DWORD = @bitCast(@as(c_long, c.WS_CHILD | c.WS_VISIBLE | switch (kind) {
        .scroll_view => c.WS_CLIPCHILDREN | c.WS_CLIPSIBLINGS,
        .button => c.WS_TABSTOP | c.BS_PUSHBUTTON,
        .checkbox, .@"switch" => c.WS_TABSTOP | c.BS_AUTOCHECKBOX,
        .text_area => c.WS_TABSTOP | c.WS_BORDER | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.WS_VSCROLL,
        .text_field, .search_field => c.WS_TABSTOP | c.WS_BORDER | c.ES_AUTOHSCROLL,
        .secure_field => c.WS_TABSTOP | c.WS_BORDER | c.ES_PASSWORD | c.ES_AUTOHSCROLL,
        .label => c.ES_READONLY | c.ES_MULTILINE | c.ES_AUTOHSCROLL,
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
    if (kind == .scroll_view) {
        o.document = c.CreateWindowExW(0, str("FabrumScroll"), str(""), c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPCHILDREN | c.WS_CLIPSIBLINGS, 0, 0, 1, 1, o.hwnd, null, c.GetModuleHandleW(null), null);
        if (o.document == null) {
            _ = c.DestroyWindow(o.hwnd);
            a.destroy(o);
            return null;
        }
    }
    if (kind == .stepper) {
        const field = makePart(o, "EDIT", c.WS_TABSTOP | c.WS_BORDER | c.ES_AUTOHSCROLL, "", 0);
        const arrows = makePart(o, "msctls_updown32", c.UDS_ARROWKEYS, "", 1);
        if (field == null or arrows == null) {
            _ = c.DestroyWindow(o.hwnd);
            o.parts.deinit(a);
            a.destroy(o);
            return null;
        }
        _ = send(arrows, c.UDM_SETRANGE32, 0, 100);
        _ = send(arrows, c.UDM_SETPOS32, 0, 50);
    }
    applyControlTheme(o);
    updateFont(o);
    if (kind == .label) _ = send(o.hwnd, c.EM_SETMARGINS, c.EC_LEFTMARGIN | c.EC_RIGHTMARGIN, 0);
    _ = c.SetWindowSubclass(o.hwnd, controlProc, 1, @intFromPtr(o));
    self.controls.append(a, o) catch {
        _ = c.DestroyWindow(o.hwnd);
        if (o.font != null) _ = c.DeleteObject(o.font);
        o.parts.deinit(a);
        a.destroy(o);
        return null;
    };
    return o;
}
fn controlProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM, _: usize, data: usize) callconv(.winapi) c.LRESULT {
    if (labelColor(msg, wp, lp)) |result| return result;
    const o: *Control = @ptrFromInt(data);
    const self = o.window;
    const was_busy = enterRuntime(self);
    defer leaveRuntime(self, was_busy);
    switch (msg) {
        c.WM_GETDLGCODE => {
            if (o.kind == .label) return c.DLGC_WANTCHARS | c.DLGC_WANTARROWS;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => {
            if (o.kind == .label and (!o.selectable or !o.enabled)) return 0;
        },
        c.BM_CLICK => {
            if (o.kind == .radio_group and !o.enabled) return 0;
        },
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            if (c.GetParent(hwnd) != o.window.hwnd and o.kind != .scroll_view and o.kind != .text_area and o.kind != .dropdown) return send(c.GetParent(hwnd), msg, wp, lp);
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (!o.enabled) return 0;
            if (menuShortcut(o.window, msg, wp)) return 0;
            if (o.kind == .radio_group and o.parts.items.len > 0) {
                if (wp == c.VK_LEFT or wp == c.VK_UP or wp == c.VK_RIGHT or wp == c.VK_DOWN or wp == c.VK_SPACE) {
                    var index: usize = 0;
                    for (o.parts.items, 0..) |h, i| if (h == hwnd) {
                        index = i;
                        break;
                    };
                    if (wp == c.VK_LEFT or wp == c.VK_UP) index = (index + o.parts.items.len - 1) % o.parts.items.len;
                    if (wp == c.VK_RIGHT or wp == c.VK_DOWN) index = (index + 1) % o.parts.items.len;
                    fabrum_win32_set_selection(o, @intCast(index));
                    _ = c.SetFocus(o.parts.items[index]);
                    emit(o, .select, @floatFromInt(index));
                    return 0;
                }
            }
            if (o.kind == .stepper and (wp == c.VK_UP or wp == c.VK_DOWN)) {
                fabrum_win32_step(o, if (wp == c.VK_UP) 1 else -1);
                return 0;
            }
            if (wp == c.VK_TAB) {
                o.window.host.tab(o.window.host.ctx, if (c.GetKeyState(c.VK_SHIFT) < 0) 0 else 1);
                return 0;
            }
            if (wp == c.VK_RETURN and o.kind == .stepper) {
                commitStepper(o);
                return 0;
            }
            if (wp == c.VK_RETURN and o.kind != .text_area) {
                emit(o, .submit, 0);
                if (!o.window.host.enter(o.window.host.ctx)) {}
                return 0;
            }
        },
        c.WM_SETFOCUS => {
            const previous: c.HWND = @ptrFromInt(wp);
            if (previous != o.hwnd and c.IsChild(o.hwnd, previous) == 0) emit(o, .focus, 1);
            if (o.kind == .radio_group) {
                // BUTTON sends BN_CLICKED while processing WM_SETFOCUS for
                // BS_RADIOBUTTON. Focus alone is not a user selection, and
                // arrow navigation reports its selection explicitly below.
                const was_writing = o.writing;
                o.writing = true;
                defer o.writing = was_writing;
                return c.DefSubclassProc(hwnd, msg, wp, lp);
            }
        },
        c.WM_KILLFOCUS => {
            if (o.kind == .stepper and o.parts.items.len > 0 and hwnd == o.parts.items[0]) commitStepper(o);
            const next: c.HWND = @ptrFromInt(wp);
            if (next != o.hwnd and c.IsChild(o.hwnd, next) == 0) emit(o, .focus, 0);
        },
        c.WM_IME_STARTCOMPOSITION => o.composing = true,
        c.WM_IME_ENDCOMPOSITION => {
            o.composing = false;
            const result = c.DefSubclassProc(hwnd, msg, wp, lp);
            if (o.kind == .stepper) commitStepper(o) else textEvent(o);
            emit(o, .composition_end, 0);
            return result;
        },
        else => {},
    }
    return c.DefSubclassProc(hwnd, msg, wp, lp);
}
pub fn fabrum_win32_destroy(p: *anyopaque) void {
    const o = control(p);
    if (o.dialog) |d| {
        d.owner = null;
        finishDialog(d, -1);
    }
    for (o.window.controls.items, 0..) |other, i| if (other == o) {
        _ = o.window.controls.orderedRemove(i);
        break;
    };
    if (!o.window.closed) {
        if (o.document != null) {
            while (c.GetWindow(o.document, c.GW_CHILD)) |child| {
                _ = c.ShowWindow(child, c.SW_HIDE);
                _ = c.SetParent(child, o.window.hwnd);
            }
        }
        _ = c.DestroyWindow(o.hwnd);
    }
    if (o.kind == .menu_item) rebuildMenu(o.window);
    if (o.font != null) {
        // A native modal service may retain the detached owner and its HWND
        // children after the runtime releases their wrappers. Stop borrowing
        // the owned font before freeing it in that path as well.
        if (o.window.closed and c.IsWindow(o.hwnd) != 0) {
            const stock = @intFromPtr(c.GetStockObject(c.DEFAULT_GUI_FONT));
            _ = send(o.hwnd, c.WM_SETFONT, stock, 0);
            for (o.parts.items) |h| if (c.IsWindow(h) != 0) {
                _ = send(h, c.WM_SETFONT, stock, 0);
            };
        }
        _ = c.DeleteObject(o.font);
    }
    o.parts.deinit(a);
    a.free(o.title);
    a.free(o.message);
    a.free(o.key);
    if (o.menu_group) |g| a.free(g);
    for (o.alert_buttons.items) |b| a.free(b);
    o.alert_buttons.deinit(a);
    a.destroy(o);
}
pub fn fabrum_win32_set_title(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const o = control(p);
    if (o.kind == .menu_item or o.kind == .alert) {
        replaceString(&o.title, bytes[0..len]);
        if (o.kind == .menu_item) rebuildMenu(o.window);
        return;
    }
    const s = wide(bytes[0..len]);
    defer a.free(s);
    const old = windowText(o.hwnd);
    defer a.free(old);
    if (std.mem.eql(u16, old, s)) return;
    var first: c.DWORD = 0;
    var last: c.DWORD = 0;
    const edit = o.kind == .label or o.kind == .text_field or o.kind == .text_area or o.kind == .search_field or o.kind == .secure_field;
    if (edit) _ = send(o.hwnd, c.EM_GETSEL, @intFromPtr(&first), @bitCast(@intFromPtr(&last)));
    _ = c.SetWindowTextW(o.hwnd, s.ptr);
    if (edit) _ = send(o.hwnd, c.EM_SETSEL, @min(first, s.len), @intCast(@min(last, s.len)));
}
pub fn fabrum_win32_set_text(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const o = control(p);
    o.writing = true;
    defer o.writing = false;
    fabrum_win32_set_title(p, bytes, len);
}
pub fn fabrum_win32_set_enabled(p: *anyopaque, enabled: bool) void {
    const o = control(p);
    o.enabled = enabled;
    if (o.kind == .menu_item) {
        rebuildMenu(o.window);
        return;
    }
    _ = c.EnableWindow(o.hwnd, @intFromBool(enabled));
    for (o.parts.items) |h| _ = c.EnableWindow(h, @intFromBool(enabled));
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
    o.min = if (std.math.isFinite(min)) min else 0;
    o.max = if (std.math.isFinite(max)) @max(o.min, max) else o.min;
    if (o.kind == .stepper) {
        // A spec-only update must not replace the user's uncommitted edit.
        if (o.value < o.min or o.value > o.max) fabrum_win32_set_number(o, o.value);
        return;
    }
    _ = send(o.hwnd, c.TBM_SETRANGEMIN, 0, 0);
    _ = send(o.hwnd, c.TBM_SETRANGEMAX, 1, 10000);
}
pub fn fabrum_win32_set_increment(p: *anyopaque, step: f64) void {
    control(p).step = if (std.math.isFinite(step) and step > 0) step else 1;
}
pub fn fabrum_win32_set_bool(p: *anyopaque, on: bool) void {
    _ = send(control(p).hwnd, c.BM_SETCHECK, if (on) c.BST_CHECKED else c.BST_UNCHECKED, 0);
}
pub fn fabrum_win32_set_number(p: *anyopaque, value: f64) void {
    const o = control(p);
    o.value = if (std.math.isFinite(value)) std.math.clamp(value, o.min, o.max) else o.min;
    if (o.kind == .stepper) {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{o.value}) catch return;
        const text_w = wide(text);
        defer a.free(text_w);
        o.writing = true;
        defer o.writing = false;
        _ = c.SetWindowTextW(o.parts.items[0], text_w.ptr);
        return;
    }
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
    const o = control(p);
    if (o.kind == .radio_group) {
        const self = o.window;
        const was_busy = enterRuntime(self);
        defer leaveRuntime(self, was_busy);
        const focused = c.GetFocus();
        const restore_focus = focused == o.hwnd or c.IsChild(o.hwnd, focused) != 0;
        var focused_index: ?usize = null;
        for (o.parts.items, 0..) |part, i| if (part == focused) {
            focused_index = i;
            break;
        };
        o.writing = true;
        defer o.writing = false;
        for (o.parts.items) |part| _ = c.DestroyWindow(part);
        o.parts.clearRetainingCapacity();
        for (0..count) |i| _ = makePart(o, "BUTTON", c.BS_RADIOBUTTON | c.WS_TABSTOP, titles[i][0..lengths[i]], i);
        fabrum_win32_set_selection(o, o.selection);
        layoutParts(o);
        if (restore_focus) {
            const replacement = if (focused_index) |i| (if (i < o.parts.items.len) o.parts.items[i] else focusHwnd(o)) else focusHwnd(o);
            _ = c.SetFocus(if (o.parts.items.len > 0) replacement else o.window.hwnd);
            if (o.parts.items.len == 0) {
                // The group no longer has a focusable native part.
                self.events.append(a, .{ .id = o.id, .kind = .focus, .number = 0 }) catch @panic("out of memory");
            }
        }
        return;
    }
    const h = o.hwnd;
    _ = send(h, c.CB_RESETCONTENT, 0, 0);
    for (0..count) |i| {
        const s = wide(titles[i][0..lengths[i]]);
        defer a.free(s);
        _ = send(h, c.CB_ADDSTRING, 0, @bitCast(@intFromPtr(s.ptr)));
    }
}
pub fn fabrum_win32_set_selection(p: *anyopaque, index: c_long) void {
    const o = control(p);
    if (o.kind == .radio_group) {
        o.selection = if (index >= 0 and index < o.parts.items.len) index else -1;
        for (o.parts.items, 0..) |h, i| {
            _ = send(h, c.BM_SETCHECK, if (o.selection == i) c.BST_CHECKED else c.BST_UNCHECKED, 0);
            const style = c.GetWindowLongPtrW(h, c.GWL_STYLE);
            const tab = if (o.selection >= 0) o.selection == i else i == 0;
            _ = c.SetWindowLongPtrW(h, c.GWL_STYLE, if (tab) style | c.WS_TABSTOP else style & ~@as(isize, c.WS_TABSTOP));
        }
        return;
    }
    _ = send(o.hwnd, c.CB_SETCURSEL, @bitCast(@as(isize, index)), 0);
}
pub fn fabrum_win32_reparent(p: *anyopaque, parent: ?*anyopaque) void {
    const o = control(p);
    if (o.kind == .menu_item or o.kind == .alert) return;
    const hwnd = if (parent) |h| control(h).document else o.window.hwnd;
    if (c.GetParent(o.hwnd) != hwnd) {
        const focused = c.GetFocus();
        const restore = focused == o.hwnd or c.IsChild(o.hwnd, focused) != 0;
        _ = c.SetParent(o.hwnd, hwnd);
        if (restore) _ = c.SetFocus(focused);
    }
}
pub fn fabrum_win32_set_frame(p: *anyopaque, x: f64, y: f64, width: f64, height: f64) void {
    const o = control(p);
    if (o.kind == .menu_item or o.kind == .alert) return;
    const scale = dpi(o.window.hwnd);
    _ = c.SetWindowPos(o.hwnd, null, int(x * scale), int(y * scale), int(width * scale), int((height + @as(f64, if (o.kind == .dropdown) 200 else 0)) * scale), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}
pub fn fabrum_win32_fitting_size(p: *anyopaque, max_width: f64, width: *f64, height: *f64) void {
    const o = control(p);
    const scale = dpi(o.window.hwnd);
    var size = textSize(o.hwnd, if (o.kind == .label and o.wrap) max_width * scale else 0, o.kind == .label and o.wrap, o.kind == .label);
    if (o.kind == .radio_group) {
        size = .{ .cx = 0, .cy = 0 };
        for (o.parts.items) |h| {
            const item = buttonSize(h);
            if (o.horizontal) {
                size.cx += item.cx;
                size.cy = @max(size.cy, item.cy);
            } else {
                size.cx = @max(size.cx, item.cx);
                size.cy += item.cy;
            }
        }
    } else switch (o.kind) {
        .button, .checkbox, .@"switch" => size = buttonSize(o.hwnd),
        .label => {},
        .text_area => {
            size.cx = @max(size.cx, int(160 * scale));
            size.cy = @max(size.cy, int(100 * scale));
        },
        .dropdown => {
            var longest = size.cx;
            const count = send(o.hwnd, c.CB_GETCOUNT, 0, 0);
            var i: usize = 0;
            while (i < @as(usize, @intCast(@max(count, 0)))) : (i += 1) {
                const len = send(o.hwnd, c.CB_GETLBTEXTLEN, i, 0);
                if (len < 0) continue;
                const text = a.allocSentinel(u16, @intCast(len), 0) catch @panic("out of memory");
                defer a.free(text);
                _ = send(o.hwnd, c.CB_GETLBTEXT, i, @bitCast(@intFromPtr(text.ptr)));
                longest = @max(longest, measureText(o.hwnd, text, 0, false, false).cx);
            }
            size.cx = longest + c.GetSystemMetricsForDpi(c.SM_CXVSCROLL, c.GetDpiForWindow(o.hwnd)) + int(12 * scale);
            size.cy += int(10 * scale);
        },
        else => {
            size.cx = @max(size.cx + int(16 * scale), int(160 * scale));
            size.cy = @max(size.cy + int(10 * scale), int(26 * scale));
        },
    }
    width.* = @as(f64, @floatFromInt(size.cx)) / scale;
    height.* = @as(f64, @floatFromInt(size.cy)) / scale;
    if (max_width > 0) width.* = @min(max_width, width.*);
}
pub fn fabrum_win32_is_composing(p: *anyopaque) bool {
    return control(p).composing;
}
pub fn fabrum_win32_can_focus(p: *anyopaque) bool {
    const o = control(p);
    return o.kind != .menu_item and o.kind != .alert and (o.kind != .radio_group or o.parts.items.len > 0) and o.kind != .scroll_view and (o.kind != .label or o.selectable) and o.kind != .progress and o.kind != .spinner and c.IsWindowEnabled(o.hwnd) != 0;
}
pub fn fabrum_win32_focus(p: *anyopaque, handle: ?*anyopaque, canvas: c_int) void {
    const self = w(p);
    _ = c.SetFocus(if (handle) |h| focusHwnd(control(h)) else if (canvas != 0 and self.layers.items.len > 0) self.layers.items[0].hwnd else self.hwnd);
}
pub fn fabrum_win32_arrange(p: *anyopaque, container: ?*anyopaque, slots: [*]const abi.CSlot, count: usize) void {
    const self = w(p);
    if (container == null) for (self.layers.items) |l| {
        l.active = false;
        _ = c.KillTimer(l.hwnd, 1);
        _ = c.ShowWindow(l.hwnd, c.SW_HIDE);
    };
    const parent = if (container) |h| control(h).document else self.hwnd;
    var r: c.RECT = undefined;
    _ = c.GetClientRect(parent, &r);
    for (0..count) |i| {
        const slot = slots[i];
        if (slot.widget) |h| {
            if (control(h).kind == .menu_item or control(h).kind == .alert) continue;
        }
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
            if (c.GetParent(l.hwnd) != parent) _ = c.SetParent(l.hwnd, parent);
            l.active = true;
            _ = c.ShowWindow(l.hwnd, c.SW_SHOWNA);
            schedulePaint(l);
            _ = c.SetWindowPos(l.hwnd, null, 0, 0, r.right, r.bottom, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            break :blk l.hwnd;
        };
        if (c.GetParent(hwnd) != parent) _ = c.SetParent(hwnd, parent);
        _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
        _ = c.SetWindowPos(hwnd, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
}
pub fn fabrum_win32_damage_layer(p: *anyopaque, layer: c_uint, _: f64, _: f64, _: f64, _: f64) void {
    const self = w(p);
    if (layer < self.layers.items.len) schedulePaint(self.layers.items[layer]);
}
pub fn fabrum_win32_theme(p: *anyopaque, out: *abi.CTheme) void {
    const colors = w(p).palette;
    const rgba = theme.colors.rgba;
    out.* = .{ .accent = rgba(colors.accent), .text = rgba(colors.text), .secondary_text = rgba(colors.secondary), .window_background = rgba(colors.background), .control_background = rgba(colors.control), .separator = rgba(colors.separator), .focus_ring = rgba(colors.accent), .font_size = 12, .control_height = 26, .full_keyboard_access = 1, .dark = @intFromBool(colors.dark) };
}
fn refreshTheme(self: *Window) void {
    self.palette = if (self.theme_test) |test_input| theme.colors.resolve(self.options.dark != 0, test_input.high_contrast, test_input.system) else theme.palette(self.options.dark != 0);
    theme.frame(self.hwnd, self.palette.dark);
    for (self.controls.items) |o| applyControlTheme(o);
    for (dialogs.items) |d| if (d.window == self) {
        theme.frame(d.hwnd, self.palette.dark);
        updateDialogFont(d);
        layoutDialog(d);
        _ = c.RedrawWindow(d.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
    };
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}
fn applyControlTheme(o: *Control) void {
    // The themed checkbox/radio renderer ignores custom text colors. The
    // documented empty theme disables visual styles for these HWNDs only,
    // retaining native input/focus/accessibility with readable dark text.
    if (o.kind != .checkbox and o.kind != .@"switch" and o.kind != .radio_group) return;
    const value = if (o.window.palette.dark) str("") else null;
    _ = c.SetWindowTheme(o.hwnd, value, value);
    for (o.parts.items) |part| _ = c.SetWindowTheme(part, value, value);
}
/// Local automation seam; never writes a Windows preference or broadcasts.
pub fn testTheme(p: *anyopaque, system: ?theme.colors.Palette, high_contrast: bool, font_points: f64) void {
    const self = w(p);
    self.theme_test = if (system) |value| .{ .system = value, .high_contrast = high_contrast } else null;
    self.dialog_font_points = if (std.math.isFinite(font_points) and font_points > 0) font_points else 0;
    refreshTheme(self);
    request_frame(self);
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
    _ = send(textHwnd(control(p)), c.EM_REPLACESEL, 1, @bitCast(@intFromPtr(s.ptr)));
}
pub fn fabrum_win32_text(p: *anyopaque, out: [*]u8, cap: usize) usize {
    const h = textHwnd(control(p));
    const n = c.GetWindowTextLengthW(h);
    const b = a.allocSentinel(u16, @intCast(@max(n, 0)), 0) catch return 0;
    defer a.free(b);
    _ = c.GetWindowTextW(h, b.ptr, @intCast(b.len + 1));
    const utf = std.unicode.utf16LeToUtf8Alloc(a, b) catch return 0;
    defer a.free(utf);
    const len = @min(cap, utf.len);
    @memcpy(out[0..len], utf[0..len]);
    return len;
}
pub fn fabrum_win32_newline(p: *anyopaque) void {
    if (control(p).kind == .stepper) {
        commitStepper(control(p));
        return;
    }
    emit(control(p), .submit, 0);
}
pub fn fabrum_win32_slide(p: *anyopaque, value: f64) void {
    if (control(p).kind == .stepper and !control(p).enabled) return;
    fabrum_win32_set_number(p, value);
    emit(control(p), .number, control(p).value);
}
pub fn fabrum_win32_select(p: *anyopaque, index: c_long) void {
    const o = control(p);
    if (o.kind == .radio_group and (!o.enabled or index < 0 or index >= o.parts.items.len)) return;
    fabrum_win32_set_selection(p, index);
    emit(control(p), .select, @floatFromInt(index));
}
pub fn fabrum_win32_step(p: *anyopaque, steps: c_long) void {
    const o = control(p);
    if (!o.enabled) return;
    const old = o.value;
    const base = if (o.kind == .stepper) readStepperValue(o) else old;
    fabrum_win32_set_number(p, std.math.clamp(base + @as(f64, @floatFromInt(steps)) * o.step, o.min, o.max));
    if (o.value != old) emit(o, .number, o.value);
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
const Dialog = struct { window: *Window, hwnd: c.HWND = null, font: c.HFONT = null, scroll_y: c_int = 0, default_index: usize = 0, button_count: usize = 0, callback: ?abi.IndexCallback = null, ctx: ?*anyopaque = null, owner: ?*Control = null, modal: bool = false, previous_focus: c.HWND = null };
var dialogs: std.ArrayList(*Dialog) = .empty;
fn updateDialogFont(d: *Dialog) void {
    const font = theme.font(d.hwnd, d.window.dialog_font_points) orelse return;
    const old = d.font;
    d.font = font;
    var child = c.GetWindow(d.hwnd, c.GW_CHILD);
    while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) _ = send(child, c.WM_SETFONT, @intFromPtr(font), 1);
    if (old != null) _ = c.DeleteObject(old);
}
fn layoutDialog(d: *Dialog) void {
    const scale = dpi(d.hwnd);
    const margin = int(20 * scale);
    const gap = int(10 * scale);
    var button_width = int(120 * scale);
    var button_height = int(28 * scale);
    for (0..d.button_count) |i| {
        const size = buttonSize(c.GetDlgItem(d.hwnd, @intCast(100 + i)));
        button_width = @max(button_width, size.cx);
        button_height = @max(button_height, size.cy);
    }
    var monitor = std.mem.zeroes(c.MONITORINFO);
    monitor.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(c.MonitorFromWindow(d.hwnd, c.MONITOR_DEFAULTTONEAREST), &monitor) == 0) return;
    const work = monitor.rcWork;
    var chrome = c.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = c.AdjustWindowRectExForDpi(&chrome, c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL, 0, c.WS_EX_DLGMODALFRAME, c.GetDpiForWindow(d.hwnd));
    const columns: c_int = @intCast(@min(3, d.button_count));
    const max_width = @max(1, work.right - work.left - (chrome.right - chrome.left) - 2 * margin);
    const width = @min(max_width, @max(int(420 * scale), columns * button_width + @max(0, columns - 1) * gap));
    button_width = @min(button_width, @max(1, @divTrunc(width - @max(0, columns - 1) * gap, @max(1, columns))));
    const body = c.GetDlgItem(d.hwnd, 99);
    const rows: c_int = @intCast((d.button_count + 2) / 3);
    const reserved = 3 * margin + rows * button_height + @max(0, rows - 1) * gap + chrome.bottom - chrome.top;
    const max_client_height = @max(1, work.bottom - work.top - (chrome.bottom - chrome.top));
    const body_height = @min(@max(int(80 * scale), work.bottom - work.top - reserved), @max(int(80 * scale), textSize(body, @floatFromInt(width), true, true).cy));
    const content_height = body_height + 3 * margin + rows * button_height + @max(0, rows - 1) * gap;
    const client_height = @min(content_height, max_client_height);
    d.scroll_y = std.math.clamp(d.scroll_y, 0, @max(0, content_height - client_height));
    _ = c.SetWindowPos(body, null, margin, margin - d.scroll_y, width, body_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    for (0..d.button_count) |i| {
        _ = c.SetWindowPos(c.GetDlgItem(d.hwnd, @intCast(100 + i)), null, margin + @as(c_int, @intCast(i % 3)) * (button_width + gap), margin + body_height + margin + @as(c_int, @intCast(i / 3)) * (button_height + gap) - d.scroll_y, button_width, button_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    var rect = c.RECT{ .left = 0, .top = 0, .right = width + 2 * margin, .bottom = client_height };
    _ = c.AdjustWindowRectExForDpi(&rect, c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL, 0, c.WS_EX_DLGMODALFRAME, c.GetDpiForWindow(d.hwnd));
    var current: c.RECT = undefined;
    _ = c.GetWindowRect(d.hwnd, &current);
    const outer_width = rect.right - rect.left;
    const outer_height = rect.bottom - rect.top;
    _ = c.SetWindowPos(d.hwnd, null, std.math.clamp(current.left, work.left, @max(work.left, work.right - outer_width)), std.math.clamp(current.top, work.top, @max(work.top, work.bottom - outer_height)), outer_width, outer_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    var info = std.mem.zeroes(c.SCROLLINFO);
    info.cbSize = @sizeOf(c.SCROLLINFO);
    info.fMask = c.SIF_RANGE | c.SIF_PAGE | c.SIF_POS;
    info.nMax = content_height - 1;
    info.nPage = @intCast(client_height);
    info.nPos = d.scroll_y;
    _ = c.SetScrollInfo(d.hwnd, c.SB_VERT, &info, 1);
    _ = c.ShowScrollBar(d.hwnd, c.SB_VERT, @intFromBool(content_height > client_height));
    _ = c.InvalidateRect(d.hwnd, null, 1);
}
fn dialogProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const d = object(hwnd, Dialog) orelse return c.DefWindowProcW(hwnd, msg, wp, lp);
    if (msg == c.WM_SETTINGCHANGE or msg == c.WM_SYSCOLORCHANGE or msg == c.WM_THEMECHANGED) {
        refreshTheme(d.window);
        request_frame(d.window);
        return 0;
    }
    if (msg == c.WM_ERASEBKGND) return theme.erase(hwnd, @ptrFromInt(wp), d.window.palette.background);
    if (msg == c.WM_CTLCOLORSTATIC) return theme.controlColor(@ptrFromInt(wp), d.window.palette.background, d.window.palette.text);
    if (msg == c.WM_DPICHANGED) {
        const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        updateDialogFont(d);
        layoutDialog(d);
        return 0;
    }
    if (msg == c.DM_GETDEFID) return @intCast((c.DC_HASDEFID << 16) | (100 + d.default_index));
    if (msg == c.DM_SETDEFID) {
        if (wp >= 100 and wp < 100 + d.button_count) d.default_index = wp - 100;
        return 0;
    }
    if (msg == c.WM_COMMAND) {
        const id = wp & 0xffff;
        const code = (wp >> 16) & 0xffff;
        if ((id >= 100 and id < 100 + d.button_count and code == c.BN_SETFOCUS) or (id == 99 and code == c.EN_SETFOCUS)) {
            var rect: c.RECT = undefined;
            _ = c.GetWindowRect(c.GetDlgItem(hwnd, @intCast(id)), &rect);
            _ = c.MapWindowPoints(null, hwnd, @ptrCast(&rect), 2);
            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            if (rect.top < 0 or rect.bottom > client.bottom) {
                d.scroll_y += if (rect.top < 0) rect.top - int(10 * dpi(hwnd)) else rect.bottom - client.bottom + int(10 * dpi(hwnd));
                layoutDialog(d);
            }
        } else if (id >= 100 and id < 100 + d.button_count and code == c.BN_CLICKED) finishDialog(d, @intCast(id - 100)) else if (id == c.IDCANCEL) finishDialog(d, -1);
        return 0;
    }
    if (msg == c.WM_VSCROLL or msg == c.WM_MOUSEWHEEL) {
        var info = std.mem.zeroes(c.SCROLLINFO);
        info.cbSize = @sizeOf(c.SCROLLINFO);
        info.fMask = c.SIF_ALL;
        _ = c.GetScrollInfo(hwnd, c.SB_VERT, &info);
        const line = int(40 * dpi(hwnd));
        d.scroll_y = if (msg == c.WM_MOUSEWHEEL) d.scroll_y - int(signedWord(wp >> 16) / 120 * @as(f64, @floatFromInt(line))) else switch (wp & 0xffff) {
            c.SB_LINEUP => d.scroll_y - line,
            c.SB_LINEDOWN => d.scroll_y + line,
            c.SB_PAGEUP => d.scroll_y - @as(c_int, @intCast(info.nPage)),
            c.SB_PAGEDOWN => d.scroll_y + @as(c_int, @intCast(info.nPage)),
            c.SB_TOP => 0,
            c.SB_BOTTOM => info.nMax,
            c.SB_THUMBTRACK, c.SB_THUMBPOSITION => info.nTrackPos,
            else => d.scroll_y,
        };
        layoutDialog(d);
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
    const owner = d.owner;
    const self = d.window;
    const was_busy = enterRuntime(self);
    defer leaveRuntime(self, was_busy);
    const modal = d.modal;
    const previous_focus = d.previous_focus;
    var top_modal: ?*Dialog = null;
    for (dialogs.items) |other| if (other.window == self and other.modal) {
        top_modal = other;
    };
    const was_top_modal = top_modal == d;
    if (owner) |o| {
        o.dialog = null;
        o.answered = true;
    }
    for (dialogs.items, 0..) |other, i| if (other == d) {
        _ = dialogs.orderedRemove(i);
        break;
    };
    // A covered dialog can be removed before the dialogs above it. Preserve
    // their eventual focus return path without activating any of them now.
    for (dialogs.items) |other| if (other.window == self and (other.previous_focus == d.hwnd or c.IsChild(d.hwnd, other.previous_focus) != 0)) {
        other.previous_focus = previous_focus;
    };
    _ = c.DestroyWindow(d.hwnd);
    if (d.font != null) _ = c.DeleteObject(d.font);
    a.destroy(d);
    if (modal and was_top_modal and !self.closed) {
        var another: c.HWND = null;
        for (dialogs.items) |other| if (other.window == self and other.modal) {
            another = other.hwnd;
        };
        if (another != null) {
            _ = c.EnableWindow(another, 1);
            _ = c.SetActiveWindow(another);
            _ = c.SetFocus(c.GetDlgItem(another, 100));
        } else {
            _ = c.EnableWindow(self.hwnd, 1);
            _ = c.SetActiveWindow(self.hwnd);
            _ = c.SetFocus(if (c.IsWindow(previous_focus) != 0 and c.IsWindowEnabled(previous_focus) != 0) previous_focus else self.hwnd);
        }
    }
    if (owner) |o| {
        // Closing/cancelling dismisses the declaration without inventing a
        // button index. Destruction detaches owner before coming here.
        if (index >= 0 and index < o.alert_buttons.items.len) emit(o, .response, @floatFromInt(index));
    }
    if (callback) |done| done(ctx, index);
}
fn dialog(p: *anyopaque, title: []const u8, text: []const u8, buttons: []const []const u8, callback: ?abi.IndexCallback, ctx: ?*anyopaque, timeout: c_uint, default_index: usize, owner: ?*Control) void {
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
    d.* = .{ .window = w(p), .callback = callback, .ctx = ctx, .default_index = default_index, .button_count = buttons.len, .owner = owner, .modal = owner != null, .previous_focus = c.GetFocus() };
    const t = wide(title);
    defer a.free(t);
    const body = wide(text);
    defer a.free(body);
    const scale = dpi(w(p).hwnd);
    const rows = (buttons.len + 2) / 3;
    d.hwnd = c.CreateWindowExW(c.WS_EX_DLGMODALFRAME, str("FabrumDialog"), t.ptr, c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_VSCROLL, c.CW_USEDEFAULT, c.CW_USEDEFAULT, int(460 * scale), int((200 + @as(f64, @floatFromInt(rows -| 1)) * 40) * scale), w(p).hwnd, null, c.GetModuleHandleW(null), null);
    if (d.hwnd == null) {
        a.destroy(d);
        if (callback) |done| done(ctx, -1);
        return;
    }
    _ = c.SetWindowLongPtrW(d.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(d)));
    const body_hwnd = c.CreateWindowExW(0, str("EDIT"), body.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_READONLY | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.WS_VSCROLL, int(20 * scale), int(20 * scale), int(410 * scale), int(80 * scale), d.hwnd, null, c.GetModuleHandleW(null), null);
    _ = c.SetWindowLongPtrW(body_hwnd, c.GWLP_ID, 99);
    for (buttons, 0..) |button, i| {
        const b = wide(button);
        defer a.free(b);
        const button_hwnd = c.CreateWindowExW(0, str("BUTTON"), b.ptr, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON | c.BS_NOTIFY, int((20 + @as(f64, @floatFromInt(i % 3)) * 130) * scale), int((115 + @as(f64, @floatFromInt(i / 3)) * 40) * scale), int(120 * scale), int(28 * scale), d.hwnd, null, c.GetModuleHandleW(null), null);
        _ = c.SetWindowLongPtrW(button_hwnd, c.GWLP_ID, @intCast(100 + i));
    }
    updateDialogFont(d);
    layoutDialog(d);
    theme.frame(d.hwnd, d.window.palette.dark);
    const default_button = c.GetDlgItem(d.hwnd, @intCast(100 + default_index));
    _ = send(default_button, c.BM_SETSTYLE, c.BS_DEFPUSHBUTTON, 1);
    _ = send(d.hwnd, c.DM_SETDEFID, 100 + default_index, 0);
    if (owner) |o| {
        for (dialogs.items) |other| if (other.window == o.window and other.modal) {
            _ = c.EnableWindow(other.hwnd, 0);
        };
        o.dialog = d;
        _ = c.EnableWindow(d.window.hwnd, 0);
    }
    dialogs.append(a, d) catch @panic("out of memory");
    if (timeout > 0) _ = c.SetTimer(d.hwnd, 1, timeout, null);
    _ = c.ShowWindow(d.hwnd, c.SW_SHOW);
    _ = c.SetFocus(default_button);
}
pub fn fabrum_win32_message(p: *anyopaque, title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, _: c_int, timeout: c_uint) void {
    dialog(p, title[0..title_len], text[0..text_len], &.{"OK"}, null, null, timeout, 0, null);
}
pub fn fabrum_win32_confirm(p: *anyopaque, title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, buttons: [*]const [*]const u8, lengths: [*]const usize, count: usize, default_index: usize, _: c_int, done: abi.IndexCallback, ctx: ?*anyopaque) void {
    var items: [3][]const u8 = undefined;
    for (0..count) |i| items[i] = buttons[i][0..lengths[i]];
    dialog(p, title[0..title_len], text[0..text_len], items[0..count], done, ctx, 0, @min(default_index, count - 1), null);
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
pub fn fabrum_win32_set_label_style(p: *anyopaque, wrap: bool, selectable: bool, font_size: f64, secondary: bool) void {
    const o = control(p);
    if (o.wrap != wrap) replaceLabelWindow(o, wrap);
    o.wrap = wrap;
    o.selectable = selectable;
    o.secondary = secondary;
    const size = if (std.math.isFinite(font_size) and font_size > 0) font_size else 0;
    if (size != o.font_size) {
        o.font_size = size;
        updateFont(o);
    }
    var style = c.GetWindowLongPtrW(o.hwnd, c.GWL_STYLE);
    style &= ~@as(isize, c.WS_TABSTOP | c.ES_AUTOHSCROLL);
    if (selectable) style |= c.WS_TABSTOP;
    if (!wrap) style |= c.ES_AUTOHSCROLL;
    _ = c.SetWindowLongPtrW(o.hwnd, c.GWL_STYLE, style);
    _ = c.SetWindowPos(o.hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED);
    _ = c.InvalidateRect(o.hwnd, null, 1);
}
pub fn fabrum_win32_set_horizontal(p: *anyopaque, horizontal: bool) void {
    const o = control(p);
    o.horizontal = horizontal;
    layoutParts(o);
}
pub fn fabrum_win32_set_message(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    replaceString(&control(p).message, bytes[0..len]);
}
pub fn fabrum_win32_add_button(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const text = a.dupe(u8, bytes[0..len]) catch @panic("out of memory");
    control(p).alert_buttons.append(a, text) catch @panic("out of memory");
}
pub fn fabrum_win32_show_alert(p: *anyopaque) void {
    const o = control(p);
    if (o.dialog != null or o.answered or o.window.closed) return;
    dialog(o.window, o.title, o.message, o.alert_buttons.items, null, null, 0, 0, o);
}
pub fn fabrum_win32_place_menu_item(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const o = control(p);
    const group = bytes[0..len];
    if (o.menu_group) |old| {
        if (std.mem.eql(u8, old, group)) return;
        a.free(old);
    }
    o.menu_group = a.dupe(u8, group) catch @panic("out of memory");
    rebuildMenu(o.window);
}
pub fn fabrum_win32_set_key_equivalent(p: *anyopaque, bytes: [*]const u8, len: usize) void {
    const o = control(p);
    replaceString(&o.key, bytes[0..len]);
    rebuildMenu(o.window);
}
pub fn fabrum_win32_set_scroll_axes(p: *anyopaque, horizontal: bool, vertical: bool) void {
    const o = control(p);
    o.horizontal = horizontal;
    o.vertical = vertical;
    updateScroll(o, o.scroll_x, o.scroll_y);
}
pub fn fabrum_win32_set_content_size(p: *anyopaque, width: f64, height: f64) void {
    const o = control(p);
    o.content_width = @max(0, width);
    o.content_height = @max(0, height);
    updateScroll(o, o.scroll_x, o.scroll_y);
}
pub fn fabrum_win32_scroll_to(p: *anyopaque, x: f64, y: f64) void {
    updateScroll(control(p), x, y);
}
pub fn controlHwnd(p: *anyopaque) c.HWND {
    return control(p).hwnd;
}
pub fn fabrum_win32_snapshot(_: *anyopaque, _: [*:0]const u8, _: f64) bool {
    return false;
}
pub fn fabrum_win32_describe_focus(p: *anyopaque, out: [*]u8, cap: usize) usize {
    const self = w(p);
    const h = c.GetFocus();
    const s: []const u8 = blk: {
        if (h == self.hwnd) break :blk "window";
        for (self.controls.items) |o| if (o.hwnd == h or (o.hwnd != null and c.IsChild(o.hwnd, h) != 0)) {
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
pub fn popupMenu(p: *anyopaque, request: *const platform.MenuRequest, callback: abi.PopupCallback, ctx: ?*anyopaque) platform.Services.Error!void {
    if (w(p).closed) return error.ServiceFailed;
    try services.popupMenu(p, w(p).hwnd, request, callback, ctx);
}
pub fn openFile(p: *anyopaque, request: *const platform.FileRequest, directory: bool, callback: abi.TextCallback, ctx: ?*anyopaque) platform.Services.Error!void {
    if (w(p).closed) return error.ServiceFailed;
    try services.openFile(p, w(p).hwnd, request, directory, callback, ctx);
}
pub fn fabrum_win32_answer_popup(p: *anyopaque, id: ?usize) bool {
    return services.answerPopup(p, id);
}
pub fn fabrum_win32_answer_open_panel(p: *anyopaque, path: ?[*:0]const u8) bool {
    return services.answerFile(p, path);
}
pub fn fabrum_win32_choose_menu(p: *anyopaque, group: [*:0]const u8, title: [*:0]const u8) bool {
    for (w(p).controls.items) |o| if (o.kind == .menu_item and o.enabled and o.menu_group != null and std.mem.eql(u8, o.menu_group.?, std.mem.span(group)) and std.mem.eql(u8, o.title, std.mem.span(title))) {
        emit(o, .activate, 0);
        return true;
    };
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
    if (menuShortcut(self, msg, vk)) return true;
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

const QueuedEvent = struct { id: u64, kind: abi.EventKind, number: f64, text: ?[]u8 = null, scroll_y: ?f64 = null };
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
        if (event.scroll_y) |y| {
            for (self.controls.items) |o| {
                if (o.id == event.id and o.kind == .scroll_view) {
                    self.host.scroll(self.host.ctx, event.id, event.number, y);
                    break;
                }
            }
        } else self.host.event(self.host.ctx, event.id, event.kind, event.number, if (event.text) |t| t.ptr else null, if (event.text) |t| t.len else 0);
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
fn replaceString(target: *[]const u8, value: []const u8) void {
    const owned = a.dupe(u8, value) catch @panic("out of memory");
    a.free(target.*);
    target.* = owned;
}
fn focusHwnd(o: *Control) c.HWND {
    if (o.parts.items.len > 0) {
        const index: usize = if (o.kind == .radio_group and o.selection >= 0) @intCast(o.selection) else 0;
        return o.parts.items[index];
    }
    return o.hwnd;
}
fn textHwnd(o: *Control) c.HWND {
    return if (o.kind == .stepper and o.parts.items.len > 0) o.parts.items[0] else o.hwnd;
}
fn makePart(o: *Control, comptime class: []const u8, style: c_long, title: []const u8, index: usize) c.HWND {
    const text = wide(title);
    defer a.free(text);
    const h = c.CreateWindowExW(0, str(class), text.ptr, @bitCast(@as(c_long, c.WS_CHILD | c.WS_VISIBLE | style)), 0, 0, 1, 1, o.hwnd, null, c.GetModuleHandleW(null), null);
    if (h == null) return null;
    _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, @bitCast(@intFromPtr(o)));
    _ = c.SetWindowLongPtrW(h, c.GWLP_ID, @intCast(100 + index));
    _ = send(h, c.WM_SETFONT, @intFromPtr(o.font orelse c.GetStockObject(c.DEFAULT_GUI_FONT)), 1);
    _ = c.SetWindowSubclass(h, controlProc, 1, @intFromPtr(o));
    _ = c.EnableWindow(h, @intFromBool(o.enabled));
    o.parts.append(a, h) catch {
        _ = c.DestroyWindow(h);
        return null;
    };
    applyControlTheme(o);
    return h;
}
fn layoutParts(o: *Control) void {
    if (o.hwnd == null) return;
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(o.hwnd, &rect);
    const scale = dpi(o.hwnd);
    var x: c_int = 0;
    var y: c_int = 0;
    for (o.parts.items, 0..) |h, i| {
        var width = rect.right;
        var height = buttonSize(h).cy;
        if (o.kind == .stepper) {
            width = if (i == 0) @max(0, rect.right - int(20 * scale)) else int(20 * scale);
            height = rect.bottom;
            x = if (i == 0) 0 else @max(0, rect.right - width);
        } else if (o.horizontal) width = buttonSize(h).cx;
        _ = c.SetWindowPos(h, null, x, y, width, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        if (o.kind == .radio_group) {
            if (o.horizontal) x += width else y += height;
        }
    }
}
fn readStepperValue(o: *Control) f64 {
    if (o.composing or o.parts.items.len == 0) return o.value;
    var buffer: [128]u16 = undefined;
    const n = c.GetWindowTextW(o.parts.items[0], &buffer, buffer.len);
    var utf8: [384]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, buffer[0..@intCast(@max(n, 0))]) catch 0;
    const parsed = std.fmt.parseFloat(f64, std.mem.trim(u8, utf8[0..len], " \t\r\n")) catch o.value;
    return if (std.math.isFinite(parsed)) std.math.clamp(parsed, o.min, o.max) else o.value;
}
fn commitStepper(o: *Control) void {
    if (!o.enabled or o.writing or o.composing or o.parts.items.len == 0) return;
    const old = o.value;
    fabrum_win32_set_number(o, readStepperValue(o));
    if (old != o.value) emit(o, .number, o.value);
}
fn compoundProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (labelColor(msg, wp, lp)) |result| return result;
    const o = object(hwnd, Control) orelse return c.DefWindowProcW(hwnd, msg, wp, lp);
    if (msg == c.WM_ERASEBKGND) return theme.erase(hwnd, @ptrFromInt(wp), o.window.palette.background);
    const self = o.window;
    const was_busy = enterRuntime(self);
    defer leaveRuntime(self, was_busy);
    switch (msg) {
        c.WM_SIZE => {
            layoutParts(o);
            return 0;
        },
        c.WM_COMMAND => {
            const code = (wp >> 16) & 0xffff;
            if (!o.enabled or o.writing) return 0;
            if (o.kind == .radio_group and code == c.BN_CLICKED and (wp & 0xffff) >= 100) {
                const index = (wp & 0xffff) - 100;
                if (index < o.parts.items.len) {
                    fabrum_win32_set_selection(o, @intCast(index));
                    emit(o, .select, @floatFromInt(index));
                }
            } else if (o.kind == .stepper and code == c.EN_KILLFOCUS) commitStepper(o);
            return 0;
        },
        c.WM_NOTIFY => {
            if (!o.enabled or o.writing) return 1;
            const hdr: *const c.NMHDR = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (o.kind == .stepper and hdr.code == @as(c.UINT, @bitCast(@as(c_int, -722)))) {
                const change: *const c.NMUPDOWN = @ptrCast(@alignCast(hdr));
                fabrum_win32_step(o, -change.iDelta);
                // The native integer position is an inert notification source;
                // f64 is authoritative, including fractional ranges and steps.
                return 1;
            }
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}
fn menuText(title: []const u8, key: []const u8) [:0]u16 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    // Ampersands in declarative labels are literal, not accidental mnemonics.
    for (title) |ch| {
        text.append(a, ch) catch @panic("out of memory");
        if (ch == '&') text.append(a, ch) catch @panic("out of memory");
    }
    if (key.len > 0) {
        text.appendSlice(a, "\tCtrl+") catch @panic("out of memory");
        text.appendSlice(a, key) catch @panic("out of memory");
    }
    return wide(text.items);
}
fn rebuildMenu(self: *Window) void {
    if (self.closed) return;
    const bar = c.CreateMenu() orelse return;
    var groups: std.ArrayList(struct { name: []const u8, menu: c.HMENU }) = .empty;
    defer groups.deinit(a);
    for (self.controls.items) |o| {
        if (o.kind != .menu_item) continue;
        const group = o.menu_group orelse continue;
        var submenu: c.HMENU = null;
        for (groups.items) |g| if (std.mem.eql(u8, g.name, group)) {
            submenu = g.menu;
            break;
        };
        if (submenu == null) {
            submenu = c.CreatePopupMenu() orelse continue;
            const label = menuText(group, "");
            defer a.free(label);
            _ = c.AppendMenuW(bar, c.MF_POPUP, @intFromPtr(submenu), label.ptr);
            groups.append(a, .{ .name = group, .menu = submenu }) catch @panic("out of memory");
        }
        const label = menuText(o.title, o.key);
        defer a.free(label);
        _ = c.AppendMenuW(submenu, @as(c.UINT, @intCast(c.MF_STRING | (if (o.enabled) @as(c_long, c.MF_ENABLED) else @as(c_long, c.MF_GRAYED)))), o.command, label.ptr);
    }
    const old = self.menu;
    self.menu = if (groups.items.len > 0) bar else null;
    _ = c.SetMenu(self.hwnd, self.menu);
    _ = c.DrawMenuBar(self.hwnd);
    if (self.menu == null) _ = c.DestroyMenu(bar);
    if (old != null) _ = c.DestroyMenu(old);
    request_frame(self);
}
fn menuShortcut(self: *Window, msg: c.UINT, vk: usize) bool {
    if (msg != c.WM_KEYDOWN or c.GetKeyState(c.VK_CONTROL) >= 0 or c.GetKeyState(c.VK_MENU) < 0 or c.GetKeyState(c.VK_SHIFT) < 0) return false;
    for (self.controls.items) |o| {
        if (o.kind != .menu_item or !o.enabled or o.menu_group == null or o.key.len == 0) continue;
        const key = wide(o.key);
        defer a.free(key);
        if (key.len != 1) continue;
        const mapped = c.VkKeyScanW(key[0]);
        if (mapped != -1 and vk == (@as(u16, @bitCast(mapped)) & 0xff)) {
            emit(o, .activate, 0);
            return true;
        }
    }
    return false;
}
/// Composite parts for native automation: radio buttons in declaration order;
/// stepper edit at zero and native updown at one.
pub fn controlPartHwnd(p: *anyopaque, index: usize) c.HWND {
    const o = control(p);
    return if (index < o.parts.items.len) o.parts.items[index] else null;
}

// Each control owns one font; child parts borrow it. Never delete a stock font.
fn updateFont(o: *Control) void {
    if (o.hwnd == null) return;
    const font = theme.font(o.window.hwnd, o.font_size) orelse return;
    const old = o.font;
    o.font = font;
    _ = send(o.hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
    for (o.parts.items) |h| _ = send(h, c.WM_SETFONT, @intFromPtr(font), 1);
    if (o.kind == .label) _ = send(o.hwnd, c.EM_SETMARGINS, c.EC_LEFTMARGIN | c.EC_RIGHTMARGIN, 0);
    if (old != null) _ = c.DeleteObject(old);
    layoutParts(o);
}
fn windowText(hwnd: c.HWND) [:0]u16 {
    const len: usize = @intCast(@max(0, c.GetWindowTextLengthW(hwnd)));
    const text = a.allocSentinel(u16, len, 0) catch @panic("out of memory");
    _ = c.GetWindowTextW(hwnd, text.ptr, @intCast(len + 1));
    return text;
}
fn measureText(hwnd: c.HWND, text: []const u16, max_width: f64, wrap: bool, multiline: bool) c.SIZE {
    const dc = c.GetDC(hwnd) orelse return .{ .cx = 0, .cy = 0 };
    defer _ = c.ReleaseDC(hwnd, dc);
    const font: c.HGDIOBJ = @ptrFromInt(@as(usize, @bitCast(send(hwnd, c.WM_GETFONT, 0, 0))));
    const old = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old);
    var rect = c.RECT{ .left = 0, .top = 0, .right = if (max_width > 0) @max(1, int(max_width)) else 0, .bottom = 0 };
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &rect, @intCast(c.DT_CALCRECT | c.DT_NOPREFIX | @as(c_int, if (wrap and max_width > 0) @as(c_int, c.DT_WORDBREAK) else if (multiline) 0 else c.DT_SINGLELINE)));
    var metrics: c.TEXTMETRICW = undefined;
    _ = c.GetTextMetricsW(dc, &metrics);
    return .{ .cx = rect.right, .cy = @max(rect.bottom, metrics.tmHeight) };
}
fn textSize(hwnd: c.HWND, max_width: f64, wrap: bool, multiline: bool) c.SIZE {
    const text = windowText(hwnd);
    defer a.free(text);
    return measureText(hwnd, text, max_width, wrap, multiline);
}
fn buttonSize(hwnd: c.HWND) c.SIZE {
    var size = std.mem.zeroes(c.SIZE);
    if (send(hwnd, c.BCM_GETIDEALSIZE, 0, @bitCast(@intFromPtr(&size))) != 0 and size.cx > 0 and size.cy > 0) return size;
    size = textSize(hwnd, 0, false, false);
    size.cx += int(28 * dpi(hwnd));
    size.cy = @max(size.cy + int(8 * dpi(hwnd)), int(26 * dpi(hwnd)));
    return size;
}
fn labelColor(msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) ?c.LRESULT {
    if (msg != c.WM_CTLCOLORSTATIC and msg != c.WM_CTLCOLOREDIT and msg != c.WM_CTLCOLORLISTBOX and msg != c.WM_CTLCOLORBTN) return null;
    const hwnd: c.HWND = @ptrFromInt(@as(usize, @bitCast(lp)));
    // Verify against the registry before reading userdata (dialogs use it too).
    for (windows.items) |window| for (window.controls.items) |o| {
        var matches = o.hwnd == hwnd;
        for (o.parts.items) |part| matches = matches or part == hwnd;
        if (!matches and o.kind == .dropdown) {
            var info = std.mem.zeroes(c.COMBOBOXINFO);
            info.cbSize = @sizeOf(c.COMBOBOXINFO);
            if (c.GetComboBoxInfo(o.hwnd, &info) != 0) matches = info.hwndList == hwnd or info.hwndItem == hwnd;
        }
        if (!matches) continue;
        const dc: c.HDC = @ptrFromInt(wp);
        const colors = window.palette;
        const background = if (o.kind == .label or msg == c.WM_CTLCOLORBTN) colors.background else colors.input;
        return theme.controlColor(dc, background, if (!o.enabled or o.secondary) colors.secondary else colors.text);
    };
    return null;
}

/// EDIT wrapping is fixed at creation. Keep the Control/Handle identity while
/// replacing only its HWND under the existing deferred-event runtime guard.
fn replaceLabelWindow(o: *Control, wrap: bool) void {
    const was_busy = enterRuntime(o.window);
    defer leaveRuntime(o.window, was_busy);
    const old = o.hwnd;
    const text = windowText(old);
    defer a.free(text);
    const parent = c.GetParent(old);
    var rect: c.RECT = undefined;
    _ = c.GetWindowRect(old, &rect);
    _ = c.MapWindowPoints(null, parent, @ptrCast(&rect), 2);
    var style = c.GetWindowLongPtrW(old, c.GWL_STYLE);
    style &= ~@as(isize, c.ES_AUTOHSCROLL);
    if (!wrap) style |= c.ES_AUTOHSCROLL;
    const replacement = c.CreateWindowExW(0, str("EDIT"), text.ptr, @intCast(style), rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, parent, null, c.GetModuleHandleW(null), null) orelse @panic("native label creation failed");
    var first: c.DWORD = 0;
    var last: c.DWORD = 0;
    _ = send(old, c.EM_GETSEL, @intFromPtr(&first), @bitCast(@intFromPtr(&last)));
    _ = send(replacement, c.WM_SETFONT, @intFromPtr(o.font orelse c.GetStockObject(c.DEFAULT_GUI_FONT)), 0);
    _ = send(replacement, c.EM_SETMARGINS, c.EC_LEFTMARGIN | c.EC_RIGHTMARGIN, 0);
    _ = send(replacement, c.EM_SETSEL, first, @intCast(last));
    _ = c.SetWindowLongPtrW(replacement, c.GWLP_USERDATA, @bitCast(@intFromPtr(o)));
    _ = c.SetWindowSubclass(replacement, controlProc, 1, @intFromPtr(o));
    _ = c.SetWindowPos(replacement, old, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    const focused = c.GetFocus() == old;
    const was_writing = o.writing;
    o.writing = true;
    defer o.writing = was_writing;
    o.hwnd = replacement;
    if (focused) _ = c.SetFocus(replacement);
    _ = c.RemoveWindowSubclass(old, controlProc, 1);
    _ = c.SetWindowLongPtrW(old, c.GWLP_USERDATA, 0);
    _ = c.DestroyWindow(old);
}
