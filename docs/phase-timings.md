# CPU phase timings

Timing support is compiled out by default. Enable the module build option with
`-Dphase_timings=true`, or pass `.phase_timings = true` when creating the
fabrum dependency in an application's `build.zig`.

Without that option, the runtime's counter field and runtime enable option are
zero-sized `void`, and all instrumentation calls are removed by comptime
branches, including in debug builds. `app.phase_timings_enabled` exposes the
build setting. The shared runtime core stays the same type for components.

In an instrumented build, set `.measure_phases = true` in `Runtime.Options`
or an AppKit, GTK, or Win32 window's `InitOptions` to start collecting.
Runtime collection defaults to off and performs no clock reads while off.
Enabled measurements use `std.Io.Clock.awake` in every optimization mode.

Read `runtime.core.timings.get(phase)` for `calls`, `total_ns`, `last_ns`,
and `max_ns`. Copy the timings value for a snapshot. Call `reset()` between
workloads to clear counters while keeping profiling enabled. Access and
reset on the runtime's owning thread, outside active measurements.

Phases:

- `frame`: inclusive `Runtime.frame` wall time.
- `messages`: deferred events, timers, and queued updates.
- `prepare`: arena reset, per-frame state reset, and backend theme lookup.
- `views`: component views and layout declarations, including overlays.
- `layout`: `computeLayout`, including text measurement it invokes.
- `scroll`: post-layout scroll clamping.
- `commands`: flattening the layout into drawing commands.
- `reconcile`: native reconciliation, scene construction, and synchronous
  backend work in `Reconciler.finish`.
- `cleanup`: focus maintenance, instance/task/timer/scroll cleanup.
- `damage`: each `Runtime.damage` call, separately from frame construction.
- `render`: each built-in desktop canvas drawing callback, including
  command coordinate translation and the renderer call.

The frame's component phases are consecutive and exclusive on successful
frames; `frame` includes them, so never add it to them. Damage and drawing
are separate operations, and multiple canvas layers can draw per frame.
`last_ns` is the last invocation, not a whole-frame aggregate. Errors still
record inclusive frame/damage/render time via defer, but unfinished internal
phases have no sample. Counters include warmup unless reset explicitly.

Rendering is **CPU wall time**, not GPU execution, compositor time, or
presentation latency. The host's native-widget drawing and presentation
outside the canvas callback are not measured. Text measurement in views
is charged to views; text measurement during layout is charged to layout.
No claim of exclusive text cost is made.

For a custom/headless host, instrument drawing and compositing separately:

```zig
const timings = &runtime.core.timings;
const started = timings.start(io);
defer timings.end(io, .render, started);
try fabrum.layout.draw(&renderer, runtime.commands(), .pixels, pixels, regions);
```

Compare equivalent workloads in the same optimization mode. Measure both
full redraws and small damage updates; idle windows and repeated unchanged
frames are not representative of scrolling or resizing. Keep screenshot
encoding and correctness-reference redraws outside production draw timings.

## Kitchen measurements

Profiling belongs to the kitchen test project. Its `src/none.zig` owns the
instrumented host and deterministic animation/resize workloads; its
`src/phase_trace.zig` buffers measurement records. There are no source-injection
helpers in fabrum.

From the kitchen checkout, use Zig 0.17's native local dependency override:

```sh
zig build measure -Doptimize=ReleaseFast -Dphase_timings=true --fork /path/to/fabrum -- --overlay --quiet --bench
zig build test-measure -Dplatform=none -Doptimize=ReleaseFast -Dphase_timings=true --fork /path/to/fabrum
```

The measurement build requires fabrum's `app.PhaseTimings` API. The separate
normal kitchen build remains compatible with its pinned dependency.
For repeated measurements and CSV/JSON summaries, kitchen supplies:

```sh
python3 tools/measure.py --fabrum /path/to/fabrum --runs 3 --out /tmp/kitchen-timings
```

That runner enables the build option, invokes the build, and summarizes its CSV output; it does not copy
projects, modify dependency manifests, or rewrite source. Optional `--renderer`
uses another native dependency fork. `metadata.json` records the exact command,
`run-N.log` retains raw output, and `frames.csv`/`summary.json` contain results.

Each CSV row is a presented update, with an explicit runtime-frame count,
final command count, region count, viewport dimensions, and summed damage
rectangle area (not a union). Phase costs refer to that same update.
Input and resize preparation are measured separately and included in total CPU
work. Frame time includes views, layout, commands, reconciliation and remaining
runtime work; do not sum those subphases with inclusive frame time.

The default scheduling policy keeps simulated time fixed while settling
immediate state changes, then advances once per presented update. The runner's
`--frame-policy batched` reproduces the original animation deadline-chasing loop
for A/B comparisons. Changing simulated time can also change animation damage.

Reference redraws, screenshot encoding, trace output and idle time are outside
timed intervals. Initial/cold updates remain a separate group. Results describe
the deterministic software host, not native OS presentation or GPU execution.
