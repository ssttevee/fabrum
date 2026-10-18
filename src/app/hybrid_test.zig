//! Native widgets in fabrum's layout, driven through the headless platform:
//! the reconciler, controlled values, focus and stacking.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const Rect = fabrum.Rect;
const app = fabrum.app;
const widgets = app.widgets;
const menus = app.menus;
const dialogs = app.dialogs;
const native = app.native;

/// A form of native controls around drawn ones: the screen most tests use.
const Form = struct {
    pub const State = struct {
        name: std.ArrayList(u8) = .empty,
        /// Makes `update` store names in capitals, so the model differs from
        /// what was typed.
        shout: bool = false,
        agree: bool = false,
        loud: bool = false,
        volume: f64 = 0.25,
        sent: usize = 0,
        chosen: ?u8 = null,
        dialog: bool = false,
        asking: bool = false,
        answer: ?usize = null,
        greeted: usize = 0,
        /// The keys of the repeated fields, in order.
        rows: [3]u8 = .{ 'a', 'b', 'c' },
        show_rows: bool = false,
        /// Whether the send button is a checkbox instead, to replace one
        /// kind of widget with another under one key.
        send_as_checkbox: bool = false,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.name.deinit(gpa);
        }
    };

    pub const Msg = union(enum) {
        name: []const u8,
        clear,
        agree: bool,
        loud: bool,
        volume: f64,
        send,
        choose: u8,
        open_dialog,
        close_dialog,
        greet,
        ask,
        answered: usize,
    };

    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Form)) void {
        switch (msg) {
            .name => |text| {
                // the message borrows the text: copy it
                state.name.clearRetainingCapacity();
                state.name.appendSlice(ctx.gpa, text) catch return;
                if (state.shout) for (state.name.items) |*c| {
                    c.* = std.ascii.toUpper(c.*);
                };
            },
            .clear => state.name.clearRetainingCapacity(),
            .agree => |on| state.agree = on,
            .loud => |on| state.loud = on,
            .volume => |v| state.volume = @round(v * 10) / 10,
            .send => state.sent += 1,
            .choose => |i| state.chosen = i,
            .open_dialog => state.dialog = true,
            .close_dialog => state.dialog = false,
            .greet => state.greeted += 1,
            .ask => state.asking = true,
            .answered => |i| {
                state.answer = i;
                state.asking = false;
            },
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Form);
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(10), .child_gap = 10 } });
        defer ui.close();

        try ui.text("Form", .{});
        try widgets.textField(ui, "name", .{ .text = state.name.items, .placeholder = "Name", .on_change = on.handler(.name) });
        {
            try ui.open(null, .{ .layout = .{ .child_gap = 8, .child_alignment = .center_left } });
            defer ui.close();
            try widgets.checkbox(ui, "agree", .{ .label = "I agree", .checked = state.agree, .on_change = on.handler(.agree) });
            try widgets.toggle(ui, "loud", .{ .on = state.loud, .on_change = on.handler(.loud) });
            if (state.send_as_checkbox) {
                try widgets.checkbox(ui, "send", .{ .label = "Send", .checked = false });
            } else {
                try widgets.button(ui, "send", .{ .label = if (state.sent == 0) "Send" else "Send again", .on_click = on.bind(.send), .enabled = state.agree });
            }
            try widgets.button(ui, "clear", .{ .label = "Clear", .on_click = on.bind(.clear) });
        }
        try widgets.slider(ui, "volume", .{ .value = state.volume, .on_change = on.handler(.volume) });
        try widgets.progressBar(ui, "progress", .{ .value = state.volume });
        {
            // drawn, focusable chips between the native controls
            try ui.open(null, .{ .layout = .{ .child_gap = 4 } });
            defer ui.close();
            for (0..3) |i| {
                const index: u8 = @intCast(i);
                // integer keys hash by value, whatever their type
                try ui.open(index, .{
                    .layout = .{ .padding = .all(4) },
                    .background_color = if (ui.focused(index)) .rgb(0, 0, 255) else .gray(220),
                    .on_click = on.bind(.{ .choose = index }),
                    .focusable = true,
                });
                defer ui.close();
                try ui.print(.{}, "chip {d}", .{i});
            }
        }
        if (state.show_rows) for (state.rows) |row| {
            // each row's text is its key, so values must follow their keys
            try widgets.textField(ui, row, .{ .text = &.{row} });
        };
        try widgets.textField(ui, "notes", .{ .text = "", .placeholder = "Notes" });
        try menus.item(ui, "greet", .{ .menu = "Form", .title = "Greet", .key = "g", .on_select = on.bind(.greet) });
        if (state.asking) try dialogs.alert(ui, "question", .{
            .title = "Really?",
            .buttons = &.{ "Yes", "No" },
            .on_response = on.handler(.answered),
        });

        // the theme the platform provides
        try ui.print(.{}, "accent {d}", .{ui.use(native.Theme).accent.b});

        if (state.dialog) {
            // a drawn modal over everything, the native field included
            try ui.open("backdrop", .{
                .layout = .{ .sizing = .grow(.{}), .child_alignment = .center },
                .floating = .{ .mode = .root },
                .background_color = .rgba(0, 0, 0, 100),
            });
            defer ui.close();
            try ui.open("dialog", .{ .layout = .{ .padding = .all(20) }, .background_color = .white });
            defer ui.close();
            try ui.open("close", .{ .layout = .{ .padding = .all(4) }, .on_click = on.bind(.close_dialog), .focusable = true });
            defer ui.close();
            try ui.text("Close", .{});
        }
    }
};

