//! Drawn interaction, driven through the harness as a host drives the
//! runtime: focus and keys, pointer capture, scrolling, timers, services
//! and their fallbacks, capabilities and refresh hints.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const app = @import("../app.zig");
const Ui = app.Ui;
const Update = app.Update;
const drawn = app.drawn;

/// A page of drawn things that take input: a list that scrolls, keyed
/// rows that take keys, a box that takes the pointer, a field, timers
/// and shortcuts.
const Page = struct {
    pub const State = struct {
        keys: std.ArrayList(app.KeyEvent) = .empty,
        /// Which element's `on_key` took each key: the row or the list.
        takers: std.ArrayList(u8) = .empty,
        focus_log: std.ArrayList(i8) = .empty,
        pointers: std.ArrayList(app.Pointer) = .empty,
        clicks: usize = 0,
        saved: usize = 0,
        ticks: usize = 0,
        toasted: bool = false,
        scrolls: usize = 0,
        last_scroll: ?app.ScrollInfo = null,
        answer: ?usize = null,
        chosen: ?usize = null,
        entered: ?[]const u8 = null,
        editor: app.TextEditor = .{},
        inputs: usize = 0,
        rows: usize = 30,
        show_toast: bool = false,
        pasted: ?[]const u8 = null,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.keys.deinit(gpa);
            self.takers.deinit(gpa);
            self.focus_log.deinit(gpa);
            self.pointers.deinit(gpa);
            self.editor.deinit(gpa);
            if (self.entered) |e| gpa.free(e);
            if (self.pasted) |p| gpa.free(p);
        }
    };

    pub const Msg = union(enum) {
        row_key: app.KeyEvent,
        list_key: app.KeyEvent,
        row_focus: bool,
        pointer: app.Pointer,
        click,
        save,
        tick,
        toast_gone,
        scrolled: app.ScrollInfo,
        focus_row: usize,
        blur,
        scroll_end,
        scroll_by: f32,
        reveal: usize,
        ask,
        answered: ?usize,
        show_menu,
        chose: ?usize,
        enter_text,
        entered: ?[]const u8,
        input: app.TextInput,
        pasted: ?[]const u8,
        page_turn,
    };

    pub const Props = struct { field: bool = false };

    pub const RowKey = struct { row: usize };

    pub fn update(state: *State, msg: Msg, ctx: *Update(Page)) !void {
        const gpa = ctx.gpa;
        switch (msg) {
            .row_key => |k| {
                try state.keys.append(gpa, k);
                try state.takers.append(gpa, 'r');
            },
            .list_key => |k| {
                try state.keys.append(gpa, k);
                try state.takers.append(gpa, 'l');
            },
            .row_focus => |gained| try state.focus_log.append(gpa, if (gained) 1 else -1),
            .pointer => |p| try state.pointers.append(gpa, p),
            .click => state.clicks += 1,
            .save => state.saved += 1,
            .tick => state.ticks += 1,
            .toast_gone => {
                state.toasted = true;
                state.show_toast = false;
            },
            .scrolled => |info| {
                state.scrolls += 1;
                state.last_scroll = info;
            },
            .focus_row => |i| ctx.focus(RowKey{ .row = i }),
            .blur => ctx.blur(),
            .scroll_end => ctx.scrollTo("list", .end, .{}),
            .scroll_by => |dy| ctx.scrollTo("list", .{ .by = .init(0, dy) }, .{ .refresh = .interactive }),
            .reveal => |i| ctx.scrollIntoView(ctx.element(RowKey{ .row = i })),
            .ask => try ctx.confirm(.{ .title = "Erase?", .text = "All of it.", .buttons = &.{ "Erase", "Keep", "Later" } }, ctx.handler(.answered)),
            .answered => |i| state.answer = i,
            .show_menu => try ctx.menu(.{ .items = &.{
                .{ .title = "File", .kind = .header },
                .{ .title = "Open", .id = 1 },
                .{ .title = "Save", .id = 2, .enabled = false },
                .{ .kind = .separator },
                .{ .title = "Export", .kind = .submenu, .submenu = &.{.{ .title = "PNG", .id = 3 }} },
            }, .at = .init(20, 20) }, ctx.handler(.chose)),
            .chose => |id| state.chosen = id,
            .enter_text => try ctx.systemText(.{ .title = "Name", .initial = "Ada", .flags = .{ .url = true } }, ctx.handler(.entered)),
            .entered => |text| {
                if (state.entered) |old| gpa.free(old);
                state.entered = if (text) |t| try gpa.dupe(u8, t) else null;
            },
            .input => |input| {
                state.inputs += 1;
                _ = try ctx.editText(&state.editor, input, .{ .single_line = true }, ctx.handler(.pasted));
            },
            .pasted => |text| {
                if (state.pasted) |old| gpa.free(old);
                state.pasted = if (text) |t| try gpa.dupe(u8, t) else null;
                if (text) |t| _ = try ctx.editText(&state.editor, .{ .paste = t }, .{ .single_line = true }, ctx.handler(.pasted));
            },
            .page_turn => ctx.refresh(.page),
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Page);
        try ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true }, on.bind(.save));
        try ui.every("tick", .fromSeconds(1), on.bind(.tick));
        if (state.show_toast) try ui.after("toast", .fromSeconds(3), on.bind(.toast_gone));
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 10 }, .background_color = .white });
        defer ui.close();
        try ui.open("box", .{
            .layout = .{ .sizing = .fixedXY(100, 40) },
            .background_color = .gray(220),
            .on_pointer = on.handler(.pointer),
            .on_click = on.bind(.click),
            .focusable = true,
        });
        ui.close();
        if (props.field) {
            try drawn.textEditor(ui, "field", &state.editor, .{ .on_input = on.handler(.input), .single_line = true, .placeholder = "Type" });
        }
        // a list of rows, 20 points each, in a 100-point view
        try ui.open("list", .{
            .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(100) }, .axis = .y, .child_gap = 0 },
            .scroll = .{ .y = true, .on_scroll = on.handler(.scrolled) },
            .focus = .{ .on_key = on.handler(.list_key), .keys = .navigation_only },
        });
        defer ui.close();
        for (0..state.rows) |i| {
            const key: RowKey = .{ .row = i };
            try ui.open(key, .{
                .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(20) }, .padding = .init(4, 4, 2, 2) },
                .background_color = if (ui.focusVisible(key)) .rgb(0, 0, 255) else if (ui.focused(key)) .rgb(0, 0, 128) else .gray(240),
                .focus = .{ .on_key = on.handler(.row_key), .keys = .{ .navigation = false, .function = false }, .on_focus = if (i == 0) on.handler(.row_focus) else null },
                .focus_on_press = true,
                .on_click = on.bind(.click),
            });
            defer ui.close();
            try ui.print(.{ .font_size = 12 }, "row {d}", .{i});
        }
    }
};

