# Write and package a renderer

A renderer turns layout commands into pixels or drawing-context calls.
It does not own component state, input, layout or the window. Start with
[custom content](custom-content.md) if all you need is an extension to an
existing renderer. The [renderer reference](../renderers.md#writing-a-renderer)
lists the contract and built-in implementations.

## Start with a contract-checked renderer

This working adapter exposes the required shape while reusing fabrum's
box-only test implementation:

```zig
const BoxRenderer = struct {
    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
    text_context: Text.Context = .default,
    inner: layout.TestRenderer = .{},
    pub fn render(self: *BoxRenderer, commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void {
        try self.inner.render(commands, surface, damage);
    }
};

comptime {
    layout.checkRenderer(BoxRenderer);
    std.debug.assert(layout.accepts(BoxRenderer, .pixels));
    std.debug.assert(!layout.accepts(BoxRenderer, .cairo));
}
```

It is useful for bringing up a host, not as a text renderer: it ignores
content and corner radii. `checkRenderer` checks the presence and shape of
`Text`, `surfaces` and `render`; it cannot verify that you draw correctly.
`accepts` is a compile-time surface query. Call through `layout.draw` so a
pixel renderer accidentally used with `.cg_context` gives a compile error
explaining which surfaces it accepts. Renderer-specific errors still return
at runtime. The helper does not validate a pixel format's support for you.

A toolkit's `AppWith(Root, Renderer)` additionally expects `init(gpa)`,
`deinit` and a `text_context`, and a renderer that accepts the toolkit's
context kind: `.cg_context` for AppKit and `.cairo` for GTK. A renderer that
only accepts pixels cannot simply replace a context canvas.

## Implement command dispatch in paint order

Read the command stream once for each damage region. Handle rectangle,
border, content, scissor-start and scissor-end. Preserve depth-first order;
`z_index` is metadata and must not be used to sort commands independently
of their clips. Rounded radii use `CornerRadius.fitted` to avoid overlap.
Draw borders inside the box; between-child dividers already arrive as
rectangle commands.

Scissors nest. Apply only the axes requested by `ScissorStart` and restore
the previous clip at the matching end. Even when a region culls a whole
subtree, keep scissor nesting balanced. Use the command's point-space box,
not a native widget coordinate system. Unknown content may draw nothing,
but document that limitation. Recognize your `Text.asTextContent(content)`
and renderer-specific picture types by their vtable before casting them.
Shared bitmap content uses `layout.Image.asImageContent(content)`. Validate
its source, use `image.placement` for fitting and alignment, and respect its
sampling and snapping options. Context backends snap through their native
device transform; pixel backends pass the target scale to placement.
Keep images inside their content box and active scissors, before later
commands. See the [shared image contract](../image-design.md).
The [TileRenderer](custom-content.md#teach-a-renderer-to-draw-your-content)
shows a complete custom-content dispatch adapter.

Read [Cairo's implementation](../../src/render/cairo.zig) for context drawing
and state preservation. In fabrum-renderer-z2d, `src/root.zig` draws each
damage region into a scratch surface and composites nested clip layers,
since z2d has no clipping primitive. ThorVG uses its software canvas and
picture types instead. Follow the actual drawing library's model rather
than assuming clipping works like another backend.

## Match measurement to text drawing

Define `Text` with `layout.text.Content(YourContext)`. The context supplies
`measureText(self, text, style) !Vec2`, using the same fonts, metrics,
weights and spacing as drawing. Wrap it in `layout.text.CachedContext` to
avoid measuring identical strings and size-affecting styles every frame.
Its default bound is 1024 entries; reaching the bound clears the cache
before insertion. Clear it deliberately after changing loaded fonts or
metrics. Shared text-context copies borrow the same underlying state, so
deinitialize that state once, after all runtime text is gone.

At draw time, recognize text and iterate `lines(width)` or
`linesWithSizes(width)` at the command's final width. Honor style alignment,
line height and ellipsis rather than drawing the original whole string.
Iterator-produced cut lines borrow scratch storage until the next call;
consume them before advancing. The layout implementation currently wraps
words on ASCII spaces and character mode on bytes; a sophisticated shaping
engine alone does not fix those layout-level limits.

The z2d package's `src/content.zig` wraps its font measurer in a cache.
`loadFont` borrows font names and font data, uses the first font as default,
and must run before layout measurement. It handles Latin kerning, but no
complex shaping or font fallback; font weight does not select a face, and
letter spacing is neither measured nor drawn. Document such limits rather
than advertising general text support. A missing usable font can surface
as `error.MeasureFailed` during layout, before `render` is called.

## Honor surfaces, scale and damage

For pixels, obey `stride`, `format` and `scale`; tightly packed RGBA is only
one valid surface. Multiply point coordinates, radii, border widths and
font sizes by scale. Premultiply color channels for RGBA/BGRA. For `gray8`,
clear to white and compute luma over white with `PixelFormat.grayOf`.
Do not dither or otherwise mutate a retained framebuffer outside the damage
unless that is an explicit host presentation step.

With null damage, redraw the whole surface. With an empty damage slice,
draw nothing. For each region, clear it and replay every command whose box
grown by the damage margin touches it, clipped to the region and nested
scissors. Clearing then drawing only the changed command loses backgrounds
and overlapping objects. Keep everything outside the regions unchanged.
Anti-aliasing and glyph overhang must stay inside the declared damage margin,
two points by default, or invalidate a larger area deliberately.

Quartz and Cairo preserve context drawing state and clip to damage but do
not clear the context; their host owns its background. Both combine more
than 64 regions into a bounding rectangle. Quartz and Cairo honor per-axis scissor flags. State the surface's
coordinate convention explicitly, especially a Core Graphics context that
may need flipping to top-left, y-down coordinates.

## Let the application inject fabrum

A renderer package imports `fabrum` but lets its consumer supply the module:

```zig
pub fn addRenderer(exe: *std.Build.Step.Compile, renderer: *std.Build.Module, fabrum: *std.Build.Module) void {
    renderer.addImport("fabrum", fabrum);
    exe.root_module.addImport("fabrum", fabrum);
    exe.root_module.addImport("my-renderer", renderer);
}
```

Here `renderer` is the module obtained from the renderer dependency and
`fabrum` is the application's already configured module. Its public import
name in this example is `my-renderer`; use the package's actual public name
in an application. For z2d, obtain `.module("fabrum-renderer-z2d")` from
the `fabrum_renderer_z2d` dependency, inject fabrum, and import that public
name. The runtime then uses that renderer's `Text` and `text_context`.

If the app asks for fabrum with `.platform = .none` but a renderer asks
for another instance with different build arguments, Zig may report
`file exists in modules 'fabrum' and 'fabrum0'`. Do not fix that by copying
files or renaming module types: inject the same `*std.Build.Module`.
Forgetting the import instead gives `no module named 'fabrum'` from the
renderer. The same rule applies to every intermediate platform package.

## Structure the package

Follow fabrum-renderer-z2d's build and source organization:

1. Keep the renderer in `src/root.zig`, renderer-specific content and text
   in `src/content.zig`, and pixel regression cases in `test/render_test.zig`.
2. In `build.zig`, expose the renderer with `b.addModule`, passing target,
   optimization and its drawing-library import. Leave fabrum unconfigured
   until the consumer calls `addImport`.
3. Declare fabrum as a lazy manifest dependency for the package's own tests.
   After public module creation, check `b.isRoot()`. Only in that root
   branch call `b.lazyDependency("fabrum", ...)`, with `.platform = .none`,
   and supply it to the renderer and tests. Return when a lazy dependency
   is not yet available so Zig can fetch and rerun the build.
4. Wire the module tests and render tests to a `test` step. Include their
   source paths in the package manifest if published consumers should be
   able to run the package's tests from the fetched archive. The current
   z2d manifest omits its `test` directory even though its root build uses it;
   do not copy that omission into a new package.
5. Add a small consumer fixture which passes options to fabrum and injects
   its module, as fabrum-renderer-thorvg's `test/consumer` does. This catches
   an accidental second fabrum instance that renderer-only tests miss.

The app chooses renderer initialization and font resources. Avoid adding a
windowing dependency to a portable pixel renderer merely to obtain fonts;
accept font bytes or a renderer-specific loading service instead.

## Compare partial drawing with a full redraw

Begin with a deterministic pixel test:

```zig
test "guide renderer partial redraw equals full redraw" {
    const gpa = std.testing.allocator;
    var renderer: BoxRenderer = .{};
    var partial: [20 * 20]u8 align(4) = undefined;
    var full: [20 * 20]u8 align(4) = undefined;
    var commands = [_]layout.RenderCommand{.{
        .bbox = .init(2, 2, 8, 8),
        .unit_id = 1,
        .data = .{ .rectangle = .{ .color = .black, .corner_radius = .{} } },
    }};
    var damage: layout.Damage = .{};
    defer damage.deinit(gpa);
    try layout.draw(&renderer, &commands, .pixels, .packed_(&partial, 20, 20, .gray8), try damage.update(gpa, &commands, .init(20, 20)));
    commands[0].bbox.x = 6;
    const changed = try damage.update(gpa, &commands, .init(20, 20));
    try layout.draw(&renderer, &commands, .pixels, .packed_(&partial, 20, 20, .gray8), changed);
    try layout.draw(&renderer, &commands, .pixels, .packed_(&full, 20, 20, .gray8), null);
    try std.testing.expectEqualSlices(u8, &full, &partial);
}
```

Extend it to moves, removals, color/content changes, overlapping alpha,
nested/per-axis clips, rounded borders, text overhang, nontrivial stride,
Retina scale, RGBA/BGRA and gray8 where supported. Initialize a retained
partial buffer, apply `Damage` for each change, and compare it with a fresh
full redraw at every step. Compare against expected pixels too: two paths
through the same buggy rasterizer can agree. Keep font fixtures and text
measurements stable, and test that unchanged fingerprinted content causes
no damage. A renderer contract check alone cannot establish any of these
properties.
