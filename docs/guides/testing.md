# Test components without a window

Use `app.testing.Harness(config, Root)` to drive the runtime with a fixed
viewport, controlled time, fake native controls and fake host services.
It uses heuristic text measurement by default and no renderer, so component
tests do not depend on screenshots, a display server or a live event loop.
The [testing reference](../app.md#testing) lists all helpers.

## Start with frames and assertions

Initialize the harness with root props and options, defer `deinit`, then
call `h.frame()` before looking up elements or state. The
[first counter test](first-app.md#test-the-first-interaction) is the minimal
example. `h.state()` points to the root state after its first frame;
`h.props` and `h.viewport` can be changed before another frame. Tests may
modify state directly when arranging a scenario, but input-driven tests
exercise more of the real event path.

`expectText` matches an entire drawn text unit, not a substring or native
widget title. `expectNoText`, `hasText`, `texts` and `findText` inspect the
same layout. Failure prints the texts actually present. Use state
assertions for domain outcomes and `expectFocused` for focus. `widget`
and `expectWidget` inspect the fake native object, including its spec,
value and frame, when the outcome is a native control.

## Find the same identity the view declared

Start from `h.root()`. For `ui.one(Dialog, props)`, use
`h.root().one(Dialog)`; for `ui.child(Row, id, props)`, use
`h.root().child(Row, id)`. Use `.element(key)` for a drawn/layout ID and
`.native(key)` for a native widget ID. These constructors do not prove an
instance exists: lookup or interaction checks that it is actually present.
The [badge test](../../test/compile/guide_snippets.zig) clicks child 20
before and after reordering without changing the ID.

Use keys for repeated labels or empty controls; `h.click("Save")` selects
the first matching drawn text and can become ambiguous as the screen grows.
Drawn text fields introduce a `drawn.TextBox` component internally; the
editor test below follows that child to its `"field"` element. Ordinary
drawn buttons use the widget key in the caller's component scope.
`app.testing.rootInstance(C)` builds the same scope outside a harness.

## Choose native or drawn widgets explicitly

`.widgets = .native` attaches `NativeTree`, a data backend available on
all platforms, including `none`. Use `clickNative`, `typeText`, `setText`,
`submit`, `slide`, `selectNative`, `stepNative`, `scrollNative`, `selectMenu`
and `respond` to deliver the corresponding native events. These are native
IDs, not layout IDs. Native field composition is tested with `compose`
and `commit`; `typeText` while marked text exists gives `error.Composing`.
The [settings tests](../../test/compile/guide_snippets.zig) drive both
native and drawn versions of the same full widget set.

`.widgets = .drawn` tests hit testing, focus, text editing and gesture logic.
`h.click`, `clickElement` and `clickAt` perform primary press/release and
then a frame. `hover`, `hoverElement`, `moveTo` and `leave` test hover
state. `drag` and `dragElement` move through a requested number of steps
with frames; `longPress` and raw `mouse` let you test other pointer phases.
`scroll`, `scrollElement` and `scrollAt` deliver wheel deltas and return
whether anything consumed them. `scrollInfo` inspects the resulting offset.
The [list recipe](layout.md#scroll-a-long-list) has a wheel and update test.

Use `tab`, `shiftTab` and `expectFocused` for traversal. `press` requires
the runtime to take the key and fails with `error.KeyNotTaken` otherwise;
`pressKey` returns the taken boolean. `hold` adds repeat events;
`keyEvent` sends an exact event. Native key interpretation belongs to the
toolkit, so use native helpers for native controls rather than expecting
the harness to reproduce an operating system's complete event processing.

## Type and select without a window

Use the [Editor component](widgets-and-input.md#own-an-editor-when-selection-matters)
for an app-owned editor and test it through real input:

```zig
test "guide editor selection clipboard undo and submission" {
    var h: app.testing.Harness(.{}, Editor) = try .init(.{}, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().child(app.drawn.TextBox, "editor").element("field"));
    try h.type_("hello");
    try h.command(.select_all);
    try std.testing.expectEqualStrings("hello", h.state().editor.selectedText());
    try h.command(.copy);
    try std.testing.expectEqualStrings("hello", h.clipboard().?);
    try h.type_("goodbye");
    try h.command(.undo);
    try h.command(.paste);
    try h.press(.enter, .{});
    try std.testing.expect(h.state().submitted);
}
```

`type_` sends typed code points to the focused text input. `command` sends
an editing command through `textInput`; raw `textInput` can send commits,
selection or preedit. Typing without focus fails rather than silently
changing state. Clipboard commands run through the configured services,
so this also tests update-side asynchronous paste handling. A bare key
press with `.char` does not type its text; use `type_` or supply a key event's
`text` explicitly.

For IME, separately test native composition and drawn committed text.
The harness can verify model ownership and composition suppression, but
does not prove real platform IME candidate-window placement or preedit
display. Keep a small toolkit smoke test when platform behavior matters.

## Test native composition and disabled controls

Reuse the [Settings form](widgets-and-input.md#build-a-controlled-settings-form) to check that marked text stays out of the model until commit and a disabled Save button does not fire:

```zig
test "guide native composition reports only committed text" {
    var h: app.testing.Harness(.{}, Settings) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const field = h.root().native("name");
    try h.compose(field, "uncommitted");
    try std.testing.expectEqualStrings("", h.state().text.items);
    try h.commit(field, "committed");
    try std.testing.expectEqualStrings("committed", h.state().text.items);
    try h.clickNative(h.root().native("enabled"));
    try h.clickNative(h.root().native("save"));
    try std.testing.expectEqual(0, h.state().saves);
}
```

## Answer host requests deterministically

Reuse [ServiceScreen](services.md#ask-the-host-and-keep-the-answer):

```zig
test "guide fake services answer dialogs menus text and choosers" {
    var h: app.testing.Harness(.{}, ServiceScreen) = try .init(.{}, .{ .services = .all });
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(ServiceScreen, .confirm), {});
    try h.answerDialog(1);
    try std.testing.expectEqual(1, h.state().answer.?);
    try h.post(h.root().handler(ServiceScreen, .menu), {});
    try h.chooseMenuItem(7);
    try std.testing.expectEqual(7, h.state().answer.?);
    try h.post(h.root().handler(ServiceScreen, .edit), {});
    try h.enterText("Ada");
    try h.post(h.root().handler(ServiceScreen, .copy), {});
    try h.post(h.root().handler(ServiceScreen, .paste), {});
    try h.expectText("Ada");
    try h.post(h.root().handler(ServiceScreen, .file), {});
    try h.chooseFile("/pictures/harbour.png");
    try h.expectText("/pictures/harbour.png");
    try h.post(h.root().handler(ServiceScreen, .directory), {});
    try h.chooseDirectory("/pictures");
    try h.expectText("/pictures");
    try std.testing.expect(!try h.requestClose(.window));
    try h.answerDialog(0);
    try std.testing.expect(!h.state().dirty);
}
```

`answerDialog` answers a service confirmation, while `respond` answers a
declared native alert by ID. `chooseMenuItem` uses the service menu's item
ID, while `selectMenu` activates a declared native menu item. `chooseFile`,
`chooseDirectory` and `enterText` answer the oldest pending request;
null cancels. A missing request gives an error such as `NoFileChooser`,
which catches tests answering before the app actually asked.

Run fallback scenarios with `.services = .basic` or `.none`. The test suite
opens a drawn confirmation with no services, clicks Cancel and verifies
`error.Unsupported` for close without a host. Use `clipboard()` for the
fake shell clipboard under `.all` or `.basic`; a `.none` runtime's private
clipboard is tested by reading it back through a handler.

For a domain-service fake, provide its value in `.provide`, retain a typed
handler and answer with `h.post(handler, payload)`. `h.post` queues and
runs a frame. `h.poster()` lets the code under test post independently;
run a frame to deliver those messages. Follow explicit post ownership:
this differs from borrowed text replies and task results. For a real
`platform.Services` vtable fake, initialize `Runtime` directly, as the
[delayed chooser test](writing-a-platform.md#implement-a-service-with-a-delayed-reply)
does; harness options select its own service sets.

## Complete tasks without I/O

Tasks are queued rather than spawned by default. Reuse
[Loader](concurrency.md#load-data-and-clone-the-result):

```zig
test "guide declared tasks retain results until an explicit restart" {
    var h: app.testing.Harness(.{}, Loader) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.taskStarted("catalogue"));
    try h.completeTask("catalogue", Loader.load, "Fake gallery");
    try h.expectText("Fake gallery");
    try std.testing.expectError(error.TaskAlreadyCompleted, h.completeTask("catalogue", Loader.load, "Again"));
    h.props.name = "New gallery";
    try h.post(h.root().handler(Loader, .refresh), {});
    try h.runTasks();
    try h.expectText("New gallery");
    try std.testing.expectEqual(2, h.state().progress);
}
```

`taskStarted` includes queued, running and retained completed declared
tasks. Completed commands and canceled tasks are absent. `completeTask`
checks the exact function and copies the fixture result; the test retains
ownership of the original fixture memory. The handler still receives a
borrowed task result and must clone retained data as in production.

A missing/canceled key gives `TaskNotFound`, a different function gives
`TaskFunctionChanged`, a second completion gives `TaskAlreadyCompleted`,
and a replacement waiting for executing predecessor cleanup gives
`TaskPending`. `h.runTasks()` executes only the current queue in order,
then delivers results and renders. Tasks created by those results wait for
the next call. Use keyed commands when you need to fake one; unkeyed
commands can be executed with `runTasks`.

For a child scope, use `taskStartedFor(instance, key)` and
`completeTaskFor(instance, key, function, result)`, with the same
`.one`/`.child` scope used for elements. The
[existing child-task test](../../test/compile/doc_snippets.zig) checks
removal, reappearance and progress across such a scope. Serialization and
thread-safety tests need real concurrency; deterministic queued tasks alone
cannot prove those properties. [examples/tasks.zig](../../examples/tasks.zig)
contains the real cancellation and cleanup tests.

## Control time and capabilities

`h.advance(duration)` moves virtual time and runs a frame. The
[timer example](timers-and-animation.md#declare-a-clock-and-a-one-shot-notification)
checks periodic and one-shot behavior without waiting on a wall clock.
Set `capabilities`, `keymap`, `theme` and `full_keyboard_access` to exercise
touch panning, no-hover displays, reduced motion, grayscale styling and
keyboard navigation. Set a small viewport to catch layout overflow.

For CI, run `zig build test -Dplatform=none` with Zig 0.17.0. No GUI
libraries or display are needed for that configuration. Toolkit builds
add compile/link coverage but still use the fake backend for these tests.
Supply `config.Text` and `text_context` when you need production text
measurement; use a renderer's own tests for pixels and damage correctness.
