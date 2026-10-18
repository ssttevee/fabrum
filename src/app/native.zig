//! Native widgets: the contract between `fabrum.app` and a platform's own
//! controls, menus and dialogs.
//!
//! Views declare native elements as they declare drawn ones, through
//! `Ui.native` (usually by way of `app.widgets`, `app.menus` and
//! `app.dialogs`). Each frame the runtime reconciles the declarations
//! against the native objects it made earlier, keyed by 64-bit element ID:
//! it creates the new ones, updates the props that changed, destroys those
//! no longer declared, and sets frames only when they change. A `Backend`
//! does the platform's part; fabrum never names a platform type.
//!
//! Native views sit in fabrum's layout like any other element: their size
//! comes from the backend (`VTable.measure`, AppKit's `fittingSize`) through
//! a `layout.Content`, and their frame from the box laid out around it.
//! Drawn content between and over them is split into canvas layers, in
//! paint order (see `Scene`), so a drawn dialog can cover a native field.
//!
//! Events come back as `Event`s through `Runtime.nativeEvent`, and become
//! messages through the element's `Handlers`, as clicks do through
//! `on_click`.
//!
//! **Native containers** (`Spec.scroll_view`) hold native elements and
//! drawn content of their own, laid out by fabrum in the container's
//! content coordinates: the reconciler makes their children inside them,
//! and the scene gives each container its own stack of canvas layers and
//! views (`Scene.containers`). The platform scrolls the content itself and
//! reports where it is (`Event.scroll`), which fabrum lays out against.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Color = fabrum.Color;

const message = @import("message.zig");
const Action = message.Action;
const Handler = message.Handler;

/// Identifies a native element: a 64-bit hash of its instance and key, which
/// is also its layout unit's ID.
pub const Id = u64;

/// A backend's reference to one native object, opaque to fabrum.
pub const Handle = enum(usize) { _ };

/// What a native element is, with the props that aren't its value. The
/// common widget set; platform catalogues add theirs through `extension`.
///
/// Strings are borrowed from the view and copied by the runtime when it
/// keeps them.
pub const Spec = union(enum) {
    button: Button,
    checkbox: Toggle,
    @"switch": Toggle,
    slider: Slider,
    text_field: TextField,
    progress: Progress,
    menu_item: MenuItem,
    alert: Alert,
    scroll_view: ScrollView,
    extension: Extension,

    pub const Button = struct {
        title: []const u8,
        enabled: bool = true,
        /// `default` answers Return, as AppKit's key equivalent `\r` does.
        role: enum { normal, default } = .normal,
    };

    pub const Toggle = struct {
        /// The label beside the box. Switches have none on macOS.
        title: []const u8 = "",
        enabled: bool = true,
    };

    pub const Slider = struct {
        min: f64 = 0,
        max: f64 = 1,
        enabled: bool = true,
    };

    pub const TextField = struct {
        placeholder: []const u8 = "",
        enabled: bool = true,
    };

    pub const Progress = struct {
        /// From 0 to 1, or null to show activity without progress.
        value: ?f64,
    };

    /// An item in a menu of the menu bar, created when missing.
    pub const MenuItem = struct {
        menu: []const u8,
        title: []const u8,
        /// The key that selects it with the platform's shortcut modifier
        /// (Command on macOS), or "" for none.
        key: []const u8 = "",
        enabled: bool = true,
    };

    /// A modal alert, shown while it is declared, until answered.
    pub const Alert = struct {
        title: []const u8,
        message: []const u8 = "",
        /// From the default button on; at least one.
        buttons: []const []const u8 = &.{"OK"},
    };

    /// A native container that scrolls its content: `NSScrollView` on
    /// macOS, `GtkScrolledWindow` in GTK. Elements declared inside it are
    /// its content, laid out by fabrum as a sub-layout, taller or wider
    /// than the view along the axes it scrolls; the platform scrolls,
    /// clips, and draws the scrollers.
    pub const ScrollView = struct {
        horizontal: bool = false,
        vertical: bool = true,
    };

    /// A widget from one platform's catalogue: `class` belongs to that
    /// platform's namespace, which its backend recognises by address.
    pub const Extension = struct {
        class: *const ExtensionClass,
        props: *const anyopaque,
    };

    /// Where an element goes.
    pub const Placement = enum {
        /// A view laid out by fabrum, in the host's paint order.
        view,
        /// Somewhere of the platform's choosing, such as the menu bar or a
        /// sheet: no layout unit.
        elsewhere,
    };

    /// Whether elements are declared inside it, as its content.
    pub fn isContainer(self: Spec) bool {
        return self == .scroll_view;
    }

    pub fn placement(self: Spec) Placement {
        return switch (self) {
            .menu_item, .alert => .elsewhere,
            .extension => |e| e.class.placement,
            else => .view,
        };
    }

    /// Whether the two specs are of one kind, so one native object can
    /// show both. Otherwise it is replaced.
    pub fn sameKind(a: Spec, b: Spec) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .extension => |e| e.class == b.extension.class,
            else => true,
        };
    }

    pub fn eql(a: Spec, b: Spec) bool {
        if (!a.sameKind(b)) return false;
        return switch (a) {
            .extension => |e| e.class.eql(e.props, b.extension.props),
            inline else => |props, tag| deepEql(props, @field(b, @tagName(tag))),
        };
    }

    /// A copy whose strings are owned by `gpa`; free it with `free`.
    pub fn clone(self: Spec, gpa: Allocator) Allocator.Error!Spec {
        return switch (self) {
            .extension => |e| .{ .extension = .{ .class = e.class, .props = try e.class.clone(e.props, gpa) } },
            inline else => |props, tag| @unionInit(Spec, @tagName(tag), try deepClone(props, gpa)),
        };
    }

    pub fn free(self: Spec, gpa: Allocator) void {
        switch (self) {
            .extension => |e| e.class.free(e.props, gpa),
            inline else => |props| deepFree(props, gpa),
        }
    }
};

