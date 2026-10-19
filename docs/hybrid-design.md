# Hybrid layering: fabrum with native controls

> This is the design record of the hybrid layering, kept for the reasoning and history. The documentation of what exists is in the [README](../README.md) and the guides beside this file: [getting-started.md](getting-started.md), [app.md](app.md), [layout.md](layout.md), [platforms.md](platforms.md), [renderers.md](renderers.md), [examples.md](examples.md).

Status: spike, on the `hybrid` branches of fabrum (`zig-layout`), the Kitchen
(`zig-fabrum-kitchen`) and the Quartz and ThorVG renderers, then the first checkpoint
(P1) of the portable track: the `.none` platform, drawn widgets, the renderer interface
and damage (§18), then the first checkpoint (N1) of the native track: real-input checks,
Quartz inside fabrum, queued native events, native scroll containers and the shell hooks
(§19), then the second checkpoint (P2) of the portable track: drawn interaction (keys,
focus, dragging, scrolling, text editing), the pluggable platform services, capabilities,
gray and scaled surfaces and e-ink refresh hints (§20), then the second checkpoint (N2) of
the native track: the N1 decisions (sRGB, unchanged canvas layers left alone, reparenting),
AppKit's dialogs and menus from `update`, the wider common widget set, the GTK 4 platform
with the Cairo renderer, and OpenEtcher on the AppKit platform (§21). Written against what
was built and ran. Parts that are designed but not built are marked **(not built)**.

The decision (user): fabrum keeps what is its own (the TEA runtime, components,
contexts, the layout engine and a keyed reconciler) and uses the platform's own
window, event loop, menus, dialogs and standard controls. Drawing everything is
opt-in, per widget. "Not reinventing the wheel, just a new electrical system."

```
fabrum (always fabrum's)    TEA runtime · components · contexts · layout engine · keyed reconciler
platform (always native)    window + chrome · event loop · menus · dialogs · clipboard · drag-and-drop ·
                            notifications · accessibility bridge
controls (native by         text field / text area · dropdown · date picker · scroll view · button ·
  default, drawn opt-in)    checkbox · switch · slider · progress
drawn (fabrum canvas)       custom visuals; the platform's 2D API draws them into canvas layers
```

Contents:

