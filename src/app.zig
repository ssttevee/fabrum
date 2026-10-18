//! The application runtime: the Elm architecture (TEA) on top of
//! `fabrum.layout`.
//!
//! An app is a tree of components. A component is a namespace with:
//!
//! ```zig
//! const Counter = struct {
//!     pub const State = struct { count: i32 = 0 }; // optional `deinit(gpa)`
//!     pub const Msg = union(enum) { increment, decrement };
//!     pub const Props = struct { step: i32 = 1, on_change: ?app.Handler(i32) = null };
//!     pub fn update(state: *State, msg: Msg, ctx: *app.Update(Counter)) void { ... }
//!     pub fn view(ui: *app.Scope(Counter), state: *const State, props: Props) !void { ... }
//! };
//! ```
//!
//! Every frame, `Runtime.frame` runs `view` from the root component down and
//! rebuilds the layout from scratch. Views read state and describe elements;
//! they never change state. State only changes in `update`, in response to a
//! message.
//!
//! ## Instances
//!
//! Each rendered component is an instance whose identity is a hash of its
//! parent instance, its component type and the key it was rendered with (see
//! `Scope.child`). An instance's `State` is created with default values the
//! first time it is rendered, and destroyed after the first frame that
//! doesn't render it, calling `State.deinit(gpa)` if it is declared.
//! Repeated children need distinct keys, as with React list keys.
//!
//! ## Messages
//!
//! Messages are values. Elements carry the component's own `Msg` (for example
//! `.on_click = .increment`), and children talk to their parents through
//! `Handler`s that the parent binds with `Scope.handler`. Emitting or posting
//! a message only queues it; the queue is processed in FIFO order at the start
//! of each frame and after each input event. Every delivered message marks
//! the runtime dirty. Messages can be posted from other threads through a
//! `Poster`, which also asks the `Platform` for a frame.
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
//!   it and must store or free it. A message that can't be delivered (its
//!   instance is gone, or queueing failed) is discarded, calling
//!   `Msg.deinit(gpa)` if it is declared.
//! - `on_click` messages are copied from the frame that rendered them, so
//!   their payload is frame memory: `update` must copy anything it keeps.
//! - State owns everything it stores, allocated with `Update.gpa`, and frees
//!   it in `State.deinit(gpa)`.
//! - Views allocate only from the frame arena (`Scope.arena`, `Scope.fmt`).
//!   It is reset at the start of the next frame, after the previous frame's
//!   render commands have been consumed.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

/// Identifies a component instance: a hash of the parent instance ID, the
/// component type and the instance's key.
pub const InstanceId = u64;

/// The parent ID used for the root component.
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

/// A child-to-parent event: one of the owner's `Msg` tags, bound to the owner
/// instance. The child only knows the payload type, not the owner's `Msg`.
///
/// Created with `Scope.handler` or `Update.handler`, and fired with
/// `Update.emit` or `Poster.post`.
pub fn Handler(comptime P: type) type {
    return struct {
        instance: InstanceId,
        message: *const fn (gpa: Allocator, instance: InstanceId, payload: P) Allocator.Error!Message,

        pub const Payload = P;
    };
}

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
            const message = h.message(self.gpa, h.instance, payload) catch |err| {
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
            return bindHandler(C, self.instance, tag);
        }

        /// A thread-safe handle for posting messages from background work.
        pub fn poster(self: *const Self) Poster {
            return .{ .core = self.core };
        }
    };
}

