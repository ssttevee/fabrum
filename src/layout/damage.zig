//! Damage: the regions of the viewport whose pixels may differ between one
//! frame's render commands and a later frame's, so that a host redraws and
//! sends only those. A VNC server sends only changed rectangles; an overlay
//! redraws its texture only where something changed.
//!
//! **How.** Each frame's commands are summarised as paint entries, one per
//! command that draws something: a hash of what it draws (its kind, colors,
//! radii, border widths, box, the clip in force, and its content's
//! `fingerprint`) and the pixels it can touch (its box cut by the clips in
//! force, rounded out to whole pixels and grown by `margin`). The entries of
//! the two frames are matched in order: a common start and end, then
//! entries whose hash is unique in both frames, kept only in increasing
//! order (the longest increasing subsequence), then their equal neighbours.
//! Every entry left unmatched, in either frame, adds its pixels to the
//! damage. Overlapping regions are merged, and many small ones merged
//! further, into at most `max_regions`.
//!
//! **Why it is correct.** A pixel's color is a function of the commands
//! that touch it, in paint order. Matched entries draw the same thing in
//! the same place and keep their relative order, since the matching is
//! increasing. So at a pixel no unmatched entry touches, both frames paint
//! the same commands in the same order, and the pixel is the same. Content
//! without a fingerprint never matches, so it is always redrawn.
//!
//! **Limits.** It is per command, not per pixel: a hover that changes a
//! button's fill damages the whole button. A command that moves damages
//! its old and new places, and one inserted early in the list (a new row)
//! is cheap, but a reordering of many commands damages all of them. It
//! trusts renderers to draw each command within its box plus `margin`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const Rect = fabrum.Rect;
const Vec2 = fabrum.Vec2;
const RenderCommand = @import("render_command.zig");

const Damage = @This();

/// The previous frame's entries.
entries: std.ArrayList(Entry) = .empty,
/// Scratch for the next frame's entries, swapped with `entries`.
next: std.ArrayList(Entry) = .empty,
/// The regions of the last `update`.
regions: std.ArrayList(Rect) = .empty,
/// The viewport of the previous frame, or null before the first.
viewport: ?Vec2 = null,
/// How far outside its box a command may draw: anti-aliasing and glyphs
/// that overhang their line. In points.
margin: f32 = margin_default,
/// The most regions `update` returns; more are merged.
max_regions: usize = 16,
/// Counts updates, so content without a fingerprint never matches the
/// previous frame's.
generation: u64 = 0,

/// How far outside its box renderers may draw a command, and the default
/// `margin`: renderers that redraw damage draw every command whose box,
/// grown by this, touches a region.
pub const margin_default = 2;

pub const Entry = struct {
    /// A hash of everything that changes what the command draws.
    hash: u64,
    /// The pixels it can touch.
    area: Area,
};

/// A rectangle of whole pixels: `x0 <= x < x1`, `y0 <= y < y1`.
pub const Area = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn isEmpty(self: Area) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    fn join(a: Area, b: Area) Area {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    fn touches(a: Area, b: Area) bool {
        return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1;
    }

    fn size(self: Area) i64 {
        return @as(i64, self.x1 - self.x0) * (self.y1 - self.y0);
    }

    fn rect(self: Area) Rect {
        return .init(@floatFromInt(self.x0), @floatFromInt(self.y0), @floatFromInt(self.x1 - self.x0), @floatFromInt(self.y1 - self.y0));
    }
};

pub fn deinit(self: *Damage, gpa: Allocator) void {
    self.entries.deinit(gpa);
    self.next.deinit(gpa);
    self.regions.deinit(gpa);
    self.* = undefined;
}

/// Forgets the previous frame, so the next `update` damages everything.
pub fn reset(self: *Damage) void {
    self.viewport = null;
    self.entries.clearRetainingCapacity();
}

