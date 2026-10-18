//! Draws into a Core Graphics context with a renderer that only draws into
//! pixels, which must be a compile error.
const fabrum = @import("fabrum");
const layout = fabrum.layout;

const PixelsOnly = struct {
    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};

    pub fn render(_: *PixelsOnly, _: []const layout.RenderCommand, _: layout.Surface, _: ?[]const fabrum.Rect) !void {}
};

export fn drawIntoCoreGraphics(cg: *anyopaque) void {
    var renderer: PixelsOnly = .{};
    layout.draw(&renderer, &.{}, .cg_context, cg, null) catch {};
}
