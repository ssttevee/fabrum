# Schedule timers and animate from time

Use a timer when time changes application state. Use frame scheduling when
a view can derive the displayed value directly from time. Both use the
host's clock, not sleeps in update or a background thread that repaints
continuously. The [time reference](../app.md#timers-and-animation) lists
the scheduling calls.

## Declare a clock and a one-shot notification

A timer is present while its view declares it. Bind its action to a message
just as you bind a button:

```zig
const Clock = struct {
    pub const State = struct { ticks: usize = 0, waiting: bool = true, last_tick: std.Io.Timestamp = .zero };
    pub const Msg = union(enum) { tick, ready };
    pub const Props = struct { running: bool = true };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Clock)) void {
        switch (msg) {
            .tick => {
                state.ticks += 1;
                state.last_tick = ctx.now();
            },
            .ready => state.waiting = false,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Clock);
        if (props.running) try ui.every("clock", .fromSeconds(1), on.bind(.tick));
        if (state.waiting) try ui.after("ready", .fromMilliseconds(250), on.bind(.ready));
        try ui.print(.{}, "Ticks: {d}", .{state.ticks});
        if (!state.waiting) try ui.text("Ready", .{});
    }
};

test "guide timers use virtual time and do not burst after a stall" {
    var h: app.testing.Harness(.{}, Clock) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(250));
    try h.expectText("Ready");
    try h.advance(.fromMilliseconds(750));
    try h.expectText("Ticks: 1");
    try h.advance(.fromSeconds(10));
    try h.expectText("Ticks: 2");
    h.props.running = false;
    try h.frame();
    try std.testing.expect(h.runtime.nextFrame() == null);
}
```

`ui.every(key, period, action)` first fires one period after its initial
declaration. Redeclaring the same key preserves the due time and updates
its action and period; changing the period does not reset the already
scheduled due time. Remove it for a frame to cancel it. Reintroducing it
starts a new schedule. Use positive periods; zero or negative periods
continually schedule already-due work and are not a useful clock.

After a long stall, the runtime sends one periodic action and schedules the
next deadline; it does not send a burst for every missed period. If elapsed
time matters, calculate it from timestamps rather than counting ticks.
`ctx.now()` is the last frame's host time. Timer messages run at frame time,
so the example records the time they were delivered; an ordinary input
message between frames sees the previous frame's time.

`ui.after(key, delay, action)` fires at its initial deadline and removes the
timer record. Remove the declaration in response, as `waiting = false`
does here. If the view keeps declaring it after it fires, the current
implementation creates a new timer with the same key and schedules another
firing. A one-shot notification therefore needs the state gate shown above.
Removing it before its deadline cancels it. Due timers fire before views
run, so a declaration removed during that frame cannot undo a firing that
was already due.

Keys are element-style keys scoped to the declaring component; keep timer
keys distinct from other timer declarations there. Rebuilding an action
each frame refreshes its current bound payload. A timer action can refer
to frame data for the same reasons as a click action; updates still copy
anything borrowed that they retain.

## Animate from elapsed time

A view can derive an animated width without changing state on every frame:

```zig
const Pulse = struct {
    pub const Props = struct { start: std.Io.Timestamp = .zero, duration: std.Io.Duration = .fromSeconds(1) };
    pub fn view(ui: *app.Ui, props: Props) !void {
        const elapsed = props.start.durationTo(ui.now()).toNanoseconds();
        const duration = props.duration.toNanoseconds();
        const t: f32 = std.math.clamp(@as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(@max(duration, 1))), 0, 1);
        const width = if (ui.capabilities().animates()) 20 + 80 * t else 100;
        if (t < 1 and ui.capabilities().animates()) ui.animate();
        try ui.open("bar", .{ .layout = .{ .sizing = .fixedXY(width, 8) }, .background_color = ui.use(app.native.Theme).accent });
        ui.close();
    }
};
```

Supply `start` from the same clock the host gives the runtime. Clamp the
elapsed fraction so a delayed frame jumps to its correct position. Counting
frames instead makes duration depend on refresh rate and event-loop load.
`ui.animate()` requests another frame as soon as the host can show one;
call it only while the animation is active. The example stops scheduling
at its destination and uses the final state immediately without full
animation capabilities. `Capabilities.animation` can be full, reduced or
none; `animates()` is true only for full. For reduced motion, choose a
meaningful static state or a restrained transition deliberately.

## Schedule a discrete visual change

```zig
const Deadline = struct {
    pub const Props = struct { due: std.Io.Timestamp };
    pub fn view(ui: *app.Ui, props: Props) !void {
        const waiting = ui.now().nanoseconds < props.due.nanoseconds;
        if (waiting) ui.frameAt(props.due);
        try ui.text(if (waiting) "Waiting" else "Due", .{});
    }
};

test "guide frameAt requests only the next visual boundary" {
    var h: app.testing.Harness(.{}, Deadline) = try .init(.{ .due = std.Io.Timestamp.zero.addDuration(.fromSeconds(2)) }, .{});
    defer h.deinit();
    try h.frame();
    try h.expectText("Waiting");
    try std.testing.expectEqual(h.props.due.nanoseconds, h.runtime.nextFrame().?.nanoseconds);
    try h.advance(.fromSeconds(2));
    try h.expectText("Due");
    try std.testing.expect(h.runtime.nextFrame() == null);
}
```

For a view that changes only at a future boundary, call `ui.frameAt(time)`
with that absolute host-clock timestamp. It avoids waking the host for
intermediate frames. Requests last one frame; the next view must request
the following boundary if there is one. `ui.caretVisible(key)` implements
this pattern for caret blink, going steady after inactivity and avoiding
blink on hosts without full animation.

Do not start a runtime task merely to sleep until a visual update. A timer
is cancellable by declaration and deterministic in tests. Use a task when
the deadline also involves I/O or a domain operation independent of the
screen's render schedule.

## Let the host sleep until work is due

`Runtime.nextFrame()` returns the last frame time when work is due now,
a future timestamp for the earliest timer or requested frame, or null when
the host may wait indefinitely for input or a posted message. Input and
message delivery make it dirty. Cross-thread posts additionally call
`Platform.requestFrame`, which must wake a sleeping host.

A toolkit `App` handles this for you. A [custom host](hosting.md) should
render at an appropriate display cadence when animation asks for immediate
frames, arm a timer for future deadlines, and sleep when there is no work.
Do not spin in a tight loop because `ui.animate` keeps returning an
immediate deadline. On e-ink, disabling decorative animation saves visible
panel refreshes as well as CPU time.

## Test time deterministically

The clock test above starts at zero and advances virtual time through
250 ms, 1 s and a stall. `h.advance(duration)` changes `h.now` and runs a
frame; it does not sleep. The animation tests in
[guide_snippets.zig](../../test/compile/guide_snippets.zig) assert the width
halfway through, the final idle state and the no-animation case. Timers,
commands and rendering therefore use the same clock in tests and on a host.
