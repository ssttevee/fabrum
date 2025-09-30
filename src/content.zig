const std = @import("std");
const root = @import("root.zig");

const Vec2 = root.Vec2;
const LayoutConstraints = root.LayoutConstraints;

vtable: *const VTable,

const Content = @This();

pub const VTable = struct {
    /// Returns the shape of the content based on optional .
    measure: *const fn (self: *Content, constraints: ?LayoutConstraints) Vec2,
    deinit: ?*const fn (self: *Content) void = null,

    debug_name: []const u8 = "Content",
};

pub fn measure(self: *Content) Vec2 {
    return self.vtable.measure(self);
}

pub fn deinit(self: *Content) void {
    if (self.vtable.deinit) |fn_ptr| fn_ptr(self);
}
