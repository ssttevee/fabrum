const std = @import("std");
const builtin = @import("builtin");

const root = @import("root.zig");
const Vec2 = root.Vec2;
const Rect = root.Rect;
const Range = root.Range;
const Color = root.Color;
const BorderWidths = root.BorderWidths;
const Sizing = root.Sizing;
const CornerRadius = root.CornerRadius;
const Padding = root.Padding;
const Alignment = root.Alignment;
const RenderCommand = root.RenderCommand;
const Element = root.Element;

const layout = @This();

pub const ContainerDeclaration = struct {
    id: []const u8 = "",

    /// Controls various settings that affect the size and position of an unit, as well as the sizes and positions of any child units.
    layout: Config = .{},

    /// Controls the background color of the resulting unit.
    /// By convention specified as 0-255, but interpretation is up to the renderer.
    /// If no other config is specified, .backgroundColor will generate a RECTANGLE render command, otherwise it will be passed as a property to IMAGE or CUSTOM render commands.
    background_color: Color = .transparent,

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

    overflow: OverflowConfig = .{},

    /// A pointer that will be transparently passed through to resulting render commands.
    user_data: ?*anyopaque = null,

    pub const AspectRatioConfig = struct {
        /// A float representing the target "Aspect ratio" for an unit, which is its final width divided by its final height.
        aspect_ratio: f32 = 0,
    };

    pub const FloatingConfig = struct {
        mode: AttachMode = .default,
        parent: union { id: u32, index: usize } = .{ .id = 0 },
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
        child_offset: Vec2 = .zero,
    };

    pub const BorderConfig = struct {
        color: Color = .black,
        widths: BorderWidths = .{},
    };

    /// Controls how overflow is handled.
    pub const OverflowConfig = struct {
        x: Mode = .visible,
        y: Mode = .visible,

        const Mode = union(enum) {
            /// No special overflow handling.
            visible,
            /// Overflow is clipped.
            hidden,
            /// Overflow is clipped with an offset that shifts the clipped range.
            scroll: f32,
        };

        pub fn any(self: OverflowConfig) bool {
            return self.x != null or self.y != null;
        }
    };
};

