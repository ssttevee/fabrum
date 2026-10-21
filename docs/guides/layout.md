# Arrange content and overlays

Build a layout from the space available, then decide which children need
fixed space and which should share the remainder. Coordinates are points,
from the top left, with y down. The renderer applies device scale.
The [layout reference](../layout.md) lists every sizing shorthand and
container field; these recipes show how to combine them.

## Build a sidebar and a wrapping body

Start with a column. Give its header a fixed height and its body the
remaining height; inside the body, put a fixed sidebar beside a growing
article:

```zig
const Page = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open("page", .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 8 } });
        defer ui.close();
        try ui.open("header", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(36) }, .child_alignment = .center_left } });
        try ui.text("Gallery", .{});
        ui.spacer();
        try ui.text("Settings", .{});
        ui.close();
        try ui.open("body", .{ .layout = .{ .sizing = .grow(.{}), .child_gap = 10 } });
        defer ui.close();
        try ui.open("sidebar", .{ .layout = .{ .sizing = .{ .width = .fixed(80), .height = .grow(.{}) } } });
        try ui.text("Albums", .{});
        ui.close();
        try ui.open("article", .{ .layout = .{ .sizing = .{ .width = .grow(.{ .min = 40, .max = 400 }), .height = .fit(.{}) }, .padding = .xy(8, 4) } });
        defer ui.close();
        try ui.text("A description wraps into the width left beside the sidebar.", .{ .wrap_mode = .words });
    }
};
```

The default axis is `.x`, a row; `.y` makes a column. `padding` belongs to
the inside of a container, and `child_gap` separates its in-flow children.
Here `padding = .xy(8, 4)` means horizontal 8 and vertical 4.
`child_alignment = .center_left` centers the header's children vertically
while leaving them at the left. `ui.spacer()` shares free space along the
current axis and pushes the settings label to the other end. A spacer
also shares that space with any growing siblings.

The article's `.grow(.{ .min = 40, .max = 400 })` takes available width but
stops at 400. The maximum leaves empty space in a wide window; use the
body's `child_alignment` to position the group in that space. A minimum
is a real constraint: if fixed widths, minimums, padding and gaps exceed
the viewport, content can still overflow. Growing space cannot repair
incompatible minimums.

## Choose fixed, fit, grow or percent

Use `.fixed(points)` for an icon, toolbar height or target whose physical
size is part of the design. Use `.fit(.{})` for a label or compact group
that should ask for its content's size. Use `.grow(.{})` for a panel that
should absorb the remaining room. Along the layout axis, growing siblings
share the free space equally, subject to their ranges; across the axis, a
growing child fills the parent. Width and height are independent: the
header grows only in width, while the body grows in both.

Use `.percent(fraction)` when a child's size should be tied to its parent's
inner size, such as a preview occupying three quarters of a panel. Fractions
are 0 to 1; `.percent(75)` asserts. Percentages do not mean a share of the
space remaining after fixed siblings. Two 50% children plus a gap ask for
more than the parent's width. Use two growing children when you want an
equal split that also leaves room for the gap.

`fit` and `grow` accept `min` and `max` ranges. Set them per dimension,
as in the article, when only one axis should be bounded. Alignment places
children in unused space; it does not create space or turn a fitting
container into a growing one. A common symptom of a missing grow is a
centered child remaining at the upper left because its parent fits it
exactly.

## Wrap text beside siblings

Widths are resolved before heights. Text first measures under a bounded
ancestor, then remeasures at the width left after its siblings and gaps.
You do not need to calculate `viewport - sidebar - gap` in your view.
`ui.text` uses `Content.limit = .ancestors` so a chain of fitting wrappers
still finds the available width.

Keep wrapping text in a parent that can obtain a finite width, as the
article above does. `.words` wraps at ASCII spaces and line breaks. Use
`.none` with `.ellipsis_end` for a single-line label, or
`.ellipsis_middle` when both ends of a filename matter. An ellipsis makes
text squeezable down to the ellipsis width. A long unbroken word can exceed
the available width with ordinary word wrapping; choose ellipsis or
clipping if that is the desired behavior. `.characters` is currently
byte-based and can split multibyte UTF-8; use word wrapping for such text.

This is wrapping of text lines, not a wrapping row layout. To build a grid,
declare rows yourself or choose rows in your view from the available size;
there is no automatic flex-wrap container.

## Scroll a long list

Give the viewport a bounded size and let its content extend vertically:

```zig
const List = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { end };
    pub const Props = struct {};
    pub fn update(_: *State, _: Msg, ctx: *app.Update(List)) void {
        ctx.scrollTo("rows", .end, .{});
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.open("rows", .{ .layout = .{ .sizing = .fixedXY(200, 80), .axis = .y }, .scroll = .{} });
        defer ui.close();
        for (0..10) |i| {
            try ui.open(i, .{ .layout = .{ .sizing = .fixedXY(180, 24) } });
            try ui.print(.{}, "Row {d}", .{i});
            ui.close();
        }
    }
};
```

`scroll = .{}` enables y scrolling and an overlay scrollbar. It clips the
content, persists offset by key, handles wheel input and thumb dragging,
and pans after a touch press passes the drag threshold. Nested scroll
containers consume what they can and pass remaining wheel motion upward.
The `end` message shows programmatic movement. `ctx.scrollTo` also accepts
`.start`, `.{ .offset = position }` and `.{ .by = delta }`;
`ctx.scrollIntoView(ctx.element(key))` reveals an element through its
containing scroll views. Focus movement reveals focused descendants.

