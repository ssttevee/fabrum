//! Standalone GDI lifetime oracle: no Fabrum host, child windows or message pump.
//! GetObjectType is deliberately observed, never used as a validity predicate.
const std = @import("std");
const H = *anyopaque;
const Font = extern struct { height: i32 = -19, rest: [88]u8 = @splat(0) };
extern "gdi32" fn CreateFontIndirectW(*const Font) callconv(.winapi) ?H;
extern "gdi32" fn GetObjectW(H, c_int, *Font) callconv(.winapi) c_int;
extern "gdi32" fn GetObjectType(H) callconv(.winapi) u32;
extern "gdi32" fn DeleteObject(H) callconv(.winapi) c_int;
extern "user32" fn GetGuiResources(H, u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) H;
pub fn main() !void {
    var stale: usize = 0;
    const baseline = GetGuiResources(GetCurrentProcess(), 0);
    for (0..20000) |i| {
        var lf: Font = .{ .height = -@as(i32, @intCast(12 + i % 50)) };
        const h = CreateFontIndirectW(&lf) orelse return error.CreateFailed;
        if (GetObjectW(h, @sizeOf(Font), &lf) != @sizeOf(Font)) return error.UnreadableLiveFont;
        const deleted = DeleteObject(h);
        const kind = GetObjectType(h);
        const readable = GetObjectW(h, @sizeOf(Font), &lf);
        if (deleted == 0 or readable != 0) return error.DeleteFailed;
        if (kind != 0) {
            if (stale < 3) std.debug.print("deleted={d} handle={x} type={d} readable={d}\n", .{ deleted, @intFromPtr(h), kind, readable });
            stale += 1;
        }
    }
    const final = GetGuiResources(GetCurrentProcess(), 0);
    if (final > baseline + 1) return error.ResourceGrowth;
    std.debug.print("font-probe PASS cycles=20000 stale_type={d} GDI={d}->{d}\n", .{ stale, baseline, final });
}
