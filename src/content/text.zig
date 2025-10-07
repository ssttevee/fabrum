const std = @import("std");
const root = @import("../root.zig");

const LayoutContent = root.LayoutContent;
const Color = root.Color;
const Vec2 = root.Vec2;
const LayoutConstraints = root.LayoutConstraints;

text: []const u8,
style: TextStyle = .{},

content: LayoutContent = .{
    .vtable = vtable,
},

const vtable = &LayoutContent.VTable{
    .measure = measureFn,
    .debug_name = "Text",
};

const TextContent = @This();

pub const TextWrapMode = enum { characters, words, none };
pub const TextAlign = enum { left, center, right };

pub const TextMeasureFn = *const fn (text: []const u8, style: TextStyle) Vec2;

pub const TextStyle = struct {
    font: ?[:0]const u8 = null,
    font_size: f32 = 16,
    line_height: f32 = 0,
    letter_spacing: f32 = 0,
    wrap_mode: TextWrapMode = .words,
    alignment: TextAlign = .left,
    color: Color = .black,
    measure_fn: ?TextMeasureFn = null,

    pub fn resolvedLineHeight(self: TextStyle) f32 {
        return if (self.line_height > 0) self.line_height else self.font_size * 1.2;
    }

    pub fn glyphAdvanceApprox(self: TextStyle) f32 {
        return self.font_size * 0.58 + self.letter_spacing;
    }
};

pub fn init(text: []const u8, style: TextStyle) TextContent {
    return .{ .text = text, .style = style };
}

pub fn deinit(self: *TextContent) void {
    self.* = undefined;
}

pub fn isTextContent(content: *const LayoutContent) bool {
    return content.vtable == vtable;
}

pub fn asTextContent(content: *const LayoutContent) ?*const TextContent {
    if (!isTextContent(content)) {
        return null;
    }

    return @fieldParentPtr("content", content);
}

pub const LineIterator = struct {
    width: f32,
    content: *const TextContent,
    pos: usize = 0,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.content.text.len) {
            return null;
        }

        var line_remaining = blk: {
            if (std.mem.indexOfScalarPos(u8, self.content.text, self.pos, '\n')) |index| {
                break :blk self.content.text[self.pos..index];
            } else {
                break :blk self.content.text[self.pos..];
            }
        };

        if (self.content.style.wrap_mode == .none) {
            self.pos += line_remaining.len + 1;
            return line_remaining;
        }

        const approx_char_width = if (self.content.style.measure_fn) |measure_fn|
            measure_fn("M", self.content.style).x
        else
            self.content.style.glyphAdvanceApprox();

        const max_chars_per_line: usize = @intFromFloat(@divFloor(self.width, approx_char_width));
        if (self.content.style.wrap_mode == .characters) {
            const n = @min(max_chars_per_line, line_remaining.len);
            self.pos += n;
            return line_remaining[0..n];
        }

        if (self.content.style.measure_fn) |measure_fn| {
            const line_width = measure_fn(line_remaining, self.content.style).x;
            if (line_width <= self.width) {
                self.pos += line_remaining.len + 1;
                return line_remaining;
            }

            var word_start: usize = 0;
            var current_width: f32 = 0;
            var last_break: ?usize = null;

            var i: usize = 0;
            while (i < line_remaining.len) : (i += 1) {
                if (line_remaining[i] == ' ') {
                    const word = line_remaining[word_start..i];
                    const word_width = measure_fn(word, self.content.style).x;

                    if (current_width + word_width <= self.width) {
                        current_width += word_width;
                        if (i + 1 < line_remaining.len) {
                            const space_width = measure_fn(" ", self.content.style).x;
                            current_width += space_width;
                        }
                        last_break = i;
                        word_start = i + 1;
                    } else {
                        if (last_break) |break_pos| {
                            self.pos += break_pos + 1;
                            return line_remaining[0..break_pos];
                        }
                        self.pos += i;
                        return line_remaining[0..i];
                    }
                }
            }

            if (word_start < line_remaining.len) {
                const word = line_remaining[word_start..];
                const word_width = measure_fn(word, self.content.style).x;

                if (current_width + word_width <= self.width) {
                    self.pos += line_remaining.len + 1;
                    return line_remaining;
                } else if (last_break) |break_pos| {
                    self.pos += break_pos + 1;
                    return line_remaining[0..break_pos];
                }
            }

            self.pos += line_remaining.len + 1;
            return line_remaining;
        } else {
            if (line_remaining.len < max_chars_per_line) {
                self.pos += line_remaining.len + 1;
                return line_remaining;
            }

            if (std.mem.lastIndexOfScalar(u8, line_remaining[0..max_chars_per_line], ' ')) |index| {
                self.pos += index + 1;
                return line_remaining[0..index];
            }

            if (std.mem.indexOfScalar(u8, line_remaining, ' ')) |index| {
                self.pos += index + 1;
                return line_remaining[0..index];
            }

            self.pos += line_remaining.len + 1;
            return line_remaining;
        }
    }
};

pub fn lines(self: *const TextContent, width: f32) LineIterator {
    return .{
        .content = self,
        .width = width,
    };
}

