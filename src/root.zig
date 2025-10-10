const std = @import("std");

/// Gravity represents unit alignment within a layout.
pub const Gravity = enum {
    /// Aligns the unit to the start of the axis. This is the left for x and top for y.
    start,
    /// Aligns the unit to the center of the axis.
    center,
    /// Aligns the unit to the end of the axis. This is the right for x and bottom for y.
    end,

    pub const default = Gravity.start;

    pub const left = Gravity.start;
    pub const top = Gravity.start;

    pub const right = Gravity.end;
    pub const bottom = Gravity.end;
};

pub const Vec2 = @import("vec2.zig");
pub const Rect = @import("rect.zig");
pub const Range = @import("range.zig");
pub const Color = @import("color.zig");

pub const Sizing = @import("sizing.zig");
pub const Padding = @import("padding.zig");
pub const Alignment = @import("alignment.zig");
pub const CornerRadius = @import("corner_radius.zig");
pub const BorderWidths = @import("border_widths.zig");
pub const RenderCommand = @import("render_command.zig");

pub const layout = @import("layout.zig");
pub const LayoutConfig = layout.Config;
pub const LayoutConstraints = layout.Constraints;
pub const LayoutContent = layout.Content;
pub const LayoutUnit = layout.Unit;
pub const Context = layout.Context;

const text = @import("content/text.zig");
pub const TextContent = text.Content;
pub const HeuristicTextContent = text.HeuristicContent;
pub const TextAlign = text.Align;
pub const TextContentCachedContext = text.ContentCachedContext;
pub const TextStyle = text.Style;
pub const TextWrapMode = text.WrapMode;

pub const Element = @import("element.zig");

pub const util = @import("util.zig");

test {
    std.testing.refAllDecls(@This());
}
