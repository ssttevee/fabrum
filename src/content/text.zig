const std = @import("std");

const root = @import("../root.zig");
const LayoutContent = root.LayoutContent;
const Color = root.Color;
const Vec2 = root.Vec2;
const LayoutConstraints = root.LayoutConstraints;

pub const Wrap = enum { characters, words, none };
pub const Align = enum { left, center, right };
pub const Weight = enum { ultralight, thin, light, regular, medium, semibold, bold, heavy, black };

pub const Style = struct {
    font_family: ?[:0]const u8 = null,
    font_weight: Weight = .regular,
    font_size: f32 = 16,
    line_height: f32 = 1.2,
    letter_spacing: f32 = 0,
    wrap_mode: Wrap = .words,
    alignment: Align = .left,
    color: Color = .black,

    fn resolvedLineHeight(self: Style) f32 {
        return if (self.line_height > 0) self.line_height else 1.2;
    }
};

/// A text content with a text measuring algorithm based on latin character heuristics
///
/// Useful as a quick and dirty placeholder, but almost guaranteed to be wrong.
pub const HeuristicContent = Content(struct {
    pub const default: @This() = undefined;

    pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
        _ = self;

        var pos: usize = 0;
        var lines: usize = 1;
        var max_line_chars: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |index| {
            max_line_chars = @max(max_line_chars, index - pos);
            pos = index + 1;
            lines += 1;
        }

        return .init(
            (style.font_size * 0.58 + style.letter_spacing) * @as(f32, @floatFromInt(@max(max_line_chars, text.len - pos))),
            style.resolvedLineHeight() * style.font_size * @as(f32, @floatFromInt(lines)),
        );
    }
});

/// The parts of a measurement request that can change the measured size.
const MeasureKey = struct {
    text: []const u8,
    font_family: ?[:0]const u8,
    font_weight: Weight,
    font_size: f32,
    line_height: f32,
    letter_spacing: f32,

    fn init(text: []const u8, style: Style) MeasureKey {
        return .{
            .text = text,
            .font_family = style.font_family,
            .font_weight = style.font_weight,
            .font_size = style.font_size,
            .line_height = style.line_height,
            .letter_spacing = style.letter_spacing,
        };
    }

    /// Copies the borrowed strings so the key can outlive the caller's memory.
    fn dupe(self: MeasureKey, allocator: std.mem.Allocator) !MeasureKey {
        const text = try allocator.dupe(u8, self.text);
        errdefer allocator.free(text);
        const font_family = if (self.font_family) |f| try allocator.dupeSentinel(u8, f, 0) else null;

        var key = self;
        key.text = text;
        key.font_family = font_family;
        return key;
    }

    fn free(self: MeasureKey, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.font_family) |f| allocator.free(f);
    }

    const HashContext = struct {
        pub fn hash(_: HashContext, key: MeasureKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key.text, .Deep);
            std.hash.autoHashStrat(&hasher, key.font_family, .Deep);
            std.hash.autoHash(&hasher, key.font_weight);
            // floats are compared bitwise so equal keys always hash equally
            std.hash.autoHash(&hasher, @as(u32, @bitCast(key.font_size)));
            std.hash.autoHash(&hasher, @as(u32, @bitCast(key.line_height)));
            std.hash.autoHash(&hasher, @as(u32, @bitCast(key.letter_spacing)));
            return hasher.final();
        }

        pub fn eql(_: HashContext, a: MeasureKey, b: MeasureKey) bool {
            const family_eql = if (a.font_family != null and b.font_family != null)
                std.mem.eql(u8, a.font_family.?, b.font_family.?)
            else
                a.font_family == null and b.font_family == null;

            return family_eql and
                std.mem.eql(u8, a.text, b.text) and
                a.font_weight == b.font_weight and
                @as(u32, @bitCast(a.font_size)) == @as(u32, @bitCast(b.font_size)) and
                @as(u32, @bitCast(a.line_height)) == @as(u32, @bitCast(b.line_height)) and
                @as(u32, @bitCast(a.letter_spacing)) == @as(u32, @bitCast(b.letter_spacing));
        }
    };
};