fn measureFn(content: *const LayoutContent, constraints: LayoutConstraints) Vec2 {
    const self: *const TextContent = @fieldParentPtr("content", content);

    if (self.style.measure_fn) |measure_fn| {
        return measureWithCustomFn(self, constraints, measure_fn);
    } else {
        return measureWithHeuristic(self, constraints);
    }
}

fn measureWithCustomFn(self: *const TextContent, constraints: LayoutConstraints, measure_fn: TextMeasureFn) Vec2 {
    var line_count: usize = 0;
    var max_line_width: f32 = 0;

    const line_height = self.style.resolvedLineHeight();

    var line_iterator = std.mem.splitScalar(u8, self.text, '\n');
    if (constraints.max_width == null or self.style.wrap_mode == .none) {
        while (line_iterator.next()) |line| {
            const dims = measure_fn(line, self.style);
            max_line_width = @max(max_line_width, dims.x);
            line_count += 1;
        }
    } else {
        const max_width = constraints.max_width.?;

        while (line_iterator.next()) |line| {
            if (line.len == 0) {
                line_count += 1;
                continue;
            }

            const full_width = measure_fn(line, self.style).x;
            if (full_width <= max_width) {
                max_line_width = @max(max_line_width, full_width);
                line_count += 1;
                continue;
            }

            if (self.style.wrap_mode == .characters) {
                var remaining = line;
                while (remaining.len > 0) {
                    var best_len: usize = remaining.len;
                    var best_width = measure_fn(remaining, self.style).x;

                    if (best_width > max_width) {
                        var low: usize = 1;
                        var high: usize = remaining.len;

                        while (low < high) {
                            const mid = (low + high + 1) / 2;
                            const test_width = measure_fn(remaining[0..mid], self.style).x;

                            if (test_width <= max_width) {
                                low = mid;
                            } else {
                                high = mid - 1;
                            }
                        }

                        best_len = low;
                        best_width = measure_fn(remaining[0..best_len], self.style).x;
                    }

                    max_line_width = @max(max_line_width, best_width);
                    line_count += 1;
                    remaining = remaining[best_len..];
                }
            } else if (self.style.wrap_mode == .words) {
                var word_start: usize = 0;
                var current_width: f32 = 0;
                var current_line_width: f32 = 0;

                var i: usize = 0;
                while (i <= line.len) : (i += 1) {
                    if (i == line.len or line[i] == ' ') {
                        const word = line[word_start..i];
                        const word_width = if (word.len > 0) measure_fn(word, self.style).x else 0;

                        const space_width = if (current_width > 0) measure_fn(" ", self.style).x else 0;

                        if (current_width + space_width + word_width <= max_width) {
                            current_width += space_width + word_width;
                            current_line_width = current_width;
                        } else {
                            if (current_width > 0) {
                                max_line_width = @max(max_line_width, current_line_width);
                                line_count += 1;
                                current_width = word_width;
                                current_line_width = word_width;
                            } else {
                                max_line_width = @max(max_line_width, word_width);
                                line_count += 1;
                                current_width = 0;
                                current_line_width = 0;
                            }
                        }

                        word_start = i + 1;
                    }
                }

                if (current_width > 0) {
                    max_line_width = @max(max_line_width, current_line_width);
                    line_count += 1;
                }
            }
        }
    }

    return .init(max_line_width, line_height * @as(f32, @floatFromInt(line_count)));
}

fn measureWithHeuristic(self: *const TextContent, constraints: LayoutConstraints) Vec2 {
    const approx_char_width = self.style.glyphAdvanceApprox();

    var line_count: usize = 0;
    var max_line_len: usize = 0;

    var line_iterator = std.mem.splitScalar(u8, self.text, '\n');
    if (constraints.max_width == null or self.style.wrap_mode == .none) {
        while (line_iterator.next()) |line| {
            max_line_len = @max(max_line_len, line.len);
            line_count += 1;
        }
    } else {
        const max_width = constraints.max_width.?;
        const max_chars_per_line: usize = @intFromFloat(@divFloor(max_width, approx_char_width));
        if (self.style.wrap_mode == .words) {
            while (line_iterator.next()) |line| {
                var word_iterator = std.mem.splitScalar(u8, line, ' ');

                var current_line_len: usize = 0;
                while (word_iterator.next()) |word| {
                    if (current_line_len > 0) {
                        if (current_line_len + 1 + word.len > max_chars_per_line) {
                            max_line_len = @max(max_line_len, current_line_len);
                            line_count += 1;
                            current_line_len = 0;
                        }

                        current_line_len += 1;
                    }

                    current_line_len += word.len;
                }

                max_line_len = @max(max_line_len, current_line_len);
                line_count += 1;
            }
        } else if (self.style.wrap_mode == .characters) {
            while (line_iterator.next()) |line| {
                const n = @divFloor(line.len + max_chars_per_line - 1, max_chars_per_line);
                if (n > 1) {
                    max_line_len = max_chars_per_line;
                }

                line_count += @max(n, 1);
            }
        }
    }

    return .init(
        approx_char_width * @as(f32, @floatFromInt(max_line_len)),
        self.style.resolvedLineHeight() * @as(f32, @floatFromInt(line_count)),
    );
}
