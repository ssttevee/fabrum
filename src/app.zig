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
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

/// Identifies a component instance: a hash of the parent instance ID, the
/// component type and the instance's key.
pub const InstanceId = u64;

/// The parent ID used for the root component. No instance has it, so it
/// also stands for "no instance".
const root_parent: InstanceId = 0;

/// Pointer state delivered to `Runtime.mouse`.
pub const MouseEvent = struct {
    /// Where the pointer is, relative to the top left of the viewport.
    position: Vec2,
    /// Every button currently held down. Bit `primary` is the button that
    /// clicks.
    pressed: Buttons = .empty,
    /// The amount scrolled in each direction.
    ///
    /// X means right and Y means down, negative mean left and up respectively.
    ///
    /// The magnitude per scroll unit depends on the platform and hardware.
    scroll_delta: Vec2 = .zero,

    pub const Buttons = std.StaticBitSet(8);

    /// The bit of the primary (usually left) button in `pressed`.
    pub const primary = 0;
};

/// The pointer shape a platform shows over the app, from `Runtime.cursor`.
pub const Cursor = enum {
    /// The platform's usual arrow.
    default,
    /// A pointing hand, over something that can be clicked.
    pointer,
};

/// Hooks into the platform shell hosting the runtime.
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Asks the platform to run a frame soon. Called by `Poster.post`
        /// from whichever thread posted, so it must be thread-safe.
        requestFrame: *const fn (ptr: *anyopaque) void,
    };

    pub fn requestFrame(self: Platform) void {
        self.vtable.requestFrame(self.ptr);
    }
};

/// What happens when an element is clicked: a message for one stateful
/// instance, with its payload in the frame arena.
///
/// Made in views with `Ui.bind`, `Handler.action` or `Handler.with`, and
/// valid until the next frame starts. Its fields are the runtime's.
pub const Action = struct {
    target: InstanceId,
    payload: *const anyopaque,
    message: MessageFn,
};

/// A child-to-parent event: one of the owner's `Msg` tags, bound to the
/// owner instance. The child only knows the payload type, not the owner's
/// `Msg`.
///
/// Made with `Ui.handler` or `Update.handler`, and fired with `Update.emit`,
/// `Poster.post`, or as an element's `Action`. Its fields are the runtime's.
pub fn Handler(comptime P: type) type {
    return struct {
        core: *Core,
        target: InstanceId,
        message: MessageFn,

        const Self = @This();

        pub const Payload = P;

        /// The handler as an element's `Action`, such as an `on_click`.
        /// Only handlers without a payload; see `with` for the others.
        pub fn action(self: Self) Action {
            if (P != void) @compileError("Handler(" ++ @typeName(P) ++ ").action: the handler needs a payload; use `with(payload)`");
            return .{ .target = self.target, .payload = erase(&nothing), .message = self.message };
        }

        /// An `Action` that fires the handler with `payload`, which is
        /// copied into the frame arena. Like every `on_click` payload, it
        /// is frame memory to `update`. Only for views.
        pub fn with(self: Self, payload: P) Allocator.Error!Action {
            const stored = try self.core.arena.allocator().create(P);
            stored.* = payload;
            return .{ .target = self.target, .payload = erase(stored), .message = self.message };
        }

        /// A message that owns `payload`.
        fn make(self: Self, gpa: Allocator, payload: P) Allocator.Error!Message {
            return self.message(gpa, self.target, erase(&payload), true);
        }
    };
}

/// The payload of handlers and actions without one.
const nothing: void = {};

/// Passed to `update`: the instance's current props, an allocator for state,
/// and ways to send further messages.
pub fn Update(comptime C: type) type {
    return struct {
        core: *Core,
        instance: InstanceId,
        /// The props the instance was last rendered with.
        props: *const C.Props,
        /// The allocator for anything the state stores.
        gpa: Allocator,

        const Self = @This();

        /// Queues `payload` for the instance the `target` handler is bound to.
        /// `target` may be optional, in which case `null` does nothing. The message is
        /// processed after every message already queued.
        ///
        /// If the message can't be queued, the payload is discarded and the
        /// next `Runtime.frame` or `Runtime.mouse` returns the error.
        pub fn emit(self: *Self, target: anytype, payload: anytype) void {
            const h = if (@typeInfo(@TypeOf(target)) == .optional) target orelse return else target;
            const message = h.make(self.gpa, payload) catch |err| {
                self.core.deferred_error = err;
                return;
            };
            self.core.enqueue(message) catch |err| {
                self.core.deferred_error = err;
            };
        }

        /// Binds one of this component's `Msg` tags, for example so that
        /// background work can post its result back with `poster`.
        pub fn handler(self: *const Self, comptime tag: std.meta.Tag(C.Msg)) Handler(@FieldType(C.Msg, @tagName(tag))) {
            return bindHandler(C, self.core, self.instance, tag);
        }

        /// A thread-safe handle for posting messages from background work.
        pub fn poster(self: *const Self) Poster {
            return .{ .core = self.core };
        }
    };
}

