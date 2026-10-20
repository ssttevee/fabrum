//! Messages and the ways views and updates send them: actions, handlers,
//! `Update` and posters.
const std = @import("std");
const app_platform = @import("platform.zig");
const Allocator = std.mem.Allocator;

const component = @import("component.zig");
const InstanceId = component.InstanceId;
const TypeTag = component.TypeTag;
const typeTag = component.typeTag;
const erase = component.erase;
const context = @import("context.zig");
const Provided = context.Provided;
const runtime = @import("runtime.zig");
const Core = runtime.Core;
const Instance = runtime.Instance;
const Storage = runtime.Storage;
const layout = @import("../layout.zig");
const text_editor = @import("text_editor.zig");
const TextEditor = text_editor.TextEditor;
const TextInput = text_editor.TextInput;

/// The most bytes of payload a `Handler` carries inline, and their
/// largest alignment. Enough for a tag plus a pointer and a length, such
/// as a whole `Msg` whose largest payload is a slice, or for a payload of
/// up to three `u64`s, `usize`s or pointers.
///
/// Binding something bigger, or more aligned, inline is a compile error
/// that points to the allocating variants: `Messages.bindAlloc` and
/// `Handler.withAlloc`.
pub const inline_size = 24;
pub const inline_align = 8;

/// A callback into one stateful instance: one of its `Msg` tags, bound to
/// the instance. Whoever fires it only knows the payload type, `P`, not the
/// owner's `Msg`.
///
/// Made with `Messages.handler` (from `Ui.messages`) or `Update.handler`,
/// and fired with `Update.emit` or `Poster.post`. `with` binds a payload,
/// making the `Handler(void)` that elements fire, also called `Action`.
///
/// A handler is a plain value: copy it into props, store it in services,
/// or post to it from other threads. Its fields are the runtime's.
pub fn Handler(comptime P: type) type {
    return struct {
        target: InstanceId,
        message: MessageFn,
        /// The payload bound by `with`, `Messages.bind` and their
        /// allocating variants. Only `Handler(void)` has one.
        bound: Bound = .{},

        const Self = @This();

        pub const Payload = P;

        /// An `Action` that fires this handler with `payload`, carried
        /// inline: a compile error if `P` is too big for that, see
        /// `inline_size`.
        ///
        /// Messages from an action borrow its payload, so `update` must copy
        /// anything it keeps, and they are never passed to `Msg.deinit`.
        pub fn with(self: Self, payload: P) Action {
            if (P == void) @compileError("Handler(void).with: the handler is already an Action");
            checkInline(P, "Handler(" ++ @typeName(P) ++ ").with", "handler.withAlloc(ui.arena(), payload)");
            return .{ .target = self.target, .message = self.message, .bound = .inline_(payload) };
        }

        /// `with` for payloads too big to carry inline: `payload` is copied
        /// into `arena`, which must keep it until the action's last message
        /// is queued. In views, pass the frame arena, `ui.arena()`.
        pub fn withAlloc(self: Self, arena: Allocator, payload: P) Allocator.Error!Action {
            if (P == void) @compileError("Handler(void).withAlloc: the handler is already an Action");
            return .{ .target = self.target, .message = self.message, .bound = try .allocated(arena, payload) };
        }
    };
}

/// A callback without a payload, such as an element's `on_click` or a
/// stateless component's `on_cancel`: the same type as `Handler(void)`.
///
/// Made with `Messages.bind`, `Messages.handler` of a tag without payload,
/// or `Handler.with`. Fired by the runtime when an element is clicked, or
/// with `ctx.emit(action, {})` from `update`.
pub const Action = Handler(void);

