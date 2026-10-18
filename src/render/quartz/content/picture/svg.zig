const std = @import("std");
const fabrum = @import("../../../../root.zig");

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
                if (std.mem.endsWith(u8, tag_content, "/")) {
                    // `<path d="..."/>` has no closing tag
                    if (parsePathDAttribute(tag_content)) |d| try parsePathData(allocator, &commands, d);
                } else {
                    in_path = true;
                    path_d_data = parsePathDAttribute(tag_content);
                }
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

/// Reads the numbers and flags of a path's `d` attribute. Numbers may run
/// together where the grammar allows it, as minifiers write them: `1-2` is
/// two numbers, and so is `.5.5`.
const Scanner = struct {
    d: []const u8,
    i: usize = 0,

    fn skipSeparators(self: *Scanner) void {
        while (self.i < self.d.len and isWhitespace(self.d[self.i])) : (self.i += 1) {}
    }

    fn done(self: *Scanner) bool {
        self.skipSeparators();
        return self.i >= self.d.len;
    }

    /// Whether a number follows, which repeats the current command.
    fn atNumber(self: *Scanner) bool {
        self.skipSeparators();
        if (self.i >= self.d.len) return false;
        const c = self.d[self.i];
        return isDigit(c) or c == '.' or c == '-' or c == '+';
    }

    fn number(self: *Scanner) ParseError!f32 {
        self.skipSeparators();
        const start = self.i;
        if (self.i < self.d.len and (self.d[self.i] == '-' or self.d[self.i] == '+')) self.i += 1;
        var digits: usize = 0;
        while (self.i < self.d.len and isDigit(self.d[self.i])) : (self.i += 1) digits += 1;
        if (self.i < self.d.len and self.d[self.i] == '.') {
            self.i += 1;
            while (self.i < self.d.len and isDigit(self.d[self.i])) : (self.i += 1) digits += 1;
        }
        if (digits == 0) return error.MalformedPath;
        if (self.i < self.d.len and (self.d[self.i] == 'e' or self.d[self.i] == 'E')) {
            var j = self.i + 1;
            if (j < self.d.len and (self.d[j] == '-' or self.d[j] == '+')) j += 1;
            if (j < self.d.len and isDigit(self.d[j])) {
                self.i = j;
                while (self.i < self.d.len and isDigit(self.d[self.i])) : (self.i += 1) {}
            }
        }
        return std.fmt.parseFloat(f32, self.d[start..self.i]) catch error.MalformedPath;
    }

    /// An arc flag: a single `0` or `1`, which needs no separator after it.
    fn flag(self: *Scanner) ParseError!bool {
        self.skipSeparators();
        if (self.i >= self.d.len) return error.MalformedPath;
        const c = self.d[self.i];
        self.i += 1;
        return switch (c) {
            '0' => false,
            '1' => true,
            else => error.MalformedPath,
        };
    }

    fn point(self: *Scanner) ParseError![2]f32 {
        const x = try self.number();
        const y = try self.number();
        return .{ x, y };
    }
};

