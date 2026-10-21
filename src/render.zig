//! Renderers that come with fabrum: they draw `fabrum.layout` render
//! commands with a platform's own 2D API.
//!
//! - `Quartz`: Core Graphics and Core Text, on macOS. It is the AppKit
//!   platform's canvas, and also draws on its own into any `CGContext`
//!   (a bitmap, a PDF) with any `platform` option, given fabrum's `quartz`
//!   option (`-Dquartz=true`, or `.quartz = true` from a `build.zig`).
//!
//! - `Cairo`: Cairo and Pango. It is the GTK platform's canvas, and also
//!   draws on its own into any `cairo_t` with any `platform` option, given
//!   fabrum's `cairo` option (`-Dcairo=true`, or `.cairo = true`), which
//!   links Cairo and Pango.
//!
//! Portable renderers that draw into pixels on any OS, such as z2d and
//! ThorVG, are separate packages, which the app gives its fabrum to (see
//! `layout.draw` and docs/renderers.md).
const std = @import("std");
const builtin = @import("builtin");

const options = @import("fabrum_options");

/// The Quartz renderer, for `.cg_context` surfaces. In builds with the
/// AppKit platform, and on macOS with fabrum's `quartz` option.
pub const Quartz = if (options.quartz) @import("render/quartz.zig") else unavailable("Quartz", if (builtin.target.os.tag == .macos)
    "build fabrum with -Dquartz=true (`.quartz = true`) to draw with it on the " ++ options.platform ++ " platform"
else
    "it needs macOS, and this build is for " ++ @tagName(builtin.target.os.tag));

/// The Cairo renderer, for `.cairo` surfaces. In builds with the GTK
/// platform, and with fabrum's `cairo` option.
pub const Cairo = if (options.cairo) @import("render/cairo.zig") else unavailable("Cairo", "build fabrum with -Dcairo=true (`.cairo = true`) to draw with it on the " ++ options.platform ++ " platform");

fn unavailable(comptime name: []const u8, comptime why: []const u8) type {
    @compileError("fabrum.render." ++ name ++ " isn't available: " ++ why);
}

test {
    if (options.quartz) _ = @import("render/quartz.zig");
    if (options.cairo) _ = @import("render/cairo.zig");
}
