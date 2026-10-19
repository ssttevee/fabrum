//! The layout system.
//!
//! A layout is rebuilt every frame: open containers and append content on a
//! `Context` between `begin` and `end`, call `computeLayout`, then walk the
//! resulting `RenderCommand`s with `renderCommands`.
//!
//! This namespace knows nothing about application state, input or
//! platforms; those belong to `fabrum.app`, which builds on top of it.
const std = @import("std");
const builtin = @import("builtin");

const fabrum = @import("root.zig");
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Range = fabrum.Range;
const Color = fabrum.Color;

pub const Sizing = @import("layout/sizing.zig");
pub const Padding = @import("layout/padding.zig");
pub const Alignment = @import("layout/alignment.zig");
pub const CornerRadius = @import("layout/corner_radius.zig");
pub const BorderWidths = @import("layout/border_widths.zig");
pub const RenderCommand = @import("layout/render_command.zig");

const renderer = @import("layout/renderer.zig");
/// What a renderer draws into.
pub const Surface = renderer.Surface;
pub const PixelFormat = renderer.PixelFormat;
/// Draws commands with a renderer, checking at compile time that it
/// accepts the surface; see `layout/renderer.zig` for the interface.
pub const draw = renderer.draw;
pub const checkRenderer = renderer.checkRenderer;
pub const accepts = renderer.accepts;
/// A renderer for tests that fills boxes into pixels.
pub const TestRenderer = renderer.TestRenderer;

/// What changed between frames: `Damage`.
pub const Damage = @import("layout/damage.zig");

/// Text content and measurement.
pub const text = @import("layout/text.zig");

const layout = @This();

/// Gravity represents unit alignment within a layout.
pub const Gravity = enum {
    /// Aligns the unit to the start of the axis. This is the left for x and top for y.
    start,
    /// Aligns the unit to the center of the axis.
    center,
    /// Aligns the unit to the end of the axis. This is the right for x and bottom for y.
    end,

    pub const default = Gravity.start;

    pub const left = Gravity.start;
    pub const top = Gravity.start;

    pub const right = Gravity.end;
    pub const bottom = Gravity.end;
};

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

    /// A floating unit is taken out of its parent's flow: it doesn't affect
    /// the size or position of its parent or siblings. Instead it is sized
    /// against the unit it attaches to (`grow` fills it, `percent` is a
    /// fraction of it) and positioned so that its `unit_point` lies on the
    /// target's `parent_point`, moved by `offset`.
    ///
    /// Floating units are painted and hit-tested in tree order like any
    /// other unit, so to layer one over everything, declare it last.
    /// `z_index` is passed through on render commands but doesn't reorder
    /// them, and `expand`, `pointer_passthrough` and `clip_to_parent` are
    /// not implemented yet.
    pub const FloatingConfig = struct {
        mode: AttachMode = .default,
        /// The unit to attach to, for the `unit_id` and `unit_index` modes.
        parent: union { id: u64, index: usize } = .{ .id = 0 },
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

            /// Where the point lies in a box of `size`, from its top left.
            pub fn offsetIn(self: AttachPoint, size: Vec2) Vec2 {
                const fx: f32, const fy: f32 = switch (self) {
                    .left_top => .{ 0, 0 },
                    .left_center => .{ 0, 0.5 },
                    .left_bottom => .{ 0, 1 },
                    .center_top => .{ 0.5, 0 },
                    .center_center => .{ 0.5, 0.5 },
                    .center_bottom => .{ 0.5, 1 },
                    .right_top => .{ 1, 0 },
                    .right_center => .{ 1, 0.5 },
                    .right_bottom => .{ 1, 1 },
                };
                return .init(size.x * fx, size.y * fy);
            }
        };

        pub const AttachMode = enum {
            /// no floating
            none,
            /// Attaches to the unit's parent.
            parent,
            /// Attaches to the unit at `parent.index`.
            unit_index,
            /// Attaches to the unit with ID `parent.id`.
            unit_id,
            /// Attaches to the root, which is the viewport.
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
        /// Whether the content is meant to be larger than the box along
        /// the axis, as a scroll view's is: content that wraps under its
        /// ancestors' width (`Content.limit`) takes no limit from beyond
        /// such a container.
        scrolls_horizontal: bool = false,
        scrolls_vertical: bool = false,
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
            return self.x != .visible or self.y != .visible;
        }
    };
};

pub const Content = struct {
    vtable: *const VTable,
    /// How far up the tree the width and height limits it is measured
    /// under come from, before sizing: its parent's own bounds (a fixed
    /// size or a finite maximum), or the nearest bounded ancestor's,
    /// looking through parents that fit or grow without a bound. Content
    /// that wraps, such as a native label, asks for `ancestors`, so that
    /// it is measured under the width it will get; content that fills its
    /// limit, such as a picture scaled to fit, keeps `parent`.
    limit: Limit = .parent,

    pub const Limit = enum { parent, ancestors };

    pub const MeasureError = error{MeasureFailed};

    pub const VTable = struct {
        /// Returns the shape of the content based on optional .
        measure: *const fn (self: *Content, constraints: Constraints) MeasureError!Vec2,
        /// Returns the smallest size the content accepts under
        /// `constraints`, if it can be squeezed below what `measure`
        /// returns, such as text that is cut with an ellipsis. Containers
        /// shrink content towards this size when space runs short. Null
        /// means the content can't be squeezed.
        measure_min: ?*const fn (self: *Content, constraints: Constraints) MeasureError!Vec2 = null,
        deinit: ?*const fn (self: *Content) void = null,
        /// A hash of everything about the content that changes how it
        /// draws in a given box, such as a text's string and style, for
        /// `Damage` to tell whether it changed between frames. Content
        /// without one is taken to have changed every frame.
        fingerprint: ?*const fn (self: *const Content) u64 = null,

        debug_name: []const u8 = "Content",
    };

    pub fn measure(self: *Content, constraints: Constraints) !Vec2 {
        return try self.vtable.measure(self, constraints);
    }

    /// The smallest size the content accepts; see `VTable.measure_min`.
    pub fn measureMin(self: *Content, constraints: Constraints) !Vec2 {
        const measure_min = self.vtable.measure_min orelse return self.measure(constraints);
        return try measure_min(self, constraints);
    }

    pub fn deinit(self: *Content) void {
        if (self.vtable.deinit) |fn_ptr| fn_ptr(self);
    }

    /// The content's `VTable.fingerprint`, or null if it has none.
    pub fn fingerprint(self: *const Content) ?u64 {
        const f = self.vtable.fingerprint orelse return null;
        return f(self);
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
            if (self.max_width) |max| @min(size.x, max) else size.x,
            if (self.max_height) |max| @min(size.y, max) else size.y,
        );
    }
};

