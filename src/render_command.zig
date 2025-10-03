const std = @import("std");
const root = @import("root.zig");

const Rect = root.Rect;
const LayoutContent = root.LayoutContent;
const Color = root.Color;
const CornerRadius = root.CornerRadius;
const BorderWidths = root.BorderWidths;
const LayoutContext = root.Context;

const RenderCommand = @This();

bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
z_index: i16 = 0,
unit_id: u64 = 0,
data: Data,

pub const Data = union(enum) {
    rectangle: Rectangle,
    border: Border,
    content: *LayoutContent,
    scissor_start: ScissorStart,
    scissor_end: void,

    pub const Rectangle = struct {
        color: Color,
        corner_radius: CornerRadius,
    };

    pub const Border = struct {
        color: Color,
        widths: BorderWidths,
        corner_radius: CornerRadius,
    };

    pub const ScissorStart = struct {
        horizontal: bool,
        vertical: bool,
    };
};

pub const Iterator = struct {
    ctx: *const LayoutContext,
    /// scratch buffer that must be at least size `ctx.depth`
    stack: []UnitTraversalState,
    len: usize = 1,

    pub const UnitTraversalState = struct {
        index: usize = 0,
        child_pos: usize = 0,
        phase: enum {
            clip_start,
            background_rectangle,
            content,
            descend_children,
            borders,
            clip_end,
            done,
        } = .clip_start, // progression through render emission for this unit
        clip_active: bool = false,
        between_index: usize = 0,
        emitted_border: bool = false,
    };

    pub fn deinit(self: *Iterator, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
        self.* = undefined;
    }

    pub fn next(self: *Iterator) ?RenderCommand {
        // If stack empty we are done
        if (self.len == 0) {
            return null;
        }

        var frame = &self.stack[self.len - 1];
        const el = self.ctx.get(frame.index);

        // Phase breakdown:
        // 0: maybe emit scissor_start
        // 1: emit background rectangle (if any)
        // 2: emit content (if any)
        // 3: descend into children or skip to phase 4
        // 4: emit border (if any)
        // 5: emit scissor_end (if active)
        // 6: done (pop and advance)
        sw: switch (frame.phase) {
            .clip_start => {
                switch (el.data) {
                    .container => |decl| {
                        if (decl.clip.horizontal or decl.clip.vertical) {
                            frame.clip_active = true;
                            frame.phase = .background_rectangle;
                            return .{
                                .bbox = el.bbox,
                                .z_index = decl.floating.z_index,
                                .unit_id = el.id,
                                .data = .{
                                    .scissor_start = .{
                                        .horizontal = decl.clip.horizontal,
                                        .vertical = decl.clip.vertical,
                                    },
                                },
                            };
                        }
                    },
                    else => {},
                }
                continue :sw .background_rectangle;
            },
            .background_rectangle => {
                switch (el.data) {
                    .container => |decl| {
                        if (!decl.background_color.isTransparent()) {
                            frame.phase = .content;
                            return .{
                                .bbox = el.bbox,
                                .z_index = decl.floating.z_index,
                                .unit_id = el.id,
                                .data = .{
                                    .rectangle = .{
                                        .color = decl.background_color,
                                        .corner_radius = decl.corner_radius,
                                    },
                                },
                            };
                        }
                    },
                    else => {},
                }
                continue :sw .content;
            },
            .content => {
                switch (el.data) {
                    .content => |content| {
                        frame.phase = .descend_children;
                        return .{
                            .bbox = el.bbox,
                            .unit_id = el.id,
                            .data = .{ .content = content },
                        };
                    },
                    else => {},
                }
                continue :sw .descend_children;
            },
            .descend_children => {
                // descend children depth-first
                switch (el.data) {
                    .container => {
                        if (frame.child_pos < el.children.items.len) {
                            // Push child frame
                            self.stack[self.len] = .{ .index = el.children.items[frame.child_pos] };
                            self.len += 1;
                            // Do not advance current frame.phase yet; child will run first
                            return self.next();
                        }
                    },
                    else => {},
                }
                continue :sw .borders;
            },
            .borders => {
                switch (el.data) {
                    .container => |decl| {
                        if (!decl.border.color.isTransparent()) {
                            const bw = decl.border.widths;
                            if (bw.between_children > 0 and el.children.items.len > 1) {
                                if (frame.between_index < el.children.items.len - 1) {
                                    const left_idx = el.children.items[frame.between_index];
                                    const right_idx = el.children.items[frame.between_index + 1];
                                    const left_el = self.ctx.get(left_idx);
                                    const right_el = self.ctx.get(right_idx);
                                    const thickness = bw.between_children;
                                    var divider_bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                                    switch (decl.layout.axis) {
                                        .x => {
                                            const gap_space = right_el.bbox.x - (left_el.bbox.x + left_el.bbox.w);
                                            const x_pos = left_el.bbox.x + left_el.bbox.w + (gap_space - thickness) / 2;
                                            divider_bbox = .{ .x = x_pos, .y = el.bbox.y, .w = thickness, .h = el.bbox.h };
                                        },
                                        .y => {
                                            const gap_space = right_el.bbox.y - (left_el.bbox.y + left_el.bbox.h);
                                            const y_pos = left_el.bbox.y + left_el.bbox.h + (gap_space - thickness) / 2;
                                            divider_bbox = .{ .x = el.bbox.x, .y = y_pos, .w = el.bbox.w, .h = thickness };
                                        },
                                    }
                                    frame.between_index += 1;
                                    return RenderCommand{
                                        .bbox = divider_bbox,
                                        .z_index = decl.floating.z_index,
                                        .unit_id = el.id,
                                        .data = .{
                                            .rectangle = .{
                                                .color = decl.border.color,
                                                .corner_radius = .{}, // straight divider
                                            },
                                        },
                                    };
                                }
                            }
                            // Outer border
                            if (!bw.isZero()) {
                                frame.phase = .clip_end;
                                return .{
                                    .bbox = el.bbox,
                                    .z_index = decl.floating.z_index,
                                    .unit_id = el.id,
                                    .data = .{
                                        .border = .{
                                            .color = decl.border.color,
                                            .widths = bw,
                                            .corner_radius = decl.corner_radius,
                                        },
                                    },
                                };
                            }
                        }
                    },
                    else => {},
                }
                continue :sw .clip_end;
            },
            .clip_end => {
                switch (el.data) {
                    .container => |decl| {
                        if (frame.clip_active) {
                            frame.phase = .done;
                            return RenderCommand{
                                .bbox = el.bbox,
                                .z_index = decl.floating.z_index,
                                .unit_id = el.id,
                                .data = .scissor_end,
                            };
                        }
                    },
                    else => {},
                }
                continue :sw .done;
            },
            .done => {
                // Pop finished unit
                self.len -= 1;

                // Advance parent child_pos
                if (self.len > 0) {
                    self.stack[self.len - 1].child_pos += 1;
                }

                // Recurse to produce next unit command
                return self.next();
            },
        }
    }
};
