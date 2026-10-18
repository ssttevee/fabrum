//! The application runtime: the Elm architecture (TEA) on top of
//! `fabrum.layout`.
//!
//! An app is a tree of components. A component is a namespace with `Props`
//! and a `view`, in one of two shapes:
//!
//! ```zig
//! // stateless: a view function with its own element keys
//! const Badge = struct {
//!     pub const Props = struct { label: []const u8 };
//!     pub fn view(ui: *app.Ui, props: Props) !void { ... }
//! };
//!
//! // stateful: state that persists across frames, changed by messages
//! const Counter = struct {
//!     pub const State = struct { count: i32 = 0 }; // optional `deinit(gpa)`
//!     pub const Msg = union(enum) { increment, decrement }; // optional, with `update`
//!     pub const Props = struct { step: i32 = 1, on_change: ?app.Handler(i32) = null };
//!     pub fn update(state: *State, msg: Msg, ctx: *app.Update(Counter)) !void { ... }
//!     pub fn view(ui: *app.Ui, state: *const State, props: Props) !void { ... }
//! };
//! ```
//!
//! `Msg` and `update` come together, and only with `State`. Anything else is
//! a compile error. `update` returns `!void`, or `void` if it can't fail. Both kinds are rendered the same way, with
//! `ui.child(C, key, props)`, or `ui.one(C, props)` for a child that
//! appears once, so a caller can't tell them apart.
//!
//! Every frame, `Runtime.frame` runs `view` from the root component down and
//! rebuilds the layout from scratch. Views read state and describe elements;
//! they never change state. State only changes in `update`, in response to a
//! message. Views and the helpers they call all take the same `*app.Ui`,
//! whatever component they belong to.
//!
//! ## Instances and keys
//!
//! Each rendered component is an instance whose identity is a hash of its
//! parent instance, its component type and the key it was rendered with (see
//! `Ui.child`). Element keys (see `Ui.open`) are scoped to the instance, so
//! they only need to be unique within one instance of one component, and
//! never collide with keys in another instance. Repeated children need
//! distinct keys, as with React list keys; rendering a component twice with
//! the same key in one parent is `error.DuplicateKey`.
//!
//! A stateful instance's `State` is created with default values the first
//! time it is rendered, and destroyed after the first frame that doesn't
//! render it, calling `State.deinit(gpa)` if it is declared. Stateless
//! instances store nothing.
//!
//! ## Messages
//!
//! Messages are values of a stateful component's `Msg`. A view binds them
//! with `ui.messages(C)`, for the nearest stateful instance of `C` rendering
//! the view: its own component's, or an ancestor's, so a stateless helper
//! deep in the tree can bind to the component it belongs to.
//!
//! ```zig
//! const on = ui.messages(App);
//! try theme.button(ui, "flash", "Flash!", .{ .on_click = on.bind(.request_flash) });
//! try ui.child(Row, i, .{ .on_click = on.bind(.{ .choose = i }) });
//! try ui.child(Picker, {}, .{ .on_pick = on.handler(.picked) });
//! ```
//!
//! There is one kind of callback, `Handler(P)`: one of an instance's `Msg`
//! tags, bound to the instance, that whoever has it fires with a payload of
//! type `P`, knowing nothing of the owner's `Msg`. `on.handler(.tag)` makes
//! one whose `P` is the tag's payload type. Children fire handlers from
//! `update` with `ctx.emit(handler, payload)`, and background work with
//! `Poster.post`.
//!
//! An `Action` is a `Handler(void)`: what an element fires when clicked
//! (`on_click`), and what stateless components take for their events. A
//! payload can be bound to make one: `on.bind(.tag)` for a tag without
//! payload, `on.bind(.{ .tag = payload })` or `handler.with(payload)` for
//! one with, and `on.bind(msg)` for a whole `Msg`. `update` fires an action
//! with `ctx.emit(action, {})`.
//!
//! Actions carry their payload inline, so binding can't fail. A payload too
//! big for that, over `inline_size` bytes or `inline_align` alignment, is a
//! compile error that points to the allocating variants, `try
//! on.bindAlloc(msg)` and `try handler.withAlloc(ui.arena(), payload)`.
//!
//! Emitting or posting a message only queues it. The queue is processed in
//! FIFO order at the start of each frame, before anything else, and after
//! each input event; messages queued while processing run in the same pass,
//! after those already queued. Every delivered message marks the runtime
//! dirty. Messages can be posted from other threads through a `Poster`,
//! which also asks the `Platform` for a frame; they are only ever delivered
//! on the thread calling `Runtime.frame` and `Runtime.mouse`.
//!
//! A message for an instance that no longer exists, or that isn't an
//! instance of the component the message was made for, is discarded.
//!
//! ## Errors
//!
//! An error returned by `update` is returned by the runtime call that
//! delivered the message: `Runtime.frame`, which delivers queued messages
//! first, or the input call (`mouse`, `key`, `nativeEvent`,
//! `activateFocused`) whose message it was. `Runtime.post` only queues, so
//! errors from posted messages come from the next `frame`. Nothing is
//! rolled back: the state is as far as `update` got before failing, and
//! the message is consumed. Messages queued after it are not lost: they
//! are delivered by the next call. `ctx.emit` returns its error, for
//! `update` to `try`; there is no deferred error.
//!
//! ## Contexts
//!
//! Values that most of the tree needs, such as services or a theme, are
//! provided once rather than passed down through every component's props.
//! A value is looked up by its type with `ui.use(T)` in views and
//! `ctx.use(T)` in `update`, which panic if nothing provides `T`, or with
//! `tryUse(T)`, which returns null instead. To provide two values of one
//! type, wrap them in distinct types.
//!
//! - Root values are given to `Runtime.init` in `Options.provide`, and are
//!   seen everywhere.
//! - `ui.provide(T, value)` in a view provides `value` to everything that
//!   view renders after it, children included, until the container that was
//!   open when it was called closes, or until the view returns if none of
//!   its containers was open. Later values of a type hide earlier ones.
//! - `update` sees the values its instance's `view` was rendered with: the
//!   ones its ancestors provided before rendering it, not the ones it
//!   provides itself.
//!
//! ## Input
//!
//! Input is hit-tested against the previous frame's layout. The hit element
//! is the topmost unit whose shape contains the pointer (using
//! `layout.Unit.hovered`, so rounded corners are respected), where topmost
//! means latest in paint order: children above their parents, later siblings
//! above earlier ones. Points cut away by a clipping ancestor don't hit.
//!
//! The hit element and all of its keyed ancestors are hovered, like CSS
//! `:hover`. A click goes to the nearest of those with an `on_click`, so
//! clicks on a label bubble up to the button around it. A click is a primary
//! button press and release that resolve to the same element. A press also
//! fires the nearest `on_pointer` with where it landed (`Pointer`), and
//! focuses the nearest element declared `focus_on_press`.
//!
//! `Runtime.mouse` and `Runtime.key` return whether the app took the event,
//! so hosts that sit over something else (an overlay over a game, a VNC
//! proxy over a remote screen) pass the rest on; see `platform.none`.
//!
//! ## Frames and time
//!
//! The host runs frames with its own clock: `Runtime.frame(Root, props,
//! viewport, now)`. Views read it with `ui.now()`, and ask for later frames
//! with `ui.animate()` or `ui.frameAt(time)`. `Runtime.nextFrame()` tells
//! the host when the next frame is due, and `Runtime.damage()` what changed
//! since the host last drew.
//!
//! ## Testing
//!
//! `testing.Harness(config, Root)` runs a root component in a runtime with
//! a fixed viewport and no window or renderer, measuring text with
//! `layout.text.HeuristicContent` unless `config` says otherwise. Tests
//! click and hover by text, or by key under an instance, through
//! `Runtime.mouse` as a user would, and check the result with
//! `expectText`, `expectNoText` and the root `state`. The text queries it
//! uses, `testing.findText` and `testing.TextIterator`, work on any
//! runtime's layout, for debugging tools in real apps.
//!
//! ## Memory ownership
//!
//! - A message fired with a payload, by `Update.emit` or `Poster.post`,
//!   owns it until `update` handles it; `update` then owns it and must store
//!   or free it. A message that can't be delivered is discarded, calling
//!   `Msg.deinit(gpa)` if it is declared.
//! - Messages from actions, `on_click` among them, borrow the payload bound
//!   to the action, which often points into the frame that bound it:
//!   `update` must copy anything it keeps. They are never passed to
//!   `Msg.deinit`.
//! - State owns everything it stores, allocated with `Update.gpa`, and frees
//!   it in `State.deinit(gpa)`.
//! - Views allocate only from the frame arena (`Ui.arena`). It is reset at
//!   the start of the next frame, after that frame has processed the queued
//!   messages and the previous frame's render commands have been consumed.
//!   `Ui.text` and `Ui.print` copy their text into it, so views can pass
//!   any string, including one in a stack buffer.
//! - Values given to `ui.provide` must live until the next frame starts, so
//!   that `update` can use them; the frame arena will do. Root values must
//!   outlive the runtime.
const std = @import("std");