pub const Unit = struct {
    /// The unit's ID, or 0 for none. 64 bits, so that IDs hashed from keys
    /// practically never collide, since interaction state such as focus is
    /// kept by ID across frames.
    id: u64,
    parent: usize,
    data: Data,
    children: std.ArrayList(usize),

    // Computed
    size: Vec2 = .zero, // preferred size, then final width/height after distribution
    min_size: Vec2 = .zero, // aggregated intrinsic minimum content size
    bbox: Rect = .zero,
    /// For containers: the extent of the children in the flow, from the
    /// top left of the content (the box's, moved by `clip.child_offset`)
    /// to the far edges of the children, plus padding on both sides. Larger
    /// than the box on an axis whose overflow is clipped, as when it
    /// scrolls; never smaller than the padding.
    content_size: Vec2 = .zero,

    pub const Id = struct {
        id: u64 = 0,

        pub const none: Id = .{};
        pub const zero: Id = .{};

        pub fn fromInt(id: u64) Id {
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

        fn hash(s: []const u8) u64 {
            return std.hash.Wyhash.hash(0, s);
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

    /// Whether the unit floats, outside its parent's flow. See
    /// `ContainerDeclaration.FloatingConfig`.
    pub fn isFloating(self: *const Unit) bool {
        return self.data == .container and self.data.container.floating.active();
    }

    pub fn hasId(self: *const Unit, unit_id: Id) bool {
        return self.id == unit_id.id;
    }

    pub fn hasIntId(self: *const Unit, id: u64) bool {
        return self.id == id;
    }

    pub fn hasStringId(self: *const Unit, str_id: []const u8) bool {
        return self.id == Id.hash(str_id);
    }

    pub fn hasStringIdComptime(self: *const Unit, comptime str_id: []const u8) bool {
        return self.id == comptime Id.hash(str_id);
    }

    /// Whether `point` lies inside the unit. For containers, points cut away
    /// by rounded corners are excluded.
    pub fn hovered(self: *const Unit, point: Vec2) bool {
        if (!self.bbox.contains(point)) {
            return false;
        }

        if (self.data != .container) {
            return true;
        }

        const rect = self.bbox;
        const corner_radius = self.data.container.corner_radius.fitted(rect.w, rect.h);

        // distances from the point to each edge of the box
        const left = point.x - rect.x;
        const top = point.y - rect.y;
        const right = rect.w - left;
        const bottom = rect.h - top;

        return insideCorner(corner_radius.top_left, left, top) and
            insideCorner(corner_radius.top_right, right, top) and
            insideCorner(corner_radius.bottom_left, left, bottom) and
            insideCorner(corner_radius.bottom_right, right, bottom);
    }

    /// Whether a point `dx` and `dy` away from the two edges meeting at a
    /// corner of the given radius is inside the rounded corner.
    fn insideCorner(radius: f32, dx: f32, dy: f32) bool {
        if (dx >= radius or dy >= radius) {
            return true;
        }

        const ox = radius - dx;
        const oy = radius - dy;
        return ox * ox + oy * oy <= radius * radius;
    }
};

pub const HoveredUnitsIterator = struct {
    point: Vec2,
    /// unfiltered list of units from the layout context
    units: []const Unit,
    pos: usize = 0,

    /// Returns the next unit whose shape contains the point, topmost first.
    pub fn next(self: *HoveredUnitsIterator) ?*const Unit {
        while (self.pos < self.units.len) {
            // read backwards to return descendents first
            const unit = &self.units[self.units.len - self.pos - 1];
            self.pos += 1;
            if (unit.hovered(self.point)) {
                return unit;
            }
        }

        return null;
    }
};

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

/// Whether overflow along `axis` is clipped, so the children can be larger
/// than the container that way, as in a scroll view.
fn clipsAxis(clip: ContainerDeclaration.ClipConfig, axis: Vec2.Axis) bool {
    return switch (axis) {
        .x => clip.horizontal,
        .y => clip.vertical,
    };
}

/// Whether the content is meant to scroll along `axis`, so it may be
/// larger than the container that way.
fn scrollsAxis(clip: ContainerDeclaration.ClipConfig, axis: Vec2.Axis) bool {
    return switch (axis) {
        .x => clip.scrolls_horizontal,
        .y => clip.scrolls_vertical,
    };
}

fn alignmentOffset(gravity: Gravity, leftover: f32) f32 {
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

    /// The layout outgrew a `Config` limit: see the log line for which,
    /// and which field raises it. The layout under way is unusable; the
    /// next `begin` starts over.
    pub const Error = error{LayoutCapacity};

    const IdMap = std.ArrayHashMapUnmanaged(
        u64,
        usize,
        struct {
            pub fn hash(self: @This(), k: u64) u32 {
                _ = self;
                // IDs are hashes already: fold the two halves
                return @truncate(k ^ (k >> 32));
            }

            pub fn eql(self: @This(), a: u64, b: u64, i: usize) bool {
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
    fn pushUnit(self: *Self, unit_id: u64, data: Unit.Data, breadth: usize) void {
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
    ) Error!usize {
        return self.openContainerId(.{}, decl);
    }

    /// Opens a new unit with the given configuration. Must be finished
    ///  with a matching call to `closeContainer`.
    pub fn openContainerId(
        self: *Self,
        unit_id: Unit.Id,
        decl: ContainerDeclaration,
    ) Error!usize {
        return self.openContainerIdBreadth(unit_id, decl, self.breadth);
    }

    /// Opens a new unit with the given configuration and breadth. Must be
    /// finished with a matching call to `closeContainer`.
    pub fn openContainerBreadth(
        self: *Self,
        decl: ContainerDeclaration,
        breadth: usize,
    ) Error!usize {
        return self.openContainerIdBreadth(.{}, decl, breadth);
    }

    /// Opens a new unit with the given configuration and breadth. Must be
    /// finished with a matching call to `closeContainer`. Fails with
    /// `error.LayoutCapacity` when a `Config` limit is reached, leaving the
    /// layout as it was.
    pub fn openContainerIdBreadth(
        self: *Self,
        unit_id: Unit.Id,
        decl: ContainerDeclaration,
        breadth: usize,
    ) Error!usize {
        std.debug.assert(self.stack.items.len > 0);
        try self.reserve(breadth, true);

        const index = self.units.items.len;
        self.pushUnit(unit_id.id, .{ .container = decl }, breadth);
        self.stack.appendAssumeCapacity(index);
        self.get(self.stack.items[self.stack.items.len - 2]).children.appendAssumeCapacity(index);
        return index;
    }

    /// Checks there is room for one more unit with `breadth` children in
    /// the open container, and on the stack if it `opens`; else fails with
    /// `error.LayoutCapacity`, logging which limit was reached and which
    /// `Config` field raises it.
    fn reserve(self: *const Self, breadth: usize, opens: bool) Error!void {
        if (self.units.items.len >= self.units.capacity) {
            return capacityError("unit", self.units.capacity, "units");
        }
        if (opens and self.stack.items.len >= self.stack.capacity) {
            return capacityError("depth", self.stack.capacity, "depth");
        }
        if (breadth > self.ci_buf.len - self.ci_buf_pos) {
            return capacityError("children buffer", self.ci_buf.len, "units, or open wide containers with openContainerBreadth and a smaller breadth elsewhere");
        }
        const siblings = &self.get(self.stack.getLast()).children;
        if (siblings.items.len >= siblings.capacity) {
            return capacityError("child breadth", siblings.capacity, "breadth, or open the parent with openContainerBreadth");
        }
    }

    fn capacityError(limit: []const u8, size: usize, raise: []const u8) Error {
        // the test runner counts error logs as failures, and tests reach
        // this on purpose
        if (!builtin.is_test) std.log.err("fabrum: the layout's {s} limit ({d}) is reached; raise Context.Config.{s}", .{ limit, size, raise });
        return error.LayoutCapacity;
    }

    /// Asserts the current unit and closes it. Must be called after a matching `openContainer`.
    pub fn closeContainer(self: *Self, expected_index: usize) void {
        std.debug.assert(expected_index == self.stack.pop());
    }

    pub fn appendContent(self: *Self, content: *Content) Error!void {
        return self.appendContentId(.{}, content);
    }

    /// Appends `content` to the open container. Fails with
    /// `error.LayoutCapacity` as `openContainerIdBreadth` does.
    pub fn appendContentId(self: *Self, unit_id: Unit.Id, content: *Content) Error!void {
        std.debug.assert(self.stack.items.len > 0);
        try self.reserve(0, false);

        const index = self.units.items.len;
        self.pushUnit(unit_id.id, .{ .content = content }, 0);
        self.get(self.stack.getLast()).children.appendAssumeCapacity(index);
    }

    /// Appends an empty unit that grows along the open container's axis,
    /// pushing the units before it and after it apart, as a flexible space
    /// in a toolbar does. Spacers in one container share the free space
    /// equally with each other and with other growing units. A spacer is a
    /// unit like any other, so the container's `child_gap` applies on both
    /// sides of it, and in a container that fits its content there is no
    /// free space for it to take.
    pub fn spacer(self: *Self) Error!void {
        const axis = self.get(self.stack.getLast()).config().axis;
        const sizing: Sizing = switch (axis) {
            .x => .{ .width = .grow(.{}) },
            .y => .{ .height = .grow(.{}) },
        };
        self.closeContainer(try self.openContainerBreadth(.{ .layout = .{ .sizing = sizing } }, 0));
    }

    pub fn appendContentIntId(self: *Self, id: u64, content: *Content) Error!void {
        return self.appendContentId(.{ .id = id }, content);
    }

    pub fn appendContentStringId(self: *Self, str_id: []const u8, content: *Content) Error!void {
        return self.appendContentId(.fromString(str_id), content);
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

    pub fn getUnitByIntId(self: *const Self, id: u64) ?*const Unit {
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

    /// Sums the sizes of the children in the flow, with `gap` between them.
    /// Floating children take no space.
    fn childrenAnySizeTotal(self: *const Self, children: []const usize, gap: f32, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
        var total: f32 = 0;
        var count: usize = 0;
        for (children) |child_index| {
            const child = self.get(child_index);
            if (child.isFloating()) continue;

            if (count != 0) {
                total += gap;
            }

            total += @field(child, size_field).axis(axis);
            count += 1;
        }

        return total;
    }

    fn childrenAnySizeMax(self: *const Self, children: []const usize, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
        var max: f32 = 0;
        for (children) |child_index| {
            const child = self.get(child_index);
            if (child.isFloating()) continue;
            max = @max(max, @field(child, size_field).axis(axis));
        }

        return max;
    }

    /// Number of children in the flow, leaving out floating ones.
    fn flowChildCount(self: *const Self, children: []const usize) usize {
        var count: usize = 0;
        for (children) |child_index| {
            if (!self.get(child_index).isFloating()) count += 1;
        }
        return count;
    }

    inline fn unitChildrenAnySizeTotal(self: *const Self, unit: *Unit, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
        return self.childrenAnySizeTotal(unit.children.items, unit.config().child_gap, size_field, axis);
    }

    inline fn unitChildrenAnySizeMax(self: *const Self, unit: *Unit, comptime size_field: []const u8, axis: Vec2.Axis) f32 {
        return self.childrenAnySizeMax(unit.children.items, size_field, axis);
    }

    /// The most room content can have along `axis` before sizing: its
    /// parent's fixed size or finite maximum that way, less the padding;
    /// or, for content whose `limit` is `ancestors`, the nearest bounded
    /// ancestor's, less the padding of every container between, so that
    /// text and native labels wrap under the width they will get.
    /// Ancestors that fit or grow without a bound are looked through,
    /// since they can't give their content more than their own ancestor
    /// allows; a container that scrolls along the axis ends the walk, as
    /// its content may be larger. Null means no limit is known.
    fn inheritedLimit(self: *const Self, unit: *const Unit, axis: Vec2.Axis, limit: Content.Limit) ?f32 {
        var padding: f32 = 0;
        var at = unit.parent;
        // as before: a content directly under the root is unbounded
        if (at == 0 and limit == .parent) return null;
        while (true) {
            const parent = &self.units.items[at];
            if (parent.data != .container) return null;
            const container = parent.data.container;
            const cfg = container.layout;
            padding += cfg.padding.sumAxis(axis);
            const dimension = cfg.sizing.axisDimension(axis);
            switch (dimension.mode) {
                .fixed => {
                    const available = dimension.value.number - padding;
                    return if (available > 0) available else null;
                },
                .fit, .grow => {
                    const max_val = dimension.value.range.max;
                    if (std.math.isFinite(max_val)) {
                        const available = max_val - padding;
                        return if (available > 0) available else null;
                    }
                },
                .percent => return null,
            }
            if (limit == .parent or scrollsAxis(container.clip, axis) or at == 0) return null;
            at = parent.parent;
        }
    }

    fn computeIntrinsicSizes(self: *const Self) !void {
        var i: usize = self.units.items.len;
        while (i > 0) {
            i -= 1;
            const unit = &self.units.items[i];
            switch (unit.data) {
                .content => {
                    const content = unit.data.content;
                    const constraints: Constraints = .{
                        .max_width = self.inheritedLimit(unit, .x, content.limit),
                        .max_height = self.inheritedLimit(unit, .y, content.limit),
                    };
                    unit.size = try content.measure(constraints);
                    unit.min_size = if (content.vtable.measure_min) |measure_min| try measure_min(content, constraints) else unit.size;
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

                    const dim_main = cfg.sizing.axisDimension(axis);
                    const dim_cross = cfg.sizing.axisDimension(cross);

                    const clips_main = clipsAxis(container.clip, axis);
                    const clips_cross = clipsAxis(container.clip, cross);

                    // the smallest the children can be squeezed to, then the size they prefer
                    inline for (.{ "min_size", "size" }, .{ true, false }) |field, is_min| {
                        // on an axis whose overflow is clipped, the children
                        // can be larger than the container, so their
                        // minimums don't hold it open
                        const child_main = if (is_min and clips_main) 0 else self.unitChildrenAnySizeTotal(unit, field, axis);
                        const child_cross = if (is_min and clips_cross) 0 else self.unitChildrenAnySizeMax(unit, field, cross);

                        var main = @max(child_main + main_padding, intrinsic_main);
                        var cross_size = @max(child_cross + cross_padding, intrinsic_cross);

                        switch (dim_main.mode) {
                            .fixed => main = @min(main, dim_main.value.number),
                            .fit, .grow => main = @min(main, dim_main.value.range.max),
                            .percent => {},
                        }

                        switch (dim_cross.mode) {
                            .fixed => cross_size = @min(cross_size, dim_cross.value.number),
                            .fit, .grow => cross_size = @min(cross_size, dim_cross.value.range.max),
                            .percent => {},
                        }

                        @field(unit, field) = vecAxisSwap(main, cross_size, axis);
                    }
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

        // overflow along a clipped axis stays: the children keep their sizes
        const clipped = unit.data == .container and clipsAxis(unit.data.container.clip, axis);

        if (total > target + epsilon and !clipped) {
            var excess = total - target;
            while (excess > epsilon) {
                var shrinkable: f32 = 0;
                var flags = self.dist_active_scratch_buf[0..child_count];
                for (unit.children.items, 0..) |child_index, idx| {
                    const child = self.get(child_index);
                    const dim = child.config().sizing.axisDimension(axis);
                    const can_shrink = dim.mode != .fixed and dim.mode != .percent and !child.isFloating();
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
                    if (dim.mode != .grow or child.isFloating()) {
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

                unit.content_size = padding_vec;
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
                    if (child.isFloating()) {
                        // placed by `layoutFloating`, taking no space here
                        sizes[idx] = 0;
                        mins[idx] = 0;
                        continue;
                    }
                    const dim = child.config().sizing.axisDimension(axis);
                    const min_main = child.min_size.axis(axis);
                    var size_main = child.size.axis(axis);
                    size_main = dim.clamp(size_main, inner_main);
                    size_main = @max(size_main, min_main);
                    sizes[idx] = size_main;
                    mins[idx] = min_main;
                    total_main += size_main;
                }

                const flow_count = self.flowChildCount(unit.children.items);
                const gap_total: f32 = if (flow_count > 1)
                    cfg.child_gap * @as(f32, @floatFromInt(flow_count - 1))
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
                    if (child.isFloating()) continue;
                    const child_cfg = child.config();
                    const dim_cross = child_cfg.sizing.axisDimension(cross);

                    const final_main = sizes[idx];
                    var cross_size = child.size.axis(cross);
                    const min_cross = child.min_size.axis(cross);

                    if (child.data == .content) {
                        const limits = vecAxisSwap(final_main, inner_cross, axis);
                        const measured = try child.measure(.init(finiteConstraint(limits.x), finiteConstraint(limits.y)));
                        cross_size = @max(cross_size, measured.axis(cross));
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
                            // across a clipped axis, children may overflow
                            const max_size = if (std.math.isFinite(inner_cross) and !clipsAxis(container.clip, cross)) inner_cross else range.max;
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

                // the children's extent, from the content's top left
                var far = Vec2.zero;
                for (unit.children.items) |child_index| {
                    const child = self.get(child_index);
                    if (child.isFloating()) continue;
                    far.x = @max(far.x, child.bbox.x + child.bbox.w - inner_origin.x);
                    far.y = @max(far.y, child.bbox.y + child.bbox.h - inner_origin.y);
                }
                unit.content_size = far.add(padding_vec);

                // Recursively layout container children after the loop to avoid corrupting scratch buffers.
                // Children are offered this unit's inner size, the space their sizes were resolved
                // against above, not their own resolved size: a `percent` child would otherwise
                // take its percentage of itself, applying it twice.
                for (unit.children.items) |child_index| {
                    const child = self.get(child_index);
                    if (child.data == .container and !child.isFloating()) {
                        try self.layoutUnitRecursive(child_index, .init(child.bbox.x, child.bbox.y), inner_size);
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
        try self.layoutFloating();
    }

    pub const FloatingError = error{FloatingTargetNotFound};

    /// Sizes and positions floating units and lays out their subtrees, once
    /// the flow layout has given every unit they can attach to its box.
    /// Units are visited in index order, so a floating unit nested in
    /// another is placed after its floating ancestor.
    fn layoutFloating(self: *const Self) !void {
        for (self.units.items, 0..) |*unit, index| {
            if (!unit.isFloating()) continue;

            const container = unit.data.container;
            const floating = container.floating;
            const target: *const Unit = switch (floating.mode) {
                .none => unreachable,
                .parent => self.get(unit.parent),
                .root => self.get(0),
                .unit_id => self.getUnitByIntId(floating.parent.id) orelse return error.FloatingTargetNotFound,
                .unit_index => self.getUnitByIndex(floating.parent.index) orelse return error.FloatingTargetNotFound,
            };
            const available = target.size;

            // `grow` fills the target; everything else resolves as in the flow
            const sizing = container.layout.sizing;
            var size = unit.size;
            if (sizing.width.mode == .grow) size.x = sizing.width.value.range.clamp(available.x);
            if (sizing.height.mode == .grow) size.y = sizing.height.value.range.clamp(available.y);
            size = sizing.clamp(size, available);
            size.x = @max(size.x, unit.min_size.x);
            size.y = @max(size.y, unit.min_size.y);
            unit.size = size;

            const anchor = Vec2.init(target.bbox.x, target.bbox.y).add(floating.parent_point.offsetIn(.init(target.bbox.w, target.bbox.h)));
            const origin = anchor.sub(floating.unit_point.offsetIn(size)).add(floating.offset);
            try self.layoutUnitRecursive(index, origin, available);
        }
    }
};

const TestContent = struct {
    content: Content = .{ .vtable = &.{
        .measure = measure,
        .debug_name = "TestContent",
    } },
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

    const fixed_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(80),
                .height = Sizing.Dimension.fixed(40),
            },
        },
    });
    ctx.closeContainer(fixed_idx);

    const grow_idx = try ctx.openContainer(.{
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

    const fit_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(.{ .x = 100, .y = 50 }, 1.0);
    try ctx.appendContent(&content.content);

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

    const outer_fit_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .y,
            .padding = Padding.all(10),
        },
    });

    const inner_fit_idx = try ctx.openContainer(.{
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
    try ctx.appendContent(&content1.content);

    var content2 = TestContent.init(.{ .x = 80, .y = 30 }, 1.0);
    try ctx.appendContent(&content2.content);

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

    const vert_idx = try ctx.openContainer(.{
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

    const horizontal_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.grow(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
            .axis = .x,
            .child_gap = 10,
        },
    });

    ctx.closeContainer(try ctx.openContainer(.{
        .layout = .{
            .sizing = Sizing.fixedXY(80, 60),
        },
    }));

    ctx.closeContainer(try ctx.openContainer(.{
        .layout = .{
            .sizing = Sizing.fixedXY(60, 60),
        },
    }));

    ctx.closeContainer(horizontal_idx);

    const text_bg_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{}),
                .height = Sizing.Dimension.fit(.{}),
            },
        },
    });

    var text_content = TestContent.init(.{ .x = 100, .y = 20 }, 1.0);
    try ctx.appendContent(&text_content.content);

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

test "Context.computeLayout fixed container constrains larger content width" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 200),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(100),
                .height = Sizing.Dimension.fit(.{ .min = 0, .max = std.math.inf(f32) }),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(Vec2.init(150, 50), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(100, container_unit.size.x, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(100, content_unit.size.x, 1e-3);
    try std.testing.expect(content_unit.size.x <= container_unit.size.x);
}

test "Context.computeLayout fixed container constrains larger content height" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 200),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{ .min = 0, .max = std.math.inf(f32) }),
                .height = Sizing.Dimension.fixed(80),
            },
            .axis = .y,
        },
    });

    var content = TestContent.init(Vec2.init(50, 120), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(80, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(80, content_unit.size.y, 1e-3);
    try std.testing.expect(content_unit.size.y <= container_unit.size.y);
}

test "Context.computeLayout fixed container with padding constrains content" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 200),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(100),
                .height = Sizing.Dimension.fixed(100),
            },
            .padding = Padding.xy(10, 10),
            .axis = .x,
        },
    });

    var content = TestContent.init(Vec2.init(200, 200), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(100, container_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(100, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(80, content_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(80, content_unit.size.y, 1e-3);
}

test "Context.computeLayout fixed container constrains both dimensions" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 400),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fixed(100),
                .height = Sizing.Dimension.fixed(50),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(Vec2.init(300, 200), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(100, container_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(50, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(100, content_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(50, content_unit.size.y, 1e-3);
    try std.testing.expect(content_unit.size.x <= container_unit.size.x);
    try std.testing.expect(content_unit.size.y <= container_unit.size.y);
}

test "Context.computeLayout centers container and remeasures content" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 100),
        .axis = .x,
        .child_alignment = .{ .x = .start, .y = .center },
    });

    const container_idx = try ctx.openContainer(.{
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
    try ctx.appendContent(&content.content);

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

test "Context.computeLayout measures content under the nearest bounded ancestor's width" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 400), .axis = .y, .padding = Padding.all(10) });
    // a column that fits, in a box that grows: neither bounds the width
    // itself, so the fixed root does, less every padding on the way
    const column = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y, .padding = Padding.all(5) } });
    const box = try ctx.openContainer(.{ .layout = .{ .padding = Padding.all(2) } });
    var content = TestContent.init(Vec2.init(1000, 10), 0.1);
    content.content.limit = .ancestors;
    try ctx.appendContent(&content.content);
    ctx.closeContainer(box);
    // content that keeps its parent's limit sees none from a box that fits
    const plain_box = try ctx.openContainer(.{ .layout = .{ .padding = Padding.all(2) } });
    var plain = TestContent.init(Vec2.init(50, 10), 0);
    try ctx.appendContent(&plain.content);
    ctx.closeContainer(plain_box);
    ctx.closeContainer(column);
    // a scroll view's content may be wider than it: nothing known
    const scroller = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) } }, .clip = .{ .horizontal = true, .scrolls_horizontal = true } });
    var free = TestContent.init(Vec2.init(1000, 10), 0);
    free.content.limit = .ancestors;
    try ctx.appendContent(&free.content);
    ctx.closeContainer(scroller);
    ctx.end();
    try ctx.computeLayout();

    try std.testing.expectApproxEqAbs(400 - 20 - 10 - 4, content.last_constraints.max_width.?, 1e-3);
    // measured under it before sizing, so the box fits the wrapped height
    const box_unit = ctx.getUnitByIndex(box).?;
    try std.testing.expectApproxEqAbs(366, box_unit.size.x - 4, 1e-3);
    try std.testing.expectApproxEqAbs(36.6 + 4, box_unit.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(50, ctx.getUnitByIndex(plain_box).?.size.x - 4, 1e-3);
    // unbounded before sizing, it keeps its width
    try std.testing.expectApproxEqAbs(1000, ctx.getUnitByIndex(scroller + 1).?.size.x, 1e-3);
}