/// Takes `commands`, laid out in `viewport`, as the current frame, and
/// returns the regions that changed since the previous call: the whole
/// viewport the first time, or when the viewport changes size. The regions
/// are whole pixels inside the viewport, don't overlap, and are valid until
/// the next call.
pub fn update(self: *Damage, gpa: Allocator, commands: []const RenderCommand, viewport: Vec2) Allocator.Error![]const Rect {
    self.next.clearRetainingCapacity();
    self.generation +%= 1;
    const bounds: Area = .{ .x0 = 0, .y0 = 0, .x1 = toPixel(@ceil(viewport.x)), .y1 = toPixel(@ceil(viewport.y)) };
    try summarise(gpa, &self.next, commands, bounds, self.margin, self.generation);
    defer std.mem.swap(std.ArrayList(Entry), &self.entries, &self.next);

    self.regions.clearRetainingCapacity();
    const whole = if (self.viewport) |old| old.x != viewport.x or old.y != viewport.y else true;
    self.viewport = viewport;
    if (whole) {
        if (!bounds.isEmpty()) try self.regions.append(gpa, bounds.rect());
        return self.regions.items;
    }

    var areas: std.ArrayList(Area) = .empty;
    defer areas.deinit(gpa);
    try changed(gpa, self.entries.items, self.next.items, &areas);
    merge(&areas, self.max_regions);
    try self.regions.ensureTotalCapacity(gpa, areas.items.len);
    for (areas.items) |area| self.regions.appendAssumeCapacity(area.rect());
    return self.regions.items;
}

/// Appends an entry for every command of `commands` that draws something
/// inside `bounds`.
fn summarise(gpa: Allocator, entries: *std.ArrayList(Entry), commands: []const RenderCommand, bounds: Area, margin: f32, generation: u64) Allocator.Error!void {
    var clips: std.ArrayList(Rect) = .empty;
    defer clips.deinit(gpa);
    for (commands) |command| {
        const clip: ?Rect = if (clips.items.len > 0) clips.getLast() else null;
        switch (command.data) {
            .scissor_start => |s| {
                const box = command.bbox;
                const huge = std.math.floatMax(f32) / 4;
                var cut: Rect = .init(if (s.horizontal) box.x else -huge, if (s.vertical) box.y else -huge, if (s.horizontal) box.w else 2 * huge, if (s.vertical) box.h else 2 * huge);
                if (clip) |c| cut = intersect(cut, c);
                try clips.append(gpa, cut);
                continue;
            },
            .scissor_end => {
                _ = clips.pop();
                continue;
            },
            else => {},
        }

        const visible = if (clip) |c| intersect(command.bbox, c) else command.bbox;
        if (visible.w <= 0 or visible.h <= 0) continue;
        var area: Area = .{
            .x0 = toPixel(@floor(visible.x - margin)),
            .y0 = toPixel(@floor(visible.y - margin)),
            .x1 = toPixel(@ceil(visible.x + visible.w + margin)),
            .y1 = toPixel(@ceil(visible.y + visible.h + margin)),
        };
        area = .{ .x0 = @max(area.x0, bounds.x0), .y0 = @max(area.y0, bounds.y0), .x1 = @min(area.x1, bounds.x1), .y1 = @min(area.y1, bounds.y1) };
        if (area.isEmpty()) continue;

        var hasher = std.hash.Wyhash.init(0);
        hashRect(&hasher, command.bbox);
        if (clip) |c| hashRect(&hasher, c);
        std.hash.autoHash(&hasher, std.meta.activeTag(command.data));
        switch (command.data) {
            .rectangle => |r| {
                std.hash.autoHash(&hasher, r.color);
                hashFloats(&hasher, r.corner_radius);
            },
            .border => |b| {
                std.hash.autoHash(&hasher, b.color);
                hashFloats(&hasher, b.widths);
                hashFloats(&hasher, b.corner_radius);
            },
            .content => |content| if (content.fingerprint()) |f| {
                std.hash.autoHash(&hasher, f);
            } else {
                // a hash no entry of another frame has
                std.hash.autoHash(&hasher, generation);
                std.hash.autoHash(&hasher, entries.items.len);
            },
            .scissor_start, .scissor_end => unreachable,
        }
        try entries.append(gpa, .{ .hash = hasher.final(), .area = area });
    }
}

fn toPixel(v: f32) i32 {
    const limit: f32 = 1 << 30;
    return @intFromFloat(std.math.clamp(v, -limit, limit));
}

