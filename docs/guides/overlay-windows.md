# Build an overlay window

A desktop status badge needs its own native window when it must appear over
other applications. A tooltip or modal inside an existing window can use a
[layout overlay](layout.md#attach-an-overlay-and-preserve-an-aspect-ratio).
Native window behavior is selected by `app.WindowPolicy` at compile time.

## Choose the behavior explicitly

| Setting | Effect |
|---|---|
| `decorations = .none` | Remove the system title bar and frame. |
| `background = .transparent` | Let unpainted pixels show the desktop beneath. |
| `level = .floating` | Use the host's floating/topmost window level. |
| `activation = .never` | Show without taking keyboard activation. |
| `pointer = .passthrough` | Pass pointer input through the entire window, including painted pixels. |
| `shadow = .none` | Request no native window shadow. |
| `placement = .positioned` | Use an explicit runtime position. |

These settings are independent. Transparency alone does not promise
click-through behavior, and floating does not imply nonactivation. A
passthrough window cannot contain usable pointer controls; keep Show, Hide
and Quit in a separate ordinary window. Nonactivating windows cannot serve
as keyboard editors.

AppKit and Win32 support all seven settings. GTK supports borderless windows
and checks transparency and pointer passthrough against the current display.
Its built-in host rejects floating level, nonactivation, positioning and
shadow suppression at compile time. If those are essential to your app,
require a host that supports them. If a simpler GTK badge is useful, give it
an explicit policy and describe its different behavior to users.

## Define and open the badge

Use the [usual imports](README.md#about-the-code-in-these-guides). This
namespace defines a full desktop overlay on AppKit/Win32 and a separate GTK
badge that retains normal activation, stacking, shadow and placement:

```zig
const OverlayWindows = struct {
    const Desktop = app.platform.current;
    const desktop_overlay: app.WindowPolicy = .{
        .decorations = .none,
        .background = .transparent,
        .level = .floating,
        .activation = .never,
        .pointer = .passthrough,
        .shadow = .none,
        .placement = .positioned,
    };
    const gtk_badge: app.WindowPolicy = .{
        .decorations = .none,
        .background = .transparent,
        .pointer = .passthrough,
    };
    const StatusBadge = struct {
        pub const Props = struct { label: []const u8 };
        pub fn view(ui: *app.Ui, props: Props) !void {
            try ui.open(null, .{
                .layout = .{ .padding = .all(20) },
                .background_color = .rgb(35, 70, 130),
                .corner_radius = .uniform(16),
            });
            defer ui.close();
            try ui.text(props.label, .{ .font_size = 24, .color = .white });
        }
    };
    const BadgeWindow = Desktop.Window(StatusBadge, switch (app.platform.kind) {
        .appkit, .win32 => desktop_overlay,
        .gtk => gtk_badge,
        else => @compileError("This badge needs AppKit, GTK or Win32"),
    });

    pub fn openBadge(host: *Desktop.Application) !app.WindowId {
        return host.open(BadgeWindow, .{ .label = "Recording" }, .{
            .title = "Status badge",
            .width = 400,
            .height = 240,
            .visible = false,
            .position = if (app.platform.kind == .gtk) null else .{ .x = 80, .y = 80 },
        }, .{});
    }
};
```

Call `OverlayWindows.openBadge(host)` after initializing the application as
in [multiple windows](multiple-windows.md). It returns a live, initially hidden
window ID. Open your ordinary controller, call `host.show(id)`, then run the
application. The complete [overlay example](../../examples/overlay.zig)
connects Show, Hide and Quit buttons to these operations:

```sh
zig build run-overlay
zig build run-overlay -Dplatform=gtk
```

The first command uses the native host; macOS and Windows get the full policy.
The second explicitly selects GTK. Build/setup requirements are in
[your first app](first-app.md) and the [platform reference](../platforms.md).

The badge paints only its rounded content box; the remaining window area
stays transparent. Avoid a full-window opaque background when you want to
see through it. Win32 transparent windows reject every native declaration,
including menu items and alerts, with `TransparentNativeControlsUnsupported`.
Use drawn content (and `app.drawn` controls for interactive transparent
windows). `app.widgets` normally selects native controls on toolkit hosts.

## Handle placement and unsupported behavior

Policy values are immutable for a window type. Changing them means opening
a different descriptor, not changing runtime options. `Window(Root, policy)`
and `WindowWith(Root, Renderer, policy)` validate unsupported static settings
when instantiated. Win32 transparency requires no decorations; GTK passthrough
also requires no decorations. `app.window_policy.capability` reports
`supported`, `unsupported` or `runtime` for each host and feature; combinations
still must satisfy the policy validator.

Runtime title, size, visibility and position are supplied to `open`. On
AppKit, positioned coordinates are screen points from the primary screen's
top-left. On Win32, they are the outer window's top-left in virtual-desktop
physical pixels; negative coordinates are valid. Win32 requires a position
exactly when the policy says `positioned`, rejecting inconsistent, nonfinite
or out-of-range values with `InvalidWindowPosition`. Do not assume identical
numeric coordinates mean identical placement across DPI settings and hosts.
GTK rejects a non-null position with `PositionUnsupported`.

GTK can return `TransparentWindowUnsupported` or `PointerPassthroughUnsupported`
when its current display cannot provide those features, or `DisplayUnavailable`
when no display opens. Propagate or report these errors. No unsupported policy
silently becomes an ordinary window. A fallback must be a deliberate product
choice, such as offering a normal status window.

## Preserve nonactivation and lifetime

AppKit and Win32 never-activate windows reject native dialog and popup service
requests with `error.Unsupported`. This includes message/confirmation dialogs,
popup menus and file/directory choosers. Native declarative alerts return
`NonactivatingNativeAlertUnsupported` (Win32 transparent windows reject all
native declarations first). Route requests requiring interaction to your
ordinary controller. Installed services returning `Unsupported` do not trigger
the runtime's drawn fallback; see [services](services.md).

`host.hide(id)` preserves state and the ID; `host.show(id)` and `present(id)`
respect the activation policy. Neither changes passthrough. Use
`host.get(OverlayWindows.BadgeWindow, id)` when borrowing this exact descriptor;
a default-policy lookup with the same root does not match it. Keep the borrowed
pointer only while the window lives.

Provide a way to quit outside the badge. Hidden windows remain alive, so
closing only the controller does not trigger quit-on-last-window behavior.
Use application `quit()` to coordinate all windows and their close guards.

## Check the result on a desktop

Run `zig build test-overlays` on the intended native host, or add
`-Dplatform=gtk`. Check alpha against other windows, click through painted
pixels, show/hide repeatedly, and confirm that showing the badge leaves
keyboard focus in the other application. A headless harness cannot establish
these native properties.

The [platform reference](../platforms.md#overlay-windows) records automated
coverage and known limitations, including GTK's macOS hide/show diagnostic.
For Windows releases, also exercise physical mixed-DPI transitions; the
current-monitor tests do not establish that behavior.
