# Add measured and drawn content

Use ordinary containers for backgrounds, borders and event targets. Add a
`layout.Content` when an object needs its own intrinsic measurement, such
as a picture, waveform or preview. Content is measured by layout and drawn
only by a renderer that recognizes it. The
[content reference](../layout.md#content) gives the exact vtable contract.

## Implement measurement and ownership

Embed a `layout.Content` in your own object and use the vtable to recover
its enclosing type:

```zig
const Tile = struct {
    content: layout.Content = .{ .vtable = &vtable, .limit = .parent },
    color: fabrum.Color = .rgb(40, 90, 160),
    released: bool = false,
    const vtable: layout.Content.VTable = .{
        .measure = measure,
        .measure_min = minimum,
        .deinit = release,
        .fingerprint = fingerprint,
        .debug_name = "Tile",
    };
    fn measure(_: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
        return constraints.clamp(.init(64, 32));
    }
    fn minimum(_: *layout.Content, _: layout.Constraints) layout.Content.MeasureError!Vec2 {
        return .init(8, 8);
    }
    fn release(content: *layout.Content) void {
        const self: *Tile = @fieldParentPtr("content", content);
        self.released = true;
    }
    fn fingerprint(content: *const layout.Content) u64 {
        const self: *const Tile = @fieldParentPtr("content", content);
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.color));
    }
    pub fn from(content: *const layout.Content) ?*const Tile {
        if (content.vtable != &vtable) return null;
        return @fieldParentPtr("content", content);
    }
};
```

`measure` receives optional maximum width and height. Return the content's
preferred size under them, or `error.MeasureFailed` if measurement cannot
be made. Layout may call it again at the final width, so keep measurement
repeatable and do not perform blocking I/O in it. `measure_min` tells layout
how far the content can be squeezed; null means it cannot shrink below its
measured size. Return a minimum consistent with the content you can draw.

Use `limit = .ancestors` for wrapping content that should discover the
nearest available bound through fitting or growing wrappers. Keep `.parent`
for a picture or other content that fills its own limit: using the ancestor
limit could make it fill much more of the screen than intended. Scroll-axis
limits stop at a scrolling container.

The context borrows content. It never calls `Content.deinit`, including
when beginning a new frame or destroying the context. The owner explicitly
calls it after drawing is finished. `Tile.release` only records that fact;
an owning implementation would release its image or other external
resources there. Frame-arena allocation releases memory, not toolkit image
handles. State-owned content needs a state deinitializer; externally owned
content needs its own lifetime management.

## Teach a renderer to draw your content

This adapter translates the tile into a rectangle and delegates pixel
drawing to the box-only test renderer:

```zig
const TileRenderer = struct {
    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
    gpa: std.mem.Allocator,
    inner: layout.TestRenderer = .{},
    pub fn render(self: *TileRenderer, commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void {
        var translated: std.ArrayList(layout.RenderCommand) = .empty;
        defer translated.deinit(self.gpa);
        for (commands) |command| {
            var output = command;
            if (command.data == .content) if (Tile.from(command.data.content)) |tile| {
                output.data = .{ .rectangle = .{ .color = tile.color, .corner_radius = .{} } };
            };
            try translated.append(self.gpa, output);
        }
        try self.inner.render(translated.items, surface, damage);
    }
};
```

It preserves command order, bounding boxes and scissor commands. Unknown
content remains available to the underlying renderer, which in this case
ignores it. In a production renderer, recognize your content inside its
`.content` case, then draw it with that renderer's paths, images or GPU
resources. There is no universal path command or canvas callback on
`layout.Content`. If you merely need rectangles and borders, declare
containers instead of adding a content type.

Use `context.appendContent(&tile.content)` in raw layout. In an app view,
use `ui.content(&tile.content)` with a tile that remains alive through
command consumption; an arena-backed tile is suitable when it owns no
external resource. `ui.content` records allocation/layout-capacity failure
for the enclosing frame, so its `void` return does not mean layout can
never fail. The
[executable tile test](../../test/compile/guide_snippets.zig) checks
measurement, drawing, damage and explicit release together.

## Use a shared bitmap

For decoded pixels, use `layout.Image`. Its source borrows bytes with an
explicit width, height, byte stride, pixel format and pixels-per-point
`scale`. The source accepts opaque `gray8` and premultiplied RGBA8 or BGRA8;
padding is allowed at the end of rows. Quartz, Cairo, z2d and ThorVG draw
this shared type.

```zig
fn bitmapExample() !void {
    const pixels = [_]u8{ 0, 64, 128, 255 };
    var image = try layout.Image.init(.{
        .data = &pixels,
        .width = 2,
        .height = 2,
        .stride = 2,
        .format = .gray8,
    }, .{ .fit_mode = .crop, .sampling = .nearest, .snap_to_pixels = true });
    var context: layout.Context = try .init(std.testing.allocator, .{ .units = 16 });
    defer context.deinit(std.testing.allocator);
    context.begin(.{ .sizing = .fixedXY(100, 100) });
    try context.appendContent(&image.content);
    context.end();
    try context.computeLayout();
    var commands = context.renderCommands();
    while (commands.next()) |command| {
        if (command.data == .content) try std.testing.expect(layout.Image.asImageContent(command.data.content) != null);
    }
}
```

The image and its bytes must live until drawing finishes. It owns no
resource and needs no deinitializer. In an app view, append the same
content with `ui.content(&image.content)`. Increment `image.revision` after
changing its pixels in place so damage tracking notices. Source metadata
and style changes are tracked automatically.

The four fit modes and alignment share their measurement and placement
logic across renderers. `smooth` uses backend interpolation; `nearest` selects
source pixels without interpolation. Scaled pixels can vary between backends. For exact 1:1 placement use crop, nearest sampling and a
source `scale` equal to the target's scale; snapping rounds only the
origin, and the box still clips the image. See the
[shared image design](../image-design.md) for the full contract.

## Use a renderer-specific picture

On AppKit, Quartz supplies SVG-path and bitmap pictures. This example
creates a path, lays it out and keeps it alive until commands are consumed:

```zig
fn pictureExample(gpa: std.mem.Allocator) !void {
    if (comptime app.platform.kind == .appkit) {
        const Quartz = fabrum.render.Quartz;
        var picture = try Quartz.svgPicture(gpa, "<svg viewBox=\"0 0 16 16\"><path d=\"M0 0 L16 0 L8 16 Z\"/></svg>");
        defer picture.deinit();
        picture.style = .{ .fit_mode = .contain, .alignment = .center, .color = .black };
        var context: layout.Context = try .init(gpa, .{ .units = 16 });
        defer context.deinit(gpa);
        context.begin(.{ .sizing = .fixedXY(100, 100) });
        try context.appendContent(&picture.content);
        context.end();
        try context.computeLayout();
        var commands = context.renderCommands();
        while (commands.next()) |command| {
            if (command.data == .content) try std.testing.expect(Quartz.content.Picture.asPictureContent(command.data.content) != null);
        }
    }
}
```

This block is conditional because Quartz is included by AppKit, or with
`-Dquartz=true` on macOS. It is not a portable SVG renderer. Its SVG parser
is a path-oriented subset; do not assume a whole SVG document's styles and
elements are implemented. Its vector picture takes the configured fill
color. Bitmap constructors can take ownership of a Core Graphics image
or borrow it; match `owns_image` to the ownership you actually have.

Choose contain to preserve the full image, cover to fill while preserving
ratio, crop for unscaled placement, or stretch to fill both axes. Quartz
pictures honor `alignment` on both axes for vectors and bitmaps, including
cover and unscaled crop placement. Stretch fills the box independently on
each axis. Every mode clips drawing to its laid-out box. If cover
measurement makes that box larger than its parent, clip the parent too.
A picture type is renderer-specific: a Quartz picture is not automatically
recognized by another renderer.

Cairo and z2d draw shared bitmap content through `layout.Image`, but supply
no SVG picture. ThorVG also supplies backend-specific picture content and
supports SVG and bitmap rendering with all four fit modes, alignment on
both axes, and clipping to the picture box. Choose a renderer that
implements your needed content, or implement the extension rather than
assuming all renderers share picture support. See the
[renderer guide](writing-a-renderer.md).

## Hit-test a content surface

`layout.Content` has no event vtable. Wrap custom content in a keyed
`ui.open` container and attach `on_click`, `on_pointer` or `focus` there.
The [drag pad](widgets-and-input.md#capture-a-drag-and-handle-keyboard-navigation)
is an event surface built this way. The runtime hit-tests boxes, respecting
rounded corners and ancestor clips. For a detailed shape, use `Pointer.local`
to test its geometry in update, while remembering that accepting pointer
capture is determined by the declared container.

With raw layout, use `unit.hovered(point)` for a unit's own shape or
`context.hoveredUnits(point)` for topmost-first candidates. Raw iteration
does not remove candidates clipped by their ancestors. If the app needs
runtime focus, capture, bubbling and clipping behavior, use the runtime
rather than rebuilding that behavior from raw hover candidates.

## Make damage follow changes

`fingerprint` must hash everything that changes the drawn pixels inside
a fixed box: source identity or revision, colors, text, style and relevant
rendering options. Geometry is already part of command comparison.
Without a fingerprint, content is conservatively damaged every frame.
A stable fingerprint that omits a changed value is worse: damage can say
nothing changed and leave stale pixels. Mutable image caches need a revision
in the fingerprint rather than just a constant pointer address.

Draw inside the command's box plus the damage margin (two points by
default), and clip effects that would extend farther. Damage tracks the
old and new boxes when content moves. Verify changing and removing content
by comparing partial redraw with a full redraw, as in the
[renderer test](writing-a-renderer.md#compare-partial-drawing-with-a-full-redraw).
