const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    const Axis = enum {
        x,
        y,

        fn other(self: Axis) Axis {
            return switch (self) {
                .x => .y,
                .y => .x,
            };
        }
    };

    pub const zero = init(0, 0);

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return init(self.x + other.x, self.y + other.y);
    }
};

pub const BoundingBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub const zero = init(.zero, .zero);

    pub fn init(pt1: Vec2, pt2: Vec2) BoundingBox {
        return BoundingBox{
            .x = @min(pt1.x, pt2.x),
            .y = @min(pt1.y, pt2.y),
            .w = @abs(pt1.x - pt2.x),
            .h = @abs(pt1.y - pt2.y),
        };
    }
};

pub const LayoutDirection = enum {
    left_to_right,
    top_to_bottom,

    pub const default: LayoutDirection = .left_to_right;

    fn axis(self: LayoutDirection) Vec2.Axis {
        return switch (self) {
            .left_to_right => .x,
            .top_to_bottom => .y,
        };
    }
};

pub const AlignX = enum {
    left,
    center,
    right,

    pub const default: AlignX = .left;
};

pub const AlignY = enum {
    top,
    center,
    bottom,

    pub const default: AlignY = .top;
};

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

pub const Sizing = struct {
    width: Dimension = .default,
    height: Dimension = .default,

    /// Controls how the element takes up space inside its parent container.
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

    /// Controls the minimum and maximum size in pixels that this element is allowed to grow or shrink to,
    /// overriding sizing types such as FIT or GROW.
    pub const Range = extern struct {
        /// The smallest final size of the element on this axis will be this value in pixels.
        min: f32 = 0,

        /// The largest final size of the element on this axis will be this value in pixels.
        max: f32 = std.math.inf(f32),

        pub fn clamp(self: Range, value: f32) f32 {
            return std.math.clamp(value, self.min, self.max);
        }
    };

    pub fn init(w: Dimension, h: Dimension) Sizing {
        return .{ .width = w, .height = h };
    }

    fn both(dim: Dimension) Sizing {
        return .init(dim);
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
};

/// Controls how child elements are aligned on each axis.
pub const ChildAlignment = struct {
    x: AlignX = .left,
    y: AlignY = .top,

    pub const top_left = init(.left, .top);
    pub const top_center = init(.center, .top);
    pub const top_right = init(.right, .top);

    pub const center_left = init(.left, .center);
    pub const center_center = init(.center, .center);
    pub const center_right = init(.right, .center);

    pub const bottom_left = init(.left, .bottom);
    pub const bottom_center = init(.center, .bottom);
    pub const bottom_right = init(.right, .bottom);

    pub const left_top = top_left;
    pub const left_center = center_left;
    pub const left_bottom = bottom_left;

    pub const center_top = top_center;
    pub const center_bottom = bottom_center;

    pub const right_top = top_right;
    pub const right_center = center_right;
    pub const right_bottom = bottom_right;

    pub const center = center_center;

    pub fn init(x: AlignX, y: AlignY) ChildAlignment {
        return .{ .x = x, .y = y };
    }
};

/// Controls various settings that affect the size and position of an element, as well as the sizes and positions
/// of any child elements.
pub const LayoutConfig = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: f32 = 0,
    child_alignment: ChildAlignment = .{},
    direction: LayoutDirection = .left_to_right,
};

