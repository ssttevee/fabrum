# Open and manage multiple windows

Use `app.platform.current.Application` when a program needs document windows,
settings, or a separate overlay controller. AppKit, GTK and Win32 share this
API. Each window has its own component state, focus, scrolling, renderer and
runtime tasks; the application owns one native event loop.

## Open two independent windows

Reuse `Counter` from [your first app](first-app.md#write-the-component), with
the [usual imports](README.md#about-the-code-in-these-guides). Replace that
guide's `Window` namespace with this one and call `MultipleWindows.main(init)`
from your file-scope `main`:

```zig
const MultipleWindows = struct {
    pub fn main(init: std.process.Init) !void {
        const Desktop = app.platform.current.Application;
        const host = try init.gpa.create(Desktop);
        defer init.gpa.destroy(host);
        try host.init(init.gpa, init.io, .{});
        defer host.deinit();
        _ = try host.openWindow(Counter, .{ .step = 1 }, .{
            .title = "First counter",
            .width = 320,
            .height = 200,
        }, .{});
        _ = try host.openWindow(Counter, .{ .step = 10 }, .{
            .title = "Second counter",
            .width = 320,
            .height = 200,
        }, .{});
        host.run();
    }
};
```

Run with `zig build run` in the first-app project, or add `-Dplatform=gtk`.
Native Windows also needs the manifest setup from that guide. The two
counters start at zero and update independently, with different increments.

Allocate the application at a stable address before initializing it. `openWindow`
allocates stable storage for each window and returns an `app.WindowId`.
The application owns those windows; do not separately destroy borrowed window
pointers. Native `run()` does not return. Window initialization offers `on_terminate` for cleanup after that runtime's
tasks are cancelled. Do not release a shared service when only one of its
windows closes; it must outlive every borrower. See
[shutdown lifetime order](concurrency.md#shut-down-in-lifetime-order).

## Keep IDs for later operations

Store the returned ID in an application-owned controller. On the native event
thread, call `host.requestFrame(id)` after data changes, `host.hide(id)` to
hide a window, and `host.show(id)` to show it again. Showing follows the
window's activation policy. These calls return false for a closed/stale ID.
IDs include a generation: an old ID cannot accidentally name a replacement
window. Remove stale IDs from your controller's list.

For host integration, `host.window(Counter, id)` borrows the default-policy
window, or returns null if the ID is stale or the type differs. For a custom
policy, use `host.get(WindowType, id)` with the exact descriptor you opened.
Root, renderer and policy are part of that type. Never keep this pointer or
its automation/native handles beyond the window's lifetime.

Use `ApplicationWith(Renderer)` with `WindowWith(Root, Renderer, policy)`
when selecting a renderer. Every descriptor opened by an application must
use that application's renderer type.

## Share a document, keep view state local

The complete [shared-document example](../../examples/windows.zig) runs with
`zig build run-windows` in the repository. Its controller owns the document
and outlives all windows. Each root receives a borrowed document pointer in
props and a `Commands` service through initialization's `provide` values.

When a component changes the document, it calls that service. The controller
requests a frame in every live window, so each view reads the new document.
Component-local state, such as a window's click count, remains independent.
For dynamic window creation, reserve space in your ID list before opening;
then a successful open can always be recorded.

Handlers belong to their originating runtime. Do not use one window's
handler with another window's poster. Keep document mutations and application
operations on the native event thread; background work should send results
through its owning runtime or an application-owned service.

## Close, hide and quit deliberately

- `hide(id)` keeps the ID, component state and runtime alive. It does not
  cancel background work. A hidden window still counts as an open window.
- `close(id)` requests a guarded close, deferred until the current callback
  returns. An accepted close destroys that window and cancels its tasks.
- `quit()` asks every window's close guard, one at a time. All windows stay
  open until every guard approves. A cancellation resets the approvals.

In a component, use `ctx.close()`, `ctx.quit()` and `ctx.cancelClose()` as
shown in [close confirmations](services.md#confirm-closing-once). Match the
approval to the received close reason. If you open a hidden badge alongside a
controller, closing the controller alone leaves the badge alive; provide an
explicit Quit action or coordinate closing both.

By default, closing the last window quits. Set
`quit_on_last_window_closed = false` in application initialization to keep
running with no windows. Stop external producers that hold a raw `Poster`
before its runtime is destroyed. Work that must survive a window belongs to
an application-owned service.

## Verify the lifecycle

Use two harnesses borrowing one document to check shared data and independent
state; the shared-document example includes this test. Harnesses do not
exercise native windows. Run `zig build test-windows` on a desktop to check
native lifecycle behavior. See [overlay windows](overlay-windows.md) for
visibility, focus and click-through behavior.
