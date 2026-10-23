//! Owned service requests. No runtime, scene, or Window pointer is dereferenced
//! across a native modal loop: closing an owner detaches it before cancellation.
const std = @import("std");
const c = @import("win32_c");
const abi = @import("../win32.zig");
const platform = @import("../../../app.zig").platform;
const shell = @import("shell.zig");
const theme = @import("theme.zig");
const a = std.heap.page_allocator;

extern fn fabrum_file_dialog_create([*:0]const u16, [*:0]const u16, bool) ?*anyopaque;
extern fn fabrum_file_dialog_show(*anyopaque, c.HWND) ?[*:0]u16;
extern fn fabrum_file_dialog_cancel(*anyopaque) c_long;
extern fn fabrum_file_dialog_destroy(*anyopaque) void;
extern fn fabrum_file_dialog_free_path([*:0]u16) void;

const Choice = struct { id: usize, enabled: bool };
const Popup = struct {
    menu: c.HMENU,
    choices: std.ArrayList(Choice) = .empty,
    at: @import("../../../root.zig").Vec2,
    anchor: ?@import("../../../root.zig").Rect,
    callback: abi.PopupCallback,
    answer: ?usize = null,
};
const File = struct {
    title: [:0]u16,
    pattern: [:0]u16,
    directory: bool,
    callback: abi.TextCallback,
    dialog: ?*anyopaque = null,
    answer: ?[:0]u8 = null,
};
const Request = struct {
    owner: ?*anyopaque,
    hwnd: c.HWND,
    ctx: ?*anyopaque,
    answered: bool = false,
    retire_hwnd: bool = false,
    value: union(enum) { popup: Popup, file: File, text: Text },

    fn destroy(self: *Request) void {
        switch (self.value) {
            .text => |t| {
                a.free(t.title);
                a.free(t.initial);
                if (t.answer) |v| a.free(v);
            },
            .popup => |*p| {
                if (p.menu != null) _ = c.DestroyMenu(p.menu);
                p.choices.deinit(a);
            },
            .file => |f| {
                a.free(f.title);
                a.free(f.pattern);
                if (f.answer) |s| a.free(s);
            },
        }
        a.destroy(self);
    }

    fn reply(self: *Request) void {
        switch (self.value) {
            .text => |t| t.callback(self.ctx, if (t.answer) |v| v.ptr else null, if (t.answer) |v| v.len else 0),
            .popup => |p| p.callback(self.ctx, p.answer != null, p.answer orelse 0),
            .file => |f| f.callback(self.ctx, if (f.answer) |s| s.ptr else null, if (f.answer) |s| s.len else 0),
        }
    }
};
var queue: std.ArrayList(*Request) = .empty;
var active: ?*Request = null;
var stopping = false;

/// The outer message loop reaches this only after every dispatcher callback,
/// including its nested Show/TrackPopupMenuEx stack, has returned. COM teardown
/// may itself pump messages: prevent queued tasks from opening another dialog.
pub fn shutdown() void {
    std.debug.assert(active == null);
    stopping = true;
    while (queue.items.len > 0) {
        const r = takeQueued(0);
        r.reply();
        r.destroy();
    }
}

fn takeQueued(index: usize) *Request {
    const r = queue.orderedRemove(index);
    if (queue.items.len == 0) {
        queue.deinit(a);
        queue = .empty;
    }
    return r;
}

fn schedule() void {
    shell.fabrum_win32_run_on_main(startNext, null);
}

