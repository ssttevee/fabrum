const std = @import("std");
const root = @import("root.zig");

const Rect = root.Rect;
const Color = root.Color;
const RenderCommand = root.RenderCommand;
const CornerRadius = root.CornerRadius;
const BorderWidths = root.BorderWidths;
const LayoutContent = root.LayoutContent;
const TextContent = root.TextContent;

/// Single-pass (one iterator consumption) SVG renderer.
/// We traverse the render command iterator once, collecting:
/// - Bounding box (min/max)
/// - clip rectangles (for scissor_start)
/// - Body SVG markup
/// After traversal we synthesize the final SVG header + <defs> + body.
/// No second traversal over commands is performed.
pub const SvgRenderer = struct {
    pub const Options = struct {
        show_ids: bool = true,
        id_font_size: f32 = 10,
    };

    pub fn render(
        allocator: std.mem.Allocator,
        it: *RenderCommand.Iterator,
        opts: Options,
    ) ![]u8 {
        // Accumulate body markup & clip metadata.
        var body = std.Io.Writer.Allocating.init(allocator);
        defer body.deinit();

        const body_writer = &body.writer;

        var clip_rects = std.ArrayListUnmanaged(Rect){};
        defer clip_rects.deinit(allocator);
        var clip_stack = std.ArrayListUnmanaged(usize){};
        defer clip_stack.deinit(allocator);

        // Bounding box tracking (store min/max edges first).
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);

        while (it.next()) |cmd| {
            // Update bounds if command has area
            if (cmd.bbox.w > 0 or cmd.bbox.h > 0) {
                min_x = @min(min_x, cmd.bbox.x);
                min_y = @min(min_y, cmd.bbox.y);
                max_x = @max(max_x, cmd.bbox.x + cmd.bbox.w);
                max_y = @max(max_y, cmd.bbox.y + cmd.bbox.h);
            }

            switch (cmd.data) {
                .scissor_start => {
                    try clip_rects.append(allocator, cmd.bbox);
                    try clip_stack.append(allocator, clip_rects.items.len - 1);
                },
                .scissor_end => {
                    if (clip_stack.items.len > 0) _ = clip_stack.pop();
                },
                .rectangle => |r| {
                    try maybeOpenClipGroup(body_writer, &clip_stack);
                    try writeRectangle(body_writer, cmd.bbox, r.corner_radius, r.color);
                    if (opts.show_ids) try writeIdLabel(body_writer, cmd, opts.id_font_size);
                    try maybeCloseClipGroup(body_writer, &clip_stack);
                },
                .border => |b| {
                    try maybeOpenClipGroup(body_writer, &clip_stack);
                    try writeBorder(body_writer, cmd.bbox, b);
                    if (opts.show_ids) try writeIdLabel(body_writer, cmd, opts.id_font_size);
                    try maybeCloseClipGroup(body_writer, &clip_stack);
                },
                .content => |c| {
                    try maybeOpenClipGroup(body_writer, &clip_stack);
                    try writeContent(body_writer, cmd.bbox, c);
                    // var handled = false;
                    // if (opts.content_renderer) |fn_ptr| {
                    //     handled = try fn_ptr(body_writer, cmd, &opts);
                    // }
                    // if (!handled and opts.show_ids) {
                    //     try writeIdLabel(body_writer, cmd, opts.id_font_size);
                    // }
                    try maybeCloseClipGroup(body_writer, &clip_stack);
                },
            }
        }

        if (min_x == std.math.inf(f32)) {
            min_x = 0;
            min_y = 0;
            max_x = 0;
            max_y = 0;
        }

        const view_x = min_x;
        const view_y = min_y;
        const view_w = (max_x - min_x);
        const view_h = (max_y - min_y);

        // Compose final output
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        var w = &out.writer;

        try w.print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\"",
            .{ @as(i64, @intFromFloat(view_w)), @as(i64, @intFromFloat(view_h)) },
        );
        try w.print(" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\"", .{ view_x, view_y, view_w, view_h });
        try w.writeAll(" font-family=\"monospace\" font-size=\"10\" text-anchor=\"middle\" dominant-baseline=\"middle\">\n");

        // Background
        try w.print(
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
            .{ view_x, view_y, view_w, view_h, "#FFFFFF", "1" },
        );

        if (clip_rects.items.len > 0) {
            try w.writeAll("<defs>\n");
            for (clip_rects.items, 0..) |cr, ci| {
                try w.print(
                    "<clipPath id=\"clip{d}\"><rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" /></clipPath>\n",
                    .{ ci, cr.x, cr.y, cr.w, cr.h },
                );
            }
            try w.writeAll("</defs>\n");
        }

        // Emit body (which already contains groups referencing clip paths)
        try w.writeAll("<g id=\"ui\">\n");
        try w.writeAll(body_writer.buffered());
        try w.writeAll("</g>\n</svg>\n");

        return out.toOwnedSlice();
    }

    fn maybeOpenClipGroup(writer: anytype, clip_stack: *const std.ArrayListUnmanaged(usize)) !void {
        if (clip_stack.items.len == 0) return;
        const active = clip_stack.items[clip_stack.items.len - 1];
        try writer.print("<g clip-path=\"url(#clip{d})\">\n", .{active});
    }

    fn maybeCloseClipGroup(writer: anytype, clip_stack: *const std.ArrayListUnmanaged(usize)) !void {
        if (clip_stack.items.len == 0) return;
        try writer.writeAll("</g>\n");
    }

    fn writeRectangle(writer: anytype, bbox: Rect, cr: CornerRadius, color: Color) !void {
        if (isAllZero(cr)) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bbox.h, colorHex(color), alphaStr(color), colorHex(color), alphaStr(color) },
            );
            return;
        }
        if (uniformCorner(cr)) {
            const rx = cr.top_left;
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" rx=\"{d:.2}\" ry=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bbox.h, rx, rx, colorHex(color), alphaStr(color), colorHex(color), alphaStr(color) },
            );
            return;
        }
        try writer.print(
            "<path d=\"{s}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
            .{ roundedRectPath(bbox, cr), colorHex(color), alphaStr(color), colorHex(color), alphaStr(color) },
        );
    }

    fn writeBorder(writer: anytype, bbox: Rect, b: RenderCommand.Data.Border) !void {
        const bw = b.widths;
        const color = b.color;

        if (bw.left == 0 and bw.right == 0 and bw.top == 0 and bw.bottom == 0) return;

        if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
            // Uniform stroke
            if (bw.left == 0) return;
            if (isAllZero(b.corner_radius)) {
                try writer.print(
                    "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"{d:.2}\" />\n",
                    .{ bbox.x, bbox.y, bbox.w, bbox.h, colorHex(color), alphaStr(color), bw.left },
                );
            } else if (uniformCorner(b.corner_radius)) {
                const rx = b.corner_radius.top_left;
                try writer.print(
                    "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" rx=\"{d:.2}\" ry=\"{d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"{d:.2}\" />\n",
                    .{ bbox.x, bbox.y, bbox.w, bbox.h, rx, rx, colorHex(color), alphaStr(color), bw.left },
                );
            } else {
                try writer.print(
                    "<path d=\"{s}\" fill=\"none\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"{d:.2}\" />\n",
                    .{ roundedRectPath(bbox, b.corner_radius), colorHex(color), alphaStr(color), bw.left },
                );
            }
            return;
        }

        // Non-uniform: draw 4 filled strips
        if (bw.top > 0)
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bw.top, colorHex(color), alphaStr(color) },
            );
        if (bw.bottom > 0)
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y + bbox.h - bw.bottom, bbox.w, bw.bottom, colorHex(color), alphaStr(color) },
            );
        if (bw.left > 0)
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y, bw.left, bbox.h, colorHex(color), alphaStr(color) },
            );
        if (bw.right > 0)
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x + bbox.w - bw.right, bbox.y, bw.right, bbox.h, colorHex(color), alphaStr(color) },
            );
    }

    fn writeContent(writer: anytype, bbox: Rect, content: *LayoutContent) !void {
        if (TextContent.asTextContent(content)) |text| {
            const line_height = text.style.resolvedLineHeight();

            var lines = text.lines(bbox.w);
            var i: usize = 0;
            while (lines.next()) |line| {
                try writer.print(
                    "<text x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" font-size=\"{d:.2}\">{s}</text>\n",
                    .{ bbox.x, bbox.y + line_height * @as(f32, @floatFromInt(i)), bbox.w, bbox.h, colorHex(text.style.color), alphaStr(text.style.color), text.style.font_size, line },
                );
                i += 1;
            }
        } else {
            std.log.err("unknown content type: {s}", .{content.vtable.debug_name});
            return error.UnknownContentType;
        }
    }

    fn writeIdLabel(writer: anytype, cmd: RenderCommand, font_size: f32) !void {
        if (cmd.bbox.w == 0 and cmd.bbox.h == 0) return;
        const cx = cmd.bbox.x + cmd.bbox.w / 2;
        const cy = cmd.bbox.y + cmd.bbox.h / 2;
        try writer.print(
            "<text x=\"{d:.2}\" y=\"{d:.2}\" fill=\"#000000\" font-size=\"{d:.0}\">{d}</text>\n",
            .{ cx, cy, font_size, cmd.unit_id },
        );
    }

    fn isAllZero(cr: CornerRadius) bool {
        return cr.top_left == 0 and cr.top_right == 0 and cr.bottom_left == 0 and cr.bottom_right == 0;
    }

    fn uniformCorner(cr: CornerRadius) bool {
        return cr.top_left == cr.top_right and cr.top_left == cr.bottom_left and cr.top_left == cr.bottom_right;
    }

    var path_buf: [256]u8 = undefined;
    fn roundedRectPath(b: Rect, cr: CornerRadius) []const u8 {
        const tl = cr.top_left;
        const tr = cr.top_right;
        const br = cr.bottom_right;
        const bl = cr.bottom_left;
        return std.fmt.bufPrint(
            &path_buf,
            "M {d:.2} {d:.2} H {d:.2} A {d:.2} {d:.2} 0 0 1 {d:.2} {d:.2} V {d:.2} A {d:.2} {d:.2} 0 0 1 {d:.2} {d:.2} H {d:.2} A {d:.2} {d:.2} 0 0 1 {d:.2} {d:.2} V {d:.2} A {d:.2} {d:.2} 0 0 1 {d:.2} {d:.2} Z",
            .{
                b.x + tl,       b.y,
                b.x + b.w - tr, tr,
                tr,             b.x + b.w,
                b.y + tr,       b.y + b.h - br,
                br,             br,
                b.x + b.w - br, b.y + b.h,
                b.x + bl,       bl,
                bl,             b.x,
                b.y + b.h - bl, b.y + tl,
                tl,             tl,
                b.x + tl,       b.y,
            },
        ) catch unreachable;
    }

    var color_buf: [16]u8 = undefined;
    var alpha_buf: [8]u8 = undefined;

    fn alphaStr(c: Color) []const u8 {
        if (c.a == 255) return "1";
        const f = @as(f32, @floatFromInt(c.a)) / 255.0;
        return std.fmt.bufPrint(&alpha_buf, "{d:.2}", .{f}) catch unreachable;
    }

    fn colorHex(c: Color) []const u8 {
        if (c.a == 255)
            return std.fmt.bufPrint(&color_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b }) catch unreachable
        else
            return std.fmt.bufPrint(&color_buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b, c.a }) catch unreachable;
    }
};