/// Text content context namespace wrapper
pub fn ContentCachedContext(comptime Context: type) type {
    return struct {
        allocator: std.mem.Allocator,
        state: *State,
        inner: Context,

        pub const State = struct {
            cache: std.HashMapUnmanaged(MeasureKey, Vec2, MeasureKey.HashContext, std.hash_map.default_max_load_percentage),
        };

        pub fn init(allocator: std.mem.Allocator, parent: Context) !@This() {
            const state = try allocator.create(State);
            state.* = .{ .cache = .empty };
            return .{
                .allocator = allocator,
                .state = state,
                .inner = parent,
            };
        }

        pub fn deinit(self: *@This()) void {
            var keys = self.state.cache.keyIterator();
            while (keys.next()) |key| {
                key.free(self.allocator);
            }
            self.state.cache.deinit(self.allocator);
            self.allocator.destroy(self.state);
            if (@hasDecl(Context, "deinit")) {
                self.inner.deinit();
            }
            self.* = undefined;
        }

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            const key: MeasureKey = .init(text, style);
            if (self.state.cache.get(key)) |cached| {
                return cached;
            }

            const size = try self.inner.measureText(text, style);

            // caching is best effort: if we ran out of memory, then we've got bigger problems
            const owned_key = key.dupe(self.allocator) catch return size;
            self.state.cache.putNoClobber(self.allocator, owned_key, size) catch owned_key.free(self.allocator);

            return size;
        }
    };
}

