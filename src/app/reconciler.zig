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
    };

    pub const Record = struct {
        handle: Handle,
        /// The props last applied, owned.
        spec: Spec,
        /// What the control shows as far as fabrum knows, owned.
        shown: Value,
        handlers: native.Handlers,
        /// The layout unit of its box, or 0 for elements placed elsewhere.
        unit: u32,
        frame: ?Rect = null,
        seen: bool = true,

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
        unit: u32,
        /// Set for native elements.
        native: ?Id = null,

        pub fn eql(a: FocusEntry, b: FocusEntry) bool {
            return a.unit == b.unit and a.native == b.native;
        }
    };

    pub fn deinit(self: *Reconciler, gpa: Allocator) void {
        for (self.records.values()) |*record| {
            if (self.backend) |backend| backend.destroy(record.handle);
            record.spec.free(gpa);
            record.shown.free(gpa);
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
    /// rule.
    pub fn declare(self: *Reconciler, gpa: Allocator, id: Id, unit: u32, element: native.Element) Error!void {
        const backend = self.backend orelse return error.NoNativeBackend;
        const gop = try self.records.getOrPut(gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.create(gpa, backend, id, unit, element) catch |err| {
                _ = self.records.swapRemove(id);
                return err;
            };
            return;
        }

        const record = gop.value_ptr;
        if (record.seen) return error.DuplicateKey;

        if (!record.spec.sameKind(element.spec)) {
            // a different kind of control under the same key: replace it
            const replacement = try self.create(gpa, backend, id, unit, element);
            self.destroyRecord(gpa, record);
            record.* = replacement;
            return;
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

    fn create(self: *Reconciler, gpa: Allocator, backend: native.Backend, id: Id, unit: u32, element: native.Element) Error!Record {
        const spec = try element.spec.clone(gpa);
        errdefer spec.free(gpa);
        const shown = try element.value.clone(gpa);
        errdefer shown.free(gpa);
        const handle = try backend.create(id, &element.spec, &element.value, null);
        self.stats.creates += 1;
        return .{ .handle = handle, .spec = spec, .shown = shown, .handlers = element.handlers, .unit = unit };
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
        focusable: *const std.AutoHashMapUnmanaged(u32, void),
        modal: ?usize,
    ) Allocator.Error!void {
        const backend = self.backend orelse return;

        // destroy first, so the scene never names a dead view
        var i: usize = 0;
        while (i < self.records.count()) {
            const record = &self.records.values()[i];
            if (record.seen) {
                i += 1;
                continue;
            }
            self.destroyRecord(gpa, record);
            self.records.swapRemoveAt(i);
        }

        for (self.records.values()) |*record| {
            if (record.unit == 0) continue;
            const unit = context.getUnitById(.fromInt(record.unit)) orelse continue;
            if (record.frame == null or !std.meta.eql(record.frame.?, unit.bbox)) {
                backend.setFrame(record.handle, unit.bbox);
                self.stats.frames += 1;
                record.frame = unit.bbox;
            }
        }

        self.chain.clearRetainingCapacity();
        for (context.units.items, 0..) |*unit, index| {
            if (modal) |scope| if (!within(context.units.items, index, scope)) continue;
            switch (unit.data) {
                .content => |content| if (NativeContent.from(content)) |nc| {
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

        self.scene = try self.split(arena, context);
        backend.present(&self.scene);
    }

    /// Splits the frame's render commands into canvas layers around the
    /// native views; see `Scene`.
    fn split(self: *Reconciler, arena: Allocator, context: *const layout.Context) Allocator.Error!Scene {
        var slots: std.ArrayList(Scene.Slot) = .empty;
        var layers: std.ArrayList(LayerBuilder) = .empty;
        var placed: std.ArrayList(Placed) = .empty;
        var clips: std.ArrayList(layout.RenderCommand) = .empty;

        try slots.append(arena, .{ .canvas = 0 });
        try layers.append(arena, .{ .slot = 0 });

        var it = context.renderCommands();
        while (it.next()) |command| {
            switch (command.data) {
                .scissor_start => try clips.append(arena, command),
                .scissor_end => {
                    _ = clips.pop();
                    for (layers.items) |*layer| {
                        if (layer.open > clips.items.len) {
                            try layer.commands.append(arena, command);
                            layer.open -= 1;
                        }
                    }
                },
                .content => |content| if (NativeContent.from(content)) |nc| {
                    const record = self.records.getPtr(nc.id) orelse continue;
                    try placed.append(arena, .{ .frame = record.frame orelse command.bbox, .slot = slots.items.len });
                    try slots.append(arena, .{ .native = record.handle });
                } else try place(arena, &slots, &layers, placed.items, clips.items, command),
                else => try place(arena, &slots, &layers, placed.items, clips.items, command),
            }
        }

        const built = try arena.alloc(Scene.Layer, layers.items.len);
        for (built, layers.items, 0..) |*out, *layer, index| {
            while (layer.open > 0) : (layer.open -= 1) {
                try layer.commands.append(arena, .{ .data = .scissor_end });
            }
            out.* = .{ .commands = layer.commands.items, .hit = if (index == 0) &.{} else layer.hit.items };
        }
        return .{ .slots = slots.items, .layers = built };
    }

    const Placed = struct { frame: Rect, slot: usize };

    const LayerBuilder = struct {
        /// Its index in the scene's slots.
        slot: usize,
        commands: std.ArrayList(layout.RenderCommand) = .empty,
        /// The visible boxes of its drawn commands.
        hit: std.ArrayList(Rect) = .empty,
        /// How many of the clips in force it has opened.
        open: usize = 0,
    };

    /// Puts a drawn command in the lowest layer above every native view
    /// and every drawn command in a higher layer that it overlaps.
    fn place(
        arena: Allocator,
        slots: *std.ArrayList(Scene.Slot),
        layers: *std.ArrayList(LayerBuilder),
        placed: []const Placed,
        clips: []const layout.RenderCommand,
        command: layout.RenderCommand,
    ) Allocator.Error!void {
        const box = visibleBox(command.bbox, clips);

        var min_slot: usize = 0;
        for (placed) |p| {
            if (overlaps(p.frame, box)) min_slot = @max(min_slot, p.slot + 1);
        }

        var target: ?usize = for (layers.items, 0..) |layer, index| {
            if (layer.slot >= min_slot) break index;
        } else null;

        if (target) |lowest| {
            // drawn content painted earlier in a higher layer stays below it
            var index = layers.items.len;
            while (index > lowest + 1) {
                index -= 1;
                const above = for (layers.items[index].hit.items) |rect| {
                    if (overlaps(rect, box)) break true;
                } else false;
                if (above) {
                    target = index;
                    break;
                }
            }
        } else {
            target = layers.items.len;
            try layers.append(arena, .{ .slot = slots.items.len });
            try slots.append(arena, .{ .canvas = @intCast(target.?) });
        }

        const layer = &layers.items[target.?];
        while (layer.open < clips.len) : (layer.open += 1) {
            try layer.commands.append(arena, clips[layer.open]);
        }
        try layer.commands.append(arena, command);
        if (target.? > 0) try layer.hit.append(arena, box);
    }
};

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
/// backend's, and the scene puts the view where its command paints.
pub const NativeContent = struct {
    content: layout.Content = .{ .vtable = &vtable },
    reconciler: *Reconciler,
    id: Id,

    const vtable: layout.Content.VTable = .{ .measure = measure, .debug_name = "native" };

    fn measure(content: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
        const self: *NativeContent = @fieldParentPtr("content", content);
        return self.reconciler.measure(self.id, constraints);
    }

    /// The native content `content` is, if it is one.
    pub fn from(content: *layout.Content) ?*NativeContent {
        if (content.vtable != &vtable) return null;
        return @fieldParentPtr("content", content);
    }
};
