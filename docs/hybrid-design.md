# Hybrid layering: fabrum with native controls

Status: spike, on the `hybrid` branches of fabrum (`zig-layout`), the Kitchen
(`zig-fabrum-kitchen`) and the Quartz renderer. Written against what the spike
built and ran. Parts that are designed but not built are marked **(not built)**.

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
9. [Native containers (not built)](#9-native-containers-not-built)
10. [Namespaces and the build option](#10-namespaces-and-the-build-option)
11. [The common widget set and platform catalogues](#11-the-common-widget-set-and-platform-catalogues)
12. [The headless platform and testing](#12-the-headless-platform-and-testing)
13. [The AppKit platform](#13-the-appkit-platform)
14. [GTK 4 and others](#14-gtk-4-and-others)
15. [The duplicate-instance trap](#15-the-duplicate-instance-trap)
16. [What happens to the Kitchen's `input-design.md`](#16-what-happens-to-the-kitchens-input-designmd)
17. [Risks and open questions](#17-risks-and-open-questions)

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
| `Id` | A native element's identity: the full 64-bit hash of (instance, key). Its low 32 bits are the layout unit's ID, until layout IDs widen too. |
| `Handle` | The backend's reference to one native object, opaque to fabrum. |
| `Spec` | What an element is, with its non-value props: `button`, `checkbox`, `switch`, `slider`, `text_field`, `progress`, `menu_item`, `alert`, and `extension` for platform catalogues. Deep `eql`, `clone`, `free`, `sameKind`, `placement`. |
| `Value` | The user-changed, model-controlled value: `none`, `toggle`, `number`, `text`. |
| `Event` | What the user did: `activate`, `toggle`, `number`, `text` (not sent while composing), `submit`, `focus`, `composition_end`, `response`. |
| `Handlers` | The `Handler`s an element fires, one per kind of event (`on_activate`, `on_toggle`, `on_number`, `on_text`, `on_submit`, `on_response`). |
| `Element` | One declaration: `spec`, `value`, `handlers`, and the box's `sizing`. |
| `Scene` | Bottom-to-top slots of canvas layers and native views, and each layer's commands and hit regions (§5). |
| `Theme` | The platform's colors and metrics (§8). |
| `Backend` | The vtable a platform implements. |

### The backend vtable

```zig
pub const VTable = struct {
    create:    fn (ptr, id: Id, spec: *const Spec, value: *const Value, parent: ?Handle) Error!Handle,
    update:    fn (ptr, handle, old: *const Spec, new: *const Spec) void, // apply what differs
    destroy:   fn (ptr, handle) void,
    setFrame:  fn (ptr, handle, frame: Rect) void,        // parent coordinates, top left
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
- **Focus** and **z-order** are covered in §6 and §5. `parent` is reserved for native
  containers (§9).

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

The same cases are headless tests (`hybrid_test.zig`, `kitchen.zig`).

**IME notes.** AppKit's field editor (`NSTextView`, an `NSTextInputClient`) does all of
the IME work: marked text, candidates, the caret rectangle. fabrum only needs
`hasMarkedText`. Composition was driven with `setMarkedText:selectedRange:replacementRange:`
and `insertText:replacementRange:`, the calls an input method makes. A real input method
(Kotoeri, Pinyin) was not tried, because the session was locked. With native fields,
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
  drawn scroll area would spill out. Fixing that needs native containers (§9), which are
  clip views.
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
  checkboxes are skipped, as the headless default does. Drawn widgets can follow the same
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
- **Not built:** file dialogs, which are asynchronous and return a value. They fit as
  dialogs that are declared and answered (`on_response: Handler([]const u8)`, borrowed),
  or as commands from `update`. The same goes for context menus, and for shell hooks that
  veto close or quit (`should_close`), which the user agreed earlier. Notifications, the
  clipboard and drag-and-drop belong to the platform too, and aren't built.

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

## 9. Native containers (not built)

A native scroll view (or split view, tab view, box) is a native element **with children**:
fabrum lays out its content as a sub-layout, in the container's content coordinates.

- `Ui.nativeOpen(key, element)` / `close()` open a container element. Children declared
  inside are created with `parent` = the container's content view handle. Their frames are
  set relative to the container's content origin (the reconciler subtracts the
  container's content box).
- A scroll view's content size is its children's extent. That needs
  `layout.Unit.content_size` and clipped-axis sizing (input-design §4 "Layout
  responsibilities"), so content can be taller than the view. The scroll offset stays the
  native view's: fabrum doesn't apply `child_offset`, because the platform scrolls the
  document view itself, with momentum, rubber-banding and scrollers for free.
- Drawn content inside a native container needs its own canvas layer **inside** the
  container's document view, so the scene becomes a tree. Each native container gets its
  own slots.
- This is also how native views get clipped (§5): a clip view is a native container.

This is the largest unbuilt piece, and the riskiest. It needs layout support that
doesn't exist, and it turns the scene into a tree.

## 10. Namespaces and the build option

```
fabrum.app.native      the contract (§2): Backend, Spec, Value, Event, Scene, Theme
fabrum.app.widgets     the common widget set (§11)
fabrum.app.menus       menu bar items, declared
fabrum.app.dialogs     alerts, declared (file dialogs later)
fabrum.app.platform    the toolkit
├── Option             the build option: native, gtk, qt, headless
├── Kind               appkit, win32, web, gtk, qt, headless
├── option, kind       this build's, at compile time
├── resolve(option, os, arch)
├── current            the namespace of `kind`
├── headless           always present (tests, layout-only use)
├── appkit             macOS; a compile error elsewhere
└── gtk, qt, win32, web   compile errors until written
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

**The build option** is `-Dplatform=native|gtk|qt|headless`, `native` by default.

- `native` means the OS's own toolkit: AppKit on macOS, Win32 on Windows, the DOM on
  wasm, and GTK 4 on Linux, the first Linux toolkit.
- fabrum's `build.zig` adds `shell.m` and links AppKit only for `native` on macOS.
- `headless` links nothing. It is the layout-only and CI option, and works on any OS.
- The value reaches the code as the `fabrum_options` module.
- Namespaces of toolkits not built in are `@compileError`s that name the build's kind.
  Zig analyses declarations lazily, so only code that uses them fails.

Verified: fabrum's tests pass with `native` and with `headless` (70/70 each). The
Kitchen's interface tests pass with `-Dplatform=headless`, where only they build
(15/15).

## 11. The common widget set and platform catalogues

**`fabrum.app.widgets`**, the common set: `button`, `checkbox`, `toggle` (a switch),
`slider`, `textField`, `progressBar`. Each is a view helper over `Ui.native` that takes a
key and an options struct with its handlers. Values are controlled (§4). Defaults follow
the platform: fields, sliders and progress bars grow to their width.

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
rating style), shown on the Kitchen's last row. On headless builds the Kitchen falls back
to a slider through `kind`. In tests on macOS, the headless backend keeps the extension
as data like any other widget.

## 12. The headless platform and testing

`fabrum.app.platform.headless` is native widgets as plain data:

- a list of `Widget`s, each with its spec, value, frame, marked text and counts of updates,
  writes and frame changes;
- the focus target;
- the last scene presented;
- a theme;
- `full_keyboard_access`.

It measures close to AppKit's regular controls and follows macOS's conventions where
platforms differ. User actions (`click`, `insert`, `replace`, `compose`, `commit`,
`slide`) change a widget as the toolkit would, and return the `Event` to deliver.

`app.testing.Harness` always runs on it, on every OS. New helpers, each followed by a
frame, as before:

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

`expectFocused` checks fabrum's focus and that the platform agrees about where keys go.
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
const gui = try gpa.create(appkit.App(Kitchen, Quartz));
try gui.init(gpa, io, .{}, .{ .title = "Kitchen", .width = 800, .height = 700 }, .{ .provide = provide });
gui.run(); // noreturn
```

- **Views:** `FabrumWindow` (Tab routing), `FabrumHostView` (flipped content view; frames
  on resize; tracking), `FabrumCanvasView` (one per canvas layer; draws through the app's
  renderer; hit-tests by `Layer.hits`; takes keys while a drawn element has focus).
- **Controls:** subclasses of `NSButton` (push and checkbox), `NSSwitch`, `NSSlider`,
  `NSLevelIndicator`, `NSTextField` and `NSProgressIndicator`. Each carries its element's
  ID and reports focus from `becomeFirstResponder`. One target receives every action.
  Text fields are their own delegate (changes, Tab, Return).
- **Menus and alerts:** `NSMenuItem`s in menus made on demand, and `NSAlert` sheets.
- **Re-entrancy:** AppKit calls that report events while fabrum runs a frame (for example
  a view leaving the window) are dropped and logged. The spike saw none.
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

**(b) Fold the Quartz renderer into the AppKit platform**, as its canvas. Recommended.

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
  compiled only for `native` on macOS. ThorVG keeps building against fabrum as today.

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
| 13. Over-fitting | **Mostly survives** | Hit-testing, hover, clicks, keys and contexts hold. Children/`View` props still wanted. "Widen IDs to 64 bits" has started: native elements use 64-bit IDs. |
| 14. Decisions | **Mostly resolved** by the user | `!void` updates, children props, 64-bit IDs, close/quit hooks, the disabled scope and focus-on-click are agreed. Scroll ownership and text editing are now drawn-only questions. zg is needed only for drawn editors. |
| 15. Phase B plan | **Reordered** | See the report's proposed plan. |

## 17. Risks and open questions

- **Native containers (§9)** are unbuilt, and need layout work (`content_size`,
  clipped-axis sizing) and a scene tree.
- **Clipping:** native views ignore drawn clips until then.
- **Real IME and real input** were driven only in process (`setMarkedText:`,
  `insertText:`, `performClick:`, the key-view selectors), because the session was
  locked. Real keyboard events through `keyDown:`, a real input method, and real mouse
  routing to native views versus canvas layers should be checked by hand, or with the
  script's `nsclick` and `key` steps in an unlocked session.
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
- **Re-entrancy:** events during a frame are dropped. Queueing them would be safer than
  dropping.
- **Look:** in a locked session the window is never key, so snapshots show controls in
  their inactive look. Verify the key-window look by hand.