1. [Ownership and the frame](#1-ownership-and-the-frame)
2. [The native contract: `fabrum.app.native`](#2-the-native-contract-fabrumappnative)
3. [The reconciler](#3-the-reconciler)
4. [Controlled values](#4-controlled-values)
5. [Stacking: canvas layers](#5-stacking-canvas-layers)
6. [Focus: one chain](#6-focus-one-chain)
7. [Menus and dialogs](#7-menus-and-dialogs)
8. [Native theme](#8-native-theme)
9. [Native containers](#9-native-containers)
10. [Namespaces and the build option](#10-namespaces-and-the-build-option)
11. [The common widget set and platform catalogues](#11-the-common-widget-set-and-platform-catalogues)
12. [Testing native widgets: `app.testing.NativeTree`](#12-testing-native-widgets-apptestingnativetree)
13. [The AppKit platform](#13-the-appkit-platform)
14. [GTK 4 and others](#14-gtk-4-and-others)
15. [The duplicate-instance trap](#15-the-duplicate-instance-trap)
16. [What happens to the Kitchen's `input-design.md`](#16-what-happens-to-the-kitchens-input-designmd)
17. [Risks and open questions](#17-risks-and-open-questions)
18. [The `none` platform: the app's own host](#18-the-none-platform-the-apps-own-host)
19. [N1: real input, Quartz in fabrum, containers and the shell](#19-n1-real-input-quartz-in-fabrum-containers-and-the-shell)
20. [P2: drawn interaction, services, capabilities, surfaces and refresh](#20-p2-drawn-interaction-services-capabilities-surfaces-and-refresh)
21. [N2: the N1 decisions, the wider widget set, GTK 4 and OpenEtcher](#21-n2-the-n1-decisions-the-wider-widget-set-gtk-4-and-openetcher)

---

## 1. Ownership and the frame

- **The toolkit owns the window and the event loop.** `[NSApp run]`, `gtk_main`, the
  Win32 message loop. fabrum never runs its own loop on a real platform.
- **fabrum owns one host view per window** and lays out everything in it, native
  controls and drawn content alike, as React Native does with Yoga. The host view is the
  window's content view. Native controls are its subviews; drawn content is in canvas
  layers, also subviews (§5).
- **Native controls measure themselves.** A native element is a box in fabrum's layout
  whose content is a `layout.Content` that asks the backend for the control's size
  (AppKit: `fittingSize`, falling back to `intrinsicContentSize`). The box's sizing comes
  from the view (`fit` by default, `grow` for fields, sliders and progress bars), and the
  native view takes the box's frame.

One frame, in `Runtime.frame`:

1. Deliver queued messages.
2. Run the views. Each native element is reconciled **as it is declared**: created,
   updated, or written to (§3, §4), so it exists with its latest props when layout
   measures it.
3. Compute the layout.
4. `Reconciler.finish`: destroy what wasn't declared, set the frames that changed, build
   the focus chain (§6), split drawn content into canvas layers (§5), and hand the
   `Scene` to the backend (`present`).
5. Sweep stateful instances.

On AppKit a frame runs when requested (a message, input, a posted result) from a
main-queue block, and synchronously from the host view's `setFrameSize:`, so live resize
re-lays out native frames every step. Canvas layers draw the last frame's commands in
`drawRect:`. This replaces the drawn-only shell, where the frame ran inside `drawRect:`.

## 2. The native contract: `fabrum.app.native`

Everything platform-neutral about native widgets is in `src/app/native.zig`:

| Type | What it is |
|---|---|
| `Id` | A native element's identity: the 64-bit hash of (instance, key), which is also its layout unit's ID. |
| `Handle` | The backend's reference to one native object, opaque to fabrum. |
| `Spec` | What an element is, with its non-value props: `button`, `checkbox`, `switch`, `slider`, `text_field`, `progress`, `menu_item`, `alert`, `scroll_view` (a container, §9), and `extension` for platform catalogues. Deep `eql`, `clone`, `free`, `sameKind`, `placement`, `isContainer`. |
| `Value` | The user-changed, model-controlled value: `none`, `toggle`, `number`, `text`. |
| `Event` | What the user did: `activate`, `toggle`, `number`, `text` (not sent while composing), `submit`, `focus`, `composition_end`, `response`, `scroll` (a container's offset, §9). |
| `Handlers` | The `Handler`s an element fires, one per kind of event (`on_activate`, `on_toggle`, `on_number`, `on_text`, `on_submit`, `on_response`). |
| `Element` | One declaration: `spec`, `value`, `handlers`, and the box's `sizing`. |
| `Scene` | Bottom-to-top slots of canvas layers and native views, each native container's own slots, and each layer's commands, hit regions and offset (§5, §9). |
| `Theme` | The platform's colors and metrics (§8). |
| `Backend` | The vtable a platform implements. |

### The backend vtable

```zig
pub const VTable = struct {
    create:    fn (ptr, id: Id, spec: *const Spec, value: *const Value, parent: ?Handle) Error!Handle,
    update:    fn (ptr, handle, old: *const Spec, new: *const Spec) void, // apply what differs
    destroy:   fn (ptr, handle) void,
    setFrame:  fn (ptr, handle, frame: Rect) void,        // parent coordinates, top left
    setContentSize: fn (ptr, handle, size: Vec2) void,    // a container's content (§9)
    measure:   fn (ptr, handle, constraints: layout.Constraints) Vec2,
    setValue:  fn (ptr, handle, value: *const Value) void, // never reported back as an Event
    composing: fn (ptr, handle) bool,                      // IME marked text
    canFocus:  fn (ptr, handle) bool,                      // the platform's own rule
    focus:     fn (ptr, target: FocusTarget) void,         // .none, .native, .canvas
    present:   fn (ptr, scene: *const Scene) void,         // stacking + canvas commands
    theme:     fn (ptr) Theme,
};
```

- **Create, update, destroy** are the reconciler's three verbs. `update` gets the old and
  new spec of the same kind and applies only what differs; a kind change replaces the
  object.
- **Set frame** is only called when a box changed.
- **Measure** is called during layout. Constraints are passed; AppKit's controls ignore
  them today. A wrapping native label would need them (`preferredMaxLayoutWidth`).
- **Event wiring** goes the other way: the backend calls `Runtime.nativeEvent(id, event)`
  from its target-actions and delegates. The runtime notes the reported value, makes the
  message through the element's handler, and delivers it at once, as clicks do. A text
  field's text is **borrowed** by the message, like an action's payload: `update` copies
  what it keeps. (`message.makeBorrowed`.)
- **Focus** and **z-order** are covered in §6 and §5. `parent` is the native container an
  element is declared in (§9); which view a native view is a subview of is decided by
  `present`, so AppKit ignores it, and a toolkit that needs it at creation has it.
- **Events during a frame.** Toolkits report from inside the calls a frame makes:
  AppKit's `becomeFirstResponder` when the frame focuses a field, GTK's `changed` when it
  writes one. `Runtime.nativeEvent` queues them while a frame runs (text copied) and
  delivers them in order before the next input or frame; `needsFrame` says so meanwhile.
  The spike dropped them.

Errors: `create` can fail (`error.NativeCreateFailed`, out of memory), and the error
propagates out of `ui.native` with `try`, like any view error. Declaring a native
element on a runtime without a backend is `error.NoNativeBackend`.

## 3. The reconciler

`src/app/reconciler.zig`. Records are kept in a hash map keyed by `native.Id` (64 bits),
with the handle, an owned copy of the last applied spec, the value the control shows
as far as fabrum knows, the handlers of the last frame, the layout unit, and the frame
last set.

- **Identity** is the element's (instance, key), exactly as for drawn elements and
  stateful instances, so keyed lists reorder without remaking anything: the reordering
  test swaps three keyed text fields, and the same handles move, with no creates,
  destroys or writes.
- **Create** happens at the first declaration. **Update** happens only when the spec
  isn't deeply equal to the last one applied. **Replace** happens when the kind changes
  under the same key. **Destroy** happens in `finish` for every record the frame didn't
  declare, before the scene is built, so the scene never names a dead view.
- **Frames** are set only when the laid-out box differs from the last frame set. A frame
  that changes nothing calls the backend for nothing (a test checks the counts:
  `Reconciler.stats`).
- **Duplicate keys** are `error.DuplicateKey`, as for drawn elements.
- **Containers.** A record has a parent container (or none) and a depth. Children are
  destroyed before their container (in `finish` and `deinit`). An element that moves to
  another container keeps its native object: the backend's `reparent` moves the view
  (optional in the vtable; a backend without it gets a replacement), and its frame is set
  again in the new parent's coordinates (N2, §21). Frames are in the parent's content
  coordinates (§9).
- Elements placed **elsewhere** (menu items, alerts) have records but no layout unit.

On AppKit a re-measure happens after an update, through layout: "Green" → "Blue"
shrank the button from 61 to 51 points and moved nothing else.

## 4. Controlled values

The rule: **write a model value into a native control only when it differs from what the
control last reported (or was last given), and never during IME composition.**

- Each record keeps `shown`: the last value the control reported in an `Event`, or the
  last value fabrum wrote.
- A declared value equal to `shown` is never written. A model that stores what was typed
  therefore never writes it back, and the caret, selection and undo stack stay the
  control's.
- A declared value that differs is written (`setValue`), unless `composing` says the user
  has marked text. Then the write is held back, and tried again on the next frame. The end
  of the composition (`Event.composition_end`) marks the runtime dirty so that frame
  happens.
- Text events are not sent while composing. The commit that ends a composition sends the
  committed text, then `composition_end`.
- On AppKit, a write to a field being edited goes into the field editor (with the caret at
  the end), so editing continues.

Shown on AppKit, in process, by the Kitchen's script:

| Step | Field shows | Model | Writes |
|---|---|---|---|
| type "Hi there" | `Hi there` | `Hi there` | 0 |
| Uppercase on | `HI THERE` | `HI THERE` | 1 |
| type "!x" | `HI THERE!X` | `HI THERE!X` | one per key, each echoing the model's capitals |
| Return | `` (heading = `HI THERE!X`) | `` | 1 |
| type "abc", compose "に", Uppercase on | `abcに` (composing) | `ABC` | held |
| commit "日本" | `ABC日本` | `ABC日本` | 1, after the composition ended |

The same cases are tests against the fake native tree (`hybrid_test.zig`, `kitchen.zig`).

**IME notes.** AppKit's field editor (`NSTextView`, an `NSTextInputClient`) does all of
the IME work: marked text, candidates, the caret rectangle. fabrum only needs
`hasMarkedText`. Composition was driven with `setMarkedText:selectedRange:replacementRange:`
and `insertText:replacementRange:`, the calls an input method makes, and then with a real
input method, Kotoeri, typed with real keys (§19). With native fields,
§7.2 of the Kitchen's design (the IME mirror, UTF-16 ranges, `firstRect`) is not needed
for them at all.

## 5. Stacking: canvas layers

Native views sit above the canvas they are placed in. To let drawn content cover a
native view (a drawn dialog over a native field, as Flutter does with platform views),
the reconciler splits the frame's render commands into **canvas layers interleaved with
native views in paint order**. This is `native.Scene`:

```
slots:  canvas 0 · button · field · slider · … · canvas 1
layers: [0] everything that overlaps no native view painted before it
        [1] the dialog's backdrop, box, text and buttons
```

The algorithm, in one pass over the render commands:

- A native view's command appends a native slot.
- A drawn command goes to the **lowest** canvas layer that is:
  - above every native view painted before it whose frame it overlaps; and
  - at or above every layer holding an earlier drawn command it overlaps.

  If no layer qualifies, a new canvas layer is appended at the top.
- Overlap uses the command's box cut by the clips in force. Content clipped away from a
  native view stays below it.
- Scissors are replayed into every layer that draws inside them, and balanced at the
  end of each layer.

So an ordinary page of native controls and drawn decoration has **one** canvas under the
controls. A drawn dialog adds **one** more on top. Labels after a native button stay in
layer 0, because they don't overlap it.

**Input.** Layer 0 takes all the pointer input that native views leave. Higher layers
take it only where they have drawn something (`Layer.hits`, the boxes of their
commands). Every layer forwards input to the runtime, which hit-tests its whole layout
as before. AppKit's own `hitTest:` confirmed the routing. Before the dialog, the line
editor's point hit `FabrumTextField`. With the dialog open, the same point hit `canvas
layer 1`.

**Limits.**

- Hit regions are rectangles, so a rounded corner of a drawn overlay blocks clicks to a
  native view beneath it.
- A native view inside a drawn clipping container is not clipped. A native view in a
  drawn scroll area would spill out. Native containers (§9) are clip views: put native
  views that must be clipped in one.
- A present redraws a canvas layer only where it changed (`native.CanvasDamage`, §21):
  a scroll step, which moves the layout and the layer's offset together, redraws nothing.

## 6. Focus: one chain

- **The chain** is built every frame in paint order. It holds native elements whose
  backend says `canFocus`, and drawn elements declared `focusable`. Focus is the runtime's
  (`?FocusEntry`: a unit and, for natives, the `native.Id`).
- **Tab and Shift-Tab** call `Runtime.focusMove`. Focusing a native element calls
  `backend.focus(.native)` (AppKit: `makeFirstResponder:`). Focusing a drawn one gives
  the platform's keys to the canvas (`.canvas`), and the view draws a ring with
  `ui.focused(key)`.
- **AppKit's Tab goes to fabrum.** It comes from the field editor (`insertTab:` and
  `insertBacktab:` through the text field's delegate) and from `FabrumWindow`'s key-view
  selectors (`selectNextKeyView:`, `selectKeyViewFollowingView:` and their reverses).
  The canvas's `keyDown:` takes Tab, Space and Return.
- **Platform convention.** Which controls join the chain is AppKit's own
  `canBecomeKeyView`, which follows System Settings > Keyboard navigation. This Mac has
  it **on** (the theme reports `full_keyboard_access`), so Tab went line editor →
  Uppercase checkbox → RadioButton1–3 → "Open dialog" → notes. With it off, buttons and
  checkboxes are skipped, as the fake tree's default does. Drawn widgets can follow the same
  setting through `Theme.full_keyboard_access`.
- **Focus on click** follows the platform: clicking a native field focuses it (reported
  by `becomeFirstResponder`, so Tab continues from there). Clicking a drawn button
  doesn't take focus, as on macOS.
- **Space** on a focused drawn element fires its `on_click` (`Runtime.activateFocused`).
  Native controls handle their own keys.
- **Modal scopes.** A container declared `modal` limits the chain to its descendants,
  native ones included. Focus outside it moves to its first element. The spike found the
  need: without it, Tab reached the native field under the drawn dialog, and typing went
  into the covered field.
- **Lost elements.** Focus on an element the frame didn't show is cleared.

## 7. Menus and dialogs

Menus and alerts are native elements **placed elsewhere**. They are declared from views
like controls, reconciled by key, and their events are messages.

```zig
try menus.item(ui, "say hello", .{ .menu = "Kitchen", .title = "Say Hello", .key = "k", .on_select = on.bind(.say_hello) });
if (state.greeting) try dialogs.alert(ui, "hello", .{
    .title = "Hello from fabrum",
    .buttons = &.{ "OK", "Again" },
    .on_response = on.handler(.answered), // usize
});
```

- A **menu item** exists while some view declares it. Its menu in the menu bar is made
  when missing (before Window) and removed when empty. `key` uses the platform's shortcut
  modifier.
- An **alert** is shown (as a sheet on macOS) when first declared, and answered once. It
  is dismissed if the view stops declaring it first. Its text is fixed once shown.
- **File dialogs, the clipboard and closing** are the shell's (§19): commands from
  `update` (`ctx.openFile`, `ctx.readClipboard`, `ctx.writeClipboard`, `ctx.quit`) whose
  answers are messages, and `ui.guardClose` for confirming before closing.
- **Not built:** context menus, save panels, notifications and drag-and-drop.

## 8. Native theme

`native.Theme` is provided by the runtime as a root value whenever it has a backend,
under the app's own values (so an app can override it), and re-read every frame:

```zig
pub const Theme = struct {
    accent, text, secondary_text, window_background, control_background, separator, focus_ring: Color,
    font_size: f32, control_height: f32, full_keyboard_access: bool, dark: bool,
};
```

On AppKit:

- The colors come from `NSColor.controlAccentColor`, `labelColor`, `windowBackgroundColor`
  and so on, resolved in the window's appearance.
- `font_size` is `NSFont.systemFontSize` (13).
- `control_height` is a push button's fitting height (24 on this Mac).

The Kitchen's drawn strip, radio buttons, dialog and focus rings use it, and match the
native controls (`11-side-by-side-drawn-vs-hybrid.png`).

**Not built:** font names, so drawn text uses the same face (the Quartz renderer's
system font already matches), and change notifications for dark mode and accent changes.
Re-reading every frame covers the next frame, but nothing asks for one.

## 9. Native containers

A native scroll view is a native element **with children**: fabrum lays out its content
as a sub-layout, in the container's content coordinates, and the platform scrolls it.

```zig
try widgets.scrollView(ui, "page", .{ .content = .{ .axis = .y } }); // NSScrollView
defer ui.close();
try widgets.textField(ui, "name", .{ ... });  // made inside the scroll view's document
try ui.text("drawn, in the document's own canvas layer", .{});
```

- **Declaring.** `Ui.nativeOpen(key, element, content_layout)` declares a container
  element and opens a layout container for its content; `close` ends it. Elements
  declared inside get it as their `parent`. `widgets.scrollView` wraps it (sizing `grow`
  by default).
- **Layout** (`layout.zig`). Every container records `Unit.content_size`: the children's
  extent from the content's top left, plus padding. On an axis whose overflow is clipped,
  the children's minimum sizes stop holding the container open, they are not squeezed
  along it, and `fit` children across it aren't capped at the container's size (the
  input design's "clipped-axis sizing"). A scroll view clips the axes it scrolls, so its
  content can be taller than the view; its preferred size still fits the content.
- **The offset is the platform's.** `NSScrollView` scrolls with momentum, rubber-banding
  and scrollers, and reports where it is (`Event.scroll`, from its clip view's bounds).
  fabrum lays the content out against that offset (`clip.child_offset = -offset`), so its
  layout stays in window coordinates: hit-testing, hover and clicks on drawn content need
  no transform. Between a scroll and the frame it asks for, input inside the document is
  mapped through the layer's offset at the last frame, so it agrees with the layout.
- **Frames** are set in the parent's content coordinates: the box minus the content's top
  left, which takes the offset out again (snapped to 1/256 point, so float rounding never
  moves a frame). Scrolling therefore moves no native view; the reconciler's counts show
  zero `setFrame` calls for a scroll. The container's content size is set with
  `setContentSize`; AppKit sizes the document to it, and at least to the view, so the
  document's first canvas layer takes clicks everywhere in it.
- **The scene is a tree.** Each container has its own slots (`Scene.containers`), with a
  base canvas layer and more above its native views as needed, by the same rule as the
  host. Layers carry the offset of the view they draw in (`Layer.offset`, the content's
  top left in layout coordinates); commands are drawn moved by minus it, and hit regions
  stay in layout coordinates. The split scopes commands by the container's own scissors,
  which aren't replayed inside it: the platform's clip view clips.
- **Clipping.** Native views in a container are its document's subviews, clipped by its
  clip view; drawn content in it is drawn by its own layers, clipped the same way.
- **Focus** stays one chain in paint order. Focusing a native view inside a scroll view
  scrolls it into sight, as AppKit's own key-view loop does.
- **Drawn fallback.** Without native widgets, `scrollView` is a drawn scroll container
  (`app.drawn.scrollView`): the runtime keeps its offset by element ID, the wheel and a
  drawn thumb scroll it, and `ctx.scrollTo` moves it (§20).

Verified with `NativeTree` (`hybrid_test.zig`: frames in document coordinates, content
size, scrolling and clamping, a drawn row and a native button clicked after scrolling,
the scene's containers and layer offsets, teardown order) and on AppKit with real wheel
events and clicks (§19).

## 10. Namespaces and the build option

```
fabrum.app.native      the contract (§2): Backend, Spec, Value, Event, Scene, Theme
fabrum.app.widgets     the common widget set (§11)
fabrum.app.drawn       the common set drawn, text widgets included (§18, §20)
fabrum.app.menus       menu bar items, declared
fabrum.app.dialogs     alerts, declared
fabrum.app.testing     Harness, and NativeTree: native widgets and services as data (§12)
fabrum.app.text_editor TextEditor, TextInput, EditCommand, TextGeometry (§20)
fabrum.app.Keymap      macOS, Windows or Linux editing keys (§20)
fabrum.app.Capabilities  what the platform can do (§20)
fabrum.render         renderers that come with fabrum: Quartz (§19)
fabrum.app.platform    what hosts the app
├── Services, the requests, Reply, IndexReply, CloseReason   the host's services (§19, §20)
├── Option             the build option: native, gtk, qt, sdl, none
├── Kind               appkit, win32, web, gtk, qt, sdl, none
├── option, kind       this build's, at compile time
├── resolve(option, os, arch), implemented(kind), check()
├── current            the namespace of `kind`
├── none               no built-in host: the app drives the runtime (§18); always present
├── appkit             macOS; a compile error elsewhere
└── gtk, qt, sdl, win32, web   compile errors until written
```

**Why `fabrum.app.platform`.** It stays where the Kitchen's design put it, with a wider
meaning:

- A platform is the toolkit: window, loop, menus, dialogs, native controls and the canvas.
  It depends on the app runtime (`App(Root, ...)`, the reconciler's `Backend`), so it
  belongs under `app`. `fabrum.layout` stays free of it.
- A top-level `fabrum.platform` would suggest layout-only users need it, which they don't.
- `native` is the contract every platform implements, so it is named for what it
  describes, not for any one platform.
- `widgets`, `menus` and `dialogs` are what apps call, so they sit at `app.*`, next to
  `Ui`. Apps never reach into `platform` except for catalogue widgets and `App`.

**`kind` at compile time.** Apps pick widgets per platform with `switch (comptime
fabrum.app.platform.kind)`. `kind` is the *resolved* toolkit (`.appkit`), not the
option (`.native`), because that is what code needs to know:

```zig
switch (comptime app.platform.kind) {
    .appkit => try app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = state.rating }),
    else => try app.widgets.slider(ui, "rating", .{ .value = state.rating, .max = 5 }),
}
```

**The build option** is `-Dplatform=native|gtk|qt|sdl|none`, `native` by default,
chosen per binary and independent of the OS.

- `native` means the OS's own toolkit: AppKit on macOS, Win32 on Windows, the DOM on
  wasm, and GTK 4 on Linux, the first Linux toolkit.
- `gtk` and `qt` mean those toolkits on any OS they support; `sdl` a portable window
  with drawn widgets.
- `none` means no built-in host: the app's own code drives the runtime, every widget is
  drawn, and a portable renderer draws into pixels (§18). It links nothing, so it builds
  for any target. There is no separate headless platform: the spike's headless backend
  was a fake native widget tree for tests, and is now `app.testing.NativeTree` (§12).
- fabrum's `build.zig` adds `shell.m` and links AppKit only for `native` on macOS.
- The value reaches the code as the `fabrum_options` module.
- **Only `native` on macOS (AppKit) and `none` exist.** Using `fabrum.app` with any
  other platform, or with `native` on an OS without a backend, is a compile error from
  `platform.check()`: "fabrum: the gtk platform is not implemented yet; build fabrum
  with -Dplatform=none (`.platform = .none`) to host the app yourself with drawn
  widgets". `fabrum.layout` alone builds with any option.
- Namespaces of toolkits not built in are `@compileError`s that name the build's kind.
  Zig analyses declarations lazily, so only code that uses them fails.

Verified: fabrum's tests pass with `native` and with `none`. Build-time tests compile
programs that must fail (gtk, qt, sdl, native for Linux) and check their errors, and
compile layout-only use with `none` for Linux and Windows.

## 11. The common widget set and platform catalogues

**`fabrum.app.widgets`**, the common set: `button`, `checkbox`, `toggle` (a switch),
`slider`, `textField`, `textArea`, `searchField`, `secureField`, `dropdown`, `radioGroup`,
`stepper`, `label`, `progressBar`, `spinner` and `scrollView` (§9). Each is a view helper
over `Ui.native` that takes a key and an options struct with its handlers. Values are
controlled (§4): text, toggles, numbers and, for the two item lists, `Value.selection`
with `Event.select`. Defaults follow the platform: fields, areas, sliders, progress bars
and labels grow to their width.

Without a native backend (the `none` platform, or a harness asked for drawn widgets) each
is drawn instead, with the same options: `fabrum.app.drawn`, which is also the opt-in for
drawn widgets on any platform (§18). Alerts are drawn as a modal box; menu items show
nothing without a menu bar.

The catalogue, each mapping to every platform's own control (built on AppKit and GTK 4
in N2, §21; Win32 is the plan):

| Widget | AppKit | GTK 4 | Win32 (not built) | Drawn (`app.drawn`) |
|---|---|---|---|---|
| `button` | `NSButton` | `GtkButton` | `BUTTON` | rounded box |
| `checkbox`, `toggle` | `NSButton` checkbox, `NSSwitch` | `GtkCheckButton`, `GtkSwitch` | `BS_AUTOCHECKBOX` | box, pill |
| `slider` | `NSSlider` | `GtkScale` | `TRACKBAR_CLASS` | track and knob, drags |
| `textField` | `NSTextField` | `GtkEntry` | `EDIT` | `TextBox` with an editor inside |
| `textArea` | `NSTextView` in `NSScrollView` | `GtkTextView` in `GtkScrolledWindow` | multi-line `EDIT` | `TextBox`, wrapping, scrolling |
| `searchField`, `secureField` | `NSSearchField`, `NSSecureTextField` | `GtkSearchEntry`, `GtkPasswordEntry` | edits with styles | `TextBox` with a magnifier and clear button; bullets per grapheme |
| `dropdown` | `NSPopUpButton` | `GtkDropDown` | `COMBOBOX` (drop-down list) | a button opening `Update.menu` |
| `radioGroup` | radio `NSButton`s in one view | grouped `GtkCheckButton`s in a `GtkBox` | `BS_AUTORADIOBUTTON` | rings in a column or row |
| `stepper` | `NSStepper` + `NSTextField` | `GtkSpinButton` | `UPDOWN_CLASS` + edit | a field with − and + |
| `label` (wrapping, selectable) | `NSTextField` label | `GtkLabel` | `STATIC` | text under the ancestors' width |
| `progressBar`, `spinner` | `NSProgressIndicator` bar, spinning | `GtkProgressBar`, `GtkSpinner` | `PROGRESS_CLASS`, marquee | bar; dots turning |
| `scrollView` | `NSScrollView` | `GtkScrolledWindow` | a scrolling child window | runtime-owned offset |

Widgets that don't exist on every platform stay out of the common set (`datePicker` waits
for Win32's `DATETIMEPICK_CLASS` to be worth it).

**Labels and width limits.** A native label is measured under the width its box will get
(`Content.limit = .ancestors`: the nearest ancestor with a fixed width or a finite maximum,
less the padding on the way, looking through parents that fit or grow without a bound and
stopping at an axis that scrolls), so it wraps there before sizing, and its content can be
squeezed below its one-line width (`measure_min`); a one-line label is cut with an ellipsis
at the limit. AppKit measures with `cellSizeForBounds:`, GTK with `gtk_widget_measure`
for that width, the fake tree at seven points a character. The drawn `label` gives its
text the same limit. Other content keeps its parent's limit, as before, since content that
fills its limit (a picture scaled to fit) must not take the window's width.

**Catalogues.** Each platform namespace has a `widgets` with its full catalogue: the
common set re-exported, plus what only it has. A catalogue widget is a
`native.Spec.extension`: a `*const ExtensionClass`, which belongs to the platform and
which its backend recognises by address, plus type-erased props.
`ExtensionClass.of(Props, name, placement)` gives deep equality, copies and frees for
plain props. The spike's example is `appkit.widgets.levelIndicator` (`NSLevelIndicator`,
rating style), shown on the Kitchen's last row. On other platforms the Kitchen falls back
to a slider through `kind`. In tests on macOS, the fake native tree keeps the extension
as data like any other widget.

## 12. Testing native widgets: `app.testing.NativeTree`

`fabrum.app.testing.NativeTree` is native widgets as plain data. It is not a platform:
programs never run on it, but tests of apps built for any platform drive it:

- a list of `Widget`s, each with its spec, value, frame, marked text and counts of updates,
  writes and frame changes;
- the focus target;
- the last scene presented;
- a theme;
- `full_keyboard_access`.

It measures close to AppKit's regular controls and follows macOS's conventions where
platforms differ. User actions (`click`, `insert`, `replace`, `compose`, `commit`,
`slide`) change a widget as the toolkit would, and return the `Event` to deliver.

`app.testing.Harness` runs native widgets in one (`h.tree`), on every OS and for every
platform. New helpers, each followed by a frame, as before:

```zig
h.root().native("name")                       // a native element's Id, as ui.nativeId gives it
h.widget(id), h.expectWidget(id)              // the widget: spec, value, frame, counts
h.clickNative(id), h.selectMenu(id)           // press, flip, focus a field, choose an item
h.typeText(id, "Ada"), h.setText(id, "...")   // one event per code point, or one replace
h.compose(id, "に"), h.commit(id, "日本")      // IME pre-edit and commit
h.submit(id), h.slide(id, 0.75), h.respond(id, 1)
h.tab(), h.shiftTab(), h.pressSpace(), h.expectFocused(h.root().element(key))
h.runtime.scene(), h.runtime.reconciler().stats
```

`expectFocused` checks fabrum's focus and that the tree agrees about where keys go.
`app.testing.rootInstance(Root)` gives scripts the same element lookups in a real app.

Tests (`src/app/hybrid_test.zig`, and the Kitchen's `kitchen.zig`) cover:

- creation, measuring and placing;
- no backend calls for an unchanged frame;
- clicks, toggles and slides;
- typing without writes;
- the model rewriting text;
- held writes during composition;
- prop updates, kind replacement and destruction;
- keyed reordering;
- Tab order with and without full keyboard access;
- modal scopes;
- layer splitting, with clips;
- menus, alerts and the theme;
- resize moving only the views that change;
- `error.NoNativeBackend`.

## 13. The AppKit platform

`fabrum.app.platform.appkit` moves the Kitchen's shell into fabrum, keeping
`appkit/shell.m` behind a narrow C ABI, as the earlier analysis recommended. Objective-C
gives ARC, blocks and `NSTextInputClient`-shaped structs for free. The Zig half
implements `native.Backend` over it, and `App(Root, Renderer)` runs a root component in
a window:

```zig
const gui = try gpa.create(appkit.App(Kitchen)); // canvas drawn with fabrum.render.Quartz
try gui.init(gpa, io, .{}, .{ .title = "Kitchen", .width = 800, .height = 700 }, .{ .provide = provide });
gui.run(); // noreturn
```

`appkit.AppWith(Root, Renderer)` takes another renderer for `.cg_context` surfaces.

- **Views:** `FabrumWindow` (Tab routing), `FabrumHostView` (flipped content view; frames
  on resize; tracking), `FabrumCanvasView` (one per canvas layer; draws through the app's
  renderer; hit-tests by `Layer.hits`; takes keys while a drawn element has focus).
- **Controls:** subclasses of `NSButton` (push and checkbox), `NSSwitch`, `NSSlider`,
  `NSLevelIndicator`, `NSTextField` and `NSProgressIndicator`. Each carries its element's
  ID and reports focus from `becomeFirstResponder`. One target receives every action.
  Text fields are their own delegate (changes, Tab, Return).
- **Menus and alerts:** `NSMenuItem`s in menus made on demand, and `NSAlert` sheets.
- **Re-entrancy:** events AppKit reports while fabrum runs a frame are queued by the
  runtime and delivered after it (§2).
- **Scroll views:** `FabrumScrollView` (an `NSScrollView` with a flipped
  `FabrumDocumentView`), §9.
- **Shell:** `NSOpenPanel`, `NSPasteboard`, `windowShouldClose:` and
  `applicationShouldTerminate:` (§19).
- **Automation** for debug scripts, all in process: `performClick:`, field-editor
  `insertText:` / `setMarkedText:` / `insertNewline:`, the key-view loop, choosing menu
  items, answering alerts, resizing, AppKit's own `hitTest:`, a dump, and snapshots. Only
  `windowClick` and `windowKey` send events, through the app's own window, and need an
  unlocked session.

**Snapshots.** `cacheDisplayInRect:` on the content view **does capture layer-backed
native controls**: buttons, checkbox, switch, slider, fields, progress bar and level
indicator, as well as marked text with its IME highlight. It does **not** capture:

- alert sheets, which are separate windows;
- the caret, focus rings and the default button's colour, because a window in a locked
  session is never key, so controls draw in their inactive look.

## 14. GTK 4 and others

**Built (N2, §21):** `fabrum.app.platform.gtk`, `native` on Linux and `gtk` anywhere
GTK 4 is, with `fabrum.render.Cairo` as its canvas. The contract ported without change:

- **Host view.** The window's child is a `GtkOverlay`: fabrum's base canvas (a
  `GtkDrawingArea` that fills it, whose `resize` runs a frame) under a `GtkFixed` that
  holds GTK's widgets and the upper canvas layers at fabrum's frames (`gtk_fixed_put`,
  `gtk_fixed_move`, `gtk_widget_set_size_request`), in paint order
  (`gtk_widget_insert_after`). A scroll view is a `GtkScrolledWindow` whose child is a
  `GtkFixed` document sized to the content, with a base canvas of its own; its
  adjustments' `value-changed` report `Event.scroll`.
- **Measure:** `gtk_widget_measure`, horizontal then vertical for that width; a label
  under the width limit.
- **Events:** `clicked`, `toggled`, `notify::active`, `value-changed`, `changed`,
  `activate`, `notify::selected`, the buffer's `changed`, each handler carrying the
  object. Writes block their handler, so GTK's `changed` on `gtk_editable_set_text` isn't
  reported (the runtime's queue would take it anyway, §2).
- **Composition:** `GtkText`'s and `GtkTextView`'s `preedit-changed` (the input method's
  pre-edit, from `GtkIMContext`): while one is up `composing` holds writes and changes
  aren't reported; its end reports the text and `composition_end`. Unverified with a real
  input method (no key events are posted).
- **Pointer input** is decided in the capture phase on the overlay (`GtkGestureClick`,
  `GtkEventControllerMotion`, `GtkEventControllerScroll`): a press on an upper canvas
  layer where it drew something (`hit_layer`), or on a canvas with no widget above it, is
  claimed for fabrum; the rest is denied, so the widget there takes it. Upper canvases
  aren't targetable themselves. The wheel over a document's canvas goes to fabrum and on
  to the scrolled window.
- **Focus:** `gtk_widget_grab_focus`; `canFocus` is `gtk_widget_get_focusable` and
  sensitive (GTK's Tab reaches every control, so the theme reports full keyboard access).
  A key controller on the window, capture phase, takes Tab and Shift-Tab for fabrum's
  chain, and Space and Return while the base canvas has focus. `notify::has-focus`
  reports focus gained.
- **Menus:** the application menu bar is a `GMenu` of submenus made on demand, items as
  `GSimpleAction`s with `<Primary>` accelerators (Command on macOS, Control elsewhere),
  set at `startup`. Declared alerts and `confirm` are `GtkAlertDialog` (`choose`, with a
  `GCancellable` to dismiss); `message` the same with one button and a timeout; `menu` a
  `GtkPopoverMenu` built from a `GMenu` (headers as section labels, separators as
  sections, disabled actions, submenus), parented to the host, pointing at the point,
  answered by its action or `closed`; `openFile` a `GtkFileDialog` with a suffix filter;
  the clipboard `GdkClipboard` (`read_text_async`, answered through the `Reply`); closing
  `close-request` asks `shouldClose(.quit)` (one window); quitting `g_application_quit`.
- **Theme:** `gtk_widget_get_color` for the text, the style context's named colors
  (`accent_bg_color`, `window_bg_color`, `view_bg_color`, `borders`; deprecated since
  4.10 but present), the font size from `gtk-font-name` (points at 96 dpi), the control
  height from a measured `GtkButton`, dark from `gtk-application-prefer-dark-theme`. The
  canvas's text takes the toolkit's font family (`Cairo.setDefaultFamily`).
- **Snapshots:** the overlay's `GtkWidgetPaintable` into a `GtkSnapshot`, its render
  node drawn with `gsk_render_node_draw` into a Cairo image, widgets included.
- **Linking:** GTK, Pango and Cairo through pkg-config (`-Dplatform=gtk`; on macOS with
  Homebrew's GTK, Homebrew's `pkgconf` must be first on `PATH` so the `.pc` files'
  private requirements resolve), each library named once, since dyld refuses a dylib
  linked twice. IME, accessibility (AT-SPI), the clipboard and portals come with GTK.

Win32 maps the same way: child `HWND` controls, `WM_COMMAND` and `WM_NOTIFY`, `WM_SIZE`,
`IsDialogMessage` for Tab, and Direct2D canvas layers. On the web, the controls are DOM
elements absolutely positioned by fabrum, with `<canvas>` layers between them by
z-index.

## 15. The duplicate-instance trap

Zig makes one instance of a dependency per set of arguments **as passed**. If an app
passes `.platform = ...` to fabrum while the Quartz renderer asks for fabrum with only
`.target` and `.optimize`, two fabrum modules end up in one program:

```
error: file exists in modules 'fabrum' and 'fabrum0'
```

Reproduced on the `hybrid` Kitchen by removing the fix and building with
`-Dplatform=native`.

**(a) Override the renderer's import (the spike's fix).**

```zig
const quartz_mod = quartz_dep.module("fabrum-renderer-quartz");
quartz_mod.addImport("fabrum", fabrum_mod); // `put` replaces the renderer's own
```

It works: one line, in the app's `build.zig`. The Kitchen also passes `-Dplatform` on
only when given. But every app that sets a fabrum option must know to do this, for every
package that depends on fabrum, and the error doesn't point at the cause.

**(b) Fold the Quartz renderer into the AppKit platform**, as its canvas. Done in N1
(§19): `fabrum.render.Quartz`, and `appkit.App(Root)` needs no renderer.

- The canvas is already AppKit's: `FabrumCanvasView` hands a `CGContextRef` to whatever
  draws. The renderer needs only system frameworks the platform already links (Core
  Graphics, Core Text).
- **Text measured by Core Text is what native controls use.** Drawn and native text then
  measure and render alike, which the hybrid look depends on.
- `App(Root)` loses its duck-typed `Renderer` parameter: `flipCanvas`, `renderCommands`,
  `Text` and `text_context` become the platform's own.
- The common case (an app, fabrum and its platform) then has one package and no trap. The
  trap remains only for third-party packages depending on fabrum, which (a) documents.
- Each platform brings its own canvas the same way: Cairo for GTK, Direct2D for Win32,
  Canvas2D for the web. Custom renderers (ThorVG) stay separate packages for apps that
  want identical pixels everywhere, behind the same layer interface.
- Cost: fabrum grows by the renderer's code, about 1,900 lines of Zig and Objective-C,
  compiled only for `native` on macOS.

**(c) Inject fabrum into renderer packages (built).** Portable renderers (ThorVG, z2d)
stay separate packages, and don't depend on fabrum except lazily, for their own tests.
Their public module imports `fabrum` without providing it; the app gives it the one it
uses:

```zig
// the app's build.zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
renderer.addImport("fabrum", fabrum);
```

```zig
// the renderer's build.zig.zon: fabrum only for its tests
.fabrum = .{ .path = "../zig-layout", .lazy = true },
// its build.zig: only when it is the root package
if (b.isRoot()) if (b.lazyDependency("fabrum", .{ ..., .platform = .none })) |dep| mod.addImport("fabrum", dep.module("fabrum"));
```

There is then one fabrum per program by construction. Forgetting the `addImport` is a
plain "no module named 'fabrum'" error from the renderer. ThorVG's `test/consumer` is an
app built this way with `.platform = .none`, as its own package, from the renderer's
`zig build test`; the Kitchen's `kitchen-none` is another.

## 16. What happens to the Kitchen's `input-design.md`

| Section | Fate | Why |
|---|---|---|
| 1. Kitchen inventory | **Changes** | Editors, slider, progress, checkbox, switch and buttons become native; the gradient, rings, the drawn strip and the dialog stay drawn. The percent bug is fixed on `trunk` (`7fd3763`). |
| 2. Principles and layering | **Survives, amended** | Rules 1–4 and 6 hold. Rule 5 ("platforms translate, they don't decide") now also covers native controls, which decide their own key handling. The layering table gains the native contract. |
| 3. Element events | **Survives** for drawn elements; native events use `Handlers` (§2) | Same pattern: handlers are values, events become messages. |
| 4. Scrolling | **Built for drawn content (P2)**; **replaced** for native pages | Pages scroll in a native scroll view where there is one (§9). Drawn scroll containers have runtime-owned offsets, chaining, latching, clamping, a thumb, `scrollInfo`, `scrollTo` and `scrollIntoView` (§20). Fling is not built. |
| 5. Dragging and capture | **Built (P2)** | `on_pointer` captures with press, drag, release, cancel and long press, a threshold and click counts (§20). Native sliders still drag themselves. |
| 6. Keyboard and focus | **Built for drawn elements (P2)** | `Focus` declarations with filters, routing to the focused element, its text input, its ancestors, `ui.shortcut` and the runtime; Space and Enter on release; `focusVisible`; `ctx.focus`/`blur` (§20). Native controls handle their own keys. |
| 7. Text input and editing | **Stage 1 built for drawn fields (P2)** | `app.TextEditor`, `TextInput`, `EditCommand`, the keymaps, carets and selection, undo, the clipboard, `textField`/`textArea`/`textEditor`, `Runtime.textInput` (§20). IME (stage 2) and bidi are not built. Native fields keep the controlled-value rule (§4). |
| 8. Animation and timed frames | **Built (P2)** | `ui.every`, `ui.after`, `ctx.now()`, the caret blink through `ui.frameAt`; off where `Capabilities.animation` isn't `full`. |
| 9. Drawing gaps | **Survives, lower priority** | Still needed for drawn content (gradient strip, arcs). Also found: borders are drawn inside the box (`BorderWidths.outside` isn't outside), which hid a focus ring over a fill. |
| 10. Disabled scope | **Survives, extended** (not built) | It must also set native `enabled` and take natives out of the chain. |
| 11. `fabrum.app.platform` | **Changes** | "Level: AppKit widgets not used" and "Linux: raw X11/Wayland" are reversed: the platform is the toolkit, GTK 4 is the first Linux target, Qt later. The bool option becomes the enum. The `Surface` union becomes canvas layers the platform provides. The shell move (Phase B step 1) is done on `hybrid`. "Keep `shell.m`" survives. Dialogs and menus move into the contract. |
| 12. Testing without a window | **Built (P2)** | The harness has native helpers (§12) and `press`, `hold`, `type_`, `command`, `textInput`, `drag`, `longPress`, `scroll`, `scrollInfo`, `answerDialog`, `chooseMenuItem`, `enterText`, capabilities and services options (§20). |
| 13. Over-fitting | **Mostly survives** | Hit-testing, hover, clicks, keys and contexts hold. Children/`View` props still wanted. "Widen IDs to 64 bits" is done: layout units and native elements share one 64-bit ID. |
| 14. Decisions | **Mostly resolved** by the user | `!void` updates, children props, 64-bit IDs, close/quit hooks, the disabled scope and focus-on-click are agreed. Scroll ownership and text editing are now drawn-only questions. zg is needed only for drawn editors. |
| 15. Phase B plan | **Reordered** | See the report's proposed plan. |

## 17. Risks and open questions

- **Native containers (§9)** are scroll views only; split views, tab views and boxes would
  follow the same path.
- **Clipping:** native views ignore drawn clips; put them in a native container.
- **Redraws:** a present redraws only the canvas layers that changed, and only where
  (§21). GTK redraws a changed layer whole (`gtk_widget_queue_draw`).
- **Hit regions** are rectangles.
- **Accessibility:** native controls are accessible for free. Drawn content needs the
  canvas to expose `NSAccessibilityElement` children from fabrum's element IDs (§13 of
  the old design). The mixed tree's order must follow fabrum's paint order.
- **Measurement with constraints:** labels honour `max_width` (§11); other native views
  still ignore the constraints, as they don't wrap.
- **Two sources of truth for focus:** fabrum's `focus` and the first responder are kept
  in step through `becomeFirstResponder` and `focus()`. A control that takes focus some
  other way (an accessibility client) still reports through `becomeFirstResponder`, but
  resignations aren't reported yet.
- **Look:** verified in a key window with real input (§19).

## 18. The `none` platform: the app's own host

`-Dplatform=none` means no built-in host. The app's own code drives the runtime: input
in; render commands and changed regions out; every widget drawn; a portable renderer
draws into pixels. It links no OS UI library, so it builds for any target, and it is what
two future uses need:

- a **VNC reverse proxy** that shows a fabrum interface over (or instead of) a remote
  screen: RFB input arrives as X11 keysyms and pointer events, with no IME, and only
  changed rectangles go back to the client;
- **overlays drawn into games or other apps**, as Steam's and Discord's are: a present
  hook drives frames, the overlay's texture is redrawn only when something changed, and
  input goes through to the game unless the overlay took it.

### The host contract

`fabrum.app.platform.none` documents it, with a pseudocode loop. In short:

| Step | Call | Notes |
|---|---|---|
| Input | `rt.mouse(event) !bool`, `rt.key(event) !bool` | Return whether the app took the event; the host passes on the rest. |
| Clock | `rt.frame(Root, props, viewport, now)` | `now` is the host's clock; views read `ui.now()`. Returns the commands (also `rt.commands()`). |
| When | `rt.nextFrame() ?Timestamp` | Null: wait for input or a post. The last frame's time: due now (something changed, a message waits, or a view called `ui.animate()`). A later time: `ui.frameAt(t)`. |
| What changed | `rt.damage() ![]const Rect` | Regions changed since the host last asked; the whole viewport the first time and after a resize. |
| Pixels | `layout.draw(&renderer, commands, .pixels, pixels, damage)` | Premultiplied RGBA or BGRA. Only the damage is cleared and redrawn. |
| Present | the host's | Composite the damage over what is under the overlay, upload it, or send it as RFB rectangles. |

**What the app takes.**

- A pointer event is taken when the pointer is over something of the app: anything but
  the root that paints there (a background, a border, content such as text) or takes input
  there (`on_click`, `on_pointer`, `focusable`), not clipped away. The rest of a press that
  began over the app is the app's too, wherever the pointer goes, so a drag that leaves
  the overlay isn't half-delivered to the game.
- Keys are taken only while a drawn element has focus: Tab and Shift-Tab move focus,
  Escape clears it, Space and Enter click the focused element; releases follow their
  press. Other keys aren't taken yet (P2). Without focus nothing is taken, so an overlay
  never steals the game's keys until something of it is clicked. Focus comes from a press
  on an element declared `focus_on_press` (drawn text fields), or from the host calling
  `rt.focusMove`. A press on nothing of the app clears drawn focus.
- `platform.none.keyFromX11Keysym` maps RFB keysyms to keys.

### Errors

`update` may return `!void`. An error comes back from the call that delivered the
message: `frame` for queued messages (before any view runs), or the input call
(`mouse`, `key`, `nativeEvent`, `activateFocused`). Nothing is rolled back: the state
is as far as `update` got, and the failing message is consumed; the messages after it
stay queued for the next call. `ctx.emit` returns its error, for `update` to `try`; the
deferred error is gone.

### Drawn widgets

`app.widgets` draws its controls when the runtime has no native backend
(`ui.hasNativeWidgets()`), with the same options, in the look of the provided
`native.Theme` (always provided now: the backend's, or `Runtime.Options.theme`). They
draw, hover and press, and respond to clicks: checkboxes and switches flip, a slider
jumps to where it was clicked and drags (§20), text fields and areas edit (§20), an
indeterminate progress bar animates with `ui.animate()`.

`app.testing.Harness` shows widgets as the build's platform does (drawn on `none`,
native in the fake tree elsewhere), unless a test asks with `.widgets = .native` or
`.drawn`, so native-widget tests run on any platform.

### Renderers

`fabrum.layout` has one renderer interface:

```zig
pub const Surface = union(enum) {
    pixels: struct { data: []u8, width: u32, height: u32, stride: u32, format: PixelFormat },
    cg_context: *anyopaque,
};
// a renderer provides:
pub const Text = ...;                                 // a layout.text.Content(...) type
pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
pub fn render(self: *Self, commands: []const RenderCommand, surface: Surface, damage: ?[]const Rect) !void
```

`layout.draw(&renderer, commands, .kind, target, damage)` checks at compile time that the
renderer accepts the kind of surface: "fabrum: the renderer X doesn't draw into
.cg_context surfaces; it accepts .pixels". `PixelFormat` is `rgba8_premultiplied` or
`bgra8_premultiplied`. A renderer draws each command inside its box, give or take
`Damage.margin_default` points, borders inside the box, and with damage clears and
redraws only those regions from the commands that touch them.

- **Quartz** (`.cg_context`, `fabrum.render.Quartz`, §19): AppKit's canvas layers draw
  through `layout.draw`; `shell.m` flips the context to fabrum's coordinates first. With
  damage it clips to the regions.
- **ThorVG** (`.pixels`): points ThorVG at each damaged region alone (ThorVG clears its
  target before drawing).
- **z2d** (`.pixels`, new, pure Zig): draws each region into a scratch surface, clipping
  through layers, and copies it in.

**The `.none` default is z2d**; ThorVG stays a supported alternative. Measured with the
Kitchen's `kitchen-none` (800x700, ReleaseFast, Apple silicon; `-Drenderer=z2d|thorvg`):

| | z2d | ThorVG 0.15 |
|---|---|---|
| Language | pure Zig | C++ (libc++), C API |
| Cross-compiles (`x86_64-linux-musl`, `x86_64-windows-gnu`) | yes, seconds | yes, minutes (libc++ and ThorVG built per target) |
| Full frame | 7.0 ms | 1.1 ms |
| A hover's damage (~1500 px) | 41 µs | 9 µs |
| `kitchen-none`, ReleaseSmall, macOS / Linux / Windows | 0.60 / 0.67 / 0.96 MB | 0.81 / 1.20 / 1.37 MB |
| Text | TrueType/OpenType/TTC, kerning and GPOS, font metrics and advances | TrueType, no metrics in the C API (ink bounds only; sizes at 96 dpi) |
| SVG | paths only (no parser yet) | full SVG loader, Lottie |
| License | MPL-2.0 (file-level) | MIT |

Both anti-alias rounded rectangles and borders alike at this size, and both pass the
damage check on every step. z2d wins for `.none` because it builds anywhere with
plain `zig build`, is smaller, and has the font metrics and advances that drawn text
editing (P2: carets, selection, hit-testing) needs, which ThorVG 0.15's C API doesn't
give. Its speed is enough for damage-driven hosts (partial redraws are tens of µs;
whole frames happen on resizes and full-screen dialogs). ThorVG is the choice where
raw speed, SVG or Lottie matter more than the C++ toolchain.

### Damage

`layout.Damage` summarises each frame's commands as paint entries: a hash of what a
command draws (kind, colors, radii, widths, box, the clip in force, its content's
`fingerprint`) and the pixels it can touch (its box cut by its clips, rounded out, grown
by the margin). It matches two frames' entries in order: the common start and end, then
hashes unique to both frames kept in increasing order (the longest increasing
subsequence), grown over equal neighbours. Unmatched entries, old and new, are damaged;
overlapping regions merge, and at most 16 are returned.

It is correct because a pixel is a function of the commands that touch it, in order: an
increasing matching keeps matched commands in the same order, so a pixel no unmatched
command touches is unchanged. Content without a fingerprint never matches.

Limits: it is per command, not per pixel (a hover damages the whole button); a moved
command damages both places; reordering many commands damages them all; it trusts
renderers to draw within the margin. Text content has a fingerprint (its string and
style), so the same text in a new frame arena matches.

Tests: unit tests of each case, a randomised test (300 edits with moves, reorders,
inserts, deletions and clips) that redrawing only the damage gives the same pixels as
redrawing everything, the same check through the runtime with drawn input, through each
renderer, and on every step of `kitchen-none`.

### 64-bit element IDs

Layout unit IDs are 64 bits, the full hash of (instance, key), and are also native
elements' IDs. A test finds two keys whose IDs agree in their low 32 bits and checks they
are distinct elements.

## 19. N1: real input, Quartz in fabrum, containers and the shell

### Real input on AppKit

Checked with real HID events (CGEvents posted to the HID event tap) and real window
captures (`screencapture -l`), with positions from fabrum's own layout and native frames
(`KITCHEN_LAYOUT_FILE`), mapped through the window frame from CGWindowList, below the
title bar. Before each input the session was checked unlocked, the Kitchen frontmost and
nothing of another app over the point. Captures are in
`/tmp/kitchen-snapshots/real-hybrid/`; the driver is `/tmp/fabrum-work/driver/`.

| What | Result |
|---|---|
| Native button, checkbox and switch clicks | their messages: Green → Blue, Transform on, "enabled" |
| Dragging the native slider | 0.3 → 0.81, progress following |
| Typing into the line editor (real key codes) | text arrives; Uppercase writes back mid-typing; Return submits |
| Japanese IME (Kotoeri romaji, selected for the run and restored) | composition, conversion with the candidate list (captured), commit by Return without submitting; also with Uppercase on |
| Tab and Shift-Tab | line editor → Uppercase → three radio buttons → Open dialog → notes → rating, and back, with focus rings in a key window |
| Drawn modal over the native field | a real click at the field's place hits the dialog; typing doesn't reach the field; Tab stays inside |
| ⌘K, a menu-bar click, the alert sheet | the alert appears both ways (sheet captured) and real clicks answer it |
| Resizing by the window's corner | content follows, 800x700 → 640x580 and back |
| Scrolling the page (§9) | wheel events scroll it natively, clamped at the end; native frames stay put; a native button and a drawn row scrolled into view take real clicks; Tab onto a button below the window scrolls it into sight |

No fabrum bug was found. In a plain `NSTextField` too, Kotoeri needs two Returns after a
Space conversion (the first closes the candidate list), and its next composition was
once left in romaji in both apps: the input method's behaviour, not fabrum's.

### Quartz inside fabrum

`fabrum.render.Quartz` is the Quartz renderer, moved in with its history (a patch series
of its 13 commits). Its Objective-C is now plain C on Core Foundation, Core Graphics and
Core Text: no AppKit, so it draws into any `CGContext`. fabrum compiles it always with
AppKit (`native` on macOS), and with `-Dquartz=true` (`.quartz = true`) on macOS with
other platforms, for drawing into a PDF or bitmap context with `none`; off by default
there, so `none` links nothing and cross-builds without the SDK's frameworks. Using it
without the option is a compile error that says how to get it.

Checked against the old AppKit code: the same fonts, identical widths, and black text
identical pixel for pixel. Line heights are now AppKit's default line height (the ascent,
descent and leading each rounded), as native labels use; text takes the context's fill
color, like rectangles (the old calibrated `NSColor` drew 0,122,255 as 0,145,255).
Colors are explicit sRGB since N2 (§21).

### The shell

`fabrum.app.platform.Shell` is what a host does beyond its window. Every entry is optional
and requests fail with `error.Unsupported` where a host has none:

```zig
// in update
try ctx.openFile(.{ .message = "Choose an image", .extensions = &.{ "img", "iso" } }, ctx.handler(.chosen)); // ?[]const u8
try ctx.writeClipboard(text);
try ctx.readClipboard(ctx.handler(.pasted)); // ?[]const u8
try ctx.quit(); // without asking again
// in a view, while closing would lose something
if (state.unsaved) ui.guardClose(on.handler(.close_requested)); // platform.CloseReason
```

- Answers arrive through `platform.Reply` (a handler and the poster), from any thread, now
  or later; their text is copied, and the message borrows it until `update` has run.
- The host asks `Runtime.shouldClose(.window or .quit)` before closing; with a guard
  declared it says no and sends the guard's handler the reason.
- AppKit: `NSOpenPanel` sheet with `UTType` filters, `NSPasteboard`,
  `windowShouldClose:` and `applicationShouldTerminate:` (asking once: closing the window
  has asked for the quit that follows). GTK 4 would use `GtkFileDialog`, `GdkClipboard`
  (asynchronous reads, which `Reply` allows) and `close-request`. On `none` the host passes
  its own `Shell`, or none, and calls `shouldClose` itself.
- `NativeTree` is a fake shell; `Harness.chooseFile` and `Harness.requestClose` drive it.
  The AppKit side was checked in process (a private pasteboard, the panel shown and
  answered through automation, close and quit held for the alert): no real input.

## 20. P2: drawn interaction, services, capabilities, surfaces and refresh

The second checkpoint of the portable track: what the `.none` platform's drawn widgets
needed to be usable (the staged subset of the Kitchen's `input-design.md`, now for drawn
widgets), and what an external platform package built on `.none` (the InkView package,
P3) needs from fabrum's core without fabrum knowing it. Everything here is built and
tested unless marked **(not built)**.

### Keys and focus

```zig
pub const KeyEvent = struct {
    key: Key,                      // the layout's meaning: .{ .char = 'a' }, .tab, .enter, .left, .{ .f = 5 }, ...
    physical: Physical = .unknown, // USB HID names: .key_a, .digit_1, .bracket_left, ...
    phase: enum { press, repeat, release } = .press,
    modifiers: Modifiers = .{},    // shift, control, alt, super, caps_lock
    text: []const u8 = "",         // what the key types, if the host knows; borrowed
};
pub const Focus = struct {         // Ui.Container.focus; makes the element focusable
    on_key: ?Handler(KeyEvent) = null,
    keys: KeyFilter = .default,    // typing, navigation, function, tab, escape, commands
    on_focus: ?Handler(bool) = null,
    on_text: ?Handler(TextInput) = null, // a text input
};
pub const Shortcut = struct { key: Key, modifiers: Modifiers = .{}, shortcut: bool = false };
try ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true }, on.bind(.save));
ui.focused(key); ui.focusVisible(key);           // focus; focus from the keyboard, for rings
ctx.focus(key); ctx.blur();                      // from update
rt.key(event) !bool; rt.focusMove(.next); rt.focusVisible()
```

- **Routing** of a press or repeat, while a drawn element has focus: the focused element's
  `on_key` if its filter admits the key; the focused text input (the keymap's edit command,
  or the key's text); the ancestors' `on_key`; the frame's shortcuts; then the runtime's
  own: Tab and Shift-Tab move focus (and scroll it into view), Escape clears it, Space and
  Enter click an `on_click` **on release**, as native buttons do. The answer to the host
  comes from the declarations, before any `update` runs. Without focus nothing is taken,
  so an overlay never steals the game's keys (§18). A release is taken when its press was.
- **Filters** leave shortcuts (Control or Command held) out by default, so a text-like
  element doesn't swallow Cmd-S; `KeyFilter.all` takes everything, as a code editor would.
- **Shortcuts on non-Latin layouts** match the physical key's US character when the layout
  types no Latin letter on it, as AppKit's key equivalents do (checklist 7): Cmd-C on a
  Russian layout copies. The keymaps do the same for Ctrl-A, C, V, X, Z.
- **Focus rings** show for focus reached by the keyboard or `ctx.focus`, not by a press
  (`focusVisible`, CSS's `:focus-visible`). `on_focus` is told on gain and loss, including
  when the element goes away (its handler is kept from the frame that declared it).
- The native path is unchanged: native controls keep their own keys, and the chain is one.

### Pointer and drag

```zig
pub const Pointer = struct {
    phase: enum { press, drag, release, cancel, long_press },
    local: Vec2, size: Vec2,       // from the element's box in the last frame
    position: Vec2, buttons: MouseEvent.Buttons, modifiers: KeyEvent.Modifiers,
    clicks: u8,                    // 1, 2, 3
};
MouseEvent: + scroll_phase (none, began, changed, ended), modifiers, long_press: bool
rt.cancelPointer()                 // the host lost the pointer
Runtime.Options.drag_threshold = 4, .multi_click = 500 ms
```

A press on the nearest `on_pointer` element captures the pointer: drags past the threshold
(which cancel the pending click), the release wherever it is, a `cancel` from
`rt.cancelPointer` or the element going away, and a `long_press` when the host reports one
(`MouseEvent.long_press`; InkView's `EVT_POINTERLONG`; AppKit doesn't send one), which also
cancels the click. Click counts go up for presses within the threshold and `multi_click`
of the last. The drawn slider drags, and steps with the arrow keys. Drags mark the
frame's refresh `interactive`.

**Touch pans (P3).** When `Capabilities.pointer` is `touch`, a press that reaches a drawn
scroll container before any `on_pointer` element latches to it: past the drag threshold
the press is a pan, the click it would have made is cancelled (a tap without movement
still clicks, as does a press that moves less than the threshold), and each drag scrolls
the container by how far the finger moved, what it can't absorb going to its scrolling
ancestors, as the wheel's leftover does. The gesture stays with the container it began
in, wherever the finger goes, until the release or `rt.cancelPointer`. A clickable
element inside the list (a row's button) doesn't stop the pan, as touch platforms do; an
`on_pointer` element nearer than the container (a slider, a text field's selection) owns
the gesture instead. Pans mark the frame `interactive`, and a scroll container counts as
"something of the app" for touch presses. Mouse pointers don't pan. There is no fling:
e-ink doesn't want one, and the platforms with momentum send their own.

### Scrolling

```zig
pub const Scroll = struct { x: bool = false, y: bool = true, scrollbar: bool = true, on_scroll: ?Handler(ScrollInfo) = null };
pub const ScrollInfo = struct { offset: Vec2, viewport: Vec2, content: Vec2, box: Vec2; fn max() Vec2 };
try ui.open("list", .{ .scroll = .{ .y = true }, ... });   // or app.widgets.scrollView
ui.scrollInfo(key) ?ScrollInfo
ctx.scrollTo(key, .start | .end | .{ .offset = v } | .{ .by = v }, .{ .refresh = .content | .interactive }); ctx.scrollIntoView(id)
rt.scrollInfo(id)
```

- The offset is the runtime's, keyed by element ID, kept while the container is declared
  and swept with it, applied as the clip's `child_offset` so hit-testing stays in viewport
  coordinates. Scroll containers clip both axes (content overflowing the axis that doesn't
  scroll is hidden rather than holding the container open).
- The wheel goes to the innermost scroll container under the pointer; what it can't absorb
  goes on to its scrolling ancestors (Gio's `clampSplit`). A trackpad gesture
  (`scroll_phase`) stays latched to the container it began in. Offsets clamp to the
  content after layout; content that shrinks under a scrolled view is clamped on the next
  frame, which the runtime asks for.
- An overlay thumb floats at the container's edge along each scrolling axis whose content
  overflows (at least 20 points long, wider under the pointer); the runtime drags it, by
  the track's share of the content. The theme colors it; grayscale displays get it black.
- Focus moved by the keyboard scrolls into view; `scrollIntoView` walks every scroll
  ancestor. A pure scroll damages the container's box alone (the clips bound the moved
  commands), marked `interactive`. A finger pans drawn scroll containers (above). Fling
  and momentum of the runtime's own are **(not built)**: macOS sends its own momentum,
  and e-ink doesn't want any.
- `scrollTo` takes `ScrollOptions`: its `refresh` is the hint the frame gets, `content`
  by default (a page key's step or a jump wants a quality refresh on e-ink), or
  `interactive` when the scroll follows a gesture of the app's own. The target doesn't
  decide it: a page key's `by` wants quality where a pan's wants speed.
- A transparent scroll container isn't "something of the app" for presses, so an overlay's
  page still lets clicks through between its widgets, while the wheel scrolls it.

### `TextEditor` and the text widgets

```zig
pub const TextEditor = struct {           // app.TextEditor, owned by the app's state
    text: ArrayList(u8), selection: Selection, affinity: Affinity, preedit: ?Preedit, generation: u64, ...
    pub fn apply(self, gpa, input: TextInput, env: Env) !Outcome;  // Outcome: changed, selection_changed, submitted, copy, paste
    pub fn setText(self, gpa, text) !void;                        // bumps generation, clears the history
    pub const Options = struct { single_line: bool = false, max_len: ?usize = null };
    pub const Env = struct { now: Timestamp, options: Options, geometry: ?*const TextGeometry };
};
pub const TextInput = union(enum) { commit, paste, set, replace, select, preedit, command: EditCommand };
pub const EditCommand = union(enum) { move: Move, delete: Delete, insert_newline, insert_line_break, insert_tab, insert_backtab,
    select_all, select_word, select_paragraph, undo, redo, copy, cut, paste, transpose, kill_to_line_end, yank, cancel };
pub const Keymap = enum { macos, windows, linux };  // Runtime.Options.keymap; the platform's by default; a root value
ctx.textEnv(options); ctx.editText(&editor, input, options, on_paste) !Outcome  // applies, and serves the clipboard
rt.textInput(input) !bool                          // committed text from hosts without keys

// the widgets
try app.widgets.textField(ui, "line", .{ .text = state.line.items, .on_change = ..., .on_submit = ... }); // an editor inside, reporting text
try app.widgets.textArea(ui, "notes", .{ .text = ..., .on_change = ..., .sizing = .{ .width = .grow(.{}), .height = .fixed(60) } });
try app.drawn.textEditor(ui, "field", &state.editor, .{ .on_input = on.handler(.input), .single_line = true }); // the app's editor
```

- **Offsets** are byte offsets on grapheme boundaries (zg's `Graphemes`); words skip
  spaces and punctuation (zg's `Words` on 64-bit targets, see below). Vertical and
  line-edge moves use the field's `TextGeometry`: its visual lines as the layout wrapped
  them and the renderer measured them, which the field's view records each frame
  (`ui.textGeometry`) and `ctx.textEnv` hands the editor; `affinity` picks the side of a
  soft wrap (checklist 12).
- **Undo** groups coalesce typing, and end on a caret move, another kind of edit, over a
  second's pause, or a new word after a space (checklist 9); each restores its selection.
- **Carets and selections** are rectangles the widget floats over the text, at positions
  from prefix measurement with the renderer's text context (z2d's advances; Quartz's
  `CTLineGetTypographicBounds` of the prefix, with `CTLineGetOffsetForStringIndex` a
  **TODO** for ligatures and kerning). Hit-testing picks the nearer half of a grapheme. The
  caret blinks through `ui.caretVisible`, which asks for the frame of the next flip,
  restarts on input, stops after ten seconds idle, and stays on where the platform
  doesn't animate.
- **Wrapping** in a text area happens at the field's inner width of the last frame (the
  layout wraps text only under a width it knows before sizing), and a size change asks
  for one more frame. The caret is kept in view by scrolling the field's own scroll
  container before the frame lays it out.
- **The clipboard** goes through the services, or, without one, a clipboard private to the
  program, so cut and paste still work within it (InkView has none). A multi-line paste
  into a single-line field becomes spaces and never submits (checklist 8).
- **Hosts without keys** deliver text with `rt.textInput(.{ .commit = text })` (RFB text,
  InkView's `OpenKeyboard` result as `.set`). A field asks for the platform's modal text
  entry (`ctx.systemText`) when pressed where `Capabilities.keyboard` is `on_screen`.
- The `widgets.textField` on `.none` keeps its editor inside and follows the controlled
  rule of §4: the app's text goes in only when it differs from what the field last
  reported or was given. So the Kitchen's line editor works unchanged on `.none`, Uppercase
  rewriting included.
- **32-bit targets.** zg 0.18.0's word tables don't build for a 32-bit `usize`
  (`micro_runeset.zig` indexes with a `u64`), so there words are runs of letters and
  digits between spaces and punctuation, which agrees with UAX #29 on Latin text.
  Graphemes come from zg everywhere. A fix belongs upstream.

### Timers

```zig
try ui.every("tick", .fromSeconds(1), on.bind(.tick));     // while declared; keyed, keeps its phase
try ui.after("toast", .fromSeconds(3), on.bind(.hide));     // once, unless the view stops declaring it
ctx.now()
```

Timers fire at the start of the frame they are due in, which `nextFrame` schedules; a
stall fires a periodic timer once, not a burst.

### Services

`platform.Shell` became `platform.Services`, with every entry optional (the table in
`app.platform`):

```zig
pub const Services = struct { ptr, vtable: *const VTable };
pub const VTable = struct {
    message:       ?fn (ptr, *const MessageRequest) Error!void,
    confirm:       ?fn (ptr, *const ConfirmRequest, IndexReply) Error!void,   // up to three buttons
    menu:          ?fn (ptr, *const MenuRequest, IndexReply) Error!void,      // items: header, separator, disabled, submenu
    editText:      ?fn (ptr, *const TextRequest, Reply) Error!void,           // title, initial, flags (url, numeric, password, email, multiline), max_len
    openFile, openDirectory: ?fn (ptr, *const FileRequest, Reply) Error!void,
    writeClipboard, readClipboard,
    quit, close:   ?fn (ptr) void,
};
ctx.message(req); ctx.confirm(req, on_answer); ctx.menu(req, on_choose); ctx.systemText(req, on_text);
ctx.openFile(req, on_path); ctx.openDirectory(req, on_path); ctx.writeClipboard(text); ctx.readClipboard(on_text); ctx.quit(); ctx.close()
```

| Missing | Fallback |
|---|---|
| `message`, `confirm` | a dialog drawn by fabrum, modal: buttons, Enter for the default, Escape dismisses (reply null) |
| `menu` | a menu drawn by fabrum at the point: headers, separators, disabled items, submenus indented; a click outside or Escape dismisses |
| `editText`, `openFile`, `openDirectory`, `quit`, `close` | `error.Unsupported` |
| clipboard | a clipboard private to the program |

Replies are messages, from any thread, now or later (`Reply` carries text, `IndexReply` an
index or `MenuItem.id`). The drawn fallbacks are the runtime's `Overlays` component,
rendered after the root. Checked against AppKit (`NSAlert`, `NSMenu`, `NSOpenPanel`,
`NSPasteboard`; dialogs and menus from `update` aren't wired on AppKit yet, so it draws
them), GTK 4 (`GtkAlertDialog`, `GtkPopoverMenu`, `GtkFileDialog`, `GdkClipboard`) and
InkView (`Message`, `Dialog3` with 1–3 buttons answered 1–3 or −1, `OpenMenu` with
`ITEM_HEADER`, `ITEM_SEPARATOR`, `ITEM_INACTIVE`, `ITEM_SUBMENU` answered by the item's
`index` or −1, `OpenKeyboard(title, buffer, maxlen, flags, callback)` with `KBD_URL`,
`KBD_NUMERIC`, `KBD_PASSWORD` and `NULL` on cancel, a directory list built on `OpenList`,
no clipboard, `CloseApp`). `app.native.Backend` is the public interface an external
package implements for native widgets, passed in `Runtime.Options.native`.

### Capabilities

```zig
pub const Capabilities = struct {
    pointer: enum { mouse, touch, none } = .mouse,
    hover: bool = true,
    animation: enum { full, reduced, none } = .full,
    color: enum { color, gray, gray16, gray4 } = .color,
    keyboard: enum { physical, on_screen, none } = .physical,
};
// Runtime.Options.capabilities (the platform's by default); ui.use(app.Capabilities)
```

Drawn widgets drop hover shading without `hover`, the caret blink and the indeterminate
progress animation without `full` animation, and ask for the system keyboard with
`on_screen`. On a grayscale display the runtime's theme turns high-contrast
(`Theme.highContrast`: black on white, the accent black, nothing translucent), selections
and thumbs are solid, and the caret is two points wide.

### Surfaces

`PixelFormat` gains `gray8` (one opaque byte per pixel, white when cleared; a color's gray
is its luma blended with white by its alpha), `bytesPerPixel()` replaces the constant, and
`Surface.Pixels` gains `scale` (device pixels per point; `packedScaled`, `pointSize`).
Commands and damage stay in points. z2d draws both, with the region drawn in RGBA and
copied out as luma plus the white its coverage left; ThorVG draws at scale and refuses
`gray8`. Tests check that redrawing only the damage matches a full redraw for `gray8` and
at scale 2, in fabrum's test renderer and in z2d.

### Refresh hints

```zig
pub const Refresh = enum { content, interactive, page };
const regions = try rt.damage(); const how = rt.refresh();   // for those regions
ctx.refresh(.page)                                           // from update
```

The strongest hint of the changes since the host last took the damage: `interactive`
during drags and scrolls (the InkView package will map it to `DynamicUpdateA2`, and
`ExitUpdateA2` when it ends), `content` otherwise (`PartialUpdate`), `page` when the app
asks (`FullUpdate`). Other hosts ignore it.

### Testing

`app.testing.Harness` gained `press`, `hold`, `type_`, `command`, `textInput`, `keyEvent`,
`drag`, `dragElement`, `longPress`, `scroll`, `scrollElement`, `scrollAt`, `scrollInfo`,
`focusedElement`, `clipboard`, `answerDialog`, `chooseMenuItem`, `enterText`,
`chooseDirectory`, and the options `capabilities`, `keymap` and `services` (`all`, `basic`
for the drawn fallbacks, `none`). `NativeTree` records dialogs, menus, text entries and
directory choosers as data for tests to answer.

Checklist of `input-design.md` §7.6, stage 1 (cases 3, 4, 6–9, 12, 15):

| # | Case | Status | Test |
|---|---|---|---|
| 3 | Byte vs grapheme offsets | built | `text_editor.zig` "offsets never land inside a grapheme"; the UTF-16 half is stage 2 |
| 4 | Deleting a combining sequence and a ZWJ emoji | built | `text_editor.zig` "one Backspace deletes…" |
| 6 | Arrow key repeat | built | `text_editor.zig` "a repeated arrow…"; `input_test.zig` repeats delivered once each |
| 7 | Shortcuts on non-Latin layouts | built | `input.zig`, `keymap.zig`, `input_test.zig` Ctrl-A/C with `.physical = .key_a/.key_c` |
| 8 | Multi-line paste into the single-line field | built | `text_editor.zig`, `input_test.zig` "an app-owned editor…" |
| 9 | Undo coalescing of typing | built | `text_editor.zig` "typing coalesces…" |
| 12 | Caret at a soft wrap | built | `text_editor.zig` "vertical moves keep their column, and Home and End…" |
| 15 | Hit-testing matches drawing | partly | prefix widths agree with themselves by construction; the Quartz `offsetAtX(caretPositions(n)) == n` test over ligatures waits for the Core Text line API (TODO) |
| 1 | Enter confirms an IME candidate | the second guard built | `text_editor.zig` "Enter during a pre-edit submits nothing"; the IME path is stage 2 |

### The Kitchen on `.none`

`kitchen-none` plays its script in two modes: as an RGBA overlay over a background (clicks
between widgets go through) and as an opaque `gray8` e-ink panel with an e-reader's
capabilities and stand-in services (a system keyboard answering text entries), reporting
the refresh hint per step. The steps now include Tab, typing in both editors (keys with
their text on the overlay, committed text on e-ink), Enter setting the heading, a drag of
the slider, a scroll of the page and back, and the dialog. Every step redraws only the
damage and checks it against a full redraw, in both modes. PNGs go to
`/tmp/kitchen-snapshots/p2/` (`eink-*` for the panel).

Cross-compiled (ReleaseSmall, z2d): `x86_64-linux-musl` 0.85 MB, `x86_64-windows-gnu`
1.14 MB, `arm-linux-gnueabi.2.38 -Dcpu=cortex_a7` (the PocketBook B288: 32-bit ARMv7,
soft-float ABI, `e_flags` 0x05000200) 0.96 MB, statically linked; with ThorVG for ARM
1.19 MB.

### An external platform on `.none`

What an InkView package (P3) would be, with fabrum knowing nothing of it:

```zig
// inkview/src/root.zig: fabrum built with .platform = .none, given by the app
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-z2d");

pub fn App(comptime Root: type) type {
    return struct {
        runtime: app.Runtime(.{ .Text = Renderer.Text }),
        renderer: Renderer,
        pixels: fabrum.layout.Surface.Pixels, // the panel's gray8 framebuffer, scale 1
        in_a2: bool = false,

        pub fn init(self: *@This(), gpa, io) !void {
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
                .services = .{ .ptr = self, .vtable = &services },  // Message, Dialog3, OpenMenu, OpenKeyboard, CloseApp
                .keymap = .linux,                                   // a USB keyboard on the device, if any
            });
        }

        // InkView's handler: its events in, frames out
        fn handler(kind: c_int, par1: c_int, par2: c_int) callconv(.c) c_int {
            switch (kind) {
                EVT_POINTERDOWN => _ = try rt.mouse(.{ .position = at(par1, par2), .pressed = primary }),
                EVT_POINTERMOVE, EVT_POINTERDRAG => _ = try rt.mouse(.{ .position = at(par1, par2), .pressed = primary }),
                EVT_POINTERLONG => _ = try rt.mouse(.{ .position = at(par1, par2), .pressed = primary, .long_press = true }),
                EVT_POINTERUP => _ = try rt.mouse(.{ .position = at(par1, par2) }),
                EVT_POINTERCANCEL => try rt.cancelPointer(),
                EVT_KEYPRESS, EVT_KEYREPEAT => _ = try rt.key(.{ .key = keyFromIvKey(par1), .phase = if (kind == EVT_KEYREPEAT) .repeat else .press }),
                EVT_KEYRELEASE => _ = try rt.key(.{ .key = keyFromIvKey(par1), .phase = .release }),
                EVT_SHOW => self.frameNow(),
                EVT_EXIT => if (!try rt.shouldClose(.quit)) return 1,
            }
            self.frameNow();          // and SetHardTimer for rt.nextFrame()
        }

        fn frameNow(self) !void {
            const commands = try self.runtime.frame(Root, .{}, viewport, clock());
            const damage = try self.runtime.damage();
            if (damage.len == 0) return;
            try fabrum.layout.draw(&self.renderer, commands, .pixels, self.pixels, damage);
            switch (self.runtime.refresh()) {
                .interactive => for (damage) |r| DynamicUpdateA2(r.x, r.y, r.w, r.h),   // and in_a2 = true
                .content => { if (self.in_a2) ExitUpdateA2(); for (damage) |r| PartialUpdate(r.x, r.y, r.w, r.h); },
                .page => FullUpdate(),
            }
        }

        // services: OpenKeyboard's callback sends the buffer, or null on cancel, through the Reply
        fn editText(ptr, request: *const app.platform.TextRequest, reply: app.platform.Reply) !void {
            copy request.initial into a static buffer; OpenKeyboard(title, buffer, maxlen, flagsFrom(request.flags), callback);
            // callback: reply.send(if (text) |t| std.mem.span(t) else null)
        }
        fn confirm(ptr, request: *const app.platform.ConfirmRequest, reply: app.platform.IndexReply) !void {
            Dialog3(icon, title, text, b1, b2, b3, callback); // callback: reply.send(if (n > 0) n - 1 else null)
        }
        fn menu(ptr, request: *const app.platform.MenuRequest, reply: app.platform.IndexReply) !void {
            build an imenu[] from the items (ITEM_HEADER, ITEM_SEPARATOR, ITEM_INACTIVE, ITEM_SUBMENU with index = id); OpenMenu(items, 0, x, y, callback);
        }
        fn quit(ptr) void { CloseApp(); }
    };
}
```

Page keys map to `.page_up`/`.page_down` (or to `ctx.scrollTo` through the app's own
`Focus.on_key`); the device has no clipboard, so the runtime's own serves cut and paste.

### Decisions and open questions

- **Keys carry their text**, unlike the Kitchen design's "key events never carry text":
  `.none` hosts (RFB keysyms, Win32 `WM_CHAR`) know it with the key, and hosts with an input
  method use `rt.textInput`. Both reach the field the same way.
- **The keymap is a runtime option**, provided as a root value, not a context an app
  overrides per subtree.
- **Escape clears focus** rather than mapping to `EditCommand.cancel`, so a key stops an
  overlay's field from holding the game's keys; `cancel` stays in the vocabulary for hosts
  that bind it.
- **The drawn `textField` keeps its editor inside**, so `app.widgets` has one API on every
  platform; `app.drawn.textEditor` is the controlled form from the design.
- **Fling** of the runtime's own, bidi and the IME mirror (stage 2) are **(not built)**.
  The native `textArea` and dialogs and menus from `update` on AppKit were built in N2
  (§21).

## 21. N2: the N1 decisions, the wider widget set, GTK 4 and OpenEtcher

The second checkpoint of the native track. Everything here is built and tested unless
marked **(not built)** or **(unverified)**.

### The N1 decisions

- **sRGB (decision 3).** `fabrum.render.Quartz` sets every fill and stroke color in an
  explicit sRGB color space (`CGContextSetFillColorSpace` and `CGContextSetFillColor`),
  text included, since Core Text takes the context's fill color. A test draws the same
  blue into an sRGB and a Display P3 bitmap: the bytes are the color's own in the first
  (0, 122, 255) and converted in the second (52, 120, 246). Probed on this Mac, Core
  Graphics already treated `CGContextSetRGBFillColor`'s device RGB as sRGB, in bitmaps
  and in the window's backing store (a real capture of the Kitchen showed the drawn accent
  and AppKit's default button at the same (0, 122, 255) with either code), so the change
  is a guarantee rather than a visible fix here: tagged colors mean the same on a
  wide-gamut display and in a PDF or bitmap of any color space.
- **Unchanged canvas layers (decision 5).** `native.CanvasDamage` keeps a `layout.Damage`
  per canvas layer, fed the layer's commands moved by minus its offset (where they draw
  in the layer's view, snapped to 1/256 point as frames are), and reports the regions that
  changed. The AppKit backend marks only those (`setNeedsDisplayInRect:`, flipped into
  the view's coordinates) instead of every canvas on every present; GTK queues the layer.
  The Kitchen's dump counts: three in-process scroll steps of the page left all six layer
  presents alone (`canvas layers presented 8, of which unchanged and not redrawn 6`), and
  a hover on a row redrew the page's layer only. Tests: a layer whose commands only moved
  with its offset is unchanged; a changed row damages its box alone.
- **Reparenting (decision 6).** `Backend.reparent` (optional) moves a view to another
  container; the reconciler calls it when the parent changes and the kind doesn't, resets
  the frame, and counts `stats.reparents`; without it the element is replaced as before.
  AppKit's `arrange` takes a view out of its old parent before putting it in the new one,
  keeping the first responder; GTK's does the same with `gtk_fixed_remove` and
  `gtk_fixed_put`. Test: a text field typed into, declared inside the list and back,
  keeps its handle, its text and its writes count, with no creates or destroys.
- **Dialogs and menus from `update` on AppKit.** `Services.message` and `confirm` are
  `NSAlert` sheets (the default button answering Return; a message with a timeout ends
  its sheet), `menu` an `NSMenu` popup built from the flattened items (section headers
  on macOS 14, separators, disabled items, submenus), opened from the next main-queue turn
  so AppKit's tracking loop never runs inside a call into fabrum, and answered once
  (`menuDidClose:` gives the chosen item's action a turn before reporting null). Checked
  in process in the Kitchen: "Ask…" answered with the third button ("asked 2"), "Menu"
  answered with the submenu's item ("chose 4"); `automation.answerPopup` chooses or
  dismisses.

### The wider common set

§11 has the catalogue. The contract grew `Spec.text_area`, `search_field`, `secure_field`,
`spinner`, `dropdown`, `radio_group`, `stepper` and `label`, `Value.selection`,
`Event.select`, `Handlers.on_select`, `Spec.isTextInput` and `Spec.enabled`. On AppKit:
`FabrumTextArea` (an `NSTextView` in an `NSScrollView`, reporting through
`textDidChange:` unless marked text is up, three lines tall by default), `NSSearchField`
and `NSSecureTextField` sharing the field's delegate implementation, a spinning
`NSProgressIndicator`, `NSPopUpButton`, radio `NSButton`s in one flipped view (exclusive by
AppKit's rule: one superview, one action), an `NSStepper` with a field (typed numbers
clamped to the range), and an `NSTextField` label measured with `cellSizeForBounds:` under
the width limit. The fake tree measures, selects (`Harness.selectNative`), steps
(`stepNative`) and types into each. Without native widgets each is drawn: the dropdown
asks `Update.menu` (the host's menu, or the runtime's drawn one, under the button as laid
out last frame), the secure field shows a bullet per grapheme and maps the caret, the
selection and hit-testing back to the text, the search field has a magnifier and a clear
button, the spinner turns once a second, the label wraps under its ancestors' width.

Tests: `hybrid_test.zig` (native: each control made, measured and driven; the text area
controlled and composing; the label wrapping narrower when its box does; drawn: the same
model driven through the drawn ones; the dropdown through the host's menu service) and
the Kitchen's (native and drawn, the dialog and menu through the fake services and drawn).
The Kitchen's hybrid screen shows them all; snapshots are in `/tmp/kitchen-snapshots/n2/`
(`03-wider-set@2x.png`: the text area with a committed composition, the dropdown,
stepper, radio group, label, search and password fields, the spinner).

### GTK 4

§14 describes what was built. It ran on this Mac against Homebrew's GTK 4.24.1, installed
for the checkpoint (`brew install gtk4`), as `kitchen-gtk` (`zig build -Dplatform=gtk` in
the Kitchen, with Homebrew's `pkgconf` first on `PATH`). The script drove, in process:
every control of the hybrid screen (snapshots in `/tmp/kitchen-snapshots/gtk/`), the page
scrolled with no canvas redrawn, the drawn dialog above the `GtkEntry` (a hit at its
place is `canvas layer 2`), `confirm` and `menu` (a `GtkAlertDialog` and a
`GtkPopoverMenu`, answered), `openFile` (a `GtkFileDialog`, answered), the clipboard
(copy heading, paste into the text area), the menu bar's Say Hello with its alert, Tab
onto a `GtkButton`, and closing held for the question while the line editor has text,
then quitting. Contract changes it forced: none. The Cairo renderer measures and draws
text with Pango in the toolkit's family, so drawn text matches the labels.

**Unverified:** real input (no events are posted, as agreed), so hover, drags of
`GtkScale`, keyboard navigation inside widgets and the input method's pre-edit are
untested; `GtkFixed` gives a child at least its natural size, so a `GtkLabel` wider than
its frame overflows rather than truncating; a `GtkLabel`'s default font looked smaller than
the controls' in the snapshot and wasn't chased; `fabrum_gtk_damage_layer` redraws the
whole layer; Linux itself (the spike only ran on macOS; GTK's X11 and Wayland backends
and AT-SPI weren't exercised); the Kitchen's `levelIndicator` falls back to a slider on
GTK, as designed. `fabrum.render.Cairo` draws no pictures (SVG paths, bitmaps) yet, so
the Kitchen's drawn screen and OpenEtcher's icons stay Quartz-only.

### OpenEtcher on the AppKit platform

OpenEtcher's `hybrid` branch (a worktree at `fabrum-hybrid/zig-openetcher`) replaces its
own shell (`src/app/platform/macos`, 452 lines of Objective-C and Zig) and the separate
Quartz renderer package with `fabrum.app.platform.appkit.App(ui.App)`: the image is chosen
with `Update.openFile` (the `NSOpenPanel` sheet with the image types), closing or quitting
mid-flash is held by `ui.guardClose` for `Update.confirm` ("Quit while flashing?", an
`NSAlert` sheet; Quit stops the flash through the new `InitOptions.on_terminate` hook, so
the target is left synced), and the icons are `fabrum.render.Quartz.content.Picture`. The
interface keeps Etcher's look, drawn on the canvas; nothing became a native control. Tests:
130 (128 on `trunk`, plus the quit guard), answering the chooser and the dialog through
fabrum's fake services; the debug script answers the real ones through fabrum's
automation, and the layout file is written ten times a second. Snapshots are in
`/tmp/openetcher-gui-shots/hybrid/`; against `v4/` the differences are the test image's
name and size, a hovered button, and the one-pixel line-height change accepted in N1.

The separate `zig-fabrum-renderer-quartz` repo can be retired: nothing depends on it any
more (the Kitchen and OpenEtcher use `fabrum.render.Quartz`, which carries its history).

### Decisions and open questions

- **`Content.limit`** is opt-in per content rather than the layout's rule, because the
  layout's test content, icons and pictures take `max_width` as a size to fill, not a
  bound; making every content inherit its ancestors' width would have scaled them to the
  window. Text in a fit container inside a fixed ancestor therefore still measures as
  one line unless it asks for `.ancestors`, as `drawn.label` does.
- **A one-line native label is cut at its limit** rather than overflowing: the box is the
  limit's width and AppKit truncates with an ellipsis; GTK's `GtkFixed` doesn't
  (unverified above).
- **The Cairo canvas moves commands on the CPU** (`drawLayer` copies them by minus the
  layer's offset) where Quartz translates the context; a `cairo_translate` would do.
- **`reparent` is optional** so an external backend (the InkView package) builds
  unchanged; backends gain nothing by leaving it out except simplicity.
- **Next (N3):** real-input checks of the GTK platform on Linux (or a VM), AT-SPI for
  drawn content, pictures in the Cairo renderer, the Win32 platform's first widgets, a
  GTK catalogue of its own (`GtkCalendar`, `GtkColorDialogButton`), a `datePicker` once
  three platforms have one, multiple windows and the multi-file and save panels deferred
  from N1, and OpenEtcher on GTK once pictures draw there.

### P3: what the InkView package needed

The InkView platform package (an external platform on `.none`, §20) found three gaps,
fixed here:

- **Touch pan-to-scroll** for drawn scroll containers (§20, "Touch pans"): the package
  had declared `on_pointer` on its list and called `ctx.scrollTo(.{ .by = … })` from each
  drag; the runtime pans now, so the app declares nothing.
- **`scrollTo`'s refresh hint** (§20, "Scrolling"): it marked the frame `content`
  always, so a scroll the app drove from a gesture was a quality refresh. It takes
  `ScrollOptions` now, `.{ .refresh = .interactive }` for such a scroll; the default
  stays `content`, which the package's page keys want (a partial update of the list
  rather than a fast one followed by a cleaning flash). Chosen over deriving the hint
  from the target (`by` → `interactive`) because the same `by` means a page key or a
  pan, and only the app knows which.
- **Layout capacity errors.** `layout.Context` hit `unreachable` when a frame outgrew
  `Context.Config` (`units`, `depth`, `breadth`, the children buffer), so a list one row
  too long for `breadth` crashed the app. `openContainer*`, `appendContent*` and `spacer`
  return `error.LayoutCapacity` now, after a `std.log.err` naming the limit and the
  `Config` field that raises it (outside test builds, whose runner counts error logs as
  failures); the layout is left as it was, so the fast path is one check per unit. The
  error comes out of `frame` through `Ui.open`, `text` and `print`; `Ui.spacer` and
  `Ui.content` keep returning nothing, so the runtime notes their failure and fails the
  frame with it after the view. The next frame starts over, as a failed view's does.