const Harness = app.testing.Harness(.{}, Form);

fn harness() !Harness {
    return .init(.{}, .{ .viewport = .init(400, 500) });
}

test "native widgets are made once, measured by the backend and placed by fabrum" {
    var h = try harness();
    defer h.deinit();
    try h.frame();

    const r = h.root();
    const send = try h.expectWidget(r.native("send"));
    try testing.expect(send.spec == .button);
    try testing.expectEqualStrings("Send", send.spec.button.title);
    try testing.expect(!send.spec.button.enabled);

    // the frame is the element's box, sized by the backend's measure
    const box = h.findElement(r.element("send")).?.bbox;
    try testing.expectEqual(box, send.frame.?);
    try testing.expectEqual(@as(f32, 64), box.w); // "Send": 4 * 7 + 28, at least 64
    try testing.expectEqual(@as(f32, 22), box.h);
    // fields fill the row's width
    try testing.expectEqual(@as(f32, 380), (try h.expectWidget(r.native("name"))).frame.?.w);
    // menu items have no box
    try testing.expect((try h.expectWidget(r.native("greet"))).frame == null);

    const stats = h.runtime.reconciler().stats;
    try testing.expectEqual(@as(usize, 9), stats.creates);
    try testing.expectEqual(@as(usize, 8), stats.frames);

    // a frame that changes nothing calls nothing
    try h.frame();
    try testing.expectEqual(stats, h.runtime.reconciler().stats);
}

test "native clicks, toggles and slides send their messages" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    // disabled until agreed
    try h.clickNative(r.native("send"));
    try testing.expectEqual(@as(usize, 0), h.state().sent);

    try h.clickNative(r.native("agree"));
    try testing.expect(h.state().agree);
    try testing.expect((try h.expectWidget(r.native("send"))).spec.button.enabled);
    try h.clickNative(r.native("send"));
    try testing.expectEqual(@as(usize, 1), h.state().sent);
    try testing.expectEqualStrings("Send again", (try h.expectWidget(r.native("send"))).spec.button.title);

    try h.clickNative(r.native("loud"));
    try testing.expect(h.state().loud);
    try h.clickNative(r.native("loud"));
    try testing.expect(!h.state().loud);

    // the model rounds to tenths, and the slider is moved to match
    try h.slide(r.native("volume"), 0.73);
    try testing.expectEqual(@as(f64, 0.7), h.state().volume);
    const volume = try h.expectWidget(r.native("volume"));
    try testing.expectEqual(@as(f64, 0.7), volume.value.number);
    try testing.expectEqual(@as(usize, 1), volume.writes);
    try testing.expectEqual(@as(?f64, 0.7), (try h.expectWidget(r.native("progress"))).spec.progress.value);
}

