# Platforms

A platform is what hosts a fabrum app. A toolkit platform owns the window and
its chrome, the event loop, the menus, the dialogs, the clipboard and the
standard controls; fabrum owns one host view per window and lays out
everything in it, native controls and drawn content alike. The `none`
platform has no built-in host: the app's own code drives the runtime, and
every widget is drawn.

## The build option

The platform is chosen when fabrum is built, with its `platform` option
(`-Dplatform=...` on the command line, `.platform = ...` in
`b.dependency`), independently of the target OS:

| Option | On | `app.platform.kind` | Status |
|---|---|---|---|
| `native` | macOS | `.appkit` | implemented |
| `native` | Linux and other Unix | `.gtk` | implemented |
| `native` | Windows | `.win32` | compile error |
| `native` | wasm | `.web` | compile error |
| `gtk` | anywhere GTK 4 is | `.gtk` | implemented |
| `qt` | | `.qt` | compile error |
| `sdl` | | `.sdl` | compile error |
| `none` | anywhere | `.none` | implemented |

`app.platform.kind` is known at compile time. Namespaces of platforms not in
the build (`app.platform.appkit` in a GTK build) are compile errors when
used, so code naming them sits behind a `kind` check; `app.platform.current`
is the namespace of `kind`. Using `fabrum.app` on a platform that isn't
implemented fails compilation with a message naming it and suggesting
`none`; `fabrum.layout` alone builds with any option.

## AppKit (macOS)

`-Dplatform=native` on macOS. Links AppKit, Core Graphics, Core Text, Core
Foundation and UniformTypeIdentifiers; the Objective-C half is
`src/app/platform/appkit/shell.m`.

- **`appkit.App(Root)`** runs a root component in an `NSWindow` whose
  content is fabrum's host view. It owns the runtime, the canvas's renderer
  and the native backend, and turns what AppKit reports into frames,
  pointer input, focus moves and native events. `appkit.AppWith(Root,
  Renderer)` takes another renderer for `.cg_context` surfaces.
  - `init(self, gpa, io, props, window: appkit.Options, options:
    InitOptions)`. `Options`: `title`, `width`, `height`, `min_width`,
    `min_height`, `dark`. `InitOptions`: `provide` (root values),
    `context` (layout capacity), `on_terminate` (called once before the
    process exits, for stopping background work).
  - `run()` opens the window and runs the event loop; it never returns.
  - `runtime`, `viewport`, `handleOf(id)` (the `NSView` behind a native
    element, for automation), `mouse(...)` and `activate(...)` for scripts
    that feed input in process.
- **Canvas:** `fabrum.render.Quartz`, drawing into `CGContext`s in canvas
  layers (`NSView`s) stacked with the native controls in paint order. Core
  Text measures the drawn text as the native controls' is.
- **Controls:** the common set, plus `appkit.widgets.levelIndicator`
  (`NSLevelIndicator`). Menu items go in the menu bar (`NSMenu`); alerts
  are `NSAlert` sheets.
- **Services:** `message` and `confirm` (`NSAlert`), `menu` (`NSMenu`
  popup), `openFile` (`NSOpenPanel`, filtering by extension through
  `UTType`), the clipboard (`NSPasteboard`), `quit`. No `openDirectory`,
  `editText` or `close`. `shouldClose` is asked from `windowShouldClose:` and
  `applicationShouldTerminate:`.
- **`appkit.automation`:** what debug scripts do to a running app in
  process, without the system's event stream: `runOnMain`, `quit`, `close`,
  `usePrivateClipboard`, `clipboardText`, `answerFileChooser`, `snapshot`
  (the window's content as a PNG, at a scale, working while the screen is
  locked), `windowNumber`, `click`, `typeText`, `mark`, `commit`,
  `fieldText`, `newline`, `slide`, `select`, `step`, `scrollTo`, `tab`,
  `answerAlert`, `answerPopup`, `chooseMenu`, `resize`, `describeFocus`,
  `describeHit`, and `windowClick` and `windowKey`, which send events
  through the window (only while the session is unlocked). OpenEtcher's and
  the Kitchen's scripts are built on these.

