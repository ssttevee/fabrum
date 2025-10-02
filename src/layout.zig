const std = @import("std");
const builtin = @import("builtin");

const root = @import("root.zig");
const Vec2 = root.Vec2;
const Rect = root.Rect;
const Range = root.Range;
const Content = root.Content;
const Color = root.Color;
const BorderWidths = root.BorderWidths;
const Sizing = root.Sizing;
const CornerRadius = root.CornerRadius;
const Padding = root.Padding;
const Alignment = root.Alignment;
const RenderCommand = root.RenderCommand;

pub const ScrollFlags = packed struct {
    horizontal: bool = false,
    vertical: bool = false,

    pub fn any(self: ScrollFlags) bool {
        return self.horizontal or self.vertical;
    }
};

pub const ContainerDeclaration = struct {
    id: []const u8 = "",

    /// Controls various settings that affect the size and position of an element, as well as the sizes and positions of any child elements.
    layout: Config = .{},

    /// Controls the background color of the resulting element.
    /// By convention specified as 0-255, but interpretation is up to the renderer.
    /// If no other config is specified, .backgroundColor will generate a RECTANGLE render command, otherwise it will be passed as a property to IMAGE or CUSTOM render commands.
    background_color: Color = .white,

    /// Controls the "radius", or corner rounding of elements, including rectangles, borders and images.
    corner_radius: CornerRadius = .{},

    /// Controls settings related to aspect ratio scaling.
    aspect_ratio: AspectRatioConfig = .{},

    /// Controls whether and how an element "floats", which means it layers over the top of other elements in z order, and doesn't affect the position and size of siblings or parent elements.
    floating: FloatingConfig = .{},

    /// Controls whether an element should clip its contents, as well as providing child x,y offset configuration for scrolling.
    clip: ClipConfig = .{},

    /// Controls settings related to element borders, and will generate BORDER render commands.
    border: BorderConfig = .{},

    /// A pointer that will be transparently passed through to resulting render commands.
    user_data: ?*anyopaque = null,

    pub const AspectRatioConfig = struct {
        /// A float representing the target "Aspect ratio" for an element, which is its final width divided by its final height.
        aspect_ratio: f32 = 0,
    };

    pub const FloatingConfig = struct {
        mode: AttachMode = .default,
        parent: union { id: u32, index: usize } = .{ .id = 0 },
        element_point: AttachPoint = .left_top,
        parent_point: AttachPoint = .left_top,
        offset: Vec2 = .zero,
        expand: Vec2 = .zero,
        z_index: i16 = 0,

        /// Transparently pass through pointer events like hover and click to elements underneath the floating element.
        pointer_passthrough: bool = false,

        /// Whether or not a floating element should be clipped to the same clipping rectangle as the element it's attached to.
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
            element_index,
            element_id,
            root,

            pub const default = AttachMode.none;
        };

        pub fn active(self: FloatingConfig) bool {
            return self.mode != .none;
        }
    };

    /// Controls the axis on which an element switches to "scrolling", which clips the contents and allows scrolling in that direction.
    pub const ClipConfig = struct {
        /// Clip overflowing elements on the X axis.
        horizontal: bool = false,
        /// Clip overflowing elements on the Y axis.
        vertical: bool = false,
        /// Offsets the x,y positions of all child elements. Used primarily for scrolling containers.
        child_offset: Vec2 = .zero,
    };

    pub const BorderConfig = struct {
        color: Color = .black,
        widths: BorderWidths = .{},
    };
};

pub const ContentDeclaration = struct {
    id: []const u8 = "",
    content: *Content,
};

/// Controls various settings that affect the size and position of an element, as well as the sizes and positions
/// of any child elements.
///
/// Can be passed directly to `Context` as the `UnitData`.
pub const Config = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: f32 = 0,
    child_alignment: Alignment = .{},
    axis: Vec2.Axis = .x,

    // pub fn isEmpty(self: LayoutConfig) bool {
    //     return self.sizing.eql(.default) and std.meta.eql(self.padding, Padding{}) and self.child_gap == 0 and std.meta.eql(self.child_alignment, ChildAlignment{}) and self.axis == .x;
    // }
};

pub const Constraints = struct {
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    pub const empty = init(null, null);

    pub fn init(width: ?f32, height: ?f32) Constraints {
        return .{ .max_width = width, .max_height = height };
    }

    pub fn isEmpty(self: Constraints) bool {
        return self.max_width == null and self.max_height == null;
    }

    pub fn clamp(self: Constraints, size: Vec2) Vec2 {
        return .init(
            if (self.max_width != null and size.x > self.max_width.?) self.max_width.? else size.x,
            if (self.max_height != null and size.y > self.max_height.?) self.max_height.? else size.y,
        );
    }
};

pub const ElementId = struct {
    id: u32 = 0,

    pub const none: ElementId = .{};
    pub const zero: ElementId = .{};

    pub fn fromInt(id: u32) ElementId {
        return .{ .id = id };
    }

    pub fn fromString(s: []const u8) ElementId {
        return .{ .id = @truncate(std.hash.Wyhash.hash(0, s)) };
    }
};

pub const Element = struct {
    id: u32,
    parent: usize,
    data: Data,
    children: std.ArrayList(usize),

    // Computed
    size: Vec2 = .zero, // final width/height after distribution
    min_size: Vec2 = .zero, // aggregated intrinsic minimum content size
    bbox: Rect = .zero,

    pub const Data = union(enum) {
        container: ContainerDeclaration,
        content: ContentDeclaration,
    };

    fn config(self: Element) Config {
        return switch (self.data) {
            .container => |container| container.layout,
            // content doesn't have layout config, default config will form to intrinsic size from `measure`
            .content => .{},
        };
    }

    fn measure(self: *const Element, constraints: Constraints) Vec2 {
        return switch (self.data) {
            .container => |container| constraints.clamp(container.layout.sizing.intrinsic()),
            // content doesn't have layout config, default config will form to intrinsic size from `measure`
            .content => |content| content.content.measure(constraints),
        };
    }
};