test "typing updates the model without writing the text back" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const name = h.root().native("name");

    try h.typeText(name, "Ada é");
    try testing.expectEqualStrings("Ada é", h.state().name.items);
    // the model echoed what the field reported, so nothing was written
    try testing.expectEqual(@as(usize, 0), (try h.expectWidget(name)).writes);
    try testing.expectEqual(@as(usize, 0), h.runtime.reconciler().stats.writes);
}

test "a model that differs from the typed text is written once per change" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    h.state().shout = true;
    const name = h.root().native("name");

    try h.typeText(name, "ab");
    try testing.expectEqualStrings("AB", h.state().name.items);
    const field = try h.expectWidget(name);
    try testing.expectEqualStrings("AB", field.value.text);
    try testing.expectEqual(@as(usize, 2), field.writes);

    // a change from elsewhere is written too
    try h.clickNative(h.root().native("clear"));
    try testing.expectEqualStrings("", field.value.text);
    try testing.expectEqual(@as(usize, 3), field.writes);
}

test "nothing is written while the user composes, and the commit lands" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const name = h.root().native("name");
    try h.typeText(name, "ab");

    try h.compose(name, "に");
    // the model changes under the composition: held back, not written
    try h.clickNative(h.root().native("clear"));
    try testing.expectEqualStrings("", h.state().name.items);
    const field = try h.expectWidget(name);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("abに", field.text(&buffer));
    try testing.expectEqual(@as(usize, 0), field.writes);
    try testing.expect(h.runtime.reconciler().stats.held_writes > 0);

    // committing reports the text, which the model takes, so nothing is
    // left to write
    try h.commit(name, "日本");
    try testing.expectEqualStrings("ab日本", h.state().name.items);
    try testing.expectEqualStrings("ab日本", field.text(&buffer));
    try testing.expectEqual(@as(usize, 0), field.writes);

    // with a model that changes what was committed, the write waits for
    // the composition to end, then goes in
    h.state().shout = true;
    try h.compose(name, "x");
    try h.commit(name, "y");
    try testing.expectEqualStrings("AB日本Y", h.state().name.items);
    try testing.expectEqualStrings("AB日本Y", field.text(&buffer));
    try testing.expectEqual(@as(usize, 1), field.writes);
}

test "the reconciler updates changed props, replaces changed kinds and destroys what's gone" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const send = (try h.expectWidget(r.native("send"))).handle;

    // a prop change updates the same widget
    try h.clickNative(r.native("agree"));
    try testing.expectEqual(send, (try h.expectWidget(r.native("send"))).handle);
    try testing.expectEqual(@as(usize, 1), (try h.expectWidget(r.native("send"))).updates);

    // another kind under the same key replaces it
    h.state().send_as_checkbox = true;
    try h.frame();
    const replaced = try h.expectWidget(r.native("send"));
    try testing.expect(replaced.spec == .checkbox);
    try testing.expect(replaced.handle != send);

    // an alert lives while declared
    try h.post(@import("message.zig").bindHandler(Form, r.id, .ask), {});
    const question = try h.expectWidget(r.native("question"));
    try testing.expectEqualStrings("Really?", question.spec.alert.title);
    try h.respond(r.native("question"), 1);
    try testing.expectEqual(@as(?usize, 1), h.state().answer);
    try testing.expect(h.widget(r.native("question")) == null);
}

