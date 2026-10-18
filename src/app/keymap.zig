//! Keymaps: which keys mean which edit commands in drawn text fields, per
//! platform convention. macOS's come from its standard key bindings
//! (`moveWordLeft:`, `deleteToBeginningOfLine:`, the Emacs control keys);
//! Windows's and Linux's from their edit controls (GTK's conventions on
//! Linux, which differ from Windows's by a word boundary and a redo key).
//!
//! The runtime maps keys through the keymap of `Runtime.Options.keymap`,
//! which defaults to the platform's, and provides it as a root value for
//! views that show shortcuts.
const std = @import("std");
const builtin = @import("builtin");

const KeyEvent = @import("input.zig").KeyEvent;
const EditCommand = @import("text_editor.zig").EditCommand;

pub const Keymap = enum {
    macos,
    windows,
    linux,

    /// The keymap of the OS this program is built for.
    pub const default: Keymap = switch (builtin.target.os.tag) {
        .macos, .ios => .macos,
        .windows => .windows,
        else => .linux,
    };

    /// Whether the shortcut modifier is Command (`super`), as on macOS,
    /// rather than Control.
    pub fn superIsShortcut(self: Keymap) bool {
        return self == .macos;
    }

    /// Whether `modifiers` hold the shortcut modifier and nothing else
    /// but `shift` as given.
    fn shortcut(self: Keymap, m: KeyEvent.Modifiers, shift: bool) bool {
        const want: KeyEvent.Modifiers = if (self.superIsShortcut()) .{ .super = true, .shift = shift } else .{ .control = true, .shift = shift };
        return m.eql(want);
    }

    /// The edit command `event` means on this keymap, if any. Only presses
    /// and repeats map; Tab and Escape never do, so focus keeps them.
    pub fn command(self: Keymap, event: KeyEvent) ?EditCommand {
        if (event.phase == .release) return null;
        const m = event.modifiers.forShortcuts();
        const shift = m.shift;
        const plain = !m.control and !m.alt and !m.super;
        const dir: EditCommand.Direction = switch (event.key) {
            .left, .up, .home, .page_up, .backspace => .backward,
            else => .forward,
        };
        return switch (self) {
            .macos => self.macCommand(event, m, shift, plain, dir),
            .windows, .linux => self.pcCommand(event, m, shift, plain, dir),
        };
    }

    fn move(by: EditCommand.Unit, dir: EditCommand.Direction, extend: bool) EditCommand {
        return .{ .move = .{ .by = by, .direction = dir, .extend = extend } };
    }

    fn delete(by: EditCommand.Unit, dir: EditCommand.Direction) EditCommand {
        return .{ .delete = .{ .by = by, .direction = dir } };
    }

    fn macCommand(self: Keymap, event: KeyEvent, m: KeyEvent.Modifiers, shift: bool, plain: bool, dir: EditCommand.Direction) ?EditCommand {
        const alt_only = m.alt and !m.control and !m.super;
        const super_only = m.super and !m.control and !m.alt;
        const control_only = m.control and !m.alt and !m.super;
        switch (event.key) {
            .left, .right => {
                if (plain) return move(.grapheme, dir, shift);
                if (alt_only) return move(if (dir == .backward) .word_start else .word_end, dir, shift);
                if (super_only) return move(.visual_line_edge, dir, shift);
            },
            .up, .down => {
                if (plain) return move(.visual_line, dir, shift);
                if (super_only) return move(.document, dir, shift);
                if (alt_only) return move(.paragraph_edge, dir, shift);
            },
            .home, .end => if (plain) return move(.document, dir, shift),
            .page_up, .page_down => if (plain) return move(.page, dir, shift),
            .backspace => {
                if (plain) return delete(.grapheme, .backward);
                if (alt_only) return delete(.word_start, .backward);
                if (super_only) return delete(.visual_line_edge, .backward);
            },
            .delete => {
                if (plain) return delete(.grapheme, .forward);
                if (alt_only) return delete(.word_end, .forward);
            },
            .enter => if (plain) return if (shift) .insert_line_break else .insert_newline,
            .char => |c| {
                if (self.shortcut(m, false)) switch (c) {
                    'a' => return .select_all,
                    'c' => return .copy,
                    'x' => return .cut,
                    'v' => return .paste,
                    'z' => return .undo,
                    else => {},
                };
                if (self.shortcut(m, true) and c == 'z') return .redo;
                if (control_only) switch (c) {
                    'a' => return move(.paragraph_edge, .backward, shift),
                    'e' => return move(.paragraph_edge, .forward, shift),
                    'f' => return move(.grapheme, .forward, shift),
                    'b' => return move(.grapheme, .backward, shift),
                    'n' => return move(.visual_line, .forward, shift),
                    'p' => return move(.visual_line, .backward, shift),
                    'd' => return delete(.grapheme, .forward),
                    'h' => return delete(.grapheme, .backward),
                    'k' => return .kill_to_line_end,
                    'y' => return .yank,
                    't' => return .transpose,
                    else => {},
                };
            },
            else => {},
        }
        return null;
    }

    fn pcCommand(self: Keymap, event: KeyEvent, m: KeyEvent.Modifiers, shift: bool, plain: bool, dir: EditCommand.Direction) ?EditCommand {
        const control = m.control and !m.alt and !m.super;
        // GTK moves to the end of the word forwards; Windows to the start of the next
        const forward_word: EditCommand.Unit = if (self == .linux) .word_end else .word_start;
        switch (event.key) {
            .left, .right => {
                if (plain) return move(.grapheme, dir, shift);
                if (control) return move(if (dir == .backward) .word_start else forward_word, dir, shift);
            },
            .up, .down => if (plain) return move(.visual_line, dir, shift),
            .home, .end => {
                if (plain) return move(.visual_line_edge, dir, shift);
                if (control) return move(.document, dir, shift);
            },
            .page_up, .page_down => if (plain) return move(.page, dir, shift),
            .backspace => {
                if (plain) return delete(.grapheme, .backward);
                if (control) return delete(.word_start, .backward);
            },
            .delete => {
                if (m.eql(.{ .shift = true })) return .cut;
                if (plain) return delete(.grapheme, .forward);
                if (control) return delete(forward_word, .forward);
            },
            .insert => {
                if (m.eql(.{ .shift = true })) return .paste;
                if (control) return .copy;
            },
            .enter => if (plain) return if (shift) .insert_line_break else .insert_newline,
            .char => |c| {
                if (self.shortcut(m, false)) switch (c) {
                    'a' => return .select_all,
                    'c' => return .copy,
                    'x' => return .cut,
                    'v' => return .paste,
                    'z' => return .undo,
                    'y' => return .redo,
                    else => {},
                };
                if (self.shortcut(m, true) and c == 'z' and self == .linux) return .redo;
            },
            else => {},
        }
        return null;
    }
};

