const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

const Vec2 = root.Vec2;
const Rect = root.Rect;
const Range = root.Range;

/// Gravity represents unit alignment within a layout.
pub const Gravity = enum {
    /// Aligns the unit to the start of the axis. This is the left for x and top for y.
    start,
    /// Aligns the unit to the center of the axis.
    center,
    /// Aligns the unit to the end of the axis. This is the right for x and bottom for y.
    end,

    pub const default = Gravity.start;
};

/// Padding represents the space around an unit.
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

/// Sizing represents how to resolve the size of the unit within a layout.
pub const Sizing = struct {
    width: Dimension = .default,
    height: Dimension = .default,

    /// Dimension represents how to resolve the size of the unit in a particular axis.
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

/// ChildAlignment controls how child units are aligned on each axis.
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

/// Controls various settings that affect the size and position of an unit, as well as the sizes and positions
/// of any child units.
///
/// Can be passed directly to `Context` as the `UnitData`.
pub const Config = struct {
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_gap: f32 = 0,
    child_alignment: ChildAlignment = .{},
    axis: Vec2.Axis = .x,

    pub fn isEmpty(self: Config) bool {
        return self.sizing.eql(.default) and std.meta.eql(self.padding, Padding{}) and self.child_gap == 0 and std.meta.eql(self.child_alignment, ChildAlignment{}) and self.axis == .x;
    }

    pub fn layoutConfig(self: *Config) *Config {
        return self;
    }

    pub fn measure(self: *const Config, constraints: Constraints) Vec2 {
        return constraints.clamp(self.sizing.intrinsic());
    }
};

pub fn id(s: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, s));
}

