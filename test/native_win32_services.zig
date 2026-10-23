//! Opt-in Win32 service integration. Injected replies and native UI are distinct phases.
//! No user files are opened or written. Run only on a coordinated desktop.
const std = @import("std");
const app = @import("fabrum").app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
extern "user32" fn GetWindow(Hwnd, u32) callconv(.winapi) ?Hwnd;
extern "user32" fn GetClassNameW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn GetWindowTextW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn EnumThreadWindows(u32, *const fn (Hwnd, isize) callconv(.winapi) c_int, isize) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "user32" fn IsWindowVisible(Hwnd) callconv(.winapi) c_int;
extern "user32" fn IsWindow(Hwnd) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PostMessageW(Hwnd, u32, usize, isize) callconv(.winapi) c_int;
extern "user32" fn GetMenuItemCount(Hwnd) callconv(.winapi) c_int;
extern "user32" fn GetSubMenu(Hwnd, c_int) callconv(.winapi) ?Hwnd;
extern "user32" fn GetMenuState(Hwnd, u32, u32) callconv(.winapi) u32;
extern "user32" fn GetMenuStringW(Hwnd, u32, [*]u16, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn GetDlgItem(Hwnd, c_int) callconv(.winapi) ?Hwnd;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Point = extern struct { x: i32, y: i32 };
extern "user32" fn SetWindowPos(Hwnd, ?Hwnd, i32, i32, i32, i32, u32) callconv(.winapi) c_int;
extern "user32" fn GetWindowRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn ClientToScreen(Hwnd, *Point) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(Hwnd) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*?[*]u16) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn RemoveDirectoryW([*:0]const u16) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?Hwnd) callconv(.winapi) Hwnd;
extern "kernel32" fn CloseHandle(Hwnd) callconv(.winapi) c_int;
extern "kernel32" fn DeleteFileW([*:0]const u16) callconv(.winapi) c_int;

const wide_id: usize = std.math.maxInt(usize);
const utf8_file: [:0]const u8 = "C:\\fabrum-test-cache\\résumé-日本語.png";
const utf8_directory: [:0]const u8 = "C:\\fabrum-test-cache\\資料";
const Case = enum {
    injected_file,
    injected_cancel,
    injected_directory,
    injected_zero,
    injected_wide,
    injected_popup_cancel,
    native_popup_zero,
    native_popup_nested,
    native_popup_cancel,
    native_file_cancel,
    native_directory_cancel,
    native_file_select,
    native_directory_select,
    concurrent_queue,
    close_before_popup,
    close_before_file,
    close_during_popup,
    close_during_file,
};
var cases: []const Case = std.enums.values(Case);
var probe: *Probe = undefined;
var total_replies: usize = 0; // UI thread only, survives destruction of a root.

fn check(ok: bool, why: []const u8) void {
    if (ok) return;
    std.debug.print("native-win32-services FAIL case={s} stage={s}: {s}\n", .{ @tagName(cases[probe.index]), @tagName(probe.stage), why });
    std.process.exit(1);
}
fn classIs(hwnd: Hwnd, name: []const u8) bool {
    var text: [128]u16 = undefined;
    const len = GetClassNameW(hwnd, &text, text.len);
    if (len != name.len) return false;
    for (name, text[0..name.len]) |a, b| if (a != b) return false;
    return true;
}
fn wideEquals(text: []const u16, expected: []const u8) bool {
    const converted = std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, expected) catch @panic("UTF16 allocation");
    defer std.heap.page_allocator.free(converted);
    return std.mem.eql(u16, text, converted);
}

