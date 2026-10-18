//! Input: pointer and key events, the cursor, and hit-testing pointer
//! events against the last frame's layout.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

/// Pointer state delivered to `Runtime.mouse`.
pub const MouseEvent = struct {
    /// Where the pointer is, relative to the top left of the viewport.
    position: Vec2,
    /// Every button currently held down. Bit `primary` is the button that
    /// clicks.
    pressed: Buttons = .empty,
    /// The amount scrolled in each direction.
    ///
    /// X means right and Y means down, negative mean left and up respectively.
    ///
    /// The magnitude per scroll unit depends on the platform and hardware.
    scroll_delta: Vec2 = .zero,

    pub const Buttons = std.StaticBitSet(8);

    /// The bit of the primary (usually left) button in `pressed`.
    pub const primary = 0;
};

/// What an element with `on_pointer` is told about the pointer.
///
/// For now only presses are delivered, which is enough for a drawn slider
/// to jump to where it was clicked. Drags, releases and pointer capture
/// come later, as more phases.
pub const Pointer = struct {
    phase: Phase = .press,
    /// Where the pointer is, from the top left of the element's box.
    local: Vec2,
    /// The size of the element's box.
    size: Vec2,

    pub const Phase = enum {
        /// The primary button went down over the element.
        press,
    };
};

/// A key pressed or released, delivered to `Runtime.key`.
///
/// A small first version: the keys that move and use focus. Full keys
/// (physical and logical, text input and IME) come with drawn text editing.
pub const KeyEvent = struct {
    key: Key,
    phase: Phase = .press,
    modifiers: Modifiers = .{},

    pub const Phase = enum { press, repeat, release };

    pub const Key = enum {
        tab,
        enter,
        space,
        escape,
        backspace,
        delete,
        left,
        right,
        up,
        down,
        home,
        end,
        page_up,
        page_down,
        /// Any other key, such as a letter: the runtime doesn't use it yet.
        other,
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        control: bool = false,
        alt: bool = false,
        /// Command on macOS, the Windows key elsewhere.
        super: bool = false,
    };
};

/// The pointer shape a platform shows over the app, from `Runtime.cursor`.
pub const Cursor = enum {
    /// The platform's usual arrow.
    default,
    /// A pointing hand, over something that can be clicked.
    pointer,
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
fn clippedAway(units: []const layout.Unit, index: usize, point: Vec2) bool {
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
