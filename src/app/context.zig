//! Contexts: values looked up by type rather than passed down as props.
const std = @import("std");

const component = @import("component.zig");
const TypeTag = component.TypeTag;
const typeTag = component.typeTag;
const erase = component.erase;

/// A value seen by every component, given to `Runtime.init` in
/// `Options.provide`.
pub const RootValue = struct {
    key: TypeTag,
    value: *const anyopaque,

    /// `value`, a pointer to one `T`, as the root's `T`.
    pub fn of(value: anytype) RootValue {
        const T = switch (@typeInfo(@TypeOf(value))) {
            .pointer => |pointer| if (pointer.size == .one) pointer.child else @compileError("RootValue.of takes a pointer to one value"),
            else => @compileError("RootValue.of takes a pointer to one value"),
        };
        return .{ .key = typeTag(T), .value = erase(value) };
    }
};

/// A provided value, in a list from the latest provided back to the root
/// values. Nodes are never changed once linked, so every instance can keep
/// the node it was rendered with.
pub const Provided = struct {
    parent: ?*const Provided,
    /// The value's type.
    key: TypeTag,
    /// Points to a value of the type `key` stands for, since only
    /// `Ui.provide(T, *const T)` and `RootValue.of(*const T)` make nodes.
    value: *const anyopaque,
};

pub fn lookup(comptime T: type, head: ?*const Provided) ?*const T {
    var it = head;
    while (it) |node| : (it = node.parent) {
        if (node.key == typeTag(T)) return @ptrCast(@alignCast(node.value));
    }
    return null;
}

pub fn missing(comptime T: type) noreturn {
    std.debug.panic("app: nothing provides " ++ @typeName(T) ++ "; provide one with `ui.provide` or `Runtime.Options.provide`", .{});
}