pub const Element = struct {
    id: u64,
    config: LayoutConfig,
    children: std.ArrayListUnmanaged(u32) = .{},

    // Computed
    size: Vec2 = .zero, // final width/height
    bbox: BoundingBox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayList(Element) = .{},
    stack: std.ArrayList(u32) = .{},
    next_id: u64 = root_id,

    pub const root_id = 0;

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Context) void {
        for (self.elements.items) |*el| el.children.deinit(self.allocator);
        self.elements.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    pub fn beginRoot(self: *Context, cfg: LayoutConfig) !void {
        std.debug.assert(self.stack.items.len == 0);
        try self.openElement(cfg);
    }

    pub fn openElement(self: *Context, cfg: LayoutConfig) !void {
        const id = self.next_id;
        self.next_id += 1;
        const idx: u32 = @intCast(self.elements.items.len);
        try self.elements.append(self.allocator, .{ .id = id, .config = cfg });
        try self.stack.append(self.allocator, idx);
        if (self.stack.items.len > 1) {
            const parent = self.stack.items[self.stack.items.len - 2];
            try self.elements.items[parent].children.append(self.allocator, idx);
        }
    }

    pub fn closeElement(self: *Context) void {
        _ = self.stack.pop();
    }

    pub fn endRoot(self: *Context) void {
        std.debug.assert(self.stack.items.len == 1);
        self.closeElement();
        self.next_id = root_id;
    }

    pub fn get(self: *const Context, i: u32) *Element {
        return &self.elements.items[i];
    }

    inline fn childrenSizeTotal(self: *const Context, children: []const u32, gap: f32, comptime axis: Vec2.Axis) f32 {
        var total: f32 = 0;
        for (children, 0..) |child_index, i| {
            if (i != 0) {
                total += gap;
            }

            total += @field(self.get(child_index).size, @tagName(axis));
        }

        return total;
    }

    inline fn childrenSizeMax(self: *const Context, children: []const u32, comptime axis: Vec2.Axis) f32 {
        var max: f32 = 0;
        for (children) |child_index| {
            max = @max(max, @field(self.get(child_index).size, @tagName(axis)));
        }

        return max;
    }

    pub fn computeLayout(ctx: *const Context, available: Vec2) void {
        // First pass: establish initial sizes (FIT -> padding, GROW treated like FIT for now)
        ctx.firstPass(Context.root_id);
        // Assign percent and fixed sizes relative to parent pass
        ctx.percentAndFixedPass(Context.root_id, available);
        // Axis distribution (grow / compression) pass for each container
        ctx.distributePass(Context.root_id);
        // Final positioning pass
        ctx.positionPass(Context.root_id, .zero);
    }

    fn firstPass(ctx: *const Context, index: u32) void {
        const el = ctx.get(index);

        const cfg = el.config;
        el.size = cfg.sizing.intrinsic();

        // Recurse children
        for (el.children.items) |child_index| {
            ctx.firstPass(child_index);
        }

        // Compute container size for fit/grow when direction considered
        if (el.children.items.len == 0) {
            return;
        }

        el.size = cfg.padding.toVec().add(switch (cfg.direction) {
            .left_to_right => .init(
                ctx.childrenSizeTotal(el.children.items, cfg.child_gap, .x),
                ctx.childrenSizeMax(el.children.items, .y),
            ),
            .top_to_bottom => .init(
                ctx.childrenSizeMax(el.children.items, .x),
                ctx.childrenSizeTotal(el.children.items, cfg.child_gap, .y),
            ),
        });
    }

    fn percentAndFixedPass(ctx: *const Context, index: u32, available: Vec2) void {
        const el = ctx.get(index);
        const cfg = el.config;

        // Adjust own size first so children with percent sizing see the final parent size.
        el.size.x = cfg.sizing.width.clamp(el.size.x, available.x);
        el.size.y = cfg.sizing.height.clamp(el.size.y, available.y);

        // Recurse after final size known
        for (el.children.items) |child_index| {
            ctx.percentAndFixedPass(child_index, el.size);
        }
    }

    fn distributePass(ctx: *const Context, index: u32) void {
        const el = ctx.get(index);
        for (el.children.items) |child_index| {
            ctx.distributePass(child_index);
        }

        if (el.children.items.len == 0) {
            return;
        }

        const cfg = el.config;
        switch (cfg.direction.axis()) {
            inline else => |axis| ctx.distributeAxis(
                el,
                @field(el.size, @tagName(axis)) - cfg.padding.sumAxis(axis),
                axis,
            ),
        }
    }

    fn distributeAxis(ctx: *const Context, parent: *Element, inner: f32, comptime axis: Vec2.Axis) void {
        const children = parent.children.items;
        if (children.len == 0) {
            return;
        }

        const total = ctx.childrenSizeTotal(children, parent.config.child_gap, axis);

        const available = inner;
        const overflow = total - available;
        if (overflow > 0.0001) {
            // compress; build list of resizable (FIT/GROW) children
            // We'll use iterative largest reduction algorithm
            // Build arrays of sizes

            // TODO replace with comptime variable for max number of children
            var buf: [512]f32 = undefined;
            var sizes = std.ArrayList(f32).initBuffer(&buf);
            std.debug.assert(sizes.capacity > children.len);

            for (children) |ci| {
                const ch = ctx.get(ci);
                sizes.appendAssumeCapacity(@field(ch.size, @tagName(axis)));
            }

            var remaining = overflow;
            while (remaining > 0.01) {
                // find largest and second largest
                var largest: f32 = -1;
                var second: f32 = -1;
                var count_largest: usize = 0;
                for (sizes.items) |s| {
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

                if (second < 0) second = 0;
                const reducible = (largest - second) * @as(f32, @floatFromInt(count_largest));
                if (reducible <= 0.0001) {
                    // distribute evenly
                    const delta = remaining / @as(f32, @floatFromInt(count_largest));
                    for (sizes.items) |*s| {
                        if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                            s.* -= delta;
                            if (s.* < 0) s.* = 0;
                        }
                    }
                    break;
                } else if (reducible < remaining) {
                    for (sizes.items) |*s| {
                        if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                            s.* = second;
                        }
                    }
                    remaining -= reducible;
                } else {
                    const delta_each = remaining / @as(f32, @floatFromInt(count_largest));
                    for (sizes.items) |*s| {
                        if (std.math.approxEqAbs(f32, s.*, largest, 0.0001)) {
                            s.* -= delta_each;
                            if (s.* < 0) s.* = 0;
                        }
                    }
                    remaining = 0;
                }
            }

            // write back
            for (children, 0..) |ci, idx| {
                const ch = ctx.get(ci);
                @field(ch.size, @tagName(axis)) = sizes.items[idx];
            }
        } else {
            // expansion / grow
            var grow_count: usize = 0;
            var grow_sum: f32 = 0;
            for (children) |ci| {
                const child = ctx.get(ci);
                if (child.config.sizing.axisDimension(axis).mode == .grow) {
                    grow_count += 1;
                    grow_sum += @field(child.size, @tagName(axis));
                }
            }

            if (grow_count > 0) {
                var leftover = available - total;
                if (leftover < 0) leftover = 0;
                const target = (leftover + grow_sum) / @as(f32, @floatFromInt(grow_count));
                for (children) |ci| {
                    const child = ctx.get(ci);
                    if (child.config.sizing.axisDimension(axis).mode == .grow) {
                        @field(child.size, @tagName(axis)) = target;
                    }
                }
            }
        }
    }

    fn positionPass(ctx: *const Context, index: u32, origin: Vec2) void {
        var el = ctx.get(index);
        el.bbox.x = origin.x;
        el.bbox.y = origin.y;
        el.bbox.w = el.size.x;
        el.bbox.h = el.size.y;
        if (el.children.items.len == 0) {
            return;
        }

        const cfg = el.config;
        const pad = cfg.padding;
        const inner_origin = pad.topLeft().add(origin);
        switch (cfg.direction) {
            .left_to_right => {
                // alignment for cross axis
                const total_w = ctx.childrenSizeTotal(el.children.items, cfg.child_gap, .x);

                const leftover = (el.size.x - pad.h()) - total_w;
                var x_cursor = inner_origin.x + switch (cfg.child_alignment.x) {
                    .left => 0,
                    .center => leftover / 2,
                    .right => leftover,
                };

                for (el.children.items) |ci| {
                    const child = ctx.get(ci);
                    const free_y = (el.size.y - pad.v()) - child.size.y;

                    const child_y = inner_origin.y + switch (cfg.child_alignment.y) {
                        .top => 0,
                        .center => free_y / 2,
                        .bottom => free_y,
                    };

                    ctx.positionPass(ci, .init(x_cursor, child_y));

                    x_cursor += child.size.x + cfg.child_gap;
                }
            },
            .top_to_bottom => {
                const total_h = ctx.childrenSizeTotal(el.children.items, cfg.child_gap, .y);
                const leftover = (el.size.y - pad.v()) - total_h;
                var y_cursor = inner_origin.y + switch (cfg.child_alignment.y) {
                    .top => 0,
                    .center => leftover / 2,
                    .bottom => leftover,
                };

                for (el.children.items) |ci| {
                    const child = ctx.get(ci);

                    const free_x = (el.size.x - pad.h()) - child.size.x;
                    const child_x = inner_origin.x + switch (cfg.child_alignment.x) {
                        .left => 0,
                        .center => free_x / 2,
                        .right => free_x,
                    };

                    ctx.positionPass(ci, .init(child_x, y_cursor));

                    y_cursor += child.size.y + cfg.child_gap;
                }
            },
        }
    }
};