const Root = struct {
    pub const Props = struct {};
    pub const State = struct {
        replies: usize = 0,
        requests: usize = 0,
        index: ?usize = null,
        text: [512]u8 = undefined,
        len: ?usize = null,
    };
    pub const Msg = union(enum) { request: Case, queued_popup, text: ?[]const u8, index: ?usize };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .queued_popup => {
                state.requests += 1;
                try ctx.menu(.{ .items = &.{.{ .title = "Queued B", .id = wide_id }}, .at = .init(40, 70), .anchor = .{ .x = 40, .y = 70, .w = 80, .h = 30 } }, ctx.handler(.index));
            },
            .text => |value| {
                state.replies += 1;
                total_replies += 1;
                state.len = if (value) |s| s.len else null;
                if (value) |s| {
                    check(s.len <= state.text.len, "reply fits buffer");
                    @memcpy(state.text[0..s.len], s);
                }
            },
            .index => |value| {
                state.replies += 1;
                total_replies += 1;
                state.index = value;
            },
            .request => |which| {
                state.requests += 1;
                const window = probe.gui.window(Root, probe.a).?;
                // Queue the coordinator's close before the deferred service starts;
                // the request is still made while its runtime is alive.
                if (which == .close_before_file or which == .close_before_popup) try ctx.close();
                switch (which) {
                    .injected_file, .injected_cancel, .injected_directory, .native_file_cancel, .native_directory_cancel, .native_file_select, .native_directory_select, .concurrent_queue, .close_before_file, .close_during_file => {
                        var title = "Choose résumé 資料".*;
                        var ext = "png".*;
                        var extensions = [_][]const u8{ &ext, "jpg" };
                        const request: app.platform.FileRequest = .{ .message = &title, .extensions = &extensions };
                        if (which == .injected_directory or which == .native_directory_cancel or which == .native_directory_select)
                            try ctx.openDirectory(request, ctx.handler(.text))
                        else
                            try ctx.openFile(request, ctx.handler(.text));
                        // A deferred host must own all three levels before returning.
                        @memset(&title, 'X');
                        @memset(&ext, 'x');
                        extensions[1] = "corrupt";
                        switch (which) {
                            .injected_file => {
                                var path = "C:\\fabrum-test-cache\\résumé-日本語.png".*;
                                try window.automation().answerFileChooser(&path);
                                @memset(path[0..path.len], 'X');
                            },
                            .injected_directory => try window.automation().answerFileChooser(utf8_directory),
                            .injected_cancel => try window.automation().answerFileChooser(null),
                            .close_before_file => {},
                            else => {},
                        }
                    },
                    else => {
                        var title = "Nested 資料".*;
                        var nested = [_]app.platform.MenuItem{
                            .{ .title = "Wide ID", .id = wide_id },
                            .{ .title = "Disabled branch", .kind = .submenu, .enabled = false, .submenu = &.{.{ .title = "Unreachable", .id = 75 }} },
                        };
                        var items = [_]app.platform.MenuItem{
                            .{ .title = "Heading", .kind = .header, .id = 71 },
                            .{ .kind = .separator, .id = 72 },
                            .{ .title = "Disabled", .id = 73, .enabled = false },
                            .{ .title = "Zero ID", .id = 0 },
                            .{ .title = &title, .kind = .submenu, .submenu = &nested },
                        };
                        try ctx.menu(.{ .items = &items, .at = .init(20, 20) }, ctx.handler(.index));
                        if (which == .injected_zero or which == .injected_wide or which == .injected_popup_cancel) {
                            for ([_]usize{ 71, 72, 73, 75, 999 }) |invalid| {
                                if (window.automation().answerPopup(invalid)) |_| check(false, "invalid/disabled menu ID accepted") else |err| check(err == error.NoPopupMenu, "invalid popup reply error");
                            }
                        }
                        @memset(&title, 'X');
                        nested[0].id = 123;
                        items[3].id = 124;
                        switch (which) {
                            .injected_zero => try window.automation().answerPopup(0),
                            .injected_wide => try window.automation().answerPopup(wide_id),
                            .injected_popup_cancel => try window.automation().answerPopup(null),
                            .close_before_popup => {},
                            else => {},
                        }
                    },
                }
            },
        }
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.text("Win32 chooser / popup service regression", .{});
    }
};