pub fn Content(
    /// A namespace that provides `pub fn measureText(self: @This(), text: []const u8, style: TextStyle) Vec2`.
    ///
    ///
    comptime TextContext: type,
) type {
    return struct {
        context: TextContext = if (@hasDecl(TextContext, "default")) TextContext.default else undefined,
        text: []const u8,
        style: Style = .{},

        content: LayoutContent = .{
            .vtable = vtable,
        },

        const vtable = &LayoutContent.VTable{
            .measure = measureFn,
            .debug_name = "Text",
        };

        const Self = @This();

        pub const Context = TextContext;

        pub fn init(text: []const u8, style: Style) Self {
            return .{ .text = text, .style = style };
        }

        pub fn initContext(text: []const u8, style: Style, context: TextContext) Self {
            return .{ .text = text, .style = style, .context = context };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn isTextContent(content: *const LayoutContent) bool {
            return content.vtable == vtable;
        }

        pub fn asTextContent(content: *const LayoutContent) ?*const Self {
            if (!isTextContent(content)) {
                return null;
            }

            return @fieldParentPtr("content", content);
        }

        pub const LineIterator = struct {
            width: f32,
            content: *const Self,
            pos: usize = 0,

            fn textWidth(self: *const LineIterator, text: []const u8) !f32 {
                return (try self.content.context.measureText(text, self.content.style)).x;
            }

            pub fn next(self: *LineIterator) !?[]const u8 {
                if (self.pos >= self.content.text.len) {
                    return null;
                }

                // trim leading spaces
                while (self.content.text[self.pos] == ' ') {
                    self.pos += 1;
                }

                var line_remaining = blk: {
                    if (std.mem.indexOfScalarPos(u8, self.content.text, self.pos, '\n')) |index| {
                        break :blk self.content.text[self.pos..index];
                    } else {
                        break :blk self.content.text[self.pos..];
                    }
                };

                if (self.content.style.wrap_mode == .none or line_remaining.len == 0) {
                    self.pos += line_remaining.len + 1;
                    return line_remaining;
                }

                const line_width = try self.textWidth(line_remaining);
                if (line_width <= self.width) {
                    self.pos += line_remaining.len + 1;
                    return line_remaining;
                }

                var n = line_remaining.len;
                var w = line_width;

                if (self.content.style.wrap_mode == .characters) {
                    // overcompensate
                    while (w > self.width) {
                        n = @intFromFloat(@as(f32, @floatFromInt(n)) * (self.width / w));
                        w = try self.textWidth(line_remaining[0..n]);
                    }

                    // increment until over
                    while (n < line_remaining.len and w < self.width) {
                        n += 1;
                        w = try self.textWidth(line_remaining[0..n]);
                    }

                    // take a step back
                    if (n > 1 and w > self.width) {
                        n -= 1;
                    }

                    self.pos += n;

                    // skip the eol
                    if (n == line_remaining.len) {
                        self.pos += 1;
                    }
                } else {
                    std.debug.assert(self.content.style.wrap_mode == .words);

                    // overcompensate
                    while (w > self.width) {
                        const pos: usize = @intFromFloat(@as(f32, @floatFromInt(n)) * (self.width / w));
                        if (std.mem.lastIndexOfScalar(u8, line_remaining[0..pos], ' ')) |index| {
                            n = index;
                        } else if (std.mem.indexOfScalarPos(u8, line_remaining, pos, ' ')) |index| {
                            n = index;
                        } else {
                            // the line has no spaces so it can't be wrapped
                            break;
                        }

                        w = try self.textWidth(line_remaining[0..n]);
                    }

                    // increment until over
                    while (n < line_remaining.len and w < self.width) {
                        if (std.mem.indexOfScalarPos(u8, line_remaining, n + 1, ' ')) |index| {
                            n = index;
                        } else {
                            // the line has no more breakable spaces
                            n = line_remaining.len;
                        }

                        w = try self.textWidth(line_remaining[0..n]);
                    }

                    // take a step back
                    if (n > 1 and w > self.width) {
                        if (std.mem.lastIndexOfScalar(u8, line_remaining[0..n], ' ')) |index| {
                            n = index;
                        } else {
                            // we only have 1 word at this point, there's nothing we can do
                        }
                    }

                    self.pos += n + 1;
                }

                return line_remaining[0..n];
            }
        };

        pub fn lines(self: *const Self, width: f32) LineIterator {
            return .{
                .content = self,
                .width = width,
            };
        }

        pub const LineIteratorWithSizes = struct {
            base: LineIterator,
            line_height: f32,

            pub const Line = struct {
                text: []const u8,
                size: Vec2,
            };

            pub fn next(self: *LineIteratorWithSizes) !?Line {
                const is_first = self.base.pos == 0;
                const line = try self.base.next() orelse return null;
                const size = try self.base.content.context.measureText(line, self.base.content.style);
                return .{
                    .text = line,
                    .size = .init(
                        size.x,
                        // first line must be have line height 1 so the bbox is correct
                        size.y * (if (is_first) 1 else self.line_height),
                    ),
                };
            }
        };

        pub fn linesWithSizes(self: *const Self, width: f32) LineIteratorWithSizes {
            return .{
                .base = self.lines(width),
                .line_height = self.style.resolvedLineHeight(),
            };
        }

        fn measureFn(content: *const LayoutContent, constraints: LayoutConstraints) LayoutContent.MeasureError!Vec2 {
            const self: *const Self = @fieldParentPtr("content", content);

            var size = Vec2.zero;

            var it = self.linesWithSizes(constraints.max_width orelse std.math.inf(f32));
            while (it.next() catch return error.MeasureFailed) |line| {
                size.x = @max(size.x, line.size.x);
                size.y += line.size.y;
            }

            return size;
        }
    };
}

test "ContentCachedContext caches by text and measuring style" {
    const CountingContext = struct {
        calls: *usize,

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            self.calls.* += 1;
            return .init(@as(f32, @floatFromInt(text.len)) * style.font_size, style.font_size);
        }
    };

    var calls: usize = 0;
    var ctx = try ContentCachedContext(CountingContext).init(std.testing.allocator, .{ .calls = &calls });
    defer ctx.deinit();

    try std.testing.expectEqual(Vec2.init(80, 16), try ctx.measureText("hello", .{}));
    try std.testing.expectEqual(Vec2.init(80, 16), try ctx.measureText("hello", .{}));
    try std.testing.expectEqual(1, calls);

    // color and alignment don't change the size, so they share the entry
    _ = try ctx.measureText("hello", .{ .color = .white, .alignment = .right });
    try std.testing.expectEqual(1, calls);

    // anything that changes the size is a separate entry
    try std.testing.expectEqual(Vec2.init(160, 32), try ctx.measureText("hello", .{ .font_size = 32 }));
    _ = try ctx.measureText("hello", .{ .font_family = "Helvetica" });
    _ = try ctx.measureText("hello", .{ .font_weight = .bold });
    try std.testing.expectEqual(4, calls);
}

test "ContentCachedContext keys don't borrow the caller's memory" {
    const CountingContext = struct {
        calls: *usize,

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            self.calls.* += 1;
            return .init(@as(f32, @floatFromInt(text.len)) * style.font_size, style.font_size);
        }
    };

    var calls: usize = 0;
    var ctx = try ContentCachedContext(CountingContext).init(std.testing.allocator, .{ .calls = &calls });
    defer ctx.deinit();

    var text_buf = "hello".*;
    var family_buf = "Helvetica".*;
    _ = try ctx.measureText(&text_buf, .{ .font_family = &family_buf });

    // reusing the buffers must not corrupt the cached entry
    text_buf = "world".*;
    family_buf = "Monaco\x00\x00\x00".*;
    _ = try ctx.measureText("hello", .{ .font_family = "Helvetica" });
    try std.testing.expectEqual(1, calls);
}
