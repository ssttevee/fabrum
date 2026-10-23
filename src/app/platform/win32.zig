//! Win32 windows, native controls and alpha-composited Direct2D canvas layers.
const shell = @import("win32/shell.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const Color = fabrum.Color;

const app = @import("../../app.zig");
const native = app.native;

/// A borrowed Direct2D bridge target supplied by the host.
pub const Direct2DContext = opaque {};

pub const Options = struct {
    title: [:0]const u8,
    width: f64 = 800,
    height: f64 = 600,
    min_width: f64 = 320,
    min_height: f64 = 240,
    /// Reserved for dark-theme support; the initial backend uses light colors.
    dark: bool = false,
};

/// Kinds of Win32 object, as in shell.c.
pub const Kind = enum(c_int) { button, checkbox, @"switch", slider, text_field, progress, menu_item, alert, scroll_view, text_area, search_field, secure_field, spinner, dropdown, radio_group, stepper, label };

/// Kinds of event, as in shell.c.
pub const EventKind = enum(c_int) { activate, toggle, number, text, submit, focus, composition_end, response, select };

pub const CInputCaret = extern struct { layer: c_uint, x: f64, y: f64, height: f64, target: u64, generation: u64 };
pub const CHost = extern struct {
    ctx: *anyopaque,
    text: *const fn (ctx: *anyopaque, input: *const anyopaque) callconv(.c) bool,
    input_caret: *const fn (ctx: *anyopaque, caret: *CInputCaret) callconv(.c) bool,
    cancel_pointer: *const fn (ctx: *anyopaque) callconv(.c) void,
    key: *const fn (ctx: *anyopaque, event: *const anyopaque) callconv(.c) bool,
    frame: *const fn (ctx: *anyopaque, width: f64, height: f64) callconv(.c) void,
    draw_layer: *const fn (ctx: *anyopaque, layer: c_uint, cr: *Direct2DContext, width: f64, height: f64) callconv(.c) void,
    hit_layer: *const fn (ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool,
    mouse: *const fn (ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) bool,
    scroll: *const fn (ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void,
    tab: *const fn (ctx: *anyopaque, forward: c_int) callconv(.c) void,
    activate: *const fn (ctx: *anyopaque) callconv(.c) void,
    enter: *const fn (ctx: *anyopaque) callconv(.c) bool,
    event: *const fn (ctx: *anyopaque, id: u64, kind: EventKind, number: f64, text: ?[*]const u8, len: usize) callconv(.c) void,
    should_close: *const fn (ctx: *anyopaque, quit: c_int) callconv(.c) bool,
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
};

pub const TextCallback = *const fn (ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void;
pub const PopupCallback = *const fn (ctx: ?*anyopaque, selected: bool, id: usize) callconv(.c) void;
pub const IndexCallback = *const fn (ctx: ?*anyopaque, index: c_long) callconv(.c) void;

pub const COptions = extern struct {
    title: [*:0]const u8,
    width: f64,
    height: f64,
    min_width: f64,
    min_height: f64,
    dark: c_int,
};

pub const CSlot = extern struct {
    canvas: c_int,
    widget: ?*anyopaque,
};

pub const CTheme = extern struct {
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

pub const CMenuItem = extern struct {
    title: [*]const u8,
    title_len: usize,
    kind: c_int,
    id: usize,
    enabled: bool,
    depth: c_uint,
};

const fabrum_win32_window_create = shell.fabrum_win32_window_create;
const fabrum_win32_window_release = shell.fabrum_win32_window_release;
const fabrum_win32_present = shell.fabrum_win32_present;
const fabrum_win32_run = shell.fabrum_win32_run;
const fabrum_win32_request_frame = shell.fabrum_win32_request_frame;
const fabrum_win32_run_on_main = shell.fabrum_win32_run_on_main;
const fabrum_win32_cancel_main = shell.fabrum_win32_cancel_main;
const fabrum_win32_quit = shell.fabrum_win32_quit;
const fabrum_win32_quit_now = shell.fabrum_win32_quit_now;
const fabrum_win32_close_now = shell.fabrum_win32_close_now;
const fabrum_win32_message = shell.fabrum_win32_message;
const fabrum_win32_confirm = shell.fabrum_win32_confirm;
const fabrum_win32_write_clipboard = shell.fabrum_win32_write_clipboard;
const fabrum_win32_read_clipboard = shell.fabrum_win32_read_clipboard;

const fabrum_win32_create = shell.fabrum_win32_create;
const fabrum_win32_destroy = shell.fabrum_win32_destroy;
const fabrum_win32_set_title = shell.fabrum_win32_set_title;
const fabrum_win32_set_message = shell.fabrum_win32_set_message;
const fabrum_win32_add_button = shell.fabrum_win32_add_button;
const fabrum_win32_show_alert = shell.fabrum_win32_show_alert;
const fabrum_win32_set_enabled = shell.fabrum_win32_set_enabled;
const fabrum_win32_set_default = shell.fabrum_win32_set_default;
const fabrum_win32_set_placeholder = shell.fabrum_win32_set_placeholder;
const fabrum_win32_set_range = shell.fabrum_win32_set_range;
const fabrum_win32_set_increment = shell.fabrum_win32_set_increment;
const fabrum_win32_set_bool = shell.fabrum_win32_set_bool;
const fabrum_win32_set_number = shell.fabrum_win32_set_number;
const fabrum_win32_set_text = shell.fabrum_win32_set_text;
const fabrum_win32_set_progress = shell.fabrum_win32_set_progress;
const fabrum_win32_set_spinner_size = shell.fabrum_win32_set_spinner_size;
const fabrum_win32_set_items = shell.fabrum_win32_set_items;
const fabrum_win32_set_selection = shell.fabrum_win32_set_selection;
const fabrum_win32_set_horizontal = shell.fabrum_win32_set_horizontal;
const fabrum_win32_set_label_style = shell.fabrum_win32_set_label_style;
const fabrum_win32_place_menu_item = shell.fabrum_win32_place_menu_item;
const fabrum_win32_set_key_equivalent = shell.fabrum_win32_set_key_equivalent;
const fabrum_win32_set_frame = shell.fabrum_win32_set_frame;
const fabrum_win32_set_scroll_axes = shell.fabrum_win32_set_scroll_axes;
const fabrum_win32_set_content_size = shell.fabrum_win32_set_content_size;
const fabrum_win32_fitting_size = shell.fabrum_win32_fitting_size;
const fabrum_win32_is_composing = shell.fabrum_win32_is_composing;
const fabrum_win32_can_focus = shell.fabrum_win32_can_focus;
const fabrum_win32_focus = shell.fabrum_win32_focus;
const fabrum_win32_arrange = shell.fabrum_win32_arrange;
const fabrum_win32_damage_layer = shell.fabrum_win32_damage_layer;
const fabrum_win32_theme = shell.fabrum_win32_theme;
const fabrum_win32_font_family = shell.fabrum_win32_font_family;

const fabrum_win32_snapshot = shell.fabrum_win32_snapshot;
const fabrum_win32_perform_click = shell.fabrum_win32_perform_click;
const fabrum_win32_type = shell.fabrum_win32_type;
const fabrum_win32_text = shell.fabrum_win32_text;
const fabrum_win32_newline = shell.fabrum_win32_newline;
const fabrum_win32_slide = shell.fabrum_win32_slide;
const fabrum_win32_select = shell.fabrum_win32_select;
const fabrum_win32_step = shell.fabrum_win32_step;
const fabrum_win32_scroll_to = shell.fabrum_win32_scroll_to;
const fabrum_win32_tab = shell.fabrum_win32_tab;
const fabrum_win32_answer_alert = shell.fabrum_win32_answer_alert;
const fabrum_win32_answer_popup = shell.fabrum_win32_answer_popup;
const fabrum_win32_answer_open_panel = shell.fabrum_win32_answer_open_panel;
const fabrum_win32_choose_menu = shell.fabrum_win32_choose_menu;
const fabrum_win32_resize = shell.fabrum_win32_resize;
const fabrum_win32_describe_focus = shell.fabrum_win32_describe_focus;
const fabrum_win32_describe_hit = shell.fabrum_win32_describe_hit;

fn ptrOf(handle: native.Handle) *anyopaque {
    return @ptrFromInt(@backingInt(handle));
}

/// The Win32 implementation of `native.Backend`. Main thread only.
pub const Backend = struct {
    gpa: Allocator,
    window: *anyopaque,
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
            // no catalogue of Win32's own yet
            .extension => error.NativeCreateFailed,
            // the common kinds share their names with shell.c's
            inline else => |_, tag| @field(Kind, @tagName(tag)),
        };
    }

    fn create(ptr: *anyopaque, id: native.Id, spec: *const native.Spec, value: *const native.Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        _ = parent;
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const made = fabrum_win32_create(self.window, try kindOf(spec), id) orelse return error.NativeCreateFailed;
        configure(made, spec, null);
        writeValue(made, value);
        if (spec.* == .alert) fabrum_win32_show_alert(made);
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
                Set.text(made, fabrum_win32_set_title, b.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != b.enabled) fabrum_win32_set_enabled(made, b.enabled);
                if (was == null or was.?.role != b.role) fabrum_win32_set_default(made, b.role == .default);
            },
            .checkbox, .@"switch" => |t| {
                const was: ?native.Spec.Toggle = if (old) |o| switch (o.*) {
                    .checkbox, .@"switch" => |w| w,
                    else => unreachable,
                } else null;
                if (spec.* == .checkbox) Set.text(made, fabrum_win32_set_title, t.title, if (was) |w| w.title else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_win32_set_enabled(made, t.enabled);
            },
            .slider => |s| {
                fabrum_win32_set_range(made, s.min, s.max);
                fabrum_win32_set_enabled(made, s.enabled);
            },
            .text_field, .text_area, .search_field, .secure_field => |t| {
                const was: ?native.Spec.TextField = if (old) |o| switch (o.*) {
                    .text_field, .text_area, .search_field, .secure_field => |w| w,
                    else => unreachable,
                } else null;
                Set.text(made, fabrum_win32_set_placeholder, t.placeholder, if (was) |w| w.placeholder else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_win32_set_enabled(made, t.enabled);
            },
            .progress => |p| fabrum_win32_set_progress(made, p.value orelse 0, p.value == null),
            .spinner => |sp| if (old == null or old.?.spinner.size != sp.size) fabrum_win32_set_spinner_size(made, sp.size == .small),
            .dropdown, .radio_group => |items| {
                const was: ?native.Spec.Items = if (old) |o| switch (o.*) {
                    .dropdown, .radio_group => |w| w,
                    else => unreachable,
                } else null;
                if (spec.* == .radio_group and (was == null or was.?.horizontal != items.horizontal)) fabrum_win32_set_horizontal(made, items.horizontal);
                if (was == null or !sameStrings(was.?.items, items.items)) {
                    const allocator = std.heap.page_allocator;
                    const pointers = allocator.alloc([*]const u8, items.items.len) catch return;
                    defer allocator.free(pointers);
                    const lengths = allocator.alloc(usize, items.items.len) catch return;
                    defer allocator.free(lengths);
                    for (items.items, pointers, lengths) |item, *p, *l| {
                        p.* = item.ptr;
                        l.* = item.len;
                    }
                    fabrum_win32_set_items(made, pointers.ptr, lengths.ptr, items.items.len);
                }
                if (was == null or was.?.enabled != items.enabled) fabrum_win32_set_enabled(made, items.enabled);
            },
            .stepper => |st| {
                const was = if (old) |o| o.stepper else null;
                if (was == null or was.?.min != st.min or was.?.max != st.max) fabrum_win32_set_range(made, st.min, st.max);
                if (was == null or was.?.step != st.step) fabrum_win32_set_increment(made, st.step);
                if (was == null or was.?.enabled != st.enabled) fabrum_win32_set_enabled(made, st.enabled);
            },
            .label => |l| {
                const was = if (old) |o| o.label else null;
                Set.text(made, fabrum_win32_set_title, l.text, if (was) |w| w.text else null);
                if (was == null or was.?.wrap != l.wrap or was.?.selectable != l.selectable or was.?.font_size != l.font_size or was.?.secondary != l.secondary) {
                    fabrum_win32_set_label_style(made, l.wrap, l.selectable, l.font_size orelse 0, l.secondary);
                }
            },
            .menu_item => |m| {
                const was = if (old) |o| o.menu_item else null;
                Set.text(made, fabrum_win32_set_title, m.title, if (was) |w| w.title else null);
                Set.text(made, fabrum_win32_set_key_equivalent, m.key, if (was) |w| w.key else null);
                fabrum_win32_set_enabled(made, m.enabled);
                fabrum_win32_place_menu_item(made, m.menu.ptr, m.menu.len);
            },
            .alert => |a| if (old == null) {
                fabrum_win32_set_title(made, a.title.ptr, a.title.len);
                fabrum_win32_set_message(made, a.message.ptr, a.message.len);
                for (a.buttons) |button| fabrum_win32_add_button(made, button.ptr, button.len);
            },
            .scroll_view => |v| fabrum_win32_set_scroll_axes(made, v.horizontal, v.vertical),
            .extension => {},
        }
    }

    fn writeValue(made: *anyopaque, value: *const native.Value) void {
        switch (value.*) {
            .none => {},
            .toggle => |on| fabrum_win32_set_bool(made, on),
            .number => |n| fabrum_win32_set_number(made, n),
            .text => |t| fabrum_win32_set_text(made, t.ptr, t.len),
            .selection => |i| fabrum_win32_set_selection(made, if (i) |index| @intCast(index) else -1),
        }
    }

    fn destroy(_: *anyopaque, handle: native.Handle) void {
        fabrum_win32_destroy(ptrOf(handle));
    }

    /// `present` puts every widget in its parent, taking it out of the
    /// old one.
    fn reparent(_: *anyopaque, handle: native.Handle, parent: ?native.Handle) void {
        shell.fabrum_win32_reparent(ptrOf(handle), if (parent) |h| ptrOf(h) else null);
    }

    fn setFrame(_: *anyopaque, handle: native.Handle, frame: Rect) void {
        fabrum_win32_set_frame(ptrOf(handle), frame.x, frame.y, frame.w, frame.h);
    }

    fn setContentSize(_: *anyopaque, handle: native.Handle, size: Vec2) void {
        fabrum_win32_set_content_size(ptrOf(handle), size.x, size.y);
    }

    /// Native control measurement: the natural size, a wrapping label's under
    /// the width limit.
    fn measure(_: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        var w: f64 = 0;
        var h: f64 = 0;
        fabrum_win32_fitting_size(ptrOf(handle), if (constraints.max_width) |limit| limit else 0, &w, &h);
        return .init(@floatCast(w), @floatCast(h));
    }

    fn setValue(_: *anyopaque, handle: native.Handle, value: *const native.Value) void {
        writeValue(ptrOf(handle), value);
    }

    fn composing(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_win32_is_composing(ptrOf(handle));
    }

    fn canFocus(_: *anyopaque, handle: native.Handle) bool {
        return fabrum_win32_can_focus(ptrOf(handle));
    }

    fn focus(ptr: *anyopaque, target: native.FocusTarget) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        switch (target) {
            .none => fabrum_win32_focus(self.window, null, 0),
            .canvas => fabrum_win32_focus(self.window, null, 1),
            .native => |handle| fabrum_win32_focus(self.window, ptrOf(handle), 0),
        }
    }

    fn present(ptr: *anyopaque, scene: *const native.Scene) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        defer shell.finishArrange(self.window);
        if (scene.slots.len == 0) {
            fabrum_win32_arrange(self.window, null, @ptrCast(&[_]CSlot{.{ .canvas = 0, .widget = null }}), 1);
            shell.finishArrange(self.window);
            return;
        }
        self.arrange(null, scene.slots);
        for (scene.containers) |container| self.arrange(ptrOf(container.handle), container.slots);
        shell.finishArrange(self.window);
        for (scene.layers, 0..) |_, index| {
            const regions = self.canvas_damage.update(self.gpa, scene, index) catch {
                fabrum_win32_damage_layer(self.window, @intCast(index), 0, 0, native.CanvasDamage.extent, native.CanvasDamage.extent);
                continue;
            };
            for (regions) |r| fabrum_win32_damage_layer(self.window, @intCast(index), r.x, r.y, r.w, r.h);
        }
    }

    fn arrange(self: *Backend, container: ?*anyopaque, slots: []const native.Scene.Slot) void {
        self.slots.clearRetainingCapacity();
        for (slots) |slot| {
            self.slots.append(self.gpa, switch (slot) {
                .canvas => |index| .{ .canvas = @intCast(index), .widget = null },
                .native => |handle| .{ .canvas = -1, .widget = ptrOf(handle) },
            }) catch {
                std.log.err("win32: out of memory arranging widgets", .{});
                return;
            };
        }
        fabrum_win32_arrange(self.window, container, self.slots.items.ptr, self.slots.items.len);
    }

    fn theme(ptr: *anyopaque) native.Theme {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        var c: CTheme = undefined;
        fabrum_win32_theme(self.window, &c);
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
const frame_vtable: app.Platform.VTable = .{ .requestFrame = requestFrame };

fn requestFrame(ptr: *anyopaque) void {
    fabrum_win32_request_frame(ptr);
}

/// The canvas's renderer: Direct2D, drawing into the canvas layers'
/// targets with DirectWrite text.
pub const Canvas = fabrum.render.Direct2D;

const Lifetime = struct {
    gpa: Allocator,
    references: usize = 1,
    alive: bool = true,
    fn retain(self: *Lifetime) *Lifetime {
        self.references += 1;
        return self;
    }
    fn release(self: *Lifetime) void {
        self.references -= 1;
        if (self.references == 0) self.gpa.destroy(self);
    }
};

fn typeTag(comptime T: type) *const anyopaque {
    return &struct {
        var value: u8 = 0;
        const Type = T;
    }.value;
}

pub const Application = ApplicationWith(Canvas);

pub fn ApplicationWith(comptime Renderer: type) type {
    return struct {
        gpa: Allocator,
        io: std.Io,
        windows: app.Application,
        scheduled: bool = false,
        options: Self.Options,
        records: std.ArrayList(Record) = .empty,
        const Record = struct { id: app.WindowId, ptr: *anyopaque, type_tag: *const anyopaque };
        pub const InitOptions = struct { quit_on_last_window_closed: bool = true };
        pub const Options = InitOptions;
        const Self = @This();
        pub fn init(self: *Self, gpa: Allocator, io: std.Io, options: Self.Options) !void {
            try shell.initialize();
            self.* = .{ .gpa = gpa, .io = io, .windows = .init(gpa), .options = options };
        }
        pub fn deinit(self: *Self) void {
            fabrum_win32_cancel_main(self);
            self.windows.deinit();
            self.records.deinit(self.gpa);
        }
        pub fn openWindow(self: *Self, comptime Root: type, props: Root.Props, options: @import("win32.zig").Options, init_options: AppWith(Root, Renderer).InitOptions) !app.WindowId {
            const W = AppWith(Root, Renderer);
            const value = try self.gpa.create(W);
            errdefer self.gpa.destroy(value);
            try value.init(self.gpa, self.io, props, options, init_options);
            errdefer value.deinit();
            const Ops = struct {
                fn guard(ptr: *anyopaque, reason: app.platform.CloseReason) anyerror!bool {
                    const w: *W = @ptrCast(@alignCast(ptr));
                    defer w.afterInput();
                    const was_busy = shell.enterRuntime(w.native_window);
                    defer shell.leaveRuntime(w.native_window, was_busy);
                    return w.runtime.shouldClose(reason);
                }
                fn destroy(ptr: *anyopaque) void {
                    const w: *W = @ptrCast(@alignCast(ptr));
                    const gpa = w.runtime.core.gpa;
                    if (w.owner) |owner| {
                        for (owner.records.items, 0..) |record, index| {
                            if (record.id == w.id) {
                                _ = owner.records.swapRemove(index);
                                break;
                            }
                        }
                    }
                    w.deinit();
                    gpa.destroy(w);
                }
                fn present(ptr: *anyopaque) void {
                    const w: *W = @ptrCast(@alignCast(ptr));
                    fabrum_win32_present(w.native_window);
                }
                fn request(ptr: *anyopaque) void {
                    const w: *W = @ptrCast(@alignCast(ptr));
                    fabrum_win32_request_frame(w.native_window);
                }
            };
            try self.records.ensureUnusedCapacity(self.gpa, 1);
            const id = try self.windows.add(.{ .ptr = value, .vtable = &.{ .guard = Ops.guard, .destroy = Ops.destroy, .present = Ops.present, .requestFrame = Ops.request } });
            self.records.appendAssumeCapacity(.{ .id = id, .ptr = value, .type_tag = typeTag(W) });
            value.owner = self;
            value.id = id;
            fabrum_win32_present(value.native_window);
            return id;
        }
        pub fn window(self: *Self, comptime Root: type, id: app.WindowId) ?*AppWith(Root, Renderer) {
            if (!self.windows.contains(id)) return null;
            for (self.records.items) |record| {
                if (record.id == id and record.type_tag == typeTag(AppWith(Root, Renderer))) return @ptrCast(@alignCast(record.ptr));
            }
            return null;
        }
        pub fn quit(self: *Self) void {
            self.windows.requestQuit(null);
            self.schedule();
        }
        pub fn present(self: *Self, id: app.WindowId) bool {
            if (!self.windows.contains(id)) return false;
            self.windows.present(id);
            return true;
        }
        pub fn requestFrame(self: *Self, id: app.WindowId) bool {
            if (!self.windows.contains(id)) return false;
            self.windows.requestFrame(id);
            return true;
        }
        pub fn close(self: *Self, id: app.WindowId) bool {
            if (!self.windows.contains(id)) return false;
            self.windows.requestClose(id, .window);
            self.schedule();
            return true;
        }
        pub fn run(_: *Self) noreturn {
            fabrum_win32_run();
        }
        fn schedule(self: *Self) void {
            if (self.scheduled) return;
            self.scheduled = true;
            fabrum_win32_run_on_main(drain, self);
        }
        fn drain(ptr: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(ptr.?));
            self.scheduled = false;
            self.windows.drain() catch |err| std.log.err("close request failed: {t}", .{err});
            if (self.windows.count() == 0 and (self.options.quit_on_last_window_closed or self.windows.quit_completed)) fabrum_win32_quit_now();
        }
    };
}

/// Runs `Root` in a window, laid out by fabrum, with drawn content in
/// canvas layers drawn by Direct2D (`Canvas`). Must not move after `init`.
pub fn App(comptime RootComponent: type) type {
    return AppWith(RootComponent, Canvas);
}

/// `App`, with canvas layers drawn by `Renderer`: a `fabrum.layout`
/// renderer that draws into `.direct2d` surfaces.
pub fn AppWith(comptime RootComponent: type, comptime Renderer: type) type {
    comptime layout.checkRenderer(Renderer);
    if (comptime !layout.accepts(Renderer, .direct2d)) @compileError("fabrum: Win32's canvas layers need a renderer that draws into .direct2d surfaces, which " ++ @typeName(Renderer) ++ " doesn't");
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
        owner: ?*ApplicationWith(Renderer) = null,
        id: app.WindowId = undefined,
        native_window: *anyopaque,
        alive: bool = true,
        lifetime: *Lifetime,

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
            var renderer = try Renderer.init(gpa);
            errdefer renderer.deinit();
            const lifetime = try gpa.create(Lifetime);
            errdefer gpa.destroy(lifetime);
            self.* = .{
                .runtime = undefined,
                .renderer = renderer,
                .backend = .{ .gpa = gpa, .window = undefined },
                .native_window = undefined,
                .lifetime = lifetime,
                .props = props,
                .options = window,
                .io = io,
                .on_terminate = options.on_terminate,
            };
            self.lifetime.* = .{ .gpa = gpa };

            self.native_window = try fabrum_win32_window_create(self.cOptions(), self.host());
            self.backend.window = self.native_window;
            errdefer {
                fabrum_win32_close_now(self.native_window);
                fabrum_win32_window_release(self.native_window);
            }
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .platform = .{ .ptr = self.native_window, .vtable = &frame_vtable },
                .provide = options.provide,
                .context = options.context,
                .watchdog_ms = options.watchdog_ms,
                .native = self.backend.backend(),
                .services = .{ .ptr = self, .vtable = &services_vtable },
                .keymap = .windows,
            });
        }

        /// Opens the window and runs until the app quits.
        fn cOptions(self: *Self) COptions {
            return .{
                .title = self.options.title,
                .width = self.options.width,
                .height = self.options.height,
                .min_width = self.options.min_width,
                .min_height = self.options.min_height,
                .dark = @intFromBool(self.options.dark),
            };
        }
        fn host(self: *Self) CHost {
            return .{
                .ctx = self,
                .key = keyInput,
                .text = textInput,
                .input_caret = inputCaret,
                .cancel_pointer = cancelPointer,
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
            };
        }
        pub fn run(self: *Self) noreturn {
            fabrum_win32_present(self.native_window);
            fabrum_win32_run();
        }
        pub fn deinit(self: *Self) void {
            if (!self.alive) return;
            fabrum_win32_cancel_main(self);
            self.alive = false;
            self.lifetime.alive = false;
            defer self.lifetime.release();
            self.runtime.cancelTasks();
            fabrum_win32_close_now(self.native_window);
            self.runtime.deinit();
            self.backend.deinit();
            self.renderer.deinit();
            fabrum_win32_window_release(self.native_window);
            if (self.on_terminate) |callback| callback.call(callback.ctx);
        }

        /// A borrowed automation view, valid only while this window remains open.
        pub fn automation(self: *Self) @import("win32.zig").automation {
            return .{ .window = self.native_window };
        }
        /// The Win32 object made for the native element `id`, for automation.
        pub fn hwnd(self: *Self) *anyopaque {
            return shell.nativeHwnd(self.native_window);
        }
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
            const n = fabrum_win32_font_family(&family, family.len);
            if (n > 0) self.renderer.setDefaultFamily(family[0..n]);
            self.viewport = .init(@floatCast(width), @floatCast(height));
            _ = self.runtime.frame(Root, self.props, self.viewport, .now(self.io, .awake)) catch |err| {
                std.log.err("frame failed: {t}", .{err});
                return;
            };
            shell.positionInput(self.native_window);
            self.afterInput();
        }

        fn drawLayer(ctx: *anyopaque, layer: c_uint, cr: *Direct2DContext, width: f64, height: f64) callconv(.c) void {
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
            layout.draw(&self.renderer, moved.items, .direct2d, cr, null) catch |err| std.log.err("render failed: {t}", .{err});
        }

        fn hitLayer(ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool {
            const scene = cast(ctx).runtime.scene();
            if (layer >= scene.layers.len) return layer == 0;
            const l = scene.layers[layer];
            return l.hits(l.offset.add(.init(@floatCast(x), @floatCast(y))));
        }

        fn mouseIn(ctx: *anyopaque, layer: c_int, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) bool {
            const scene = cast(ctx).runtime.scene();
            const offset: Vec2 = if (layer >= 0 and layer < scene.layers.len) scene.layers[@intCast(layer)].offset else .zero;
            return dispatchMouse(ctx, x + offset.x, y + offset.y, buttons, scroll_x, scroll_y);
        }

        fn scroll(ctx: *anyopaque, id: u64, x: f64, y: f64) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.nativeEvent(id, .{ .scroll = .init(@floatCast(x), @floatCast(y)) }) catch |err| std.log.err("native event failed: {t}", .{err});
            self.afterInput();
        }

        /// Pointer input in the layout's coordinates; also for scripts.
        pub fn mouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
            _ = dispatchMouse(ctx, x, y, buttons, scroll_x, scroll_y);
        }

        fn dispatchMouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) bool {
            const self = cast(ctx);
            var pressed: app.MouseEvent.Buttons = .empty;
            if (buttons & 1 != 0) pressed.set(app.MouseEvent.primary);
            self.pointer = .init(@floatCast(x), @floatCast(y));
            const result = self.runtime.mouseResult(.{
                .position = self.pointer,
                .pressed = pressed,
                .scroll_delta = .init(@floatCast(scroll_x), @floatCast(scroll_y)),
            }) catch |err| {
                std.log.err("input failed: {t}", .{err});
                return false;
            };
            self.afterInput();
            return if (scroll_x != 0 or scroll_y != 0) result.scrolled else result.handled;
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

        fn cancelPointer(ctx: *anyopaque) callconv(.c) void {
            const self = cast(ctx);
            self.runtime.cancelPointer() catch {};
            self.afterInput();
        }
        fn textInput(ctx: *anyopaque, input_ptr: *const anyopaque) callconv(.c) bool {
            const self = cast(ctx);
            const input: *const app.TextInput = @ptrCast(@alignCast(input_ptr));
            const handled = self.runtime.textInput(input.*) catch false;
            self.afterInput();
            return handled;
        }
        fn inputCaret(ctx: *anyopaque, out: *CInputCaret) callconv(.c) bool {
            const self = cast(ctx);
            const focus = self.runtime.focused() orelse return false;
            if (focus.native != null) return false;
            const core = &self.runtime.core;
            const geometry = core.textGeometry(focus.unit) orelse return false;
            const caret = geometry.input_caret orelse return false;
            const unit = core.context.getUnitById(.fromInt(focus.unit)) orelse return false;
            const pad = unit.data.container.layout.padding;
            const scroll_offset = if (core.scrolls.get(focus.unit)) |v| v.offset else Vec2.zero;
            const x = unit.bbox.x + pad.left - scroll_offset.x + caret.x;
            const y = unit.bbox.y + pad.top - scroll_offset.y + caret.y;
            for (self.runtime.scene().layers, 0..) |layer, index| {
                for (layer.commands) |command| if (command.unit_id == focus.unit) {
                    out.* = .{ .layer = @intCast(index), .x = x - layer.offset.x, .y = y - layer.offset.y, .height = caret.h, .target = focus.unit, .generation = if (geometry.input_generation) |generation| generation.* else 0 };
                    return true;
                };
            }
            return false;
        }
        fn keyInput(ctx: *anyopaque, event_ptr: *const anyopaque) callconv(.c) bool {
            const self = cast(ctx);
            const input: *const app.KeyEvent = @ptrCast(@alignCast(event_ptr));
            const handled = self.runtime.key(input.*) catch false;
            self.afterInput();
            return handled;
        }
        fn afterInput(self: *Self) void {
            if (self.runtime.nextFrame()) |due| {
                const now = std.Io.Timestamp.now(self.io, .awake);
                const remaining = due.nanoseconds - now.nanoseconds;
                shell.scheduleFrame(self.native_window, @intCast(@min(@max(@divTrunc(remaining + 999999, 1000000), 1), 2147483647)));
            } else shell.cancelFrame(self.native_window);
        }

        fn willTerminate(ctx: *anyopaque) callconv(.c) void {
            const self = cast(ctx);
            self.deinit();
        }

        fn shouldClose(ctx: *anyopaque, quit: c_int) callconv(.c) bool {
            const self = cast(ctx);
            if (self.owner) |owner| {
                if (quit != 0) owner.windows.requestQuit(null) else owner.windows.requestClose(self.id, .window);
                owner.schedule();
                return false;
            }
            const was_busy = shell.enterRuntime(self.native_window);
            defer shell.leaveRuntime(self.native_window, was_busy);
            const may = self.runtime.shouldClose(if (quit != 0) .quit else .window) catch |err| blk: {
                std.log.err("close request failed: {t}", .{err});
                break :blk true;
            };
            self.afterInput();
            return may;
        }

        // Modeless Win32 messages and confirmations, clipboard, and lifecycle services.

        const services_vtable: app.platform.Services.VTable = .{
            .message = showMessage,
            .confirm = confirm,
            .menu = popupMenu,
            .editText = editText,
            .openFile = openFile,
            .openDirectory = openDirectory,
            .writeClipboard = writeClipboard,
            .readClipboard = readClipboard,
            .quit = quitNow,
            .close = closeNow,
            .cancelClose = cancelClose,
        };

        fn dialogKind(kind: app.platform.DialogKind) c_int {
            return switch (kind) {
                .info => 0,
                .question => 1,
                .warning => 2,
                .@"error" => 3,
            };
        }

        fn showMessage(ptr: *anyopaque, request: *const app.platform.MessageRequest) app.platform.Services.Error!void {
            const self = cast(ptr);
            fabrum_win32_message(self.native_window, request.title.ptr, request.title.len, request.text.ptr, request.text.len, dialogKind(request.kind), request.timeout_ms);
        }

        fn confirm(ptr: *anyopaque, request: *const app.platform.ConfirmRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
            const self = cast(ptr);
            if (request.buttons.len == 0 or request.buttons.len > 3) return error.ServiceFailed;
            const pending = try PendingIndex.create(self.runtime.core.gpa, self.lifetime, reply);
            errdefer pending.destroy();
            var pointers: [3][*]const u8 = undefined;
            var lengths: [3]usize = undefined;
            for (request.buttons, 0..) |button, i| {
                pointers[i] = button.ptr;
                lengths[i] = button.len;
            }
            fabrum_win32_confirm(self.native_window, request.title.ptr, request.title.len, request.text.ptr, request.text.len, &pointers, &lengths, request.buttons.len, request.default, dialogKind(request.kind), PendingIndex.answer, pending);
        }

        fn popupMenu(ptr: *anyopaque, request: *const app.platform.MenuRequest, reply: app.platform.IndexReply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const pending = try PendingIndex.create(self.runtime.core.gpa, self.lifetime, reply);
            errdefer pending.destroy();
            try shell.popupMenu(self.native_window, request, PendingIndex.popupAnswer, pending);
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
                    .id = item.id,
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
            pending.* = .{ .gpa = gpa, .reply = reply, .lifetime = self.lifetime.retain() };
            errdefer {
                pending.lifetime.release();
                gpa.destroy(pending);
            }
            try shell.openFile(self.native_window, request, directory, PendingReply.answer, pending);
        }

        fn editText(ptr: *anyopaque, request: *const app.platform.TextRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            const pending = try gpa.create(PendingReply);
            pending.* = .{ .gpa = gpa, .reply = reply, .lifetime = self.lifetime.retain() };
            errdefer {
                pending.lifetime.release();
                gpa.destroy(pending);
            }
            try shell.editText(self.native_window, request, PendingReply.answer, pending);
        }

        fn writeClipboard(_: *anyopaque, text: []const u8) app.platform.Services.Error!void {
            fabrum_win32_write_clipboard(text.ptr, text.len);
        }

        /// Win32 reads the clipboard asynchronously: the reply comes later.
        fn readClipboard(ptr: *anyopaque, reply: app.platform.Reply) app.platform.Services.Error!void {
            const self = cast(ptr);
            const gpa = self.runtime.core.gpa;
            const pending = try gpa.create(PendingReply);
            pending.* = .{ .gpa = gpa, .reply = reply, .lifetime = self.lifetime.retain() };
            fabrum_win32_read_clipboard(PendingReply.answer, pending);
        }

        fn quitNow(ptr: *anyopaque) void {
            const self = cast(ptr);
            if (self.owner) |owner| {
                owner.windows.requestQuit(self.id);
                owner.schedule();
            } else fabrum_win32_run_on_main(closeStandalone, self);
        }

        fn cancelClose(ptr: *anyopaque) void {
            const self = cast(ptr);
            if (self.owner) |owner| owner.windows.cancelClose(self.id);
        }
        fn closeNow(ptr: *anyopaque) void {
            const self = cast(ptr);
            if (self.owner) |owner| {
                owner.windows.approveClose(self.id);
                owner.schedule();
            } else fabrum_win32_run_on_main(closeStandalone, self);
        }

        fn closeStandalone(ctx: ?*anyopaque) callconv(.c) void {
            const self = cast(ctx.?);
            self.deinit();
            fabrum_win32_quit_now();
        }

        const PendingReply = struct {
            gpa: Allocator,
            reply: app.platform.Reply,
            lifetime: *Lifetime,

            fn answer(ctx: ?*anyopaque, text: ?[*]const u8, len: usize) callconv(.c) void {
                const self: *PendingReply = @ptrCast(@alignCast(ctx.?));
                defer self.gpa.destroy(self);
                defer self.lifetime.release();
                if (!self.lifetime.alive) return;
                self.reply.send(if (text) |t| t[0..len] else null) catch |err| std.log.err("reply lost: {t}", .{err});
            }
        };

        const PendingIndex = struct {
            gpa: Allocator,
            reply: app.platform.IndexReply,
            lifetime: *Lifetime,

            fn create(gpa: Allocator, lifetime: *Lifetime, reply: app.platform.IndexReply) Allocator.Error!*PendingIndex {
                const self = try gpa.create(PendingIndex);
                self.* = .{ .gpa = gpa, .reply = reply, .lifetime = lifetime.retain() };
                return self;
            }

            fn destroy(self: *PendingIndex) void {
                self.lifetime.release();
                self.gpa.destroy(self);
            }

            fn popupAnswer(ctx: ?*anyopaque, selected: bool, id: usize) callconv(.c) void {
                const self: *PendingIndex = @ptrCast(@alignCast(ctx.?));
                defer self.destroy();
                if (!self.lifetime.alive) return;
                self.reply.send(if (selected) id else null) catch |err| std.log.err("menu answer lost: {t}", .{err});
            }

            fn answer(ctx: ?*anyopaque, index: c_long) callconv(.c) void {
                const self: *PendingIndex = @ptrCast(@alignCast(ctx.?));
                defer self.destroy();
                if (!self.lifetime.alive) return;
                self.reply.send(if (index < 0) null else @intCast(index)) catch |err| std.log.err("dialog answer lost: {t}", .{err});
            }
        };
    };
}