/// A payload carried by a `Handler`: inline, or in an arena.
const Bound = struct {
    bytes: [inline_size]u8 align(inline_align) = undefined,
    /// Whether `bytes` holds a pointer to the payload, not the payload.
    indirect: bool = false,
    clone_payload: ?*const fn (Allocator, *const Bound) Allocator.Error!Bound = null,

    fn inline_(value: anytype) Bound {
        // callers check first, with `checkInline`, to say what to do instead
        comptime std.debug.assert(@sizeOf(@TypeOf(value)) <= inline_size and @alignOf(@TypeOf(value)) <= inline_align);
        var bound: Bound = .{ .clone_payload = clonePayload(@TypeOf(value)) };
        @as(*@TypeOf(value), @ptrCast(&bound.bytes)).* = value;
        return bound;
    }

    fn allocated(arena: Allocator, value: anytype) Allocator.Error!Bound {
        const stored = try arena.create(@TypeOf(value));
        stored.* = value;
        var bound: Bound = .{ .indirect = true, .clone_payload = clonePayload(@TypeOf(value)) };
        @as(**const anyopaque, @ptrCast(&bound.bytes)).* = @ptrCast(stored);
        return bound;
    }

    /// Copies even indirectly bound payloads before a task outlives a frame.
    pub fn clone(self: *const Bound, arena: Allocator) Allocator.Error!Bound {
        return if (self.clone_payload) |clone_payload| clone_payload(arena, self) else self.*;
    }

    fn clonePayload(comptime P: type) *const fn (Allocator, *const Bound) Allocator.Error!Bound {
        return struct {
            fn clone(arena: Allocator, bound: *const Bound) Allocator.Error!Bound {
                const value = @as(*const P, @ptrCast(@alignCast(bound.payload()))).*;
                return .allocated(arena, (try @import("task.zig").copy(arena, value)).value);
            }
        }.clone;
    }

    fn payload(self: *const Bound) *const anyopaque {
        return if (self.indirect) @as(*const *const anyopaque, @ptrCast(&self.bytes)).* else &self.bytes;
    }
};

/// Fails compilation if a `T` can't be carried inline by a handler.
fn checkInline(comptime T: type, comptime what: []const u8, comptime instead: []const u8) void {
    if (@sizeOf(T) > inline_size or @alignOf(T) > inline_align) {
        @compileError(std.fmt.comptimePrint(
            "app: {s}: {s} is {d} bytes aligned to {d}, but handlers carry at most {d} bytes aligned to {d} inline; use `try {s}`, which copies it into the frame arena",
            .{ what, @typeName(T), @sizeOf(T), @alignOf(T), inline_size, inline_align, instead },
        ));
    }
}

/// The message `handler` stands for when fired with `payload`. A payload
/// passed here belongs to the message; a bound one is borrowed.
pub fn make(handler: anytype, gpa: Allocator, payload: @TypeOf(handler).Payload) Allocator.Error!Message {
    if (@TypeOf(handler).Payload == void) {
        return handler.message(gpa, handler.target, handler.bound.payload(), false);
    }
    return handler.message(gpa, handler.target, erase(&payload), true);
}

/// The message `handler` stands for when fired with `payload`, which the
/// message borrows rather than owns, as messages from actions do: `update`
/// copies what it keeps, and the payload is never passed to `Msg.deinit`.
/// For payloads the runtime keeps alive until the message is delivered,
/// such as the text a native field reported.
pub fn makeBorrowed(handler: anytype, gpa: Allocator, payload: @TypeOf(handler).Payload) Allocator.Error!Message {
    return handler.message(gpa, handler.target, erase(&payload), false);
}

