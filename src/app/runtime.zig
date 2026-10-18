//! The runtime: component instances, the message queue and frames.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

const component = @import("component.zig");
const InstanceId = component.InstanceId;
const root_parent = component.root_parent;
const TypeTag = component.TypeTag;
const typeTag = component.typeTag;
const instanceId = component.instanceId;
const elementId = component.elementId;
const componentKind = component.componentKind;
const PropsOf = component.PropsOf;
const Provided = @import("context.zig").Provided;
const RootValue = @import("context.zig").RootValue;
const Action = @import("message.zig").Action;
const Handler = @import("message.zig").Handler;
const Update = @import("message.zig").Update;
const Poster = @import("message.zig").Poster;
const Message = @import("message.zig").Message;
const bindHandler = @import("message.zig").bindHandler;
const make = @import("message.zig").make;
const inline_size = @import("message.zig").inline_size;
const MouseEvent = @import("input.zig").MouseEvent;
const KeyEvent = @import("input.zig").KeyEvent;
const Pointer = @import("input.zig").Pointer;
const Cursor = @import("input.zig").Cursor;
const Input = @import("input.zig").Input;
const occupied = @import("input.zig").occupied;
const Rect = fabrum.Rect;
const Ui = @import("ui.zig").Ui;
const Ancestor = @import("ui.zig").Ancestor;
const native = @import("native.zig");
const app_platform = @import("platform.zig");
const Reconciler = @import("reconciler.zig").Reconciler;
const FocusEntry = Reconciler.FocusEntry;
const makeBorrowed = @import("message.zig").makeBorrowed;

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
            /// Values seen by every component, such as services, as in
            /// `.provide = &.{ .of(&services), .of(&icons) }`. The values
            /// must outlive the runtime; the slice is copied.
            provide: []const RootValue = &.{},
            /// Capacity of the layout built each frame.
            context: layout.Context.Config = .{},
            /// Configuration of the root container. Its sizing is replaced
            /// with the viewport size each frame.
            root: layout.Config = .{},
            /// The platform's native widgets, for `Ui.native`. Without one,
            /// `app.widgets` are drawn, as on the `none` platform.
            native: ?native.Backend = null,
            /// The look of drawn widgets without a native backend. The
            /// runtime provides a `native.Theme` as a root value, under those
            /// in `provide`: the backend's if it has one, else this.
            theme: native.Theme = .{},
            /// The host's shell: file chooser, clipboard, quitting. Without
            /// one, `update`'s requests for them fail with
            /// `error.Unsupported`. See `app.platform`.
            shell: ?app_platform.Shell = null,
        };

        pub fn init(gpa: Allocator, options: Options) !Self {
            const text_context = options.text_context orelse if (@hasDecl(Text.Context, "default"))
                Text.Context.default
            else
                @panic("app.Runtime: text_context is required for " ++ @typeName(Text));

            const theme = try gpa.create(native.Theme);
            errdefer gpa.destroy(theme);
            theme.* = if (options.native) |backend| backend.theme() else options.theme;

            // the theme first, so the app's own values hide it
            const theme_root: []const RootValue = &.{.of(@as(*const native.Theme, theme))};
            const roots = try gpa.alloc(Provided, theme_root.len + options.provide.len);
            errdefer gpa.free(roots);
            for (roots, 0..) |*node, i| {
                const value = if (i < theme_root.len) theme_root[i] else options.provide[i - theme_root.len];
                node.* = .{ .parent = if (i > 0) &roots[i - 1] else null, .key = value.key, .value = value.value };
            }

            return .{
                .core = .{
                    .gpa = gpa,
                    .io = options.io,
                    .platform = options.platform,
                    .arena = .init(gpa),
                    .context = try .init(gpa, options.context),
                    .make_text = makeText,
                    .roots = roots,
                    .theme = theme,
                    .reconciler = .{ .backend = options.native },
                    .shell = options.shell,
                },
                .text_context = text_context,
                .root = options.root,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.* = undefined;
        }

        /// Runs one frame at time `now`, from the host's clock: processes
        /// queued messages, runs every view from `Root` down, computes the
        /// layout for `viewport`, destroys instances that weren't rendered,
        /// and clears the dirty flag. Returns the frame's render commands
        /// (also `commands`).
        ///
        /// An error from an `update` is returned before any view runs, with
        /// the state as far as that update got; see "Errors" in `app`.
        ///
        /// The returned commands, and all content in them, are valid until the
        /// next call to `frame`.
        pub fn frame(self: *Self, comptime Root: type, props: PropsOf(Root), viewport: Vec2, now: std.Io.Timestamp) anyerror![]const layout.RenderCommand {
            var root = self.root;
            root.sizing = .fixedXY(viewport.x, viewport.y);
            return self.core.frame(Root, props, root, viewport, now);
        }

        /// The last frame's render commands, in paint order, for a renderer;
        /// see `layout.draw`. Valid until the next frame starts.
        pub fn commands(self: *const Self) []const layout.RenderCommand {
            return self.core.commands;
        }

        /// The regions of the viewport that changed since the last call,
        /// as of the last frame: what a host redraws, and what a VNC server
        /// sends. The whole viewport the first time, and when its size
        /// changes. Whole points, in the viewport; valid until the next
        /// call. See `layout.Damage` for how, and what it can't see.
        pub fn damage(self: *Self) Allocator.Error![]const Rect {
            return self.core.damage.update(self.core.gpa, self.core.commands, self.core.viewport);
        }

        /// When the host should run the next frame, or null to wait for
        /// input or a posted message (which calls `Platform.requestFrame`).
        /// The last frame's time if a frame is due now (something changed,
        /// messages are waiting, or a view called `Ui.animate`), else the
        /// earliest time a view asked for with `Ui.frameAt`.
        pub fn nextFrame(self: *Self) ?std.Io.Timestamp {
            if (self.needsFrame()) return self.core.now;
            return self.core.wake;
        }

        /// Updates hover and press state from pointer input, queues a click
        /// message if the primary button was released on the element it was
        /// pressed on, fires `on_pointer` and focuses `focus_on_press`
        /// elements on a press, and processes queued messages.
        ///
        /// Returns whether the app took the event: whether the pointer is
        /// over something of the app (anything but the root that paints or
        /// takes input there), or the primary button went down over one and
        /// is still held or just released. A host passes events it didn't
        /// take on, as an overlay lets clicks through to the game under it.
        /// A press on nothing of the app also clears drawn focus.
        pub fn mouse(self: *Self, event: MouseEvent) anyerror!bool {
            return self.core.mouse(event);
        }

        /// Handles a key while a drawn element has focus, and returns
        /// whether the app took it; keys it didn't take go on to whatever is
        /// under the app. Without drawn focus nothing is taken, so an
        /// overlay never steals the game's keys until something of it is
        /// clicked (or focused with `focusMove`).
        ///
        /// With drawn focus: Tab and Shift-Tab move it, Escape clears it,
        /// and Space and Enter click the focused element if it has an
        /// `on_click`. Other keys are not taken yet. Releases are taken
        /// when their press was.
        pub fn key(self: *Self, event: KeyEvent) anyerror!bool {
            return self.core.keyEvent(event);
        }

        /// Reports what the user did to a native element, from its backend:
        /// notes the value it now shows, queues the message its handler
        /// makes, and processes queued messages. Events for elements that
        /// no longer exist are dropped.
        ///
        /// Events reported while a frame runs, as toolkits do from inside
        /// the calls a frame makes (a field reporting the text fabrum just
        /// wrote, a control reporting the focus fabrum just gave it), wait
        /// until the frame is over: they are delivered, in order, before
        /// the next input or frame, and `needsFrame` says so meanwhile.
        pub fn nativeEvent(self: *Self, id: native.Id, event: native.Event) anyerror!void {
            return self.core.nativeEvent(id, event);
        }

        /// Whether the host may close the window or quit now, asked before
        /// it does. True unless the last frame declared `Ui.guardClose`:
        /// then the guard's handler gets `reason`, and messages are
        /// processed, so the app can ask the user and call `quit` (on
        /// `Update`) if they agree.
        pub fn shouldClose(self: *Self, reason: app_platform.CloseReason) anyerror!bool {
            return self.core.shouldClose(reason);
        }

        /// Moves keyboard focus to the next element in the Tab order, or
        /// the previous one, wrapping around. The order is the paint order
        /// of the last frame's focusable elements, native and drawn alike.
        pub fn focusMove(self: *Self, direction: FocusDirection) void {
            self.core.focusMove(direction);
        }

        /// Clicks the focused drawn element, as Space does: queues its
        /// `on_click` and processes queued messages. Native elements handle
        /// their own keys.
        pub fn activateFocused(self: *Self) anyerror!void {
            return self.core.activateFocused();
        }

        /// The focused element, native or drawn, or null.
        pub fn focused(self: *const Self) ?FocusEntry {
            return self.core.focus;
        }

        /// The last frame's canvas layers and native views, for the
        /// platform to show. Valid until the next frame starts.
        pub fn scene(self: *const Self) *const native.Scene {
            return &self.core.reconciler.scene;
        }

        /// The native element records, for tests and debugging.
        pub fn reconciler(self: *Self) *Reconciler {
            return &self.core.reconciler;
        }

        /// Whether something changed since the last frame: a message was
        /// delivered, hover or press state changed, or messages are waiting.
        pub fn needsFrame(self: *Self) bool {
            return self.core.dirty or self.core.hasQueued() or self.core.deferred.items.len > 0;
        }

        /// The cursor to show as of the last input event: `pointer` while
        /// the pointer is over an element with an `on_click` (or over one of
        /// its descendants, since clicks bubble up to it), `default`
        /// elsewhere. Platforms call this after `mouse` and `frame`.
        pub fn cursor(self: *const Self) Cursor {
            return if (self.core.input.clickTarget(self.core.clicks) != null) .pointer else .default;
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
            const storage: *Storage(Root) = @alignCast(@fieldParentPtr("instance", instance));
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

pub const FocusDirection = enum { next, previous };

/// Type-erased handle to one stateful instance in the store.
pub const Instance = struct {
    id: InstanceId,
    /// The instance's component.
    type_tag: TypeTag,
    destroy: *const fn (gpa: Allocator, instance: *Instance) void,
    /// Whether the instance was rendered this frame.
    seen: bool = false,
    /// The context the instance was last rendered in, for `Update.use`.
    provided: ?*const Provided = null,
};

pub fn Storage(comptime C: type) type {
    return struct {
        instance: Instance,
        state: C.State = .{},
        props: C.Props = undefined,

        fn destroy(gpa: Allocator, instance: *Instance) void {
            const self: *@This() = @alignCast(@fieldParentPtr("instance", instance));
            if (@hasDecl(C.State, "deinit")) {
                self.state.deinit(gpa);
            }
            gpa.destroy(self);
        }
    };
}

/// The part of the runtime that doesn't depend on `Config`, so views and
/// handlers don't either.
pub const Core = struct {
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
    clicks: std.AutoHashMapUnmanaged(u64, Action) = .empty,
    /// Element ID to `on_pointer` handler, rebuilt every frame.
    pointers: std.AutoHashMapUnmanaged(u64, Handler(Pointer)) = .empty,
    /// Elements declared `focus_on_press` this frame.
    focus_on_press: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The time of the last frame, from the host.
    now: std.Io.Timestamp = .zero,
    /// The earliest frame the last frame's views asked for.
    wake: ?std.Io.Timestamp = null,
    /// The last frame's viewport and render commands, in the frame arena.
    viewport: Vec2 = .zero,
    commands: []const layout.RenderCommand = &.{},
    /// What changed since the host last asked.
    damage: layout.Damage = .{},
    /// Whether the primary button went down over something of the app, so
    /// the rest of the gesture is the app's too.
    captured: bool = false,
    /// Keys whose press the app took, so it takes their release too.
    keys_taken: std.EnumSet(KeyEvent.Key) = .empty,
    make_text: *const fn (core: *Core, string: []const u8, style: layout.text.Style) Allocator.Error!*layout.Content,

    /// The root values, linked last to first, owned with the gpa.
    roots: []Provided,
    /// The values provided at the point the view being rendered has
    /// reached.
    provided: ?*const Provided = null,
    /// `provided` as of each open container, restored when it closes.
    provider_marks: std.ArrayList(?*const Provided) = .empty,

    /// Guards `queue`, the only state touched from other threads.
    queue_mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(Message) = .empty,
    /// The batch being processed, swapped with `queue` so new messages can
    /// be queued while it runs.
    batch: std.ArrayList(Message) = .empty,

    /// Hover and press state.
    input: Input = .{},

    /// The platform's look, or the drawn widgets', provided as a root value.
    theme: *native.Theme,
    /// Native elements and the scene.
    reconciler: Reconciler,
    /// Drawn elements declared `focusable` this frame, by unit ID.
    focusable: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The focused element.
    focus: ?FocusEntry = null,
    /// The unit index of the last modal scope declared this frame.
    modal: ?usize = null,
    /// The host's shell, for `update`'s requests.
    shell: ?app_platform.Shell = null,
    /// The handler the last frame's `Ui.guardClose` declared, if any.
    close_guard: ?Handler(app_platform.CloseReason) = null,
    /// The native containers open while views run, innermost last.
    native_parents: std.ArrayList(NativeParent) = .empty,
    /// Whether a frame is running, when native events wait in `deferred`.
    in_frame: bool = false,
    /// Native events reported while a frame was running, in order, with
    /// their text copied, for the next input or frame to deliver.
    deferred: std.ArrayList(DeferredEvent) = .empty,

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
        for (self.deferred.items) |deferred| deferred.free(self.gpa);
        self.deferred.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.batch.deinit(self.gpa);

        self.clicks.deinit(self.gpa);
        self.pointers.deinit(self.gpa);
        self.focus_on_press.deinit(self.gpa);
        self.damage.deinit(self.gpa);
        self.reconciler.deinit(self.gpa);
        self.focusable.deinit(self.gpa);
        self.gpa.destroy(self.theme);
        self.provider_marks.deinit(self.gpa);
        self.native_parents.deinit(self.gpa);
        self.gpa.free(self.roots);
        self.input.deinit(self.gpa);
        self.context.deinit(self.gpa);
        self.arena.deinit();
    }

    /// The latest root value, which every view and update starts from.
    fn rootProvided(self: *const Core) ?*const Provided {
        return if (self.roots.len > 0) &self.roots[self.roots.len - 1] else null;
    }

    fn frame(self: *Core, comptime Root: type, props: Root.Props, root: layout.Config, viewport: Vec2, now: std.Io.Timestamp) anyerror![]const layout.RenderCommand {
        self.now = now;
        // Messages run before the arena is reset, while the context nodes
        // and click payloads of the frame that queued them are alive.
        try self.deliverDeferred();
        try self.processMessages();

        // from here until the frame is done, native events wait
        self.in_frame = true;
        defer self.in_frame = false;

        _ = self.arena.reset(.retain_capacity);
        self.commands = &.{};
        self.viewport = viewport;
        self.wake = null;
        self.pointers.clearRetainingCapacity();
        self.focus_on_press.clearRetainingCapacity();
        self.reconciler.begin();
        self.focusable.clearRetainingCapacity();
        self.modal = null;
        if (self.reconciler.backend) |backend| self.theme.* = backend.theme();
        self.clicks.clearRetainingCapacity();
        self.stateless.clearRetainingCapacity();
        self.provider_marks.clearRetainingCapacity();
        self.native_parents.clearRetainingCapacity();
        self.close_guard = null;
        self.provided = self.rootProvided();
        self.laid_out = false;

        var instances = self.instances.valueIterator();
        while (instances.next()) |instance| {
            instance.*.seen = false;
            // until rendered again, since its old context was in the arena
            instance.*.provided = self.provided;
        }

        // a failed view leaves containers open; drop them so the next frame can begin
        errdefer self.context.stack.clearRetainingCapacity();
        // and the last scene's commands were in the arena
        errdefer if (self.reconciler.backend) |backend| backend.present(&.{});

        self.context.begin(root);
        const parent: Ui = .{ .core = self, .scope = root_parent, .owners = null };
        try self.render(&parent, Root, {}, props);
        self.context.end();

        try self.context.computeLayout();
        self.laid_out = true;

        var commands: std.ArrayList(layout.RenderCommand) = .empty;
        var it = self.context.renderCommands();
        while (it.next()) |command| try commands.append(self.arena.allocator(), command);
        self.commands = commands.items;

        try self.reconciler.finish(self.gpa, self.arena.allocator(), &self.context, &self.focusable, self.modal);
        self.dropLostFocus();
        // a modal scope takes focus from what it covers, and the next frame
        // shows where it went
        const refocus = self.modal != null and self.focus == null and self.reconciler.chain.items.len > 0;
        if (refocus) self.focusEntry(self.reconciler.chain.items[0]);

        try self.sweep();
        self.dirty = refocus;

        return self.commands;
    }

    pub fn render(self: *Core, parent: *const Ui, comptime C: type, key: anytype, props: C.Props) anyerror!void {
        const id = instanceId(parent.scope, C, key);

        // values the child provides stay in its subtree
        const provided = self.provided;
        defer self.provided = provided;

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

                const storage: *Storage(C) = @alignCast(@fieldParentPtr("instance", gop.value_ptr.*));
                if (storage.instance.seen) {
                    // the same component type was rendered twice with the same key
                    return error.DuplicateKey;
                }
                storage.instance.seen = true;
                storage.instance.provided = provided;
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

    pub fn enqueue(self: *Core, message: Message) Allocator.Error!void {
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
    ///
    /// An error from an `update` stops processing and is returned: the
    /// message that failed is consumed, and the messages after it stay
    /// queued, in order, for the next call.
    fn processMessages(self: *Core) anyerror!void {
        while (true) {
            {
                self.queue_mutex.lockUncancelable(self.io);
                defer self.queue_mutex.unlock(self.io);

                std.mem.swap(std.ArrayList(Message), &self.queue, &self.batch);
            }

            if (self.batch.items.len == 0) break;

            for (self.batch.items, 0..) |message, index| {
                const instance = self.instances.get(message.target) orelse {
                    message.discard(self.gpa);
                    continue;
                };
                if (instance.type_tag != message.type_tag) {
                    // a hash collision or a misbound action: never cast to the wrong type
                    message.discard(self.gpa);
                    continue;
                }
                self.dirty = true;
                defer message.release(self.gpa);
                // anything queued from here on goes to `queue` and runs after this batch
                message.vtable.deliver(self, instance, message.msg) catch |err| {
                    self.requeue(self.batch.items[index + 1 ..]);
                    self.batch.clearRetainingCapacity();
                    return err;
                };
            }
            self.batch.clearRetainingCapacity();
        }
    }

    /// Puts `messages`, which were queued before anything in `queue`, back
    /// in front of it.
    fn requeue(self: *Core, messages: []const Message) void {
        if (messages.len == 0) return;
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        self.queue.insertSlice(self.gpa, 0, messages) catch {
            // with no room to keep them, they are lost, as undeliverable
            // messages are; the update's error is returned regardless
            for (messages) |message| message.discard(self.gpa);
        };
    }

    /// An open native container: its ID, and its unit's index.
    pub const NativeParent = struct { id: native.Id, index: usize };

    /// The native container elements are declared in, if any.
    pub fn nativeParent(self: *const Core) ?native.Id {
        const last = self.native_parents.getLastOrNull() orelse return null;
        return last.id;
    }

    /// A native event reported while a frame ran, waiting for the next
    /// input or frame.
    const DeferredEvent = struct {
        id: native.Id,
        /// Its text, if any, is owned.
        event: native.Event,

        fn free(self: DeferredEvent, gpa: Allocator) void {
            if (self.event == .text) gpa.free(self.event.text);
        }
    };

    fn nativeEvent(self: *Core, id: native.Id, event: native.Event) anyerror!void {
        // the frame is rebuilding the records and the scene: wait
        if (self.in_frame) return self.deferEvent(id, event);
        try self.deliverDeferred();
        try self.handleNativeEvent(id, event);
    }

    fn deferEvent(self: *Core, id: native.Id, event: native.Event) Allocator.Error!void {
        var copy = event;
        if (event == .text) copy = .{ .text = try self.gpa.dupe(u8, event.text) };
        errdefer if (copy == .text) self.gpa.free(copy.text);
        try self.deferred.append(self.gpa, .{ .id = id, .event = copy });
    }

    /// Delivers the native events reported during the last frame, in
    /// order. An `update`'s error stops it, with the rest still waiting.
    fn deliverDeferred(self: *Core) anyerror!void {
        while (self.deferred.items.len > 0) {
            const first = self.deferred.orderedRemove(0);
            defer first.free(self.gpa);
            try self.handleNativeEvent(first.id, first.event);
        }
    }

    fn handleNativeEvent(self: *Core, id: native.Id, event: native.Event) anyerror!void {
        const record = self.reconciler.records.getPtr(id) orelse return;
        const handlers = record.handlers;
        switch (event) {
            .activate => if (handlers.on_activate) |h| try self.enqueue(try make(h, self.gpa, {})),
            .submit => if (handlers.on_submit) |h| try self.enqueue(try make(h, self.gpa, {})),
            .toggle => |on| {
                try record.report(self.gpa, .{ .toggle = on });
                if (handlers.on_toggle) |h| try self.enqueue(try make(h, self.gpa, on));
            },
            .number => |number| {
                try record.report(self.gpa, .{ .number = number });
                if (handlers.on_number) |h| try self.enqueue(try make(h, self.gpa, number));
            },
            .text => |text| {
                try record.report(self.gpa, .{ .text = text });
                // borrows the record's copy, which outlives the update
                if (handlers.on_text) |h| try self.enqueue(try makeBorrowed(h, self.gpa, record.shown.text));
            },
            .response => |index| if (handlers.on_response) |h| try self.enqueue(try make(h, self.gpa, index)),
            // laid out against from the next frame on
            .scroll => |offset| record.scroll = offset,
            .focus => |gained| {
                const entry: FocusEntry = .{ .unit = record.unit, .native = id };
                if (gained) {
                    self.focus = entry;
                } else if (self.focus != null and self.focus.?.eql(entry)) {
                    self.focus = null;
                }
            },
            // a write held back during the composition can go in now
            .composition_end => {},
        }
        self.dirty = true;
        try self.processMessages();
    }

    fn shouldClose(self: *Core, reason: app_platform.CloseReason) anyerror!bool {
        try self.deliverDeferred();
        const guard = self.close_guard orelse return true;
        try self.enqueue(try make(guard, self.gpa, reason));
        try self.processMessages();
        return false;
    }

    fn focusMove(self: *Core, direction: FocusDirection) void {
        const chain = self.reconciler.chain.items;
        if (chain.len == 0) return;
        const current: ?usize = if (self.focus) |focus| for (chain, 0..) |entry, i| {
            if (entry.eql(focus)) break i;
        } else null else null;
        const next = switch (direction) {
            .next => if (current) |i| (i + 1) % chain.len else 0,
            .previous => if (current) |i| (i + chain.len - 1) % chain.len else chain.len - 1,
        };
        self.focusEntry(chain[next]);
    }

    fn focusEntry(self: *Core, entry: FocusEntry) void {
        if (self.reconciler.backend) |backend| {
            if (entry.native) |id| {
                if (self.reconciler.records.getPtr(id)) |record| backend.focus(.{ .native = record.handle });
            } else {
                backend.focus(.canvas);
            }
        }
        // after the backend, whose focus events report the old element leaving
        self.focus = entry;
        self.dirty = true;
    }

    fn activateFocused(self: *Core) anyerror!void {
        try self.deliverDeferred();
        const focus = self.focus orelse return;
        if (focus.native != null) return;
        if (self.clicks.get(focus.unit)) |action| {
            try self.enqueue(try make(action, self.gpa, {}));
            try self.processMessages();
        }
    }

    /// Clears focus from an element the last frame didn't show.
    fn dropLostFocus(self: *Core) void {
        const focus = self.focus orelse return;
        for (self.reconciler.chain.items) |entry| {
            if (entry.eql(focus)) return;
        }
        self.focus = null;
    }

    /// The elements that take input, for `occupied`.
    const Interactive = struct {
        core: *const Core,

        pub fn contains(self: Interactive, id: u64) bool {
            const core = self.core;
            return core.clicks.contains(id) or core.pointers.contains(id) or core.focusable.contains(id);
        }
    };

    fn mouse(self: *Core, event: MouseEvent) anyerror!bool {
        try self.deliverDeferred();
        const units = if (self.laid_out) self.context.units.items else null;
        const over = if (units) |u| occupied(u, event.position, Interactive{ .core = self }) else false;
        const was_down = self.input.primary_down;
        const down = event.pressed.isSet(MouseEvent.primary);
        const outcome = try self.input.handle(self.gpa, units, self.clicks, event);
        if (outcome.press) self.captured = over;
        const handled = over or (self.captured and (down or was_down));
        if (!down) self.captured = false;

        if (outcome.changed) self.dirty = true;
        if (outcome.press) {
            if (self.input.nearest(self.focus_on_press)) |id| {
                self.focusEntry(.{ .unit = id });
            } else if (!over and self.focus != null and self.focus.?.native == null) {
                self.focus = null;
                self.dirty = true;
            }
            if (self.input.nearest(self.pointers)) |id| {
                const box = self.context.getUnitById(.fromInt(id)).?.bbox;
                const pointer: Pointer = .{ .local = event.position.sub(.init(box.x, box.y)), .size = .init(box.w, box.h) };
                try self.enqueue(try make(self.pointers.get(id).?, self.gpa, pointer));
            }
        }
        if (outcome.click) |clicked| {
            try self.enqueue(try make(self.clicks.get(clicked).?, self.gpa, {}));
        }

        try self.processMessages();
        return handled;
    }

    fn keyEvent(self: *Core, event: KeyEvent) anyerror!bool {
        try self.deliverDeferred();
        if (event.phase == .release) {
            const taken = self.keys_taken.contains(event.key);
            self.keys_taken.remove(event.key);
            return taken;
        }
        const focus = self.focus orelse return false;
        if (focus.native != null) return false;
        const taken = switch (event.key) {
            .tab => blk: {
                self.focusMove(if (event.modifiers.shift) .previous else .next);
                break :blk true;
            },
            .escape => blk: {
                self.focus = null;
                self.dirty = true;
                break :blk true;
            },
            .space, .enter => blk: {
                const action = self.clicks.get(focus.unit) orelse break :blk false;
                try self.enqueue(try make(action, self.gpa, {}));
                break :blk true;
            },
            else => false,
        };
        if (taken) self.keys_taken.insert(event.key);
        try self.processMessages();
        return taken;
    }
};

const testing = std.testing;
const app_testing = @import("testing.zig");

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

    pub fn update(state: *State, msg: Msg, ctx: *Update(Counter)) !void {
        switch (msg) {
            .increment => state.count += ctx.props.step,
            .decrement => state.count -= ctx.props.step,
        }
        try state.history.append(ctx.gpa, state.count);
        // one update emitting two messages
        try ctx.emit(ctx.props.on_change, state.count);
        try ctx.emit(ctx.props.on_step, ctx.props.step);
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        try ui.open("row", .{ .layout = .{ .child_gap = 4, .child_alignment = .center_left } });
        defer ui.close();

        try ui.print(.{}, "{s} = {d}", .{ props.label, state.count });
        const on = ui.messages(Counter);
        try testButton(ui, "inc", try ui.fmt("{s} +", .{props.label}), on.bind(.increment));
        try testButton(ui, "dec", try ui.fmt("{s} -", .{props.label}), on.bind(.decrement));
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

    pub fn update(state: *State, msg: Msg, ctx: *Update(App)) !void {
        switch (msg) {
            .add_counter => state.counters += 1,
            .remove_counter => state.counters -|= 1,
            .counter_changed => |value| {
                state.changes += 1;
                state.record(.{ .changed = value });
                // queued behind the `counter_step` Counter already emitted
                try ctx.emit(ctx.handler(.echo), value);
            },
            .counter_step => |step| state.record(.{ .step = step }),
            .echo => |value| state.record(.{ .echo = value }),
        }
    }

    pub fn view(ui: *Ui, state: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 8, .sizing = .grow(.{}) } });
        defer ui.close();

        try ui.print(.{}, "changes = {d}", .{state.changes});
        const on = ui.messages(App);
        try testButton(ui, "add", "add", on.bind(.add_counter));
        try testButton(ui, "remove", "remove", on.bind(.remove_counter));
        for (0..state.counters) |i| {
            try ui.child(Counter, i, .{
                .label = try ui.fmt("c{d}", .{i}),
                .step = @intCast(i + 1),
                // checked at comptime: .counter_changed carries i32, matching Handler(i32)
                .on_change = on.handler(.counter_changed),
                .on_step = on.handler(.counter_step),
            });
        }
    }
};

