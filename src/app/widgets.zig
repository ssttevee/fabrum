//! The common widget set: controls every platform has, each shown as the
//! platform's own (an `NSButton` on macOS, a `GtkButton` with GTK). They
//! are view helpers over `Ui.native`, keyed like any element, and fire
//! ordinary handlers:
//!
//! ```zig
//! const on = ui.messages(Form);
//! try widgets.textField(ui, "name", .{ .text = state.name, .on_change = on.handler(.name_changed) });
//! try widgets.checkbox(ui, "agree", .{ .label = "I agree", .checked = state.agree, .on_change = on.handler(.agreed) });
//! try widgets.button(ui, "send", .{ .label = "Send", .on_click = on.bind(.send), .enabled = state.agree });
//! ```
//!
//! Values are controlled: the control shows what the view passes, and
//! reports the user's changes through `on_change`, which `update` stores
//! in the model. fabrum writes the model's value into the control only
//! when it differs from what the control last reported, and never while
//! the user is composing text, so echoing input back never disturbs typing.
//!
//! Without native widgets, as on the `none` platform (or in a test harness
//! asked for drawn widgets), each is drawn by fabrum instead: `app.drawn`,
//! with the same options. Apps that want drawn widgets everywhere call
//! `app.drawn` directly.
//!
//! What only some platforms have is in their catalogue, as
//! `fabrum.app.platform.appkit.widgets`; see `app.platform`.
const std = @import("std");

const fabrum = @import("../root.zig");
const layout = fabrum.layout;

const Ui = @import("ui.zig").Ui;
const drawn = @import("drawn.zig");
const message = @import("message.zig");
const Action = message.Action;
const Handler = message.Handler;

pub const ButtonOptions = struct {
    label: []const u8,
    on_click: ?Action = null,
    enabled: bool = true,
    /// The default button of a window or dialog, which Return presses.
    default: bool = false,
    sizing: layout.Sizing = .{},
};

/// A push button.
pub fn button(ui: *Ui, key: anytype, options: ButtonOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.button(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .button = .{ .title = options.label, .enabled = options.enabled, .role = if (options.default) .default else .normal } },
        .handlers = .{ .on_activate = options.on_click },
        .sizing = options.sizing,
    });
}

pub const CheckboxOptions = struct {
    label: []const u8,
    checked: bool,
    /// Fired with the new state when the user clicks it.
    on_change: ?Handler(bool) = null,
    enabled: bool = true,
    sizing: layout.Sizing = .{},
};

/// A checkbox with its label.
pub fn checkbox(ui: *Ui, key: anytype, options: CheckboxOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.checkbox(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .checkbox = .{ .title = options.label, .enabled = options.enabled } },
        .value = .{ .toggle = options.checked },
        .handlers = .{ .on_toggle = options.on_change },
        .sizing = options.sizing,
    });
}

pub const ToggleOptions = struct {
    on: bool,
    on_change: ?Handler(bool) = null,
    enabled: bool = true,
    sizing: layout.Sizing = .{},
};

/// A switch, without a label: put one beside it.
pub fn toggle(ui: *Ui, key: anytype, options: ToggleOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.toggle(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .@"switch" = .{ .enabled = options.enabled } },
        .value = .{ .toggle = options.on },
        .handlers = .{ .on_toggle = options.on_change },
        .sizing = options.sizing,
    });
}

pub const SliderOptions = struct {
    value: f64,
    min: f64 = 0,
    max: f64 = 1,
    /// Fired with the new value as the user drags.
    on_change: ?Handler(f64) = null,
    enabled: bool = true,
    /// Sliders fill the width they are given by default.
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// A horizontal slider.
pub fn slider(ui: *Ui, key: anytype, options: SliderOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.slider(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .slider = .{ .min = options.min, .max = options.max, .enabled = options.enabled } },
        .value = .{ .number = options.value },
        .handlers = .{ .on_number = options.on_change },
        .sizing = options.sizing,
    });
}

pub const TextFieldOptions = struct {
    text: []const u8,
    placeholder: []const u8 = "",
    /// Fired with the field's text after each edit, except while the user
    /// is composing. The message borrows the text: `update` copies it.
    on_change: ?Handler([]const u8) = null,
    /// Fired by Return.
    on_submit: ?Action = null,
    enabled: bool = true,
    /// Fields fill the width they are given by default.
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// A single-line text field, editable. Native where there are native
/// widgets; otherwise drawn, with an editor of its own inside
/// (`app.drawn.textField`).
pub fn textField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.textField(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .text_field = .{ .placeholder = options.placeholder, .enabled = options.enabled } },
        .value = .{ .text = options.text },
        .handlers = .{ .on_text = options.on_change, .on_submit = options.on_submit },
        .sizing = options.sizing,
    });
}

pub const TextAreaOptions = struct {
    text: []const u8,
    placeholder: []const u8 = "",
    /// Fired with the area's text after each edit. The message borrows
    /// the text: `update` copies it.
    on_change: ?Handler([]const u8) = null,
    enabled: bool = true,
    /// Areas fill the width they are given and are as tall as their text
    /// by default; a bounded height scrolls inside.
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// A multi-line text area, editable, wrapping its text. Drawn so far
/// (`app.drawn.textArea`): the native `NSTextView` and `GtkTextView` are
/// still to come, so with native widgets it is drawn too.
pub fn textArea(ui: *Ui, key: anytype, options: TextAreaOptions) !void {
    return drawn.textArea(ui, key, options);
}

pub const ProgressOptions = struct {
    /// From 0 to 1, or null for activity without progress.
    value: ?f64,
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// A progress bar.
pub fn progressBar(ui: *Ui, key: anytype, options: ProgressOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.progressBar(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .progress = .{ .value = options.value } },
        .sizing = options.sizing,
    });
}

pub const ScrollViewOptions = struct {
    horizontal: bool = false,
    vertical: bool = true,
    /// Told whenever a drawn scroll view's offset changes.
    on_scroll: ?Handler(@import("runtime.zig").ScrollInfo) = null,
    /// How the content is laid out inside: its axis, padding, gap and
    /// alignment. (Its sizing is ignored: the view's is `sizing`.)
    content: layout.Config = .{ .axis = .y },
    /// The view's own size, filling what it is given by default.
    sizing: layout.Sizing = .grow(.{}),
};

/// Opens a scroll view: everything declared until the matching `ui.close`
/// is its content, which scrolls along the axes asked for where it is
/// larger than the view. The platform's own (`NSScrollView`), which owns
/// the scroll offset and scrolls with momentum and scrollers; fabrum lays
/// the content out, native views and drawn content alike. Close it with
/// `defer ui.close()`.
///
/// Without native widgets it is drawn (`app.drawn.scrollView`): the
/// runtime keeps the offset, scrolls it by the wheel and a scrollbar, and
/// `Update.scrollTo` moves it.
pub fn scrollView(ui: *Ui, key: anytype, options: ScrollViewOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.scrollView(ui, key, options);
    try ui.nativeOpen(key, .{
        .spec = .{ .scroll_view = .{ .horizontal = options.horizontal, .vertical = options.vertical } },
        .sizing = options.sizing,
    }, options.content);
}
