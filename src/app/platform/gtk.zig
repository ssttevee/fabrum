//! The GTK 4 platform: `native` on Linux, and `gtk` wherever GTK is (this
//! spike ran on macOS with Homebrew's GTK). A `GtkWindow` whose content is
//! fabrum's base canvas (a `GtkDrawingArea` drawn with `fabrum.render.Cairo`)
//! under a `GtkFixed` host that holds GTK's own widgets and the canvas
//! layers above them, placed at the frames fabrum lays out; see
//! `app.native.Scene`. The menu bar, dialogs and popovers are GTK's too.
//!
//! `App(Root)` runs a root component in a window, as `appkit.App` does:
//! it owns the runtime, the canvas's renderer and the `Backend`, and turns
//! what GTK reports into frames, pointer input, focus moves and native
//! events. `AppWith(Root, Renderer)` takes another renderer for `.cairo`
//! surfaces.
//!
//! The C half is `gtk/shell.c`, a port of `appkit/shell.m` behind the
//! same narrow ABI. fabrum's build adds it, and links GTK 4 through
//! pkg-config, for `-Dplatform=gtk` and for `native` on Linux.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Color = fabrum.Color;

const app = @import("../../app.zig");
const native = app.native;

/// A Cairo drawing context (`cairo_t`).
pub const CairoContext = opaque {};

pub const Options = struct {
    title: [:0]const u8,
    width: f64 = 800,
    height: f64 = 600,
    min_width: f64 = 320,
    min_height: f64 = 240,
    /// Prefer the toolkit's dark theme.
    dark: bool = false,
};

/// Kinds of GTK object, as in shell.c.
const Kind = enum(c_int) { button, checkbox, @"switch", slider, text_field, progress, menu_item, alert, scroll_view, text_area, search_field, secure_field, spinner, dropdown, radio_group, stepper, label };

/// Kinds of event, as in shell.c.
const EventKind = enum(c_int) { activate, toggle, number, text, submit, focus, composition_end, response, select };