fn startNext(_: ?*anyopaque) callconv(.c) void {
    if (stopping or active != null or queue.items.len == 0) return;
    const request = takeQueued(0);
    active = request;
    // Only request data survives this call. The owner may be freed by the
    // dispatcher inside Show/TrackPopupMenuEx; cancelOwner clears its identity.
    switch (request.value) {
        .text => {
            if (showText(request)) return;
        },
        .popup => |*p| {
            // Convert when shown, so a queued popup follows a moved window or
            // a DPI change that happened after the originating update.
            const scale: f64 = @as(f64, @floatFromInt(c.GetDpiForWindow(request.hwnd))) / 96;
            var point: c.POINT = .{ .x = coordinate(p.at.x * scale), .y = coordinate(p.at.y * scale) };
            _ = c.ClientToScreen(request.hwnd, &point);
            var params = std.mem.zeroes(c.TPMPARAMS);
            params.cbSize = @sizeOf(c.TPMPARAMS);
            if (p.anchor) |rect| {
                var origin: c.POINT = .{ .x = coordinate(rect.x * scale), .y = coordinate(rect.y * scale) };
                _ = c.ClientToScreen(request.hwnd, &origin);
                params.rcExclude = .{ .left = origin.x, .top = origin.y, .right = origin.x +| coordinate(rect.w * scale), .bottom = origin.y +| coordinate(rect.h * scale) };
            }
            const token = c.TrackPopupMenuEx(p.menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON, point.x, point.y, request.hwnd, if (p.anchor != null) &params else null);
            if (!request.answered and request.owner != null and token > 0 and token <= p.choices.items.len) {
                const choice = p.choices.items[@intCast(token - 1)];
                if (choice.enabled) p.answer = choice.id;
            }
        },
        .file => |*f| {
            f.dialog = fabrum_file_dialog_create(f.title.ptr, f.pattern.ptr, f.directory);
            if (f.dialog) |dialog| {
                const path = if (request.owner != null and !request.answered) fabrum_file_dialog_show(dialog, request.hwnd) else null;
                if (path) |s| {
                    defer fabrum_file_dialog_free_path(s);
                    if (!request.answered and request.owner != null) f.answer = std.unicode.utf16LeToUtf8AllocZ(a, std.mem.span(s)) catch null;
                }
                request.answered = true;
                f.dialog = null;
                fabrum_file_dialog_destroy(dialog);
            }
        },
    }
    finishActive(request);
}

fn finishActive(request: *Request) void {
    // Destroying native resources can also pump messages and close the owner.
    // Finish it before checking whether HWND ownership has been transferred.
    if (request.value == .popup) {
        const menu = request.value.popup.menu;
        request.value.popup.menu = null;
        _ = c.DestroyMenu(menu);
    }
    // EndMenu/Close request an unwind; native code may still use its owner
    // until Show/TrackPopupMenuEx (and COM Release) have actually returned.
    // The HWND's application userdata was detached when its wrapper closed.
    if (request.retire_hwnd) {
        const hwnd = request.hwnd;
        request.hwnd = null;
        request.retire_hwnd = false;
        _ = c.DestroyWindow(hwnd);
    }
    request.reply();
    request.destroy();
    active = null;
    if (queue.items.len > 0) schedule();
}

/// Returns true when the active request assumes ownership of the native HWND.
pub fn cancelOwner(owner: *anyopaque) bool {
    var deferred = false;
    if (active) |r| if (r.owner == owner) {
        deferred = true;
        r.retire_hwnd = true;
        r.owner = null;
        r.answered = true;
        switch (r.value) {
            .text => |*t| {
                if (t.answer) |v| a.free(v);
                t.answer = null;
                if (t.dialog != null) _ = c.DestroyWindow(t.dialog);
                t.dialog = null;
                if (!t.finishing) {
                    t.finishing = true;
                    shell.fabrum_win32_run_on_main(finishTextTask, r);
                }
            },
            .popup => |*p| {
                p.answer = null;
                _ = c.EndMenu();
            },
            .file => |*f| {
                if (f.answer) |s| a.free(s);
                f.answer = null;
                if (f.dialog) |d| {
                    _ = fabrum_file_dialog_cancel(d);
                }
            },
        }
    };
    var i: usize = 0;
    while (i < queue.items.len) {
        const r = queue.items[i];
        if (r.owner != owner) {
            i += 1;
            continue;
        }
        _ = takeQueued(i);
        r.reply();
        r.destroy();
    }
    return deferred;
}

fn enqueue(r: *Request) platform.Services.Error!void {
    if (stopping) return error.ServiceFailed;
    try queue.append(a, r);
    schedule();
}

pub fn openFile(owner: *anyopaque, hwnd: c.HWND, request: *const platform.FileRequest, directory: bool, callback: abi.TextCallback, ctx: ?*anyopaque) platform.Services.Error!void {
    const title = std.unicode.utf8ToUtf16LeAllocZ(a, request.message) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ServiceFailed,
    };
    errdefer a.free(title);
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(a);
    if (!directory) for (request.extensions) |extension| {
        // FileRequest extensions are literal suffixes, never shell patterns.
        if (extension.len == 0 or std.mem.indexOfAny(u8, extension, "*?;/\\\x00") != null) return error.ServiceFailed;
        if (pattern.items.len > 0) try pattern.append(a, ';');
        try pattern.appendSlice(a, "*.");
        try pattern.appendSlice(a, extension);
    };
    const filter = std.unicode.utf8ToUtf16LeAllocZ(a, pattern.items) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ServiceFailed,
    };
    errdefer a.free(filter);
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = .{ .owner = owner, .hwnd = hwnd, .ctx = ctx, .value = .{ .file = .{ .title = title, .pattern = filter, .directory = directory, .callback = callback } } };
    try enqueue(r);
}

