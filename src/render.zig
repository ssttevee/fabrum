//! Renderers that come with fabrum: they draw `fabrum.layout` render
//! commands with a platform's own 2D API.
//!
//! - `Quartz`: Core Graphics and Core Text, on macOS. It is the AppKit
//!   platform's canvas, and also draws on its own into any `CGContext`
//!   (a bitmap, a PDF), whatever the `platform` option.
//!
//! Portable renderers that draw into pixels on any OS, such as z2d and
//! ThorVG, are separate packages, which the app gives its fabrum to (see
//! `layout.draw` and docs/hybrid-design.md, §15).
const std = @import("std");
const builtin = @import("builtin");

const options = @import("fabrum_options");

/// The Quartz renderer, for `.cg_context` surfaces. In builds for macOS,
/// unless fabrum's `quartz` option leaves it out.
pub const Quartz = if (options.quartz) @import("render/quartz.zig") else unavailable("Quartz", if (builtin.target.os.tag == .macos)
    "it is left out of this build (fabrum's `quartz` option is false)"
else
    "it needs macOS, and this build is for " ++ @tagName(builtin.target.os.tag));

fn unavailable(comptime name: []const u8, comptime why: []const u8) type {
    @compileError("fabrum.render." ++ name ++ " isn't available: " ++ why);
}

test {
    if (options.quartz) _ = @import("render/quartz.zig");
}