/// Binds messages for the nearest stateful instance of `C` rendering a
/// view, from `Ui.messages`, so that a view, or a stateless helper deep
/// inside it, can make actions and handlers for it:
///
/// ```zig
/// const on = ui.messages(App);
/// try ui.child(Dialog, {}, .{ .on_cancel = on.bind(.close), .on_pick = on.handler(.picked) });
/// ```
///
/// The instance is found when `ui.messages` is called. Safety-checked
/// builds panic there if no instance of `C` is rendering the view; other
/// builds bind to no instance, and the messages are discarded.
pub fn Messages(comptime C: type) type {
    return struct {
        core: *Core,
        /// The instance messages are bound to.
        target: InstanceId,

        const Self = @This();

        /// An `Action` that delivers a message to the instance. `msg` is
        /// one of:
        ///
        /// - a tag without payload: `on.bind(.refresh)`;
        /// - a tag and its payload: `on.bind(.{ .choose = index })`;
        /// - a whole `C.Msg`, perhaps chosen at run time.
        ///
        /// The payload, or the whole `Msg`, is carried inline in the action,
        /// so binding can't fail; it is a compile error if it is too big for
        /// that (see `inline_size`), in which case use `bindAlloc`. As with
        /// every action, messages borrow the payload.
        pub fn bind(self: Self, msg: anytype) Action {
            switch (comptime Bind.of(@TypeOf(msg))) {
                .tag => return self.handler(bareTag(@tagName(msg))),
                .field => |name| {
                    const tag = @field(Tag, name);
                    const payload: PayloadOf(C, tag) = @field(msg, name);
                    checkInline(@TypeOf(payload), "Messages(" ++ @typeName(C) ++ ").bind(.{ ." ++ name ++ " = ... })", "on.bindAlloc(.{ ." ++ name ++ " = payload })");
                    return .{ .target = self.target, .message = Envelope(C).fromPayload(tag), .bound = .inline_(payload) };
                },
                .msg => {
                    checkInline(C.Msg, "Messages(" ++ @typeName(C) ++ ").bind", "on.bindAlloc(msg)");
                    return .{ .target = self.target, .message = Envelope(C).fromMsg, .bound = .inline_(@as(C.Msg, msg)) };
                },
            }
        }

        /// `bind` for messages too big to carry inline: the payload, or the
        /// whole `Msg`, is copied into the frame arena.
        pub fn bindAlloc(self: Self, msg: anytype) Allocator.Error!Action {
            const arena = self.core.arena.allocator();
            switch (comptime Bind.of(@TypeOf(msg))) {
                .tag => return self.handler(bareTag(@tagName(msg))),
                .field => |name| return self.handler(@field(Tag, name)).withAlloc(arena, @field(msg, name)),
                .msg => return .{ .target = self.target, .message = Envelope(C).fromMsg, .bound = try .allocated(arena, @as(C.Msg, msg)) },
            }
        }

        /// A handler for one of `C.Msg`'s tags, whose payload type is the
        /// tag's, for a child to fire. A tag without payload makes an
        /// `Action`.
        pub fn handler(self: Self, comptime tag: Tag) Handler(PayloadOf(C, tag)) {
            return bindHandler(C, self.target, tag);
        }

        const Tag = std.meta.Tag(C.Msg);

        /// The tag named `name`, checked to have no payload.
        fn bareTag(comptime name: []const u8) Tag {
            if (!@hasField(C.Msg, name)) @compileError(@typeName(C.Msg) ++ " has no `." ++ name ++ "`");
            const Payload = @FieldType(C.Msg, name);
            if (Payload != void) {
                @compileError("app: `." ++ name ++ "` of " ++ @typeName(C.Msg) ++ " carries a " ++ @typeName(Payload) ++
                    "; bind it with `.{ ." ++ name ++ " = payload }`, or pass `handler(." ++ name ++ ")` to whoever has the payload");
            }
            return @field(Tag, name);
        }

        /// The forms of `bind`'s argument.
        const Bind = union(enum) {
            tag,
            field: [:0]const u8,
            msg,

            fn of(comptime T: type) Bind {
                switch (@typeInfo(T)) {
                    .enum_literal => return .tag,
                    .@"struct" => |info| if (info.field_names.len == 1 and @hasField(C.Msg, info.field_names[0])) {
                        return .{ .field = info.field_names[0] };
                    },
                    else => {},
                }
                return .msg;
            }
        };
    };
}

/// The payload type of `C.Msg`'s `tag`.
pub fn PayloadOf(comptime C: type, comptime tag: std.meta.Tag(C.Msg)) type {
    return @FieldType(C.Msg, @tagName(tag));
}