```zig
pub const Gui = appkit.App(ui.App);

pub fn main(init: std.process.Init) !void {
    const gui = try init.gpa.create(Gui);
    try gui.init(init.gpa, init.io, .{}, .{ .title = "OpenEtcher", .width = 800, .height = 480 }, .{
        .provide = &.{ .of(&provided.services), .of(&provided.icons) },
        .on_terminate = .{ .ctx = services, .call = shutdown },
    });
    gui.run();
}
```

(Condensed from OpenEtcher's `src/app/main.zig`.)

## GTK 4

`-Dplatform=gtk` anywhere GTK 4 is, and `native` on Linux. Links `gtk4`
through pkg-config, which brings Cairo and Pango; the C half is
`src/app/platform/gtk/shell.c`. With Homebrew's GTK on macOS, Homebrew's
`pkgconf` must be first on `PATH` so the `.pc` files' private requirements
resolve.

- **`gtk.App(Root)`** and `gtk.AppWith(Root, Renderer)` (for `.cairo`
  surfaces) have the same shape as AppKit's: a `GtkWindow` whose content is
  fabrum's base canvas (a `GtkDrawingArea`) under a `GtkFixed` holding GTK's
  widgets and the canvas layers above them. The runtime's keymap is
  `.linux`.
- **Canvas:** `fabrum.render.Cairo`, with text set by Pango in the toolkit's
  font family, so drawn text measures like the labels beside it.
- **Controls:** the common set. Menu items go in a menu bar; alerts are
  `GtkAlertDialog`s.
- **Services:** `message`, `confirm`, `menu` (`GtkPopoverMenu`), `openFile`
  (`GtkFileDialog`), the clipboard (`GdkClipboard`; reading is asynchronous),
  `quit`; no `openDirectory`, `editText` or `close` either. `shouldClose`
  from `close-request`.
- **`gtk.automation`:** the in-process subset of AppKit's (`runOnMain`,
  `quit`, `snapshot`, `click`, `typeText`, `fieldText`, `newline`, `slide`,
  `select`, `step`, `scrollTo`, `tab`, `answerAlert`, `answerPopup`,
  `answerFileChooser`, `chooseMenu`, `resize`, `describeFocus`,
  `describeHit`).

## `none`: the app's own host

`-Dplatform=none`. No window, no toolkit, nothing linked, so it builds for
any target. The program is the host: it owns the loop, the clock, the pixels
and where input comes from. This is what a VNC server showing a fabrum
interface over a remote screen, an overlay drawn into a game's frames, an
e-reader's toolkit and a test rig use.

### The host contract

The runtime is single-threaded: call it from one thread. Other threads only
post messages (`Runtime.poster()`), which wake the host through the
`app.Platform` it passes in `Options.platform` (one function,
`requestFrame`, which must be thread-safe).