// --------------------------- Tests ---------------------------

test "horizontal fixed children basic sizing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(400, 100),
        .padding = .xy(5, 10),
        .child_gap = 10,
    });

    try ctx.openElement(.{ .sizing = .fixedXY(50, 20) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(60, 30) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(70, 40) });
    ctx.closeElement();
    ctx.endRoot();
    ctx.computeLayout(.init(400, 100));
    const r = ctx.get(Context.root_id);
    try std.testing.expectApproxEqAbs(400, r.size.x, 0.001);
    try std.testing.expectApproxEqAbs(100, r.size.y, 0.001);
    // child positions
    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    const c2 = ctx.get(3);
    try std.testing.expectApproxEqAbs(5, c0.bbox.x, 0.001);
    try std.testing.expectApproxEqAbs(5 + 50 + 10, c1.bbox.x, 0.001);
    try std.testing.expectApproxEqAbs(5 + 50 + 10 + 60 + 10, c2.bbox.x, 0.001);
}

test "grow distribution horizontal" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(300, 50),
    });

    try ctx.openElement(.{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeElement();
    ctx.endRoot();
    ctx.computeLayout(.init(300, 50));
    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    try std.testing.expectApproxEqAbs(150, c0.size.x, 0.01);
    try std.testing.expectApproxEqAbs(150, c1.size.x, 0.01);
}

test "percent sizing vertical" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(100, 200),
        .direction = .top_to_bottom,
    });

    try ctx.openElement(.{ .sizing = .init(.default, .percent(0.25)) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .init(.default, .percent(0.5)) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(50, 10) });
    ctx.closeElement();
    ctx.endRoot();
    ctx.computeLayout(.init(100, 200));
    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    const c2 = ctx.get(3);
    try std.testing.expectApproxEqAbs(50, c0.size.y, 0.001); // 0.25 * 200
    try std.testing.expectApproxEqAbs(100, c1.size.y, 0.001); // 0.5 * 200
    try std.testing.expectApproxEqAbs(10, c2.size.y, 0.001); // intrinsic
}

