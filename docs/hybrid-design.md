# Hybrid layering: fabrum with native controls

Status: spike, on the `hybrid` branches of fabrum (`zig-layout`), the Kitchen
(`zig-fabrum-kitchen`) and the Quartz and ThorVG renderers, then the first checkpoint
(P1) of the portable track: the `.none` platform, drawn widgets, the renderer interface
and damage (§18), then the first checkpoint (N1) of the native track: real-input checks,
Quartz inside fabrum, queued native events, native scroll containers and the shell hooks
(§19). Written against what was built and ran. Parts that are designed but not built are
marked **(not built)**.

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
  destroyed before their container (in `finish` and `deinit`); an element that moves to
  another container is replaced. Frames are in the parent's content coordinates (§9).
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
- Every present redraws every canvas layer.

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
- **Drawn fallback.** Without native widgets, `scrollView` is a clipped container that
  doesn't scroll yet (`app.drawn.scrollView`): drawn scrolling, with a runtime-owned
  offset, is to come.

Verified with `NativeTree` (`hybrid_test.zig`: frames in document coordinates, content
size, scrolling and clamping, a drawn row and a native button clicked after scrolling,
the scene's containers and layer offsets, teardown order) and on AppKit with real wheel
events and clicks (§19).

## 10. Namespaces and the build option

```
fabrum.app.native      the contract (§2): Backend, Spec, Value, Event, Scene, Theme
fabrum.app.widgets     the common widget set (§11)
fabrum.app.menus       menu bar items, declared
fabrum.app.dialogs     alerts, declared (file dialogs later)
fabrum.app.testing     Harness, and NativeTree: native widgets as data (§12)
fabrum.render         renderers that come with fabrum: Quartz (§19)
fabrum.app.platform    what hosts the app
├── Shell, FileRequest, Reply, CloseReason   the shell's services (§19)
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
`slider`, `textField`, `progressBar`. Each is a view helper over `Ui.native` that takes a
key and an options struct with its handlers. Values are controlled (§4). Defaults follow
the platform: fields, sliders and progress bars grow to their width.

Without a native backend (the `none` platform, or a harness asked for drawn widgets) each
is drawn instead, with the same options: `fabrum.app.drawn`, which is also the opt-in for
drawn widgets on any platform (§18). Alerts are drawn as a modal box; menu items show
nothing without a menu bar.

Breadth to add next, each mapping to every platform's own control:

| Widget | AppKit | GTK 4 | Win32 |
|---|---|---|---|
| `textArea` | `NSTextView` in `NSScrollView` | `GtkTextView` in `GtkScrolledWindow` | multi-line `EDIT` |
| `dropdown` | `NSPopUpButton` | `GtkDropDown` | `COMBOBOX` (drop-down list) |
| `radioGroup` | `NSButton` radio style | `GtkCheckButton` groups | `BS_AUTORADIOBUTTON` |
| `datePicker` | `NSDatePicker` | `GtkCalendar` in a popover | `DATETIMEPICK_CLASS` |
| `stepper` | `NSStepper` + field | `GtkSpinButton` | `UPDOWN_CLASS` + edit |
| `label` (selectable, wrapping) | `NSTextField` label | `GtkLabel` | `STATIC` |
| `scrollView` | `NSScrollView` | `GtkScrolledWindow` | a scrolling child window |
| `searchField`, `secureField` | `NSSearchField`, `NSSecureTextField` | `GtkSearchEntry`, `GtkPasswordEntry` | edits with styles |
| `spinner` | indeterminate `NSProgressIndicator` (spinning) | `GtkSpinner` | marquee progress |

Widgets that don't exist on every platform stay out of the common set.

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

The contract was written to fit GTK 4 without change:

- **Host view.** A `GtkFixed` (or a custom `GtkWidget` whose `size_allocate` places
  children at fabrum's frames) holds native widgets and canvas layers, each a
  `GtkDrawingArea` drawn with Cairo, stacked in child order.
- **Measure:** `gtk_widget_measure`, which takes the constraint fabrum passes.
- **Events:** GTK signals (`clicked`, `toggled`, `value-changed`, `changed`, `activate`),
  connected to one handler carrying the element's ID.
- **Composition:** `GtkIMContext`'s `preedit-start` and `preedit-end` on a `GtkText`, for
  `composing`.
- **Focus:** `gtk_widget_grab_focus`. GTK's own Tab handling is overridden through the
  window's `move-focus` signal, or the host's `focus` vfunc.
- **Menus:** `GMenu` with `GAction`s (the application menu bar). Alerts are `GtkAlertDialog`.
- **Theme:** the style context's named colors (`accent_bg_color`, `window_bg_color`,
  ...), read through `gtk_widget_get_color`, or libadwaita's style manager.
- **Linking:** GTK must be linked (or `dlopen`ed) on Linux, which the earlier "raw
  X11/Wayland" design avoided. IME, accessibility (AT-SPI), clipboard and portals come
  with it.

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
| 4. Scrolling | **Deferred** for drawn content; **replaced** for pages | Pages and lists scroll in a native scroll view (§9), with platform momentum and scrollers. Runtime-owned offsets, chaining and fling are only for drawn scroll areas, which can wait. `Unit.content_size` and clipped-axis sizing are still needed, now for native scroll views. |
| 5. Dragging and capture | **Deferred** | Native sliders drag themselves. Capture is for drawn custom widgets later. |
| 6. Keyboard and focus | **Changes** | Focus is one chain across native and drawn (§6), with modal scopes. Native controls handle their own keys. `Runtime.key` is only for the canvas. Shortcuts become native menu items with key equivalents (`menus.item(.key)`) rather than `ui.shortcut`. |
| 7. Text input and editing | **Deferred, drawn only** | Native fields and text views do editing, IME, clipboard and undo. The design stays valid for a future drawn editor. The controlled-value rule (§4) replaces "controlled text through `app.TextEditor`" for native fields. |
| 8. Animation and timed frames | **Survives, smaller** | Still needed for ticking models (progress) and drawn animation. Native indeterminate progress and spinners animate themselves. |
| 9. Drawing gaps | **Survives, lower priority** | Still needed for drawn content (gradient strip, arcs). Also found: borders are drawn inside the box (`BorderWidths.outside` isn't outside), which hid a focus ring over a fill. |
| 10. Disabled scope | **Survives, extended** | It must also set native `enabled` and take natives out of the chain. |
| 11. `fabrum.app.platform` | **Changes** | "Level: AppKit widgets not used" and "Linux: raw X11/Wayland" are reversed: the platform is the toolkit, GTK 4 is the first Linux target, Qt later. The bool option becomes the enum. The `Surface` union becomes canvas layers the platform provides. The shell move (Phase B step 1) is done on `hybrid`. "Keep `shell.m`" survives. Dialogs and menus move into the contract. |
| 12. Testing without a window | **Survives, extended** | The harness gained native helpers (§12). Key and text helpers wait for drawn editors. |
| 13. Over-fitting | **Mostly survives** | Hit-testing, hover, clicks, keys and contexts hold. Children/`View` props still wanted. "Widen IDs to 64 bits" is done: layout units and native elements share one 64-bit ID. |
| 14. Decisions | **Mostly resolved** by the user | `!void` updates, children props, 64-bit IDs, close/quit hooks, the disabled scope and focus-on-click are agreed. Scroll ownership and text editing are now drawn-only questions. zg is needed only for drawn editors. |
| 15. Phase B plan | **Reordered** | See the report's proposed plan. |

## 17. Risks and open questions

- **Native containers (§9)** are scroll views only; split views, tab views and boxes would
  follow the same path. Drawn scrolling isn't built.
- **Clipping:** native views ignore drawn clips; put them in a native container.
- **Redraws:** every present redraws every canvas layer, and a scroll asks for a frame,
  so a long document's canvas is redrawn on each scroll step. Damage (§18) could skip
  layers whose commands didn't change.
- **Hit regions** are rectangles.
- **Accessibility:** native controls are accessible for free. Drawn content needs the
  canvas to expose `NSAccessibilityElement` children from fabrum's element IDs (§13 of
  the old design). The mixed tree's order must follow fabrum's paint order.
- **Measurement with constraints:** wrapping native labels need `measure` to honour
  `max_width`.
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
`native.Theme` (always provided now: the backend's, or `Runtime.Options.theme`). So far
they draw, hover and press, and respond to clicks: checkboxes and switches flip, a slider
jumps to where it was clicked (through `on_pointer`, which delivers presses with where
they landed), a text field takes focus and shows a caret, an indeterminate progress bar
animates with `ui.animate()`. Dragging, typing and keys are P2.

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
