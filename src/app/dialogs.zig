//! Dialogs: the platform's own alerts, declared from views. An alert shows
//! while a view declares it, as a sheet on the window on macOS, and is
//! answered once; the view stops declaring it when the model has the
//! answer:
//!
//! ```zig
//! if (state.confirming) try dialogs.alert(ui, "erase?", .{
//!     .title = "Erase the disk?",
//!     .buttons = &.{ "Erase", "Cancel" },
//!     .on_response = on.handler(.answered), // usize: the button's index
//! });
//! ```
const Ui = @import("ui.zig").Ui;
const Handler = @import("message.zig").Handler;

pub const AlertOptions = struct {
    title: []const u8,
    message: []const u8 = "",
    /// From the default button on; at least one.
    buttons: []const []const u8 = &.{"OK"},
    /// Fired with the index of the button pressed.
    on_response: ?Handler(usize) = null,
};

/// A modal alert.
pub fn alert(ui: *Ui, key: anytype, options: AlertOptions) !void {
    try ui.native(key, .{
        .spec = .{ .alert = .{ .title = options.title, .message = options.message, .buttons = options.buttons } },
        .handlers = .{ .on_response = options.on_response },
    });
}
