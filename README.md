# fabrum

fabrum is a library for building user interfaces in [Zig](https://ziglang.org).
You write your screen once, as plain Zig. On a Mac it shows up with real macOS
buttons and text fields. On Linux it uses GTK's. On a device with no UI
toolkit at all, like an e-reader or a game overlay, fabrum draws every
button itself.

> **Status: early.** It works, and it has tests, but the API still changes.
> It runs on macOS (AppKit), on Linux and anywhere else GTK 4 runs, and with no
> toolkit at all. Windows and the web are not implemented yet.

## Why fabrum?

Most UI libraries take one of two approaches:

- **Use the operating system's toolkit** (AppKit on macOS, GTK on Linux,
  Win32 on Windows). Controls look and behave exactly as users expect, with
  accessibility, keyboard shortcuts and text input handled for you. The cost
  is that each toolkit has its own API, and you have to keep your app's data
  and the toolkit's widgets in sync by hand.
- **Draw everything yourself**, as games, Flutter and Dear ImGui do. You get
  one API and the same pixels everywhere, but none of the platform's own
  behaviour.

fabrum takes a middle path. **fabrum owns your app's data and decides where
everything goes on screen. The platform's toolkit owns the window and the
standard controls.** A native macOS button sits in a fabrum layout like any
other box. Where there is no toolkit, the same code falls back to buttons
that fabrum draws.

## A first look

Here is a complete counter: a number with −, + and Reset buttons.

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

This is [`examples/counter.zig`](examples/counter.zig) without its `main`
function and tests. Here is what each part does:

- **`State`** is the data the component remembers between frames: here,
  just the count.
- **`Msg`** lists everything that can happen to that data. It is a tagged
  union: either "add some amount" or "reset".
- **`update`** is the only place where `State` changes. It receives one
  message and applies it.
- **`view`** describes what the screen looks like for the current state.
  It is not allowed to change the state; its `state` parameter is `const`.
- **`Props`** are settings the parent passes in, like function arguments.
  Here `step` controls how much each button adds.
- **`ui.open` / `ui.close`** start and end a box. Boxes nest, and each one
  lays out its children in a row or a column (`.axis = .y` means a column).
  Zig's `defer` closes the box at the end of the scope, so opens and closes
  always pair up.
- **`on.bind(...)`** turns a message into a click handler. When the button
  is clicked, fabrum sends that message to `update`.
- **`"minus"`, `"plus"`, `"reset"`** are keys. They let fabrum tell, from
  one frame to the next, that this is the same button.

On macOS those buttons are real `NSButton`s; with GTK they are `GtkButton`s.
The number is text that fabrum draws itself. With no toolkit, fabrum draws
the buttons too, and the code doesn't change.

## Three ideas behind fabrum

### 1. You describe the screen; fabrum works out what changed

`view` runs again every time something might have changed, and describes
the *whole* screen from scratch. There are no widget objects to create,
update or delete. If `state.count != 0` becomes false, the Reset button
turns disabled because the next `view` says so.

This style is called **immediate mode**. If you've used React, it is the
same idea as a component's render function: the UI is a function of the
state. fabrum compares each frame's description with the previous one and
makes the matching changes to the real native controls.

### 2. State changes only through messages

A view never edits state directly. It attaches messages to events (a
click, a keypress, a timer), and fabrum delivers each message to `update`.
This is the **Elm architecture**, the same pattern as reducers in Redux.

The payoff is that every change to your data goes through one function. That
makes it easy to see why the screen looks the way it does, and easy to test:
send a message, then check the state.

### 3. Native controls where possible, drawn ones where not

```
                 your component (State, Msg, update, view)
                                    │
                         fabrum.app (the runtime)
            runs view, turns clicks and keys into messages,
                   calls update, schedules frames
                                    │
                     fabrum.layout (the layout engine)
                  decides the size and position of every box
                                    │
        ┌───────────────────────────┼────────────────────────────┐
     AppKit (macOS)           GTK 4 (Linux, …)          none (no toolkit)
  native controls, text    native controls, text      your program owns the
   drawn with Quartz        drawn with Cairo          loop and the pixels;
                                                       a renderer draws them
```

A **platform** is what hosts the app: it owns the window and the event
loop. A **renderer** is what turns fabrum's drawing commands into pixels.
The `none` platform is for places with no toolkit. There, your own program
(the **host**) feeds input into fabrum and gets drawing commands back. It is
also how fabrum runs in tests, so tests need no window.

### A few more things worth knowing

