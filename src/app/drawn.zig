//! The common widget set, drawn by fabrum: what `app.widgets` shows when
//! the runtime has no native widgets, as on the `none` platform, and an
//! opt-in on every platform for apps that want the same pixels everywhere.
//!
//! Each takes the same options as its `app.widgets` counterpart, and looks
//! like the platform through the provided `native.Theme` (its accent,
//! colors, font size and control height). Values are controlled, as with
//! native widgets: a click fires `on_change` with the new value, and the
//! view shows whatever the model then says.
//!
//! What they do so far: they draw, hover and press, and respond to clicks.
//! A checkbox or switch flips, a slider jumps to where it was clicked, a
//! button clicks, and a text field takes focus and shows a caret. Dragging,
//! typing and keys beyond Tab, Space and Enter come later.
const std = @import("std");

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Color = fabrum.Color;

const Ui = @import("ui.zig").Ui;
const native = @import("native.zig");
const Theme = native.Theme;
const message = @import("message.zig");
const Update = message.Update;
const Pointer = @import("input.zig").Pointer;
const widgets = @import("widgets.zig");

pub const ButtonOptions = widgets.ButtonOptions;
pub const CheckboxOptions = widgets.CheckboxOptions;
pub const ToggleOptions = widgets.ToggleOptions;
pub const SliderOptions = widgets.SliderOptions;
pub const TextFieldOptions = widgets.TextFieldOptions;
pub const ProgressOptions = widgets.ProgressOptions;

/// A push button: the accent color if it is the default button, the
/// control background otherwise.
pub fn button(ui: *Ui, key: anytype, options: ButtonOptions) !void {
    const theme = ui.use(Theme);
    const base = if (options.default) theme.accent else theme.control_background;
    const fill = if (!options.enabled) base.withAlpha(base.a / 2) else shade(ui, key, base);
    const text = if (!options.enabled) theme.secondary_text else if (options.default) Color.white else theme.text;
    try ui.open(key, .{
        .layout = .{
            .sizing = options.sizing,
            .padding = .init(12, 12, padding(theme), padding(theme)),
            .child_alignment = .center,
        },
        .background_color = fill,
        .corner_radius = .uniform(6),
        .border = ring(ui, key, theme, if (options.default) .transparent else theme.separator),
        .on_click = if (options.enabled) options.on_click else null,
        .focusable = options.enabled and theme.full_keyboard_access,
    });
    defer ui.close();
    try ui.text(options.label, label(theme, text));
}

/// A box with a mark while checked, and its label.
pub fn checkbox(ui: *Ui, key: anytype, options: CheckboxOptions) !void {
    const theme = ui.use(Theme);
    try ui.open(key, .{
        .layout = .{ .sizing = options.sizing, .child_gap = 6, .child_alignment = .center_left },
        .on_click = if (options.enabled) if (options.on_change) |h| h.with(!options.checked) else null else null,
        .focusable = options.enabled and theme.full_keyboard_access,
    });
    defer ui.close();
    {
        const on = options.checked and options.enabled;
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(14), .child_alignment = .center },
            .background_color = if (on) shade(ui, key, theme.accent) else theme.control_background,
            .corner_radius = .uniform(3),
            .border = ring(ui, key, theme, if (on) .transparent else theme.secondary_text),
        });
        defer ui.close();
        if (options.checked) {
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(6) }, .background_color = if (options.enabled) .white else theme.secondary_text, .corner_radius = .uniform(1) });
            ui.close();
        }
    }
    if (options.label.len > 0) try ui.text(options.label, label(theme, if (options.enabled) theme.text else theme.secondary_text));
}

/// A switch: a pill, in the accent color while on, with its knob at the
/// end it is switched to.
pub fn toggle(ui: *Ui, key: anytype, options: ToggleOptions) !void {
    const theme = ui.use(Theme);
    const track = if (options.on) theme.accent else Color.rgba(0, 0, 0, 40);
    var sizing = options.sizing;
    if (sizing.width.mode == .fit) sizing.width = .fixed(32);
    if (sizing.height.mode == .fit) sizing.height = .fixed(18);
    try ui.open(key, .{
        .layout = .{ .sizing = sizing, .padding = .all(2), .child_alignment = if (options.on) .center_right else .center_left },
        .background_color = if (options.enabled) shade(ui, key, track) else track.withAlpha(track.a / 2),
        .corner_radius = .uniform(9),
        .border = ring(ui, key, theme, .transparent),
        .on_click = if (options.enabled) if (options.on_change) |h| h.with(!options.on) else null else null,
        .focusable = options.enabled and theme.full_keyboard_access,
    });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .fixed(14) },
        .background_color = .white,
        .corner_radius = .uniform(7),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
    });
    ui.close();
}