fn hashRect(hasher: *std.hash.Wyhash, rect: Rect) void {
    hashFloats(hasher, rect);
}

/// Hashes every `f32` field of `value`, a struct of them, by its bits.
fn hashFloats(hasher: *std.hash.Wyhash, value: anytype) void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        std.hash.autoHash(hasher, @as(u32, @bitCast(@as(f32, @field(value, name)))));
    }
}

fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .init(x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0));
}

/// Appends the areas of the entries of `old` and `new` left unmatched by an
/// increasing matching of equal entries.
fn changed(gpa: Allocator, old: []const Entry, new: []const Entry, out: *std.ArrayList(Area)) Allocator.Error!void {
    // the common start and end
    var start: usize = 0;
    while (start < old.len and start < new.len and old[start].hash == new[start].hash) start += 1;
    var end: usize = 0;
    while (end < old.len - start and end < new.len - start and old[old.len - 1 - end].hash == new[new.len - 1 - end].hash) end += 1;
    const a = old[start .. old.len - end];
    const b = new[start .. new.len - end];
    if (a.len == 0 and b.len == 0) return;

    const pair_a = try gpa.alloc(?usize, a.len);
    defer gpa.free(pair_a);
    const pair_b = try gpa.alloc(?usize, b.len);
    defer gpa.free(pair_b);
    @memset(pair_a, null);
    @memset(pair_b, null);
    try match(gpa, a, b, pair_a, pair_b);

    for (a, pair_a) |entry, pair| if (pair == null) try out.append(gpa, entry.area);
    for (b, pair_b) |entry, pair| if (pair == null) try out.append(gpa, entry.area);
}

/// Pairs entries of `a` and `b` in increasing order, as patience diff
/// does: hashes unique in both are anchors, the longest run of anchors in
/// the same order is kept, and pairs grow from each kept anchor over equal
/// neighbours. `pair_a[i]` is the index in `b` of `a[i]`'s partner, and
/// the other way round.
fn match(gpa: Allocator, a: []const Entry, b: []const Entry, pair_a: []?usize, pair_b: []?usize) Allocator.Error!void {
    const Count = struct { in_a: u32 = 0, in_b: u32 = 0, at_a: usize = 0 };
    var counts: std.AutoHashMapUnmanaged(u64, Count) = .empty;
    defer counts.deinit(gpa);
    for (a, 0..) |entry, i| {
        const gop = try counts.getOrPut(gpa, entry.hash);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.in_a += 1;
        gop.value_ptr.at_a = i;
    }
    for (b) |entry| if (counts.getPtr(entry.hash)) |count| {
        count.in_b += 1;
    };

    // anchors in `b`'s order, with their place in `a`
    const Anchor = struct { a: usize, b: usize };
    var anchors: std.ArrayList(Anchor) = .empty;
    defer anchors.deinit(gpa);
    for (b, 0..) |entry, j| if (counts.get(entry.hash)) |count| {
        if (count.in_a == 1 and count.in_b == 1) try anchors.append(gpa, .{ .a = count.at_a, .b = j });
    };

    // the longest run of anchors whose places in `a` increase too
    const n = anchors.items.len;
    const tails = try gpa.alloc(usize, n);
    defer gpa.free(tails);
    const previous = try gpa.alloc(?usize, n);
    defer gpa.free(previous);
    var length: usize = 0;
    for (anchors.items, 0..) |anchor, i| {
        var lo: usize = 0;
        var hi: usize = length;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (anchors.items[tails[mid]].a < anchor.a) lo = mid + 1 else hi = mid;
        }
        previous[i] = if (lo > 0) tails[lo - 1] else null;
        tails[lo] = i;
        if (lo == length) length += 1;
    }
    var at: ?usize = if (length > 0) tails[length - 1] else null;
    while (at) |i| : (at = previous[i]) {
        const anchor = anchors.items[i];
        pair_a[anchor.a] = anchor.b;
        pair_b[anchor.b] = anchor.a;
    }

    // grow each pair forwards, then backwards, over equal unpaired
    // neighbours; between two pairs, that keeps the order
    for (0..a.len) |i| {
        const j = pair_a[i] orelse continue;
        var x = i + 1;
        var y = j + 1;
        while (x < a.len and y < b.len and pair_a[x] == null and pair_b[y] == null and a[x].hash == b[y].hash) : ({
            x += 1;
            y += 1;
        }) {
            pair_a[x] = y;
            pair_b[y] = x;
        }
    }
    var i = a.len;
    while (i > 0) {
        i -= 1;
        const j = pair_a[i] orelse continue;
        var x = i;
        var y = j;
        while (x > 0 and y > 0 and pair_a[x - 1] == null and pair_b[y - 1] == null and a[x - 1].hash == b[y - 1].hash) : ({
            x -= 1;
            y -= 1;
        }) {
            pair_a[x - 1] = y - 1;
            pair_b[y - 1] = x - 1;
        }
    }
}