fn testFrame(rt: *TestRuntime) !void {
    _ = try rt.frame(App, .{}, .init(400, 300), .zero);
}

fn findText(rt: *TestRuntime, string: []const u8) ?*const layout.Unit {
    return app_testing.findText(TestRuntime.Text, rt.context(), string);
}

fn hasText(rt: *TestRuntime, string: []const u8) bool {
    return findText(rt, string) != null;
}

/// The container around the text `label`, such as a button.
fn findButton(rt: *TestRuntime, label: []const u8) !*const layout.Unit {
    const t = findText(rt, label) orelse return error.NoSuchText;
    return rt.context().getUnitByIndex(t.parent).?;
}

fn press(rt: *TestRuntime, point: Vec2) !void {
    var buttons: MouseEvent.Buttons = .empty;
    buttons.set(MouseEvent.primary);
    _ = try rt.mouse(.{ .position = point, .pressed = buttons });
}

fn release(rt: *TestRuntime, point: Vec2) !void {
    _ = try rt.mouse(.{ .position = point });
}

/// Presses and releases at the center of the button labelled `label`.
fn clickButton(rt: *TestRuntime, label: []const u8) !void {
    const point = app_testing.center(try findButton(rt, label));
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
    const point = app_testing.center(try findButton(&rt, "c0 +"));

    _ = try rt.mouse(.{ .position = point });
    try testing.expect(rt.needsFrame());
    // the current layout was built before the pointer moved
    try testing.expectEqual(idle, (try findButton(&rt, "c0 +")).data.container.background_color);

    try testFrame(&rt);
    try testing.expectEqual(hover, (try findButton(&rt, "c0 +")).data.container.background_color);
    try testing.expectEqual(idle, (try findButton(&rt, "c1 +")).data.container.background_color);

    // moving within the same element changes nothing
    _ = try rt.mouse(.{ .position = point.addValues(1, 0) });
    try testing.expect(!rt.needsFrame());

    try press(&rt, point);
    try testing.expect(rt.needsFrame());
    try testFrame(&rt);
    try testing.expectEqual(pressed, (try findButton(&rt, "c0 +")).data.container.background_color);

    try release(&rt, point);
    _ = try rt.mouse(.{ .position = .init(399, 299) });
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
    try press(&rt, app_testing.center(try findButton(&rt, "c0 +")));
    try release(&rt, app_testing.center(try findButton(&rt, "c0 -")));
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
    _ = try rt.mouse(.{ .position = app_testing.center(label) });
    try testing.expectEqual(Cursor.pointer, rt.cursor());

    // plain text has nothing to click
    _ = try rt.mouse(.{ .position = app_testing.center(findText(&rt, "changes = 0").?) });
    try testing.expectEqual(Cursor.default, rt.cursor());

    _ = try rt.mouse(.{ .position = .init(399, 299) });
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
        props.handler.* = ui.messages(Loader).handler(.loaded);
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
    _ = try rt.frame(Loader, .{ .handler = &handler }, .init(200, 100), .zero);
    try testing.expect(hasText(&rt, "waiting"));
    try testing.expect(!rt.needsFrame());

    const thread = try std.Thread.spawn(.{}, Wake.post, .{ rt.poster(), handler.?, 42 });
    thread.join();

    try testing.expectEqual(1, wake.requests.load(.seq_cst));
    try testing.expect(rt.needsFrame()); // queued, not yet applied
    try testing.expect(hasText(&rt, "waiting"));

    _ = try rt.frame(Loader, .{ .handler = &handler }, .init(200, 100), .zero);
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
        props.handler.* = ui.messages(Owner).handler(.rename);
        try ui.text(state.name orelse "unnamed", .{});
    }
};