fn parsePathData(allocator: std.mem.Allocator, commands: *std.ArrayList(PathCommand), d: []const u8) ParseError!void {
    var scanner: Scanner = .{ .d = d };
    var cmd: u8 = 0;
    var current_x: f32 = 0;
    var current_y: f32 = 0;
    // where `Z` returns to, and what commands after it are relative to
    var start_x: f32 = 0;
    var start_y: f32 = 0;
    // the last curve's second control point, reflected by `S` and `T`
    var control_x: f32 = 0;
    var control_y: f32 = 0;
    var previous: u8 = 0;

    while (!scanner.done()) {
        const c = d[scanner.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            scanner.i += 1;
        } else if (cmd == 0 or cmd == 'Z' or cmd == 'z') {
            // numbers must follow a command that takes them
            return error.MalformedPath;
        }

        const relative = std.ascii.isLower(cmd);
        const base_x: f32 = if (relative) current_x else 0;
        const base_y: f32 = if (relative) current_y else 0;

        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const p = try scanner.point();
                current_x = base_x + p[0];
                current_y = base_y + p[1];
                start_x = current_x;
                start_y = current_y;
                try commands.append(allocator, .{ .move_to = .{ .x = current_x, .y = current_y } });
                // further pairs are implicit line-tos
                cmd = if (relative) 'l' else 'L';
            },
            'L' => {
                const p = try scanner.point();
                current_x = base_x + p[0];
                current_y = base_y + p[1];
                try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
            },
            'H' => {
                current_x = base_x + try scanner.number();
                try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
            },
            'V' => {
                current_y = base_y + try scanner.number();
                try commands.append(allocator, .{ .line_to = .{ .x = current_x, .y = current_y } });
            },
            'C', 'S' => {
                const first_x, const first_y = if (std.ascii.toUpper(cmd) == 'C') first: {
                    const p = try scanner.point();
                    break :first .{ base_x + p[0], base_y + p[1] };
                } else if (previous == 'C' or previous == 'S')
                    .{ 2 * current_x - control_x, 2 * current_y - control_y }
                else
                    .{ current_x, current_y };
                const second = try scanner.point();
                const end = try scanner.point();
                control_x = base_x + second[0];
                control_y = base_y + second[1];
                current_x = base_x + end[0];
                current_y = base_y + end[1];
                try commands.append(allocator, .{ .curve_to = .{
                    .x1 = first_x,
                    .y1 = first_y,
                    .x2 = control_x,
                    .y2 = control_y,
                    .x = current_x,
                    .y = current_y,
                } });
            },
            'Q', 'T' => {
                if (std.ascii.toUpper(cmd) == 'Q') {
                    const p = try scanner.point();
                    control_x = base_x + p[0];
                    control_y = base_y + p[1];
                } else if (previous == 'Q' or previous == 'T') {
                    control_x = 2 * current_x - control_x;
                    control_y = 2 * current_y - control_y;
                } else {
                    control_x = current_x;
                    control_y = current_y;
                }
                const end = try scanner.point();
                current_x = base_x + end[0];
                current_y = base_y + end[1];
                try commands.append(allocator, .{ .quadratic_to = .{
                    .x1 = control_x,
                    .y1 = control_y,
                    .x = current_x,
                    .y = current_y,
                } });
            },
            'A' => {
                const rx = try scanner.number();
                const ry = try scanner.number();
                const rotation = try scanner.number();
                const large_arc = try scanner.flag();
                const sweep = try scanner.flag();
                const end = try scanner.point();
                const end_x = base_x + end[0];
                const end_y = base_y + end[1];
                try appendArc(allocator, commands, current_x, current_y, rx, ry, rotation, large_arc, sweep, end_x, end_y);
                current_x = end_x;
                current_y = end_y;
            },
            'Z' => {
                try commands.append(allocator, .close_path);
                current_x = start_x;
                current_y = start_y;
            },
            else => return error.MalformedPath,
        }
        previous = std.ascii.toUpper(cmd);
    }
}

