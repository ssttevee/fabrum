# Compose screens and own their state

Use components to give related state and events one lifetime. Use ordinary
view helpers for repeated declaration code that does not need an identity.
This guide builds on the [counter](first-app.md#write-the-component);
[the component reference](../app.md#components) defines the allowed shapes.

## Decide where state belongs

A stateless component declares `Props` and `view(ui, props) !void`. A
stateful component also declares `State`, with defaults for every field,
and its view takes `*const State`. Add `Msg` and `update` together when
messages can change that state. An `update` may return `void` or `!void`;
a view returns `!void`. A `Msg` without its matching `update`, or without
`State`, gives a compile-time shape error.

Keep state in the nearest component that needs to coordinate it. A settings
form should own its values; a label should receive a value through props.
A stateful child may receive `on_change` as a handler, emit it from update
with `try ctx.emit(ctx.props.on_change, new_value)`, and remain independent of
the parent's message type. Optional handlers accept null as a no-op.

State is initialized once, when an instance first appears. New props are
inputs to the existing instance, not constructor arguments. An instance
that is absent in a completed frame is destroyed. If state owns an
allocation, implement `pub fn deinit(self: *State, gpa:
std.mem.Allocator) void`; the runtime calls it when removing the instance
and at shutdown. The [settings form](widgets-and-input.md#build-a-controlled-settings-form)
shows allocation replacement and `deinit` together.

## Pass handlers to children

Use a stateless `Badge` to report an item ID to its stateful parent:

```zig
const Badge = struct {
    pub const Props = struct { label: []const u8, on_pick: app.Handler(usize), index: usize };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.open("badge", .{ .on_click = props.on_pick.with(props.index), .layout = .{ .padding = .all(4) } });
        defer ui.close();
        try ui.text(props.label, .{});
    }
};

const Picks = struct {
    pub const State = struct { selected: usize = 0 };
    pub const Msg = union(enum) { picked: usize };
    pub const Props = struct { reversed: bool = false };
    pub fn update(state: *State, msg: Msg, _: *app.Update(Picks)) void {
        switch (msg) {
            .picked => |index| state.selected = index,
        }
    }
    fn children(ui: *app.Ui, reversed: bool, on_pick: app.Handler(usize)) !void {
        const ids = if (reversed) [2]usize{ 20, 10 } else [2]usize{ 10, 20 };
        for (ids) |id| try ui.child(Badge, id, .{ .label = try ui.fmt("Item {d}", .{id}), .index = id, .on_pick = on_pick });
    }
    pub fn view(ui: *app.Ui, _: *const State, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();
        try children(ui, props.reversed, ui.messages(Picks).handler(.picked));
    }
};
```

`on.handler(.picked)` is a `Handler(usize)`: the child knows the payload
type but nothing about `Picks.Msg`. `.with(index)` binds that payload to an
`Action`, which the clickable box fires. `on.bind(.save)` binds a bare tag;
`on.bind(.{ .picked = index })` binds an entire message. A stateful child
can fire the same handler with `ctx.emit` from its update. Emitting queues
rather than reentering the parent; delivery is FIFO, including messages
emitted while processing the queue.

`ui.messages(C)` finds the nearest stateful ancestor of type `C`, including
the current instance. It lets a tightly coupled stateless helper bind its
owner's messages. Calling it with a type that is not rendering the view
panics in safety-checked builds; in unchecked builds the resulting messages
have no live target and are discarded. Pass handlers through props for
reusable children whose owner should not be fixed.

Bound action payloads fit inline up to `app.inline_size` and
`app.inline_align` (24 bytes and 8-byte alignment). Oversized payloads give
a compile error directing you to `try on.bindAlloc(msg)` or
`try handler.withAlloc(ui.arena(), payload)`. Those allocate in the frame
arena. Bound payloads are borrowed; clone anything an update retains.
[Message ownership](../app.md#messages-and-handlers) distinguishes this
from explicit `emit` and `post` payloads, which transfer ownership.

## Keep identity stable

`ui.child(C, key, props)` identifies a child by parent instance, component
type and key. `ui.one(C, props)` is exactly `ui.child(C, {}, props)`:
use it once per child type under that parent. Calling it twice for the
same type is `error.DuplicateKey`. Repeated children need stable distinct
keys such as item IDs. An array index is suitable only when the item at
that index has the same identity after insertion, deletion and sorting.

The badge example uses IDs 10 and 20 even after reversing their display
order. With stateful children, those IDs preserve local state and focus;
using the row position would associate that state with a different item.
Changing a key intentionally creates a fresh instance and destroys the
old state after the frame. Messages to removed instances are discarded.

Element keys are scoped to a component instance. Each badge may call its
box `"badge"`; two boxes with that key in one badge may not. `null` is
appropriate for an anonymous layout wrapper with no events or focus.
An anonymous box with `on_click`, `on_pointer` or `focusable` triggers
an assertion in safety-checked builds. Use a key for `focus`, `scroll` and
`cursor` too: the current anonymous-container path does not install them.

The `children` function above is an ordinary helper: it declares multiple
children inside its caller's open container. You can similarly write a
panel helper that opens a box, calls a supplied view function with props,
then closes the box. There is no separate retained children object to
store. A helper uses its caller's element scope; promote it to a component
with `ui.child` when it needs its own key namespace or state.

## Provide values to a subtree

Use props for local inputs; use a context when many descendants need the
same theme, preferences or domain service. This example supplies immutable
preferences to one subtree and a mutable resource pointer from the root:

```zig
const Preferences = struct { compact: bool = false };
const Shared = struct { saves: usize = 0 };
const ContextChild = struct {
    pub const State = struct { compact_seen: bool = false };
    pub const Msg = union(enum) { save };
    pub const Props = struct {};
    pub fn update(state: *State, _: Msg, ctx: *app.Update(ContextChild)) void {
        state.compact_seen = ctx.use(Preferences).compact;
        ctx.use(*Shared).*.saves += 1;
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try widgets.button(ui, "save", .{ .label = if (ui.use(Preferences).compact) "Save compact" else "Save", .on_click = ui.messages(ContextChild).bind(.save) });
    }
};
const ContextRoot = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        const preferences = try ui.arena().create(Preferences);
        preferences.* = .{ .compact = true };
        try ui.provide(Preferences, preferences);
        try ui.one(ContextChild, .{});
    }
};

test "guide root resource pointer and subtree value reach updates" {
    var shared: Shared = .{};
    var shared_ptr: *Shared = &shared;
    var h: app.testing.Harness(.{}, ContextRoot) = try .init(.{}, .{
        .provide = &.{.of(&shared_ptr)},
        .widgets = .drawn,
    });
    defer h.deinit();
    try h.frame();
    try h.click("Save compact");
    try std.testing.expectEqual(1, shared.saves);
}
```

`ui.provide(T, &value)` affects declarations after it, including children,
until the container open at that call closes, or that view returns if it
opened none. A later provider of the same type hides an earlier one.
The arena allocation keeps `Preferences` alive through the next frame's
queued updates. A pointer to a local stack value would already be dangling
when those updates read it.

An update sees the context its own view was rendered under, supplied by
ancestors. It does not see providers declared inside its own view.
`ui.use(T)` and `ctx.use(T)` panic with `app: nothing provides ...` if a
value is absent. Use `tryUse(T)` when absence is expected. Wrap values in
distinct types if you need two contexts with the same underlying data type.

At the root, `Runtime.Options.provide` and toolkit `App.init`'s
`InitOptions.provide` both accept `.of(&value)` entries. They copy the list
but borrow each value until the runtime is destroyed. The test provides a
value of type `*Shared` by passing `&shared_ptr`; `ctx.use(*Shared).*`
recovers the mutable pointer. Context lookup itself is const. Synchronize
mutable resources if tasks or other threads share them; keep them alive
through [task shutdown](concurrency.md#shut-down-in-lifetime-order).
The runtime already provides `native.Theme`, `Capabilities` and `Keymap`,
which application root values may override.

## Handle errors at the boundary

Use `try` for fallible declarations and message emission. A view error
fails `Runtime.frame`; an update error is returned by the runtime call
that delivered its message, such as `mouse`, `nativeEvent`, `key` or
`frame`. Posting only queues, so an update error from `Runtime.post`
appears during the next delivery call, not from `post` itself.

There is no transaction: state changes before the error remain, the failing
message is consumed, and later queued messages wait for the next delivery
call. Catch a domain error inside update when the UI should show it; let
allocation or unrecoverable errors reach the host's error policy. A view
that fills layout capacity gives `error.LayoutCapacity`; increase
`Runtime.Options.context` rather than silently dropping controls.

Avoid blocking work in either function. Debug builds log a component and
method exceeding the default 16 ms watchdog budget. Move that work into
[tasks](concurrency.md) or a synchronized injected service.