test "messages own their payload until delivered or discarded" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    var handler: ?Handler([]u8) = null;
    _ = try rt.frame(Owner, .{ .handler = &handler }, .init(200, 100), .zero);

    try rt.post(handler, try testing.allocator.dupe(u8, "first"));
    try rt.post(handler, try testing.allocator.dupe(u8, "second"));
    _ = try rt.frame(Owner, .{ .handler = &handler }, .init(200, 100), .zero);
    try testing.expect(hasText(&rt, "second"));

    // still queued at deinit: discarded through `Msg.deinit`
    try rt.post(handler, try testing.allocator.dupe(u8, "third"));
}

test "a message is never delivered to an instance of another component" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    _ = try rt.frame(Board, .{}, .init(400, 300), .zero);
    const panel = instanceId(instanceId(root_parent, Board, {}), Panel, "p");
    try testing.expect(rt.core.instances.contains(panel));

    // messages for other components aimed at a `Panel`, as a hash
    // collision or a misbound action would make: discarded rather than
    // cast, and an owned payload is still freed through `Msg.deinit`
    try rt.post(bindHandler(App, panel, .echo), 7);
    try rt.post(bindHandler(Owner, panel, .rename), try testing.allocator.dupe(u8, "lost"));
    // while the `Panel`'s own messages still arrive
    try rt.post(bindHandler(Panel, panel, .set), 3);

    _ = try rt.frame(Board, .{}, .init(400, 300), .zero);
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
        try testButton(ui, "bump", try ui.fmt("{s} bump", .{props.name}), ui.messages(Panel).bind(.bump));
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
        const on = ui.messages(Panel);
        // a handler of a tag without payload is an action
        try ui.one(Toolbar, .{ .name = props.name, .on_reset = on.handler(.reset) });
        try testButton(ui, "set", try ui.fmt("{s} set", .{props.name}), on.handler(.set).with(7));
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

    _ = try rt.frame(Board, .{}, .init(400, 300), .zero);
    // two panels; neither the board nor the toolbars are stored
    try testing.expectEqual(2, rt.core.instances.count());
    try testing.expect(hasText(&rt, "p = 0"));

    // the toolbar's button binds to the panel around it, not the other one
    try clickButton(&rt, "q bump");
    try clickButton(&rt, "q bump");
    _ = try rt.frame(Board, .{}, .init(400, 300), .zero);
    try testing.expect(hasText(&rt, "p = 0"));
    try testing.expect(hasText(&rt, "q = 2"));

    // a handler with a payload, and one passed down to a stateless child
    try clickButton(&rt, "p set");
    try clickButton(&rt, "q reset");
    _ = try rt.frame(Board, .{}, .init(400, 300), .zero);
    try testing.expect(hasText(&rt, "p = 7"));
    try testing.expect(hasText(&rt, "q = 0"));

    // repeated keys are an error for stateless children too
    try testing.expectError(error.DuplicateKey, rt.frame(Board, .{ .names = &.{ "p", "p" } }, .init(400, 300), .zero));
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
    _ = try rt.frame(Stack, .{}, .init(200, 100), .zero);
    try testing.expect(hasText(&rt, "first 1"));
    try testing.expect(hasText(&rt, "second 2"));
    try testing.expect(hasText(&rt, "third and 3"));
}