/// Passed to `view`: builds elements into the frame's layout. Element events
/// are typed against `C.Msg`, and element IDs are derived from the instance,
/// so keys only need to be unique within one component.
pub fn Scope(comptime C: type) type {
    return struct {
        core: *Core,
        instance: InstanceId,
        /// Number of containers this scope opened and hasn't closed yet.
        depth: usize = 0,

        const Self = @This();

        /// A `layout.ContainerDeclaration` (without its unused `id`) plus the
        /// element's events:
        ///
        /// - `on_click: ?C.Msg = null`: queued when the element is clicked.
        pub const Container = ContainerOptions(C.Msg);

        /// The frame arena. Everything allocated from it is freed at the
        /// start of the next frame.
        pub fn arena(self: *const Self) Allocator {
            return self.core.arena.allocator();
        }

        /// Formats a string into the frame arena.
        pub fn fmt(self: *const Self, comptime format: []const u8, args: anytype) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(self.arena(), format, args);
        }

        /// The raw layout context, for anything the scope doesn't wrap. Units
        /// appended here are added to the currently open container.
        pub fn context(self: *const Self) *layout.Context {
            return &self.core.context;
        }

        /// The layout unit ID of this instance's element with `key`.
        pub fn id(self: *const Self, key: anytype) layout.Unit.Id {
            return elementId(self.instance, key);
        }

        /// Opens a container. Must be finished with a matching `close`,
        /// usually `defer ui.close()`.
        ///
        /// `key` identifies the element within this component, for `id`,
        /// `hovered`, `pressed` and events. It can be a string, integer, enum
        /// or any hashable value. Pass `null` for an anonymous container,
        /// which can't have events.
        pub fn open(self: *Self, key: anytype, container: Container) !void {
            const decl = declaration(Container, container);
            const ctx = &self.core.context;

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

            if (container.on_click) |msg| {
                const stored = try self.arena().create(C.Msg);
                stored.* = msg;
                try self.core.clicks.put(self.core.gpa, unit_id.id, .{
                    .instance = self.instance,
                    .msg = stored,
                    .message = Envelope(C).clickMessage,
                });
            }

            _ = ctx.openContainerId(unit_id, decl);
            self.depth += 1;
        }

        /// Closes the container most recently opened by this scope.
        pub fn close(self: *Self) void {
            std.debug.assert(self.depth > 0);
            self.depth -= 1;
            const ctx = &self.core.context;
            ctx.closeContainer(ctx.stack.getLast());
        }

        /// Appends text, allocated in the frame arena. `string` must live
        /// until the frame's render commands are consumed.
        pub fn text(self: *Self, string: []const u8, style: layout.text.Style) Allocator.Error!void {
            self.core.context.appendContent(try self.core.make_text(self.core, string, style));
        }

        /// Appends any layout content. `content` must live until the frame's
        /// render commands are consumed.
        pub fn content(self: *Self, c: *layout.Content) void {
            self.core.context.appendContent(c);
        }

        /// Renders a child component into the currently open container.
        /// `key` distinguishes repeated children of the same type; pass `{}`
        /// for a single child.
        pub fn child(self: *Self, comptime Child: type, key: anytype, props: Child.Props) anyerror!void {
            try self.core.render(self.instance, Child, key, props);
        }

        /// Binds one of this component's `Msg` tags so a child can emit into
        /// it. The handler's payload type is the tag's payload type.
        pub fn handler(self: *const Self, comptime tag: std.meta.Tag(C.Msg)) Handler(@FieldType(C.Msg, @tagName(tag))) {
            return bindHandler(C, self.instance, tag);
        }

        /// Whether the pointer was over the element with `key` (or one of its
        /// descendants) as of the last input event.
        pub fn hovered(self: *const Self, key: anytype) bool {
            return std.mem.indexOfScalar(u32, self.core.hovered.items, self.id(key).id) != null;
        }

        /// Whether the primary button was pressed on the element with `key`
        /// (or one of its descendants) and hasn't been released yet.
        pub fn pressed(self: *const Self, key: anytype) bool {
            return std.mem.indexOfScalar(u32, self.core.pressed.items, self.id(key).id) != null;
        }
    };
}

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
        try self.core.enqueue(try h.message(self.core.gpa, h.instance, payload));
        if (self.core.platform) |platform| {
            platform.requestFrame();
        }
    }
};

/// Compile-time options for `Runtime`.
pub const Config = struct {
    /// The text content created by `Scope.text`: a `layout.text.Content(...)`
    /// type, usually from a renderer. The default measures text with rough
    /// heuristics, which is enough for tests.
    Text: type = layout.text.HeuristicContent,
};