test "Context.computeLayout fit container with max constraint respects overflow" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 400),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.fit(.{ .min = 0, .max = 100 }),
                .height = Sizing.Dimension.fit(.{ .min = 0, .max = 80 }),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(Vec2.init(300, 200), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(100, container_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(80, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(100, content_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(80, content_unit.size.y, 1e-3);
    try std.testing.expect(content_unit.size.x <= container_unit.size.x);
    try std.testing.expect(content_unit.size.y <= container_unit.size.y);
}

test "Context.computeLayout grow container with max constraint respects overflow" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(400, 400),
        .axis = .x,
    });

    const container_idx = try ctx.openContainer(.{
        .layout = .{
            .sizing = .{
                .width = Sizing.Dimension.grow(.{ .min = 0, .max = 120 }),
                .height = Sizing.Dimension.grow(.{ .min = 0, .max = 90 }),
            },
            .axis = .x,
        },
    });

    var content = TestContent.init(Vec2.init(300, 200), 1.0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const container_unit = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectApproxEqAbs(120, container_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(90, container_unit.size.y, 1e-3);

    const content_unit = ctx.getUnitByIndex(container_idx + 1).?;
    try std.testing.expectApproxEqAbs(120, content_unit.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(90, content_unit.size.y, 1e-3);
    try std.testing.expect(content_unit.size.x <= container_unit.size.x);
    try std.testing.expect(content_unit.size.y <= container_unit.size.y);
}

test "Unit.hovered excludes points outside rounded corners" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{
        .sizing = Sizing.fixedXY(200, 100),
        .axis = .x,
    });

    // radius 50 overflows the 40px height, so it is fitted down to 20 (a pill)
    const pill_idx = try ctx.openContainer(.{
        .layout = .{ .sizing = Sizing.fixedXY(100, 40) },
        .corner_radius = .uniform(50),
    });
    ctx.closeContainer(pill_idx);

    ctx.end();
    try ctx.computeLayout();

    const pill = ctx.getUnitByIndex(pill_idx).?;
    try std.testing.expectApproxEqAbs(0, pill.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(0, pill.bbox.y, 1e-3);

    // center and the straight edges between the corners
    try std.testing.expect(pill.hovered(Vec2.init(50, 20)));
    try std.testing.expect(pill.hovered(Vec2.init(50, 0)));
    try std.testing.expect(pill.hovered(Vec2.init(20, 1)));

    // inside the fitted radius 20, but outside the unfitted radius 50
    try std.testing.expect(pill.hovered(Vec2.init(6, 6)));

    // cut away by each rounded corner
    try std.testing.expect(!pill.hovered(Vec2.init(1, 1)));
    try std.testing.expect(!pill.hovered(Vec2.init(98, 1)));
    try std.testing.expect(!pill.hovered(Vec2.init(1, 38)));
    try std.testing.expect(!pill.hovered(Vec2.init(98, 38)));

    // outside the bounding box entirely
    try std.testing.expect(!pill.hovered(Vec2.init(150, 20)));
}

test "ContainerDeclaration.OverflowConfig.any is true when either axis isn't visible" {
    const Overflow = ContainerDeclaration.OverflowConfig;
    try std.testing.expect(!(Overflow{}).any());
    try std.testing.expect((Overflow{ .x = .hidden }).any());
    try std.testing.expect((Overflow{ .y = .{ .scroll = 10 } }).any());
}

test {
    std.testing.refAllDecls(@This());
}

test "Context.appendContentStringId parents the content" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(200, 100) });

    const container_idx = try ctx.openContainer(.{ .layout = .{ .padding = .all(5) } });
    var content = TestContent.init(Vec2.init(30, 20), 1.0);
    try ctx.appendContentStringId("label", &content.content);
    ctx.closeContainer(container_idx);

    ctx.end();
    try ctx.computeLayout();

    const label = ctx.getUnitByStringId("label").?;
    try std.testing.expectEqual(container_idx, label.parent);

    // the fit container sizes around its content, so the content is one of its children
    const container = ctx.getUnitByIndex(container_idx).?;
    try std.testing.expectEqualSlices(usize, &.{container_idx + 1}, container.children.items);
    try std.testing.expectApproxEqAbs(40, container.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(30, container.size.y, 1e-3);
    try std.testing.expectApproxEqAbs(5, label.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(5, label.bbox.y, 1e-3);
}

test "Context.hoveredUnits yields hovered units topmost first" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 4, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(200, 100) });

    const pill_idx = try ctx.openContainer(.{
        .layout = .{ .sizing = Sizing.fixedXY(100, 40), .child_alignment = .center },
        .corner_radius = .uniform(20),
    });
    // fills the pill's width, but stays a 10px strip through its middle
    var content = TestContent.init(Vec2.init(10, 10), 0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(pill_idx);

    ctx.end();
    try ctx.computeLayout();

    // center: content, then the pill, then the root
    var center = ctx.hoveredUnits(Vec2.init(50, 20));
    try std.testing.expectEqual(ctx.getUnitByIndex(pill_idx + 1).?, center.next().?);
    try std.testing.expectEqual(ctx.getUnitByIndex(pill_idx).?, center.next().?);
    try std.testing.expectEqual(ctx.getUnitByIndex(0).?, center.next().?);
    try std.testing.expectEqual(null, center.next());
    try std.testing.expectEqual(null, center.next());

    // a point cut away by the pill's rounded corner only hits the root
    var corner = ctx.hoveredUnits(Vec2.init(1, 1));
    try std.testing.expectEqual(ctx.getUnitByIndex(0).?, corner.next().?);
    try std.testing.expectEqual(null, corner.next());
}