/// Passed to `update`: the instance's current props, an allocator for state,
/// its context values, and ways to send further messages.
pub fn Update(comptime C: type) type {
    return struct {
        core: *Core,
        instance: InstanceId,
        /// The props the instance was last rendered with.
        props: *const C.Props,
        /// The allocator for anything the state stores.
        gpa: Allocator,
        /// The context the instance was last rendered in.
        provided: ?*const Provided,

        const Self = @This();

        /// Runs concurrent work. The function's first parameter is *app.Task;
        /// its return type (including errors) must match the handler payload.
        pub fn run(self: *Self, comptime function: anytype, args: anytype, on_result: Handler(@import("task.zig").Result(function))) !void {
            try self.core.tasks.start(self.core, self.instance, null, false, function, args, on_result);
        }

        /// Replaces the command with this instance-local key. Old progress
        /// and results are discarded even if already queued.
        pub fn runKey(self: *Self, key: anytype, comptime function: anytype, args: anytype, on_result: Handler(@import("task.zig").Result(function))) !void {
            try self.core.tasks.start(self.core, self.instance, component.elementKey(self.instance, key), false, function, args, on_result);
        }

        /// Requests cancellation without waiting for I/O on this thread.
        pub fn cancel(self: *Self, key: anytype) !void {
            try self.core.tasks.cancel(self.core, self.instance, component.elementKey(self.instance, key));
        }

        /// Queues `payload` for the instance the `target` handler is bound to.
        /// `target` may be optional, in which case `null` does nothing. The message is
        /// processed after every message already queued.
        ///
        /// An `Action` is fired with `{}`, and sends the payload bound to it.
        ///
        /// If the message can't be queued, the payload is discarded and the
        /// error returned, for `update` to return in turn with `try`.
        pub fn emit(self: *Self, target: anytype, payload: anytype) Allocator.Error!void {
            const h = if (@typeInfo(@TypeOf(target)) == .optional) target orelse return else target;
            try self.core.enqueue(try make(h, self.gpa, payload));
        }

        /// A handler for one of this component's `Msg` tags, for example
        /// so that background work can post its result back with `poster`.
        pub fn handler(self: *const Self, comptime tag: std.meta.Tag(C.Msg)) Handler(PayloadOf(C, tag)) {
            return bindHandler(C, self.instance, tag);
        }

        /// A thread-safe handle for posting messages from background work.
        pub fn poster(self: *const Self) Poster {
            return .{ .core = self.core };
        }

        /// Queues a copy of `text` for `target`, a handler of `[]const u8`
        /// or `?[]const u8`, which the message borrows and the runtime
        /// frees once `update` has run: for text that may change before
        /// the message is delivered, such as an editor's.
        pub fn emitText(self: *Self, target: anytype, text: ?[]const u8) Allocator.Error!void {
            const h = if (@typeInfo(@TypeOf(target)) == .optional) target orelse return else target;
            try postText(.{ .core = self.core }, h, text);
        }

        /// The time of the last frame, from the host's clock.
        pub fn now(self: *const Self) std.Io.Timestamp {
            return self.core.now;
        }

        /// The layout ID of this instance's element with `key`, as
        /// `Ui.id` gives it in the view.
        pub fn element(self: *const Self, key: anytype) layout.Unit.Id {
            return component.elementId(self.instance, key);
        }

        // Focus

        /// Gives keyboard focus to this instance's element with `key`, now
        /// if the last frame showed it as focusable, else once a frame does.
        /// Shows its focus ring, as the keyboard would.
        pub fn focus(self: *const Self, key: anytype) void {
            self.core.requestFocus(self.element(key).id);
        }

        /// Takes keyboard focus away from the drawn element that has it.
        pub fn blur(self: *const Self) void {
            self.core.requestBlur();
        }

        // Scrolling

        /// Scrolls this instance's scroll container with `key` to `target`,
        /// clamped to its content as of the last frame. The host refreshes
        /// the frame as `options.refresh` says: `content` (a quality
        /// refresh) unless the scroll follows a gesture of the app's own,
        /// when `.{ .refresh = .interactive }` makes it fast, as the
        /// runtime's pans are.
        pub fn scrollTo(self: *const Self, key: anytype, target: runtime.ScrollTarget, options: runtime.ScrollOptions) void {
            self.core.scrollTo(self.element(key).id, target, options);
        }

        /// Scrolls whatever scroll containers are around the element with
        /// layout ID `id` (`element(key)`, or another instance's, from
        /// `app.testing.Instance.element`) so that it is in view.
        pub fn scrollIntoView(self: *const Self, id: layout.Unit.Id) void {
            self.core.scrollIntoView(id.id);
        }

        /// Asks the host to refresh the next frame's damage as `hint`
        /// says, at least: `page` after a page turn on e-ink. See
        /// `Runtime.refresh`.
        pub fn refresh(self: *const Self, hint: runtime.Refresh) void {
            self.core.refresh = self.core.refresh.strongest(hint);
            self.core.dirty = true;
        }

        // Text

        /// What `TextEditor.apply` needs for a message that came from the
        /// runtime (`Focus.on_text`): the time, the field's `options`, and
        /// the visual lines its view recorded (`Ui.textGeometry`).
        pub fn textEnv(self: *const Self, options: TextEditor.Options) TextEditor.Env {
            const target = self.core.text_target orelse 0;
            return .{ .now = self.core.now, .options = options, .geometry = self.core.textGeometry(target) };
        }

        /// Applies `input` to `editor` with `textEnv(options)`, and serves
        /// the clipboard: `copy` and `cut` write it, and `paste` reads it
        /// and sends the text to `on_paste`, which the app applies as
        /// `TextInput.paste`. Returns what `apply` did.
        pub fn editText(self: *Self, editor: *TextEditor, input: TextInput, options: TextEditor.Options, on_paste: Handler(?[]const u8)) !TextEditor.Outcome {
            const outcome = try editor.apply(self.gpa, input, self.textEnv(options));
            if (outcome.copy) |text| self.writeClipboard(text) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
            if (outcome.paste) self.readClipboard(on_paste) catch |err| switch (err) {
                error.Unsupported => {},
                else => return err,
            };
            return outcome;
        }

        // The host's services: see `app.platform.Services`. Each falls back
        // or fails with `error.Unsupported` where the host has none.

        /// Shows a message box: the host's, or one the runtime draws.
        pub fn message(self: *const Self, request: app_platform.MessageRequest) app_platform.Services.Error!void {
            if (self.core.services) |s| if (s.vtable.message) |show| return show(s.ptr, &request);
            try self.core.overlays.showDialog(self.gpa, request.title, request.text, &.{"OK"}, 0, null);
            self.core.dirty = true;
        }

        /// Asks a question with up to three buttons: the host's dialog, or
        /// one the runtime draws. `on_answer` gets the index of the button
        /// pressed, or null if the dialog was dismissed.
        pub fn confirm(self: *const Self, request: app_platform.ConfirmRequest, on_answer: Handler(?usize)) app_platform.Services.Error!void {
            if (request.buttons.len == 0 or request.buttons.len > 3) return error.ServiceFailed;
            const reply: app_platform.IndexReply = .{ .poster = self.poster(), .handler = on_answer };
            if (self.core.services) |s| if (s.vtable.confirm) |ask| return ask(s.ptr, &request, reply);
            try self.core.overlays.showDialog(self.gpa, request.title, request.text, request.buttons, request.default, reply);
            self.core.dirty = true;
        }

        /// Shows a popup or context menu: the host's, or one the runtime
        /// draws. `on_choose` gets the `MenuItem.id` chosen, or null.
        pub fn menu(self: *const Self, request: app_platform.MenuRequest, on_choose: Handler(?usize)) app_platform.Services.Error!void {
            const reply: app_platform.IndexReply = .{ .poster = self.poster(), .handler = on_choose };
            if (self.core.services) |s| if (s.vtable.menu) |show| return show(s.ptr, &request, reply);
            try self.core.overlays.showMenu(self.gpa, &request, reply);
            self.core.dirty = true;
        }

        /// Edits text with the platform's modal entry (an e-reader's system
        /// keyboard): `on_text` gets the text, or null if cancelled, as a
        /// message that borrows it. `error.Unsupported` where the platform
        /// has none: drawn fields take keys themselves then.
        pub fn systemText(self: *const Self, request: app_platform.TextRequest, on_text: Handler(?[]const u8)) app_platform.Services.Error!void {
            const s = self.core.services orelse return error.Unsupported;
            const edit = s.vtable.editText orelse return error.Unsupported;
            try edit(s.ptr, &request, .{ .poster = self.poster(), .handler = on_text });
        }

        /// Shows the platform's chooser for one file (`NSOpenPanel` on
        /// macOS). `on_choose` gets its path later, or null if the user
        /// cancelled; the message borrows the path.
        pub fn openFile(self: *const Self, request: app_platform.FileRequest, on_choose: Handler(?[]const u8)) app_platform.Services.Error!void {
            const s = self.core.services orelse return error.Unsupported;
            const open = s.vtable.openFile orelse return error.Unsupported;
            try open(s.ptr, &request, .{ .poster = self.poster(), .handler = on_choose });
        }

        /// Shows the platform's chooser for one directory. `on_choose` gets
        /// its path later, or null if the user cancelled; the message
        /// borrows the path.
        pub fn openDirectory(self: *const Self, request: app_platform.FileRequest, on_choose: Handler(?[]const u8)) app_platform.Services.Error!void {
            const s = self.core.services orelse return error.Unsupported;
            const open = s.vtable.openDirectory orelse return error.Unsupported;
            try open(s.ptr, &request, .{ .poster = self.poster(), .handler = on_choose });
        }

        /// Puts `text` on the clipboard: the host's, or, where the host has
        /// none, one private to the program, so that cut and paste still
        /// work within it.
        pub fn writeClipboard(self: *const Self, text: []const u8) app_platform.Services.Error!void {
            try self.core.writeClipboard(text);
        }

        /// Reads the clipboard (the host's, or the program's own): `on_text`
        /// gets its text, or null if it has none, as a message that borrows
        /// it.
        pub fn readClipboard(self: *const Self, on_text: Handler(?[]const u8)) app_platform.Services.Error!void {
            try self.core.readClipboard(.{ .poster = self.poster(), .handler = on_text });
        }

        /// Closes the window and quits, without asking `ui.guardClose`'s
        /// handler again: for once the user has confirmed.
        pub fn quit(self: *const Self) error{Unsupported}!void {
            const s = self.core.services orelse return error.Unsupported;
            const q = s.vtable.quit orelse return error.Unsupported;
            q(s.ptr);
        }

        /// Closes the window without asking `ui.guardClose`'s handler.
        /// Where it is the only window, as on AppKit and GTK, the program
        /// then quits.
        pub fn close(self: *const Self) error{Unsupported}!void {
            const s = self.core.services orelse return error.Unsupported;
            const c = s.vtable.close orelse return error.Unsupported;
            c(s.ptr);
        }

        /// The value of type `T` the instance's view was rendered with.
        /// Panics if nothing provides one; see "Contexts".
        pub fn use(self: *const Self, comptime T: type) *const T {
            return self.tryUse(T) orelse context.missing(T);
        }

        /// The value of type `T` the instance's view was rendered with, or
        /// null if nothing provides one.
        pub fn tryUse(self: *const Self, comptime T: type) ?*const T {
            return context.lookup(T, self.provided);
        }
    };
}

