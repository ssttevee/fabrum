//! The common widget set, drawn by fabrum: what `app.widgets` shows when
//! the runtime has no native widgets, as on the `none` platform, and an
//! opt-in on every platform for apps that want the same pixels everywhere.
//!
//! Each takes the same options as its `app.widgets` counterpart, and looks
//! like the platform through the provided `native.Theme` (its accent,
//! colors, font size and control height), adapting to the provided
//! `app.Capabilities`: no hover styles without hover, no caret blink or
//! animation without `full` animation. Values are controlled, as with
//! native widgets: a click fires `on_change` with the new value, and the
//! view shows whatever the model then says.
//!
//! A checkbox or switch flips, a slider jumps to where it was pressed and
//! follows a drag (and the arrow keys), a button clicks (by pointer, Space
//! or Enter), a progress bar animates while indeterminate, a scroll view
//! scrolls (see `app.Scroll`), and the text widgets edit:
//!
//! - `textField` and `textArea` keep an `app.TextEditor` inside and report
//!   the text after each edit through `on_change`, as native fields do;
//! - `textEditor` shows an `app.TextEditor` the app's state owns, and
//!   sends every keystroke, command and selection to the app as
//!   `app.TextInput` for `update` to apply (`Update.editText`), so the app
//!   can set and clear the text itself. See `app.text_editor`.
//!
//! Both draw the caret and the selection as rectangles at the positions
//! the renderer's text measurement gives, scroll to keep the caret in
//! view, and, where the platform has an on-screen keyboard
//! (`Capabilities.keyboard`), ask for it when pressed (`Update.systemText`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Color = fabrum.Color;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const Ui = @import("ui.zig").Ui;
const native = @import("native.zig");
const Theme = native.Theme;
const message = @import("message.zig");
const Update = message.Update;
const Handler = message.Handler;
const Action = message.Action;
const input_api = @import("input.zig");
const Pointer = input_api.Pointer;
const KeyEvent = input_api.KeyEvent;
const Capabilities = @import("capabilities.zig").Capabilities;
const text_editor = @import("text_editor.zig");
const TextEditor = text_editor.TextEditor;
const TextInput = text_editor.TextInput;
const TextGeometry = text_editor.TextGeometry;
const runtime_api = @import("runtime.zig");
const app_platform = @import("platform.zig");
const segmentation = @import("segmentation.zig");
const widgets = @import("widgets.zig");

pub const ButtonOptions = widgets.ButtonOptions;
pub const CheckboxOptions = widgets.CheckboxOptions;
pub const ToggleOptions = widgets.ToggleOptions;
pub const SliderOptions = widgets.SliderOptions;
pub const TextFieldOptions = widgets.TextFieldOptions;
pub const TextAreaOptions = widgets.TextAreaOptions;
pub const ProgressOptions = widgets.ProgressOptions;
pub const ScrollViewOptions = widgets.ScrollViewOptions;
pub const DropdownOptions = widgets.DropdownOptions;
pub const RadioGroupOptions = widgets.RadioGroupOptions;
pub const StepperOptions = widgets.StepperOptions;
pub const LabelOptions = widgets.LabelOptions;
pub const SpinnerOptions = widgets.SpinnerOptions;

/// A push button: the accent color if it is the default button, the
/// control background otherwise.
pub fn button(ui: *Ui, key: anytype, options: ButtonOptions) !void {
    const theme = ui.use(Theme);
    const base = if (options.default) theme.accent else theme.control_background;
    const fill = if (!options.enabled) base.withAlpha(base.a / 2) else shade(ui, key, base);
    const text = if (!options.enabled) theme.secondary_text else if (options.default) buttonText(ui, theme) else theme.text;
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
    if (options.default and options.enabled and options.on_click != null) {
        try ui.core.default_buttons.append(ui.core.gpa, ui.id(key).id);
    }
    try ui.text(options.label, label_style(theme, text));
}

/// The text on an accent-filled button: white, or the background's color
/// on a grayscale display, where the accent is black.
fn buttonText(ui: *const Ui, theme: *const Theme) Color {
    return if (ui.capabilities().isGray()) theme.control_background else .white;
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
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(6) }, .background_color = if (options.enabled) buttonText(ui, theme) else theme.secondary_text, .corner_radius = .uniform(1) });
            ui.close();
        }
    }
    if (options.label.len > 0) try ui.text(options.label, label_style(theme, if (options.enabled) theme.text else theme.secondary_text));
}

/// A switch: a pill, in the accent color while on, with its knob at the
/// end it is switched to.
pub fn toggle(ui: *Ui, key: anytype, options: ToggleOptions) !void {
    const theme = ui.use(Theme);
    const gray = ui.capabilities().isGray();
    const track = if (options.on) theme.accent else if (gray) Color.gray(160) else Color.rgba(0, 0, 0, 40);
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

/// A horizontal slider. Pressing it moves the knob to where it was
/// pressed, dragging follows the pointer, and the arrow keys step it.
pub fn slider(ui: *Ui, key: anytype, options: SliderOptions) !void {
    try ui.child(Slider, key, options);
}

/// A drawn slider as a component: it turns where it was pressed or dragged
/// into a value for its `on_change`.
pub const Slider = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { pointer: Pointer, key: KeyEvent };
    pub const Props = SliderOptions;

    /// The track's inset on each side, so the knob stays inside.
    pub const inset = 8;

    pub fn update(_: *State, msg: Msg, ctx: *Update(Slider)) !void {
        const props = ctx.props.*;
        switch (msg) {
            .pointer => |p| switch (p.phase) {
                .press, .drag => {
                    const fraction = std.math.clamp((p.local.x - inset) / @max(p.size.x - 2 * inset, 1), 0, 1);
                    try ctx.emit(props.on_change, props.min + fraction * (props.max - props.min));
                },
                .release, .cancel, .long_press => {},
            },
            .key => |k| {
                // a hundredth of the range per arrow, a tenth with Shift
                const step = (props.max - props.min) * (if (k.modifiers.shift) @as(f64, 0.1) else 0.01);
                const value: ?f64 = switch (k.key) {
                    .left, .down => props.value - step,
                    .right, .up => props.value + step,
                    .home => props.min,
                    .end => props.max,
                    else => null,
                };
                if (value) |v| try ctx.emit(props.on_change, std.math.clamp(v, props.min, props.max));
            },
        }
    }

    pub fn view(ui: *Ui, _: *const State, props: Props) !void {
        const theme = ui.use(Theme);
        const range = props.max - props.min;
        const fraction: f32 = if (range > 0) @floatCast(std.math.clamp((props.value - props.min) / range, 0, 1)) else 0;
        var sizing = props.sizing;
        if (sizing.height.mode == .fit) sizing.height = .fixed(20);
        const live = props.enabled and props.on_change != null;
        try ui.open("slider", .{
            .layout = .{ .sizing = sizing, .padding = .init(inset, inset, 0, 0), .child_alignment = .center_left },
            .on_pointer = if (live) ui.messages(Slider).handler(.pointer) else null,
            .focusable = props.enabled and theme.full_keyboard_access,
            .focus = if (live and theme.full_keyboard_access) .{ .on_key = ui.messages(Slider).handler(.key), .keys = .navigation_only } else null,
        });
        defer ui.close();
        try ui.open(null, .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(4) } },
            .background_color = if (ui.capabilities().isGray()) .gray(160) else .rgba(0, 0, 0, 40),
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

/// A single-line text field that keeps its editor inside and reports its
/// text after each edit (`on_change`) and on Enter (`on_submit`), as the
/// native one does. Pressing it focuses it; typing, the arrow keys, the
/// keymap's commands, selection by pointer and the clipboard all work.
pub fn textField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    try singleLineBox(ui, key, options, .plain);
}