test "compression shrink largest first" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(100, 30),
    });

    try ctx.openElement(.{ .sizing = .fixedXY(80, 10) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(40, 10) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(60, 10) });
    ctx.closeElement();
    ctx.endRoot();
    ctx.computeLayout(.init(100, 30));
    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    const c2 = ctx.get(3);
    const sum = c0.size.x + c1.size.x + c2.size.x;
    try std.testing.expectApproxEqAbs(100, sum, 0.1);
    // Expect roughly equal sizes after compression
    try std.testing.expect(std.math.approxEqAbs(f32, c0.size.x, c1.size.x, 1.0));
    try std.testing.expect(std.math.approxEqAbs(f32, c1.size.x, c2.size.x, 1.0));
}

test "alignment center horizontal" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(300, 50),
        .child_alignment = .center,
    });

    try ctx.openElement(.{ .sizing = .fixedXY(40, 10) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(20, 20) });
    ctx.closeElement();
    ctx.endRoot();
    ctx.computeLayout(.init(300, 50));
    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    // Check they are vertically centered
    try std.testing.expectApproxEqAbs((50 - c0.size.y) / 2, c0.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs((50 - c1.size.y) / 2, c1.bbox.y, 0.01);
}
test "compression reducible epsilon branch" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // Root width forces compression of equal-sized children where (largest - second) == 0
    try ctx.beginRoot(.{
        .sizing = .fixedXY(80, 40),
        // left_to_right by default
    });

    try ctx.openElement(.{ .sizing = .fixedXY(30, 10) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(30, 12) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(30, 14) });
    ctx.closeElement();

    ctx.endRoot();
    ctx.computeLayout(.init(80, 40));

    const c0 = ctx.get(1);
    const c1 = ctx.get(2);
    const c2 = ctx.get(3);

    // After epsilon branch compression, total should match available width
    const total = c0.size.x + c1.size.x + c2.size.x;
    try std.testing.expectApproxEqAbs(80, total, 0.01);

    // All sizes should now be close to each other (even distribution)
    try std.testing.expect(std.math.approxEqAbs(f32, c0.size.x, c1.size.x, 0.01));
    try std.testing.expect(std.math.approxEqAbs(f32, c1.size.x, c2.size.x, 0.01));
}

test "alignment center vertical direction" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.beginRoot(.{
        .sizing = .fixedXY(100, 200),
        .direction = .top_to_bottom,
        .child_alignment = .center, // center on both axes
    });

    try ctx.openElement(.{ .sizing = .fixedXY(30, 40) });
    ctx.closeElement();
    try ctx.openElement(.{ .sizing = .fixedXY(50, 20) });
    ctx.closeElement();

    ctx.endRoot();
    ctx.computeLayout(.init(100, 200));

    const c0 = ctx.get(1);
    const c1 = ctx.get(2);

    // Vertical centering along layout axis:
    // total children height = 40 + 20 = 60, leftover = 200 - 60 = 140, start offset = 70
    try std.testing.expectApproxEqAbs(70, c0.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs(110, c1.bbox.y, 0.01); // 70 + first height (40)

    // Horizontal centering per child
    try std.testing.expectApproxEqAbs((100 - 30) / 2, c0.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs((100 - 50) / 2, c1.bbox.x, 0.01);
}