/// Win32's widget catalogue: the common set. Nothing of Win32's own yet.
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
    window: *anyopaque,
    /// Synthetic WM_IME_* coverage, independent of installed IMEs. The cursor
    /// uses UTF-16 code units like IMM; this does not exercise a real IME UI.
    pub fn composition(self: @This(), text: []const u8, cursor_utf16: usize, commit: bool) bool {
        return shell.syntheticComposition(self.window, text, cursor_utf16, commit);
    }
    pub fn cancelComposition(self: @This()) void {
        shell.syntheticCompositionCancel(self.window);
    }
    /// Invokes `callback(ctx)` once through the Win32 dispatcher,
    /// from any thread. The callback runs on a later main-loop turn.
    pub fn runOnMain(callback: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) void {
        fabrum_win32_run_on_main(callback, ctx);
    }

    /// Whether a canvas has nontransparent pixels after successful HWND presentation.
    pub fn canvasHasInk(self: @This(), layer: usize) bool {
        return shell.canvasHasInk(self.window, layer);
    }

    pub const CanvasState = shell.CanvasState;
    /// Layer upload dimensions and actual HWND visibility; excludes desktop capture.
    pub fn canvasState(self: @This(), layer: usize) ?CanvasState {
        return shell.canvasState(self.window, layer);
    }
    /// Premultiplied BGRA in physical pixels from a successful layer upload.
    pub fn canvasPixel(self: @This(), layer: usize, x: usize, y: usize) ?[4]u8 {
        return shell.canvasPixel(self.window, layer, x, y);
    }
    /// Forces the next EndDraw to report device loss, for recovery regression tests.
    pub fn injectCanvasDeviceLoss(self: @This(), layer: usize) void {
        shell.injectCanvasDeviceLoss(self.window, layer);
    }
    pub fn failCanvasCreates(self: @This(), layer: usize, count: u32) void {
        shell.failCanvasCreates(self.window, layer, count);
    }
    pub fn repaintCanvas(self: @This(), layer: usize) void {
        shell.repaintCanvas(self.window, layer);
    }

    /// Closes the window as its close button does, asking the app first.
    pub fn quit() void {
        fabrum_win32_quit();
    }

    /// Draws the window's content into a PNG at `path`, at `scale` pixels
    /// per point, or the screen's if null, through the widget's paintable.
    pub fn snapshot(self: @This(), path: [:0]const u8, scale: ?f64) error{SnapshotFailed}!void {
        if (!fabrum_win32_snapshot(self.window, path, scale orelse 0)) return error.SnapshotFailed;
    }

    pub fn click(handle: native.Handle) void {
        fabrum_win32_perform_click(ptrOf(handle));
    }

    /// Types `text` at a field's caret, as keyboard text input does.
    pub fn typeText(handle: native.Handle, text: []const u8) void {
        fabrum_win32_type(ptrOf(handle), text.ptr, text.len);
    }

    pub fn fieldText(handle: native.Handle, buffer: []u8) []const u8 {
        return buffer[0..fabrum_win32_text(ptrOf(handle), buffer.ptr, buffer.len)];
    }

    pub fn newline(handle: native.Handle) void {
        fabrum_win32_newline(ptrOf(handle));
    }

    pub fn slide(handle: native.Handle, value: f64) void {
        fabrum_win32_slide(ptrOf(handle), value);
    }

    pub fn select(handle: native.Handle, index: usize) void {
        fabrum_win32_select(ptrOf(handle), @intCast(index));
    }

    pub fn step(handle: native.Handle, steps: i32) void {
        fabrum_win32_step(ptrOf(handle), steps);
    }

    pub fn widgetHwnd(handle: native.Handle) ?*anyopaque {
        return shell.controlHwnd(ptrOf(handle));
    }

    /// Radio buttons in declaration order; stepper edit at zero, updown at one.
    pub fn widgetPartHwnd(handle: native.Handle, index: usize) ?*anyopaque {
        return shell.controlPartHwnd(ptrOf(handle), index);
    }

    pub fn scrollTo(handle: native.Handle, offset: Vec2) void {
        fabrum_win32_scroll_to(ptrOf(handle), offset.x, offset.y);
    }

    pub fn tab(self: @This(), forward: bool) void {
        fabrum_win32_tab(self.window, @intFromBool(forward));
    }

    /// Answers the alert being shown (a declared one, or `Update.confirm`)
    /// with the button at `index`.
    pub fn answerAlert(self: @This(), index: usize) void {
        fabrum_win32_answer_alert(self.window, @intCast(index));
    }

    pub fn answerPopup(self: @This(), id: ?usize) error{NoPopupMenu}!void {
        if (!fabrum_win32_answer_popup(self.window, id)) return error.NoPopupMenu;
    }

    pub fn answerFileChooser(self: @This(), path: ?[:0]const u8) error{NoFileChooser}!void {
        if (!fabrum_win32_answer_open_panel(self.window, if (path) |p| p.ptr else null)) return error.NoFileChooser;
    }

    pub fn chooseMenu(self: @This(), menu: [:0]const u8, title: [:0]const u8) error{NoSuchMenuItem}!void {
        if (!fabrum_win32_choose_menu(self.window, menu, title)) return error.NoSuchMenuItem;
    }

    pub fn resize(self: @This(), width: f64, height: f64) void {
        fabrum_win32_resize(self.window, width, height);
    }

    pub fn describeFocus(self: @This(), buffer: []u8) []const u8 {
        return buffer[0..fabrum_win32_describe_focus(self.window, buffer.ptr, buffer.len)];
    }

    pub fn describeHit(self: @This(), x: f64, y: f64, buffer: []u8) []const u8 {
        return buffer[0..fabrum_win32_describe_hit(self.window, x, y, buffer.ptr, buffer.len)];
    }
};

test "apps draw their canvas with Direct2D unless given another renderer" {
    const Root = struct {
        pub const Props = struct {};
        pub fn view(ui: *app.Ui, props: Props) !void {
            _ = props;
            try ui.text("hi", .{});
        }
    };
    try std.testing.expect(App(Root).Runtime.Text == fabrum.render.Direct2D.Text);
}

test "app initialization forwards the debug watchdog budget" {
    const Root = struct {
        pub const Props = struct {};
        pub fn view(_: *app.Ui, _: Props) !void {}
    };
    const Gui = App(Root);
    try std.testing.expectEqual(@as(?u32, 16), (Gui.InitOptions{}).watchdog_ms);
    comptime {
        _ = Gui.init;
        _ = Gui.deinit;
    }
}
