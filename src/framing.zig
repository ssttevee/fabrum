const std = @import("std");
const root = @import("root.zig");
// const layout = @import("layout.zig");

const Vec2 = root.Vec2;
const Rect = root.Rect;
const Color = root.Color;
const LayoutConstraints = root.LayoutConstraints;
const LayoutContext = root.LayoutContext;
const LayoutConfig = root.LayoutConfig;
const Content = root.Content;
const LayoutContextConfig = root.LayoutContextConfig;

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub fn uniform(v: f32) CornerRadius {
        return .{
            .top_left = v,
            .top_right = v,
            .bottom_left = v,
            .bottom_right = v,
        };
    }
};

pub const BorderWidths = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    /// Adds a divider between each child.
    between_children: f32 = 0,

    pub fn isZero(self: BorderWidths) bool {
        return self.left == 0 and self.right == 0 and self.top == 0 and self.bottom == 0;
    }

    pub fn any(self: BorderWidths) bool {
        return !self.isZero() or self.between_children != 0;
    }
};

pub const BorderConfig = struct {
    color: Color = .{},
    widths: BorderWidths = .{},
};

pub const ScrollFlags = packed struct {
    horizontal: bool = false,
    vertical: bool = false,

    pub fn any(self: ScrollFlags) bool {
        return self.horizontal or self.vertical;
    }
};

