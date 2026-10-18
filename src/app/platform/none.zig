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
//! 2. **Feed input** as it arrives, in the viewport's points from its top
//!    left: `rt.mouse(event)` for pointer moves, buttons and scrolling, and
//!    `rt.key(event)` for keys. Both return whether the app took the event;
//!    pass on what it didn't (an overlay lets it through to the game; a VNC
//!    proxy forwards it to the server under the overlay).
//!    - A pointer event is taken when the pointer is over something of the
//!      app (anything but the root that paints or takes input there), and
//!      for the rest of a press that began over one.
//!    - Keys are taken only while a drawn element has focus: Tab and
//!      Shift-Tab move it, Escape clears it, Space and Enter click it.
//!      Pressing something of the app's that takes focus (a text field)
//!      gives it focus; pressing nothing of the app's clears it.
//! 3. **Run a frame** when `rt.nextFrame()` says so: it returns null when
//!    nothing is due (wait for input or a post), or the time the next frame
//!    is due; a time at or before now means as soon as possible.
//!    `rt.frame(Root, props, viewport, now)` takes the host's clock, which
//!    views see as `ui.now()`, and returns the render commands.
//! 4. **Take what changed**: `rt.damage()` gives the regions that changed
//!    since the host last asked (all of the viewport the first time, or
//!    after a resize), in whole points. Nothing changed: nothing to redraw
//!    or send.
//! 5. **Draw** the commands into the host's pixels, redrawing only the
//!    damage: `fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels,
//!    damage)`. Pixels are premultiplied RGBA or BGRA; outside the damage
//!    they are left as they were, and inside it the renderer clears them
//!    before drawing, so the buffer always holds the overlay alone.
//! 6. **Present**: composite the damaged regions over whatever is under the
//!    overlay (`out = overlay + under * (1 - overlay.alpha)`), upload them
//!    to a texture, or send them as RFB rectangles.
//!
//! ```zig
//! var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = io, .text_context = renderer.text_context });
//! while (running) {
//!     for (host.pendingInput()) |input| {
//!         const taken = switch (input) {
//!             .pointer => |event| try rt.mouse(event),
//!             .key => |event| try rt.key(event),
//!         };
//!         if (!taken) host.passOn(input);
//!     }
//!     const now = host.clock();
//!     if (rt.nextFrame()) |due| if (due.nanoseconds <= now.nanoseconds) {
//!         const commands = try rt.frame(Root, props, viewport, now);
//!         const damage = try rt.damage();
//!         if (damage.len > 0) {
//!             try fabrum.layout.draw(&renderer, commands, .pixels, overlay, damage);
//!             host.present(overlay, damage);
//!         }
//!     };
//!     host.sleepUntil(rt.nextFrame(), host.inputArrives());
//! }
//! ```
const std = @import("std");

const KeyEvent = @import("../input.zig").KeyEvent;

/// The key an X11 keysym stands for, as RFB (VNC) clients send them, or
/// null for keysyms that are text rather than keys.
pub fn keyFromX11Keysym(keysym: u32) ?KeyEvent.Key {
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
        else => if (keysym >= 0xfd00) .other else null,
    };
}

test "X11 keysyms map to keys, and printable ones are text" {
    try std.testing.expectEqual(KeyEvent.Key.tab, keyFromX11Keysym(0xff09).?);
    try std.testing.expectEqual(KeyEvent.Key.enter, keyFromX11Keysym(0xff0d).?);
    try std.testing.expectEqual(KeyEvent.Key.space, keyFromX11Keysym(0x20).?);
    try std.testing.expectEqual(KeyEvent.Key.other, keyFromX11Keysym(0xffbe).?); // F1
    try std.testing.expectEqual(null, keyFromX11Keysym('a'));
}