const Harness = app.testing.Harness(.{}, Page);

fn harness() !Harness {
    return .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn });
}

fn row(h: *Harness, i: usize) fabrum.layout.Unit.Id {
    return h.root().element(Page.RowKey{ .row = i });
}

test "Tab moves focus in paint order and shows the ring; a press focuses without it" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try testing.expectEqual(null, h.focusedElement());
    // nothing focused: keys go through
    try testing.expect(!try h.pressKey(.tab, .{}));

    try h.tab();
    try h.expectFocused(h.root().element("box"));
    try testing.expect(h.runtime.focusVisible());
    try h.tab();
    try h.expectFocused(h.root().element("list"));
    try h.tab();
    try h.expectFocused(row(&h, 0));
    try testing.expectEqual(fabrum.Color.rgb(0, 0, 255), h.findElement(row(&h, 0)).?.data.container.background_color);
    try h.shiftTab();
    try h.expectFocused(h.root().element("list"));

    // a press focuses the row, without the ring, and tells it
    try h.clickElement(row(&h, 0));
    try h.expectFocused(row(&h, 0));
    try testing.expect(!h.runtime.focusVisible());
    try testing.expectEqual(fabrum.Color.rgb(0, 0, 128), h.findElement(row(&h, 0)).?.data.container.background_color);
    try testing.expectEqualSlices(i8, &.{ 1, -1, 1 }, h.state().focus_log.items);
    // Escape blurs, telling it
    try h.press(.escape, .{});
    try testing.expectEqual(null, h.focusedElement());
    try testing.expectEqualSlices(i8, &.{ 1, -1, 1, -1 }, h.state().focus_log.items);
}

test "keys go to the focused element by its filter, then bubble, then shortcuts, then the runtime" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.clickElement(row(&h, 1));
    // a typing key: the row's
    try h.press(.{ .char = 'a' }, .{});
    try testing.expectEqualSlices(u8, "r", h.state().takers.items);
    try testing.expectEqual(app.KeyEvent.Key{ .char = 'a' }, h.state().keys.items[0].key);
    // an arrow: not the row's (its filter leaves navigation out), so the list's
    try h.press(.down, .{});
    try testing.expectEqualSlices(u8, "rl", h.state().takers.items);
    // a shortcut, with the platform's modifier; and on a Russian layout
    const shortcut: app.KeyEvent.Modifiers = if (app.Keymap.default.superIsShortcut()) .{ .super = true } else .{ .control = true };
    try h.press(.{ .char = 's' }, shortcut);
    try testing.expectEqual(1, h.state().saved);
    try testing.expect(try h.keyEvent(.{ .key = .{ .char = 'ы' }, .physical = .key_s, .modifiers = shortcut }));
    _ = try h.keyEvent(.{ .key = .{ .char = 'ы' }, .physical = .key_s, .modifiers = shortcut, .phase = .release });
    try testing.expectEqual(2, h.state().saved);
    // Tab is nobody's but the runtime's; a function key is nobody's
    try h.press(.tab, .{});
    try h.expectFocused(row(&h, 2));
    try testing.expect(!try h.pressKey(.{ .f = 5 }, .{}));
    // a release is taken only when its press was
    try testing.expect(!try h.runtime.key(.{ .key = .{ .f = 5 }, .phase = .release }));
    // repeats are delivered like presses, once each (checklist 6)
    const before = h.state().keys.items.len;
    try h.hold(.{ .char = 'b' }, .{}, 3);
    try testing.expectEqual(before + 4, h.state().keys.items.len);
    // text on a key reaches on_key too
    try testing.expect(try h.keyEvent(.{ .key = .{ .char = 'c' }, .text = "C", .modifiers = .{ .shift = true } }));
    try testing.expectEqualStrings("C", h.state().keys.items[h.state().keys.items.len - 1].text);
}

