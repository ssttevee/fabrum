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
//! Only `appkit` (`native` on macOS), `gtk` (`native` on Linux, or `gtk`
//! anywhere GTK 4 is) and `none` exist so far. Building `fabrum.app` for
//! any other platform is a compile error that says so; `fabrum.layout`
//! alone builds with any option.
//!
//! Tests don't need a platform: `app.testing.Harness` runs native widgets
//! in a fake tree on every platform (`app.testing.NativeTree`).
//!
//! **Services.** What a host does for the app beyond its window, with
//! signatures any host can implement (`Services`): dialogs, menus, modal
//! text entry, file and directory choosers, the clipboard, closing and
//! quitting. Apps ask from `update` (`ctx.confirm`, `ctx.menu`,
//! `ctx.systemText`, `ctx.openFile`, `ctx.readClipboard`, `ctx.quit`, ...);
//! answers come back as messages (`Reply`, `IndexReply`). Closing the
//! window or quitting can be held for the app to confirm: a view declares
//! `ui.guardClose`, and the host asks `Runtime.shouldClose` first.
//!
//! Every service is optional. A host leaves out what it can't do, and the
//! runtime falls back where it reasonably can:
//!
//! | Service | AppKit | GTK 4 | InkView (external, to come) | Missing |
//! |---|---|---|---|---|
//! | `message`, `confirm` | `NSAlert` sheet | `GtkAlertDialog` | `Message`, `Dialog3` | a dialog drawn by fabrum, modal |
//! | `menu` | `NSMenu` popup | `GtkPopoverMenu` | `OpenMenu` / `OpenContextMenu` | a menu drawn by fabrum |
//! | `editText` | (not needed: drawn fields take keys) | (the same) | `OpenKeyboard` | `error.Unsupported` |
//! | `openFile`, `openDirectory` | `NSOpenPanel` | `GtkFileDialog` | a list built on `OpenList` | `error.Unsupported` |
//! | clipboard | `NSPasteboard` | `GdkClipboard` (read is async) | none | a clipboard private to the program |
//! | `quit`, `close` | `-[NSApp terminate:]`, `-[NSWindow close]` | `g_application_quit` | `CloseApp` | `error.Unsupported` |
//! | `shouldClose` | `windowShouldClose:`, `applicationShouldTerminate:` | `close-request` | `EVT_EXIT` | the host calls it before closing |
//!
//! On `none`, the host passes its own `Services` in
//! `Runtime.Options.services`, or none.
//!
//! **Native widgets** are pluggable the same way: an external platform
//! package implements `app.native.Backend` and passes it in
//! `Runtime.Options.native`, and `app.widgets` then declares its controls
//! through it; see `app.native`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const message = @import("message.zig");
const Handler = message.Handler;
const Poster = message.Poster;
const fabrum = @import("../root.zig");
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

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
        .appkit, .gtk, .none => true,
        .win32, .web, .qt, .sdl => false,
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

/// What a host does for the app beyond its window, each optional: a host
/// leaves out what it can't do, and the app's request falls back or fails
/// with `error.Unsupported` (see the module's table). Called on the thread
/// that runs frames; answers may come from any thread, now or later.
pub const Services = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ Unsupported, OutOfMemory, ServiceFailed };

    pub const VTable = struct {
        /// Shows a message box that the user dismisses, or that goes away
        /// by itself after `MessageRequest.timeout`.
        message: ?*const fn (ptr: *anyopaque, request: *const MessageRequest) Error!void = null,
        /// Asks a question with up to three buttons, and later sends the
        /// index of the one pressed, or null if the dialog was dismissed,
        /// through `reply`.
        confirm: ?*const fn (ptr: *anyopaque, request: *const ConfirmRequest, reply: IndexReply) Error!void = null,
        /// Shows a popup or context menu at a point, and later sends the
        /// `MenuItem.id` of the item chosen, or null if the menu was
        /// dismissed, through `reply`.
        menu: ?*const fn (ptr: *anyopaque, request: *const MenuRequest, reply: IndexReply) Error!void = null,
        /// Edits text with the platform's own modal entry (an e-reader's
        /// system keyboard), and later sends the text, or null if the
        /// user cancelled, through `reply`.
        editText: ?*const fn (ptr: *anyopaque, request: *const TextRequest, reply: Reply) Error!void = null,
        /// Shows a chooser for one existing file, and later sends its path,
        /// or null if the user cancelled, through `reply`, from any thread.
        openFile: ?*const fn (ptr: *anyopaque, request: *const FileRequest, reply: Reply) Error!void = null,
        /// Shows a chooser for a directory, and later sends its path or
        /// null through `reply`.
        openDirectory: ?*const fn (ptr: *anyopaque, request: *const FileRequest, reply: Reply) Error!void = null,
        /// Puts text on the clipboard.
        writeClipboard: ?*const fn (ptr: *anyopaque, text: []const u8) Error!void = null,
        /// Reads the clipboard's text, and sends it (null without text)
        /// through `reply`, now or later, as clipboards that are read
        /// asynchronously do.
        readClipboard: ?*const fn (ptr: *anyopaque, reply: Reply) Error!void = null,
        /// Closes the window and quits, without asking `shouldClose`: for
        /// after the app has confirmed.
        quit: ?*const fn (ptr: *anyopaque) void = null,
        /// Closes the window without quitting, without asking.
        close: ?*const fn (ptr: *anyopaque) void = null,
    };
};

