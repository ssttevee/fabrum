# Build forms and handle input

Start with `app.widgets` for controls that follow the host's toolkit. It
uses native controls when the runtime has a backend and calls `app.drawn`
otherwise. Call `app.drawn` directly when you need drawn controls even in a
toolkit app. Native controls bring toolkit text editing, accessibility and
platform behavior; drawn controls give your renderer control over their
pixels and work on a host with no native toolkit. Drawn text editing is
still partial, as described below. The
[widget reference](../app.md#the-widget-set) lists every option and default.

## Build a controlled settings form

Declare the displayed values from state and store each change reported by
a handler. This example includes every common widget. Several text fields
intentionally edit the same string so changes in one appear in the others;
a real form usually gives each field its own state.

```zig
const Settings = struct {
    pub const State = struct {
        text: std.ArrayList(u8) = .empty,
        enabled: bool = true,
        amount: f64 = 0.5,
        selected: usize = 0,
        saves: usize = 0,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.text.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { text: []const u8, enabled: bool, amount: f64, selected: usize, save };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Settings)) !void {
        switch (msg) {
            .text => |text| {
                const copy = try ctx.gpa.dupe(u8, text);
                state.text.deinit(ctx.gpa);
                state.text = .fromOwnedSlice(copy);
            },
            .enabled => |value| state.enabled = value,
            .amount => |value| state.amount = value,
            .selected => |value| state.selected = value,
            .save => state.saves += 1,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Settings);
        try widgets.scrollView(ui, "settings", .{ .content = .{ .axis = .y, .padding = .all(8), .child_gap = 6 } });
        defer ui.close();
        try widgets.label(ui, "title", .{ .text = "Settings", .wrap = true, .selectable = true });
        try widgets.checkbox(ui, "enabled", .{ .label = "Enable edits", .checked = state.enabled, .on_change = on.handler(.enabled) });
        try widgets.toggle(ui, "toggle", .{ .on = state.enabled, .on_change = on.handler(.enabled) });
        try widgets.slider(ui, "amount", .{ .value = state.amount, .on_change = on.handler(.amount), .enabled = state.enabled });
        try widgets.stepper(ui, "stepper", .{ .value = state.amount, .min = 0, .max = 1, .step = 0.1, .on_change = on.handler(.amount), .enabled = state.enabled });
        try widgets.textField(ui, "name", .{ .text = state.text.items, .placeholder = "Name", .on_change = on.handler(.text), .on_submit = on.bind(.save), .enabled = state.enabled });
        try widgets.searchField(ui, "search", .{ .text = state.text.items, .placeholder = "Search", .on_change = on.handler(.text), .enabled = state.enabled });
        try widgets.secureField(ui, "secret", .{ .text = state.text.items, .placeholder = "Password", .on_change = on.handler(.text), .enabled = state.enabled });
        try widgets.textArea(ui, "notes", .{ .text = state.text.items, .on_change = on.handler(.text), .enabled = state.enabled, .sizing = .fixedXY(240, 80) });
        try widgets.dropdown(ui, "choice", .{ .items = &.{ "Light", "Dark" }, .selected = state.selected, .on_select = on.handler(.selected), .enabled = state.enabled });
        try widgets.radioGroup(ui, "radio", .{ .items = &.{ "Light", "Dark" }, .selected = state.selected, .on_select = on.handler(.selected), .horizontal = true, .enabled = state.enabled });
        try widgets.progressBar(ui, "progress", .{ .value = state.amount });
        try widgets.progressBar(ui, "pending", .{ .value = null });
        try widgets.spinner(ui, "spinner", .{ .size = .small });
        try widgets.button(ui, "save", .{ .label = "Save settings", .on_click = on.bind(.save), .enabled = state.enabled, .default = true });
        switch (comptime app.platform.kind) {
            .appkit => if (ui.hasNativeWidgets())
                try app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = state.amount, .max = 1 })
            else
                try widgets.progressBar(ui, "rating", .{ .value = state.amount }),
            else => try widgets.progressBar(ui, "rating", .{ .value = state.amount }),
        }
    }
};
```

`textField` is single-line and can submit with Return; `textArea` is
multiline and needs useful height. `searchField` and `secureField` share
the single-line options. Secure display masks characters; it does not
turn the stored string into protected memory. The example replaces its
owned buffer only after cloning the incoming borrowed text, then frees it
in `State.deinit`. Reusing the old buffer before copying can invalidate a
payload that refers to it.

The checkbox includes a label; the toggle is an unlabeled switch, so add
a nearby label in a real form. Both report a `bool`. A slider reports a
`f64` while dragging; a stepper changes a number by `step` within its
bounds. Keep both controlled by the same value when they represent the
same setting. Dropdowns and radio groups report an item index as `usize`;
`selected` may be null for no selection. `horizontal` changes the radio
group's arrangement. Keep selection valid when replacing the items.

Use a determinate `progressBar` with a fraction from 0 to 1 when you know
progress, null for indeterminate work, and a `spinner` for compact busy
feedback. They report no messages. On hosts without full animation, the
drawn indicators avoid continuous scheduling. `label` uses the toolkit's
text when native; `selectable` is native-only. A drawn label supports
wrapping, secondary color and font size but no text selection.

`button` emits an action. `enabled = false` disables each interactive
control rather than merely dimming its color; derive it from the model.
A button with `.default = true` responds to unmodified Return anywhere in
its window when the focused control does not consume it. Drawn defaults
follow the same rule: multiline text inputs keep Return for a newline, and
a focused button keeps its own activation. In a modal dialog, only defaults
inside the active dialog can respond. Disabled defaults do not respond; if
several drawn defaults share a scope, the last declared enabled one wins.
`scrollView` opens a container, so pair it with `ui.close()`. Its `content`
field configures the inside layout. Most controls fit by default; fields,
sliders, labels and progress bars grow in width, and scroll views grow in
both dimensions. Constrain the parent when growth has no useful bound.

Toolkit-only controls belong behind a compile-time `platform.kind` switch,
as the AppKit `levelIndicator` shows. Also check `ui.hasNativeWidgets()`:
a toolkit build can still run with drawn widgets. Calling a native-only
helper without a backend returns `error.NoNativeBackend` from the
view/frame, including in a Harness with `.widgets = .drawn`; it never
attempts a native call. The common aliases in toolkit catalogs use the same
drawn fallback as `app.widgets`. Use a common control as a fallback, as the
rating indicator does here. Never import an unavailable platform namespace
unconditionally: that gives a platform compile error.

## Mix native controls and drawn decoration

A runtime reconciles native controls by key, measures them with the backend,
and gives each a layout box. Keep a control's key and kind stable to keep
the native object. A kind change replaces it; moving between native
containers can also replace it when the backend cannot reparent.

Fabrum interleaves canvas layers and native views in paint order. A drawn
modal declared after a native field can cover it. You can insert ordinary
`ui.text` or drawn controls between native widgets without creating another
runtime. `ui.hasNativeWidgets()` tests the runtime, rather than the build
platform: a harness or custom host can have a backend on `none`.

The toolkit's reported field value is echoed back only when the model
actually differs, and not during IME composition. Store the reported value
rather than rebuilding an unrelated buffer every frame. Use native IME
composition when the platform's full input-method behavior matters.

## Capture a drag and handle keyboard navigation

A custom pad can handle pointer movement and navigation keys independently:

```zig
const DragPad = struct {
    pub const State = struct { x: f32 = 0, keys: usize = 0, saves: usize = 0 };
    pub const Msg = union(enum) { pointer: app.Pointer, key: app.KeyEvent, save };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(DragPad)) void {
        switch (msg) {
            .pointer => |p| switch (p.phase) {
                .press, .drag, .release => state.x = std.math.clamp(p.local.x, 0, p.size.x),
                .cancel, .long_press => {},
            },
            .key => |event| if (event.phase == .press) {
                state.keys += 1;
            },
            .save => state.saves += 1,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(DragPad);
        const theme = ui.use(app.native.Theme);
        try ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true }, on.bind(.save));
        try ui.open("pad", .{
            .layout = .{ .sizing = .fixedXY(200, 80) },
            .on_pointer = on.handler(.pointer),
            .focus_on_press = true,
            .focus = .{ .on_key = on.handler(.key), .keys = .navigation_only },
            .cursor = .pointer,
            .background_color = if (ui.pressed("pad")) theme.accent else if (ui.hovered("pad") and ui.capabilities().hover) theme.control_background.withAlpha(200) else theme.control_background,
            .border = .{ .color = if (ui.focusVisible("pad")) theme.accent else theme.separator, .widths = .outside(1) },
        });
        defer ui.close();
        try ui.print(.{ .color = theme.text }, "Position {d:.0}", .{state.x});
    }
};
```

Input is tested against the previous frame's layout. A press captures the
nearest `on_pointer` handler, which receives drag, long press, release or
cancel even outside its original box. `local` is relative to that box;
clamp it for a slider, as above. A move beyond the default four-point drag
threshold cancels click activation. Long press also cancels the click.
A release without a drag clicks only when it resolves to the same element
as the press. Clicks bubble to the nearest keyed ancestor with `on_click`.
Rounded corners and ancestor clips filter hits.

Handle `.cancel` as a terminal gesture: a host may lose capture, or your
control may disappear, without a release. `Pointer.clicks` distinguishes
single, double and triple presses. `buttons`, modifiers and viewport
`position` are available when your gesture needs them.

A custom control becomes focusable with `focusable` or `focus` and joins
the Tab order in paint order alongside native controls. `focus_on_press`
focuses the pad on a press. `ctx.focus(key)` can focus a declared element
now or once it appears; `ctx.blur()` clears drawn focus. `ui.focusVisible`
lets you show a ring for keyboard focus without showing one after every
pointer press. `Focus.on_focus` reports transitions if state needs them.
Tab and Shift-Tab wrap; Escape clears drawn focus; Space or Enter activates
a focused `on_click` on release. A modal subtree restricts that traversal.

The key filter decides synchronously whether the host should consider a
key taken. `.navigation_only` lets the pad handle arrows while leaving
shortcuts for `ui.shortcut`. `.default` excludes Tab, Escape and command
shortcuts; `.all` takes those too; `.none` takes no keys. Narrow filters
prevent a list from stealing text editing or host shortcuts. Delivery checks
the focused handler, text input, ancestor handlers, shortcuts, then the
runtime's own navigation. With no drawn focus, only an unmodified Return
for an enabled drawn default button is taken.

`.shortcut = true` means Command on the macOS keymap and Control on Linux
or Windows. A character shortcut uses its typed identity, with a physical
US-key fallback on layouts without that Latin character. Key events also
carry press/repeat/release phase and modifiers. The GTK `App` selects the
Linux keymap even when built on macOS; custom hosts choose explicitly.

## Set cursors and follow the theme

Clickables default to the pointer cursor, text inputs to text, and other
content to default. Set `Ui.Container.cursor` to override it, including on
an unkeyed (`null`) container. Focus and scroll options require a stable
non-null key; otherwise `ui.open` returns `error.KeyRequired` and logs the
option name. The host reads
`Runtime.cursor()` after input and applies its native cursor. Hover and
pressed states mark the runtime dirty, so a custom control can use
`ui.hovered` and `ui.pressed` without polling.

Read `ui.use(app.native.Theme)` for accent, text, backgrounds, separators,
font size and control height. Honor `ui.capabilities().hover` before adding
hover-only styling and `animates()` before requesting continuous frames.
Drawn controls use these values already; grayscale capabilities produce a
high-contrast theme. `theme.full_keyboard_access` controls whether drawn
buttons and other non-text controls join Tab traversal, matching the
platform's keyboard-navigation setting. Text fields always participate.
For a custom host, set the runtime's `theme`, `keymap` and `capabilities`;
for a subtree, provide an arena-backed Theme as a context override.

## Own an editor when selection matters

Use the common text widgets when your model only needs their string. Own a
`TextEditor` when you need selection, custom commands, undo or controlled
composition state:

```zig
const Editor = struct {
    pub const State = struct {
        editor: app.TextEditor = .{},
        submitted: bool = false,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.editor.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { input: app.TextInput, pasted: ?[]const u8 };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Editor)) !void {
        switch (msg) {
            .input => |input| {
                const outcome = try ctx.editText(&state.editor, input, .{ .single_line = true, .max_len = 80 }, ctx.handler(.pasted));
                if (outcome.submitted) state.submitted = true;
            },
            .pasted => |text| if (text) |value| {
                _ = try state.editor.apply(ctx.gpa, .{ .paste = value }, ctx.textEnv(.{ .single_line = true, .max_len = 80 }));
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try app.drawn.textEditor(ui, "editor", &state.editor, .{ .on_input = ui.messages(Editor).handler(.input), .single_line = true });
    }
};
```

`TextEditor` stores UTF-8 plus selection anchor and focus as byte offsets.
Use its editing API to maintain grapheme boundaries rather than changing
those offsets with byte arithmetic. `selectedText()`, `caret()` and
`composing()` inspect it. `setText(gpa, text)` replaces app-owned text and
bumps generation so input-method composition can be discarded. Deinitialize
the editor with the state's allocator.

`ctx.editText` supplies the last frame's visual geometry and time, applies
input and serves copy/cut/paste. Paste is asynchronous: its handler receives
borrowed text, then applies `.paste` using the same options. `Outcome`
reports text changes, selection changes and single-line submission. A
single-line paste normalizes line breaks; `max_len` is bytes and insertions
are cut on a grapheme boundary. `TextInput` also supports set, replace,
selection and preedit; `EditCommand` supports grapheme/word/line movement
with selection extension, deletion, select-all, undo/redo, transpose,
kill/yank and clipboard commands. Use the
[text editor source](../../src/app/text_editor.zig) for the exact command
variants rather than inventing key bindings.

The provided `Keymap` translates host key events. Text geometry connects
caret and pointer movement to visual lines; `app.drawn.textEditor` records
it for you. A custom editor surface must use `ui.textGeometry` with a
frame-lived `TextGeometry`. `ui.caretVisible(key)` schedules the next blink
when appropriate. Hosts send committed input through `Runtime.textInput`.
On-screen-keyboard hosts ask `systemText` when a drawn field is pressed.

Grapheme moves use UAX #29. Word moves use UAX #29 on 64-bit targets and a
letter/digit-run fallback on 32-bit targets. Bidirectional text and drawing
IME preedit are not implemented; preedit is accepted and kept separate from
committed text. Prefer native fields where those features are required.
See [editor testing](testing.md#type-and-select-without-a-window) for a
working clipboard and selection test.