/// A thread-safe handle for queueing messages from any thread.
pub const Poster = struct {
    core: *Core,

    /// Queues `payload` for the instance the `target` handler is bound to and
    /// asks the platform for a frame. `target` may be optional, in which case `null`
    /// does nothing. An `Action` is posted with `{}`.
    ///
    /// The payload belongs to the message from this call on, even if it
    /// fails. Allocates the message with the runtime's gpa on the calling
    /// thread, so the gpa must be thread-safe when posting from other
    /// threads.
    pub fn post(self: Poster, target: anytype, payload: anytype) Allocator.Error!void {
        const h = if (@typeInfo(@TypeOf(target)) == .optional) target orelse return else target;
        try self.core.enqueue(try make(h, self.core.gpa, payload));
        if (self.core.platform) |platform| {
            platform.requestFrame();
        }
    }
};

/// Posts a copy of `text` (or null) to a handler of `[]const u8` or
/// `?[]const u8`, which the message borrows and the runtime frees once
/// `update` has run, as with the text a native field reports. For answers
/// that arrive from the platform, such as a chosen file's path.
pub fn postText(poster: Poster, handler: anytype, text: ?[]const u8) Allocator.Error!void {
    const H = @TypeOf(handler);
    const gpa = poster.core.gpa;
    const copy: ?[]u8 = if (text) |t| try gpa.dupe(u8, t) else null;
    var message = (switch (H.Payload) {
        []const u8 => makeBorrowed(handler, gpa, copy orelse ""),
        ?[]const u8 => makeBorrowed(handler, gpa, copy),
        else => @compileError("postText: the handler takes " ++ @typeName(H.Payload) ++ ", not text"),
    }) catch |err| {
        if (copy) |c| gpa.free(c);
        return err;
    };
    // the message has it from here, and frees it even if it can't be queued
    message.text = copy;
    try poster.core.enqueue(message);
    if (poster.core.platform) |platform| platform.requestFrame();
}