/// A context value: the label suffix the views below show.
const Accent = struct { name: []const u8 };
/// A context value nothing provides.
const Unprovided = struct {};

/// Shows the `Accent` it sees, and records the one its `update` sees.
const Probe = struct {
    pub const State = struct { seen_in_update: ?[]const u8 = null };
    pub const Msg = union(enum) { check };
    pub const Props = struct { key: []const u8 };

    pub fn update(state: *State, msg: Msg, ctx: *Update(Probe)) void {
        switch (msg) {
            .check => state.seen_in_update = ctx.use(Accent).name,
        }
    }

    pub fn view(ui: *Ui, _: *const State, props: Props) !void {
        try testButton(ui, "check", try ui.fmt("{s}: {s}", .{ props.key, ui.use(Accent).name }), ui.messages(Probe).bind(.check));
        // a value provided here is for what the probe renders next, not its update
        try ui.provide(Accent, &.{ .name = "probe's own" });
        try ui.print(.{}, "{s} inside: {s}", .{ props.key, ui.use(Accent).name });
    }
};

const Themed = struct {
    pub const Props = struct {};

    pub fn view(ui: *Ui, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();

        try testing.expect(ui.tryUse(Unprovided) == null);
        try ui.child(Probe, "root", .{ .key = "a" });
        {
            try ui.open(null, .{});
            defer ui.close();
            const dark = try ui.arena().create(Accent);
            dark.* = .{ .name = "dark" };
            try ui.provide(Accent, dark);
            try ui.child(Probe, "inner", .{ .key = "b" });
        }
        // the container that held the provided value is closed
        try ui.child(Probe, "after", .{ .key = "c" });
    }
};

