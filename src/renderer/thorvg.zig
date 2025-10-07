//! ThorVG renderer for zig-layout.
//!
//! This renderer builds a ThorVG scene from layout commands.
//! It supports rectangles, borders, text, and scissor-based clipping.
//!
//! Example usage:
//! ```
//! const tvg = @import("thorvg");
//! const fabrum = @import("fabrum");
//!
//! // Initialize ThorVG
//! var engines = tvg.Engines.sw;
//! try engines.init(0);
//! defer engines.deinit();
//!
//! // Create a canvas
//! const sw_canvas = try tvg.SoftwareCanvas.init();
//! defer sw_canvas.deinit();
//!
//! const buffer = try allocator.alloc(u32, width * height);
//! defer allocator.free(buffer);
//!
//! try sw_canvas.setTarget(buffer, width, width, height, tvg.Colorspace.argb8888);
//! const canvas = sw_canvas.asCanvas();
//!
//! // Build the scene
//! var renderer = try fabrum.ThorVGRenderer.init(allocator);
//! defer renderer.deinit();
//!
//! var commands = ctx.renderCommands();
//! try renderer.render(&commands, .{});
//!
//! // Push scene to canvas and draw
//! _ = canvas.push(renderer.scene.asPaint());
//! try canvas.draw();
//! try canvas.sync();
//! ```
//!
//! For text rendering with proper measurements, use `fabrum.measureTextThorVG`:
//! ```
//! var text = fabrum.TextContent{
//!     .text = "Hello World",
//!     .style = .{
//!         .font_size = 16,
//!         .measure_fn = fabrum.measureTextThorVG,
//!     },
//! };
//! ```

const std = @import("std");
const tvg = @import("thorvg");
const root = @import("../root.zig");

const Rect = root.Rect;
const Color = root.Color;
const RenderCommand = root.RenderCommand;
const CornerRadius = root.CornerRadius;
const BorderWidths = root.BorderWidths;
const LayoutContent = root.LayoutContent;
const TextContent = root.TextContent;