/// A single-line `TextBox` with `look`.
fn singleLineBox(ui: *Ui, key: anytype, options: TextFieldOptions, look: TextBox.Look) !void {
    try ui.child(TextBox, key, .{
        .text = options.text,
        .placeholder = options.placeholder,
        .on_change = options.on_change,
        .on_submit = options.on_submit,
        .enabled = options.enabled,
        .single_line = true,
        .sizing = options.sizing,
        .look = look,
    });
}

/// A multi-line text area that keeps its editor inside, wraps its text,
/// scrolls inside its height, and reports its text after each edit.
pub fn textArea(ui: *Ui, key: anytype, options: TextAreaOptions) !void {
    try ui.child(TextBox, key, .{
        .text = options.text,
        .placeholder = options.placeholder,
        .on_change = options.on_change,
        .enabled = options.enabled,
        .single_line = false,
        .sizing = options.sizing,
    });
}

/// A single-line field with a search look: a magnifier before the text,
/// and a clear button while there is some. Edits as `textField` does.
pub fn searchField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    try singleLineBox(ui, key, options, .search);
}

/// A single-line field that shows a bullet for each character typed, for
/// passwords. Edits as `textField` does; the text itself is never drawn.
pub fn secureField(ui: *Ui, key: anytype, options: TextFieldOptions) !void {
    try singleLineBox(ui, key, options, .secure);
}

/// How `textEditor` shows an editor the app owns.
pub const TextEditorOptions = struct {
    /// Gets every keystroke, command and selection, for `update` to apply
    /// to the editor (`Update.editText`).
    on_input: Handler(TextInput),
    placeholder: []const u8 = "",
    enabled: bool = true,
    /// One line: Enter submits (`TextEditor.Outcome.submitted`), the
    /// text never wraps, and it scrolls sideways to the caret.
    single_line: bool = false,
    /// The field's own size; a multi-line field with a bounded height
    /// scrolls inside it.
    sizing: layout.Sizing = .{ .width = .grow(.{}) },
    /// The text's style, or the theme's.
    style: ?layout.text.Style = null,
};

/// A text field or area showing `editor`, which the app's state owns and
/// changes in `update` with what `on_input` sends it.
pub fn textEditor(ui: *Ui, key: anytype, editor: *const TextEditor, options: TextEditorOptions) !void {
    try ui.child(TextBox, key, .{
        .editor = editor,
        .on_input = options.on_input,
        .placeholder = options.placeholder,
        .enabled = options.enabled,
        .single_line = options.single_line,
        .sizing = options.sizing,
        .style = options.style,
    });
}

