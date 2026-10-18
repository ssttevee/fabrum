//! Input: pointer and key events, focus declarations, shortcuts, the
//! cursor, and hit-testing pointer events against the last frame's layout.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Handler = @import("message.zig").Handler;
const TextInput = @import("text_editor.zig").TextInput;

/// Pointer state delivered to `Runtime.mouse`.
pub const MouseEvent = struct {
    /// Where the pointer is, relative to the top left of the viewport.
    position: Vec2,
    /// Every button currently held down. Bit `primary` is the button that
    /// clicks.
    pressed: Buttons = .empty,
    /// The amount scrolled in each direction, in points: what the content
    /// moves by. X means right and Y means down (the content moves up,
    /// towards its end); negative mean left and up respectively.
    ///
    /// Hosts turn line-stepped wheels into points themselves.
    scroll_delta: Vec2 = .zero,
    /// Where in a scroll gesture the delta is, for hosts that know
    /// (trackpads): a gesture stays with the container it began in until
    /// it ends, as the platforms' scroll views do. Plain wheels send
    /// `none`.
    scroll_phase: ScrollPhase = .none,
    /// The modifier keys held.
    modifiers: KeyEvent.Modifiers = .{},
    /// Whether the host found the primary button held in place long
    /// enough for a long press (InkView's `EVT_POINTERLONG`, a touch
    /// screen's hold). The runtime sends `Pointer.long_press` to the
    /// element that took the press, and the release no longer clicks.
    /// Hosts without long presses never set it.
    long_press: bool = false,

    pub const Buttons = std.StaticBitSet(8);

    /// The bit of the primary (usually left) button in `pressed`.
    pub const primary = 0;

    pub const ScrollPhase = enum { none, began, changed, ended };
};

/// What an element with `on_pointer` is told about the pointer.
///
/// A primary press on the element captures the pointer: until the
/// release, every move goes to it as a `drag`, wherever the pointer is,
/// and the release too. `local` and `size` come from the element's box in
/// the last frame, so a slider needs nothing else.
pub const Pointer = struct {
    phase: Phase,
    /// Where the pointer is, from the top left of the element's box. Can
    /// lie outside the box while dragging.
    local: Vec2,
    /// The size of the element's box.
    size: Vec2,
    /// Where the pointer is in the viewport.
    position: Vec2 = .zero,
    /// The buttons held.
    buttons: MouseEvent.Buttons = .empty,
    modifiers: KeyEvent.Modifiers = .{},
    /// 1 for a press, 2 for a double-click's second press, 3 for a
    /// triple-click's third, for selecting words and paragraphs.
    clicks: u8 = 1,

    pub const Phase = enum {
        /// The primary button went down over the element.
        press,
        /// The pointer moved while held, after moving further than the
        /// drag threshold from the press. The press's click is off.
        drag,
        /// The primary button came up, wherever the pointer is.
        release,
        /// The gesture was taken away: the host lost the pointer
        /// (`Runtime.cancelPointer`) or the element went away. No
        /// release follows.
        cancel,
        /// The host reported a long press (`MouseEvent.long_press`). The
        /// press's click is off; a release follows.
        long_press,
    };
};