pub const Content = struct {
    vtable: *const VTable,

    pub const MeasureError = error{MeasureFailed};

    pub const VTable = struct {
        /// Returns the shape of the content based on optional .
        measure: *const fn (self: *Content, constraints: Constraints) MeasureError!Vec2,
        deinit: ?*const fn (self: *Content) void = null,

        debug_name: []const u8 = "Content",
    };

    pub fn measure(self: *Content, constraints: Constraints) !Vec2 {
        return try self.vtable.measure(self, constraints);
    }

    pub fn deinit(self: *Content) void {
        if (self.vtable.deinit) |fn_ptr| fn_ptr(self);
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
    child_alignment: Alignment = .{},
    axis: Vec2.Axis = .x,
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

pub const Unit = struct {
    id: u32,
    parent: usize,
    data: Data,
    children: std.ArrayList(usize),

    // Computed
    size: Vec2 = .zero, // final width/height after distribution
    min_size: Vec2 = .zero, // aggregated intrinsic minimum content size
    bbox: Rect = .zero,

    pub const Id = struct {
        id: u32 = 0,

        pub const none: Id = .{};
        pub const zero: Id = .{};

        pub fn fromInt(id: u32) Id {
            return .{ .id = id };
        }

        /// Generates a unit id from a string
        pub fn fromString(s: []const u8) Id {
            return .{ .id = hash(s) };
        }

        /// Generates a unit id from a string. Guarantees comptime hash.
        pub fn fromStringComptime(comptime s: []const u8) Id {
            return comptime .{ .id = hash(s) };
        }

        fn hash(s: []const u8) u32 {
            return @truncate(std.hash.Wyhash.hash(0, s));
        }
    };

    pub const Data = union(enum) {
        container: ContainerDeclaration,
        content: *Content,
    };

    fn config(self: Unit) Config {
        return switch (self.data) {
            .container => |container| container.layout,
            // content doesn't have layout config, default config will form to intrinsic size from `measure`
            .content => .{},
        };
    }

    fn measure(self: *const Unit, constraints: Constraints) !Vec2 {
        return switch (self.data) {
            .container => |container| constraints.clamp(container.layout.sizing.intrinsic()),
            // content doesn't have layout config, default config will form to intrinsic size from `measure`
            .content => |content| try content.measure(constraints),
        };
    }

    pub fn hasId(self: *const Unit, unit_id: Id) bool {
        return self.id == unit_id.id;
    }

    pub fn hasIntId(self: *const Unit, id: u32) bool {
        return self.id == id;
    }

    pub fn hasStringId(self: *const Unit, str_id: []const u8) bool {
        return self.id == Id.hash(str_id);
    }

    pub fn hasStringIdComptime(self: *const Unit, comptime str_id: []const u8) bool {
        return self.id == comptime Id.hash(str_id);
    }

    pub fn hovered(self: *const Unit, point: Vec2) bool {
        return self.bbox.contains(point);
    }
};

pub const HoveredUnitsIterator = struct {
    point: Vec2,
    /// unfiltered list of units from the layout context
    units: []const Unit,
    pos: usize = 0,

    pub fn next(self: HoveredUnitsIterator) ?*const Unit {
        while (self.pos < self.units.len) : (self.pos += 1) {
            // read backwards to return descendents first
            if (self.units[self.units.len - self.pos - 1].bbox.contains(self.point)) {
                return &self.units[self.units.len - self.pos - 1];
            }
        }

        return null;
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

inline fn normalizeIntrinsicValue(value: f32) f32 {
    return if (std.math.isFinite(value)) value else 0;
}

inline fn finiteConstraint(value: f32) ?f32 {
    return if (std.math.isFinite(value) and value >= 0) value else null;
}

fn alignmentOffset(gravity: root.Gravity, leftover: f32) f32 {
    if (!std.math.isFinite(leftover) or leftover <= 0) {
        return 0;
    }

    return switch (gravity) {
        .start => 0,
        .center => leftover / 2,
        .end => leftover,
    };
}

/// Context for layout operations.
///
/// All allocations are made on initialization based on a target number of total
/// units. Heuristics are used to estimate the amount of memory needed.
///
/// `begin` and `openContainer` have `breadth` variants that can be used to
/// specify the maximum number of children an unit can have. If these
/// functions are used for a large number of children, it's advisable to balance
/// it out with some smaller breadth units, either manually or by setting the
/// `breadth` field.
pub const Context = struct {
    units: std.ArrayList(Unit),
    ids: IdMap,
    stack: std.ArrayList(usize),
    ci_buf: []usize,
    ci_buf_pos: usize = 0,
    breadth: usize,
    /// scratch buffer for `distributeAxis`
    dist_size_scratch_buf: []f32,
    dist_active_scratch_buf: []bool,
    rci_scratch_buf: []RenderCommand.Iterator.UnitTraversalState,

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

    pub const Config = struct {
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

        pub fn getDepth(self: Context.Config) usize {
            return self.depth orelse std.math.sqrt(self.units) * 2;
        }

        pub fn getBreadth(self: Context.Config) usize {
            return self.breadth orelse std.math.sqrt(self.units);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Context.Config) !Self {
        const breadth = config.getBreadth();

        var units: std.ArrayList(Unit) = .empty;
        errdefer units.deinit(allocator);
        try units.ensureTotalCapacityPrecise(allocator, config.units);

        var ids: IdMap = .empty;
        errdefer ids.deinit(allocator);
        try ids.ensureTotalCapacity(allocator, config.units);

        var stack: std.ArrayList(usize) = .empty;
        errdefer stack.deinit(allocator);
        try stack.ensureTotalCapacityPrecise(allocator, config.getDepth());

        const ci_buf = try allocator.alloc(usize, config.units * breadth);
        errdefer allocator.free(ci_buf);

        const dist_size_scratch_buf = try allocator.alloc(f32, config.max_breadth * 2);
        errdefer allocator.free(dist_size_scratch_buf);

        const dist_active_scratch_buf = try allocator.alloc(bool, config.max_breadth);
        errdefer allocator.free(dist_active_scratch_buf);

        const rci_scratch_buf = try allocator.alloc(RenderCommand.Iterator.UnitTraversalState, config.getDepth());
        errdefer allocator.free(rci_scratch_buf);

        return .{
            .units = units,
            .ids = ids,
            .stack = stack,
            .ci_buf = ci_buf,
            .breadth = breadth,
            .dist_size_scratch_buf = dist_size_scratch_buf,
            .dist_active_scratch_buf = dist_active_scratch_buf,
            .rci_scratch_buf = rci_scratch_buf,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.units.deinit(allocator);
        self.stack.deinit(allocator);
        self.ids.deinit(allocator);
        allocator.free(self.ci_buf);
        allocator.free(self.dist_size_scratch_buf);
        allocator.free(self.dist_active_scratch_buf);
        allocator.free(self.rci_scratch_buf);
        self.* = undefined;
    }

    fn depth(self: *const Self) usize {
        return self.units.capacity;
    }

    fn maxBreadth(self: *const Self) usize {
        return self.dist_active_scratch_buf.len;
    }

    pub fn hoveredUnits(self: *Self, point: Vec2) HoveredUnitsIterator {
        std.debug.assert(self.units.items.len > 0);
        std.debug.assert(!self.units.items[0].size.isZero());

        return .{
            .units = self.units.items,
            .point = point,
        };
    }

    /// Assume available memory, check space before calling
    fn pushUnit(self: *Self, unit_id: u32, data: Unit.Data, breadth: usize) void {
        std.debug.assert(breadth <= self.maxBreadth());

        if (unit_id != 0) {
            self.ids.putAssumeCapacityNoClobber(unit_id, self.units.items.len);
        }

        const children = self.ci_buf[self.ci_buf_pos .. self.ci_buf_pos + breadth];
        self.ci_buf_pos += breadth;

        const parent = if (self.stack.items.len > 0) self.stack.getLast() else 0;
        self.units.appendAssumeCapacity(.{
            .id = unit_id,
            .parent = parent,
            .data = data,
            .children = .initBuffer(children),
        });
    }

    /// Convenience function for laying out a slice of elements
    pub fn appendElements(self: *Self, elements: []const *Element) void {
        for (elements) |elem| {
            elem.layout(self);
        }
    }

    /// Convenience function for processing the entire layout from end to end given the elements
    pub fn layoutElements(self: *Self, root_config: layout.Config, elements: []const *Element) !RenderCommand.Iterator {
        {
            self.begin(root_config);
            defer self.end();

            self.appendElements(elements);
        }

        try self.computeLayout();

        return self.renderCommands();
    }

    /// Starts a new layout. Must be finished with a call to `end`.
    ///
    /// After calling, previously built layout is destroyed. Create another
    /// context if you need keep it.
    pub fn begin(self: *Self, cfg: layout.Config) void {
        std.debug.assert(cfg.sizing.width.mode == .fixed);
        std.debug.assert(cfg.sizing.height.mode == .fixed);

        self.beginBreadth(cfg, self.breadth);
    }

    /// Starts a new layout with a specific breadth. Must be finished with a
    /// call to `end`.
    ///
    /// After calling, previously built layout is destroyed. Create another
    /// context if you need keep it.
    pub fn beginBreadth(self: *Self, cfg: layout.Config, breadth: usize) void {
        std.debug.assert(self.stack.items.len == 0);

        self.units.items.len = 0;
        self.ids.clearRetainingCapacity();
        self.ci_buf_pos = 0;

        self.pushUnit(0, .{ .container = .{ .layout = cfg } }, breadth);
        self.stack.appendAssumeCapacity(0);
    }

    /// Opens a new unit with the given configuration. Must be finished
    ///  with a matching call to `closeContainer`.
    pub fn openContainer(
        self: *Self,
        decl: ContainerDeclaration,
    ) usize {
        return self.openContainerId(.{}, decl);
    }

    /// Opens a new unit with the given configuration. Must be finished
    ///  with a matching call to `closeContainer`.
    pub fn openContainerId(
        self: *Self,
        unit_id: Unit.Id,
        decl: ContainerDeclaration,
    ) usize {
        return self.openContainerIdBreadth(unit_id, decl, self.breadth);
    }

    /// Opens a new unit with the given configuration and breadth. Must be
    /// finished with a matching call to `closeContainer`.
    pub fn openContainerBreadth(
        self: *Self,
        decl: ContainerDeclaration,
        breadth: usize,
    ) usize {
        return self.openContainerIdBreadth(.{}, decl, breadth);
    }

    /// Opens a new unit with the given configuration and breadth. Must be
    /// finished with a matching call to `closeContainer`.
    pub fn openContainerIdBreadth(
        self: *Self,
        unit_id: Unit.Id,
        decl: ContainerDeclaration,
        breadth: usize,
    ) usize {
        std.debug.assert(self.stack.items.len > 0);

        if (self.units.items.len >= self.depth()) {
            // unit limit reached, try increasing `context_config.max_units`
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

        const index = self.units.items.len;
        self.pushUnit(unit_id.id, .{ .container = decl }, breadth);
        self.stack.appendAssumeCapacity(index);
        siblings.appendAssumeCapacity(index);
        return index;
    }

    /// Asserts the current unit and closes it. Must be called after a matching `openContainer`.
    pub fn closeContainer(self: *Self, expected_index: usize) void {
        std.debug.assert(expected_index == self.stack.pop());
    }

    pub fn appendContent(self: *Self, content: *Content) void {
        self.appendContentId(.{}, content);
    }

    pub fn appendContentId(self: *Self, unit_id: Unit.Id, content: *Content) void {
        std.debug.assert(self.stack.items.len > 0);

        const index = self.units.items.len;
        self.pushUnit(unit_id.id, .{ .content = content }, 0);
        self.get(self.stack.getLast()).children.appendAssumeCapacity(index);
    }

    pub fn appendContentIntId(self: *Self, id: u32, content: *Content) void {
        self.pushUnit(id, .{ .content = content }, 0);
    }

    pub fn appendContentStringId(self: *Self, str_id: []const u8, content: *Content) void {
        self.pushUnit(Unit.Id.fromString(str_id).id, .{ .content = content }, 0);
    }

    /// Ends a layout. Must be called after `begin`.
    pub fn end(self: *Self) void {
        std.debug.assert(self.stack.items.len == 1);
        _ = self.stack.pop();
    }

    pub fn getUnitById(self: *const Self, unit_id: Unit.Id) ?*const Unit {
        return self.getUnitByIntId(unit_id.id);
    }

    pub fn getUnitByStringId(self: *const Self, str_id: []const u8) ?*const Unit {
        return self.getUnitById(.fromString(str_id));
    }

    pub fn getUnitByStringIdComptime(self: *const Self, comptime str_id: []const u8) ?*const Unit {
        return self.getUnitById(.fromStringComptime(str_id));
    }

    pub fn getUnitByIntId(self: *const Self, id: u32) ?*const Unit {
        return &self.units.items[self.ids.get(id) orelse return null];
    }

    pub fn getUnitByIndex(self: *const Self, index: usize) ?*const Unit {
        if (index >= self.units.items.len) {
            return null;
        }

        return &self.units.items[index];
    }

    pub fn get(self: *const Self, i: usize) *Unit {
        return &self.units.items[i];
    }

    pub fn renderCommands(self: *const Self) RenderCommand.Iterator {
        std.debug.assert(self.units.items.len > 0);
        std.debug.assert(!self.units.items[0].size.isZero());

        self.rci_scratch_buf[0] = .{};

        return .{
            .ctx = self,
            .stack = self.rci_scratch_buf,
        };
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

    fn computeIntrinsicSizes(self: *const Self) !void {
        var i: usize = self.units.items.len;
        while (i > 0) {
            i -= 1;
            const unit = &self.units.items[i];
            switch (unit.data) {
                .content => {
                    const measured = try unit.measure(.empty);
                    unit.min_size = measured;
                    unit.size = measured;
                },
                .container => |container| {
                    const cfg = container.layout;
                    const axis = cfg.axis;
                    const cross = axis.cross();

                    const intrinsic = cfg.sizing.intrinsic();
                    const intrinsic_main = normalizeIntrinsicValue(intrinsic.axis(axis));
                    const intrinsic_cross = normalizeIntrinsicValue(intrinsic.axis(cross));

                    const main_padding = cfg.padding.sumAxis(axis);
                    const cross_padding = cfg.padding.sumAxis(cross);

                    const child_main = self.unitChildrenAnySizeTotal(unit, "min_size", axis);
                    const child_cross = self.unitChildrenAnySizeMax(unit, "min_size", cross);

                    const main_min = @max(child_main + main_padding, intrinsic_main);
                    const cross_min = @max(child_cross + cross_padding, intrinsic_cross);

                    unit.min_size = vecAxisSwap(main_min, cross_min, axis);
                    unit.size = unit.min_size;
                },
            }
        }
    }

    fn distributeMainAxis(
        self: *const Self,
        unit: *Unit,
        axis: Vec2.Axis,
        inner_main: f32,
        sizes: []f32,
        mins: []f32,
        gap_total: f32,
    ) f32 {
        const epsilon: f32 = 1e-4;
        const child_count = unit.children.items.len;
        if (child_count == 0) return gap_total;

        var total: f32 = 0;
        for (sizes) |s| total += s;

        if (!std.math.isFinite(inner_main)) {
            return total + gap_total;
        }

        const target = @max(inner_main - gap_total, 0);

        if (total > target + epsilon) {
            var excess = total - target;
            while (excess > epsilon) {
                var shrinkable: f32 = 0;
                var flags = self.dist_active_scratch_buf[0..child_count];
                for (unit.children.items, 0..) |child_index, idx| {
                    const child = self.get(child_index);
                    const dim = child.config().sizing.axisDimension(axis);
                    const can_shrink = dim.mode != .fixed and dim.mode != .percent;
                    if (!can_shrink) {
                        flags[idx] = false;
                        continue;
                    }
                    const cap = sizes[idx] - mins[idx];
                    if (cap > epsilon) {
                        shrinkable += cap;
                        flags[idx] = true;
                    } else {
                        flags[idx] = false;
                    }
                }
                if (shrinkable <= epsilon) break;

                var consumed: f32 = 0;
                for (unit.children.items, 0..) |_, idx| {
                    if (!self.dist_active_scratch_buf[idx]) continue;
                    const cap = sizes[idx] - mins[idx];
                    if (cap <= epsilon) continue;
                    const share = excess * (cap / shrinkable);
                    const delta = @min(share, cap);
                    sizes[idx] -= delta;
                    consumed += delta;
                }
                if (consumed <= epsilon) break;
                total -= consumed;
                excess = total - target;
            }
        } else if (total < target - epsilon) {
            var remaining = target - total;
            while (remaining > epsilon) {
                var growable: f32 = 0;
                var flags = self.dist_active_scratch_buf[0..child_count];
                for (unit.children.items, 0..) |child_index, idx| {
                    const child = self.get(child_index);
                    const dim = child.config().sizing.axisDimension(axis);
                    if (dim.mode != .grow) {
                        flags[idx] = false;
                        continue;
                    }
                    var max_val = dim.value.range.max;
                    if (!std.math.isFinite(max_val)) {
                        max_val = inner_main;
                    }
                    if (!std.math.isFinite(max_val)) {
                        max_val = sizes[idx] + remaining;
                    }
                    const cap = @max(max_val - sizes[idx], 0);
                    if (cap > epsilon) {
                        flags[idx] = true;
                        growable += cap;
                    } else {
                        flags[idx] = false;
                    }
                }
                if (growable <= epsilon) break;

                var consumed: f32 = 0;
                for (unit.children.items, 0..) |child_index, idx| {
                    if (!self.dist_active_scratch_buf[idx]) continue;
                    const child = self.get(child_index);
                    const dim = child.config().sizing.axisDimension(axis);
                    var max_val = dim.value.range.max;
                    if (!std.math.isFinite(max_val)) {
                        max_val = inner_main;
                    }
                    if (!std.math.isFinite(max_val)) {
                        max_val = sizes[idx] + remaining;
                    }
                    const cap = @max(max_val - sizes[idx], 0);
                    if (cap <= epsilon) continue;
                    const share = remaining * (cap / growable);
                    const delta = @min(share, cap);
                    sizes[idx] += delta;
                    consumed += delta;
                }
                if (consumed <= epsilon) break;
                total += consumed;
                remaining = target - total;
            }
        }

        return total + gap_total;
    }

    fn layoutUnitRecursive(self: *const Self, index: usize, origin: Vec2, available: Vec2) !void {
        var unit = self.get(index);
        switch (unit.data) {
            .content => {
                const constraints = Constraints{
                    .max_width = finiteConstraint(available.x),
                    .max_height = finiteConstraint(available.y),
                };
                const measured = try unit.measure(constraints);
                unit.size = .init(
                    @max(unit.min_size.x, if (constraints.max_width) |limit| @min(measured.x, limit) else measured.x),
                    @max(unit.min_size.y, if (constraints.max_height) |limit| @min(measured.y, limit) else measured.y),
                );
                unit.bbox = Rect.init(origin.x, origin.y, unit.size.x, unit.size.y);
            },
            .container => |container| {
                const cfg = container.layout;
                const axis = cfg.axis;
                const cross = axis.cross();

                unit.size = cfg.sizing.clamp(unit.size, available);
                unit.size.x = @max(unit.size.x, unit.min_size.x);
                unit.size.y = @max(unit.size.y, unit.min_size.y);

                if (container.aspect_ratio.aspect_ratio > 0 and unit.size.x > 0 and unit.size.y > 0) {
                    const ratio = container.aspect_ratio.aspect_ratio;
                    var width = unit.size.x;
                    var height = unit.size.y;
                    if (width / ratio > height) {
                        width = height * ratio;
                    } else {
                        height = width / ratio;
                    }
                    unit.size = .init(width, height);
                }

                unit.bbox = Rect.init(origin.x, origin.y, unit.size.x, unit.size.y);

                const padding_vec = cfg.padding.toVec();
                var inner_size = unit.size.sub(padding_vec);
                if (inner_size.x < 0) inner_size.x = 0;
                if (inner_size.y < 0) inner_size.y = 0;

                const inner_origin = origin
                    .add(cfg.padding.topLeft())
                    .add(container.clip.child_offset);

                const child_count = unit.children.items.len;
                if (child_count == 0) return;

                var scratch = self.dist_size_scratch_buf[0 .. child_count * 2];
                var sizes = scratch[0..child_count];
                var mins = scratch[child_count .. child_count * 2];

                const inner_main = inner_size.axis(axis);
                const inner_cross = inner_size.axis(cross);

                var total_main: f32 = 0;
                for (unit.children.items, 0..) |child_index, idx| {
                    const child = self.get(child_index);
                    const dim = child.config().sizing.axisDimension(axis);
                    const min_main = child.min_size.axis(axis);
                    var size_main = child.size.axis(axis);
                    size_main = dim.clamp(size_main, inner_main);
                    size_main = @max(size_main, min_main);
                    sizes[idx] = size_main;
                    mins[idx] = min_main;
                    total_main += size_main;
                }

                const gap_total: f32 = if (child_count > 1)
                    cfg.child_gap * @as(f32, @floatFromInt(child_count - 1))
                else
                    0;

                const required_with_gaps = self.distributeMainAxis(
                    unit,
                    axis,
                    inner_main,
                    sizes,
                    mins,
                    gap_total,
                );

                const leftover_main = inner_main - required_with_gaps;
                const main_align = cfg.child_alignment.axis(axis);
                const cross_align = cfg.child_alignment.axis(cross);
                var current_main = inner_origin.axis(axis) + alignmentOffset(main_align, leftover_main);

                for (unit.children.items, 0..) |child_index, idx| {
                    var child = self.get(child_index);
                    const child_cfg = child.config();
                    const dim_cross = child_cfg.sizing.axisDimension(cross);

                    const final_main = sizes[idx];
                    var cross_size = child.size.axis(cross);
                    const min_cross = child.min_size.axis(cross);

                    if (child.data == .content) {
                        const width_constraint = if (axis == .x) finiteConstraint(final_main) else finiteConstraint(inner_cross);
                        const height_constraint = if (axis == .x) finiteConstraint(inner_cross) else finiteConstraint(final_main);
                        const measure_constraints = Constraints.init(width_constraint, height_constraint);
                        const measured = try child.measure(measure_constraints);
                        const measured_cross = switch (axis) {
                            .x => measured.y,
                            .y => measured.x,
                        };
                        if (measured_cross > cross_size) {
                            cross_size = measured_cross;
                        }
                    }

                    switch (dim_cross.mode) {
                        .fixed, .percent => {
                            cross_size = dim_cross.clamp(cross_size, inner_cross);
                        },
                        .grow => {
                            var target = inner_cross;
                            if (!std.math.isFinite(target)) {
                                target = cross_size;
                            }
                            const range = dim_cross.value.range;
                            cross_size = std.math.clamp(target, range.min, range.max);
                        },
                        .fit => {
                            const range = dim_cross.value.range;
                            const max_size = if (std.math.isFinite(inner_cross)) inner_cross else range.max;
                            cross_size = std.math.clamp(cross_size, range.min, @min(range.max, max_size));
                        },
                    }

                    cross_size = @max(cross_size, min_cross);

                    child.size = vecAxisSwap(final_main, cross_size, axis);

                    var cross_space = inner_cross - cross_size;
                    if (!std.math.isFinite(cross_space) or cross_space < 0) {
                        cross_space = 0;
                    }
                    const cross_offset = alignmentOffset(cross_align, cross_space);

                    const child_main_pos = current_main;
                    const child_cross_pos = inner_origin.axis(cross) + cross_offset;
                    const child_origin = vecAxisSwap(child_main_pos, child_cross_pos, axis);

                    child.bbox = Rect.init(child_origin.x, child_origin.y, child.size.x, child.size.y);

                    current_main += child.size.axis(axis) + cfg.child_gap;
                }

                // Recursively layout container children after the loop to avoid corrupting scratch buffers
                for (unit.children.items) |child_index| {
                    const child = self.get(child_index);
                    if (child.data == .container) {
                        try self.layoutUnitRecursive(child_index, .init(child.bbox.x, child.bbox.y), child.size);
                    }
                }
            },
        }
    }

    pub fn computeLayout(self: *const Self) !void {
        std.debug.assert(self.stack.items.len == 0);
        std.debug.assert(self.units.items.len > 0);
        std.debug.assert(self.units.items[0].size.isZero());

        try self.computeIntrinsicSizes();

        const root_size = self.get(0).size;
        try self.layoutUnitRecursive(0, Vec2.zero, root_size);
    }
};

const TestContent = struct {
    const vtable = &Content.VTable{
        .measure = measure,
        .debug_name = "TestContent",
    };

    content: Content = .{ .vtable = vtable },
    base_size: Vec2,
    factor: f32,
    call_count: usize = 0,
    last_constraints: Constraints = Constraints.empty,

    fn init(base_size: Vec2, factor: f32) TestContent {
        return .{
            .base_size = base_size,
            .factor = factor,
        };
    }

    fn measure(content_ptr: *Content, constraints: Constraints) Content.MeasureError!Vec2 {
        const self: *TestContent = @fieldParentPtr("content", content_ptr);
        self.call_count += 1;
        self.last_constraints = constraints;

        var width = self.base_size.x;
        var height = self.base_size.y;

        if (constraints.max_width) |w| {
            width = w;
            height = @max(height, w * self.factor);
        }

        if (constraints.max_height) |h| {
            height = @min(height, h);
        }

        return Vec2.init(width, height);
    }
};

test "Context.computeLayout distributes grow widths" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 60),
        .axis = .x,
    });

    const fixed_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(80),
                .height = Sizing.Dimension.fixed(40),
            },
        },
    });
    ctx.closeContainer(fixed_idx);

    const grow_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.grow(.{ .min = 50, .max = 200 }),
                .height = Sizing.Dimension.fixed(40),
            },
        },
    });
    ctx.closeContainer(grow_idx);

    ctx.end();
    try ctx.computeLayout();

    const root_unit = ctx.getUnitByIndex(0).?;
    try std.testing.expectApproxEqAbs(200, root_unit.size.x, 1e-4);
    try std.testing.expectApproxEqAbs(60, root_unit.size.y, 1e-4);

    const fixed_unit = ctx.getUnitByIndex(fixed_idx).?;
    try std.testing.expectApproxEqAbs(80, fixed_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(40, fixed_unit.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(0, fixed_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(0, fixed_unit.bbox.y, 1e-3);

    const grow_unit = ctx.getUnitByIndex(grow_idx).?;
    try std.testing.expectApproxEqAbs(120, grow_unit.size.x, 1e-2);
    try std.testing.expectApproxEqAbs(40, grow_unit.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(80, grow_unit.bbox.x, 1e-2);
    try std.testing.expectApproxEqAbs(0, grow_unit.bbox.y, 1e-3);
}

test "Context.computeLayout fit container sizes to content" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 400),
        .axis = .x,
    });

    const fit_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(.{ .x = 100, .y = 50 }, 1.0);
    ctx.appendContent(&content.content);

    ctx.closeContainer(fit_idx);

    ctx.end();
    try ctx.computeLayout();

    const fit_unit = ctx.getUnitByIndex(fit_idx).?;
    try std.testing.expectApproxEqAbs(100, fit_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(50, fit_unit.size.y, 1e-3);
}