pub const ContextConfig = struct {
    /// Target number of total elements
    elements: usize = 1024,

    /// Level of the deepest nested child
    ///
    /// Estimated based on heuristics if null.
    depth: ?usize = null,

    /// Default number of direct children an element can have
    ///
    /// Estimated based on heuristics if null.
    breadth: ?usize = null,

    /// Maximum number of direct children an element can have.
    max_breadth: usize = 256,

    pub fn getDepth(self: ContextConfig) usize {
        return self.depth orelse std.math.sqrt(self.elements) * 2;
    }

    pub fn getBreadth(self: ContextConfig) usize {
        return self.breadth orelse std.math.sqrt(self.elements);
    }
};

fn sumF32(nums: []const f32) f32 {
    var sum: f32 = 0.0;
    for (nums) |num| {
        sum += num;
    }
    return sum;
}

fn vecAxisSwap(a: f32, b: f32, axis: Vec2.Axis) Vec2 {
    return switch (axis) {
        .x => .init(a, b),
        .y => .init(b, a),
    };
}

/// Context for layout operations.
///
/// `UnitData` is a struct that contains whatever information is necessary to
/// render the element as well as a method named `layoutConfig` that returns the
/// `LayoutConfig` for the element.
///
/// All allocations are made on initialization based on a target number of total
/// elements. Heuristics are used to estimate the amount of memory needed.
///
/// `begin` and `openContainer` have `breadth` variants that can be used to
/// specify the maximum number of children an element can have. If these
/// functions are used for a large number of children, it's advisable to balance
/// it out with some smaller breadth elements, either manually or by setting the
/// `breadth` field.
pub fn Context(comptime context_config: ContextConfig) type {
    const default_breadth = context_config.getBreadth();
    const depth = context_config.getDepth();
    return struct {
        elements: std.ArrayList(Element),
        ids: IdMap,
        stack: std.ArrayList(usize),
        ci_buf: []usize,
        ci_buf_pos: usize = 0,

        const Self = @This();

        pub const root_id = 0;

        const IdMap = std.ArrayHashMapUnmanaged(
            u32,
            usize,
            struct {
                pub fn hash(self: @This(), k: u32) u32 {
                    _ = self;
                    return k;
                }

                pub fn eql(self: @This(), a: u32, b: u32, i: usize) bool {
                    _ = self;
                    _ = i;
                    return a == b;
                }
            },
            false,
        );

        pub const RenderCommandIteratorImpl = struct {
            ctx: *const Self,
            stack: [depth]UnitTraversalState = undefined,
            len: usize = 1,
            iterator: RenderCommand.Iterator = .{
                .vtable = &.{
                    .next = nextFn,
                },
            },

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
                } = .clip_start, // progression through render emission for this element
                clip_active: bool = false,
                between_index: usize = 0,
                emitted_border: bool = false,
            };

            fn nextFn(interface: *RenderCommand.Iterator) ?RenderCommand {
                const self: *RenderCommandIteratorImpl = @fieldParentPtr("iterator", interface);

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
                                        .element_id = el.id,
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
                                        .element_id = el.id,
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
                                frame.phase = .descend_children;
                                return .{
                                    .bbox = el.bbox,
                                    .element_id = el.id,
                                    .data = .{ .content = decl.content },
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
                                    return interface.next();
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
                                                .element_id = el.id,
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
                                            .element_id = el.id,
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
                                        .element_id = el.id,
                                        .data = .scissor_end,
                                    };
                                }
                            },
                            else => {},
                        }
                        continue :sw .done;
                    },
                    .done => {
                        // Pop finished element
                        self.len -= 1;

                        // Advance parent child_pos
                        if (self.len > 0) {
                            self.stack[self.len - 1].child_pos += 1;
                        }

                        // Recurse to produce next element command
                        return interface.next();
                    },
                }
            }
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            var elements: std.ArrayList(Element) = .empty;
            errdefer elements.deinit(allocator);
            try elements.ensureTotalCapacityPrecise(allocator, context_config.elements);

            var ids: IdMap = .empty;
            errdefer ids.deinit(allocator);
            try ids.ensureTotalCapacity(allocator, context_config.elements);

            var stack: std.ArrayList(usize) = .empty;
            errdefer stack.deinit(allocator);
            try stack.ensureTotalCapacityPrecise(allocator, depth);

            const ci_buf = try allocator.alloc(usize, context_config.elements * default_breadth);

            return .{
                .elements = elements,
                .ids = ids,
                .stack = stack,
                .ci_buf = ci_buf,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.elements.deinit(allocator);
            self.stack.deinit(allocator);
            self.ids.deinit(allocator);
            allocator.free(self.ci_buf);
            self.* = undefined;
        }

        /// Assume available memory, check space before calling
        fn pushUnit(self: *Self, element_id: u32, data: Element.Data, breadth: usize) void {
            std.debug.assert(breadth <= context_config.max_breadth);

            if (element_id != 0) {
                self.ids.putAssumeCapacityNoClobber(element_id, self.elements.items.len);
            }

            const parent = if (self.stack.items.len > 0) self.stack.getLast() else 0;
            self.stack.appendAssumeCapacity(self.elements.items.len);

            const children = self.ci_buf[self.ci_buf_pos .. self.ci_buf_pos + breadth];
            self.ci_buf_pos += breadth;

            self.elements.appendAssumeCapacity(.{
                .id = element_id,
                .parent = parent,
                .data = data,
                .children = .initBuffer(children),
            });
        }

        /// Starts a new layout. Must be finished with a call to `end`.
        ///
        /// After calling, previously built layout is destroyed. Create another
        /// context if you need keep it.
        pub fn begin(self: *Self, cfg: Config) void {
            std.debug.assert(cfg.sizing.width.mode == .fixed);
            std.debug.assert(cfg.sizing.height.mode == .fixed);

            self.beginBreadth(cfg, default_breadth);
        }

        /// Starts a new layout with a specific breadth. Must be finished with a
        /// call to `end`.
        ///
        /// After calling, previously built layout is destroyed. Create another
        /// context if you need keep it.
        pub fn beginBreadth(self: *Self, cfg: Config, breadth: usize) void {
            std.debug.assert(self.stack.items.len == 0);

            self.elements.items.len = 0;
            self.ids.clearRetainingCapacity();
            self.ci_buf_pos = 0;

            self.pushUnit(0, .{ .container = .{ .layout = cfg } }, breadth);
        }

        /// Opens a new element with the given configuration. Must be finished
        ///  with a matching call to `closeUnit`.
        pub fn openContainer(
            self: *Self,
            element_id: ElementId,
            decl: ContainerDeclaration,
        ) usize {
            return self.openContainerBreadth(element_id, decl, default_breadth);
        }

        /// Opens a new element with the given configuration and breadth. Must be
        /// finished with a matching call to `closeUnit`.
        pub fn openContainerBreadth(
            self: *Self,
            element_id: ElementId,
            decl: ContainerDeclaration,
            breadth: usize,
        ) usize {
            std.debug.assert(self.stack.items.len > 0);

            if (self.elements.items.len >= self.elements.capacity) {
                // element limit reached, try increasing `context_config.max_elements`
                unreachable;
            }

            if (self.stack.items.len >= self.stack.capacity) {
                // child depth limit reached, try increasing `context_config.depth`
                unreachable;
            }

            if (breadth > self.ci_buf.len - self.ci_buf_pos) {
                // children buffer limit, try using `openContainerBreadth` with smaller
                // breadth values where possible
                unreachable;
            }

            const siblings = &self.get(self.stack.getLast()).children;
            if (siblings.items.len >= siblings.capacity) {
                // child breadth limit reached, try using `openContainerBreadth` with a
                // larger breadth value or increasing `context_config.max_breadth`
                unreachable;
            }

            const index = self.elements.items.len;
            self.pushUnit(element_id.id, .{ .container = decl }, breadth);
            siblings.appendAssumeCapacity(index);

            return index;
        }

        /// Asserts the current element and closes it. Must be called after a matching `openContainer`.
        pub fn closeContainer(self: *Self, expected_index: usize) void {
            std.debug.assert(expected_index == self.stack.pop());
        }

        /// Ends a layout. Must be called after `begin`.
        pub fn end(self: *Self) void {
            std.debug.assert(self.stack.items.len == 1);
            _ = self.stack.pop();
        }

        pub fn get(self: *const Self, i: usize) *Element {
            return &self.elements.items[i];
        }

        pub fn renderCommands(self: *const Self) RenderCommandIteratorImpl {
            std.debug.assert(self.elements.items.len > 0);
            std.debug.assert(!self.elements.items[0].size.isZero());
            var it = RenderCommandIteratorImpl{ .ctx = self };
            it.stack[0] = .{};
            return it;
        }

        pub fn computeLayout(self: *const Self) void {
            std.debug.assert(self.stack.items.len == 0);
            std.debug.assert(self.elements.items.len > 0);

            // Stage 0: Root sizing bootstrap (Clay sets root explicitly if unset)
            const root_el = self.get(Self.root_id);
            const available = root_el.measure(.{});

            // Stage 1: Intrinsic sizing (collect base FIT/GROW ranges -> current size)
            self.firstPass(Self.root_id);

            // Stage 2: Percent & fixed resolution (horizontal axis only)
            self.percentAndFixedAxisPass(Self.root_id, available.x, .x);

            // Stage 3: Horizontal axis distribution (grow / compression)
            self.sizeAxisPass(.x);

            // Stage 4: Content adjustments (text wrapping, image aspect) - placeholder
            self.contentAdjustmentPass();

            // Stage 5: Percent & fixed resolution (vertical axis after content adjustments)
            self.percentAndFixedAxisPass(Self.root_id, available.y, .y);

            // Stage 6: Vertical axis distribution (grow / compression)
            self.sizeAxisPass(.y);

            // Stage 7: Final positioning & alignment
            self.positionPass(Self.root_id, .zero);
        }

        fn sizeAxisPass(self: *const Self, comptime axis: Vec2.Axis) void {
            // Per-axis distribution pass:
            // - Only run grow/compression along the passed global axis for containers whose layout axis matches it.
            // - For containers whose layout axis differs, enforce/min-clamp children on this axis (off-axis adjustment).
            self.sizeAxisRecurse(Self.root_id, axis);
        }

        fn sizeAxisRecurse(self: *const Self, index: usize, comptime pass_axis: Vec2.Axis) void {
            const el = self.get(index);
            // Recurse first so child intrinsic/min adjustments are available
            for (el.children.items) |ci| {
                self.sizeAxisRecurse(ci, pass_axis);
            }
            if (el.children.items.len == 0) return;

            const cfg = el.config();
            if (cfg.axis == pass_axis) {
                // Main-axis distribution for this container
                const inner = @field(el.size, @tagName(pass_axis)) - cfg.padding.sumAxis(pass_axis);
                self.distributeAxis(el, inner, pass_axis);
            } else {
                // Off-axis: ensure children respect their content minimums and declared ranges on this global axis
                const axis_name = @tagName(pass_axis);
                for (el.children.items) |ci| {
                    const child = self.get(ci);
                    const dim = child.config().sizing.axisDimension(pass_axis);
                    switch (dim.mode) {
                        .fit, .grow => {
                            var v = @field(child.size, axis_name);
                            const content_min = @field(child.min_size, axis_name);
                            if (v < content_min) v = content_min;
                            const r = dim.value.range;
                            if (v < r.min) v = r.min;
                            if (v > r.max) v = r.max;
                            @field(child.size, axis_name) = v;
                        },
                        else => {},
                    }
                }
            }
        }

        fn contentAdjustmentPass(self: *const Self) void {
            // Phase 1: measure leaf content with horizontal width constraint (for wrapping)
            // A leaf's already–resolved width (after horizontal distribution & percent pass) is
            // treated as the available inner width for wrapping. Height may grow as a result.
            for (self.elements.items) |*el| {
                if (el.children.items.len != 0) continue;

                const cfg = el.config();

                // Inner width available for content after padding
                const inner_w = el.size.x - cfg.padding.sumAxis(.x);

                // Build constraints: only constrain width if > 0 (wrapping). We leave height unconstrained here.
                var constraints = Constraints.empty;
                if (inner_w > 0) {
                    constraints.max_width = inner_w;
                }

                const measured = el.measure(constraints);

                // Required total height including padding
                const needed_total_h = measured.y + cfg.padding.sumAxis(.y);

                // Increase element height if content needs more (only for fit/grow vertical sizing)
                const vdim = cfg.sizing.height;
                switch (vdim.mode) {
                    .fit, .grow => {
                        if (needed_total_h > el.size.y) {
                            // Clamp to declared max
                            const max_h = vdim.value.range.max;
                            el.size.y = if (needed_total_h > max_h) max_h else needed_total_h;
                        }
                    },
                    else => {}, // fixed / percent: keep existing resolved size; overflow is allowed
                }

                // Update content-derived minimum
                if (needed_total_h > el.min_size.y) {
                    el.min_size.y = needed_total_h;
                }
            }

            // Phase 2: upward aggregation – containers may need to expand vertically
            // after children (especially text) have wrapped / grown.
            var i: usize = self.elements.items.len;
            while (i > 0) {
                i -= 1;
                const el = &self.elements.items[i];
                if (el.children.items.len == 0) continue;

                const cfg = el.config();
                const pad_y = cfg.padding.sumAxis(.y);

                var needed_inner_h: f32 = 0;
                switch (cfg.axis) {
                    .x => {
                        // Cross axis (vertical) = max child height
                        var max_h: f32 = 0;
                        for (el.children.items) |ci| {
                            const ch = self.get(ci);
                            if (ch.size.y > max_h) max_h = ch.size.y;
                        }
                        needed_inner_h = max_h;
                    },
                    .y => {
                        // Layout axis vertical: sum child heights + gaps
                        var sum_h: f32 = 0;
                        for (el.children.items, 0..) |ci, idx| {
                            const ch = self.get(ci);
                            if (idx != 0) sum_h += cfg.child_gap;
                            sum_h += ch.size.y;
                        }
                        needed_inner_h = sum_h;
                    },
                }

                const needed_total_h = needed_inner_h + pad_y;

                const vdim = cfg.sizing.height;
                switch (vdim.mode) {
                    .fit, .grow => {
                        if (needed_total_h > el.size.y) {
                            const max_h = vdim.value.range.max;
                            el.size.y = if (needed_total_h > max_h) max_h else needed_total_h;
                        }
                    },
                    else => {}, // fixed / percent: do not auto-expand
                }

                if (needed_total_h > el.min_size.y) {
                    el.min_size.y = needed_total_h;
                }
            }
        }

        fn childrenAnySizeTotal(self: *const Self, children: []const usize, gap: f32, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
            var total: f32 = 0;
            for (children, 0..) |child_index, i| {
                if (i != 0) {
                    total += gap;
                }

                total += @field(self.get(child_index), size_field).axis(axis);
            }

            return total;
        }

        fn childrenAnySizeMax(self: *const Self, children: []const usize, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
            var max: f32 = 0;
            for (children) |child_index| {
                max = @max(max, @field(self.get(child_index), size_field).axis(axis));
            }

            return max;
        }

        inline fn elementChildrenAnySizeTotal(self: *const Self, element: *Element, size_field: []const u8, axis: Vec2.Axis) f32 {
            return self.childrenAnySizeTotal(element.children.items, element.config().child_gap, size_field, axis);
        }

        inline fn elementChildrenAnySizeMax(self: *const Self, element: *Element, size_field: []const u8, axis: Vec2.Axis) f32 {
            return self.childrenAnySizeMax(element.children.items, size_field, axis);
        }

        inline fn elementChildrenSizeTotal(self: *const Self, element: *Element, axis: Vec2.Axis) f32 {
            return self.elementChildrenAnySizeTotal(element, "size", axis);
        }

        inline fn elementChildrenSizeMax(self: *const Self, element: *Element, axis: Vec2.Axis) f32 {
            return self.elementChildrenAnySizeMax(element, "size", axis);
        }

        fn firstPass(self: *const Self, index: usize) void {
            const el = self.get(index);

            const cfg = el.config();
            el.size = cfg.sizing.intrinsic();
            // Seed intrinsic minimum to current intrinsic size (will be aggregated for containers)
            el.min_size = el.size;

            inline for (std.meta.tags(Vec2.Axis)) |axis| switch (axis) {
                inline else => |tag| {
                    var current_el = el;
                    while (@field(current_el.size, @tagName(tag)) == 0 and current_el.config().sizing.axisDimension(tag).mode == .grow) {
                        current_el = self.get(current_el.parent);
                    }

                    @field(el.size, @tagName(tag)) = @field(current_el.size, @tagName(tag));
                },
            };

            // Recurse children
            for (el.children.items) |child_index| {
                self.firstPass(child_index);
            }

            // Leaf: nothing further to aggregate
            if (el.children.items.len == 0) {
                return;
            }

            // Aggregate container final and minimum content size:
            // Along layout axis: sum + gaps; cross axis: max
            const padding = cfg.padding.toVec();
            inline for (.{ "size", "min_size" }) |field| {
                @field(el, field) = padding.add(switch (cfg.axis) {
                    inline else => |axis| vecAxisSwap(
                        self.elementChildrenAnySizeTotal(el, field, axis),
                        self.elementChildrenAnySizeMax(el, field, axis.cross()),
                        axis,
                    ),
                });
            }

            // Clamp min_size to declared sizing ranges (so later compression can use tighter of content vs declared)
            inline for (std.meta.tags(Vec2.Axis)) |axis| switch (axis) {
                inline else => |tag| {
                    const dim = cfg.sizing.axisDimension(tag);
                    switch (dim.mode) {
                        .fit, .grow => {
                            const r = dim.value.range;
                            @field(el.min_size, @tagName(tag)) = @max(el.min_size.axis(tag), r.min);
                            // (Don't raise above max here; max is enforced on final size separately)
                        },
                        .percent, .fixed => {
                            // For fixed / percent we treat current resolved size as minimum already
                        },
                    }
                },
            };
        }

        fn percentAndFixedAxisPass(self: *const Self, index: usize, available_axis: f32, comptime axis: Vec2.Axis) void {
            const el = self.get(index);
            const cfg = el.config();

            // Resolve this element's size along the given axis if percent or fixed
            const dim = cfg.sizing.axisDimension(axis);
            const axis_name = @tagName(axis);
            const current = @field(el.size, axis_name);
            switch (dim.mode) {
                .percent => {
                    // Parent available axis supplied already (outer size). For percent we apply to parent inner space:
                    const inner_available = available_axis - cfg.padding.sumAxis(axis);
                    @field(el.size, axis_name) = inner_available * dim.value.number;
                },
                .fixed => {
                    @field(el.size, axis_name) = dim.value.number;
                },
                .fit, .grow => {
                    // Leave intrinsic; later distribution / compression may adjust
                    @field(el.size, axis_name) = current;
                },
            }

            if (el.children.items.len == 0) return;

            // Compute child available axis (content box of this element)
            var child_available_axis = @field(el.size, axis_name) - cfg.padding.sumAxis(axis);
            if (cfg.axis == axis and el.children.items.len > 0) {
                child_available_axis -= cfg.child_gap * @as(f32, @floatFromInt(el.children.items.len - 1));
            }
            // Recurse
            for (el.children.items) |ci| {
                self.percentAndFixedAxisPass(ci, child_available_axis, axis);
            }
        }

        // (removed distributePass: per-axis sizing now handled by sizeAxisPass / sizeAxisRecurse)

        fn distributeAxis(self: *const Self, parent: *Element, inner: f32, comptime axis: Vec2.Axis) void {
            const children = parent.children.items;
            if (children.len == 0) return;

            const cfg = parent.config();
            std.debug.assert(context_config.max_breadth >= children.len);

            // Collect sizes and content mins
            var buf: [context_config.max_breadth]f32 = undefined;
            var min_buf: [context_config.max_breadth]f32 = undefined;
            var sizes = buf[0..children.len];
            var content_mins = min_buf[0..children.len];
            for (children, 0..) |ci, i| {
                const child = self.get(ci);
                sizes[i] = @field(child.size, @tagName(axis));
                content_mins[i] = @field(child.min_size, @tagName(axis));
            }

            // Initial clamp to content min & declared min/max (resizable only)
            for (children, 0..) |ci, i| {
                const child = self.get(ci);
                const dim = child.config().sizing.axisDimension(axis);
                switch (dim.mode) {
                    .fit, .grow => {
                        const r = dim.value.range;
                        const floor_val = @max(r.min, content_mins[i]);
                        if (sizes[i] < floor_val) sizes[i] = floor_val;
                        if (sizes[i] > r.max) sizes[i] = r.max;
                    },
                    else => {},
                }
            }

            const available = inner;
            const gap_total: f32 = if (children.len > 0) cfg.child_gap * @as(f32, @floatFromInt(children.len - 1)) else 0;

            const total = sumF32(sizes) + gap_total;
            var overflow = total - available;

            if (overflow > 0.0001) {
                // Equal-share compression among resizable children (fit/grow),
                // removing any child that hits its floor (content or declared min).
                var active: [context_config.max_breadth]bool = undefined;
                var active_count: usize = 0;
                for (children, 0..) |ci, i| {
                    const dim = self.get(ci).config().sizing.axisDimension(axis).mode;
                    const resizable = (dim == .fit or dim == .grow);
                    active[i] = resizable;
                    if (resizable) active_count += 1;
                }
                if (active_count > 0) {
                    while (overflow > 0.0001 and active_count > 0) {
                        // Remaining space to remove (overflow) distributed equally
                        const per = overflow / @as(f32, @floatFromInt(active_count));
                        var reduced: f32 = 0;
                        var any_progress = false;
                        for (children, 0..) |ci, i| {
                            if (!active[i]) continue;
                            const dim_axis = self.get(ci).config().sizing.axisDimension(axis);
                            const r = dim_axis.value.range;
                            const floor_val = @max(r.min, content_mins[i]);
                            const potential = sizes[i] - floor_val;
                            var deactivated = false;
                            if (potential <= 0.0001) {
                                // Already at or below floor; deactivate once
                                active[i] = false;
                                active_count -= 1;
                                deactivated = true;
                            } else {
                                const apply = if (potential > per) per else potential;
                                if (apply > 0.0001) {
                                    sizes[i] -= apply;
                                    reduced += apply;
                                    any_progress = true;
                                } else {
                                    // Numerically tiny; snap to floor
                                    sizes[i] = @max(sizes[i], floor_val);
                                }
                                if (sizes[i] <= floor_val + 0.0001) {
                                    sizes[i] = floor_val;
                                    if (!deactivated) {
                                        active[i] = false;
                                        active_count -= 1;
                                        deactivated = true;
                                    }
                                }
                            }
                        }
                        if (!any_progress or reduced <= 0.0001) break;
                        overflow -= reduced;
                    }
                }
                // Final clamp (safety)
                for (children, 0..) |ci, i| {
                    const dim_axis = self.get(ci).config().sizing.axisDimension(axis);
                    switch (dim_axis.mode) {
                        .fit, .grow => {
                            const r = dim_axis.value.range;
                            const floor_val = @max(r.min, content_mins[i]);
                            if (sizes[i] < floor_val) sizes[i] = floor_val;
                            if (sizes[i] > r.max) sizes[i] = r.max;
                        },
                        else => {},
                    }
                }
            } else {
                // Expansion: distribute leftover to GROW children (respect content min & declared max)
                var leftover = -overflow; // overflow is negative or near zero here
                leftover = available - (sumF32(sizes) + gap_total);
                if (leftover > 0.0001) {
                    var active: [context_config.max_breadth]bool = undefined;
                    var grow_exists = false;
                    for (children, 0..) |ci, i| {
                        const dim = self.get(ci).config().sizing.axisDimension(axis).mode;
                        active[i] = (dim == .grow);
                        if (active[i]) grow_exists = true;
                    }
                    if (grow_exists) {
                        while (leftover > 0.0001) {
                            var active_count: usize = 0;
                            var active_sum: f32 = 0;
                            for (sizes, 0..) |s, i| if (active[i]) {
                                active_count += 1;
                                active_sum += s;
                            };
                            if (active_count == 0) break;
                            const target = (active_sum + leftover) / @as(f32, @floatFromInt(active_count));
                            var consumed: f32 = 0;
                            for (children, 0..) |ci, i| {
                                if (!active[i]) continue;
                                const dim_axis = self.get(ci).config().sizing.axisDimension(axis);
                                const r = dim_axis.value.range;
                                const floor_val = @max(r.min, content_mins[i]);
                                var new_size = target;
                                if (new_size < floor_val) new_size = floor_val;
                                if (new_size > r.max) new_size = r.max;
                                consumed += (new_size - sizes[i]);
                                sizes[i] = new_size;
                                if (sizes[i] >= r.max - 0.0001) active[i] = false;
                            }
                            if (consumed <= 0.0001) break;
                            leftover = available - (sumF32(sizes) + gap_total);
                        }
                    }
                }
            }

            // Write back final sizes
            for (children, 0..) |ci, i| {
                const ch = self.get(ci);
                @field(ch.size, @tagName(axis)) = sizes[i];
            }
        }

        fn positionPass(self: *const Self, index: usize, origin: Vec2) void {
            var el = self.get(index);
            el.bbox.x = origin.x;
            el.bbox.y = origin.y;
            el.bbox.w = el.size.x;
            el.bbox.h = el.size.y;
            if (el.children.items.len == 0) {
                return;
            }

            const cfg = el.config();
            const pad = cfg.padding;
            const inner_origin = pad.topLeft().add(origin);
            switch (cfg.axis) {
                inline else => |axis| {
                    // alignment for cross axis
                    const total_size = self.elementChildrenSizeTotal(el, axis);
                    const leftover = el.size.axis(axis) - pad.sumAxis(axis) - total_size;
                    var cursor = inner_origin.axis(axis) + switch (cfg.child_alignment.axis(axis)) {
                        .start => 0,
                        .center => leftover / 2,
                        .end => leftover,
                    };

                    const cross_axis = comptime axis.cross();
                    for (el.children.items) |ci| {
                        const child = self.get(ci);
                        const cross_free = el.size.axis(cross_axis) - pad.sumAxis(cross_axis) - child.size.axis(cross_axis);

                        const cross_child = inner_origin.axis(cross_axis) + switch (cfg.child_alignment.axis(cross_axis)) {
                            .start => 0,
                            .center => cross_free / 2,
                            .end => cross_free,
                        };

                        self.positionPass(
                            ci,
                            vecAxisSwap(
                                cursor,
                                cross_child,
                                axis,
                            ),
                        );

                        cursor += child.size.axis(axis) + cfg.child_gap;
                    }
                },
            }
        }
    };
}

