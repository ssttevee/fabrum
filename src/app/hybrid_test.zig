//! Native widgets in fabrum's layout, driven through the fake native tree:
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
                .modal = true,
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
    // native widgets in the fake tree, whatever this build's platform
    return .init(.{}, .{ .viewport = .init(400, 500), .widgets = .native });
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
    var h: Harness = try .init(.{}, .{ .viewport = .init(400, 500), .full_keyboard_access = true, .widgets = .native });
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

test "a modal scope takes focus from the native field it covers, and keeps Tab inside" {
    var h = try harness();
    defer h.deinit();
    try h.frame();
    try h.clickNative(h.root().native("name"));
    try h.expectFocused(h.root().element("name"));

    h.state().dialog = true;
    try h.frame();
    // the dialog's only focusable element, with the platform's keys on the canvas
    try h.expectFocused(h.root().element("close"));
    try testing.expectEqual(@as(usize, 1), h.runtime.reconciler().chain.items.len);
    try h.tab();
    try h.expectFocused(h.root().element("close"));
    try h.shiftTab();
    try h.expectFocused(h.root().element("close"));

    // focus leaves an element that goes away
    try h.pressSpace();
    try testing.expect(!h.state().dialog);
    try testing.expectEqual(null, h.runtime.focused());
    try h.tab();
    try h.expectFocused(h.root().element("name"));
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
    var h: app.testing.Harness(.{}, Clipped) = try .init(.{}, .{ .viewport = .init(200, 200), .widgets = .native });
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
    h.tree.look.accent = .rgb(1, 2, 3);
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

test "native elements need a backend, and the common widgets are drawn without one" {
    const Lone = struct {
        pub const Props = struct { raw: bool };
        pub fn view(ui: *app.Ui, props: Props) !void {
            if (props.raw) {
                try ui.native("b", .{ .spec = .{ .button = .{ .title = "B" } } });
            } else {
                try widgets.button(ui, "b", .{ .label = "B" });
            }
        }
    };
    var rt: app.Runtime(.{}) = try .init(testing.allocator, .{ .io = testing.io });
    defer rt.deinit();
    try testing.expectError(error.NoNativeBackend, rt.frame(Lone, .{ .raw = true }, .init(100, 100), .zero));
    _ = try rt.frame(Lone, .{ .raw = false }, .init(100, 100), .zero);
    try testing.expect(app.testing.findText(app.Runtime(.{}).Text, rt.context(), "B") != null);
}

fn countTexts(layer: native.Scene.Layer) usize {
    var count: usize = 0;
    for (layer.commands) |command| {
        if (command.data == .content and fabrum.layout.text.HeuristicContent.asTextContent(command.data.content) != null) count += 1;
    }
    return count;
}

/// A field whose model stores what was typed in capitals, counting the
/// messages it gets.
const Shouting = struct {
    pub const State = struct {
        text: std.ArrayList(u8) = .empty,
        changes: usize = 0,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.text.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { typed: []const u8 };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Shouting)) !void {
        state.changes += 1;
        state.text.clearRetainingCapacity();
        try state.text.appendSlice(ctx.gpa, msg.typed);
        for (state.text.items) |*c| c.* = std.ascii.toUpper(c.*);
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try widgets.textField(ui, "field", .{ .text = state.text.items, .on_change = ui.messages(Shouting).handler(.typed) });
    }
};

test "events a toolkit reports while a frame runs wait for it, then arrive in order" {
    var h: app.testing.Harness(.{}, Shouting) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    // as GTK does: writing a field's text reports it back
    h.tree.report_writes = true;
    try h.frame();
    const field = h.root().native("field");

    // "a" makes the model "A", which the frame writes; the field reports
    // "A" from inside that frame
    try h.typeText(field, "a");
    try testing.expectEqualStrings("A", (try h.expectWidget(field)).value.text);
    try testing.expectEqual(@as(usize, 1), h.state().changes);
    try testing.expect(h.runtime.needsFrame());

    // the next frame delivers it first: the model sees what the field shows
    try h.frame();
    try testing.expectEqual(@as(usize, 2), h.state().changes);
    try testing.expectEqualStrings("A", h.state().text.items);
    // and since the model already shows it, nothing more is written or reported
    try testing.expect(!h.runtime.needsFrame());
    try testing.expectEqual(@as(usize, 1), (try h.expectWidget(field)).writes);

    // input waiting behind the reported text comes after it
    try h.setText(field, "Ab");
    try testing.expect(h.runtime.needsFrame());
    try h.typeText(field, "c");
    try testing.expectEqualStrings("ABC", h.state().text.items);
    try h.frame();
    try testing.expectEqualStrings("ABC", (try h.expectWidget(field)).value.text);
}