/// Passed to every `view` and view helper: builds elements into the frame's
/// layout, and binds their events.
///
/// Element keys are scoped to the component instance being rendered, so
/// they only need to be unique within it.
pub const Ui = struct {
    core: *Core,
    /// The instance whose element keys this view uses.
    scope: InstanceId,
    /// The stateful instances rendering this view, innermost first.
    owners: ?*const Ancestor,
    /// Number of containers this view opened and hasn't closed yet.
    depth: usize = 0,

    /// A `layout.ContainerDeclaration` (without its unused `id`) plus the
    /// element's events:
    ///
    /// - `on_click: ?Action = null`: queued when the element is clicked.
    pub const Container = ContainerOptions();

    /// The frame arena. Everything allocated from it is freed at the
    /// start of the next frame.
    pub fn arena(self: *const Ui) Allocator {
        return self.core.arena.allocator();
    }

    /// Formats a string into the frame arena, for example for a label
    /// passed to a helper. To show formatted text, use `print`.
    pub fn fmt(self: *const Ui, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena(), format, args);
    }

    /// The raw layout context, for anything `Ui` doesn't wrap. Units
    /// appended here are added to the currently open container.
    pub fn context(self: *const Ui) *layout.Context {
        return &self.core.context;
    }

    /// The layout unit ID of this instance's element with `key`.
    pub fn id(self: *const Ui, key: anytype) layout.Unit.Id {
        return elementId(self.scope, key);
    }

    /// Opens a container. Must be finished with a matching `close`,
    /// usually `defer ui.close()`.
    ///
    /// `key` identifies the element within this instance, for `id`,
    /// `hovered`, `pressed` and events. It can be a string, integer, enum
    /// or any hashable value. Pass `null` for an anonymous container,
    /// which can't have events.
    pub fn open(self: *Ui, key: anytype, container: Container) !void {
        const decl = declaration(container);
        const core = self.core;
        const ctx = &core.context;

        if (@TypeOf(key) == @TypeOf(null)) {
            // only keyed elements can be hit-tested back to their events
            std.debug.assert(container.on_click == null);
            _ = ctx.openContainer(decl);
            self.depth += 1;
            return;
        }

        const unit_id = self.id(key);
        if (ctx.getUnitById(unit_id) != null) {
            return error.DuplicateKey;
        }

        if (container.on_click) |action| {
            try core.clicks.put(core.gpa, unit_id.id, action);
        }

        _ = ctx.openContainerId(unit_id, decl);
        self.depth += 1;
    }

    /// Closes the container most recently opened by this view.
    pub fn close(self: *Ui) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const ctx = &self.core.context;
        ctx.closeContainer(ctx.stack.getLast());
    }

    /// Appends text. `string` is copied into the frame arena, so it only
    /// needs to live for the call.
    pub fn text(self: *Ui, string: []const u8, style: layout.text.Style) Allocator.Error!void {
        try self.appendText(try self.arena().dupe(u8, string), style);
    }

    /// Appends text formatted into the frame arena, as with `std.fmt`.
    /// Types with a `format` method print with `{f}`.
    pub fn print(self: *Ui, style: layout.text.Style, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try self.appendText(try std.fmt.allocPrint(self.arena(), format, args), style);
    }

    fn appendText(self: *Ui, owned: []const u8, style: layout.text.Style) Allocator.Error!void {
        self.core.context.appendContent(try self.core.make_text(self.core, owned, style));
    }

    /// Appends any layout content. `content` must live until the frame's
    /// render commands are consumed; the frame arena will do.
    pub fn content(self: *Ui, c: *layout.Content) void {
        self.core.context.appendContent(c);
    }

    /// Appends a `layout.Context.spacer`: empty space that grows along the
    /// open container's axis, pushing what comes before and after it
    /// apart.
    pub fn spacer(self: *Ui) void {
        self.core.context.spacer();
    }

    /// Renders a child component, stateless or stateful, into the currently
    /// open container. `key` distinguishes repeated children of the same
    /// type; pass `{}` for a single child..
    pub fn child(self: *Ui, comptime C: type, key: anytype, props: PropsOf(C)) anyerror!void {
        try self.core.render(self, C, key, props);
    }

    /// An `Action` that delivers `msg` to the nearest stateful instance of
    /// `C` rendering this view, which may be this view's own component or
    /// any ancestor of it. `msg` is copied into the frame arena.
    ///
    /// Safety-checked builds panic if no instance of `C` is rendering this
    /// view; other builds return an action that is discarded when it
    /// fires.
    pub fn bind(self: *const Ui, comptime C: type, msg: MsgOf(C)) Allocator.Error!Action {
        const stored = try self.arena().create(C.Msg);
        stored.* = msg;
        return .{ .target = self.owner(C), .payload = erase(stored), .message = Envelope(C).fromMsg };
    }

    /// Binds one of the `Msg` tags of the nearest stateful instance of `C`
    /// rendering this view, so a child can emit into it. The handler's
    /// payload type is the tag's payload type. Safety-checked builds panic
    /// if there is no such instance, as with `bind`.
    pub fn handler(self: *const Ui, comptime C: type, comptime tag: std.meta.Tag(MsgOf(C))) Handler(@FieldType(C.Msg, @tagName(tag))) {
        return bindHandler(C, self.core, self.owner(C), tag);
    }

    /// The instance of `C` that `bind` and `handler` target.
    fn owner(self: *const Ui, comptime C: type) InstanceId {
        var it = self.owners;
        while (it) |o| : (it = o.parent) {
            if (o.type_tag == typeTag(C)) return o.instance;
        }
        if (std.debug.runtime_safety) {
            std.debug.panic("app: binding to " ++ @typeName(C) ++ ", but no " ++ @typeName(C) ++ " is rendering this view", .{});
        }
        return root_parent;
    }

    /// Whether the pointer was over the element with `key` (or one of its
    /// descendants) as of the last input event.
    pub fn hovered(self: *const Ui, key: anytype) bool {
        return std.mem.indexOfScalar(u32, self.core.hovered.items, self.id(key).id) != null;
    }

    /// Whether the primary button was pressed on the element with `key`
    /// (or one of its descendants) and hasn't been released yet.
    pub fn pressed(self: *const Ui, key: anytype) bool {
        return std.mem.indexOfScalar(u32, self.core.pressed.items, self.id(key).id) != null;
    }
};

/// A stateful instance rendering a view, in the chain `Ui.owner` searches.
const Ancestor = struct {
    parent: ?*const Ancestor,
    instance: InstanceId,
    type_tag: TypeTag,
};

/// A thread-safe handle for queueing messages from any thread.
pub const Poster = struct {
    core: *Core,

    /// Queues `payload` for the instance the `target` handler is bound to and
    /// asks the platform for a frame. `target` may be optional, in which case `null`
    /// does nothing.
    ///
    /// The payload belongs to the message from this call on, even if it
    /// fails. Allocates the message with the runtime's gpa on the calling
    /// thread, so the gpa must be thread-safe when posting from other
    /// threads.
    pub fn post(self: Poster, target: anytype, payload: anytype) Allocator.Error!void {
        const h = if (@typeInfo(@TypeOf(target)) == .optional) target orelse return else target;
        try self.core.enqueue(try h.make(self.core.gpa, payload));
        if (self.core.platform) |platform| {
            platform.requestFrame();
        }
    }
};

/// Compile-time options for `Runtime`.
pub const Config = struct {
    /// The text content created by `Ui.text`: a `layout.text.Content(...)`
    /// type, usually from a renderer. The default measures text with rough
    /// heuristics, which is enough for tests.
    Text: type = layout.text.HeuristicContent,
};

