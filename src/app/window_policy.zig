//! Native window behavior selected at compile time, independently of runtime
//! dimensions, title and position. Unsupported built-in host features are errors;
//! compositor-dependent features are checked when creating the native window.
const std = @import("std");
const Kind = @import("platform.zig").Kind;

pub const WindowPolicy = struct {
    decorations: enum { system, none } = .system,
    background: enum { system, transparent } = .system,
    level: enum { normal, floating } = .normal,
    activation: enum { normal, never } = .normal,
    pointer: enum { normal, passthrough } = .normal,
    shadow: enum { system, none } = .system,
    placement: enum { automatic, positioned } = .automatic,
};

pub const Capability = enum { supported, unsupported, runtime };
pub const Feature = enum { decorations, background, level, activation, pointer, shadow, placement };

/// Describes a non-default policy setting on the built-in host. `runtime`
/// means the host must check the display/compositor while creating the window.
pub fn capability(comptime kind: Kind, comptime feature: Feature) Capability {
    return switch (kind) {
        .appkit => .supported,
        .gtk => switch (feature) {
            .level, .activation, .placement, .shadow => .unsupported,
            .background, .pointer => .runtime,
            .decorations => .supported,
        },
        else => .unsupported,
    };
}

pub fn validate(comptime kind: Kind, comptime policy: WindowPolicy) void {
    if (kind == .gtk and policy.decorations != .none) {
        if (policy.pointer == .passthrough)
            @compileError("window policy 'pointer = passthrough' requires 'decorations = none' on the built-in 'gtk' host");
    }
    const defaults: WindowPolicy = .{};
    inline for (@typeInfo(WindowPolicy).@"struct".field_names) |name| {
        if (@field(policy, name) != @field(defaults, name)) {
            const feature: Feature = @field(Feature, name);
            if (capability(kind, feature) == .unsupported) {
                @compileError("window policy '" ++ name ++ "' is unsupported by the built-in '" ++ @tagName(kind) ++ "' host");
            }
        }
    }
}

test "window policy support distinguishes static and display-dependent features" {
    try std.testing.expectEqual(Capability.supported, capability(.appkit, .activation));
    try std.testing.expectEqual(Capability.unsupported, capability(.gtk, .level));
    try std.testing.expectEqual(Capability.unsupported, capability(.gtk, .activation));
    try std.testing.expectEqual(Capability.unsupported, capability(.gtk, .placement));
    try std.testing.expectEqual(Capability.runtime, capability(.gtk, .background));
    try std.testing.expectEqual(Capability.runtime, capability(.gtk, .pointer));
    try std.testing.expectEqual(Capability.unsupported, capability(.none, .decorations));
    comptime validate(.appkit, .{ .decorations = .none, .background = .transparent, .level = .floating, .activation = .never, .pointer = .passthrough, .shadow = .none, .placement = .positioned });
    comptime validate(.gtk, .{ .decorations = .none, .background = .transparent, .pointer = .passthrough });
    comptime validate(.none, .{});
}