/// A key pressed, repeated or released, delivered to `Runtime.key`.
///
/// A key has two identities: where it is (`physical`), which shortcuts
/// fall back to on layouts that type no Latin letters, and what it means
/// in the active layout (`key`). Hosts that know what text the key types
/// pass it in `text`, which the focused text field inserts when no
/// shortcut or edit command took the key; hosts with an input method
/// deliver text through `Runtime.textInput` instead.
pub const KeyEvent = struct {
    /// What the key means in the active layout, ignoring modifiers: a
    /// named key or the character it types unshifted.
    key: Key,
    /// Where the key is, if the host knows.
    physical: Physical = .unknown,
    phase: Phase = .press,
    modifiers: Modifiers = .{},
    /// The text the key types with these modifiers, as UTF-8, or "" if
    /// none or unknown. Borrowed for the call.
    text: []const u8 = "",

    pub const Phase = enum { press, repeat, release };

    /// A key's meaning in the active layout.
    pub const Key = union(enum) {
        /// A key that types a character, by the character it types
        /// unshifted, lowercase: `'a'`, `'1'`, `'с'`.
        char: u21,
        tab,
        enter,
        space,
        escape,
        backspace,
        delete,
        insert,
        left,
        right,
        up,
        down,
        home,
        end,
        page_up,
        page_down,
        /// A function key, by its number: `.{ .f = 1 }` is F1.
        f: u8,
        shift,
        control,
        alt,
        super,
        caps_lock,
        /// A key the host couldn't name.
        unknown,

        pub fn eql(a: Key, b: Key) bool {
            return std.meta.eql(a, b);
        }

        /// Whether the key moves within text or a list.
        pub fn isNavigation(self: Key) bool {
            return switch (self) {
                .left, .right, .up, .down, .home, .end, .page_up, .page_down => true,
                else => false,
            };
        }

        /// Whether the key is a modifier.
        pub fn isModifier(self: Key) bool {
            return switch (self) {
                .shift, .control, .alt, .super, .caps_lock => true,
                else => false,
            };
        }
    };

    /// Where a key is on the keyboard, by its USB HID usage name,
    /// independent of the layout.
    pub const Physical = enum {
        unknown,
        // zig fmt: off
        key_a, key_b, key_c, key_d, key_e, key_f, key_g, key_h, key_i, key_j, key_k, key_l, key_m,
        key_n, key_o, key_p, key_q, key_r, key_s, key_t, key_u, key_v, key_w, key_x, key_y, key_z,
        digit_1, digit_2, digit_3, digit_4, digit_5, digit_6, digit_7, digit_8, digit_9, digit_0,
        // zig fmt: on
        enter,
        escape,
        backspace,
        tab,
        space,
        minus,
        equal,
        bracket_left,
        bracket_right,
        backslash,
        semicolon,
        quote,
        grave,
        comma,
        period,
        slash,
        caps_lock,
        // zig fmt: off
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
        // zig fmt: on
        insert,
        home,
        page_up,
        delete,
        end,
        page_down,
        right,
        left,
        down,
        up,
        shift_left,
        shift_right,
        control_left,
        control_right,
        alt_left,
        alt_right,
        super_left,
        super_right,

        /// The character the key types, unshifted, on a US layout: what
        /// shortcuts match when the active layout types no Latin letter
        /// on it, so that Ctrl-C copies on a Russian layout, as AppKit's
        /// key equivalents and GTK's accelerators do.
        pub fn ascii(self: Physical) ?u8 {
            const tag = @backingInt(self);
            const a = @backingInt(Physical.key_a);
            const one = @backingInt(Physical.digit_1);
            if (tag >= a and tag <= @backingInt(Physical.key_z)) return 'a' + @as(u8, @intCast(tag - a));
            if (tag >= one and tag <= @backingInt(Physical.digit_9)) return '1' + @as(u8, @intCast(tag - one));
            return switch (self) {
                .digit_0 => '0',
                .space => ' ',
                .minus => '-',
                .equal => '=',
                .bracket_left => '[',
                .bracket_right => ']',
                .backslash => '\\',
                .semicolon => ';',
                .quote => '\'',
                .grave => '`',
                .comma => ',',
                .period => '.',
                .slash => '/',
                else => null,
            };
        }
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        control: bool = false,
        /// Option on macOS.
        alt: bool = false,
        /// Command on macOS, the Windows key elsewhere.
        super: bool = false,
        /// Caps Lock, which changes text and never shortcuts.
        caps_lock: bool = false,

        /// The modifiers without Caps Lock, as shortcuts compare them.
        pub fn forShortcuts(self: Modifiers) Modifiers {
            var m = self;
            m.caps_lock = false;
            return m;
        }

        pub fn eql(a: Modifiers, b: Modifiers) bool {
            return std.meta.eql(a.forShortcuts(), b.forShortcuts());
        }

        /// Whether a modifier that makes keys commands rather than text
        /// is held: Control, or Command on macOS.
        pub fn hasCommand(self: Modifiers) bool {
            return self.control or self.super;
        }
    };
};