test "contexts reach what is rendered after them, until their container closes" {
    var accent: Accent = .{ .name = "light" };
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io, .provide = &.{.of(&accent)} });
    defer rt.deinit();

    _ = try rt.frame(Themed, .{}, .init(400, 300), .zero);
    try testing.expect(hasText(&rt, "a: light"));
    try testing.expect(hasText(&rt, "b: dark"));
    try testing.expect(hasText(&rt, "c: light"));
    try testing.expect(hasText(&rt, "a inside: probe's own"));

    // updates see what their view was rendered with
    try clickButton(&rt, "a: light");
    try clickButton(&rt, "b: dark");
    try clickButton(&rt, "c: light");
    const probe = struct {
        fn state(r: *TestRuntime, key: []const u8) *Probe.State {
            const instance = r.core.instances.get(instanceId(instanceId(root_parent, Themed, {}), Probe, key)).?;
            const storage: *Storage(Probe) = @alignCast(@fieldParentPtr("instance", instance));
            return &storage.state;
        }
    }.state;
    try testing.expectEqualStrings("light", probe(&rt, "root").seen_in_update.?);
    try testing.expectEqualStrings("dark", probe(&rt, "inner").seen_in_update.?);
    try testing.expectEqualStrings("light", probe(&rt, "after").seen_in_update.?);
}