test "Space and Enter click the focused element on release" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.tab();
    try h.expectFocused(h.root().element("box"));
    try testing.expect(try h.runtime.key(.{ .key = .space }));
    try testing.expectEqual(0, h.state().clicks);
    try testing.expect(try h.runtime.key(.{ .key = .space, .phase = .release }));
    try testing.expectEqual(1, h.state().clicks);
    try h.press(.enter, .{});
    try testing.expectEqual(2, h.state().clicks);
    // focus moving away before the release: no click
    try testing.expect(try h.runtime.key(.{ .key = .space }));
    h.runtime.focusMove(.next);
    _ = try h.runtime.key(.{ .key = .space, .phase = .release });
    try h.frame();
    try testing.expectEqual(2, h.state().clicks);
}

test "update can focus, blur, and focus scrolls the element into view" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Page, .focus_row), 20);
    try h.expectFocused(row(&h, 20));
    try testing.expect(h.runtime.focusVisible());
    const list = h.findElement(h.root().element("list")).?.bbox;
    const box = h.findElement(row(&h, 20)).?.bbox;
    try testing.expect(box.y >= list.y and box.y + box.h <= list.y + list.h);
    try testing.expect(h.scrollInfo(h.root().element("list")).?.offset.y > 0);
    try h.post(h.root().handler(Page, .blur), {});
    try testing.expectEqual(null, h.focusedElement());
    // Tab from the end wraps to the start, scrolling back
    try h.post(h.root().handler(Page, .focus_row), 29);
    try h.tab();
    try h.expectFocused(h.root().element("box"));
    try h.tab();
    try h.tab();
    try h.expectFocused(row(&h, 0));
    try testing.expectEqual(0, h.scrollInfo(h.root().element("list")).?.offset.y);
}

test "focus on an element that goes away is dropped, telling it" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.clickElement(row(&h, 0));
    h.state().rows = 0;
    try h.frame();
    try testing.expectEqual(null, h.focusedElement());
    // told on the frame after, as messages from a frame are
    try testing.expect(h.runtime.needsFrame());
    try h.frame();
    try testing.expectEqualSlices(i8, &.{ 1, -1 }, h.state().focus_log.items);
}

fn phases(h: *Harness) ![]const app.Pointer.Phase {
    var out: std.ArrayList(app.Pointer.Phase) = .empty;
    for (h.state().pointers.items) |p| try out.append(h.runtime.core.arena.allocator(), p.phase);
    return out.items;
}

test "a press captures the pointer: drags past the threshold cancel the click, and the release follows anywhere" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const box = h.findElement(h.root().element("box")).?.bbox;
    const inside: Vec2 = .init(box.x + 10, box.y + 10);
    // a click: press and release, no drag
    try h.clickAt(inside);
    try testing.expectEqualSlices(app.Pointer.Phase, &.{ .press, .release }, try phases(&h));
    try testing.expectEqual(1, h.state().clicks);
    try testing.expectEqual(Vec2.init(10, 10), h.state().pointers.items[0].local);
    try testing.expectEqual(Vec2.init(100, 40), h.state().pointers.items[0].size);
    try testing.expectEqual(1, h.state().pointers.items[0].clicks);

    // a small move while held is no drag, and still clicks
    try h.drag(inside, inside.addValues(2, 2), 1);
    try testing.expectEqual(2, h.state().clicks);
    try testing.expectEqualSlices(app.Pointer.Phase, &.{ .press, .release, .press, .release }, try phases(&h));

    // a drag out of the box: drags, then a release outside, and no click
    try h.drag(inside, .init(box.x + 200, box.y + 100), 3);
    try testing.expectEqual(2, h.state().clicks);
    const last = h.state().pointers.items[h.state().pointers.items.len - 1];
    try testing.expectEqual(app.Pointer.Phase.release, last.phase);
    try testing.expectEqual(Vec2.init(200, 100), last.local);
    try testing.expectEqual(app.Pointer.Phase.drag, h.state().pointers.items[h.state().pointers.items.len - 2].phase);
    try testing.expect(h.state().pointers.items[h.state().pointers.items.len - 2].buttons.isSet(app.MouseEvent.primary));
}