/// Which keys of each kind an element's `Focus.on_key` takes. The
/// runtime answers the host from this, before any `update` runs, so a
/// host knows at once whether to pass the key on.
pub const KeyFilter = struct {
    /// Keys that type: characters, Space, Enter, Backspace, Delete,
    /// Insert.
    typing: bool = true,
    /// Arrows, Home, End, Page Up and Page Down.
    navigation: bool = true,
    /// Function keys.
    function: bool = true,
    /// Tab and Shift-Tab, which otherwise move focus.
    tab: bool = false,
    /// Escape, which otherwise clears focus.
    escape: bool = false,
    /// Keys with Control or Command held, which are usually shortcuts and
    /// otherwise go on to `Ui.shortcut`.
    commands: bool = false,

    /// Everything but Tab, Escape and shortcuts.
    pub const default: KeyFilter = .{};
    /// Every key, Tab, Escape and shortcuts included, as a code editor
    /// wants.
    pub const all: KeyFilter = .{ .tab = true, .escape = true, .commands = true };
    /// Only the arrow and paging keys, as a list or a slider wants.
    pub const navigation_only: KeyFilter = .{ .typing = false, .function = false };
    /// No keys at all.
    pub const none: KeyFilter = .{ .typing = false, .navigation = false, .function = false };

    pub fn matches(self: KeyFilter, key: KeyEvent.Key, modifiers: KeyEvent.Modifiers) bool {
        if (modifiers.hasCommand() and !self.commands) return false;
        return switch (key) {
            .char, .space, .enter, .backspace, .delete, .insert => self.typing,
            .left, .right, .up, .down, .home, .end, .page_up, .page_down => self.navigation,
            .f => self.function,
            .tab => self.tab,
            .escape => self.escape,
            .shift, .control, .alt, .super, .caps_lock, .unknown => false,
        };
    }
};

/// What makes an element take keyboard focus and keys. Declared on a
/// container as `Ui.Container.focus`; a declaration also makes the element
/// focusable, so it joins the Tab order.
pub const Focus = struct {
    /// Gets the keys `keys` admits while the element has focus, and the
    /// ones its descendants' `on_key` passed on. Pressed and repeated
    /// keys only; a release is never delivered.
    on_key: ?Handler(KeyEvent) = null,
    /// Which keys `on_key` takes. Others go on to the ancestors, the
    /// shortcuts, then the runtime's own (Tab, Escape, Space, Enter).
    keys: KeyFilter = .default,
    /// Told when the element gains (true) or loses (false) focus.
    on_focus: ?Handler(bool) = null,
    /// Makes the element a text input: keys the active keymap maps to an
    /// edit command, and keys that type text, reach it as `TextInput`,
    /// after `on_key` and before the ancestors and shortcuts; so does
    /// `Runtime.textInput`.
    on_text: ?Handler(TextInput) = null,
};

/// A key with modifiers, as `Ui.shortcut` declares and the runtime
/// matches against a `KeyEvent`.
pub const Shortcut = struct {
    key: KeyEvent.Key,
    modifiers: KeyEvent.Modifiers = .{},
    /// Whether the platform's shortcut modifier is part of it: Command on
    /// macOS, Control elsewhere (see `Keymap`). `modifiers` then names the
    /// others.
    shortcut: bool = false,

    /// Whether `event` is this shortcut, on a keymap whose shortcut key
    /// is Command (`super`) or Control. A character key matches the
    /// character the active layout types, or, where that isn't Latin, the
    /// one the same physical key types on a US layout.
    pub fn matches(self: Shortcut, event: KeyEvent, super_is_shortcut: bool) bool {
        var wanted = self.modifiers;
        if (self.shortcut) {
            if (super_is_shortcut) wanted.super = true else wanted.control = true;
        }
        if (!wanted.eql(event.modifiers)) return false;
        if (self.key.eql(event.key)) return true;
        if (self.key == .char and self.key.char < 0x80) {
            // a non-Latin layout: the physical key's US character
            const latin = event.key == .char and event.key.char < 0x80;
            if (!latin) if (event.physical.ascii()) |c| return c == self.key.char;
        }
        return false;
    }
};

