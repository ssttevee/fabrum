//! fabrum is an immediate-mode UI framework.
//!
//! It is split into namespaces so users only pay for what they use:
//!
//! - `layout`: the layout system. Units are declared every frame, sized and
//!   positioned, then turned into render commands for a renderer.
//!
//! The shared geometry and color primitives below are used by every
//! namespace. Renderers live in separate packages.
const std = @import("std");

pub const layout = @import("layout.zig");

pub const Vec2 = @import("vec2.zig");
pub const Rect = @import("rect.zig");
pub const Range = @import("range.zig");
pub const Color = @import("color.zig");

test {
    std.testing.refAllDecls(@This());
}