/// A horizontal slider. Clicking it moves the knob to where it was
/// clicked; dragging comes later.
pub fn slider(ui: *Ui, key: anytype, options: SliderOptions) !void {
    try ui.child(Slider, key, options);
}

/// A drawn slider as a component: it turns where it was pressed into a
/// value for its `on_change`.
pub const Slider = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { pointer: Pointer };
    pub const Props = SliderOptions;

    /// The track's inset on each side, so the knob stays inside.
    const inset = 8;

    pub fn update(_: *State, msg: Msg, ctx: *Update(Slider)) !void {
        switch (msg) {
            .pointer => |p| {
                const props = ctx.props.*;
                const fraction = std.math.clamp((p.local.x - inset) / @max(p.size.x - 2 * inset, 1), 0, 1);
                try ctx.emit(props.on_change, props.min + fraction * (props.max - props.min));
            },
        }
    }

    pub fn view(ui: *Ui, _: *const State, props: Props) !void {
        const theme = ui.use(Theme);
        const range = props.max - props.min;
        const fraction: f32 = if (range > 0) @floatCast(std.math.clamp((props.value - props.min) / range, 0, 1)) else 0;
        var sizing = props.sizing;
        if (sizing.height.mode == .fit) sizing.height = .fixed(20);
        try ui.open("slider", .{
            .layout = .{ .sizing = sizing, .padding = .init(inset, inset, 0, 0), .child_alignment = .center_left },
            .on_pointer = if (props.enabled and props.on_change != null) ui.messages(Slider).handler(.pointer) else null,
            .focusable = props.enabled and theme.full_keyboard_access,
        });
        defer ui.close();
        try ui.open(null, .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(4) } },
            .background_color = .rgba(0, 0, 0, 40),
            .corner_radius = .uniform(2),
        });
        defer ui.close();
        try ui.open(null, .{
            .layout = .{ .sizing = .{ .width = .percent(fraction), .height = .grow(.{}) } },
            .background_color = if (props.enabled) theme.accent else theme.secondary_text,
            .corner_radius = .uniform(2),
        });
        defer ui.close();
        try ui.open("knob", .{
            .layout = .{ .sizing = .fixed(16) },
            .floating = .{ .mode = .parent, .parent_point = .right_center, .unit_point = .center_center },
            .background_color = if (ui.pressed("slider")) Color.gray(235) else .white,
            .corner_radius = .uniform(8),
            .border = ring(ui, "slider", theme, theme.separator),
        });
        ui.close();
    }
};

/// A single-line text field. Pressing it focuses it and shows a caret;
/// typing comes later.
pub fn textField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    const theme = ui.use(Theme);
    const focused = ui.focused(key);
    try ui.open(key, .{
        .layout = .{
            .sizing = options.sizing,
            .padding = .init(6, 6, padding(theme), padding(theme)),
            .child_alignment = .center_left,
        },
        .background_color = if (options.enabled) theme.control_background else theme.control_background.withAlpha(128),
        .corner_radius = .uniform(4),
        .border = if (focused) .{ .color = theme.focus_ring.withAlpha(255), .widths = .outside(2) } else .{ .color = theme.separator, .widths = .outside(1) },
        .clip = .{ .horizontal = true },
        .focusable = options.enabled,
        .focus_on_press = options.enabled,
    });
    defer ui.close();
    const placeholder = options.text.len == 0;
    if (!placeholder) {
        try ui.text(options.text, label(theme, if (options.enabled) theme.text else theme.secondary_text));
    }
    if (focused) {
        try ui.open(null, .{ .layout = .{ .sizing = .fixedXY(1, theme.font_size + 2) }, .background_color = theme.text });
        ui.close();
    }
    if (placeholder and options.placeholder.len > 0) try ui.text(options.placeholder, label(theme, theme.secondary_text));
}