/// Merges areas that overlap or touch until none do, then the pairs whose
/// union adds the fewest pixels until at most `max` are left.
fn merge(areas: *std.ArrayList(Area), max: usize) void {
    mergeTouching(areas);
    while (areas.items.len > @max(max, 1)) {
        var best: struct { i: usize = 0, j: usize = 1, cost: i64 = std.math.maxInt(i64) } = .{};
        for (areas.items, 0..) |x, i| for (areas.items[i + 1 ..], i + 1..) |y, j| {
            const cost = x.join(y).size() - x.size() - y.size();
            if (cost < best.cost) best = .{ .i = i, .j = j, .cost = cost };
        };
        areas.items[best.i] = areas.items[best.i].join(areas.items[best.j]);
        _ = areas.swapRemove(best.j);
        // the union may touch others now
        mergeTouching(areas);
    }
}

fn mergeTouching(areas: *std.ArrayList(Area)) void {
    var merged = true;
    while (merged) {
        merged = false;
        var i: usize = 0;
        while (i < areas.items.len) : (i += 1) {
            var j = i + 1;
            while (j < areas.items.len) {
                if (areas.items[i].touches(areas.items[j])) {
                    areas.items[i] = areas.items[i].join(areas.items[j]);
                    _ = areas.swapRemove(j);
                    merged = true;
                } else j += 1;
            }
        }
    }
}

const testing = std.testing;
const Color = fabrum.Color;
const TestRenderer = @import("renderer.zig").TestRenderer;
const Surface = @import("renderer.zig").Surface;

fn rectangle(x: f32, y: f32, w: f32, h: f32, color: Color) RenderCommand {
    return .{ .bbox = .init(x, y, w, h), .data = .{ .rectangle = .{ .color = color, .corner_radius = .{} } } };
}

fn expectRegions(expected: []const Rect, actual: []const Rect) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected) |e| {
        for (actual) |a| {
            if (std.meta.eql(a, e)) break;
        } else {
            std.debug.print("missing region {any} in {any}\n", .{ e, actual });
            return error.TestExpectedEqual;
        }
    }
}

test "the first frame, and a new viewport size, damage everything; an unchanged frame nothing" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    const frame = [_]RenderCommand{rectangle(10, 10, 20, 20, .black)};
    try expectRegions(&.{.init(0, 0, 100, 50)}, try damage.update(testing.allocator, &frame, .init(100, 50)));
    try expectRegions(&.{}, try damage.update(testing.allocator, &frame, .init(100, 50)));
    try expectRegions(&.{.init(0, 0, 80, 50)}, try damage.update(testing.allocator, &frame, .init(80, 50)));
}

test "a changed command damages its box, grown by the margin to whole pixels" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    _ = try damage.update(testing.allocator, &.{ rectangle(0, 0, 100, 100, .white), rectangle(10.5, 10, 20, 20, .black), rectangle(60, 60, 10, 10, .black) }, .init(100, 100));
    // a hover: one fill changes color
    const regions = try damage.update(testing.allocator, &.{ rectangle(0, 0, 100, 100, .white), rectangle(10.5, 10, 20, 20, .gray(50)), rectangle(60, 60, 10, 10, .black) }, .init(100, 100));
    try expectRegions(&.{.init(8, 8, 25, 24)}, regions);
}

