//! fabrum is an immediate-mode UI framework.
//!
//! It is split into namespaces so users only pay for what they use:
//!
//! - `layout`: the layout system. Units are declared every frame, sized and
//!   positioned, then turned into render commands for a renderer.
//! - `app`: an Elm-architecture runtime built on `layout`, with components
//!   that keep their own state, messages and input handling.
//!
//! - `render`: renderers that come with fabrum, such as Quartz on macOS.
//!   Portable ones live in separate packages.
//!
//! The shared geometry and color primitives below are used by every
//! namespace.
const std = @import("std");

pub const layout = @import("layout.zig");
pub const app = @import("app.zig");
pub const render = @import("render.zig");

pub const Vec2 = @import("vec2.zig");
pub const Rect = @import("rect.zig");
pub const Range = @import("range.zig");
pub const Color = @import("color.zig");

test {
    std.testing.refAllDecls(@This());
}