/// A modal sheet whose first stop is a native field.
const Sheet = struct {
    pub const State = struct { open: bool = false };
    pub const Msg = union(enum) {};
    pub const Props = struct {};

    pub fn update(_: *State, msg: Msg, _: *app.Update(Sheet)) void {
        switch (msg) {}
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try widgets.textField(ui, "outside", .{ .text = "" });
        if (!state.open) return;
        try ui.open("sheet", .{ .layout = .{ .padding = .all(8) }, .modal = true });
        defer ui.close();
        try widgets.textField(ui, "inside", .{ .text = "" });
    }
};

test "a focus reported from inside a frame lands after it" {
    var h: app.testing.Harness(.{}, Sheet) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    // as AppKit does: making a view first responder reports its focus
    h.tree.report_focus = true;
    try h.frame();
    const r = h.root();

    // the modal sheet takes focus for its field during the frame, and the
    // field reports it from inside that frame: it waits
    h.state().open = true;
    try h.frame();
    try h.expectFocused(r.element("inside"));
    try testing.expectEqual(@as(usize, 1), h.runtime.core.deferred.items.len);
    try testing.expect(h.runtime.needsFrame());

    // and is delivered by the next frame, agreeing with where focus is
    try h.frame();
    try h.expectFocused(r.element("inside"));
    try testing.expect(!h.runtime.needsFrame());

    // Tab outside a frame is reported and handled at once
    try h.tab();
    try h.expectFocused(r.element("inside"));
    try testing.expectEqual(@as(usize, 0), h.runtime.core.deferred.items.len);
}

/// A header, a scroll view with more rows than fit, each a drawn label
/// and a native button, and a button after it.
const Scroller = struct {
    pub const State = struct {
        picked: ?u8 = null,
        clicked: ?u8 = null,
        list: bool = true,
    };
    pub const Msg = union(enum) { pick: u8, click: u8 };
    pub const Props = struct {};

    /// The keys of a row and of its button.
    const Row = struct { row: u8 };
    const Pick = struct { pick: u8 };

    pub fn update(state: *State, msg: Msg, _: *app.Update(Scroller)) void {
        switch (msg) {
            .pick => |i| state.picked = i,
            .click => |i| state.clicked = i,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Scroller);
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .axis = .y } });
        defer ui.close();
        try ui.text("Header", .{});
        if (state.list) {
            try widgets.scrollView(ui, "list", .{ .content = .{ .axis = .y, .padding = .all(8), .child_gap = 4 } });
            defer ui.close();
            for (0..20) |i| {
                const index: u8 = @intCast(i);
                try ui.open(Row{ .row = index }, .{
                    .layout = .{ .child_gap = 8, .child_alignment = .center_left },
                    .on_click = on.bind(.{ .click = index }),
                });
                defer ui.close();
                try ui.print(.{}, "Row {d}", .{i});
                try widgets.button(ui, Pick{ .pick = index }, .{ .label = "Pick", .on_click = on.bind(.{ .pick = index }) });
            }
        }
        try widgets.button(ui, "after", .{ .label = "After" });
    }
};

