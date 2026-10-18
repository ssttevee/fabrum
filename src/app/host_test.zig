//! The host contract of the `none` platform, driven as a host drives it:
//! which input the app takes, when the next frame is due, and what
//! changed.
const std = @import("std");
const testing = std.testing;

const fabrum = @import("../root.zig");
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const layout = fabrum.layout;
const app = fabrum.app;

const Rt = app.Runtime(.{});

/// An overlay: a panel with a button and a field in the middle of an
/// otherwise empty, transparent viewport, and a full-screen backdrop when
/// `dim` is on.
const Overlay = struct {
    pub const State = struct {
        clicks: usize = 0,
        dim: bool = false,
        animating: bool = false,
        wake_at: ?std.Io.Timestamp = null,
        last_pointer: ?app.Pointer = null,
    };
    pub const Msg = union(enum) { click, toggle_dim, pointer: app.Pointer };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, _: *app.Update(Overlay)) void {
        switch (msg) {
            .click => state.clicks += 1,
            .toggle_dim => state.dim = !state.dim,
            .pointer => |p| state.last_pointer = p,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Overlay);
        if (state.animating) ui.animate();
        if (state.wake_at) |t| ui.frameAt(t);
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .child_alignment = .center } });
        defer ui.close();
        try ui.open("panel", .{
            .layout = .{ .padding = .all(10), .child_gap = 10, .axis = .y },
            .background_color = .rgba(255, 255, 255, 200),
        });
        defer ui.close();
        try ui.open("button", .{
            .layout = .{ .sizing = .fixedXY(80, 20) },
            .background_color = if (ui.hovered("button")) .gray(200) else .gray(230),
            .on_click = on.bind(.click),
            .focusable = true,
        });
        ui.close();
        try ui.open("field", .{
            .layout = .{ .sizing = .fixedXY(80, 20) },
            .border = .{ .color = if (ui.focused("field")) .rgb(0, 0, 255) else .gray(150), .widths = .all(1) },
            .on_pointer = on.handler(.pointer),
            .focusable = true,
            .focus_on_press = true,
        });
        ui.close();
        if (state.dim) {
            try ui.open("backdrop", .{
                .layout = .{ .sizing = .grow(.{}) },
                .floating = .{ .mode = .root },
                .background_color = .rgba(0, 0, 0, 90),
            });
            ui.close();
        }
    }
};

const viewport: Vec2 = .init(300, 200);

fn frame(rt: *Rt, now: i96) !void {
    _ = try rt.frame(Overlay, .{}, viewport, .fromNanoseconds(now));
}

fn center(rt: *Rt, key: []const u8) Vec2 {
    const unit = rt.context().getUnitById(app.testing.rootInstance(Overlay).element(key)).?;
    return app.testing.center(unit);
}

fn primary() app.MouseEvent.Buttons {
    var buttons: app.MouseEvent.Buttons = .empty;
    buttons.set(app.MouseEvent.primary);
    return buttons;
}

test "the app takes pointer input over what it shows, and lets the rest through" {
    var rt: Rt = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    try frame(&rt, 0);

    // over the button, the panel's padding, and nothing
    try testing.expect(try rt.mouse(.{ .position = center(&rt, "button") }));
    try testing.expect(try rt.mouse(.{ .position = center(&rt, "panel").addValues(0, -24) }));
    try testing.expect(!try rt.mouse(.{ .position = .init(5, 5) }));
    try testing.expect(!try rt.mouse(.{ .position = .init(5, 5), .scroll_delta = .init(0, 3) }));

    // a press that starts on the app is the app's until it is released,
    // wherever the pointer goes
    try testing.expect(try rt.mouse(.{ .position = center(&rt, "button"), .pressed = primary() }));
    try testing.expect(try rt.mouse(.{ .position = .init(5, 5), .pressed = primary() }));
    try testing.expect(try rt.mouse(.{ .position = .init(5, 5) }));
    try testing.expect(!try rt.mouse(.{ .position = .init(6, 5) }));
    // and one that starts elsewhere is never the app's
    try testing.expect(!try rt.mouse(.{ .position = .init(5, 5), .pressed = primary() }));
    try testing.expect(!try rt.mouse(.{ .position = .init(5, 6) }));

    // a full-screen backdrop takes everything
    try rt.post(app.testing.rootInstance(Overlay).handler(Overlay, .toggle_dim), {});
    try frame(&rt, 1);
    try testing.expect(try rt.mouse(.{ .position = .init(5, 5) }));
}