test "double and triple clicks count, a long press cancels the click, and losing the pointer cancels" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const box = h.findElement(h.root().element("box")).?.bbox;
    const inside: Vec2 = .init(box.x + 10, box.y + 10);
    try h.clickAt(inside);
    try h.clickAt(inside);
    try h.clickAt(inside.addValues(1, 0));
    const presses = h.state().pointers.items;
    try testing.expectEqual(1, presses[0].clicks);
    try testing.expectEqual(2, presses[2].clicks);
    try testing.expectEqual(3, presses[4].clicks);
    // later, or elsewhere, it starts over
    try h.advance(.fromSeconds(2));
    try h.clickAt(inside);
    try testing.expectEqual(1, h.state().pointers.items[6].clicks);
    try h.clickAt(.init(box.x + 60, box.y + 10));
    try testing.expectEqual(1, h.state().pointers.items[8].clicks);
    try testing.expectEqual(5, h.state().clicks);

    try h.longPress(inside);
    try testing.expectEqual(5, h.state().clicks);
    const n = h.state().pointers.items.len;
    try testing.expectEqual(app.Pointer.Phase.long_press, h.state().pointers.items[n - 2].phase);
    try testing.expectEqual(app.Pointer.Phase.release, h.state().pointers.items[n - 1].phase);

    var buttons: app.MouseEvent.Buttons = .empty;
    buttons.set(app.MouseEvent.primary);
    _ = try h.runtime.mouse(.{ .position = inside, .pressed = buttons });
    try h.runtime.cancelPointer();
    try h.frame();
    try testing.expectEqual(app.Pointer.Phase.cancel, h.state().pointers.items[h.state().pointers.items.len - 1].phase);
    _ = try h.runtime.mouse(.{ .position = inside });
    try h.frame();
    try testing.expectEqual(5, h.state().clicks);
}

test "the wheel scrolls the innermost container, clamped, the rest going to its ancestors, and the thumb drags" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const list = h.root().element("list");
    const info = h.scrollInfo(list).?;
    try testing.expectEqual(100, info.box.y);
    try testing.expectEqual(600, info.content.y);
    try testing.expectEqual(Vec2.init(0, 0), info.offset);

    try testing.expect(try h.scroll("row 1", .init(0, 50)));
    try testing.expectEqual(50, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(1, h.state().scrolls);
    // the rows moved up, and the one scrolled into view is clicked where it is
    try testing.expectEqual(1, h.state().last_scroll.?.offset.y / 50);
    const r5 = h.findElement(row(&h, 5)).?.bbox;
    try testing.expect(r5.y < h.findElement(list).?.bbox.y + 100);
    try h.click("row 5");
    try h.expectFocused(row(&h, 5));
    // damage of a scroll is the list's box alone, marked interactive
    _ = try h.runtime.damage();
    try testing.expect(try h.scrollElement(list, .init(0, 20)));
    const regions = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.interactive, h.runtime.refresh());
    const box = h.findElement(list).?.bbox;
    for (regions) |r| {
        try testing.expect(r.x >= box.x - 2 and r.x + r.w <= box.x + box.w + 2);
        try testing.expect(r.y >= box.y - 2 and r.y + r.h <= box.y + box.h + 2);
    }
    // past the end clamps; a wheel over the page scrolls nothing
    try testing.expect(try h.scrollElement(list, .init(0, 1000)));
    try testing.expectEqual(500, h.scrollInfo(list).?.offset.y);
    _ = try h.scrollAt(.init(5, 5), .init(0, 10));
    try testing.expectEqual(500, h.scrollInfo(list).?.offset.y);
    try testing.expect(try h.scrollElement(list, .init(0, -500)));
    try testing.expectEqual(0, h.scrollInfo(list).?.offset.y);
    // negative past the start clamps too
    _ = try h.scrollElement(list, .init(0, -10));
    try testing.expectEqual(0, h.scrollInfo(list).?.offset.y);

    // the thumb: at least 20 points long; dragging it moves the content by the track's share
    const thumb = h.findElement(h.root().element(app.ui_internal.ThumbKey{ .container = list.id, .axis = .y })).?.bbox;
    try testing.expectApproxEqAbs(@as(f32, 20), thumb.h, 0.5);
    const track = 100 - 2 * app.runtime_internal.Core.scrollbar_inset;
    try h.drag(.init(thumb.x + 2, thumb.y + 2), .init(thumb.x + 2, thumb.y + 2 + 40), 4);
    try testing.expectApproxEqAbs(40 * 500 / (track - thumb.h), h.scrollInfo(list).?.offset.y, 1);
    try testing.expectEqual(app.Refresh.interactive, blk: {
        _ = try h.runtime.damage();
        break :blk h.runtime.refresh();
    });

    // update scrolls to the end, as content unless it asks otherwise, and reveals a row
    _ = try h.runtime.damage();
    try h.post(h.root().handler(Page, .scroll_end), {});
    try testing.expectEqual(500, h.scrollInfo(list).?.offset.y);
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.content, h.runtime.refresh());
    try h.post(h.root().handler(Page, .scroll_by), -100);
    try testing.expectEqual(400, h.scrollInfo(list).?.offset.y);
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.interactive, h.runtime.refresh());
    try h.post(h.root().handler(Page, .scroll_end), {});
    try h.post(h.root().handler(Page, .reveal), 2);
    try testing.expectEqual(40, h.scrollInfo(list).?.offset.y);
    // content shrinking clamps the offset on the next frame
    try h.post(h.root().handler(Page, .scroll_end), {});
    h.state().rows = 8;
    try h.frame();
    try testing.expect(h.runtime.needsFrame());
    try h.frame();
    try testing.expectEqual(60, h.scrollInfo(list).?.offset.y);
}