test "a moved command damages where it was and where it is" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    damage.margin = 0;
    _ = try damage.update(testing.allocator, &.{rectangle(0, 0, 10, 10, .black)}, .init(100, 100));
    try expectRegions(&.{ .init(0, 0, 10, 10), .init(50, 50, 10, 10) }, try damage.update(testing.allocator, &.{rectangle(50, 50, 10, 10, .black)}, .init(100, 100)));
}

test "swapping the paint order of overlapping commands damages them" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    damage.margin = 0;
    const red = rectangle(0, 0, 20, 20, .rgb(255, 0, 0));
    const blue = rectangle(10, 0, 20, 20, .rgb(0, 0, 255));
    _ = try damage.update(testing.allocator, &.{ red, blue }, .init(100, 100));
    const regions = try damage.update(testing.allocator, &.{ blue, red }, .init(100, 100));
    try testing.expect(regions.len > 0);
    var covered: Area = .{ .x0 = 1000, .y0 = 1000, .x1 = -1000, .y1 = -1000 };
    for (regions) |r| covered = covered.join(.{ .x0 = @intFromFloat(r.x), .y0 = @intFromFloat(r.y), .x1 = @intFromFloat(r.x + r.w), .y1 = @intFromFloat(r.y + r.h) });
    // the overlap at least
    try testing.expect(covered.x0 <= 10 and covered.x1 >= 20);
}

test "clips cut what a command can damage, and a changed clip damages what it shows" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    damage.margin = 0;
    const clip: RenderCommand = .{ .bbox = .init(0, 0, 50, 50), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } };
    const end: RenderCommand = .{ .data = .scissor_end };
    _ = try damage.update(testing.allocator, &.{ clip, rectangle(40, 40, 40, 40, .black), end }, .init(100, 100));
    // a change outside the clip draws nothing new
    try expectRegions(&.{.init(40, 40, 10, 10)}, try damage.update(testing.allocator, &.{ clip, rectangle(40, 40, 40, 40, .white), end }, .init(100, 100)));
    // a wider clip shows more of the same rectangle
    const wider: RenderCommand = .{ .bbox = .init(0, 0, 60, 60), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = true } } };
    try expectRegions(&.{.init(40, 40, 20, 20)}, try damage.update(testing.allocator, &.{ wider, rectangle(40, 40, 40, 40, .white), end }, .init(100, 100)));
}

test "content without a fingerprint is redrawn every frame; text only when it changes" {
    const Text = @import("text.zig").HeuristicContent;
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    damage.margin = 0;
    var opaque_content: @import("../layout.zig").Content = .{ .vtable = &.{ .measure = undefined } };
    var hello: Text = .init("hello", .{});
    var hello_again: Text = .init("hello", .{});
    var bye: Text = .init("bye", .{});
    const picture: RenderCommand = .{ .bbox = .init(0, 0, 10, 10), .data = .{ .content = &opaque_content } };
    const text = struct {
        fn at(t: *Text) RenderCommand {
            return .{ .bbox = .init(20, 0, 30, 10), .data = .{ .content = &t.content } };
        }
    }.at;
    _ = try damage.update(testing.allocator, &.{ picture, text(&hello) }, .init(100, 100));
    // the same text in other memory, as in the next frame's arena, is unchanged
    try expectRegions(&.{.init(0, 0, 10, 10)}, try damage.update(testing.allocator, &.{ picture, text(&hello_again) }, .init(100, 100)));
    try expectRegions(&.{ .init(0, 0, 10, 10), .init(20, 0, 30, 10) }, try damage.update(testing.allocator, &.{ picture, text(&bye) }, .init(100, 100)));
}

test "many changes merge into at most max_regions regions" {
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);
    damage.max_regions = 4;
    var before: [40]RenderCommand = undefined;
    var after: [40]RenderCommand = undefined;
    for (&before, &after, 0..) |*b, *a, i| {
        const x: f32 = @floatFromInt((i % 8) * 20);
        const y: f32 = @floatFromInt((i / 8) * 20);
        b.* = rectangle(x, y, 10, 10, .black);
        a.* = rectangle(x, y, 10, 10, .white);
    }
    _ = try damage.update(testing.allocator, &before, .init(200, 200));
    const regions = try damage.update(testing.allocator, &after, .init(200, 200));
    try testing.expect(regions.len <= 4);
}