pub const RenderData = union(enum) {
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

pub const RenderCommand = struct {
    bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    z_index: i16 = 0,
    unit_id: u64 = 0,
    data: RenderData,
};

pub const RenderCommandIterator = struct {
    vtable: *const VTable,

    const VTable = struct {
        next: *const fn (*RenderCommandIterator) ?RenderCommand,
    };

    pub fn next(self: *RenderCommandIterator) ?RenderCommand {
        return self.vtable.next(self);
    }
};

pub const ContainerDeclaration = struct {
    id: []const u8 = "",

    /// Controls various settings that affect the size and position of an unit, as well as the sizes and positions of any child units.
    layout: LayoutConfig = .{},

    /// Controls the background color of the resulting unit.
    /// By convention specified as 0-255, but interpretation is up to the renderer.
    /// If no other config is specified, .backgroundColor will generate a RECTANGLE render command, otherwise it will be passed as a property to IMAGE or CUSTOM render commands.
    background_color: Color = .{},

    /// Controls the "radius", or corner rounding of units, including rectangles, borders and images.
    corner_radius: CornerRadius = .{},

    /// Controls settings related to aspect ratio scaling.
    aspect_ratio: AspectRatioConfig = .{},

    /// Controls whether and how an unit "floats", which means it layers over the top of other units in z order, and doesn't affect the position and size of siblings or parent units.
    floating: FloatingConfig = .{},

    /// Controls whether an unit should clip its contents, as well as providing child x,y offset configuration for scrolling.
    clip: ClipConfig = .{},

    /// Controls settings related to unit borders, and will generate BORDER render commands.
    border: BorderConfig = .{},

    /// A pointer that will be transparently passed through to resulting render commands.
    user_data: ?*anyopaque = null,

    pub const AspectRatioConfig = struct {
        /// A float representing the target "Aspect ratio" for an unit, which is its final width divided by its final height.
        aspect_ratio: f32 = 0,
    };

    pub const FloatingConfig = struct {
        mode: AttachMode = .default,
        parent: union { id: u32, index: usize } = 0,
        unit_point: AttachPoint = .left_top,
        parent_point: AttachPoint = .left_top,
        offset: Vec2 = .zero,
        expand: Vec2 = .zero,
        z_index: i16 = 0,

        /// Transparently pass through pointer events like hover and click to units underneath the floating unit.
        pointer_passthrough: bool = false,

        /// Whether or not a floating unit should be clipped to the same clipping rectangle as the unit it's attached to.
        clip_to_parent: bool = false,

        pub const AttachPoint = enum {
            left_top,
            left_center,
            left_bottom,
            center_top,
            center_center,
            center_bottom,
            right_top,
            right_center,
            right_bottom,

            pub const top_left = AttachPoint.left_top;
            pub const top_center = AttachPoint.center_top;
            pub const top_right = AttachPoint.right_top;

            pub const center_left = AttachPoint.center_left;
            pub const center = AttachPoint.center_center;
            pub const center_right = AttachPoint.center_right;

            pub const bottom_left = AttachPoint.left_bottom;
            pub const bottom_center = AttachPoint.center_bottom;
            pub const bottom_right = AttachPoint.right_bottom;

            pub const default = top_left;
        };

        pub const AttachMode = enum {
            /// no floating
            none,
            parent,
            unit_index,
            unit_id,
            root,

            pub const default = AttachMode.none;
        };

        pub fn active(self: FloatingConfig) bool {
            return self.mode != .none;
        }
    };

    /// Controls the axis on which an unit switches to "scrolling", which clips the contents and allows scrolling in that direction.
    pub const ClipConfig = struct {
        /// Clip overflowing units on the X axis.
        horizontal: bool = false,
        /// Clip overflowing units on the Y axis.
        vertical: bool = false,
        /// Offsets the x,y positions of all child units. Used primarily for scrolling containers.
        child_offset: Vec2 = .{},
    };

    pub fn layoutConfig(self: *ContainerDeclaration) *LayoutConfig {
        return &self.layout;
    }

    pub fn measure(self: *const ContainerDeclaration, constraints: LayoutConstraints) Vec2 {
        return self.layout.measure(constraints);
    }
};

pub const ContentDeclaration = struct {
    id: []const u8 = "",
    content: *Content,

    var zeroconfig = LayoutConfig{};

    pub fn layoutConfig(self: *ContentDeclaration) *LayoutConfig {
        _ = self;
        std.debug.assert(zeroconfig.isEmpty());
        return &zeroconfig;
    }

    pub fn measure(self: *const ContentDeclaration, constraints: LayoutConstraints) Vec2 {
        return self.content.measure(constraints);
    }
};

pub fn Context(comptime config: LayoutContextConfig) type {
    return struct {
        layout: LayoutContext(UnitData, config),

        const Self = @This();

        pub const UnitData = union(enum) {
            container: ContainerDeclaration,
            content: ContentDeclaration,

            pub fn layoutConfig(self: *UnitData) *LayoutConfig {
                return switch (self) {
                    inline else => |decl| decl.layoutConfig(),
                };
            }

            pub fn measure(self: *const UnitData, constraints: LayoutConstraints) Vec2 {
                return switch (self) {
                    inline else => |decl| decl.measure(constraints),
                };
            }
        };

        pub const Commands = struct {
            ctx: *const Self,
            stack: [config.getDepth()]UnitTraversalState = undefined,
            len: usize = 1,
            iterator: RenderCommandIterator,

            const UnitTraversalState = struct {
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

            pub fn next(interface: *RenderCommandIterator) ?RenderCommand {
                const self: *Commands = @fieldParentPtr("iterator", interface);

                // If stack empty we are done
                if (self.len == 0) {
                    return null;
                }

                var frame = &self.stack[self.len - 1];
                const el = self.ctx.layout.get(frame.index);

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
                            .content => |decl| {
                                if (decl.content) |c| {
                                    frame.phase = .descend_children;
                                    return .{
                                        .bbox = el.bbox,
                                        .unit_id = el.id,
                                        .data = .{ .content = c },
                                    };
                                }
                            },
                            else => {},
                        }
                        continue :sw .descend_children;
                    },
                    .descend_children => {
                        // descend children depth-first
                        switch (el.data) {
                            .container => {
                                if (frame.child_pos < el.children.len) {
                                    const child_index = el.children[frame.child_pos];
                                    // Push child frame
                                    self.stack[self.len] = .{ .index = child_index };
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
                            .container => {
                                if (!el.data.border.color.isTransparent()) {
                                    const bw = el.data.border.widths;
                                    if (bw.between_children > 0 and el.children.len > 1) {
                                        if (frame.between_index < el.children.len - 1) {
                                            const left_idx = el.children[frame.between_index];
                                            const right_idx = el.children[frame.between_index + 1];
                                            const left_el = self.ctx.layout.get(left_idx);
                                            const right_el = self.ctx.layout.get(right_idx);
                                            const thickness = bw.between_children;
                                            var divider_bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                                            switch (el.data.layout.axis) {
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
                                            if (frame.between_index == el.children.len - 1) {
                                                frame.emitted_between = true;
                                            }
                                            return RenderCommand{
                                                .bbox = divider_bbox,
                                                .z_index = el.data.floating.z_index,
                                                .unit_id = el.id,
                                                .data = .{
                                                    .rectangle = .{
                                                        .color = el.data.border.color,
                                                        .corner_radius = .{}, // straight divider
                                                    },
                                                },
                                            };
                                        }
                                    }
                                    // Outer border
                                    if (!bw.isZero()) {
                                        frame.phase = .clip_end;
                                        return RenderCommand{
                                            .bbox = el.bbox,
                                            .z_index = el.data.floating.z_index,
                                            .unit_id = el.id,
                                            .data = .{
                                                .border = .{
                                                    .color = el.data.border.color,
                                                    .widths = bw,
                                                    .corner_radius = el.data.corner_radius,
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
                            .container => {
                                if (frame.clip_active) {
                                    frame.phase = .done;
                                    return RenderCommand{
                                        .bbox = el.bbox,
                                        .z_index = el.data.floating.z_index,
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

        pub fn begin(self: *Self) void {
            self.layout.begin();
        }

        pub fn beginBreadth(self: *Self, breadth: bool) void {
            self.layout.beginBreadth(breadth);
        }

        pub fn openContainer(self: *Self, decl: ContainerDeclaration) usize {
            return self.layout.openUnit(root.layout.id(decl.id), decl);
        }

        pub fn openContainerBreadth(self: *Self, decl: ContainerDeclaration, breadth: usize) usize {
            return self.layout.openUnitBreadth(root.layout.id(decl.id), breadth);
        }

        pub fn putContent(self: *Self, decl: ContentDeclaration) !void {
            self.layout.openUnit(root.layout.id(decl.id), .{ .content = decl });
        }

        pub fn closeElement(self: *Self, unit_index: usize) void {
            self.layout.closeUnit(unit_index);
        }

        pub fn end(self: *Self) Commands {
            self.layout.end();

            var it = Commands{ .ctx = self };
            it.stack[0] = .{};
            return it;
        }
    };
}