/// The drawn text widgets as one component: a field or area, showing the
/// app's editor or one of its own.
pub const TextBox = struct {
    pub const State = struct {
        /// The editor kept inside, when the app gives none.
        own: TextEditor = .{},
        /// The text last reported to or given by the app, for the
        /// controlled rule: `text` is written into the editor only when
        /// it differs.
        shown: std.ArrayList(u8) = .empty,
        /// Where the press that started a pointer selection landed.
        anchor: usize = 0,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.own.deinit(gpa);
            self.shown.deinit(gpa);
        }
    };

    pub const Msg = union(enum) {
        input: TextInput,
        pointer: Pointer,
        pasted: ?[]const u8,
        /// The system keyboard's result.
        system_text: ?[]const u8,
        /// The search field's clear button.
        clear,
    };

    pub const Props = struct {
        editor: ?*const TextEditor = null,
        on_input: ?Handler(TextInput) = null,
        text: []const u8 = "",
        placeholder: []const u8 = "",
        on_change: ?Handler([]const u8) = null,
        on_submit: ?Action = null,
        enabled: bool = true,
        single_line: bool = true,
        sizing: layout.Sizing = .{ .width = .grow(.{}) },
        style: ?layout.text.Style = null,
        /// A plain field, a search field (a magnifier and a clear button)
        /// or a secure one (bullets for the text).
        look: Look = .plain,
    };

    pub const Look = enum { plain, search, secure };

    /// What a secure field shows for each grapheme.
    pub const bullet = "\u{2022}";

    const field_key = "field";
    const clear_key = "clear";

    fn options(props: Props) TextEditor.Options {
        return .{ .single_line = props.single_line };
    }

    pub fn update(state: *State, msg: Msg, ctx: *Update(TextBox)) !void {
        const props = ctx.props.*;
        switch (msg) {
            .input => |input| try apply(state, input, ctx),
            .pasted => |text| if (text) |t| try apply(state, .{ .paste = t }, ctx),
            .system_text => |text| if (text) |t| try apply(state, .{ .set = t }, ctx),
            .clear => try apply(state, .{ .set = "" }, ctx),
            .pointer => |p| {
                const geometry = ctx.core.textGeometry(ctx.element(field_key).id) orelse return;
                const info = ctx.core.scrolls.get(ctx.element(field_key).id) orelse return;
                const pad = fieldPadding(ctx.use(Theme), props.look);
                const point: Vec2 = .init(p.local.x - pad.left + info.offset.x, p.local.y - pad.top + info.offset.y);
                var hit = geometry.offsetAt(point);
                const editor = props.editor orelse &state.own;
                // the geometry is over the bullets: back to the text's offsets
                if (props.look == .secure) {
                    const current = try editor.displayText(ctx.core.arena.allocator());
                    hit.offset = unmaskedOffset(current, hit.offset);
                }
                hit.offset = editor.modelOffset(hit.offset);
                switch (p.phase) {
                    .press => {
                        state.anchor = hit.offset;
                        try apply(state, .{ .select = .{ .anchor = hit.offset, .head = hit.offset, .clicks = p.clicks } }, ctx);
                        if (ctx.use(Capabilities).keyboard == .on_screen) {
                            const current = if (props.editor) |e| e.text.items else state.own.text.items;
                            ctx.systemText(.{ .title = props.placeholder, .initial = current, .flags = .{ .multiline = !props.single_line, .password = props.look == .secure } }, ctx.handler(.system_text)) catch |err| switch (err) {
                                error.Unsupported => {},
                                else => return err,
                            };
                        }
                    },
                    .drag => try apply(state, .{ .select = .{ .anchor = state.anchor, .head = hit.offset, .clicks = p.clicks } }, ctx),
                    .release, .cancel, .long_press => {},
                }
            },
        }
    }

    /// Applies `input` to the editor inside, reporting the text, or sends
    /// it to the app's.
    fn apply(state: *State, input: TextInput, ctx: *Update(TextBox)) !void {
        const props = ctx.props.*;
        // the app's editor: the input goes on, its text copied, since
        // this message's may be freed before the app's is delivered
        if (props.on_input) |h| return ctx.core.sendText(ctx.element(field_key).id, h, input);
        const outcome = try ctx.editText(&state.own, input, options(props), ctx.handler(.pasted));
        if (outcome.changed) {
            state.shown.clearRetainingCapacity();
            try state.shown.appendSlice(ctx.gpa, state.own.text.items);
            try ctx.emitText(props.on_change, state.own.text.items);
        }
        if (outcome.submitted) try ctx.emit(props.on_submit, {});
    }

    fn fieldPadding(theme: *const Theme, look: Look) layout.Padding {
        // room for the magnifier, and for the clear button
        const left: f32 = if (look == .search) 6 + 14 + 4 else 6;
        const right: f32 = if (look == .search) 6 + 14 + 4 else 6;
        return .init(left, right, padding(theme), padding(theme));
    }

    /// The offset in the bullets shown for `text` that stands for byte
    /// `offset` of it: one bullet per grapheme.
    fn maskedOffset(text: []const u8, offset: usize) usize {
        var graphemes: usize = 0;
        var at: usize = 0;
        while (at < offset and at < text.len) : (graphemes += 1) at = segmentation.nextGrapheme(text, at);
        return graphemes * bullet.len;
    }

    /// The byte offset of `text` that bullet offset `masked` stands for.
    fn unmaskedOffset(text: []const u8, masked_offset: usize) usize {
        var graphemes = (masked_offset + bullet.len / 2) / bullet.len;
        var at: usize = 0;
        while (graphemes > 0 and at < text.len) : (graphemes -= 1) at = segmentation.nextGrapheme(text, at);
        return at;
    }

    /// A bullet for each grapheme of `text`, in the frame arena.
    fn masked(ui: *Ui, text: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (at < text.len) : (at = segmentation.nextGrapheme(text, at)) try out.appendSlice(ui.arena(), bullet);
        return out.items;
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        const theme = ui.use(Theme);
        const caps = ui.use(Capabilities);
        const on = ui.messages(TextBox);
        const gpa = ui.core.gpa;

        // the controlled rule: the app's text goes in only when it differs
        // from what the field last reported or was given
        const editor: *const TextEditor = props.editor orelse blk: {
            const own: *TextEditor = @constCast(&state.own);
            if (!std.mem.eql(u8, props.text, state.shown.items)) {
                try own.setText(gpa, props.text);
                const shown: *std.ArrayList(u8) = @constCast(&state.shown);
                shown.clearRetainingCapacity();
                try shown.appendSlice(gpa, props.text);
            }
            break :blk own;
        };
        // a secure field shows bullets, and measures them, so the caret,
        // the selection and hit-testing are over what is drawn
        const display = try editor.displayText(ui.arena());
        const text = if (props.look == .secure) try masked(ui, display) else display;
        const focused = ui.focused(field_key);
        const style = (props.style orelse label_style(theme, if (props.enabled) theme.text else theme.secondary_text)).with(.{ .wrap_mode = if (props.single_line) .none else .words });
        const pad = fieldPadding(theme, props.look);
        const line_height = style.font_size * style.line_height;
        const caret_offset = if (props.look == .secure) maskedOffset(display, editor.displayCaret()) else editor.displayCaret();
        const selection_start = if (props.look == .secure) maskedOffset(editor.text.items, editor.selection.start()) else editor.selection.start();
        const selection_end = if (props.look == .secure) maskedOffset(editor.text.items, editor.selection.end()) else editor.selection.end();

        // the visual lines at the last frame's width, for the caret, the
        // selection and hit-testing
        const info = ui.scrollInfo(field_key);
        const width: f32 = if (props.single_line) std.math.inf(f32) else if (info) |i| @max(i.viewport.x, 1) else std.math.inf(f32);
        const geometry = try ui.arena().create(TextGeometry);
        const measurer = try ui.arena().create(Measurer);
        measurer.* = .{ .core = ui.core, .style = style };
        geometry.* = .{
            .text = text,
            .lines = try ui.core.make_lines(ui.core, text, style, width),
            .measure = .{ .ctx = measurer, .width = Measurer.width },
            .page_height = if (info) |i| i.viewport.y else 0,
        };
        try ui.textGeometry(field_key, geometry);
        const caret = geometry.caretRect(caret_offset, editor.affinity, line_height);
        geometry.input_caret = caret;
        geometry.input_generation = &editor.generation;
        // keep the caret in view before the frame lays the field out
        if (focused) ui.core.revealInScroll(ui.id(field_key).id, .init(caret.x - 2, caret.y, caret.w + 4, caret.h));

        var sizing = props.sizing;
        if (props.single_line and sizing.height.mode == .fit) sizing.height = .fixed(line_height + pad.top + pad.bottom);
        try ui.open(field_key, .{
            .layout = .{ .sizing = sizing, .padding = pad, .axis = .y },
            .background_color = if (props.enabled) theme.control_background else theme.control_background.withAlpha(128),
            .corner_radius = .uniform(4),
            .border = if (ui.focusVisible(field_key)) .{ .color = theme.focus_ring.withAlpha(255), .widths = .outside(2) } else if (focused) .{ .color = theme.accent, .widths = .outside(1) } else .{ .color = theme.separator, .widths = .outside(1) },
            .scroll = .{ .x = props.single_line, .y = !props.single_line, .scrollbar = !props.single_line },
            .focus = if (props.enabled) .{ .on_text = on.handler(.input) } else null,
            .focus_on_press = props.enabled,
            .on_pointer = if (props.enabled) on.handler(.pointer) else null,
            .cursor = if (caps.pointer == .mouse) .text else null,
        });
        defer ui.close();
        // the decorations float over the field at content positions, which
        // the padding moves in and the scroll offset moves back
        const scrolled: Vec2 = if (ui.scrollInfo(field_key)) |i| i.offset else .zero;
        const origin: Vec2 = .init(pad.left - scrolled.x, pad.top - scrolled.y);
        // the selection under the text, the text, then the caret over it
        if (focused and !editor.composing() and !editor.selection.isEmpty()) {
            var rects: [64]Rect = undefined;
            const n = geometry.selectionRects(selection_start, selection_end, &rects);
            const color = if (caps.isGray()) Color.gray(200) else theme.accent.withAlpha(70);
            for (rects[0..n]) |r| {
                try ui.open(null, .{
                    .layout = .{ .sizing = .fixedXY(r.w, r.h) },
                    .floating = .{ .mode = .parent, .offset = origin.add(.init(r.x, r.y)) },
                    .background_color = color,
                });
                ui.close();
            }
        }
        {
            // the text wraps at the field's inner width, which the box
            // fills; the caret and selection above use the same width as
            // of the last frame
            const inner_width: layout.Sizing.Dimension = if (props.single_line) .fit(.{}) else .grow(.{});
            try ui.open(null, .{ .layout = .{ .sizing = .{ .width = inner_width }, .axis = .y } });
            defer ui.close();
            if (text.len > 0) {
                try ui.text(text, style);
            } else {
                // an empty line's height
                try ui.open(null, .{ .layout = .{ .sizing = .{ .height = .fixed(line_height) } } });
                ui.close();
            }
        }
        if (text.len == 0 and props.placeholder.len > 0) {
            try ui.open(null, .{ .floating = .{ .mode = .parent, .offset = origin } });
            defer ui.close();
            try ui.text(props.placeholder, style.with(.{ .color = theme.secondary_text }));
        }
        if (editor.preedit) |preedit| {
            const start = editor.selection.start();
            const end = start + preedit.text.items.len;
            const visual_start = if (props.look == .secure) maskedOffset(display, start) else start;
            const visual_end = if (props.look == .secure) maskedOffset(display, end) else end;
            var rects: [64]Rect = undefined;
            const n = geometry.selectionRects(visual_start, visual_end, &rects);
            for (rects[0..n]) |r| {
                try ui.open(null, .{
                    .layout = .{ .sizing = .fixedXY(r.w, 1) },
                    .floating = .{ .mode = .parent, .offset = origin.add(.init(r.x, r.y + r.h - 1)) },
                    .background_color = theme.text,
                });
                ui.close();
            }
        }
        if (focused and ui.caretVisible(field_key)) {
            try ui.open(null, .{
                .layout = .{ .sizing = .fixedXY(if (caps.isGray()) 2 else 1, caret.h) },
                .floating = .{ .mode = .parent, .offset = origin.add(.init(caret.x, caret.y)) },
                .background_color = theme.text,
            });
            ui.close();
        }
        if (props.look == .search) {
            // a magnifier at the left edge: a ring with a handle
            const dim = theme.secondary_text;
            try ui.open(null, .{
                .layout = .{ .sizing = .fixed(10) },
                .floating = .{ .mode = .parent, .offset = .init(7, (line_height - 14) / 2 + pad.top + 1) },
                .corner_radius = .uniform(5),
                .border = .{ .color = dim, .widths = .outside(2) },
            });
            ui.close();
            try ui.open(null, .{
                .layout = .{ .sizing = .fixedXY(5, 2) },
                .floating = .{ .mode = .parent, .offset = .init(15, (line_height - 14) / 2 + pad.top + 10) },
                .background_color = dim,
            });
            ui.close();
            // a clear button at the right edge while there is text
            if (editor.text.items.len > 0 and props.enabled) {
                try ui.open(clear_key, .{
                    .layout = .{ .sizing = .fixed(14), .child_alignment = .center },
                    .floating = .{ .mode = .parent, .parent_point = .right_center, .unit_point = .right_center, .offset = .init(-6, 0) },
                    .background_color = shade(ui, clear_key, dim),
                    .corner_radius = .uniform(7),
                    .on_click = on.bind(.clear),
                });
                defer ui.close();
                try ui.text("\u{00d7}", label_style(theme, theme.control_background).with(.{ .font_size = 11 }));
            }
        }
    }

    /// Measures prefixes of a line with the runtime's text context, for
    /// the geometry.
    const Measurer = struct {
        core: *runtime_api.Core,
        style: layout.text.Style,

        fn width(ctx: *const anyopaque, s: []const u8) f32 {
            const self: *const Measurer = @ptrCast(@alignCast(ctx));
            return self.core.measure_width(self.core, s, self.style);
        }
    };
};

