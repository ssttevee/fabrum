//! The AppKit platform, on macOS: an `NSWindow` whose content is fabrum's
//! host view. fabrum lays out everything in it. AppKit's own controls
//! (`NSButton`, `NSSwitch`, `NSSlider`, `NSTextField`, ...) sit in it as
//! subviews, stacked with canvas layers (`NSView`s the app's renderer draws
//! into) in paint order; see `app.native.Scene`. The menu bar and alerts
//! are AppKit's too.
//!
//! `App(Root)` runs a root component in a window: it owns the runtime, the
//! canvas's renderer and the `Backend`, and turns what AppKit reports into
//! frames, pointer input, focus moves and native events. Canvas layers draw
//! with `fabrum.render.Quartz`, whose Core Text measures text as the native
//! controls do; `AppWith(Root, Renderer)` takes another renderer for
//! `.cg_context` surfaces.
//!
//! The Objective-C half is `appkit/shell.m`, behind a narrow C ABI, as
//! `NSTextInputClient`-style structs are easier there than through
//! `objc_msgSend`. fabrum's build adds it, and links AppKit, when the
//! `platform` option is `native` on macOS.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Color = fabrum.Color;

const app = @import("../../app.zig");
const native = app.native;

/// A Core Graphics context (`CGContextRef`). Renderers that draw with Core
/// Graphics take it by casting, as in `@as(*Quartz.CGContext, @ptrCast(cg))`.
pub const CGContext = opaque {};

pub const Options = struct {
    title: [:0]const u8,
    width: f64 = 800,
    height: f64 = 600,
    min_width: f64 = 320,
    min_height: f64 = 240,
    /// A dark window frame, for apps with a dark interface.
    dark: bool = false,
};

/// Kinds of AppKit object, as in shell.m.
const Kind = enum(c_int) { button, checkbox, @"switch", slider, text_field, progress, menu_item, alert, level_indicator, scroll_view, text_area, search_field, secure_field, spinner, dropdown, radio_group, stepper, label };

/// Kinds of event, as in shell.m.
const EventKind = enum(c_int) { activate, toggle, number, text, submit, focus, composition_end, response, select };