/// A message box: `title` and `text`, with the look of its `kind`.
pub const MessageRequest = struct {
    title: []const u8 = "",
    text: []const u8,
    kind: DialogKind = .info,
    /// Milliseconds after which the box goes away by itself, or 0 to wait
    /// for the user.
    timeout_ms: u32 = 0,
};

/// A question with buttons; `default` is the button Enter presses.
pub const ConfirmRequest = struct {
    title: []const u8 = "",
    text: []const u8,
    /// One to three, the default first by convention.
    buttons: []const []const u8 = &.{ "OK", "Cancel" },
    default: usize = 0,
    kind: DialogKind = .question,
};

pub const DialogKind = enum { info, question, warning, @"error" };

/// A popup or context menu.
pub const MenuRequest = struct {
    items: []const MenuItem,
    /// Where its top left goes, in the viewport's points.
    at: Vec2,
    /// What it belongs to, if a context menu, for platforms that place
    /// menus beside their anchor.
    anchor: ?Rect = null,
};

pub const MenuItem = struct {
    title: []const u8 = "",
    kind: MenuItemKind = .item,
    /// What the reply carries when the item is chosen: give every item in
    /// the tree its own.
    id: usize = 0,
    enabled: bool = true,
    /// A `submenu`'s items.
    submenu: []const MenuItem = &.{},

    pub const Kind = MenuItemKind;
};

pub const MenuItemKind = enum { item, header, separator, submenu };

/// Modal text entry by the platform.
pub const TextRequest = struct {
    /// Shown as the entry's caption.
    title: []const u8 = "",
    initial: []const u8 = "",
    flags: Flags = .{},
    /// The most bytes, or 0 for the platform's limit.
    max_len: usize = 0,

    pub const Flags = packed struct {
        url: bool = false,
        numeric: bool = false,
        password: bool = false,
        email: bool = false,
        multiline: bool = false,
    };
};

/// What a file chooser offers.
pub const FileRequest = struct {
    /// Shown with the files, such as "Choose an image to flash".
    message: []const u8 = "",
    /// The file name extensions offered, without dots ("img", "iso"), or
    /// every file if empty.
    extensions: []const []const u8 = &.{},
};

/// Where a host sends what the app asked for: text, or null for none (a
/// cancelled chooser, a clipboard without text). Thread-safe; the text is
/// copied, and the message borrows the copy until `update` has run.
pub const Reply = struct {
    poster: Poster,
    handler: Handler(?[]const u8),

    pub fn send(self: Reply, text: ?[]const u8) Allocator.Error!void {
        try message.postText(self.poster, self.handler, text);
    }
};

/// Where a host sends which button or item the user chose: its index or
/// `MenuItem.id`, or null for none (dismissed, cancelled). Thread-safe.
pub const IndexReply = struct {
    poster: Poster,
    handler: Handler(?usize),

    pub fn send(self: IndexReply, index: ?usize) Allocator.Error!void {
        try self.poster.post(self.handler, index);
    }
};

/// Why the host wants to close: the window's close button, or quitting the
/// app (the menu, the keyboard, logging out).
pub const CloseReason = enum { window, quit };

/// No built-in host: the app's own code drives the runtime. Always present.
pub const none = @import("platform/none.zig");

/// AppKit, on macOS.
pub const appkit = if (kind == .appkit) @import("platform/appkit.zig") else unavailable("appkit");

/// GTK 4, on Linux (`native`) and wherever GTK is (`gtk`).
pub const gtk = if (kind == .gtk) @import("platform/gtk.zig") else unavailable("gtk");
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

test "only AppKit, GTK and none exist so far" {
    try std.testing.expect(implemented(.appkit));
    try std.testing.expect(implemented(.gtk));
    try std.testing.expect(implemented(.none));
    for ([_]Kind{ .win32, .web, .qt, .sdl }) |k| try std.testing.expect(!implemented(k));
}