/// A progress bar, filled to its value, or with a sliding segment while
/// the value is unknown, which animates where the platform does.
pub fn progressBar(ui: *Ui, key: anytype, options: ProgressOptions) !void {
    const theme = ui.use(Theme);
    var sizing = options.sizing;
    if (sizing.height.mode == .fit) sizing.height = .fixed(6);
    try ui.open(key, .{
        .layout = .{ .sizing = sizing },
        .background_color = if (ui.capabilities().isGray()) .gray(200) else .rgba(0, 0, 0, 30),
        .corner_radius = .uniform(3),
        .clip = .{ .horizontal = true },
    });
    defer ui.close();
    const segment: f32 = 0.3;
    const start: f32, const width: f32 = if (options.value) |value|
        .{ 0, @floatCast(std.math.clamp(value, 0, 1)) }
    else if (!ui.capabilities().animates())
        // still: a segment in the middle
        .{ (1 - segment) / 2, segment }
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

/// Activity without progress: dots around a circle, the leading one in
/// the accent color, turning once a second where the platform animates.
pub fn spinner(ui: *Ui, key: anytype, options: SpinnerOptions) !void {
    const theme = ui.use(Theme);
    const side: f32 = if (options.size == .small) 16 else 32;
    const dot: f32 = if (options.size == .small) 3 else 5;
    var sizing = options.sizing;
    if (sizing.width.mode == .fit) sizing.width = .fixed(side);
    if (sizing.height.mode == .fit) sizing.height = .fixed(side);
    const dots = 8;
    const lead: usize = if (ui.capabilities().animates()) phase: {
        ui.animate();
        const ns_per_turn = std.time.ns_per_s;
        break :phase @intCast(@divFloor(@mod(ui.now().nanoseconds, ns_per_turn) * dots, ns_per_turn));
    } else 0;
    try ui.open(key, .{ .layout = .{ .sizing = sizing } });
    defer ui.close();
    const radius = side / 2 - dot / 2;
    for (0..dots) |i| {
        const angle = @as(f32, @floatFromInt(i)) / dots * std.math.tau;
        const behind = (i + dots - lead) % dots;
        const alpha: u8 = @intFromFloat(255 * (1 - @as(f32, @floatFromInt(behind)) / dots));
        const color = if (ui.capabilities().isGray()) (if (behind < dots / 2) Color.black else Color.gray(160)) else if (behind == 0) theme.accent else theme.secondary_text.withAlpha(@max(alpha, 40));
        try ui.open(null, .{
            .layout = .{ .sizing = .fixed(dot) },
            .floating = .{ .mode = .parent, .offset = .init(side / 2 - dot / 2 + radius * @sin(angle), side / 2 - dot / 2 - radius * @cos(angle)) },
            .background_color = color,
            .corner_radius = .uniform(dot / 2),
        });
        ui.close();
    }
}

/// Text in the theme's font, wrapping within its box unless asked not to,
/// as the platform's own label would show it. `selectable` is not implemented.
pub fn label(ui: *Ui, key: anytype, options: LabelOptions) !void {
    const theme = ui.use(Theme);
    try ui.open(key, .{ .layout = .{ .sizing = options.sizing } });
    defer ui.close();
    try ui.text(options.text, .{
        .font_size = options.font_size orelse theme.font_size,
        .color = if (options.secondary) theme.secondary_text else theme.text,
        .wrap_mode = if (options.wrap) .words else .none,
        .overflow = if (options.wrap) .visible else .ellipsis_end,
    });
}

/// Radio buttons in a column (or a row), of which one is on. A click
/// fires `on_select` with the button's index; with full keyboard access
/// each joins the Tab order and Space turns it on.
pub fn radioGroup(ui: *Ui, key: anytype, options: RadioGroupOptions) !void {
    const theme = ui.use(Theme);
    try ui.open(key, .{ .layout = .{ .sizing = options.sizing, .axis = if (options.horizontal) .x else .y, .child_gap = if (options.horizontal) 12 else 4 } });
    defer ui.close();
    for (options.items, 0..) |item, i| {
        const item_key: RadioKey = .{ .group = ui.id(key).id, .index = i };
        const on = options.selected == i;
        const color = if (!options.enabled) theme.secondary_text else if (on) theme.accent else theme.secondary_text;
        try ui.open(item_key, .{
            .layout = .{ .child_gap = 6, .child_alignment = .center_left, .padding = .init(2, 2, 1, 1) },
            .corner_radius = .uniform(4),
            .border = ring(ui, item_key, theme, .transparent),
            .on_click = if (options.enabled) if (options.on_select) |h| h.with(i) else null else null,
            .focusable = options.enabled and theme.full_keyboard_access,
        });
        defer ui.close();
        {
            try ui.open(null, .{
                .layout = .{ .sizing = .fixed(14), .child_alignment = .center },
                .corner_radius = .uniform(7),
                .background_color = if (on and options.enabled) shade(ui, item_key, theme.accent) else theme.control_background,
                .border = .{ .color = if (on) .transparent else color, .widths = .outside(1) },
            });
            defer ui.close();
            if (on) {
                try ui.open(null, .{ .layout = .{ .sizing = .fixed(5) }, .background_color = if (options.enabled) buttonText(ui, theme) else theme.secondary_text, .corner_radius = .uniform(2.5) });
                ui.close();
            }
        }
        try ui.text(item, label_style(theme, if (options.enabled) theme.text else theme.secondary_text));
    }
}

/// The key of one button of a drawn radio group.
pub const RadioKey = struct { group: u64, index: usize };

/// A value with buttons that step it down and up, within its range, and a
/// field that shows it.
pub fn stepper(ui: *Ui, key: anytype, options: StepperOptions) !void {
    const theme = ui.use(Theme);
    const down: StepKey = .{ .stepper = ui.id(key).id, .up = false };
    const up: StepKey = .{ .stepper = ui.id(key).id, .up = true };
    const can_down = options.enabled and options.value > options.min;
    const can_up = options.enabled and options.value < options.max;
    const pad = padding(theme);
    try ui.open(key, .{ .layout = .{ .sizing = options.sizing, .child_gap = 4, .child_alignment = .center_left } });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .fixed(60) }, .padding = .init(6, 6, pad, pad), .child_alignment = .center_right },
        .background_color = if (options.enabled) theme.control_background else theme.control_background.withAlpha(128),
        .corner_radius = .uniform(4),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
    });
    try ui.print(label_style(theme, if (options.enabled) theme.text else theme.secondary_text), "{d}", .{options.value});
    ui.close();
    for ([_]StepKey{ down, up }, [_]bool{ can_down, can_up }, [_][]const u8{ "\u{2212}", "+" }) |step_key, live, glyph| {
        const target = std.math.clamp(options.value + (if (step_key.up) options.step else -options.step), options.min, options.max);
        try ui.open(step_key, .{
            .layout = .{ .sizing = .fixedXY(22, theme.control_height), .child_alignment = .center },
            .background_color = if (live) shade(ui, step_key, theme.control_background) else theme.control_background.withAlpha(128),
            .corner_radius = .uniform(4),
            .border = ring(ui, step_key, theme, theme.separator),
            .on_click = if (live) if (options.on_change) |h| h.with(target) else null else null,
            .focusable = live and theme.full_keyboard_access,
        });
        defer ui.close();
        try ui.text(glyph, label_style(theme, if (live) theme.text else theme.secondary_text));
    }
}