const CHost = extern struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, width: f64, height: f64) callconv(.c) void,
    draw_layer: *const fn (ctx: *anyopaque, layer: c_uint, cg: *CGContext, width: f64, height: f64) callconv(.c) void,
    hit_layer: *const fn (ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool,
    mouse: *const fn (ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void,
    scroll: *const fn (ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void,
    tab: *const fn (ctx: *anyopaque, forward: c_int) callconv(.c) void,
    activate: *const fn (ctx: *anyopaque) callconv(.c) void,
    event: *const fn (ctx: *anyopaque, id: u64, kind: EventKind, number: f64, text: ?[*]const u8, len: usize) callconv(.c) void,
    should_close: *const fn (ctx: *anyopaque, quit: c_int) callconv(.c) bool,
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
};

/// Called with text, or null for none, valid for the call.
const TextCallback = *const fn (ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void;

/// Called with the index of the button or item chosen, or -1 for none.
const IndexCallback = *const fn (ctx: ?*anyopaque, index: c_long) callconv(.c) void;

/// One item of a popup menu, as in shell.m.
const CMenuItem = extern struct {
    title: [*]const u8,
    title_len: usize,
    kind: c_int,
    id: c_long,
    enabled: bool,
    depth: c_uint,
};

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
    view: ?*anyopaque,
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

extern fn fabrum_appkit_run(options: COptions, host: CHost) callconv(.c) noreturn;
extern fn fabrum_appkit_request_frame() callconv(.c) void;
extern fn fabrum_appkit_set_cursor(cursor: c_int, x: f64, y: f64) callconv(.c) void;
extern fn fabrum_appkit_run_on_main(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_appkit_quit() callconv(.c) void;
extern fn fabrum_appkit_quit_now() callconv(.c) void;
extern fn fabrum_appkit_open_file(message: [*]const u8, message_len: usize, extensions: [*]const [*]const u8, lengths: [*]const usize, count: usize, done: TextCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_appkit_write_clipboard(bytes: [*]const u8, len: usize) callconv(.c) bool;
extern fn fabrum_appkit_read_clipboard(done: TextCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_appkit_use_private_clipboard() callconv(.c) void;
extern fn fabrum_appkit_clipboard_text(out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_appkit_answer_open_panel(path: ?[*:0]const u8) callconv(.c) bool;
extern fn fabrum_appkit_message(title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, kind: c_int, timeout_ms: c_uint) callconv(.c) void;
extern fn fabrum_appkit_confirm(title: [*]const u8, title_len: usize, text: [*]const u8, text_len: usize, buttons: [*]const [*]const u8, lengths: [*]const usize, count: usize, default_index: usize, kind: c_int, done: IndexCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_appkit_popup_menu(items: [*]const CMenuItem, count: usize, x: f64, y: f64, done: IndexCallback, ctx: ?*anyopaque) callconv(.c) void;
extern fn fabrum_appkit_answer_popup(id: c_long) callconv(.c) bool;
extern fn fabrum_appkit_perform_close() callconv(.c) void;

extern fn fabrum_appkit_create(kind: Kind, id: u64) callconv(.c) ?*anyopaque;
extern fn fabrum_appkit_destroy(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_appkit_set_title(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_set_message(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_add_button(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_show_alert(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_appkit_set_enabled(handle: *anyopaque, enabled: bool) callconv(.c) void;
extern fn fabrum_appkit_set_default(handle: *anyopaque, is_default: bool) callconv(.c) void;
extern fn fabrum_appkit_set_placeholder(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_set_range(handle: *anyopaque, min: f64, max: f64) callconv(.c) void;
extern fn fabrum_appkit_set_bool(handle: *anyopaque, on: bool) callconv(.c) void;
extern fn fabrum_appkit_set_number(handle: *anyopaque, value: f64) callconv(.c) void;
extern fn fabrum_appkit_set_text(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_set_progress(handle: *anyopaque, value: f64, indeterminate: bool) callconv(.c) void;
extern fn fabrum_appkit_place_menu_item(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_set_key_equivalent(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_set_frame(handle: *anyopaque, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_appkit_fitting_size(handle: *anyopaque, max_width: f64, w: *f64, h: *f64) callconv(.c) void;
extern fn fabrum_appkit_set_label_style(handle: *anyopaque, wrap: bool, selectable: bool, font_size: f64, secondary: bool) callconv(.c) void;
extern fn fabrum_appkit_set_items(handle: *anyopaque, titles: [*]const [*]const u8, lengths: [*]const usize, count: usize) callconv(.c) void;
extern fn fabrum_appkit_set_selection(handle: *anyopaque, index: c_long) callconv(.c) void;
extern fn fabrum_appkit_set_horizontal(handle: *anyopaque, horizontal: bool) callconv(.c) void;
extern fn fabrum_appkit_set_increment(handle: *anyopaque, step: f64) callconv(.c) void;
extern fn fabrum_appkit_set_spinner_size(handle: *anyopaque, small: bool) callconv(.c) void;
extern fn fabrum_appkit_select(handle: *anyopaque, index: c_long) callconv(.c) void;
extern fn fabrum_appkit_step(handle: *anyopaque, steps: c_long) callconv(.c) void;
extern fn fabrum_appkit_is_composing(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_appkit_can_focus(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_appkit_focus(handle: ?*anyopaque, canvas: c_int) callconv(.c) void;
extern fn fabrum_appkit_arrange(container: ?*anyopaque, slots: [*]const CSlot, count: usize) callconv(.c) void;
extern fn fabrum_appkit_damage_layer(layer: c_uint, x: f64, y: f64, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_appkit_set_scroll_axes(handle: *anyopaque, horizontal: bool, vertical: bool) callconv(.c) void;
extern fn fabrum_appkit_set_content_size(handle: *anyopaque, w: f64, h: f64) callconv(.c) void;
extern fn fabrum_appkit_translate(cg: *CGContext, dx: f64, dy: f64) callconv(.c) void;
extern fn fabrum_appkit_theme(out: *CTheme) callconv(.c) void;

extern fn fabrum_appkit_snapshot(path: [*:0]const u8, scale: f64) callconv(.c) bool;
extern fn fabrum_appkit_window_number() callconv(.c) c_long;
extern fn fabrum_appkit_perform_click(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_appkit_type(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_mark(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_commit(handle: *anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;
extern fn fabrum_appkit_text(handle: *anyopaque, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_appkit_newline(handle: *anyopaque) callconv(.c) void;
extern fn fabrum_appkit_slide(handle: *anyopaque, value: f64) callconv(.c) void;
extern fn fabrum_appkit_tab(forward: c_int) callconv(.c) void;
extern fn fabrum_appkit_answer_alert(index: c_int) callconv(.c) void;
extern fn fabrum_appkit_choose_menu(menu: [*:0]const u8, title: [*:0]const u8) callconv(.c) bool;
extern fn fabrum_appkit_resize(width: f64, height: f64) callconv(.c) void;
extern fn fabrum_appkit_describe_focus(out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_appkit_describe_hit(x: f64, y: f64, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn fabrum_appkit_synthesize_click(x: f64, y: f64) callconv(.c) void;
extern fn fabrum_appkit_synthesize_key(key_code: c_ushort, characters: [*:0]const u8, shift: bool) callconv(.c) void;

fn ptrOf(handle: native.Handle) *anyopaque {
    return @ptrFromInt(@backingInt(handle));
}

/// The AppKit implementation of `native.Backend`. Main thread only.
pub const Backend = struct {
    gpa: Allocator,
    slots: std.ArrayList(CSlot) = .empty,
    /// Which canvas layers changed, so only those are redrawn, and only
    /// where they changed.
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
            .button => .button,
            .checkbox => .checkbox,
            .@"switch" => .@"switch",
            .slider => .slider,
            .text_field => .text_field,
            .text_area => .text_area,
            .search_field => .search_field,
            .secure_field => .secure_field,
            .progress => .progress,
            .spinner => .spinner,
            .dropdown => .dropdown,
            .radio_group => .radio_group,
            .stepper => .stepper,
            .label => .label,
            .menu_item => .menu_item,
            .alert => .alert,
            .scroll_view => .scroll_view,
            .extension => |e| if (e.class == &widgets.level_indicator_class) .level_indicator else error.NativeCreateFailed,
        };
    }

    fn create(_: *anyopaque, id: native.Id, spec: *const native.Spec, value: *const native.Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        // `present` puts views in their containers
        _ = parent;
        const made = fabrum_appkit_create(try kindOf(spec), id) orelse return error.NativeCreateFailed;
        configure(made, spec, null);
        writeValue(made, value);
        switch (spec.*) {
            .alert => fabrum_appkit_show_alert(made),
            else => {},
        }
        return @fromBackingInt(@intCast(@intFromPtr(made)));
    }

    fn update(_: *anyopaque, handle: native.Handle, old: *const native.Spec, new: *const native.Spec) void {
        configure(ptrOf(handle), new, old);
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
                Set.text(made, fabrum_appkit_set_title, b.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != b.enabled) fabrum_appkit_set_enabled(made, b.enabled);
                if (was == null or was.?.role != b.role) fabrum_appkit_set_default(made, b.role == .default);
            },
            .checkbox, .@"switch" => |t| {
                const was: ?native.Spec.Toggle = if (old) |o| switch (o.*) {
                    .checkbox, .@"switch" => |w| w,
                    else => unreachable,
                } else null;
                if (spec.* == .checkbox) Set.text(made, fabrum_appkit_set_title, t.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_appkit_set_enabled(made, t.enabled);
            },
            .slider => |s| {
                fabrum_appkit_set_range(made, s.min, s.max);
                fabrum_appkit_set_enabled(made, s.enabled);
            },
            .text_field, .text_area, .search_field, .secure_field => |t| {
                const was: ?native.Spec.TextField = if (old) |o| switch (o.*) {
                    .text_field, .text_area, .search_field, .secure_field => |w| w,
                    else => unreachable,
                } else null;
                Set.text(made, fabrum_appkit_set_placeholder, t.placeholder, if (was) |w| w.placeholder else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_appkit_set_enabled(made, t.enabled);
            },
            .progress => |p| fabrum_appkit_set_progress(made, p.value orelse 0, p.value == null),
            .spinner => |sp| if (old == null or old.?.spinner.size != sp.size) fabrum_appkit_set_spinner_size(made, sp.size == .small),
            .dropdown, .radio_group => |items| {
                const was: ?native.Spec.Items = if (old) |o| switch (o.*) {
                    .dropdown, .radio_group => |w| w,
                    else => unreachable,
                } else null;
                if (was == null or !sameStrings(was.?.items, items.items)) {
                    var pointers: [64][*]const u8 = undefined;
                    var lengths: [64]usize = undefined;
                    const count = @min(items.items.len, pointers.len);
                    for (items.items[0..count], pointers[0..count], lengths[0..count]) |item, *p, *l| {
                        p.* = item.ptr;
                        l.* = item.len;
                    }
                    fabrum_appkit_set_items(made, &pointers, &lengths, count);
                }
                if (spec.* == .radio_group and (was == null or was.?.horizontal != items.horizontal)) fabrum_appkit_set_horizontal(made, items.horizontal);
                if (was == null or was.?.enabled != items.enabled) fabrum_appkit_set_enabled(made, items.enabled);
            },
            .stepper => |st| {
                fabrum_appkit_set_range(made, st.min, st.max);
                fabrum_appkit_set_increment(made, st.step);
                fabrum_appkit_set_enabled(made, st.enabled);
            },
            .label => |l| {
                const was = if (old) |o| o.label else null;
                Set.text(made, fabrum_appkit_set_title, l.text, if (was) |w| w.text else null);
                if (was == null or was.?.wrap != l.wrap or was.?.selectable != l.selectable or was.?.font_size != l.font_size or was.?.secondary != l.secondary) {
                    fabrum_appkit_set_label_style(made, l.wrap, l.selectable, l.font_size orelse 0, l.secondary);
                }
            },
            .menu_item => |m| {
                const was = if (old) |o| o.menu_item else null;
                Set.text(made, fabrum_appkit_set_title, m.title, if (was) |w| w.title else null);
                Set.text(made, fabrum_appkit_set_key_equivalent, m.key, if (was) |w| w.key else null);
                fabrum_appkit_set_enabled(made, m.enabled);
                fabrum_appkit_place_menu_item(made, m.menu.ptr, m.menu.len);
            },
            .alert => |a| if (old == null) {
                // an alert's text is fixed once shown
                fabrum_appkit_set_title(made, a.title.ptr, a.title.len);
                fabrum_appkit_set_message(made, a.message.ptr, a.message.len);
                for (a.buttons) |button| fabrum_appkit_add_button(made, button.ptr, button.len);
            },
            .scroll_view => |v| fabrum_appkit_set_scroll_axes(made, v.horizontal, v.vertical),
            .extension => |e| {
                const level = native.ExtensionClass.propsOf(widgets.LevelIndicator, e);
                fabrum_appkit_set_range(made, level.min, level.max);
                fabrum_appkit_set_enabled(made, level.enabled);
            },
        }
    }

    fn writeValue(made: *anyopaque, value: *const native.Value) void {
        switch (value.*) {
            .none => {},
            .toggle => |on| fabrum_appkit_set_bool(made, on),
            .number => |n| fabrum_appkit_set_number(made, n),
            .text => |t| fabrum_appkit_set_text(made, t.ptr, t.len),
            .selection => |i| fabrum_appkit_set_selection(made, if (i) |index| @intCast(index) else -1),
        }
    }

    fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    fn destroy(_: *anyopaque, handle: native.Handle) void {
        fabrum_appkit_destroy(ptrOf(handle));
    }

    /// Nothing to do yet: `present` puts every view in its parent, taking
    /// it out of the old one, and keeps the first responder.
    fn reparent(_: *anyopaque, handle: native.Handle, parent: ?native.Handle) void {
        _ = handle;
        _ = parent;
    }

    fn setFrame(_: *anyopaque, handle: native.Handle, frame: Rect) void {
        fabrum_appkit_set_frame(ptrOf(handle), frame.x, frame.y, frame.w, frame.h);
    }

    fn setContentSize(_: *anyopaque, handle: native.Handle, size: Vec2) void {
        fabrum_appkit_set_content_size(ptrOf(handle), size.x, size.y);
    }

    /// The view's fitting size; a wrapping label's under the width limit.
    fn measure(_: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        var w: f64 = 0;
        var h: f64 = 0;
        fabrum_appkit_fitting_size(ptrOf(handle), if (constraints.max_width) |limit| limit else 0, &w, &h);
        return .init(@floatCast(w), @floatCast(h));
    }

    fn setValue(_: *anyopaque, handle: native.Handle, value: *const native.Value) void {
        writeValue(ptrOf(handle), value);
    }

    fn composing(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_appkit_is_composing(ptrOf(handle));
    }

    fn canFocus(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_appkit_can_focus(ptrOf(handle));
    }

    fn focus(_: *anyopaque, target: native.FocusTarget) void {
        switch (target) {
            .none => fabrum_appkit_focus(null, 0),
            .canvas => fabrum_appkit_focus(null, 1),
            .native => |handle| fabrum_appkit_focus(ptrOf(handle), 0),
        }
    }

    fn present(ptr: *anyopaque, scene: *const native.Scene) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        // with no scene, keep one empty canvas so the window still takes input
        if (scene.slots.len == 0) {
            const empty: CSlot = .{ .canvas = 0, .view = null };
            fabrum_appkit_arrange(null, @ptrCast(&empty), 1);
            return;
        }
        // the host first, then each container, outermost first, so that
        // a container is in place before what is in it
        self.arrange(null, scene.slots);
        for (scene.containers) |container| self.arrange(ptrOf(container.handle), container.slots);
        // then redraw each canvas layer where it changed, if it did
        for (scene.layers, 0..) |_, index| {
            const regions = self.canvas_damage.update(self.gpa, scene, index) catch {
                std.log.err("appkit: out of memory finding what to redraw", .{});
                fabrum_appkit_damage_layer(@intCast(index), 0, 0, native.CanvasDamage.extent, native.CanvasDamage.extent);
                continue;
            };
            for (regions) |r| fabrum_appkit_damage_layer(@intCast(index), r.x, r.y, r.w, r.h);
        }
    }

    fn arrange(self: *Backend, container: ?*anyopaque, slots: []const native.Scene.Slot) void {
        self.slots.clearRetainingCapacity();
        for (slots) |slot| {
            self.slots.append(self.gpa, switch (slot) {
                .canvas => |index| .{ .canvas = @intCast(index), .view = null },
                .native => |handle| .{ .canvas = -1, .view = ptrOf(handle) },
            }) catch {
                std.log.err("appkit: out of memory arranging views", .{});
                return;
            };
        }
        fabrum_appkit_arrange(container, self.slots.items.ptr, self.slots.items.len);
    }

    fn theme(_: *anyopaque) native.Theme {
        var c: CTheme = undefined;
        fabrum_appkit_theme(&c);
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
/// queue, from any thread.
pub const platform: app.Platform = .{ .ptr = undefined, .vtable = &.{ .requestFrame = requestFrame } };

fn requestFrame(_: *anyopaque) void {
    fabrum_appkit_request_frame();
}

/// The canvas's renderer: Quartz, which draws into the canvas layers'
/// `CGContext`s.
pub const Canvas = fabrum.render.Quartz;

/// Runs `Root` in a window, laid out by fabrum, with drawn content in
/// canvas layers drawn by Quartz (`Canvas`).
///
/// Must not move after `init`.
pub fn App(comptime RootComponent: type) type {
    return AppWith(RootComponent, Canvas);
}

/// `App`, with canvas layers drawn by `Renderer`: a `fabrum.layout`
/// renderer that draws into `.cg_context` surfaces (see `layout.draw`), with
/// `init(gpa)`, `deinit` and a `text_context` for its `Text`.
pub fn AppWith(comptime RootComponent: type, comptime Renderer: type) type {
    comptime layout.checkRenderer(Renderer);
    if (comptime !layout.accepts(Renderer, .cg_context)) @compileError("fabrum: AppKit's canvas layers need a renderer that draws into .cg_context surfaces, which " ++ @typeName(Renderer) ++ " doesn't");
    return struct {
        runtime: Runtime,
        renderer: Renderer,
        backend: Backend,
        props: Root.Props,
        options: Options,
        io: std.Io,
        viewport: Vec2 = .zero,
        pointer: Vec2 = .init(-1, -1),

        const Self = @This();

        /// The root component.
        pub const Root = RootComponent;
        pub const Runtime = app.Runtime(.{ .Text = Renderer.Text });

        pub const InitOptions = struct {
            /// Root values, as in `Runtime.Options.provide`.
            provide: []const app.RootValue = &.{},
            context: layout.Context.Config = .{},
        };

        pub fn init(self: *Self, gpa: Allocator, io: std.Io, props: Root.Props, window: Options, options: InitOptions) !void {
            self.* = .{
                .runtime = undefined,
                .renderer = try Renderer.init(gpa),
                .backend = .{ .gpa = gpa },
                .props = props,
                .options = window,
                .io = io,
            };
            errdefer self.renderer.deinit();
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .platform = platform,
                .provide = options.provide,
                .context = options.context,
                .native = self.backend.backend(),
                .services = .{ .ptr = self, .vtable = &services_vtable },
            });
        }

        /// Opens the window and runs until the app quits.
        pub fn run(self: *Self) noreturn {
            fabrum_appkit_run(.{
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
                .event = event,
                .should_close = shouldClose,
                .will_terminate = willTerminate,
            });
        }

        /// The AppKit object made for the native element `id`, for
        /// automation.
        pub fn handleOf(self: *Self, id: native.Id) ?native.Handle {
            const record = self.runtime.reconciler().records.getPtr(id) orelse return null;
            return record.handle;
        }

        fn cast(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn frame(ctx: *anyopaque, width: f64, height: f64) callconv(.c) void {
            const self = cast(ctx);
            self.viewport = .init(@floatCast(width), @floatCast(height));
            _ = self.runtime.frame(Root, self.props, self.viewport, .now(self.io, .awake)) catch |err| {
                std.log.err("frame failed: {t}", .{err});
                return;
            };
            self.afterInput();
        }

        fn drawLayer(ctx: *anyopaque, layer: c_uint, cg: *CGContext, width: f64, height: f64) callconv(.c) void {
            _ = width;
            _ = height;
            const self = cast(ctx);
            const scene = self.runtime.scene();
            if (layer >= scene.layers.len) return;
            const l = scene.layers[layer];
            // shell.m has flipped the context to fabrum's coordinates; a layer
            // in a scroll view's document draws where the document starts
            fabrum_appkit_translate(cg, -l.offset.x, -l.offset.y);
            layout.draw(&self.renderer, l.commands, .cg_context, cg, null) catch |err| std.log.err("render failed: {t}", .{err});
        }

        fn hitLayer(ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool {
            const scene = cast(ctx).runtime.scene();
            // before the first frame, the empty canvas takes everything
            if (layer >= scene.layers.len) return layer == 0;
            const l = scene.layers[layer];
            return l.hits(l.offset.add(.init(@floatCast(x), @floatCast(y))));
        }

        /// Pointer input from a canvas layer, in its own coordinates, or
        /// from the host view (`layer` -1).
        fn mouseIn(ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
            const scene = cast(ctx).runtime.scene();
            const offset: Vec2 = if (layer >= 0 and layer < scene.layers.len) scene.layers[@intCast(layer)].offset else .zero;
            mouse(ctx, x + offset.x, y + offset.y, buttons, scroll_x, scroll_y);
        }

        /// A scroll view scrolled; its content is laid out against it from
        /// the next frame.
        fn scroll(ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.nativeEvent(id, .{ .scroll = .init(@floatCast(x), @floatCast(y)) }) catch |err| std.log.err("native event failed: {t}", .{err});
            self.afterInput();
        }

        /// Pointer input in the layout's coordinates (the content's, as
        /// shown); also for scripts that point at drawn content without
        /// events.
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
            fabrum_appkit_set_cursor(switch (self.runtime.cursor()) {
                .default => 0,
                .pointer => 1,
                .text => 2,
            }, x, y);
            self.afterInput();
        }

        fn tab(ctx: *anyopaque, forward: c_int) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.focusMove(if (forward != 0) .next else .previous);
            self.afterInput();
        }

        /// Space or Return on the canvas: clicks the focused drawn element.
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
            if (self.runtime.needsFrame()) fabrum_appkit_request_frame();
        }

        fn willTerminate(ctx: *anyopaque) callconv(.c) void {
            _ = ctx;
        }

        /// The window's close button, or quitting: asks the app first.
        fn shouldClose(ctx: *anyopaque, quit: c_int) callconv(.c) bool {
            const self = cast(ctx);
            const may = self.runtime.shouldClose(if (quit != 0) .quit else .window) catch |err| blk: {
                std.log.err("close request failed: {t}", .{err});
                break :blk true;
            };
            self.afterInput();
            return may;
        }

        // The services: `app.platform.Services` on AppKit. Dialogs are
        // NSAlert sheets, menus NSMenu popups, the file chooser an
        // NSOpenPanel sheet, the clipboard the general pasteboard.

        const services_vtable: app.platform.Services.VTable = .{
            .message = showMessage,
            .confirm = confirm,
            .menu = popupMenu,
            .openFile = openFile,
            .writeClipboard = writeClipboard,
            .readClipboard = readClipboard,
            .quit = quitNow,
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
            fabrum_appkit_message(request.title.ptr, request.title.len, request.text.ptr, request.text.len, dialogKind(request.kind), request.timeout_ms);
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
            fabrum_appkit_confirm(request.title.ptr, request.title.len, request.text.ptr, request.text.len, &pointers, &lengths, request.buttons.len, request.default, dialogKind(request.kind), PendingIndex.answer, pending);
        }

        fn popupMenu(ptr: *anyopaque, request: *const app.platform.MenuRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            var items: std.ArrayList(CMenuItem) = .empty;
            defer items.deinit(gpa);
            try flattenMenu(gpa, &items, request.items, 0);
            const pending = try PendingIndex.create(gpa, reply);
            errdefer pending.destroy();
            fabrum_appkit_popup_menu(items.items.ptr, items.items.len, request.at.x, request.at.y, PendingIndex.answer, pending);
        }

        /// The items as one list, a submenu's after its own, one deeper;
        /// shell.m builds the tree back.
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
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            // until the panel answers
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
            fabrum_appkit_open_file(request.message.ptr, request.message.len, &pointers, &lengths, count, PendingReply.answer, pending);
        }

        fn writeClipboard(_: *anyopaque, text: []const u8) app.platform.Services.Error!void {
            if (!fabrum_appkit_write_clipboard(text.ptr, text.len)) return error.ServiceFailed;
        }

        fn readClipboard(_: *anyopaque, reply: app.platform.Reply) app.platform.Services.Error!void {
            var read: ReadClipboard = .{ .reply = reply };
            fabrum_appkit_read_clipboard(ReadClipboard.answer, &read);
            try read.result;
        }

        fn quitNow(_: *anyopaque) void {
            fabrum_appkit_quit_now();
        }

        /// A reply waiting for the file chooser.
        const PendingReply = struct {
            gpa: Allocator,
            reply: app.platform.Reply,

            fn answer(ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
                const self: *PendingReply = @ptrCast(@alignCast(ctx.?));
                defer self.gpa.destroy(self);
                self.reply.send(if (text) |t| t[0..len] else null) catch |err| std.log.err("file chooser answer lost: {t}", .{err});
            }
        };

        /// A reply waiting for a dialog's button or a menu's item.
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

        const ReadClipboard = struct {
            reply: app.platform.Reply,
            result: Allocator.Error!void = {},

            fn answer(ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
                const self: *ReadClipboard = @ptrCast(@alignCast(ctx.?));
                self.result = self.reply.send(if (text) |t| t[0..len] else null);
            }
        };
    };
}

/// AppKit's widget catalogue: the common set, as `app.widgets` has it, and
/// what only AppKit has.
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

    /// The props of an `NSLevelIndicator` in its rating style.
    pub const LevelIndicator = struct {
        min: f64 = 0,
        max: f64 = 5,
        enabled: bool = true,
    };

    pub const level_indicator_class: native.ExtensionClass = .of(LevelIndicator, "NSLevelIndicator", .view);

    pub const LevelIndicatorOptions = struct {
        value: f64,
        min: f64 = 0,
        max: f64 = 5,
        on_change: ?app.Handler(f64) = null,
        enabled: bool = true,
        sizing: layout.Sizing = .{},
    };

    /// Stars the user clicks to rate something: `NSLevelIndicator`, which
    /// only AppKit has.
    pub fn levelIndicator(ui: *app.Ui, key: anytype, options: LevelIndicatorOptions) !void {
        const props = try ui.arena().create(LevelIndicator);
        props.* = .{ .min = options.min, .max = options.max, .enabled = options.enabled };
        try ui.native(key, .{
            .spec = .{ .extension = .{ .class = &level_indicator_class, .props = props } },
            .value = .{ .number = options.value },
            .handlers = .{ .on_number = options.on_change },
            .sizing = options.sizing,
        });
    }
};

/// What debug scripts do to a running app, in process: nothing reaches the
/// system's event stream and the real pointer never moves. Main thread
/// only, except `runOnMain`.
pub const automation = struct {
    /// Runs `callback(ctx)` on the main thread after the current event,
    /// from any thread.
    pub fn runOnMain(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
        fabrum_appkit_run_on_main(callback, ctx);
    }

    /// Quits as the Quit menu item does, asking the app first.
    pub fn quit() void {
        fabrum_appkit_quit();
    }

    /// Closes the window as its close button does, asking the app first.
    pub fn close() void {
        fabrum_appkit_perform_close();
    }

    /// Makes the clipboard a private pasteboard from now on, so that
    /// checks of copying and pasting never touch the user's clipboard.
    pub fn usePrivateClipboard() void {
        fabrum_appkit_use_private_clipboard();
    }

    /// The clipboard's text.
    pub fn clipboardText(buffer: []u8) []const u8 {
        return buffer[0..fabrum_appkit_clipboard_text(buffer.ptr, buffer.len)];
    }

    /// Answers the file chooser being shown with `path`, or cancels it with
    /// null, closing it. Errors if none is shown.
    pub fn answerFileChooser(path: ?[:0]const u8) error{NoFileChooser}!void {
        if (!fabrum_appkit_answer_open_panel(if (path) |p| p.ptr else null)) return error.NoFileChooser;
    }

    /// Draws the window's content into a PNG at `path`, at `scale` pixels
    /// per point, or the screen's if null. Draws the views rather than
    /// reading the screen, so it works while the screen is locked.
    pub fn snapshot(path: [:0]const u8, scale: ?f64) error{SnapshotFailed}!void {
        if (!fabrum_appkit_snapshot(path, scale orelse 0)) return error.SnapshotFailed;
    }

    /// The window's number, for `screencapture -l`.
    pub fn windowNumber() c_long {
        return fabrum_appkit_window_number();
    }

    /// Clicks a native control with its own `performClick:`, or chooses a
    /// menu item through its menu.
    pub fn click(handle: native.Handle) void {
        fabrum_appkit_perform_click(ptrOf(handle));
    }

    /// Focuses a field and types `text` into it with the field editor's
    /// `insertText:`, as keyboard text input does.
    pub fn typeText(handle: native.Handle, text: []const u8) void {
        fabrum_appkit_type(ptrOf(handle), text.ptr, text.len);
    }

    /// Composes `marked` in a field, as an input method's
    /// `setMarkedText:` does.
    pub fn mark(handle: native.Handle, marked: []const u8) void {
        fabrum_appkit_mark(ptrOf(handle), marked.ptr, marked.len);
    }

    /// Commits a composition with `text`.
    pub fn commit(handle: native.Handle, text: []const u8) void {
        fabrum_appkit_commit(ptrOf(handle), text.ptr, text.len);
    }

    /// The text a field or text area shows, marked text included.
    pub fn fieldText(handle: native.Handle, buffer: []u8) []const u8 {
        return buffer[0..fabrum_appkit_text(ptrOf(handle), buffer.ptr, buffer.len)];
    }

    /// Presses Return in a field, through its field editor's
    /// `insertNewline:`.
    pub fn newline(handle: native.Handle) void {
        fabrum_appkit_newline(ptrOf(handle));
    }

    /// Moves a slider as dragging it does.
    pub fn slide(handle: native.Handle, value: f64) void {
        fabrum_appkit_slide(ptrOf(handle), value);
    }

    /// Chooses item `index` of a popup button or radio group, as a click
    /// does.
    pub fn select(handle: native.Handle, index: usize) void {
        fabrum_appkit_select(ptrOf(handle), @intCast(index));
    }

    /// Steps a stepper `steps` up (or down, if negative), as its arrows do.
    pub fn step(handle: native.Handle, steps: i32) void {
        fabrum_appkit_step(ptrOf(handle), steps);
    }

    /// Tab or Shift-Tab where focus is, through AppKit's own key-view
    /// routing (the field editor's `insertTab:`, or the window's
    /// `selectNextKeyView:`).
    pub fn tab(forward: bool) void {
        fabrum_appkit_tab(@intFromBool(forward));
    }

    /// Answers the alert being shown with the button at `index`: a
    /// declared alert's, or a dialog's from `update` (`message`,
    /// `confirm`).
    pub fn answerAlert(index: usize) void {
        fabrum_appkit_answer_alert(@intCast(index));
    }

    /// Chooses the item with `id` in the popup menu being shown
    /// (`Update.menu`), or dismisses it with null. Errors if none is
    /// shown.
    pub fn answerPopup(id: ?usize) error{NoPopupMenu}!void {
        if (!fabrum_appkit_answer_popup(if (id) |i| @intCast(i) else -1)) return error.NoPopupMenu;
    }

    /// Chooses a menu bar item by its menu's title and its own.
    pub fn chooseMenu(menu: [:0]const u8, title: [:0]const u8) error{NoSuchMenuItem}!void {
        if (!fabrum_appkit_choose_menu(menu, title)) return error.NoSuchMenuItem;
    }

    /// Resizes the window's content, as dragging its corner does.
    pub fn resize(width: f64, height: f64) void {
        fabrum_appkit_resize(width, height);
    }

    /// What has keyboard focus, as a class name and element ID.
    pub fn describeFocus(buffer: []u8) []const u8 {
        return buffer[0..fabrum_appkit_describe_focus(buffer.ptr, buffer.len)];
    }

    /// The view AppKit's hit-testing gives a click at a point of the
    /// content: a canvas layer, or a native view and its element ID.
    pub fn describeHit(x: f64, y: f64, buffer: []u8) []const u8 {
        return buffer[0..fabrum_appkit_describe_hit(x, y, buffer.ptr, buffer.len)];
    }

    /// Clicks at a point of the content with mouse events sent through the
    /// window. Window-level events: only while the session is unlocked.
    pub fn windowClick(x: f64, y: f64) void {
        fabrum_appkit_synthesize_click(x, y);
    }

    /// Presses a key with events sent through the window. Window-level
    /// events: only while the session is unlocked.
    pub fn windowKey(key_code: u16, characters: [:0]const u8, shift: bool) void {
        fabrum_appkit_synthesize_key(key_code, characters, shift);
    }
};

test "apps draw their canvas with Quartz unless given another renderer" {
    const Root = struct {
        pub const Props = struct {};
        pub fn view(ui: *app.Ui, props: Props) !void {
            _ = props;
            try ui.text("hi", .{});
        }
    };
    try std.testing.expect(App(Root).Runtime.Text == fabrum.render.Quartz.Text);
    try std.testing.expect(AppWith(Root, Canvas) == App(Root));
}
