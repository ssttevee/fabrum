const std = @import("std");

const fabrum = @import("../root.zig");
const layout = @import("../layout.zig");
const Color = fabrum.Color;
const Vec2 = fabrum.Vec2;
const LayoutContent = layout.Content;
const LayoutConstraints = layout.Constraints;

/// How text breaks into lines under its available width. `words` splits at
/// ASCII spaces and line breaks; `none` only at line breaks. `characters` is
/// currently byte-based and may split multibyte UTF-8; use `words` for it.
pub const Wrap = enum { characters, words, none };
pub const Align = enum { left, center, right };
pub const Weight = enum { ultralight, thin, light, regular, medium, semibold, bold, heavy, black };

/// What happens to a line that is wider than the space it is given, after
/// wrapping. Lines are cut on UTF-8 character boundaries, as measured by
/// the text context, so the cut line with its ellipsis fits the width.
pub const Overflow = enum {
    /// The line keeps its width and draws past its box.
    visible,
    /// The end of the line is cut off for an ellipsis: `A very long na…`.
    ellipsis_end,
    /// The middle of the line is cut out for an ellipsis, keeping both its
    /// start and its end: `raspios-bo…lite.img.xz`. Suits file names.
    ellipsis_middle,
};

/// The ellipsis that marks where `Overflow` cut a line.
pub const ellipsis = "\u{2026}";

pub const Style = struct {
    font_family: ?[:0]const u8 = null,
    font_weight: Weight = .regular,
    font_size: f32 = 16,
    line_height: f32 = 1.2,
    letter_spacing: f32 = 0,
    wrap_mode: Wrap = .words,
    /// With an ellipsis, text can be squeezed narrower than its lines, down
    /// to the width of the ellipsis, so containers around it can shrink.
    /// Usually combined with `wrap_mode = .none`; with wrapping, only lines
    /// that are still too wide, such as one long word, are cut.
    overflow: Overflow = .visible,
    alignment: Align = .left,
    color: Color = .black,

    /// Every field of `Style` as an optional that defaults to null, for
    /// `with`. Fields that are optional in `Style`, such as `font_family`,
    /// take a `Clearable` instead of their value.
    pub const Overrides = Partial(Style);

    /// A copy of the style with the fields set in `overrides` replaced, for
    /// example `style.with(.{ .wrap_mode = .none, .color = .white })`. Null
    /// leaves a field unchanged.
    ///
    /// Optional fields are set with `.{ .set = value }` and cleared with
    /// `.clear`, as in `.font_family = .clear` for the system font, since a
    /// plain `null` would mean "unchanged".
    pub fn with(self: Style, overrides: Overrides) Style {
        var style = self;
        inline for (@typeInfo(Style).@"struct".field_names) |name| {
            if (@field(overrides, name)) |value| {
                @field(style, name) = if (comptime isOptional(@FieldType(Style, name))) switch (value) {
                    .clear => null,
                    .set => |set| set,
                } else value;
            }
        }
        return style;
    }

    fn resolvedLineHeight(self: Style) f32 {
        return if (self.line_height > 0) self.line_height else 1.2;
    }
};

/// Hashes every field of `style`, floats by their bits.
fn hashStyle(hasher: *std.hash.Wyhash, style: Style) void {
    inline for (@typeInfo(Style).@"struct".field_names) |name| {
        const value = @field(style, name);
        switch (@TypeOf(value)) {
            f32 => std.hash.autoHash(hasher, @as(u32, @bitCast(value))),
            ?[:0]const u8 => {
                std.hash.autoHash(hasher, value != null);
                if (value) |v| hasher.update(v);
            },
            else => std.hash.autoHash(hasher, value),
        }
    }
}