/// The key of a drawn stepper's down or up button.
pub const StepKey = struct { stepper: u64, up: bool };

/// One of a list of items, chosen from a popup the button opens.
pub fn dropdown(ui: *Ui, key: anytype, options: DropdownOptions) !void {
    try ui.child(Dropdown, key, options);
}

/// A drawn dropdown as a component: a button showing the chosen item,
/// which opens a popup menu of the items (the host's own, or the one the
/// runtime draws, through `Update.menu`); choosing one fires `on_select`.
pub const Dropdown = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { open, chosen: ?usize };
    pub const Props = DropdownOptions;

    pub const button_key = "button";

    pub fn update(_: *State, msg: Msg, ctx: *Update(Dropdown)) !void {
        const props = ctx.props.*;
        switch (msg) {
            .open => {
                // under the button, as laid out last frame
                const at: Vec2 = if (ctx.core.context.getUnitById(ctx.element(button_key))) |unit| .init(unit.bbox.x, unit.bbox.y + unit.bbox.h + 2) else .zero;
                var items: std.ArrayList(app_platform.MenuItem) = .empty;
                defer items.deinit(ctx.gpa);
                for (props.items, 0..) |item, i| try items.append(ctx.gpa, .{ .title = item, .id = i });
                try ctx.menu(.{ .items = items.items, .at = at }, ctx.handler(.chosen));
            },
            .chosen => |id| if (id) |index| try ctx.emit(props.on_select, index),
        }
    }

    pub fn view(ui: *Ui, _: *const State, props: Props) !void {
        const theme = ui.use(Theme);
        const on = ui.messages(Dropdown);
        const text_color = if (props.enabled) theme.text else theme.secondary_text;
        const pad = padding(theme);
        var sizing = props.sizing;
        if (sizing.height.mode == .fit) sizing.height = .fixed(theme.control_height);
        try ui.open(button_key, .{
            .layout = .{ .sizing = sizing, .padding = .init(10, 6, pad, pad), .child_gap = 8, .child_alignment = .center_left },
            .background_color = if (props.enabled) shade(ui, button_key, theme.control_background) else theme.control_background.withAlpha(128),
            .corner_radius = .uniform(5),
            .border = ring(ui, button_key, theme, theme.separator),
            .on_click = if (props.enabled) on.bind(.open) else null,
            .focusable = props.enabled and theme.full_keyboard_access,
        });
        defer ui.close();
        const shown = if (props.selected) |i| (if (i < props.items.len) props.items[i] else "") else "";
        try ui.text(shown, label_style(theme, text_color));
        ui.spacer();
        // the arrows in a small accent box, as macOS draws them
        try ui.open(null, .{
            .layout = .{ .sizing = .fixedXY(16, 16), .child_alignment = .center },
            .background_color = if (props.enabled) theme.accent else theme.secondary_text,
            .corner_radius = .uniform(4),
        });
        try ui.text("\u{2195}", label_style(theme, buttonText(ui, theme)).with(.{ .font_size = 10 }));
        ui.close();
    }
};