/// Owns component instances, the message queue, input state and the layout
/// of the last frame.
///
/// Must not be moved after `init`: views, handlers and posters point into
/// it.
pub fn Runtime(comptime config: Config) type {
    return struct {
        core: Core,
        text_context: Text.Context,
        root: layout.Config,

        const Self = @This();

        pub const Text = config.Text;

        pub const Options = struct {
            /// Used to lock the message queue.
            io: std.Io,
            /// Measures `Text`. Optional when `Text.Context` declares a
            /// `default`.
            text_context: ?Text.Context = null,
            /// Notified when messages are posted.
            platform: ?Platform = null,
            /// Capacity of the layout built each frame.
            context: layout.Context.Config = .{},
            /// Configuration of the root container. Its sizing is replaced
            /// with the viewport size each frame.
            root: layout.Config = .{},
        };

        pub fn init(gpa: Allocator, options: Options) !Self {
            const text_context = options.text_context orelse if (@hasDecl(Text.Context, "default"))
                Text.Context.default
            else
                @panic("app.Runtime: text_context is required for " ++ @typeName(Text));

            return .{
                .core = .{
                    .gpa = gpa,
                    .io = options.io,
                    .platform = options.platform,
                    .arena = .init(gpa),
                    .context = try .init(gpa, options.context),
                    .make_text = makeText,
                },
                .text_context = text_context,
                .root = options.root,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.* = undefined;
        }

        /// Runs one frame: processes queued messages, runs every view from
        /// `Root` down, computes the layout for `viewport`, destroys instances
        /// that weren't rendered, and clears the dirty flag.
        ///
        /// The returned commands, and all content in them, are valid until the
        /// next call to `frame`.
        pub fn frame(self: *Self, comptime Root: type, props: PropsOf(Root), viewport: Vec2) anyerror!layout.RenderCommand.Iterator {
            var root = self.root;
            root.sizing = .fixedXY(viewport.x, viewport.y);
            return self.core.frame(Root, props, root);
        }

        /// Updates hover and press state from pointer input, queues a click
        /// message if the primary button was released on the element it was
        /// pressed on, and processes queued messages.
        pub fn mouse(self: *Self, event: MouseEvent) Allocator.Error!void {
            return self.core.mouse(event);
        }

        /// Whether something changed since the last frame: a message was
        /// delivered, hover or press state changed, or messages are waiting.
        pub fn needsFrame(self: *Self) bool {
            return self.core.dirty or self.core.hasQueued();
        }

        /// The cursor to show as of the last input event: `pointer` while
        /// the pointer is over an element with an `on_click` (or over one of
        /// its descendants, since clicks bubble up to it), `default`
        /// elsewhere. Platforms call this after `mouse` and `frame`.
        pub fn cursor(self: *const Self) Cursor {
            return if (self.core.clickTarget() != null) .pointer else .default;
        }

        /// A thread-safe handle for posting messages from background work.
        pub fn poster(self: *Self) Poster {
            return .{ .core = &self.core };
        }

        /// Shorthand for `poster().post(target, payload)`.
        pub fn post(self: *Self, target: anytype, payload: anytype) Allocator.Error!void {
            return self.poster().post(target, payload);
        }

        /// The state of the root component rendered by the last frame, or
        /// null before the first. For tests and debugging: state changes
        /// belong in `update`.
        pub fn rootState(self: *Self, comptime Root: type) ?*Root.State {
            if (comptime componentKind(Root) != .stateful) @compileError("rootState: " ++ @typeName(Root) ++ " has no State");
            const instance = self.core.instances.get(instanceId(root_parent, Root, {})) orelse return null;
            const storage: *Storage(Root) = @fieldParentPtr("instance", instance);
            return &storage.state;
        }

        /// The layout built by the last frame.
        pub fn context(self: *Self) *layout.Context {
            return &self.core.context;
        }

        fn makeText(core: *Core, string: []const u8, style: layout.text.Style) Allocator.Error!*layout.Content {
            const self: *Self = @fieldParentPtr("core", core);
            const t = try core.arena.allocator().create(Text);
            t.* = .initContext(string, style, self.text_context);
            return &t.content;
        }
    };
}

/// Stands for a type at run time: the address of a variable that exists
/// once per type.
const TypeTag = *const anyopaque;

fn typeTag(comptime T: type) TypeTag {
    return &TypeMarker(T).marker;
}

fn TypeMarker(comptime T: type) type {
    return struct {
        const Type = T;
        var marker: u8 = 0;
    };
}

/// `ptr` as a type-erased pointer, for the runtime to cast back to the
/// type it was made from.
fn erase(ptr: anytype) *const anyopaque {
    return @ptrCast(ptr);
}

/// Makes the message a handler or an action stands for. `payload` points to
/// the handler's payload type, or to the whole `Msg` for `Ui.bind`.
const MessageFn = *const fn (gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message;

/// A queued, type-erased message for one instance.
const Message = struct {
    target: InstanceId,
    /// The component the message was made for. Delivered only to
    /// instances of it.
    type_tag: TypeTag,
    /// The target component's `Msg`, allocated with the gpa.
    msg: *anyopaque,
    vtable: *const VTable,
    /// Whether the payload is owned by the message. `on_click` payloads
    /// borrow frame memory and are never deinitialized.
    owned: bool,

    const VTable = struct {
        /// Runs `update` and frees the message.
        deliver: *const fn (core: *Core, instance: *Instance, msg: *anyopaque) void,
        /// Frees the message without delivering it.
        discard: *const fn (gpa: Allocator, msg: *anyopaque, owned: bool) void,
    };

    fn discard(self: Message, gpa: Allocator) void {
        self.vtable.discard(gpa, self.msg, self.owned);
    }
};

/// Type-erased handle to one stateful instance in the store.
const Instance = struct {
    id: InstanceId,
    /// The instance's component.
    type_tag: TypeTag,
    destroy: *const fn (gpa: Allocator, instance: *Instance) void,
    /// Whether the instance was rendered this frame.
    seen: bool = false,
};

fn Storage(comptime C: type) type {
    return struct {
        instance: Instance,
        state: C.State = .{},
        props: C.Props = undefined,

        fn destroy(gpa: Allocator, instance: *Instance) void {
            const self: *@This() = @fieldParentPtr("instance", instance);
            if (@hasDecl(C.State, "deinit")) {
                self.state.deinit(gpa);
            }
            gpa.destroy(self);
        }
    };
}

/// Message plumbing for component `C`.
fn Envelope(comptime C: type) type {
    return struct {
        const vtable: Message.VTable = .{ .deliver = deliver, .discard = discard };

        fn create(gpa: Allocator, target: InstanceId, msg: C.Msg, owned: bool) Allocator.Error!Message {
            const stored = gpa.create(C.Msg) catch |err| {
                if (owned) deinitMsg(gpa, msg);
                return err;
            };
            stored.* = msg;
            return .{ .target = target, .type_tag = typeTag(C), .msg = stored, .vtable = &vtable, .owned = owned };
        }

        /// For `Ui.bind`, whose payload is the whole `Msg`.
        fn fromMsg(gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message {
            return create(gpa, target, @as(*const C.Msg, @ptrCast(@alignCast(payload))).*, owned);
        }

        /// For handlers of `tag`, whose payload is the tag's.
        fn fromPayload(comptime tag: std.meta.Tag(C.Msg)) MessageFn {
            const Payload = @FieldType(C.Msg, @tagName(tag));
            return struct {
                fn message(gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message {
                    const value = @as(*const Payload, @ptrCast(@alignCast(payload))).*;
                    return create(gpa, target, @unionInit(C.Msg, @tagName(tag), value), owned);
                }
            }.message;
        }

        fn deliver(core: *Core, instance: *Instance, erased: *anyopaque) void {
            // `processMessages` checked the instance is a `C`
            std.debug.assert(instance.type_tag == typeTag(C));
            const stored: *C.Msg = @ptrCast(@alignCast(erased));
            const msg = stored.*;
            core.gpa.destroy(stored);

            const storage: *Storage(C) = @fieldParentPtr("instance", instance);
            var ctx: Update(C) = .{
                .core = core,
                .instance = instance.id,
                .props = &storage.props,
                .gpa = core.gpa,
            };
            C.update(&storage.state, msg, &ctx);
        }

        fn discard(gpa: Allocator, erased: *anyopaque, owned: bool) void {
            const stored: *C.Msg = @ptrCast(@alignCast(erased));
            if (owned) deinitMsg(gpa, stored.*);
            gpa.destroy(stored);
        }

        fn deinitMsg(gpa: Allocator, msg: C.Msg) void {
            if (@hasDecl(C.Msg, "deinit")) {
                var m = msg;
                m.deinit(gpa);
            }
        }
    };
}

/// The part of the runtime that doesn't depend on `Config`, so views and
/// handlers don't either.
const Core = struct {
    gpa: Allocator,
    io: std.Io,
    platform: ?Platform,
    /// Frame arena for views and the content they create.
    arena: std.heap.ArenaAllocator,
    context: layout.Context,
    /// Whether `context` holds a computed layout that can be hit-tested.
    laid_out: bool = false,
    instances: std.AutoHashMapUnmanaged(InstanceId, *Instance) = .empty,
    /// Stateless instances rendered this frame, to catch duplicate keys.
    stateless: std.AutoHashMapUnmanaged(InstanceId, void) = .empty,
    /// Element ID to click action, rebuilt every frame.
    clicks: std.AutoHashMapUnmanaged(u32, Action) = .empty,
    make_text: *const fn (core: *Core, string: []const u8, style: layout.text.Style) Allocator.Error!*layout.Content,

    /// Guards `queue`, the only state touched from other threads.
    queue_mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(Message) = .empty,
    /// The batch being processed, swapped with `queue` so new messages can
    /// be queued while it runs.
    batch: std.ArrayList(Message) = .empty,
    /// An error from `Update.emit`, returned by the next frame or input.
    deferred_error: ?Allocator.Error = null,

    /// Keyed element IDs under the pointer: the hit element first, then its
    /// ancestors.
    hovered: std.ArrayList(u32) = .empty,
    /// Scratch for the next `hovered`, swapped in by `hitTest`.
    next_hovered: std.ArrayList(u32) = .empty,
    /// `hovered` as of the primary button press, until it is released.
    pressed: std.ArrayList(u32) = .empty,
    /// The element the primary button press would click.
    press_target: ?u32 = null,
    primary_down: bool = false,

    dirty: bool = true,

    fn deinit(self: *Core) void {
        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| {
            instance.*.destroy(self.gpa, instance.*);
        }
        self.instances.deinit(self.gpa);
        self.stateless.deinit(self.gpa);

        for (self.queue.items) |message| message.discard(self.gpa);
        for (self.batch.items) |message| message.discard(self.gpa);
        self.queue.deinit(self.gpa);
        self.batch.deinit(self.gpa);

        self.clicks.deinit(self.gpa);
        self.hovered.deinit(self.gpa);
        self.next_hovered.deinit(self.gpa);
        self.pressed.deinit(self.gpa);
        self.context.deinit(self.gpa);
        self.arena.deinit();
    }

    fn frame(self: *Core, comptime Root: type, props: Root.Props, root: layout.Config) anyerror!layout.RenderCommand.Iterator {
        // Messages run before the arena is reset, while the click payloads
        // of the frame that queued them are alive.
        try self.processMessages();

        _ = self.arena.reset(.retain_capacity);
        self.clicks.clearRetainingCapacity();
        self.stateless.clearRetainingCapacity();
        self.laid_out = false;

        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| {
            instance.*.seen = false;
        }

        // a failed view leaves containers open; drop them so the next frame can begin
        errdefer self.context.stack.clearRetainingCapacity();

        self.context.begin(root);
        const parent: Ui = .{ .core = self, .scope = root_parent, .owners = null };
        try self.render(&parent, Root, {}, props);
        self.context.end();

        try self.context.computeLayout();
        self.laid_out = true;

        try self.sweep();
        self.dirty = false;

        return self.context.renderCommands();
    }

    fn render(self: *Core, parent: *const Ui, comptime C: type, key: anytype, props: C.Props) anyerror!void {
        const id = instanceId(parent.scope, C, key);

        switch (comptime componentKind(C)) {
            .stateless => {
                const gop = try self.stateless.getOrPut(self.gpa, id);
                if (gop.found_existing) {
                    // the same component type was rendered twice with the same key
                    return error.DuplicateKey;
                }

                var ui: Ui = .{ .core = self, .scope = id, .owners = parent.owners };
                try C.view(&ui, props);
                // every `open` needs a matching `close`
                std.debug.assert(ui.depth == 0);
            },
            .stateful => {
                const gop = try self.instances.getOrPut(self.gpa, id);
                if (!gop.found_existing) {
                    errdefer _ = self.instances.remove(id);
                    const storage = try self.gpa.create(Storage(C));
                    storage.* = .{ .instance = .{ .id = id, .type_tag = typeTag(C), .destroy = Storage(C).destroy } };
                    gop.value_ptr.* = &storage.instance;
                }

                const storage: *Storage(C) = @fieldParentPtr("instance", gop.value_ptr.*);
                if (storage.instance.seen) {
                    // the same component type was rendered twice with the same key
                    return error.DuplicateKey;
                }
                storage.instance.seen = true;
                storage.props = props;

                const owner: Ancestor = .{ .parent = parent.owners, .instance = id, .type_tag = typeTag(C) };
                var ui: Ui = .{ .core = self, .scope = id, .owners = &owner };
                try C.view(&ui, &storage.state, props);
                // every `open` needs a matching `close`
                std.debug.assert(ui.depth == 0);
            },
        }
    }

    /// Destroys every stateful instance that wasn't rendered this frame.
    fn sweep(self: *Core) Allocator.Error!void {
        var gone: std.ArrayList(InstanceId) = .empty;
        var entries = self.instances.iterator();
        while (entries.next()) |entry| {
            if (!entry.value_ptr.*.seen) {
                try gone.append(self.arena.allocator(), entry.key_ptr.*);
            }
        }

        for (gone.items) |id| {
            const instance = self.instances.fetchRemove(id).?.value;
            instance.destroy(self.gpa, instance);
        }
    }

    fn enqueue(self: *Core, message: Message) Allocator.Error!void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        self.queue.append(self.gpa, message) catch |err| {
            message.discard(self.gpa);
            return err;
        };
    }

    fn hasQueued(self: *Core) bool {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        return self.queue.items.len > 0;
    }

    /// Delivers queued messages in FIFO order, including any queued while
    /// processing, until the queue is empty. A message is only delivered
    /// to an instance of the component it was made for.
    fn processMessages(self: *Core) Allocator.Error!void {
        while (true) {
            {
                self.queue_mutex.lockUncancelable(self.io);
                defer self.queue_mutex.unlock(self.io);

                std.mem.swap(std.ArrayList(Message), &self.queue, &self.batch);
            }

            if (self.batch.items.len == 0) break;

            for (self.batch.items) |message| {
                const instance = self.instances.get(message.target) orelse {
                    message.discard(self.gpa);
                    continue;
                };
                if (instance.type_tag != message.type_tag) {
                    // a hash collision or a misbound action: never cast to the wrong type
                    message.discard(self.gpa);
                    continue;
                }
                // anything queued from here on goes to `queue` and runs after this batch
                message.vtable.deliver(self, instance, message.msg);
                self.dirty = true;
            }
            self.batch.clearRetainingCapacity();
        }

        if (self.deferred_error) |err| {
            self.deferred_error = null;
            return err;
        }
    }

    fn mouse(self: *Core, event: MouseEvent) Allocator.Error!void {
        try self.hitTest(event.position);

        const down = event.pressed.isSet(MouseEvent.primary);
        if (down and !self.primary_down) {
            try self.pressed.appendSlice(self.gpa, self.hovered.items);
            self.press_target = self.clickTarget();
            if (self.pressed.items.len > 0) self.dirty = true;
        } else if (!down and self.primary_down) {
            const release_target = self.clickTarget();
            if (self.press_target != null and self.press_target == release_target) {
                const action = self.clicks.get(release_target.?).?;
                try self.enqueue(try action.message(self.gpa, action.target, action.payload, false));
            }
            if (self.pressed.items.len > 0) self.dirty = true;
            self.pressed.clearRetainingCapacity();
            self.press_target = null;
        }
        self.primary_down = down;

        try self.processMessages();
    }

    /// Recomputes `hovered` for `point`, marking the runtime dirty if it
    /// changed.
    fn hitTest(self: *Core, point: Vec2) Allocator.Error!void {
        self.next_hovered.clearRetainingCapacity();
        if (self.laid_out) {
            const units = self.context.units.items;
            var i = units.len;
            const hit: ?usize = while (i > 1) {
                i -= 1;
                if (units[i].hovered(point) and !clippedAway(units, i, point)) break i;
            } else null;

            var index = hit orelse 0;
            while (index != 0) : (index = units[index].parent) {
                if (units[index].id != 0) {
                    try self.next_hovered.append(self.gpa, units[index].id);
                }
            }
        }

        if (!std.mem.eql(u32, self.hovered.items, self.next_hovered.items)) {
            self.dirty = true;
        }
        std.mem.swap(std.ArrayList(u32), &self.hovered, &self.next_hovered);
    }

    /// The nearest hovered element with an `on_click`.
    fn clickTarget(self: *const Core) ?u32 {
        for (self.hovered.items) |id| {
            if (self.clicks.contains(id)) return id;
        }
        return null;
    }
};

/// Whether an ancestor of `units[index]` clips `point` away.
fn clippedAway(units: []const layout.Unit, index: usize, point: Vec2) bool {
    var ancestor = units[index].parent;
    while (true) : (ancestor = units[ancestor].parent) {
        const unit = &units[ancestor];
        if (unit.data == .container) {
            const clip = unit.data.container.clip;
            const box = unit.bbox;
            if (clip.horizontal and (point.x < box.x or point.x >= box.x + box.w)) return true;
            if (clip.vertical and (point.y < box.y or point.y >= box.y + box.h)) return true;
        }
        if (ancestor == 0) return false;
    }
}

fn bindHandler(comptime C: type, core: *Core, target: InstanceId, comptime tag: std.meta.Tag(C.Msg)) Handler(@FieldType(C.Msg, @tagName(tag))) {
    return .{ .core = core, .target = target, .message = Envelope(C).fromPayload(tag) };
}

/// Builds `Ui.Container`: the fields of `layout.ContainerDeclaration`
/// except `id`, plus `on_click`. Generating it keeps the two in sync.
fn ContainerOptions() type {
    const decl = @typeInfo(layout.ContainerDeclaration).@"struct";
    const n = decl.field_names.len;

    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;

    var len: usize = 0;
    for (decl.field_names, decl.field_types, decl.field_attrs) |name, T, attr| {
        if (std.mem.eql(u8, name, "id")) continue;
        names[len] = name;
        types[len] = T;
        attrs[len] = attr;
        len += 1;
    }
    std.debug.assert(len == n - 1);

    const no_click: ?Action = null;
    names[len] = "on_click";
    types[len] = ?Action;
    attrs[len] = .{ .default_value_ptr = &no_click };

    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn declaration(options: Ui.Container) layout.ContainerDeclaration {
    var decl: layout.ContainerDeclaration = .{};
    inline for (@typeInfo(Ui.Container).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "on_click")) {
            @field(decl, name) = @field(options, name);
        }
    }
    return decl;
}

/// The ID of the instance of `C` rendered by `parent` with `key`.
fn instanceId(parent: InstanceId, comptime C: type, key: anytype) InstanceId {
    var hasher = std.hash.Wyhash.init(parent);
    hasher.update(@typeName(C));
    hashKey(&hasher, key);
    return hasher.final();
}

/// The layout unit ID of the element with `key` in `instance`. Never zero,
/// since zero means "no ID" to the layout.
fn elementId(instance: InstanceId, key: anytype) layout.Unit.Id {
    var hasher = std.hash.Wyhash.init(instance);
    hashKey(&hasher, key);
    const id: u32 = @truncate(hasher.final());
    return .fromInt(if (id == 0) 1 else id);
}

/// Hashes a key so that equal values hash equally whatever their type:
/// string literals and slices, integer types and comptime integers, and enum
/// values and enum literals with the same name.
fn hashKey(hasher: *std.hash.Wyhash, key: anytype) void {
    const K = @TypeOf(key);
    switch (@typeInfo(K)) {
        .void => {},
        .int, .comptime_int => {
            const value: i128 = key;
            hasher.update("i");
            hasher.update(std.mem.asBytes(&value));
        },
        .enum_literal, .@"enum" => hashKey(hasher, @as([]const u8, @tagName(key))),
        else => if (comptime isString(K)) {
            const bytes: []const u8 = key;
            hasher.update("s");
            hasher.update(bytes);
        } else {
            hasher.update(@typeName(K));
            std.hash.autoHashStrat(hasher, key, .Deep);
        },
    }
}

fn isString(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

const Kind = enum { stateless, stateful };

/// `C.Props`, once `C` is checked to be a component.
fn PropsOf(comptime C: type) type {
    _ = componentKind(C);
    return C.Props;
}

/// `C.Msg`, for binding to `C`.
fn MsgOf(comptime C: type) type {
    _ = componentKind(C);
    if (!@hasDecl(C, "Msg")) @compileError(@typeName(C) ++ " has no `Msg` to bind to");
    return C.Msg;
}

/// Checks that `C` has one of the two component shapes, and says which.
fn componentKind(comptime C: type) Kind {
    const shapes =
        \\. A component is a namespace with `pub const Props` and one of:
        \\  stateless: pub fn view(ui: *app.Ui, props: Props) !void
        \\             (and no `State`, `Msg` or `update`)
        \\  stateful:  pub const State, and
        \\             pub fn view(ui: *app.Ui, state: *const State, props: Props) !void
        \\             with, optionally, both of
        \\             pub const Msg
        \\             pub fn update(state: *State, msg: Msg, ctx: *app.Update(Self)) void
    ;
    const Fail = struct {
        fn because(comptime why: []const u8) noreturn {
            @compileError(@typeName(C) ++ " is not a component: " ++ why ++ shapes);
        }

        fn params(comptime name: []const u8, comptime f: anytype, comptime expected: []const type, comptime since: []const u8) void {
            const info = @typeInfo(@TypeOf(f)).@"fn";
            if (info.param_types.len != expected.len) {
                because(std.fmt.comptimePrint("{s}`{s}` takes {d} parameters, not {d}", .{ since, name, expected.len, info.param_types.len }));
            }
            for (info.param_types, expected, 0..) |actual, wanted, i| {
                if (actual != wanted) {
                    because(std.fmt.comptimePrint("parameter {d} of `{s}` must be `{s}`", .{ i + 1, name, @typeName(wanted) }));
                }
            }
        }
    };

    switch (@typeInfo(C)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => Fail.because("it is not a namespace"),
    }
    if (!@hasDecl(C, "Props")) Fail.because("it has no `pub const Props`");
    if (!@hasDecl(C, "view")) Fail.because("it has no `pub fn view`");

    const has_state = @hasDecl(C, "State");
    const has_msg = @hasDecl(C, "Msg");
    const has_update = @hasDecl(C, "update");
    if (has_msg and !has_update) Fail.because("it has a `Msg` but no `update`");
    if (has_update and !has_msg) Fail.because("it has an `update` but no `Msg`");
    if (has_msg and !has_state) Fail.because("it has a `Msg` but no `State`");

    if (has_state) {
        Fail.params("view", C.view, &.{ *Ui, *const C.State, C.Props }, "it has a `State`, so ");
    } else {
        Fail.params("view", C.view, &.{ *Ui, C.Props }, "it has no `State`, so ");
    }
    if (has_update) {
        Fail.params("update", C.update, &.{ *C.State, C.Msg, *Update(C) }, "");
    }
    return if (has_state) .stateful else .stateless;
}

const testing = std.testing;

const TestRuntime = Runtime(.{});

/// Number of `Counter.State.deinit` calls, to check instances are swept.
var counter_deinits: usize = 0;

/// A rounded button around a text label, as a view helper.
fn testButton(ui: *Ui, key: []const u8, label: []const u8, on_click: ?Action) !void {
    try ui.open(key, .{
        .layout = .{ .padding = .all(6) },
        .background_color = if (ui.pressed(key)) .gray(150) else if (ui.hovered(key)) .gray(200) else .gray(230),
        .corner_radius = .uniform(8),
        .on_click = on_click,
    });
    defer ui.close();
    try ui.text(label, .{});
}

const Counter = struct {
    pub const State = struct {
        count: i32 = 0,
        /// Allocated, so a missing `deinit` leaks under the testing allocator.
        history: std.ArrayList(i32) = .empty,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.history.deinit(gpa);
            counter_deinits += 1;
        }
    };

    pub const Msg = union(enum) { increment, decrement };

    pub const Props = struct {
        label: []const u8,
        step: i32 = 1,
        on_change: ?Handler(i32) = null,
        on_step: ?Handler(i32) = null,
    };

    pub fn update(state: *State, msg: Msg, ctx: *Update(Counter)) void {
        switch (msg) {
            .increment => state.count += ctx.props.step,
            .decrement => state.count -= ctx.props.step,
        }
        state.history.append(ctx.gpa, state.count) catch {};
        // one update emitting two messages
        ctx.emit(ctx.props.on_change, state.count);
        ctx.emit(ctx.props.on_step, ctx.props.step);
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        try ui.open("row", .{ .layout = .{ .child_gap = 4, .child_alignment = .center_left } });
        defer ui.close();

        try ui.print(.{}, "{s} = {d}", .{ props.label, state.count });
        try testButton(ui, "inc", try ui.fmt("{s} +", .{props.label}), try ui.bind(Counter, .increment));
        try testButton(ui, "dec", try ui.fmt("{s} -", .{props.label}), try ui.bind(Counter, .decrement));
    }
};

const App = struct {
    pub const State = struct {
        counters: usize = 2,
        changes: u32 = 0,
        log: [16]Entry = undefined,
        log_len: usize = 0,

        fn record(self: *State, entry: Entry) void {
            self.log[self.log_len] = entry;
            self.log_len += 1;
        }
    };

    const Entry = union(enum) { changed: i32, step: i32, echo: i32 };

    pub const Msg = union(enum) {
        add_counter,
        remove_counter,
        counter_changed: i32,
        counter_step: i32,
        echo: i32,
    };

    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *Update(App)) void {
        switch (msg) {
            .add_counter => state.counters += 1,
            .remove_counter => state.counters -|= 1,
            .counter_changed => |value| {
                state.changes += 1;
                state.record(.{ .changed = value });
                // queued behind the `counter_step` Counter already emitted
                ctx.emit(ctx.handler(.echo), value);
            },
            .counter_step => |step| state.record(.{ .step = step }),
            .echo => |value| state.record(.{ .echo = value }),
        }
    }

    pub fn view(ui: *Ui, state: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 8, .sizing = .grow(.{}) } });
        defer ui.close();

        try ui.print(.{}, "changes = {d}", .{state.changes});
        try testButton(ui, "add", "add", try ui.bind(App, .add_counter));
        try testButton(ui, "remove", "remove", try ui.bind(App, .remove_counter));
        for (0..state.counters) |i| {
            try ui.child(Counter, i, .{
                .label = try ui.fmt("c{d}", .{i}),
                .step = @intCast(i + 1),
                // checked at comptime: .counter_changed carries i32, matching Handler(i32)
                .on_change = ui.handler(App, .counter_changed),
                .on_step = ui.handler(App, .counter_step),
            });
        }
    }
};