pub const ContextConfig = struct {
    /// Target number of total units
    units: usize = 1024,

    /// Level of the deepest nested child
    ///
    /// Estimated based on heuristics if null.
    depth: ?usize = null,

    /// Default number of direct children an unit can have
    ///
    /// Estimated based on heuristics if null.
    breadth: ?usize = null,

    /// Maximum number of direct children an unit can have.
    max_breadth: usize = 256,

    pub fn getDepth(self: ContextConfig) usize {
        return self.depth orelse std.math.sqrt(self.units) * 2;
    }

    pub fn getBreadth(self: ContextConfig) usize {
        return self.breadth orelse std.math.sqrt(self.units);
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
/// render the unit as well as a method named `layoutConfig` that returns the
/// `LayoutConfig` for the unit.
///
/// All allocations are made on initialization based on a target number of total
/// units. Heuristics are used to estimate the amount of memory needed.
///
/// `begin` and `openUnit` have `breadth` variants that can be used to
/// specify the maximum number of children an unit can have. If these
/// functions are used for a large number of children, it's advisable to balance
/// it out with some smaller breadth units, either manually or by setting the
/// `breadth` field.
pub fn Context(comptime UnitData: type, comptime context_config: ContextConfig) type {
    std.debug.assert(@hasDecl(UnitData, "layoutConfig"));
    std.debug.assert(@TypeOf(UnitData.layoutConfig) == fn (self: *UnitData) *Config);
    std.debug.assert(@hasDecl(UnitData, "measure"));
    std.debug.assert(@TypeOf(UnitData.measure) == fn (self: *const UnitData, constraints: Constraints) Vec2);

    const default_breadth = context_config.getBreadth();
    const depth = context_config.getDepth();
    return struct {
        units: std.ArrayList(Unit),
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

        pub const Unit = struct {
            id: u32,
            parent: usize,
            data: UnitData,
            children: std.ArrayList(usize),

            // Computed
            size: Vec2 = .zero, // final width/height after distribution
            min_size: Vec2 = .zero, // aggregated intrinsic minimum content size
            bbox: Rect = .zero,

            fn config(self: *Unit) *Config {
                return self.data.layoutConfig();
            }

            fn measure(self: *const Unit, constraints: Constraints) *Config {
                return self.data.measure(constraints);
            }
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            var units: std.ArrayList(Unit) = .empty;
            errdefer units.deinit(allocator);
            try units.ensureTotalCapacityPrecise(allocator, context_config.units);

            var ids: IdMap = .empty;
            errdefer ids.deinit(allocator);
            try ids.ensureTotalCapacity(allocator, context_config.units);

            var stack: std.ArrayList(usize) = .empty;
            errdefer stack.deinit(allocator);
            try stack.ensureTotalCapacityPrecise(allocator, depth);

            const ci_buf = try allocator.alloc(usize, context_config.units * default_breadth);

            return .{
                .units = units,
                .ids = ids,
                .stack = stack,
                .ci_buf = ci_buf,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.units.deinit(allocator);
            self.stack.deinit(allocator);
            self.ids.deinit(allocator);
            allocator.free(self.ci_buf);
            self.* = undefined;
        }

        /// Assume available memory, check space before calling
        fn pushUnit(self: *Self, unit_id: u32, data: UnitData, breadth: usize) void {
            std.debug.assert(breadth <= context_config.max_breadth);

            if (unit_id != 0) {
                self.ids.putAssumeCapacityNoClobber(unit_id, self.units.items.len);
            }

            const parent = if (self.stack.items.len > 0) self.stack.getLast() else 0;
            self.stack.appendAssumeCapacity(self.units.items.len);

            const children = self.ci_buf[self.ci_buf_pos .. self.ci_buf_pos + breadth];
            self.ci_buf_pos += breadth;

            self.units.appendAssumeCapacity(.{
                .id = unit_id,
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
            self.units.items.len = 0;
            self.ids.clearRetainingCapacity();
            self.ci_buf_pos = 0;

            var data = if (@hasDecl(UnitData, "default")) UnitData.default else UnitData{};
            data.layoutConfig().* = cfg;
            self.pushUnit(0, data, breadth);
        }

        /// Opens a new unit with the given configuration. Must be finished
        ///  with a matching call to `closeUnit`.
        pub fn openUnit(
            self: *Self,
            /// Number that must be unique within the context. It can be used
            /// to uniquely lookup and identify the unit in various case.
            /// It's advisable to use a string hash. Use zero for no id.
            unit_id: u32,
            data: UnitData,
        ) usize {
            return self.openUnitBreadth(unit_id, data, default_breadth);
        }

        /// Opens a new unit with the given configuration and breadth. Must be
        /// finished with a matching call to `closeUnit`.
        pub fn openUnitBreadth(
            self: *Self,
            /// Number that must be unique within the context. It can be used
            /// to uniquely lookup and identify the unit in various case.
            /// It's advisable to use a string hash. Use zero for no id.
            unit_id: u32,
            data: UnitData,
            breadth: usize,
        ) usize {
            std.debug.assert(self.stack.items.len > 0);

            if (self.units.items.len >= self.units.capacity) {
                // unit limit reached, try increasing `context_config.max_units`
                unreachable;
            }

            if (self.stack.items.len >= self.stack.capacity) {
                // child depth limit reached, try increasing `context_config.depth`
                unreachable;
            }

            if (breadth > self.ci_buf.len - self.ci_buf_pos) {
                // children buffer limit, try using `openUnitBreadth` with smaller
                // breadth values where possible
                unreachable;
            }

            const siblings = &self.get(self.stack.getLast()).children;
            if (siblings.items.len >= siblings.capacity) {
                // child breadth limit reached, try using `openUnitBreadth` with a
                // larger breadth value or increasing `context_config.max_breadth`
                unreachable;
            }

            const index = self.units.items.len;
            self.pushUnit(unit_id, data, breadth);
            siblings.appendAssumeCapacity(index);

            return index;
        }

        /// Asserts the current unit and closes it. Must be called after a matching `openUnit`.
        pub fn closeUnit(self: *Self, expected_index: usize) void {
            std.debug.assert(expected_index == self.stack.pop());
        }

        /// Ends a layout. Must be called after `begin`.
        pub fn end(self: *Self) void {
            std.debug.assert(self.stack.items.len == 1);
            _ = self.stack.pop();
        }

        pub fn get(self: *const Self, i: usize) *Unit {
            return &self.units.items[i];
        }

        pub fn computeLayout(self: *const Self, width: f32, height: f32) void {
            self.computeLayoutVec(.init(width, height));
        }

        pub fn computeLayoutVec(self: *const Self, available: Vec2) void {
            std.debug.assert(self.stack.items.len == 0);
            std.debug.assert(self.units.items.len > 0);

            // Stage 0: Root sizing bootstrap (Clay sets root explicitly if unset)
            const root_el = self.get(Self.root_id);
            if (root_el.config().sizing.eql(Sizing.default)) {
                root_el.config().sizing = .fixedXY(available.x, available.y);
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
            // Phase 1: measure leaf content with horizontal width constraint (for wrapping)
            // A leaf's already–resolved width (after horizontal distribution & percent pass) is
            // treated as the available inner width for wrapping. Height may grow as a result.
            for (self.units.items) |*el| {
                if (el.children.items.len != 0) continue;

                const cfg = el.config();

                // Inner width available for content after padding
                const inner_w = el.size.x - cfg.padding.sumAxis(.x);

                // Build constraints: only constrain width if > 0 (wrapping). We leave height unconstrained here.
                var constraints = Constraints.empty;
                if (inner_w > 0) {
                    constraints.max_width = inner_w;
                }

                const measured = el.data.measure(constraints);

                // Required total height including padding
                const needed_total_h = measured.y + cfg.padding.sumAxis(.y);

                // Increase unit height if content needs more (only for fit/grow vertical sizing)
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
            var i: usize = self.units.items.len;
            while (i > 0) {
                i -= 1;
                const el = &self.units.items[i];
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

        inline fn unitChildrenAnySizeTotal(self: *const Self, unit: *Unit, size_field: []const u8, axis: Vec2.Axis) f32 {
            return self.childrenAnySizeTotal(unit.children.items, unit.config().child_gap, size_field, axis);
        }

        inline fn unitChildrenAnySizeMax(self: *const Self, unit: *Unit, size_field: []const u8, axis: Vec2.Axis) f32 {
            return self.childrenAnySizeMax(unit.children.items, size_field, axis);
        }

        inline fn unitChildrenSizeTotal(self: *const Self, unit: *Unit, axis: Vec2.Axis) f32 {
            return self.unitChildrenAnySizeTotal(unit, "size", axis);
        }

        inline fn unitChildrenSizeMax(self: *const Self, unit: *Unit, axis: Vec2.Axis) f32 {
            return self.unitChildrenAnySizeMax(unit, "size", axis);
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
                        self.unitChildrenAnySizeTotal(el, field, axis),
                        self.unitChildrenAnySizeMax(el, field, axis.cross()),
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

            // Resolve this unit's size along the given axis if percent or fixed
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

            // Compute child available axis (content box of this unit)
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

        fn distributeAxis(self: *const Self, parent: *Unit, inner: f32, comptime axis: Vec2.Axis) void {
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
                    const total_size = self.unitChildrenSizeTotal(el, axis);
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

    const wrapper = ctx.openUnit(0, .{ .padding = .xy(5, 10), .child_gap = 10 });
    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(50, 20) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(60, 30) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .fixedXY(70, 40) });
    ctx.closeUnit(c);
    ctx.closeUnit(wrapper);

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

    const a = ctx.openUnit(0, .{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.grow(.{}), .default) });
    ctx.closeUnit(b);

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

    const a = ctx.openUnit(0, .{ .sizing = .init(.default, .percent(0.25)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.default, .percent(0.5)) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .fixedXY(50, 10) });
    ctx.closeUnit(c);

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

    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(80, 10) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .fixedXY(60, 10) });
    ctx.closeUnit(c);

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

    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(20, 20) });
    ctx.closeUnit(b);

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

    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(30, 10) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(30, 12) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .fixedXY(30, 14) });
    ctx.closeUnit(c);

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

    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(30, 40) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(50, 20) });
    ctx.closeUnit(b);

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

    const a = ctx.openUnit(0, .{ .sizing = .init(.percent(0.5), .fixed(10)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.percent(0.5), .fixed(10)) });
    ctx.closeUnit(b);

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

    const a = ctx.openUnit(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(10)) });
    ctx.closeUnit(b);

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
    const p = ctx.openUnit(0, .{ .sizing = .init(.percent(0.25), .fixed(10)) });
    ctx.closeUnit(p);
    const f = ctx.openUnit(0, .{ .sizing = .fixedXY(100, 10) });
    ctx.closeUnit(f);
    const g = ctx.openUnit(0, .{ .sizing = .init(.grow(.{ .min = 50, .max = 10000 }), .fixed(10)) });
    ctx.closeUnit(g);

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
    const p = ctx.openUnit(0, .{ .sizing = .init(.fixed(40), .percent(0.25)) });
    ctx.closeUnit(p);
    // f: fixed height 60
    const f = ctx.openUnit(0, .{ .sizing = .fixedXY(60, 60) });
    ctx.closeUnit(f);
    // g: grow min 40
    const g = ctx.openUnit(0, .{ .sizing = .init(.fixed(30), .grow(.{ .min = 40, .max = 1000 })) });
    ctx.closeUnit(g);

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
    const a = ctx.openUnit(0, .{ .sizing = .init(.fit(.{ .min = 50, .max = 500 }), .fixed(10)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.percent(0.25), .fixed(10)) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .fixedXY(80, 10) });
    ctx.closeUnit(c);

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

    const a = ctx.openUnit(0, .{ .sizing = .init(.fixed(40), .percent(0.5)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(60, 40) });
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .{ .sizing = .init(.fixed(20), .percent(0.25)) });
    ctx.closeUnit(c);

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
    const cont = ctx.openUnit(0, .{ .sizing = .init(.fit(.{ .min = 10, .max = 500 }), .fixed(30)), .child_gap = 10 });
    const ca = ctx.openUnit(0, .{ .sizing = .fixedXY(40, 10) });
    ctx.closeUnit(ca);
    const cb = ctx.openUnit(0, .{ .sizing = .fixedXY(50, 15) });
    ctx.closeUnit(cb);
    const cc = ctx.openUnit(0, .{ .sizing = .fixedXY(30, 12) });
    ctx.closeUnit(cc);
    ctx.closeUnit(cont);

    // Sibling to force overflow scenario
    const sib = ctx.openUnit(0, .{ .sizing = .fixedXY(10, 10) });
    ctx.closeUnit(sib);

    ctx.end();
    ctx.computeLayout(120, 100);

    const c_cont = ctx.get(cont);
    // Intrinsic min content width = 40 + 50 + 30 + gaps(2*10) = 140
    try std.testing.expect(c_cont.size.x >= 140);
}