// --------------------------- Tests ---------------------------

const TestContext = Context(.{});

test "horizontal fixed children basic sizing" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(400, 100) });

    const wrapper = ctx.openContainer(.zero, .{ .layout = .{ .padding = .xy(5, 10), .child_gap = 10 } });
    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(50, 20) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(60, 30) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(70, 40) } });
    ctx.closeContainer(c);
    ctx.closeContainer(wrapper);

    ctx.end();
    ctx.computeLayout();

    const r = ctx.get(TestContext.root_id);
    try std.testing.expectApproxEqAbs(400, r.size.x, 0.001);
    try std.testing.expectApproxEqAbs(100, r.size.y, 0.001);
    // child positions
    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);
    try std.testing.expectApproxEqAbs(5, c_a.bbox.x, 0.001);
    try std.testing.expectApproxEqAbs(5 + 50 + 10, c_b.bbox.x, 0.001);
    try std.testing.expectApproxEqAbs(5 + 50 + 10 + 60 + 10, c_c.bbox.x, 0.001);
}

test "grow distribution horizontal" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(300, 50) });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{}), .default) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{}), .default) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    try std.testing.expectApproxEqAbs(150, c_a.size.x, 0.01);
    try std.testing.expectApproxEqAbs(150, c_b.size.x, 0.01);
}