test "Context.computeLayout keeps floating units out of the flow" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 300) });

    const row_idx = try ctx.openContainer(.{ .layout = .{ .padding = .all(10), .child_gap = 10 } });

    const first_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(50, 20) } });
    ctx.closeContainer(first_idx);

    // a tooltip below the row's bottom right corner, overlapping nothing in the flow
    const tooltip_idx = try ctx.openContainer(.{
        .layout = .{ .sizing = Sizing.fixedXY(80, 30) },
        .floating = .{
            .mode = .parent,
            .parent_point = .right_bottom,
            .unit_point = .right_top,
            .offset = .init(0, 4),
        },
    });
    ctx.closeContainer(tooltip_idx);

    const second_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(20) } } });
    ctx.closeContainer(second_idx);

    ctx.closeContainer(row_idx);
    ctx.end();
    try ctx.computeLayout();

    // the row fits the two flow children and one gap, not the 80px tooltip
    const row = ctx.getUnitByIndex(row_idx).?;
    try std.testing.expectApproxEqAbs(80, row.size.x, 1e-3);
    try std.testing.expectApproxEqAbs(40, row.size.y, 1e-3);

    // nor does the tooltip push the second child along
    const second = ctx.getUnitByIndex(second_idx).?;
    try std.testing.expectApproxEqAbs(70, second.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(0, second.size.x, 1e-3);

    const tooltip = ctx.getUnitByIndex(tooltip_idx).?;
    try std.testing.expectEqual(Rect.init(0, 44, 80, 30), tooltip.bbox);
}

