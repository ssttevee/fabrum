//! Which canvas layers of a scene changed since the last one, so a backend
//! redraws only those, and only where they changed.
//!
//! Every present brings a new scene whose commands are rebuilt, and a
//! backend that marks every canvas layer for display redraws the whole
//! window on each frame: a scroll step redraws a long document's canvas
//! although nothing in it moved, since the layout moves with the scroll
//! offset and the layer's offset takes it out again. `CanvasDamage` keeps a
//! `layout.Damage` per canvas layer, fed the layer's commands moved by
//! minus its offset (where they draw in the layer's view), and reports the
//! regions that changed: none while scrolling, a row's box when it is
//! hovered, everything the first time.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const native = @import("native.zig");
const Scene = native.Scene;

const CanvasDamage = @This();

/// One per canvas layer index, in the order the scene numbers them.
layers: std.ArrayList(Layer) = .empty,
/// The layer's commands moved into its view's coordinates.
scratch: std.ArrayList(layout.RenderCommand) = .empty,
/// Counts, for tests and dumps: layers looked at, and of those, left
/// alone because nothing in them changed.
stats: Stats = .{},

/// A layer's view is taken to be at most this big: the regions are
/// clipped to it, and the first frame damages it whole.
pub const extent: f32 = 1 << 20;

pub const Stats = struct {
    presented: usize = 0,
    skipped: usize = 0,
};

const Layer = struct {
    damage: layout.Damage = .{},
};

pub fn deinit(self: *CanvasDamage, gpa: Allocator) void {
    for (self.layers.items) |*layer| layer.damage.deinit(gpa);
    self.layers.deinit(gpa);
    self.scratch.deinit(gpa);
    self.* = undefined;
}

/// The regions of canvas layer `index` of `scene` that changed since the
/// last scene it was in, in the layer's view's coordinates (points from
/// its top left): empty if nothing changed, and the whole `extent` the
/// first time. Valid until the next call for the same layer.
pub fn update(self: *CanvasDamage, gpa: Allocator, scene: *const Scene, index: usize) Allocator.Error![]const Rect {
    while (self.layers.items.len <= index) try self.layers.append(gpa, .{});
    const layer = scene.layers[index];
    self.scratch.clearRetainingCapacity();
    try self.scratch.ensureTotalCapacity(gpa, layer.commands.len);
    for (layer.commands) |command| {
        var moved = command;
        // the offset is in the box too (the layout moved with the scroll),
        // so taking it out leaves float rounding, which snapping removes,
        // as the reconciler does for frames
        moved.bbox.x = snap(command.bbox.x - layer.offset.x);
        moved.bbox.y = snap(command.bbox.y - layer.offset.y);
        self.scratch.appendAssumeCapacity(moved);
    }
    const regions = try self.layers.items[index].damage.update(gpa, self.scratch.items, .init(extent, extent));
    self.stats.presented += 1;
    if (regions.len == 0) self.stats.skipped += 1;
    return regions;
}

/// `v` to the nearest 1/256 of a point, which floats hold exactly.
fn snap(v: f32) f32 {
    return @round(v * 256) / 256;
}

/// Forgets what layer `index` showed, so its next update damages it
/// whole: for a canvas the backend remade or resized.
pub fn reset(self: *CanvasDamage, index: usize) void {
    if (index < self.layers.items.len) self.layers.items[index].damage.reset();
}

test "a layer whose commands only moved with its offset is unchanged" {
    const gpa = std.testing.allocator;
    var damage: CanvasDamage = .{};
    defer damage.deinit(gpa);
    const label = layout.RenderCommand{ .bbox = .init(10, 100, 50, 20), .data = .{ .rectangle = .{ .color = .rgb(1, 2, 3), .corner_radius = .{} } } };
    var scene: Scene = .{ .layers = &.{.{ .commands = &.{label}, .hit = &.{}, .offset = .init(0, 0), .base = true }} };
    // everything the first time
    const first = try damage.update(gpa, &scene, 0);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(extent, first[0].w);
    // scrolled by 30: the command and the offset moved together
    const scrolled = layout.RenderCommand{ .bbox = .init(10, 70, 50, 20), .data = label.data };
    scene = .{ .layers = &.{.{ .commands = &.{scrolled}, .hit = &.{}, .offset = .init(0, -30), .base = true }} };
    try std.testing.expectEqual(@as(usize, 0), (try damage.update(gpa, &scene, 0)).len);
    try std.testing.expectEqual(@as(usize, 1), damage.stats.skipped);
    // a color change damages the command's box, where it draws in the view
    const hovered = layout.RenderCommand{ .bbox = .init(10, 70, 50, 20), .data = .{ .rectangle = .{ .color = .rgb(9, 9, 9), .corner_radius = .{} } } };
    scene = .{ .layers = &.{.{ .commands = &.{hovered}, .hit = &.{}, .offset = .init(0, -30), .base = true }} };
    const changed = try damage.update(gpa, &scene, 0);
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expect(changed[0].contains(.init(12, 102)));
    try std.testing.expect(!changed[0].contains(.init(12, 140)));
    try std.testing.expectEqual(@as(usize, 1), damage.stats.skipped);
    try std.testing.expectEqual(@as(usize, 3), damage.stats.presented);
}
