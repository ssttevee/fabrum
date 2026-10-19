const std = @import("std");
const fabrum = @import("../../root.zig");
const UIFont = @import("text.zig").Font;

const Vec2 = fabrum.Vec2;

pub const Picture = @import("content/picture.zig");

pub const Text = fabrum.layout.text.Content(
    struct {
        inner: fabrum.layout.text.CachedContext(struct {
            pub fn measureText(self: @This(), text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
                _ = self;

                const font = UIFont.forStyle(style);
                defer font.deinit();
                return font.measureText(text);
            }

            pub fn deinit(self: *@This()) void {
                self.* = undefined;
            }
        }),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .inner = try .init(allocator, .{}),
            };
        }

        pub fn measureText(self: @This(), text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
            return self.inner.measureText(text, style);
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    },
);

test "text with an ellipsis is cut to fit by Core Text's measurements" {
    var context: Text.Context = try .init(std.testing.allocator);
    defer context.deinit();

    const name = "raspios-bookworm-arm64-lite.img.xz";
    const style: fabrum.layout.text.Style = .{ .font_size = 15, .wrap_mode = .none, .overflow = .ellipsis_middle };
    const full = try context.measureText(name, style);

    const text: Text = .initContext(name, style, context);
    var lines = text.lines(full.x / 2);
    const line = (try lines.next()).?;

    try std.testing.expect(std.mem.indexOf(u8, line, fabrum.layout.text.ellipsis) != null);
    try std.testing.expect(std.mem.startsWith(u8, line, "rasp"));
    try std.testing.expect(std.mem.endsWith(u8, line, ".xz"));
    try std.testing.expect((try context.measureText(line, style)).x <= full.x / 2);

    // the whole name is drawn when it fits
    lines = text.lines(full.x);
    try std.testing.expectEqualStrings(name, (try lines.next()).?);
}
