const std = @import("std");
const fabrum = @import("../root.zig");
const layout = @import("../layout.zig");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const Content = layout.Content;
const CornerRadius = layout.CornerRadius;
const BorderWidths = layout.BorderWidths;
const Context = layout.Context;

const RenderCommand = @This();

bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
z_index: i16 = 0,
unit_id: u64 = 0,
data: Data,

pub const Data = union(enum) {
    rectangle: Rectangle,
    border: Border,
    content: *Content,
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
    ctx: *const Context,
    /// scratch buffer that must hold one frame per level of the tree, `Context.Config.getDepth`
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
        // each frame is a unit part way through emitting its commands
        while (self.len > 0) {
            const frame = &self.stack[self.len - 1];
            const el = self.ctx.get(frame.index);

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
                    // descend children depth-first: push the next child's
                    // frame, and keep this phase until every child is done
                    if (el.data == .container and frame.child_pos < el.children.items.len) {
                        self.stack[self.len] = .{ .index = el.children.items[frame.child_pos] };
                        self.len += 1;
                        continue;
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
                                        const left_el = self.ctx.get(el.children.items[frame.between_index]);
                                        const right_el = self.ctx.get(el.children.items[frame.between_index + 1]);
                                        const thickness = bw.between_children;
                                        // centered in the gap between the two
                                        const divider_bbox: Rect = switch (decl.layout.axis) {
                                            .x => .{
                                                .x = left_el.bbox.x + left_el.bbox.w + (right_el.bbox.x - (left_el.bbox.x + left_el.bbox.w) - thickness) / 2,
                                                .y = el.bbox.y,
                                                .w = thickness,
                                                .h = el.bbox.h,
                                            },
                                            .y => .{
                                                .x = el.bbox.x,
                                                .y = left_el.bbox.y + left_el.bbox.h + (right_el.bbox.y - (left_el.bbox.y + left_el.bbox.h) - thickness) / 2,
                                                .w = el.bbox.w,
                                                .h = thickness,
                                            },
                                        };
                                        frame.between_index += 1;
                                        return .{
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
                                return .{
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
                    // pop the finished unit and move its parent on to the next child
                    self.len -= 1;
                    if (self.len > 0) {
                        self.stack[self.len - 1].child_pos += 1;
                    }
                    continue;
                },
            }
        }
        return null;
    }
};
