const std = @import("std");
const root = @import("root.zig");

const Rect = root.Rect;
const Color = root.Color;
const RenderCommand = root.RenderCommand; // direct reference

const RenderData = root.RenderData;
const CornerRadius = root.CornerRadius;
const BorderWidths = root.BorderWidths;

/// Simple immediate SVG renderer for the ui.RenderCommand stream.
/// Goals:
/// - Zero heap allocations per primitive (only grows an ArrayList buffer).
/// - Stable ordering (no z-sorting by default so clipping phases remain intact).
/// - Basic support for:
///     * Rectangles (with uniform or per-corner radii)
///     * Borders (approximated as stroked rect if uniform, else decomposed)
///     * Between-child dividers (already emitted as rectangles by layout)
///     * Clipping via <clipPath> stack
/// - Optional element id labeling for debugging.
///
/// Non-goals / simplifications:
/// - Complex border joins with distinct per-edge radii (approximation only)
/// - Content rendering (user can extend via callback)
///
/// Extension points:
/// - Provide a ContentRenderer to draw custom nodes for RenderData.content.
/// - Add z-index grouping if you ensure scissor groups do not interleave.
pub const SvgRenderer = struct {
    pub const Options = struct {
        margin: f32 = 8, // extra space around computed bounds
        background: Color = .white,
        show_ids: bool = true, // draw text labels (element id) at centers
        id_font_size: f32 = 10,
        sort_by_z: bool = false, // WARNING: disables clipping correctness if true and clips used
        decimal_places: u8 = 2,
        embed_view_box: bool = true,
        /// Called for RenderData.content. Return true if handled (so default box/label skipped).
        content_renderer: ?*const fn (
            writer: *std.Io.Writer,
            cmd: RenderCommand,
            opts: *const Options,
        ) anyerror!bool = null,
    };

    pub fn render(
        allocator: std.mem.Allocator,
        command_iterator: *root.RenderCommandIterator,
        opts: Options,
    ) ![]u8 {
        // Pass 1: compute bounding box and clip references
        var bbox = Rect{
            .x = std.math.inf(f32),
            .y = std.math.inf(f32),
            .w = 0,
            .h = 0,
        };

        // Record all clip rectangles so we can emit <defs> before drawing
        var clip_rects = std.ArrayListUnmanaged(Rect){};
        defer clip_rects.deinit(allocator);

        // For each command index, the current "top" clip id (0-based into clip_rects) or null
        var clip_at_index = try allocator.alloc(?usize, ordered_cmds.len);
        defer allocator.free(clip_at_index);

        var clip_stack = std.ArrayListUnmanaged(usize){};
        defer clip_stack.deinit(allocator);

        for (ordered_cmds, 0..) |cmd, i| {
            // Expand global bbox
            if (cmd.bbox.w > 0 or cmd.bbox.h > 0) {
                bbox.x = @min(bbox.x, cmd.bbox.x);
                bbox.y = @min(bbox.y, cmd.bbox.y);
                bbox.w = @max(bbox.w, cmd.bbox.x + cmd.bbox.w);
                bbox.h = @max(bbox.h, cmd.bbox.y + cmd.bbox.h);
            }

            switch (cmd.data) {
                .scissor_start => {
                    // Track immediately, but element itself also counts to bounds (above)
                    try clip_rects.append(allocator, cmd.bbox);
                    try clip_stack.append(allocator, clip_rects.items.len - 1);
                    clip_at_index[i] = if (clip_stack.items.len > 0) clip_stack.items[clip_stack.items.len - 1] else null;
                },
                .scissor_end => {
                    // pop AFTER applying top for this index
                    clip_at_index[i] = if (clip_stack.items.len > 0) clip_stack.items[clip_stack.items.len - 1] else null;
                    if (clip_stack.items.len > 0) _ = clip_stack.pop();
                },
                else => {
                    clip_at_index[i] = if (clip_stack.items.len > 0) clip_stack.items[clip_stack.items.len - 1] else null;
                },
            }
        }
        if (bbox.x == std.math.inf(f32)) {
            bbox = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        } else {
            bbox.w -= bbox.x;
            bbox.h -= bbox.y;
        }

        const margin = opts.margin;
        const view_x = bbox.x - margin;
        const view_y = bbox.y - margin;
        const view_w = bbox.w + margin * 2;
        const view_h = bbox.h + margin * 2;

        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();

        var writer = &out.writer;

        try writer.print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\"",
            .{ @as(i64, @intFromFloat(view_w)), @as(i64, @intFromFloat(view_h)) },
        );
        if (opts.embed_view_box) {
            try writer.print(" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\"", .{ view_x, view_y, view_w, view_h });
        }
        try writer.writeAll(" font-family=\"monospace\" font-size=\"10\" text-anchor=\"middle\" dominant-baseline=\"middle\">\n");

        // Background
        try writer.print(
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
            .{ view_x, view_y, view_w, view_h, colorHex(opts.background), alphaStr(opts.background) },
        );

        // Clip definitions
        if (clip_rects.items.len > 0) {
            try writer.writeAll("<defs>\n");
            for (clip_rects.items, 0..) |cr, ci| {
                try writer.print(
                    "<clipPath id=\"clip{d}\"><rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" /></clipPath>\n",
                    .{ ci, cr.x, cr.y, cr.w, cr.h },
                );
            }
            try writer.writeAll("</defs>\n");
        }

        try writer.writeAll("<g id=\"ui\">\n");

        // Second pass: draw shapes
        for (ordered_cmds, 0..) |cmd, i| {
            if (cmd.data == .scissor_start or cmd.data == .scissor_end) continue;

            const clip_ref = clip_at_index[i];
            if (clip_ref) |cr_idx| {
                try writer.print("<g clip-path=\"url(#clip{d})\">\n", .{cr_idx});
            }

            switch (cmd.data) {
                .rectangle => |r| {
                    try writeRectangle(writer, cmd.bbox, r.corner_radius, r.color);
                    if (opts.show_ids) try writeIdLabel(writer, cmd);
                },
                .border => |b| {
                    try writeBorder(writer, cmd.bbox, b);
                    if (opts.show_ids) try writeIdLabel(writer, cmd);
                },
                .content => |_| {
                    if (opts.content_renderer) |fn_ptr| {
                        const handled = try fn_ptr(writer, cmd, &opts);
                        if (!handled and opts.show_ids) {
                            try writeIdLabel(writer, cmd);
                        }
                    } else {
                        // Fall back to just labeling the element
                        if (opts.show_ids) try writeIdLabel(writer, cmd);
                    }
                },
                else => {},
            }

            if (clip_ref != null) {
                try writer.writeAll("</g>\n");
            }
        }

        try writer.writeAll("</g>\n</svg>\n");

        if (effective_sort) allocator.free(tmp);

        return out.toOwnedSlice();
    }

    fn writeRectangle(writer: *std.Io.Writer, bbox: Rect, cr: CornerRadius, color: Color) !void {
        if (isAllZero(cr)) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bbox.h, colorHex(color), alphaStr(color), colorHex(color), alphaStr(color) },
            );
            return;
        }
        // Non-zero corners: If all corners uniform -> rect with rx/ry
        if (cr.top_left == cr.top_right and cr.top_left == cr.bottom_left and cr.top_left == cr.bottom_right) {
            const rx = cr.top_left;
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" rx=\"{d:.2}\" ry=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bbox.h, rx, rx, colorHex(color), alphaStr(color), colorHex(color), alphaStr(color) },
            );
            return;
        }
        // Arbitrary corner radii -> path
        try writer.print(
            "<path d=\"{s}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"{s}\" stroke-opacity=\"{s}\" stroke-width=\"1\" />\n",
            .{
                roundedRectPath(bbox, cr),
                colorHex(color),
                alphaStr(color),
                colorHex(color),
                alphaStr(color),
            },
        );
    }

    fn writeIdLabel(writer: *std.Io.Writer, cmd: RenderCommand) !void {
        if (cmd.bbox.w == 0 and cmd.bbox.h == 0) return;
        const cx = cmd.bbox.x + cmd.bbox.w / 2;
        const cy = cmd.bbox.y + cmd.bbox.h / 2;
        try writer.print(
            "<text x=\"{d:.2}\" y=\"{d:.2}\" fill=\"#000000\" font-size=\"10\">{d}</text>\n",
            .{ cx, cy, cmd.unit_id },
        );
    }

    fn writeBorder(writer: *std.Io.Writer, bbox: Rect, b: RenderData.Border) !void {
        const bw = b.widths;
        const color = b.color;
        if (bw.between_children != 0) {
            // between_children not used here (those came as rectangle commands already)
        }
        // If all edges equal -> stroke rectangle
        if (bw.left == bw.right and bw.left == bw.top and bw.left == bw.bottom) {
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

        // Otherwise draw 4 separate filled rect strips
        if (bw.top > 0) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y, bbox.w, bw.top, colorHex(color), alphaStr(color) },
            );
        }
        if (bw.bottom > 0) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y + bbox.h - bw.bottom, bbox.w, bw.bottom, colorHex(color), alphaStr(color) },
            );
        }
        if (bw.left > 0) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x, bbox.y, bw.left, bbox.h, colorHex(color), alphaStr(color) },
            );
        }
        if (bw.right > 0) {
            try writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{s}\" stroke=\"none\" />\n",
                .{ bbox.x + bbox.w - bw.right, bbox.y, bw.right, bbox.h, colorHex(color), alphaStr(color) },
            );
        }
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
        const slice = std.fmt.bufPrint(
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
        return slice;
    }

    // Runtime formatting helpers for color and alpha, reused by attribute writers.
    var color_buf: [16]u8 = undefined;
    var alpha_buf: [8]u8 = undefined;

    fn alphaStr(c: Color) []const u8 {
        if (c.a == 255) return "1";
        const f = @as(f32, @floatFromInt(c.a)) / 255.0;
        return std.fmt.bufPrint(&alpha_buf, "{d:.2}", .{f}) catch unreachable;
    }

    fn colorHex(c: Color) []const u8 {
        if (c.a == 255) {
            return std.fmt.bufPrint(&color_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
        } else {
            return std.fmt.bufPrint(&color_buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b, c.a }) catch unreachable;
        }
    }
};

// -----------------------------------------------------------------------------
// Basic smoke test (does not validate SVG semantics, only that it builds).
// -----------------------------------------------------------------------------
test "svg renderer basic output" {
    const allocator = std.testing.allocator;

    const Cmd = RenderCommand;
    var commands = [_]Cmd{
        .{
            .bbox = Rect{ .x = 0, .y = 0, .w = 200, .h = 100 },
            .z_index = 0,
            .unit_id = 1,
            .data = .{ .rectangle = .{ .color = Color.rgb(30, 144, 255), .corner_radius = .{} } },
        },
        .{
            .bbox = Rect{ .x = 20, .y = 20, .w = 60, .h = 40 },
            .z_index = 1,
            .unit_id = 2,
            .data = .{ .border = .{ .color = Color.rgb(200, 50, 50), .widths = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 }, .corner_radius = CornerRadius.uniform(6) } },
        },
    };

    const svg = try SvgRenderer.render(allocator, &commands, .{});
    defer allocator.free(svg);

    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "clipPath") == null);
}
