//! ThorVG renderer for fabrum.
//!
//! This renderer builds a ThorVG scene from layout commands.
//! It supports rectangles, borders, text, and scissor-based clipping.

const std = @import("std");
const fabrum = @import("fabrum");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.RenderCommand;
const CornerRadius = fabrum.CornerRadius;
const BorderWidths = fabrum.BorderWidths;
const LayoutContent = fabrum.LayoutContent;

pub const content = @import("content.zig");

allocator: std.mem.Allocator,
cg_context: *anyopaque,
text_context: content.Text.Context,

const Renderer = @This();

pub fn init(allocator: std.mem.Allocator, cg_context: *anyopaque) !Renderer {
    return .{
        .allocator = allocator,
        .cg_context = cg_context,
        .text_context = try .init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.* = undefined;
}

pub fn render(self: *Renderer, it: *RenderCommand.Iterator) !void {
    _ = self;
    _ = it;
    // while (it.next()) |cmd| {
    //     switch (cmd.data) {
    //         .scissor_start => {},
    //         .scissor_end => {},
    //         .rectangle => |r| {},
    //         .border => |b| {},
    //         .content => |c| {},
    //     }
    // }
}

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.TextStyle) content.Text {
    return .initContext(s, style, self.text_context);
}

test {
    _ = @import("text.zig");
    // std.testing.refAllDecls(@This());
}