test "overflow horizontal positioning no compression" {
    var ctx = try TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    ctx.beginConfig(.{ .sizing = .fixedXY(200, 80) });

    const cont = ctx.openUnit(0, .{ .sizing = .fixedXY(200, 50) });
    const a = ctx.openUnit(0, .{ .sizing = .fixedXY(150, 40) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .fixedXY(150, 40) });
    ctx.closeUnit(b);
    ctx.closeUnit(cont);

    ctx.end();
    ctx.computeLayout(200, 80);

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
    ctx.beginConfig(.{ .axis = .y, .child_alignment = .center, .child_gap = 20 });

    const wide = ctx.openUnit(0, .{ .sizing = .fixedXY(300, 60) });
    ctx.closeUnit(wide);
    const narrow = ctx.openUnit(0, .{ .sizing = .fixedXY(100, 40) });
    ctx.closeUnit(narrow);

    ctx.end();
    ctx.computeLayout(400, 500);

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
    ctx.begin();

    const a = ctx.openUnit(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(20)) });
    ctx.closeUnit(a);
    const b = ctx.openUnit(0, .{ .sizing = .init(.grow(.{ .min = 60, .max = 200 }), .fixed(30)) });
    ctx.closeUnit(b);

    ctx.end();
    ctx.computeLayout(115, 80);

    const ea = ctx.get(a);
    const eb = ctx.get(b);

    // Both remain at their floor (min) sizes; compression loop should early‑deactivate them
    // covering the branch where potential <= 0.0001.
    try std.testing.expectApproxEqAbs(60, ea.size.x, 0.001);
    try std.testing.expectApproxEqAbs(60, eb.size.x, 0.001);
}

