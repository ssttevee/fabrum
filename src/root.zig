const std = @import("std");

pub const Content = @import("content.zig");

const core = @import("core.zig");
pub const Vec2 = core.Vec2;
pub const Rect = core.Rect;
pub const Range = core.Range;
pub const Color = core.Color;

pub const layout = @import("layout.zig");
pub const LayoutGravity = layout.Gravity;
pub const LayoutPadding = layout.Padding;
pub const LayoutSizing = layout.Sizing;
pub const LayoutChildAlignment = layout.ChildAlignment;
pub const LayoutConstraints = layout.Constraints;
pub const LayoutConfig = layout.Config;
pub const LayoutContext = layout.Context;
pub const LayoutContextConfig = layout.ContextConfig;

pub const framing = @import("framing.zig");
pub const CornerRadius = framing.CornerRadius;
pub const BorderWidths = framing.BorderWidths;
pub const BorderConfig = framing.BorderConfig;
pub const ScrollFlags = framing.ScrollFlags;
pub const RenderData = framing.RenderData;
pub const RenderCommand = framing.RenderCommand;
pub const RenderCommandIterator = framing.RenderCommandIterator;
pub const ElementDeclaration = framing.ContainerDeclaration;
pub const FramingContext = framing.Context;

const svg = @import("renderer_svg.zig");
pub const SvgRenderer = svg.SvgRenderer;

test {
    std.testing.refAllDecls(@This());
}