/// How `Style.with` changes a field that is optional in `Style`: `.clear`
/// sets it to null, `.{ .set = value }` to a value.
pub fn Clearable(comptime T: type) type {
    return union(enum) {
        clear,
        set: T,
    };
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// `T` with every field made optional and defaulting to null, where null
/// means "unchanged". A field that is already optional, `?U`, becomes a
/// `?Clearable(U)`, so it can still be changed to null. Generated from
/// `T`'s fields, so it can't fall out of step with them.
fn Partial(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    const n = info.field_names.len;

    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    for (info.field_names, info.field_types, 0..) |name, Field, i| {
        const Override = if (isOptional(Field)) Clearable(@typeInfo(Field).optional.child) else Field;
        const none: ?Override = null;
        names[i] = name;
        types[i] = ?Override;
        attrs[i] = .{ .default_value_ptr = &none };
    }

    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

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
            return familyEql(a.font_family, b.font_family) and
                std.mem.eql(u8, a.text, b.text) and
                a.font_weight == b.font_weight and
                @as(u32, @bitCast(a.font_size)) == @as(u32, @bitCast(b.font_size)) and
                @as(u32, @bitCast(a.line_height)) == @as(u32, @bitCast(b.line_height)) and
                @as(u32, @bitCast(a.letter_spacing)) == @as(u32, @bitCast(b.letter_spacing));
        }

        /// Whether both name the same family, or neither names one.
        fn familyEql(a: ?[:0]const u8, b: ?[:0]const u8) bool {
            const family_a = a orelse return b == null;
            const family_b = b orelse return false;
            return std.mem.eql(u8, family_a, family_b);
        }
    };
};

/// Wraps a text context so each measurement is made once and then served
/// from a cache keyed by the text and the parts of the style that change its
/// size.
///
/// Apps that rebuild their layout every frame measure new strings all the
/// time, such as a changing percentage, so the cache is bounded: once it
/// holds `State.max_entries` entries it is emptied before the next one is
/// added, and whatever is still on screen is measured again.
pub fn CachedContext(comptime Context: type) type {
    return struct {
        allocator: std.mem.Allocator,
        state: *State,
        inner: Context,

        pub const State = struct {
            cache: std.HashMapUnmanaged(MeasureKey, Vec2, MeasureKey.HashContext, std.hash_map.default_max_load_percentage),
            max_entries: usize = default_max_entries,
        };

        pub const default_max_entries = 1024;

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
            self.clear();
            self.state.cache.deinit(self.allocator);
            self.allocator.destroy(self.state);
            if (@hasDecl(Context, "deinit")) {
                self.inner.deinit();
            }
            self.* = undefined;
        }

        /// Drops every cached measurement.
        pub fn clear(self: @This()) void {
            var keys = self.state.cache.keyIterator();
            while (keys.next()) |key| {
                key.free(self.allocator);
            }
            self.state.cache.clearRetainingCapacity();
        }

        /// Number of cached measurements.
        pub fn count(self: @This()) usize {
            return self.state.cache.count();
        }

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            const key: MeasureKey = .init(text, style);
            if (self.state.cache.get(key)) |cached| {
                return cached;
            }

            const size = try self.inner.measureText(text, style);

            if (self.state.cache.count() >= self.state.max_entries) {
                self.clear();
            }

            // caching is best effort: if we ran out of memory, then we've got bigger problems
            const owned_key = key.dupe(self.allocator) catch return size;
            self.state.cache.putNoClobber(self.allocator, owned_key, size) catch owned_key.free(self.allocator);

            return size;
        }
    };
}

fn isContinuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