pub const AlertOptions = @import("dialogs.zig").AlertOptions;

/// A modal alert over everything declared before it, with its buttons in a
/// row, the first being the default. Declare it last, so that it is on
/// top.
pub fn alert(ui: *Ui, key: anytype, options: AlertOptions) !void {
    try modalBox(ui, key, options.title, options.message, options.buttons, 0, options.on_response, null);
}

/// A modal box with a title, a message and buttons: `on_response` gets a
/// button's index, or `on_answer` gets it as an optional. The backdrop
/// takes focus; unconsumed Enter presses the default and Escape dismisses
/// (`on_answer` with null).
fn modalBox(ui: *Ui, key: anytype, title: []const u8, text: []const u8, buttons: []const []const u8, default: usize, on_response: ?Handler(usize), on_answer: ?Handler(?usize)) !void {
    const theme = ui.use(Theme);
    if (on_answer) |h| try ui.shortcut(.{ .key = .escape }, h.with(null));
    try ui.open(key, .{
        .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
        .floating = .{ .mode = .root },
        .background_color = if (ui.capabilities().isGray()) .transparent else .rgba(0, 0, 0, 60),
        .modal = true,
        // keys reach the dialog's shortcuts while nothing else in it has focus
        .focus = .{ .keys = .none },
    });
    defer ui.close();
    try ui.open(null, .{
        .layout = .{ .sizing = .{ .width = .fixed(300) }, .axis = .y, .padding = .all(20), .child_gap = 12 },
        .background_color = theme.control_background,
        .corner_radius = .uniform(10),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
    });
    defer ui.close();
    if (title.len > 0) try ui.text(title, label_style(theme, theme.text).with(.{ .font_size = theme.font_size + 2, .font_weight = .bold }));
    if (text.len > 0) try ui.text(text, label_style(theme, theme.secondary_text).with(.{ .wrap_mode = .words }));
    try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}) }, .child_gap = 8, .child_alignment = .center_right } });
    defer ui.close();
    for (buttons, 0..) |button_title, i| {
        const action: ?Action = if (on_response) |h| h.with(i) else if (on_answer) |h| h.with(@as(?usize, i)) else null;
        try button(ui, AlertButton{ .alert = ui.id(key).id, .index = i }, .{
            .label = button_title,
            .default = i == default,
            .on_click = action,
        });
    }
}

/// The key of an alert's button: its alert's element ID and its index.
pub const AlertButton = struct { alert: u64, index: usize };

/// A dialog the runtime draws for a host without its own (`Update.confirm`
/// and `Update.message`): modal, answered by its buttons, or by Escape
/// with null.
pub fn dialogBox(ui: *Ui, key: anytype, dialog: runtime_api.Overlays.Pending.Dialog, on_answer: Handler(?usize)) !void {
    try modalBox(ui, key, dialog.title, dialog.text, dialog.buttons, dialog.default, null, on_answer);
}

/// The key of a drawn menu's item: its menu's element ID and the item's
/// position.
pub const MenuItemKey = struct { menu: u64, index: usize };

/// A popup menu the runtime draws for a host without its own
/// (`Update.menu`): items with headers, separators, disabled items and
/// submenus shown indented, at a point of the viewport, over a backdrop
/// that dismisses it. `on_ignore` takes the clicks on the menu's own
/// surface, so they don't reach the backdrop.
pub fn popupMenu(ui: *Ui, key: anytype, menu: runtime_api.Overlays.Pending.Menu, on_choose: Handler(?usize), on_ignore: Action) !void {
    const theme = ui.use(Theme);
    const dismiss = on_choose.with(null);
    try ui.shortcut(.{ .key = .escape }, dismiss);
    try ui.open(key, .{
        .layout = .{ .sizing = .grow(.{}) },
        .floating = .{ .mode = .root },
        .on_click = dismiss,
        .modal = true,
        .focus = .{ .keys = .none },
    });
    defer ui.close();
    const menu_id = ui.id(key).id;
    try ui.open(MenuItemKey{ .menu = menu_id, .index = std.math.maxInt(usize) }, .{
        .layout = .{ .axis = .y, .padding = .all(4), .child_gap = 1, .sizing = .{ .width = .fit(.{ .min = 160 }) } },
        .floating = .{ .mode = .parent, .offset = menu.at },
        .background_color = theme.control_background,
        .corner_radius = .uniform(6),
        .border = .{ .color = theme.separator, .widths = .outside(1) },
        .on_click = on_ignore,
    });
    defer ui.close();
    for (menu.items, 0..) |item, i| {
        const item_key: MenuItemKey = .{ .menu = menu_id, .index = i };
        const indent: f32 = 10 + 14 * @as(f32, @floatFromInt(item.depth));
        switch (item.kind) {
            .separator => {
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(1) }, .padding = .init(0, 0, 3, 3) } });
                defer ui.close();
                try ui.open(null, .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(1) } }, .background_color = theme.separator });
                ui.close();
            },
            .header, .submenu => {
                try ui.open(null, .{ .layout = .{ .padding = .init(indent, 10, 4, 4), .sizing = .{ .width = .grow(.{}) } } });
                defer ui.close();
                try ui.text(item.title, label_style(theme, theme.secondary_text).with(.{ .font_weight = .bold }));
            },
            .item => {
                const selectable = item.enabled;
                try ui.open(item_key, .{
                    .layout = .{ .padding = .init(indent, 10, 4, 4), .sizing = .{ .width = .grow(.{}) } },
                    .background_color = if (selectable and ui.hovered(item_key) and ui.capabilities().hover) theme.accent.withAlpha(if (ui.capabilities().isGray()) 255 else 40) else .transparent,
                    .corner_radius = .uniform(4),
                    .on_click = if (selectable) on_choose.with(@as(?usize, item.id)) else null,
                    .focusable = selectable,
                });
                defer ui.close();
                try ui.text(item.title, label_style(theme, if (selectable) theme.text else theme.secondary_text));
            },
        }
    }
}

