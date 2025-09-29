const std = @import("std");
const root = @import("root.zig");

const Vec2 = root.Vec2;

vtable: *const VTable,

const Content = @This();

pub const ReshapeError = std.mem.Allocator.Error;

pub const Constraints = struct {
    max_width: ?f32 = null,
    max_height: ?f32 = null,

    pub fn clamp(self: Constraints, size: Vec2) Vec2 {
        return .init(
            @min(size.x, self.max_width orelse size.x),
            @min(size.y, self.max_height orelse size.y),
        );
    }
};

pub const VTable = struct {
    measure: *const fn (self: *Content, constraints: Constraints) Vec2,
    reshape: ?*const fn (self: *Content, available: Vec2, allocator: std.mem.Allocator) ReshapeError!?Vec2 = null,
    deinit: ?*const fn (self: *Content, allocator: std.mem.Allocator) void = null,

    debug_name: []const u8 = "Content",
};

pub fn measure(self: *Content, constraints: Constraints) Vec2 {
    return self.vtable.measure_fn(self, constraints);
}

pub fn reshape(self: *Content, available: Vec2, allocator: std.mem.Allocator) !?Vec2 {
    if (self.vtable.reshape_fn) |fn_ptr| {
        return try fn_ptr(self, available, allocator);
    }

    return null;
}

pub fn deinit(self: *Content, allocator: std.mem.Allocator) void {
    if (self.vtable.deinit_fn) |fn_ptr| fn_ptr(self, allocator);
}
