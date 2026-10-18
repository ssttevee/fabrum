//! A fake native widget tree: native widgets as plain data in memory, with
//! no window and no toolkit, for tests.
//!
//! `app.testing.Harness` runs apps against it, whatever platform they are
//! built for, so tests click native buttons, type into native fields and
//! tab through focus on any OS, and check the widgets fabrum made, their
//! frames and their values. It is not a platform: programs never run on it.
//!
//! It behaves as macOS does where platforms differ: only text fields take
//! focus unless `full_keyboard_access` is on, and sizes are close to
//! AppKit's regular controls.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const native = @import("../native.zig");
const Spec = native.Spec;
const Value = native.Value;
const Event = native.Event;

/// The in-memory widget tree. Must not move once its `backend` is in use;
/// `create` puts one on the heap.
pub const NativeTree = struct {
    gpa: Allocator,
    widgets: std.AutoArrayHashMapUnmanaged(native.Handle, Widget) = .empty,
    /// Handles are never reused, so a stale one finds nothing.
    next_handle: usize = 1,
    focus: native.FocusTarget = .none,
    /// The last scene presented; valid until the runtime's next frame.
    scene: native.Scene = .{},
    presents: usize = 0,
    /// Whether every control takes focus (macOS's "Keyboard navigation"),
    /// or only text fields.
    full_keyboard_access: bool = false,
    look: native.Theme = .{},
    /// Whether writes are reported back as events, as GTK's `changed`
    /// signal reports `gtk_editable_set_text`. They arrive while a frame
    /// runs, from inside `setValue`.
    report_writes: bool = false,
    /// Whether focusing a widget reports `.focus = true`, as AppKit's
    /// `becomeFirstResponder` does, from inside `focus`.
    report_focus: bool = false,
    /// Where events the tree reports by itself go: the runtime's
    /// `nativeEvent`. `app.testing.Harness` sets it.
    listener: ?Listener = null,
    /// The first error the listener returned, as the backend's calls can't.
    listener_error: ?anyerror = null,

    pub fn create(gpa: Allocator) Allocator.Error!*NativeTree {
        const self = try gpa.create(NativeTree);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Frees the widget tree. The runtime destroys its widgets first.
    pub fn destroy(self: *NativeTree) void {
        for (self.widgets.values()) |*widget| widget.deinit(self.gpa);
        self.widgets.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn backend(self: *NativeTree) native.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Receives events the tree reports by itself, from inside backend
    /// calls, as a toolkit's signals and delegates do.
    pub const Listener = struct {
        ctx: *anyopaque,
        report: *const fn (ctx: *anyopaque, id: native.Id, event: Event) anyerror!void,
    };

    fn emit(self: *NativeTree, id: native.Id, event: Event) void {
        const listener = self.listener orelse return;
        listener.report(listener.ctx, id, event) catch |err| {
            if (self.listener_error == null) self.listener_error = err;
        };
    }

    /// The widget made for the element with `id`, or null.
    pub fn find(self: *NativeTree, id: native.Id) ?*Widget {
        for (self.widgets.values()) |*widget| {
            if (widget.id == id) return widget;
        }
        return null;
    }

    /// The widgets in the order they were made.
    pub fn all(self: *NativeTree) []Widget {
        return self.widgets.values();
    }

    /// The focused widget, if a native one is.
    pub fn focusedWidget(self: *NativeTree) ?*Widget {
        return switch (self.focus) {
            .native => |handle| self.widgets.getPtr(handle),
            else => null,
        };
    }

    // What the user does. Each returns the event the toolkit would report,
    // for the caller to give `Runtime.nativeEvent`, or null if nothing
    // happens, as for a disabled control.

    /// A click: presses a button or menu item, flips a checkbox or switch.
    pub fn click(self: *NativeTree, widget: *Widget) Allocator.Error!?Event {
        if (!widget.enabled()) return null;
        switch (widget.spec) {
            .button, .menu_item => return .activate,
            .checkbox, .@"switch" => {
                const on = !(widget.value == .toggle and widget.value.toggle);
                try widget.show(self.gpa, .{ .toggle = on });
                return .{ .toggle = on };
            },
            .text_field => {
                self.focus = .{ .native = widget.handle };
                return .{ .focus = true };
            },
            else => return null,
        }
    }

    /// Text inserted at the end of a field, as one keystroke.
    pub fn insert(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (!widget.enabled() or widget.spec != .text_field) return null;
        const old = if (widget.value == .text) widget.value.text else "";
        const joined = try std.mem.concat(self.gpa, u8, &.{ old, text });
        defer self.gpa.free(joined);
        try widget.show(self.gpa, .{ .text = joined });
        return .{ .text = widget.value.text };
    }

    /// A field's whole text replaced, as by pasting over a selection.
    pub fn replace(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (!widget.enabled() or widget.spec != .text_field) return null;
        try widget.show(self.gpa, .{ .text = text });
        return .{ .text = widget.value.text };
    }

    /// An IME pre-edit: `marked` shows after the text, uncommitted, and is
    /// not reported.
    pub fn compose(self: *NativeTree, widget: *Widget, marked: []const u8) Allocator.Error!void {
        std.debug.assert(widget.spec == .text_field);
        const copy = try self.gpa.dupe(u8, marked);
        if (widget.marked) |old| self.gpa.free(old);
        widget.marked = copy;
    }

    /// Ends a composition by committing `text` in place of the pre-edit.
    /// Returns the text event; the caller then reports `composition_end`.
    pub fn commit(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (widget.marked) |old| self.gpa.free(old);
        widget.marked = null;
        return self.insert(widget, text);
    }

    /// A slider dragged to `number`, clamped to its range.
    pub fn slide(self: *NativeTree, widget: *Widget, number: f64) Allocator.Error!?Event {
        if (!widget.enabled() or widget.spec != .slider) return null;
        const clamped = std.math.clamp(number, widget.spec.slider.min, widget.spec.slider.max);
        try widget.show(self.gpa, .{ .number = clamped });
        return .{ .number = clamped };
    }

    const vtable: native.Backend.VTable = .{
        .create = vtCreate,
        .update = vtUpdate,
        .destroy = vtDestroy,
        .setFrame = vtSetFrame,
        .measure = vtMeasure,
        .setValue = vtSetValue,
        .composing = vtComposing,
        .canFocus = vtCanFocus,
        .focus = vtFocus,
        .present = vtPresent,
        .theme = vtTheme,
    };

    fn cast(ptr: *anyopaque) *NativeTree {
        return @ptrCast(@alignCast(ptr));
    }

    fn get(self: *NativeTree, handle: native.Handle) *Widget {
        return self.widgets.getPtr(handle) orelse std.debug.panic("app.testing.NativeTree: no widget {d}", .{@backingInt(handle)});
    }

    fn vtCreate(ptr: *anyopaque, id: native.Id, spec: *const Spec, value: *const Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        _ = parent;
        const self = cast(ptr);
        const handle: native.Handle = @fromBackingInt(@intCast(self.next_handle));
        const owned_spec = try spec.clone(self.gpa);
        errdefer owned_spec.free(self.gpa);
        const owned_value = try value.clone(self.gpa);
        errdefer owned_value.free(self.gpa);
        try self.widgets.put(self.gpa, handle, .{ .id = id, .handle = handle, .spec = owned_spec, .value = owned_value });
        self.next_handle += 1;
        return handle;
    }

    fn vtUpdate(ptr: *anyopaque, handle: native.Handle, old: *const Spec, new: *const Spec) void {
        _ = old;
        const self = cast(ptr);
        const widget = self.get(handle);
        const copy = new.clone(self.gpa) catch @panic("app.testing.NativeTree: out of memory");
        widget.spec.free(self.gpa);
        widget.spec = copy;
        widget.updates += 1;
    }

    fn vtDestroy(ptr: *anyopaque, handle: native.Handle) void {
        const self = cast(ptr);
        var removed = (self.widgets.fetchOrderedRemove(handle) orelse return).value;
        if (self.focus == .native and self.focus.native == handle) self.focus = .none;
        removed.deinit(self.gpa);
    }

    fn vtSetFrame(ptr: *anyopaque, handle: native.Handle, frame: Rect) void {
        const widget = cast(ptr).get(handle);
        widget.frame = frame;
        widget.frames += 1;
    }

    fn vtMeasure(ptr: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        _ = constraints;
        return cast(ptr).get(handle).fittingSize();
    }

    fn vtSetValue(ptr: *anyopaque, handle: native.Handle, value: *const Value) void {
        const self = cast(ptr);
        const widget = self.get(handle);
        widget.show(self.gpa, value.*) catch @panic("app.testing.NativeTree: out of memory");
        widget.writes += 1;
        if (self.report_writes) switch (widget.value) {
            .none => {},
            .toggle => |on| self.emit(widget.id, .{ .toggle = on }),
            .number => |n| self.emit(widget.id, .{ .number = n }),
            .text => |t| self.emit(widget.id, .{ .text = t }),
        };
    }

    fn vtComposing(ptr: *anyopaque, handle: native.Handle) bool {
        return cast(ptr).get(handle).marked != null;
    }

    fn vtCanFocus(ptr: *anyopaque, handle: native.Handle) bool {
        const self = cast(ptr);
        const widget = self.get(handle);
        if (!widget.enabled()) return false;
        return switch (widget.spec) {
            .text_field => true,
            .button, .checkbox, .@"switch", .slider => self.full_keyboard_access,
            else => false,
        };
    }

    fn vtFocus(ptr: *anyopaque, target: native.FocusTarget) void {
        const self = cast(ptr);
        self.focus = target;
        if (self.report_focus and target == .native) self.emit(self.get(target.native).id, .{ .focus = true });
    }

    fn vtPresent(ptr: *anyopaque, scene: *const native.Scene) void {
        const self = cast(ptr);
        self.scene = scene.*;
        self.presents += 1;
    }

    fn vtTheme(ptr: *anyopaque) native.Theme {
        const self = cast(ptr);
        var look = self.look;
        look.full_keyboard_access = self.full_keyboard_access;
        return look;
    }
};

/// One native widget, as data.
pub const Widget = struct {
    /// The element it was made for.
    id: native.Id,
    handle: native.Handle,
    /// Its props, as last created or updated.
    spec: Spec,
    /// What it shows: a checkbox's state, a slider's position, a field's
    /// committed text.
    value: Value,
    /// Text being composed after `value`, if any.
    marked: ?[]u8 = null,
    /// In its parent, from the top left; null until laid out.
    frame: ?Rect = null,
    /// How many times fabrum changed its props, wrote its value, and moved
    /// it.
    updates: usize = 0,
    writes: usize = 0,
    frames: usize = 0,

    fn deinit(self: *Widget, gpa: Allocator) void {
        self.spec.free(gpa);
        self.value.free(gpa);
        if (self.marked) |marked| gpa.free(marked);
    }

    fn show(self: *Widget, gpa: Allocator, value: Value) Allocator.Error!void {
        const copy = try value.clone(gpa);
        self.value.free(gpa);
        self.value = copy;
    }

    pub fn enabled(self: *const Widget) bool {
        return switch (self.spec) {
            inline .button, .checkbox, .@"switch", .slider, .text_field, .menu_item => |props| props.enabled,
            else => true,
        };
    }

    /// The text a field shows, including any pre-edit; "" for others.
    pub fn text(self: *const Widget, buffer: []u8) []const u8 {
        const committed = if (self.value == .text) self.value.text else "";
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ committed, self.marked orelse "" }) catch committed;
    }

    /// Sizes close to AppKit's regular controls in the system font.
    fn fittingSize(self: *const Widget) Vec2 {
        const char: f32 = 7;
        return switch (self.spec) {
            .button => |b| .init(@max(char * @as(f32, @floatFromInt(b.title.len)) + 28, 64), 22),
            .checkbox => |c| .init(if (c.title.len == 0) 18 else 22 + char * @as(f32, @floatFromInt(c.title.len)), 18),
            .@"switch" => .init(38, 22),
            .slider => .init(96, 20),
            .text_field => .init(96, 22),
            .progress => .init(96, 20),
            .menu_item, .alert => .zero,
            .extension => .init(64, 22),
        };
    }
};