/// Opens a container that scrolls its content along the axes asked for,
/// with the offset kept by the runtime (`app.Scroll`): the wheel scrolls
/// it, a drag of its scrollbar too, and `Update.scrollTo` moves it.
/// Close it with `ui.close`.
pub fn scrollView(ui: *Ui, key: anytype, options: ScrollViewOptions) !void {
    var content = options.content;
    content.sizing = options.sizing;
    try ui.open(key, .{
        .layout = content,
        .scroll = .{ .x = options.horizontal, .y = options.vertical, .on_scroll = options.on_scroll },
    });
}

/// The vertical padding that makes a control of one line of text as tall
/// as the platform's controls.
fn padding(theme: *const Theme) f32 {
    return @max((theme.control_height - theme.font_size * 1.2) / 2, 2);
}

fn label_style(theme: *const Theme, color: Color) layout.text.Style {
    return .{ .font_size = theme.font_size, .color = color, .wrap_mode = .none };
}

/// `color` lightened under the pointer, where the platform has one that
/// hovers, and darkened while pressed.
fn shade(ui: *const Ui, key: anytype, color: Color) Color {
    if (ui.pressed(key)) return mix(color, .black, 0.12);
    if (ui.capabilities().hover and ui.hovered(key)) return mix(color, .white, 0.12);
    return color;
}

/// The border of a control: the focus ring while focused by the keyboard,
/// else `normal`.
fn ring(ui: *const Ui, key: anytype, theme: *const Theme, normal: Color) layout.ContainerDeclaration.BorderConfig {
    if (ui.focusVisible(key)) return .{ .color = theme.focus_ring.withAlpha(255), .widths = .outside(2) };
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
        name: std.ArrayList(u8) = .empty,
        notes: std.ArrayList(u8) = .empty,
        submitted: usize = 0,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.name.deinit(gpa);
            self.notes.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { click, agree: bool, loud: bool, volume: f64, ask, answered: usize, name: []const u8, notes: []const u8, submit, clear };
    pub const Props = struct { busy: bool = false };

    pub fn update(state: *State, msg: Msg, ctx: *Update(Form)) !void {
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
            .name => |text| {
                state.name.clearRetainingCapacity();
                try state.name.appendSlice(ctx.gpa, text);
            },
            .notes => |text| {
                state.notes.clearRetainingCapacity();
                try state.notes.appendSlice(ctx.gpa, text);
            },
            .submit => state.submitted += 1,
            .clear => state.name.clearRetainingCapacity(),
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
        try widgets.textField(ui, "name", .{ .text = state.name.items, .placeholder = "Name", .on_change = on.handler(.name), .on_submit = on.bind(.submit) });
        try widgets.textArea(ui, "notes", .{ .text = state.notes.items, .placeholder = "Notes", .on_change = on.handler(.notes), .sizing = .{ .width = .grow(.{}), .height = .fixed(60) } });
        try widgets.button(ui, "clear", .{ .label = "Clear", .on_click = on.bind(.clear) });
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

fn sliderTrack(h: *Harness) Rect {
    return h.findElement(h.root().child(Slider, "volume").element("slider")).?.bbox;
}

test "a drawn slider jumps to where it is pressed, and follows a drag" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const track = sliderTrack(&h);
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

    // a drag from a quarter to a half, in steps, leaving the track on the way
    const y = track.y + track.h / 2;
    const quarter = track.x + Slider.inset + (track.w - 2 * Slider.inset) * 0.25;
    const half = track.x + Slider.inset + (track.w - 2 * Slider.inset) * 0.5;
    try h.drag(.init(quarter, y), .init(half, y + 40), 4);
    try testing.expectApproxEqAbs(0.5, h.state().volume, 0.001);
    // the arrow keys step it while it is focused
    h.runtime.focusMove(.next);
    try h.frame();
}

test "a drawn text field edits, reports its text, and submits on Enter" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const name = h.root().child(TextBox, "name").element("field");
    try h.clickElement(name);
    try h.expectFocused(name);
    try h.type_("Ada");
    try testing.expectEqualStrings("Ada", h.state().name.items);
    // the model's text is what the field shows
    try h.expectText("Ada");
    try h.press(.left, .{});
    try h.type_("d");
    try testing.expectEqualStrings("Adda", h.state().name.items);
    try h.press(.backspace, .{});
    try h.press(.enter, .{});
    try testing.expectEqual(1, h.state().submitted);
    try testing.expectEqualStrings("Ada", h.state().name.items);
    // the model clearing the text clears the field, and the caret with it
    try h.click("Clear");
    try h.expectNoText("Ada");
    try h.expectText("Name");
    try h.clickElement(name);
    try h.type_("x");
    try testing.expectEqualStrings("x", h.state().name.items);
    // Escape gives focus back
    try testing.expect(try h.pressKey(.escape, .{}));
    try testing.expectEqual(null, h.runtime.focused());
}

