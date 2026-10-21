# Package an external platform on none

Use an external platform package when a device SDK or application engine
owns the loop. Keep fabrum built with `.platform = .none`; your package
implements the host boundary instead of adding a built-in platform enum
variant. Read [hosting](hosting.md) first. Fabrum-platform-inkview is the
working model: it owns InkView events, a z2d renderer, the framebuffer,
refresh policy and optional modal services. The
[platform reference](../platforms.md#writing-an-external-platform-package)
summarizes that structure.

## Define the package boundary

Expose a `run(Root, gpa, io, props, options)` entry point, or an `App(Root)`
that an existing toolkit loop drives. Options should describe fonts,
capabilities, theme, keymap, layout capacity and application root values.
Keep callbacks and the owning host at a stable address. Make ownership of
toolkit APIs, windows and buffers explicit: a package that borrows a host
window should not destroy it at shutdown.

In the InkView package, `src/root.zig` exports `Options`, `App`, capabilities,
refresh helpers and a fake SDK. `run` loads `libinkview.so` and gives its API
to the host. The device program must match the firmware ABI and libc;
loading the SDK dynamically does not remove that compatibility requirement.
A missing required symbol is an initialization failure; optional symbols
remain absent and select a fallback.

## Inject the same module throughout the package

A platform and its renderer must use the app's one fabrum module. Export a
build helper that forwards it to both:

```zig
pub fn addFabrum(platform: *std.Build.Module, fabrum: *std.Build.Module) void {
    platform.addImport("fabrum", fabrum);
    platform.import_table.get("my-renderer").?.addImport("fabrum", fabrum);
}
```

The example renderer import is `my-renderer`; a real helper uses its actual
import name. InkView's helper forwards to `fabrum-renderer-z2d`. The app
obtains fabrum with `.platform = .none`, obtains your public platform
module with `b.dependency(...).module(...)`, calls your dependency's
`addFabrum`, then imports the platform module into its executable. Its
`main` calls the platform's `run` with the component and resources.

Expose the public module before any `b.isRoot()` branch. Put your own
fabrum dependency behind `lazyDependency` inside that branch for root tests
and examples; consumers supply theirs and should not fetch another one.
Include all source and test fixtures needed by root build steps in your
published manifest paths. The
[renderer packaging guide](writing-a-renderer.md#structure-the-package)
explains the duplicate-module error this avoids.

## Map events into runtime turns

Translate pointer down/move/up into `MouseEvent` position and pressed bits,
long press into its flag, and lost capture into `cancelPointer`. Translate
hardware keys to logical key, modifiers and physical identity when known.
Keep scale conversion in one place: toolkit pixels become fabrum points,
while damage points become panel pixels at presentation.

After an event, run frames when `nextFrame` is due, consume the final
commands, draw damage and present. Arm a toolkit timer for the next future
deadline. Bound immediate frame draining so a continuously animating view
cannot monopolize the SDK callback. When a different thread posts, implement
`Platform.requestFrame` with the SDK's documented thread-safe wake primitive.
Coalesce wake events if its queue is bounded. Do not call arbitrary toolkit
functions from the posting thread.

InkView's `host.zig` maps show, repaint, foreground and orientation changes
to full redraws because the SDK may replace screen pixels under the host.
It limits immediate frames per event turn and arms a one-shot toolkit timer
for later work. Cross-thread wakeups are coalesced into its custom event.
These are host policies; the app runtime does not know when a device has
lost its retained framebuffer.

## Implement a service with a delayed reply

Services are optional vtable entries. Here a file-chooser service copies
the request data it keeps and stores only the typed reply:

```zig
const ChooserService = struct {
    gpa: std.mem.Allocator,
    title: ?[]u8 = null,
    pending: ?app.platform.Reply = null,
    pub fn services(self: *ChooserService) app.platform.Services {
        return .{ .ptr = self, .vtable = &.{ .openFile = openFile } };
    }
    fn openFile(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
        const self: *ChooserService = @ptrCast(@alignCast(ptr));
        if (self.pending != null) return error.ServiceFailed;
        self.title = try self.gpa.dupe(u8, request.message);
        self.pending = reply;
    }
    pub fn answer(self: *ChooserService, path: ?[]const u8) !void {
        const reply = self.pending orelse return error.NoFileChooser;
        self.pending = null;
        defer {
            self.gpa.free(self.title.?);
            self.title = null;
        }
        try reply.send(path);
    }
    pub fn deinit(self: *ChooserService) void {
        if (self.title) |title| self.gpa.free(title);
    }
};
```

Initialize a runtime with `services = service.services()`. When the SDK
answers, call `answer(path)` or `answer(null)`; the executable test in
[guide_snippets.zig](../../test/compile/guide_snippets.zig) drives that exact
round trip. This minimal example is single-threaded except for the reply's
thread-safe posting; synchronize its pending-request state if callbacks
can race. It rejects a second simultaneous chooser rather than overwriting
an outstanding reply. A production host can instead queue requests.

The request pointer and its strings are borrowed for the service call.
Copy everything retained for asynchronous SDK use, including nested menu
items and button strings, and release it when the request ends. `Reply.send`
copies text so the SDK's answer buffer need only survive that call;
`IndexReply.send` posts the optional button index or menu item ID. Answers
are delivered on the runtime thread. The runtime allocator must support
concurrent use if replies arrive elsewhere. Do not send after destroying
the runtime, even if the target component disappeared earlier.

Leave unsupported entries null: message, confirmation and popup-menu
fallbacks are drawn; clipboard falls back privately; system text, choosers
and closing may give `Unsupported`. An installed callback returning an
error does not trigger the absent-entry fallback. Translate SDK failures
into `ServiceFailed` or `OutOfMemory` rather than silently sending a
cancellation. A host may implement a directory chooser without an open-file
chooser; InkView does so.

A toolkit's modal UI can reenter callbacks or save and restore screen
pixels. InkView holds runtime presentation while its dialog/menu/keyboard
is active and forces a redraw afterward if frames were held. Preserve
message and timer progress without drawing over the SDK's modal surface;
do not assume the SDK's saved pixels include state changes made behind it.

## Describe the device and refresh policy

Advertise real capabilities: InkView uses touch, no hover, no animation,
gray16 and an on-screen keyboard. That makes drawn widgets high contrast
and avoids caret blink and decorative spinner refreshes. Supply the device
keymap and enough font data before the first frame. A keyboard service
then turns `systemText` into the SDK's editor; an ordinary hardware-keyboard
host can leave that entry absent and send text input directly.

Use `Runtime.refresh()` after `damage()` as a hint to a device policy.
InkView maps page changes to full update, normal content to partial gray
updates, and sustained interaction to fast A2 black/white updates after a
short run. Its policy keeps full gray values in the framebuffer, applies
hysteresis around A2, then schedules a cleaning refresh after idle. It also
periodically cleans ordinary partial updates. Keep that policy separate
from application components so panel-specific trade-offs remain testable.
Convert damage regions to panel pixels carefully, including non-unit scale,
stride and orientation. If direct gray8 access is unavailable, a private
buffer plus SDK blit can preserve the same renderer contract.

## Add native controls only when the toolkit has them

A `none` host does not need a native backend. Without one, `app.widgets`
uses drawn controls. Host services alone are enough for SDK dialogs, menus
and a system keyboard. Add `Options.native` only if your toolkit supplies
persistent controls that should participate in layout and focus.

Implement `app.native.Backend`: create, update, destroy, setFrame,
setContentSize, measure, setValue, composing, canFocus, focus, present and
theme, with optional reparent. The runtime reconciles stable IDs into
backend handles, inserts native placeholders into layout, and sends a
`native.Scene` interleaving native views and canvas layers in paint order.
For native containers, reconcile their content in their own coordinates.
If reparenting is unavailable, the runtime may recreate a moved control.

Report user changes through `Runtime.nativeEvent(id, event)`. Distinguish
programmatic value writes from user events to avoid echo loops. Report
composition state so controlled updates do not interrupt native IME edits.
Implement keyboard focus consistently with drawn elements and modal scopes.
Use the backend theme for measured control sizes and matching drawn text.
The [native contract source](../../src/app/native.zig) and
[NativeTree](../../src/app/testing/native_tree.zig) are the detailed models;
AppKit and GTK show real scene presentation. Do not claim native behavior
by mapping controls to rectangles without implementing this lifecycle.

## Test the host independently of a device

Put the SDK behind an injectable function table or adapter and provide a
fake clock, framebuffer, event queue and service replies. InkView's
`src/fake.zig` and `src/host_test.zig` exercise that layer without loading
the real SDK. Check input conversion, wake coalescing, due-frame timers,
resize/exposure redraw, modal save/restore behavior, close guards and
refresh decisions. Test missing optional SDK functions and failed requests.
Compare partial framebuffer updates with full redraws through the renderer.

Test application components separately with
[Harness](testing.md), including the device's capabilities and service
fallbacks. A fake SDK proves host logic; device and emulator smoke tests
still establish ABI, real fonts, event semantics and panel behavior.
Keep those distinctions visible in the package's documented test commands.

## Close and release resources in order

Ask `Runtime.shouldClose` for a user close before ending the loop so a
component's guard can confirm. An SDK's already-committed exit event may
not permit refusal; InkView's `EVT_EXIT` is such a case. Provide a guardable
app close command or hardware close key where possible.

On termination, cancel and join runtime tasks before destroying borrowed
domain services. Stop SDK service replies and independent posters while
the runtime is still live, then deinitialize it and the renderer, release
framebuffers and toolkit resources, and unload borrowed API handles last.
Document an SDK that terminates the process without returning, so consumers
put essential shutdown work in the host's termination path instead of a
`defer` after `run`.
