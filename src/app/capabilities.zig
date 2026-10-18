//! What the platform can do, for drawn widgets and themes to adapt to:
//! whether there is a pointer that hovers, how much animation to show,
//! how many colors there are, and what kind of keyboard, if any. The
//! runtime provides one as a root value, read with
//! `ui.use(app.Capabilities)`: the platform's own on a toolkit platform,
//! and on `none` whatever the host sets in `Runtime.Options.capabilities`
//! (an e-reader says touch, no hover, no animation, gray16, an on-screen
//! keyboard).
const std = @import("std");

const platform = @import("platform.zig");

pub const Capabilities = struct {
    /// What points: a mouse (or trackpad), which hovers and has buttons,
    /// a touch screen, which only presses, or nothing.
    pointer: Pointer = .mouse,
    /// Whether the pointer can be over something without pressing, so
    /// hover styles mean anything. Touch screens have none.
    hover: bool = true,
    /// How much to animate: everything, only what carries meaning
    /// (reduced motion), or nothing, as on e-ink, where every frame is a
    /// visible refresh. Without `full`, carets don't blink.
    animation: Animation = .full,
    /// How many colors the display shows.
    color: Color = .color,
    /// What types: a physical keyboard, an on-screen one the platform
    /// shows on request (`Update.systemText`), or none.
    keyboard: Keyboard = .physical,

    pub const Pointer = enum { mouse, touch, none };
    pub const Animation = enum { full, reduced, none };
    pub const Color = enum {
        color,
        /// Many gray levels.
        gray,
        /// 16 gray levels, as most e-ink panels.
        gray16,
        /// 4 gray levels.
        gray4,
    };
    pub const Keyboard = enum { physical, on_screen, none };

    /// What a toolkit platform has: a mouse that hovers, animation and
    /// color, and a keyboard. Hosts on `none` set their own.
    pub const default: Capabilities = .{};

    /// The capabilities of a platform `kind`.
    pub fn of(kind: platform.Kind) Capabilities {
        return switch (kind) {
            .appkit, .win32, .gtk, .qt, .web, .sdl, .none => .{},
        };
    }

    /// Whether the display is grayscale, so themes should keep contrast
    /// high and not rely on color or translucency.
    pub fn isGray(self: Capabilities) bool {
        return self.color != .color;
    }

    /// Whether to animate continuously (blink a caret, spin a spinner).
    pub fn animates(self: Capabilities) bool {
        return self.animation == .full;
    }
};

test "capabilities say what to adapt" {
    const eink: Capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen };
    try std.testing.expect(eink.isGray());
    try std.testing.expect(!eink.animates());
    try std.testing.expect(!Capabilities.default.isGray());
    try std.testing.expect(Capabilities.of(.none).animates());
}
