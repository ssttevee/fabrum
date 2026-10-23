//! Per-window color policy, independent of HWNDs and global preferences.
const std = @import("std");
pub const Palette = struct {
    background: u32,
    control: u32,
    input: u32,
    text: u32,
    secondary: u32,
    separator: u32,
    accent: u32,
    dark: bool = false,
};
pub fn resolve(dark: bool, high_contrast: bool, system: Palette) Palette {
    if (high_contrast or !dark) return system;
    return .{ .background = 0x202020, .control = 0x303030, .input = 0x303030, .text = 0xf0f0f0, .secondary = 0xb4b4b4, .separator = 0x606060, .accent = 0xffb366, .dark = true };
}
pub fn rgba(color: u32) [4]f64 {
    return .{ @as(f64, @floatFromInt(color & 255)) / 255, @as(f64, @floatFromInt((color >> 8) & 255)) / 255, @as(f64, @floatFromInt((color >> 16) & 255)) / 255, 1 };
}
test "explicit preferences are isolated and accessibility takes precedence" {
    const system: Palette = .{ .background = 0xffffff, .input = 0xffffff, .control = 0, .text = 0, .secondary = 0x808080, .separator = 0xaaaaaa, .accent = 0xff0000 };
    const dark = resolve(true, false, system);
    try std.testing.expect(dark.dark);
    try std.testing.expect(dark.background != system.background);
    try std.testing.expectEqual(system, resolve(false, false, system));
    try std.testing.expectEqual(system, resolve(true, true, system));
    try std.testing.expectEqual(dark, resolve(true, false, system));
    try std.testing.expectEqual([4]f64{ 1, 0, 0, 1 }, rgba(0x0000ff));
    try std.testing.expectEqual([4]f64{ 0, 0, 1, 1 }, rgba(0xff0000));
}
