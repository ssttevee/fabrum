const std = @import("std");
const fabrum = @import("fabrum");

pub const ParseError = error{
    UnsupportedSVGElement,
    InvalidSVGData,
    OutOfMemory,
    MalformedPath,
};

pub const PathCommand = union(enum) {
    move_to: struct { x: f32, y: f32 },
    line_to: struct { x: f32, y: f32 },
    curve_to: struct { x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32 },
    quadratic_to: struct { x1: f32, y1: f32, x: f32, y: f32 },
    close_path,
};

pub const PathData = @This();

commands: []PathCommand,
viewbox: fabrum.Rect,

pub fn parse(allocator: std.mem.Allocator, svg_data: []const u8) ParseError!PathData {
    var commands: std.ArrayList(PathCommand) = .empty;
    defer commands.deinit(allocator);

    var viewbox: ?fabrum.Rect = null;

    var in_svg = false;
    var in_path = false;
    var path_d_data: ?[]const u8 = null;

    var i: usize = 0;
    while (i < svg_data.len) {
        if (svg_data[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, svg_data, i, '>') orelse return error.InvalidSVGData;
            const tag_content = std.mem.trim(u8, svg_data[i + 1 .. tag_end], " \t\n\r");

            if (std.mem.startsWith(u8, tag_content, "svg")) {
                in_svg = true;
                viewbox = try parseViewBox(tag_content);
            } else if (std.mem.startsWith(u8, tag_content, "/svg")) {
                in_svg = false;
            } else if (in_svg and std.mem.startsWith(u8, tag_content, "path")) {
                in_path = true;
                path_d_data = parsePathDAttribute(tag_content);
            } else if (in_svg and std.mem.startsWith(u8, tag_content, "/path")) {
                if (path_d_data) |d| {
                    try parsePathData(allocator, &commands, d);
                    path_d_data = null;
                }
                in_path = false;
            } else if (in_svg and !std.mem.startsWith(u8, tag_content, "?") and !std.mem.startsWith(u8, tag_content, "!")) {
                const is_self_closing = std.mem.endsWith(u8, tag_content, "/");
                const is_closing = std.mem.startsWith(u8, tag_content, "/");

                if (!is_closing and !is_self_closing) {
                    return error.UnsupportedSVGElement;
                }
            }

            i = tag_end + 1;
        } else {
            i += 1;
        }
    }

    return .{
        .viewbox = viewbox orelse return error.InvalidSVGData,
        .commands = try commands.toOwnedSlice(allocator),
    };
}

pub fn deinit(self: *PathData, allocator: std.mem.Allocator) void {
    allocator.free(self.commands);
    self.* = undefined;
}

pub fn toCGPath(self: PathData) *CGPath {
    return .fromPathData(self);
}

fn parseViewBox(svg_tag: []const u8) !?fabrum.Rect {
    const viewbox_start = std.mem.indexOf(u8, svg_tag, "viewBox=\"") orelse
        std.mem.indexOf(u8, svg_tag, "viewBox='") orelse return null;
    const quote_char = svg_tag[viewbox_start + 8];
    const value_start = viewbox_start + 9;
    const value_end = std.mem.indexOfScalarPos(u8, svg_tag, value_start, quote_char) orelse return error.InvalidSVGData;
    const value = svg_tag[value_start..value_end];

    var parts = std.mem.tokenizeAny(u8, value, " ,\t\n\r");
    const x = std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSVGData) catch return error.InvalidSVGData;
    const y = std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSVGData) catch return error.InvalidSVGData;
    const width = std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSVGData) catch return error.InvalidSVGData;
    const height = std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSVGData) catch return error.InvalidSVGData;

    return .init(x, y, width, height);
}

fn parsePathDAttribute(path_tag: []const u8) ?[]const u8 {
    const d_start = std.mem.indexOf(u8, path_tag, "d=\"") orelse
        std.mem.indexOf(u8, path_tag, "d='") orelse return null;
    const quote_char = path_tag[d_start + 2];
    const value_start = d_start + 3;
    const value_end = std.mem.indexOfScalarPos(u8, path_tag, value_start, quote_char) orelse return null;
    return path_tag[value_start..value_end];
}