fn testFrame(rt: *TestRuntime) !void {
    _ = try rt.frame(App, .{}, .init(400, 300));
}

fn findText(rt: *TestRuntime, string: []const u8) ?*const layout.Unit {
    for (rt.context().units.items) |*unit| {
        if (unit.data != .content) continue;
        const t = TestRuntime.Text.asTextContent(unit.data.content) orelse continue;
        if (std.mem.eql(u8, t.text, string)) return unit;
    }
    return null;
}

fn hasText(rt: *TestRuntime, string: []const u8) bool {
    return findText(rt, string) != null;
}

/// The container around the text `label`, such as a button.
fn findButton(rt: *TestRuntime, label: []const u8) !*const layout.Unit {
    const t = findText(rt, label) orelse return error.NoSuchText;
    return rt.context().getUnitByIndex(t.parent).?;
}

fn center(rect: fabrum.Rect) Vec2 {
    return .init(rect.x + rect.w / 2, rect.y + rect.h / 2);
}

fn press(rt: *TestRuntime, point: Vec2) !void {
    var buttons: MouseEvent.Buttons = .empty;
    buttons.set(MouseEvent.primary);
    try rt.mouse(.{ .position = point, .pressed = buttons });
}

fn release(rt: *TestRuntime, point: Vec2) !void {
    try rt.mouse(.{ .position = point });
}

