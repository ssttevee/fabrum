//! Documented Win32 theme APIs only. No process-wide dark-mode switches.
const std = @import("std");
const c = @import("win32_c");
pub const colors = @import("palette.zig");
pub fn palette(dark: bool) colors.Palette {
    var hc = std.mem.zeroes(c.HIGHCONTRASTW);
    hc.cbSize = @sizeOf(c.HIGHCONTRASTW);
    // A failed accessibility query conservatively keeps system colors.
    const accessible = c.SystemParametersInfoW(c.SPI_GETHIGHCONTRAST, hc.cbSize, &hc, 0) == 0 or (hc.dwFlags & c.HCF_HIGHCONTRASTON) != 0;
    return colors.resolve(dark, accessible, .{
        .background = c.GetSysColor(c.COLOR_WINDOW),
        .control = c.GetSysColor(c.COLOR_BTNFACE),
        .input = c.GetSysColor(c.COLOR_WINDOW),
        .text = c.GetSysColor(c.COLOR_WINDOWTEXT),
        .secondary = c.GetSysColor(c.COLOR_GRAYTEXT),
        .separator = c.GetSysColor(c.COLOR_3DSHADOW),
        .accent = c.GetSysColor(c.COLOR_HIGHLIGHT),
    });
}
pub fn frame(hwnd: c.HWND, dark: bool) void {
    const enabled: c.BOOL = @intFromBool(dark);
    // Unsupported OS versions return HRESULT failure and retain system chrome.
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &enabled, @sizeOf(c.BOOL));
}
pub fn brush(dc: c.HDC, color: u32) c.HBRUSH {
    _ = c.SetDCBrushColor(dc, color);
    return c.GetStockObject(c.DC_BRUSH);
}
pub fn erase(hwnd: c.HWND, dc: c.HDC, color: u32) c.LRESULT {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    _ = c.FillRect(dc, &rect, brush(dc, color));
    return 1;
}
pub fn controlColor(dc: c.HDC, background: u32, text: u32) c.LRESULT {
    _ = c.SetTextColor(dc, text);
    _ = c.SetBkColor(dc, background);
    return @bitCast(@intFromPtr(brush(dc, background)));
}
pub fn font(hwnd: c.HWND, points: f64) c.HFONT {
    var metrics = std.mem.zeroes(c.NONCLIENTMETRICSW);
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    const dpi = c.GetDpiForWindow(hwnd);
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0, dpi) == 0) return null;
    if (points > 0) metrics.lfMessageFont.lfHeight = -@as(c_long, @intFromFloat(std.math.clamp(@round(points * @as(f64, @floatFromInt(dpi)) / 72), 1, 2147483647)));
    return c.CreateFontIndirectW(&metrics.lfMessageFont);
}

/// Child HWNDs borrow the replacement before the previous owned font is freed.
pub fn refreshChildFont(hwnd: c.HWND, owned: *c.HFONT, points: f64) void {
    const replacement = font(hwnd, points) orelse return;
    const old = owned.*;
    owned.* = replacement;
    var child = c.GetWindow(hwnd, c.GW_CHILD);
    while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) {
        _ = c.SendMessageW(child, c.WM_SETFONT, @intFromPtr(replacement), 1);
    }
    if (old != null) _ = c.DeleteObject(old);
}