fn appendItems(menu: c.HMENU, items: []const platform.MenuItem, choices: *std.ArrayList(Choice), ancestors_enabled: bool) platform.Services.Error!void {
    for (items) |item| {
        const enabled = ancestors_enabled and item.enabled;
        if (item.kind == .separator) {
            if (c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null) == 0) return error.ServiceFailed;
            continue;
        }
        // Escape ampersands so labels are literal, consistent with menu bars.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        for (item.title) |ch| {
            try text.append(a, ch);
            if (ch == '&') try text.append(a, ch);
        }
        const label = std.unicode.utf8ToUtf16LeAllocZ(a, text.items) catch return error.ServiceFailed;
        defer a.free(label);
        var flags: c.UINT = c.MF_STRING;
        if (!enabled or item.kind == .header) flags |= c.MF_GRAYED;
        var token: usize = 0;
        if (item.kind == .submenu) {
            const child = c.CreatePopupMenu() orelse return error.ServiceFailed;
            errdefer _ = c.DestroyMenu(child);
            try appendItems(child, item.submenu, choices, enabled);
            if (c.AppendMenuW(menu, flags | c.MF_POPUP, @intFromPtr(child), label.ptr) == 0) return error.ServiceFailed;
        } else {
            if (item.kind == .item) {
                if (choices.items.len >= std.math.maxInt(c_int)) return error.ServiceFailed;
                try choices.append(a, .{ .id = item.id, .enabled = enabled });
                token = choices.items.len;
            }
            if (c.AppendMenuW(menu, flags, token, label.ptr) == 0) return error.ServiceFailed;
        }
    }
}

pub fn popupMenu(owner: *anyopaque, hwnd: c.HWND, request: *const platform.MenuRequest, callback: abi.PopupCallback, ctx: ?*anyopaque) platform.Services.Error!void {
    const menu = c.CreatePopupMenu() orelse return error.ServiceFailed;
    errdefer _ = c.DestroyMenu(menu);
    var choices: std.ArrayList(Choice) = .empty;
    errdefer choices.deinit(a);
    try appendItems(menu, request.items, &choices, true);
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = .{ .owner = owner, .hwnd = hwnd, .ctx = ctx, .value = .{ .popup = .{ .menu = menu, .choices = choices, .at = request.at, .anchor = request.anchor, .callback = callback } } };
    try enqueue(r);
}

fn coordinate(value: f64) c_long {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(@round(value), std.math.minInt(c_long), std.math.maxInt(c_long)));
}

fn find(owner: *anyopaque, comptime tag: std.meta.Tag(@FieldType(Request, "value"))) ?*Request {
    if (active) |r| if (r.owner == owner and r.value == tag and !r.answered) return r;
    for (queue.items) |r| if (r.owner == owner and r.value == tag and !r.answered) return r;
    return null;
}

pub fn answerPopup(owner: *anyopaque, id: ?usize) bool {
    const r = find(owner, .popup) orelse return false;
    if (id) |wanted| {
        var valid = false;
        for (r.value.popup.choices.items) |choice| if (choice.id == wanted and choice.enabled) {
            valid = true;
            break;
        };
        if (!valid) return false;
    }
    r.value.popup.answer = id;
    r.answered = true;
    if (active == r) {
        _ = c.EndMenu();
    } else finishQueued(r);
    return true;
}

pub fn answerFile(owner: *anyopaque, path: ?[*:0]const u8) bool {
    const r = find(owner, .file) orelse return false;
    r.value.file.answer = if (path) |p| a.dupeSentinel(u8, std.mem.span(p), 0) catch return false else null;
    r.answered = true;
    if (active == r) {
        if (r.value.file.dialog) |dialog| _ = fabrum_file_dialog_cancel(dialog);
    } else finishQueued(r);
    return true;
}