test "the macOS keymap follows its standard key bindings" {
    const k: Keymap = .macos;
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .grapheme, .direction = .backward, .extend = false } }, k.command(.{ .key = .left }).?);
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .word_end, .direction = .forward, .extend = true } }, k.command(.{ .key = .right, .modifiers = .{ .alt = true, .shift = true } }).?);
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .visual_line_edge, .direction = .backward, .extend = false } }, k.command(.{ .key = .left, .modifiers = .{ .super = true } }).?);
    try std.testing.expectEqual(EditCommand.copy, k.command(.{ .key = .{ .char = 'c' }, .modifiers = .{ .super = true } }).?);
    try std.testing.expectEqual(EditCommand.redo, k.command(.{ .key = .{ .char = 'z' }, .modifiers = .{ .super = true, .shift = true } }).?);
    try std.testing.expectEqual(EditCommand.kill_to_line_end, k.command(.{ .key = .{ .char = 'k' }, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(EditCommand.insert_newline, k.command(.{ .key = .enter }).?);
    // Control-C is nothing on macOS; Tab and Escape are focus's
    try std.testing.expectEqual(null, k.command(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true } }));
    try std.testing.expectEqual(null, k.command(.{ .key = .tab }));
    try std.testing.expectEqual(null, k.command(.{ .key = .escape }));
    try std.testing.expectEqual(null, k.command(.{ .key = .left, .phase = .release }));
}

test "the Windows and Linux keymaps follow their edit controls" {
    const w: Keymap = .windows;
    const l: Keymap = .linux;
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .word_start, .direction = .forward, .extend = false } }, w.command(.{ .key = .right, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .word_end, .direction = .forward, .extend = false } }, l.command(.{ .key = .right, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .visual_line_edge, .direction = .forward, .extend = true } }, w.command(.{ .key = .end, .modifiers = .{ .shift = true } }).?);
    try std.testing.expectEqual(EditCommand{ .move = .{ .by = .document, .direction = .backward, .extend = false } }, w.command(.{ .key = .home, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(EditCommand.redo, w.command(.{ .key = .{ .char = 'y' }, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(EditCommand.redo, l.command(.{ .key = .{ .char = 'z' }, .modifiers = .{ .control = true, .shift = true } }).?);
    try std.testing.expectEqual(null, w.command(.{ .key = .{ .char = 'z' }, .modifiers = .{ .control = true, .shift = true } }));
    try std.testing.expectEqual(EditCommand.paste, w.command(.{ .key = .insert, .modifiers = .{ .shift = true } }).?);
    try std.testing.expectEqual(EditCommand.cut, w.command(.{ .key = .delete, .modifiers = .{ .shift = true } }).?);
    try std.testing.expectEqual(null, w.command(.{ .key = .{ .char = 'c' }, .modifiers = .{ .super = true } }));
}
