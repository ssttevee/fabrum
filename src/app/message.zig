//! Messages and the ways views and updates send them: actions, handlers,
//! `Update` and posters.
const std = @import("std");
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

/// Makes the message a handler or an action stands for. `payload` points to
/// the handler's payload type, or to the whole `Msg` for `Ui.bind`.
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
    /// Whether the payload is owned by the message. `on_click` payloads
    /// borrow frame memory and are never deinitialized.
    owned: bool,

    const VTable = struct {
        /// Runs `update` and frees the message.
        deliver: *const fn (core: *Core, instance: *Instance, msg: *anyopaque) void,
        /// Frees the message without delivering it.
        discard: *const fn (gpa: Allocator, msg: *anyopaque, owned: bool) void,
    };

    pub fn discard(self: Message, gpa: Allocator) void {
        self.vtable.discard(gpa, self.msg, self.owned);
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

        /// For `Ui.bind`, whose payload is the whole `Msg`.
        pub fn fromMsg(gpa: Allocator, target: InstanceId, payload: *const anyopaque, owned: bool) Allocator.Error!Message {
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
                .provided = instance.provided,
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

pub fn bindHandler(comptime C: type, core: *Core, target: InstanceId, comptime tag: std.meta.Tag(C.Msg)) Handler(@FieldType(C.Msg, @tagName(tag))) {
    return .{ .core = core, .target = target, .message = Envelope(C).fromPayload(tag) };
}