fn finishQueued(r: *Request) void {
    for (queue.items, 0..) |entry, i| if (entry == r) {
        _ = takeQueued(i);
        break;
    };
    r.reply();
    r.destroy();
}
const Text = struct {
    title: [:0]u16,
    initial: [:0]u16,
    flags: platform.TextRequest.Flags,
    max_len: usize,
    callback: abi.TextCallback,
    dialog: c.HWND = null,
    edit: c.HWND = null,
    previous_focus: c.HWND = null,
    font: c.HFONT = null,
    palette: theme.colors.Palette = undefined,
    font_points: f64 = 0,
    laying_out: bool = false,
    finishing: bool = false,
    answer: ?[:0]u8 = null,
};
const text_class = std.unicode.utf8ToUtf16LeStringLiteral("FabrumTextRequest");
const literal = std.unicode.utf8ToUtf16LeStringLiteral;
var text_registered = false;

pub fn editText(owner: *anyopaque, hwnd: c.HWND, request: *const platform.TextRequest, callback: abi.TextCallback, ctx: ?*anyopaque) platform.Services.Error!void {
    // Windows EDIT explicitly does not support password masking in multiline mode.
    if (request.flags.password and request.flags.multiline) return error.Unsupported;
    if (std.mem.indexOfScalar(u8, request.title, 0) != null or std.mem.indexOfScalar(u8, request.initial, 0) != null) return error.ServiceFailed;
    const title = std.unicode.utf8ToUtf16LeAllocZ(a, request.title) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ServiceFailed,
    };
    errdefer a.free(title);
    const initial = std.unicode.utf8ToUtf16LeAllocZ(a, request.initial) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ServiceFailed,
    };
    errdefer a.free(initial);
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = .{ .owner = owner, .hwnd = hwnd, .ctx = ctx, .value = .{ .text = .{ .title = title, .initial = initial, .flags = request.flags, .max_len = request.max_len, .callback = callback } } };
    try enqueue(r);
}

fn showText(r: *Request) bool {
    if (!text_registered) {
        var wc = std.mem.zeroes(c.WNDCLASSEXW);
        wc.cbSize = @sizeOf(c.WNDCLASSEXW);
        wc.lpfnWndProc = textProc;
        wc.hInstance = c.GetModuleHandleW(null);
        wc.lpszClassName = text_class;
        wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
        wc.hbrBackground = c.GetSysColorBrush(c.COLOR_BTNFACE);
        if (c.RegisterClassExW(&wc) == 0) return false;
        text_registered = true;
    }
    const t = &r.value.text;
    const appearance = shell.serviceTheme(r.owner orelse return false);
    t.palette = appearance.palette;
    t.font_points = appearance.points;
    const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(r.hwnd))) / 96;
    const width = coordinate(440 * scale);
    const height = coordinate((if (t.flags.multiline) @as(f64, 280) else 160) * scale);
    var bounds: c.RECT = undefined;
    _ = c.GetWindowRect(r.hwnd, &bounds);
    t.previous_focus = c.GetFocus();
    t.dialog = c.CreateWindowExW(c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT, text_class, t.title.ptr, c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU, bounds.left + @divTrunc(bounds.right - bounds.left - width, 2), bounds.top + @divTrunc(bounds.bottom - bounds.top - height, 2), width, height, r.hwnd, null, c.GetModuleHandleW(null), null);
    if (t.dialog == null) return false;
    _ = c.SetWindowLongPtrW(t.dialog, c.GWLP_USERDATA, @bitCast(@intFromPtr(r)));
    var style: c.DWORD = c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL;
    if (t.flags.multiline) style |= c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN | c.WS_VSCROLL;
    if (t.flags.password) style |= c.ES_PASSWORD;
    if (t.flags.numeric) style |= c.ES_NUMBER;
    t.edit = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, literal("EDIT"), t.initial.ptr, style, coordinate(16 * scale), coordinate(16 * scale), width - coordinate(48 * scale), height - coordinate(105 * scale), t.dialog, @ptrFromInt(100), c.GetModuleHandleW(null), null);
    const ok = c.CreateWindowExW(0, literal("BUTTON"), literal("OK"), c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, width - coordinate(200 * scale), height - coordinate(75 * scale), coordinate(75 * scale), coordinate(28 * scale), t.dialog, @ptrFromInt(c.IDOK), c.GetModuleHandleW(null), null);
    const cancel = c.CreateWindowExW(0, literal("BUTTON"), literal("Cancel"), c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP, width - coordinate(115 * scale), height - coordinate(75 * scale), coordinate(85 * scale), coordinate(28 * scale), t.dialog, @ptrFromInt(c.IDCANCEL), c.GetModuleHandleW(null), null);
    if (t.edit == null or ok == null or cancel == null) {
        _ = c.DestroyWindow(t.dialog);
        t.dialog = null;
        return false;
    }
    refreshTextTheme(t);
    layoutText(t);
    _ = c.SendMessageW(t.edit, c.EM_SETLIMITTEXT, if (t.max_len == 0) 0x7ffffffe else @min(t.max_len, 0x7ffffffe), 0);
    _ = c.SendMessageW(t.edit, c.EM_SETSEL, 0, -1);
    _ = c.EnableWindow(r.hwnd, 0);
    _ = c.ShowWindow(t.dialog, c.SW_SHOW);
    _ = c.SetFocus(t.edit);
    return true;
}