- **Native and drawn content stack in order.** A box fabrum draws can sit on
  top of a native control, so a drawn dialog can cover a native text field.
- **You can opt out of native controls.** An app that wants identical
  pixels on every platform can use fabrum's drawn widgets everywhere.
- **Handlers are plain values.** A click handler can be stored, passed down
  to a child component, or used from another thread to send a message
  back to the UI. Widgets never call into your code directly.
- **Mistakes show up at compile time where possible.** If a component is
  missing `update`, the compiler error says so. The same goes for using a
  renderer with a surface it can't draw into, or picking a platform that
  isn't implemented.

## Try it

You need **Zig 0.17.0**. To open a window, you also need:

- **macOS:** the Xcode command line tools (`xcode-select --install`).
- **Linux:** GTK 4 and its development package (for example
  `libgtk-4-dev` on Debian and Ubuntu, or `gtk4-devel` on Fedora), plus
  `pkg-config`.

The `none` platform needs nothing extra and builds for any target Zig
supports.

```sh
git clone https://github.com/ssttevee/fabrum
cd fabrum
zig build run-counter                    # the counter, in a window
zig build run-headless                   # no window: prints what each frame would draw
zig build test                           # every test; no window needed
```

To use GTK on a Mac (from Homebrew), add `-Dplatform=gtk` and put
Homebrew's tools first on your `PATH`:

```sh
PATH=/opt/homebrew/bin:$PATH zig build run-counter -Dplatform=gtk
```

## Add it to your project