test "a native scroll view lays its content out in its own coordinates, and scrolls it" {
    var h: app.testing.Harness(.{}, Scroller) = try .init(.{}, .{ .widgets = .native, .viewport = .init(400, 300) });
    defer h.deinit();
    try h.frame();
    const r = h.root();
    const list_id = r.native("list");
    const list = try h.expectWidget(list_id);
    const box = h.findElement(r.element("list")).?.bbox;

    // the view fills what the header and the last button leave
    try testing.expect(list.spec == .scroll_view);
    try testing.expectEqual(box, list.frame.?);
    try testing.expect(box.h < 300 and box.h > 200);
    // its content is all twenty rows, taller than the view
    const content = list.content_size.?;
    try testing.expectApproxEqAbs(h.findElement(r.element("list")).?.content_size.y, content.y, 0.01);
    try testing.expect(content.y > 20 * 22);
    // and as wide as the widest row, label and button
    try testing.expect(content.x < box.w);

    // the buttons inside are its children, framed in its content's coordinates
    const first = try h.expectWidget(r.native(Scroller.Pick{ .pick = 0 }));
    const last = try h.expectWidget(r.native(Scroller.Pick{ .pick = 19 }));
    try testing.expectEqual(list.handle, first.parent.?);
    try testing.expectEqual(@as(?native.Handle, null), (try h.expectWidget(r.native("after"))).parent);
    const first_box = h.findElement(r.element(Scroller.Pick{ .pick = 0 })).?.bbox;
    try testing.expectApproxEqAbs(first_box.x - box.x, first.frame.?.x, 0.01);
    try testing.expectApproxEqAbs(first_box.y - box.y, first.frame.?.y, 0.01);
    try testing.expectEqual(@as(f32, 8), first.frame.?.y);
    try testing.expect(last.frame.?.y + last.frame.?.h > box.h);

    // the scene: the view stacks in the host, and its content has its own
    // canvas, in the content's coordinates
    const scene = h.runtime.scene();
    try testing.expectEqual(@as(usize, 1), scene.containers.len);
    try testing.expectEqual(list.handle, scene.containers[0].handle);
    const inner = scene.containers[0].slots;
    try testing.expect(inner[0] == .canvas);
    const inner_layer = scene.layers[inner[0].canvas];
    try testing.expect(inner_layer.base);
    try testing.expectEqual(fabrum.Vec2.init(box.x, box.y), inner_layer.offset);
    // every row's label is drawn in it, and none in the host's
    var labels: usize = 0;
    for (inner_layer.commands) |command| {
        if (command.data == .content) labels += 1;
    }
    try testing.expectEqual(@as(usize, 20), labels);
    var host_has_list = false;
    for (scene.slots) |slot| {
        if (slot == .native and slot.native == list.handle) host_has_list = true;
    }
    try testing.expect(host_has_list);
    // twenty buttons over the content's canvas
    try testing.expectEqual(@as(usize, 21), inner.len);

    // scrolling: the platform reports where it is, and the content is laid
    // out against it, so clicks land on what is shown there
    const frames = h.runtime.reconciler().stats.frames;
    try h.scrollNative(list_id, .init(0, 120));
    try testing.expectEqual(fabrum.Vec2.init(0, 120), list.scroll);
    try testing.expectEqual(first_box.y - 120, h.findElement(r.element(Scroller.Pick{ .pick = 0 })).?.bbox.y);
    // nothing native moves: the content scrolled, not the views in it
    try testing.expectEqual(frames, h.runtime.reconciler().stats.frames);
    try testing.expectEqual(@as(f32, 8), first.frame.?.y);
    try testing.expectEqual(fabrum.Vec2.init(box.x, box.y - 120), h.runtime.scene().layers[h.runtime.scene().containers[0].slots[0].canvas].offset);
    // a drawn row now in view is clicked where it is shown
    try h.click("Row 9");
    try testing.expectEqual(@as(?u8, 9), h.state().clicked);
    try h.clickNative(r.native(Scroller.Pick{ .pick = 12 }));
    try testing.expectEqual(@as(?u8, 12), h.state().picked);

    // as far as it goes, and no further
    try h.scrollNative(list_id, .init(0, 1e6));
    try testing.expectEqual(content.y - box.h, list.scroll.y);

    // taking the view away takes what is in it first
    h.state().list = false;
    try h.frame();
    try testing.expect(h.widget(list_id) == null);
    try testing.expect(h.widget(r.native(Scroller.Pick{ .pick = 0 })) == null);
    try testing.expectEqual(@as(usize, 0), h.runtime.scene().containers.len);
}

