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
//! The set: `button`, `checkbox`, `toggle`, `slider`, `textField`,
//! `textArea`, `searchField`, `secureField`, `dropdown`, `radioGroup`,
//! `stepper`, `label`, `progressBar`, `spinner` and `scrollView`.
//!
//! What only some platforms have is in their catalogue, as
//! `fabrum.app.platform.appkit.widgets`; see `app.platform`.
const std = @import("std");

const fabrum = @import("../root.zig");
const layout = fabrum.layout;

const Ui = @import("ui.zig").Ui;
const drawn = @import("drawn.zig");
const native = @import("native.zig");
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
    try nativeTextField(ui, key, .text_field, options);
}

/// A native single-line field of `kind`: a text, search or secure field.
fn nativeTextField(ui: *Ui, key: anytype, comptime kind: std.meta.Tag(native.Spec), options: TextFieldOptions) !void {
    try ui.native(key, .{
        .spec = @unionInit(native.Spec, @tagName(kind), .{ .placeholder = options.placeholder, .enabled = options.enabled }),
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

/// A multi-line text area, editable, wrapping its text and scrolling
/// inside its box: `NSTextView` in a scroll view on macOS. Controlled like
/// `textField`, and left alone while the user composes.
pub fn textArea(ui: *Ui, key: anytype, options: TextAreaOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.textArea(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .text_area = .{ .placeholder = options.placeholder, .enabled = options.enabled } },
        .value = .{ .text = options.text },
        .handlers = .{ .on_text = options.on_change },
        .sizing = options.sizing,
    });
}

/// A text field with the platform's search look (`NSSearchField`): a
/// magnifier and a button that clears it. Controlled like `textField`;
/// Return fires `on_submit`.
pub fn searchField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.searchField(ui, key, options);
    try nativeTextField(ui, key, .search_field, options);
}

/// A text field that shows bullets for what is typed
/// (`NSSecureTextField`), for passwords. Controlled like `textField`.
pub fn secureField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.secureField(ui, key, options);
    try nativeTextField(ui, key, .secure_field, options);
}

pub const DropdownOptions = struct {
    /// The titles to choose from.
    items: []const []const u8,
    /// The index of the item shown, or null for none.
    selected: ?usize,
    /// Fired with the index of the item the user chooses.
    on_select: ?Handler(usize) = null,
    enabled: bool = true,
    sizing: layout.Sizing = .{},
};

/// One of a list of items, chosen from a popup: `NSPopUpButton` on macOS,
/// `GtkDropDown` in GTK. The chosen item is controlled.
pub fn dropdown(ui: *Ui, key: anytype, options: DropdownOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.dropdown(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .dropdown = .{ .items = options.items, .enabled = options.enabled } },
        .value = .{ .selection = options.selected },
        .handlers = .{ .on_select = options.on_select },
        .sizing = options.sizing,
    });
}

pub const RadioGroupOptions = struct {
    /// The label of each radio button.
    items: []const []const u8,
    /// The index of the button that is on, or null for none.
    selected: ?usize,
    /// Fired with the index of the button the user turns on.
    on_select: ?Handler(usize) = null,
    enabled: bool = true,
    /// In a row rather than a column.
    horizontal: bool = false,
    sizing: layout.Sizing = .{},
};

/// Radio buttons, of which one is on: the platform's own, grouped. The
/// chosen one is controlled.
pub fn radioGroup(ui: *Ui, key: anytype, options: RadioGroupOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.radioGroup(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .radio_group = .{ .items = options.items, .enabled = options.enabled, .horizontal = options.horizontal } },
        .value = .{ .selection = options.selected },
        .handlers = .{ .on_select = options.on_select },
        .sizing = options.sizing,
    });
}

pub const StepperOptions = struct {
    value: f64,
    min: f64 = 0,
    max: f64 = 100,
    /// What one click of an arrow adds or takes.
    step: f64 = 1,
    /// Fired with the new value when the user steps it, or types one.
    on_change: ?Handler(f64) = null,
    enabled: bool = true,
    sizing: layout.Sizing = .{},
};

/// A number in a field with arrows that step it: `NSStepper` with a field
/// on macOS, `GtkSpinButton` in GTK. The value is controlled.
pub fn stepper(ui: *Ui, key: anytype, options: StepperOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.stepper(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .stepper = .{ .min = options.min, .max = options.max, .step = options.step, .enabled = options.enabled } },
        .value = .{ .number = options.value },
        .handlers = .{ .on_number = options.on_change },
        .sizing = options.sizing,
    });
}

pub const LabelOptions = struct {
    text: []const u8,
    /// Wraps within the width the box is given; otherwise one line.
    wrap: bool = true,
    /// Whether the user can select and copy the text (native labels only).
    selectable: bool = false,
    /// Points, or the platform's size for controls.
    font_size: ?f32 = null,
    /// In the secondary (dimmer) text color.
    secondary: bool = false,
    /// Labels fill the width they are given, and wrap within it.
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
};

/// Text in the platform's own label (`NSTextField` as a label, `GtkLabel`),
/// in the system font, wrapping within its box, and selectable if asked;
/// for text that should read exactly like the controls around it. Drawn
/// text (`ui.text`) is the choice for everything else.
pub fn label(ui: *Ui, key: anytype, options: LabelOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.label(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .label = .{ .text = options.text, .wrap = options.wrap, .selectable = options.selectable, .font_size = options.font_size, .secondary = options.secondary } },
        .sizing = options.sizing,
    });
}

pub const SpinnerOptions = struct {
    size: enum { small, regular } = .regular,
    sizing: layout.Sizing = .{},
};

/// Activity without progress: a spinning indicator (`NSProgressIndicator`
/// spinning, `GtkSpinner`). Declare it while something is running.
pub fn spinner(ui: *Ui, key: anytype, options: SpinnerOptions) !void {
    if (!ui.hasNativeWidgets()) return drawn.spinner(ui, key, options);
    try ui.native(key, .{
        .spec = .{ .spinner = .{ .size = if (options.size == .small) .small else .regular } },
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