test "Context.computeLayout floats root-attached overlays over the viewport" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 300), .padding = .all(20) });

    const page_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .grow(.{}) } });

    // declared deep in the tree, but attached to the root
    const backdrop_idx = try ctx.openContainer(.{
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
        .floating = .{ .mode = .root },
    });
    const dialog_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(200, 100), .padding = .all(10) } });
    var content = TestContent.init(Vec2.init(50, 20), 0);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(dialog_idx);
    ctx.closeContainer(backdrop_idx);

    ctx.closeContainer(page_idx);
    ctx.end();
    try ctx.computeLayout();

    try std.testing.expectEqual(Rect.init(20, 20, 360, 260), ctx.getUnitByIndex(page_idx).?.bbox);

    // grow fills the root rather than the padded parent
    try std.testing.expectEqual(Rect.init(0, 0, 400, 300), ctx.getUnitByIndex(backdrop_idx).?.bbox);

    // and the subtree is laid out inside the floating box
    try std.testing.expectEqual(Rect.init(100, 100, 200, 100), ctx.getUnitByIndex(dialog_idx).?.bbox);
    const label = ctx.getUnitByIndex(dialog_idx + 1).?;
    try std.testing.expectApproxEqAbs(110, label.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(110, label.bbox.y, 1e-3);
}

