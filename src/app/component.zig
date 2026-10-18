//! What makes a type a component, and how instances and elements are
//! identified: instance IDs, element keys and type tags.
const std = @import("std");

const layout = @import("../layout.zig");
const Ui = @import("ui.zig").Ui;
const Update = @import("message.zig").Update;

/// Identifies a component instance: a hash of the parent instance ID, the
/// component type and the instance's key.
pub const InstanceId = u64;

/// The parent ID used for the root component. No instance has it, so it
/// also stands for "no instance".
pub const root_parent: InstanceId = 0;

/// Stands for a type at run time: the address of a variable that exists
/// once per type.
pub const TypeTag = *const anyopaque;

pub fn typeTag(comptime T: type) TypeTag {
    return &TypeMarker(T).marker;
}

fn TypeMarker(comptime T: type) type {
    return struct {
        const Type = T;
        var marker: u8 = 0;
    };
}

/// `ptr` as a type-erased pointer, for the runtime to cast back to the
/// type it was made from.
pub fn erase(ptr: anytype) *const anyopaque {
    return @ptrCast(ptr);
}

/// The ID of the instance of `C` rendered by `parent` with `key`.
pub fn instanceId(parent: InstanceId, comptime C: type, key: anytype) InstanceId {
    var hasher = std.hash.Wyhash.init(parent);
    hasher.update(@typeName(C));
    hashKey(&hasher, key);
    return hasher.final();
}

/// The layout unit ID of the element with `key` in `instance`.
pub fn elementId(instance: InstanceId, key: anytype) layout.Unit.Id {
    return .fromInt(elementKey(instance, key));
}

/// The 64-bit ID of the element with `key` in `instance`: its layout unit's
/// ID, and the ID native elements are reconciled by. Never zero, since zero
/// means "no ID" to the layout.
pub fn elementKey(instance: InstanceId, key: anytype) u64 {
    var hasher = std.hash.Wyhash.init(instance);
    hashKey(&hasher, key);
    const id = hasher.final();
    return if (id == 0) 1 else id;
}

/// Hashes a key so that equal values hash equally whatever their type:
/// string literals and slices, integer types and comptime integers, and enum
/// values and enum literals with the same name.
fn hashKey(hasher: *std.hash.Wyhash, key: anytype) void {
    const K = @TypeOf(key);
    switch (@typeInfo(K)) {
        .void => {},
        .int, .comptime_int => {
            const value: i128 = key;
            hasher.update("i");
            hasher.update(std.mem.asBytes(&value));
        },
        .enum_literal, .@"enum" => hashKey(hasher, @as([]const u8, @tagName(key))),
        else => if (comptime isString(K)) {
            const bytes: []const u8 = key;
            hasher.update("s");
            hasher.update(bytes);
        } else {
            hasher.update(@typeName(K));
            std.hash.autoHashStrat(hasher, key, .Deep);
        },
    }
}

fn isString(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

pub const Kind = enum { stateless, stateful };

/// `C.Props`, once `C` is checked to be a component.
pub fn PropsOf(comptime C: type) type {
    _ = componentKind(C);
    return C.Props;
}

/// `C.Msg`, for binding to `C`.
pub fn MsgOf(comptime C: type) type {
    _ = componentKind(C);
    if (!@hasDecl(C, "Msg")) @compileError(@typeName(C) ++ " has no `Msg` to bind to");
    return C.Msg;
}

/// Checks that `C` has one of the two component shapes, and says which.
pub fn componentKind(comptime C: type) Kind {
    const shapes =
        \\. A component is a namespace with `pub const Props` and one of:
        \\  stateless: pub fn view(ui: *app.Ui, props: Props) !void
        \\             (and no `State`, `Msg` or `update`)
        \\  stateful:  pub const State, and
        \\             pub fn view(ui: *app.Ui, state: *const State, props: Props) !void
        \\             with, optionally, both of
        \\             pub const Msg
        \\             pub fn update(state: *State, msg: Msg, ctx: *app.Update(Self)) !void
        \\             (or returning `void`)
    ;
    const Fail = struct {
        fn because(comptime why: []const u8) noreturn {
            @compileError(@typeName(C) ++ " is not a component: " ++ why ++ shapes);
        }

        fn params(comptime name: []const u8, comptime f: anytype, comptime expected: []const type, comptime since: []const u8) void {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            if (info.param_types.len != expected.len) {
                because(std.fmt.comptimePrint("{s}`{s}` takes {d} parameters, not {d}", .{ since, name, expected.len, info.param_types.len }));
            }
            for (info.param_types, expected, 0..) |actual, wanted, i| {
                if (actual != wanted) {
                    because(std.fmt.comptimePrint("parameter {d} of `{s}` must be `{s}`", .{ i + 1, name, @typeName(wanted) }));
                }
            }
        }
    };

    switch (@typeInfo(C)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => Fail.because("it is not a namespace"),
    }
    if (!@hasDecl(C, "Props")) Fail.because("it has no `pub const Props`");
    if (!@hasDecl(C, "view")) Fail.because("it has no `pub fn view`");

    const has_state = @hasDecl(C, "State");
    const has_msg = @hasDecl(C, "Msg");
    const has_update = @hasDecl(C, "update");
    if (has_msg and !has_update) Fail.because("it has a `Msg` but no `update`");
    if (has_update and !has_msg) Fail.because("it has an `update` but no `Msg`");
    if (has_msg and !has_state) Fail.because("it has a `Msg` but no `State`");

    if (has_state) {
        Fail.params("view", C.view, &.{ *Ui, *const C.State, C.Props }, "it has a `State`, so ");
    } else {
        Fail.params("view", C.view, &.{ *Ui, C.Props }, "it has no `State`, so ");
    }
    if (has_update) {
        Fail.params("update", C.update, &.{ *C.State, C.Msg, *Update(C) }, "");
        const Return = @typeInfo(@TypeOf(C.update)).@"fn".return_type orelse
            Fail.because("`update` must return `void` or `!void`, not a generic type");
        const returns_void = switch (@typeInfo(Return)) {
            .void => true,
            .error_union => |eu| eu.payload == void,
            else => false,
        };
        if (!returns_void) Fail.because("`update` must return `void` or `!void`, not `" ++ @typeName(Return) ++ "`");
    }
    return if (has_state) .stateful else .stateless;
}