pub fn Content(
    /// A namespace that provides `pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2`.
    ///
    ///
    comptime TextContext: type,
) type {
    return struct {
        context: TextContext = if (@hasDecl(TextContext, "default")) TextContext.default else undefined,
        text: []const u8,
        style: Style = .{},

        /// Measured under its ancestors' width (`layout.Content.limit`):
        /// a text asks for no more than the width it can get, so a
        /// container that fits it stays within what holds them, and it
        /// wraps at the width it is finally given.
        content: LayoutContent = .{
            .vtable = vtable,
            .limit = .ancestors,
        },

        const vtable = &LayoutContent.VTable{
            .measure = measureFn,
            .measure_min = measureMinFn,
            .fingerprint = fingerprintFn,
            .debug_name = "Text",
        };

        fn fingerprintFn(content: *const LayoutContent) u64 {
            const self: *const Self = @fieldParentPtr("content", content);
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(self.text);
            hashStyle(&hasher, self.style);
            return hasher.final();
        }

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
            /// Holds the last line cut by `Style.overflow`.
            buffer: [max_cut_line_bytes]u8 = undefined,

            /// The most bytes a line cut by `Style.overflow` keeps,
            /// ellipsis included. Longer cuts are cut shorter still.
            pub const max_cut_line_bytes = 256;

            fn textWidth(self: *const LineIterator, text: []const u8) !f32 {
                return (try self.content.context.measureText(text, self.content.style)).x;
            }

            /// The next line to draw, cut to fit the width if the style's
            /// `overflow` asks for it. A cut line is only valid until the
            /// next call.
            pub fn next(self: *LineIterator) !?[]const u8 {
                const line = try self.nextLine() orelse return null;
                if (self.content.style.overflow == .visible or !std.math.isFinite(self.width)) return line;
                if (try self.textWidth(line) <= self.width) return line;
                return try self.cut(line);
            }

            /// `line` with as much as fits around an ellipsis, cut as
            /// `Style.overflow` says. Searches for the most bytes to keep,
            /// measuring each try.
            fn cut(self: *LineIterator, line: []const u8) ![]const u8 {
                const most = @min(line.len -| 1, self.buffer.len - ellipsis.len);
                var low: usize = 0;
                var high: usize = most;
                while (low < high) {
                    const mid = low + (high - low + 1) / 2;
                    if (try self.textWidth(self.compose(line, mid)) <= self.width) {
                        low = mid;
                    } else {
                        high = mid - 1;
                    }
                }
                // nothing but the ellipsis fits when `low` is zero
                return self.compose(line, low);
            }

            /// Writes `line` with about `keep` of its bytes kept around an
            /// ellipsis into the buffer.
            fn compose(self: *LineIterator, line: []const u8, keep: usize) []const u8 {
                var head_len: usize, var tail_start: usize = switch (self.content.style.overflow) {
                    .visible => unreachable,
                    .ellipsis_end => .{ keep, line.len },
                    .ellipsis_middle => .{ (keep + 1) / 2, line.len - keep / 2 },
                };
                while (head_len > 0 and isContinuation(line[head_len])) head_len -= 1;
                while (tail_start < line.len and isContinuation(line[tail_start])) tail_start += 1;
                // the ellipsis takes the place of spaces at the cut
                while (head_len > 0 and line[head_len - 1] == ' ') head_len -= 1;
                while (tail_start < line.len and line[tail_start] == ' ') tail_start += 1;

                const tail = line[tail_start..];
                var len: usize = 0;
                for ([_][]const u8{ line[0..head_len], ellipsis, tail }) |part| {
                    @memcpy(self.buffer[len..][0..part.len], part);
                    len += part.len;
                }
                return self.buffer[0..len];
            }

            fn nextLine(self: *LineIterator) !?[]const u8 {
                if (self.pos >= self.content.text.len) {
                    return null;
                }

                // trim leading spaces
                while (self.pos < self.content.text.len and self.content.text[self.pos] == ' ') {
                    self.pos += 1;
                }

                const line_remaining = if (std.mem.indexOfScalarPos(u8, self.content.text, self.pos, '\n')) |index|
                    self.content.text[self.pos..index]
                else
                    self.content.text[self.pos..];

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
                        const shorter = if (std.mem.lastIndexOfScalar(u8, line_remaining[0..pos], ' ')) |index|
                            index
                        else if (std.mem.indexOfScalarPos(u8, line_remaining, pos, ' ')) |index|
                            index
                        else
                            // the line has no spaces so it can't be wrapped
                            break;

                        // the first word alone is too wide, and can't be cut any shorter
                        if (shorter >= n) break;

                        n = shorter;
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

        /// Text that is cut with an ellipsis can be squeezed down to the
        /// width of the ellipsis; text that wraps, down to the widest
        /// piece it can't break, a word or a character, as it wraps the
        /// rest at whatever width it is given. Text that does neither
        /// keeps its width.
        fn measureMinFn(content: *const LayoutContent, constraints: LayoutConstraints) LayoutContent.MeasureError!Vec2 {
            const self: *const Self = @fieldParentPtr("content", content);
            const size = try measureFn(content, constraints);
            const min_width = switch (self.style.overflow) {
                .ellipsis_end, .ellipsis_middle => (self.context.measureText(ellipsis, self.style) catch return error.MeasureFailed).x,
                .visible => switch (self.style.wrap_mode) {
                    .none => return size,
                    .words, .characters => try self.widestPiece(),
                },
            };
            return .init(@min(size.x, min_width), size.y);
        }

        /// The width of the widest piece the text can't break when it
        /// wraps: a word between spaces or line breaks, or a character.
        fn widestPiece(self: *const Self) LayoutContent.MeasureError!f32 {
            var widest: f32 = 0;
            var pos: usize = 0;
            while (pos < self.text.len) {
                const end = switch (self.style.wrap_mode) {
                    .words => std.mem.indexOfAnyPos(u8, self.text, pos, " \n") orelse self.text.len,
                    .characters => @min(pos + (std.unicode.utf8ByteSequenceLength(self.text[pos]) catch 1), self.text.len),
                    .none => unreachable,
                };
                if (end > pos) {
                    const piece = self.context.measureText(self.text[pos..end], self.style) catch return error.MeasureFailed;
                    widest = @max(widest, piece.x);
                }
                pos = @max(end, pos + 1);
            }
            return widest;
        }
    };
}

test "CachedContext caches by text and measuring style" {
    const CountingContext = struct {
        calls: *usize,

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            self.calls.* += 1;
            return .init(@as(f32, @floatFromInt(text.len)) * style.font_size, style.font_size);
        }
    };

    var calls: usize = 0;
    var ctx = try CachedContext(CountingContext).init(std.testing.allocator, .{ .calls = &calls });
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

test "CachedContext keys don't borrow the caller's memory" {
    const CountingContext = struct {
        calls: *usize,

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            self.calls.* += 1;
            return .init(@as(f32, @floatFromInt(text.len)) * style.font_size, style.font_size);
        }
    };

    var calls: usize = 0;
    var ctx = try CachedContext(CountingContext).init(std.testing.allocator, .{ .calls = &calls });
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

test "CachedContext stays within its entry limit" {
    const CountingContext = struct {
        calls: *usize,

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            self.calls.* += 1;
            return .init(@as(f32, @floatFromInt(text.len)) * style.font_size, style.font_size);
        }
    };

    var calls: usize = 0;
    var ctx = try CachedContext(CountingContext).init(std.testing.allocator, .{ .calls = &calls });
    defer ctx.deinit();
    ctx.state.max_entries = 2;

    _ = try ctx.measureText("10%", .{});
    _ = try ctx.measureText("11%", .{});
    try std.testing.expectEqual(2, ctx.count());

    // a third string empties the full cache first
    try std.testing.expectEqual(Vec2.init(48, 16), try ctx.measureText("12%", .{}));
    try std.testing.expectEqual(1, ctx.count());
    try std.testing.expectEqual(3, calls);

    // so the evicted entries are measured again, the kept one is not
    _ = try ctx.measureText("12%", .{});
    _ = try ctx.measureText("10%", .{});
    try std.testing.expectEqual(4, calls);
}