test "keyed native widgets keep their identity when reordered" {
    var h = try harness();
    defer h.deinit();
    h.props = .{};
    try h.frame();
    h.state().show_rows = true;
    try h.frame();

    const r = h.root();
    const a = try h.expectWidget(r.native('a'));
    const c = try h.expectWidget(r.native('c'));
    const a_handle = a.handle;
    const c_handle = c.handle;
    const a_top = a.frame.?.y;
    const c_top = c.frame.?.y;
    const creates = h.runtime.reconciler().stats.creates;

    h.state().rows = .{ 'c', 'b', 'a' };
    try h.frame();

    // the same widgets, swapped, each still showing its own text, so
    // nothing was written
    try testing.expectEqual(creates, h.runtime.reconciler().stats.creates);
    try testing.expectEqual(@as(usize, 0), h.runtime.reconciler().stats.destroys);
    const a2 = try h.expectWidget(r.native('a'));
    const c2 = try h.expectWidget(r.native('c'));
    try testing.expectEqual(a_handle, a2.handle);
    try testing.expectEqual(c_handle, c2.handle);
    try testing.expectEqual(c_top, a2.frame.?.y);
    try testing.expectEqual(a_top, c2.frame.?.y);
    try testing.expectEqualStrings("a", a2.value.text);
    try testing.expectEqualStrings("c", c2.value.text);
    try testing.expectEqual(@as(usize, 0), a2.writes + c2.writes);
    try testing.expectEqual(@as(usize, 0), h.runtime.reconciler().stats.writes);
}

test "Tab moves through native and drawn elements in paint order" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const r = h.root();

    // only text fields take focus without full keyboard access, as on macOS
    try h.tab();
    try h.expectFocused(r.element("name"));
    try h.tab();
    try h.expectFocused(r.element(0));
    try h.expectText("chip 0");
    try h.tab();
    try h.tab();
    try h.expectFocused(r.element(2));
    try h.tab();
    try h.expectFocused(r.element("notes"));
    try h.tab();
    try h.expectFocused(r.element("name"));
    try h.shiftTab();
    try h.expectFocused(r.element("notes"));
    try h.shiftTab();

    // Space clicks the focused drawn element
    try h.pressSpace();
    try testing.expectEqual(@as(?u8, 2), h.state().chosen);

    // clicking a field focuses it, and Tab goes on from there
    try h.clickNative(r.native("notes"));
    try h.expectFocused(r.element("notes"));
    try h.tab();
    try h.expectFocused(r.element("name"));
}

test "with full keyboard access, every control is in the Tab order" {
    var h: Harness = try .init(.{}, .{ .viewport = .init(400, 500), .full_keyboard_access = true });
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.tab();
    try h.expectFocused(r.element("name"));
    try h.tab();
    try h.expectFocused(r.element("agree"));
    try h.tab();
    try h.expectFocused(r.element("loud"));
    // the disabled button is skipped
    try h.tab();
    try h.expectFocused(r.element("clear"));
    try h.tab();
    try h.expectFocused(r.element("volume"));
    try h.tab();
    try h.expectFocused(r.element(0));
    // two fields, two toggles, a button, a slider and three chips
    try testing.expectEqual(@as(usize, 9), h.runtime.reconciler().chain.items.len);
}

test "focus leaves an element that goes away" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    h.state().dialog = true;
    try h.frame();
    try h.shiftTab();
    try h.expectFocused(h.root().element("close"));
    try h.pressSpace();
    try testing.expect(!h.state().dialog);
    try testing.expectEqual(null, h.runtime.focused());
}

