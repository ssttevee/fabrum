//! Quartz renderer for fabrum.
//!
//! This renderer uses macOS Core Graphics (Quartz) to render layout commands.
//! It supports rectangles, borders, text, and clipping.

const std = @import("std");
const fabrum = @import("fabrum");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.RenderCommand;
const CornerRadius = fabrum.CornerRadius;
const BorderWidths = fabrum.BorderWidths;
const LayoutContent = fabrum.LayoutContent;

pub const content = @import("content.zig");

const Font = @import("text.zig").Font;

allocator: std.mem.Allocator,
text_context: content.Text.Context,

const Renderer = @This();

pub const CGContext = opaque {
    pub fn flipCanvas(self: *CGContext, height: f64) void {
        quartz_renderer_flip_canvas(self, height);
    }

    fn renderRectangle(cg_context: *CGContext, bbox: Rect, corner_radius: CornerRadius, color: Color) void {
        const cr = corner_radius.fitted(bbox.w, bbox.h);

        if (isAllZero(cr)) {
            quartz_renderer_fill_rect(
                cg_context,
                bbox.x,
                bbox.y,
                bbox.w,
                bbox.h,
                color.r,
                color.g,
                color.b,
                color.a,
            );
        } else {
            quartz_renderer_fill_rounded_rect(
                cg_context,
                bbox.x,
                bbox.y,
                bbox.w,
                bbox.h,
                cr.top_left,
                cr.top_right,
                cr.bottom_right,
                cr.bottom_left,
                color.r,
                color.g,
                color.b,
                color.a,
            );
        }
    }

    fn renderBorder(cg_context: *CGContext, bbox: Rect, b: RenderCommand.Data.Border) void {
        const bw = b.widths;
        const color = b.color;

        if (bw.left == 0 and bw.right == 0 and bw.top == 0 and bw.bottom == 0) return;

        if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
            const half_width = bw.left / 2.0;
            const inset_bbox = Rect{
                .x = bbox.x + half_width,
                .y = bbox.y + half_width,
                .w = bbox.w - bw.left,
                .h = bbox.h - bw.top,
            };

            const cr = b.corner_radius.fitted(bbox.w, bbox.h);

            if (isAllZero(cr)) {
                quartz_renderer_stroke_rect(
                    cg_context,
                    inset_bbox.x,
                    inset_bbox.y,
                    inset_bbox.w,
                    inset_bbox.h,
                    bw.left,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            } else {
                const adjusted_cr = CornerRadius{
                    .top_left = @max(0, cr.top_left - half_width),
                    .top_right = @max(0, cr.top_right - half_width),
                    .bottom_right = @max(0, cr.bottom_right - half_width),
                    .bottom_left = @max(0, cr.bottom_left - half_width),
                };

                quartz_renderer_stroke_rounded_rect(
                    cg_context,
                    inset_bbox.x,
                    inset_bbox.y,
                    inset_bbox.w,
                    inset_bbox.h,
                    adjusted_cr.top_left,
                    adjusted_cr.top_right,
                    adjusted_cr.bottom_right,
                    adjusted_cr.bottom_left,
                    bw.left,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }
        } else {
            if (bw.top > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y,
                    bbox.w,
                    bw.top,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.bottom > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y + bbox.h - bw.bottom,
                    bbox.w,
                    bw.bottom,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.left > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x,
                    bbox.y,
                    bw.left,
                    bbox.h,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }

            if (bw.right > 0) {
                quartz_renderer_fill_rect(
                    cg_context,
                    bbox.x + bbox.w - bw.right,
                    bbox.y,
                    bw.right,
                    bbox.h,
                    color.r,
                    color.g,
                    color.b,
                    color.a,
                );
            }
        }
    }

    fn renderContent(self: *CGContext, bbox: Rect, c: *LayoutContent) !void {
        if (content.Text.asTextContent(c)) |text_content| {
            try self.renderText(bbox, text_content);
            return;
        }
    }

    fn renderText(self: *CGContext, bbox: Rect, text_content: *const content.Text) !void {
        var lines = text_content.linesWithSizes(bbox.w);
        var line_index: usize = 0;

        var y_pos: f32 = bbox.y;
        while (try lines.next()) |line| : (line_index += 1) {
            const font = (if (text_content.style.font_family) |font_family|
                Font.fromFamilyName(font_family, text_content.style.font_size, text_content.style.font_weight)
            else
                null) orelse Font.systemFont(text_content.style.font_size, text_content.style.font_weight);
            defer font.deinit();

            const x_pos = bbox.x + switch (text_content.style.alignment) {
                .left => 0,
                .center => (bbox.w - line.size.x) / 2,
                .right => bbox.w - line.size.x,
            };

            quartz_renderer_draw_text(
                self,
                line.text.ptr,
                line.text.len,
                x_pos,
                y_pos,
                font,
                text_content.style.color.r,
                text_content.style.color.g,
                text_content.style.color.b,
                text_content.style.color.a,
            );

            y_pos += line.size.y;
        }
    }
};

pub fn init(allocator: std.mem.Allocator) !Renderer {
    return .{
        .allocator = allocator,
        .text_context = try content.Text.Context.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.text_context.deinit();
    self.* = undefined;
}

pub fn render(self: *Renderer, it: *RenderCommand.Iterator, cg_context: *CGContext) !void {
    _ = self;

    while (it.next()) |cmd| {
        switch (cmd.data) {
            .scissor_start => {
                quartz_renderer_save_state(cg_context);
                quartz_renderer_clip_to_rect(
                    cg_context,
                    cmd.bbox.x,
                    cmd.bbox.y,
                    cmd.bbox.w,
                    cmd.bbox.h,
                );
            },
            .scissor_end => {
                quartz_renderer_restore_state(cg_context);
            },
            .rectangle => |r| {
                cg_context.renderRectangle(cmd.bbox, r.corner_radius, r.color);
            },
            .border => |b| {
                cg_context.renderBorder(cmd.bbox, b);
            },
            .content => |c| {
                try cg_context.renderContent(cmd.bbox, c);
            },
        }
    }
}

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.TextStyle) content.Text {
    return .initContext(s, style, self.text_context);
}

fn isAllZero(cr: CornerRadius) bool {
    return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
}

const CGFloat = f64;

extern fn quartz_renderer_flip_canvas(self: *CGContext, height: CGFloat) callconv(.c) void;

extern fn quartz_renderer_save_state(context: *CGContext) void;
extern fn quartz_renderer_restore_state(context: *CGContext) void;
extern fn quartz_renderer_clip_to_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) void;
extern fn quartz_renderer_fill_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_fill_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_draw_text(context: *CGContext, text: [*]const u8, text_len: usize, x: CGFloat, y: CGFloat, font: *const Font, r: u8, g: u8, b: u8, a: u8) void;

test {
    std.testing.refAllDecls(@This());
}
