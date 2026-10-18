//! Keeps native objects in step with the native elements views declare.
//!
//! Declarations are reconciled as views make them, so a native view exists
//! and shows its latest props by the time layout measures it. After layout,
//! `finish` moves the views whose boxes changed, builds the focus chain and
//! the canvas layers, hands the scene to the backend, and destroys what
//! wasn't declared.
//!
//! **Controlled values.** Each record remembers the value its control shows
//! as far as fabrum knows: what the control last reported, or what fabrum
//! last wrote. A declared value is written only when it differs from that,
//! so a model that echoes what the user typed never writes it back, and
//! the caret, selection and undo stack stay the control's. A write is held
//! back while the user is composing (IME marked text), and tried again on
//! the next frame, which the end of the composition asks for.
//!
//! **Native containers.** A record's parent is the native container it was
//! declared in, or none for the host. Its frame is set in its parent's
//! content coordinates: the layout lays a container's content out moved by
//! the scroll offset the platform last reported (`clip.child_offset`), so
//! that hit-testing works in the window's coordinates, and subtracting the
//! content's top left takes that out again. Frames inside a container
//! therefore don't change while it scrolls. Each container gets its content
//! size and its own slots and canvas layers in the scene. An element
//! declared in another container than last frame is moved there by the
//! backend (`Backend.reparent`), keeping its native object and state, or
//! remade there by a backend that can't move views.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const native = @import("native.zig");
const Id = native.Id;
const Handle = native.Handle;
const Spec = native.Spec;
const Value = native.Value;
const Scene = native.Scene;

