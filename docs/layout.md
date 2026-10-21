# The layout engine: `fabrum.layout`

`fabrum.layout` is an immediate-mode layout engine in the style of Clay: a
tree of containers is declared into a `Context` every frame, sized and
positioned, and turned into render commands for a renderer. It knows nothing
of application state, input or platforms; `fabrum.app` builds on it, and it
can be used alone. It builds for any target with any `-Dplatform`, and links
nothing.

```zig
const layout = @import("fabrum").layout;
```

## A frame

[`examples/layout_only.zig`](../examples/layout_only.zig), whole but for
its printing:

```zig
/// A header bar of fixed height over a panel that takes the rest, in a
/// column; the header holds a round badge beside its title. The names are
/// the unit IDs, to find the boxes by afterwards.
fn declare(ctx: *layout.Context, title: *Text, body: *Text) !void {
    ctx.begin(.{ .sizing = .fixedXY(320, 160), .axis = .y, .padding = .all(10), .child_gap = 10 });
    defer ctx.end();

    const header = try ctx.openContainerId(.fromString("header"), .{
        .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(32) }, .padding = .x(8), .child_gap = 8, .child_alignment = .center_left },
        .background_color = .rgb(60, 90, 160),
        .corner_radius = .uniform(6),
    });
    {
        const badge = try ctx.openContainer(.{ .layout = .{ .sizing = .fixed(16) }, .background_color = .white, .corner_radius = .uniform(8) });
        ctx.closeContainer(badge);
        try ctx.appendContent(&title.content);
    }
    ctx.closeContainer(header);

    const panel = try ctx.openContainerId(.fromString("panel"), .{
        .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(8) },
        .background_color = .white,
        .border = .{ .color = .gray(200), .widths = .outside(1) },
    });
    defer ctx.closeContainer(panel);
    try ctx.appendContent(&body.content);
}
```

```zig
    // allocates once, for up to `units` units; a layout is rebuilt in it every frame
    var ctx: layout.Context = try .init(gpa, .{ .units = 64 });
    defer ctx.deinit(gpa);

    var title: Text = undefined;
    var body: Text = undefined;
    texts(&title, &body);
    try declare(&ctx, &title, &body);
    try ctx.computeLayout();

    for ([_][]const u8{ "header", "panel" }) |id| {
        const box = ctx.getUnitByStringId(id).?.bbox;
        try out.print("{s}: {d:.0}x{d:.0} at {d:.0},{d:.0}\n", .{ id, box.w, box.h, box.x, box.y });
    }

    // what a renderer draws, in paint order
    var commands = ctx.renderCommands();
    while (commands.next()) |command| {
        const box = command.bbox;
        try out.print("  {t} {d:.0}x{d:.0} at {d:.0},{d:.0}\n", .{ command.data, box.w, box.h, box.x, box.y });
    }
```

The lifecycle: `Context.init(gpa, config)` allocates once for up to
`config.units` units (`depth` and `breadth` are estimated from it unless
given; `max_breadth` is 256). Each frame, `begin(root_config)` starts a
layout whose root must have fixed width and height supplied by the caller.
`openContainer`/`closeContainer`
and `appendContent` declare the tree, `end()` finishes it, `computeLayout()`
sizes and positions everything, and `renderCommands()` walks the result.
Units are read back by index (`get`, `getUnitByIndex`) or ID
(`getUnitById`, `getUnitByStringId`, `getUnitByIntId`), and
`hoveredUnits(point)` iterates units whose own shapes contain a point,
topmost first; it does not filter ancestor clips as the app runtime does.
The render-command iterator borrows the context's scratch buffer: finish
consuming it before creating another, and do not call its `deinit`.

Running out of room (`units`, `depth`, `breadth` or the children buffer)
fails the declaration with `error.LayoutCapacity`, logging which limit to
raise; the layout under way is unusable and the next `begin` starts over.
`openContainerBreadth` opens a container with a breadth of its own, for a
long list or a leaf. Any breadth, including the root's (`beginBreadth`),
must not exceed `max_breadth`; exceeding that is an assertion failure,
not `error.LayoutCapacity`. `computeLayout()` can return
`error.MeasureFailed` from content or `error.FloatingTargetNotFound` for a
missing floating target.

