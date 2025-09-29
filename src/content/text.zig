const std = @import("std");
const root = @import("../root.zig");

const Content = root.Content;
const Color = root.Color;
const Vec2 = root.Vec2;

text: []const u8,
style: TextStyle,

content: Content = .{ .vtable = &.{ .measure = measureFn } },

const TextContent = @This();

pub const TextWrapMode = enum { words, newlines, none };
pub const TextAlign = enum { left, center, right };

pub const TextStyle = struct {
    font_size: f32 = 16,
    line_height: f32 = 0, // 0 => auto (= font_size * 1.2)
    letter_spacing: f32 = 0,
    wrap_mode: TextWrapMode = .words,
    alignment: TextAlign = .left,
    color: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },

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

pub fn deinit(self: *TextContent, allocator: std.mem.Allocator) void {
    self.lines.deinit(allocator);
    self.* = undefined;
}

pub fn destroyFn(content: *Content, allocator: std.mem.Allocator) void {
    const self: *TextContent = @fieldParentPtr("content", content);
    self.deinit(allocator);
}

fn measureFn(content: *const Content, constraints: Content.Constraints) Vec2 {
    const self: *const TextContent = @fieldParentPtr("content", content);

    // For measurement without wrapping we assume single line unless wrap requires width clamp.
    const adv = self.style.glyphAdvanceApprox();
    var line_count: f32 = 1;
    var max_line_width: f32 = 0;
    var current: f32 = 0;
    if (self.style.wrap_mode == .none or constraints.max_width == null) {
        max_line_width = adv * @as(f32, @floatFromInt(self.text.len));
    } else {
        const cap = constraints.max_width.?;
        var i: usize = 0;
        while (i < self.text.len) : (i += 1) {
            const c = self.text[i];
            if (c == '\n') {
                if (current > max_line_width) max_line_width = current;
                current = 0;
                line_count += 1;
                continue;
            }
            if (self.style.wrap_mode == .words and c == ' ') {
                // treat as word boundary – include the space
            }
            const g = adv;
            if (current + g > cap and self.style.wrap_mode != .none) {
                if (current > max_line_width) max_line_width = current;
                current = 0;
                line_count += 1;
            }
            current += g;
        }
        if (current > max_line_width) max_line_width = current;
    }
    const lh = self.style.resolvedLineHeight();
    const h = lh * line_count;
    return constraints.clamp(.init(max_line_width, h));
}

pub fn reshape(content: *const Content, available: Vec2, allocator: std.mem.Allocator) std.mem.Allocator.Error!?Vec2 {
    const self: *const TextContent = @fieldParentPtr("content", content);

    const Line = struct {
        slice: []const u8,
        width: f32,
    };

    var lines = std.ArrayListUnmanaged(Line){};
    defer lines.deinit(allocator);

    const adv = self.style.glyphAdvanceApprox();
    const max_w = if (self.style.wrap_mode == .none) std.math.inf(f32) else available.x;

    var line_start: usize = 0;
    var current_w: f32 = 0;
    var last_break: usize = 0;
    var i: usize = 0;

    while (i < self.text.len) : (i += 1) {
        const c = self.text[i];
        if (c == '\n') {
            try lines.append(allocator, .{ .slice = self.text[line_start..i], .width = current_w });
            line_start = i + 1;
            current_w = 0;
            last_break = line_start;
            continue;
        }

        if (self.style.wrap_mode == .words and c == ' ') {
            last_break = i;
        }

        const g = adv;
        if (current_w + g > max_w) {
            if (self.style.wrap_mode == .none) {
                current_w += g;
            } else {
                var end_index = i;
                if (self.style.wrap_mode == .words and last_break > line_start) {
                    end_index = last_break;
                    i = last_break; // rewind to last break (space will start next line)
                }
                try lines.append(allocator, .{ .slice = self.text[line_start..end_index], .width = current_w });
                line_start = end_index;
                while (line_start < self.text.len and self.text[line_start] == ' ') line_start += 1;
                current_w = 0;
                last_break = line_start;
            }
        }
        current_w += g;
    }

    if (line_start <= self.text.len) {
        try lines.append(allocator, .{ .slice = self.text[line_start..], .width = current_w });
    }

    const lh = self.style.resolvedLineHeight();
    const final_height = lh * @as(f32, @floatFromInt(lines.items.len));
    const final_width = blk: {
        var mw: f32 = 0;
        for (lines.items) |ln| {
            if (ln.width > mw) mw = ln.width;
        }
        break :blk mw;
    };

    return .{
        .final_size = .{ .x = final_width, .y = final_height },
    };
}