/// The type-erased props of a catalogue widget.
pub const ExtensionClass = struct {
    name: []const u8,
    placement: Spec.Placement = .view,
    eql: *const fn (a: *const anyopaque, b: *const anyopaque) bool,
    clone: *const fn (props: *const anyopaque, gpa: Allocator) Allocator.Error!*const anyopaque,
    free: *const fn (props: *const anyopaque, gpa: Allocator) void,

    /// The class of catalogue props `P`, a struct of plain values, strings
    /// and slices of them.
    pub fn of(comptime P: type, comptime name: []const u8, comptime placement: Spec.Placement) ExtensionClass {
        const ops = struct {
            fn eql(a: *const anyopaque, b: *const anyopaque) bool {
                return deepEql(cast(a).*, cast(b).*);
            }
            fn clone(erased: *const anyopaque, gpa: Allocator) Allocator.Error!*const anyopaque {
                const copy = try gpa.create(P);
                errdefer gpa.destroy(copy);
                copy.* = try deepClone(cast(erased).*, gpa);
                return copy;
            }
            fn free(erased: *const anyopaque, gpa: Allocator) void {
                deepFree(cast(erased).*, gpa);
                gpa.destroy(cast(erased));
            }
            fn cast(p: *const anyopaque) *const P {
                return @ptrCast(@alignCast(p));
            }
        };
        return .{ .name = name, .placement = placement, .eql = ops.eql, .clone = ops.clone, .free = ops.free };
    }

    /// The props of `extension`, as the `P` its class was made for.
    pub fn propsOf(comptime P: type, extension: Spec.Extension) *const P {
        return @ptrCast(@alignCast(extension.props));
    }
};

/// A native element's value, which the user changes and the model controls:
/// written into the control only when it differs from what the control last
/// reported, and never while the user is composing text (see
/// `Reconciler`).
pub const Value = union(enum) {
    none,
    toggle: bool,
    number: f64,
    text: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a, b);
    }

    pub fn clone(self: Value, gpa: Allocator) Allocator.Error!Value {
        return deepClone(self, gpa);
    }

    pub fn free(self: Value, gpa: Allocator) void {
        deepFree(self, gpa);
    }
};

