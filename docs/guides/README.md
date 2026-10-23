# Usage guides

Each guide walks through one task, explains the choices along the way, and
points out the mistakes that are easy to make. They don't try to list every
option. When you need one, the reference pages have the complete lists:
[app runtime](../app.md), [layout](../layout.md),
[platforms](../platforms.md) and [renderers](../renderers.md).

## Where to start

If you're new to fabrum, read these in order:

1. **[Build your first app](first-app.md).** Set up a project, open a
   window, write a component and its first test.
2. **[Components](components.md).** Split a screen into parts that each own
   their own state, and pass data and handlers between them.
3. **[Layout recipes](layout.md).** Rows, columns, wrapping text, scrolling
   lists and overlays.
4. **[Widgets and input](widgets-and-input.md).** Every built-in widget,
   plus building your own controls: pointer dragging, focus, keyboard
   shortcuts and text editing.
5. **[Testing](testing.md).** Click, type and check the screen in tests that
   run without a window.

## When your app needs more

- **[Multiple windows](multiple-windows.md).** Open independent views, share
  documents, track window lifetimes, and coordinate close and quit.
- **[Overlay windows](overlay-windows.md).** Build a transparent desktop badge,
  choose activation and pointer behavior, and handle platform restrictions.

- **[Host services](services.md).** Alerts, menus, file choosers, the
  clipboard, and asking "save changes?" before a window closes.
- **[Concurrency](concurrency.md).** Running slow work, like network
  requests or file loading, off the UI thread. Covers cancelling it,
  reporting progress, and who owns the results.
- **[Timers and animation](timers-and-animation.md).** Changing state after
  a delay, animating over time, and only redrawing when something moves.
- **[Custom content](custom-content.md).** Drawing things that aren't boxes
  and text, like pictures and charts, and making sure fabrum redraws them
  when they change.

## If you're porting fabrum somewhere new

These are for running fabrum where it doesn't run yet, such as a new device
or a new graphics library.

- **[Hosting](hosting.md).** Running fabrum on the `none` platform, where
  your program owns the event loop, the input and the pixels.
- **[Writing a renderer](writing-a-renderer.md).** Turning fabrum's drawing
  commands into pixels, measuring text consistently, and testing that
  partial redraws match full ones.
- **[Writing a platform](writing-a-platform.md).** Packaging a host as a
  reusable library, with optional native dialogs and controls.

## About the code in these guides

Every Zig block in the guides is copied from code that is compiled and
tested. The blocks come from
[guide_snippets.zig](../../test/compile/guide_snippets.zig) and the
[first-app project](../../test/compile/guide_project/build.zig). A test
fails if a guide and its source drift apart, so the code you read is code
that works.

Short snippets leave out the imports at the top of the file. Unless a block
is a complete file, assume it starts with:

```zig
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const widgets = app.widgets;
const Rect = fabrum.Rect;
const Vec2 = fabrum.Vec2;
```

Blocks that start with `test` are meant to go in a test file and run with
`zig build test`, not in your program's `main`.

Running `zig build test` in the fabrum repository runs all of these
examples. The tests replace native widgets with fakes, so they need no
display. On Linux they still need GTK's development files installed.

For complete programs you can run, see the
[repository examples](../examples.md). For a larger app with forms and
custom drawing, see
[fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen).
