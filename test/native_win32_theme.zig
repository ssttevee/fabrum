//! Synchronous desktop regression; never changes Windows/user settings.
//! Theme notifications are local messages, not simulated system color changes.
const std = @import("std");
const fabrum = @import("fabrum");
const platform = fabrum.app.platform.win32;
const H = *anyopaque;
const long_message = blk: {
    const line = "Unicode Ω body with wrapped words\r\n";
    var result: [line.len * 200]u8 = undefined;
    for (0..200) |i| @memcpy(result[i * line.len ..][0..line.len], line);
    break :blk result;
};
extern "user32" fn SendMessageW(H, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetDC(H) callconv(.winapi) ?H;
extern "user32" fn ReleaseDC(H, H) callconv(.winapi) c_int;
extern "user32" fn GetParent(H) callconv(.winapi) ?H;
extern "user32" fn GetDlgItem(H, c_int) callconv(.winapi) ?H;
extern "user32" fn GetDlgCtrlID(H) callconv(.winapi) c_int;
extern "user32" fn GetLastActivePopup(H) callconv(.winapi) H;
extern "user32" fn ShowWindow(H, c_int) callconv(.winapi) c_int;
extern "user32" fn SetFocus(H) callconv(.winapi) ?H;
extern "user32" fn GetFocus() callconv(.winapi) ?H;
extern "user32" fn IsWindowEnabled(H) callconv(.winapi) c_int;
extern "user32" fn GetGuiResources(H, u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) H;
extern "gdi32" fn GetTextColor(H) callconv(.winapi) u32;
extern "gdi32" fn GetBkColor(H) callconv(.winapi) u32;
extern "gdi32" fn GetObjectType(H) callconv(.winapi) u32;
extern "uxtheme" fn GetWindowTheme(H) callconv(.winapi) ?H;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Monitor = extern struct { size: u32 = @sizeOf(Monitor), monitor: Rect = undefined, work: Rect = undefined, flags: u32 = 0 };
const LogFont = extern struct { height: i32, rest: [88]u8 };
extern "user32" fn GetWindowRect(H, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(H, *Rect) callconv(.winapi) c_int;
extern "user32" fn MapWindowPoints(?H, ?H, *[2]Point, u32) callconv(.winapi) c_int;
const Point = extern struct { x: i32, y: i32 };
const Message = extern struct { hwnd: ?H, message: u32, wparam: usize, lparam: isize, time: u32 = 0, point: Point = .{ .x = 0, .y = 0 } };
extern "user32" fn IsDialogMessageW(H, *Message) callconv(.winapi) c_int;
const ScrollInfo = extern struct { size: u32 = @sizeOf(ScrollInfo), mask: u32 = 0x17, min: i32 = 0, max: i32 = 0, page: u32 = 0, pos: i32 = 0, track: i32 = 0 };
extern "user32" fn GetScrollInfo(H, c_int, *ScrollInfo) callconv(.winapi) c_int;
extern "user32" fn MonitorFromWindow(H, u32) callconv(.winapi) H;
extern "user32" fn GetMonitorInfoW(H, *Monitor) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(H) callconv(.winapi) u32;
extern "gdi32" fn GetObjectW(H, c_int, *LogFont) callconv(.winapi) c_int;
const Root = struct {
    pub const Props = struct {};
    pub const State = struct {};
    pub fn view(ui: *fabrum.app.Ui, _: *const State, _: Props) !void {
        try ui.text("Theme regression", .{});
    }
};
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-theme FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
}
fn colorRef(color: fabrum.Color) u32 {
    return @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16);
}
fn font(hwnd: H) H {
    const f = SendMessageW(hwnd, 0x31, 0, 0);
    check(f != 0, "owned font installed");
    return @ptrFromInt(@as(usize, @bitCast(f)));
}
fn colors(hwnd: H, msg: u32, expected_text: u32, expected_bg: u32) void {
    const dc = GetDC(hwnd).?;
    defer _ = ReleaseDC(hwnd, dc);
    check(SendMessageW(GetParent(hwnd).?, msg, @intFromPtr(dc), @bitCast(@intFromPtr(hwnd))) != 0, "native color handler supplies brush");
    check(GetTextColor(dc) == expected_text and GetBkColor(dc) == expected_bg, "native text/background agree with drawn palette");
}
fn visibleInClient(dialog: H, child: H) bool {
    var rect: Rect = undefined;
    var client: Rect = undefined;
    _ = GetWindowRect(child, &rect);
    _ = MapWindowPoints(null, dialog, @ptrCast(&rect), 2);
    _ = GetClientRect(dialog, &client);
    const visible = rect.left >= 0 and rect.top >= 0 and rect.right <= client.right and rect.bottom <= client.bottom;
    if (!visible) std.debug.print("client visibility: control=({d},{d})-({d},{d}), client=({d},{d})\n", .{ rect.left, rect.top, rect.right, rect.bottom, client.right, client.bottom });
    return visible;
}
pub fn main(init: std.process.Init) !void {
    var light: platform.App(Root) = undefined;
    try light.init(init.gpa, init.io, .{}, .{ .title = "Light theme regression" }, .{});
    defer light.deinit();
    var dark: platform.App(Root) = undefined;
    try dark.init(init.gpa, init.io, .{}, .{ .title = "Dark theme regression", .dark = true }, .{});
    defer dark.deinit();
    const lb = light.backend.backend();
    const db = dark.backend.backend();
    const lt = lb.theme();
    const dt = db.theme();
    dark.automation().injectTheme(null, false, 18);
    // A real high-contrast session is allowed to override the dark preference.
    if (dt.dark) check(!lt.dark and !std.meta.eql(lt.window_background, dt.window_background), "simultaneous explicit light/dark windows are isolated");
    const label = try db.create(1, &.{ .label = .{ .text = "Readable Ω text" } }, &.none, null);
    defer db.destroy(label);
    const field = try db.create(2, &.{ .text_field = .{} }, &.{ .text = "Focus survives refresh" }, null);
    defer db.destroy(field);
    const light_label = try lb.create(1, &.{ .label = .{ .text = "Light text" } }, &.none, null);
    defer lb.destroy(light_label);
    const checkbox = try db.create(4, &.{ .checkbox = .{ .title = "Dark checkbox" } }, &.{ .toggle = true }, null);
    defer db.destroy(checkbox);
    const ch = platform.automation.widgetHwnd(checkbox).?;
    if (dt.dark) check(GetWindowTheme(ch) == null, "dark checkbox uses documented classic renderer for custom text colors");
    const lh = platform.automation.widgetHwnd(label).?;
    const fh = platform.automation.widgetHwnd(field).?;
    _ = ShowWindow(dark.hwnd(), 5);
    _ = SetFocus(fh);
    check(GetFocus() == fh, "native field focused before refresh");
    const hc: platform.automation.SystemColors = .{ .background = 0, .input = 0, .control = 0xffffff, .text = 0xffffff, .secondary = 0x00ffff, .separator = 0xff00ff, .accent = 0xffff00 };
    dark.automation().injectTheme(hc, true, 18);
    check(!db.theme().dark and colorRef(db.theme().window_background) == 0 and colorRef(db.theme().control_background) == 0xffffff, "injected high contrast overrides dark with distinct window/button surfaces");
    colors(lh, 0x138, 0xffffff, 0);
    colors(fh, 0x133, 0xffffff, 0);
    check(std.meta.eql(lt, lb.theme()), "injected accessibility input is per-window");
    dark.automation().injectTheme(hc, false, 18);
    check(db.theme().dark and colorRef(db.theme().window_background) == 0x202020, "leaving injected high contrast restores explicit dark preference");
    dark.automation().injectTheme(null, false, 18);
    var baseline: u32 = 0;
    for (0..25) |cycle| {
        for ([_]u32{ 0x1a, 0x31a, 0x15 }) |message| _ = SendMessageW(dark.hwnd(), message, 0, 0);
        check(GetFocus() == fh, "theme/font refresh preserves focus");
        check(std.meta.eql(lt, lb.theme()) and std.meta.eql(dt, db.theme()), "local refresh preserves each window preference");
        colors(lh, 0x138, colorRef(dt.text), colorRef(dt.window_background));
        colors(ch, 0x135, colorRef(dt.text), colorRef(dt.window_background));
        check(SendMessageW(ch, 0xf0, 0, 0) == 1, "theme refresh preserves native checkbox state");
        colors(fh, 0x133, colorRef(dt.text), colorRef(if (dt.dark) dt.control_background else dt.window_background));
        colors(platform.automation.widgetHwnd(light_label).?, 0x138, colorRef(lt.text), colorRef(lt.window_background));
        const alert = try db.create(3, &.{ .alert = .{ .title = "Owned dialog font", .message = &long_message, .buttons = &.{ "A longer localized button caption", "Cancel" } } }, &.none, null);
        const dialog = GetLastActivePopup(dark.hwnd());
        check(dialog != dark.hwnd() and IsWindowEnabled(dark.hwnd()) == 0, "owned modal dialog disables its window");
        const body = GetDlgItem(dialog, 99).?;
        const button = GetDlgItem(dialog, 100).?;
        const old = font(body);
        check(font(button) == old and GetObjectType(old) == 6, "dialog children borrow one live owned HFONT");
        var lf: LogFont = undefined;
        check(GetObjectW(old, @sizeOf(LogFont), &lf) == @sizeOf(LogFont) and @abs(lf.height) == @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(GetDpiForWindow(dialog))) * 18 / 72))), "owned enlarged dialog font follows its HWND DPI");
        var rect: Rect = undefined;
        _ = GetWindowRect(dialog, &rect);
        var monitor: Monitor = .{};
        check(GetMonitorInfoW(MonitorFromWindow(dialog, 2), &monitor) != 0, "monitor work area available");
        check(rect.left >= monitor.work.left and rect.top >= monitor.work.top and rect.right <= monitor.work.right and rect.bottom <= monitor.work.bottom, "long enlarged-font dialog fits monitor work area");
        var button_rect: Rect = undefined;
        _ = GetWindowRect(button, &button_rect);
        check(button_rect.bottom <= monitor.work.bottom, "response buttons remain reachable");
        _ = SendMessageW(body, 0xb6, 0, 100); // EM_LINESCROLL
        check(SendMessageW(body, 0xce, 0, 0) > 0, "overflowing read-only body scrolls");
        _ = SendMessageW(dialog, 0x2e0, @as(usize, GetDpiForWindow(dialog)) * 0x10001, @bitCast(@intFromPtr(&rect)));
        colors(body, 0x138, colorRef(dt.text), colorRef(dt.window_background));
        _ = SendMessageW(dark.hwnd(), 0x1a, 0, 0);
        check(font(body) == font(button) and GetObjectType(font(body)) == 6, "open dialog gets replacement live font on settings notification");
        const final_font = font(body);
        db.destroy(alert);
        check(GetObjectType(final_font) == 0, "unique enlarged dialog font released after child HWND destruction");
        check(IsWindowEnabled(dark.hwnd()) != 0 and GetFocus() == fh, "modal teardown restores owner and focus");
        const count = GetGuiResources(GetCurrentProcess(), 0);
        if (cycle == 1) baseline = count;
        if (cycle > 1) check(count <= baseline + 2, "refresh and owned dialog cycles do not accumulate GDI objects");
    }
    var many_buttons: [60][]const u8 = undefined;
    @memset(&many_buttons, "Response Ω");
    const many = try db.create(5, &.{ .alert = .{ .title = "Scrollable responses", .message = &long_message, .buttons = &many_buttons } }, &.none, null);
    const dialog = GetLastActivePopup(dark.hwnd());
    var monitor: Monitor = .{};
    check(GetMonitorInfoW(MonitorFromWindow(dialog, 2), &monitor) != 0, "many-button monitor work area available");
    var rect: Rect = undefined;
    _ = GetWindowRect(dialog, &rect);
    check(rect.top >= monitor.work.top and rect.bottom <= monitor.work.bottom, "60-button dialog stays within monitor work area");
    _ = SendMessageW(dialog, 0x115, 7, 0); // WM_VSCROLL / SB_BOTTOM
    const last = GetDlgItem(dialog, 159).?;
    _ = GetWindowRect(last, &rect);
    check(rect.top >= monitor.work.top and rect.bottom <= monitor.work.bottom, "scrollbar reaches last response without dropping buttons");
    check(visibleInClient(dialog, last), "scrollbar reveals last response fully inside dialog client area");
    // SB_BOTTOM can scroll the still-focused default response out of view.
    // SetFocus on that same HWND emits no BN_SETFOCUS. Start at the visible
    // last response so every iteration below exercises a real focus change.
    _ = SetFocus(last);
    check(GetFocus() == last, "focus starts on visible last response");
    for (0..60) |i| {
        const button = GetDlgItem(dialog, @intCast(100 + i)) orelse @panic("missing response button");
        const already_focused = GetFocus() == button;
        _ = SetFocus(button);
        _ = GetWindowRect(button, &rect);
        check(GetFocus() == button and rect.top >= monitor.work.top and rect.bottom <= monitor.work.bottom, "every response scrolls into view on keyboard focus");
        const visible = visibleInClient(dialog, button);
        if (!visible) {
            var info: ScrollInfo = .{};
            _ = GetScrollInfo(dialog, 1, &info);
            std.debug.print("response index={d}; SetFocus target already focused={any}; scroll pos={d}, max={d}, page={d}\n", .{ i, already_focused, info.pos, info.max, info.page });
        }
        check(visible, "focused response is fully inside dialog client area");
    }
    var tab: Message = .{ .hwnd = last, .message = 0x100, .wparam = 9, .lparam = 1 }; // WM_KEYDOWN / VK_TAB
    check(IsDialogMessageW(dialog, &tab) != 0, "native dialog consumes Tab from last response");
    const body = GetDlgItem(dialog, 99).?;
    check(GetFocus() == body and visibleInClient(dialog, body), "Tab wraps to body and scrolls it fully into dialog client area");
    for (0..60) |i| {
        tab = .{ .hwnd = GetFocus(), .message = 0x100, .wparam = 9, .lparam = 1 };
        check(IsDialogMessageW(dialog, &tab) != 0, "native dialog consumes Tab to response");
        const focused = GetDlgItem(dialog, @intCast(100 + i)).?;
        if (GetFocus() != focused) std.debug.print("Tab index={d}; actual focused ID={d}, expected={d}; dlgcode={x}\n", .{ i, GetDlgCtrlID(GetFocus().?), 100 + i, SendMessageW(GetFocus().?, 0x87, 9, @bitCast(@intFromPtr(&tab))) });
        check(GetFocus() == focused and visibleInClient(dialog, focused), "Tab navigation reveals every response within dialog client area");
    }
    db.destroy(many);
    check(GetFocus() == fh, "scrolling response dialog restores prior native focus");
    std.debug.print("native-win32-theme PASS (25 refresh/dialog cycles; 60 reachable responses; local notifications; no system settings changed)\n", .{});
}
