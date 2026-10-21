# Run work without blocking the UI

Updates and views run on the UI thread. Put file reads, decoding, network
requests and CPU-heavy transformations in tasks so input and frames can
continue. A task is owned by a component instance and reports through typed
messages. Use a separately injected service when the work has a longer or
shared domain lifetime. The [concurrency reference](../app.md#concurrency)
holds the complete contract; [examples/tasks.zig](../../examples/tasks.zig)
exercises replacement ordering with real concurrent workers.

## Choose a command or a declaration

Use `ctx.run` for independent work initiated by a message, such as an export
that should not replace another export. Use `ctx.runKey` for the current
request in a named slot, such as searching after the query changes. Use
`ui.task` for data required while a screen or child is present, such as
loading the visible gallery. Do not launch an unkeyed command on every
frame.

Keys are local to the component instance. Keyed commands and declarations
use the same instance-local task manager; choose distinct names if they
represent independent work. An unkeyed command has no key to cancel or fake
individually. Component removal cancels its tasks regardless of how they
were started.

## Load data and clone the result

The loader below stands in for I/O by copying its input; it exercises the
same allocation, cancellation, progress and result rules as a file load:

```zig
const Loader = struct {
    pub const State = struct {
        result: ?[]u8 = null,
        progress: usize = 0,
        generation: usize = 0,
        failed: bool = false,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.result) |result| gpa.free(result);
        }
    };
    pub const Msg = union(enum) { load, independent, cancel, refresh, result: anyerror![]const u8, progress: usize };
    pub const Props = struct { name: []const u8 = "Gallery", declared: bool = true };

    pub fn load(task: *app.Task, name: []const u8, on_progress: app.Handler(usize)) anyerror![]const u8 {
        try task.checkCancel();
        try task.post(on_progress, 1);
        const progress = try task.progress(on_progress);
        try progress.post(2);
        return try task.gpa.dupe(u8, name);
    }
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Loader)) !void {
        switch (msg) {
            .load => try ctx.runKey("load", load, .{ ctx.props.name, ctx.handler(.progress) }, ctx.handler(.result)),
            .independent => try ctx.run(load, .{ ctx.props.name, ctx.handler(.progress) }, ctx.handler(.result)),
            .cancel => try ctx.cancel("load"),
            .refresh => state.generation += 1,
            .result => |result| {
                const borrowed = result catch {
                    state.failed = true;
                    return;
                };
                const owned = try ctx.gpa.dupe(u8, borrowed);
                if (state.result) |old| ctx.gpa.free(old);
                state.result = owned;
            },
            .progress => |value| state.progress = value,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Loader);
        if (props.declared) try ui.task("catalogue", .{ .restart = state.generation }, load, .{ props.name, on.handler(.progress) }, on.handler(.result));
        try ui.text(state.result orelse "Loading", .{});
    }
};
```

The first task parameter must be `*app.Task`. Its remaining parameters
match the argument tuple, and its exact return type, including an error
union, is the result handler's payload type. A function missing that first
parameter gives `app task: first parameter must be *app.Task`. Generic and
variadic functions are rejected. Use a concrete wrapper when adapting a
generic library operation.

Use `task.io` for I/O; it participates in cancellation. `task.gpa` is an
arena for this task's arguments, temporary work, results and progress data.
It is not the state's allocator. Use `defer` inside the task to close files
or release decoded handles: reclaiming arena memory cannot release external
resources. CPU loops should call `try task.checkCancel()` regularly so
replacement and shutdown can complete.

Results and task progress messages borrow task memory and bypass
`Msg.deinit`. The runtime keeps that arena until the function exits and
its messages have been delivered or discarded, then reclaims it. The
`.result` branch clones with `ctx.gpa` before storing. Simply assigning
`state.result = borrowed` creates a dangling reference after delivery;
passing a borrowed task result to a deinitializer can also double-free it.
The clone stays owned by state and is freed by `State.deinit`.

## Replace and cancel requests

A second `ctx.runKey("load", ...)` immediately suppresses the old task's
messages, including results already queued. It requests cancellation and
starts a background join. The replacement stays pending until the previous
function returns, including all its cleanup; the UI thread does not wait
for that cleanup. This is useful when operations in one slot must not
overlap, such as replacing a file reader that owns a resource.

Replacing a pending replacement discards its copied arguments without
running it. `ctx.cancel(key)` also drops an unstarted replacement. Different
keys run independently, even while canceled work is still unwinding; do
not use different keys when serialization is required. Both starting and
canceling can fail, so propagate their allocation/spawn errors. If a
cancellation worker cannot spawn, messages remain suppressed and shutdown
still joins the work.

Task errors arrive as the result's error union. Catch expected failures in
update to show a useful state. `error.Canceled` is suppressed rather than
delivered. Final-result enqueue failure logs the failure and drops the
result; it does not call the handler with an invented result. An I/O backend
without concurrency gives `error.ConcurrencyUnavailable`; the runtime does
not run blocking work inline as a fallback.

## Keep a screen-scoped task stable

`ui.task("catalogue", .{ .restart = state.generation }, ...)` starts after
the frame's views and layout finish. A spawn failure therefore comes from
`Runtime.frame`. With the same key and restart hash, the task keeps running
or remains completed; merely changing its arguments does not restart it.
Increment the generation when the user requests refresh. Use `.{}` for
options when no explicit restart value is needed.

For independent visible items, use keys such as `.{ "thumbnail", path }`.
Removing a declaration cancels it; reintroducing it creates work again.
Keep a stable key with a changing restart value when old work must finish
cleanup before its replacement; changing the key allows both to overlap.
A duplicate declaration in one frame gives `error.DuplicateTaskKey`;
changing the function behind a retained key gives
`error.TaskFunctionChanged`. Stateless child components have task scopes
too, so a gallery cell can own its own load without adding state.

## Pass data that can be copied safely

Arguments and bound handler payloads are copied before `run`, `runKey` or
`ui.task` returns. Slices, nested slices, arrays, structs, optionals, tagged
unions and error unions are copied recursively. It is safe to pass a
frame-arena string as a slice. Untagged unions are rejected because the
runtime cannot know which member to copy.

Owning containers are rejected in arguments and results: `ArrayList`, hash
maps, `ArenaAllocator`, allocators themselves, structs with a `capacity`
field or allocator field, and owning values nested in other copied values.
The diagnostic says to pass a slice or borrow a synchronized object with
a single pointer. Pass `list.items` for copied data; do not pass the list
and assume its capacity still describes the copied allocation.

A single pointer is borrowed, not recursively copied. It must refer to a
synchronized object that outlives cancellation and task shutdown. Never
pass pointers into a view's frame arena or a component's state: a new frame
or removed component can free that memory while cancellation is pending.
The checks deliberately reject some ordinary structs with ownership-shaped
fields; make a small plain argument type or pass its needed fields.

## Post progress from a producer thread

Use `task.post(handler, value)` on the task thread. If another thread needs
to report progress, create a copyable `Task.Progress(P)` handle first:

```zig
fn threadedWork(task: *app.Task, handler: app.Handler(usize)) anyerror!usize {
    const Producer = struct {
        fn run(progress: app.Task.Progress(usize)) void {
            progress.post(50) catch {};
        }
    };
    const progress = try task.progress(handler);
    var group: std.Io.Group = .init;
    defer group.cancel(task.io);
    try group.concurrent(task.io, Producer.run, .{progress});
    try group.await(task.io);
    try task.checkCancel();
    return 100;
}
```

The group is joined before returning, so the producer cannot outlive the
task's memory. `progress.post` is thread-safe and ignores posts after
cancellation or completion, including after the task record has been
reclaimed. Handles need no release, but all uses still require a live
runtime. A handle does not keep arena data alive. If a producer reads a
slice allocated in the task arena, join or otherwise synchronize it before
the task function returns. Posted slices must stay immutable through
delivery. Do not allocate from `task.gpa` concurrently; it belongs to the
task thread. The runtime allocator supplied at initialization must support
concurrent allocation for task queues and external posters.

## Run cleanup without a result message

This command borrows `Shared`, introduced in the [context example](components.md#provide-values-to-a-subtree). The test waits for the task before reading the shared value; a concurrent application must synchronize other access.

```zig
const Cleanup = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { clean };
    pub const Props = struct { shared: *Shared };
    fn clean(_: *app.Task, shared: *Shared) void {
        // Only this task accesses shared while it runs in this example.
        shared.saves += 1;
    }
    pub fn update(_: *State, _: Msg, ctx: *app.Update(Cleanup)) !void {
        try ctx.runKey("cleanup", clean, .{ctx.props.shared}, null);
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try widgets.button(ui, "clean", .{ .label = "Clean", .on_click = ui.messages(Cleanup).bind(.clean) });
    }
};

test "guide a plain void task accepts a null handler" {
    var shared: Shared = .{};
    var h: app.testing.Harness(.{}, Cleanup) = try .init(.{ .shared = &shared }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Clean");
    try h.runTasks();
    try std.testing.expectEqual(1, shared.saves);
}
```

A plain `void` task can use a null result handler; a task returning
`anyerror!void` still needs a handler for that exact error union. The
[tested command examples](../../test/compile/doc_snippets.zig) include
`runKey` cleanup work with a borrowed resource pointer and null handler.
Use a void command for work whose completion needs no model change, not to
hide failures that should be shown.

## Recognize blocked UI work

In Debug builds, the watchdog times updates and each view's own work,
excluding child render calls. The default budget is 16 ms. A warning looks
like `Loader.update(.load) took 24 ms (budget 16 ms)` with the actual
qualified component name. It is a diagnostic, not preemption: a blocking
update still blocks input. Move that work into a task, then use the warning
to check the UI-side processing of its result. `watchdog_ms = 0` or null
disables it; release builds omit the timing and logging.

## Use an injected service for shared work

A persistent connection, shared image cache or export that must outlive a
screen belongs to an injected domain service with its own lifecycle. Read
it through `ctx.use(Service)` or an explicitly provided mutable `*Service`.
A runtime task may borrow that service and use `task.io` to perform one
operation; synchronization and service lifetime remain your responsibility.
Do not move I/O back into update merely because it is behind a service
method. Use [contexts](components.md#provide-values-to-a-subtree) for
injection and `Poster` for service-owned asynchronous answers.

## Shut down in lifetime order

First stop accepting new domain work. Call `rt.cancelTasks()` before
tearing down anything tasks borrow; it cancels and joins them, suppresses
queued task messages and can block until cooperative tasks return. Then
stop independent producers and service replies while the runtime is still
alive. Destroy services and finally deinitialize the runtime. `rt.deinit()`
also cancels and joins tasks, but calling it after destroying their borrowed
services is too late.

AppKit and GTK cancel and join tasks before invoking `on_terminate`.
Use that callback to shut down application services. External posters and
progress handles must stop before their runtime is destroyed. A task that
ignores cancellation can delay both `cancelTasks` and application exit;
regular cancellation checks and cancelable I/O are part of its contract.

For deterministic tests of work, use
[task completion in the harness](testing.md#complete-tasks-without-io).
