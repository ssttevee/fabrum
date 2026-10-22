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

/// Borrowed bitmap content shared by renderers that support images.
pub const Image = @import("layout/image.zig");

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
    /// Reserved; container IDs come from `Context.openContainerId`.
    id: []const u8 = "",

    /// Controls various settings that affect the size and position of an unit, as well as the sizes and positions of any child units.
    layout: Config = .{},

    /// Controls the background color of the resulting unit.
    /// Channels are 0-255. A nontransparent color emits a `rectangle` command
    /// before the children, independently of the other declaration fields.
    background_color: Color = .transparent,

    /// Controls the "radius", or corner rounding of units, including rectangles, borders and images.
    corner_radius: CornerRadius = .{},

    /// Controls settings related to aspect ratio scaling.
    aspect_ratio: AspectRatioConfig = .{},

    /// Takes a unit out of its parent's flow and attaches it to another box.
    /// Paint order remains tree order; see `FloatingConfig`.
    floating: FloatingConfig = .{},

    /// Controls whether an unit should clip its contents, as well as providing child x,y offset configuration for scrolling.
    clip: ClipConfig = .{},

    /// Controls settings related to unit borders, and will generate BORDER render commands.
    border: BorderConfig = .{},

    /// Reserved; has no effect. Use `clip` for clipping and child offsets.
    overflow: OverflowConfig = .{},

    /// Stored on the declaration; not carried by render commands.
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

        /// Reserved; pointer passthrough is not implemented.
        pointer_passthrough: bool = false,

        /// Reserved; clipping to the attachment target is not implemented.
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

            pub const center_left = AttachPoint.left_center;
            pub const center = AttachPoint.center_center;
            pub const center_right = AttachPoint.right_center;

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

    /// Clips children per axis and offsets them. The caller owns the scroll
    /// offset; this layout API does not handle input.
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

    /// Reserved overflow settings; not applied by layout or render commands.
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
    /// How far up the tree the width and height limits it is first
    /// measured under come from, before sizing: its parent's own bounds
    /// (a fixed size or a finite maximum), or the nearest bounded
    /// ancestor's, looking through parents that fit or grow without a
    /// bound. That measurement is the width the content asks for; once
    /// widths are settled, content that got less, or more than its limit,
    /// is measured again at its final width, and the heights follow from
    /// that. Content that wraps, such as text or a native label, asks for
    /// `ancestors`, so that it asks for no more than the width it can get
    /// and a container that fits it stays within its ancestor; content
    /// that fills its limit, such as a picture scaled to fit, keeps
    /// `parent`, since it would fill the ancestor otherwise.
    limit: Limit = .parent,

    pub const Limit = enum { parent, ancestors };

    pub const MeasureError = error{MeasureFailed};

    pub const VTable = struct {
        /// Measures content under optional width and height limits. Return
        /// `error.MeasureFailed` when the measurement cannot be made.
        measure: *const fn (self: *Content, constraints: Constraints) MeasureError!Vec2,
        /// Returns the smallest size the content accepts under
        /// `constraints`, if it can be squeezed below what `measure`
        /// returns, such as text that is cut with an ellipsis, or that
        /// wraps and so accepts any width down to its widest word.
        /// Containers shrink content towards this size when space runs
        /// short. Null means the content can't be squeezed. Called once,
        /// with the first `measure`, before sizing; content measured
        /// again at its final width keeps its minimum width, and is
        /// taken to be as squeezable in height as it was.
        measure_min: ?*const fn (self: *Content, constraints: Constraints) MeasureError!Vec2 = null,
        /// Called only by `Content.deinit`; the layout context borrows content
        /// and never calls this automatically.
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
    /// scratch buffer for `distributeMainAxis`: a size and a minimum per child
    dist_size_scratch_buf: []f32,
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

        /// Maximum breadth supported by the layout scratch buffers. Every
        /// explicit or default breadth must fit this limit; exceeding it
        /// asserts rather than returning `error.LayoutCapacity`.
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

        const rci_scratch_buf = try allocator.alloc(RenderCommand.Iterator.UnitTraversalState, config.getDepth());
        errdefer allocator.free(rci_scratch_buf);

        return .{
            .units = units,
            .ids = ids,
            .stack = stack,
            .ci_buf = ci_buf,
            .breadth = breadth,
            .dist_size_scratch_buf = dist_size_scratch_buf,
            .rci_scratch_buf = rci_scratch_buf,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.units.deinit(allocator);
        self.stack.deinit(allocator);
        self.ids.deinit(allocator);
        allocator.free(self.ci_buf);
        allocator.free(self.dist_size_scratch_buf);
        allocator.free(self.rci_scratch_buf);
        self.* = undefined;
    }

    fn maxBreadth(self: *const Self) usize {
        return self.dist_size_scratch_buf.len / 2;
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

    /// Starts a new layout with fixed width and height in `cfg.sizing`,
    /// supplied by the caller. Must be finished with a call to `end`.
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

    /// Iterates commands in paint order, borrowing the context's scratch
    /// buffer. Consume before creating another iterator; do not call the
    /// iterator's `deinit`, because the context owns its stack.
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
    /// text and native labels ask for no more than the width they can
    /// get. Ancestors that fit or grow without a bound are looked
    /// through, since they can't give their content more than their own
    /// ancestor allows; a container that scrolls along the axis ends the
    /// walk, as its content may be larger. Null means no limit is known.
    /// Siblings aren't counted: what the content gets once they have
    /// their share is settled by `sizeAxis`, which measures it again
    /// there (`remeasureAtWidth`).
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

    /// Measures every content under the limits it inherits and sizes
    /// every container to its children, bottom-up: the `size` each unit
    /// asks for along both axes, and the `min_size` it can be squeezed
    /// to. These are what `sizeAxis` distributes from.
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
                .container => {
                    // the smallest the children can be squeezed to, then the size they prefer
                    inline for (.{ "min_size", "size" }, .{ true, false }) |field, is_min| {
                        @field(unit, field) = .init(
                            self.fitAxis(unit, .x, field, is_min),
                            self.fitAxis(unit, .y, field, is_min),
                        );
                    }
                },
            }
        }
    }

    /// The size a container takes along `axis` from its children's
    /// `field` (`size` or `min_size`): their total along the container's
    /// own axis, gaps included, or the largest across it, plus the
    /// padding; at least the sizing's minimum and at most its maximum.
    /// On an axis whose overflow is clipped, the children can be larger
    /// than the container, so their minimums don't hold it open.
    fn fitAxis(self: *const Self, unit: *Unit, axis: Vec2.Axis, comptime field: []const u8, comptime is_min: bool) f32 {
        const container = unit.data.container;
        const cfg = container.layout;
        const from_children = if (is_min and clipsAxis(container.clip, axis))
            0
        else if (axis == cfg.axis)
            self.unitChildrenAnySizeTotal(unit, field, axis)
        else
            self.unitChildrenAnySizeMax(unit, field, axis);

        var size = @max(from_children + cfg.padding.sumAxis(axis), normalizeIntrinsicValue(cfg.sizing.intrinsic().axis(axis)));
        const dim = cfg.sizing.axisDimension(axis);
        switch (dim.mode) {
            .fixed => size = @min(size, dim.value.number),
            .fit, .grow => size = @min(size, dim.value.range.max),
            .percent => {},
        }
        return size;
    }

    const Direction = enum { shrink, grow };

    /// How far the child at `child_index` can move along `axis` in
    /// `direction`: down to its minimum, or up to its maximum, which is
    /// the container's inner size when it has none. Zero for children
    /// that don't move that way: floating ones, fixed and percent sizes
    /// when shrinking, anything but grow when growing.
    fn mainAxisRoom(self: *const Self, child_index: usize, axis: Vec2.Axis, direction: Direction, size: f32, min: f32, inner_main: f32) f32 {
        const child = self.get(child_index);
        if (child.isFloating()) return 0;
        const dim = child.config().sizing.axisDimension(axis);
        return switch (direction) {
            .shrink => if (dim.mode == .fixed or dim.mode == .percent) 0 else size - min,
            .grow => if (dim.mode != .grow) 0 else @max((if (std.math.isFinite(dim.value.range.max)) dim.value.range.max else inner_main) - size, 0),
        };
    }

    /// Shrinks or grows the children's `sizes` along the main axis, each
    /// by its share of the room it has (`mainAxisRoom`), until they fill
    /// `inner_main` less the gaps, or no child has room left. Returns the
    /// space the children then take, gaps included.
    fn distributeMainAxis(
        self: *const Self,
        unit: *Unit,
        axis: Vec2.Axis,
        inner_main: f32,
        sizes: []f32,
        mins: []const f32,
        gap_total: f32,
    ) f32 {
        const epsilon: f32 = 1e-4;
        const children = unit.children.items;
        if (children.len == 0) return gap_total;

        var total: f32 = 0;
        for (sizes) |s| total += s;

        if (!std.math.isFinite(inner_main)) {
            return total + gap_total;
        }

        const target = @max(inner_main - gap_total, 0);

        // overflow along a clipped axis stays: the children keep their sizes
        const clipped = unit.data == .container and clipsAxis(unit.data.container.clip, axis);

        const direction: Direction = if (total > target + epsilon and !clipped)
            .shrink
        else if (total < target - epsilon)
            .grow
        else
            return total + gap_total;

        while (true) {
            const wanted = switch (direction) {
                .shrink => total - target,
                .grow => target - total,
            };
            if (wanted <= epsilon) break;

            var room: f32 = 0;
            for (children, sizes, mins) |child_index, size, min| {
                room += self.mainAxisRoom(child_index, axis, direction, size, min, inner_main);
            }
            if (room <= epsilon) break;

            var moved: f32 = 0;
            for (children, sizes, mins) |child_index, *size, min| {
                const cap = self.mainAxisRoom(child_index, axis, direction, size.*, min, inner_main);
                if (cap <= epsilon) continue;
                const delta = @min(wanted * (cap / room), cap);
                size.* = switch (direction) {
                    .shrink => size.* - delta,
                    .grow => size.* + delta,
                };
                moved += delta;
            }
            if (moved <= epsilon) break;
            total = switch (direction) {
                .shrink => total - moved,
                .grow => total + moved,
            };
        }

        return total + gap_total;
    }

    /// Gives every unit under `index` its final size along `axis`, top
    /// down: the subtree's root is clamped by its sizing against
    /// `available`, the room it is offered, then each container sizes its
    /// children (`sizeChildrenAxis`). Widths go first, measuring content
    /// again where its width turned out differently; heights follow, once
    /// `fitHeights` has let the containers take the heights that come of
    /// that.
    fn sizeAxis(self: *const Self, index: usize, axis: Vec2.Axis, available: f32) !void {
        const unit = self.get(index);
        if (unit.data != .container) return;
        const cfg = unit.data.container.layout;
        const dim = cfg.sizing.axisDimension(axis);
        const size = @max(dim.clamp(unit.size.axis(axis), available), unit.min_size.axis(axis));
        unit.size = vecAxisSwap(size, unit.size.axis(axis.cross()), axis);
        try self.sizeChildrenAxis(index, axis);
    }

    /// Sizes the children of the container at `index` along `axis`, from
    /// the sizes they ask for, then their own children. Along the
    /// container's axis, the children share its inner size
    /// (`distributeMainAxis`); across it, growing children fill it, and
    /// the rest keep what they ask for, clamped to it. Floating children
    /// take nothing here: `layoutFloating` sizes them against the unit
    /// they attach to.
    ///
    /// The children's heights depend on their widths, so along y a
    /// container with an aspect ratio settles its own box first: the
    /// smaller of its two sizes rules, and if that narrows it, its
    /// children are sized across again at the narrower width.
    fn sizeChildrenAxis(self: *const Self, index: usize, axis: Vec2.Axis) !void {
        const unit = self.get(index);
        const container = unit.data.container;
        const cfg = container.layout;

        if (axis == .y and container.aspect_ratio.aspect_ratio > 0 and unit.size.x > 0 and unit.size.y > 0) {
            const ratio = container.aspect_ratio.aspect_ratio;
            if (unit.size.x / ratio > unit.size.y) {
                unit.size.x = unit.size.y * ratio;
                try self.sizeChildrenAxis(index, .x);
                self.fitHeights(index);
            } else {
                unit.size.y = unit.size.x / ratio;
            }
        }

        const children = unit.children.items;
        if (children.len == 0) return;
        const inner = @max(unit.size.axis(axis) - cfg.padding.sumAxis(axis), 0);

        if (axis == cfg.axis) {
            const scratch = self.dist_size_scratch_buf[0 .. children.len * 2];
            const sizes = scratch[0..children.len];
            const mins = scratch[children.len .. children.len * 2];

            for (children, sizes, mins) |child_index, *size, *min| {
                const child = self.get(child_index);
                if (child.isFloating()) {
                    size.* = 0;
                    min.* = 0;
                    continue;
                }
                const dim = child.config().sizing.axisDimension(axis);
                min.* = child.min_size.axis(axis);
                size.* = @max(dim.clamp(child.size.axis(axis), inner), min.*);
            }

            const flow_count = self.flowChildCount(children);
            const gap_total: f32 = if (flow_count > 1)
                cfg.child_gap * @as(f32, @floatFromInt(flow_count - 1))
            else
                0;
            _ = self.distributeMainAxis(unit, axis, inner, sizes, mins, gap_total);

            // the scratch buffer is consumed before any child sizes its own children
            for (children, sizes) |child_index, size| {
                const child = self.get(child_index);
                if (!child.isFloating()) try self.setSizeAxis(child, axis, size);
            }
        } else {
            for (children) |child_index| {
                const child = self.get(child_index);
                if (child.isFloating()) continue;
                const dim = child.config().sizing.axisDimension(axis);
                var size = child.size.axis(axis);
                switch (dim.mode) {
                    .fixed, .percent => size = dim.clamp(size, inner),
                    .grow => {
                        const range = dim.value.range;
                        size = std.math.clamp(if (std.math.isFinite(inner)) inner else size, range.min, range.max);
                    },
                    .fit => {
                        const range = dim.value.range;
                        // across a clipped axis, children may overflow
                        const max_size = if (std.math.isFinite(inner) and !clipsAxis(container.clip, axis)) inner else range.max;
                        size = std.math.clamp(size, range.min, @min(range.max, max_size));
                    },
                }
                try self.setSizeAxis(child, axis, @max(size, child.min_size.axis(axis)));
            }
        }

        for (children) |child_index| {
            const child = self.get(child_index);
            if (child.data == .container and !child.isFloating()) {
                try self.sizeChildrenAxis(child_index, axis);
            }
        }
    }

    /// Sets a child's final size along `axis`, measuring content again
    /// at a width it hadn't been measured for.
    fn setSizeAxis(self: *const Self, child: *Unit, axis: Vec2.Axis, size: f32) !void {
        if (axis == .x and child.data == .content) {
            try self.remeasureAtWidth(child, size);
        } else {
            child.size = vecAxisSwap(size, child.size.axis(axis.cross()), axis);
        }
    }

    /// Gives a content its final `width`, and the height it has there. It
    /// is measured again only when the width is outside what its first
    /// measurement holds for: narrower than the width it took, so what
    /// wraps gets taller, or wider than the limit it was measured under,
    /// so it may get shorter. Given anything from the width it took up to
    /// that limit, it would measure the same, so it keeps its height.
    fn remeasureAtWidth(self: *const Self, unit: *Unit, width: f32) !void {
        const content = unit.data.content;
        const taken = unit.size.x;
        unit.size.x = width;
        const limit = self.inheritedLimit(unit, .x, content.limit) orelse std.math.inf(f32);
        if (width >= taken and width <= limit) return;

        const measured = try content.measure(.{
            .max_width = width,
            .max_height = self.inheritedLimit(unit, .y, content.limit),
        });
        // the height it can be squeezed to follows its height: content
        // that couldn't be squeezed below its height still can't, and
        // content that could keeps its minimum
        const squeezable = unit.min_size.y < unit.size.y;
        unit.size.y = measured.y;
        unit.min_size.y = if (squeezable) @min(unit.min_size.y, measured.y) else measured.y;
    }

    /// Sizes the containers under `index` to their children along y
    /// again, bottom-up, once every content has the height it has at its
    /// final width: a row that fits text which wrapped grows with it, and
    /// so does whatever fits the row. The unit at `index` itself keeps its
    /// height, which `layoutFloating` may have given it.
    fn fitHeights(self: *const Self, index: usize) void {
        const unit = self.get(index);
        if (unit.data != .container) return;
        for (unit.children.items) |child_index| {
            const child = self.get(child_index);
            if (child.data != .container or child.isFloating()) continue;
            self.fitHeights(child_index);
            child.min_size.y = self.fitAxis(child, .y, "min_size", true);
            child.size.y = self.fitAxis(child, .y, "size", false);
        }
    }

    /// Places the unit at `index` with its top left at `origin`, and its
    /// children in order along its axis after the padding, `child_gap`
    /// apart, aligned in the leftover space by `child_alignment` and moved
    /// by the clip's `child_offset`; then records its `content_size`.
    fn placeUnit(self: *const Self, index: usize, origin: Vec2) void {
        const unit = self.get(index);
        unit.bbox = Rect.init(origin.x, origin.y, unit.size.x, unit.size.y);
        if (unit.data != .container) return;

        const container = unit.data.container;
        const cfg = container.layout;
        const axis = cfg.axis;
        const cross = axis.cross();

        const padding_vec = cfg.padding.toVec();
        var inner_size = unit.size.sub(padding_vec);
        if (inner_size.x < 0) inner_size.x = 0;
        if (inner_size.y < 0) inner_size.y = 0;

        const inner_origin = origin
            .add(cfg.padding.topLeft())
            .add(container.clip.child_offset);

        unit.content_size = padding_vec;
        const children = unit.children.items;
        if (children.len == 0) return;

        const used_main = self.childrenAnySizeTotal(children, cfg.child_gap, "size", axis);
        const main_align = cfg.child_alignment.axis(axis);
        const cross_align = cfg.child_alignment.axis(cross);
        var current_main = inner_origin.axis(axis) + alignmentOffset(main_align, inner_size.axis(axis) - used_main);

        // the children's extent, from the content's top left
        var far = Vec2.zero;
        for (children) |child_index| {
            const child = self.get(child_index);
            // placed by `layoutFloating`, taking no space here
            if (child.isFloating()) continue;

            var cross_space = inner_size.axis(cross) - child.size.axis(cross);
            if (!std.math.isFinite(cross_space) or cross_space < 0) {
                cross_space = 0;
            }
            const child_cross_pos = inner_origin.axis(cross) + alignmentOffset(cross_align, cross_space);
            self.placeUnit(child_index, vecAxisSwap(current_main, child_cross_pos, axis));

            far.x = @max(far.x, child.bbox.x + child.bbox.w - inner_origin.x);
            far.y = @max(far.y, child.bbox.y + child.bbox.h - inner_origin.y);
            current_main += child.size.axis(axis) + cfg.child_gap;
        }
        unit.content_size = far.add(padding_vec);
    }

    /// Sizes and places the units under `index`, whose own box is offered
    /// `available` by what holds it, from the sizes `computeIntrinsicSizes`
    /// found: widths first, top down, measuring content again where its
    /// width turned out differently; then the heights that come of that,
    /// bottom up through the containers that fit; then heights top down;
    /// then positions. Widths go first because wrapping content's height
    /// depends on its width.
    fn layoutSubtree(self: *const Self, index: usize, origin: Vec2, available: Vec2) !void {
        try self.sizeAxis(index, .x, available.x);
        self.fitHeights(index);
        try self.sizeAxis(index, .y, available.y);
        self.placeUnit(index, origin);
    }

    /// Sizes widths before heights, then positions units and floating
    /// subtrees. Call once after `end` for each layout. Can fail with
    /// `error.MeasureFailed` or `error.FloatingTargetNotFound`.
    pub fn computeLayout(self: *const Self) !void {
        std.debug.assert(self.stack.items.len == 0);
        std.debug.assert(self.units.items.len > 0);
        std.debug.assert(self.units.items[0].size.isZero());

        try self.computeIntrinsicSizes();

        const root_size = self.get(0).size;
        try self.layoutSubtree(0, Vec2.zero, root_size);
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
            try self.layoutSubtree(index, origin, available);
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

test "FloatingConfig.AttachPoint aliases name the matching points" {
    const AttachPoint = ContainerDeclaration.FloatingConfig.AttachPoint;
    try std.testing.expectEqual(AttachPoint.left_top, AttachPoint.top_left);
    try std.testing.expectEqual(AttachPoint.center_top, AttachPoint.top_center);
    try std.testing.expectEqual(AttachPoint.right_top, AttachPoint.top_right);
    try std.testing.expectEqual(AttachPoint.left_center, AttachPoint.center_left);
    try std.testing.expectEqual(AttachPoint.center_center, AttachPoint.center);
    try std.testing.expectEqual(AttachPoint.right_center, AttachPoint.center_right);
    try std.testing.expectEqual(AttachPoint.left_bottom, AttachPoint.bottom_left);
    try std.testing.expectEqual(AttachPoint.center_bottom, AttachPoint.bottom_center);
    try std.testing.expectEqual(AttachPoint.right_bottom, AttachPoint.bottom_right);
}

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

test "Context.computeLayout centers container and measures content once at the width it holds" {
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

    // measured under its parent's fixed width and given just that, it
    // isn't measured again; the height is unbounded, as the parent fits
    try std.testing.expectEqual(@as(usize, 1), content.call_count);
    try std.testing.expect(content.last_constraints.max_width != null);
    try std.testing.expectApproxEqAbs(60, content.last_constraints.max_width.?, 1e-3);
    try std.testing.expectEqual(null, content.last_constraints.max_height);
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

/// Content that wraps like text: `length` of ink, in as many lines of
/// 10 as the width it is given takes, and squeezable to its widest
/// `word`. Counts how often it is measured.
const WrappingContent = struct {
    content: Content = .{ .vtable = &.{
        .measure = measure,
        .measure_min = measureMin,
        .debug_name = "WrappingContent",
    }, .limit = .ancestors },
    length: f32,
    word: f32 = 30,
    measures: usize = 0,

    fn size(self: *const WrappingContent, constraints: Constraints) Vec2 {
        const width = @min(self.length, constraints.max_width orelse self.length);
        return .init(width, @ceil(self.length / width) * 10);
    }

    fn measure(content_ptr: *Content, constraints: Constraints) Content.MeasureError!Vec2 {
        const self: *WrappingContent = @fieldParentPtr("content", content_ptr);
        self.measures += 1;
        return self.size(constraints);
    }

    fn measureMin(content_ptr: *Content, constraints: Constraints) Content.MeasureError!Vec2 {
        const self: *WrappingContent = @fieldParentPtr("content", content_ptr);
        return .init(self.word, self.size(constraints).y);
    }
};

test "Context.computeLayout wraps content at the width its row siblings leave it, and the row grows with it" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 16, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 400), .axis = .y });
    // a row of a box and content that asks for the root's width, which the box takes part of
    const row = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
    ctx.closeContainer(try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(100, 10) } }));
    var wrapped: WrappingContent = .{ .length = 3000 };
    try ctx.appendContent(&wrapped.content);
    ctx.closeContainer(row);
    const below = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(10, 10) } });
    ctx.closeContainer(below);
    // in a column with room to spare, content keeps its first measurement
    const column = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .axis = .y } });
    var roomy: WrappingContent = .{ .length = 200 };
    try ctx.appendContent(&roomy.content);
    ctx.closeContainer(column);
    ctx.end();
    try ctx.computeLayout();

    // measured under the root's 400, it gets the 300 the box leaves: ten lines, not eight
    try std.testing.expectEqual(Rect.init(100, 0, 300, 100), ctx.getUnitByIndex(row + 2).?.bbox);
    // and the row, which fits it, is as tall, pushing what follows down
    try std.testing.expectEqual(Rect.init(0, 0, 400, 100), ctx.getUnitByIndex(row).?.bbox);
    try std.testing.expectEqual(Rect.init(0, 100, 10, 10), ctx.getUnitByIndex(below).?.bbox);
    // once under the limit, once at its own width
    try std.testing.expectEqual(2, wrapped.measures);

    try std.testing.expectEqual(Rect.init(0, 110, 200, 10), ctx.getUnitByIndex(column + 1).?.bbox);
    try std.testing.expectEqual(1, roomy.measures);
}

