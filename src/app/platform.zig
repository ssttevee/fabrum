//! Platforms: what hosts a fabrum app. A toolkit platform owns the window
//! and its chrome, the event loop, menus, dialogs, the clipboard and
//! accessibility, and provides the native controls that `app.widgets`
//! stands for; fabrum owns one host view per window and lays out
//! everything inside it. The `none` platform has no built-in host at all:
//! the app's own code drives the runtime, and every widget is drawn.
//!
//! Which platform a program uses is chosen when it is built, with fabrum's
//! `platform` option (`-Dplatform=native|gtk|qt|sdl|none`, independent of
//! the target OS), and is known at compile time as `kind`, so apps can pick
//! widgets per platform:
//!
//! ```zig
//! switch (comptime fabrum.app.platform.kind) {
//!     .appkit => try fabrum.app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = 3, .max = 5 }),
//!     else => try fabrum.app.widgets.slider(ui, "rating", .{ .value = 3, .max = 5 }),
//! }
//! ```
//!
//! Each toolkit namespace (`appkit`, later `gtk`, `win32`, ...) has its
//! full catalogue of native widgets in its own `widgets`, next to what
//! every platform has. Namespaces of platforms not built in are compile
//! errors when used, so code naming them must sit behind a `kind` check.
//!
//! Only `appkit` (`native` on macOS) and `none` exist so far. Building
//! `fabrum.app` for any other platform is a compile error that says so;
//! `fabrum.layout` alone builds with any option.
//!
//! Tests don't need a platform: `app.testing.Harness` runs native widgets
//! in a fake tree on every platform (`app.testing.NativeTree`).
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
    /// Qt, on any OS that has it.
    qt,
    /// A portable window from SDL, with drawn widgets.
    sdl,
    /// No built-in host: the app's own code drives the runtime, feeding it
    /// input and taking render commands and changed regions out, and a
    /// portable renderer draws every widget into pixels. See `none`.
    none,
};

/// The platform a program is built for: `Option` resolved for the target.
pub const Kind = enum { appkit, win32, web, gtk, qt, sdl, none };

/// The `platform` option this fabrum was built with.
pub const option: Option = std.meta.stringToEnum(Option, options.platform) orelse
    @compileError("fabrum: unknown platform option '" ++ options.platform ++ "'; it is one of native, gtk, qt, sdl or none");

/// The platform this program uses, from `option` and the target OS.
pub const kind: Kind = resolve(option, builtin.target.os.tag, builtin.target.cpu.arch);

/// The platform `option` means on a target.
pub fn resolve(o: Option, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) Kind {
    return switch (o) {
        .native => switch (os) {
            .macos => .appkit,
            .windows => .win32,
            else => if (arch.isWasm()) .web else .gtk,
        },
        .gtk => .gtk,
        .qt => .qt,
        .sdl => .sdl,
        .none => .none,
    };
}

/// Whether fabrum has the platform `k` yet.
pub fn implemented(k: Kind) bool {
    return switch (k) {
        .appkit, .none => true,
        .win32, .web, .gtk, .qt, .sdl => false,
    };
}

/// Fails compilation unless this build's platform exists. `fabrum.app`
/// calls it, so layout-only programs build with any option.
pub fn check() void {
    if (comptime implemented(kind)) return;
    const what = switch (option) {
        .native => "the native platform of " ++ @tagName(builtin.target.os.tag) ++ " (" ++ @tagName(kind) ++ ")",
        else => "the " ++ @tagName(option) ++ " platform",
    };
    @compileError("fabrum: " ++ what ++ " is not implemented yet; " ++ remedy);
}

/// What `check` suggests instead of a missing platform.
pub const remedy = "build fabrum with -Dplatform=none (`.platform = .none`) to host the app yourself with drawn widgets";

/// No built-in host: the app's own code drives the runtime. Always present.
pub const none = @import("platform/none.zig");

/// AppKit, on macOS.
pub const appkit = if (kind == .appkit) @import("platform/appkit.zig") else unavailable("appkit");

/// GTK 4: designed for (see docs/hybrid-design.md), not yet written.
pub const gtk = unavailable("gtk");
pub const qt = unavailable("qt");
pub const sdl = unavailable("sdl");
pub const win32 = unavailable("win32");
pub const web = unavailable("web");

/// The namespace of `kind`.
pub const current = switch (kind) {
    .appkit => appkit,
    .none => none,
    .gtk => gtk,
    .qt => qt,
    .sdl => sdl,
    .win32 => win32,
    .web => web,
};

fn unavailable(comptime name: []const u8) type {
    @compileError("fabrum.app.platform." ++ name ++ " isn't in this build: fabrum's platform is ." ++
        @tagName(kind) ++ " (option ." ++ @tagName(option) ++ "); check `fabrum.app.platform.kind` before using it");
}

test "native means the OS's toolkit; the others mean themselves on any OS" {
    try std.testing.expectEqual(Kind.appkit, resolve(.native, .macos, .aarch64));
    try std.testing.expectEqual(Kind.gtk, resolve(.native, .linux, .x86_64));
    try std.testing.expectEqual(Kind.win32, resolve(.native, .windows, .x86_64));
    try std.testing.expectEqual(Kind.web, resolve(.native, .freestanding, .wasm32));
    try std.testing.expectEqual(Kind.gtk, resolve(.gtk, .macos, .aarch64));
    try std.testing.expectEqual(Kind.qt, resolve(.qt, .windows, .x86_64));
    try std.testing.expectEqual(Kind.sdl, resolve(.sdl, .linux, .x86_64));
    try std.testing.expectEqual(Kind.none, resolve(.none, .macos, .aarch64));
    try std.testing.expectEqual(Kind.none, resolve(.none, .freestanding, .wasm32));
}

test "only AppKit and none exist so far" {
    try std.testing.expect(implemented(.appkit));
    try std.testing.expect(implemented(.none));
    for ([_]Kind{ .win32, .web, .gtk, .qt, .sdl }) |k| try std.testing.expect(!implemented(k));
}
