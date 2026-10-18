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
//! What only some platforms have is in their catalogue, as
//! `fabrum.app.platform.appkit.widgets`; see `app.platform`.
const std = @import("std");

const fabrum = @import("../root.zig");
const layout = fabrum.layout;

const Ui = @import("ui.zig").Ui;
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

/// A single-line text field, editable.
pub fn textField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    try ui.native(key, .{
        .spec = .{ .text_field = .{ .placeholder = options.placeholder, .enabled = options.enabled } },
        .value = .{ .text = options.text },
        .handlers = .{ .on_text = options.on_change, .on_submit = options.on_submit },
        .sizing = options.sizing,
    });
}

pub const ProgressOptions = struct {
    /// From 0 to 1, or null for activity without progress.
    value: ?f64,
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// A progress bar.
pub fn progressBar(ui: *Ui, key: anytype, options: ProgressOptions) !void {
    try ui.native(key, .{
        .spec = .{ .progress = .{ .value = options.value } },
        .sizing = options.sizing,
    });
}
