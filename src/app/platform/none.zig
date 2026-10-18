//! The `none` platform: no built-in host. The app's own code drives the
//! runtime: it feeds input in, runs frames, and takes render commands and
//! changed regions out, for a portable renderer to draw into pixels. Every
//! widget is drawn by fabrum (`app.widgets` finds no native backend and
//! draws, as `app.drawn` does).
//!
//! This is for hosts fabrum can't know about: a VNC server that shows a
//! fabrum interface over (or instead of) a video stream, an overlay drawn
//! into a game's frames by a present hook, a test rig, or a program that
//! only wants layout. It links no OS UI library, so it builds for any
//! target.
//!
//! ## The host contract
//!
//! A host owns the loop, the clock, the pixels and where input comes from.
//! The runtime is single-threaded: call it from one thread. Other threads
//! only post messages (`Runtime.poster`), which wake the host through the
//! `app.Platform` it passes in `Options.platform`.
//!
//! 1. **Make the runtime** with the renderer's text: `app.Runtime(.{ .Text =
//!    Renderer.Text })`, with no `native` backend, and the look of drawn
//!    widgets in `Options.theme` (a translucent `window_background` makes
//!    an overlay).
//!    Describe the host in `Options.capabilities` (a touch screen without
//!    hover, no animation, a grayscale panel, an on-screen keyboard), give
//!    it `Options.services` for what it does beyond the viewport (dialogs,
//!    menus, a system keyboard, choosers, a clipboard, quitting; each
//!    optional, see `app.platform`), and `Options.keymap` if its users
//!    expect another platform's editing keys.
//! 2. **Feed input** as it arrives, in the viewport's points from its top
//!    left: `rt.mouse(event)` for pointer moves, buttons, long presses and
//!    scrolling (with the gesture's phase from a trackpad), `rt.key(event)`
//!    for keys (with the text they type, if the host knows it), and
//!    `rt.textInput(input)` for text committed without keys (an input
//!    method, a system keyboard's result). Each returns whether the app
//!    took the event; pass on what it didn't (an overlay lets it through
//!    to the game; a VNC proxy forwards it to the server under the overlay).
//!    - A pointer event is taken when the pointer is over something of the
//!      app (anything but the root that paints or takes a press there),
//!      for the rest of a press that began over one, and when a wheel
//!      scrolled something. `rt.cancelPointer()` ends a press the host
//!      lost.
//!    - Keys are taken only while a drawn element has focus: it gets the
//!      keys it declared, a text field its typing and editing commands,
//!      the frame's shortcuts their keys, and the runtime Tab, Shift-Tab,
//!      Escape, Space and Enter. Pressing something of the app's that
//!      takes focus (a text field) gives it focus; pressing nothing of the
//!      app's clears it; `rt.focusMove` moves it from the host.
//!    - `keyFromX11Keysym` maps RFB keysyms to keys; a printable keysym is
//!      the key's `text` too.
//! 3. **Run a frame** when `rt.nextFrame()` says so: it returns null when
//!    nothing is due (wait for input or a post), or the time the next frame
//!    is due (a timer, a caret blink, an animation); a time at or before
//!    now means as soon as possible. `rt.frame(Root, props, viewport,
//!    now)` takes the host's clock, which views see as `ui.now()`, and
//!    returns the render commands.
//! 4. **Take what changed**: `rt.damage()` gives the regions that changed
//!    since the host last asked (all of the viewport the first time, or
//!    after a resize), in whole points, and `rt.refresh()` how to show
//!    them: `interactive` during a drag or a scroll, `content` otherwise,
//!    `page` when the app asked for a full refresh. E-ink hosts map these
//!    to their fast, quality and full updates; others ignore them. Nothing
//!    changed: nothing to redraw or send.
//! 5. **Draw** the commands into the host's pixels, redrawing only the
//!    damage: `fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels,
//!    damage)`. Pixels are premultiplied RGBA or BGRA, or opaque `gray8`
//!    for a grayscale panel, at the host's scale; outside the damage they
//!    are left as they were, and inside it the renderer clears them
//!    before drawing, so a buffer with alpha always holds the overlay
//!    alone.
//! 6. **Present**: composite the damaged regions over whatever is under the
//!    overlay (`out = overlay + under * (1 - overlay.alpha)`), upload them
//!    to a texture, send them as RFB rectangles, or hand them to the
//!    panel with the refresh it asked for.
//!
//! ```zig
//! var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{
//!     .io = io,
//!     .text_context = renderer.text_context,
//!     .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
//!     .services = host.services(), // dialogs, a system keyboard, quitting: what the host has
//! });
//! while (running) {
//!     for (host.pendingInput()) |input| {
//!         const taken = switch (input) {
//!             .pointer => |event| try rt.mouse(event),
//!             .key => |event| try rt.key(event),
//!             .text => |text| try rt.textInput(.{ .commit = text }),
//!         };
//!         if (!taken) host.passOn(input);
//!     }
//!     const now = host.clock();
//!     if (rt.nextFrame()) |due| if (due.nanoseconds <= now.nanoseconds) {
//!         const commands = try rt.frame(Root, props, viewport, now);
//!         const damage = try rt.damage();
//!         if (damage.len > 0) {
//!             try fabrum.layout.draw(&renderer, commands, .pixels, pixels, damage);
//!             host.present(pixels, damage, rt.refresh());
//!         }
//!     };
//!     host.sleepUntil(rt.nextFrame(), host.inputArrives());
//! }
//! ```
//!
//! An external platform package (an e-reader's toolkit) is such a host,
//! with its own `app.platform.Services` and, if it has native widgets, an
//! `app.native.Backend` in `Options.native`.
const std = @import("std");