/// A progress bar, filled to its value, or with a sliding segment while
/// the value is unknown, which animates.
pub fn progressBar(ui: *Ui, key: anytype, options: ProgressOptions) !void {
    const theme = ui.use(Theme);
    var sizing = options.sizing;
    if (sizing.height.mode == .fit) sizing.height = .fixed(6);
    try ui.open(key, .{
        .layout = .{ .sizing = sizing },
        .background_color = .rgba(0, 0, 0, 30),
        .corner_radius = .uniform(3),
        .clip = .{ .horizontal = true },
    });
    defer ui.close();
    const segment: f32 = 0.3;
    const start: f32, const width: f32 = if (options.value) |value|
        .{ 0, @floatCast(std.math.clamp(value, 0, 1)) }
    else indeterminate: {
        // a segment sliding across once a second
        ui.animate();
        const ns_per_cycle = std.time.ns_per_s;
        const phase: f32 = @floatFromInt(@mod(ui.now().nanoseconds, ns_per_cycle));
        break :indeterminate .{ phase / ns_per_cycle * (1 - segment), segment };
    };
    if (options.value == null) {
        try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .percent(start), .height = .grow(.{}) } } });
        ui.close();
    }
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .percent(width), .height = .grow(.{}) } },
        .background_color = theme.accent,
        .corner_radius = .uniform(3),
    });
    ui.close();
}

pub const AlertOptions = @import("dialogs.zig").AlertOptions;

/// A modal alert over everything declared before it, with its buttons in a
/// row, the first being the default. Declare it last, so that it is on
/// top.
pub fn alert(ui: *Ui, key: anytype, options: AlertOptions) !void {
    const theme = ui.use(Theme);
    try ui.open(key, .{
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
        .floating = .{ .mode = .root },
        .background_color = .rgba(0, 0, 0, 60),
        .modal = true,
    });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .fixed(300) }, .axis = .y, .padding = .all(20), .child_gap = 12 },
        .background_color = theme.control_background,
        .corner_radius = .uniform(10),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
    });
    defer ui.close();
    try ui.text(options.title, label(theme, theme.text).with(.{ .font_size = theme.font_size + 2, .font_weight = .bold }));
    if (options.message.len > 0) try ui.text(options.message, label(theme, theme.secondary_text).with(.{ .wrap_mode = .words }));
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_right } });
    defer ui.close();
    for (options.buttons, 0..) |title, i| {
        try button(ui, AlertButton{ .alert = ui.id(key).id, .index = i }, .{
            .label = title,
            .default = i == 0,
            .on_click = if (options.on_response) |h| h.with(i) else null,
        });
    }
}

/// The key of an alert's button: its alert's element ID and its index.
pub const AlertButton = struct { alert: u64, index: usize };

/// The vertical padding that makes a control of one line of text as tall
/// as the platform's controls.
fn padding(theme: *const Theme) f32 {
    return @max((theme.control_height - theme.font_size * 1.2) / 2, 2);
}

fn label(theme: *const Theme, color: Color) layout.text.Style {
    return .{ .font_size = theme.font_size, .color = color, .wrap_mode = .none };
}

/// `color` lightened under the pointer and darkened while pressed.
fn shade(ui: *const Ui, key: anytype, color: Color) Color {
    if (ui.pressed(key)) return mix(color, .black, 0.12);
    if (ui.hovered(key)) return mix(color, .white, 0.12);
    return color;
}

/// The border of a control: the focus ring while focused, else `normal`.
fn ring(ui: *const Ui, key: anytype, theme: *const Theme, normal: Color) layout.ContainerDeclaration.BorderConfig {
    if (ui.focused(key)) return .{ .color = theme.focus_ring.withAlpha(255), .widths = .outside(2) };
    return .{ .color = normal, .widths = .outside(1) };
}

fn mix(a: Color, b: Color, t: f32) Color {
    const channel = struct {
        fn of(x: u8, y: u8, f: f32) u8 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(x)) * (1 - f) + @as(f32, @floatFromInt(y)) * f));
        }
    }.of;
    return .rgba(channel(a.r, b.r, t), channel(a.g, b.g, t), channel(a.b, b.b, t), a.a);
}

const testing = std.testing;
const app = @import("../app.zig");