/// Records the messages its buttons bind in each of the ways there are.
const Recorder = struct {
    pub const State = struct {
        log: [8]Msg = undefined,
        len: usize = 0,
    };

    pub const Msg = union(enum) {
        plain,
        number: u64,
        name: []const u8,
        /// Too big to carry inline.
        many: [6]u64,
        relayed: u64,
    };

    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, _: *Update(Recorder)) void {
        state.log[state.len] = msg;
        state.len += 1;
    }

    pub fn view(ui: *Ui, _: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();

        const on = ui.messages(Recorder);
        try testButton(ui, "plain", "plain", on.bind(.plain));
        try testButton(ui, "number", "number", on.bind(.{ .number = 42 }));
        var buffer: [8]u8 = undefined;
        // the slice is carried, not what it points to: frame memory will do
        try testButton(ui, "name", "name", on.bind(.{ .name = try ui.arena().dupe(u8, try std.fmt.bufPrint(&buffer, "n{d}", .{1})) }));
        try testButton(ui, "many", "many", try on.bindAlloc(.{ .many = .{ 1, 2, 3, 4, 5, 6 } }));
        try testButton(ui, "with", "with", try on.handler(.many).withAlloc(ui.arena(), .{ 10, 0, 0, 0, 0, 0 }));
        try ui.one(Relay, .{ .on_fire = on.handler(.relayed).with(7) });
        try ui.one(Lamp, .{});
    }
};