const WrapContext = Context(struct {
    const Self = @This();
    cfg: Config = .{},
    intrinsic_width: f32 = 0,
    line_height: f32 = 0,

    fn init(intrinsic_width: f32, line_height: f32, cfg: Config) @This() {
        return .{
            .intrinsic_width = intrinsic_width,
            .line_height = line_height,
            .cfg = cfg,
        };
    }

    pub fn layoutConfig(self: *Self) *Config {
        return &self.cfg;
    }

    pub fn measure(self: *const Self, constraints: Constraints) Vec2 {
        const iw = self.intrinsic_width;
        if (constraints.max_width) |mw| {
            if (mw >= iw) return .init(iw, self.line_height);
            const lines = @ceil(iw / mw);
            return .init(mw, self.line_height * lines);
        }
        return .init(iw, self.line_height);
    }
}, .{});

test "content adjustment wrapping increases height" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root with fixed outer size (width constrains wrapping)
    ctx.beginConfig(.{ .padding = .xy(0, 0) });

    const a = ctx.openUnit(0, .init(250, 20, .{
        .sizing = .init(.fixed(100), .default),
    }));
    ctx.closeUnit(a);

    ctx.end();
    ctx.computeLayout(300, 400);

    // Child should have wrapped into ceil(250 / 100) = 3 lines => height = 3 * 20 = 60
    const child_index = ctx.get(WrapContext.root_id).children.items[0];
    const child = ctx.get(child_index);
    try std.testing.expectApproxEqAbs(100, child.size.x, 0.01);
    try std.testing.expectApproxEqAbs(60, child.size.y, 0.01);
}