/// An editor that opens files, copies and pastes, and asks before closing
/// with unsaved changes.
const Editor = struct {
    pub const State = struct {
        path: std.ArrayList(u8) = .empty,
        cancelled: bool = false,
        pasted: std.ArrayList(u8) = .empty,
        nothing_to_paste: bool = false,
        unsaved: bool = false,
        confirming: ?app.platform.CloseReason = null,

        pub fn deinit(self: *State, gpa: Allocator) void {
            self.path.deinit(gpa);
            self.pasted.deinit(gpa);
        }
    };
    pub const Msg = union(enum) {
        open,
        chosen: ?[]const u8,
        copy,
        paste,
        pasted: ?[]const u8,
        close_requested: app.platform.CloseReason,
        answered: usize,
    };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Editor)) !void {
        switch (msg) {
            .open => try ctx.openFile(.{ .message = "Choose an image", .extensions = &.{ "img", "iso" } }, ctx.handler(.chosen)),
            .chosen => |path| {
                state.cancelled = path == null;
                state.path.clearRetainingCapacity();
                // the message borrows the path: copy it
                try state.path.appendSlice(ctx.gpa, path orelse "");
            },
            .copy => try ctx.writeClipboard("copied text"),
            .paste => try ctx.readClipboard(ctx.handler(.pasted)),
            .pasted => |text| {
                state.nothing_to_paste = text == null;
                state.pasted.clearRetainingCapacity();
                try state.pasted.appendSlice(ctx.gpa, text orelse "");
            },
            .close_requested => |reason| state.confirming = reason,
            .answered => |button| {
                state.confirming = null;
                // "Quit" is the first button
                if (button == 0) try ctx.quit();
            },
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Editor);
        try ui.open(null, .{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        try widgets.button(ui, "open", .{ .label = "Open", .on_click = on.bind(.open) });
        try widgets.button(ui, "copy", .{ .label = "Copy", .on_click = on.bind(.copy) });
        try widgets.button(ui, "paste", .{ .label = "Paste", .on_click = on.bind(.paste) });
        if (state.unsaved) ui.guardClose(on.handler(.close_requested));
        if (state.confirming != null) try dialogs.alert(ui, "confirm", .{
            .title = "Quit without saving?",
            .buttons = &.{ "Quit", "Cancel" },
            .on_response = on.handler(.answered),
        });
    }
};

const EditorHarness = app.testing.Harness(.{}, Editor);

test "the file chooser shows the app's filters, and its answer comes back as a message" {
    var h: EditorHarness = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickNative(r.native("open"));
    try testing.expectEqual(@as(usize, 1), h.tree.file_requests.items.len);
    const request = h.tree.file_requests.items[0];
    try testing.expectEqualStrings("Choose an image", request.message);
    try testing.expectEqual(@as(usize, 2), request.extensions.len);
    try testing.expectEqualStrings("iso", request.extensions[1]);

    try h.chooseFile("/Users/ada/raspios.img");
    try testing.expectEqualStrings("/Users/ada/raspios.img", h.state().path.items);
    try testing.expect(!h.state().cancelled);

    // cancelling answers null
    try h.clickNative(r.native("open"));
    try h.chooseFile(null);
    try testing.expect(h.state().cancelled);
    try testing.expectEqual(@as(usize, 0), h.tree.file_requests.items.len);
}

test "the clipboard is written, and read back as a message" {
    var h: EditorHarness = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const r = h.root();

    try h.clickNative(r.native("copy"));
    try testing.expectEqualStrings("copied text", h.tree.clipboard.?);

    try h.tree.setClipboard("from another app");
    try h.clickNative(r.native("paste"));
    try testing.expectEqualStrings("from another app", h.state().pasted.items);

    try h.tree.setClipboard(null);
    try h.clickNative(r.native("paste"));
    try testing.expect(h.state().nothing_to_paste);
}

test "closing is held while a view guards it, and the app quits once confirmed" {
    var h: EditorHarness = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const r = h.root();

    // nothing to lose: closing goes ahead
    try testing.expect(try h.requestClose(.window));

    // with unsaved changes the view guards closing: the host is told no,
    // and the app asks the user
    h.state().unsaved = true;
    try h.frame();
    try testing.expect(!try h.requestClose(.quit));
    try testing.expectEqual(app.platform.CloseReason.quit, h.state().confirming.?);
    _ = try h.expectWidget(r.native("confirm"));
    try testing.expectEqual(@as(usize, 0), h.tree.quits);

    // Cancel keeps the app; Quit quits without asking again
    try h.respond(r.native("confirm"), 1);
    try testing.expectEqual(@as(usize, 0), h.tree.quits);
    try testing.expect(!try h.requestClose(.window));
    try h.respond(r.native("confirm"), 0);
    try testing.expectEqual(@as(usize, 1), h.tree.quits);
}

test "without a shell, the app's requests say so" {
    var h: EditorHarness = try .init(.{}, .{ .widgets = .drawn, .shell = false });
    defer h.deinit();
    try h.frame();
    try testing.expectError(error.Unsupported, h.click("Open"));
    try testing.expectError(error.Unsupported, h.click("Copy"));
    // closing still asks the app, which needs no shell
    try testing.expect(try h.requestClose(.quit));
}
