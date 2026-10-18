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
//!     pub fn update(state: *State, msg: Msg, ctx: *app.Update(Counter)) void { ... }
//!     pub fn view(ui: *app.Ui, state: *const State, props: Props) !void { ... }
//! };
//! ```
//!
//! `Msg` and `update` come together, and only with `State`. Anything else is
//! a compile error. Both kinds are rendered the same way, with
//! `ui.child(C, key, props)`, so a caller can't tell them apart.
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
//! Messages are values of a stateful component's `Msg`. Views make
//! `Action`s for elements' events: `ui.bind(C, msg)` delivers `msg` to the
//! nearest stateful instance of `C` rendering the view, so a stateless helper
//! deep in the tree can bind to the component it belongs to, as in
//! `ui.bind(App, .open_drives)`. Children talk to their parents through
//! `Handler`s, made with `ui.handler(C, .tag)`, that `update` fires with
//! `Update.emit`; a handler can also become an `Action` with
//! `Handler.action` or `Handler.with`, so a stateless component can put its
//! parent's handler straight on an element.
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
//! button press and release that resolve to the same element.
//!
//! ## Memory ownership
//!
//! - A message owns its payload until `update` handles it; `update` then owns
//!   it and must store or free it. A message that can't be delivered is
//!   discarded, calling `Msg.deinit(gpa)` if it is declared.
//! - `on_click` messages are copied from the frame that rendered them, so
//!   their payload is frame memory: `update` must copy anything it keeps.
//!   They are never passed to `Msg.deinit`.
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

pub const InstanceId = component.InstanceId;

pub const MouseEvent = input.MouseEvent;
pub const Cursor = input.Cursor;

pub const Action = message.Action;
pub const Handler = message.Handler;
pub const Update = message.Update;
pub const Poster = message.Poster;

pub const Ui = ui.Ui;

pub const RootValue = context.RootValue;

pub const Platform = runtime.Platform;
pub const Config = runtime.Config;
pub const Runtime = runtime.Runtime;

test {
    _ = component;
    _ = context;
    _ = input;
    _ = message;
    _ = runtime;
    _ = ui;
}
