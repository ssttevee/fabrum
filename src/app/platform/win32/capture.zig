//! Client reconstruction, not a screen/desktop capture. HWND traversal and
//! composition belong here; the bridge only paints SDK controls and encodes PNG.
const std = @import("std");
const c = @import("win32_c");
const a = std.heap.page_allocator;
extern fn fabrum_d2d_image_create(u32, u32, f32, f32, f32) ?*anyopaque;
extern fn fabrum_d2d_target_destroy(*anyopaque) void;
extern fn fabrum_d2d_image_data(*anyopaque) ?[*]u8;
extern fn fabrum_d2d_capture_native(*anyopaque, c.HWND, c_int, c_int, c_int, c_int, c_int, c_int, bool) bool;
extern fn fabrum_d2d_write_png(*anyopaque, [*:0]const u8, u32, u32) bool;

pub const Canvas = struct { hwnd: c.HWND, pixels: []const u8, width: usize, height: usize };
const Item = struct { hwnd: c.HWND, parent: c.HWND, identity: isize, box: c.RECT, clip: c.RECT, pixels: ?[]u8 = null, width: usize = 0 };

fn clientInRoot(hwnd: c.HWND, root: c.HWND) c.RECT {
    var r: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &r);
    _ = c.MapWindowPoints(hwnd, root, @ptrCast(&r), 2);
    return r;
}

fn collect(root: c.HWND, hwnd: c.HWND, clip: c.RECT, canvases: []const Canvas, items: *std.ArrayList(Item)) !void {
    var child = c.GetWindow(hwnd, c.GW_CHILD);
    if (child == null) return;
    child = c.GetWindow(child, c.GW_HWNDLAST);
    while (child != null) : (child = c.GetWindow(child, c.GW_HWNDPREV)) {
        if (c.IsWindowVisible(child) == 0) continue;
        var box: c.RECT = undefined;
        _ = c.GetWindowRect(child, &box);
        _ = c.MapWindowPoints(null, root, @ptrCast(&box), 2);
        var bounded: c.RECT = undefined;
        if (c.IntersectRect(&bounded, &box, &clip) == 0) continue;
        var item: Item = .{ .hwnd = child, .parent = hwnd, .identity = c.GetWindowLongPtrW(child, c.GWLP_USERDATA), .box = box, .clip = bounded };
        for (canvases) |canvas| if (canvas.hwnd == child) {
            item.pixels = try a.dupe(u8, canvas.pixels);
            item.width = canvas.width;
            break;
        };
        items.append(a, item) catch |err| {
            if (item.pixels) |pixels| a.free(pixels);
            return err;
        };
        const client = clientInRoot(child, root);
        _ = c.IntersectRect(&bounded, &bounded, &client);
        try collect(root, child, bounded, canvases, items);
    }
}

pub fn snapshot(root: c.HWND, owner: isize, canvases: []const Canvas, path: [*:0]const u8, requested_scale: f64) bool {
    if (!std.math.isFinite(requested_scale) or requested_scale < 0 or c.IsIconic(root) != 0) return false;
    var r: c.RECT = undefined;
    if (c.GetClientRect(root, &r) == 0 or r.right <= 0 or r.bottom <= 0) return false;
    const factor = if (requested_scale == 0) 1 else requested_scale * 96 / @as(f64, @floatFromInt(c.GetDpiForWindow(root)));
    const output_w = @ceil(@as(f64, @floatFromInt(r.right)) * factor);
    const output_h = @ceil(@as(f64, @floatFromInt(r.bottom)) * factor);
    if (output_w < 1 or output_h < 1 or output_w > 32768 or output_h > 32768) return false;
    const target = fabrum_d2d_image_create(@intCast(r.right), @intCast(r.bottom), 1, 0, 0) orelse return false;
    defer fabrum_d2d_target_destroy(target);
    const pixels = fabrum_d2d_image_data(target) orelse return false;
    @memset(pixels[0 .. @as(usize, @intCast(r.right)) * @as(usize, @intCast(r.bottom)) * 4], 255);
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |item| if (item.pixels) |data| a.free(data);
        items.deinit(a);
    }
    // Copy canvas pixels before calling any application-controlled window proc.
    collect(root, root, r, canvases, &items) catch return false;
    if (!fabrum_d2d_capture_native(target, root, 0, 0, 0, 0, r.right, r.bottom, false)) return false;
    if (c.IsWindow(root) == 0 or c.GetWindowLongPtrW(root, c.GWLP_USERDATA) != owner) return false;
    for (items.items) |item| {
        if (c.IsWindow(item.hwnd) == 0 or c.GetParent(item.hwnd) != item.parent or c.GetWindowLongPtrW(item.hwnd, c.GWLP_USERDATA) != item.identity) return false;
        if (item.pixels) |source| {
            var y = item.clip.top;
            while (y < item.clip.bottom) : (y += 1) {
                var x = item.clip.left;
                while (x < item.clip.right) : (x += 1) {
                    const si = (@as(usize, @intCast(y - item.box.top)) * item.width + @as(usize, @intCast(x - item.box.left))) * 4;
                    if (si + 4 > source.len) return false;
                    const di = (@as(usize, @intCast(y)) * @as(usize, @intCast(r.right)) + @as(usize, @intCast(x))) * 4;
                    blend(pixels[di..][0..4], source[si..][0..4]);
                }
            }
        } else {
            if (!fabrum_d2d_capture_native(target, item.hwnd, item.box.left, item.box.top, item.clip.left, item.clip.top, item.clip.right, item.clip.bottom, true)) return false;
            if (c.IsWindow(root) == 0 or c.GetWindowLongPtrW(root, c.GWLP_USERDATA) != owner) return false;
        }
    }
    return fabrum_d2d_write_png(target, path, @intFromFloat(output_w), @intFromFloat(output_h));
}

fn blend(dst: *[4]u8, src: *const [4]u8) void {
    const inverse: u32 = 255 - @as(u32, src[3]);
    for (0..4) |i| dst[i] = @intCast(@min(255, @as(u32, src[i]) + (@as(u32, dst[i]) * inverse + 127) / 255));
}

test "client composition uses premultiplied source-over including transparent pixels" {
    var dst = [4]u8{ 255, 0, 0, 255 };
    blend(&dst, &.{ 0, 0, 128, 128 });
    try std.testing.expectEqual([4]u8{ 127, 0, 128, 255 }, dst);
    blend(&dst, &.{ 0, 0, 0, 0 });
    try std.testing.expectEqual([4]u8{ 127, 0, 128, 255 }, dst);
}