/// A form of every common widget, through `app.widgets`, which draws them
/// in a harness asked for drawn widgets.
const Form = struct {
    pub const State = struct {
        clicks: usize = 0,
        agree: bool = false,
        loud: bool = false,
        volume: f64 = 0.25,
        asking: bool = false,
        answer: ?usize = null,
    };
    pub const Msg = union(enum) { click, agree: bool, loud: bool, volume: f64, ask, answered: usize };
    pub const Props = struct { busy: bool = false };

    pub fn update(state: *State, msg: Msg, _: *Update(Form)) void {
        switch (msg) {
            .click => state.clicks += 1,
            .agree => |on| state.agree = on,
            .loud => |on| state.loud = on,
            .volume => |v| state.volume = v,
            .ask => state.asking = true,
            .answered => |i| {
                state.answer = i;
                state.asking = false;
            },
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Form);
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 10 } });
        defer ui.close();
        try widgets.button(ui, "send", .{ .label = "Send", .on_click = on.bind(.click), .enabled = state.agree });
        try widgets.button(ui, "ask", .{ .label = "Ask", .on_click = on.bind(.ask), .default = true });
        try widgets.checkbox(ui, "agree", .{ .label = "I agree", .checked = state.agree, .on_change = on.handler(.agree) });
        try widgets.toggle(ui, "loud", .{ .on = state.loud, .on_change = on.handler(.loud) });
        try widgets.slider(ui, "volume", .{ .value = state.volume, .on_change = on.handler(.volume) });
        try widgets.progressBar(ui, "progress", .{ .value = if (props.busy) null else state.volume });
        try widgets.textField(ui, "name", .{ .text = "", .placeholder = "Name" });
        try @import("menus.zig").item(ui, "greet", .{ .menu = "Form", .title = "Greet" });
        if (state.asking) try @import("dialogs.zig").alert(ui, "question", .{ .title = "Really?", .buttons = &.{ "Yes", "No" }, .on_response = on.handler(.answered) });
    }
};

const Harness = app.testing.Harness(.{}, Form);

fn harness() !Harness {
    return .init(.{}, .{ .viewport = .init(300, 400), .widgets = .drawn });
}

test "drawn widgets respond to clicks" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.expectText("I agree");
    try h.expectText("Name");
    // no native widgets, and no menu bar
    try testing.expectEqual(0, h.tree.all().len);

    // disabled until agreed
    try h.click("Send");
    try testing.expectEqual(0, h.state().clicks);
    try h.click("I agree");
    try testing.expect(h.state().agree);
    try h.click("Send");
    try testing.expectEqual(1, h.state().clicks);
    // clicking the box, not just the label, flips it back
    try h.clickElement(h.root().element("agree"));
    try testing.expect(!h.state().agree);

    try h.clickElement(h.root().element("loud"));
    try testing.expect(h.state().loud);
    try h.clickElement(h.root().element("loud"));
    try testing.expect(!h.state().loud);
}

test "a drawn slider jumps to where it is clicked" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const track = h.findElement(h.root().child(Slider, "volume").element("slider")).?.bbox;
    // three quarters of the way along the track, inside its insets
    const x = track.x + Slider.inset + (track.w - 2 * Slider.inset) * 0.75;
    try h.clickAt(.init(x, track.y + track.h / 2));
    try testing.expectApproxEqAbs(0.75, h.state().volume, 0.001);
    // past the end clamps
    try h.clickAt(.init(track.x + track.w - 1, track.y + track.h / 2));
    try testing.expectEqual(1, h.state().volume);
    // the progress bar follows
    const bar = h.findElement(h.root().element("progress")).?;
    const fill = h.runtime.context().getUnitByIndex(bar.children.items[0]).?;
    try testing.expectEqual(bar.bbox.w, fill.bbox.w);
}

test "a drawn text field takes focus when pressed, and shows a caret" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const units = h.runtime.context().units.items.len;
    try h.clickElement(h.root().element("name"));
    try h.expectFocused(h.root().element("name"));
    // the caret
    try testing.expectEqual(units + 1, h.runtime.context().units.items.len);
    // Escape gives focus back
    try testing.expect(try h.pressKey(.escape, .{}));
    try testing.expectEqual(null, h.runtime.focused());
}

test "an indeterminate drawn progress bar animates" {
    var h = try harness();
    defer h.deinit();
    h.props.busy = true;
    try h.frame();
    try testing.expectEqual(h.now.nanoseconds, h.runtime.nextFrame().?.nanoseconds);
    const bar = h.findElement(h.root().element("progress")).?;
    const before = h.runtime.context().getUnitByIndex(bar.children.items[1]).?.bbox.x;
    try h.advance(.fromMilliseconds(500));
    const after = h.runtime.context().getUnitByIndex(h.findElement(h.root().element("progress")).?.children.items[1]).?.bbox.x;
    try testing.expect(after > before);
}

test "without native widgets an alert is drawn, and answered by its buttons" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.click("Ask");
    try h.expectText("Really?");
    // modal: the backdrop takes clicks meant for what is under it
    try h.click("I agree");
    try testing.expect(!h.state().agree);
    try h.click("No");
    try testing.expectEqual(1, h.state().answer.?);
    try h.expectNoText("Really?");
}