/// What a backend reports about a native element, from the user.
pub const Event = union(enum) {
    /// A button pressed, or a menu item chosen.
    activate,
    /// A checkbox or switch turned on or off.
    toggle: bool,
    /// A slider moved.
    number: f64,
    /// A text field's text after an edit. Not sent while composing; the
    /// commit that ends a composition sends it. Borrowed for the call.
    text: []const u8,
    /// Return in a text field.
    submit,
    /// The element gained or lost keyboard focus.
    focus: bool,
    /// A composition (IME pre-edit) ended, so held-back writes can apply.
    composition_end,
    /// An alert was answered with the button at this index.
    response: usize,
    /// A container scrolled: where the top left of what it shows is in
    /// its content, from the content's top left (0 or more on each axis).
    /// The platform owns the offset; fabrum lays the content out against
    /// it, so hit-testing and drawn content agree with what is shown.
    scroll: Vec2,
};

/// The handlers a native element fires, each for one kind of `Event`.
pub const Handlers = struct {
    on_activate: ?Action = null,
    on_toggle: ?Handler(bool) = null,
    on_number: ?Handler(f64) = null,
    /// Fired with text the message borrows: `update` copies what it keeps.
    on_text: ?Handler([]const u8) = null,
    on_submit: ?Action = null,
    on_response: ?Handler(usize) = null,
};

/// One native element as a view declares it.
pub const Element = struct {
    spec: Spec,
    value: Value = .none,
    handlers: Handlers = .{},
    /// The sizing of the element's box, whose frame the native view takes.
    /// The default fits the backend's measured size.
    sizing: layout.Sizing = .{},
};

/// Where keyboard focus goes.
pub const FocusTarget = union(enum) {
    /// Nothing focused.
    none,
    /// A native element.
    native: Handle,
    /// fabrum's own drawn elements, whose focus the runtime tracks: the
    /// backend gives keys to the canvas and passes them to the runtime.
    canvas,
};

/// What the host shows, bottom to top: canvas layers interleaved with the
/// native views placed in the host, in paint order.
///
/// Drawn content goes in the lowest canvas layer that keeps it above every
/// native view and drawn command it overlaps that paints before it. Content
/// that overlaps no native view stays in the first layer, so a page of
/// native controls and drawn decoration has one canvas under the controls,
/// and a drawn dialog over a native field gets a second canvas above it.
///
/// Native containers are scenes within the scene: each has its own slots,
/// bottom to top within its content, and its own canvas layers, which draw
/// in its content's coordinates (`Layer.offset`).
pub const Scene = struct {
    /// The host's.
    slots: []const Slot = &.{},
    /// Every layer, the host's and the containers'.
    layers: []const Layer = &.{},
    /// What each native container shows, outermost first.
    containers: []const Container = &.{},

    /// The slots of one native container, whose own view is a slot of the
    /// host or of the container around it.
    pub const Container = struct {
        handle: Handle,
        /// Bottom to top, in its content.
        slots: []const Slot,
    };

    pub const Slot = union(enum) {
        /// The canvas layer at this index of `layers`.
        canvas: u32,
        native: Handle,
    };

    pub const Layer = struct {
        /// In paint order, with scissors balanced within the layer, in the
        /// layout's coordinates.
        commands: []const layout.RenderCommand,
        /// Where the layer has something drawn, from the commands' boxes,
        /// in the layout's coordinates. Pointer input there belongs to
        /// fabrum, not to the native views below.
        hit: []const Rect,
        /// Where the top left of the view the layer draws in is, in the
        /// layout's coordinates: zero in the host, the content's top left
        /// in a container. Commands draw moved by minus this, and points
        /// in the layer's view are this plus the point.
        offset: Vec2 = .zero,
        /// Whether it is the first layer of the host or of a container,
        /// which takes all the pointer input its native views leave.
        base: bool = false,

        /// Whether the layer takes pointer input at `point`, in the
        /// layout's coordinates.
        pub fn hits(self: Layer, point: Vec2) bool {
            if (self.base) return true;
            for (self.hit) |rect| if (rect.contains(point)) return true;
            return false;
        }
    };
};