/// Makes the message a handler stands for. `payload` points to the
/// handler's payload type, or to the whole `Msg` for `Messages.bind`.
pub const MessageFn = *const fn (gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message;

/// A queued, type-erased message for one instance.
pub const Message = struct {
    target: InstanceId,
    /// The component the message was made for. Delivered only to
    /// instances of it.
    type_tag: TypeTag,
    /// The target component's `Msg`, allocated with the gpa.
    msg: *anyopaque,
    vtable: *const VTable,
    /// Whether the payload is owned by the message. Payloads bound to
    /// actions are borrowed and never deinitialized.
    owned: bool,
    /// Text the payload borrows, which the runtime frees with the gpa once
    /// the message is delivered or discarded; see `Poster.postText`.
    text: ?[]u8 = null,
    task: ?*@import("task.zig").Record = null,

    const VTable = struct {
        /// Frees the message and runs `update`, returning its error.
        deliver: *const fn (core: *Core, instance: *Instance, msg: *anyopaque) anyerror!void,
        /// Frees the message without delivering it.
        discard: *const fn (gpa: Allocator, msg: *anyopaque, owned: bool) void,
    };

    pub fn discard(self: Message, gpa: Allocator) void {
        self.vtable.discard(gpa, self.msg, self.owned);
        self.release(gpa);
    }

    /// Frees the text the payload borrowed, after delivery.
    pub fn release(self: Message, gpa: Allocator) void {
        if (self.text) |text| gpa.free(text);
        if (self.task) |task| _ = task.messages.fetchSub(1, .release);
    }
};

/// Message plumbing for component `C`.
pub fn Envelope(comptime C: type) type {
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

        /// For `Messages.bind` of a whole `Msg`.
        pub fn fromMsg(gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message {
            return create(gpa, target, @as(*const C.Msg, @ptrCast(@alignCast(payload))).*, owned);
        }

        /// For handlers of `tag`, whose payload is the tag's.
        pub fn fromPayload(comptime tag: std.meta.Tag(C.Msg)) MessageFn {
            const Payload = @FieldType(C.Msg, @tagName(tag));
            return struct {
                fn message(gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message {
                    const value = @as(*const Payload, @ptrCast(@alignCast(payload))).*;
                    return create(gpa, target, @unionInit(C.Msg, @tagName(tag), value), owned);
                }
            }.message;
        }

        fn deliver(core: *Core, instance: *Instance, erased: *anyopaque) anyerror!void {
            // `processMessages` checked the instance is a `C`
            std.debug.assert(instance.type_tag == typeTag(C));
            const stored: *C.Msg = @ptrCast(@alignCast(erased));
            const msg = stored.*;
            core.gpa.destroy(stored);

            const storage: *Storage(C) = @alignCast(@fieldParentPtr("instance", instance));
            var ctx: Update(C) = .{
                .core = core,
                .instance = instance.id,
                .props = &storage.props,
                .gpa = core.gpa,
                .provided = instance.provided,
            };
            // `void` or an error union of it, as `componentKind` checked
            const started = core.watchStart();
            defer core.watchEnd(started, @typeName(C), "update", @tagName(msg));
            return C.update(&storage.state, msg, &ctx);
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

pub fn bindHandler(comptime C: type, target: InstanceId, comptime tag: std.meta.Tag(C.Msg)) Handler(PayloadOf(C, tag)) {
    return .{ .target = target, .message = Envelope(C).fromPayload(tag) };
}
