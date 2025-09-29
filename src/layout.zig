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

        inline fn intrinsic(self: Dimension) f32 {
            return switch (self.mode) {
                else => 0,
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
};

/// Controls various settings that affect the size and position of an element, as well as the sizes and positions
/// of any child elements.
pub const Config = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: f32 = 0,
    child_alignment: ChildAlignment = .{},
    axis: Vec2.Axis = .x,

    /// Returns itself.
    ///
    /// This function exists solely to allow passing the layout config type
    /// directly to `Context` without a wrapper.
    pub inline fn layoutConfig(config: *Config) *Config {
        return config;
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
            size: Vec2 = .zero, // final width/height
            bbox: Rect = .zero,

            fn config(self: *Element) *Config {
                return self.data.layoutConfig();
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

            const root_el = self.get(Self.root_id);
            if (root_el.config().sizing.eql(Sizing.default)) {
                if (ElementData == Config) {
                    root_el.data.sizing = .fixedXY(available.x, available.y);
                } else {
                    root_el.data.layout.sizing = .fixedXY(available.x, available.y);
                }
            }

            // establish initial sizes (FIT -> padding, GROW treated like FIT for now)
            self.firstPass(Self.root_id);
            // Assign percent and fixed sizes relative to parent
            self.percentAndFixedPass(Self.root_id, available);
            // Axis distribution (grow / compression) for each container
            self.distributePass(Self.root_id);
            // Final positioning
            self.positionPass(Self.root_id, .zero);
        }

        fn childrenSizeTotal(self: *const Self, children: []const usize, gap: f32, comptime axis: Vec2.Axis) f32 {
            var total: f32 = 0;
            for (children, 0..) |child_index, i| {
                if (i != 0) {
                    total += gap;
                }

                total += @field(self.get(child_index).size, @tagName(axis));
            }

            return total;
        }

        fn childrenSizeMax(self: *const Self, children: []const usize, comptime axis: Vec2.Axis) f32 {
            var max: f32 = 0;
            for (children) |child_index| {
                max = @max(max, @field(self.get(child_index).size, @tagName(axis)));
            }

            return max;
        }

        fn firstPass(self: *const Self, index: usize) void {
            const el = self.get(index);

            const cfg = el.config();
            el.size = cfg.sizing.intrinsic();

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

            // Compute container size for fit/grow when direction considered
            if (el.children.items.len == 0) {
                return;
            }

            el.size = cfg.padding.toVec().addValues(
                switch (cfg.axis) {
                    .x => self.childrenSizeTotal(el.children.items, cfg.child_gap, .x),
                    .y => self.childrenSizeMax(el.children.items, .x),
                },
                switch (cfg.axis) {
                    .x => self.childrenSizeMax(el.children.items, .y),
                    .y => self.childrenSizeTotal(el.children.items, cfg.child_gap, .y),
                },
            );
        }

        fn percentAndFixedPass(self: *const Self, index: usize, available: Vec2) void {
            const el = self.get(index);
            const cfg = el.config();

            // First pass: apply explicit fixed / percent relative to parent 'available'
            el.size = cfg.sizing.clamp(el.size, available);

            // Recurse using the same parent 'available' (not el.size) so percent children
            // inside FIT/GROW containers resolve against ancestor fixed space. We will
            // recompute this container's FIT/GROW size after visiting children.
            for (el.children.items) |ci| {
                self.percentAndFixedPass(ci, el.size);
            }
        }

        fn distributePass(self: *const Self, index: usize) void {
            const el = self.get(index);
            for (el.children.items) |ci| {
                self.distributePass(ci);
            }

            if (el.children.items.len == 0) {
                return;
            }

            const cfg = el.config();
            switch (cfg.axis) {
                inline else => |axis| self.distributeAxis(
                    el,
                    @field(el.size, @tagName(axis)) - cfg.padding.sumAxis(axis),
                    axis,
                ),
            }
        }

        fn distributeAxis(self: *const Self, parent: *Element, inner: f32, comptime axis: Vec2.Axis) void {
            const children = parent.children.items;
            if (children.len == 0) {
                return;
            }

            const total = self.childrenSizeTotal(children, parent.config().child_gap, axis);

            const available = inner;
            const overflow = total - available;
            if (overflow > 0.0001) {
                // compress; build list of resizable (FIT/GROW) children
                // We'll use iterative largest reduction algorithm
                // Build arrays of sizes

                std.debug.assert(context_config.max_breadth >= children.len);

                // use a static size to avoid heap allocation
                // this function isn't recursive, so it probably won't overflow the stack
                var buf: [context_config.max_breadth]f32 = undefined;
                var sizes = buf[0..children.len];

                for (children, 0..) |ci, i| {
                    const ch = self.get(ci);
                    sizes[i] = @field(ch.size, @tagName(axis));
                }

                var remaining = overflow;
                while (remaining > 0.01) {
                    // find largest and second largest
                    var largest: f32 = -1;
                    var second: f32 = -1;
                    var count_largest: usize = 0;
                    for (sizes) |s| {
                        if (s > largest) {
                            second = largest;
                            largest = s;
                            count_largest = 1;
                        } else if (std.math.approxEqAbs(f32, s, largest, 0.0001)) {
                            count_largest += 1;
                        } else if (s > second) {
                            second = s;
                        }
                    }

                    second = @max(second, 0);

                    const reducible = (largest - second) * @as(f32, @floatFromInt(count_largest));
                    if (reducible <= 0.0001) {
                        // distribute evenly
                        const delta = remaining / @as(f32, @floatFromInt(count_largest));
                        for (sizes) |*s| {
                            if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                                s.* -= delta;
                                if (s.* < 0) s.* = 0;
                            }
                        }

                        break;
                    }

                    if (reducible < remaining) {
                        for (sizes) |*s| {
                            if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                                s.* = second;
                            }
                        }
                        remaining -= reducible;
                    } else {
                        const delta_each = remaining / @as(f32, @floatFromInt(count_largest));
                        for (sizes) |*s| {
                            if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                                s.* -= delta_each;
                                if (s.* < 0) s.* = 0;
                            }
                        }
                        remaining = 0;
                    }
                }

                // write back
                for (children, 0..) |ci, i| {
                    const ch = self.get(ci);
                    @field(ch.size, @tagName(axis)) = sizes[i];
                }
            } else {
                // expansion / grow
                var grow_count: usize = 0;
                var grow_sum: f32 = 0;
                for (children) |ci| {
                    const child = self.get(ci);
                    if (child.config().sizing.axisDimension(axis).mode == .grow) {
                        grow_count += 1;
                        grow_sum += @field(child.size, @tagName(axis));
                    }
                }

                if (grow_count > 0) {
                    const leftover = @max(available - total, 0);
                    const target = (leftover + grow_sum) / @as(f32, @floatFromInt(grow_count));
                    for (children) |ci| {
                        const child = self.get(ci);
                        if (child.config().sizing.axisDimension(axis).mode == .grow) {
                            @field(child.size, @tagName(axis)) = target;
                        }
                    }
                }
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
                .x => {
                    // alignment for cross axis
                    const total_w = self.childrenSizeTotal(el.children.items, cfg.child_gap, .x);

                    const leftover = (el.size.x - pad.h()) - total_w;
                    var x_cursor = inner_origin.x + switch (cfg.child_alignment.x) {
                        .start => 0,
                        .center => leftover / 2,
                        .end => leftover,
                    };

                    for (el.children.items) |ci| {
                        const child = self.get(ci);
                        const free_y = (el.size.y - pad.v()) - child.size.y;

                        const child_y = inner_origin.y + switch (cfg.child_alignment.y) {
                            .start => 0,
                            .center => free_y / 2,
                            .end => free_y,
                        };

                        self.positionPass(ci, .init(x_cursor, child_y));

                        x_cursor += child.size.x + cfg.child_gap;
                    }
                },
                .y => {
                    const total_h = self.childrenSizeTotal(el.children.items, cfg.child_gap, .y);
                    const leftover = (el.size.y - pad.v()) - total_h;
                    var y_cursor = inner_origin.y + switch (cfg.child_alignment.y) {
                        .start => 0,
                        .center => leftover / 2,
                        .end => leftover,
                    };

                    for (el.children.items) |ci| {
                        const child = self.get(ci);

                        const free_x = (el.size.x - pad.h()) - child.size.x;
                        const child_x = inner_origin.x + switch (cfg.child_alignment.x) {
                            .start => 0,
                            .center => free_x / 2,
                            .end => free_x,
                        };

                        self.positionPass(ci, .init(child_x, y_cursor));

                        y_cursor += child.size.y + cfg.child_gap;
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
    try std.testing.expectApproxEqAbs(50, c_a.size.y, 0.001); // 0.25 * 200
    try std.testing.expectApproxEqAbs(100, c_b.size.y, 0.001); // 0.5 * 200
    try std.testing.expectApproxEqAbs(10, c_c.size.y, 0.001); // intrinsic
}

test "compression shrink largest first" {
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
    try std.testing.expectApproxEqAbs(100, sum, 0.1);
    // Expect roughly equal sizes after compression
    try std.testing.expect(std.math.approxEqAbs(f32, c_a.size.x, c_b.size.x, 1.0));
    try std.testing.expect(std.math.approxEqAbs(f32, c_b.size.x, c_c.size.x, 1.0));
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
test "compression reducible epsilon branch" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Root width forces compression of equal-sized children where (largest - second) == 0
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

    // After epsilon branch compression, total should match available width
    const total = c_a.size.x + c_b.size.x + c_c.size.x;
    try std.testing.expectApproxEqAbs(80, total, 0.01);

    // All sizes should now be close to each other (even distribution)
    try std.testing.expect(std.math.approxEqAbs(f32, c_a.size.x, c_b.size.x, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, c_b.size.x, c_c.size.x, 0.01));
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
