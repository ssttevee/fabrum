const std = @import("std");
const root = @import("../root.zig");

const LayoutContent = root.LayoutContent;
const Color = root.Color;
const Vec2 = root.Vec2;
const LayoutConstraints = root.LayoutConstraints;

allocator: std.mem.Allocator,
text: []const u8,
style: TextStyle,

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

fn measureFn(content: *const LayoutContent, constraints: LayoutConstraints) Vec2 {
    const self: *const TextContent = @fieldParentPtr("content", content);

    // TODO: replace uniform glyph approximation with real glyph measuring function per char/word
    const approx_char_width = self.style.glyphAdvanceApprox();

    // measure without constraints
    var line_count: usize = 0;
    var max_line_len: usize = 0;

    var line_iterator = std.mem.splitScalar(self.text, '\n');
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
                var word_iterator = std.mem.splitScalar(line, ' ');

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
        self.style.resolvedLineHeight() * line_count,
    );
}