/// Appends an SVG elliptical arc from (x1, y1) to (x2, y2) as cubic Bézier
/// curves, one per quarter turn or less, following the endpoint to center
/// conversion in the SVG specification (appendix B.2.4).
fn appendArc(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(PathCommand),
    x1: f32,
    y1: f32,
    rx_in: f32,
    ry_in: f32,
    rotation_degrees: f32,
    large_arc: bool,
    sweep: bool,
    x2: f32,
    y2: f32,
) ParseError!void {
    if (x1 == x2 and y1 == y2) return;
    var rx: f64 = @abs(rx_in);
    var ry: f64 = @abs(ry_in);
    if (rx == 0 or ry == 0) {
        try commands.append(allocator, .{ .line_to = .{ .x = x2, .y = y2 } });
        return;
    }

    const phi = std.math.degreesToRadians(@as(f64, rotation_degrees));
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // the start point in a frame centered between the endpoints, unrotated
    const dx = (@as(f64, x1) - x2) / 2;
    const dy = (@as(f64, y1) - y2) / 2;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // radii too small to reach both endpoints are scaled up until they do
    const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        rx *= @sqrt(lambda);
        ry *= @sqrt(lambda);
    }

    const numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    const denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coefficient = @sqrt(@max(0, numerator / denominator));
    if (large_arc == sweep) coefficient = -coefficient;
    const cxp = coefficient * rx * y1p / ry;
    const cyp = -coefficient * ry * x1p / rx;
    const cx = cos_phi * cxp - sin_phi * cyp + (@as(f64, x1) + x2) / 2;
    const cy = sin_phi * cxp + cos_phi * cyp + (@as(f64, y1) + y2) / 2;

    const start_angle = vectorAngle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var sweep_angle = vectorAngle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep and sweep_angle > 0) sweep_angle -= 2 * std.math.pi;
    if (sweep and sweep_angle < 0) sweep_angle += 2 * std.math.pi;

    const segments: usize = @intFromFloat(@max(1, @ceil(@abs(sweep_angle) / (std.math.pi / 2.0) - 1e-9)));
    const delta = sweep_angle / @as(f64, @floatFromInt(segments));
    // control point distance along the tangent for a segment of `delta`
    const k = 4.0 / 3.0 * @tan(delta / 4);

    const Ellipse = struct {
        cx: f64,
        cy: f64,
        rx: f64,
        ry: f64,
        cos_phi: f64,
        sin_phi: f64,

        fn point(e: @This(), angle: f64) [2]f64 {
            const ex = e.rx * @cos(angle);
            const ey = e.ry * @sin(angle);
            return .{ e.cx + e.cos_phi * ex - e.sin_phi * ey, e.cy + e.sin_phi * ex + e.cos_phi * ey };
        }

        fn tangent(e: @This(), angle: f64) [2]f64 {
            const ex = -e.rx * @sin(angle);
            const ey = e.ry * @cos(angle);
            return .{ e.cos_phi * ex - e.sin_phi * ey, e.sin_phi * ex + e.cos_phi * ey };
        }
    };
    const ellipse: Ellipse = .{ .cx = cx, .cy = cy, .rx = rx, .ry = ry, .cos_phi = cos_phi, .sin_phi = sin_phi };

    var angle = start_angle;
    for (0..segments) |index| {
        const next_angle = angle + delta;
        const from = ellipse.point(angle);
        const from_tangent = ellipse.tangent(angle);
        const to_tangent = ellipse.tangent(next_angle);
        // the last segment ends exactly on the requested endpoint
        const to: [2]f64 = if (index + 1 == segments) .{ x2, y2 } else ellipse.point(next_angle);
        try commands.append(allocator, .{ .curve_to = .{
            .x1 = @floatCast(from[0] + k * from_tangent[0]),
            .y1 = @floatCast(from[1] + k * from_tangent[1]),
            .x2 = @floatCast(to[0] - k * to_tangent[0]),
            .y2 = @floatCast(to[1] - k * to_tangent[1]),
            .x = @floatCast(to[0]),
            .y = @floatCast(to[1]),
        } });
        angle = next_angle;
    }
}