test "content adjustment propagates parent height growth" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root vertical container (so parent height should sum children heights)
    ctx.beginConfig(.{ .axis = .y, .padding = .xy(0, 0), .child_gap = 10 });

    const a = ctx.openUnit(0, .init(0, 0, .{
        .sizing = .init(.fixed(200), .default),
        .axis = .y,
    }));
    const b = ctx.openUnit(0, .init(300, 18, .{
        .sizing = .init(.fixed(120), .default), // wraps -> ceil(300/120)=3 lines => 54
    }));
    ctx.closeUnit(b);
    const c = ctx.openUnit(0, .init(260, 18, .{
        .sizing = .init(.fixed(120), .default), // wraps -> ceil(260/120)=3 lines => 54
    }));
    ctx.closeUnit(c);
    ctx.closeUnit(a);

    ctx.end();
    ctx.computeLayout(220, 500);

    const parent = ctx.get(a);
    // parent height = sum(child heights)+ gap (10)
    // Each child height 54 => total 54 + 54 + 10 = 118
    // Parent container had no child_gap configured (gap belongs only to root), so expected = 54 + 54 = 108
    try std.testing.expectApproxEqAbs(108, parent.size.y, 0.1);
}

test "percent width influences wrapping height" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    ctx.beginConfig(.{ .sizing = .fixedXY(240, 400) });

    const a = ctx.openUnit(0, .init(250, 16, .{
        .sizing = .init(.percent(0.5), .default),
    }));
    ctx.closeUnit(a);

    ctx.end();
    ctx.computeLayout(240, 400);

    const c_a = ctx.get(a);

    try std.testing.expectApproxEqAbs(120, c_a.size.x, 0.01);
    // wrapped lines = ceil(250/120)=3 -> height 3 * 16 = 48
    try std.testing.expectApproxEqAbs(48, c_a.size.y, 0.2);
}