/// Fires the action it is given from its `update`.
const Relay = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { fire };
    pub const Props = struct { on_fire: Action };

    pub fn update(_: *State, msg: Msg, ctx: *Update(Relay)) !void {
        switch (msg) {
            .fire => try ctx.emit(ctx.props.on_fire, {}),
        }
    }

    pub fn view(ui: *Ui, _: *const State, _: Props) !void {
        try testButton(ui, "fire", "fire", ui.messages(Relay).bind(.fire));
    }
};

/// Binds a whole `Msg` chosen at run time.
const Lamp = struct {
    pub const State = struct { lit: bool = false };
    pub const Msg = union(enum) { set: bool };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, _: *Update(Lamp)) void {
        switch (msg) {
            .set => |lit| state.lit = lit,
        }
    }

    pub fn view(ui: *Ui, state: *const State, _: Props) !void {
        const next: Msg = .{ .set = !state.lit };
        try testButton(ui, "lamp", if (state.lit) "lamp on" else "lamp off", ui.messages(Lamp).bind(next));
    }
};

test "actions carry their message inline, or in the frame arena when it is too big" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    // a tag, a slice and a whole small `Msg` fit; six u64s don't
    comptime std.debug.assert(@sizeOf(Recorder.Msg) > inline_size);
    comptime std.debug.assert(@sizeOf(Lamp.Msg) <= inline_size);

    _ = try rt.frame(Recorder, .{}, .init(400, 600), .zero);
    for ([_][]const u8{ "plain", "number", "name", "many", "with", "fire" }) |label| {
        try clickButton(&rt, label);
        _ = try rt.frame(Recorder, .{}, .init(400, 600), .zero);
    }

    const state = rt.rootState(Recorder).?;
    const log = state.log[0..state.len];
    try testing.expectEqual(6, log.len);
    try testing.expectEqual(.plain, log[0]);
    try testing.expectEqual(42, log[1].number);
    try testing.expectEqualStrings("n1", log[2].name);
    try testing.expectEqual([6]u64{ 1, 2, 3, 4, 5, 6 }, log[3].many);
    try testing.expectEqual([6]u64{ 10, 0, 0, 0, 0, 0 }, log[4].many);
    // bound with a payload in one view, fired by another component's update
    try testing.expectEqual(7, log[5].relayed);

    // `one` is `child` with no key
    try testing.expect(rt.core.instances.contains(instanceId(instanceId(root_parent, Recorder, {}), Lamp, {})));

    try clickButton(&rt, "lamp off");
    _ = try rt.frame(Recorder, .{}, .init(400, 600), .zero);
    try clickButton(&rt, "lamp on");
    _ = try rt.frame(Recorder, .{}, .init(400, 600), .zero);
    try testing.expect(hasText(&rt, "lamp off"));
}