test "a trackpad gesture stays with the container it began in" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const list = h.root().element("list");
    const over = app.testing.center(h.findElement(row(&h, 1)).?);
    try testing.expect(try h.mouse(.{ .position = over, .scroll_delta = .init(0, 30), .scroll_phase = .began }));
    // the pointer leaves the list: the gesture still scrolls it
    try testing.expect(try h.mouse(.{ .position = .init(5, 5), .scroll_delta = .init(0, 30), .scroll_phase = .changed }));
    try testing.expectEqual(60, h.scrollInfo(list).?.offset.y);
    try testing.expect(try h.mouse(.{ .position = .init(5, 5), .scroll_delta = .init(0, 10), .scroll_phase = .ended }));
    try testing.expectEqual(70, h.scrollInfo(list).?.offset.y);
    // after the gesture, a wheel elsewhere scrolls nothing
    _ = try h.mouse(.{ .position = .init(5, 5), .scroll_delta = .init(0, 10) });
    try testing.expectEqual(70, h.scrollInfo(list).?.offset.y);
}

test "timers fire while declared, every period or once" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try testing.expectEqual(std.time.ns_per_s, h.runtime.nextFrame().?.nanoseconds);
    try h.advance(.fromMilliseconds(999));
    try testing.expectEqual(0, h.state().ticks);
    try h.advance(.fromMilliseconds(1));
    try testing.expectEqual(1, h.state().ticks);
    try h.advance(.fromSeconds(1));
    try testing.expectEqual(2, h.state().ticks);
    // a stall fires once, not a burst
    try h.advance(.fromSeconds(5));
    try testing.expectEqual(3, h.state().ticks);

    h.state().show_toast = true;
    try h.frame();
    try h.advance(.fromSeconds(2));
    try testing.expect(!h.state().toasted);
    try h.advance(.fromSeconds(1));
    try testing.expect(h.state().toasted);
    try testing.expect(!h.state().show_toast);
    // the one-shot is gone; the periodic one is still due
    try testing.expectEqual(1, h.runtime.core.timers.count());
}

test "every one-shot timer due in a frame fires once, however many there are" {
    const Alarms = struct {
        pub const State = struct { fired: usize = 0 };
        pub const Msg = union(enum) { fired };
        pub const Props = struct {};

        pub fn update(state: *State, msg: Msg, _: *Update(@This())) void {
            switch (msg) {
                .fired => state.fired += 1,
            }
        }

        pub fn view(ui: *Ui, _: *const State, _: Props) !void {
            const on = ui.messages(@This());
            for (0..40) |i| try ui.after(i, .fromSeconds(1), on.bind(.fired));
        }
    };
    var h: app.testing.Harness(.{}, Alarms) = try .init(.{}, .{ .viewport = .init(100, 100) });
    defer h.deinit();
    try h.frame();
    try h.advance(.fromSeconds(1));
    try testing.expectEqual(40, h.state().fired);
    // Continuous declarations stay completed.
    try h.advance(.fromMilliseconds(1));
    try testing.expectEqual(40, h.state().fired);
    try h.advance(.fromSeconds(1));
    try testing.expectEqual(40, h.state().fired);
    try testing.expectEqual(null, h.runtime.nextFrame());
}

test "without the host's dialogs and menus, the runtime draws them" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn, .services = .basic });
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Page, .ask), {});
    try h.expectText("Erase?");
    try h.expectText("All of it.");
    // modal: the dialog has the keys, and the page under it isn't clicked
    try h.click("row 0");
    try testing.expectEqual(0, h.state().clicks);
    try h.click("Keep");
    try testing.expectEqual(@as(?usize, 1), h.state().answer);
    try h.expectNoText("Erase?");
    // Enter presses the default button; Escape dismisses
    try h.post(h.root().handler(Page, .ask), {});
    try h.frame();
    try h.press(.enter, .{});
    try testing.expectEqual(@as(?usize, 0), h.state().answer);
    try h.post(h.root().handler(Page, .ask), {});
    try h.frame();
    try h.press(.escape, .{});
    try testing.expectEqual(@as(?usize, null), h.state().answer);
    try h.expectNoText("Erase?");

    try h.post(h.root().handler(Page, .show_menu), {});
    try h.expectText("Open");
    try h.expectText("PNG");
    // a disabled item does nothing
    try h.click("Save");
    try h.expectText("Open");
    try testing.expectEqual(null, h.state().chosen);
    try h.click("PNG");
    try testing.expectEqual(@as(?usize, 3), h.state().chosen);
    try h.expectNoText("Open");
    // clicking outside dismisses
    try h.post(h.root().handler(Page, .show_menu), {});
    try h.clickAt(.init(290, 290));
    try testing.expectEqual(@as(?usize, null), h.state().chosen);
    // text entry has no fallback
    try testing.expectError(error.Unsupported, h.post(h.root().handler(Page, .enter_text), {}));
}

