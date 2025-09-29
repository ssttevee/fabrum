const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const Vec2 = root.Vec2;
const Rect = root.Rect;
const Range = root.Range;

/// Gravity represents element alignment within a layout.
pub const Gravity = enum {
    /// Aligns the element to the start of the axis. This is the left for x and top for y.
    start,
    /// Aligns the element to the center of the axis.
    center,
    /// Aligns the element to the end of the axis. This is the right for x and bottom for y.
    end,

    pub const default = Gravity.start;
};

/// Padding represents the space around an element.
pub const Padding = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub inline fn h(self: Padding) f32 {
        return self.left + self.right;
    }

    pub inline fn v(self: Padding) f32 {
        return self.top + self.bottom;
    }

    pub inline fn sumAxis(self: Padding, axis: Vec2.Axis) f32 {
        return switch (axis) {
            .x => self.h(),
            .y => self.v(),
        };
    }

    pub inline fn toVec(self: Padding) Vec2 {
        return .init(self.h(), self.v());
    }

    pub inline fn topLeft(self: Padding) Vec2 {
        return .init(self.left, self.top);
    }

    pub fn init(left: f32, right: f32, top: f32, bottom: f32) Padding {
        return .{
            .left = left,
            .right = right,
            .top = top,
            .bottom = bottom,
        };
    }

    pub inline fn all(padding: f32) Padding {
        return .{
            .left = padding,
            .right = padding,
            .top = padding,
            .bottom = padding,
        };
    }

    pub inline fn x(x_pad: f32) Padding {
        return .{
            .left = x_pad,
            .right = x_pad,
        };
    }

    pub inline fn y(y_pad: f32) Padding {
        return .{
            .top = y_pad,
            .bottom = y_pad,
        };
    }

    pub inline fn xy(x_pad: f32, y_pad: f32) Padding {
        return .{
            .left = x_pad,
            .right = x_pad,
            .top = y_pad,
            .bottom = y_pad,
        };
    }
};

/// Sizing represents how to resolve the size of the element within a layout.
pub const Sizing = struct {
    width: Dimension = .default,
    height: Dimension = .default,

    /// Dimension represents how to resolve the size of the element in a particular axis.
    pub const Dimension = struct {
        // NOTE: a union was not used here for better initialization ergonomics
        mode: Mode,
        value: union {
            range: Range,
            number: f32,
        },

        pub const Mode = enum {
            fit,
            grow,
            percent,
            fixed,
        };

        pub const default = Dimension.fit(.{});

        pub fn eql(self: Dimension, other: Dimension) bool {
            if (self.mode != other.mode) {
                return false;
            }

            return switch (self.mode) {
                .fit, .grow => self.value.range.eql(other.value.range),
                .percent, .fixed => self.value.number == other.value.number,
            };
        }

        pub fn fit(range: Range) Dimension {
            return .{ .mode = .fit, .value = .{ .range = range } };
        }

        pub fn grow(range: Range) Dimension {
            return .{ .mode = .grow, .value = .{ .range = range } };
        }

        pub fn percent(pct: f32) Dimension {
            std.debug.assert(pct >= 0.0 and pct <= 1.0);
            return .{ .mode = .percent, .value = .{ .number = pct } };
        }

        pub fn fixed(value: f32) Dimension {
            return .{ .mode = .fixed, .value = .{ .number = value } };
        }

        fn intrinsic(self: Dimension) f32 {
            return switch (self.mode) {
                .fit => self.value.range.min,
                .grow => self.value.range.min,
                .percent => if (self.value.number > 0) std.math.inf(f32) else 0,
                .fixed => self.value.number,
            };
        }

        fn clamp(self: Dimension, current: f32, available: f32) f32 {
            return switch (self.mode) {
                .percent => available * self.value.number,
                .fixed => self.value.number,
                inline .fit, .grow => self.value.range.clamp(current),
            };
        }
    };

    pub const default = both(.default);

    pub fn init(w: Dimension, h: Dimension) Sizing {
        return .{ .width = w, .height = h };
    }

    fn both(dim: Dimension) Sizing {
        return .init(dim, dim);
    }

    pub fn fit(min_max: Range) Sizing {
        return both(.fit(min_max));
    }

    pub fn fitXY(x: Range, y: Range) Sizing {
        return init(.fit(x), .fit(y));
    }

    pub fn grow(min_max: Range) Sizing {
        return both(.grow(min_max));
    }

    pub fn growXY(x: Range, y: Range) Sizing {
        return init(.grow(x), .grow(y));
    }

    pub fn fixed(size: f32) Sizing {
        return both(.fixed(size));
    }

    pub fn fixedXY(x: f32, y: f32) Sizing {
        return init(.fixed(x), .fixed(y));
    }

    /// Range between 0 - 1
    pub fn percent(pct: f32) Sizing {
        return both(.percent(pct));
    }

    /// Range between 0 - 1
    pub fn percentXY(x: f32, y: f32) Sizing {
        return init(.percent(x), .percent(y));
    }

    pub fn intrinsic(self: Sizing) Vec2 {
        return .init(self.width.intrinsic(), self.height.intrinsic());
    }

    inline fn axisDimension(self: Sizing, axis: Vec2.Axis) Dimension {
        return switch (axis) {
            .x => self.width,
            .y => self.height,
        };
    }

    pub fn clamp(self: Sizing, size: Vec2, available: Vec2) Vec2 {
        return .init(
            self.width.clamp(size.x, available.x),
            self.height.clamp(size.y, available.y),
        );
    }

    pub fn eql(self: Sizing, other: Sizing) bool {
        return self.width.eql(other.width) and self.height.eql(other.height);
    }
};

