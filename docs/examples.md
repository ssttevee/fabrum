# Examples and real apps

## In this repository

`examples/` holds small complete programs. `zig build examples` builds them
into `zig-out/bin`, `zig build run-<name>` runs one, and `zig build test`
runs their tests on every platform, so they can't rot.

| Example | Platforms | What it shows |
|---|---|---|
| [`counter.zig`](../examples/counter.zig) (`run-counter`) | `native`, `gtk` | A stateful component with native push buttons from `app.widgets` around drawn text; `appkit.App` and `gtk.App` chosen by `app.platform.kind`; tests with `app.testing.Harness` driving the native widgets in the fake tree, and the same component with drawn widgets. |
| [`tasks.zig`](../examples/tasks.zig) (`run-tasks`) | any | Commands, keyed cancellation, declared tasks, arena-backed borrowed results and deterministic harness completion. |
| [`headless.zig`](../examples/headless.zig) (`run-headless`) | any | The `none` host contract: a program that owns the clock, feeds pointer input to `Runtime.mouse`, runs frames when `nextFrame` says, and takes `commands`, `damage` and `refresh` out; it prints them instead of drawing. Drawn widgets, `Capabilities` for a touch screen, a test that checks the damage and the idle state. |
| [`layout_only.zig`](../examples/layout_only.zig) (`run-layout-only`) | any | `fabrum.layout` without `fabrum.app`: a `Context`, fixed and growing sizing in a column, alignment, a text that wraps at the width a growing panel gives it, boxes read back by ID, and the render commands. |

The repository's own tests are examples too: `src/app/hybrid_test.zig` is a
form of native controls, drawn chips, a menu item, an alert and a drawn modal
dialog, driven through the harness; `src/app/host_test.zig` drives the
runtime as a `none` host, checking which input it takes and which it lets
through; `src/app/input_test.zig` covers focus, keys, shortcuts, scrolling
and text fields.

## The Kitchen

[fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen) is a port of
Gio's Kitchen demo: one screen with every widget. It has two versions of the
screen, `kitchen.Hybrid` (the platform's controls laid out by fabrum, with
drawn content between and over them) and `kitchen.Kitchen` (everything
drawn), and three programs:

- `kitchen` (`src/main.zig`): the hybrid screen in an AppKit window, with
  `--drawn` for the drawn one. Debug builds take a script in
  `KITCHEN_SCRIPT` that clicks, types, slides, tabs, opens menus, answers
  dialogs and takes snapshots in process, through `appkit.automation`.
- `kitchen-gtk` (`src/main_gtk.zig`): the hybrid screen on GTK 4, with the
  same script.
- `kitchen-none` (`src/none.zig`): the Kitchen hosted by its own code on the
  `none` platform, drawn by z2d or ThorVG (`-Drenderer`), in two modes: an
  RGBA overlay over a background image, where clicks between widgets pass
  through, and an opaque `gray8` e-ink panel with an e-reader's capabilities
  and services. It plays a script of input, redraws only the damage,
  checks every step against a full redraw, writes PNGs and times the
  renderer. It cross-compiles, as it links no UI library.

Its `build.zig` shows how an app passes `-Dplatform` on to fabrum, and how
`kitchen-none` gives the renderer package the app's fabrum
(`renderer_mod.addImport("fabrum", fabrum_none)`).

## OpenEtcher

[open-etcher](https://github.com/ssttevee/open-etcher) is a disk-image
flasher in Zig. Its macOS GUI (`zig build gui`) is a fabrum app on the AppKit
platform: the window, the image chooser (`NSOpenPanel`), the question before
quitting mid-flash (`NSAlert`) and the Quartz canvas are the platform's; the
interface keeps balena Etcher's own look, drawn. Everything is in
`src/app/`:

| File | What it does |
|---|---|
| `main.zig` | `appkit.App(ui.App)`: makes the window, provides the services and the icons to the runtime as root values, and runs. In debug builds it also runs `OPENETCHER_GUI_SCRIPT`, a list of steps (`image=`, `click=`, `answer=`, `snapshot=`, `quit`, ...) performed in process through `appkit.automation` and the app's own `mouse`, and writes the layout of every text to `OPENETCHER_GUI_LAYOUT_FILE` ten times a second, so tests driving the window with real input know where to click. |
| `ui.zig` | The interface's module root, and its tests: `app.testing.Harness` over `App` with fake services and icons, clicking as a user would and answering the file chooser and the dialogs through the harness's fake services. |
| `ui/App.zig` | The root component: the model of the image, the target and the flash, and the screen built from it. It asks the platform for the image with `ctx.openFile`, holds the window's close button and quitting while a flash runs with `ui.guardClose` and asks with `ctx.confirm`, starts image loading with `ctx.runKey`, declares drive listing with `ui.task`, and gets results back as messages. |
| `ui/model.zig` | Plain data: images, drives, progress, outcomes, and the `Services` and `Icons` interfaces the interface asks for, so `update` is testable without a disk. |
| `ui/steps.zig` | The three steps across the main screen (image, target, flash), stateless components whose buttons fire the actions the app passes. |
| `ui/DriveSelector.zig` | The target dialog, a child component with its own state (the row picked but not confirmed, whether system drives are shown). |
| `ui/ConfirmDialog.zig`, `ui/Finish.zig` | The confirmation before writing, and the finished screen. |
| `ui/theme.zig` | Etcher's colors and type, and view helpers for its buttons, links, badges and icons. |
| `ui/format.zig` | Sizes, speeds and durations as values with a `format` method, printed with `{f}`. |
| `tasks.zig` | Runtime task functions for image loading with progress and screen-scoped drive listing; an image-source cache shared with flashing. |
| `services.zig` | Flashing through `model.Services`, with its own group and cancellation lifecycle; progress and outcomes come back through an `app.Poster`. |
| `progress.zig` | Reads the library's `std.Progress` tree from a pipe inside the process, for the progress bar. |
| `icons.zig` | Etcher's SVG icons as Quartz picture content. |

It is the best real-world example of the API: root values for services, a
stateful root with stateless step components and stateful dialogs, platform
services from `update`, background work posting messages, and a test suite
that never opens a window.

## An external platform

[fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview)
hosts the runtime on PocketBook e-readers. Its `src/example/ReaderShell.zig`
is a reader's first screen (a list, a search field that opens the system
keyboard, a menu, a settings page), with its `main.zig` calling
`inkview.run(ReaderShell, ...)`. Its `host.zig` is a complete `none` host
driven by a toolkit's event loop; see [platforms.md](platforms.md).
