//! `Ui`: what views use to build elements, render children, bind messages
//! and use contexts.
const std = @import("std");
const Allocator = std.mem.Allocator;

const layout = @import("../layout.zig");
const component = @import("component.zig");
const InstanceId = component.InstanceId;
const TypeTag = component.TypeTag;
const typeTag = component.typeTag;
const erase = component.erase;
const PropsOf = component.PropsOf;
const MsgOf = component.MsgOf;
const Provided = @import("context.zig").Provided;
const lookup = @import("context.zig").lookup;
const missing = @import("context.zig").missing;
const message = @import("message.zig");
const Action = message.Action;
const Handler = message.Handler;
const Envelope = message.Envelope;
const Core = @import("runtime.zig").Core;

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
        return component.elementId(self.scope, key);
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

        // values provided inside the container end with it
        try core.provider_marks.append(core.gpa, core.provided);

        if (@TypeOf(key) == @TypeOf(null)) {
            // only keyed elements can be hit-tested back to their events
            std.debug.assert(container.on_click == null);
            _ = ctx.openContainer(decl);
            self.depth += 1;
            return;
        }

        const unit_id = self.id(key);
        if (ctx.getUnitById(unit_id) != null) {
            _ = core.provider_marks.pop();
            return error.DuplicateKey;
        }

        if (container.on_click) |action| {
            core.clicks.put(core.gpa, unit_id.id, action) catch |err| {
                _ = core.provider_marks.pop();
                return err;
            };
        }

        _ = ctx.openContainerId(unit_id, decl);
        self.depth += 1;
    }

    /// Closes the container most recently opened by this view, and ends
    /// the values provided inside it.
    pub fn close(self: *Ui) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        const core = self.core;
        core.provided = core.provider_marks.pop().?;
        core.context.closeContainer(core.context.stack.getLast());
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
    /// type; pass `{}` for a single child. Values provided by the child stay
    /// in its subtree.
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
        return message.bindHandler(C, self.core, self.owner(C), tag);
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
        return component.root_parent;
    }

    /// Whether the pointer was over the element with `key` (or one of its
    /// descendants) as of the last input event.
    pub fn hovered(self: *const Ui, key: anytype) bool {
        return std.mem.indexOfScalar(u32, self.core.input.hovered.items, self.id(key).id) != null;
    }

    /// Whether the primary button was pressed on the element with `key`
    /// (or one of its descendants) and hasn't been released yet.
    pub fn pressed(self: *const Ui, key: anytype) bool {
        return std.mem.indexOfScalar(u32, self.core.input.pressed.items, self.id(key).id) != null;
    }

    /// Provides `value` as the `T` for everything rendered after it until
    /// the open container closes, or until this view returns if none of its
    /// containers is open; see "Contexts". `value` must live until the next
    /// frame starts.
    pub fn provide(self: *Ui, comptime T: type, value: *const T) Allocator.Error!void {
        const node = try self.arena().create(Provided);
        node.* = .{ .parent = self.core.provided, .key = typeTag(T), .value = erase(value) };
        self.core.provided = node;
    }

    /// The `T` provided to this point of the view. Panics if nothing
    /// provides one; see "Contexts".
    pub fn use(self: *const Ui, comptime T: type) *const T {
        return self.tryUse(T) orelse missing(T);
    }

    /// The `T` provided to this point of the view, or null if nothing
    /// provides one.
    pub fn tryUse(self: *const Ui, comptime T: type) ?*const T {
        return lookup(T, self.core.provided);
    }
};

/// A stateful instance rendering a view, in the chain `Ui.owner` searches.
pub const Ancestor = struct {
    parent: ?*const Ancestor,
    instance: InstanceId,
    type_tag: TypeTag,
};

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
