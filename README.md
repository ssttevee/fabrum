# fabrum

fabrum is a UI framework for Zig. It is an immediate-mode layout engine with
an Elm-style application runtime on top, and it works *with* the platform's
own toolkit rather than instead of it: fabrum owns the application state, the
layout and the widget tree; AppKit or GTK owns the window, the event loop, the
menus, the dialogs and the standard controls, which sit in fabrum's layout as
ordinary elements. Where there is no toolkit (an e-reader, an overlay drawn
into a game, a VNC proxy, a headless test), fabrum draws every widget itself
and your program is the host.

```zig
pub const Counter = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { add: i32, reset };
    pub const Props = struct { step: i32 = 1 };

    pub fn update(state: *State, msg: Msg, _: *app.Update(Counter)) void {
        switch (msg) {
            .add => |amount| state.count += amount,
            .reset => state.count = 0,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Counter);
        const theme = ui.use(app.native.Theme);

        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(16), .child_gap = 12, .child_alignment = .center } });
        defer ui.close();

        try ui.print(.{ .font_size = theme.font_size * 2, .color = theme.text }, "{d}", .{state.count});

        try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        try widgets.button(ui, "minus", .{ .label = "\u{2212}", .on_click = on.bind(.{ .add = -props.step }) });
        try widgets.button(ui, "plus", .{ .label = "+", .on_click = on.bind(.{ .add = props.step }) });
        try widgets.button(ui, "reset", .{ .label = "Reset", .on_click = on.bind(.reset), .enabled = state.count != 0 });
    }
};
```

That is [`examples/counter.zig`](examples/counter.zig), whole but for its
`main` and tests. The buttons are the platform's own (`NSButton`,
`GtkButton`); the number is text fabrum draws on the platform's canvas; the
same file, with drawn buttons, runs where there is no toolkit.

## Goals

- **Immediate mode.** A view describes the whole screen every frame from
  the state; fabrum lays it out from scratch and reconciles the native
  controls, so there is no widget tree to keep in sync. Layout is Clay-style:
  nested containers with `fit`, `grow`, `percent` and `fixed` sizing along
  an axis, padding, gaps, alignment, floating, clipping and borders.
- **An Elm-architecture runtime.** Components are plain types with a
  `State`, a `Msg` and `update`; views never change state. Handlers are
  values that can be stored, passed to children and posted to from other
  threads. Nothing is ever a callback into a widget.
- **Hybrid native layering.** fabrum owns state, layout and the tree; the
  toolkit owns the window, the event loop, menus, dialogs, the clipboard and
  the standard controls. Drawn content and native views are stacked in paint
  order, so a drawn dialog can cover a native text field. Apps that want the
  same pixels everywhere can draw every widget instead.
- **A portable `none` platform.** The runtime takes input in and hands
  render commands, damage regions and refresh hints out; the host owns the
  loop, the clock and the pixels. This is what e-ink readers, overlays and
  headless tests use, and it links nothing.
- **Zig-first.** Comptime where it pays: component shapes are checked at
  compile time with an error that says what is missing, message payloads are
  carried inline, a renderer used with a surface it doesn't draw into is a
  compile error, and a platform that isn't implemented fails the build
  rather than the run.

## Status

Early. The APIs move, and only three platforms exist: **AppKit** on macOS,
**GTK 4** on Linux (and anywhere GTK is), and **`none`**. The `qt`, `sdl`,
`win32` and `web` platforms are named in the build option but fail
compilation with a message saying so. Text editing has no bidirectional
text or IME pre-edit display yet; the Cairo renderer draws no pictures yet.

## Requirements

- Zig **0.17.0**.
- `native` on macOS: the Xcode command line tools (AppKit, Core Graphics,
  Core Text and UniformTypeIdentifiers are linked).