const Search = struct { owner: Hwnd, popup: bool, found: ?Hwnd = null, count: usize = 0 };
fn findNative(hwnd: Hwnd, context: isize) callconv(.winapi) c_int {
    const search: *Search = @ptrFromInt(@as(usize, @bitCast(context)));
    if (IsWindowVisible(hwnd) == 0) return 1;
    if (search.popup) {
        if (!classIs(hwnd, "#32768")) return 1;
    } else {
        if (!classIs(hwnd, "#32770") or GetWindow(hwnd, 4) != search.owner) return 1;
    }
    if (search.found == null) search.found = hwnd;
    search.count += 1;
    return 1;
}
fn native(owner: Hwnd, popup: bool) ?Hwnd {
    var search: Search = .{ .owner = owner, .popup = popup };
    _ = EnumThreadWindows(GetCurrentThreadId(), findNative, @bitCast(@intFromPtr(&search)));
    return search.found;
}
fn key(hwnd: Hwnd, vk: usize) void {
    check(PostMessageW(hwnd, 0x0100, vk, 0) != 0, "post native key down");
    check(PostMessageW(hwnd, 0x0101, vk, 0) != 0, "post native key up");
}
fn inspectMenu(hwnd: Hwnd) void {
    const handle = SendMessageW(hwnd, 0x01e1, 0, 0); // MN_GETHMENU
    check(handle != 0, "real popup has an HMENU");
    const menu: Hwnd = @ptrFromInt(@as(usize, @bitCast(handle)));
    check(GetMenuItemCount(menu) == 5, "copied top-level popup tree");
    check(GetMenuState(menu, 0, 0x400) & 3 != 0, "header is not selectable");
    check(GetMenuState(menu, 1, 0x400) & 0x800 != 0, "native separator");
    check(GetMenuState(menu, 2, 0x400) & 3 != 0, "disabled item is not selectable");
    var title: [128]u16 = undefined;
    const n = GetMenuStringW(menu, 4, &title, title.len, 0x400);
    check(n > 0 and wideEquals(title[0..@intCast(n)], "Nested 資料"), "transient UTF8 submenu title copied");
    check(GetMenuItemCount(GetSubMenu(menu, 4).?) == 2, "nested transient item array copied");
}

// Read the native file-type combo without control IDs or screen coordinates.
fn hasFilter(hwnd: Hwnd) bool {
    if (classIs(hwnd, "ComboBox")) {
        const count = SendMessageW(hwnd, 0x0146, 0, 0); // CB_GETCOUNT
        if (count > 0 and count < 100) {
            var i: usize = 0;
            while (i < @as(usize, @intCast(count))) : (i += 1) {
                const len = SendMessageW(hwnd, 0x0149, i, 0); // CB_GETLBTEXTLEN
                if (len <= 0 or len >= 512) continue;
                var text: [512]u16 = undefined;
                const n = SendMessageW(hwnd, 0x0148, i, @bitCast(@intFromPtr(&text))); // CB_GETLBTEXT
                if (n > 0 and wideEquals(text[0..@intCast(n)], "*.png;*.jpg")) return true;
            }
        }
    }
    var child = GetWindow(hwnd, 5);
    while (child) |next| : (child = GetWindow(next, 2)) {
        if (hasFilter(next)) return true;
    }
    return false;
}

fn filenameEdit(hwnd: Hwnd) ?Hwnd {
    if (GetDlgItem(hwnd, 1152)) |edit| if (classIs(edit, "Edit")) return edit;
    if (GetDlgItem(hwnd, 1148)) |combo| {
        if (classIs(combo, "Edit")) return combo;
        var child = GetWindow(combo, 5);
        while (child) |next| : (child = GetWindow(next, 2)) {
            if (classIs(next, "Edit")) return next;
        }
    }
    var child = GetWindow(hwnd, 5);
    while (child) |next| : (child = GetWindow(next, 2)) {
        if (filenameEdit(next)) |edit| return edit;
    }
    return null;
}
const Assets = struct {
    directory: [:0]u16,
    file: [:0]u16,
    directory_utf8: []u8,
    file_utf8: []u8,

    fn init() !Assets {
        const gpa = std.heap.page_allocator;
        const relative = try std.fmt.allocPrint(gpa, ".zig-cache\\native-services-{d}-資料", .{GetCurrentProcessId()});
        defer gpa.free(relative);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, relative);
        defer gpa.free(wide);
        var absolute: [32768]u16 = undefined;
        const n = GetFullPathNameW(wide, absolute.len, &absolute, null);
        if (n == 0 or n >= absolute.len) return error.PathFailed;
        const directory = try gpa.dupeSentinel(u16, absolute[0..n], 0);
        if (CreateDirectoryW(directory, null) == 0) return error.CreateDirectoryFailed;
        const directory_utf8 = try std.unicode.utf16LeToUtf8Alloc(gpa, directory);
        const file_utf8 = try std.fmt.allocPrint(gpa, "{s}\\résumé-日本語.png", .{directory_utf8});
        const file = try std.unicode.utf8ToUtf16LeAllocZ(gpa, file_utf8);
        const handle = CreateFileW(file, 0x40000000, 0, null, 1, 0x80, null); // CREATE_NEW
        if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.CreateFileFailed;
        _ = CloseHandle(handle);
        return .{ .directory = directory, .file = file, .directory_utf8 = directory_utf8, .file_utf8 = file_utf8 };
    }
    fn deinit(self: Assets) void {
        check(DeleteFileW(self.file) != 0, "remove owned Unicode file");
        check(RemoveDirectoryW(self.directory) != 0, "remove owned Unicode directory");
        const gpa = std.heap.page_allocator;
        gpa.free(self.directory);
        gpa.free(self.file);
        gpa.free(self.directory_utf8);
        gpa.free(self.file_utf8);
    }
};