/// Owns component instances, the message queue, input state and the layout
/// of the last frame.
///
/// Must not be moved after `init`: scopes, handlers and posters point into
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
        pub fn frame(self: *Self, comptime Root: type, props: Root.Props, viewport: Vec2) anyerror!layout.RenderCommand.Iterator {
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

/// A queued, type-erased message for one instance.
pub const Message = struct {
    target: InstanceId,
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

/// Type-erased handle to one component instance in the store.
const Instance = struct {
    id: InstanceId,
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
            return .{ .target = target, .msg = stored, .vtable = &vtable, .owned = owned };
        }

        fn clickMessage(gpa: Allocator, target: InstanceId, msg: *const anyopaque) Allocator.Error!Message {
            return create(gpa, target, @as(*const C.Msg, @ptrCast(@alignCast(msg))).*, false);
        }

        fn deliver(core: *Core, instance: *Instance, erased: *anyopaque) void {
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

/// An `on_click` registered by the last frame.
const Click = struct {
    instance: InstanceId,
    /// The component's `Msg`, in the frame arena.
    msg: *const anyopaque,
    message: *const fn (gpa: Allocator, target: InstanceId, msg: *const anyopaque) Allocator.Error!Message,
};

/// The part of the runtime that doesn't depend on `Config`, so scopes and
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
    /// Element ID to click message, rebuilt every frame.
    clicks: std.AutoHashMapUnmanaged(u32, Click) = .empty,
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
        try self.processMessages();

        _ = self.arena.reset(.retain_capacity);
        self.clicks.clearRetainingCapacity();
        self.laid_out = false;

        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| {
            instance.*.seen = false;
        }

        // a failed view leaves containers open; drop them so the next frame can begin
        errdefer self.context.stack.clearRetainingCapacity();

        self.context.begin(root);
        try self.render(root_parent, Root, {}, props);
        self.context.end();

        try self.context.computeLayout();
        self.laid_out = true;

        try self.sweep();
        self.dirty = false;

        return self.context.renderCommands();
    }

    fn render(self: *Core, parent: InstanceId, comptime C: type, key: anytype, props: C.Props) anyerror!void {
        comptime checkComponent(C);

        const id = instanceId(parent, C, key);
        const gop = try self.instances.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            errdefer _ = self.instances.remove(id);
            const storage = try self.gpa.create(Storage(C));
            storage.* = .{ .instance = .{ .id = id, .destroy = Storage(C).destroy } };
            gop.value_ptr.* = &storage.instance;
        }

        const storage: *Storage(C) = @fieldParentPtr("instance", gop.value_ptr.*);
        if (storage.instance.seen) {
            // the same component type was rendered twice with the same key
            return error.DuplicateKey;
        }
        storage.instance.seen = true;
        storage.props = props;

        var scope: Scope(C) = .{ .core = self, .instance = id };
        try C.view(&scope, &storage.state, props);
        // every `open` needs a matching `close`
        std.debug.assert(scope.depth == 0);
    }

    /// Destroys every instance that wasn't rendered this frame.
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
    /// processing, until the queue is empty.
    fn processMessages(self: *Core) Allocator.Error!void {
        while (true) {
            {
                self.queue_mutex.lockUncancelable(self.io);
                defer self.queue_mutex.unlock(self.io);

                std.mem.swap(std.ArrayList(Message), &self.queue, &self.batch);
            }

            if (self.batch.items.len == 0) break;

            for (self.batch.items) |message| {
                if (self.instances.get(message.target)) |instance| {
                    // anything queued from here on goes to `queue` and runs after this batch
                    message.vtable.deliver(self, instance, message.msg);
                    self.dirty = true;
                } else {
                    message.discard(self.gpa);
                }
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
                const click = self.clicks.get(release_target.?).?;
                try self.enqueue(try click.message(self.gpa, click.instance, click.msg));
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

fn bindHandler(comptime C: type, instance: InstanceId, comptime tag: std.meta.Tag(C.Msg)) Handler(@FieldType(C.Msg, @tagName(tag))) {
    const Payload = @FieldType(C.Msg, @tagName(tag));
    return .{
        .instance = instance,
        .message = struct {
            fn message(gpa: Allocator, target: InstanceId, payload: Payload) Allocator.Error!Message {
                return Envelope(C).create(gpa, target, @unionInit(C.Msg, @tagName(tag), payload), true);
            }
        }.message,
    };
}

/// Builds the options struct taken by `Scope.open`: the fields of
/// `layout.ContainerDeclaration` except `id`, plus `on_click`. Generating it
/// keeps the two in sync.
fn ContainerOptions(comptime Msg: type) type {
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

    const no_click: ?Msg = null;
    names[len] = "on_click";
    types[len] = ?Msg;
    attrs[len] = .{ .default_value_ptr = &no_click };

    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn declaration(comptime Options: type, options: Options) layout.ContainerDeclaration {
    var decl: layout.ContainerDeclaration = .{};
    inline for (@typeInfo(Options).@"struct".field_names) |name| {
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

fn checkComponent(comptime C: type) void {
    for ([_][]const u8{ "State", "Msg", "Props", "update", "view" }) |name| {
        if (!@hasDecl(C, name)) {
            @compileError(@typeName(C) ++ " is not a component: missing `pub " ++
                (if (std.ascii.isUpper(name[0])) "const " else "fn ") ++ name ++ "`");
        }
    }
}

const testing = std.testing;

const TestRuntime = Runtime(.{});

/// Number of `Counter.State.deinit` calls, to check instances are swept.
var counter_deinits: usize = 0;

/// A rounded button around a text label, as a reusable view function.
fn testButton(comptime C: type, ui: *Scope(C), key: []const u8, label: []const u8, msg: C.Msg) !void {
    try ui.open(key, .{
        .layout = .{ .padding = .all(6) },
        .background_color = if (ui.pressed(key)) .gray(150) else if (ui.hovered(key)) .gray(200) else .gray(230),
        .corner_radius = .uniform(8),
        .on_click = msg,
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

    pub fn view(ui: *Scope(Counter), state: *const State, props: Props) !void {
        try ui.open("row", .{ .layout = .{ .child_gap = 4, .child_alignment = .center_left } });
        defer ui.close();

        try ui.text(try ui.fmt("{s} = {d}", .{ props.label, state.count }), .{});
        try testButton(Counter, ui, "inc", try ui.fmt("{s} +", .{props.label}), .increment);
        try testButton(Counter, ui, "dec", try ui.fmt("{s} -", .{props.label}), .decrement);
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

    pub fn view(ui: *Scope(App), state: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 8, .sizing = .grow(.{}) } });
        defer ui.close();

        try ui.text(try ui.fmt("changes = {d}", .{state.changes}), .{});
        try testButton(App, ui, "add", "add", .add_counter);
        try testButton(App, ui, "remove", "remove", .remove_counter);
        for (0..state.counters) |i| {
            try ui.child(Counter, i, .{
                .label = try ui.fmt("c{d}", .{i}),
                .step = @intCast(i + 1),
                // checked at comptime: .counter_changed carries i32, matching Handler(i32)
                .on_change = ui.handler(.counter_changed),
                .on_step = ui.handler(.counter_step),
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

    pub fn view(ui: *Scope(Loader), state: *const State, props: Props) !void {
        props.handler.* = ui.handler(.loaded);
        if (state.value) |value| {
            try ui.text(try ui.fmt("loaded {d}", .{value}), .{});
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

    pub fn view(ui: *Scope(Owner), state: *const State, props: Props) !void {
        props.handler.* = ui.handler(.rename);
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

test "element and instance keys hash by value" {
    try testing.expectEqual(elementId(1, "a"), elementId(1, @as([]const u8, "a")));
    try testing.expectEqual(elementId(1, 3), elementId(1, @as(usize, 3)));
    try testing.expectEqual(elementId(1, .x), elementId(1, Vec2.Axis.x));
    try testing.expect(elementId(1, "a").id != elementId(2, "a").id);
    try testing.expect(instanceId(0, App, 0) != instanceId(0, Counter, 0));
}
