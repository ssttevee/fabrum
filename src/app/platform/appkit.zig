//! The AppKit platform, on macOS: an `NSWindow` whose content is fabrum's
//! host view. fabrum lays out everything in it. AppKit's own controls
//! (`NSButton`, `NSSwitch`, `NSSlider`, `NSTextField`, ...) sit in it as
//! subviews, stacked with canvas layers (`NSView`s the app's renderer draws
//! into) in paint order; see `app.native.Scene`. The menu bar and alerts
//! are AppKit's too.
//!
//! `App(Root, Renderer)` runs a root component in a window: it owns the
//! runtime, the renderer and the `Backend`, and turns what AppKit reports
//! into frames, pointer input, focus moves and native events.
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
const Kind = enum(c_int) { button, checkbox, @"switch", slider, text_field, progress, menu_item, alert, level_indicator };

/// Kinds of event, as in shell.m.
const EventKind = enum(c_int) { activate, toggle, number, text, submit, focus, composition_end, response };

const CHost = extern struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, width: f64, height: f64) callconv(.c) void,
    draw_layer: *const fn (ctx: *anyopaque, layer: c_uint, cg: *CGContext, width: f64, height: f64) callconv(.c) void,
    hit_layer: *const fn (ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool,
    mouse: *const fn (ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void,
    tab: *const fn (ctx: *anyopaque, forward: c_int) callconv(.c) void,
    activate: *const fn (ctx: *anyopaque) callconv(.c) void,
    event: *const fn (ctx: *anyopaque, id: u64, kind: EventKind, number: f64, text: ?[*]const u8, len: usize) callconv(.c) void,
    will_terminate: *const fn (ctx: *anyopaque) callconv(.c) void,
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
extern fn fabrum_appkit_fitting_size(handle: *anyopaque, w: *f64, h: *f64) callconv(.c) void;
extern fn fabrum_appkit_is_composing(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_appkit_can_focus(handle: *anyopaque) callconv(.c) bool;
extern fn fabrum_appkit_focus(handle: ?*anyopaque, canvas: c_int) callconv(.c) void;
extern fn fabrum_appkit_arrange(slots: [*]const CSlot, count: usize) callconv(.c) void;
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

    pub fn deinit(self: *Backend) void {
        self.slots.deinit(self.gpa);
    }

    pub fn backend(self: *Backend) native.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: native.Backend.VTable = .{
        .create = create,
        .update = update,
        .destroy = destroy,
        .setFrame = setFrame,
        .measure = measure,
        .setValue = setValue,
        .composing = composing,
        .canFocus = canFocus,
        .focus = focus,
        .present = present,
        .theme = theme,
    };

    fn kindOf(spec: *const native.Spec) error{NativeCreateFailed}!Kind {
        return switch (spec.*) {
            .button => .button,
            .checkbox => .checkbox,
            .@"switch" => .@"switch",
            .slider => .slider,
            .text_field => .text_field,
            .progress => .progress,
            .menu_item => .menu_item,
            .alert => .alert,
            .extension => |e| if (e.class == &widgets.level_indicator_class) .level_indicator else error.NativeCreateFailed,
        };
    }

    fn create(_: *anyopaque, id: native.Id, spec: *const native.Spec, value: *const native.Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        std.debug.assert(parent == null);
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
            .text_field => |t| {
                const was = if (old) |o| o.text_field else null;
                Set.text(made, fabrum_appkit_set_placeholder, t.placeholder, if (was) |w| w.placeholder else null);
                if (was == null or was.?.enabled != t.enabled) fabrum_appkit_set_enabled(made, t.enabled);
            },
            .progress => |p| fabrum_appkit_set_progress(made, p.value orelse 0, p.value == null),
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
        }
    }

    fn destroy(_: *anyopaque, handle: native.Handle) void {
        fabrum_appkit_destroy(ptrOf(handle));
    }

    fn setFrame(_: *anyopaque, handle: native.Handle, frame: Rect) void {
        fabrum_appkit_set_frame(ptrOf(handle), frame.x, frame.y, frame.w, frame.h);
    }

    fn measure(_: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        _ = constraints;
        var w: f64 = 0;
        var h: f64 = 0;
        fabrum_appkit_fitting_size(ptrOf(handle), &w, &h);
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
        self.slots.clearRetainingCapacity();
        for (scene.slots) |slot| {
            self.slots.append(self.gpa, switch (slot) {
                .canvas => |index| .{ .canvas = @intCast(index), .view = null },
                .native => |handle| .{ .canvas = -1, .view = ptrOf(handle) },
            }) catch {
                std.log.err("appkit: out of memory arranging views", .{});
                return;
            };
        }
        // with no scene, keep one empty canvas so the window still takes input
        if (self.slots.items.len == 0) {
            const empty: CSlot = .{ .canvas = 0, .view = null };
            fabrum_appkit_arrange(@ptrCast(&empty), 1);
            return;
        }
        fabrum_appkit_arrange(self.slots.items.ptr, self.slots.items.len);
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

/// Runs `Root` in a window, drawn by `Renderer` and laid out by fabrum.
///
/// `Renderer` is duck-typed, as Quartz is: `Renderer.Text` is the runtime's
/// text, `Renderer.init(gpa)`, `deinit`, `text_context`, a
/// `Renderer.CGContext` with `flipCanvas(height)`, and
/// `renderCommands(commands: []const layout.RenderCommand, cg)`.
///
/// Must not move after `init`.
pub fn App(comptime RootComponent: type, comptime Renderer: type) type {
    return struct {
        runtime: Runtime,
        renderer: Renderer,
        backend: Backend,
        props: Root.Props,
        options: Options,
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
            };
            errdefer self.renderer.deinit();
            self.runtime = try .init(gpa, .{
                .io = io,
                .text_context = self.renderer.text_context,
                .platform = platform,
                .provide = options.provide,
                .context = options.context,
                .native = self.backend.backend(),
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
                .mouse = mouse,
                .tab = tab,
                .activate = activate,
                .event = event,
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
            _ = self.runtime.frame(Root, self.props, self.viewport) catch |err| {
                std.log.err("frame failed: {t}", .{err});
                return;
            };
        }

        fn drawLayer(ctx: *anyopaque, layer: c_uint, cg: *CGContext, width: f64, height: f64) callconv(.c) void {
            _ = width;
            const self = cast(ctx);
            const scene = self.runtime.scene();
            if (layer >= scene.layers.len) return;
            const renderer_cg: *Renderer.CGContext = @ptrCast(cg);
            renderer_cg.flipCanvas(height);
            self.renderer.renderCommands(scene.layers[layer].commands, renderer_cg) catch |err| std.log.err("render failed: {t}", .{err});
        }

        fn hitLayer(ctx: *anyopaque, layer: c_uint, x: f64, y: f64) callconv(.c) bool {
            const scene = cast(ctx).runtime.scene();
            if (layer >= scene.layers.len) return false;
            return scene.layers[layer].hits(.init(@floatCast(x), @floatCast(y)));
        }

        /// Pointer input, as the host view reports it; also for scripts
        /// that point at drawn content without events.
        pub fn mouse(ctx: *anyopaque, x: f64, y: f64, buttons: c_uint, scroll_x: f64, scroll_y: f64) callconv(.c) void {
            const self = cast(ctx);
            var pressed: app.MouseEvent.Buttons = .empty;
            if (buttons & 1 != 0) pressed.set(app.MouseEvent.primary);
            self.pointer = .init(@floatCast(x), @floatCast(y));
            self.runtime.mouse(.{
                .position = self.pointer,
                .pressed = pressed,
                .scroll_delta = .init(@floatCast(scroll_x), @floatCast(scroll_y)),
            }) catch |err| std.log.err("input failed: {t}", .{err});
            fabrum_appkit_set_cursor(switch (self.runtime.cursor()) {
                .default => 0,
                .pointer => 1,
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
    pub const progressBar = app.widgets.progressBar;

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

    /// Quits as the Quit menu item does.
    pub fn quit() void {
        fabrum_appkit_quit();
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

    /// The text a field shows, marked text included.
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

    /// Tab or Shift-Tab where focus is, through AppKit's own key-view
    /// routing (the field editor's `insertTab:`, or the window's
    /// `selectNextKeyView:`).
    pub fn tab(forward: bool) void {
        fabrum_appkit_tab(@intFromBool(forward));
    }

    /// Answers the alert being shown with the button at `index`.
    pub fn answerAlert(index: usize) void {
        fabrum_appkit_answer_alert(@intCast(index));
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