/// ChildAlignment controls how child elements are aligned on each axis.
pub const ChildAlignment = struct {
    x: Gravity = .default,
    y: Gravity = .default,

    pub const top_left = init(.start, .start);
    pub const top_center = init(.center, .start);
    pub const top_right = init(.end, .start);

    pub const center_left = init(.start, .center);
    pub const center_center = init(.center, .center);
    pub const center_right = init(.end, .center);

    pub const bottom_left = init(.start, .end);
    pub const bottom_center = init(.center, .end);
    pub const bottom_right = init(.end, .end);

    pub const left_top = top_left;
    pub const left_center = center_left;
    pub const left_bottom = bottom_left;

    pub const center_top = top_center;
    pub const center_bottom = bottom_center;

    pub const right_top = top_right;
    pub const right_center = center_right;
    pub const right_bottom = bottom_right;

    pub const center = center_center;

    pub fn init(x: Gravity, y: Gravity) ChildAlignment {
        return .{ .x = x, .y = y };
    }

    pub fn axis(self: ChildAlignment, ax: Vec2.Axis) Gravity {
        return switch (ax) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

pub const Constraints = struct {
    max_width: ?f32,
    max_height: ?f32,

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

/// Controls various settings that affect the size and position of an element, as well as the sizes and positions
/// of any child elements.
///
/// Can be passed directly to `Context` as the `ElementData`.
pub const Config = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: f32 = 0,
    child_alignment: ChildAlignment = .{},
    axis: Vec2.Axis = .x,

    pub fn layoutConfig(self: *Config) *Config {
        return self;
    }

    pub fn isSizeFlexible(self: *const Config) bool {
        return self.sizing.width.mode != .fixed or self.sizing.height.mode != .fixed;
    }

    pub fn measure(self: *const Config, constraints: Constraints) Vec2 {
        return constraints.clamp(self.sizing.intrinsic());
    }
};

pub fn id(s: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, s));
}

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

    fn getDepth(self: ContextConfig) usize {
        return self.depth orelse std.math.sqrt(self.elements) * 2;
    }

    fn getBreadth(self: ContextConfig) usize {
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
/// `ElementData` is a struct that contains whatever information is necessary to
/// render the element as well as a method named `layoutConfig` that returns the
/// `LayoutConfig` for the element.
///
/// All allocations are made on initialization based on a target number of total
/// elements. Heuristics are used to estimate the amount of memory needed.
///
/// `begin` and `openElement` have `breadth` variants that can be used to
/// specify the maximum number of children an element can have. If these
/// functions are used for a large number of children, it's advisable to balance
/// it out with some smaller breadth elements, either manually or by setting the
/// `breadth` field.
pub fn Context(comptime ElementData: type, comptime context_config: ContextConfig) type {
    std.debug.assert(@hasDecl(ElementData, "layoutConfig"));
    std.debug.assert(@TypeOf(ElementData.layoutConfig) == fn (self: *ElementData) *Config);
    std.debug.assert(@hasDecl(ElementData, "isSizeFlexible"));
    std.debug.assert(@TypeOf(ElementData.isSizeFlexible) == fn (self: *const ElementData) bool);
    std.debug.assert(@hasDecl(ElementData, "measure"));
    std.debug.assert(@TypeOf(ElementData.measure) == fn (self: *const ElementData, constraints: Constraints) Vec2);

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

        pub const Element = struct {
            id: u32,
            parent: usize,
            data: ElementData,
            children: std.ArrayList(usize),

            // Computed
            size: Vec2 = .zero, // final width/height after distribution
            min_size: Vec2 = .zero, // aggregated intrinsic minimum content size
            bbox: Rect = .zero,

            fn config(self: *Element) *Config {
                return self.data.layoutConfig();
            }

            fn isSizeFlexible(self: *const Element) *Config {
                return self.data.isSizeFlexible();
            }

            fn measure(self: *const Element, constraints: Constraints) *Config {
                return self.data.measure(constraints);
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
        fn pushElement(self: *Self, element_id: u32, data: ElementData, breadth: usize) void {
            const parent = if (self.stack.items.len > 0) self.stack.getLast() else 0;
            self.stack.appendAssumeCapacity(self.elements.items.len);
            const children = self.ci_buf[self.ci_buf_pos .. self.ci_buf_pos + breadth];
            self.ci_buf_pos += breadth;
            if (element_id != 0) {
                self.ids.putAssumeCapacityNoClobber(element_id, self.elements.items.len);
            }

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
        pub fn begin(self: *Self) void {
            self.beginBreadth(default_breadth);
        }

        /// Starts a new layout. Must be finished with a call to `end`.
        ///
        /// After calling, previously built layout is destroyed. Create another
        /// context if you need keep it.
        pub fn beginConfig(self: *Self, cfg: Config) void {
            self.beginConfigBreadth(cfg, default_breadth);
        }

        /// Starts a new layout with a specific breadth. Must be finished with a
        /// call to `end`.
        ///
        /// After calling, previously built layout is destroyed. Create another
        /// context if you need keep it.
        pub fn beginBreadth(self: *Self, breadth: usize) void {
            self.beginConfigBreadth(.{}, breadth);
        }

        /// Starts a new layout with a specific breadth. Must be finished with a
        /// call to `end`.
        ///
        /// After calling, previously built layout is destroyed. Create another
        /// context if you need keep it.
        pub fn beginConfigBreadth(self: *Self, cfg: Config, breadth: usize) void {
            std.debug.assert(self.stack.items.len == 0);
            self.elements.items.len = 0;
            self.ids.clearRetainingCapacity();
            self.ci_buf_pos = 0;

            var data = ElementData{};
            data.layoutConfig().* = cfg;
            self.pushElement(0, data, breadth);
        }

        /// Opens a new element with the given configuration. Must be finished
        ///  with a matching call to `closeElement`.
        pub fn openElement(
            self: *Self,
            /// Number that must be unique within the context. It can be used
            /// to uniquely lookup and identify the element in various case.
            /// It's advisable to use a string hash. Use zero for no id.
            element_id: u32,
            data: ElementData,
        ) !usize {
            return try self.openElementBreadth(element_id, data, default_breadth);
        }

        /// Opens a new element with the given configuration and breadth. Must be
        /// finished with a matching call to `closeElement`.
        pub fn openElementBreadth(
            self: *Self,
            /// Number that must be unique within the context. It can be used
            /// to uniquely lookup and identify the element in various case.
            /// It's advisable to use a string hash. Use zero for no id.
            element_id: u32,
            data: ElementData,
            breadth: usize,
        ) !usize {
            std.debug.assert(self.stack.items.len > 0);

            if (self.elements.items.len >= self.elements.capacity) {
                return error.ReachedElementLimit;
            }

            if (self.stack.items.len >= self.stack.capacity) {
                return error.ReachedChildDepthLimit;
            }

            if (breadth > self.ci_buf.len - self.ci_buf_pos) {
                return error.ReachedChildrenBufferLimit;
            }

            const siblings = &self.get(self.stack.getLast()).children;
            if (siblings.items.len >= siblings.capacity) {
                return error.ReachedChildBreadthLimit;
            }

            const index = self.elements.items.len;
            self.pushElement(element_id, data, breadth);
            siblings.appendAssumeCapacity(index);

            return index;
        }

        /// Asserts the current element and closes it. Must be called after a matching `openElement`.
        pub fn closeElement(self: *Self, expected_index: usize) void {
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

        pub fn computeLayout(self: *const Self, width: f32, height: f32) void {
            self.computeLayoutVec(.init(width, height));
        }

        pub fn computeLayoutVec(self: *const Self, available: Vec2) void {
            std.debug.assert(self.stack.items.len == 0);
            std.debug.assert(self.elements.items.len > 0);

            // Stage 0: Root sizing bootstrap (Clay sets root explicitly if unset)
            const root_el = self.get(Self.root_id);
            if (root_el.config().sizing.eql(Sizing.default)) {
                if (ElementData == Config) {
                    root_el.data.sizing = .fixedXY(available.x, available.y);
                } else {
                    root_el.data.layout.sizing = .fixedXY(available.x, available.y);
                }
            }

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
            _ = self;
            // Placeholder: future parity with Clay
            // - Text wrapping affecting cross-axis size
            // - Image aspect ratio adjustments
            // - Upward propagation before second axis pass
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

        inline fn elementChildrenMinSizeTotal(self: *const Self, element: *Element, axis: Vec2.Axis) f32 {
            return self.elementChildrenAnySizeTotal(element, "min_size", axis);
        }

        inline fn elementChildrenMinSizeMax(self: *const Self, element: *Element, axis: Vec2.Axis) f32 {
            return self.elementChildrenAnySizeMax(element, "min_size", axis);
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
                    // For grow inheritance also propagate into min_size baseline if still zero
                    if (@field(el.min_size, @tagName(tag)) == 0) {
                        @field(el.min_size, @tagName(tag)) = @field(current_el.size, @tagName(tag));
                    }
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

const TestContext = Context(Config, .{});

test "horizontal fixed children basic sizing" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin();

    const wrapper = try ctx.openElement(0, .{ .padding = .xy(5, 10), .child_gap = 10 });
    const a = try ctx.openElement(0, .{ .sizing = .fixedXY(50, 20) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(60, 30) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .fixedXY(70, 40) });
    ctx.closeElement(c);
    ctx.closeElement(wrapper);

    ctx.end();
    ctx.computeLayout(400, 100);

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

    ctx.begin();

    const a = try ctx.openElement(0, .{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeElement(b);

    ctx.end();
    ctx.computeLayout(300, 50);

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    try std.testing.expectApproxEqAbs(150, c_a.size.x, 0.01);
    try std.testing.expectApproxEqAbs(150, c_b.size.x, 0.01);
}

test "percent sizing vertical" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.beginConfig(.{ .axis = .y });

    const a = try ctx.openElement(0, .{ .sizing = .init(.default, .percent(0.25)) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .init(.default, .percent(0.5)) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .fixedXY(50, 10) });
    ctx.closeElement(c);

    ctx.end();
    ctx.computeLayout(100, 200);

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

    ctx.begin();

    const a = try ctx.openElement(0, .{ .sizing = .fixedXY(80, 10) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .fixedXY(60, 10) });
    ctx.closeElement(c);

    ctx.end();
    ctx.computeLayout(100, 30);

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

    ctx.beginConfig(.{ .child_alignment = .center });

    const a = try ctx.openElement(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(20, 20) });
    ctx.closeElement(b);

    ctx.end();
    ctx.computeLayout(300, 50);

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    // Check they are vertically centered
    try std.testing.expectApproxEqAbs((50 - c_a.size.y) / 2, c_a.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs((50 - c_b.size.y) / 2, c_b.bbox.y, 0.01);
}
test "fixed children epsilon no compression" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin();

    const a = try ctx.openElement(0, .{ .sizing = .fixedXY(30, 10) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(30, 12) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .fixedXY(30, 14) });
    ctx.closeElement(c);

    ctx.end();
    ctx.computeLayout(80, 40);

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

    ctx.beginConfig(.{ .axis = .y, .child_alignment = .center });

    const a = try ctx.openElement(0, .{ .sizing = .fixedXY(30, 40) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(50, 20) });
    ctx.closeElement(b);

    ctx.end();
    ctx.computeLayout(100, 200);

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

    ctx.beginConfig(.{ .padding = .x(10), .child_gap = 20 });

    const a = try ctx.openElement(0, .{ .sizing = .init(.percent(0.5), .fixed(10)) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .init(.percent(0.5), .fixed(10)) });
    ctx.closeElement(b);

    ctx.end();
    ctx.computeLayout(300, 60);

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

    ctx.begin();

    const a = try ctx.openElement(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) });
    ctx.closeElement(b);

    ctx.end();
    ctx.computeLayout(100, 40);

    const c_a = ctx.get(a);
    const c_b = ctx.get(b);
    try std.testing.expect(c_a.size.x >= 60);
    try std.testing.expect(c_b.size.x >= 60);
}

test "grow after percent distribution horizontal leftover" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin();

    // Order: percent, fixed, grow
    const p = try ctx.openElement(0, .{ .sizing = .init(.percent(0.25), .fixed(10)) });
    ctx.closeElement(p);
    const f = try ctx.openElement(0, .{ .sizing = .fixedXY(100, 10) });
    ctx.closeElement(f);
    const g = try ctx.openElement(0, .{ .sizing = .init(.grow(.{ .min = 50, .max = 10000 }), .fixed(10)) });
    ctx.closeElement(g);

    ctx.end();
    ctx.computeLayout(500, 80);

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
    ctx.beginConfig(.{ .axis = .y });

    // p: 25% height of 400 = 100
    const p = try ctx.openElement(0, .{ .sizing = .init(.fixed(40), .percent(0.25)) });
    ctx.closeElement(p);
    // f: fixed height 60
    const f = try ctx.openElement(0, .{ .sizing = .fixedXY(60, 60) });
    ctx.closeElement(f);
    // g: grow min 40
    const g = try ctx.openElement(0, .{ .sizing = .init(.fixed(30), .grow(.{ .min = 40, .max = 1000 })) });
    ctx.closeElement(g);

    ctx.end();
    ctx.computeLayout(300, 400);

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

    ctx.begin();

    // a: fit so it remains at its intrinsic (min) and does not expand; b: percent; c: fixed
    const a = try ctx.openElement(0, .{ .sizing = .init(.fit(.{ .min = 50, .max = 500 }), .fixed(10)) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .init(.percent(0.25), .fixed(10)) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .fixedXY(80, 10) });
    ctx.closeElement(c);

    ctx.end();
    ctx.computeLayout(400, 80);

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
    ctx.beginConfig(.{ .axis = .y });

    const a = try ctx.openElement(0, .{ .sizing = .init(.fixed(40), .percent(0.5)) });
    ctx.closeElement(a);
    const b = try ctx.openElement(0, .{ .sizing = .fixedXY(60, 40) });
    ctx.closeElement(b);
    const c = try ctx.openElement(0, .{ .sizing = .init(.fixed(20), .percent(0.25)) });
    ctx.closeElement(c);

    ctx.end();
    ctx.computeLayout(120, 300);

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

    ctx.begin();

    // Container with intrinsic summed child width larger than parent available width.
    const cont = try ctx.openElement(0, .{ .sizing = .init(.fit(.{ .min = 10, .max = 500 }), .fixed(30)), .child_gap = 10 });
    const ca = try ctx.openElement(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeElement(ca);
    const cb = try ctx.openElement(0, .{ .sizing = .fixedXY(50, 15) });
    ctx.closeElement(cb);
    const cc = try ctx.openElement(0, .{ .sizing = .fixedXY(30, 12) });
    ctx.closeElement(cc);
    ctx.closeElement(cont);

    // Sibling to force overflow scenario
    const sib = try ctx.openElement(0, .{ .sizing = .fixedXY(10, 10) });
    ctx.closeElement(sib);

    ctx.end();
    ctx.computeLayout(120, 100);

    const c_cont = ctx.get(cont);
    // Intrinsic min content width = 40 + 50 + 30 + gaps(2*10) = 140
    try std.testing.expect(c_cont.size.x >= 140);
}