test "vertical percent container with wrapping child does not expand percent height" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root fixed size with vertical axis
    ctx.beginConfig(.{ .sizing = .fixedXY(300, 400), .axis = .y });

    // Open percent-height container (50% of 400 => 200)
    const pc_index = ctx.openUnit(0, .init(0, 0, .{
        .sizing = .init(.fixed(300), .percent(0.5)),
        .axis = .y,
    }));

    // Wrapped child: intrinsic width larger than fixed width forces wrapping
    const child_index = ctx.openUnit(0, .init(500, 20, .{
        .sizing = .init(.fixed(150), .default),
    }));
    ctx.closeUnit(child_index);
    ctx.closeUnit(pc_index);

    ctx.end();
    ctx.computeLayout(300, 400);

    const pc = ctx.get(pc_index);
    const wrapped_child = ctx.get(child_index);

    // Percent container height should remain exactly 50% of root height (200) despite child wrapping
    try std.testing.expectApproxEqAbs(200, pc.size.y, 0.1);
    try std.testing.expectApproxEqAbs(300, pc.size.x, 0.1);

    // Wrapped child height: ceil(500 / 150)=4 lines * 20 = 80
    try std.testing.expectApproxEqAbs(80, wrapped_child.size.y, 0.2);
    try std.testing.expectApproxEqAbs(150, wrapped_child.size.x, 0.1);

    // Child fully inside percent container
    try std.testing.expect(wrapped_child.bbox.y >= pc.bbox.y);
    try std.testing.expect(wrapped_child.bbox.y + wrapped_child.size.y <= pc.bbox.y + pc.size.y + 0.01);
}

test "mixed percent grow wrapping horizontal distribution" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root with explicit width/height and gaps to test leftover distribution
    ctx.beginConfig(.{ .sizing = .fixedXY(600, 400), .child_gap = 20 });

    // 1. Percent width unit: 25% of 600 => 150, intrinsic wider -> wraps
    const p_idx = ctx.openUnit(0, .init(400, 16, .{
        .sizing = .init(.percent(0.25), .default),
    }));
    ctx.closeUnit(p_idx);

    // 2. Fixed width unit: 120, intrinsic 500 -> more wrapping
    const f_idx = ctx.openUnit(0, .init(500, 16, .{ .sizing = .init(.fixed(120), .default) }));
    ctx.closeUnit(f_idx);

    // 3. Grow unit: absorbs leftover after percent + fixed + gaps
    const g_idx = ctx.openUnit(0, .init(0, 16, .{
        .sizing = .init(.grow(.{ .min = 100, .max = 1000 }), .default),
    }));
    ctx.closeUnit(g_idx);

    ctx.end();
    ctx.computeLayout(600, 400);

    const p = ctx.get(p_idx);
    const f = ctx.get(f_idx);
    const g = ctx.get(g_idx);

    // Expected widths (percent uses inner space minus total gaps):
    // Parent inner main = 600 - gaps(2*20) = 560
    // Percent (25%) of inner = 140
    // Fixed: 120
    // Used + gaps = 140 + 120 + 40 = 300
    // Remaining for grow = 600 - 300 = 300
    try std.testing.expectApproxEqAbs(140, p.size.x, 0.1);
    try std.testing.expectApproxEqAbs(120, f.size.x, 0.1);
    try std.testing.expectApproxEqAbs(300, g.size.x, 0.1);

    // Wrapping heights:
    // Percent unit: ceil(400/150)=3 lines -> 48
    try std.testing.expectApproxEqAbs(48, p.size.y, 0.6); // allow tolerance for rounding
    // Fixed unit: ceil(500/120)=5 lines -> 80
    try std.testing.expectApproxEqAbs(80, f.size.y, 0.6);
    // Grow unit has no text; measurement returns one line height (16)
    try std.testing.expectApproxEqAbs(16, g.size.y, 0.6);

    // Position checks along x
    try std.testing.expectApproxEqAbs(0, p.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs(p.bbox.x + p.size.x + 20, f.bbox.x, 0.01);
    try std.testing.expectApproxEqAbs(f.bbox.x + f.size.x + 20, g.bbox.x, 0.01);
}
test "cross-axis vertical centering with wrapping disparity (horizontal layout)" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root: horizontal axis, center alignment on cross (Y) axis
    ctx.beginConfig(.{ .child_gap = 30, .child_alignment = .center });

    // Tall wrapped child: width 120, intrinsic 360 -> 3 lines (54 height if line_height=18)
    const tall = ctx.openUnit(0, .init(360, 18, .{
        .sizing = .init(.fixed(120), .default),
    }));
    ctx.closeUnit(tall);

    // Short child: width 180 intrinsic 90 -> 1 line (18 height)
    const short = ctx.openUnit(0, .init(90, 18, .{
        .sizing = .init(.fixed(180), .default),
    }));
    ctx.closeUnit(short);

    ctx.end();
    ctx.computeLayout(500, 300);

    const tall_el = ctx.get(tall);
    const short_el = ctx.get(short);

    const expected_tall_y = (300 - 54) / 2;
    const expected_short_y = (300 - 18) / 2;

    try std.testing.expectApproxEqAbs(54, tall_el.size.y, 0.5);
    try std.testing.expectApproxEqAbs(18, short_el.size.y, 0.01);
    try std.testing.expectApproxEqAbs(expected_tall_y, tall_el.bbox.y, 0.5);
    try std.testing.expectApproxEqAbs(expected_short_y, short_el.bbox.y, 0.5);
}