const CHost = extern struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, width: f64, height: f64) callconv(.c) void,
    draw_layer: *const fn (ctx: *anyopaque, layer: c_uint, cr: *CairoContext, width: f64, height: f64) callconv(.c) void,
    hit_layer: *const fn (ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool,
    mouse: *const fn (ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void,
    scroll: *const fn (ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void,
    tab: *const fn (ctx: *anyopaque, forward: c_int) callconv(.c) void,
    activate: *const fn (ctx: *anyopaque) callconv(.c) void,
    enter: *const fn (ctx: *anyopaque) callconv(.c) bool,
    event: *const fn (ctx: *anyopaque, id: u64, kind: EventKind, number: f64, text: ?[*]const u8, len: usize) callconv(.c) void,
    should_close: *const fn (ctx: *anyopaque, quit: c_int) callconv(.c) bool,
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
};

const TextCallback = *const fn (ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void;
const IndexCallback = *const fn (ctx: ?*anyopaque, index: c_long) callconv(.c) void;

const COptions = extern struct {
    title: [*:0]const u8,
    width: f64,
    height: f64,
    min_width: f64,
    min_height: f64,
    dark: c_int,
};

const CSlot = extern struct {
    canvas: c_int,
    widget: ?*anyopaque,
};

const CTheme = extern struct {
    accent: [4]f64,
    text: [4]f64,
    secondary_text: [4]f64,
    window_background: [4]f64,
    control_background: [4]f64,
    separator: [4]f64,
    focus_ring: [4]f64,
    font_size: f64,
    control_height: f64,
    full_keyboard_access: c_int,
    dark: c_int,
};

const CMenuItem = extern struct {
    title: [*]const u8,
    title_len: usize,
    kind: c_int,
    id: c_long,
    enabled: bool,
    depth: c_uint,
};

extern fn fabrum_gtk_run(options: COptions, host: CHost) callconv(.c) noreturn;
extern fn fabrum_gtk_request_frame() callconv(.c) void;
extern fn fabrum_gtk_run_on_main(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_gtk_quit() callconv(.c) void;
extern fn fabrum_gtk_quit_now() callconv(.c) void;
extern fn fabrum_gtk_close_now() callconv(.c) void;
extern fn fabrum_gtk_message(title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, kind: c_int, timeout_ms: c_uint) callconv(.c) void;
extern fn fabrum_gtk_confirm(title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, buttons: [*]const [*]const u8, lengths: [*]const usize, count: usize, default_index: usize, kind: c_int, done: IndexCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_gtk_popup_menu(items: [*]const CMenuItem, count: usize, x: f64, y: f64, done: IndexCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_gtk_open_file(message: [*]const u8, message_len: usize, extensions: [*]const [*]const u8, lengths: [*]const usize, count: usize, directory: bool, done: TextCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_gtk_write_clipboard(bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_read_clipboard(done: TextCallback, ctx: ?*anyopaque) callconv(.c) void;

extern fn fabrum_gtk_create(kind: Kind, id: u64) callconv(.c) ?*anyopaque;
extern fn fabrum_gtk_destroy(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_gtk_set_title(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_set_message(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_add_button(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_show_alert(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_gtk_set_enabled(handle: *anyopaque, enabled: bool) callconv(.c) void;
extern fn fabrum_gtk_set_default(handle: *anyopaque, is_default: bool) callconv(.c) void;
extern fn fabrum_gtk_set_placeholder(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_set_range(handle: *anyopaque, min: f64, max: f64) callconv(.c) void;
extern fn fabrum_gtk_set_increment(handle: *anyopaque, step: f64) callconv(.c) void;
extern fn fabrum_gtk_set_bool(handle: *anyopaque, on: bool) callconv(.c) void;
extern fn fabrum_gtk_set_number(handle: *anyopaque, value: f64) callconv(.c) void;
extern fn fabrum_gtk_set_text(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_set_progress(handle: *anyopaque, value: f64, indeterminate: bool) callconv(.c) void;
extern fn fabrum_gtk_set_spinner_size(handle: *anyopaque, small: bool) callconv(.c) void;
extern fn fabrum_gtk_set_items(handle: *anyopaque, titles: [*]const [*]const u8, lengths: [*]const usize, count: usize) callconv(.c) void;
extern fn fabrum_gtk_set_selection(handle: *anyopaque, index: c_long) callconv(.c) void;
extern fn fabrum_gtk_set_horizontal(handle: *anyopaque, horizontal: bool) callconv(.c) void;
extern fn fabrum_gtk_set_label_style(handle: *anyopaque, wrap: bool, selectable: bool, font_size: f64, secondary: bool) callconv(.c) void;
extern fn fabrum_gtk_place_menu_item(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_set_key_equivalent(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_set_frame(handle: *anyopaque, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_gtk_set_scroll_axes(handle: *anyopaque, horizontal: bool, vertical: bool) callconv(.c) void;
extern fn fabrum_gtk_set_content_size(handle: *anyopaque, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_gtk_fitting_size(handle: *anyopaque, max_width: f64, w: *f64, h: *f64) callconv(.c) void;
extern fn fabrum_gtk_is_composing(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_gtk_can_focus(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_gtk_focus(handle: ?*anyopaque, canvas: c_int) callconv(.c) void;
extern fn fabrum_gtk_arrange(container: ?*anyopaque, slots: [*]const CSlot, count: usize) callconv(.c) void;
extern fn fabrum_gtk_damage_layer(layer: c_uint, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_gtk_theme(out: *CTheme) callconv(.c) void;
extern fn fabrum_gtk_font_family(out: [*]u8, cap: usize) callconv(.c) usize;

extern fn fabrum_gtk_snapshot(path: [*:0]const u8, scale: f64) callconv(.c) bool;
extern fn fabrum_gtk_perform_click(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_gtk_type(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_gtk_text(handle: *anyopaque, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_gtk_newline(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_gtk_slide(handle: *anyopaque, value: f64) callconv(.c) void;
extern fn fabrum_gtk_select(handle: *anyopaque, index: c_long) callconv(.c) void;
extern fn fabrum_gtk_step(handle: *anyopaque, steps: c_long) callconv(.c) void;
extern fn fabrum_gtk_scroll_to(handle: *anyopaque, x: f64, y: f64) callconv(.c) void;
extern fn fabrum_gtk_tab(forward: c_int) callconv(.c) void;
extern fn fabrum_gtk_answer_alert(index: c_int) callconv(.c) void;
extern fn fabrum_gtk_answer_popup(id: c_long) callconv(.c) bool;
extern fn fabrum_gtk_answer_open_panel(path: ?[*:0]const u8) callconv(.c) bool;
extern fn fabrum_gtk_choose_menu(menu: [*:0]const u8, title: [*:0]const u8) callconv(.c) bool;
extern fn fabrum_gtk_resize(width: f64, height: f64) callconv(.c) void;
extern fn fabrum_gtk_describe_focus(out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_gtk_describe_hit(x: f64, y: f64, out: [*]u8, cap: usize) callconv(.c) usize;

fn ptrOf(handle: native.Handle) *anyopaque {
    return @ptrFromInt(@backingInt(handle));
}

/// The GTK implementation of `native.Backend`. Main thread only.
pub const Backend = struct {
    gpa: Allocator,
    slots: std.ArrayList(CSlot) = .empty,
    /// Which canvas layers changed, so only those are redrawn.
    canvas_damage: native.CanvasDamage = .{},

    pub fn deinit(self: *Backend) void {
        self.slots.deinit(self.gpa);
        self.canvas_damage.deinit(self.gpa);
    }

    pub fn backend(self: *Backend) native.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: native.Backend.VTable = .{
        .create = create,
        .update = update,
        .destroy = destroy,
        .setFrame = setFrame,
        .setContentSize = setContentSize,
        .measure = measure,
        .setValue = setValue,
        .composing = composing,
        .canFocus = canFocus,
        .focus = focus,
        .present = present,
        .theme = theme,
        .reparent = reparent,
    };

    fn kindOf(spec: *const native.Spec) error{NativeCreateFailed}!Kind {
        return switch (spec.*) {
            // no catalogue of GTK's own yet
            .extension => error.NativeCreateFailed,
            // the common kinds share their names with shell.c's
            inline else => |_, tag| @field(Kind, @tagName(tag)),
        };
    }

    fn create(_: *anyopaque, id: native.Id, spec: *const native.Spec, value: *const native.Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        _ = parent;
        const made = fabrum_gtk_create(try kindOf(spec), id) orelse return error.NativeCreateFailed;
        configure(made, spec, null);
        writeValue(made, value);
        if (spec.* == .alert) fabrum_gtk_show_alert(made);
        return @fromBackingInt(@intCast(@intFromPtr(made)));
    }

    fn update(_: *anyopaque, handle: native.Handle, old: *const native.Spec, new: *const native.Spec) void {
        configure(ptrOf(handle), new, old);
    }

    fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    /// Applies the props of `spec` that differ from `old`, or all of them.
    fn configure(made: *anyopaque, spec: *const native.Spec, old: ?*const native.Spec) void {
        const Set = struct {
            fn text(h: *anyopaque, comptime f: anytype, new: []const u8, was: ?[]const u8) void {
                if (was == null or !std.mem.eql(u8, was.?, new)) f(h, new.ptr, new.len);
            }
        };
        switch (spec.*) {
            .button => |b| {
                const was = if (old) |o| o.button else null;
                Set.text(made, fabrum_gtk_set_title, b.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != b.enabled) fabrum_gtk_set_enabled(made, b.enabled);
                if (was == null or was.?.role != b.role) fabrum_gtk_set_default(made, b.role == .default);
            },
            .checkbox, .@"switch" => |t| {
                const was: ?native.Spec.Toggle = if (old) |o| switch (o.*) {
                    .checkbox, .@"switch" => |w| w,
                    else => unreachable,
                } else null;
                if (spec.* == .checkbox) Set.text(made, fabrum_gtk_set_title, t.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_gtk_set_enabled(made, t.enabled);
            },
            .slider => |s| {
                fabrum_gtk_set_range(made, s.min, s.max);
                fabrum_gtk_set_enabled(made, s.enabled);
            },
            .text_field, .text_area, .search_field, .secure_field => |t| {
                const was: ?native.Spec.TextField = if (old) |o| switch (o.*) {
                    .text_field, .text_area, .search_field, .secure_field => |w| w,
                    else => unreachable,
                } else null;
                Set.text(made, fabrum_gtk_set_placeholder, t.placeholder, if (was) |w| w.placeholder else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_gtk_set_enabled(made, t.enabled);
            },
            .progress => |p| fabrum_gtk_set_progress(made, p.value orelse 0, p.value == null),
            .spinner => |sp| if (old == null or old.?.spinner.size != sp.size) fabrum_gtk_set_spinner_size(made, sp.size == .small),
            .dropdown, .radio_group => |items| {
                const was: ?native.Spec.Items = if (old) |o| switch (o.*) {
                    .dropdown, .radio_group => |w| w,
                    else => unreachable,
                } else null;
                if (spec.* == .radio_group and (was == null or was.?.horizontal != items.horizontal)) fabrum_gtk_set_horizontal(made, items.horizontal);
                if (was == null or !sameStrings(was.?.items, items.items)) {
                    var pointers: [64][*]const u8 = undefined;
                    var lengths: [64]usize = undefined;
                    const count = @min(items.items.len, pointers.len);
                    for (items.items[0..count], pointers[0..count], lengths[0..count]) |item, *p, *l| {
                        p.* = item.ptr;
                        l.* = item.len;
                    }
                    fabrum_gtk_set_items(made, &pointers, &lengths, count);
                }
                if (was == null or was.?.enabled != items.enabled) fabrum_gtk_set_enabled(made, items.enabled);
            },
            .stepper => |st| {
                fabrum_gtk_set_range(made, st.min, st.max);
                fabrum_gtk_set_increment(made, st.step);
                fabrum_gtk_set_enabled(made, st.enabled);
            },
            .label => |l| {
                const was = if (old) |o| o.label else null;
                Set.text(made, fabrum_gtk_set_title, l.text, if (was) |w| w.text else null);
                if (was == null or was.?.wrap != l.wrap or was.?.selectable != l.selectable or was.?.font_size != l.font_size or was.?.secondary != l.secondary) {
                    fabrum_gtk_set_label_style(made, l.wrap, l.selectable, l.font_size orelse 0, l.secondary);
                }
            },
            .menu_item => |m| {
                const was = if (old) |o| o.menu_item else null;
                Set.text(made, fabrum_gtk_set_title, m.title, if (was) |w| w.title else null);
                Set.text(made, fabrum_gtk_set_key_equivalent, m.key, if (was) |w| w.key else null);
                fabrum_gtk_set_enabled(made, m.enabled);
                fabrum_gtk_place_menu_item(made, m.menu.ptr, m.menu.len);
            },
            .alert => |a| if (old == null) {
                fabrum_gtk_set_title(made, a.title.ptr, a.title.len);
                fabrum_gtk_set_message(made, a.message.ptr, a.message.len);
                for (a.buttons) |button| fabrum_gtk_add_button(made, button.ptr, button.len);
            },
            .scroll_view => |v| fabrum_gtk_set_scroll_axes(made, v.horizontal, v.vertical),
            .extension => {},
        }
    }

    fn writeValue(made: *anyopaque, value: *const native.Value) void {
        switch (value.*) {
            .none => {},
            .toggle => |on| fabrum_gtk_set_bool(made, on),
            .number => |n| fabrum_gtk_set_number(made, n),
            .text => |t| fabrum_gtk_set_text(made, t.ptr, t.len),
            .selection => |i| fabrum_gtk_set_selection(made, if (i) |index| @intCast(index) else -1),
        }
    }

    fn destroy(_: *anyopaque, handle: native.Handle) void {
        fabrum_gtk_destroy(ptrOf(handle));
    }

    /// `present` puts every widget in its parent, taking it out of the
    /// old one.
    fn reparent(_: *anyopaque, handle: native.Handle, parent: ?native.Handle) void {
        _ = handle;
        _ = parent;
    }

    fn setFrame(_: *anyopaque, handle: native.Handle, frame: Rect) void {
        fabrum_gtk_set_frame(ptrOf(handle), frame.x, frame.y, frame.w, frame.h);
    }

    fn setContentSize(_: *anyopaque, handle: native.Handle, size: Vec2) void {
        fabrum_gtk_set_content_size(ptrOf(handle), size.x, size.y);
    }

    /// `gtk_widget_measure`: the natural size, a wrapping label's under
    /// the width limit.
    fn measure(_: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        var w: f64 = 0;
        var h: f64 = 0;
        fabrum_gtk_fitting_size(ptrOf(handle), if (constraints.max_width) |limit| limit else 0, &w, &h);
        return .init(@floatCast(w), @floatCast(h));
    }

    fn setValue(_: *anyopaque, handle: native.Handle, value: *const native.Value) void {
        writeValue(ptrOf(handle), value);
    }

    fn composing(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_gtk_is_composing(ptrOf(handle));
    }

    fn canFocus(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_gtk_can_focus(ptrOf(handle));
    }

    fn focus(_: *anyopaque, target: native.FocusTarget) void {
        switch (target) {
            .none => fabrum_gtk_focus(null, 0),
            .canvas => fabrum_gtk_focus(null, 1),
            .native => |handle| fabrum_gtk_focus(ptrOf(handle), 0),
        }
    }

    fn present(ptr: *anyopaque, scene: *const native.Scene) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        if (scene.slots.len == 0) {
            fabrum_gtk_arrange(null, @ptrCast(&[_]CSlot{.{ .canvas = 0, .widget = null }}), 1);
            return;
        }
        self.arrange(null, scene.slots);
        for (scene.containers) |container| self.arrange(ptrOf(container.handle), container.slots);
        for (scene.layers, 0..) |_, index| {
            const regions = self.canvas_damage.update(self.gpa, scene, index) catch {
                fabrum_gtk_damage_layer(@intCast(index), 0, 0, native.CanvasDamage.extent, native.CanvasDamage.extent);
                continue;
            };
            for (regions) |r| fabrum_gtk_damage_layer(@intCast(index), r.x, r.y, r.w, r.h);
        }
    }

    fn arrange(self: *Backend, container: ?*anyopaque, slots: []const native.Scene.Slot) void {
        self.slots.clearRetainingCapacity();
        for (slots) |slot| {
            self.slots.append(self.gpa, switch (slot) {
                .canvas => |index| .{ .canvas = @intCast(index), .widget = null },
                .native => |handle| .{ .canvas = -1, .widget = ptrOf(handle) },
            }) catch {
                std.log.err("gtk: out of memory arranging widgets", .{});
                return;
            };
        }
        fabrum_gtk_arrange(container, self.slots.items.ptr, self.slots.items.len);
    }

    fn theme(_: *anyopaque) native.Theme {
        var c: CTheme = undefined;
        fabrum_gtk_theme(&c);
        return .{
            .accent = color(c.accent),
            .text = color(c.text),
            .secondary_text = color(c.secondary_text),
            .window_background = color(c.window_background),
            .control_background = color(c.control_background),
            .separator = color(c.separator),
            .focus_ring = color(c.focus_ring),
            .font_size = @floatCast(c.font_size),
            .control_height = @floatCast(c.control_height),
            .full_keyboard_access = c.full_keyboard_access != 0,
            .dark = c.dark != 0,
        };
    }

    fn color(c: [4]f64) Color {
        const byte = struct {
            fn of(v: f64) u8 {
                return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
            }
        }.of;
        return .rgba(byte(c[0]), byte(c[1]), byte(c[2]), byte(c[3]));
    }
};

/// The `app.Platform` of this shell: frames are requested on the main
/// loop, from any thread.
pub const platform: app.Platform = .{ .ptr = undefined, .vtable = &.{ .requestFrame = requestFrame } };

fn requestFrame(_: *anyopaque) void {
    fabrum_gtk_request_frame();
}

/// The canvas's renderer: Cairo, drawing into the canvas layers'
/// `cairo_t`s with Pango's text.
pub const Canvas = fabrum.render.Cairo;

/// Runs `Root` in a window, laid out by fabrum, with drawn content in
/// canvas layers drawn by Cairo (`Canvas`). Must not move after `init`.
pub fn App(comptime RootComponent: type) type {
    return AppWith(RootComponent, Canvas);
}

/// `App`, with canvas layers drawn by `Renderer`: a `fabrum.layout`
/// renderer that draws into `.cairo` surfaces.
pub fn AppWith(comptime RootComponent: type, comptime Renderer: type) type {
    comptime layout.checkRenderer(Renderer);
    if (comptime !layout.accepts(Renderer, .cairo)) @compileError("fabrum: GTK's canvas layers need a renderer that draws into .cairo surfaces, which " ++ @typeName(Renderer) ++ " doesn't");
    return struct {
        runtime: Runtime,
        renderer: Renderer,
        backend: Backend,
        props: Root.Props,
        options: Options,
        io: std.Io,
        viewport: Vec2 = .zero,
        pointer: Vec2 = .init(-1, -1),
        on_terminate: ?Callback = null,

        const Self = @This();

        pub const Root = RootComponent;
        pub const Runtime = app.Runtime(.{ .Text = Renderer.Text });

        pub const InitOptions = struct {
            /// Debug budget per update/view; 0 or null disables the watchdog.
            watchdog_ms: ?u32 = 16,
            provide: []const app.RootValue = &.{},
            context: layout.Context.Config = .{},
            /// Called once before the process exits, once the app has
            /// agreed to quit.
            /// Runtime tasks have been canceled and joined before this runs,
            /// so borrowed domain services can now shut down.
            on_terminate: ?Callback = null,
        };

        pub const Callback = struct {
            ctx: ?*anyopaque = null,
            call: *const fn (ctx: ?*anyopaque) void,
        };

        pub fn init(self: *Self, gpa: Allocator, io: std.Io, props: Root.Props, window: Options, options: InitOptions) !void {
            self.* = .{
                .runtime = undefined,
                .renderer = try Renderer.init(gpa),
                .backend = .{ .gpa = gpa },
                .props = props,
                .options = window,
                .io = io,
                .on_terminate = options.on_terminate,
            };
            errdefer self.renderer.deinit();
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .platform = platform,
                .provide = options.provide,
                .context = options.context,
                .watchdog_ms = options.watchdog_ms,
                .native = self.backend.backend(),
                .services = .{ .ptr = self, .vtable = &services_vtable },
                .keymap = .linux,
            });
        }

        /// Opens the window and runs until the app quits.
        pub fn run(self: *Self) noreturn {
            fabrum_gtk_run(.{
                .title = self.options.title,
                .width = self.options.width,
                .height = self.options.height,
                .min_width = self.options.min_width,
                .min_height = self.options.min_height,
                .dark = @intFromBool(self.options.dark),
            }, .{
                .ctx = self,
                .frame = frame,
                .draw_layer = drawLayer,
                .hit_layer = hitLayer,
                .mouse = mouseIn,
                .scroll = scroll,
                .tab = tab,
                .activate = activate,
                .enter = enter,
                .event = event,
                .should_close = shouldClose,
                .will_terminate = willTerminate,
            });
        }

        /// The GTK object made for the native element `id`, for automation.
        pub fn handleOf(self: *Self, id: native.Id) ?native.Handle {
            const record = self.runtime.reconciler().records.getPtr(id) orelse return null;
            return record.handle;
        }

        fn cast(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn frame(ctx: *anyopaque, width: f64, height: f64) callconv(.c) void {
            const self = cast(ctx);
            // the canvas's text in the toolkit's font
            var family: [128]u8 = undefined;
            const n = fabrum_gtk_font_family(&family, family.len);
            if (n > 0) Renderer.setDefaultFamily(family[0..n]);
            self.viewport = .init(@floatCast(width), @floatCast(height));
            _ = self.runtime.frame(Root, self.props, self.viewport, .now(self.io, .awake)) catch |err| {
                std.log.err("frame failed: {t}", .{err});
                return;
            };
            self.afterInput();
        }

        fn drawLayer(ctx: *anyopaque, layer: c_uint, cr: *CairoContext, width: f64, height: f64) callconv(.c) void {
            _ = width;
            _ = height;
            const self = cast(ctx);
            const scene = self.runtime.scene();
            if (layer >= scene.layers.len) return;
            const l = scene.layers[layer];
            // a layer in a document draws where the document starts
            var moved: std.ArrayList(layout.RenderCommand) = .empty;
            defer moved.deinit(self.runtime.core.gpa);
            moved.ensureTotalCapacity(self.runtime.core.gpa, l.commands.len) catch return;
            for (l.commands) |command| {
                var m = command;
                m.bbox.x -= l.offset.x;
                m.bbox.y -= l.offset.y;
                moved.appendAssumeCapacity(m);
            }
            layout.draw(&self.renderer, moved.items, .cairo, cr, null) catch |err| std.log.err("render failed: {t}", .{err});
        }

        fn hitLayer(ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool {
            const scene = cast(ctx).runtime.scene();
            if (layer >= scene.layers.len) return layer == 0;
            const l = scene.layers[layer];
            return l.hits(l.offset.add(.init(@floatCast(x), @floatCast(y))));
        }

        fn mouseIn(ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
            const scene = cast(ctx).runtime.scene();
            const offset: Vec2 = if (layer >= 0 and layer < scene.layers.len) scene.layers[@intCast(layer)].offset else .zero;
            mouse(ctx, x + offset.x, y + offset.y, buttons, scroll_x, scroll_y);
        }

        fn scroll(ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.nativeEvent(id, .{ .scroll = .init(@floatCast(x), @floatCast(y)) }) catch |err| std.log.err("native event failed: {t}", .{err});
            self.afterInput();
        }

        /// Pointer input in the layout's coordinates; also for scripts.
        pub fn mouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
            const self = cast(ctx);
            var pressed: app.MouseEvent.Buttons = .empty;
            if (buttons & 1 != 0) pressed.set(app.MouseEvent.primary);
            self.pointer = .init(@floatCast(x), @floatCast(y));
            _ = self.runtime.mouse(.{
                .position = self.pointer,
                .pressed = pressed,
                .scroll_delta = .init(@floatCast(scroll_x), @floatCast(scroll_y)),
            }) catch |err| std.log.err("input failed: {t}", .{err});
            self.afterInput();
        }

        fn tab(ctx: *anyopaque, forward: c_int) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.focusMove(if (forward != 0) .next else .previous);
            self.afterInput();
        }

        /// Return after the toolkit's focused native control has declined it.
        fn enter(ctx: *anyopaque) callconv(.c) bool {
            const self = cast(ctx);
            const taken = self.runtime.key(.{ .key = .enter, .phase = .press }) catch |err| {
                std.log.err("input failed: {t}", .{err});
                return false;
            };
            _ = self.runtime.key(.{ .key = .enter, .phase = .release }) catch |err| std.log.err("input failed: {t}", .{err});
            self.afterInput();
            return taken;
        }

        pub fn activate(ctx: *anyopaque) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.activateFocused() catch |err| std.log.err("input failed: {t}", .{err});
            self.afterInput();
        }

        fn event(ctx: *anyopaque, id: u64, kind: EventKind, number: f64, text: ?[*]const u8, len: usize) callconv(.c) void {
            const self = cast(ctx);
            const e: native.Event = switch (kind) {
                .activate => .activate,
                .toggle => .{ .toggle = number != 0 },
                .number => .{ .number = number },
                .text => .{ .text = if (text) |t| t[0..len] else "" },
                .submit => .submit,
                .focus => .{ .focus = number != 0 },
                .composition_end => .composition_end,
                .response => .{ .response = @intFromFloat(@max(number, 0)) },
                .select => .{ .select = @intFromFloat(@max(number, 0)) },
            };
            self.runtime.nativeEvent(id, e) catch |err| std.log.err("native event failed: {t}", .{err});
            self.afterInput();
        }

        fn afterInput(self: *Self) void {
            if (self.runtime.needsFrame()) fabrum_gtk_request_frame();
        }

        fn willTerminate(ctx: *anyopaque) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.cancelTasks();
            if (self.on_terminate) |callback| callback.call(callback.ctx);
        }

        fn shouldClose(ctx: *anyopaque, quit: c_int) callconv(.c) bool {
            const self = cast(ctx);
            const may = self.runtime.shouldClose(if (quit != 0) .quit else .window) catch |err| blk: {
                std.log.err("close request failed: {t}", .{err});
                break :blk true;
            };
            self.afterInput();
            return may;
        }

        // The services: `GtkAlertDialog`, `GtkPopoverMenu`, `GtkFileDialog`
        // (files and directories), `GdkClipboard` (read asynchronously),
        // `g_application_quit`. Closing the window quits, as it is the only
        // one.

        const services_vtable: app.platform.Services.VTable = .{
            .message = showMessage,
            .confirm = confirm,
            .menu = popupMenu,
            .openFile = openFile,
            .openDirectory = openDirectory,
            .writeClipboard = writeClipboard,
            .readClipboard = readClipboard,
            .quit = quitNow,
            .close = closeNow,
        };

        fn dialogKind(kind: app.platform.DialogKind) c_int {
            return switch (kind) {
                .info => 0,
                .question => 1,
                .warning => 2,
                .@"error" => 3,
            };
        }

        fn showMessage(_: *anyopaque, request: *const app.platform.MessageRequest) app.platform.Services.Error!void {
            fabrum_gtk_message(request.title.ptr, request.title.len, request.text.ptr, request.text.len, dialogKind(request.kind), request.timeout_ms);
        }

        fn confirm(ptr: *anyopaque, request: *const app.platform.ConfirmRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
            const self = cast(ptr);
            if (request.buttons.len == 0 or request.buttons.len > 3) return error.ServiceFailed;
            const pending = try PendingIndex.create(self.runtime.core.gpa, reply);
            errdefer pending.destroy();
            var pointers: [3][*]const u8 = undefined;
            var lengths: [3]usize = undefined;
            for (request.buttons, 0..) |button, i| {
                pointers[i] = button.ptr;
                lengths[i] = button.len;
            }
            fabrum_gtk_confirm(request.title.ptr, request.title.len, request.text.ptr, request.text.len, &pointers, &lengths, request.buttons.len, request.default, dialogKind(request.kind), PendingIndex.answer, pending);
        }

        fn popupMenu(ptr: *anyopaque, request: *const app.platform.MenuRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            var items: std.ArrayList(CMenuItem) = .empty;
            defer items.deinit(gpa);
            try flattenMenu(gpa, &items, request.items, 0);
            const pending = try PendingIndex.create(gpa, reply);
            errdefer pending.destroy();
            fabrum_gtk_popup_menu(items.items.ptr, items.items.len, request.at.x, request.at.y, PendingIndex.answer, pending);
        }

        fn flattenMenu(gpa: Allocator, out: *std.ArrayList(CMenuItem), items: []const app.platform.MenuItem, depth: c_uint) Allocator.Error!void {
            for (items) |item| {
                try out.append(gpa, .{
                    .title = item.title.ptr,
                    .title_len = item.title.len,
                    .kind = switch (item.kind) {
                        .item => 0,
                        .header => 1,
                        .separator => 2,
                        .submenu => 3,
                    },
                    .id = @intCast(item.id),
                    .enabled = item.enabled,
                    .depth = depth,
                });
                if (item.kind == .submenu) try flattenMenu(gpa, out, item.submenu, depth + 1);
            }
        }

        fn openFile(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
            try choose(ptr, request, reply, false);
        }

        fn openDirectory(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
            try choose(ptr, request, reply, true);
        }

        fn choose(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply, directory: bool) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            const pending = try gpa.create(PendingReply);
            pending.* = .{ .gpa = gpa, .reply = reply };
            errdefer gpa.destroy(pending);
            var pointers: [32][*]const u8 = undefined;
            var lengths: [32]usize = undefined;
            const count = @min(request.extensions.len, pointers.len);
            for (request.extensions[0..count], pointers[0..count], lengths[0..count]) |extension, *p, *l| {
                p.* = extension.ptr;
                l.* = extension.len;
            }
            fabrum_gtk_open_file(request.message.ptr, request.message.len, &pointers, &lengths, count, directory, PendingReply.answer, pending);
        }

        fn writeClipboard(_: *anyopaque, text: []const u8) app.platform.Services.Error!void {
            fabrum_gtk_write_clipboard(text.ptr, text.len);
        }

        /// GTK reads the clipboard asynchronously: the reply comes later.
        fn readClipboard(ptr: *anyopaque, reply: app.platform.Reply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            const pending = try gpa.create(PendingReply);
            pending.* = .{ .gpa = gpa, .reply = reply };
            fabrum_gtk_read_clipboard(PendingReply.answer, pending);
        }

        fn quitNow(_: *anyopaque) void {
            fabrum_gtk_quit_now();
        }

        fn closeNow(_: *anyopaque) void {
            fabrum_gtk_close_now();
        }

        const PendingReply = struct {
            gpa: Allocator,
            reply: app.platform.Reply,

            fn answer(ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
                const self: *PendingReply = @ptrCast(@alignCast(ctx.?));
                defer self.gpa.destroy(self);
                self.reply.send(if (text) |t| t[0..len] else null) catch |err| std.log.err("reply lost: {t}", .{err});
            }
        };

        const PendingIndex = struct {
            gpa: Allocator,
            reply: app.platform.IndexReply,

            fn create(gpa: Allocator, reply: app.platform.IndexReply) Allocator.Error!*PendingIndex {
                const self = try gpa.create(PendingIndex);
                self.* = .{ .gpa = gpa, .reply = reply };
                return self;
            }

            fn destroy(self: *PendingIndex) void {
                self.gpa.destroy(self);
            }

            fn answer(ctx: ?*anyopaque, index: c_long) callconv(.c) void {
                const self: *PendingIndex = @ptrCast(@alignCast(ctx.?));
                defer self.destroy();
                self.reply.send(if (index < 0) null else @intCast(index)) catch |err| std.log.err("dialog answer lost: {t}", .{err});
            }
        };
    };
}

/// GTK's widget catalogue: the common set. Nothing of GTK's own yet.
pub const widgets = struct {
    pub const button = app.widgets.button;
    pub const checkbox = app.widgets.checkbox;
    pub const toggle = app.widgets.toggle;
    pub const slider = app.widgets.slider;
    pub const textField = app.widgets.textField;
    pub const textArea = app.widgets.textArea;
    pub const searchField = app.widgets.searchField;
    pub const secureField = app.widgets.secureField;
    pub const dropdown = app.widgets.dropdown;
    pub const radioGroup = app.widgets.radioGroup;
    pub const stepper = app.widgets.stepper;
    pub const label = app.widgets.label;
    pub const progressBar = app.widgets.progressBar;
    pub const spinner = app.widgets.spinner;
    pub const scrollView = app.widgets.scrollView;
};

/// What debug scripts do to a running app, in process. Main thread only,
/// except `runOnMain`.
pub const automation = struct {
    /// Invokes `callback(ctx)` once through the default GLib main context,
    /// from any thread. GLib may invoke it immediately when the caller owns
    /// or can acquire the context; otherwise it queues it.
    pub fn runOnMain(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
        fabrum_gtk_run_on_main(callback, ctx);
    }

    /// Closes the window as its close button does, asking the app first.
    pub fn quit() void {
        fabrum_gtk_quit();
    }

    /// Draws the window's content into a PNG at `path`, at `scale` pixels
    /// per point, or the screen's if null, through the widget's paintable.
    pub fn snapshot(path: [:0]const u8, scale: ?f64) error{SnapshotFailed}!void {
        if (!fabrum_gtk_snapshot(path, scale orelse 0)) return error.SnapshotFailed;
    }

    pub fn click(handle: native.Handle) void {
        fabrum_gtk_perform_click(ptrOf(handle));
    }

    /// Types `text` at a field's caret, as keyboard text input does.
    pub fn typeText(handle: native.Handle, text: []const u8) void {
        fabrum_gtk_type(ptrOf(handle), text.ptr, text.len);
    }

    pub fn fieldText(handle: native.Handle, buffer: []u8) []const u8 {
        return buffer[0..fabrum_gtk_text(ptrOf(handle), buffer.ptr, buffer.len)];
    }

    pub fn newline(handle: native.Handle) void {
        fabrum_gtk_newline(ptrOf(handle));
    }

    pub fn slide(handle: native.Handle, value: f64) void {
        fabrum_gtk_slide(ptrOf(handle), value);
    }

    pub fn select(handle: native.Handle, index: usize) void {
        fabrum_gtk_select(ptrOf(handle), @intCast(index));
    }

    pub fn step(handle: native.Handle, steps: i32) void {
        fabrum_gtk_step(ptrOf(handle), steps);
    }

    pub fn scrollTo(handle: native.Handle, offset: Vec2) void {
        fabrum_gtk_scroll_to(ptrOf(handle), offset.x, offset.y);
    }

    pub fn tab(forward: bool) void {
        fabrum_gtk_tab(@intFromBool(forward));
    }

    /// Answers the alert being shown (a declared one, or `Update.confirm`)
    /// with the button at `index`.
    pub fn answerAlert(index: usize) void {
        fabrum_gtk_answer_alert(@intCast(index));
    }

    pub fn answerPopup(id: ?usize) error{NoPopupMenu}!void {
        if (!fabrum_gtk_answer_popup(if (id) |i| @intCast(i) else -1)) return error.NoPopupMenu;
    }

    pub fn answerFileChooser(path: ?[:0]const u8) error{NoFileChooser}!void {
        if (!fabrum_gtk_answer_open_panel(if (path) |p| p.ptr else null)) return error.NoFileChooser;
    }

    pub fn chooseMenu(menu: [:0]const u8, title: [:0]const u8) error{NoSuchMenuItem}!void {
        if (!fabrum_gtk_choose_menu(menu, title)) return error.NoSuchMenuItem;
    }

    pub fn resize(width: f64, height: f64) void {
        fabrum_gtk_resize(width, height);
    }

    pub fn describeFocus(buffer: []u8) []const u8 {
        return buffer[0..fabrum_gtk_describe_focus(buffer.ptr, buffer.len)];
    }

    pub fn describeHit(x: f64, y: f64, buffer: []u8) []const u8 {
        return buffer[0..fabrum_gtk_describe_hit(x, y, buffer.ptr, buffer.len)];
    }
};

test "apps draw their canvas with Cairo unless given another renderer" {
    const Root = struct {
        pub const Props = struct {};
        pub fn view(ui: *app.Ui, props: Props) !void {
            _ = props;
            try ui.text("hi", .{});
        }
    };
    try std.testing.expect(App(Root).Runtime.Text == fabrum.render.Cairo.Text);
}

test "app initialization forwards the debug watchdog budget" {
    const Root = struct {
        pub const Props = struct {};
        pub fn view(_: *app.Ui, _: Props) !void {}
    };
    const Gui = App(Root);
    try std.testing.expectEqual(@as(?u32, 16), (Gui.InitOptions{}).watchdog_ms);
    for ([_]?u32{ 37, 0, null }) |budget| {
        var gui: Gui = undefined;
        try gui.init(std.testing.allocator, std.testing.io, .{}, .{ .title = "Watchdog test" }, .{ .watchdog_ms = budget });
        defer gui.runtime.deinit();
        defer gui.renderer.deinit();
        try std.testing.expectEqual(budget, gui.runtime.core.watchdog_ms);
    }
}
