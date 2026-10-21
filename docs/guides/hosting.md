# Host the runtime on none

Use `none` when your program already owns a window, framebuffer, device
loop or overlay. It links no UI toolkit. Your host supplies a clock, input,
a renderer and presentation; fabrum supplies state, layout, event handling,
commands and damage. Begin with the runnable
[headless example](../../examples/headless.zig), then replace its printing
with drawing. The [host reference](../platforms.md#the-host-contract)
defines the full boundary.

## Choose text and a surface together

Build fabrum with `.platform = .none`. Choose a renderer that accepts your
surface: a portable pixel renderer for a framebuffer, or an enabled Quartz
or Cairo renderer for a context surface. Construct
`app.Runtime(.{ .Text = Renderer.Text })` and pass the renderer's
`text_context`; otherwise measurement and drawing can disagree about line
breaks and hit boxes. Load fonts before measuring. A missing required text
context panics during runtime initialization.

`Surface.Pixels` has pixel width/height, byte stride, pixel format and scale.
The viewport given to `frame` is its `pointSize()`, not its raw pixel size
when scale differs from one. Premultiplied RGBA/BGRA suits transparent
overlays; `gray8` is opaque, with white as the cleared background. Keep
pixel buffers four-byte aligned for renderers that write whole pixels.
Choose a renderer with the format you actually need: z2d supports gray8;
ThorVG's companion does not.

## Supply a wakeup and minimal services

Keep the host at a stable address for callbacks. This host records wakeups
atomically and supplies close/quit without implementing dialogs or choosers:

```zig
const Host = struct {
    wake: std.atomic.Value(bool) = .init(false),
    running: bool = true,
    presents: usize = 0,
    last_refresh: app.Refresh = .content,
    pub fn platform(self: *Host) app.Platform {
        return .{ .ptr = self, .vtable = &.{ .requestFrame = requestFrame } };
    }
    fn requestFrame(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.wake.store(true, .release);
        // A real host also signals its event loop here.
    }
    pub fn services(self: *Host) app.platform.Services {
        return .{ .ptr = self, .vtable = &.{ .quit = quit, .close = quit } };
    }
    fn quit(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.running = false;
    }
    fn present(self: *Host, _: layout.Surface.Pixels, _: []const Rect, hint: app.Refresh) void {
        self.presents += 1;
        self.last_refresh = hint;
    }
};
```

`requestFrame` can run on a posting thread. A real implementation must signal
a thread-safe event, post a toolkit wake event or wake a poller; setting a
flag alone does not wake a sleeping event loop. Coalesce wakes if the
underlying queue is bounded. Do not run `frame` in the callback. The loop
thread owns updates, views, layout and drawing.

`Services` is separate from `Platform`: the latter only wakes the loop.
Leaving service entries null enables runtime fallbacks or returns
`Unsupported`, as [services](services.md) describes. A host may provide
just a keyboard or clipboard while all its widgets remain drawn.

## Run one event-loop turn

This example uses the [BoxRenderer](writing-a-renderer.md#start-with-a-contract-checked-renderer)
for a renderer-independent smoke test and the
[first-app Counter](first-app.md#write-the-component) as its root:

```zig
fn hostTurn(rt: *app.Runtime(.{ .Text = BoxRenderer.Text }), host: *Host, renderer: *BoxRenderer, pixels: layout.Surface.Pixels, now: std.Io.Timestamp) !void {
    const due = rt.nextFrame() orelse return;
    if (due.nanoseconds > now.nanoseconds) return;
    _ = try rt.frame(Counter, .{}, pixels.pointSize(), now);
    const changed = try rt.damage();
    if (changed.len > 0) {
        try layout.draw(renderer, rt.commands(), .pixels, pixels, changed);
        host.present(pixels, changed, rt.refresh());
    }
}

fn hostExample(gpa: std.mem.Allocator, io: std.Io) !void {
    var host: Host = .{};
    var renderer: BoxRenderer = .{};
    var pixels: [320 * 200]u8 align(4) = undefined;
    const surface: layout.Surface.Pixels = .packed_(&pixels, 320, 200, .gray8);
    var rt: app.Runtime(.{ .Text = BoxRenderer.Text }) = try .init(gpa, .{
        .io = io,
        .text_context = renderer.text_context,
        .platform = host.platform(),
        .services = host.services(),
        .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
    });
    defer rt.deinit();
    try hostTurn(&rt, &host, &renderer, surface, .zero);
    _ = try rt.mouse(.{ .position = .init(20, 50) });
    _ = try rt.key(.{ .key = .tab });
    _ = try rt.textInput(.{ .commit = "text from an input method" });
    try rt.cancelPointer();
    try hostTurn(&rt, &host, &renderer, surface, .fromNanoseconds(16_000_000));
    rt.cancelTasks();
    // Stop domain services and external posters before rt.deinit().
}
```

BoxRenderer intentionally ignores text and draws only test boxes. Substitute
a production renderer and its fonts to make the counter readable. The
example performs bounded turns so a test can run it without a live toolkit.
To connect it to your real loop:

1. Initialize the renderer and runtime once. Keep all callback targets,
   root values and borrowed services alive at their stored addresses.
2. Drain input on the loop thread and call the runtime input methods. Pass
   unconsumed events to the underlying application when hosting an overlay.
3. Read a monotonic host timestamp. If `nextFrame()` is due, call `frame`
   with current props and viewport, then consume its commands before the
   next frame invalidates them.
4. Call `damage()` once for the frame you intend to present. If regions
   changed, draw those regions, then present with the following `refresh()`.
5. Check `nextFrame()` again: arrange a display-paced turn for immediate
   animation, arm a timer for a future deadline, or sleep until input/wakeup
   when it is null. Repeat while the host is running.

The first frame is due immediately. Input and queued messages make another
frame due. A host-side props or viewport change must also run a frame;
`nextFrame` cannot detect a variable you changed outside the runtime.
A resize changes the next damage to the full viewport. Exposure or lost
framebuffer contents needs a full redraw even if state is unchanged: force
a frame when needed and draw/present the whole viewport instead of trusting
a retained-pixel damage history. Damage assumes the previous pixels remain.

`ui.animate()` can request immediate work every frame. Never drain that in
an unbounded busy loop; pace it to the display. An event-driven host may
bound the number of immediate frames per turn and rearm the next event.
An e-ink host should advertise no decorative animation and apply a
panel-specific refresh policy.

## Translate input faithfully

`mouse` takes the current pointer position, all currently pressed buttons,
scroll delta in points, optional trackpad gesture phase, modifiers and
long-press indication. A release sends an empty button set. Convert a
line-stepped wheel to points yourself. Use `cancelPointer()` when the
host loses capture, including application deactivation, so a pressed
control is not left stuck. Input is hit-tested against the previous layout.

`key` takes meaning, physical identity when known, modifiers and phase.
Use lowercase unshifted characters for `.char`; `text` is the UTF-8 a
non-IME key actually types. Hosts with an IME send committed text through
`textInput` instead of inserting it twice. Preedit is accepted but drawn
preedit display is not implemented. `Runtime.cursor()` tells a desktop
host which cursor to show; focus/text-input queries support its keyboard
and IME integration. The `none` namespace also supplies X11-keysym key and
text conversion helpers for RFB-style input.

The boolean from input methods says whether fabrum took the event. Respect
it when an overlay must let unhandled input reach content below. A custom
content's own drawing does not automatically consume input; declare keyed
event handlers for that surface.

## Draw damage and apply refresh hints

`rt.commands()` returns the last frame's commands, also returned by `frame`.
Both commands and their content pointers are valid only until the next
frame. `damage()` compares the final commands with the previous call and
returns point-space regions valid until the next damage call. If you run
several frames before presenting, compare and draw the final one; do not
advance damage history for intermediate frames that you discard.

Read `refresh()` after `damage()`: the damage call captures the strongest
accumulated hint and resets the pending hint for future work. `interactive`
marks drags and scrolling, `content` ordinary updates, and `page` an
explicit quality/full refresh request. A host with no refresh cost can
ignore the hint. An e-ink host maps it to panel waveforms and may schedule
a cleaning update after fast interactions. A quality refresh may require
presenting the existing framebuffer even with no changed pixels; treat
panel maintenance separately from pixel damage where needed.

With damage, a pixel renderer clears each region then redraws every command
that touches it, respecting clips and paint order. Preserve pixels outside
those regions. For a transparent overlay, composite it over the unchanged
underlying scene using premultiplied-alpha composition. Context renderers
do not clear the host context; paint/clear the relevant background first.

## Describe capabilities and injected resources

Set capabilities to match the actual device, not merely `none`:
pointer kind, hover, full/reduced/no animation, color/gray levels, and
physical/on-screen/no keyboard. The example describes touch e-ink. `none`
defaults to desktop-like capabilities, so omitting these would permit
spinner animation and caret blink on a slow panel. Choose a `keymap` and
`theme`; grayscale defaults become high contrast.

Provide shared application values through `Options.provide`, distinct from
host `services`. Increase `context` capacity for large trees. A host with
native controls can also pass `Options.native`, but then it must implement
native reconciliation and scene presentation as described in
[writing a platform](writing-a-platform.md#add-native-controls-only-when-the-toolkit-has-them).

## Post from threads and shut down

Obtain `rt.poster()` and copy typed handlers to external workers. Posting
queues a message and calls your wakeup; only loop-thread delivery runs
update. The runtime allocator must support concurrent allocation. Explicit
post payloads transfer ownership, while `Reply.send` copies text into a
borrowed reply. A task's cross-thread progress uses a progress handle,
not a shared `*Task`; see [concurrency](concurrency.md).

Before a user-requested close, ask `shouldClose` and honor a guard's false
result. On actual shutdown, cancel/join runtime tasks before destroying
domain services. Stop other posters and service replies while the runtime
is live; then destroy the runtime, renderer and framebuffer. A posted
handler's target can disappear safely, but a destroyed runtime is never a
valid posting target. `on_terminate` ordering in toolkit hosts is explained
in [task shutdown](concurrency.md#shut-down-in-lifetime-order).