test "percent sizing vertical" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(100, 200), .axis = .y });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.default, .percent(0.25)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.default, .percent(0.5)) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(50, 10) } });
    ctx.closeContainer(c);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);

    // Updated expectations: rely on ratio rather than absolute parent space.
    try std.testing.expectApproxEqAbs(50, c_a.size.y, 0.001);
    try std.testing.expectApproxEqAbs(100, c_b.size.y, 0.001);
    try std.testing.expectApproxEqAbs(10, c_c.size.y, 0.001);
}

test "fixed children no compression horizontal" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(100, 30) });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(80, 10) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(40, 10) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(60, 10) } });
    ctx.closeContainer(c);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);
    const sum = c_a.size.x + c_b.size.x + c_c.size.x;

    // Updated: current implementation keeps intrinsic total (no compression of fixed).
    try std.testing.expectApproxEqAbs(180, sum, 0.1);
    try std.testing.expectApproxEqAbs(80, c_a.size.x, 0.001);
    try std.testing.expectApproxEqAbs(40, c_b.size.x, 0.001);
    try std.testing.expectApproxEqAbs(60, c_c.size.x, 0.001);
}

test "alignment center horizontal" {
    const gpa = std.testing.allocator;
    var ctx = try TestContext.init(gpa);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(300, 50), .child_alignment = .center });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(40, 10) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(20, 20) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    // Check they are vertically centered
    try std.testing.expectApproxEqAbs((50 - c_a.size.y) / 2, c_a.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs((50 - c_b.size.y) / 2, c_b.bbox.y, 0.01);
}

