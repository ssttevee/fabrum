//! `Ui`: what views use to build elements, render children, bind messages
//! and use contexts.
const std = @import("std");
const Allocator = std.mem.Allocator;

const layout = @import("../layout.zig");
const Vec2 = @import("../vec2.zig");
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
const Messages = message.Messages;
const input_api = @import("input.zig");
const Pointer = input_api.Pointer;
const Focus = input_api.Focus;
const Shortcut = input_api.Shortcut;
const Cursor = input_api.Cursor;
const runtime_api = @import("runtime.zig");
const Core = runtime_api.Core;
const Scroll = runtime_api.Scroll;
const ScrollInfo = runtime_api.ScrollInfo;
const Capabilities = @import("capabilities.zig").Capabilities;
const TextGeometry = @import("text_editor.zig").TextGeometry;
const native_api = @import("native.zig");
const app_platform = @import("platform.zig");
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
    ///   activated with Space or Enter while focused;
    /// - `on_pointer: ?Handler(app.Pointer) = null`: takes the primary
    ///   button's press over the element, then its drags, long press and
    ///   release wherever the pointer goes, with where it is from the
    ///   element's box (`app.Pointer`), as a drawn slider needs;
    /// - `focusable: bool = false`: whether the element joins the Tab order,
    ///   with native elements, in paint order. Needs a key.
    /// - `focus_on_press: bool = false`: whether pressing the element
    ///   focuses it, as with text fields. Needs `focusable` or `focus`.
    /// - `focus: ?app.Focus = null`: what the element does with keys
    ///   while focused (`on_key` with a filter, `on_text` for text
    ///   inputs) and when focus comes and goes (`on_focus`). Makes it
    ///   focusable.
    /// - `scroll: ?app.Scroll = null`: makes the element a scroll
    ///   container whose content scrolls by the wheel, a drag of its
    ///   scrollbar, `Update.scrollTo` and focus; the runtime keeps the
    ///   offset by the element's key, and clips the content.
    /// - `cursor: ?app.Cursor = null`: the cursor to show over the
    ///   element, instead of the pointing hand over clickables.
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
        errdefer _ = core.provider_marks.pop();

        if (@TypeOf(key) == @TypeOf(null)) {
            // only keyed elements can be hit-tested back to their events
            std.debug.assert(container.on_click == null);
            std.debug.assert(container.on_pointer == null);
            std.debug.assert(!container.focusable);
            const index = try ctx.openContainer(decl);
            if (container.modal) core.modal = index;
            self.depth += 1;
            return;
        }

        const unit_id = self.id(key);
        if (ctx.getUnitById(unit_id) != null) return error.DuplicateKey;

        if (container.on_click) |action| try core.clicks.put(core.gpa, unit_id.id, action);
        if (container.on_pointer) |handler| try core.pointers.put(core.gpa, unit_id.id, handler);
        if (container.focusable or container.focus != null) try core.focusable.put(core.gpa, unit_id.id, {});
        if (container.focus) |focus| try core.focus_decls.put(core.gpa, unit_id.id, focus);
        if (container.focus_on_press) {
            std.debug.assert(container.focusable or container.focus != null);
            try core.focus_on_press.put(core.gpa, unit_id.id, {});
        }
        if (container.cursor) |cursor| try core.cursors.put(core.gpa, unit_id.id, cursor);

        var final = decl;
        if (container.scroll) |scroll| {
            // the runtime's offset, applied as the content's offset; both
            // axes clip, so content overflowing the one that doesn't scroll
            // is hidden rather than holding the container open
            const offset = try core.openScroll(unit_id.id, scroll);
            final.clip = .{ .horizontal = true, .vertical = true, .child_offset = Vec2.zero.sub(offset), .scrolls_horizontal = scroll.x, .scrolls_vertical = scroll.y };
            try core.scroll_frames.ensureUnusedCapacity(core.gpa, 1);
            try core.scroll_open.ensureUnusedCapacity(core.gpa, 1);
        }

        const index = try ctx.openContainerId(unit_id, final);
        if (container.scroll != null) {
            core.scroll_frames.appendAssumeCapacity(.{ .id = unit_id.id, .index = index });
            core.scroll_open.appendAssumeCapacity(.{ .id = unit_id.id, .index = index });
        }
        if (container.modal) core.modal = index;
        self.depth += 1;
    }

    /// Closes the container most recently opened by this view, and ends
    /// the values provided inside it.
    pub fn close(self: *Ui) void {
        std.debug.assert(self.depth > 0);
        const core = self.core;
        const index = core.context.stack.getLast();
        // a scroll container's scrollbars, drawn last so they are on top
        if (core.scroll_open.getLastOrNull()) |open_scroll| {
            if (open_scroll.index == index) {
                _ = core.scroll_open.pop();
                self.scrollbars(open_scroll.id) catch |err| switch (err) {
                    // the thumb's key is its container and axis, which no view element has
                    error.DuplicateKey => unreachable,
                    // the thumb didn't fit: fail the frame rather than lose it
                    else => |e| core.noteLayoutError(e),
                };
            }
        }
        self.depth -= 1;
        core.provided = core.provider_marks.pop().?;
        core.context.closeContainer(index);
        // the end of a native container's content
        if (core.native_parents.getLastOrNull()) |parent| {
            if (parent.index == index) _ = core.native_parents.pop();
        }
    }

    /// Appends text. `string` is copied into the frame arena, so it only
    /// needs to live for the call.
    pub fn text(self: *Ui, string: []const u8, style: layout.text.Style) ContentError!void {
        try self.appendText(try self.arena().dupe(u8, string), style);
    }

    /// Appends text formatted into the frame arena, as with `std.fmt`.
    /// Types with a `format` method print with `{f}`.
    pub fn print(self: *Ui, style: layout.text.Style, comptime format: []const u8, args: anytype) ContentError!void {
        try self.appendText(try std.fmt.allocPrint(self.arena(), format, args), style);
    }

    /// What appending content can fail with: the arena, or the layout
    /// outgrowing `Runtime.Options.context` (`error.LayoutCapacity`).
    pub const ContentError = Allocator.Error || layout.Context.Error;

    fn appendText(self: *Ui, owned: []const u8, style: layout.text.Style) ContentError!void {
        try self.core.context.appendContent(try self.core.make_text(self.core, owned, style));
    }

    /// Appends any layout content. `content` must live until the frame's
    /// render commands are consumed; the frame arena will do. If the
    /// layout is out of room (`error.LayoutCapacity`) the content is
    /// dropped and the frame fails with it.
    pub fn content(self: *Ui, c: *layout.Content) void {
        self.core.context.appendContent(c) catch |err| self.core.noteLayoutError(err);
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
        std.debug.assert(!element.spec.isContainer()); // use nativeOpen
        const core = self.core;
        const native_id = component.elementKey(self.scope, key);
        switch (element.spec.placement()) {
            .elsewhere => try core.reconciler.declare(core.gpa, native_id, 0, element, null),
            .view => {
                const unit_id: layout.Unit.Id = .fromInt(native_id);
                const ctx = &core.context;
                if (ctx.getUnitById(unit_id) != null) return error.DuplicateKey;
                try core.reconciler.declare(core.gpa, native_id, unit_id.id, element, core.nativeParent());
                const placeholder = try self.arena().create(NativeContent);
                placeholder.* = .init(&core.reconciler, native_id, &element.spec);
                const index = try ctx.openContainerId(unit_id, .{ .layout = .{ .sizing = element.sizing } });
                try ctx.appendContent(&placeholder.content);
                ctx.closeContainer(index);
            },
        }
    }

    /// Opens a native container element with `key`, such as a scroll view
    /// (`app.widgets.scrollView`): elements declared until the matching
    /// `close` are its content, made inside it and laid out with `inside`
    /// (its sizing is `element.sizing`) in its content's coordinates. Along
    /// the axes it scrolls, the content can be larger than the container,
    /// and is laid out against the scroll offset the platform reports.
    pub fn nativeOpen(self: *Ui, key: anytype, element: native_api.Element, inside: layout.Config) !void {
        const scroll = element.spec.scroll_view;
        const core = self.core;
        const ctx = &core.context;
        const native_id = component.elementKey(self.scope, key);
        const unit_id: layout.Unit.Id = .fromInt(native_id);
        if (ctx.getUnitById(unit_id) != null) return error.DuplicateKey;
        try core.reconciler.declare(core.gpa, native_id, unit_id.id, element, core.nativeParent());

        try core.provider_marks.append(core.gpa, core.provided);
        errdefer _ = core.provider_marks.pop();
        try core.native_parents.ensureUnusedCapacity(core.gpa, 1);

        var config = inside;
        config.sizing = element.sizing;
        const offset = core.reconciler.layoutScroll(native_id);
        const index = try ctx.openContainerId(unit_id, .{
            .layout = config,
            // the platform clips; the scissors mark the content's commands,
            // so a container clips one axis at least
            .clip = .{
                .horizontal = scroll.horizontal,
                .vertical = scroll.vertical or !scroll.horizontal,
                .child_offset = Vec2.zero.sub(offset),
                .scrolls_horizontal = scroll.horizontal,
                .scrolls_vertical = scroll.vertical,
            },
        });
        core.native_parents.appendAssumeCapacity(.{ .id = native_id, .index = index });
        self.depth += 1;
    }

    /// Holds closing the window or quitting for the app to confirm, while
    /// a view declares it: the host asks `Runtime.shouldClose` first, which
    /// then sends `on_request` why instead of letting it close. The app
    /// asks the user, and calls `quit` from `update` if they agree. The
    /// last one declared in a frame counts.
    pub fn guardClose(self: *Ui, on_request: Handler(app_platform.CloseReason)) void {
        self.core.close_guard = on_request;
    }

    /// The 64-bit ID of this instance's native element with `key`.
    pub fn nativeId(self: *const Ui, key: anytype) native_api.Id {
        return component.elementKey(self.scope, key);
    }

    /// Whether the drawn element with `key` has keyboard focus.
    pub fn focused(self: *const Ui, key: anytype) bool {
        const focus = self.core.focus orelse return false;
        return focus.native == null and focus.unit == self.id(key).id;
    }

    /// Whether the drawn element with `key` has keyboard focus that it
    /// reached by the keyboard (or `Update.focus`), so a focus ring should
    /// show, as CSS's `:focus-visible`; focus from a press shows none.
    pub fn focusVisible(self: *const Ui, key: anytype) bool {
        return self.focused(key) and self.core.focus_visible;
    }

    /// Declares a keyboard shortcut for this frame: while a drawn element
    /// has focus and neither it nor its ancestors take the key, `action`
    /// fires. See `app.Shortcut`.
    pub fn shortcut(self: *Ui, key: Shortcut, action: Action) Allocator.Error!void {
        try self.core.shortcuts.append(self.core.gpa, .{ .shortcut = key, .action = action });
    }

    /// Declares a timer that fires `action` every `period`, for as long as
    /// the view declares it, keyed like an element: declaring it again
    /// keeps its phase. The first firing is one period from the frame that
    /// first declared it.
    pub fn every(self: *Ui, key: anytype, period: std.Io.Duration, action: Action) Allocator.Error!void {
        try self.core.declareTimer(self.id(key).id, period, period, action);
    }

    /// Declares a timer that fires `action` once, `delay` after the frame
    /// that first declared it, unless the view stops declaring it first.
    pub fn after(self: *Ui, key: anytype, delay: std.Io.Duration, action: Action) Allocator.Error!void {
        try self.core.declareTimer(self.id(key).id, delay, null, action);
    }

    /// Where the scroll container with `key` is, as of the last frame, or
    /// null before its first.
    pub fn scrollInfo(self: *const Ui, key: anytype) ?ScrollInfo {
        const state = self.core.scrolls.get(self.id(key).id) orelse return null;
        return state.info();
    }

    /// Whether the caret of the focused text field with `key` is on in
    /// its blink: half a second on and half off from the last keystroke,
    /// steady after ten seconds idle, and always on where the platform
    /// doesn't animate (`app.Capabilities.animation`). Asks for the frame
    /// of the next flip.
    pub fn caretVisible(self: *Ui, key: anytype) bool {
        if (!self.focused(key)) return false;
        const core = self.core;
        if (!core.capabilities.animates()) return true;
        const half = std.time.ns_per_s / 2;
        const idle: i96 = 10 * std.time.ns_per_s;
        const since = core.now.nanoseconds - core.last_input.nanoseconds;
        if (since < 0 or since >= idle) return true;
        const phases = @divFloor(since, half);
        core.frameAt(.fromNanoseconds(core.last_input.nanoseconds + (phases + 1) * half));
        return @mod(phases, 2) == 0;
    }

    /// Records the visual lines of the text element with `key` for this
    /// frame, for `Update.textEnv` to hand the editor. `geometry` must
    /// live until the next frame starts; the frame arena will do.
    pub fn textGeometry(self: *Ui, key: anytype, geometry: *const TextGeometry) Allocator.Error!void {
        try self.core.text_geometries.put(self.core.gpa, self.id(key).id, geometry);
    }

    /// What the platform can do: `ui.use(app.Capabilities)`.
    pub fn capabilities(self: *const Ui) *const Capabilities {
        return self.core.capabilities;
    }

    /// Draws the scrollbars of the scroll container `id`, which is about
    /// to close, along the axes whose content overflows: a floating thumb
    /// at the container's edge, which the runtime drags.
    fn scrollbars(self: *Ui, container: u64) !void {
        const core = self.core;
        const state = core.scrolls.get(container) orelse return;
        if (!state.scrollbar) return;
        const info = state.info();
        const theme = self.use(native_api.Theme);
        inline for (.{ Vec2.Axis.y, Vec2.Axis.x }) |axis| {
            const scrolls_axis = if (axis == .y) state.y else state.x;
            if (scrolls_axis and info.max().axis(axis) > 0.5) {
                const thumb_key: ThumbKey = .{ .container = container, .axis = axis };
                const thumb_id = self.id(thumb_key).id;
                try core.thumbs.put(core.gpa, thumb_id, .{ .container = container, .axis = axis });
                const length = Core.thumbLength(info, axis);
                const position = Core.thumbPosition(info, axis);
                const active = self.hovered(thumb_key) or (core.thumb_drag != null and core.thumb_drag.?.container == container and core.thumb_drag.?.axis == axis);
                const thickness: f32 = if (active) 8 else 5;
                const inset = Core.scrollbar_inset;
                const gray = core.capabilities.isGray();
                try self.open(thumb_key, .{
                    .layout = .{ .sizing = if (axis == .y) .fixedXY(thickness, length) else .fixedXY(length, thickness) },
                    .floating = .{
                        .mode = .parent,
                        .parent_point = if (axis == .y) .right_top else .left_bottom,
                        .unit_point = if (axis == .y) .right_top else .left_bottom,
                        .offset = if (axis == .y) .init(-inset, inset + position) else .init(inset + position, -inset),
                    },
                    .background_color = if (gray) .black else theme.text.withAlpha(if (active) 150 else 100),
                    .corner_radius = .uniform(thickness / 2),
                });
                self.close();
            }
        }
    }

    /// Whether the runtime shows native widgets, so `app.widgets` declares
    /// the platform's controls; otherwise they are drawn (`app.drawn`), as
    /// on the `none` platform.
    pub fn hasNativeWidgets(self: *const Ui) bool {
        return self.core.reconciler.backend != null;
    }

    /// The time of the frame being built, from the host. Animation is a
    /// function of it, never of frame counts.
    pub fn now(self: *const Ui) std.Io.Timestamp {
        return self.core.now;
    }

    /// Asks for another frame as soon as the host can show one, for drawn
    /// animation. Ask again every frame to keep animating; see
    /// `Runtime.nextFrame`.
    pub fn animate(self: *Ui) void {
        self.frameAt(self.core.now);
    }

    /// Asks for a frame at `time` or soon after, for something drawn that
    /// changes then, such as a caret that blinks. Requests last one frame.
    pub fn frameAt(self: *Ui, time: std.Io.Timestamp) void {
        const core = self.core;
        if (core.wake == null or time.nanoseconds < core.wake.?.nanoseconds) core.wake = time;
    }

    /// Appends a `layout.Context.spacer`: empty space that grows along the
    /// open container's axis, pushing what comes before and after it
    /// apart. If the layout is out of room (`error.LayoutCapacity`) the
    /// spacer is dropped and the frame fails with it.
    pub fn spacer(self: *Ui) void {
        self.core.context.spacer() catch |err| self.core.noteLayoutError(err);
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

/// The key of a scroll container's scrollbar thumb, in the instance that
/// declared the container.
pub const ThumbKey = struct { container: u64, axis: Vec2.Axis };

/// The fields `Ui.Container` adds to `layout.ContainerDeclaration`, with
/// their defaults.
const extra_fields = .{
    .{ "on_click", ?Action, @as(?Action, null) },
    .{ "on_pointer", ?Handler(Pointer), @as(?Handler(Pointer), null) },
    .{ "focusable", bool, false },
    .{ "focus_on_press", bool, false },
    .{ "focus", ?Focus, @as(?Focus, null) },
    .{ "scroll", ?Scroll, @as(?Scroll, null) },
    .{ "cursor", ?Cursor, @as(?Cursor, null) },
    .{ "modal", bool, false },
};

fn isExtra(comptime name: []const u8) bool {
    inline for (extra_fields) |field| {
        if (comptime std.mem.eql(u8, field[0], name)) return true;
    }
    return false;
}

/// Builds `Ui.Container`: the fields of `layout.ContainerDeclaration`
/// except `id`, plus `extra_fields`. Generating it keeps the two in sync.
fn ContainerOptions() type {
    const decl = @typeInfo(layout.ContainerDeclaration).@"struct";
    const n = decl.field_names.len - 1 + extra_fields.len;

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
    for (extra_fields) |field| {
        const default: field[1] = field[2];
        names[len] = field[0];
        types[len] = field[1];
        attrs[len] = .{ .default_value_ptr = &default };
        len += 1;
    }
    std.debug.assert(len == n);

    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

fn declaration(options: Ui.Container) layout.ContainerDeclaration {
    var decl: layout.ContainerDeclaration = .{};
    inline for (@typeInfo(Ui.Container).@"struct".field_names) |name| {
        if (comptime !isExtra(name)) {
            @field(decl, name) = @field(options, name);
        }
    }
    return decl;
}
