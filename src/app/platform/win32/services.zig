//! Owned service requests. No runtime, scene, or Window pointer is dereferenced
//! across a native modal loop: closing an owner detaches it before cancellation.
const std = @import("std");
const c = @import("win32_c");
const abi = @import("../win32.zig");
const platform = @import("../../../app.zig").platform;
const shell = @import("shell.zig");
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
    value: union(enum) { popup: Popup, file: File },

    fn destroy(self: *Request) void {
        switch (self.value) {
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