test "fixed children epsilon no compression" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(80, 40) });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(30, 10) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(30, 12) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(30, 14) } });
    ctx.closeContainer(c);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);

    const total = c_a.size.x + c_b.size.x + c_c.size.x;
    // Updated: fixed children retain original widths (no compression), sum is intrinsic.
    try std.testing.expectApproxEqAbs(90, total, 0.01);
    try std.testing.expectApproxEqAbs(30, c_a.size.x, 0.001);
    try std.testing.expectApproxEqAbs(30, c_b.size.x, 0.001);
    try std.testing.expectApproxEqAbs(30, c_c.size.x, 0.001);
}

test "alignment center vertical direction" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(100, 200), .axis = .y, .child_alignment = .center });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(30, 40) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(50, 20) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);

    // Vertical centering along layout axis:
    // total children height = 40 + 20 = 60, leftover = 200 - 60 = 140, start offset = 70
    try std.testing.expectApproxEqAbs(70, c_a.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs(110, c_b.bbox.y, 0.01); // 70 + first height (40)

    // Horizontal centering per child
    try std.testing.expectApproxEqAbs((100 - 30) / 2, c_a.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs((100 - 50) / 2, c_b.bbox.x, 0.01);
}

test "percent sizing subtracts padding and gaps" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(300, 60), .padding = .x(10), .child_gap = 20 });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.percent(0.5), .fixed(10)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.percent(0.5), .fixed(10)) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);

    // inner main = 300 - (10+10) = 280; minus one gap (20) => 260; each percent(0.5) = 130
    try std.testing.expectApproxEqAbs(130, c_a.size.x, 0.01);
    try std.testing.expectApproxEqAbs(130, c_b.size.x, 0.01);

    // Updated positions
    try std.testing.expectApproxEqAbs(10, c_a.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs(10 + 130 + 20, c_b.bbox.x, 0.01);
}