/// Presses and releases at the center of the button labelled `label`.
fn clickButton(rt: *TestRuntime, label: []const u8) !void {
    const point = center((try findButton(rt, label)).bbox);
    try press(rt, point);
    try release(rt, point);
}

test "components keep local state across frames, independently per instance" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    try testing.expect(rt.needsFrame());
    try testFrame(&rt);
    try testing.expect(!rt.needsFrame());
    try testing.expect(hasText(&rt, "c0 = 0"));
    try testing.expect(hasText(&rt, "c1 = 0"));

    try clickButton(&rt, "c1 +");
    try testing.expect(rt.needsFrame());
    try testFrame(&rt);
    try testing.expect(!rt.needsFrame());
    try testing.expect(hasText(&rt, "c1 = 2")); // step 2, local to c1
    try testing.expect(hasText(&rt, "c0 = 0")); // c0 untouched

    try clickButton(&rt, "c0 +");
    try clickButton(&rt, "c0 +");
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "c0 = 2"));
    try testing.expect(hasText(&rt, "c1 = 2"));
}

test "children emit to their parent through handlers, in FIFO order" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    try testing.expectEqual(null, rt.rootState(App));
    try testFrame(&rt);
    try clickButton(&rt, "c1 +");
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "changes = 1"));

    const app_state = rt.rootState(App).?;

    // Counter emitted `changed` then `step`; App's `echo`, emitted while
    // handling `changed`, is queued behind `step` rather than run inline.
    try testing.expectEqualSlices(App.Entry, &.{
        .{ .changed = 2 },
        .{ .step = 2 },
        .{ .echo = 2 },
    }, app_state.log[0..app_state.log_len]);

    try clickButton(&rt, "c0 -");
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "changes = 2"));
    try testing.expectEqualSlices(App.Entry, &.{
        .{ .changed = -1 },
        .{ .step = 1 },
        .{ .echo = -1 },
    }, app_state.log[3..app_state.log_len]);
}