test "a drawn text area wraps, scrolls to the caret, and takes a pointer selection" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const notes = h.root().child(TextBox, "notes").element("field");
    try h.clickElement(notes);
    for (0..12) |_| try h.type_("word of a long note ");
    try testing.expect(std.mem.startsWith(u8, h.state().notes.items, "word of a long note word"));
    // wrapped into several lines, and scrolled so the caret is in view
    const info = h.scrollInfo(notes).?;
    try testing.expect(info.content.y > info.viewport.y);
    try testing.expect(info.offset.y > 0);
    // Home then a shift-click selects from the line's start
    try h.press(.home, .{});
    const box = h.findElement(notes).?.bbox;
    try h.drag(.init(box.x + 8, box.y + 8), .init(box.x + 60, box.y + 8), 3);
    const editor = &h.runtime.rootState(Form).?.notes;
    _ = editor;
    const field_state = h.runtime.core.instances.get(h.root().child(TextBox, "notes").id).?;
    const storage: *runtime_api.Storage(TextBox) = @alignCast(@fieldParentPtr("instance", field_state));
    try testing.expect(!storage.state.own.selection.isEmpty());
    // Enter inserts a line in a multi-line field
    try h.press(.end, .{});
    try h.press(.enter, .{});
    try testing.expect(std.mem.indexOfScalar(u8, h.state().notes.items, '\n') != null);
}

test "an indeterminate drawn progress bar animates, except where the platform doesn't" {
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

    var still: Harness = try .init(.{ .busy = true }, .{ .viewport = .init(300, 400), .widgets = .drawn, .capabilities = .{ .animation = .none } });
    defer still.deinit();
    try still.frame();
    try testing.expectEqual(null, still.runtime.nextFrame());
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

test "without hover, drawn buttons don't shade under the pointer" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 400), .widgets = .drawn, .capabilities = .{ .pointer = .touch, .hover = false } });
    defer h.deinit();
    try h.frame();
    const idle = h.findElement(h.root().element("ask")).?.data.container.background_color;
    try h.hover("Ask");
    try testing.expectEqual(idle, h.findElement(h.root().element("ask")).?.data.container.background_color);
}

test "drawn defaults take window-wide Return after focused controls" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 400), .widgets = .drawn, .theme = .{ .full_keyboard_access = true } });
    defer h.deinit();
    try h.frame();
    try testing.expectEqual(null, h.runtime.focused());
    try h.press(.enter, .{});
    try testing.expect(h.state().asking);
    // The dialog default wins over the window default.
    try h.press(.enter, .{});
    try testing.expect(!h.state().asking);
    try testing.expectEqual(@as(?usize, 0), h.state().answer);
    // A focused button takes Return before the default.
    h.state().agree = true;
    try h.frame();
    const send = h.root().element("send");
    try h.tab();
    try h.expectFocused(send);
    try h.press(.enter, .{});
    try testing.expectEqual(1, h.state().clicks);
    try testing.expect(!h.state().asking);
    // A multiline field consumes Return as a newline.
    try h.clickElement(h.root().child(TextBox, "notes").element("field"));
    try h.press(.enter, .{});
    try testing.expectEqualStrings("\n", h.state().notes.items);
    try testing.expect(!h.state().asking);
    // A dialog's focused nondefault button keeps its own action.
    h.state().asking = true;
    try h.frame();
    try h.tab();
    try h.tab();
    try h.press(.enter, .{});
    try testing.expectEqual(@as(?usize, 1), h.state().answer);
    try testing.expect(!h.state().asking);
}

test "disabled and obscured drawn defaults do not handle Return" {
    const Window = struct {
        pub const State = struct { enabled: bool = false, modal: bool = false, clicks: usize = 0 };
        pub const Props = struct {};
        pub const Msg = union(enum) { clicked };
        pub fn update(state: *State, _: Msg, _: *Update(@This())) void {
            state.clicks += 1;
        }
        pub fn view(ui: *Ui, state: *const State, _: Props) !void {
            try button(ui, "default", .{ .label = "Default", .default = true, .enabled = state.enabled, .on_click = ui.messages(@This()).bind(.clicked) });
            if (state.modal) {
                try ui.open("modal", .{ .modal = true, .focus = .{ .keys = .none } });
                ui.close();
            }
        }
    };
    var h: app.testing.Harness(.{}, Window) = try .init(.{}, .{ .viewport = .init(100, 100), .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try testing.expect(!try h.pressKey(.enter, .{}));
    h.state().enabled = true;
    try h.frame();
    try testing.expect(!try h.pressKey(.enter, .{ .shift = true }));
    try h.hold(.enter, .{}, 3);
    try testing.expectEqual(1, h.state().clicks);
    h.state().modal = true;
    try h.frame();
    try testing.expect(!try h.pressKey(.enter, .{}));
    try testing.expectEqual(1, h.state().clicks);
}

test "drawn preedit displays a selected Unicode replacement and masks secure marks" {
    const PreeditForm = struct {
        pub const Props = struct { secure: bool = false };
        pub const State = struct {
            editor: TextEditor = .{},
            pub fn deinit(self: *@This(), gpa: Allocator) void {
                self.editor.deinit(gpa);
            }
        };
        pub const Msg = union(enum) { input: TextInput, pasted: ?[]const u8 };
        pub fn update(state: *State, msg: Msg, ctx: *Update(@This())) !void {
            switch (msg) {
                .input => |input| {
                    _ = try ctx.editText(&state.editor, input, .{ .single_line = true }, ctx.handler(.pasted));
                },
                .pasted => {},
            }
        }
        pub fn view(ui: *Ui, state: *const State, props: Props) !void {
            try ui.child(TextBox, "editor", .{ .editor = &state.editor, .on_input = ui.messages(@This()).handler(.input), .single_line = true, .look = if (props.secure) .secure else .plain });
            try ui.open("other", .{ .focusable = true });
            ui.close();
        }
    };
    var h: app.testing.Harness(.{}, PreeditForm) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    h.runtime.focusMove(.next);
    try testing.expect(try h.runtime.textInput(.{ .set = "A😀e\u{301}Z" }));
    try testing.expect(try h.runtime.textInput(.{ .select = .{ .anchor = 8, .head = 1 } }));
    try testing.expect(try h.runtime.textInput(.{ .preedit = .{ .text = "に😀", .cursor = .{ .start = 3, .end = 3 } } }));
    try h.frame();
    try h.expectText("Aに😀Z");
    try testing.expectEqualStrings("A😀e\u{301}Z", h.state().editor.text.items);
    const geometry = h.runtime.core.textGeometry(h.runtime.focused().?.unit).?;
    try testing.expect(geometry.input_caret != null);
    try testing.expectEqual(@as(usize, 1), h.state().editor.modelOffset(3));
    try testing.expectEqual(@as(usize, 8), h.state().editor.modelOffset(8));
    h.props.secure = true;
    try h.frame();
    try h.expectText("••••");
    try h.expectNoText("に😀");
    h.runtime.focusMove(.next);
    try h.frame();
    try testing.expect(!h.state().editor.composing());
    try testing.expectEqual(@as(usize, 8), h.state().editor.selection.anchor);
    try testing.expectEqual(@as(usize, 1), h.state().editor.selection.head);
}
