# Platforms

A platform is what hosts a fabrum app. A toolkit platform owns the window and
its chrome, the event loop, the menus, the dialogs, the clipboard and the
standard controls; fabrum owns one host view per window and lays out
everything in it, native controls and drawn content alike. The `none`
platform has no built-in host: the app's own code drives the runtime, and
every widget is drawn.

For an event-loop walkthrough, see [hosting](guides/hosting.md); for a reusable
integration, see [writing a platform](guides/writing-a-platform.md).

## The build option

The platform is chosen when fabrum is built, with its `platform` option
(`-Dplatform=...` on the command line, `.platform = ...` in
`b.dependency`), independently of the target OS:

| Option | On | `app.platform.kind` | Status |
|---|---|---|---|
| `native` | macOS | `.appkit` | implemented |
| `native` | Linux | `.gtk` | implemented |
| `native` | Windows | `.win32` | initial implementation |
| `native` | wasm | `.web` | compile error |
| `gtk` | anywhere GTK 4 is | `.gtk` | implemented |
| `qt` | | `.qt` | compile error |
| `sdl` | | `.sdl` | compile error |
| `none` | anywhere | `.none` | implemented |

The resolver maps other non-wasm targets to `.gtk`, but the build only
automatically links GTK for `native` on Linux; use `-Dplatform=gtk` on
other targets with GTK.

`app.platform.kind` is known at compile time. Namespaces of platforms not in
the build (`app.platform.appkit` in a GTK build) are compile errors when
used, so code naming them sits behind a `kind` check; `app.platform.current`
is the namespace of `kind`. Using `fabrum.app` on a platform that isn't
implemented fails compilation with a message naming it and suggesting
`none`; `fabrum.layout` alone builds with any option.

## Overlay windows

For a worked badge with a separate controller, see the
[overlay window guide](guides/overlay-windows.md).

The policy-aware window API is implemented on AppKit, GTK and Win32.

`app.platform.current.Window(Root, policy)` creates a window type with an
`app.WindowPolicy` known at compile time. `WindowWith(Root, Renderer, policy)`
selects its renderer. Existing `App(Root)` and `AppWith(Root, Renderer)` keep
the default window policy. Open a descriptor with
`application.open(WindowType, props, window_options, init_options)` and borrow
it with `application.get(WindowType, id)`.

Policy fields select decorations (`system` or `none`), background (`system`
or `transparent`), level (`normal` or `floating`), activation (`normal` or
`never`), pointer input (`normal` or `passthrough`), shadow (`system` or `none`),
and placement (`automatic` or `positioned`). Defaults preserve ordinary
application windows. Size, title, initial `visible` state, and `position`
belong to runtime window options. Positioned AppKit coordinates are screen
points measured from the primary screen's top-left corner. Win32 positions are
the outer window's top-left in virtual-desktop physical pixels, including
negative coordinates on monitors left of or above the primary monitor. On
Win32, `position` must be supplied exactly when `placement = .positioned`;
inconsistent options, nonfinite coordinates or coordinates outside signed
32-bit bounds return `error.InvalidWindowPosition` before native allocation.

AppKit supports the full overlay policy: borderless transparent windows,
floating level, nonactivation, whole-window pointer passthrough, no shadow,
and explicit positioning. Nonactivating windows do not become key when shown. Dialog and popup services return `error.Unsupported` on these windows; declarative native alerts return `error.NonactivatingNativeAlertUnsupported` before creating a sheet.
`passthrough` applies to the entire native window, including painted pixels;
it does not perform per-element hit testing. Keep controls in another window.

Win32 supports all seven policy settings. Transparent windows require
`decorations = .none` at compile time. The host composes premultiplied drawn
canvas layers into a per-pixel-alpha layered root window. Native HWND controls
are unsupported in transparent windows and return
`error.TransparentNativeControlsUnsupported`. All native declarations, including
menu items and alerts, are rejected in transparent windows. Use drawn controls
inside the overlay. Whole-window
passthrough includes painted pixels and applies across processes; never-activate
windows neither activate when shown nor take focus on pointer input. Native
creation remains hidden; the wrapper presents only when `visible` is true.
`automation().windowFrame()` reports outer bounds in physical desktop pixels.
Services that open dialogs or popup menus return `error.Unsupported` for
never-activate windows, preserving their nonactivation contract.
Declarative native alerts on those windows return
`error.NonactivatingNativeAlertUnsupported` before creating a dialog.

The current GTK 4 host supports borderless transparency and whole-window
pointer passthrough. Passthrough requires `decorations = .none` so a window
manager frame cannot intercept input. Transparency and input shaping depend
on the display/compositor and can fail during window creation with
`error.TransparentWindowUnsupported` or `error.PointerPassthroughUnsupported`
(`error.DisplayUnavailable` means no display could be opened). The built-in
GTK host rejects floating level, nonactivation, explicit global positioning,
and shadow suppression at compile time. A non-null runtime `position` on GTK
returns `error.PositionUnsupported`. These are limitations of this host,
not a claim that every Wayland or X11 implementation lacks these features.
No unsupported policy silently falls back. `app.window_policy.capability`
reports `supported`, `unsupported`, or `runtime` for each host/feature.