const component = @import("app/component.zig");
const context = @import("app/context.zig");
const input = @import("app/input.zig");
const message = @import("app/message.zig");
const runtime = @import("app/runtime.zig");
const ui = @import("app/ui.zig");
const reconciler = @import("app/reconciler.zig");

/// The contract between fabrum and a platform's native widgets, menus and
/// dialogs: `native.Backend`, `native.Spec`, `native.Scene`, `native.Theme`.
pub const native = @import("app/native.zig");

/// Testing apps without a window or a renderer: `testing.Harness`.
pub const testing = @import("app/testing.zig");

/// What hosts the app, chosen at build time: `platform.kind`.
pub const platform = @import("app/platform.zig");

comptime {
    // a clear error for platforms that don't exist yet
    platform.check();
}

/// The common widget set, shown as each platform's own controls, or drawn
/// where there are none.
pub const widgets = @import("app/widgets.zig");
/// The common widget set drawn by fabrum: the `none` platform's widgets,
/// and an opt-in everywhere else.
pub const drawn = @import("app/drawn.zig");
/// The platform's menu bar, declared from views.
pub const menus = @import("app/menus.zig");
/// The platform's alerts, declared from views.
pub const dialogs = @import("app/dialogs.zig");

pub const InstanceId = component.InstanceId;