test "keys are the app's only while a drawn element has focus" {
    var rt: Rt = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    try frame(&rt, 0);

    // nothing focused: even Tab goes through
    try testing.expect(!try rt.key(.{ .key = .tab }));
    try testing.expect(!try rt.key(.{ .key = .tab, .phase = .release }));

    // pressing the field focuses it, and tells it where it was pressed
    const field = center(&rt, "field");
    _ = try rt.mouse(.{ .position = field.addValues(-30, 2), .pressed = primary() });
    _ = try rt.mouse(.{ .position = field.addValues(-30, 2) });
    try frame(&rt, 1);
    const pointer = rt.rootState(Overlay).?.last_pointer.?;
    try testing.expectEqual(Vec2.init(10, 12), pointer.local);
    try testing.expectEqual(Vec2.init(80, 20), pointer.size);
    try testing.expectEqual(app.testing.rootInstance(Overlay).element("field").id, rt.focused().?.unit);

    // Tab moves focus, and its release is taken too
    try testing.expect(try rt.key(.{ .key = .tab }));
    try testing.expect(try rt.key(.{ .key = .tab, .phase = .release }));
    try testing.expectEqual(app.testing.rootInstance(Overlay).element("button").id, rt.focused().?.unit);
    // Space clicks the focused button
    try testing.expect(try rt.key(.{ .key = .space }));
    try testing.expectEqual(1, rt.rootState(Overlay).?.clicks);
    // keys the app doesn't use yet go through
    try testing.expect(!try rt.key(.{ .key = .other }));
    // Escape gives focus back
    try testing.expect(try rt.key(.{ .key = .escape }));
    try testing.expectEqual(null, rt.focused());
    try testing.expect(!try rt.key(.{ .key = .space }));

    // pressing nothing of the app's clears focus too
    _ = try rt.mouse(.{ .position = field, .pressed = primary() });
    _ = try rt.mouse(.{ .position = field });
    try testing.expect(rt.focused() != null);
    _ = try rt.mouse(.{ .position = .init(5, 5), .pressed = primary() });
    _ = try rt.mouse(.{ .position = .init(5, 5) });
    try testing.expectEqual(null, rt.focused());
}

test "nextFrame says when the host should run a frame" {
    var rt: Rt = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    // before the first frame: now
    try testing.expectEqual(@as(i96, 0), rt.nextFrame().?.nanoseconds);
    try frame(&rt, 100);
    try testing.expectEqual(null, rt.nextFrame());

    // input that changes something: as soon as possible
    _ = try rt.mouse(.{ .position = center(&rt, "button") });
    try testing.expectEqual(@as(i96, 100), rt.nextFrame().?.nanoseconds);
    try frame(&rt, 200);
    try testing.expectEqual(null, rt.nextFrame());

    // a posted message: as soon as possible
    const state = rt.rootState(Overlay).?;
    try rt.post(app.testing.rootInstance(Overlay).handler(Overlay, .click), {});
    try testing.expectEqual(@as(i96, 200), rt.nextFrame().?.nanoseconds);
    try frame(&rt, 300);

    // a view that animates asks for every frame, until it stops
    state.animating = true;
    try frame(&rt, 400);
    try testing.expectEqual(@as(i96, 400), rt.nextFrame().?.nanoseconds);
    state.animating = false;
    try frame(&rt, 500);
    try testing.expectEqual(null, rt.nextFrame());

    // a view that asks for a later frame gets that time
    state.wake_at = .fromNanoseconds(1_000);
    try frame(&rt, 600);
    try testing.expectEqual(@as(i96, 1_000), rt.nextFrame().?.nanoseconds);
}

test "damage covers what changed, and redrawing it gives the same pixels as redrawing everything" {
    var rt: Rt = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    const w: u32 = @intFromFloat(viewport.x);
    const h: u32 = @intFromFloat(viewport.y);
    const partial = try testing.allocator.alignedAlloc(u8, .@"4", w * h * 4);
    defer testing.allocator.free(partial);
    const full = try testing.allocator.alignedAlloc(u8, .@"4", w * h * 4);
    defer testing.allocator.free(full);
    var renderer: layout.TestRenderer = .{};

    try frame(&rt, 0);
    try testing.expectEqualSlices(Rect, &.{.init(0, 0, 300, 200)}, try rt.damage());
    try layout.draw(&renderer, rt.commands(), .pixels, .packed_(partial, w, h, .rgba8_premultiplied), null);
    // nothing changed
    try frame(&rt, 1);
    try testing.expectEqual(0, (try rt.damage()).len);

    const steps = [_]struct { point: Vec2, press: bool }{
        .{ .point = center(&rt, "button"), .press = false }, // hover the button
        .{ .point = center(&rt, "field"), .press = true }, // focus the field
        .{ .point = .init(5, 5), .press = true }, // and give focus back
    };
    for (steps, 2..) |step, t| {
        if (step.press) _ = try rt.mouse(.{ .position = step.point, .pressed = primary() });
        _ = try rt.mouse(.{ .position = step.point });
        try frame(&rt, @intCast(t));
        const damage = try rt.damage();
        try testing.expect(damage.len > 0);
        // a small part of the viewport
        var area: f32 = 0;
        for (damage) |r| area += r.w * r.h;
        try testing.expect(area < viewport.x * viewport.y / 4);
        try layout.draw(&renderer, rt.commands(), .pixels, .packed_(partial, w, h, .rgba8_premultiplied), damage);
        try layout.draw(&renderer, rt.commands(), .pixels, .packed_(full, w, h, .rgba8_premultiplied), null);
        try testing.expectEqualSlices(u8, full, partial);
    }
}