test "Context.computeLayout attaches floating units by ID" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 300), .child_alignment = .center });

    const anchor_idx = try ctx.openContainerId(.fromString("anchor"), .{ .layout = .{ .sizing = Sizing.fixedXY(100, 40) } });
    ctx.closeContainer(anchor_idx);

    const menu_idx = try ctx.openContainer(.{
        .layout = .{ .sizing = .{ .width = .percent(0.5), .height = .fixed(60) } },
        .floating = .{
            .mode = .unit_id,
            .parent = .{ .id = Unit.Id.fromString("anchor").id },
            .parent_point = .center_bottom,
            .unit_point = .center_top,
        },
    });
    ctx.closeContainer(menu_idx);

    const missing_idx = try ctx.openContainer(.{ .floating = .{ .mode = .unit_id, .parent = .{ .id = 12345 } } });
    ctx.closeContainer(missing_idx);

    ctx.end();
    try std.testing.expectError(error.FloatingTargetNotFound, ctx.computeLayout());

    // the anchor sits in the flow alone, centered in the root
    try std.testing.expectEqual(Rect.init(150, 130, 100, 40), ctx.getUnitByIndex(anchor_idx).?.bbox);
    // the menu is half as wide as the anchor and hangs below its center
    try std.testing.expectEqual(Rect.init(175, 170, 50, 60), ctx.getUnitByIndex(menu_idx).?.bbox);
}

