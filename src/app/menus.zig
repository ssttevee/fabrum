//! Menus: the platform's own menu bar, declared from views. An item exists
//! while some view declares it, so a view can add commands for as long as
//! it is shown:
//!
//! ```zig
//! try menus.item(ui, "greet", .{ .menu = "Kitchen", .title = "Say Hello", .key = "k", .on_select = on.bind(.greet) });
//! ```
const Ui = @import("ui.zig").Ui;
const Action = @import("message.zig").Action;

pub const ItemOptions = struct {
    /// The title of the menu in the menu bar, made when missing.
    menu: []const u8,
    title: []const u8,
    /// Selects the item with the platform's shortcut modifier (Command on
    /// macOS), or "" for none.
    key: []const u8 = "",
    on_select: ?Action = null,
    enabled: bool = true,
};

/// An item in a menu of the menu bar.
pub fn item(ui: *Ui, key: anytype, options: ItemOptions) !void {
    try ui.native(key, .{
        .spec = .{ .menu_item = .{ .menu = options.menu, .title = options.title, .key = options.key, .enabled = options.enabled } },
        .handlers = .{ .on_activate = options.on_select },
    });
}