Use `ui.scrollInfo(key)` to inspect offset, viewport and content after a
frame; it is null before the first layout. Programmatic movement clamps
against the last frame's content. For a gesture implemented by your app,
pass `.{ .refresh = .interactive }` so an e-ink host can choose a fast
refresh. Keep the scroll key stable to keep its position.

Use `widgets.scrollView` instead when you want the native scroll container
on toolkit builds; the [settings form](widgets-and-input.md#build-a-controlled-settings-form)
shows its `content` layout and matching `ui.close()`. Native controls inside
it belong to that native container. The drawn version uses the runtime
scroll machinery. Neither version virtualizes a long list: every declared
row consumes layout capacity and work. Increase `context.units`, `depth`
and `breadth` as needed; `max_breadth` is a hard bound of 256.

## Attach an overlay and preserve an aspect ratio

Declare an overlay after the content it should cover:

```zig
const Overlay = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open("preview", .{
            .layout = .{ .sizing = .fixedXY(200, 140) },
            .aspect_ratio = .{ .aspect_ratio = 2 },
            .clip = .{ .horizontal = true, .vertical = true },
            .background_color = .gray(230),
        });
        defer ui.close();
        try ui.open("badge", .{
            .layout = .{ .sizing = .fixedXY(40, 20) },
            .floating = .{ .mode = .unit_id, .parent = .{ .id = ui.id("preview").id }, .parent_point = .right_top, .unit_point = .right_top, .offset = .init(-4, 4) },
            .background_color = .black,
        });
        defer ui.close();
        try ui.text("New", .{ .color = .white });
    }
};
```

`aspect_ratio` is width divided by height; it shrinks one dimension to
preserve that ratio. It does not crop a picture by itself. The badge is
outside normal flow, so it does not make the preview larger or displace
other children. Its top-right attach point meets the preview's top-right
point, then moves four points inward and down.

Use `.parent` for the immediate layout parent, `.root` for the viewport,
`.unit_id` with `ui.id(key).id` for another element, or `.unit_index` with
a layout index. Indices are frame-local; stable IDs are usually clearer.
A missing attachment target gives `error.FloatingTargetNotFound` during
layout. Attach points have nine combinations; the aliases `center_left`
and `center_right` mean the middle of the left and right edges.

Paint and hit order remain declaration order. `z_index` travels with
commands but does not reorder them. The floating fields `expand`,
`pointer_passthrough` and `clip_to_parent` are reserved and do not work yet.
A backdrop with `modal = true` restricts focus to the last modal subtree;
place a full-viewport keyed backdrop with an action if it should intercept
outside clicks. Merely making an element float does not make it modal.

## Clip content deliberately

Set `clip.horizontal` and/or `clip.vertical` to cut overflow at the box.
`child_offset` shifts children without changing the viewport. Runtime
scroll containers set these for you; with raw layout, keep the offset in
your own state. Set the matching `scrolls_*` flags when that axis is meant
to grow beyond the viewport, so wrapping measurement does not inherit a
limit from outside it along that axis.

Clipping is separate from rounded-corner hit testing. The app runtime
filters hits through ancestor clips. Raw `hoveredUnits` only tests units'
own shapes. Quartz currently clips both axes even for a one-axis scissor;
Cairo honors the requested axes. `ContainerDeclaration.overflow` is
reserved and has no effect; use `clip`.

## Use layout without the application runtime

You can use the same sizing rules in a diagram, image generator or custom
host without components, messages or native widgets:

```zig
test "guide raw layout percentage widths and manual clipping" {
    const gpa = std.testing.allocator;
    var context: layout.Context = try .init(gpa, .{ .units = 32 });
    defer context.deinit(gpa);
    var text: layout.text.HeuristicContent = .init("Text beside a fixed icon wraps at its final width.", .{});
    context.begin(.{ .sizing = .fixedXY(240, 120), .axis = .y });
    const row = try context.openContainerId(.fromString("row"), .{
        .layout = .{ .sizing = .{ .width = .percent(0.75), .height = .fixed(60) }, .child_gap = 8 },
        .clip = .{ .horizontal = true, .vertical = true, .child_offset = .init(0, -4) },
    });
    const icon = try context.openContainer(.{ .layout = .{ .sizing = .fixed(24) }, .background_color = .black });
    context.closeContainer(icon);
    try context.appendContent(&text.content);
    context.closeContainer(row);
    context.end();
    try context.computeLayout();
    try std.testing.expectEqual(180, context.getUnitByStringId("row").?.bbox.w);
    var commands = context.renderCommands();
    var count: usize = 0;
    while (commands.next()) |_| count += 1;
    try std.testing.expect(count >= 4);
}
```

Initialize a `layout.Context` once, declare between `begin` and `end`, then
call `computeLayout`. The root must have fixed width and height. The context
borrows the `Text` object, which borrows its string. Keep both alive until
you finish drawing. A production renderer supplies a text type that uses
its actual fonts; `HeuristicContent` is for tests and rough measurements.

Read units by ID after layout. Consume `renderCommands()` before starting
another iterator, because it borrows one scratch stack; do not call its
`deinit`. On `error.LayoutCapacity`, the current declaration is unusable;
start the next attempt with `begin` and larger capacity. The complete
[layout-only example](../../examples/layout_only.zig) also prints boxes.
Continue with [custom content](custom-content.md) when measurement needs a
callback, or [hosting](hosting.md) when this layout is interactive.