const Probe = struct {
    gui: platform.Application,
    io: std.Io,
    assets: Assets,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    current_case: std.atomic.Value(usize) = .init(0),
    a: app.WindowId = @fromBackingInt(0),
    b: app.WindowId = @fromBackingInt(0),
    index: usize = 0,
    stage: enum { start, waiting, settling, closing } = .start,
    expected_replies: usize = 0,
    quiet_ticks: usize = 0,
    native_seen: bool = false,
    native_ready_ticks: usize = 0,
    menu_step: usize = 0,
    queue_step: usize = 0,
    b_replies: usize = 0,
    owner_hwnd: ?Hwnd = null,

    fn open(self: *Probe, title: [:0]const u8) app.WindowId {
        return self.gui.openWindow(Root, .{}, .{ .title = title, .width = 360, .height = 160 }, .{ .watchdog_ms = null }) catch @panic("open service test window");
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        if (self.b == @as(app.WindowId, @fromBackingInt(0))) {
            self.a = self.open("Service owner A");
            self.b = self.open("Service isolation B");
            return;
        }
        const b = self.gui.window(Root, self.b) orelse @panic("unrelated owner destroyed");
        const bs = b.runtime.rootState(Root) orelse return;
        if (cases[self.index] != .concurrent_queue) check(bs.replies == self.b_replies, "service replies isolated to their owner");
        const which = cases[self.index];
        const a = self.gui.window(Root, self.a);
        if (self.stage == .closing) {
            if (a != null) return;
            self.assets.deinit(); // The platform run loop exits the process directly.
            self.gui.options.quit_on_last_window_closed = true;
            self.done.store(true, .release);
            self.gui.quit();
            std.debug.print("native-win32-services PASS ({d} cases)\n", .{cases.len});
            return;
        }
        switch (self.stage) {
            .start => {
                self.current_case.store(self.index, .release);
                const window = a orelse return;
                self.owner_hwnd = window.hwnd();
                _ = window.runtime.rootState(Root) orelse return;
                self.expected_replies = total_replies;
                self.native_seen = false;
                self.native_ready_ticks = 0;
                self.menu_step = 0;
                self.quiet_ticks = 0;
                self.stage = .waiting; // Requests may enter a nested modal loop.
                check(self.gui.present(self.a), "present native service owner");
                window.runtime.post(app.testing.rootInstance(Root).handler(Root, .request), which) catch @panic("post request");
            },
            .waiting => {
                if (which == .concurrent_queue) {
                    switch (self.queue_step) {
                        0 => {
                            const window = a orelse return;
                            _ = native(window.hwnd(), false) orelse return;
                            self.native_seen = true;
                            b.runtime.post(app.testing.rootInstance(Root).handler(Root, .queued_popup), {}) catch @panic("queue B popup during A modal");
                            self.queue_step = 1;
                        },
                        1 => {
                            if (bs.requests == 0) return;
                            const window = a orelse @panic("A closed before B queued");
                            check(native(window.hwnd(), false) != null, "A chooser remains active while B is queued");
                            check(native(b.hwnd(), true) == null, "queued B popup cannot nest inside A chooser");
                            check(bs.replies == 0, "queued B has no early reply");
                            check(SetWindowPos(b.hwnd(), null, 500, 300, 0, 0, 0x15) != 0, "move queued popup owner before display");
                            self.queue_step = 2;
                            check(PostMessageW(window.hwnd(), 0x0010, 0, 0) != 0, "close A with B request queued");
                        },
                        2 => {
                            if (a != null) return;
                            const hwnd = native(b.hwnd(), true) orelse return;
                            var search: Search = .{ .owner = b.hwnd(), .popup = true };
                            _ = EnumThreadWindows(GetCurrentThreadId(), findNative, @bitCast(@intFromPtr(&search)));
                            check(search.count == 1, "exactly one native popup after A modal unwinds");
                            check(native(b.hwnd(), false) == null, "no chooser remains after A closes");
                            var rect: Rect = undefined;
                            check(GetWindowRect(hwnd, &rect) != 0, "queued popup geometry");
                            const scale: f64 = @as(f64, @floatFromInt(GetDpiForWindow(b.hwnd()))) / 96;
                            var point: Point = .{ .x = @intFromFloat(40 * scale), .y = @intFromFloat(70 * scale) };
                            check(ClientToScreen(b.hwnd(), &point) != 0, "moved owner client origin");
                            // Border/shadow can extend a few pixels around the menu. The
                            // anchor excludes the requested top-left, so placement moves
                            // to an edge of its current (moved, DPI-scaled) rectangle.
                            const right = point.x + @as(i32, @intFromFloat(80 * scale));
                            const bottom = point.y + @as(i32, @intFromFloat(30 * scale));
                            check(rect.left >= point.x - 8 and rect.top >= point.y - 8, "queued popup follows moved owner");
                            check(rect.left >= right - 8 or rect.top >= bottom - 8, "popup excludes moved anchor rectangle");
                            _ = SendMessageW(hwnd, 0x01e5, 0, 0); // MN_SELECTITEM
                            key(b.hwnd(), 0x0d);
                            self.queue_step = 3;
                        },
                        3 => {
                            if (bs.replies == 0) return;
                            check(bs.replies == 1 and bs.index == wide_id, "queued B reply delivered after A close");
                            check(total_replies == self.expected_replies + 1, "closed A request does not deliver late reply");
                            self.b_replies = 1;
                            self.expected_replies += 1;
                            self.stage = .settling;
                        },
                        else => unreachable,
                    }
                    return;
                }
                if (which == .close_before_popup or which == .close_before_file) {
                    if (a != null) return;
                    self.stage = .settling;
                    return;
                }
                const window = a orelse {
                    check(which == .close_during_popup or which == .close_during_file, "owner survived service");
                    self.stage = .settling;
                    return;
                };
                // Owner B must not consume A's pending request, including during modal UI.
                if (b.automation().answerPopup(null)) |_| check(false, "B consumed popup") else |err| check(err == error.NoPopupMenu, "B popup error");
                if (b.automation().answerFileChooser(null)) |_| check(false, "B consumed chooser") else |err| check(err == error.NoFileChooser, "B chooser error");
                const popup = which == .native_popup_zero or which == .native_popup_nested or which == .native_popup_cancel or which == .close_during_popup;
                const chooser = which == .native_file_cancel or which == .native_directory_cancel or which == .native_file_select or which == .native_directory_select or which == .close_during_file;
                if (!popup and !chooser) {
                    check(native(window.hwnd(), false) == null and native(window.hwnd(), true) == null, "deterministic injected reply bypasses native UI");
                }
                if ((popup or chooser) and !self.native_seen) {
                    const hwnd = native(window.hwnd(), popup) orelse return;
                    if (chooser) {
                        // Visibility can precede the shell's final control population.
                        // Let its initialization messages run before entering a path.
                        self.native_ready_ticks += 1;
                        if (self.native_ready_ticks < 3) return;
                    }
                    self.native_seen = true;
                    if (popup) inspectMenu(hwnd) else {
                        var text: [128]u16 = undefined;
                        const n = GetWindowTextW(hwnd, &text, text.len);
                        check(n > 0 and wideEquals(text[0..@intCast(n)], "Choose résumé 資料"), "chooser copied transient UTF8 title");
                        if (which == .native_file_cancel or which == .native_file_select or which == .close_during_file)
                            check(hasFilter(hwnd), "native chooser copied extension strings and slice")
                        else
                            check(!hasFilter(hwnd), "directory chooser ignores extension filters");
                    }
                    if (which == .close_during_popup or which == .close_during_file) {
                        // WM_CLOSE is asynchronous, so no owner is freed under this callback.
                        check(PostMessageW(window.hwnd(), 0x0010, 0, 0) != 0, "close owner during real native request");
                    } else if (chooser) {
                        if (which == .native_file_select or which == .native_directory_select) {
                            const edit = filenameEdit(hwnd) orelse @panic("native filename edit not found");
                            const path = if (which == .native_file_select) self.assets.file else self.assets.directory;
                            check(SendMessageW(edit, 0x000c, 0, @bitCast(@intFromPtr(path.ptr))) != 0, "set native filename to owned Unicode path");
                            check(PostMessageW(GetDlgItem(hwnd, 1).?, 0x00f5, 0, 0) != 0, "accept real native chooser");
                        } else check(PostMessageW(hwnd, 0x0111, 2, 0) != 0, "cancel real native chooser with IDCANCEL");
                    } else if (which == .native_popup_cancel) {
                        key(window.hwnd(), 0x1b);
                    } else {
                        // Select by native menu position, then activate through its modal keyboard loop.
                        _ = SendMessageW(hwnd, 0x01e5, 3, 0);
                        if (which == .native_popup_nested) {
                            _ = SendMessageW(hwnd, 0x01e5, 4, 0);
                            key(window.hwnd(), 0x27);
                        }
                        self.menu_step = 1;
                    }
                }
                if (self.menu_step == 1) {
                    self.menu_step = 2;
                    return;
                } else if (self.menu_step == 2) {
                    self.menu_step = 3;
                    key(window.hwnd(), 0x0d);
                    return;
                }
                if (which == .close_during_popup or which == .close_during_file) return;
                const state = window.runtime.rootState(Root).?;
                if (total_replies == self.expected_replies) {
                    if (which == .native_directory_select and self.native_seen) {
                        self.quiet_ticks += 1;
                        if (self.quiet_ticks % 5 == 0) if (native(window.hwnd(), false)) |dialog| {
                            if (filenameEdit(dialog)) |edit| {
                                const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
                                _ = SendMessageW(edit, 0x000c, 0, @bitCast(@intFromPtr(empty.ptr)));
                            }
                            _ = PostMessageW(GetDlgItem(dialog, 1).?, 0x00f5, 0, 0);
                        };
                    }
                    return;
                }
                check(total_replies == self.expected_replies + 1, "one callback per request");
                switch (which) {
                    .injected_file => check(state.len != null and std.mem.eql(u8, state.text[0..state.len.?], utf8_file), "UTF8 file reply"),
                    .injected_directory => check(state.len != null and std.mem.eql(u8, state.text[0..state.len.?], utf8_directory), "UTF8 directory reply"),
                    .native_file_select => check(state.len != null and std.mem.eql(u8, state.text[0..state.len.?], self.assets.file_utf8), "real COM file result UTF8 conversion"),
                    .native_directory_select => check(state.len != null and std.mem.eql(u8, state.text[0..state.len.?], self.assets.directory_utf8), "real COM directory result UTF8 conversion"),
                    .injected_zero, .native_popup_zero => check(state.index == 0, "item ID zero preserved"),
                    .injected_wide, .native_popup_nested => check(state.index == wide_id, "nested full-width usize ID preserved"),
                    .injected_popup_cancel, .native_popup_cancel => check(state.index == null, "popup cancellation"),
                    else => check(state.len == null, "chooser cancellation"),
                }
                self.expected_replies += 1;
                self.stage = .settling;
            },
            .settling => {
                check(total_replies == self.expected_replies, "no late or duplicate callbacks after response/owner close");
                if (a == null) if (self.owner_hwnd) |hwnd| {
                    // Modal unwind must retire the detached HWND before success.
                    if (IsWindow(hwnd) != 0) return;
                };
                if (a) |window| {
                    if (window.automation().answerPopup(null)) |_| check(false, "answered popup remained live") else |_| {}
                    if (window.automation().answerFileChooser(null)) |_| check(false, "answered chooser remained live") else |_| {}
                }
                self.quiet_ticks += 1;
                if (self.quiet_ticks < 3) return;
                if (self.index + 1 == cases.len) {
                    if (a != null) check(self.gui.close(self.a), "close final owner");
                    self.stage = .closing;
                } else {
                    self.index += 1;
                    if (a == null) self.a = self.open("Service owner A reopened");
                    self.stage = .start;
                }
            },
            .closing => unreachable,
        }
    }
    fn timer(self: *Probe) void {
        for (0..900) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            if (!self.done.load(.acquire) and !self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        std.debug.print("native-win32-services FAIL: timeout in {s} (native unwind and process exit required)\n", .{@tagName(cases[self.current_case.load(.acquire)])});
        std.process.exit(1);
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    _ = args.next();
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "--popup-close-only")) {
            cases = &.{ .close_before_popup, .close_before_file, .close_during_popup };
        } else if (std.mem.eql(u8, mode, "--dialog-close-only")) {
            cases = &.{ .native_file_cancel, .native_directory_cancel, .close_before_file, .close_during_file };
        } else if (std.mem.eql(u8, mode, "--selection-only")) {
            cases = &.{ .native_file_select, .native_directory_select };
        } else if (std.mem.eql(u8, mode, "--queue-only")) {
            cases = &.{.concurrent_queue};
        } else return error.InvalidMode;
    }
    probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io, .assets = try Assets.init() };
    try probe.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
