const std = @import("std");

const root = @import("../root.zig");
const LayoutContent = root.LayoutContent;
const Color = root.Color;
const Vec2 = root.Vec2;
const LayoutConstraints = root.LayoutConstraints;

pub const WrapMode = enum { characters, words, none };
pub const Align = enum { left, center, right };

pub const Style = struct {
    font_name: ?[:0]const u8 = null,
    font_weight: ?[:0]const u8 = null,
    font_size: f32 = 16,
    line_height: f32 = 1.2,
    letter_spacing: f32 = 0,
    wrap_mode: WrapMode = .words,
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

/// Text content context namespace wrapper
pub fn ContentCachedContext(comptime Context: type) type {
    return struct {
        allocator: std.mem.Allocator,
        state: *State,
        inner: Context,

        pub const State = struct {
            cache: std.StringHashMapUnmanaged(Vec2),
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
            self.state.cache.deinit(self.allocator);
            self.allocator.destroy(self.state);
            if (@hasDecl(Context, "deinit")) {
                self.inner.deinit();
            }
            self.* = undefined;
        }

        pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2 {
            if (self.state.cache.get(text)) |cached| {
                return cached;
            }

            const size = try self.inner.measureText(text, style);
            self.state.cache.put(self.allocator, text, size) catch {
                // if we ran out of memory, then we've got bigger problems
            };
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
