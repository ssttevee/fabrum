# Usage guides

Start with a working component, then follow the guide for the task you have.
These guides explain choices, lifetimes and failure modes. The
[app](../app.md), [layout](../layout.md), [platform](../platforms.md) and
[renderer](../renderers.md) references hold the complete option lists.

## Choose a guide

- [First app](first-app.md): for a new project; dependency wiring, a window,
  a component and its first test.
- [Components](components.md): for splitting a screen into state owners,
  keyed children, handlers and shared contexts.
- [Layout recipes](layout.md): for arranging rows, columns, wrapping text,
  scrolling content and overlays, with or without the app runtime.
- [Widgets and input](widgets-and-input.md): for forms and custom controls;
  every common widget, pointer capture, focus, keys and text editing.
- [Host services](services.md): for dialogs, menus, choosers, the clipboard
  and confirming close requests across hosts.
- [Concurrency](concurrency.md): for background work with cancellation,
  screen-scoped tasks, safe result ownership and progress.
- [Timers and animation](timers-and-animation.md): for timed state changes,
  elapsed-time animation and efficient frame scheduling.
- [Testing](testing.md): for deterministic interaction, host-service,
  task and virtual-time tests without a window.
- [Custom content](custom-content.md): for measured content, pictures,
  renderer extensions and reliable damage tracking.
- [Hosting](hosting.md): for owning the event loop, input and framebuffer
  on `none`.
- [Writing a renderer](writing-a-renderer.md): for implementing the drawing
  contract, matching text measurement and testing partial redraws.
- [Writing a platform](writing-a-platform.md): for packaging a `none` host,
  toolkit services and optional native controls.

## Suggested reading order

For an application, read first app, components, layout, widgets and input,
then testing. Add services, concurrency and timers when the screen needs
them. Custom content is useful when ordinary boxes and text no longer
express your display. A host author should then read hosting, followed by
the renderer or platform guide for the part being implemented.

The twelve guides are separate because each follows a different workflow:
components own state, layout allocates space, input turns gestures into
messages, services cross the host boundary, and hosting and package writing
have different lifetimes from a screen. Related guides link at that boundary.

## Read and run the examples

Zig blocks are exact excerpts from
[guide_snippets.zig](../../test/compile/guide_snippets.zig) or the
[first-app build fixture](../../test/compile/guide_project/build.zig).
Unless a block is a complete file, it uses these file-scope imports:
`std = @import("std")`, `fabrum = @import("fabrum")`, `app = fabrum.app`,
`layout = fabrum.layout`, `widgets = app.widgets`, `Rect = fabrum.Rect`
and `Vec2 = fabrum.Vec2`, each declared with `const`. Names shared between
blocks are linked where introduced. Test blocks use `std.testing` and are
intended for `zig build test`, rather than the executable's `main`.

The repository's `zig build test` compiles and runs these examples with the
selected platform. Native widgets use a fake backend, so GTK tests need
its development libraries but no display server. Window entry points are
compiled only on AppKit and GTK and are never run by tests. The consumer
fixture builds the same counter as a separate package. A synchronization
test checks the quoted Zig blocks against their sources.

For complete runnable programs, use the
[repository examples](../examples.md); for larger forms and external
rendering, read the fabrum-kitchen package.