test "Context.computeLayout nested fit containers size correctly" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 400),
        .axis = .x,
    });

    const outer_fit_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .y,
            .padding = Padding.all(10),
        },
    });

    const inner_fit_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .x,
            .child_gap = 5,
        },
    });

    var content1 = TestContent.init(.{ .x = 60, .y = 40 }, 1.0);
    ctx.appendContent(&content1.content);

    var content2 = TestContent.init(.{ .x = 80, .y = 30 }, 1.0);
    ctx.appendContent(&content2.content);

    ctx.closeContainer(inner_fit_idx);
    ctx.closeContainer(outer_fit_idx);

    ctx.end();
    try ctx.computeLayout();

    const inner_unit = ctx.getUnitByIndex(inner_fit_idx).?;
    try std.testing.expectApproxEqAbs(145, inner_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(40, inner_unit.size.y, 1e-3);

    const outer_unit = ctx.getUnitByIndex(outer_fit_idx).?;
    try std.testing.expectApproxEqAbs(165, outer_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(60, outer_unit.size.y, 1e-3);
}

test "Context.computeLayout vertical container with padding and fit text background" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 200),
        .axis = .y,
    });

    const vert_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.grow(.{}),
                .height = Sizing.Dimension.grow(.{}),
            },
            .axis = .y,
            .padding = Padding.all(10),
            .child_gap = 10,
        },
    });

    const horizontal_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.grow(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .x,
            .child_gap = 10,
        },
    });

    ctx.closeContainer(ctx.openContainer(.{
        .layout = .{
            .sizing = Sizing.fixedXY(80, 60),
        },
    }));

    ctx.closeContainer(ctx.openContainer(.{
        .layout = .{
            .sizing = Sizing.fixedXY(60, 60),
        },
    }));

    ctx.closeContainer(horizontal_idx);

    const text_bg_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
        },
    });

    var text_content = TestContent.init(.{ .x = 100, .y = 20 }, 1.0);
    ctx.appendContent(&text_content.content);

    ctx.closeContainer(text_bg_idx);

    ctx.closeContainer(vert_idx);

    ctx.end();
    try ctx.computeLayout();

    const vert_unit = ctx.getUnitByIndex(vert_idx).?;
    try std.testing.expectApproxEqAbs(400, vert_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(200, vert_unit.size.y, 1e-3);

    const horizontal_unit = ctx.getUnitByIndex(horizontal_idx).?;
    try std.testing.expectApproxEqAbs(380, horizontal_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(60, horizontal_unit.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(10, horizontal_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(10, horizontal_unit.bbox.y, 1e-3);

    const text_bg_unit = ctx.getUnitByIndex(text_bg_idx).?;
    try std.testing.expectApproxEqAbs(100, text_bg_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(20, text_bg_unit.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(10, text_bg_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(80, text_bg_unit.bbox.y, 1e-3);

    const expected_bottom = text_bg_unit.bbox.y + text_bg_unit.size.y;
    const container_bottom = vert_unit.bbox.y + vert_unit.size.y - 10;
    try std.testing.expect(expected_bottom < container_bottom);
}

test "Context.computeLayout centers container and remeasures content" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 100),
        .axis = .x,
        .child_alignment = .{ .x = .start, .y = .center },
    });

    const container_idx = ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(60),
                .height = Sizing.Dimension.fit(.{ .min = 20, .max = std.math.inf(f32) }),
            },
            .axis = .y,
        },
    });

    var content = TestContent.init(Vec2.init(20, 30), 0.5);
    const content_idx = ctx.units.items.len;
    ctx.appendContent(&content.content);

    ctx.closeContainer(container_idx);
    ctx.end();

    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(0, container_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(35, container_unit.bbox.y, 1e-3);
    try std.testing.expectApproxEqAbs(60, container_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(30, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(content_idx).?;
    try std.testing.expectApproxEqAbs(0, content_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(35, content_unit.bbox.y, 1e-3);
    try std.testing.expectApproxEqAbs(60, content_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(30, content_unit.size.y, 1e-3);

    try std.testing.expectEqual(@as(usize, 2), content.call_count);
    try std.testing.expect(content.last_constraints.max_width != null);
    try std.testing.expectApproxEqAbs(60, content.last_constraints.max_width.?, 1e-3);
    try std.testing.expect(content.last_constraints.max_height != null);
    try std.testing.expectApproxEqAbs(30, content.last_constraints.max_height.?, 1e-3);
}