## Units and declarations

A **unit** is a container or a content. A container is declared with a
`ContainerDeclaration`:

| Field | Meaning |
|---|---|
| `layout: Config` | How the unit and its children are sized and placed: `sizing`, `padding`, `child_gap`, `child_alignment`, `axis`. |
| `background_color: Color` | A `rectangle` command when not transparent. |
| `corner_radius: CornerRadius` | `.uniform(r)` or `top_left`, `top_right`, `bottom_left`, `bottom_right`; radii that would overlap are scaled down as CSS does (`fitted`). |
| `border: .{ .color, .widths }` | `BorderWidths`: `left`, `right`, `top`, `bottom` and `between_children` (a divider centered in each gap). `.outside(w)`, `.all(w)`. Borders are drawn inside the box. |
| `floating: FloatingConfig` | See [floating](#floating). |
| `clip: ClipConfig` | See [clipping and scrolling](#clipping-and-scrolling). |
| `aspect_ratio` | `.{ .aspect_ratio = width_over_height }`, 0 for none. Shrinks one dimension to preserve the ratio. |
| `overflow` | Reserved; has no effect. Use `clip` for clipping and child offsets. |
| `user_data` | Stored on the declaration; not carried by render commands. |
| `id` | Reserved and unused; supply a `Unit.Id` to `openContainerId`. |

`Config`:

- `axis`: `.x` (a row, the default) or `.y` (a column). Children are laid
  along it in order, `child_gap` apart, after `padding`.
- `sizing`: a `Sizing` with a `width` and a `height` `Dimension`, each one
  of:
  - `.fit(range)`: as big as its content, clamped to `range` (`.{ .min = 0,
    .max = std.math.inf(f32) }` by default). The default.
  - `.grow(range)`: takes a share of the parent's free space along the axis,
    equally with its growing siblings; across the axis, fills the parent.
  - `.percent(fraction)`: a fraction of the parent's inner size (0 to 1).
  - `.fixed(points)`.

  Shorthands: `.fixed(n)`, `.fixedXY(w, h)`, `.grow(.{})`, `.growXY(x, y)`,
  `.fit(.{})`, `.fitXY(x, y)`, `.percent(f)`, `.percentXY(x, y)`, and
  `.{ .width = ..., .height = ... }`.
- `child_alignment`: an `Alignment` of two `Gravity` values (`start`,
  `center`, `end`), with the constants `top_left`, `center`, `center_left`,
  `bottom_right` and so on, placing children in the leftover space.

**How sizes are decided.** Widths are settled before heights, because the
height of content that wraps depends on its width. First, bottom-up, every
unit gets the size it asks for and a minimum (`min_size`) below which it
won't be squeezed: content is measured (under the width or height limit it
inherits, see below), and containers sum their children along the axis and
take the largest across it, plus padding and gaps. Then, top-down, each
container distributes its inner width: along its axis, fixed and percent
children take theirs, fitting children keep what they asked for, growing
children share what is left, and if the children don't fit, they are shrunk
towards their minimums (content that can be squeezed reports a smaller one
through `measure_min`: text cut with an ellipsis, or text that wraps, down to
its widest word, or widest character with `.characters` wrapping); across
its axis, growing children fill the parent and the rest are clamped to it. Content whose final width differs from what it was
measured for is measured again at that width, which gives it its height;
containers that fit take their heights from that, bottom-up; then heights
are distributed top-down the same way, and everything is positioned, with
leftover space given out by `child_alignment`. Floating units are laid out
last, against the unit they attach to.

`Context.spacer()` appends an empty unit that grows along the container's
axis, pushing what is before and after apart; spacers share free space with
growing siblings.

## Content

Content is anything measured by a callback: text, a native view's
placeholder, a picture. It is a `layout.Content` with a `VTable`:

- `measure(self, constraints)`: the size under `Constraints` (`max_width`,
  `max_height`, each optional).
- `measure_min` (optional): the smallest size it accepts, if it can be
  squeezed below `measure`.
- `fingerprint` (optional): a hash of everything that changes how it draws
  in a given box, for `Damage`; content without one is redrawn every frame.
- `deinit` (optional), `debug_name`.

Measurement callbacks return `Content.MeasureError!Vec2`
(`error.MeasureFailed`). The context borrows content; it never calls
`Content.deinit`, including on `begin` or `Context.deinit`. The owner frees
content and any external resources once its commands have been consumed.

Content is appended with `appendContent` (or the `Id` variants) and lives
until the frame's render commands have been consumed. Its `limit` says how
far up the tree the limits of its first measurement come from: `.parent`
(the parent's own fixed size or finite maximum, the default) or `.ancestors`
(the nearest bounded ancestor's, looking through parents that fit or grow
without a bound, less the paddings on the way, stopping at a container that
scrolls along the axis). That measurement is what the content asks for;
once widths are settled, content that got less (a sibling took some of the
row) or more than its limit is measured again at its final width, and the
heights follow. Content that wraps asks for `.ancestors`, so that it asks
for no more than it can get and a container that fits it stays within its
ancestor: text does by default, and so does a native label. Content that
fills its limit, such as a picture scaled to fit, keeps `.parent`, since it
would fill the ancestor otherwise.

### Text

`layout.text.Content(TextContext)` makes a text content type from a context
that measures strings:

```zig
pub fn measureText(self: @This(), text: []const u8, style: Style) !Vec2
```

A text is `.init(string, style)` or `.initContext(string, style, context)`;
its `content` field is what is appended. It wraps its string into lines under
`max_width` as its `Style` says, measures each with the context, and reports
the widest and the summed height. Renderers provide their `Text` (Core Text
for Quartz, Pango for Cairo, the font engine's for z2d and ThorVG), and
`text.HeuristicContent` measures by Latin-character heuristics for tests.
`text.CachedContext(Inner)` caches measurements by string and the style
fields that affect size, with 1024 entries by default. Set
`context.state.max_entries` to change the bound; reaching it clears the
cache before the next insertion. `clear()` invalidates measurements.

Text content borrows its string and context; `init` needs a context with a
`default`, otherwise use `initContext`. Its `deinit()` does not free the
string or deinitialize the shared context. Word wrapping splits at ASCII
spaces and line breaks; character wrapping currently splits by bytes and
can cut multibyte UTF-8. Use word wrapping for such text.

`text.Style`:

| Field | Default | Meaning |
|---|---|---|
| `font_family` | null (the renderer's default) | A family name. |
| `font_weight` | `.regular` | `ultralight` to `black`. |
| `font_size` | 16 | Points. |
| `line_height` | 1.2 | A multiple of the size. |
| `letter_spacing` | 0 | |
| `wrap_mode` | `.words` | `.words`, `.characters`, `.none`. |
| `overflow` | `.visible` | `.ellipsis_end` cuts a line that is still too wide (`A very long na…`); `.ellipsis_middle` keeps both ends (`raspios-bo…lite.img.xz`). Either lets containers shrink the text to the ellipsis. |
| `alignment` | `.left` | `.left`, `.center`, `.right`, within the box. |
| `color` | black | |

`style.with(.{ .color = .white, .wrap_mode = .none })` copies a style with
fields replaced (an optional field is set with `.{ .set = v }` or cleared
with `.clear`). Texts expose `lines(width)` and `linesWithSizes(width)`
iterators for renderers, and `asTextContent(*Content)` to recognise a
content as this text type, which `app.testing` uses to find text. Cut lines
borrow the iterator's buffer until its next `next()` call and keep at most
256 bytes, including the ellipsis.

## Floating

A floating unit is taken out of its parent's flow: it doesn't affect the
size or position of its parent or siblings. It is sized against the unit it
attaches to (`grow` fills it, `percent` is a fraction of it) and positioned
so that its `unit_point` lies on the target's `parent_point`, moved by
`offset`:

```zig
.floating = .{
    .mode = .parent,              // .parent, .root, .unit_id (parent = .{ .id = ... }), .unit_index
    .parent_point = .right_top,   // an AttachPoint
    .unit_point = .right_top,
    .offset = .init(-8, 8),
},
```

Floating units are painted and hit-tested in tree order like any other, so
to layer one over everything, declare it last. `z_index` is passed through
on render commands but doesn't reorder them; `expand`, `pointer_passthrough`
and `clip_to_parent` are not implemented yet.

## Clipping and scrolling

`clip` cuts the children to the box per axis (`horizontal`, `vertical`) and
moves them by `child_offset`, which is how a scroll container shows an
offset into its content. A container that clips an axis may have children
larger than itself that way; `scrolls_horizontal` and `scrolls_vertical`
say the content is meant to be larger, so content measured under its
ancestors' width takes no limit from beyond the container along that axis.
After layout, a container's `content_size` is the extent of its children in
the flow, padding included, which a scroll container compares with its box.

`fabrum.app` sets all of this from `Ui.Container.scroll`; with `layout`
alone, the caller keeps the offset.

## Units after layout

A `Unit` has `id`, `parent` (an index), `data` (`.container` or
`.content`), `children` (indices), and the computed `size`, `min_size`,
`bbox` (a `Rect`, from the top left of the root) and `content_size`.
`unit.hovered(point)` says whether a point is inside it, respecting rounded
corners.

IDs are 64-bit (`Unit.Id`): `.fromString(s)` hashes a string,
`.fromInt(n)` takes a number, and `.none` is no ID. `fabrum.app` hashes its
element keys into them.

## Render commands

`renderCommands()` iterates `RenderCommand`s in paint order, depth first:
for each container, a `scissor_start` if it clips, its background
`rectangle`, its content, its children, its `between_children` dividers,
its `border`, and a `scissor_end`. Each command has a `bbox`, the
`unit_id` it came from, a `z_index` and `data`:

| `data` | Fields |
|---|---|
| `rectangle` | `color`, `corner_radius` |
| `border` | `color`, `widths`, `corner_radius` |
| `content` | `*Content`, which the renderer casts to what it knows (`Text.asTextContent`, its own picture type) |
| `scissor_start` | `horizontal`, `vertical`: which axes the box clips |
| `scissor_end` | |

## Damage

`layout.Damage` reports the regions of the viewport whose pixels may differ
between one frame's commands and a later frame's, so a host redraws, sends
or refreshes only those. Each frame's commands are summarised as entries (a
hash of what each draws and the pixels it can touch, its box cut by the
clips in force and grown by `margin`); the two frames' entries are matched
(common ends, then unique hashes in increasing order), and everything
unmatched adds its pixels to the damage, merged into at most `max_regions`.
It is per command, not per pixel: a hover that changes a button's fill
damages the whole button; a reordering of many commands damages all of
them. Content without a fingerprint is always redrawn. `fabrum.app` keeps
one and exposes it as `Runtime.damage()`.

## Surfaces and drawing

A renderer draws commands into a `Surface`:

- `.pixels`: a `Surface.Pixels` buffer (`data`, `width`, `height`,
  `stride`, `format`, `scale`), made with `.packed_(data, w, h, format)`
  or `.packedScaled(..., scale)`. `PixelFormat` is `rgba8_premultiplied`,
  `bgra8_premultiplied` (color premultiplied by alpha, so an overlay
  composites as `out = overlay + under * (1 - alpha)`, a cleared pixel
  transparent) or `gray8` (opaque gray, cleared to white, for e-ink).
- `.cg_context`: a Core Graphics context in fabrum's coordinates.
- `.cairo`: a `cairo_t`.

`layout.draw(&renderer, commands, kind, target, damage)` draws through a
renderer, checking at compile time that it accepts the kind of surface:

```zig
try fabrum.layout.draw(&renderer, commands, .pixels, .packed_(buffer, 800, 600, .rgba8_premultiplied), damage);
```

With `damage`, only those regions are redrawn (cleared, then every command
that touches them drawn clipped to them); null redraws everything. The
renderer interface is in [renderers.md](renderers.md). `layout.TestRenderer`
fills rectangle and border boxes into pixels, for tests.

## Shared types

`fabrum.Vec2` (`x`, `y`, `init`, `add`, `sub`, `Axis`), `fabrum.Rect`
(`x`, `y`, `w`, `h`, `init`, `contains`), `fabrum.Range` (`min`, `max`),
`fabrum.Color` (`r`, `g`, `b`, `a`; `.rgb`, `.rgba`, `.gray`, `.black`,
`.white`, `.transparent`, `withAlpha`). Coordinates are points from the top
left, y down; renderers scale to device pixels.