`application.hide(id)` hides a window while keeping its runtime and ID alive.
`show(id)` (also `present(id)`) shows it according to its activation policy.
These native application methods return false for stale IDs. Closing still
runs close guards and destroys the window. Direct window instances expose
`hide()` and `present()` too.

Run [`examples/overlay.zig`](../examples/overlay.zig) with
`zig build run-overlay` on macOS or Windows for the full native overlay, or
`zig build run-overlay -Dplatform=gtk` for its explicitly named GTK transparent
badge variant. A separate controller window shows, hides, and quits the
click-through badge. GTK keeps its normal activation, stacking, shadow, and
placement behavior.

`zig build test-overlays` exercises native visibility, policy identity, focus,
state preservation, and teardown. It writes `/tmp/fabrum-overlay-appkit.png`
or `/tmp/fabrum-overlay-gtk.png` for alpha inspection. GTK 4.24.1 on macOS
currently emits `gdk_surface_thaw_updates` criticals when hiding and showing
a window; `G_DEBUG=fatal-criticals` therefore aborts this test. The independent
[`test/gtk_hide_repro.c`](../test/gtk_hide_repro.c) reproduces it without Fabrum.
The regular test still checks the lifecycle assertions; this does not establish
GTK behavior on other display backends.

On Windows, `zig build test-overlays` checks live root upload pixels and PNG
alpha, actual cross-process pointer passthrough, focus preservation, visibility,
positioning, empty-scene clearing, and bounded composition recovery. It is also
included in the sequential `test-windows` suite. Use
`zig build build-win32-overlays check-win32-policies` for compile-only checks.
The desktop regression uses the current monitor; physical mixed-DPI transitions
and real driver resets still require manual validation.

## Multiple windows

Start with the [multiple-window guide](guides/multiple-windows.md) for ownership,
shared documents and closing behavior.

AppKit, GTK and Win32 expose `Application` (or `ApplicationWith(Renderer)`) for
programs with multiple windows. Initialize it at a stable address with
`init(gpa, io, .{})`, then call
`openWindow(Root, props, window_options, init_options)` for each window.
The returned `app.WindowId` identifies that window until it closes. Each
window owns its component runtime, native controls, renderer, focus,
scrolling, tasks and damage. Windows may use different root component types.

[`examples/windows.zig`](../examples/windows.zig) is a complete example:
`zig build run-windows` opens two views of one document, and a button opens
more. The document and controller outlive their windows. Components borrow
a controller service through `provide`; it requests a frame in each live
window when shared document data changes. Component-local click counts
remain independent.

| Application operation | Effect |
|---|---|
| `openWindow(Root, props, window_options, init_options)` | Allocate and mount a window, returning its `WindowId`. |
| `open(WindowType, props, window_options, init_options)` | Open a descriptor with a compile-time policy; its renderer must match the application. |
| `show(id)` / `present(id)` | Show a live window according to its activation policy. Returns false for a stale ID. |
| `hide(id)` | Hide without destroying state or cancelling tasks. Returns false for a stale ID. |
| `get(WindowType, id)` | Borrow the exact descriptor type, including its policy; null for stale or mismatched IDs. |
| `requestFrame(id)` | Schedule that window to rebuild its view. Returns false for a stale ID. |
| `close(id)` | Request a guarded close, deferred until the current callback returns. Returns false for a stale ID. |
| `quit()` | Request application quit, asking each window's guard. |
| `window(Root, id)` | Borrow a typed window pointer for host integration or automation; null for a stale ID or the wrong root type. |
| `run()` | Run the application's single native event loop. |

Keep application operations on the native event thread. A borrowed window
pointer, native handle or automation value must not outlive its window.
Store `WindowId` for later operations: IDs carry generations, so closing
and reopening a window cannot retarget an old ID to the new window.
`Handler` values remain local to their runtime; do not send one through a
different window's `Poster`. For shared documents, notify the owning
application service and invalidate the affected window IDs.

Closing a window cancels its runtime tasks and disconnects native replies
before releasing its runtime. Task cancellation is cooperative. Work that
must outlive an editor window belongs to an application-owned service;
stop any external producers using that window's raw `Poster` before the
runtime is destroyed.

`Application.InitOptions` accepts `.quit_on_last_window_closed = false` to keep the application
running without windows; the default is true. An explicit application quit
still exits. Quit guards run one at a time. A window can approve with
`ctx.quit()` or cancel with `ctx.cancelClose()`; no window closes for that
quit until all have approved. `ctx.close()` approves only its own window's
close. Shared document state is not rolled back when a quit is cancelled.