test "compression enforces min range values" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(100, 40) });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    try std.testing.expect(c_a.size.x >= 60);
    try std.testing.expect(c_b.size.x >= 60);
}

test "grow after percent distribution horizontal leftover" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(500, 80) });

    // Order: percent, fixed, grow
    const p = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.percent(0.25), .fixed(10)) } });
    ctx.closeContainer(p);
    const f = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(100, 10) } });
    ctx.closeContainer(f);
    const g = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{ .min = 50, .max = 10000 }), .fixed(10)) } });
    ctx.closeContainer(g);

    ctx.end();
    ctx.computeLayout();

    const c_p = ctx.get(p);
    const c_f = ctx.get(f);
    const c_g = ctx.get(g);

    // Percent (25%) resolved before distribution
    try std.testing.expectApproxEqAbs(125, c_p.size.x, 0.01);
    try std.testing.expectApproxEqAbs(100, c_f.size.x, 0.01);

    // Leftover: 500 - (125 + 100) = 275 -> single grow child consumes all
    try std.testing.expectApproxEqAbs(275, c_g.size.x, 0.01);
}

test "vertical grow after percent distribution leftover" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Vertical layout axis
    ctx.begin(.{ .sizing = .fixedXY(300, 400), .axis = .y });

    // p: 25% height of 400 = 100
    const p = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fixed(40), .percent(0.25)) } });
    ctx.closeContainer(p);
    // f: fixed height 60
    const f = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(60, 60) } });
    ctx.closeContainer(f);
    // g: grow min 40
    const g = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fixed(30), .grow(.{ .min = 40, .max = 1000 })) } });
    ctx.closeContainer(g);

    ctx.end();
    ctx.computeLayout();

    const c_p = ctx.get(p);
    const c_f = ctx.get(f);
    const c_g = ctx.get(g);

    try std.testing.expectApproxEqAbs(100, c_p.size.y, 0.01);
    try std.testing.expectApproxEqAbs(60, c_f.size.y, 0.01);
    // Leftover: 400 - (100 + 60 + 40 intrinsic grow min) = 200 -> grow child final 240
    try std.testing.expectApproxEqAbs(240, c_g.size.y, 0.01);
}