test "unrendered instances are destroyed and re-added ones start fresh" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    counter_deinits = 0;

    try testFrame(&rt);
    try clickButton(&rt, "c1 +");
    try clickButton(&rt, "remove");
    try testFrame(&rt);
    try testing.expect(!hasText(&rt, "c1 = 2")); // c1 no longer rendered
    try testing.expectEqual(1, counter_deinits); // and its state was freed

    try clickButton(&rt, "add");
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "c1 = 0")); // fresh instance
    try testing.expectEqual(1, counter_deinits);
}

test "hover and press marks the runtime dirty and is visible to the next view" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    const idle: fabrum.Color = .gray(230);
    const hover: fabrum.Color = .gray(200);
    const pressed: fabrum.Color = .gray(150);

    try testFrame(&rt);
    const point = center((try findButton(&rt, "c0 +")).bbox);

    try rt.mouse(.{ .position = point });
    try testing.expect(rt.needsFrame());
    // the current layout was built before the pointer moved
    try testing.expectEqual(idle, (try findButton(&rt, "c0 +")).data.container.background_color);

    try testFrame(&rt);
    try testing.expectEqual(hover, (try findButton(&rt, "c0 +")).data.container.background_color);
    try testing.expectEqual(idle, (try findButton(&rt, "c1 +")).data.container.background_color);

    // moving within the same element changes nothing
    try rt.mouse(.{ .position = point.addValues(1, 0) });
    try testing.expect(!rt.needsFrame());

    try press(&rt, point);
    try testing.expect(rt.needsFrame());
    try testFrame(&rt);
    try testing.expectEqual(pressed, (try findButton(&rt, "c0 +")).data.container.background_color);

    try release(&rt, point);
    try rt.mouse(.{ .position = .init(399, 299) });
    try testing.expect(rt.needsFrame());
    try testFrame(&rt);
    try testing.expectEqual(idle, (try findButton(&rt, "c0 +")).data.container.background_color);
    try testing.expect(hasText(&rt, "c0 = 1"));
}