/// The pointer shape a platform shows over the app, from `Runtime.cursor`.
pub const Cursor = enum {
    /// The platform's usual arrow.
    default,
    /// A pointing hand, over something that can be clicked.
    pointer,
    /// An I-beam, over text that can be edited.
    text,
};

/// What the pointer is over and what it pressed, as of the last
/// `MouseEvent`.
pub const Input = struct {
    /// Keyed element IDs under the pointer: the hit element first, then its
    /// ancestors.
    hovered: std.ArrayList(u64) = .empty,
    /// Scratch for the next `hovered`, swapped in by `hitTest`.
    next_hovered: std.ArrayList(u64) = .empty,
    /// `hovered` as of the primary button press, until it is released.
    pressed: std.ArrayList(u64) = .empty,
    /// The element the primary button press would click.
    press_target: ?u64 = null,
    primary_down: bool = false,

    pub fn deinit(self: *Input, gpa: Allocator) void {
        self.hovered.deinit(gpa);
        self.next_hovered.deinit(gpa);
        self.pressed.deinit(gpa);
    }

    /// What an event changed.
    pub const Outcome = struct {
        /// Whether hover or press state changed.
        changed: bool = false,
        /// Whether the primary button went down.
        press: bool = false,
        /// Whether the primary button came up.
        release: bool = false,
        /// The element clicked, if the event completed a click.
        click: ?u64 = null,
    };

    /// Updates hover and press state from `event`. `units` is the laid-out
    /// layout to hit-test, or null if there is none. `clickable` says
    /// whether an element has an `on_click`.
    pub fn handle(self: *Input, gpa: Allocator, units: ?[]const layout.Unit, clickable: anytype, event: MouseEvent) Allocator.Error!Outcome {
        var outcome: Outcome = .{ .changed = try self.hitTest(gpa, units, event.position) };

        const down = event.pressed.isSet(MouseEvent.primary);
        if (down and !self.primary_down) {
            outcome.press = true;
            try self.pressed.appendSlice(gpa, self.hovered.items);
            self.press_target = self.clickTarget(clickable);
            if (self.pressed.items.len > 0) outcome.changed = true;
        } else if (!down and self.primary_down) {
            outcome.release = true;
            const release_target = self.clickTarget(clickable);
            if (self.press_target != null and self.press_target == release_target) {
                outcome.click = release_target;
            }
            if (self.pressed.items.len > 0) outcome.changed = true;
            self.pressed.clearRetainingCapacity();
            self.press_target = null;
        }
        self.primary_down = down;
        return outcome;
    }

    /// Takes the click out of the press under way, as a drag or a long
    /// press does: the release then clicks nothing.
    pub fn cancelClick(self: *Input) void {
        self.press_target = null;
    }

    /// Recomputes `hovered` for `point`, and says whether it changed.
    fn hitTest(self: *Input, gpa: Allocator, laid_out: ?[]const layout.Unit, point: Vec2) Allocator.Error!bool {
        self.next_hovered.clearRetainingCapacity();
        if (laid_out) |units| {
            var i = units.len;
            const hit: ?usize = while (i > 1) {
                i -= 1;
                if (units[i].hovered(point) and !clippedAway(units, i, point)) break i;
            } else null;

            var index = hit orelse 0;
            while (index != 0) : (index = units[index].parent) {
                if (units[index].id != 0) {
                    try self.next_hovered.append(gpa, units[index].id);
                }
            }
        }

        const changed = !std.mem.eql(u64, self.hovered.items, self.next_hovered.items);
        std.mem.swap(std.ArrayList(u64), &self.hovered, &self.next_hovered);
        return changed;
    }

    /// The nearest hovered element with an `on_click`. `clickable` has a
    /// `contains(u64) bool`.
    pub fn clickTarget(self: *const Input, clickable: anytype) ?u64 {
        return self.nearest(clickable);
    }

    /// The nearest hovered element in `set`, which has a
    /// `contains(u64) bool`: the hit element or its closest keyed ancestor.
    pub fn nearest(self: *const Input, set: anytype) ?u64 {
        for (self.hovered.items) |id| {
            if (set.contains(id)) return id;
        }
        return null;
    }
};

