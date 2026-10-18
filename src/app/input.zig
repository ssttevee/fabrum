//! Pointer input: events, the cursor, and hit-testing them against the
//! last frame's layout.
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
    hovered: std.ArrayList(u32) = .empty,
    /// Scratch for the next `hovered`, swapped in by `hitTest`.
    next_hovered: std.ArrayList(u32) = .empty,
    /// `hovered` as of the primary button press, until it is released.
    pressed: std.ArrayList(u32) = .empty,
    /// The element the primary button press would click.
    press_target: ?u32 = null,
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
        /// The element clicked, if the event completed a click.
        click: ?u32 = null,
    };

    /// Updates hover and press state from `event`. `units` is the laid-out
    /// layout to hit-test, or null if there is none. `clickable` says
    /// whether an element has an `on_click`.
    pub fn handle(self: *Input, gpa: Allocator, units: ?[]const layout.Unit, clickable: anytype, event: MouseEvent) Allocator.Error!Outcome {
        var outcome: Outcome = .{ .changed = try self.hitTest(gpa, units, event.position) };

        const down = event.pressed.isSet(MouseEvent.primary);
        if (down and !self.primary_down) {
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

        const changed = !std.mem.eql(u32, self.hovered.items, self.next_hovered.items);
        std.mem.swap(std.ArrayList(u32), &self.hovered, &self.next_hovered);
        return changed;
    }

    /// The nearest hovered element with an `on_click`. `clickable` has a
    /// `contains(u32) bool`.
    pub fn clickTarget(self: *const Input, clickable: anytype) ?u32 {
        for (self.hovered.items) |id| {
            if (clickable.contains(id)) return id;
        }
        return null;
    }
};

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
