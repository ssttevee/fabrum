//! Platforms: the native toolkit fabrum runs on. A platform owns the window
//! and its chrome, the event loop, menus, dialogs, the clipboard and
//! accessibility, and provides the native controls that `app.widgets`
//! stands for; fabrum owns one host view per window and lays out
//! everything inside it.
//!
//! Which platform a program uses is chosen when it is built, with fabrum's
//! `platform` option, and is known at compile time as `kind`, so apps can
//! pick widgets per platform:
//!
//! ```zig
//! switch (comptime fabrum.app.platform.kind) {
//!     .appkit => try fabrum.app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = 3, .max = 5 }),
//!     else => try fabrum.app.widgets.slider(ui, "rating", .{ .value = 3, .max = 5 }),
//! }
//! ```
//!
//! Each platform namespace (`appkit`, later `gtk`, `win32`, ...) has its
//! full catalogue of native widgets in its own `widgets`, next to what
//! every platform has. Namespaces of platforms not built in are compile
//! errors when used, so code naming them must sit behind a `kind` check.
//!
//! `headless` is always present: it keeps native widgets as plain data, for
//! `app.testing` on every platform and for programs without a window.
const std = @import("std");
const builtin = @import("builtin");

const options = @import("fabrum_options");

/// fabrum's `platform` build option.
pub const Option = enum {
    /// The OS's own toolkit: AppKit on macOS, later Win32 on Windows and
    /// the DOM on the web; GTK 4 on Linux, the first toolkit there.
    native,
    /// GTK 4, on any OS that has it.
    gtk,
    /// Qt, later.
    qt,
    /// No toolkit: native widgets as plain data, for tests and layout-only
    /// use.
    headless,
};

/// The toolkit a program is built for.
pub const Kind = enum { appkit, win32, web, gtk, qt, headless };

/// The `platform` option this fabrum was built with.
pub const option: Option = std.meta.stringToEnum(Option, options.platform) orelse
    @compileError("fabrum: unknown platform option '" ++ options.platform ++ "'");

/// The toolkit this program uses, from `option` and the target OS.
pub const kind: Kind = resolve(option, builtin.target.os.tag, builtin.target.cpu.arch);

/// The toolkit `option` means on a target.
pub fn resolve(o: Option, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) Kind {
    return switch (o) {
        .native => switch (os) {
            .macos => .appkit,
            .windows => .win32,
            else => if (arch.isWasm()) .web else .gtk,
        },
        .gtk => .gtk,
        .qt => .qt,
        .headless => .headless,
    };
}

/// Native widgets as plain data. Always present.
pub const headless = @import("platform/headless.zig");

/// AppKit, on macOS.
pub const appkit = if (kind == .appkit) @import("platform/appkit.zig") else unavailable("appkit");

/// GTK 4: designed for (see docs/hybrid-design.md), not yet written.
pub const gtk = unavailable("gtk");
pub const qt = unavailable("qt");
pub const win32 = unavailable("win32");
pub const web = unavailable("web");

/// The namespace of `kind`.
pub const current = switch (kind) {
    .appkit => appkit,
    .headless => headless,
    .gtk => gtk,
    .qt => qt,
    .win32 => win32,
    .web => web,
};

fn unavailable(comptime name: []const u8) type {
    @compileError("fabrum.app.platform." ++ name ++ " isn't in this build: fabrum's platform is ." ++
        @tagName(kind) ++ " (option ." ++ @tagName(option) ++ "); check `fabrum.app.platform.kind` before using it");
}

test "native means the OS's toolkit" {
    try std.testing.expectEqual(Kind.appkit, resolve(.native, .macos, .aarch64));
    try std.testing.expectEqual(Kind.gtk, resolve(.native, .linux, .x86_64));
    try std.testing.expectEqual(Kind.win32, resolve(.native, .windows, .x86_64));
    try std.testing.expectEqual(Kind.web, resolve(.native, .freestanding, .wasm32));
    try std.testing.expectEqual(Kind.headless, resolve(.headless, .macos, .aarch64));
}