test "lines of text that is only spaces are empty" {
    const blank: HeuristicContent = .init("   ", .{ .font_size = 10 });
    var lines = blank.lines(100);
    try std.testing.expectEqualStrings("", (try lines.next()).?);
    try std.testing.expectEqual(null, try lines.next());

    // wrapping at a space leaves only spaces on the next line
    const trailing: HeuristicContent = .init("ab  ", .{ .font_size = 10, .wrap_mode = .characters });
    var wrapped = trailing.lines(12);
    while (try wrapped.next()) |_| {}
}

test "a first word wider than the line is put on a line of its own" {
    const t: HeuristicContent = .init("verylongword rest", .{ .font_size = 10 });
    var lines = t.lines(30);
    try std.testing.expectEqualStrings("verylongword", (try lines.next()).?);
    try std.testing.expectEqualStrings("rest", (try lines.next()).?);
    try std.testing.expectEqual(null, try lines.next());
}

test "Style.with replaces only the fields it is given" {
    const base: Style = .{ .font_size = 14, .color = .white };
    const changed = base.with(.{ .wrap_mode = .none, .font_weight = .bold });
    try std.testing.expectEqual(Wrap.none, changed.wrap_mode);
    try std.testing.expectEqual(Weight.bold, changed.font_weight);
    try std.testing.expectEqual(14, changed.font_size);
    try std.testing.expectEqual(Color.white, changed.color);
    try std.testing.expectEqual(Wrap.words, base.wrap_mode);
}

