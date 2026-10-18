//! Quartz renderer for fabrum.
//!
//! This renderer uses macOS Core Graphics (Quartz) to render layout commands.
//! It supports rectangles, borders, text, and clipping.

const std = @import("std");
const fabrum = @import("fabrum");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const BorderWidths = fabrum.layout.BorderWidths;
const LayoutContent = fabrum.layout.Content;

pub const content = @import("content.zig");

const Picture = content.Picture;
const CGImage = Picture.CGImage;

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

        if (Picture.asPictureContent(c)) |picture_content| {
            try self.renderPicture(bbox, picture_content);
            return;
        }
    }

    fn renderPicture(self: *CGContext, bbox: Rect, picture_content: *const Picture) !void {
        switch (picture_content.source) {
            .vector => |vector| try self.renderVectorPicture(bbox, vector, picture_content.style),
            .bitmap => |bitmap| self.renderBitmapPicture(bbox, bitmap, picture_content.style),
        }
    }

    fn renderVectorPicture(self: *CGContext, bbox: Rect, vector: Picture.Source.Vector, style: Picture.Style) !void {
        var scale_x: f32 = 1.0;
        var scale_y: f32 = 1.0;
        var offset_x: f32 = bbox.x;
        var offset_y: f32 = bbox.y;

        scale_x = bbox.w / vector.viewbox.w;
        scale_y = bbox.h / vector.viewbox.h;

        switch (style.fit_mode) {
            .contain => {
                const scale = @min(scale_x, scale_y);
                scale_x = scale;
                scale_y = scale;

                const scaled_w = vector.viewbox.w * scale;
                const scaled_h = vector.viewbox.h * scale;
                offset_x += (bbox.w - scaled_w) / 2.0;
                offset_y += (bbox.h - scaled_h) / 2.0;
            },
            .cover => {
                const scale = @max(scale_x, scale_y);
                scale_x = scale;
                scale_y = scale;

                const scaled_w = vector.viewbox.w * scale;
                const scaled_h = vector.viewbox.h * scale;
                offset_x += (bbox.w - scaled_w) / 2.0;
                offset_y += (bbox.h - scaled_h) / 2.0;
            },
            .crop => {
                scale_x = 1.0;
                scale_y = 1.0;
            },
            .stretch => {},
        }

        offset_x -= vector.viewbox.x * scale_x;
        offset_y -= vector.viewbox.y * scale_y;

        quartz_renderer_draw_path(
            self,
            vector.path,
            offset_x,
            offset_y,
            scale_x,
            scale_y,
            style.color.r,
            style.color.g,
            style.color.b,
            style.color.a,
            0,
            0,
            0,
            0,
            0,
        );
    }

    fn renderBitmapPicture(self: *CGContext, bbox: Rect, bitmap: Picture.Source.Bitmap, style: Picture.Style) void {
        var draw_width: f32 = bitmap.width;
        var draw_height: f32 = bitmap.height;
        var offset_x: f32 = bbox.x;
        var offset_y: f32 = bbox.y;

        const scale_x = bbox.w / bitmap.width;
        const scale_y = bbox.h / bitmap.height;

        switch (style.fit_mode) {
            .contain => {
                const scale = @min(scale_x, scale_y);
                draw_width = bitmap.width * scale;
                draw_height = bitmap.height * scale;
                offset_x += (bbox.w - draw_width) / 2.0;
                offset_y += (bbox.h - draw_height) / 2.0;
            },
            .cover => {
                const scale = @max(scale_x, scale_y);
                draw_width = bitmap.width * scale;
                draw_height = bitmap.height * scale;
                offset_x += (bbox.w - draw_width) / 2.0;
                offset_y += (bbox.h - draw_height) / 2.0;
            },
            .crop => {
                offset_x += (bbox.w - bitmap.width) / 2.0;
                offset_y += (bbox.h - bitmap.height) / 2.0;
            },
            .stretch => {
                draw_width = bbox.w;
                draw_height = bbox.h;
            },
        }

        quartz_renderer_draw_image(
            self,
            bitmap.image,
            offset_x,
            offset_y,
            draw_width,
            draw_height,
        );
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

/// The text content this renderer measures and draws, for
/// `fabrum.app.Runtime`'s `Config.Text`.
pub const Text = content.Text;

pub fn render(self: *Renderer, it: *RenderCommand.Iterator, cg_context: *CGContext) !void {
    while (it.next()) |cmd| try self.renderCommand(cmd, cg_context);
}

/// Draws commands already taken from a layout, such as one canvas layer of
/// a window that interleaves drawn content with native views.
pub fn renderCommands(self: *Renderer, commands: []const RenderCommand, cg_context: *CGContext) !void {
    for (commands) |cmd| try self.renderCommand(cmd, cg_context);
}

/// Draws one command.
pub fn renderCommand(self: *Renderer, cmd: RenderCommand, cg_context: *CGContext) !void {
    _ = self;
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

pub fn text(self: *const Renderer, s: []const u8, style: fabrum.layout.text.Style) content.Text {
    return .initContext(s, style, self.text_context);
}

pub fn svgPicture(allocator: std.mem.Allocator, svg_data: []const u8) !Picture {
    return Picture.fromSVG(allocator, svg_data);
}

pub fn bitmapPicture(image_ref: *CGImage, width: f32, height: f32, owns_image: bool) Picture {
    return Picture.fromCGImage(image_ref, width, height, owns_image);
}

pub fn bitmapPictureFromCGImage(image_ref: *CGImage, owns_image: bool) Picture {
    const width = cgimage_get_width(image_ref);
    const height = cgimage_get_height(image_ref);
    return Picture.fromCGImage(image_ref, @floatCast(width), @floatCast(height), owns_image);
}

fn isAllZero(cr: CornerRadius) bool {
    return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
}

const CGFloat = f64;
pub const CGPath = @import("content/picture/svg.zig").CGPath;

extern fn quartz_renderer_flip_canvas(self: *CGContext, height: CGFloat) callconv(.c) void;

extern fn quartz_renderer_save_state(context: *CGContext) void;
extern fn quartz_renderer_restore_state(context: *CGContext) void;
extern fn quartz_renderer_clip_to_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) void;
extern fn quartz_renderer_fill_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_fill_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_stroke_rounded_rect(context: *CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, top_left: CGFloat, top_right: CGFloat, bottom_right: CGFloat, bottom_left: CGFloat, line_width: CGFloat, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_draw_text(context: *CGContext, text: [*]const u8, text_len: usize, x: CGFloat, y: CGFloat, font: *const Font, r: u8, g: u8, b: u8, a: u8) void;
extern fn quartz_renderer_draw_path(context: *CGContext, path: *const CGPath, x: CGFloat, y: CGFloat, scale_x: CGFloat, scale_y: CGFloat, fill_r: u8, fill_g: u8, fill_b: u8, fill_a: u8, stroke_r: u8, stroke_g: u8, stroke_b: u8, stroke_a: u8, stroke_width: CGFloat) void;
extern fn quartz_renderer_draw_image(context: *CGContext, image: *CGImage, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) void;

extern fn cgimage_get_width(image: *CGImage) CGFloat;
extern fn cgimage_get_height(image: *CGImage) CGFloat;

test {
    std.testing.refAllDecls(@This());
}