test "vertical mixed percent grow wrapping distribution" {
    const gpa = std.testing.allocator;

    var ctx = try WrapContext.init(gpa);
    defer ctx.deinit(gpa);

    // Root vertical axis: height 500, width 400
    ctx.beginConfig(.{ .axis = .y, .child_gap = 10 });

    // 1. Percent height unit: 30% of inner vertical space (inner = 500 - gaps(2*10)=480) => 144
    const p_idx = ctx.openUnit(0, .init(350, 18, .{
        .sizing = .init(.fixed(200), .percent(0.3)),
    }));
    ctx.closeUnit(p_idx);

    // 2. Fixed height unit: fixed height 120, width fixed 160 (wrapping width)
    const f_idx = ctx.openUnit(0, .init(500, 18, .{
        .sizing = .fixedXY(160, 120),
    }));
    ctx.closeUnit(f_idx);

    // 3. Grow unit: consumes leftover vertical space, width fixed 100
    const g_idx = ctx.openUnit(0, .init(0, 18, .{
        .sizing = .init(.fixed(100), .grow(.{ .min = 50, .max = 1000 })),
    }));
    ctx.closeUnit(g_idx);

    ctx.end();
    ctx.computeLayout(400, 500);

    const p = ctx.get(p_idx);
    const f = ctx.get(f_idx);
    const g = ctx.get(g_idx);

    // Heights:
    // Percent unit: 144 (30% of 480 inner height)
    try std.testing.expectApproxEqAbs(144, p.size.y, 0.6);
    // Fixed unit: 120
    try std.testing.expectApproxEqAbs(120, f.size.y, 0.1);
    // Remaining for grow: total = 500 - (144 + 120 + gaps 20) = 216
    try std.testing.expectApproxEqAbs(216, g.size.y, 0.6);

    // Widths unchanged
    try std.testing.expectApproxEqAbs(200, p.size.x, 0.1);
    try std.testing.expectApproxEqAbs(160, f.size.x, 0.1);
    try std.testing.expectApproxEqAbs(100, g.size.x, 0.1);

    // Vertical positioning (y coordinates)
    try std.testing.expectApproxEqAbs(0, p.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs(p.bbox.y + p.size.y + 10, f.bbox.y, 0.01);
    try std.testing.expectApproxEqAbs(f.bbox.y + f.size.y + 10, g.bbox.y, 0.01);
}