test "the host's dialogs, menus and text entry answer through replies" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Page, .ask), {});
    try h.expectNoText("Erase?");
    try testing.expectEqualStrings("Later", h.tree.dialogs.items[0].buttons[2]);
    try h.answerDialog(2);
    try testing.expectEqual(@as(?usize, 2), h.state().answer);

    try h.post(h.root().handler(Page, .show_menu), {});
    const menu = h.tree.menus.items[0];
    try testing.expectEqual(1, menu.find("PNG").?.depth);
    try testing.expectEqual(app.platform.MenuItem.Kind.separator, menu.items[3].kind);
    try testing.expectError(error.MenuItemDisabled, h.chooseMenuItem(2));
    try h.chooseMenuItem(1);
    try testing.expectEqual(@as(?usize, 1), h.state().chosen);

    try h.post(h.root().handler(Page, .enter_text), {});
    try testing.expectEqualStrings("Ada", h.tree.text_requests.items[0].initial);
    try testing.expect(h.tree.text_requests.items[0].flags.url);
    try h.enterText("Ada Lovelace");
    try testing.expectEqualStrings("Ada Lovelace", h.state().entered.?);
}

test "an app-owned editor gets every input, and the clipboard goes through the services (checklist 7, 8)" {
    var h: Harness = try .init(.{ .field = true }, .{ .viewport = .init(300, 300), .widgets = .drawn, .keymap = .windows });
    defer h.deinit();
    try h.frame();
    const field = h.root().child(drawn.TextBox, "field").element("field");
    try h.clickElement(field);
    try h.type_("hello world");
    try testing.expectEqualStrings("hello world", h.state().editor.text.items);
    // Ctrl-A, Ctrl-C on a Russian layout: the physical keys say what they mean
    try testing.expect(try h.keyEvent(.{ .key = .{ .char = 'ф' }, .physical = .key_a, .modifiers = .{ .control = true } }));
    try testing.expect(try h.keyEvent(.{ .key = .{ .char = 'с' }, .physical = .key_c, .modifiers = .{ .control = true } }));
    try testing.expectEqualStrings("hello world", h.clipboard().?);
    // a multi-line paste from the clipboard becomes one line
    try h.tree.setClipboard("a\nb\r\nc");
    try h.press(.end, .{});
    try h.press(.{ .char = 'v' }, .{ .control = true });
    try testing.expectEqualStrings("hello worlda b c", h.state().editor.text.items);
    try testing.expectEqualStrings("a\nb\r\nc", h.state().pasted.?);
    // a host's committed text, with no keys at all
    try h.textInput(.{ .commit = "!" });
    try testing.expectEqualStrings("hello worlda b c!", h.state().editor.text.items);
    // the caret is drawn where the text ends, and blinks
    const caret_on = h.runtime.context().units.items.len;
    try h.advance(.fromMilliseconds(600));
    try testing.expectEqual(caret_on - 1, h.runtime.context().units.items.len);
    try h.advance(.fromMilliseconds(500));
    try testing.expectEqual(caret_on, h.runtime.context().units.items.len);
    // the cursor over the field is an I-beam
    try h.hoverElement(field);
    try testing.expectEqual(app.Cursor.text, h.runtime.cursor());
}

test "a grayscale platform gets a high-contrast theme, and apps can ask for a page refresh" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn, .capabilities = .{ .color = .gray16, .hover = false, .animation = .none, .pointer = .touch, .keyboard = .on_screen } });
    defer h.deinit();
    try h.frame();
    const theme = h.runtime.core.theme;
    try testing.expectEqual(fabrum.Color.black, theme.accent);
    try testing.expectEqual(fabrum.Color.white, theme.control_background);
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.content, h.runtime.refresh());
    try h.post(h.root().handler(Page, .page_turn), {});
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.page, h.runtime.refresh());
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.content, h.runtime.refresh());
}

test "a drawn field asks for the system keyboard where there is one" {
    var h: Harness = try .init(.{ .field = true }, .{ .viewport = .init(300, 300), .widgets = .drawn, .capabilities = .{ .keyboard = .on_screen, .pointer = .touch, .hover = false } });
    defer h.deinit();
    try h.frame();
    const field = h.root().child(drawn.TextBox, "field").element("field");
    try h.clickElement(field);
    try testing.expectEqual(1, h.tree.text_requests.items.len);
    try h.enterText("typed on screen");
    try testing.expectEqualStrings("typed on screen", h.state().editor.text.items);
}

// Touch pans