test "Style.with sets and clears optional fields" {
    const system: Style = .{ .font_size = 14 };
    const mono = system.with(.{ .font_family = .{ .set = "Menlo" } });
    try std.testing.expectEqualStrings("Menlo", mono.font_family.?);
    // null leaves the family alone, `.clear` removes it
    try std.testing.expectEqualStrings("Menlo", mono.with(.{ .font_size = 12 }).font_family.?);
    const cleared = mono.with(.{ .font_family = .clear });
    try std.testing.expectEqual(null, cleared.font_family);
    try std.testing.expectEqual(14, cleared.font_size);
}

test "lines too wide are cut at the end or in the middle around an ellipsis" {
    // 5.8 points per byte with the heuristic measurer at size 10
    const end: HeuristicContent = .init("abcdefghij", .{ .font_size = 10, .wrap_mode = .none, .overflow = .ellipsis_end });
    var lines = end.lines(40);
    try std.testing.expectEqualStrings("abc" ++ ellipsis, (try lines.next()).?);
    try std.testing.expectEqual(null, try lines.next());

    const middle: HeuristicContent = .init("abcdefghij", .{ .font_size = 10, .wrap_mode = .none, .overflow = .ellipsis_middle });
    lines = middle.lines(40);
    try std.testing.expectEqualStrings("ab" ++ ellipsis ++ "j", (try lines.next()).?);

    // lines that fit are left alone, and too little room leaves the ellipsis
    lines = middle.lines(100);
    try std.testing.expectEqualStrings("abcdefghij", (try lines.next()).?);
    lines = middle.lines(1);
    try std.testing.expectEqualStrings(ellipsis, (try lines.next()).?);

    // the ellipsis replaces spaces at the cut
    const spaced: HeuristicContent = .init("ab cd ef", .{ .font_size = 10, .wrap_mode = .none, .overflow = .ellipsis_end });
    lines = spaced.lines(36);
    try std.testing.expectEqualStrings("ab" ++ ellipsis, (try lines.next()).?);

    // with wrapping, only a word too long for a line is cut
    const wrapped: HeuristicContent = .init("ab verylongword cd", .{ .font_size = 10, .overflow = .ellipsis_middle });
    lines = wrapped.lines(40);
    try std.testing.expectEqualStrings("ab", (try lines.next()).?);
    try std.testing.expectEqualStrings("ve" ++ ellipsis ++ "d", (try lines.next()).?);
    try std.testing.expectEqualStrings("cd", (try lines.next()).?);
}

test "cutting lines never splits a character" {
    const t: HeuristicContent = .init("ééééééééé.img", .{ .font_size = 10, .wrap_mode = .none, .overflow = .ellipsis_middle });
    for (1..20) |width| {
        var lines = t.lines(@floatFromInt(width * 5));
        try std.testing.expect(std.unicode.utf8ValidateSlice((try lines.next()).?));
    }
}