test "element IDs are 64 bits: keys whose IDs share their low 32 bits stay distinct" {
    const Pair = struct {
        pub const Props = struct { a: u64, b: u64 };

        pub fn view(ui: *Ui, props: Props) !void {
            try ui.open(null, .{ .layout = .{ .axis = .y } });
            defer ui.close();
            inline for (.{ "a", "b" }) |name| {
                try ui.open(@field(props, name), .{ .layout = .{ .sizing = .fixed(10) } });
                ui.close();
            }
        }
    };

    // a birthday search: two keys whose IDs agree in their low 32 bits,
    // which 32-bit IDs would have taken for one element
    const scope = instanceId(root_parent, Pair, {});
    var seen: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    defer seen.deinit(testing.allocator);
    const pair: [2]u64 = for (0..1 << 22) |i| {
        const key: u64 = i;
        const gop = try seen.getOrPut(testing.allocator, @truncate(elementId(scope, key).id));
        if (gop.found_existing) break .{ gop.value_ptr.*, key };
        gop.value_ptr.* = key;
    } else return error.NoCollisionFound;
    const a = elementId(scope, pair[0]);
    const b = elementId(scope, pair[1]);
    try testing.expectEqual(@as(u32, @truncate(a.id)), @as(u32, @truncate(b.id)));
    try testing.expect(a.id != b.id);

    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    _ = try rt.frame(Pair, .{ .a = pair[0], .b = pair[1] }, .init(100, 100), .zero);
    const unit_a = rt.context().getUnitById(a).?;
    const unit_b = rt.context().getUnitById(b).?;
    try testing.expect(unit_a != unit_b);
    try testing.expectEqual(a.id, unit_a.id);
    try testing.expect(unit_b.bbox.y > unit_a.bbox.y);
}

/// Fails on `.refuse`, after changing its state, as an `update` that runs
/// out of memory halfway might.
const Fallible = struct {
    pub const State = struct {
        applied: [4]i32 = undefined,
        len: usize = 0,
        /// Set by the update that failed, before it failed.
        half_done: bool = false,
    };
    pub const Msg = union(enum) { apply: i32, refuse };
    pub const Props = struct { handler: *?Handler(i32) = undefined };

    pub fn update(state: *State, msg: Msg, _: *Update(Fallible)) !void {
        switch (msg) {
            .apply => |value| {
                state.applied[state.len] = value;
                state.len += 1;
            },
            .refuse => {
                state.half_done = true;
                return error.Refused;
            },
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        props.handler.* = ui.messages(Fallible).handler(.apply);
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();
        try testButton(ui, "refuse", "refuse", ui.messages(Fallible).bind(.refuse));
        try ui.print(.{}, "applied {d}", .{state.len});
    }
};

test "an update's error is returned by the call that delivered it, and later messages wait" {
    var rt: TestRuntime = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();

    var handler: ?Handler(i32) = null;
    _ = try rt.frame(Fallible, .{ .handler = &handler }, .init(200, 100), .zero);
    const apply = handler.?;
    const refuse = bindHandler(Fallible, instanceId(root_parent, Fallible, {}), .refuse);

    try rt.post(apply, 1);
    try rt.post(refuse, {});
    try rt.post(apply, 2);

    // from the frame, which delivers queued messages first
    try testing.expectError(error.Refused, rt.frame(Fallible, .{ .handler = &handler }, .init(200, 100), .zero));
    const state = rt.rootState(Fallible).?;
    // the state is as the failing update left it
    try testing.expectEqualSlices(i32, &.{1}, state.applied[0..state.len]);
    try testing.expect(state.half_done);
    // the message after the failing one is still queued, for the next call
    try testing.expect(rt.needsFrame());
    _ = try rt.frame(Fallible, .{ .handler = &handler }, .init(200, 100), .zero);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, state.applied[0..state.len]);
    try testing.expect(hasText(&rt, "applied 2"));

    // from input, which delivers the click's message at once
    const point = app_testing.center(try findButton(&rt, "refuse"));
    try press(&rt, point);
    try testing.expectError(error.Refused, release(&rt, point));
    _ = try rt.frame(Fallible, .{ .handler = &handler }, .init(200, 100), .zero);
}