pub const MouseEvent = input.MouseEvent;
pub const KeyEvent = input.KeyEvent;
pub const KeyFilter = input.KeyFilter;
pub const Focus = input.Focus;
pub const Shortcut = input.Shortcut;
pub const Pointer = input.Pointer;
pub const Cursor = input.Cursor;

/// Controlled text for drawn fields: `TextEditor`, what reaches it
/// (`TextInput`, `EditCommand`), and its visual lines (`TextGeometry`).
pub const text_editor = @import("app/text_editor.zig");
pub const TextEditor = text_editor.TextEditor;
pub const TextInput = text_editor.TextInput;
pub const EditCommand = text_editor.EditCommand;
pub const TextGeometry = text_editor.TextGeometry;
/// Which keys mean which edit commands: macOS, Windows or Linux.
pub const Keymap = @import("app/keymap.zig").Keymap;

pub const Handler = message.Handler;
pub const Action = message.Action;
pub const Messages = message.Messages;
pub const inline_size = message.inline_size;
pub const inline_align = message.inline_align;
pub const Update = message.Update;
pub const Poster = message.Poster;

pub const Ui = ui.Ui;
/// Internals of `Ui` and the runtime that tests and tools reach for, such
/// as the key of a scroll container's thumb.
pub const ui_internal = ui;
pub const runtime_internal = runtime;

pub const RootValue = context.RootValue;

pub const Reconciler = reconciler.Reconciler;
pub const FocusDirection = runtime.FocusDirection;

pub const Platform = runtime.Platform;
pub const Config = runtime.Config;
pub const Runtime = runtime.Runtime;
pub const Scroll = runtime.Scroll;
pub const ScrollInfo = runtime.ScrollInfo;
pub const ScrollTarget = runtime.ScrollTarget;
pub const Refresh = runtime.Refresh;

/// What the platform can do: pointer, hover, animation, color, keyboard.
pub const Capabilities = @import("app/capabilities.zig").Capabilities;

test {
    _ = component;
    _ = context;
    _ = input;
    _ = message;
    _ = runtime;
    _ = ui;
    _ = testing;
    _ = native;
    _ = reconciler;
    _ = platform;
    _ = platform.none;
    if (platform.kind == .appkit) _ = platform.appkit;
    _ = @import("app/hybrid_test.zig");
    _ = @import("app/host_test.zig");
    _ = @import("app/input_test.zig");
    _ = @import("app/segmentation.zig");
    _ = text_editor;
    _ = Keymap;
    _ = Capabilities;
    _ = drawn;
}