test "drawn content over a native view goes in a canvas layer above it" {
    var h = try harness();
    defer h.deinit();
    try h.frame();

    // one canvas under every native view: nothing drawn overlaps them
    var scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 1), scene.layers.len);
    try testing.expect(scene.slots[0] == .canvas);
    try testing.expectEqual(@as(usize, 1 + 8), scene.slots.len);
    for (scene.slots[1..]) |slot| try testing.expect(slot == .native);
    // and the chips and texts after the native views are in it
    try testing.expect(countTexts(scene.layers[0]) == 5);

    h.state().dialog = true;
    try h.frame();
    scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 2), scene.layers.len);
    // the second canvas is last, above every native view
    try testing.expectEqual(native.Scene.Slot{ .canvas = 1 }, scene.slots[scene.slots.len - 1]);
    const top = scene.layers[1];
    try testing.expectEqual(@as(usize, 1), countTexts(top));
    try testing.expectEqual(@as(usize, 5), countTexts(scene.layers[0]));
    // the backdrop takes the pointer everywhere, so the field beneath gets
    // no clicks
    const field = (try h.expectWidget(h.root().native("name"))).frame.?;
    try testing.expect(top.hits(.init(field.x + 2, field.y + 2)));

    // clicking the drawn dialog works through the runtime as ever
    try h.click("Close");
    try testing.expect(!h.state().dialog);
    try testing.expectEqual(@as(usize, 1), h.runtime.scene().layers.len);
}

test "clips are reopened in each layer that draws inside them" {
    const Clipped = struct {
        pub const Props = struct {};
        pub fn view(ui: *app.Ui, _: Props) !void {
            try ui.open(null, .{ .layout = .{ .sizing = .fixed(100) }, .clip = .{ .horizontal = true, .vertical = true } });
            defer ui.close();
            try widgets.button(ui, "under", .{ .label = "Under", .sizing = .fixed(50) });
            // drawn over the button, inside the clip
            try ui.open(null, .{
                .layout = .{ .sizing = .fixed(80) },
                .floating = .{ .mode = .parent },
                .background_color = .gray(10),
            });
            ui.close();
            try ui.text("inside", .{});
        }
    };
    var h: app.testing.Harness(.{}, Clipped) = try .init(.{}, .{ .viewport = .init(200, 200) });
    defer h.deinit();
    try h.frame();
    // drawn content clipped away from a native view stays below it

    const scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 2), scene.layers.len);
    for (scene.layers) |layer| {
        var depth: i32 = 0;
        for (layer.commands) |command| switch (command.data) {
            .scissor_start => depth += 1,
            .scissor_end => depth -= 1,
            else => {},
        };
        try testing.expectEqual(@as(i32, 0), depth);
    }
    // the overlay is clipped in the top layer too
    try testing.expect(scene.layers[1].commands[0].data == .scissor_start);
}

test "menu items send their messages" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const greet = try h.expectWidget(h.root().native("greet"));
    try testing.expectEqualStrings("Form", greet.spec.menu_item.menu);
    try h.selectMenu(greet.id);
    try h.selectMenu(greet.id);
    try testing.expectEqual(@as(usize, 2), h.state().greeted);
}

test "the platform's theme is provided to views" {
    var h = try harness();
    defer h.deinit();
    h.platform.look.accent = .rgb(1, 2, 3);
    try h.frame();
    try h.expectText("accent 3");
}

test "resizing moves only the native views whose boxes change" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    const frames = h.runtime.reconciler().stats.frames;
    h.viewport = .init(600, 500);
    try h.frame();
    // the three fields, the slider and the progress bar grow with the window
    try testing.expectEqual(frames + 4, h.runtime.reconciler().stats.frames);
    try testing.expectEqual(@as(f32, 580), (try h.expectWidget(h.root().native("name"))).frame.?.w);
}

test "native elements need a backend" {
    const Lone = struct {
        pub const Props = struct {};
        pub fn view(ui: *app.Ui, _: Props) !void {
            try widgets.button(ui, "b", .{ .label = "B" });
        }
    };
    var rt: app.Runtime(.{}) = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    try testing.expectError(error.NoNativeBackend, rt.frame(Lone, .{}, .init(100, 100)));
}

fn countTexts(layer: native.Scene.Layer) usize {
    var count: usize = 0;
    for (layer.commands) |command| {
        if (command.data == .content and fabrum.layout.text.HeuristicContent.asTextContent(command.data.content) != null) count += 1;
    }
    return count;
}