/// Two scroll containers, one inside the other: an outer view of 150
/// points over the inner list and a filler, the list 100 points over 30
/// rows of 20. The rows click; the first takes the pointer.
const Lists = struct {
    pub const State = struct { clicks: usize = 0, pointers: usize = 0 };
    pub const Msg = union(enum) { click, pointer: app.Pointer };
    pub const Props = struct {};
    pub const RowKey = struct { row: usize };

    pub fn update(state: *State, msg: Msg, _: *Update(Lists)) void {
        switch (msg) {
            .click => state.clicks += 1,
            .pointer => state.pointers += 1,
        }
    }

    pub fn view(ui: *Ui, _: *const State, _: Props) !void {
        const on = ui.messages(Lists);
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y }, .background_color = .white });
        defer ui.close();
        try ui.open("outer", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(150) }, .axis = .y, .child_gap = 0 }, .scroll = .{ .y = true } });
        defer ui.close();
        {
            try ui.open("list", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(100) }, .axis = .y, .child_gap = 0 }, .scroll = .{ .y = true } });
            defer ui.close();
            for (0..30) |i| {
                const key: RowKey = .{ .row = i };
                try ui.open(key, .{
                    .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(20) } },
                    .background_color = .gray(240),
                    .on_click = on.bind(.click),
                    .on_pointer = if (i == 0) on.handler(.pointer) else null,
                });
                ui.close();
            }
        }
        try ui.open("filler", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(200) } }, .background_color = .gray(200) });
        ui.close();
    }
};

const ListsHarness = app.testing.Harness(.{}, Lists);
const touch: app.Capabilities = .{ .pointer = .touch, .hover = false };

fn listsHarness(capabilities: app.Capabilities) !ListsHarness {
    return .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn, .capabilities = capabilities });
}

fn listRow(h: *ListsHarness, i: usize) Vec2 {
    return app.testing.center(h.findElement(h.root().element(Lists.RowKey{ .row = i })).?);
}

test "a touch pan scrolls the list under the finger, marked interactive, and cancels the click; a tap still clicks" {
    var h = try listsHarness(touch);
    defer h.deinit();
    try h.frame();
    const list = h.root().element("list");
    const row2 = listRow(&h, 2);
    _ = try h.runtime.damage();
    try h.drag(row2, row2.addValues(0, -50), 5);
    try testing.expectEqual(50, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(0, h.state().clicks);
    _ = try h.runtime.damage();
    try testing.expectEqual(app.Refresh.interactive, h.runtime.refresh());

    // a tap, and a press that moves within the threshold, still click
    const row5 = listRow(&h, 5);
    try h.clickAt(row5);
    try h.drag(row5, row5.addValues(0, -2), 1);
    try testing.expectEqual(2, h.state().clicks);
    try testing.expectEqual(50, h.scrollInfo(list).?.offset.y);

    // a pan that comes back to where it pressed clicks nothing: the
    // threshold cancelled the click
    var primary: app.MouseEvent.Buttons = .empty;
    primary.set(app.MouseEvent.primary);
    try testing.expect(try h.mouse(.{ .position = row5, .pressed = primary }));
    try testing.expect(try h.mouse(.{ .position = row5.addValues(0, -30), .pressed = primary }));
    try testing.expectEqual(80, h.scrollInfo(list).?.offset.y);
    try testing.expect(try h.mouse(.{ .position = row5, .pressed = primary }));
    try testing.expectEqual(50, h.scrollInfo(list).?.offset.y);
    try testing.expect(try h.mouse(.{ .position = row5 }));
    try h.frame();
    try testing.expectEqual(2, h.state().clicks);
}

test "a touch pan stays with the container it began in, clamps, and hands the rest to the outer one" {
    var h = try listsHarness(touch);
    defer h.deinit();
    try h.frame();
    const list = h.root().element("list");
    const outer = h.root().element("outer");
    var primary: app.MouseEvent.Buttons = .empty;
    primary.set(app.MouseEvent.primary);

    // past the end, the list stops and the outer view takes the rest
    _ = try h.scrollElement(list, .init(0, 500));
    try testing.expectEqual(500, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(0, h.scrollInfo(outer).?.offset.y);
    _ = try h.mouse(.{ .position = .init(150, 90), .pressed = primary });
    _ = try h.mouse(.{ .position = .init(150, 10), .pressed = primary });
    try h.frame();
    try testing.expectEqual(500, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(80, h.scrollInfo(outer).?.offset.y);
    // back down, over the filler now: the list, not the filler's view, scrolls
    _ = try h.mouse(.{ .position = .init(150, 200), .pressed = primary });
    try h.frame();
    try testing.expectEqual(310, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(80, h.scrollInfo(outer).?.offset.y);
    // and the pointer leaving the page altogether still scrolls it
    _ = try h.mouse(.{ .position = .init(150, 290), .pressed = primary });
    try h.frame();
    try testing.expectEqual(220, h.scrollInfo(list).?.offset.y);
    _ = try h.mouse(.{ .position = .init(150, 290) });
    try h.frame();
    // after the release, a press elsewhere pans nothing
    _ = try h.mouse(.{ .position = .init(150, 290), .pressed = primary });
    _ = try h.mouse(.{ .position = .init(150, 200), .pressed = primary });
    _ = try h.mouse(.{ .position = .init(150, 200) });
    try h.frame();
    try testing.expectEqual(220, h.scrollInfo(list).?.offset.y);
    try testing.expectEqual(80, h.scrollInfo(outer).?.offset.y);
}

test "a row that takes the pointer owns the touch, losing the pointer ends a pan, and a mouse drag doesn't pan" {
    var h = try listsHarness(touch);
    defer h.deinit();
    try h.frame();
    const list = h.root().element("list");
    try h.drag(listRow(&h, 0), listRow(&h, 0).addValues(0, 50), 3);
    try testing.expect(h.state().pointers > 0);
    try testing.expectEqual(0, h.scrollInfo(list).?.offset.y);

    var primary: app.MouseEvent.Buttons = .empty;
    primary.set(app.MouseEvent.primary);
    const row3 = listRow(&h, 3);
    _ = try h.mouse(.{ .position = row3, .pressed = primary });
    _ = try h.mouse(.{ .position = row3.addValues(0, -20), .pressed = primary });
    try testing.expectEqual(20, h.scrollInfo(list).?.offset.y);
    try h.runtime.cancelPointer();
    _ = try h.mouse(.{ .position = row3.addValues(0, -40), .pressed = primary });
    try h.frame();
    try testing.expectEqual(20, h.scrollInfo(list).?.offset.y);

    var m = try listsHarness(.{});
    defer m.deinit();
    try m.frame();
    try m.drag(listRow(&m, 2), listRow(&m, 2).addValues(0, -50), 5);
    try testing.expectEqual(0, m.scrollInfo(m.root().element("list")).?.offset.y);
}

test "a layout that outgrows its capacity fails the frame with LayoutCapacity, and the next frame starts over" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn, .context = .{ .units = 256, .breadth = 8 } });
    defer h.deinit();
    // the list's 30 rows are more children than the breadth allows (outside tests the layout logs which limit)
    try testing.expectError(error.LayoutCapacity, h.frame());
    try testing.expect(!h.runtime.core.laid_out);
    // fewer rows fit, and the frame after the failure lays out and takes input
    h.state().rows = 5;
    try h.frame();
    try h.expectText("row 4");
    try h.click("row 3");
    try testing.expectEqual(1, h.state().clicks);
}

test "a scroll container whose rows fill the breadth fails the frame rather than losing its scrollbar" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(300, 300), .widgets = .drawn, .context = .{ .units = 256, .breadth = 8 } });
    defer h.deinit();
    try testing.expectError(error.LayoutCapacity, h.frame());
    // eight rows fill the list's breadth; the thumb drawn as it closes,
    // once a frame has measured its content, is a ninth child
    h.state().rows = 8;
    try h.frame();
    try testing.expectError(error.LayoutCapacity, h.frame());
    // with one row fewer the thumb fits, and is there
    h.state().rows = 7;
    try h.frame();
    const list = h.root().element("list");
    try testing.expect(h.findElement(h.root().element(app.ui_internal.ThumbKey{ .container = list.id, .axis = .y })) != null);
}