/// Renders `commands` into `pixels` with the test renderer.
fn renderAll(commands: []const RenderCommand, pixels: Surface.Pixels, damage: ?[]const Rect) !void {
    var r: TestRenderer = .{};
    try r.render(commands, .{ .pixels = pixels }, damage);
}

test "redrawing only the damage gives the same pixels as redrawing everything, for random changes" {
    const size = 64;
    var prng: std.Random.DefaultPrng = .init(0xfab);
    const random = prng.random();
    var damage: Damage = .{};
    defer damage.deinit(testing.allocator);

    var full: [size * size * 4]u8 align(4) = undefined;
    var partial: [size * size * 4]u8 align(4) = undefined;
    const surface = struct {
        fn of(buffer: []u8) Surface.Pixels {
            return .packed_(buffer, size, size, .rgba8_premultiplied);
        }
    }.of;

    var commands: std.ArrayList(RenderCommand) = .empty;
    defer commands.deinit(testing.allocator);
    const palette = [_]Color{ .rgb(200, 30, 30), .rgba(30, 30, 200, 128), .rgb(30, 160, 30), .rgba(0, 0, 0, 60), .white };

    var damaged_pixels: usize = 0;
    for (0..300) |step| {
        // a random edit: recolor, move, insert, delete, swap, or wrap in a clip
        const scene_changed = commands.items.len == 0 or step % 37 == 0;
        if (scene_changed) {
            commands.clearRetainingCapacity();
            for (0..12) |_| try commands.append(testing.allocator, rectangle(@floatFromInt(random.uintLessThan(u32, size)), @floatFromInt(random.uintLessThan(u32, size)), @floatFromInt(random.intRangeAtMost(u32, 1, 30)), @floatFromInt(random.intRangeAtMost(u32, 1, 30)), palette[random.uintLessThan(usize, palette.len)]));
        } else {
            const items = commands.items;
            const i = random.uintLessThan(usize, items.len);
            switch (random.uintLessThan(u8, 6)) {
                0 => if (items[i].data == .rectangle) {
                    items[i].data.rectangle.color = palette[random.uintLessThan(usize, palette.len)];
                },
                1 => {
                    items[i].bbox.x += @floatFromInt(random.intRangeAtMost(i32, -5, 5));
                    items[i].bbox.y += @as(f32, @floatFromInt(random.intRangeAtMost(i32, -5, 5))) * 0.5;
                },
                2 => try commands.insert(testing.allocator, i, rectangle(@floatFromInt(random.uintLessThan(u32, size)), @floatFromInt(random.uintLessThan(u32, size)), 12, 9, palette[random.uintLessThan(usize, palette.len)])),
                3 => if (items[i].data == .rectangle and items.len > 2) {
                    _ = commands.orderedRemove(i);
                },
                4 => if (i + 1 < items.len and items[i].data == .rectangle and items[i + 1].data == .rectangle) {
                    std.mem.swap(RenderCommand, &items[i], &items[i + 1]);
                },
                5 => if (items[i].data == .rectangle) {
                    const at = items[i].bbox;
                    try commands.insert(testing.allocator, i + 1, .{ .data = .scissor_end });
                    try commands.insert(testing.allocator, i, .{ .bbox = .init(at.x + 2, at.y + 1, at.w / 2 + 1, at.h), .data = .{ .scissor_start = .{ .horizontal = true, .vertical = random.boolean() } } });
                },
                else => unreachable,
            }
        }

        const regions = try damage.update(testing.allocator, commands.items, .init(size, size));
        if (step == 0) try renderAll(commands.items, surface(&partial), null);
        if (step > 0) try renderAll(commands.items, surface(&partial), regions);
        try renderAll(commands.items, surface(&full), null);
        for (regions) |r| damaged_pixels += @intFromFloat(r.w * r.h);
        if (!std.mem.eql(u8, &full, &partial)) {
            std.debug.print("step {d}: redrawing {any} differs from redrawing everything\n", .{ step, regions });
            return error.TestDamageMissed;
        }
    }
    // and the damage is much less than redrawing everything every time
    try testing.expect(damaged_pixels < 300 * size * size / 2);
}