pub const Reconciler = struct {
    backend: ?native.Backend = null,
    records: std.AutoArrayHashMapUnmanaged(Id, Record) = .empty,
    /// This frame's focusable elements, native and drawn, in paint order.
    chain: std.ArrayList(FocusEntry) = .empty,
    /// The last frame's scene, in the frame arena.
    scene: Scene = .{},
    /// Counts of backend calls, for tests of what reconciling costs.
    stats: Stats = .{},

    pub const Error = native.Backend.Error || error{ NoNativeBackend, DuplicateKey };

    pub const Stats = struct {
        creates: usize = 0,
        updates: usize = 0,
        destroys: usize = 0,
        frames: usize = 0,
        writes: usize = 0,
        held_writes: usize = 0,
        reparents: usize = 0,
    };

    pub const Record = struct {
        handle: Handle,
        /// The props last applied, owned.
        spec: Spec,
        /// What the control shows as far as fabrum knows, owned.
        shown: Value,
        handlers: native.Handlers,
        /// The layout unit of its box, or 0 for elements placed elsewhere.
        unit: u64,
        /// The frame last set, in its parent's coordinates.
        frame: ?Rect = null,
        seen: bool = true,
        /// The native container it is in, or null for the host.
        parent: ?Id = null,
        /// How many native containers it is in.
        depth: u32 = 0,
        /// For containers: the scroll offset the platform last reported,
        /// and the one this frame's layout used.
        scroll: Vec2 = .zero,
        laid_scroll: Vec2 = .zero,
        /// For containers: the content size last set.
        content: ?Vec2 = null,

        /// Notes a value the control reported.
        pub fn report(self: *Record, gpa: Allocator, value: Value) Allocator.Error!void {
            const copy = try value.clone(gpa);
            self.shown.free(gpa);
            self.shown = copy;
        }
    };

    /// One stop in the Tab order.
    pub const FocusEntry = struct {
        /// The element's layout unit: a native element's box, or a drawn
        /// focusable container.
        unit: u64,
        /// Set for native elements.
        native: ?Id = null,

        pub fn eql(a: FocusEntry, b: FocusEntry) bool {
            return a.unit == b.unit and a.native == b.native;
        }
    };

    pub fn deinit(self: *Reconciler, gpa: Allocator) void {
        // what is in a container before the container
        var deepest: u32 = 0;
        for (self.records.values()) |record| deepest = @max(deepest, record.depth);
        var depth = deepest + 1;
        while (depth > 0) {
            depth -= 1;
            for (self.records.values()) |*record| {
                if (record.depth != depth) continue;
                if (self.backend) |backend| backend.destroy(record.handle);
                record.spec.free(gpa);
                record.shown.free(gpa);
            }
        }
        self.records.deinit(gpa);
        self.chain.deinit(gpa);
        self.* = undefined;
    }

    /// Starts a frame: nothing is declared yet, and the last scene's memory
    /// is about to go.
    pub fn begin(self: *Reconciler) void {
        for (self.records.values()) |*record| record.seen = false;
        self.scene = .{};
    }

    /// Reconciles one declared element: creates its native object, or
    /// updates the one it has, and writes its value under the controlled
    /// rule. `parent` is the native container it is declared in, declared
    /// earlier in the frame, or null for the host.
    pub fn declare(self: *Reconciler, gpa: Allocator, id: Id, unit: u64, element: native.Element, parent: ?Id) Error!void {
        const backend = self.backend orelse return error.NoNativeBackend;
        const where: Place = if (parent) |p| blk: {
            const container = self.records.getPtr(p).?;
            break :blk .{ .parent = p, .handle = container.handle, .depth = container.depth + 1 };
        } else .{};
        const gop = try self.records.getOrPut(gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.create(gpa, backend, id, unit, element, where) catch |err| {
                _ = self.records.swapRemove(id);
                return err;
            };
            return;
        }

        const record = gop.value_ptr;
        if (record.seen) return error.DuplicateKey;

        if (!record.spec.sameKind(element.spec)) {
            // a different kind of control under the same key: replace it
            const replacement = try self.create(gpa, backend, id, unit, element, where);
            self.destroyRecord(gpa, record);
            record.* = replacement;
            return;
        }

        if (record.parent != where.parent) {
            // moved to another container: the backend moves the view, so
            // it keeps its state, or it is remade there
            if (backend.reparent(record.handle, where.handle)) {
                self.stats.reparents += 1;
                record.parent = where.parent;
                record.depth = where.depth;
                // in the new parent's coordinates
                record.frame = null;
            } else {
                const replacement = try self.create(gpa, backend, id, unit, element, where);
                self.destroyRecord(gpa, record);
                record.* = replacement;
                return;
            }
        }

        if (!record.spec.eql(element.spec)) {
            const spec = try element.spec.clone(gpa);
            backend.update(record.handle, &record.spec, &element.spec);
            self.stats.updates += 1;
            record.spec.free(gpa);
            record.spec = spec;
        }

        if (element.value != .none and !element.value.eql(record.shown)) {
            if (backend.composing(record.handle)) {
                self.stats.held_writes += 1;
            } else {
                const shown = try element.value.clone(gpa);
                backend.setValue(record.handle, &element.value);
                self.stats.writes += 1;
                record.shown.free(gpa);
                record.shown = shown;
            }
        }

        record.handlers = element.handlers;
        record.unit = unit;
        record.seen = true;
    }

    /// Where a record goes: the host, or a container.
    const Place = struct {
        parent: ?Id = null,
        handle: ?Handle = null,
        depth: u32 = 0,
    };

    fn create(self: *Reconciler, gpa: Allocator, backend: native.Backend, id: Id, unit: u64, element: native.Element, where: Place) Error!Record {
        const spec = try element.spec.clone(gpa);
        errdefer spec.free(gpa);
        const shown = try element.value.clone(gpa);
        errdefer shown.free(gpa);
        const handle = try backend.create(id, &element.spec, &element.value, where.handle);
        self.stats.creates += 1;
        return .{
            .handle = handle,
            .spec = spec,
            .shown = shown,
            .handlers = element.handlers,
            .unit = unit,
            .parent = where.parent,
            .depth = where.depth,
        };
    }

    /// The scroll offset to lay the container `id`'s content out with
    /// this frame: the one the platform last reported. Call after
    /// declaring it.
    pub fn layoutScroll(self: *Reconciler, id: Id) Vec2 {
        const record = self.records.getPtr(id) orelse return .zero;
        record.laid_scroll = record.scroll;
        return record.scroll;
    }

    /// The top left of the content of the container `parent`, in the
    /// layout's coordinates, as this frame laid it out; zero for the host.
    fn contentOrigin(self: *const Reconciler, context: *const layout.Context, parent: ?Id) Vec2 {
        const id = parent orelse return .zero;
        const record = self.records.getPtr(id) orelse return .zero;
        const unit = context.getUnitById(.fromInt(record.unit)) orelse return .zero;
        return Vec2.init(unit.bbox.x, unit.bbox.y).sub(record.laid_scroll);
    }

    fn destroyRecord(self: *Reconciler, gpa: Allocator, record: *Record) void {
        self.backend.?.destroy(record.handle);
        self.stats.destroys += 1;
        record.spec.free(gpa);
        record.shown.free(gpa);
    }

    /// The size the native view of `id` wants.
    pub fn measure(self: *Reconciler, id: Id, constraints: layout.Constraints) Vec2 {
        const record = self.records.getPtr(id) orelse return .zero;
        return self.backend.?.measure(record.handle, constraints);
    }

    /// Finishes a laid-out frame: frames, the focus chain, the scene, and
    /// destroying what wasn't declared. `focusable` holds the unit IDs of
    /// drawn focusable elements; `modal` is the index of the unit whose
    /// descendants alone make the chain, if any.
    pub fn finish(
        self: *Reconciler,
        gpa: Allocator,
        arena: Allocator,
        context: *const layout.Context,
        focusable: *const std.AutoHashMapUnmanaged(u64, void),
        modal: ?usize,
    ) Allocator.Error!void {
        const backend = self.backend orelse {
            // drawn elements only: just the focus chain
            try self.buildChain(gpa, context, focusable, modal);
            return;
        };

        // destroy first, so the scene never names a dead view, and what is
        // in a container before the container
        var gone: std.ArrayList(Gone) = .empty;
        for (self.records.keys(), self.records.values()) |id, record| {
            if (!record.seen) try gone.append(arena, .{ .id = id, .depth = record.depth });
        }
        std.mem.sort(Gone, gone.items, {}, Gone.deeperFirst);
        for (gone.items) |entry| {
            var removed = self.records.fetchSwapRemove(entry.id).?;
            self.destroyRecord(gpa, &removed.value);
        }

        for (self.records.values()) |*record| {
            if (record.unit == 0) continue;
            const unit = context.getUnitById(.fromInt(record.unit)) orelse continue;
            const frame: Rect = if (record.parent == null) unit.bbox else blk: {
                // the scroll offset is in both the box and the origin;
                // snapping takes out the rounding left when it cancels, so
                // scrolling moves nothing
                const origin = self.contentOrigin(context, record.parent);
                break :blk .init(snap(unit.bbox.x - origin.x), snap(unit.bbox.y - origin.y), unit.bbox.w, unit.bbox.h);
            };
            if (record.frame == null or !std.meta.eql(record.frame.?, frame)) {
                backend.setFrame(record.handle, frame);
                self.stats.frames += 1;
                record.frame = frame;
            }
            const content: Vec2 = .init(snap(unit.content_size.x), snap(unit.content_size.y));
            if (record.spec.isContainer() and (record.content == null or !record.content.?.eql(content))) {
                backend.setContentSize(record.handle, content);
                self.stats.frames += 1;
                record.content = content;
            }
        }

        try self.buildChain(gpa, context, focusable, modal);
        self.scene = try self.split(arena, context);
        backend.present(&self.scene);
    }

    const Gone = struct {
        id: Id,
        depth: u32,

        fn deeperFirst(_: void, a: Gone, b: Gone) bool {
            return a.depth > b.depth;
        }
    };

    /// Builds the focus chain: focusable elements in paint order, native
    /// ones that their backend lets take focus, within `modal` if set.
    fn buildChain(
        self: *Reconciler,
        gpa: Allocator,
        context: *const layout.Context,
        focusable: *const std.AutoHashMapUnmanaged(u64, void),
        modal: ?usize,
    ) Allocator.Error!void {
        self.chain.clearRetainingCapacity();
        for (context.units.items, 0..) |*unit, index| {
            if (modal) |scope| if (!within(context.units.items, index, scope)) continue;
            switch (unit.data) {
                .content => |content| if (NativeContent.from(content)) |nc| {
                    const backend = self.backend orelse continue;
                    const record = self.records.getPtr(nc.id) orelse continue;
                    if (backend.canFocus(record.handle)) {
                        try self.chain.append(gpa, .{ .unit = record.unit, .native = nc.id });
                    }
                },
                .container => if (unit.id != 0 and focusable.contains(unit.id)) {
                    try self.chain.append(gpa, .{ .unit = unit.id });
                },
            }
        }
    }

    /// Splits the frame's render commands into canvas layers around the
    /// native views; see `Scene`. A native container's commands come
    /// between its scissors; they go to the container's own scope, which
    /// stacks like the host, and the container's view is a slot of the
    /// scope around it.
    fn split(self: *Reconciler, arena: Allocator, context: *const layout.Context) Allocator.Error!Scene {
        var layers: std.ArrayList(LayerBuilder) = .empty;
        var containers: std.ArrayList(Scene.Container) = .empty;
        var scopes: std.ArrayList(Scope) = .empty;
        try scopes.append(arena, .{});
        try openLayer(arena, &scopes.items[0], &layers, .zero, true);

        var it = context.renderCommands();
        while (it.next()) |command| {
            const scope = &scopes.items[scopes.items.len - 1];
            switch (command.data) {
                .scissor_start => if (self.containerAt(command.unit_id)) |record| {
                    // the container's view stacks in the scope around it
                    try scope.placed.append(arena, .{ .frame = visibleBox(command.bbox, scope.clips.items), .slot = scope.slots.items.len });
                    try scope.slots.append(arena, .{ .native = record.handle });
                    // and its content is a scope of its own, which its view clips
                    try containers.append(arena, .{ .handle = record.handle, .slots = &.{} });
                    try scopes.append(arena, .{ .container = containers.items.len - 1 });
                    const inner = &scopes.items[scopes.items.len - 1];
                    try openLayer(arena, inner, &layers, self.contentOrigin(context, command.unit_id), true);
                } else try scope.clips.append(arena, command),
                .scissor_end => if (scope.container != null and scope.clips.items.len == 0) {
                    // the end of the container's content
                    for (scope.layers.items) |index| try closeScissors(arena, &layers.items[index], 0);
                    containers.items[scope.container.?].slots = scope.slots.items;
                    _ = scopes.pop();
                } else {
                    _ = scope.clips.pop();
                    for (scope.layers.items) |index| try closeScissors(arena, &layers.items[index], scope.clips.items.len);
                },
                .content => |content| if (NativeContent.from(content)) |nc| {
                    const record = self.records.getPtr(nc.id) orelse continue;
                    try scope.placed.append(arena, .{ .frame = visibleBox(command.bbox, scope.clips.items), .slot = scope.slots.items.len });
                    try scope.slots.append(arena, .{ .native = record.handle });
                } else try place(arena, scope, &layers, command),
                else => try place(arena, scope, &layers, command),
            }
        }

        const host = &scopes.items[0];
        const built = try arena.alloc(Scene.Layer, layers.items.len);
        for (built, layers.items) |*out, *layer| {
            try closeScissors(arena, layer, 0);
            out.* = .{
                .commands = layer.commands.items,
                .hit = if (layer.base) &.{} else layer.hit.items,
                .offset = layer.offset,
                .base = layer.base,
            };
        }
        return .{ .slots = host.slots.items, .layers = built, .containers = containers.items };
    }

    /// The native container whose content a scissor with this unit ID
    /// clips, if it is one.
    fn containerAt(self: *Reconciler, unit_id: u64) ?*Record {
        const record = self.records.getPtr(unit_id) orelse return null;
        if (!record.spec.isContainer() or record.unit != unit_id) return null;
        return record;
    }

    const Placed = struct { frame: Rect, slot: usize };

    /// The host, or one native container's content, as the split builds it.
    const Scope = struct {
        /// The index in the scene's containers, or null for the host.
        container: ?usize = null,
        slots: std.ArrayList(Scene.Slot) = .empty,
        /// Its layers, as indices in the scene's.
        layers: std.ArrayList(usize) = .empty,
        /// Its native views, and where they are.
        placed: std.ArrayList(Placed) = .empty,
        /// The clips in force within it.
        clips: std.ArrayList(layout.RenderCommand) = .empty,
    };

    const LayerBuilder = struct {
        /// Its index in its scope's slots.
        slot: usize,
        commands: std.ArrayList(layout.RenderCommand) = .empty,
        /// The visible boxes of its drawn commands.
        hit: std.ArrayList(Rect) = .empty,
        /// How many of its scope's clips in force it has opened.
        open: usize = 0,
        offset: Vec2 = .zero,
        base: bool = false,
    };

    /// Adds a canvas layer at the top of `scope`.
    fn openLayer(arena: Allocator, scope: *Scope, layers: *std.ArrayList(LayerBuilder), offset: Vec2, base: bool) Allocator.Error!void {
        const index = layers.items.len;
        try layers.append(arena, .{ .slot = scope.slots.items.len, .offset = offset, .base = base });
        try scope.layers.append(arena, index);
        try scope.slots.append(arena, .{ .canvas = @intCast(index) });
    }

    /// Closes the scissors a layer opened beyond the first `keep`.
    fn closeScissors(arena: Allocator, layer: *LayerBuilder, keep: usize) Allocator.Error!void {
        while (layer.open > keep) : (layer.open -= 1) {
            try layer.commands.append(arena, .{ .data = .scissor_end });
        }
    }

    /// Puts a drawn command in the lowest layer of its scope above every
    /// native view and every drawn command in a higher layer that it
    /// overlaps.
    fn place(
        arena: Allocator,
        scope: *Scope,
        layers: *std.ArrayList(LayerBuilder),
        command: layout.RenderCommand,
    ) Allocator.Error!void {
        const clips = scope.clips.items;
        const box = visibleBox(command.bbox, clips);

        var min_slot: usize = 0;
        for (scope.placed.items) |p| {
            if (overlaps(p.frame, box)) min_slot = @max(min_slot, p.slot + 1);
        }

        const own = scope.layers.items;
        var target: ?usize = for (own, 0..) |index, i| {
            if (layers.items[index].slot >= min_slot) break i;
        } else null;

        if (target) |lowest| {
            // drawn content painted earlier in a higher layer stays below it
            var i = own.len;
            while (i > lowest + 1) {
                i -= 1;
                const above = for (layers.items[own[i]].hit.items) |rect| {
                    if (overlaps(rect, box)) break true;
                } else false;
                if (above) {
                    target = i;
                    break;
                }
            }
        } else {
            target = own.len;
            try openLayer(arena, scope, layers, layers.items[own[0]].offset, false);
        }

        const layer = &layers.items[scope.layers.items[target.?]];
        while (layer.open < clips.len) : (layer.open += 1) {
            try layer.commands.append(arena, clips[layer.open]);
        }
        try layer.commands.append(arena, command);
        if (!layer.base) try layer.hit.append(arena, box);
    }
};

