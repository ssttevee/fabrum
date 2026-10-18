const std = @import("std");
const fabrum = @import("fabrum");
const UIFont = @import("text.zig").Font;

const Vec2 = fabrum.Vec2;

pub const Picture = @import("content/picture.zig");

pub const Text = fabrum.layout.text.Content(
    struct {
        inner: fabrum.layout.text.CachedContext(struct {
            pub fn measureText(self: @This(), text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
                _ = self;

                const font = (if (style.font_family) |font_family| UIFont.fromFamilyName(font_family, style.font_size, style.font_weight) else null) orelse UIFont.systemFont(style.font_size, style.font_weight);
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