test "clicks respect rounded corners and need press and release on one element" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    try testFrame(&rt);
    const button = (try findButton(&rt, "c0 +")).bbox;

    // inside the bounding box, but cut away by the 8px corner radius
    const corner: Vec2 = .init(button.x + 1, button.y + 1);
    try press(&rt, corner);
    try release(&rt, corner);
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "c0 = 0"));

    // just inside the straight top edge is part of the shape
    const edge: Vec2 = .init(button.x + button.w / 2, button.y + 1);
    try press(&rt, edge);
    try release(&rt, edge);
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "c0 = 1"));

    // pressed on one button, released on another
    try press(&rt, center((try findButton(&rt, "c0 +")).bbox));
    try release(&rt, center((try findButton(&rt, "c0 -")).bbox));
    try testFrame(&rt);
    try testing.expect(hasText(&rt, "c0 = 1"));
}

test "the cursor points over clickable elements and their labels" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    try testing.expectEqual(Cursor.default, rt.cursor());
    try testFrame(&rt);

    // the label inside the button bubbles up to its on_click
    const label = findText(&rt, "c0 +").?;
    try rt.mouse(.{ .position = center(label.bbox) });
    try testing.expectEqual(Cursor.pointer, rt.cursor());

    // plain text has nothing to click
    try rt.mouse(.{ .position = center(findText(&rt, "changes = 0").?.bbox) });
    try testing.expectEqual(Cursor.default, rt.cursor());

    try rt.mouse(.{ .position = .init(399, 299) });
    try testing.expectEqual(Cursor.default, rt.cursor());
}

