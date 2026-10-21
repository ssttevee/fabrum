# Renderers

A renderer draws `fabrum.layout` render commands into a surface. The layout
engine does not import a renderer. fabrum comes with two that use a
platform's own 2D API, and
portable ones that draw into pixels on any OS are separate packages that the
app gives its fabrum to.

For implementation steps and pixel tests, see
[writing a renderer](guides/writing-a-renderer.md).

## Built in: `fabrum.render`

| Renderer | Surface | Text | Comes with | On its own |
|---|---|---|---|---|
| `fabrum.render.Quartz` | `.cg_context` (a `CGContextRef` whose user space is fabrum's: top left, y down, points) | Core Text | the AppKit platform, as its canvas | `-Dquartz=true` (`.quartz = true`) with any platform on macOS: draw into a bitmap or PDF context without a window |
| `fabrum.render.Cairo` | `.cairo` (a `cairo_t`) | Pango | the GTK platform, as its canvas | `-Dcairo=true` (`.cairo = true`) with any platform; links Cairo and Pango through pkg-config |

Both have `init(gpa)`, `deinit`, a `text_context` for their `Text`, and
`render`. Quartz draws rectangles, borders, text, clips and pictures (SVG
paths and bitmaps, `fabrum.render.Quartz.content.Picture`); Cairo draws
rectangles, borders, text and clips, not pictures yet. Asking for a renderer
that isn't in the build is a compile error that says which option to pass.

`renderer.text(string, style)` creates text using its `text_context`; the
string and renderer must stay alive through drawing. Quartz also exposes
`svgPicture(gpa, svg)`, `bitmapPicture(image, width, height, owns_image)`
and `bitmapPictureFromCGImage(image, owns_image)`; deinitialize pictures
when their commands have been consumed. Cairo's `Image.init(width, height)`
creates an offscreen context (`image.context`), with `pixel(x, y)`,
`writePng(path)` and `deinit()`. `pixel` returns premultiplied R, G, B, A
bytes; `writePng` requires a sentinel-terminated path.

For context surfaces, both renderers preserve the drawing state and clip
to damage, but do not clear the context: the host clears or paints its
background first. More than 64 damage rectangles are combined into their
bounding rectangle. Quartz currently clips both axes for every
`scissor_start`, even when the command requests only one; Cairo honors the
per-axis flags.

A platform's `App(Root)` uses its canvas renderer; `AppWith(Root, Renderer)`
takes another one that accepts the platform's surface kind, with `init(gpa)`,
`deinit` and a `text_context`.

## External renderers

| Package | Surface | Formats | Notes |
|---|---|---|---|
| [fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d) | `.pixels` | premultiplied RGBA and BGRA, `gray8` | Pure Zig: builds for any target from any host. TrueType and OpenType fonts through `loadFont`; Latin text with kerning, no complex shaping. Used by fabrum-platform-inkview and the Kitchen's `none` build. |
| [fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg) | `.pixels` | premultiplied RGBA and BGRA | ThorVG's software engine: rectangles, borders, text, pictures and clipping. No `gray8`. |

Both are used the same way:

```zig
var renderer: Renderer = try .init(gpa);
defer renderer.deinit();
try renderer.loadFont("Go", @embedFile("Go-Regular.ttf"));
try fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, try rt.damage());
```

and the runtime is made with their text, `app.Runtime(.{ .Text =
Renderer.Text })` and `.text_context = renderer.text_context`, so text is
measured as it will be drawn.

### Injecting fabrum: one instance per program

Zig makes one instance of a dependency per set of arguments as passed. If
the app passes `.platform = .none` to fabrum and a renderer package asks for
fabrum with only `.target` and `.optimize`, two fabrum modules end up in one
program, and the build fails with `file exists in modules 'fabrum' and
'fabrum0'`. So the renderer packages don't depend on fabrum: their module
imports `fabrum` without providing it, and the app's `build.zig` gives them
the one it uses:

```zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
renderer.addImport("fabrum", fabrum);
```

Forgetting it is a plain "no module named 'fabrum'" error from the renderer.
The same applies to platform packages (fabrum-platform-inkview's
`addFabrum`), and to any package of your own that depends on fabrum. The
Kitchen's `build.zig` (`addNone`) is a complete example, choosing between
z2d and ThorVG with a build option. The history is in
`docs/hybrid-design.md` §15.

## Writing a renderer

A renderer is a type, usually in its own package, with:

```zig
/// Its text: a `layout.text.Content(...)` type that measures text as
/// the renderer draws it, for `app.Config.Text`.
pub const Text = ...;
/// The kinds of surface it draws into.
pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
/// Draws `commands` into `surface`. With `damage`, only those regions
/// are redrawn: each is cleared, for pixel surfaces, and every command
/// that touches it is drawn clipped to it; everything else is left as it
/// was. Null redraws everything.
pub fn render(self: *@This(), commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void
```

`layout.checkRenderer(R)` checks the shape at compile time with an error
that says what is missing, and `layout.draw` checks that the renderer
accepts the surface kind it is given, so a renderer for pixels used with a
`CGContext` fails the build, not the run. `layout.accepts(R, kind)` queries
surface support at compile time. Renderer-specific drawing failures still
come back from `draw`; content measurement can fail earlier during layout.

What a renderer must do:

- **Text.** Make `Text` with `layout.text.Content(Context)`, where `Context`
  has `measureText(self, text, style) !Vec2`; wrap it in
  `layout.text.CachedContext` so each string and style is measured once. At
  draw time, recognise a text command with `Text.asTextContent(content)` and
  draw its lines (`text.lines(width)` iterates them, cut with an ellipsis
  where the style asks) inside the command's box, aligned as the style says.
  Other content (a picture type of your own) is recognised the same way:
  content the renderer doesn't know draws nothing.
- **Rectangles and borders** with their corner radii (`CornerRadius.fitted`
  scales radii that would overlap); borders are drawn inside the box, with
  `between_children` dividers arriving as plain rectangles.
- **Clipping**: `scissor_start` begins a clip to the command's box along the
  axes it names, until the matching `scissor_end`; they nest.
- **Damage.** Draw each command within its box plus `layout.Damage.margin`
  (`margin_default` is 2 points, for anti-aliasing and glyphs that overhang),
  so that redrawing only the regions `Damage` reports is enough. With damage given, clear each
  region (transparent for formats with alpha, white for `gray8`), draw
  every command whose box grown by the margin touches it, clipped to it, and
  leave the rest untouched.
- **Pixels.** Honour `Surface.Pixels`'s `stride`, `format` and `scale`:
  commands and damage are in points, so every coordinate, radius, width and
  font size is multiplied by `scale`. Colors in the 4-byte formats are
  premultiplied by alpha; `gray8` is a luma over white
  (`layout.PixelFormat.grayOf`).

`layout.TestRenderer` is the smallest possible one (boxes only, no text),
and `src/render/cairo.zig` is a complete, readable one. The z2d renderer
shows how to do clipping and damage with a library that has no clip of its
own: each region is drawn into a scratch surface and copied into place.

For a renderer's own tests, depend on fabrum lazily and only when the
package is the root (`b.lazyDependency("fabrum", .{ ..., .platform = .none
})` inside `if (b.isRoot())`), as both external renderers do, so apps that
depend on the renderer never fetch a second fabrum.