`App(Root)` and `AppWith(Root, Renderer)` remain convenient single-window
entry points. The renderer contract is unchanged: every draw receives that
window's surface, commands and damage.

Custom hosts can use the toolkit-independent `app.Application` coordinator
with their own erased `app.Window` callbacks. Queue close/quit requests,
then call `drain()` at a safe point after runtime/native callbacks return.
The host is responsible for stable window storage, frame scheduling and
stopping callbacks before destroying a window.

## Win32 (Windows)

`-Dplatform=native` on Windows selects `app.platform.win32`, using Windows
controls and Direct2D/DirectWrite for drawn content. This implementation targets
Windows 10 version 1703 and later, including Windows 11. Build with Zig's Windows
toolchain and the Windows SDK. `zig build examples` builds the counter and
multi-window examples; `zig build run-counter` opens the counter.

This implementation provides buttons, checkboxes, text fields and areas,
sliders, progress indicators, dropdowns, radio groups, steppers, labels and
scrolling containers. It also provides a per-window menu bar, declarative
alerts, clipboard access, message/confirmation dialogs, file and directory
choosers, native popup menus and owned native text-entry requests. Full
AppKit/GTK parity is follow-up work.

Radio groups support rows or columns and an empty selection. Steppers use
floating-point ranges and increments, committing typed input on Enter or focus
loss. Menu shortcuts use Control with a single BMP character. Declarative
alerts disable their owning window until dismissed and deliver each button
response once. Run
`zig build test-win32-controls` for the native controls regression, also
included in `zig build test-windows`.

File and directory choosers use Windows' modern file dialog. File requests
support extension filters and return UTF-8 filesystem paths; directory requests
ignore extensions. Popup menus support nested submenus, disabled items, headers
and separators, and preserve the full `usize` item ID, including zero.
Requests copy their input and run through a shared queue. Closing an owner
cancels its queued and active requests. Run `zig build test-win32-services`
for the service regression, also included in `zig build test-windows`.
It separates injected replies from native popup selection, Unicode file and
directory selection, cancellation, owner closure and cross-window queuing.
Popup placement is checked at the current desktop DPI; cross-monitor DPI
transitions still need manual validation.

Native text measurements use the control font, with native ideal sizes for
buttons and radio items. Control fonts follow the window DPI. Labels support
point sizes, secondary text color, wrapping and read-only selection/copy.
Changing wrapping replaces the underlying edit HWND while retaining the widget
handle, text selection and focus. Other label style updates retain the HWND.
Run `zig build test-win32-metrics` for sizing, label and font-lifetime regressions.
This checks native line layout and GDI resource cleanup at the current monitor's
DPI; it does not compare raster pixels or exercise physical monitor transitions.
Custom dialogs own DPI-aware system message fonts; children borrow them until
replacement or destruction. Text service dialogs follow their owner palette,
high-contrast colors and font refresh, and relayout on DPI changes. Text entry
and response heights follow the installed font; response widths include measured
labels and padding. Text dialogs grow within the monitor work area and stack
responses on narrow work areas. Alert
buttons use native font measurements. Alert dialogs fit
the current monitor work area, with a keyboard-scrollable read-only body for
long messages. Some native control padding and minimum sizes remain fixed.
If response rows exhaust the work area, the dialog scrolls vertically and brings
each response into view on keyboard focus; all declared buttons remain available.

Native edit controls handle IME composition. Drawn fields display
underlined preedit separately from their model, replace the selection on commit,
and preserve it on cancellation. Win32 converts IMM UTF-16 cursor positions to
UTF-8 byte offsets, and places composition/candidate windows at the drawn caret.
Placement maps logical document points through the canvas's visible origin into
the input HWND, including native scrolling, rebasing and cropped viewports. Text remains
left-to-right; bidirectional shaping and IME reconversion are not implemented.

`Services.editText` uses an owned native EDIT request with OK/Cancel. It disables
its owner and occupies the shared service slot until completion. Closing the
owner detaches it, disposes its callback, and lets queued requests continue.
The native control supports password, numeric and multiline styles; URL/email
flags are hints with no special desktop keyboard. Password plus multiline is
unsupported. A nonzero `max_len` limits the accepted UTF-8 bytes: an over-limit
entry stays open for correction rather than truncating a Unicode character.
Embedded NUL or malformed UTF-8 requests fail. Native multiline replies retain
Windows CRLF line endings. Run `zig build build-win32-text` to compile without
opening windows, or `zig build test-win32-text` on a coordinated desktop.
The latter covers text selection/cancellation/owner close and synthetic
`WM_IME_*` strings, not real installed IME candidate selection. Interactive
testing with an installed IME and cross-monitor DPI changes remains necessary.