test "mixed percent grow fixed horizontal" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(400, 80) });

    // a: fit so it remains at its intrinsic (min) and does not expand; b: percent; c: fixed
    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fit(.{ .min = 50, .max = 500 }), .fixed(10)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.percent(0.25), .fixed(10)) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(80, 10) } });
    ctx.closeContainer(c);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);

    try std.testing.expectApproxEqAbs(50, c_a.size.x, 0.01);
    try std.testing.expectApproxEqAbs(100, c_b.size.x, 0.01); // 25% of 400
    try std.testing.expectApproxEqAbs(80, c_c.size.x, 0.01);
}

test "vertical percent ordering after horizontal distribution" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Layout axis vertical
    ctx.begin(.{ .sizing = .fixedXY(120, 300), .axis = .y });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fixed(40), .percent(0.5)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(60, 40) } });
    ctx.closeContainer(b);
    const c = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fixed(20), .percent(0.25)) } });
    ctx.closeContainer(c);

    ctx.end();
    ctx.computeLayout();

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    const c_c = ctx.get(c);

    try std.testing.expectApproxEqAbs(150, c_a.size.y, 0.01); // 50% of 300
    try std.testing.expectApproxEqAbs(40, c_b.size.y, 0.01);
    try std.testing.expectApproxEqAbs(75, c_c.size.y, 0.01); // 25% of 300
}

