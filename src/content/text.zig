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

pub const TextStyle = struct {
    font_size: f32 = 16,
    line_height: f32 = 0,
    letter_spacing: f32 = 0,
    wrap_mode: TextWrapMode = .words,
    alignment: TextAlign = .left,
    color: Color = .black,

    pub fn resolvedLineHeight(self: TextStyle) f32 {
        return if (self.line_height > 0) self.line_height else self.font_size * 1.2;
    }

    pub fn glyphAdvanceApprox(self: TextStyle) f32 {
        // crude heuristic: typical Latin average width ratio ~0.55-0.6
        return self.font_size * 0.58 + self.letter_spacing;
    }
};

pub fn init(text: []const u8, style: TextStyle) TextContent {
    return .{ .text = text, .style = style };
}

pub fn deinit(self: *TextContent) void {
    self.lines.deinit();
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
            // can't do anything but let it overflow
            self.pos += line_remaining.len + 1;
            return line_remaining;
        }

        const approx_char_width = self.content.style.glyphAdvanceApprox();

        const max_chars_per_line: usize = @intFromFloat(@divFloor(self.width, approx_char_width));
        if (self.content.style.wrap_mode == .characters) {
            // just emit up to `max_chars_per_line` chars per iteration
            const n = @min(max_chars_per_line, line_remaining.len);
            self.pos += n;
            return line_remaining[0..n];
        }

        if (line_remaining.len < max_chars_per_line) {
            // all remaining chars will fit
            self.pos += line_remaining.len + 1;
            return line_remaining;
        }

        if (std.mem.lastIndexOfScalar(u8, line_remaining[0..max_chars_per_line], ' ')) |index| {
            // found a word break under the char limit
            self.pos += index + 1;
            return line_remaining[0..index];
        }

        // word is too long
        if (std.mem.indexOfScalar(u8, line_remaining, ' ')) |index| {
            // just emit the word and let it overflow
            self.pos += index + 1;
            return line_remaining[0..index];
        }

        // the whole line is the word, can't break it up, so let it overflow
        self.pos += line_remaining.len + 1;
        return line_remaining;
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

    // TODO: replace uniform glyph approximation with real glyph measuring function per char/word
    const approx_char_width = self.style.glyphAdvanceApprox();

    // measure without constraints
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
