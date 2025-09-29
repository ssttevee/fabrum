const std = @import("std");
const root = @import("root.zig");
// const layout = @import("layout.zig");

const Vec2 = root.Vec2;
const Rect = root.Rect;
const Color = root.Color;
const LayoutContext = root.LayoutContext;
const LayoutConfig = root.LayoutConfig;
const Content = root.Content;
const LayoutContextConfig = root.LayoutContextConfig;

/// Generalized measurable + (optionally) reshape-able content abstraction.
/// The core layout engine is agnostic of what "content" is; this file provides
/// a higher layer similar to Clay's text/image/custom concepts, but unified
/// behind a small vtable.
///
/// Philosophy:
/// - No global state (all caching is optional + user provided).
/// - Content instances are owned by the caller; this layer does not allocate
///   unless reshape() is invoked for dynamic wrapping.
/// - Rendering is still out of scope; we only produce logical render commands
///   (that a later renderer layer can translate to backend draw calls).

// -----------------------------------------------------------------------------
// Basic Shared Types
// -----------------------------------------------------------------------------

pub const CornerRadius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_left: f32 = 0,
    bottom_right: f32 = 0,

    pub fn uniform(v: f32) CornerRadius {
        return .{
            .top_left = v,
            .top_right = v,
            .bottom_left = v,
            .bottom_right = v,
        };
    }
};

pub const BorderWidths = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    /// Adds a divider between each child.
    between_children: f32 = 0,

    pub fn isZero(self: BorderWidths) bool {
        return self.left == 0 and self.right == 0 and self.top == 0 and self.bottom == 0 and self.between_children == 0;
    }

    pub fn any(self: BorderWidths) bool {
        return !isZero(self);
    }
};

pub const BorderConfig = struct {
    color: Color = .{},
    widths: BorderWidths = .{},
};

pub const ScrollFlags = packed struct {
    horizontal: bool = false,
    vertical: bool = false,

    pub fn any(self: ScrollFlags) bool {
        return self.horizontal or self.vertical;
    }
};

pub const RenderData = union(enum) {
    rectangle: Rectangle,
    border: Border,
    content: *Content,
    scissor_start: ScissorStart,
    scissor_end: void,

    pub const Rectangle = struct {
        color: Color,
        corner_radius: CornerRadius,
    };

    pub const Border = struct {
        color: Color,
        widths: BorderWidths,
        corner_radius: CornerRadius,
    };

    pub const ScissorStart = struct {
        horizontal: bool,
        vertical: bool,
    };
};

pub const RenderCommand = struct {
    bbox: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    z_index: i16 = 0,
    element_id: u64 = 0,
    data: RenderData,
};