- `gtk`, and `native` on Linux: GTK 4 and its development files, found with
  `pkg-config`. On macOS with Homebrew's GTK, put Homebrew's `pkgconf` first
  on `PATH`: `PATH=/opt/homebrew/bin:$PATH zig build -Dplatform=gtk`.
- `none`: nothing. It builds for any target Zig does.

fabrum has one package dependency, [zg](https://codeberg.org/atman/zg), for
grapheme and word segmentation in text editing; Zig fetches it.

## Installation

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum
```

Then in `build.zig`:

```zig
// fabrum, built for the platform the app wants: `native` is AppKit on
// macOS and GTK 4 on Linux; `gtk` is GTK 4 anywhere; `none` hosts
// the runtime yourself with drawn widgets
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .native });

const exe = b.addExecutable(.{
    .name = "hello",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fabrum", .module = fabrum.module("fabrum") }},
    }),
});
```

`.platform` is optional and defaults to `native`. If another package in the
program also depends on fabrum (a renderer, a platform package), give it the
same module with `addImport("fabrum", ...)` rather than letting it ask for
its own, or two fabrums end up in one program; see
[docs/renderers.md](docs/renderers.md).

### Build options

| Option | Values | Meaning |
|---|---|---|
| `platform` | `native` (default), `gtk`, `qt`, `sdl`, `none` | What hosts `fabrum.app`. `native` resolves by target OS: AppKit on macOS, GTK 4 on Linux, Win32 on Windows (not implemented), the DOM on wasm (not implemented). |
| `quartz` | `bool`, default `false` | Include `fabrum.render.Quartz` with any platform on macOS, to draw into a `CGContext` without a window. The AppKit platform always has it. |
| `cairo` | `bool`, default `false` | Include `fabrum.render.Cairo` with any platform, to draw into a `cairo_t`; links Cairo and Pango through pkg-config. The GTK platform always has it. |

What each platform links: AppKit (macOS) links AppKit, Core Graphics, Core
Text, Core Foundation and UniformTypeIdentifiers; GTK links `gtk4` through
pkg-config (which brings Cairo and Pango); `none` links nothing.

## The module

```zig
const fabrum = @import("fabrum");
```

| Namespace | What it is |
|---|---|
| `fabrum.layout` | The layout engine on its own: a `Context` that is declared into every frame, sizing (widths first, so text wraps at the width it gets), alignment, padding, text styles and wrapping, floating and clipping, `RenderCommand`s, `Damage`, `Surface` and `draw`. Knows nothing of state, input or platforms. [docs/layout.md](docs/layout.md) |
| `fabrum.app` | The runtime: components (`State`, `Msg`, `Props`, `update`, `view`), the `Ui` builder, handlers and messages, contexts, input, focus, scrolling, timers, `TextEditor` and `Keymap`, `Capabilities`, `Refresh` hints, and `Runtime` itself. [docs/app.md](docs/app.md) |
| `fabrum.app.widgets` | The common widget set: `button`, `checkbox`, `toggle`, `slider`, `textField`, `textArea`, `searchField`, `secureField`, `dropdown`, `radioGroup`, `stepper`, `label`, `progressBar`, `spinner`, `scrollView`. Native where the platform has them, drawn otherwise. |
| `fabrum.app.drawn` | The same set drawn by fabrum, for the `none` platform and as an opt-in elsewhere; plus `textEditor`. |
| `fabrum.app.menus`, `fabrum.app.dialogs` | The platform's menu bar items and alerts, declared from views. |
| `fabrum.app.native` | The contract between the runtime and a platform's controls: `Backend`, `Spec`, `Value`, `Event`, `Scene`, `Theme`. For platform packages. |
| `fabrum.app.platform` | `kind` (which platform this build is), `Services` (what a host does beyond its window), and the platform namespaces `appkit`, `gtk`, `none`. [docs/platforms.md](docs/platforms.md) |
| `fabrum.app.testing` | `Harness`: runs a component without a window or a renderer, clicks by text or key, types, answers dialogs and choosers, and checks what is shown. |
| `fabrum.render` | Renderers that come with fabrum: `Quartz` and `Cairo`. Portable ones are separate packages. [docs/renderers.md](docs/renderers.md) |
| `fabrum.Vec2`, `Rect`, `Range`, `Color` | Shared geometry and color. |

## Platforms

| `-Dplatform` | Resolves to | Window and controls | Canvas | Status |
|---|---|---|---|---|
| `native` on macOS | `appkit` | `NSWindow`, AppKit controls, `NSMenu`, `NSAlert`, `NSOpenPanel`, `NSPasteboard` | Quartz | Implemented |
| `native` on Linux, or `gtk` anywhere | `gtk` | `GtkWindow`, GTK 4 widgets, `GtkPopoverMenu`, `GtkAlertDialog`, `GtkFileDialog`, `GdkClipboard` | Cairo (Pango text) | Implemented |
| `none` | `none` | None: the program hosts the runtime; every widget is drawn | The host's renderer | Implemented |
| `native` on Windows | `win32` | | | Compile error |
| `native` on wasm | `web` | | | Compile error |
| `qt`, `sdl` | `qt`, `sdl` | | | Compile error |

`fabrum.layout` alone builds with any option, for any OS.

## Ecosystem

| Package | What it is |
|---|---|
| [fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d) | A pure-Zig renderer for `.pixels` surfaces (premultiplied RGBA/BGRA, or opaque `gray8` for e-ink), with z2d. For the `none` platform; builds for any target. |
| [fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg) | A renderer for `.pixels` surfaces with ThorVG's software engine; rectangles, borders, text, pictures and clipping. |
| [fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview) | PocketBook e-readers through libinkview: an external platform package that hosts the runtime on `none`, draws the damage into the panel's gray framebuffer with z2d, maps refresh hints to e-ink updates, and offers InkView's dialogs, menus and keyboard as services. |
| [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen) | The Kitchen sample, a port of Gio's Kitchen demo: every widget, on AppKit, GTK and `none` (as an overlay and as an e-ink panel). |
| [open-etcher](https://github.com/ssttevee/open-etcher) | OpenEtcher, a disk-image flasher. Its macOS GUI is a fabrum app on the AppKit platform, drawn in balena Etcher's look on the Quartz canvas, with the file chooser and the dialogs from the platform, tests through `app.testing`, and a script that drives the window. |

## Examples

In [`examples/`](examples/), built by `zig build examples` and tested by
`zig build test`:

- [`counter.zig`](examples/counter.zig): the counter above, in a window with
  native buttons (`zig build run-counter`, with `-Dplatform=native` or
  `gtk`).
- [`headless.zig`](examples/headless.zig): a program that hosts the runtime
  itself, as a `none` host does, and prints the render commands and the
  damage of each frame instead of drawing them (`zig build run-headless`,
  any platform).
- [`layout_only.zig`](examples/layout_only.zig): `fabrum.layout` without
  `fabrum.app` (`zig build run-layout-only`, any platform).

See [docs/examples.md](docs/examples.md) for these and the real apps.

## Documentation

- [Getting started](docs/getting-started.md): a first app end to end, on
  AppKit, GTK and `none`, and testing it with the harness.
- [The app runtime](docs/app.md): components, messages, the `Ui` API,
  contexts, widgets, input, focus, scrolling, text editing, dialogs and menus,
  capabilities, refresh hints, testing.
- [The layout engine](docs/layout.md): `fabrum.layout` on its own.
- [Platforms](docs/platforms.md): what each platform provides, the `none`
  host contract, writing an external platform package.
- [Renderers](docs/renderers.md): Quartz and Cairo, external renderers and
  how to inject them, writing a renderer.
- [Examples and real apps](docs/examples.md).
- [Hybrid design record](docs/hybrid-design.md): the design history of the
  hybrid layering, kept for the reasoning behind it.

## License

[MIT](LICENSE).