`automation().describeHit(x, y, buffer)` follows native child stacking and
ancestor clipping, returning `canvas layer N`, a native kind and hexadecimal
element ID, `window`, or `nothing`. Coordinates are client points.
`automation().snapshot(path, scale)` writes a PNG reconstruction of the client:
retained premultiplied canvas pixels and native controls painted through
`WM_PRINT`/`WM_PRINTCLIENT`, composed in HWND order with nested clipping.
It excludes the window frame, menus/popups in separate windows, desktop
occlusion, DWM effects and hardware surfaces that do not support native print
messages. It is not a screenshot of the final desktop compositor.
Null scale uses current physical client pixels; an explicit positive scale
is pixels per point. Minimized windows, pending/failed canvas uploads,
invalid dimensions/scales, destroyed owners and PNG write failures return
`SnapshotFailed`. Capture does not pump the event loop; allow scheduled
presentation to finish before calling it. Windows Imaging Component encodes
the PNG; the renderer links `windowscodecs`, `ole32` and `uuid` from the SDK.

Unchanged canvas layers and damage outside their visible slices are skipped.
Each scheduled paint fully redraws its bounded slice, preserving transparency
and command ordering; geometry, DPI/settings changes, exposure and lost targets
use that full fallback. Content/revision changes still use `CanvasDamage`.
Slices beyond its finite damage-history extent redraw on each present.
Direct2D target loss recreates the target
and retries presentation, with a bounded retry budget for an idle window.
Minimized windows retain their scene until restoration.

Win32 `Options.dark` is an explicit per-window preference: `false` uses Windows
system colors, `true` uses fabrum's dark palette. It is not an automatic
light/dark system preference. This matches AppKit's explicit Aqua/Dark Aqua
choice; GTK's `true` instead sets the toolkit's process-wide prefer-dark setting,
while `false` leaves GTK's existing setting alone. Win32 changes no global setting.
Windows high contrast overrides either preference with system colors. Text
fields, lists and labels use matching window text/background colors in high
contrast, independently of the button-face color. Settings, theme and system-color
notifications re-query accessibility/colors, refresh native fonts and request a
drawn frame without replacing controls or moving focus.