/// Queued requests sample appearance when shown; only the active one owns HWNDs.
pub fn refreshOwnerTheme(owner: *anyopaque, palette: theme.colors.Palette, points: f64) void {
    const r = active orelse return;
    if (r.owner != owner or r.value != .text) return;
    const t = &r.value.text;
    t.palette = palette;
    t.font_points = points;
    if (t.dialog != null) {
        refreshTextTheme(t);
        layoutText(t);
    }
}
fn refreshTextTheme(t: *Text) void {
    theme.frame(t.dialog, t.palette.dark);
    theme.refreshChildFont(t.dialog, &t.font, t.font_points);
    _ = c.RedrawWindow(t.dialog, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}
fn layoutText(t: *Text) void {
    if (t.laying_out) return;
    t.laying_out = true;
    defer t.laying_out = false;
    const dc = c.GetDC(t.dialog) orelse return;
    defer _ = c.ReleaseDC(t.dialog, dc);
    const old_font = c.SelectObject(dc, t.font);
    defer _ = c.SelectObject(dc, old_font);
    var metrics = std.mem.zeroes(c.TEXTMETRICW);
    if (c.GetTextMetricsW(dc, &metrics) == 0) return;
    const dpi = c.GetDpiForWindow(t.dialog);
    const scale = @as(f64, @floatFromInt(dpi)) / 96;
    const margin = coordinate(16 * scale);
    const gap = coordinate(10 * scale);
    const padding_x = coordinate(24 * scale);
    const padding_y = coordinate(12 * scale);
    var button_width = coordinate(85 * scale);
    var button_height = @max(coordinate(28 * scale), metrics.tmHeight + padding_y);
    for ([_]c_int{ c.IDOK, c.IDCANCEL }) |id| {
        var label: [32]u16 = undefined;
        const len = c.GetWindowTextW(c.GetDlgItem(t.dialog, id), &label, label.len);
        var size: c.SIZE = .{ .cx = 0, .cy = 0 };
        if (c.GetTextExtentPoint32W(dc, &label, len, &size) != 0) {
            button_width = @max(button_width, size.cx + padding_x);
            button_height = @max(button_height, size.cy + padding_y);
        }
    }
    var monitor = std.mem.zeroes(c.MONITORINFO);
    monitor.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(c.MonitorFromWindow(t.dialog, c.MONITOR_DEFAULTTONEAREST), &monitor) == 0) return;
    const work = monitor.rcWork;
    var chrome: c.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = c.AdjustWindowRectExForDpi(&chrome, c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU, 0, c.WS_EX_DLGMODALFRAME | c.WS_EX_CONTROLPARENT, dpi);
    const chrome_width = chrome.right - chrome.left;
    const chrome_height = chrome.bottom - chrome.top;
    const max_width = @max(1, work.right - work.left - chrome_width);
    const max_height = @max(1, work.bottom - work.top - chrome_height);
    // Stack responses on narrow work areas rather than compressing both labels.
    const stacked = 2 * button_width + gap + 2 * margin > max_width;
    const responses_height = if (stacked) 2 * button_height + gap else button_height;
    const edit_height = @max(metrics.tmHeight * @as(c_long, if (t.flags.multiline) 4 else 1) + padding_y, coordinate(if (t.flags.multiline) 140 * scale else 0));
    var client: c.RECT = undefined;
    _ = c.GetClientRect(t.dialog, &client);
    const width = @min(max_width, @max(client.right, @max(coordinate(408 * scale), (if (stacked) button_width else 2 * button_width + gap) + 2 * margin)));
    const height = @min(max_height, @max(client.bottom, edit_height + responses_height + gap + 2 * margin));
    var current: c.RECT = undefined;
    _ = c.GetWindowRect(t.dialog, &current);
    const outer_width = width + chrome_width;
    const outer_height = height + chrome_height;
    _ = c.SetWindowPos(t.dialog, null, std.math.clamp(current.left, work.left, @max(work.left, work.right - outer_width)), std.math.clamp(current.top, work.top, @max(work.top, work.bottom - outer_height)), outer_width, outer_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    const available_width = @max(1, width - 2 * margin);
    button_width = @min(button_width, available_width);
    const y = @max(margin, height - margin - responses_height);
    _ = c.MoveWindow(t.edit, margin, margin, available_width, @max(1, y - gap - margin), 1);
    const x = @max(margin, width - margin - (if (stacked) button_width else 2 * button_width + gap));
    _ = c.MoveWindow(c.GetDlgItem(t.dialog, c.IDOK), x, y, button_width, button_height, 1);
    _ = c.MoveWindow(c.GetDlgItem(t.dialog, c.IDCANCEL), if (stacked) x else x + button_width + gap, if (stacked) y + button_height + gap else y, button_width, button_height, 1);
}

fn textProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wp, lp);
    const r: *Request = @ptrFromInt(@as(usize, @bitCast(ptr)));
    const t = &r.value.text;
    if (msg == c.WM_NCDESTROY) {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        const result = c.DefWindowProcW(hwnd, msg, wp, lp);
        // Child borrowers are destroyed before the owned font is released.
        if (t.font != null) _ = c.DeleteObject(t.font);
        t.font = null;
        return result;
    }
    if (msg == c.WM_SETTINGCHANGE or msg == c.WM_THEMECHANGED or msg == c.WM_SYSCOLORCHANGE) {
        if (r.owner) |owner| shell.refreshServiceTheme(owner);
        return 0;
    }
    if (msg == c.WM_ERASEBKGND) return theme.erase(hwnd, @ptrFromInt(wp), t.palette.background);
    if (msg == c.WM_CTLCOLOREDIT or msg == c.WM_CTLCOLORSTATIC or msg == c.WM_CTLCOLORBTN) {
        const background = if (msg == c.WM_CTLCOLOREDIT) t.palette.input else if (msg == c.WM_CTLCOLORBTN) t.palette.control else t.palette.background;
        return theme.controlColor(@ptrFromInt(wp), background, t.palette.text);
    }
    if (msg == c.WM_DPICHANGED) {
        const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        refreshTextTheme(t);
        layoutText(t);
        return 0;
    }
    if (msg == c.WM_SIZE) {
        layoutText(t);
        return 0;
    }
    if (msg == c.DM_GETDEFID) return (c.DC_HASDEFID << 16) | c.IDOK;
    if (msg == c.WM_CLOSE or (msg == c.WM_COMMAND and (wp & 0xffff == c.IDOK or wp & 0xffff == c.IDCANCEL))) {
        if (r.answered) return 0;
        if (msg == c.WM_COMMAND and wp & 0xffff == c.IDOK) {
            const len = c.GetWindowTextLengthW(t.edit);
            const text = a.allocSentinel(u16, @intCast(@max(len, 0)), 0) catch return 0;
            defer a.free(text);
            _ = c.GetWindowTextW(t.edit, text.ptr, @intCast(text.len + 1));
            const utf8 = std.unicode.utf16LeToUtf8AllocZ(a, text) catch return 0;
            if (t.max_len != 0 and utf8.len > t.max_len) {
                a.free(utf8);
                _ = c.SetFocus(t.edit);
                return 0;
            }
            t.answer = utf8;
        }
        r.answered = true;
        r.value.text.finishing = true;
        shell.fabrum_win32_run_on_main(finishTextTask, r);
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return 0;
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

fn finishTextTask(ctx: ?*anyopaque) callconv(.c) void {
    const r: *Request = @ptrCast(@alignCast(ctx.?));
    const t = &r.value.text;
    if (t.dialog != null) _ = c.DestroyWindow(t.dialog);
    t.dialog = null;
    if (r.owner != null) {
        _ = c.EnableWindow(r.hwnd, 1);
        if (c.IsWindow(t.previous_focus) != 0) _ = c.SetFocus(t.previous_focus);
    }
    finishActive(r);
}

pub fn dialogMessage(msg: *c.MSG) bool {
    const r = active orelse return false;
    if (r.value != .text or r.value.text.dialog == null) return false;
    return c.IsDialogMessageW(r.value.text.dialog, msg) != 0;
}