const Loader = struct {
    pub const State = struct { value: ?i32 = null };
    pub const Msg = union(enum) { loaded: i32 };
    pub const Props = struct { handler: *?Handler(i32) };

    pub fn update(state: *State, msg: Msg, _: *Update(Loader)) void {
        switch (msg) {
            .loaded => |value| state.value = value,
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        props.handler.* = ui.handler(Loader, .loaded);
        if (state.value) |value| {
            try ui.print(.{}, "loaded {d}", .{value});
        } else {
            try ui.text("waiting", .{});
        }
    }
};

test "messages posted from another thread wake the platform and apply next frame" {
    const Wake = struct {
        requests: std.atomic.Value(u32) = .init(0),

        fn requestFrame(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.requests.fetchAdd(1, .seq_cst);
        }

        fn post(poster: Poster, handler: Handler(i32), value: i32) void {
            poster.post(handler, value) catch @panic("post failed");
        }
    };

    var wake: Wake = .{};
    var rt: TestRuntime = try .init(testing.allocator, .{
        .io = testing.io,
        .platform = .{ .ptr = &wake, .vtable = &.{ .requestFrame = Wake.requestFrame } },
    });
    defer rt.deinit();

    var handler: ?Handler(i32) = null;
    _ = try rt.frame(Loader, .{ .handler = &handler }, .init(200, 100));
    try testing.expect(hasText(&rt, "waiting"));
    try testing.expect(!rt.needsFrame());

    const thread = try std.Thread.spawn(.{}, Wake.post, .{ rt.poster(), handler.?, 42 });
    thread.join();

    try testing.expectEqual(1, wake.requests.load(.seq_cst));
    try testing.expect(rt.needsFrame()); // queued, not yet applied
    try testing.expect(hasText(&rt, "waiting"));

    _ = try rt.frame(Loader, .{ .handler = &handler }, .init(200, 100));
    try testing.expect(hasText(&rt, "loaded 42"));
    try testing.expect(!rt.needsFrame());
}

const Owner = struct {
    pub const State = struct {
        name: ?[]u8 = null,

        pub fn deinit(self: *State, gpa: Allocator) void {
            if (self.name) |name| gpa.free(name);
        }
    };

    pub const Msg = union(enum) {
        rename: []u8,

        pub fn deinit(self: *Msg, gpa: Allocator) void {
            switch (self.*) {
                .rename => |name| gpa.free(name),
            }
        }
    };

    pub const Props = struct { handler: *?Handler([]u8) };

    pub fn update(state: *State, msg: Msg, ctx: *Update(Owner)) void {
        switch (msg) {
            .rename => |name| {
                // the payload is ours now: keep it, free what it replaces
                if (state.name) |old| ctx.gpa.free(old);
                state.name = name;
            },
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        props.handler.* = ui.handler(Owner, .rename);
        try ui.text(state.name orelse "unnamed", .{});
    }
};

test "messages own their payload until delivered or discarded" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    var handler: ?Handler([]u8) = null;
    _ = try rt.frame(Owner, .{ .handler = &handler }, .init(200, 100));

    try rt.post(handler, try testing.allocator.dupe(u8, "first"));
    try rt.post(handler, try testing.allocator.dupe(u8, "second"));
    _ = try rt.frame(Owner, .{ .handler = &handler }, .init(200, 100));
    try testing.expect(hasText(&rt, "second"));

    // still queued at deinit: discarded through `Msg.deinit`
    try rt.post(handler, try testing.allocator.dupe(u8, "third"));
}

test "a message is never delivered to an instance of another component" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    _ = try rt.frame(Board, .{}, .init(400, 300));
    const panel = instanceId(instanceId(root_parent, Board, {}), Panel, "p");
    try testing.expect(rt.core.instances.contains(panel));

    // messages for other components aimed at a `Panel`, as a hash
    // collision or a misbound action would make: discarded rather than
    // cast, and an owned payload is still freed through `Msg.deinit`
    try rt.post(bindHandler(App, &rt.core, panel, .echo), 7);
    try rt.post(bindHandler(Owner, &rt.core, panel, .rename), try testing.allocator.dupe(u8, "lost"));
    // while the `Panel`'s own messages still arrive
    try rt.post(bindHandler(Panel, &rt.core, panel, .set), 3);

    _ = try rt.frame(Board, .{}, .init(400, 300));
    try testing.expect(hasText(&rt, "p = 3"));
}

test "element and instance keys hash by value" {
    try testing.expectEqual(elementId(1, "a"), elementId(1, @as([]const u8, "a")));
    try testing.expectEqual(elementId(1, 3), elementId(1, @as(usize, 3)));
    try testing.expectEqual(elementId(1, .x), elementId(1, Vec2.Axis.x));
    try testing.expect(elementId(1, "a").id != elementId(2, "a").id);
    try testing.expect(instanceId(0, App, 0) != instanceId(0, Counter, 0));
}

/// A stateless component: buttons that bind to the `Panel` rendering them,
/// and to a handler `Panel` passes down.
const Toolbar = struct {
    pub const Props = struct {
        name: []const u8,
        on_reset: Action,
    };

    pub fn view(ui: *Ui, props: Props) !void {
        // the same keys in every toolbar, which never collide
        try ui.open("bar", .{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        try testButton(ui, "bump", try ui.fmt("{s} bump", .{props.name}), try ui.bind(Panel, .bump));
        try testButton(ui, "reset", try ui.fmt("{s} reset", .{props.name}), props.on_reset);
    }
};

const Panel = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { bump, reset, set: i32 };
    pub const Props = struct { name: []const u8 };

    pub fn update(state: *State, msg: Msg, _: *Update(Panel)) void {
        switch (msg) {
            .bump => state.count += 1,
            .reset => state.count = 0,
            .set => |value| state.count = value,
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 4 } });
        defer ui.close();
        try ui.print(.{}, "{s} = {d}", .{ props.name, state.count });
        try ui.child(Toolbar, {}, .{ .name = props.name, .on_reset = ui.handler(Panel, .reset).action() });
        try testButton(ui, "set", try ui.fmt("{s} set", .{props.name}), try ui.handler(Panel, .set).with(7));
    }
};

/// A stateless root over two panels.
const Board = struct {
    pub const Props = struct { names: []const []const u8 = &.{ "p", "q" } };

    pub fn view(ui: *Ui, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 8 } });
        defer ui.close();
        for (props.names) |name| try ui.child(Panel, name, .{ .name = name });
    }
};

test "stateless components keep their own keys, store nothing and bind to stateful ancestors" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    _ = try rt.frame(Board, .{}, .init(400, 300));
    // two panels; neither the board nor the toolbars are stored
    try testing.expectEqual(2, rt.core.instances.count());
    try testing.expect(hasText(&rt, "p = 0"));

    // the toolbar's button binds to the panel around it, not the other one
    try clickButton(&rt, "q bump");
    try clickButton(&rt, "q bump");
    _ = try rt.frame(Board, .{}, .init(400, 300));
    try testing.expect(hasText(&rt, "p = 0"));
    try testing.expect(hasText(&rt, "q = 2"));

    // a handler with a payload, and one passed down to a stateless child
    try clickButton(&rt, "p set");
    try clickButton(&rt, "q reset");
    _ = try rt.frame(Board, .{}, .init(400, 300));
    try testing.expect(hasText(&rt, "p = 7"));
    try testing.expect(hasText(&rt, "q = 0"));

    // repeated keys are an error for stateless children too
    try testing.expectError(error.DuplicateKey, rt.frame(Board, .{ .names = &.{ "p", "p" } }, .init(400, 300)));
}

test "text is copied, so views can show strings from stack buffers" {
    const Stack = struct {
        pub const Props = struct {};

        pub fn view(ui: *Ui, _: Props) !void {
            try ui.open(null, .{ .layout = .{ .axis = .y } });
            defer ui.close();
            var buffer: [16]u8 = undefined;
            try ui.text(try std.fmt.bufPrint(&buffer, "first {d}", .{1}), .{});
            try ui.text(try std.fmt.bufPrint(&buffer, "second {d}", .{2}), .{});
            try ui.print(.{}, "{s} and {d}", .{ "third", 3 });
            ui.spacer();
        }
    };

    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    _ = try rt.frame(Stack, .{}, .init(200, 100));
    try testing.expect(hasText(&rt, "first 1"));
    try testing.expect(hasText(&rt, "second 2"));
    try testing.expect(hasText(&rt, "third and 3"));
}