/// The platform's look, for drawn widgets to match the native ones.
/// Provided by the runtime as a root value when it has a backend, so views
/// read it with `ui.use(native.Theme)`.
pub const Theme = struct {
    /// The user's accent color.
    accent: Color = .rgb(0, 122, 255),
    /// Text on the window background.
    text: Color = .rgb(0, 0, 0),
    secondary_text: Color = .rgba(0, 0, 0, 128),
    window_background: Color = .rgb(236, 236, 236),
    control_background: Color = .rgb(255, 255, 255),
    separator: Color = .rgba(0, 0, 0, 26),
    focus_ring: Color = .rgba(0, 103, 244, 64),
    /// The system font's size for controls, in points.
    font_size: f32 = 13,
    /// The height of a regular control, such as a push button.
    control_height: f32 = 22,
    /// Whether keyboard navigation reaches every control, not just text
    /// and lists (macOS's "Keyboard navigation" setting). Drawn widgets
    /// follow it to join the Tab order as native buttons do.
    full_keyboard_access: bool = false,
    dark: bool = false,

    /// The theme for a grayscale display, such as e-ink: black on white,
    /// nothing translucent, the accent black, so that every state reads
    /// at 16 or 4 gray levels.
    pub fn highContrast(self: Theme) Theme {
        var t = self;
        t.accent = .black;
        t.text = .black;
        t.secondary_text = .gray(80);
        t.window_background = .white;
        t.control_background = .white;
        t.separator = .black;
        t.focus_ring = .black;
        t.dark = false;
        return t;
    }
};

/// A platform's native widgets, menus and dialogs, behind which the runtime
/// reconciles. All calls come from the thread running frames.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = Allocator.Error || error{NativeCreateFailed};

    pub const VTable = struct {
        /// Makes the native object for `spec`, showing `value`, inside the
        /// host's top level or inside the native container `parent`. Events
        /// for it carry `id`. (Which view a native view is a subview of is
        /// decided by `present`; `parent` is for toolkits that need it
        /// sooner.)
        create: *const fn (ptr: *anyopaque, id: Id, spec: *const Spec, value: *const Value, parent: ?Handle) Error!Handle,
        /// Applies the props that differ between `old` and `new`, which are
        /// of the same kind.
        update: *const fn (ptr: *anyopaque, handle: Handle, old: *const Spec, new: *const Spec) void,
        destroy: *const fn (ptr: *anyopaque, handle: Handle) void,
        /// Moves a view, in its parent's coordinates from the top left: the
        /// host's, or a container's content's.
        setFrame: *const fn (ptr: *anyopaque, handle: Handle, frame: Rect) void,
        /// Sizes a container's content (its document), whose children fabrum
        /// laid out; it scrolls where that is larger than the view.
        setContentSize: *const fn (ptr: *anyopaque, handle: Handle, size: Vec2) void,
        /// The size the view wants, such as AppKit's `fittingSize`.
        measure: *const fn (ptr: *anyopaque, handle: Handle, constraints: layout.Constraints) Vec2,
        /// Writes a controlled value. Never reported back as an `Event`.
        setValue: *const fn (ptr: *anyopaque, handle: Handle, value: *const Value) void,
        /// Whether the user is composing text in it (IME marked text).
        composing: *const fn (ptr: *anyopaque, handle: Handle) bool,
        /// Whether the platform lets the view take keyboard focus now, by
        /// its own convention (AppKit's `canBecomeKeyView`).
        canFocus: *const fn (ptr: *anyopaque, handle: Handle) bool,
        focus: *const fn (ptr: *anyopaque, target: FocusTarget) void,
        /// Shows the frame's canvas layers and stacks them with the views.
        /// The scene is valid until the next frame starts.
        present: *const fn (ptr: *anyopaque, scene: *const Scene) void,
        theme: *const fn (ptr: *anyopaque) Theme,
    };

    pub fn create(self: Backend, id: Id, spec: *const Spec, value: *const Value, parent: ?Handle) Error!Handle {
        return self.vtable.create(self.ptr, id, spec, value, parent);
    }
    pub fn update(self: Backend, handle: Handle, old: *const Spec, new: *const Spec) void {
        self.vtable.update(self.ptr, handle, old, new);
    }
    pub fn destroy(self: Backend, handle: Handle) void {
        self.vtable.destroy(self.ptr, handle);
    }
    pub fn setFrame(self: Backend, handle: Handle, frame: Rect) void {
        self.vtable.setFrame(self.ptr, handle, frame);
    }
    pub fn setContentSize(self: Backend, handle: Handle, size: Vec2) void {
        self.vtable.setContentSize(self.ptr, handle, size);
    }
    pub fn measure(self: Backend, handle: Handle, constraints: layout.Constraints) Vec2 {
        return self.vtable.measure(self.ptr, handle, constraints);
    }
    pub fn setValue(self: Backend, handle: Handle, value: *const Value) void {
        self.vtable.setValue(self.ptr, handle, value);
    }
    pub fn composing(self: Backend, handle: Handle) bool {
        return self.vtable.composing(self.ptr, handle);
    }
    pub fn canFocus(self: Backend, handle: Handle) bool {
        return self.vtable.canFocus(self.ptr, handle);
    }
    pub fn focus(self: Backend, target: FocusTarget) void {
        self.vtable.focus(self.ptr, target);
    }
    pub fn present(self: Backend, scene: *const Scene) void {
        self.vtable.present(self.ptr, scene);
    }
    pub fn theme(self: Backend) Theme {
        return self.vtable.theme(self.ptr);
    }
};

