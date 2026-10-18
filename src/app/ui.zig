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
const Messages = message.Messages;
const Core = @import("runtime.zig").Core;
const native_api = @import("native.zig");
const NativeContent = @import("reconciler.zig").NativeContent;

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
    /// element's events and focus:
    ///
    /// - `on_click: ?Action = null`: queued when the element is clicked, or
    ///   activated with Space while focused;
    /// - `focusable: bool = false`: whether the element joins the Tab order,
    ///   with native elements, in paint order. Needs a key.
    /// - `modal: bool = false`: whether the element is a modal scope, such
    ///   as a drawn dialog's backdrop. While one is shown, the Tab order is
    ///   only what is inside the last one declared, native elements
    ///   included, and focus outside it moves to its first element.
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
            std.debug.assert(!container.focusable);
            const index = ctx.openContainer(decl);
            if (container.modal) core.modal = index;
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
        if (container.focusable) {
            core.focusable.put(core.gpa, unit_id.id, {}) catch |err| {
                _ = core.provider_marks.pop();
                return err;
            };
        }

        const index = ctx.openContainerId(unit_id, decl);
        if (container.modal) core.modal = index;
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

    /// Declares a native element with `key`, such as a platform button or
    /// menu item; see `native`. Most views use `app.widgets`, `app.menus`
    /// and `app.dialogs` rather than calling this.
    ///
    /// A view element gets a box in the open container, sized by
    /// `element.sizing` around the backend's measured size; the native view
    /// takes the box's frame. Elements placed elsewhere, such as menu items,
    /// take no space. Errors with `error.NoNativeBackend` if the runtime has
    /// none.
    pub fn native(self: *Ui, key: anytype, element: native_api.Element) !void {
        const core = self.core;
        const native_id = component.elementKey(self.scope, key);
        switch (element.spec.placement()) {
            .elsewhere => try core.reconciler.declare(core.gpa, native_id, 0, element),
            .view => {
                const unit_id: layout.Unit.Id = .fromInt(native_id);
                const ctx = &core.context;
                if (ctx.getUnitById(unit_id) != null) return error.DuplicateKey;
                try core.reconciler.declare(core.gpa, native_id, unit_id.id, element);
                const placeholder = try self.arena().create(NativeContent);
                placeholder.* = .{ .reconciler = &core.reconciler, .id = native_id };
                const index = ctx.openContainerId(unit_id, .{ .layout = .{ .sizing = element.sizing } });
                ctx.appendContent(&placeholder.content);
                ctx.closeContainer(index);
            },
        }
    }

    /// The 64-bit ID of this instance's native element with `key`.
    pub fn nativeId(self: *const Ui, key: anytype) native_api.Id {
        return component.elementKey(self.scope, key);
    }

    /// Whether the drawn element with `key` has keyboard focus, to draw a
    /// focus ring.
    pub fn focused(self: *const Ui, key: anytype) bool {
        const focus = self.core.focus orelse return false;
        return focus.native == null and focus.unit == self.id(key).id;
    }

    /// Appends a `layout.Context.spacer`: empty space that grows along the
    /// open container's axis, pushing what comes before and after it
    /// apart.
    pub fn spacer(self: *Ui) void {
        self.core.context.spacer();
    }

    /// Renders a child component, stateless or stateful, into the currently
    /// open container. `key` distinguishes repeated children of the same
    /// type; for a single child, use `one`. Values provided by the child
    /// stay in its subtree.
    pub fn child(self: *Ui, comptime C: type, key: anytype, props: PropsOf(C)) anyerror!void {
        try self.core.render(self, C, key, props);
    }

    /// Renders a child that appears once in this view, such as a dialog:
    /// the same as `child(C, {}, props)`, so it is the same instance.
    pub fn one(self: *Ui, comptime C: type, props: PropsOf(C)) anyerror!void {
        try self.core.render(self, C, {}, props);
    }

    /// Binds messages for the nearest stateful instance of `C` rendering
    /// this view, which may be this view's own component or any ancestor
    /// of it, as in `const on = ui.messages(App);` then `on.bind(.open)`
    /// and `on.handler(.picked)`. See `Messages`.
    ///
    /// Safety-checked builds panic if no instance of `C` is rendering this
    /// view; other builds bind to no instance, so the messages are
    /// discarded.
    pub fn messages(self: *const Ui, comptime C: type) Messages(C) {
        _ = MsgOf(C);
        return .{ .core = self.core, .target = self.owner(C) };
    }

    /// The nearest stateful instance of `C` rendering this view.
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
        return std.mem.indexOfScalar(u64, self.core.input.hovered.items, self.id(key).id) != null;
    }

    /// Whether the primary button was pressed on the element with `key`
    /// (or one of its descendants) and hasn't been released yet.
    pub fn pressed(self: *const Ui, key: anytype) bool {
        return std.mem.indexOfScalar(u64, self.core.input.pressed.items, self.id(key).id) != null;
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
/// except `id`, plus `on_click`, `focusable` and `modal`. Generating it
/// keeps the two in sync.
fn ContainerOptions() type {
    const decl = @typeInfo(layout.ContainerDeclaration).@"struct";
    const n = decl.field_names.len;

    var names: [n + 2][]const u8 = undefined;
    var types: [n + 2]type = undefined;
    var attrs: [n + 2]std.lang.Type.Struct.FieldAttributes = undefined;

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
    len += 1;

    const not_focusable = false;
    names[len] = "focusable";
    types[len] = bool;
    attrs[len] = .{ .default_value_ptr = &not_focusable };
    len += 1;

    const not_modal = false;
    names[len] = "modal";
    types[len] = bool;
    attrs[len] = .{ .default_value_ptr = &not_modal };

    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn declaration(options: Ui.Container) layout.ContainerDeclaration {
    var decl: layout.ContainerDeclaration = .{};
    inline for (@typeInfo(Ui.Container).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "on_click") and !std.mem.eql(u8, name, "focusable") and !std.mem.eql(u8, name, "modal")) {
            @field(decl, name) = @field(options, name);
        }
    }
    return decl;
}
