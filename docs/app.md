# The app runtime: `fabrum.app`

`fabrum.app` is an Elm-architecture (TEA) runtime on top of `fabrum.layout`.
An app is a tree of components; each frame every view runs from the root
down and rebuilds the layout from scratch; state changes only in `update`,
in response to messages. This document is the reference for writing
components. The names are the real ones: when in doubt, the doc comments in
`src/app.zig` and `src/app/*.zig` are the source of truth.

```zig
const fabrum = @import("fabrum");
const app = fabrum.app;
```

Contents: [components](#components), [views and the `Ui`
builder](#views-and-the-ui-builder), [messages and
handlers](#messages-and-handlers), [`update` and its
context](#update-and-its-context), [concurrency](#concurrency), [contexts](#contexts), [the widget
set](#the-widget-set), [menus and dialogs](#menus-and-dialogs), [pointer
input](#pointer-input), [focus and keys](#focus-and-keys),
[scrolling](#scrolling), [text editing](#text-editing), [timers and
animation](#timers-and-animation), [capabilities and
theme](#capabilities-and-theme), [refresh hints](#refresh-hints), [closing
and quitting](#closing-and-quitting), [the runtime](#the-runtime),
[testing](#testing).

## Components

A component is a type (a namespace) in one of two shapes:

```zig
// stateless: a view function with its own element keys
const Badge = struct {
    pub const Props = struct { label: []const u8 };
    pub fn view(ui: *app.Ui, props: Props) !void { ... }
};

// stateful: state that persists across frames, changed by messages
const Counter = struct {
    pub const State = struct { count: i32 = 0 }; // optional `deinit(gpa)`
    pub const Msg = union(enum) { increment, decrement }; // optional, with `update`
    pub const Props = struct { step: i32 = 1, on_change: ?app.Handler(i32) = null };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Counter)) !void { ... }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void { ... }
};
```

The rules, checked at compile time with an error that says which is broken:

- `Props` and `view` are required. `view` returns `!void`.
- `State` makes the component stateful; `view` then takes `*const State`.
  `State` must have defaults for every field: an instance's state is made
  with them the first time it is rendered.
- `Msg` and `update` come together, and only with `State`. `update`
  returns `!void`, or `void` if it can't fail.
- `State.deinit(gpa)` and `Msg.deinit(gpa)`, if declared, free what they
  own.

Both shapes are rendered the same way, with `ui.child(C, key, props)` or
`ui.one(C, props)`, so a parent can't tell them apart, and a stateless
helper can be promoted to a stateful component without touching its callers.

**Instances and keys.** Each rendered component is an instance identified by
a hash of its parent instance, its type and the key it was rendered with.
Repeated children need distinct keys, as React list keys; rendering the same
component twice with one key under one parent is `error.DuplicateKey`. A
stateful instance's state is created on its first frame and destroyed after
the first frame that doesn't render it (calling `State.deinit`). Stateless
instances store nothing. Element keys (`ui.open(key, ...)`) are scoped to
the instance, so they only need to be unique within one instance of one
component.

**The root.** The root component is given to `Runtime.frame` (or a
platform's `App(Root)`) with its props each frame. `Runtime.rootState(Root)`
reads its state, for tests and debugging.

## Views and the `Ui` builder

Every `view`, and every helper it calls, takes the same `*app.Ui`. Views
read state and props and describe elements; they never change state.

### Containers

```zig
try ui.open("panel", .{
    .layout = .{ .axis = .y, .sizing = .grow(.{}), .padding = .all(10), .child_gap = 8, .child_alignment = .center_left },
    .background_color = .rgba(255, 255, 255, 200),
    .corner_radius = .uniform(6),
    .border = .{ .color = .gray(200), .widths = .outside(1) },
    .on_click = on.bind(.open),
});
defer ui.close();
```

`ui.open(key, container)` opens a container in the one currently open;
`ui.close()` closes the most recent one. `key` is a string, an integer, an
enum or any hashable value, or `null` for an anonymous container, which can
have no events. `container` is a `Ui.Container`: every field of
`layout.ContainerDeclaration` except `id`, plus the runtime's own.

| Field | Type | Meaning |
|---|---|---|
| `layout` | `layout.Config` | `sizing`, `padding`, `child_gap`, `child_alignment`, `axis` (`.x` by default). See [layout.md](layout.md). |
| `background_color` | `Color` | Transparent by default. |
| `corner_radius` | `layout.CornerRadius` | `.uniform(r)` or per corner. |
| `border` | `.{ .color, .widths }` | `widths` is a `layout.BorderWidths`: `.outside(w)`, `.all(w)` (with `between_children`), or per side. |
| `floating` | `layout.ContainerDeclaration.FloatingConfig` | Takes the element out of the flow and attaches it to its parent, the root or another unit. |
| `clip` | `ClipConfig` | Clips overflow per axis, with a `child_offset`; `scroll` sets it for you. |
| `aspect_ratio`, `overflow`, `user_data` | | As in `layout.ContainerDeclaration`. |
| `on_click` | `?app.Action` | Queued when the element is clicked, or activated with Space or Enter while focused. Clicks bubble: a click on a label goes to the nearest keyed ancestor with an `on_click`. |
| `on_pointer` | `?app.Handler(app.Pointer)` | Takes the primary press over the element and then every drag, long press and release wherever the pointer goes. |
| `focusable` | `bool` | Joins the Tab order. Needs a key. |
| `focus_on_press` | `bool` | Pressing the element focuses it, as text fields do. |
| `focus` | `?app.Focus` | What the element does with keys while focused; also makes it focusable. |
| `scroll` | `?app.Scroll` | Makes the element a scroll container whose offset the runtime keeps by key. |
| `cursor` | `?app.Cursor` | The cursor over the element (`default`, `pointer`, `text`); clickables show `pointer` by default. |
| `modal` | `bool` | A modal scope: while declared, the Tab order is only what is inside the last one, and focus outside moves into it. |

Other things a view puts in the open container:

| Call | What it adds |
|---|---|
| `ui.text(string, style)` | Text, copied into the frame arena; `style` is a `layout.text.Style` (font family, weight, size, line height, wrap, overflow, alignment, color). It wraps at the width its box gets, beside its siblings, in a growing container or not (`layout.Content.limit` is `.ancestors`). |
| `ui.print(style, fmt, args)` | Formatted text; values with a `format` method print with `{f}`. |
| `ui.fmt(fmt, args)` | A string in the frame arena, for a label passed to a helper. |
| `ui.spacer()` | Empty space that grows along the container's axis, pushing what is before and after apart. |
| `ui.content(*layout.Content)` | Any content (a picture, a custom measure); it must live until the frame's commands are consumed, so allocate it in `ui.arena()`. |
| `ui.child(C, key, props)` | A child component. |
| `ui.one(C, props)` | A child that appears once in this view: `child(C, {}, props)`. |
| `ui.native(key, element)` / `ui.nativeOpen(key, element, inside)` | A native element or container; `app.widgets` wraps these. |

### Reading the frame

| Call | Returns |
|---|---|
| `ui.hovered(key)`, `ui.pressed(key)` | Whether the pointer is over the element (or a descendant), or pressed on it, as of the last input event. |
| `ui.focused(key)`, `ui.focusVisible(key)` | Whether the drawn element has focus; whether it got it by keyboard, so a ring should show (CSS `:focus-visible`). |
| `ui.scrollInfo(key)` | Where a scroll container is (`ScrollInfo`: `offset`, `viewport`, `content`, `box`), or null before its first frame. |
| `ui.caretVisible(key)` | The caret's blink phase for the focused field, asking for the frame of the next flip. |
| `ui.task(key, options, function, args, handler)` | Declare concurrent work for this component scope. |
| `ui.id(key)` | The element's `layout.Unit.Id`, for `Update.scrollIntoView` or floating attachment. |
| `ui.context()` | The raw `layout.Context`, for anything `Ui` doesn't wrap. |
| `ui.arena()` | The frame arena: freed at the start of the next frame. |
| `ui.now()` | The frame's time from the host's clock. |
| `ui.capabilities()` | What the platform can do; the same as `ui.use(app.Capabilities)`. |
| `ui.hasNativeWidgets()` | Whether `app.widgets` are native in this runtime, or drawn. |

Views allocate only from the frame arena. `ui.text` and `ui.print` copy
their strings, so a view can format into a stack buffer and pass it.

## Messages and handlers

Messages are values of a stateful component's `Msg`. Views bind them with
`ui.messages(C)`, for the nearest stateful instance of `C` rendering the view:
its own component's, or an ancestor's, so a stateless helper deep in the
tree can bind to the component it belongs to.

```zig
const on = ui.messages(App);
try widgets.button(ui, "flash", .{ .label = "Flash!", .on_click = on.bind(.request_flash) });
try ui.child(Row, i, .{ .on_click = on.bind(.{ .choose = i }) });
try ui.child(Picker, {}, .{ .on_pick = on.handler(.picked) });
```

There is one kind of callback, **`app.Handler(P)`**: one of an instance's
`Msg` tags, bound to the instance, that whoever has it fires with a payload
of type `P`, knowing nothing of the owner's `Msg`. It is a plain value: copy
it into props, store it in a service, post to it from another thread.

- `on.handler(.tag)` makes a `Handler(Payload)` whose `P` is the tag's
  payload type (`void` for a bare tag).
- **`app.Action`** is `Handler(void)`: what elements fire (`on_click`) and
  what stateless components take for their events. `on.bind(.tag)` makes one
  for a tag without payload; `on.bind(.{ .tag = payload })` binds a payload;
  `on.bind(msg)` binds a whole `Msg`; `handler.with(payload)` binds a
  payload to an existing handler.
- Bound payloads are carried inline, so binding can't fail; a payload over
  `app.inline_size` (24) bytes or `app.inline_align` (8) is a compile error
  pointing at `try on.bindAlloc(msg)` and `try handler.withAlloc(ui.arena(),
  payload)`, which copy it into the frame arena.

Firing: `ctx.emit(handler, payload)` from `update` (an action with `{}`),
`Poster.post(handler, payload)` from anywhere, including other threads
(`ctx.poster()`, `Runtime.poster()`), and the runtime itself for `on_click`
and the rest. `handler` may be optional: null does nothing.

**Delivery.** Emitting or posting only queues. The queue is processed in
FIFO order at the start of each frame, before anything else, and after each
input event; messages queued while processing run in the same pass. Posting
from another thread also asks the platform for a frame. A message for an
instance that no longer exists, or isn't an instance of the component the
message was made for, is discarded (calling `Msg.deinit` if it owns a
payload).

**Errors.** An error returned by `update` is returned by the runtime call
that delivered the message (`frame`, `mouse`, `key`, `nativeEvent`, ...).
Nothing is rolled back; the message is consumed; later messages are
delivered by the next call.

**Ownership.** A payload fired with `emit` or `post` belongs to the message
until `update` handles it, then to `update`, which stores or frees it. A
payload bound to an action is *borrowed*, often from the frame that bound
it: `update` copies what it keeps, and it is never passed to `Msg.deinit`.
Text that reaches `update` from the platform (a field's text, a chosen
file's path) is borrowed the same way. `Update.emitText` and
`app.platform.Reply` copy text for a handler of `[]const u8` or
`?[]const u8` and free it after delivery.

## `update` and its context

```zig
pub fn update(state: *State, msg: Msg, ctx: *app.Update(App)) !void
```

`ctx` is the instance's view of the runtime:

| Member | What it is |
|---|---|
| `ctx.props` | The props the instance was last rendered with. |
| `ctx.gpa` | The allocator for anything the state stores; `State.deinit(gpa)` gets the same one. |
| `ctx.emit(handler, payload)`, `ctx.emitText(handler, text)` | Queue a message. |
| `ctx.handler(.tag)` | A `Handler` for one of this component's tags, to give to background work. |
| `ctx.poster()` | A thread-safe `Poster`. |
| `ctx.run(function, args, handler)`, `ctx.runKey(key, function, args, handler)`, `ctx.cancel(key)` | Start concurrent work, replace a keyed command, or cancel it. See Concurrency. |
| `ctx.now()` | The time of the last frame. |
| `ctx.element(key)` | The layout ID of this instance's element, as `ui.id(key)` gives it. |
| `ctx.focus(key)`, `ctx.blur()` | Give keyboard focus to an element, now or once a frame shows it; take it away. |
| `ctx.scrollTo(key, target, options)`, `ctx.scrollIntoView(id)` | Move a scroll container (`ScrollTarget`: `.start`, `.end`, `.{ .offset = v }`, `.{ .by = v }`). |
| `ctx.refresh(hint)` | Ask the host for a `page` refresh of the next frame (e-ink). |
| `ctx.textEnv(options)`, `ctx.editText(editor, input, options, on_paste)` | Apply text input to a `TextEditor`, serving the clipboard. |
| `ctx.message(request)`, `ctx.confirm(request, on_answer)`, `ctx.menu(request, on_choose)` | The host's dialog, question or popup menu, or one the runtime draws where the host has none. |
| `ctx.systemText(request, on_text)` | The platform's modal text entry (an e-reader's keyboard). |
| `ctx.openFile(request, on_choose)`, `ctx.openDirectory(request, on_choose)` | The platform's choosers. |
| `ctx.writeClipboard(text)`, `ctx.readClipboard(on_text)` | The clipboard, or one private to the program. |
| `ctx.quit()`, `ctx.close()` | Quit, or close the window, without asking again. On AppKit and GTK the window is the only one, so closing it quits. |
| `ctx.use(T)`, `ctx.tryUse(T)` | The context value the instance's view was rendered with. |

The services return `app.platform.Services.Error`: `Unsupported` where the
host has none (and the runtime can't stand in), `ServiceFailed`,
`OutOfMemory`. Answers come back as messages to the handler passed in
(`?usize` for a button or item index, `?[]const u8` for text or a path,
null when cancelled). OpenEtcher's `App.update` asks for an image like this:

```zig
.pick_image => if (!state.flashing()) try ctx.openFile(.{ .message = "Choose an image to flash", .extensions = model.image_extensions }, ctx.handler(.image_picked)),
.image_picked => |picked| {
    const borrowed = picked orelse return;
    const path = try gpa.dupe(u8, borrowed);
    ...
```

## Concurrency

`update` and `view` run on the UI thread. They have no I/O parameter:
use runtime tasks for file reads, network requests, image decoding and
other work that could block. [`examples/tasks.zig`](../examples/tasks.zig)
is a complete, tested example.

**Commands** start in response to a message:

```zig
try ctx.run(readImage, .{path}, ctx.handler(.image_read));
try ctx.runKey("image", readImage, .{path}, ctx.handler(.image_read));
try ctx.cancel("image");
```

A task function's first parameter must be `*app.Task`, checked at compile
time. Its remaining parameters match `args`; its exact return type is the
handler's payload, including an error union (`anyerror!Image`, for example).
`ctx.run` starts independent commands. `runKey` cancels the previous
command with the same instance-local key and leaves its replacement pending
until the previous function has returned, including its cleanup. The UI
thread never waits for that return. Replacing again while pending discards
the pending arguments without running the function; canceling a pending
task drops it too. Both return allocation or spawn
errors to the caller, so use `try`. Task errors are delivered to the
handler; `error.Canceled` is suppressed. A function returning plain `void`
may use `null` instead of a result handler:

```zig
try ctx.runKey("image", unloadImage, .{work}, null);
```

Error unions, including `anyerror!void`, still require a handler.

`Task` exposes `io`, `gpa`, `checkCancel()`, and `post(handler, payload)`.
I/O uses `task.io`; CPU loops should call `try task.checkCancel()` regularly.
Use `task.post` on the task thread. For progress from other threads, create
a handle on the task thread with `const progress = try task.progress(handler)`
and copy it to the producer. `try progress.post(payload)` is thread-safe;
posts after cancellation or completion are dropped, including after the
record and arena are reclaimed. Handles need no release, but the runtime
must outlive their use. A handle does not keep task memory alive: synchronize
any producer that reads arena memory before the task returns. Posted slices
must stay immutable and alive through delivery. The arena allocator itself
is for the task thread. Updates always run on the UI thread.

**Declared tasks** describe work needed by the current screen:

```zig
try ui.task("drives", .{ .restart = state.drive_refresh }, listDrives, .{}, on.handler(.drives_listed));
try ui.task(.{ "thumb", path }, .{}, loadThumbnail, .{path}, on.handler(.thumb));
```

Keys are scoped to the component rendering the declaration, including
stateless components. With the same key and restart value, a task keeps
running or stays completed while declared. Use `.{}` for the default
options (no explicit restart value), or `.{ .restart = value }` to hash any
value supported by keys. Changing the restart value cancels the old task
and leaves its replacement pending until the old function has returned,
just like `ctx.runKey`. Keep the key stable for an explicit refresh.
Different keys run independently, even while canceled work is still
returning. A key that disappears, or whose component disappears, is canceled;
it only holds up future work with that same key. Changing arguments alone
does not restart a task. Duplicate keys in a frame fail with
`error.DuplicateTaskKey`; changing the function for a retained key fails
with `error.TaskFunctionChanged`.

Arguments are copied before either API returns: slices (including nested
slices), arrays, structs, tagged unions and optionals are copied recursively.
Task handlers copy bound action payloads too, including `withAlloc` data.
Owning containers are rejected at compile time in arguments and results:
structs with a `capacity` field, an `std.mem.Allocator` field (or the allocator
itself), and std hash maps (including unmanaged maps with metadata and
available-slot fields). This includes ArrayList, hash maps and ArenaAllocator.
The check recurses through values, slices, optionals and tagged unions.
Pass a slice instead, or borrow the synchronized owning object by pointer.
Single pointers are borrowed: point only to synchronized domain objects
that outlive cancellation and shutdown, never frame or component state.
Allocate results and progress data with `task.gpa`, an arena reclaimed
after the task exits and its messages have been delivered or discarded.
Messages **borrow** this memory and bypass `Msg.deinit`; `update` must
clone anything retained in state using `ctx.gpa`. Do not mutate posted
data. Close files and release other external resources with `defer` inside
the function; arena reclamation only frees memory.

Cancellation immediately suppresses even already queued task messages.
The runtime requests I/O cancellation and joins the task on a background
worker, so replacing or removing a task does not wait on the UI thread.
Each cancellation worker is joined and reclaimed with its record; completed
workers do not accumulate until shutdown.
Cancellation is cooperative; tasks that ignore it can delay shutdown.
The runtime's allocator must support concurrent allocation. An I/O backend
without concurrency returns `error.ConcurrencyUnavailable`, never runs
blocking work inline. An error spawning a cancellation worker is returned;
messages remain suppressed and shutdown still joins the task.

The runtime cancels and joins all work on `deinit`. AppKit and GTK also do
so before invoking `on_terminate`, keeping injected services alive while
tasks unwind. Custom hosts should call `runtime.cancelTasks()` before
shutting down domain services, then deinitialize the runtime.

**Debug watchdog:** `Runtime.Options.watchdog_ms` defaults to 16. Debug
builds time every `update` and each view's own work (excluding child render
calls), logging the component name, message
tag for updates, elapsed milliseconds and budget when exceeded. Set it to
`0` or `null` to disable. Release builds compile out the clock reads and
logging. A warning identifies slow UI work; it does not preempt it.

Keep `ctx.use(Services)` for domain work with an independent lifecycle,
such as a flashing session, shared image cache or persistent connection.
Tasks may borrow such a service to do domain work using `task.io`; the
service must synchronize shared data and outlive runtime task shutdown.

Harnesses queue tasks by default. `h.taskStarted(key)` reports whether a root task
was declared or queued; `h.runTasks()` runs the current queue in order,
then delivers messages and renders. Work created by those results waits
for the next call. `h.completeTask(key, function, result)` copies a fake
result and delivers it without running the function. The function supplies
the result type, and is checked against the queued task. Completed tasks
cannot be completed twice. Declared tasks are looked up by their stable key,
independently of the restart value. A replacement blocked by an executing task
with the same key cannot run or be faked yet (`error.TaskPending`); queued unstarted predecessors
are canceled immediately and never run. Fixture memory stays owned by the test.
For children use `taskStartedFor(instance, key)` and
`completeTaskFor(instance, key, function, result)`, with an instance from
`h.root().child(C, key)` or `h.root().one(C)`. Unkeyed commands can be
executed with `runTasks`; use keyed commands when tests need fake results.

## Contexts

Values most of the tree needs (services, a theme, icons) are provided once
and looked up by type, rather than threaded through every component's props.

- Root values go to `Runtime.init` (or `App.init`) in `provide`, as
  `.provide = &.{ .of(&services), .of(&icons) }` (`app.RootValue.of` takes a
  pointer to one value). They must outlive the runtime.
- `ui.provide(T, &value)` in a view provides to everything rendered after
  it, children included, until the container that was open closes (or the
  view returns). Later values of a type hide earlier ones. The value must
  live until the next frame starts; the frame arena will do.
- `ui.use(T)` and `ctx.use(T)` panic if nothing provides `T`;
  `tryUse(T)` returns null instead. `update` sees the values its instance's
  view was rendered with.
- For a mutable shared resource, provide a pointer value: keep
  `var work_ptr: *Work = &work` alive and provide `.of(&work_ptr)`, then use
  `ctx.use(*Work).*` (or `ui.use(*Work).*`). The context lookup is const;
  the explicitly provided pointer carries mutability. Synchronize shared
  access and keep the resource alive until tasks and other producers stop.
- To provide two values of one type, wrap them in distinct types.

The runtime provides three root values itself, under the app's own:
`app.native.Theme`, `app.Capabilities` and `app.Keymap`.

## The widget set

`app.widgets` is the common set, each a view helper keyed like any element,
shown as the platform's own control where the runtime has native widgets and
drawn by fabrum (`app.drawn`) where it hasn't, as on the `none` platform.
Apps that want the same pixels everywhere call `app.drawn` directly.

```zig
const on = ui.messages(Form);
try widgets.textField(ui, "name", .{ .text = state.name, .on_change = on.handler(.name_changed) });
try widgets.checkbox(ui, "agree", .{ .label = "I agree", .checked = state.agree, .on_change = on.handler(.agreed) });
try widgets.button(ui, "send", .{ .label = "Send", .on_click = on.bind(.send), .enabled = state.agree });
```

| Widget | Options | Reports | Native on macOS / GTK |
|---|---|---|---|
| `button` | `label`, `on_click`, `enabled`, `default` (Return presses it), `sizing` | `Action` | `NSButton` / `GtkButton` |
| `checkbox` | `label`, `checked`, `on_change`, `enabled` | `Handler(bool)` | `NSButton` (check) / `GtkCheckButton` |
| `toggle` | `on`, `on_change`, `enabled` | `Handler(bool)` | `NSSwitch` / `GtkSwitch` |
| `slider` | `value`, `min`, `max`, `on_change`, `enabled`; fills its width | `Handler(f64)` | `NSSlider` / `GtkScale` |
| `textField`, `searchField`, `secureField` | `text`, `placeholder`, `on_change`, `on_submit`, `enabled`; fill their width | `Handler([]const u8)` (borrowed), `Action` | `NSTextField`, `NSSearchField`, `NSSecureTextField` / `GtkEntry`, `GtkSearchEntry`, `GtkPasswordEntry` |
| `textArea` | `text`, `placeholder`, `on_change`, `enabled` | `Handler([]const u8)` | `NSTextView` in a scroll view / `GtkTextView` |
| `dropdown` | `items`, `selected`, `on_select`, `enabled` | `Handler(usize)` | `NSPopUpButton` / `GtkDropDown` |
| `radioGroup` | `items`, `selected`, `on_select`, `enabled`, `horizontal` | `Handler(usize)` | `NSButton` radios / `GtkCheckButton` group |
| `stepper` | `value`, `min`, `max`, `step`, `on_change`, `enabled` | `Handler(f64)` | `NSStepper` with a field / `GtkSpinButton` |
| `label` | `text`, `wrap`, `selectable`, `font_size`, `secondary` | | `NSTextField` as a label / `GtkLabel` |
| `progressBar` | `value` (0 to 1, or null for indeterminate) | | `NSProgressIndicator` / `GtkProgressBar` |
| `spinner` | `size` (`small`, `regular`) | | `NSProgressIndicator` spinning / `GtkSpinner` |
| `scrollView` | `horizontal`, `vertical`, `on_scroll`, `content` (the inner `layout.Config`), `sizing`; closed with `ui.close()` | `Handler(ScrollInfo)` (drawn) | `NSScrollView` / `GtkScrolledWindow` |

**Controlled values.** A control shows what the view passes and reports the
user's changes through its handler; `update` stores them in the state. The
runtime writes the state's value into the control only when it differs from
what the control last reported, and never while the user is composing text
(IME), so echoing input back never disturbs typing. Text from `on_change` is
borrowed: copy it.

**Native widgets in the layout.** A native view gets a box in the open
container, sized by `sizing` around the backend's measured size (AppKit's
`fittingSize`), and takes the box's frame. Drawn content between and over
native views is split into canvas layers in paint order, so a drawn modal
declared after a native field covers it. A `scrollView` is a native
container: fabrum lays its content out in the container's coordinates, and
the platform scrolls it and reports the offset.

**Platform catalogues.** What only one toolkit has lives in its namespace,
behind a `kind` check:

```zig
switch (comptime fabrum.app.platform.kind) {
    .appkit => try fabrum.app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = 3, .max = 5 }),
    else => try fabrum.app.widgets.slider(ui, "rating", .{ .value = 3, .max = 5 }),
}
```

`appkit.widgets` has the common set and `levelIndicator`
(`NSLevelIndicator`); `gtk.widgets` the common set.

**Drawn widgets** (`app.drawn`) take the same options, look like the
platform through the provided `native.Theme` (accent, colors, font size,
control height) and adapt to `app.Capabilities`: no hover shades without
hover, no caret blink or spinner animation without `full` animation, high
contrast on a gray display. They are focusable when the theme's
`full_keyboard_access` is on (macOS's "Keyboard navigation"); text fields
always are. `app.drawn` also has `textEditor` (below) and `alert`.

## Menus and dialogs

Declared from views, the platform's own, existing while a view declares
them:

```zig
try menus.item(ui, "greet", .{ .menu = "Kitchen", .title = "Say Hello", .key = "k", .on_select = on.bind(.greet) });
```

```zig
if (state.confirming) try dialogs.alert(ui, "erase?", .{
    .title = "Erase the disk?",
    .buttons = &.{ "Erase", "Cancel" },
    .on_response = on.handler(.answered), // usize: the button's index
});
```

`app.menus.item` adds an item to a menu of the menu bar (made when
missing), with a key equivalent under the platform's shortcut modifier.
Without native widgets there is no menu bar, and it shows nothing.
`app.dialogs.alert` is a modal alert, a sheet on macOS; the view stops
declaring it once the state has the answer. Without native widgets it is
drawn (`app.drawn.alert`) over what was declared before it.

From `update`, `ctx.message`, `ctx.confirm` (up to three buttons, with a
default) and `ctx.menu` (items with `title`, `kind` of `item`, `header`,
`separator` or `submenu`, an `id` for the reply, `enabled`, `submenu`) ask
the host's services. Where the host has no such service, the runtime draws
the dialog or menu itself as a modal overlay and answers through the same
handler. `ctx.openFile` and `ctx.openDirectory` have no drawn fallback and
fail with `error.Unsupported` where the host has none.

## Pointer input

Input is hit-tested against the previous frame's layout. The hit element is
the topmost unit whose shape contains the pointer (rounded corners
respected), topmost meaning latest in paint order; points cut away by a
clipping ancestor don't hit. The hit element and its keyed ancestors are
hovered, as CSS `:hover`.

- **Clicks.** A click is a primary press and release that resolve to the
  same element. It goes to the nearest hovered element with an `on_click`,
  so clicks on a label bubble to the button around it. A press that moves
  past `drag_threshold` (4 points) or is reported long is no longer a click.
- **`on_pointer`.** A primary press on the element captures the pointer:
  until the release, every move goes to it as a `Pointer` with phase
  `press`, `drag`, `release`, `cancel` or `long_press`, `local` (from the
  element's box) and `size`, the buttons and modifiers, and `clicks` (2 for
  a double click's second press, 3 for a triple), as a drawn slider or a
  text selection needs. `Runtime.cancelPointer` ends a press the host lost.
- **Hover and press state** show in views as `ui.hovered(key)` and
  `ui.pressed(key)`; both mark the runtime dirty when they change.
- **Scrolling** by wheel or trackpad goes to the innermost scroll container
  under the pointer, the rest to its ancestors; on a touch screen
  (`Capabilities.pointer == .touch`) a press on a scroll container that
  moves past the threshold pans it.
- **The cursor.** `Runtime.cursor()` is `pointer` over a clickable, `text`
  over a text input, else `default`; `Ui.Container.cursor` overrides it.

`app.MouseEvent` is what hosts deliver: `position`, `pressed` (a bit set,
`MouseEvent.primary` is bit 0), `scroll_delta` in points, `scroll_phase`
for trackpad gestures, `modifiers`, `long_press`.

## Focus and keys

Keyboard focus is one chain across native and drawn elements. Elements join
the Tab order with `focusable`, `focus` or (for native ones) the platform's
own rules; `focus_on_press` makes a press focus the element. Tab and
Shift-Tab move focus in paint order, wrapping; Escape clears drawn focus;
Space and Enter click the focused element's `on_click` on release. A
`modal` element restricts the Tab order to its contents.

An element that wants keys declares a `Focus`:

```zig
try ui.open("list", .{
    .focusable = true,
    .focus = .{
        .on_key = on.handler(.key),        // Handler(app.KeyEvent)
        .keys = .navigation_only,          // which keys on_key takes: a KeyFilter
        .on_focus = on.handler(.focused),  // Handler(bool)
    },
});
```

`KeyFilter` sorts keys into `typing`, `navigation`, `function`, `tab`,
`escape` and `commands` (Control or Command held); the presets are
`.default` (everything but Tab, Escape and shortcuts), `.all`,
`.navigation_only` and `.none`. The runtime answers the host from the filter
before any `update` runs, so a host knows at once whether to pass the key
on. `Focus.on_text` makes the element a text input (see below).

A key press goes, in order, to: the focused element's `on_key` if its filter
admits it; the focused text input; the ancestors' `on_key`; the frame's
shortcuts; then the runtime's own (Tab, Escape, Space, Enter). Keys are only
the app's while a drawn element has focus; without one, `Runtime.key`
returns false and an overlay host lets the key through.

**Shortcuts.** `ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true },
on.bind(.save))` declares one for the frame; `shortcut` means the platform's
modifier (Command on macOS, Control elsewhere, from the `Keymap`). A
character shortcut matches the character the layout types or, on a layout
that types no Latin letter there, the physical key's US character, so
Ctrl-C copies on a Russian layout.

**`app.KeyEvent`**: `key` (a `Key`: `.{ .char = 'a' }` lowercase unshifted,
or a named key), `physical` (USB HID name), `phase` (`press`, `repeat`,
`release`), `modifiers` (`shift`, `control`, `alt`, `super`, `caps_lock`)
and `text` (what the key types, for hosts that know).

**`app.Keymap`** (`.macos`, `.windows`, `.linux`) decides which keys mean
which edit commands and which modifier shortcuts use; the platform's by
default, or `Runtime.Options.keymap`.

## Scrolling

A drawn scroll container is `Ui.Container.scroll`, an `app.Scroll`: `x`,
`y` (on by default), `scrollbar` (an overlay thumb the runtime draws and
drags), `on_scroll`. `app.widgets.scrollView` declares one (native where the
platform has them). The runtime keeps the offset by the element's key, as a
browser keeps scroll positions, clips the content, scrolls it by the wheel,
the scrollbar, a touch pan, and focus moving into it, and clamps it to the
content as of the last frame.

- `ui.scrollInfo(key)` reads where it is.
- `ctx.scrollTo(key, .end, .{})` moves it; `.{ .refresh = .interactive }`
  marks a scroll that follows a gesture of the app's own, so e-ink hosts
  use a fast update.
- `ctx.scrollIntoView(id)` scrolls whatever containers are around an element
  (`ctx.element(key)`, or another instance's from `app.testing.Instance`).

Content that wraps is measured under a scroll view's size only along the
axis that doesn't scroll (`layout.ContainerDeclaration.ClipConfig`'s
`scrolls_*`); along the one that does, it takes the room it needs.

## Text editing

Drawn text widgets edit with `app.TextEditor`: controlled text with a caret,
a selection and undo, moving by grapheme and word (UAX #29), with vertical
moves over the field's visual lines.

- `widgets.textField`, `textArea`, `searchField` and `secureField`, when
  drawn, keep an editor inside and report the text after each edit through
  `on_change`, as native fields do.
- `app.drawn.textEditor(ui, key, &editor, .{ .on_input = on.handler(.input),
  .single_line = true })` shows an editor the app's state owns and sends
  every keystroke, command and selection to the app as an `app.TextInput`,
  which `update` applies:

```zig
.input => |input| {
    const outcome = try ctx.editText(&state.editor, input, .{ .single_line = true }, ctx.handler(.pasted));
    if (outcome.submitted) try ctx.emit(ctx.handler(.send), {});
},
.pasted => |text| if (text) |t| {
    _ = try state.editor.apply(ctx.gpa, .{ .paste = t }, ctx.textEnv(.{ .single_line = true }));
},
```

`TextInput` is `commit` (typed text), `paste`, `set`, `replace`, `select`
(from a pointer), `preedit` (accepted, not shown yet) or a `command`: an
`app.EditCommand` such as `.{ .move = .{ .by = .word_end, .direction =
.forward, .extend = true } }`, `select_all`, `undo`, `copy`, `cut`, `paste`,
`transpose`, `kill_to_line_end`. The `Keymap` turns key events into commands.
`Update.editText` applies the input with `textEnv` (the time, the field's
options and the visual lines the view recorded with `ui.textGeometry`) and
serves the clipboard: `copy` and `cut` write it, `paste` reads it and sends
the text to `on_paste`. `TextEditor.Outcome` says whether the text or the
selection changed and whether Enter submitted a single-line field.

Hosts with an input method or a system keyboard deliver text with
`Runtime.textInput`. Where the platform's keyboard is on-screen
(`Capabilities.keyboard == .on_screen`), pressing a drawn field asks for it
with `ctx.systemText`, and the result replaces the text.

## Timers and animation

The host runs frames with its own clock; views see it as `ui.now()` and
animation is a function of it, never of frame counts.

- `ui.animate()` asks for another frame as soon as the host can show one;
  ask every frame to keep animating.
- `ui.frameAt(time)` asks for a frame at `time`.
- `try ui.every(key, period, action)` fires `action` every `period`
  (`std.Io.Duration`) for as long as the view declares it, keeping its
  phase; `try ui.after(key, delay, action)` fires once, unless the view
  stops declaring it first.
- `Runtime.nextFrame()` tells the host when the next frame is due, or null
  to wait for input or a post.

## Capabilities and theme

`app.Capabilities` says what the platform can do, for drawn widgets and
themes to adapt to: `pointer` (`mouse`, `touch`, `none`), `hover`,
`animation` (`full`, `reduced`, `none`), `color` (`color`, `gray`, `gray16`,
`gray4`), `keyboard` (`physical`, `on_screen`, `none`). A toolkit platform
has a mouse that hovers, animation, color and a keyboard; a `none` host
describes itself in `Runtime.Options.capabilities`. Views read it with
`ui.use(app.Capabilities)` or `ui.capabilities()`; `isGray()` and
`animates()` are the common questions.

`app.native.Theme` is the platform's look: `accent`, `text`,
`secondary_text`, `window_background`, `control_background`, `separator`,
`focus_ring`, `font_size`, `control_height`, `full_keyboard_access`,
`dark`. With a native backend it is the toolkit's; without one it is
`Runtime.Options.theme`, made `highContrast()` on a gray display. Views read
it with `ui.use(app.native.Theme)`, and drawn text that should match the
controls uses its `font_size` and `text`.

## Refresh hints

For displays whose refresh has a cost, such as e-ink. `Runtime.refresh()`
says how the host should show the regions the last `Runtime.damage()`
returned: `content` (a quality refresh, the default), `interactive`
(something is moving under the user's hand: a drag, a scroll; fast over
faithful) or `page` (everything changed, as a page turn: a full refresh
clearing ghosts), which an app asks for with `ctx.refresh(.page)`. The
strongest hint since the host last took the damage wins. Hosts without a
refresh cost ignore it.

## Closing and quitting

A view that wants to be asked before the window closes or the app quits
declares `ui.guardClose(on.handler(.close_requested))`, a
`Handler(app.platform.CloseReason)` (`window` or `quit`). The host asks
`Runtime.shouldClose(reason)` first; while a guard is declared it sends the
reason instead of letting the close happen. `update` asks the user
(`ctx.confirm`) and, if they agree, calls `ctx.quit()` or `ctx.close()`,
which don't ask again. OpenEtcher does this while a flash runs.

## The runtime

`app.Runtime(config)` is the thing platforms and hosts drive; `config.Text`
is the text content type, `layout.text.HeuristicContent` by default (rough,
font-free measurement for tests) or a renderer's `Text`. It must not move
after `init`.

`Runtime.Options`:

| Option | Meaning |
|---|---|
| `io` | A `std.Io`, used to lock the message queue. Required. |
| `text_context` | Measures `Text`; optional when `Text.Context` has a `default`. |
| `platform` | An `app.Platform` the runtime asks for a frame when a message is posted from another thread. |
| `provide` | Root values. |
| `context` | The layout's capacity (`layout.Context.Config`: `units`, `depth`, `breadth`, `max_breadth`); the frame fails with `error.LayoutCapacity` past it. |
| `root` | The root container's `layout.Config`; its sizing is the viewport each frame. |
| `native` | The platform's `native.Backend`; without one, widgets are drawn. |
| `theme`, `capabilities`, `keymap` | For hosts without a backend; the platform's otherwise. |
| `services` | The host's `app.platform.Services`. |
| `drag_threshold`, `multi_click` | 4 points; 500 ms. |

The calls a host makes: `frame(Root, props, viewport, now)`, `commands()`,
`damage()`, `refresh()`, `nextFrame()`, `needsFrame()`, `mouse(event)`,
`cancelPointer()`, `key(event)`, `textInput(input)`, `nativeEvent(id,
event)`, `shouldClose(reason)`, `focusMove(direction)`, `activateFocused()`,
`cursor()`, `scene()`, `poster()`, `post(handler, payload)`,
`rootState(Root)`, `context()`. See [platforms.md](platforms.md) for the
host loop.

## Testing

`app.testing.Harness(config, Root)` runs a root component in a runtime with a
fixed viewport, no window and no renderer, on every platform, and drives it
through the runtime's own input. Every input and every `post` is followed by
a frame, so queries always see the result. It uses `std.testing.allocator`
and `std.testing.io` unless told otherwise, so leaks fail the test.

```zig
var h: app.testing.Harness(.{}, Counter) = try .init(.{}, .{});
defer h.deinit();
try h.frame();
try h.click("+");
try h.expectText("count = 1");
try std.testing.expectEqual(1, h.state().count);
```

`Harness.Options`: `viewport` (800 by 600), `provide`, `text_context`,
`gpa`, `io`, `context`, `full_keyboard_access`, `widgets` (`.native` in the
fake tree, `.drawn`; the platform's default: drawn on `none`), `theme`,
`services` (`.all` fake services, `.basic` so the runtime draws dialogs and
menus, `.none`), `capabilities`, `keymap`.

| Group | Calls |
|---|---|
| Tasks | `taskStarted(key)`, `runTasks()`, `completeTask(key, function, result)`, `taskStartedFor(instance, key)`, `completeTaskFor(instance, key, function, result)` |
| Frames and state | `frame()`, `advance(duration)`, `state()`, `props` (change it between frames), `post(handler, payload)`, `poster()` |
| Finding | `texts()`, `findText(s)`, `hasText(s)`, `expectText(s)`, `expectNoText(s)`, `root()` (an `Instance`), `findElement(id)` |
| Pointer | `click(text)`, `clickElement(id)`, `clickAt(point)`, `hover(text)`, `hoverElement(id)`, `moveTo(point)`, `leave()`, `mouse(event)`, `drag(from, to, steps)`, `dragElement(id, to, steps)`, `longPress(point)`, `scroll(text, delta)`, `scrollElement(id, delta)`, `scrollAt(point, delta)`, `scrollInfo(id)` |
| Keys and text | `press(key, modifiers)` (fails unless taken), `pressKey`, `hold(key, modifiers, repeats)`, `keyEvent(event)`, `type_(text)`, `command(edit_command)`, `textInput(input)`, `tab()`, `shiftTab()`, `pressSpace()`, `focusedElement()`, `expectFocused(id)` |
| Native widgets (fake tree) | `widget(id)`, `expectWidget(id)`, `clickNative(id)`, `selectMenu(id)`, `typeText(id, text)`, `setText(id, text)`, `compose(id, marked)`, `commit(id, text)`, `submit(id)`, `slide(id, value)`, `selectNative(id, index)`, `stepNative(id, steps)`, `scrollNative(id, offset)`, `respond(id, index)` |
| The shell | `chooseFile(path)`, `chooseDirectory(path)`, `answerDialog(index)`, `chooseMenuItem(id)`, `enterText(text)`, `requestClose(reason)`, `clipboard()` |

`app.testing.Instance` finds elements the way they were rendered:
`h.root().one(Dialog).element("ok")`, `h.root().child(Row, 3).native("name")`,
and `instance.handler(C, .tag)` makes a handler to post to as a service
would. `app.testing.findText`, `TextIterator` and `center` work on any
runtime's layout, so debugging tools in real apps (OpenEtcher's script, the
Kitchen's) find what to click the same way.