pub const ElementDeclaration = struct {
    id: []const u8 = .{},

    /// Controls various settings that affect the size and position of an element, as well as the sizes and positions of any child elements.
    layout: LayoutConfig = .{},

    /// Controls the background color of the resulting element.
    /// By convention specified as 0-255, but interpretation is up to the renderer.
    /// If no other config is specified, .backgroundColor will generate a RECTANGLE render command, otherwise it will be passed as a property to IMAGE or CUSTOM render commands.
    background_color: Color = .{},

    /// Controls the "radius", or corner rounding of elements, including rectangles, borders and images.
    corner_radius: CornerRadius = .{},

    /// Controls settings related to aspect ratio scaling.
    aspect_ratio: AspectRatioConfig = .{},

    /// Controls whether and how an element "floats", which means it layers over the top of other elements in z order, and doesn't affect the position and size of siblings or parent elements.
    floating: FloatingConfig = .{},

    /// Used to create CUSTOM render commands, usually to render element types not supported by Clay.
    content: *Content = .{},

    /// Controls whether an element should clip its contents, as well as providing child x,y offset configuration for scrolling.
    clip: ClipConfig = .{},

    /// Controls settings related to element borders, and will generate BORDER render commands.
    border: BorderConfig = .{},

    /// A pointer that will be transparently passed through to resulting render commands.
    user_data: ?*anyopaque = null,

    pub const AspectRatioConfig = struct {
        /// A float representing the target "Aspect ratio" for an element, which is its final width divided by its final height.
        aspect_ratio: f32 = 0,
    };

    pub const FloatingConfig = struct {
        mode: AttachMode = .default,
        parent: union { id: u32, index: usize } = 0,
        element_point: AttachPoint = .left_top,
        parent_point: AttachPoint = .left_top,
        offset: Vec2 = .zero,
        expand: Vec2 = .zero,
        z_index: i16 = 0,

        /// Transparently pass through pointer events like hover and click to elements underneath the floating element.
        pointer_passthrough: bool = false,

        /// Whether or not a floating element should be clipped to the same clipping rectangle as the element it's attached to.
        clip_to_parent: bool = false,

        pub const AttachPoint = enum {
            left_top,
            left_center,
            left_bottom,
            center_top,
            center_center,
            center_bottom,
            right_top,
            right_center,
            right_bottom,

            pub const top_left = AttachPoint.left_top;
            pub const top_center = AttachPoint.center_top;
            pub const top_right = AttachPoint.right_top;

            pub const center_left = AttachPoint.center_left;
            pub const center = AttachPoint.center_center;
            pub const center_right = AttachPoint.center_right;

            pub const bottom_left = AttachPoint.left_bottom;
            pub const bottom_center = AttachPoint.center_bottom;
            pub const bottom_right = AttachPoint.right_bottom;

            pub const default = top_left;
        };

        pub const AttachMode = enum {
            /// no floating
            none,
            parent,
            element_index,
            element_id,
            root,

            pub const default = AttachMode.none;
        };

        pub fn active(self: FloatingConfig) bool {
            return self.mode != .none;
        }
    };

    /// Controls the axis on which an element switches to "scrolling", which clips the contents and allows scrolling in that direction.
    pub const ClipConfig = struct {
        /// Clip overflowing elements on the X axis.
        horizontal: bool = false,
        /// Clip overflowing elements on the Y axis.
        vertical: bool = false,
        /// Offsets the x,y positions of all child elements. Used primarily for scrolling containers.
        child_offset: Vec2 = .{},
    };
};

pub fn Context(comptime config: LayoutContextConfig) type {
    return struct {
        layout: LayoutContext(ElementData, config),

        const Self = @This();

        const ElementData = struct {};

        pub const RenderCommandIterator = struct {
            ctx: *const Self,
            stack: [config.getDepth()]ElementTraversalState = [_]ElementTraversalState{.{}} ** config.getDepth(),
            len: usize = 1,

            const ElementTraversalState = struct {
                index: usize = 0,
                child_pos: usize = 0,

                // step: something, // since we're emitting render commands once per `next` call, we need to keep track of which render command should come next
            };

            pub fn next(self: *RenderCommandIterator) ?RenderCommand {
                if (self.len <= 0) {
                    return null;
                }

                const parent = self.ctx.layout.get(self.stack[self.len - 1]);
                if (self.child_pos >= parent.children.len) {
                    self.child_pos = 0;
                    self.len -= 1; // pop
                }

                const element = self.ctx.layout.get(parent.children[self.child_pos]);

                _ = element;

                // TODO: walk through elements depth first and generate render commands

                // return command;
            }
        };

        pub fn beginLayout(self: *Self) void {
            self.layout.begin();
        }

        pub fn beginLayoutBreadth(self: *Self, breadth: bool) void {
            self.layout.beginBreadth(breadth);
        }

        pub fn openElement(self: *Self, decl: ElementDeclaration) !usize {
            return try self.layout.openElement(decl);
        }

        pub fn openElementBreadth(self: *Self) !usize {
            return try self.layout.openElement();
        }

        pub fn closeElement(self: *Self, element_index: usize) void {
            self.layout.closeElement(element_index);
        }

        pub fn endLayout(self: *Self) RenderCommandIterator {
            self.layout.end();

            return .{ .ctx = self };
        }
    };
}
