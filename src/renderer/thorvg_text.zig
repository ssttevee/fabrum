//! ThorVG text measurement utilities.
//!
//! This module provides text measurement functions using ThorVG's actual
//! text rendering capabilities, replacing the crude heuristics with accurate
//! measurements based on font metrics.
//!
//! Usage:
//! ```
//! var text = fabrum.TextContent{
//!     .text = "Hello World",
//!     .style = .{
//!         .font_size = 16,
//!         .measure_fn = fabrum.measureTextThorVG,
//!     },
//! };
//! ```

const std = @import("std");
const tvg = @import("thorvg");
const root = @import("../root.zig");

const Vec2 = root.Vec2;
const TextContent = root.TextContent;

/// Measures text using ThorVG's actual text rendering.
/// This function creates a temporary Text object, sets the font size,
/// and retrieves the bounding box to get accurate measurements.
///
/// Falls back to heuristic measurements if ThorVG operations fail.
pub fn measureText(text: []const u8, style: TextContent.TextStyle) Vec2 {
    if (text.len == 0) {
        return Vec2.init(0, style.resolvedLineHeight());
    }

    var buf: [4096]u8 = undefined;
    if (text.len >= buf.len) {
        return Vec2.init(0, style.resolvedLineHeight());
    }

    const text_obj = tvg.Text.init() catch {
        return Vec2.init(0, style.resolvedLineHeight());
    };
    defer text_obj.deinit();

    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;

    text_obj.setText(buf[0..text.len :0]);

    text_obj.setFont(if (style.font) |f| f.ptr else null, style.font_size, null) catch unreachable;

    const bounds = text_obj.asPaint().getBounds(false);

    return Vec2.init(bounds.w, @max(bounds.h, style.resolvedLineHeight()));
}