/// `v` to the nearest 1/256 of a point, which floats hold exactly.
fn snap(v: f32) f32 {
    return @round(v * 256) / 256;
}

/// Whether `units[index]` is `units[scope]` or inside it.
fn within(units: []const layout.Unit, index: usize, scope: usize) bool {
    var at = index;
    while (true) : (at = units[at].parent) {
        if (at == scope) return true;
        if (at == 0) return false;
    }
}

/// The part of `box` left visible by the clips in force.
fn visibleBox(box: Rect, clips: []const layout.RenderCommand) Rect {
    var x0 = box.x;
    var y0 = box.y;
    var x1 = box.x + box.w;
    var y1 = box.y + box.h;
    for (clips) |clip| {
        const c = clip.bbox;
        const s = clip.data.scissor_start;
        if (s.horizontal) {
            x0 = @max(x0, c.x);
            x1 = @min(x1, c.x + c.w);
        }
        if (s.vertical) {
            y0 = @max(y0, c.y);
            y1 = @min(y1, c.y + c.h);
        }
    }
    return .init(x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0));
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
        a.x < b.x + b.w and b.x < a.x + a.w and
        a.y < b.y + b.h and b.y < a.y + a.h;
}

/// The layout content standing for a native view: its size is the
/// backend's, and the scene puts the view where its command paints. A
/// label is measured under the width its box will get (the nearest
/// bounded ancestor's, `Content.limit`), so it wraps there, and can be
/// squeezed below its one-line width.
pub const NativeContent = struct {
    content: layout.Content = .{ .vtable = &vtable },
    reconciler: *Reconciler,
    id: Id,

    const vtable: layout.Content.VTable = .{ .measure = measure, .measure_min = measureMin, .debug_name = "native" };

    /// The content for the element `id`, whose spec is `spec`.
    pub fn init(reconciler: *Reconciler, id: Id, spec: *const Spec) NativeContent {
        return .{
            .content = .{ .vtable = &vtable, .limit = if (spec.* == .label) .ancestors else .parent },
            .reconciler = reconciler,
            .id = id,
        };
    }

    fn measure(content: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
        // the content is a field of a NativeContent, whose alignment is
        // higher on 32-bit targets
        const self: *NativeContent = @alignCast(@fieldParentPtr("content", content));
        return self.reconciler.measure(self.id, constraints);
    }

    /// Labels give way (they wrap, or are cut); other views keep their size.
    fn measureMin(content: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
        const self: *NativeContent = @alignCast(@fieldParentPtr("content", content));
        const size = try measure(content, constraints);
        const record = self.reconciler.records.getPtr(self.id) orelse return size;
        return if (record.spec == .label) .init(0, size.y) else size;
    }

    /// The native content `content` is, if it is one.
    pub fn from(content: *layout.Content) ?*NativeContent {
        if (content.vtable != &vtable) return null;
        return @alignCast(@fieldParentPtr("content", content));
    }
};