test "Context.computeLayout applies percent sizes once, against the parent's inner size" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(800, 700), .axis = .y });

    // a progress bar: a grow track with a 30% fill, along the track's axis
    const track_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(4) } } });
    const fill_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .percent(0.3), .height = .grow(.{}) } } });
    ctx.closeContainer(fill_idx);
    ctx.closeContainer(track_idx);

    // the same inside padding, where the inner size is what counts
    const padded_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .padding = .all(16) } });
    const inner_track_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(4) } } });
    const inner_fill_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .percent(0.3), .height = .grow(.{}) } } });
    ctx.closeContainer(inner_fill_idx);
    ctx.closeContainer(inner_track_idx);
    ctx.closeContainer(padded_idx);

    // and across a row's axis: half of a fixed-height row
    const row_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(100) } } });
    const half_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .percent(0.5) } } });
    ctx.closeContainer(half_idx);
    ctx.closeContainer(row_idx);

    ctx.end();
    try ctx.computeLayout();

    try std.testing.expectEqual(Rect.init(0, 0, 800, 4), ctx.getUnitByIndex(track_idx).?.bbox);
    try std.testing.expectApproxEqAbs(240, ctx.getUnitByIndex(fill_idx).?.bbox.w, 1e-3);
    try std.testing.expectEqual(4, ctx.getUnitByIndex(fill_idx).?.bbox.h);

    try std.testing.expectEqual(768, ctx.getUnitByIndex(inner_track_idx).?.bbox.w);
    try std.testing.expectApproxEqAbs(230.4, ctx.getUnitByIndex(inner_fill_idx).?.bbox.w, 1e-3);

    try std.testing.expectEqual(50, ctx.getUnitByIndex(half_idx).?.bbox.h);
}

test "Context.spacer pushes its siblings apart along the container's axis" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(300, 200), .axis = .y });

    const row_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 10 } });
    const a_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(50, 20) } });
    ctx.closeContainer(a_idx);
    try ctx.spacer();
    const b_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(40, 20) } });
    ctx.closeContainer(b_idx);
    const c_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(30, 20) } });
    ctx.closeContainer(c_idx);
    ctx.closeContainer(row_idx);

    // in a column, a spacer grows vertically and leaves the width alone
    try ctx.spacer();
    const footer_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(60, 30) } });
    ctx.closeContainer(footer_idx);

    ctx.end();
    try ctx.computeLayout();

    // the spacer takes what's left after the units and three gaps
    try std.testing.expectEqual(Rect.init(0, 0, 50, 20), ctx.getUnitByIndex(a_idx).?.bbox);
    try std.testing.expectEqual(Rect.init(60, 0, 150, 0), ctx.getUnitByIndex(a_idx + 1).?.bbox);
    try std.testing.expectEqual(Rect.init(220, 0, 40, 20), ctx.getUnitByIndex(b_idx).?.bbox);
    try std.testing.expectEqual(Rect.init(270, 0, 30, 20), ctx.getUnitByIndex(c_idx).?.bbox);

    try std.testing.expectEqual(Rect.init(0, 20, 0, 150), ctx.getUnitByIndex(footer_idx - 1).?.bbox);
    try std.testing.expectEqual(Rect.init(0, 170, 60, 30), ctx.getUnitByIndex(footer_idx).?.bbox);
}

test "Context.computeLayout squeezes text with an ellipsis, and only when short of space" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    // 5.8 points per byte with the heuristic measurer at size 10
    const cut: text.Style = .{ .font_size = 10, .wrap_mode = .none, .overflow = .ellipsis_end };
    var squeezed: text.HeuristicContent = .init("abcdefghij", cut);
    var roomy: text.HeuristicContent = .init("abcdefghij", cut);
    var visible: text.HeuristicContent = .init("abcdefghij", cut.with(.{ .overflow = .visible }));

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 300), .axis = .y });

    const row_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    const before_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(40, 10) } });
    ctx.closeContainer(before_idx);
    // nested in a box that fits it, which has to shrink with it
    const box_idx = try ctx.openContainer(.{});
    try ctx.appendContent(&squeezed.content);
    ctx.closeContainer(box_idx);
    const after_idx = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(30, 10) } });
    ctx.closeContainer(after_idx);
    ctx.closeContainer(row_idx);

    // with room to spare, a fitting box keeps the text's full width
    const roomy_idx = try ctx.openContainer(.{});
    try ctx.appendContent(&roomy.content);
    ctx.closeContainer(roomy_idx);

    const narrow_idx = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .fixed(40) } } });
    try ctx.appendContent(&visible.content);
    ctx.closeContainer(narrow_idx);

    ctx.end();
    try ctx.computeLayout();

    const squeezed_unit = ctx.getUnitByIndex(box_idx + 1).?;
    try std.testing.expectApproxEqAbs(30, squeezed_unit.bbox.w, 1e-3);
    try std.testing.expectApproxEqAbs(40, squeezed_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(70, ctx.getUnitByIndex(after_idx).?.bbox.x, 1e-3);
    var lines = squeezed.lines(squeezed_unit.bbox.w);
    // two bytes and the three-byte ellipsis fit in 30 points
    try std.testing.expectEqualStrings("ab" ++ text.ellipsis, (try lines.next()).?);

    try std.testing.expectApproxEqAbs(58, ctx.getUnitByIndex(roomy_idx).?.bbox.w, 1e-3);
    var roomy_lines = roomy.lines(ctx.getUnitByIndex(roomy_idx + 1).?.bbox.w);
    try std.testing.expectEqualStrings("abcdefghij", (try roomy_lines.next()).?);

    // without an ellipsis, text keeps its width and overflows
    try std.testing.expectApproxEqAbs(58, ctx.getUnitByIndex(narrow_idx + 1).?.bbox.w, 1e-3);
}