1. **Make the runtime** with the renderer's text: `app.Runtime(.{ .Text =
   Renderer.Text })`, with no `native` backend, and the look of drawn widgets
   in `Options.theme` (a translucent `window_background` makes an overlay).
   Describe the host in `Options.capabilities` (a touch screen without hover,
   no animation, a grayscale panel, an on-screen keyboard), give it
   `Options.services` for what it does beyond the viewport (each optional),
   and `Options.keymap` if its users expect another platform's editing keys.
2. **Feed input** as it arrives, in the viewport's points from its top left:
   `rt.mouse(event)` for pointer moves, buttons, long presses and scrolling
   (with the gesture's phase from a trackpad), `rt.key(event)` for keys (with
   the text they type, if the host knows it), `rt.textInput(input)` for text
   committed without keys (an input method, a system keyboard's result).
   Each returns whether the app took the event; pass on what it didn't.
   - A pointer event is taken when the pointer is over something of the app
     (anything but the root that paints or takes a press there), for the
     rest of a press that began over one, and when a wheel scrolled
     something. `rt.cancelPointer()` ends a press the host lost.
   - Keys are taken only while a drawn element has focus. Pressing something
     that takes focus gives it; pressing nothing of the app's clears it;
     `rt.focusMove` moves it from the host.
   - `app.platform.none.keyFromX11Keysym` and `textFromX11Keysym` map RFB
     (VNC) keysyms to keys and the text they type.
3. **Run a frame** when `rt.nextFrame()` says so: null when nothing is due
   (wait for input or a post), or the time the next frame is due (a timer, a
   caret blink, an animation); a time at or before now means as soon as
   possible. `rt.frame(Root, props, viewport, now)` takes the host's clock
   and returns the render commands.
4. **Take what changed**: `rt.damage()` gives the regions that changed since
   the host last asked (the whole viewport the first time and after a
   resize), in whole points, and `rt.refresh()` how to show them:
   `interactive` during a drag or a scroll, `content` otherwise, `page`
   when the app asked. E-ink hosts map these to fast, quality and full
   updates; others ignore them. No regions: nothing to redraw.
5. **Draw** the commands into the host's pixels, redrawing only the damage:
   `fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, damage)`.
   Pixels are premultiplied RGBA or BGRA, or opaque `gray8`, at the host's
   scale; outside the damage they are left as they were, inside it the
   renderer clears them first, so a buffer with alpha always holds the
   overlay alone.
6. **Present**: composite the damaged regions over whatever is under the
   overlay, upload them, send them as RFB rectangles, or hand them to the
   panel with the refresh it asked for.

```zig
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{
    .io = io,
    .text_context = renderer.text_context,
    .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
    .services = host.services(), // dialogs, a system keyboard, quitting: what the host has
});
while (host.running) {
    for (host.pendingInput()) |input| {
        const taken = switch (input) {
            .pointer => |event| try rt.mouse(event),
            .key => |event| try rt.key(event),
            .text => |text| try rt.textInput(.{ .commit = text }),
        };
        if (!taken) host.passOn(input);
    }
    const now = host.clock();
    if (rt.nextFrame()) |due| if (due.nanoseconds <= now.nanoseconds) {
        const commands = try rt.frame(Root, props, viewport, now);
        const damage = try rt.damage();
        if (damage.len > 0) {
            try fabrum.layout.draw(&renderer, commands, .pixels, pixels, damage);
            host.present(pixels, damage, rt.refresh());
        }
    };
    host.sleepUntil(rt.nextFrame(), host.inputArrives());
}
```

(`host` is whatever the program has; `test/compile/doc_snippets.zig` runs
this loop against a host made of data.) [`examples/headless.zig`](../examples/headless.zig) is a
complete, runnable host that prints instead of drawing, and the Kitchen's
`src/none.zig` draws with z2d or ThorVG as an overlay and as an e-ink
panel, checking the damage against a full redraw at every step.

### Services

`app.platform.Services` is a vtable of what a host does beyond its window.
Every entry is optional; the runtime falls back where it reasonably can:

| Service | Request | Reply | Without it |
|---|---|---|---|
| `message` | `MessageRequest` (`title`, `text`, `kind`, `timeout_ms`) | | a dialog drawn by fabrum, modal |
| `confirm` | `ConfirmRequest` (`title`, `text`, one to three `buttons`, `default`, `kind`) | `IndexReply` (the index, or null) | a drawn dialog |
| `menu` | `MenuRequest` (`items`, `at`, `anchor`) | `IndexReply` (the `MenuItem.id`, or null) | a drawn menu |
| `editText` | `TextRequest` (`title`, `initial`, `flags`: url, numeric, password, email, multiline; `max_len`) | `Reply` (the text, or null) | `error.Unsupported`; drawn fields take keys themselves |
| `openFile`, `openDirectory` | `FileRequest` (`message`, `extensions`) | `Reply` (the path, or null) | `error.Unsupported` |
| `writeClipboard`, `readClipboard` | text; `Reply` | | a clipboard private to the program |
| `quit`, `close` | | | `error.Unsupported` |

Replies are thread-safe and may be sent later, from any thread:
`reply.send(text)` copies the text and posts it as a message that borrows
the copy. A host that can't do something leaves the entry null. The
Kitchen's `EinkServices` in `src/none.zig` is a minimal one (a keyboard
that answers a text entry, a dialog answered with its first button).

### What the runtime needs from the host

| `Runtime.Options` | A `none` host sets |
|---|---|
| `io` | its `std.Io` |
| `text_context` | the renderer's, so text is measured as it is drawn |
| `platform` | an `app.Platform` whose `requestFrame` wakes the loop, if other threads post |
| `theme` | the look of drawn widgets; made high-contrast on a gray display |
| `capabilities` | what the display and input are |
| `keymap` | `.macos`, `.windows` or `.linux` |
| `services` | the table above |
| `context` | a larger `breadth` for long lists |

## Writing an external platform package

An external platform (an e-reader's toolkit, a game engine's UI layer) is a
`none` host packaged as a Zig module that apps depend on, with its own
`Services` and, if the toolkit has native widgets, an `app.native.Backend`
in `Options.native`. fabrum-platform-inkview is the model:

- The package's module imports `fabrum` and its renderer but **does not
  depend on fabrum** except lazily, for its own tests. The app gives it the
  fabrum it uses, built with `.platform = .none`, so there is one fabrum in
  the program:

```zig
const inkview = b.dependency("fabrum_platform_inkview", .{ .target = target, .optimize = optimize });
const platform = inkview.module("fabrum-platform-inkview");
@import("fabrum_platform_inkview").addFabrum(platform, fabrum_mod);
exe.root_module.addImport("fabrum-platform-inkview", platform);
```

  where `addFabrum` is the package's `pub fn` that calls
  `platform.addImport("fabrum", fabrum)` on its module and on the renderer
  module inside it.

- It exposes `run(Root, gpa, io, props, options)`, which makes the runtime
  with the device's `Capabilities` (InkView: touch, no hover, no animation,
  `gray16`, an on-screen keyboard), the theme, the keymap and its services,
  and hands the toolkit a handler.
- Its host (`src/host.zig` there) maps the toolkit's events to
  `Runtime.mouse`, `key`, `cancelPointer` and `textInput`; runs frames
  after every event while `nextFrame` says one is due, arming a toolkit
  timer for a later one; draws the damage into the framebuffer with the
  renderer; and turns `Runtime.refresh` into the panel's updates (InkView:
  `page` is a full update, `content` a partial one per region,
  `interactive` a fast gray or A2 update with hysteresis and a cleaning
  full refresh afterwards).
- Posts from other threads go through `app.Platform.requestFrame`, which
  sends the toolkit an event to wake its loop.
- Its services wrap the toolkit's modal UI (InkView's `Dialog3`,
  `OpenMenu`, `OpenKeyboard`) and answer through `Reply` and `IndexReply`;
  frames are held while one is up and everything is redrawn when it closes.
- A fake toolkit (`src/fake.zig`) lets the host be tested without the
  device, and the app's components are tested with `app.testing.Harness` as
  on any platform.

## The native contract

Toolkit platforms, and external packages with native widgets, implement
`app.native.Backend`: `create`, `update`, `destroy`, `setFrame`,
`setContentSize`, `measure`, `setValue`, `composing`, `canFocus`, `focus`,
`present`, `theme` and the optional `reparent`. Each frame the runtime
reconciles the declared elements (`native.Spec` plus a `native.Value`)
against the native objects it made, keyed by 64-bit element ID, and hands
the backend a `native.Scene`: canvas layers interleaved with native views
in paint order, and the same for each native container. Events come back
through `Runtime.nativeEvent(id, event)`. `app.testing.NativeTree` is a
backend made of data, which the harness uses. The full description is in
`src/app/native.zig` and `docs/hybrid-design.md` §2 to §9.