const KeyEvent = @import("../input.zig").KeyEvent;

/// The widgets of the `none` platform: the common set, drawn.
pub const widgets = @import("../drawn.zig");

/// The key an X11 keysym stands for, as RFB (VNC) clients send them: a
/// named key, or the character a printable keysym types (`.char`), which
/// is also the event's `text`, with `textFromX11Keysym`. Null for keysyms
/// that are neither.
pub fn keyFromX11Keysym(keysym: u32) ?KeyEvent.Key {
    if (keysym > 0x20 and keysym < 0x7f) return .{ .char = std.ascii.toLower(@intCast(keysym)) };
    // Latin-1 and the Unicode keysyms
    if (keysym >= 0xa0 and keysym <= 0xff) return .{ .char = @intCast(keysym) };
    if (keysym >= 0x0100_0100 and keysym <= 0x0110_ffff) return .{ .char = @intCast(keysym - 0x0100_0000) };
    return switch (keysym) {
        0xff09, 0xfe20 => .tab, // Tab, ISO_Left_Tab (Shift-Tab)
        0xff0d, 0xff8d => .enter, // Return, KP_Enter
        0x0020 => .space,
        0xff1b => .escape,
        0xff08 => .backspace,
        0xffff => .delete,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xffe1, 0xffe2 => .shift,
        0xffe3, 0xffe4 => .control,
        0xffe9, 0xffea => .alt,
        0xffeb, 0xffec => .super,
        0xffe5 => .caps_lock,
        0xff63 => .insert,
        else => if (keysym >= 0xffbe and keysym <= 0xffc9) .{ .f = @intCast(keysym - 0xffbe + 1) } else if (keysym >= 0xfd00) .unknown else null,
    };
}

/// The text a printable X11 keysym types, as UTF-8 in `buffer`, or "" for
/// keysyms that type nothing (named keys, modifiers).
pub fn textFromX11Keysym(keysym: u32, buffer: *[4]u8) []const u8 {
    const cp: u21 = if (keysym >= 0x20 and keysym < 0x7f) @intCast(keysym) else if (keysym >= 0xa0 and keysym <= 0xff) @intCast(keysym) else if (keysym >= 0x0100_0100 and keysym <= 0x0110_ffff) @intCast(keysym - 0x0100_0000) else return "";
    const len = std.unicode.utf8Encode(cp, buffer) catch return "";
    return buffer[0..len];
}

test "X11 keysyms map to keys, and printable ones type text" {
    try std.testing.expectEqual(KeyEvent.Key.tab, keyFromX11Keysym(0xff09).?);
    try std.testing.expectEqual(KeyEvent.Key.enter, keyFromX11Keysym(0xff0d).?);
    try std.testing.expectEqual(KeyEvent.Key.space, keyFromX11Keysym(0x20).?);
    try std.testing.expectEqual(KeyEvent.Key{ .f = 1 }, keyFromX11Keysym(0xffbe).?);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'a' }, keyFromX11Keysym('A').?);
    try std.testing.expectEqual(KeyEvent.Key{ .char = 'é' }, keyFromX11Keysym(0xe9).?);
    try std.testing.expectEqual(KeyEvent.Key{ .char = '日' }, keyFromX11Keysym(0x0100_65e5).?);
    try std.testing.expectEqual(KeyEvent.Key.unknown, keyFromX11Keysym(0xff7e).?); // Mode_switch
    try std.testing.expectEqual(null, keyFromX11Keysym(0x10)); // nothing
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("A", textFromX11Keysym('A', &buffer));
    try std.testing.expectEqualStrings("é", textFromX11Keysym(0xe9, &buffer));
    try std.testing.expectEqualStrings("", textFromX11Keysym(0xff09, &buffer));
}