/// The signed angle from vector u to vector v.
fn vectorAngle(ux: f64, uy: f64, vx: f64, vy: f64) f64 {
    return std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == ',';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const CGFloat = f64;
const CGContext = @import("../../../quartz.zig").CGContext;

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

fn expectEndPoint(command: PathCommand, x: f32, y: f32) !void {
    const end_x, const end_y = switch (command) {
        .move_to => |c| .{ c.x, c.y },
        .line_to => |c| .{ c.x, c.y },
        .curve_to => |c| .{ c.x, c.y },
        .quadratic_to => |c| .{ c.x, c.y },
        .close_path => return error.TestUnexpectedResult,
    };
    try std.testing.expectApproxEqAbs(x, end_x, 1e-4);
    try std.testing.expectApproxEqAbs(y, end_y, 1e-4);
}

test "parse reads every path in the svg" {
    var path = try parse(std.testing.allocator,
        \\<?xml version="1.0"?>
        \\<svg viewBox="0 0 16 16"><defs/>
        \\  <path d="M0 0L16 0"></path>
        \\  <path d="M0 16H8V8z"/>
        \\</svg>
    );
    defer path.deinit(std.testing.allocator);

    try std.testing.expectEqual(fabrum.Rect.init(0, 0, 16, 16), path.viewbox);
    // two commands from the first path and four from the self-closing one
    try std.testing.expectEqual(6, path.commands.len);
    try std.testing.expectEqual(PathCommand.close_path, path.commands[5]);
}

test "parsePathData splits numbers the way minifiers write them" {
    var commands: std.ArrayList(PathCommand) = .empty;
    defer commands.deinit(std.testing.allocator);

    // `.5.5` and `1-1` are two numbers each; `1e2` is one
    try parsePathData(std.testing.allocator, &commands, "M.5.5l1-1L1e2,0");
    try std.testing.expectEqual(3, commands.items.len);
    try expectEndPoint(commands.items[0], 0.5, 0.5);
    try expectEndPoint(commands.items[1], 1.5, -0.5);
    try expectEndPoint(commands.items[2], 100, 0);

    try std.testing.expectError(error.MalformedPath, parsePathData(std.testing.allocator, &commands, "M0 0L1"));
    try std.testing.expectError(error.MalformedPath, parsePathData(std.testing.allocator, &commands, "M0 0 X1 1"));
}

test "parsePathData repeats commands and returns to the subpath start" {
    var commands: std.ArrayList(PathCommand) = .empty;
    defer commands.deinit(std.testing.allocator);

    // pairs after m are relative line-tos; after z, m is relative to (10, 10)
    try parsePathData(std.testing.allocator, &commands, "m10 10 5 0 0 5zm1 1h2v2h-2z");
    try std.testing.expectEqual(9, commands.items.len);
    try expectEndPoint(commands.items[0], 10, 10);
    try expectEndPoint(commands.items[1], 15, 10);
    try expectEndPoint(commands.items[2], 15, 15);
    try std.testing.expectEqual(PathCommand.close_path, commands.items[3]);
    try expectEndPoint(commands.items[4], 11, 11);
    try expectEndPoint(commands.items[7], 11, 13);
}

test "parsePathData reflects control points for smooth curves" {
    var commands: std.ArrayList(PathCommand) = .empty;
    defer commands.deinit(std.testing.allocator);

    try parsePathData(std.testing.allocator, &commands, "M0 0C0 10 10 10 10 0s10-10 10 0Q25 5 30 0t10 0");
    const smooth = commands.items[2].curve_to;
    try std.testing.expectEqual(10, smooth.x1);
    try std.testing.expectEqual(-10, smooth.y1);
    const quadratic = commands.items[4].quadratic_to;
    try std.testing.expectEqual(35, quadratic.x1);
    try std.testing.expectEqual(-5, quadratic.y1);
}

test "parsePathData turns arcs into curves that stay on the ellipse" {
    var commands: std.ArrayList(PathCommand) = .empty;
    defer commands.deinit(std.testing.allocator);

    // a half circle of radius 8 over the top, with compact flags
    try parsePathData(std.testing.allocator, &commands, "M0 8a8 8 0 0 1 16 0");
    try std.testing.expectEqual(3, commands.items.len);
    try expectEndPoint(commands.items[1], 8, 0);
    try expectEndPoint(commands.items[2], 16, 8);

    // a quarter turn's control points sit 4/3 * tan(pi/8) * r along the tangents
    const quarter = commands.items[1].curve_to;
    const k: f32 = 8 * 4.0 / 3.0 * @tan(std.math.pi / 8.0);
    try std.testing.expectApproxEqAbs(0, quarter.x1, 1e-4);
    try std.testing.expectApproxEqAbs(8 - k, quarter.y1, 1e-4);
    try std.testing.expectApproxEqAbs(8 - k, quarter.x2, 1e-4);
    try std.testing.expectApproxEqAbs(0, quarter.y2, 1e-4);

    commands.clearRetainingCapacity();
    // the other sweep goes under, and radii too small to span the endpoints are scaled up
    try parsePathData(std.testing.allocator, &commands, "M0 8A1 1 0 0 0 16 8");
    try std.testing.expectEqual(3, commands.items.len);
    try expectEndPoint(commands.items[1], 8, 16);

    commands.clearRetainingCapacity();
    // a large arc of three quarters of a circle
    try parsePathData(std.testing.allocator, &commands, "M8 0a8 8 0 1 0 8 8");
    try std.testing.expectEqual(4, commands.items.len);
    try expectEndPoint(commands.items[1], 0, 8);
    try expectEndPoint(commands.items[2], 8, 16);
    try expectEndPoint(commands.items[3], 16, 8);
}