test "Context.computeLayout wraps two texts in growing boxes that share a row" {
    var ctx = try Context.init(std.testing.allocator, .{ .units = 8, .max_breadth = 4 });
    defer ctx.deinit(std.testing.allocator);

    // eight words of four characters: 226.2 points on one line with the
    // heuristic measurer at size 10, 5.8 a character, 12 for the first
    // line and 14.4 for every other
    const style: text.Style = .{ .font_size = 10 };
    var left: text.HeuristicContent = .init("aaaa bbbb cccc dddd eeee ffff gggg hhhh", style);
    var right: text.HeuristicContent = .init("iiii jjjj kkkk llll mmmm nnnn oooo pppp", style);

    ctx.begin(.{ .sizing = Sizing.fixedXY(400, 300), .axis = .y });
    const row = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
    const left_box = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
    try ctx.appendContent(&left.content);
    ctx.closeContainer(left_box);
    const right_box = try ctx.openContainer(.{ .layout = .{ .sizing = .{ .width = .grow(.{}) } } });
    try ctx.appendContent(&right.content);
    ctx.closeContainer(right_box);
    ctx.closeContainer(row);
    const below = try ctx.openContainer(.{ .layout = .{ .sizing = Sizing.fixedXY(10, 10) } });
    ctx.closeContainer(below);
    ctx.end();
    try ctx.computeLayout();

    // the boxes share the row, and each text wraps at its box: seven words, then one
    const left_unit = ctx.getUnitByIndex(left_box + 1).?;
    const right_unit = ctx.getUnitByIndex(right_box + 1).?;
    try std.testing.expectApproxEqAbs(200, left_unit.bbox.w, 1e-3);
    try std.testing.expectApproxEqAbs(26.4, left_unit.bbox.h, 1e-3);
    try std.testing.expectApproxEqAbs(200, right_unit.bbox.x, 1e-3);
    try std.testing.expectApproxEqAbs(200, right_unit.bbox.w, 1e-3);
    try std.testing.expectApproxEqAbs(26.4, right_unit.bbox.h, 1e-3);
    var lines = right.lines(right_unit.bbox.w);
    try std.testing.expectEqualStrings("iiii jjjj kkkk llll mmmm nnnn oooo", (try lines.next()).?);
    try std.testing.expectEqualStrings("pppp", (try lines.next()).?);
    // the row is two lines tall, and what follows comes after it
    try std.testing.expectApproxEqAbs(26.4, ctx.getUnitByIndex(row).?.bbox.h, 1e-3);
    try std.testing.expectApproxEqAbs(26.4, ctx.getUnitByIndex(below).?.bbox.y, 1e-3);
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