test {
    _ = renderer;
    _ = Damage;
}

test "Context.computeLayout records each container's content size, padding included" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 400) });
    const column = try ctx.openContainer(.{ .layout = .{ .axis = .y, .padding = .all(10), .child_gap = 5 } });
    var a = TestContent.init(.init(100, 20), 1.0);
    var b = TestContent.init(.init(60, 30), 1.0);
    try ctx.appendContent(&a.content);
    try ctx.appendContent(&b.content);
    ctx.closeContainer(column);
    const empty = try ctx.openContainer(.{ .layout = .{ .padding = .init(1, 2, 3, 4) } });
    ctx.closeContainer(empty);
    ctx.end();
    try ctx.computeLayout();

    // 10 + 100 + 10 wide; 10 + 20 + 5 + 30 + 10 tall
    try std.testing.expectEqual(Vec2.init(120, 75), ctx.getUnitByIndex(column).?.content_size);
    try std.testing.expectEqual(Vec2.init(3, 7), ctx.getUnitByIndex(empty).?.content_size);
}

/// Content that prefers `size` and accepts being squeezed to nothing.
const SqueezableContent = struct {
    content: Content = .{ .vtable = &.{
        .measure = measure,
        .measure_min = measureMin,
        .debug_name = "SqueezableContent",
    } },
    size: Vec2,

    fn measure(content_ptr: *Content, _: Constraints) Content.MeasureError!Vec2 {
        return @as(*SqueezableContent, @fieldParentPtr("content", content_ptr)).size;
    }

    fn measureMin(_: *Content, _: Constraints) Content.MeasureError!Vec2 {
        return .zero;
    }
};

test "Context.computeLayout lets content overflow a clipped axis, unsqueezed, as a scroll view needs" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(300, 200), .axis = .y });
    // a viewport that fills the window and scrolls vertically
    const viewport = try ctx.openContainer(.{
        .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(4) },
        .clip = .{ .vertical = true, .child_offset = .init(0, -50) },
    });
    var rows: [4]SqueezableContent = undefined;
    for (&rows) |*row| {
        // it could shrink to nothing if asked to
        row.* = .{ .size = .init(80, 100) };
        try ctx.appendContent(&row.content);
    }
    ctx.closeContainer(viewport);
    ctx.end();
    try ctx.computeLayout();

    const unit = ctx.getUnitByIndex(viewport).?;
    // the viewport takes the window, not its content's height
    try std.testing.expectEqual(Rect.init(0, 0, 300, 200), unit.bbox);
    // the rows keep their heights, one after the other, moved by the offset
    for (unit.children.items, 0..) |child_index, i| {
        const row = ctx.get(child_index);
        try std.testing.expectApproxEqAbs(100, row.bbox.h, 1e-3);
        try std.testing.expectApproxEqAbs(4 - 50 + 100 * @as(f32, @floatFromInt(i)), row.bbox.y, 1e-3);
    }
    // and the content is as tall as all of them
    try std.testing.expectEqual(Vec2.init(88, 408), unit.content_size);
}

test "Context.computeLayout still squeezes children along an axis that isn't clipped" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 8 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(300, 200), .axis = .y });
    const viewport = try ctx.openContainer(.{
        .layout = .{ .sizing = .grow(.{}), .axis = .y },
        .clip = .{ .horizontal = true },
    });
    var rows: [4]SqueezableContent = undefined;
    for (&rows) |*row| {
        row.* = .{ .size = .init(80, 100) };
        try ctx.appendContent(&row.content);
    }
    ctx.closeContainer(viewport);
    ctx.end();
    try ctx.computeLayout();

    const unit = ctx.getUnitByIndex(viewport).?;
    var total: f32 = 0;
    for (unit.children.items) |child_index| total += ctx.get(child_index).bbox.h;
    try std.testing.expectApproxEqAbs(200, total, 1e-3);
}

test "Context.openContainer and appendContent fail with LayoutCapacity at a Config limit, leaving the layout usable" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 6, .breadth = 2, .depth = 3 });
    defer ctx.deinit(std.testing.allocator);
    const Text = text.HeuristicContent;
    var content = Text.init("x", .{});

    // breadth: a third child of the root (logged outside tests, as every limit is)
    ctx.begin(.{ .sizing = .fixedXY(100, 100) });
    ctx.closeContainer(try ctx.openContainer(.{}));
    ctx.closeContainer(try ctx.openContainer(.{}));
    try std.testing.expectError(error.LayoutCapacity, ctx.openContainer(.{}));
    try std.testing.expectError(error.LayoutCapacity, ctx.appendContent(&content.content));
    try std.testing.expectEqual(3, ctx.units.items.len);
    ctx.end();
    try ctx.computeLayout();

    // depth: the root and two more fill the stack
    ctx.begin(.{ .sizing = .fixedXY(100, 100) });
    const a = try ctx.openContainer(.{});
    const b = try ctx.openContainer(.{});
    try std.testing.expectError(error.LayoutCapacity, ctx.openContainer(.{}));
    try ctx.appendContent(&content.content);
    ctx.closeContainer(b);
    ctx.closeContainer(a);
    ctx.end();

    // units: six in all
    ctx.begin(.{ .sizing = .fixedXY(100, 100) });
    const c = try ctx.openContainer(.{});
    const d = try ctx.openContainer(.{});
    try ctx.appendContent(&content.content);
    try ctx.appendContent(&content.content);
    ctx.closeContainer(d);
    const e = try ctx.openContainer(.{});
    try std.testing.expectError(error.LayoutCapacity, ctx.appendContent(&content.content));
    ctx.closeContainer(e);
    ctx.closeContainer(c);
    ctx.end();
    try ctx.computeLayout();
    try std.testing.expectEqual(6, ctx.units.items.len);
}