fn parsePathData(allocator: std.mem.Allocator, commands: *std.ArrayList(PathCommand), d: []const u8) ParseError!void {
    var i: usize = 0;
    var current_x: f32 = 0;
    var current_y: f32 = 0;

    while (i < d.len) {
        while (i < d.len and isWhitespace(d[i])) : (i += 1) {}
        if (i >= d.len) break;

        const cmd = d[i];
        i += 1;

        switch (cmd) {
            'M' => {
                const coords = try parseCoordinates(allocator, d, &i);
                if (coords.len < 2) return error.MalformedPath;
                current_x = coords[0];
                current_y = coords[1];
                try commands.append(allocator, .{ .move_to = .{ .x = current_x, .y = current_y } });

                var j: usize = 2;
                while (j + 1 < coords.len) : (j += 2) {
                    current_x = coords[j];
                    current_y = coords[j + 1];
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'm' => {
                const coords = try parseCoordinates(allocator, d, &i);
                if (coords.len < 2) return error.MalformedPath;
                current_x += coords[0];
                current_y += coords[1];
                try commands.append(allocator, .{ .move_to = .{ .x = current_x, .y = current_y } });

                var j: usize = 2;
                while (j + 1 < coords.len) : (j += 2) {
                    current_x += coords[j];
                    current_y += coords[j + 1];
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'L' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 1 < coords.len) : (j += 2) {
                    current_x = coords[j];
                    current_y = coords[j + 1];
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'l' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 1 < coords.len) : (j += 2) {
                    current_x += coords[j];
                    current_y += coords[j + 1];
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'H' => {
                const coords = try parseCoordinates(allocator, d, &i);
                for (coords) |x| {
                    current_x = x;
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'h' => {
                const coords = try parseCoordinates(allocator, d, &i);
                for (coords) |dx| {
                    current_x += dx;
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'V' => {
                const coords = try parseCoordinates(allocator, d, &i);
                for (coords) |y| {
                    current_y = y;
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'v' => {
                const coords = try parseCoordinates(allocator, d, &i);
                for (coords) |dy| {
                    current_y += dy;
                    try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
                }
            },
            'C' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 5 < coords.len) : (j += 6) {
                    current_x = coords[j + 4];
                    current_y = coords[j + 5];
                    try commands.append(allocator, .{ .curve_to = .{
                        .x1 = coords[j],
                        .y1 = coords[j + 1],
                        .x2 = coords[j + 2],
                        .y2 = coords[j + 3],
                        .x = current_x,
                        .y = current_y,
                    } });
                }
            },
            'c' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 5 < coords.len) : (j += 6) {
                    const x1 = current_x + coords[j];
                    const y1 = current_y + coords[j + 1];
                    const x2 = current_x + coords[j + 2];
                    const y2 = current_y + coords[j + 3];
                    current_x += coords[j + 4];
                    current_y += coords[j + 5];
                    try commands.append(allocator, .{ .curve_to = .{
                        .x1 = x1,
                        .y1 = y1,
                        .x2 = x2,
                        .y2 = y2,
                        .x = current_x,
                        .y = current_y,
                    } });
                }
            },
            'Q' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 3 < coords.len) : (j += 4) {
                    current_x = coords[j + 2];
                    current_y = coords[j + 3];
                    try commands.append(allocator, .{ .quadratic_to = .{
                        .x1 = coords[j],
                        .y1 = coords[j + 1],
                        .x = current_x,
                        .y = current_y,
                    } });
                }
            },
            'q' => {
                const coords = try parseCoordinates(allocator, d, &i);
                var j: usize = 0;
                while (j + 3 < coords.len) : (j += 4) {
                    const x1 = current_x + coords[j];
                    const y1 = current_y + coords[j + 1];
                    current_x += coords[j + 2];
                    current_y += coords[j + 3];
                    try commands.append(allocator, .{ .quadratic_to = .{
                        .x1 = x1,
                        .y1 = y1,
                        .x = current_x,
                        .y = current_y,
                    } });
                }
            },
            'Z', 'z' => {
                try commands.append(allocator, .close_path);
            },
            else => {
                if (!isWhitespace(cmd) and !isDigit(cmd) and cmd != '-' and cmd != '.') {
                    return error.MalformedPath;
                }
            },
        }
    }
}

fn parseCoordinates(allocator: std.mem.Allocator, d: []const u8, index: *usize) ![]f32 {
    var coords: std.ArrayList(f32) = .empty;
    errdefer coords.deinit(allocator);

    while (index.* < d.len) {
        while (index.* < d.len and isWhitespace(d[index.*])) : (index.* += 1) {}
        if (index.* >= d.len) break;

        const c = d[index.*];
        if (std.ascii.isAlphabetic(c)) break;

        const start = index.*;
        var end = start;
        while (end < d.len and (isDigit(d[end]) or d[end] == '.' or d[end] == '-' or d[end] == '+' or d[end] == 'e' or d[end] == 'E')) : (end += 1) {}

        if (start == end) break;

        const num_str = d[start..end];
        const num = std.fmt.parseFloat(f32, num_str) catch return error.MalformedPath;
        try coords.append(allocator, num);

        index.* = end;

        while (index.* < d.len and (isWhitespace(d[index.*]) or d[index.*] == ',')) : (index.* += 1) {}
    }

    return coords.items;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const CGFloat = f64;
const CGContext = @import("../../root.zig").CGContext;

pub const CGPath = opaque {
    pub fn fromPathData(path_data: PathData) *CGPath {
        const path = quartz_renderer_create_path();

        for (path_data.commands) |cmd| {
            switch (cmd) {
                .move_to => |mt| quartz_renderer_path_move_to(path, mt.x, mt.y),
                .line_to => |lt| quartz_renderer_path_line_to(path, lt.x, lt.y),
                .curve_to => |ct| quartz_renderer_path_curve_to(path, ct.x1, ct.y1, ct.x2, ct.y2, ct.x, ct.y),
                .quadratic_to => |qt| quartz_renderer_path_quadratic_to(path, qt.x1, qt.y1, qt.x, qt.y),
                .close_path => quartz_renderer_path_close(path),
            }
        }

        return path;
    }

    pub fn deinit(self: *CGPath) void {
        quartz_renderer_path_release(self);
    }
};

extern fn quartz_renderer_create_path() *CGPath;
extern fn quartz_renderer_path_move_to(path: *CGPath, x: CGFloat, y: CGFloat) void;
extern fn quartz_renderer_path_line_to(path: *CGPath, x: CGFloat, y: CGFloat) void;
extern fn quartz_renderer_path_curve_to(path: *CGPath, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x: CGFloat, y: CGFloat) void;
extern fn quartz_renderer_path_quadratic_to(path: *CGPath, x1: CGFloat, y1: CGFloat, x: CGFloat, y: CGFloat) void;
extern fn quartz_renderer_path_close(path: *CGPath) void;
extern fn quartz_renderer_path_release(path: *CGPath) void;