test "min_size floors prevent compression" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(120, 100) });

    // Container with intrinsic summed child width larger than parent available width.
    const cont = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.fit(.{ .min = 10, .max = 500 }), .fixed(30)), .child_gap = 10 } });
    const ca = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(40, 10) } });
    ctx.closeContainer(ca);
    const cb = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(50, 15) } });
    ctx.closeContainer(cb);
    const cc = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(30, 12) } });
    ctx.closeContainer(cc);
    ctx.closeContainer(cont);

    // Sibling to force overflow scenario
    const sib = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(10, 10) } });
    ctx.closeContainer(sib);

    ctx.end();
    ctx.computeLayout();

    const c_cont = ctx.get(cont);
    // Intrinsic min content width = 40 + 50 + 30 + gaps(2*10) = 140
    try std.testing.expect(c_cont.size.x >= 140);
}

test "overflow horizontal positioning no compression" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = .fixedXY(200, 80) });

    const cont = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(200, 50) } });
    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(150, 40) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(150, 40) } });
    ctx.closeContainer(b);
    ctx.closeContainer(cont);

    ctx.end();
    ctx.computeLayout();

    const c_cont = ctx.get(cont);
    const c_a = ctx.get(a);
    const c_b = ctx.get(b);

    // Children retain fixed widths and overflow horizontally
    try std.testing.expectApproxEqAbs(150, c_a.size.x, 0.01);
    try std.testing.expectApproxEqAbs(150, c_b.size.x, 0.01);
    try std.testing.expect(c_b.bbox.x + c_b.size.x > c_cont.size.x);
}

test "cross-axis horizontal centering with width disparity (vertical layout)" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Root vertical axis with center alignment (centers children horizontally)
    ctx.begin(.{ .sizing = .fixedXY(400, 500), .axis = .y, .child_alignment = .center, .child_gap = 20 });

    const wide = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(300, 60) } });
    ctx.closeContainer(wide);
    const narrow = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .fixedXY(100, 40) } });
    ctx.closeContainer(narrow);

    ctx.end();
    ctx.computeLayout();

    const wide_el = ctx.get(wide);
    const narrow_el = ctx.get(narrow);

    // Centered horizontally
    try std.testing.expectApproxEqAbs((400 - 300) / 2, wide_el.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs((400 - 100) / 2, narrow_el.bbox.x, 0.01);

    // Vertical centered stacking order with gap (start at (500 - (60 + 40 + 20)) / 2 = 190)
    try std.testing.expectApproxEqAbs(190, wide_el.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs(190 + wide_el.size.y + 20, narrow_el.bbox.y, 0.01);
}

test "compression no-op when children already at floor" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Root width slightly smaller than sum of two grow children at their min (60 + 60 = 120).
    // We set available width to 115 to force compression attempt; both at floor so no change.
    ctx.begin(.{ .sizing = .fixedXY(115, 80) });

    const a = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(20)) } });
    ctx.closeContainer(a);
    const b = ctx.openContainer(.zero, .{ .layout = .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(30)) } });
    ctx.closeContainer(b);

    ctx.end();
    ctx.computeLayout();

    const ea = ctx.get(a);
    const eb = ctx.get(b);

    // Both remain at their floor (min) sizes; compression loop should early‑deactivate them
    // covering the branch where potential <= 0.0001.
    try std.testing.expectApproxEqAbs(60, ea.size.x, 0.001);
    try std.testing.expectApproxEqAbs(60, eb.size.x, 0.001);
}