/// Whether something of the app is at `point` in the laid-out `units`:
/// anything but the root that paints there (a background, a border or
/// content such as text) or that takes input there (`interactive`, with a
/// `contains(u64) bool`), and that no clipping ancestor cuts away. Hosts
/// pass pointer input elsewhere on, as an overlay lets clicks through to
/// the game under it.
pub fn occupied(units: []const layout.Unit, point: Vec2, interactive: anytype) bool {
    for (units[1..], 1..) |*unit, index| {
        if (!unit.hovered(point) or clippedAway(units, index, point)) continue;
        switch (unit.data) {
            .content => return true,
            .container => |c| {
                if (!c.background_color.isTransparent()) return true;
                if (!c.border.color.isTransparent() and !c.border.widths.isZero()) return true;
                if (unit.id != 0 and interactive.contains(unit.id)) return true;
            },
        }
    }
    return false;
}

/// Whether an ancestor of `units[index]` clips `point` away.
pub fn clippedAway(units: []const layout.Unit, index: usize, point: Vec2) bool {
    var ancestor = units[index].parent;
    while (true) : (ancestor = units[ancestor].parent) {
        const unit = &units[ancestor];
        if (unit.data == .container) {
            const clip = unit.data.container.clip;
            const box = unit.bbox;
            if (clip.horizontal and (point.x < box.x or point.x >= box.x + box.w)) return true;
            if (clip.vertical and (point.y < box.y or point.y >= box.y + box.h)) return true;
        }
        if (ancestor == 0) return false;
    }
}

test "shortcuts match the layout's character, or the physical key's on non-Latin layouts" {
    const copy: Shortcut = .{ .key = .{ .char = 'c' }, .shortcut = true };
    // Command on macOS, Control elsewhere
    try std.testing.expect(copy.matches(.{ .key = .{ .char = 'c' }, .modifiers = .{ .super = true } }, true));
    try std.testing.expect(!copy.matches(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true } }, true));
    try std.testing.expect(copy.matches(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true } }, false));
    // Caps Lock doesn't matter; Shift does
    try std.testing.expect(copy.matches(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true, .caps_lock = true } }, false));
    try std.testing.expect(!copy.matches(.{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true, .shift = true } }, false));
    // a Russian layout types с on the C key
    try std.testing.expect(copy.matches(.{ .key = .{ .char = 'с' }, .physical = .key_c, .modifiers = .{ .control = true } }, false));
    try std.testing.expect(!copy.matches(.{ .key = .{ .char = 'с' }, .physical = .key_v, .modifiers = .{ .control = true } }, false));
    // a Latin layout that types another letter there (Dvorak) matches the letter, not the key
    try std.testing.expect(!copy.matches(.{ .key = .{ .char = 'j' }, .physical = .key_c, .modifiers = .{ .control = true } }, false));
    try std.testing.expectEqual('c', KeyEvent.Physical.key_c.ascii().?);
    try std.testing.expectEqual('0', KeyEvent.Physical.digit_0.ascii().?);
    try std.testing.expectEqual(null, KeyEvent.Physical.f1.ascii());
}

test "key filters sort keys by kind" {
    try std.testing.expect(KeyFilter.default.matches(.{ .char = 'a' }, .{}));
    try std.testing.expect(KeyFilter.default.matches(.left, .{ .shift = true }));
    try std.testing.expect(!KeyFilter.default.matches(.tab, .{}));
    try std.testing.expect(!KeyFilter.default.matches(.escape, .{}));
    try std.testing.expect(!KeyFilter.default.matches(.{ .char = 's' }, .{ .control = true }));
    try std.testing.expect(KeyFilter.all.matches(.tab, .{}));
    try std.testing.expect(KeyFilter.all.matches(.{ .char = 's' }, .{ .super = true }));
    try std.testing.expect(!KeyFilter.navigation_only.matches(.{ .char = 'a' }, .{}));
    try std.testing.expect(KeyFilter.navigation_only.matches(.page_down, .{}));
    try std.testing.expect(!KeyFilter.all.matches(.shift, .{}));
}