test "after re-arms only after absence or a changed key or delay" {
    const Alarm = struct {
        pub const State = struct { declared: bool = true, key: u8 = 0, delay_ms: i64 = 100, fired: usize = 0 };
        pub const Msg = union(enum) { fired };
        pub const Props = struct {};
        pub fn update(state: *State, _: Msg, _: *Update(@This())) void {
            state.fired += 1;
        }
        pub fn view(ui: *Ui, state: *const State, _: Props) !void {
            if (state.declared) try ui.after(state.key, .fromMilliseconds(state.delay_ms), ui.messages(@This()).bind(.fired));
        }
    };
    var h: app.testing.Harness(.{}, Alarm) = try .init(.{}, .{ .viewport = .init(100, 100) });
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(100));
    try testing.expectEqual(1, h.state().fired);
    try h.advance(.fromSeconds(5));
    try testing.expectEqual(1, h.state().fired);
    try testing.expectEqual(null, h.runtime.nextFrame());
    h.state().declared = false;
    try h.frame();
    h.state().declared = true;
    try h.frame();
    try h.advance(.fromMilliseconds(100));
    try testing.expectEqual(2, h.state().fired);
    h.state().delay_ms = 200;
    try h.frame();
    try h.advance(.fromMilliseconds(199));
    try testing.expectEqual(2, h.state().fired);
    try h.advance(.fromMilliseconds(1));
    try testing.expectEqual(3, h.state().fired);
    h.state().key = 1;
    try h.frame();
    try h.advance(.fromMilliseconds(200));
    try testing.expectEqual(4, h.state().fired);
    // Changing the delay while pending restarts from the declaration.
    h.state().key = 2;
    try h.frame();
    try h.advance(.fromMilliseconds(100));
    h.state().delay_ms = 300;
    try h.frame();
    try h.advance(.fromMilliseconds(200));
    try testing.expectEqual(4, h.state().fired);
    try h.advance(.fromMilliseconds(100));
    try testing.expectEqual(5, h.state().fired);
}