Window, scroll-document and dialog backgrounds and native text surfaces follow
the palette. Dark checkboxes/radios use documented per-HWND classic styling so
their text colors remain readable. Push-button faces, dropdown frames, sliders,
progress, menus and scrollbars retain system-painted chrome; this is not complete
native dark-mode skinning. Title bars request the documented
[`DWMWA_USE_IMMERSIVE_DARK_MODE`](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/apply-windows-themes)
hint; unsupported Windows versions keep their normal frame. No private APIs,
ordinals, registry writes or process-wide dark-mode switches are used.
[`WM_CTLCOLORBTN`](https://learn.microsoft.com/en-us/windows/win32/controls/wm-ctlcolorbtn)
cannot recolor native push-button faces.

`zig build test-win32-palette` tests color policy without a desktop.
`zig build build-win32-theme` compiles the desktop regression;
`zig build test-win32-theme` runs it. It checks simultaneous light/dark windows,
native text colors, focus and GDI lifetime over 25 refresh/dialog cycles. A local
per-window automation seam injects high-contrast color transitions and an 18-point
dialog font; no user/system settings change. The test checks a 200-line dialog
against the monitor work area, scrolls its body, and verifies all 60 responses
in a many-button dialog remain reachable by scrollbar and focus. DPI notifications run on the
same monitor. Real system theme/high-contrast changes, physical monitor transitions,
older-OS DWM fallback and final desktop appearance remain manual checks.

`zig build test-win32-rendering` checks uploaded canvas pixels, translucent
overlays, native/canvas stacking, layer removal, resize, minimize/restore and
recovery from injected target loss. It also runs a same-monitor DPI notification
check; physical cross-monitor DPI transitions, actual driver loss and final
desktop composition still need manual validation. This regression is included
in `zig build test-windows`.

Native scrolling containers clip a document containing both native controls
and drawn canvas layers, including nested containers. Scrollbars use the
available client area and clamp offsets when content or viewport sizes change.
Wheel input respects Windows scrolling settings and passes to the enclosing
container when an axis is disabled or its boundary is reached. Run
`zig build test-win32-scrolling` for the native scrolling regression; it is
also included in `zig build test-windows`.
Canvas HWNDs and bitmaps cover only the document's intersection with every
ancestor client rectangle. Native widgets remain in document coordinates;
rendering and input translate the visible slice origin at device pixel
precision. Bitmap allocation therefore depends on the viewport rather than
the document extent, including nested scroll views.
Win32 clamps native child positions to signed 16-bit coordinates. Beyond a
nearby scroll anchor the host rebases direct native children while retaining
logical frames and scroll offsets. Layer origins include this rebase; caret
and candidate placement converts logical document pixels by subtracting the
layer origin, then mapping the layer HWND to the destination HWND.

`zig build test-win32-capture` checks a two-million-point document, nonzero scroll
translation, bounded allocation, unchanged/changed scene redraws, far-document
native geometry/hits/pixels beyond the damage-history extent, hit stacking,
PNG native/canvas composition, scale/errors and injected recovery. Compile
without a desktop with `build-win32-capture`, `build-win32-rendering` and
`build-win32-scrolling`. For manual verification, move the window between
monitors with different DPI, scroll both nested axes and inspect native/drawn
alignment and clipping; minimize/restore and resize at a nonzero offset. Real
driver resets and final desktop composition remain manual checks; injection
exercises the target recreation path without changing machine settings.

Consumer executables must embed a Windows compatibility manifest declaring
Windows 8 or later support, Common Controls v6 and PerMonitorV2 DPI awareness.
The examples use [`src/app/platform/win32/windows.manifest`](../src/app/platform/win32/windows.manifest):
set `exe.win32_manifest = dependency.path("src/app/platform/win32/windows.manifest")`
in a consumer build, where `dependency` is its `b.dependency("fabrum", ...)`.
Compatibility declarations permit
the host's layered child canvas to compose drawn content with native controls.

### Windows validation and font lifetime

Run `zig build test examples`, `zig build test-windows`, and
`zig build check-win32-policies` before handing off Windows changes. The desktop
suite is sequential; do not run another GUI fixture alongside it. Build the
documented consumer with
`zig build --build-file test/compile/guide_project/build.zig -Dplatform=native`.
For Direct2D without the built-in window host, use
`zig build test examples -Dplatform=none -Ddirect2d=true`.

The font-refresh regression previously treated `GetObjectType(old_font) == 0`
as proof of disposal. That is not a valid lifetime oracle on the validation
machine: an isolated 20,000-cycle create/read/delete probe saw successful
`DeleteObject`, unreadable retired `LOGFONT` data and zero net GDI objects,
while `GetObjectType` still classified almost all retired handles as fonts.
Run `zig build test-win32-fonts` to reproduce without a Fabrum host or windows.
This probe is also part of `test` on Windows. It requires deletion to succeed
and retired data to be unreadable; it does not require a particular stale type
result. The theme fixture checks readable fonts before replacement/disposal,
all child borrowers using the readable replacement, retired data becoming
unreadable, and bounded GDI counts across 25 alert and 25 text-dialog cycles.
These checks preserve the resource-lifetime assertions instead of classifying
a stale handle as a live object.

The current validation environment has one 1920×1080 monitor at 100% scale and
English UK/Canada input profiles using the US keyboard layout. No physical
mixed-DPI transition or real composition-IME candidate interaction has been
validated there. The automated IME tests inject composition messages and query
IMM candidate placement at near/far scroll offsets; DPI tests send local
notifications at the current DPI. Neither substitutes for those manual checks.

## AppKit (macOS)

`-Dplatform=native` on macOS. Links AppKit, Core Graphics, Core Text, Core
Foundation and UniformTypeIdentifiers; the Objective-C half is
`src/app/platform/appkit/shell.m`.

- **`appkit.App(Root)`** runs a root component in an `NSWindow` whose
  content is fabrum's host view. It owns the runtime, the canvas's renderer
  and the native backend, and turns what AppKit reports into frames,
  pointer input, focus moves and native events. `appkit.AppWith(Root,
  Renderer)` takes another renderer for `.cg_context` surfaces.
  - `init(self, gpa, io, props, window: appkit.Options, options:
    InitOptions)`. `Options`: `title`, `width`, `height`, `min_width`,
    `min_height`, `dark`. `title` is a sentinel-terminated string; the
    defaults are 800 by 600 points, a 320 by 240 minimum, and `dark = false`.
    `InitOptions`: `provide` (root values),
    `context` (layout capacity), `watchdog_ms` (Debug budget per update and
    view, 16 ms by default; `0` or `null` disables it),
    `on_terminate` (called once when this window is torn down, after its
    runtime tasks have been canceled and joined; shared application services
    must outlive the other windows).
  - `run()` opens the window and runs the event loop; it never returns.
  - `runtime`, `viewport`, `handleOf(id)` (the `NSView` behind a native
    element, for automation), `mouse(...)` and `activate(...)` for scripts
    that feed input in process.
- **Canvas:** `fabrum.render.Quartz`, drawing into `CGContext`s in canvas
  layers (`NSView`s) stacked with the native controls in paint order. Core
  Text measures the drawn text as the native controls' is.
- **Controls:** the common set, plus `appkit.widgets.levelIndicator`
  (`NSLevelIndicator`). Menu items go in the menu bar (`NSMenu`); alerts
  are `NSAlert` sheets. Toolkit-only controls also require a native runtime
  backend: `levelIndicator` returns `error.NoNativeBackend` in a drawn
  harness or custom runtime without one. Check `ui.hasNativeWidgets()` and
  choose a common control as a fallback. Using the AppKit namespace on
  `none` is a compile error; guard it with `platform.kind`.
- **Services:** `message` and `confirm` (`NSAlert`), `menu` (`NSMenu`
  popup), `openFile` and `openDirectory` (`NSOpenPanel`, filtering files by
  extension through `UTType`), the clipboard (`NSPasteboard`), `quit` and
  `close` (subject to the application's last-window policy). No `editText`: drawn fields take
  keys. `shouldClose` is asked from `windowShouldClose:` and
  `applicationShouldTerminate:`.
- **`appkit.automation`:** what debug scripts do to a running app in
  process, without the system's event stream: `runOnMain`, `quit`, `close`,
  `usePrivateClipboard`, `clipboardText`, `answerFileChooser`, `snapshot`
  (the window's content as a PNG, at a scale, working while the screen is
  locked), `windowNumber`, `click`, `typeText`, `mark`, `commit`,
  `fieldText`, `newline`, `slide`, `select`, `step`, `scrollTo`, `tab`,
  `answerAlert`, `answerPopup`, `chooseMenu`, `resize`, `describeFocus`,
  `describeHit`, and `windowClick` and `windowKey`, which send events
  through the window (only while the session is unlocked). The Kitchen's
  script is built on these.

```zig
// Counter is the component from getting-started.md.
pub const Gui = appkit.App(Counter);

pub fn main(init: std.process.Init) !void {
    const gui = try init.gpa.create(Gui);
    try gui.init(init.gpa, init.io, .{}, .{ .title = "Gallery", .width = 800, .height = 480 }, .{
        // root values every view and update can `use`
        .provide = &.{ .of(&services), .of(&icons) },
        // tasks have finished unwinding; domain services can now shut down
        .on_terminate = .{ .ctx = &services, .call = shutdown },
    });
    gui.run();
}
```

## GTK 4

`-Dplatform=gtk` anywhere GTK 4 is, and `native` on Linux. Links `gtk4`
through pkg-config, which brings Cairo and Pango; the C half is
`src/app/platform/gtk/shell.c`. With Homebrew's GTK on macOS, Homebrew's
`pkgconf` must be first on `PATH` so the `.pc` files' private requirements
resolve.

- **`gtk.App(Root)`** and `gtk.AppWith(Root, Renderer)` (for `.cairo`
  surfaces) have the same shape as AppKit's: a `GtkWindow` whose content is
  fabrum's base canvas (a `GtkDrawingArea`) under a `GtkFixed` holding GTK's
  widgets and the canvas layers above them. The runtime's keymap is
  `.linux`.
- **Canvas:** `fabrum.render.Cairo`, with text set by Pango in the toolkit's
  font family, so drawn text measures like the labels beside it.
- **Controls:** the common set. Menu items go in a menu bar; alerts are
  `GtkAlertDialog`s.
- **Services:** `message`, `confirm`, `menu` (`GtkPopoverMenu`), `openFile`
  and `openDirectory` (`GtkFileDialog`), the clipboard (`GdkClipboard`;
  reading is asynchronous), `quit` and `close` (subject to the application's last-window policy); no `editText` either. `shouldClose` from `close-request`.
- **`gtk.automation`:** the in-process subset of AppKit's (`runOnMain`,
  `quit`, `snapshot`, `click`, `typeText`, `fieldText`, `newline`, `slide`,
  `select`, `step`, `scrollTo`, `tab`, `answerAlert`, `answerPopup`,
  `answerFileChooser`, `chooseMenu`, `resize`, `describeFocus`,
  `describeHit`).

For targeted automation, borrow `application.window(Root, id)` and call
its `automation()` method. Operations such as resize, snapshot and dialog
answers use that window; native control actions still take the control
handle. Keep these borrowed values within the window's lifetime.

`zig build test-windows` runs the native integration checks, opening real
windows and testing input isolation, close/quit guards, pending dialog
replies and task cancellation. Use `-Dplatform=gtk` for GTK; the usual
`zig build test` needs no visible windows.

## `none`: the app's own host

`-Dplatform=none`. No window, no toolkit, nothing linked, so it builds for
any target. The program is the host: it owns the loop, the clock, the pixels
and where input comes from. This is what a VNC server showing a fabrum
interface over a remote screen, an overlay drawn into a game's frames, an
e-reader's toolkit and a test rig use.

### The host contract

The runtime is single-threaded: call it from one thread. Other threads only
post messages (`Runtime.poster()`), or task progress through a
`Task.Progress(P)` handle. These wake the host through the
`app.Platform` it passes in `Options.platform` (one function,
`requestFrame`, which must be thread-safe).

1. **Make the runtime** with the renderer's text: `app.Runtime(.{ .Text =
   Renderer.Text })`, with no `native` backend, and the look of drawn widgets
   in `Options.theme` (a translucent `window_background` makes an overlay).
   Describe the host in `Options.capabilities` (a touch screen without hover,
   no animation, a grayscale panel, an on-screen keyboard), give it
   `Options.services` for what it does beyond the viewport (each optional),
   and `Options.keymap` if its users expect another platform's editing keys.
2. **Feed input** as it arrives, in the viewport's points from its top left:
   `rt.mouse(event)` for pointer moves, buttons, long presses and scrolling
   (with the gesture's phase from a trackpad), `rt.key(event)` for keys (with
   the text they type, if the host knows it), `rt.textInput(input)` for text
   committed without keys (an input method, a system keyboard's result).
   Each returns whether the app took the event; pass on what it didn't.
   Hosts that mix drawn and native scrolling can use `rt.mouseResult(event)`:
   `handled` has the same meaning as `mouse`, while `scrolled` reports whether
   a drawn scroller absorbed any wheel delta. Forward a wheel event to a native
   ancestor when `scrolled` is false, even if painted content handled the pointer.
   - A pointer event is taken when the pointer is over something of the app
     (anything but the root that paints or takes a press there), for the
     rest of a press that began over one, and when a wheel scrolled
     something. `rt.cancelPointer()` ends a press the host lost.
   - Focused drawn elements take keys; an unconsumed unmodified Return
     can also activate a drawn default button without focus. Pressing
     something that takes focus gives it; pressing nothing of the app's
     clears it; `rt.focusMove` moves it from the host.
   - `app.platform.none.keyFromX11Keysym` and `textFromX11Keysym` map RFB
     (VNC) keysyms to keys and the text they type.
3. **Run a frame** when `rt.nextFrame()` says so: null when nothing is due
   (wait for input or a post), or the time the next frame is due (a timer, a
   caret blink, an animation); a time at or before now means as soon as
   possible. `rt.frame(Root, props, viewport, now)` takes the host's clock
   and returns the render commands.
4. **Take what changed**: `rt.damage()` gives the regions that changed since
   the host last asked (the whole viewport the first time and after a
   resize), in whole points, and `rt.refresh()` how to show them:
   `interactive` during a drag or a scroll, `content` otherwise, `page`
   when the app asked. E-ink hosts map these to fast, quality and full
   updates; others ignore them. No regions: nothing to redraw.
5. **Draw** the commands into the host's pixels, redrawing only the damage:
   `fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, damage)`.
   Pixels are premultiplied RGBA or BGRA, or opaque `gray8`, at the host's
   scale; outside the damage they are left as they were, inside it the
   renderer clears them first, so a buffer with alpha always holds the
   overlay alone.
6. **Present**: composite the damaged regions over whatever is under the
   overlay, upload them, send them as RFB rectangles, or hand them to the
   panel with the refresh it asked for.

```zig
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{
    .io = io,
    .text_context = renderer.text_context,
    .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
    .services = host.services(), // dialogs, a system keyboard, quitting: what the host has
});
defer rt.deinit();
while (host.running) {
    for (host.pendingInput()) |input| {
        const taken = switch (input) {
            .pointer => |event| try rt.mouse(event),
            .key => |event| try rt.key(event),
            .text => |text| try rt.textInput(.{ .commit = text }),
        };
        if (!taken) host.passOn(input);
    }
    const now = host.clock();
    if (rt.nextFrame()) |due| if (due.nanoseconds <= now.nanoseconds) {
        const commands = try rt.frame(Root, props, viewport, now);
        const damage = try rt.damage();
        if (damage.len > 0) {
            try fabrum.layout.draw(&renderer, commands, .pixels, pixels, damage);
            host.present(pixels, damage, rt.refresh());
        }
    };
    host.sleepUntil(rt.nextFrame(), host.inputArrives());
}
```

(`host` is whatever the program has; `test/compile/doc_snippets.zig` runs
this loop against a host made of data.) [`examples/headless.zig`](../examples/headless.zig) is a
complete, runnable host that prints instead of drawing, and the Kitchen's
`src/none.zig` draws with z2d or ThorVG as an overlay and as an e-ink
panel, checking the damage against a full redraw at every step.

Before destroying services borrowed by tasks, call `rt.cancelTasks()` to
cancel and join the work; `rt.deinit()` also does this. Cancellation is
cooperative, so a task that ignores it can delay shutdown. Keep the runtime
alive until all posters, service replies and progress producers have stopped.

### Services

`app.platform.Services` is a vtable of what a host does beyond its window.
Every entry is optional; the runtime falls back where it reasonably can:

| Service | Request | Reply | Without it |
|---|---|---|---|
| `message` | `MessageRequest` (`title`, `text`, `kind`, `timeout_ms`) | | a dialog drawn by fabrum, modal; `kind` and timeout ignored |
| `confirm` | `ConfirmRequest` (`title`, `text`, one to three `buttons`, `default`, `kind`) | `IndexReply` (the index, or null) | a drawn dialog; `kind` ignored |
| `menu` | `MenuRequest` (`items`, `at`, `anchor`) | `IndexReply` (the `MenuItem.id`, or null) | a drawn menu |
| `editText` | `TextRequest` (`title`, `initial`, `flags`: url, numeric, password, email, multiline; `max_len`) | `Reply` (the text, or null) | `error.Unsupported`; drawn fields take keys themselves |
| `openFile`, `openDirectory` | `FileRequest` (`message`, `extensions`) | `Reply` (the path, or null) | `error.Unsupported` |
| `writeClipboard`, `readClipboard` | text; `Reply` | | a clipboard private to the program |
| `quit`, `close`, `cancelClose` | | | `error.Unsupported` |

`Services.Error` is `error{Unsupported, OutOfMemory, ServiceFailed}`.
`confirm` rejects zero or more than three buttons with `error.ServiceFailed`.
Directory choosers use `FileRequest.message` and ignore its `extensions`.
GTK ignores dialog `kind`; AppKit uses it for the alert style. Hosts must
copy request data they retain after the service call returns.

Replies are thread-safe and may be sent later, from any thread:
`reply.send(text)` copies the text and posts it as a message that borrows
the copy, which is freed after delivery or discard. `IndexReply.send(index)`
posts an index or null. Replies require a live runtime, and cross-thread
posting requires its allocator to support concurrent use. A host that can't
do something leaves the entry null. The Kitchen's `EinkServices` in `src/none.zig` is a minimal one (a keyboard
that answers a text entry, a dialog answered with its first button).

### What the runtime needs from the host

| `Runtime.Options` | A `none` host sets |
|---|---|
| `io` | its `std.Io` |
| `text_context` | the renderer's, so text is measured as it is drawn |
| `platform` | an `app.Platform` whose `requestFrame` wakes the loop, if other threads post |
| `theme` | the look of drawn widgets; made high-contrast on a gray display |
| `capabilities` | what the display and input are |
| `keymap` | `.macos`, `.windows` or `.linux` |
| `services` | the table above |
| `context` | a larger `breadth` for long lists |

## Writing an external platform package

An external platform (an e-reader's toolkit, a game engine's UI layer) is a
`none` host packaged as a Zig module that apps depend on, with its own
`Services` and, if the toolkit has native widgets, an `app.native.Backend`
in `Options.native`. fabrum-platform-inkview is the model:

- The package's module imports `fabrum` and its renderer but **does not
  depend on fabrum** except lazily, for its own tests. The app gives it the
  fabrum it uses, built with `.platform = .none`, so there is one fabrum in
  the program:

```zig
const inkview = b.dependency("fabrum_platform_inkview", .{ .target = target, .optimize = optimize });
const platform = inkview.module("fabrum-platform-inkview");
@import("fabrum_platform_inkview").addFabrum(platform, fabrum_mod);
exe.root_module.addImport("fabrum-platform-inkview", platform);
```

  where `addFabrum` is the package's `pub fn` that calls
  `platform.addImport("fabrum", fabrum)` on its module and on the renderer
  module inside it.

- It exposes `run(Root, gpa, io, props, options)`, which makes the runtime
  with the device's `Capabilities` (InkView: touch, no hover, no animation,
  `gray16`, an on-screen keyboard), the theme, the keymap and its services,
  and hands the toolkit a handler.
- Its host (`src/host.zig` there) maps the toolkit's events to
  `Runtime.mouse`, `key`, `cancelPointer` and `textInput`; runs frames
  after every event while `nextFrame` says one is due, arming a toolkit
  timer for a later one; draws the damage into the framebuffer with the
  renderer; and turns `Runtime.refresh` into the panel's updates (InkView:
  `page` is a full update, `content` a partial one per region,
  `interactive` a fast gray or A2 update with hysteresis and a cleaning
  full refresh afterwards).
- Posts from other threads go through `app.Platform.requestFrame`, which
  sends the toolkit an event to wake its loop.
- Its services wrap the toolkit's modal UI (InkView's `Dialog3`,
  `OpenMenu`, `OpenKeyboard`) and answer through `Reply` and `IndexReply`;
  frames are held while one is up and everything is redrawn when it closes.
- A fake toolkit (`src/fake.zig`) lets the host be tested without the
  device, and the app's components are tested with `app.testing.Harness` as
  on any platform.

## The native contract

Toolkit platforms, and external packages with native widgets, implement
`app.native.Backend`: `create`, `update`, `destroy`, `setFrame`,
`setContentSize`, `measure`, `setValue`, `composing`, `canFocus`, `focus`,
`present`, `theme` and the optional `reparent`. Each frame the runtime
reconciles the declared elements (`native.Spec` plus a `native.Value`)
against the native objects it made, keyed by 64-bit element ID, and hands
the backend a `native.Scene`: canvas layers interleaved with native views
in paint order, and the same for each native container. Events come back
through `Runtime.nativeEvent(id, event)`. `app.testing.NativeTree` is a
backend made of data, which the harness uses. The full description is in
`src/app/native.zig` and `docs/hybrid-design.md` §2 to §9.
