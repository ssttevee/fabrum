# Ask the host for dialogs, files and clipboard data

Use services from update for an operation the host owns: a popup menu,
a file chooser, a system keyboard or closing a window. Answers arrive as
messages, so the same component can work with a toolkit, an e-ink host or
test fakes. Services and native widgets are independent: a host can draw
all controls and still provide a system chooser. The
[service reference](../platforms.md#services) lists request fields and
fallbacks.

## Ask the host and keep the answer

This screen uses the main services, handles a missing chooser and guards
closing while it has unsaved changes:

```zig
const ServiceScreen = struct {
    pub const State = struct {
        text: ?[]u8 = null,
        answer: ?usize = null,
        unsupported: bool = false,
        dirty: bool = true,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.text) |text| gpa.free(text);
        }
    };
    pub const Msg = union(enum) {
        message,
        confirm,
        menu,
        edit,
        file,
        directory,
        copy,
        paste,
        close,
        text: ?[]const u8,
        answer: ?usize,
        closing: app.platform.CloseReason,
        discard: ?usize,
    };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(ServiceScreen)) !void {
        switch (msg) {
            .message => try ctx.message(.{ .title = "Saved", .text = "Your settings were saved.", .timeout_ms = 2000 }),
            .confirm => try ctx.confirm(.{ .title = "Remove item?", .text = "This removes the selected item.", .buttons = &.{ "Remove", "Cancel" }, .default = 1 }, ctx.handler(.answer)),
            .menu => try ctx.menu(.{ .items = &.{ .{ .id = 7, .title = "Open" }, .{ .kind = .separator }, .{ .id = 9, .title = "Remove", .enabled = false } }, .at = .init(20, 20) }, ctx.handler(.answer)),
            .edit => ctx.systemText(.{ .title = "Name", .initial = state.text orelse "", .max_len = 80 }, ctx.handler(.text)) catch |err| switch (err) {
                error.Unsupported => state.unsupported = true,
                else => return err,
            },
            .file => ctx.openFile(.{ .message = "Open a picture", .extensions = &.{ "png", "jpg" } }, ctx.handler(.text)) catch |err| switch (err) {
                error.Unsupported => state.unsupported = true,
                else => return err,
            },
            .directory => try ctx.openDirectory(.{ .message = "Choose a folder" }, ctx.handler(.text)),
            .copy => try ctx.writeClipboard(state.text orelse "copied"),
            .paste => try ctx.readClipboard(ctx.handler(.text)),
            .text => |value| if (value) |borrowed| {
                const owned = try ctx.gpa.dupe(u8, borrowed);
                if (state.text) |old| ctx.gpa.free(old);
                state.text = owned;
            },
            .answer => |answer| state.answer = answer,
            .close => try ctx.close(),
            .closing => try ctx.confirm(.{ .title = "Discard changes?", .text = "There are unsaved edits.", .buttons = &.{ "Discard", "Keep editing" }, .default = 1 }, ctx.handler(.discard)),
            .discard => |answer| if (answer == 0) {
                state.dirty = false;
                try ctx.quit();
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(ServiceScreen);
        if (state.dirty) ui.guardClose(on.handler(.closing));
        try app.menus.item(ui, "open-menu", .{ .menu = "File", .title = "Open", .key = "o", .on_select = on.bind(.file) });
        try widgets.button(ui, "open", .{ .label = "Open picture", .on_click = on.bind(.file) });
        if (state.unsupported) try ui.text("This host has no chooser or system text entry.", .{});
        if (state.text) |text| try ui.text(text, .{});
    }
};
```

Start the request from an input message, not unconditionally from the view:
a view runs every frame and would reopen the chooser repeatedly. The answer
is optional; null means cancellation, dismissal or no text. Keep the old
value when cancellation should leave the current selection intact.

Service reply strings are borrowed until update returns. Duplicate them
with `ctx.gpa` before storing, and release the old owned value only after
the allocation succeeds. The same rule applies to a chosen file, directory,
system text and clipboard contents. Keeping the borrowed slice can become
a use-after-free on a later frame. `IndexReply` values are numbers and need
no allocation.

## Choose a dialog style

Use `ctx.message` for information that needs no answer. A host may honor
`kind` and `timeout_ms`; the drawn fallback is modal and ignores both the
kind and timeout. GTK ignores `kind`, while AppKit maps it to alert style.
Use `ctx.confirm` for a question: one to three buttons, a default button
index, and a `Handler(?usize)`. Zero or more than three buttons gives
`error.ServiceFailed`. A reply is the button index, or null if dismissed.

```zig
const Question = struct {
    pub const State = struct { asking: bool = true, answer: ?usize = null };
    pub const Msg = union(enum) { answered: usize };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(Question)) void {
        switch (msg) {
            .answered => |answer| {
                state.asking = false;
                state.answer = answer;
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.text("Settings", .{});
        if (state.asking) try app.dialogs.alert(ui, "question", .{
            .title = "Apply settings?",
            .buttons = &.{ "Apply", "Cancel" },
            .on_response = ui.messages(Question).handler(.answered),
        });
    }
};

test "guide declared alerts disappear after answering in both widget modes" {
    inline for (.{ app.testing.Widgets.native, app.testing.Widgets.drawn }) |mode| {
        var h: app.testing.Harness(.{}, Question) = try .init(.{}, .{ .widgets = mode });
        defer h.deinit();
        try h.frame();
        if (mode == .native) try h.respond(h.root().native("question"), 0) else try h.click("Apply");
        try std.testing.expectEqual(0, h.state().answer.?);
        try std.testing.expect(!h.state().asking);
        try h.expectNoText("Apply settings?");
    }
}
```

For a dialog whose presence belongs to view state, use
`app.dialogs.alert` and stop declaring it once its `Handler(usize)` answers.
It is native with a backend and drawn otherwise. `app.drawn.alert` forces
the drawn version. The complete tested
[Form example](../../test/compile/doc_snippets.zig) shows conditional
`dialogs.alert` declaration and `h.respond`. Use a stable dialog key;
leaving it in the view after an answer does not represent a fresh request.
Declare drawn modals after the content they must cover.

## Choose a menu

`app.menus.item` declares a menu-bar item while its view is present. Its
`key` option is a key equivalent under the platform shortcut modifier;
the element key identifies the item. On a host without native widgets,
menu-bar items show nothing. Provide a visible button or shortcut for a
command that must remain available there.

`ctx.menu` is a popup service and does have a drawn fallback. Menu items
carry explicit IDs; the answer is the selected `MenuItem.id`, not its array
position. Use distinct IDs and account for null on dismissal. Items may
be ordinary entries, headers, separators or submenus, with enabled state.
`at` and `anchor` provide placement hints. In the example, Open answers
with 7 even though it is the first item. The
[fake service test](testing.md#answer-host-requests-deterministically)
checks that distinction.

## Open files, directories and system text entry

`openFile` chooses one existing file. Pass extensions without a leading
dot, or an empty list for all files. `openDirectory` uses the message but
ignores extensions. There is no save-file or multiple-file chooser in this
API. A chosen path is a path to operate on, not loaded file contents; use a
[task](concurrency.md) for reading it.

`systemText` requests a host's modal text input, useful for an e-reader's
on-screen keyboard. Supply title, initial text, optional byte limit and
flags such as numeric, URL, password, email or multiline. It is distinct
from a field accepting physical-keyboard input. No host service means
`error.Unsupported`; it does not create another editable dialog for you.

File and directory choosers also have no drawn fallback. Catch
`error.Unsupported` and show a path field or unavailable-state explanation
when that is a supported workflow, as the example does. Do not treat
`ServiceFailed` or `OutOfMemory` as a user cancellation. If an installed
service callback returns `Unsupported`, that error is returned directly;
the runtime does not retry it as though the callback were absent. Leave a
service entry null to request its automatic fallback.

## Use the clipboard

Write with `ctx.writeClipboard(text)` and read with
`ctx.readClipboard(handler)`. Reading can be asynchronous and can return
null. Without host entries, the runtime maintains a private clipboard so
copy and paste work within the program. That private clipboard cannot
exchange data with other applications. An installed clipboard service's
failure is returned rather than silently bypassed. For text editing,
prefer `ctx.editText`, which connects the same services to copy/cut/paste.

## Confirm closing once

`ui.guardClose(handler)` is active only while declared. The last guard
in a frame wins. A host asks `rt.shouldClose(.window)` for a close button
or `.quit` for an application quit. A guard queues its reason and returns
false. Your update asks a question, then calls `ctx.close()` or `ctx.quit()`
after consent. Those service calls bypass the guard, avoiding another
confirmation cycle. On AppKit and GTK the one window's close also quits.

Without a guard, `shouldClose` returns true. A custom host must actually
call it before closing; the runtime cannot intercept an external host's
termination by itself. An unavoidable device shutdown may not permit
refusal. Both `quit` and `close` return `error.Unsupported` if no matching
host entry exists. A `none` host commonly provides callbacks that change
its loop's running state.

## Test availability and answers

Use a harness with `.services = .all` to answer requests without a desktop.
Use `.basic` for a fake clipboard and close/quit with drawn dialogs and
menus, or `.none` for no host services and a private runtime clipboard.
The [testing guide](testing.md#answer-host-requests-deterministically)
shows dialog, menu, text, file and directory replies. Platform authors can
implement a [delayed service reply](writing-a-platform.md#implement-a-service-with-a-delayed-reply)
without storing frame-lived request pointers.