// Deep equality, copies and frees of plain props: numbers, bools, enums,
// optionals, strings and slices of strings, structs and unions of them.

fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names) |name| {
                if (!deepEql(@field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| return deepEql(payload, @field(b, @tagName(tag))),
            }
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        .pointer => |info| {
            comptime std.debug.assert(info.size == .slice);
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

fn deepClone(value: anytype, gpa: Allocator) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var copy: T = value;
            inline for (info.field_names, 0..) |name, i| {
                errdefer inline for (info.field_names[0..i]) |done| deepFree(@field(copy, done), gpa);
                @field(copy, name) = try deepClone(@field(value, name), gpa);
            }
            return copy;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try deepClone(payload, gpa)),
        },
        .optional => return if (value) |v| try deepClone(v, gpa) else null,
        .pointer => |info| {
            comptime std.debug.assert(info.size == .slice);
            const copy = try gpa.alloc(info.child, value.len);
            var done: usize = 0;
            errdefer {
                for (copy[0..done]) |item| deepFree(item, gpa);
                gpa.free(copy);
            }
            for (copy, value) |*to, from| {
                to.* = try deepClone(from, gpa);
                done += 1;
            }
            return copy;
        },
        else => return value,
    }
}

fn deepFree(value: anytype, gpa: Allocator) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |name| deepFree(@field(value, name), gpa),
        .@"union" => switch (value) {
            inline else => |payload| deepFree(payload, gpa),
        },
        .optional => if (value) |v| deepFree(v, gpa),
        .pointer => {
            for (value) |item| deepFree(item, gpa);
            gpa.free(value);
        },
        else => {},
    }
}

test "specs compare, copy and free their strings deeply" {
    const gpa = std.testing.allocator;
    var title: [5]u8 = "Hello".*;
    const spec: Spec = .{ .alert = .{ .title = &title, .buttons = &.{ "OK", "Cancel" } } };
    const copy = try spec.clone(gpa);
    defer copy.free(gpa);
    try std.testing.expect(spec.eql(copy));
    title[0] = 'J';
    try std.testing.expect(!spec.eql(copy));
    try std.testing.expect(!spec.sameKind(.{ .button = .{ .title = "OK" } }));
    try std.testing.expectEqual(Spec.Placement.elsewhere, spec.placement());
}

test "values compare by content" {
    const gpa = std.testing.allocator;
    const v: Value = .{ .text = "abc" };
    const copy = try v.clone(gpa);
    defer copy.free(gpa);
    try std.testing.expect(v.eql(copy));
    try std.testing.expect(!v.eql(.{ .text = "abd" }));
    try std.testing.expect(!v.eql(.none));
}