Fetch fabrum. This adds it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum
```

Then import it in `build.zig`:

```zig
// `.platform` picks what hosts the app. `native` (the default) means AppKit
// on macOS and GTK 4 on Linux; `gtk` means GTK 4 anywhere; `none` means
// your program hosts fabrum itself and every widget is drawn.
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
b.installArtifact(exe);
```

**One thing that trips people up:** some packages, like the renderers below,
also use fabrum. Don't let them fetch their own copy. Pass them *your*
fabrum module with `addImport("fabrum", ...)`. Otherwise your program ends
up with two separate fabrums, and the build fails with an error like "file
exists in modules 'fabrum' and 'fabrum0'". Each package's README shows the
exact lines.

From here, [Build your first app](docs/guides/first-app.md) walks through a
new project step by step, from the window to the first test.

## Platforms

| `-Dplatform=` | What you get | Status |
|---|---|---|
| `native` on macOS | AppKit: `NSWindow`, native controls, the menu bar, alerts, file dialogs, the clipboard. Drawn content uses Quartz. | Works |
| `native` on Linux, or `gtk` anywhere | GTK 4: native widgets, menus, dialogs, the clipboard. Drawn content uses Cairo, with Pango for text. | Works |
| `none` | No toolkit. Your program runs the loop and draws the pixels with a renderer, and fabrum draws every widget. | Works |
| `native` on Windows or the web, `qt`, `sdl` | — | Not implemented: the build stops with a message saying so |

Known gaps: text editing has no right-to-left text and doesn't yet show
in-progress input-method composition (as used for Chinese or Japanese), and
the Cairo renderer can't draw pictures yet.

The layout engine alone (`fabrum.layout`) builds for any OS, whatever
`-Dplatform` says.

## Related packages

| Package | What it's for |
|---|---|
| [fabrum-renderer-z2d](https://github.com/ssttevee/fabrum-renderer-z2d) | Draws fabrum's UI into a pixel buffer. Pure Zig, so it builds for any target. Supports grayscale for e-ink screens. |
| [fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg) | Also draws into a pixel buffer, and can draw SVG, TVG and Lottie pictures as well. Compiles a C++ library. |
| [fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview) | Runs fabrum apps on PocketBook e-readers. |
| [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen) | A demo with one of every widget, running on every platform. A good place to see fabrum in action. |

## Examples

These are in [`examples/`](examples/). `zig build examples` builds them all,
and `zig build test` runs their tests.

| Example | What it shows | Run it |
|---|---|---|
| [`counter.zig`](examples/counter.zig) | The counter above, in a window with native buttons | `zig build run-counter` |
| [`tasks.zig`](examples/tasks.zig) | Background work: running tasks off the UI thread, cancelling them, and faking their results in tests | `zig build run-tasks` |
| [`headless.zig`](examples/headless.zig) | Hosting fabrum yourself with no window: it prints each frame's drawing commands and what changed | `zig build run-headless` |
| [`layout_only.zig`](examples/layout_only.zig) | Using just the layout engine, without the app runtime | `zig build run-layout-only` |

[docs/examples.md](docs/examples.md) describes these and the larger sample
apps in more detail.

## Learn more

Start with the **[usage guides](docs/guides/README.md)**. Each one walks
through a single task, such as your first app, splitting a screen into
components, forms and input, background work, or testing.

For reference, when you need every option:

- [Getting started](docs/getting-started.md): one app on AppKit, GTK and
  `none`, and its tests.
- [The app runtime](docs/app.md): components, messages, the `Ui` API,
  widgets, input, focus, scrolling, text editing, dialogs, menus, background
  tasks and testing.
- [The layout engine](docs/layout.md): sizing, alignment, text wrapping,
  floating and clipping.
- [Platforms](docs/platforms.md): what each platform provides, and how to
  host fabrum yourself.
- [Renderers](docs/renderers.md): the built-in renderers, using other ones,
  and writing your own.
- [Design record](docs/hybrid-design.md): why fabrum mixes native and drawn
  controls the way it does.

### What's in the module

```zig
const fabrum = @import("fabrum");
```

| Namespace | What it is |
|---|---|
| `fabrum.layout` | The layout engine on its own. Each frame you declare nested boxes into a `Context`, each sized `fit`, `grow`, `percent` or `fixed` along its axis. It sizes them (widths first, so text wraps at the width it gets), positions them, and produces `RenderCommand`s plus the `Damage` (the regions that changed), which `draw` sends to a renderer's `Surface`. It knows nothing about state, input or platforms. [docs/layout.md](docs/layout.md) |
| `fabrum.app` | The runtime: components, the `Ui` builder, messages and handlers, input, focus, scrolling, timers, background tasks (`Task`, `Update.run`, `Ui.task`), text editing (`TextEditor`, `Keymap`), what the device can do (`Capabilities`), e-ink refresh hints (`Refresh`), and `Runtime` itself. [docs/app.md](docs/app.md) |
| `fabrum.app.widgets` | The common widgets: `button`, `checkbox`, `toggle`, `slider`, `textField`, `textArea`, `searchField`, `secureField`, `dropdown`, `radioGroup`, `stepper`, `label`, `progressBar`, `spinner`, `scrollView`. Native where the platform has them, drawn otherwise. |
| `fabrum.app.drawn` | The same widgets, always drawn by fabrum, plus `textEditor` and `alert`. Used on `none`, and available anywhere. |
| `fabrum.app.menus`, `fabrum.app.dialogs` | The platform's menu bar items and alerts, declared from views. |
| `fabrum.app.testing` | `Harness`: runs a component with no window and no renderer. Tests can click buttons by their text or key, type, answer dialogs, check what's on screen, and control background tasks. |
| `fabrum.app.platform` | Which platform this build uses (`kind`), what a host offers beyond its window (`Services`), and the platforms themselves (`appkit`, `gtk`, `none`). [docs/platforms.md](docs/platforms.md) |
| `fabrum.app.native` | The interface between the runtime and a platform's native controls. Only needed to write a platform package. |
| `fabrum.render` | The renderers that come with fabrum: `Quartz` (macOS) and `Cairo`. [docs/renderers.md](docs/renderers.md) |
| `fabrum.Vec2`, `Rect`, `Range`, `Color` | Shared geometry and color types. |

### Build options

Pass these to `b.dependency("fabrum", .{ ... })`, or with `-D` when building
fabrum itself.

| Option | Values | What it does |
|---|---|---|
| `platform` | `native` (default), `gtk`, `none`, `qt`, `sdl` | What hosts the app; see [Platforms](#platforms). |
| `quartz` | `bool`, default `false` | Include the Quartz renderer on macOS with any platform, to draw into a Core Graphics context without a window. AppKit always includes it. |
| `cairo` | `bool`, default `false` | Include the Cairo renderer with any platform, to draw into a Cairo context. Links Cairo and Pango through `pkg-config`. GTK always includes it. |
| `coverage` | `bool`, default `false` | Measure test coverage with `kcov`: `zig build test -Dcoverage`. |

What gets linked: AppKit links the AppKit, Core Graphics, Core Text, Core
Foundation and UniformTypeIdentifiers frameworks. GTK links `gtk4` through
`pkg-config`, which brings in Cairo and Pango. `none` links nothing. fabrum's
only package dependency is [zg](https://codeberg.org/atman/zg), which it uses
to split text into characters and words for editing. `zig build` fetches
it for you.

## License

[MIT](LICENSE).