pub const Renderer = struct {
    pub const Options = struct {
        show_ids: bool = false,
    };

    scene: *tvg.Scene,
    clip_stack: std.ArrayListUnmanaged(*tvg.Scene),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        const scene = try tvg.Scene.init();
        return .{
            .scene = scene,
            .clip_stack = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.clip_stack.items) |clip_scene| {
            clip_scene.deinit();
        }
        self.clip_stack.deinit(self.allocator);
        self.scene.deinit();
    }

    pub fn render(self: *Renderer, it: *RenderCommand.Iterator) !void {
        while (it.next()) |cmd| {
            switch (cmd.data) {
                .scissor_start => {
                    const clip_scene = tvg.Scene.init() catch continue;
                    self.getActiveScene().push(clip_scene.asPaint());
                    try self.clip_stack.append(self.allocator, clip_scene);
                },
                .scissor_end => {
                    if (self.clip_stack.items.len > 0) {
                        _ = self.clip_stack.pop();
                    }
                },
                .rectangle => |r| {
                    try self.renderRectangle(cmd.bbox, r.corner_radius, r.color);
                },
                .border => |b| {
                    try self.renderBorder(cmd.bbox, b);
                },
                .content => |c| {
                    try self.renderContent(cmd.bbox, c);
                },
            }
        }
    }

    fn getActiveScene(self: *Renderer) *tvg.Scene {
        if (self.clip_stack.items.len > 0) {
            return self.clip_stack.items[self.clip_stack.items.len - 1];
        }
        return self.scene;
    }

    fn renderRectangle(self: *Renderer, bbox: Rect, cr: CornerRadius, color: Color) !void {
        const shape = tvg.Shape.init() catch return;

        if (isAllZero(cr)) {
            _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, 0, 0);
        } else if (uniformCorner(cr)) {
            _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, cr.top_left, cr.top_left);
        } else {
            try appendRoundedRect(shape, bbox, cr);
        }

        _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));

        self.getActiveScene().push(shape.asPaint());
    }

    fn renderBorder(self: *Renderer, bbox: Rect, b: RenderCommand.Data.Border) !void {
        const bw = b.widths;
        const color = b.color;

        if (bw.left == 0 and bw.right == 0 and bw.top == 0 and bw.bottom == 0) return;

        if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
            const shape = tvg.Shape.init() catch return;

            if (isAllZero(b.corner_radius)) {
                _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, 0, 0);
            } else if (uniformCorner(b.corner_radius)) {
                _ = shape.appendRect(bbox.x, bbox.y, bbox.w, bbox.h, b.corner_radius.top_left, b.corner_radius.top_left);
            } else {
                try appendRoundedRect(shape, bbox, b.corner_radius);
            }

            shape.setStrokeWidth(bw.left);
            shape.setStrokeColor(tvg.Color.init(color.r, color.g, color.b, color.a));
            shape.setFillColor(tvg.Color.init(0, 0, 0, 0));

            self.getActiveScene().push(shape.asPaint());
        } else {
            if (bw.top > 0) {
                const shape = tvg.Shape.init() catch return;
                shape.appendRect(bbox.x, bbox.y, bbox.w, bw.top, 0, 0);
                _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
                self.getActiveScene().push(shape.asPaint());
            }

            if (bw.bottom > 0) {
                const shape = tvg.Shape.init() catch return;
                shape.appendRect(bbox.x, bbox.y + bbox.h - bw.bottom, bbox.w, bw.bottom, 0, 0);
                _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
                self.getActiveScene().push(shape.asPaint());
            }

            if (bw.left > 0) {
                const shape = tvg.Shape.init() catch return;
                shape.appendRect(bbox.x, bbox.y, bw.left, bbox.h, 0, 0);
                _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
                self.getActiveScene().push(shape.asPaint());
            }

            if (bw.right > 0) {
                const shape = tvg.Shape.init() catch return;
                shape.appendRect(bbox.x + bbox.w - bw.right, bbox.y, bw.right, bbox.h, 0, 0);
                _ = shape.setFillColor(tvg.Color.init(color.r, color.g, color.b, color.a));
                self.getActiveScene().push(shape.asPaint());
            }
        }
    }

    fn renderContent(self: *Renderer, bbox: Rect, content: *LayoutContent) !void {
        if (TextContent.asTextContent(content)) |text_content| {
            try self.renderText(bbox, text_content);
        }
    }

    fn renderText(self: *Renderer, bbox: Rect, text_content: *const TextContent) !void {
        const line_height = text_content.style.resolvedLineHeight();

        var lines = text_content.lines(bbox.w);
        var line_index: usize = 0;

        var buf: [4096]u8 = undefined;

        while (lines.next()) |line| : (line_index += 1) {
            if (line.len == 0) continue;

            const text_obj = tvg.Text.init() catch continue;

            if (line.len >= buf.len) continue;
            @memcpy(buf[0..line.len], line);
            buf[line.len] = 0;

            text_obj.setText(buf[0..line.len :0]);
            try text_obj.setFont(
                if (text_content.style.font) |f| f.ptr else null,
                text_content.style.font_size,
                null,
            );
            text_obj.setFillColor(tvg.Color.init(
                text_content.style.color.r,
                text_content.style.color.g,
                text_content.style.color.b,
                text_content.style.color.a,
            ));

            const y_pos = bbox.y + line_height * @as(f32, @floatFromInt(line_index));
            const paint = text_obj.asPaint();

            const bounds = paint.getBounds(false);
            _ = paint.translate(bbox.x - bounds.x, y_pos);

            self.getActiveScene().push(paint);
        }
    }

    fn isAllZero(cr: CornerRadius) bool {
        return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
    }

    fn uniformCorner(cr: CornerRadius) bool {
        return cr.top_left == cr.top_right and cr.top_left == cr.bottom_left and cr.top_left == cr.bottom_right;
    }

    fn appendRoundedRect(shape: *tvg.Shape, bbox: Rect, cr: CornerRadius) !void {
        const x = bbox.x;
        const y = bbox.y;
        const w = bbox.w;
        const h = bbox.h;

        const tl = cr.top_left;
        const tr = cr.top_right;
        const br = cr.bottom_right;
        const bl = cr.bottom_left;

        _ = shape.moveTo(x + tl, y);
        _ = shape.lineTo(x + w - tr, y);

        if (tr > 0) {
            _ = shape.cubicTo(
                x + w - tr * 0.448,
                y,
                x + w,
                y + tr * 0.448,
                x + w,
                y + tr,
            );
        }

        _ = shape.lineTo(x + w, y + h - br);

        if (br > 0) {
            _ = shape.cubicTo(
                x + w,
                y + h - br * 0.448,
                x + w - br * 0.448,
                y + h,
                x + w - br,
                y + h,
            );
        }

        _ = shape.lineTo(x + bl, y + h);

        if (bl > 0) {
            _ = shape.cubicTo(
                x + bl * 0.448,
                y + h,
                x,
                y + h - bl * 0.448,
                x,
                y + h - bl,
            );
        }

        _ = shape.lineTo(x, y + tl);

        if (tl > 0) {
            _ = shape.cubicTo(
                x,
                y + tl * 0.448,
                x + tl * 0.448,
                y,
                x + tl,
                y,
            );
        }

        _ = shape.close();
    }
};
