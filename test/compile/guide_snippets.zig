//! Executable examples quoted in docs/guides. Markers delimit exact Markdown blocks.
// docs/guides/README.md, "About the code in these guides"
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const widgets = app.widgets;
const Rect = fabrum.Rect;
const Vec2 = fabrum.Vec2;
// end-guide-snippet

// docs/guides/first-app.md, "Write the component"
const Counter = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { add };
    pub const Props = struct { step: i32 = 1 };

    pub fn update(state: *State, _: Msg, ctx: *app.Update(Counter)) void {
        state.count += ctx.props.step;
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open("counter", .{ .layout = .{ .axis = .y, .child_gap = 8, .padding = .all(16) } });
        defer ui.close();
        try ui.print(.{}, "Count: {d}", .{state.count});
        try widgets.button(ui, "add", .{ .label = "Add", .on_click = ui.messages(Counter).bind(.add) });
    }
};
// end-guide-snippet

// docs/guides/first-app.md, "Open a window"
const Window = struct {
    const Gui = switch (app.platform.kind) {
        .appkit => app.platform.appkit.App(Counter),
        .gtk => app.platform.gtk.App(Counter),
        else => @compileError("This program needs AppKit or GTK; use a custom host for none"),
    };

    pub fn main(init: std.process.Init) !void {
        const gui = try init.gpa.create(Gui);
        try gui.init(init.gpa, init.io, .{ .step = 1 }, .{ .title = "Counter", .width = 320, .height = 200 }, .{});
        gui.run();
    }
};
// end-guide-snippet

test "guide window entry point compiles without opening a window" {
    if (comptime app.platform.kind == .appkit or app.platform.kind == .gtk) _ = &Window.main;
}

// docs/guides/first-app.md, "Test the first interaction"
test "guide counter increments without a window" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{ .step = 2 }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Add");
    try h.expectText("Count: 2");
    try std.testing.expectEqual(2, h.state().count);
}
// end-guide-snippet

// docs/guides/components.md, "Pass handlers to children"
const Badge = struct {
    pub const Props = struct { label: []const u8, on_pick: app.Handler(usize), index: usize };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.open("badge", .{ .on_click = props.on_pick.with(props.index), .layout = .{ .padding = .all(4) } });
        defer ui.close();
        try ui.text(props.label, .{});
    }
};

const Picks = struct {
    pub const State = struct { selected: usize = 0 };
    pub const Msg = union(enum) { picked: usize };
    pub const Props = struct { reversed: bool = false };
    pub fn update(state: *State, msg: Msg, _: *app.Update(Picks)) void {
        switch (msg) {
            .picked => |index| state.selected = index,
        }
    }
    fn children(ui: *app.Ui, reversed: bool, on_pick: app.Handler(usize)) !void {
        const ids = if (reversed) [2]usize{ 20, 10 } else [2]usize{ 10, 20 };
        for (ids) |id| try ui.child(Badge, id, .{ .label = try ui.fmt("Item {d}", .{id}), .index = id, .on_pick = on_pick });
    }
    pub fn view(ui: *app.Ui, _: *const State, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();
        try children(ui, props.reversed, ui.messages(Picks).handler(.picked));
    }
};
// end-guide-snippet

test "guide child handlers keep stable IDs after reordering" {
    var h: app.testing.Harness(.{}, Picks) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const id = h.root().child(Badge, @as(usize, 20)).element("badge");
    try h.clickElement(id);
    try std.testing.expectEqual(20, h.state().selected);
    h.props.reversed = true;
    try h.frame();
    try h.clickElement(id);
    try std.testing.expectEqual(20, h.state().selected);
}

// docs/guides/components.md, "Provide values to a subtree"
const Preferences = struct { compact: bool = false };
const Shared = struct { saves: usize = 0 };
const ContextChild = struct {
    pub const State = struct { compact_seen: bool = false };
    pub const Msg = union(enum) { save };
    pub const Props = struct {};
    pub fn update(state: *State, _: Msg, ctx: *app.Update(ContextChild)) void {
        state.compact_seen = ctx.use(Preferences).compact;
        ctx.use(*Shared).*.saves += 1;
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try widgets.button(ui, "save", .{ .label = if (ui.use(Preferences).compact) "Save compact" else "Save", .on_click = ui.messages(ContextChild).bind(.save) });
    }
};
const ContextRoot = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        const preferences = try ui.arena().create(Preferences);
        preferences.* = .{ .compact = true };
        try ui.provide(Preferences, preferences);
        try ui.one(ContextChild, .{});
    }
};

test "guide root resource pointer and subtree value reach updates" {
    var shared: Shared = .{};
    var shared_ptr: *Shared = &shared;
    var h: app.testing.Harness(.{}, ContextRoot) = try .init(.{}, .{
        .provide = &.{.of(&shared_ptr)},
        .widgets = .drawn,
    });
    defer h.deinit();
    try h.frame();
    try h.click("Save compact");
    try std.testing.expectEqual(1, shared.saves);
}
// end-guide-snippet

// docs/guides/layout.md, "Build a sidebar and a wrapping body"
const Page = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open("page", .{ .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 8 } });
        defer ui.close();
        try ui.open("header", .{ .layout = .{ .sizing = .{ .width = .grow(.{}), .height = .fixed(36) }, .child_alignment = .center_left } });
        try ui.text("Gallery", .{});
        ui.spacer();
        try ui.text("Settings", .{});
        ui.close();
        try ui.open("body", .{ .layout = .{ .sizing = .grow(.{}), .child_gap = 10 } });
        defer ui.close();
        try ui.open("sidebar", .{ .layout = .{ .sizing = .{ .width = .fixed(80), .height = .grow(.{}) } } });
        try ui.text("Albums", .{});
        ui.close();
        try ui.open("article", .{ .layout = .{ .sizing = .{ .width = .grow(.{ .min = 40, .max = 400 }), .height = .fit(.{}) }, .padding = .xy(8, 4) } });
        defer ui.close();
        try ui.text("A description wraps into the width left beside the sidebar.", .{ .wrap_mode = .words });
    }
};
// end-guide-snippet

test "guide sidebar leaves finite width for wrapped text" {
    var h: app.testing.Harness(.{}, Page) = try .init(.{}, .{ .viewport = .init(320, 200) });
    defer h.deinit();
    try h.frame();
    try std.testing.expectEqual(80, h.findElement(h.root().element("sidebar")).?.bbox.w);
    try std.testing.expect(h.findElement(h.root().element("article")).?.bbox.w <= 206);
}

// docs/guides/layout.md, "Scroll a long list"
const List = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { end };
    pub const Props = struct {};
    pub fn update(_: *State, _: Msg, ctx: *app.Update(List)) void {
        ctx.scrollTo("rows", .end, .{});
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.open("rows", .{ .layout = .{ .sizing = .fixedXY(200, 80), .axis = .y }, .scroll = .{} });
        defer ui.close();
        for (0..10) |i| {
            try ui.open(i, .{ .layout = .{ .sizing = .fixedXY(180, 24) } });
            try ui.print(.{}, "Row {d}", .{i});
            ui.close();
        }
    }
};
// end-guide-snippet

test "guide scroll list moves by wheel and update" {
    var h: app.testing.Harness(.{}, List) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const id = h.root().element("rows");
    try std.testing.expect(try h.scrollElement(id, .init(0, 20)));
    try std.testing.expect(h.scrollInfo(id).?.offset.y > 0);
    try h.post(h.root().handler(List, .end), {});
    try std.testing.expectEqual(h.scrollInfo(id).?.max().y, h.scrollInfo(id).?.offset.y);
}

// docs/guides/layout.md, "Attach an overlay and preserve an aspect ratio"
const Overlay = struct {
    pub const Props = struct {};
    pub fn view(ui: *app.Ui, _: Props) !void {
        try ui.open("preview", .{
            .layout = .{ .sizing = .fixedXY(200, 140) },
            .aspect_ratio = .{ .aspect_ratio = 2 },
            .clip = .{ .horizontal = true, .vertical = true },
            .background_color = .gray(230),
        });
        defer ui.close();
        try ui.open("badge", .{
            .layout = .{ .sizing = .fixedXY(40, 20) },
            .floating = .{ .mode = .unit_id, .parent = .{ .id = ui.id("preview").id }, .parent_point = .right_top, .unit_point = .right_top, .offset = .init(-4, 4) },
            .background_color = .black,
        });
        defer ui.close();
        try ui.text("New", .{ .color = .white });
    }
};
// end-guide-snippet

test "guide overlay anchors inside a ratio-constrained preview" {
    var h: app.testing.Harness(.{}, Overlay) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const preview = h.findElement(h.root().element("preview")).?.bbox;
    const badge = h.findElement(h.root().element("badge")).?.bbox;
    try std.testing.expectEqual(2, preview.w / preview.h);
    try std.testing.expectEqual(preview.x + preview.w - 44, badge.x);
}

// docs/guides/widgets-and-input.md, "Build a controlled settings form"
const Settings = struct {
    pub const State = struct {
        text: std.ArrayList(u8) = .empty,
        enabled: bool = true,
        amount: f64 = 0.5,
        selected: usize = 0,
        saves: usize = 0,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.text.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { text: []const u8, enabled: bool, amount: f64, selected: usize, save };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Settings)) !void {
        switch (msg) {
            .text => |text| {
                const copy = try ctx.gpa.dupe(u8, text);
                state.text.deinit(ctx.gpa);
                state.text = .fromOwnedSlice(copy);
            },
            .enabled => |value| state.enabled = value,
            .amount => |value| state.amount = value,
            .selected => |value| state.selected = value,
            .save => state.saves += 1,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Settings);
        try widgets.scrollView(ui, "settings", .{ .content = .{ .axis = .y, .padding = .all(8), .child_gap = 6 } });
        defer ui.close();
        try widgets.label(ui, "title", .{ .text = "Settings", .wrap = true, .selectable = true });
        try widgets.checkbox(ui, "enabled", .{ .label = "Enable edits", .checked = state.enabled, .on_change = on.handler(.enabled) });
        try widgets.toggle(ui, "toggle", .{ .on = state.enabled, .on_change = on.handler(.enabled) });
        try widgets.slider(ui, "amount", .{ .value = state.amount, .on_change = on.handler(.amount), .enabled = state.enabled });
        try widgets.stepper(ui, "stepper", .{ .value = state.amount, .min = 0, .max = 1, .step = 0.1, .on_change = on.handler(.amount), .enabled = state.enabled });
        try widgets.textField(ui, "name", .{ .text = state.text.items, .placeholder = "Name", .on_change = on.handler(.text), .on_submit = on.bind(.save), .enabled = state.enabled });
        try widgets.searchField(ui, "search", .{ .text = state.text.items, .placeholder = "Search", .on_change = on.handler(.text), .enabled = state.enabled });
        try widgets.secureField(ui, "secret", .{ .text = state.text.items, .placeholder = "Password", .on_change = on.handler(.text), .enabled = state.enabled });
        try widgets.textArea(ui, "notes", .{ .text = state.text.items, .on_change = on.handler(.text), .enabled = state.enabled, .sizing = .fixedXY(240, 80) });
        try widgets.dropdown(ui, "choice", .{ .items = &.{ "Light", "Dark" }, .selected = state.selected, .on_select = on.handler(.selected), .enabled = state.enabled });
        try widgets.radioGroup(ui, "radio", .{ .items = &.{ "Light", "Dark" }, .selected = state.selected, .on_select = on.handler(.selected), .horizontal = true, .enabled = state.enabled });
        try widgets.progressBar(ui, "progress", .{ .value = state.amount });
        try widgets.progressBar(ui, "pending", .{ .value = null });
        try widgets.spinner(ui, "spinner", .{ .size = .small });
        try widgets.button(ui, "save", .{ .label = "Save settings", .on_click = on.bind(.save), .enabled = state.enabled, .default = true });
        switch (comptime app.platform.kind) {
            .appkit => if (ui.hasNativeWidgets())
                try app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = state.amount, .max = 1 })
            else
                try widgets.progressBar(ui, "rating", .{ .value = state.amount }),
            else => try widgets.progressBar(ui, "rating", .{ .value = state.amount }),
        }
    }
};
// end-guide-snippet

test "guide every common widget declares in native and drawn modes" {
    inline for (.{ app.testing.Widgets.native, app.testing.Widgets.drawn }) |mode| {
        var h: app.testing.Harness(.{}, Settings) = try .init(.{}, .{ .widgets = mode, .viewport = .init(600, 1000) });
        defer h.deinit();
        try h.frame();
        if (mode == .native) {
            try h.typeText(h.root().native("name"), "Ada");
            try h.slide(h.root().native("amount"), 0.75);
            try h.selectNative(h.root().native("choice"), 1);
            try h.stepNative(h.root().native("stepper"), 1);
            try h.submit(h.root().native("name"));
        } else {
            try h.clickElement(h.root().child(app.drawn.TextBox, "name").element("field"));
            try h.type_("Ada");
            try h.click("Save settings");
        }
        try std.testing.expectEqualStrings("Ada", h.state().text.items);
        try std.testing.expectEqual(1, h.state().saves);
    }
}

// docs/guides/widgets-and-input.md, "Capture a drag and handle keyboard navigation"
const DragPad = struct {
    pub const State = struct { x: f32 = 0, keys: usize = 0, saves: usize = 0 };
    pub const Msg = union(enum) { pointer: app.Pointer, key: app.KeyEvent, save };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(DragPad)) void {
        switch (msg) {
            .pointer => |p| switch (p.phase) {
                .press, .drag, .release => state.x = std.math.clamp(p.local.x, 0, p.size.x),
                .cancel, .long_press => {},
            },
            .key => |event| if (event.phase == .press) {
                state.keys += 1;
            },
            .save => state.saves += 1,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(DragPad);
        const theme = ui.use(app.native.Theme);
        try ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true }, on.bind(.save));
        try ui.open("pad", .{
            .layout = .{ .sizing = .fixedXY(200, 80) },
            .on_pointer = on.handler(.pointer),
            .focus_on_press = true,
            .focus = .{ .on_key = on.handler(.key), .keys = .navigation_only },
            .cursor = .pointer,
            .background_color = if (ui.pressed("pad")) theme.accent else if (ui.hovered("pad") and ui.capabilities().hover) theme.control_background.withAlpha(200) else theme.control_background,
            .border = .{ .color = if (ui.focusVisible("pad")) theme.accent else theme.separator, .widths = .outside(1) },
        });
        defer ui.close();
        try ui.print(.{ .color = theme.text }, "Position {d:.0}", .{state.x});
    }
};
// end-guide-snippet

test "guide drag capture focus keys and shortcut" {
    var h: app.testing.Harness(.{}, DragPad) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const pad = h.root().element("pad");
    try h.dragElement(pad, .init(250, 40), 3);
    try std.testing.expectEqual(200, h.state().x);
    try h.expectFocused(pad);
    try h.press(.right, .{});
    try std.testing.expectEqual(1, h.state().keys);
    const modifiers: app.KeyEvent.Modifiers = if (h.runtime.core.keymap.superIsShortcut()) .{ .super = true } else .{ .control = true };
    try h.press(.{ .char = 's' }, modifiers);
    try std.testing.expectEqual(1, h.state().saves);
}

// docs/guides/widgets-and-input.md, "Own an editor when selection matters"
const Editor = struct {
    pub const State = struct {
        editor: app.TextEditor = .{},
        submitted: bool = false,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.editor.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { input: app.TextInput, pasted: ?[]const u8 };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Editor)) !void {
        switch (msg) {
            .input => |input| {
                const outcome = try ctx.editText(&state.editor, input, .{ .single_line = true, .max_len = 80 }, ctx.handler(.pasted));
                if (outcome.submitted) state.submitted = true;
            },
            .pasted => |text| if (text) |value| {
                _ = try state.editor.apply(ctx.gpa, .{ .paste = value }, ctx.textEnv(.{ .single_line = true, .max_len = 80 }));
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try app.drawn.textEditor(ui, "editor", &state.editor, .{ .on_input = ui.messages(Editor).handler(.input), .single_line = true });
    }
};
// end-guide-snippet

// docs/guides/testing.md, "Type and select without a window"
test "guide editor selection clipboard undo and submission" {
    var h: app.testing.Harness(.{}, Editor) = try .init(.{}, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().child(app.drawn.TextBox, "editor").element("field"));
    try h.type_("hello");
    try h.command(.select_all);
    try std.testing.expectEqualStrings("hello", h.state().editor.selectedText());
    try h.command(.copy);
    try std.testing.expectEqualStrings("hello", h.clipboard().?);
    try h.type_("goodbye");
    try h.command(.undo);
    try h.command(.paste);
    try h.press(.enter, .{});
    try std.testing.expect(h.state().submitted);
}
// end-guide-snippet

// docs/guides/services.md, "Ask the host and keep the answer"
const ServiceScreen = struct {
    pub const State = struct {
        text: ?[]u8 = null,
        answer: ?usize = null,
        unsupported: bool = false,
        dirty: bool = true,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.text) |text| gpa.free(text);
        }
    };
    pub const Msg = union(enum) {
        message,
        confirm,
        menu,
        edit,
        file,
        directory,
        copy,
        paste,
        close,
        text: ?[]const u8,
        answer: ?usize,
        closing: app.platform.CloseReason,
        discard: ?usize,
    };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(ServiceScreen)) !void {
        switch (msg) {
            .message => try ctx.message(.{ .title = "Saved", .text = "Your settings were saved.", .timeout_ms = 2000 }),
            .confirm => try ctx.confirm(.{ .title = "Remove item?", .text = "This removes the selected item.", .buttons = &.{ "Remove", "Cancel" }, .default = 1 }, ctx.handler(.answer)),
            .menu => try ctx.menu(.{ .items = &.{ .{ .id = 7, .title = "Open" }, .{ .kind = .separator }, .{ .id = 9, .title = "Remove", .enabled = false } }, .at = .init(20, 20) }, ctx.handler(.answer)),
            .edit => ctx.systemText(.{ .title = "Name", .initial = state.text orelse "", .max_len = 80 }, ctx.handler(.text)) catch |err| switch (err) {
                error.Unsupported => state.unsupported = true,
                else => return err,
            },
            .file => ctx.openFile(.{ .message = "Open a picture", .extensions = &.{ "png", "jpg" } }, ctx.handler(.text)) catch |err| switch (err) {
                error.Unsupported => state.unsupported = true,
                else => return err,
            },
            .directory => try ctx.openDirectory(.{ .message = "Choose a folder" }, ctx.handler(.text)),
            .copy => try ctx.writeClipboard(state.text orelse "copied"),
            .paste => try ctx.readClipboard(ctx.handler(.text)),
            .text => |value| if (value) |borrowed| {
                const owned = try ctx.gpa.dupe(u8, borrowed);
                if (state.text) |old| ctx.gpa.free(old);
                state.text = owned;
            },
            .answer => |answer| state.answer = answer,
            .close => try ctx.close(),
            .closing => try ctx.confirm(.{ .title = "Discard changes?", .text = "There are unsaved edits.", .buttons = &.{ "Discard", "Keep editing" }, .default = 1 }, ctx.handler(.discard)),
            .discard => |answer| if (answer == 0) {
                state.dirty = false;
                try ctx.quit();
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(ServiceScreen);
        if (state.dirty) ui.guardClose(on.handler(.closing));
        try app.menus.item(ui, "open-menu", .{ .menu = "File", .title = "Open", .key = "o", .on_select = on.bind(.file) });
        try widgets.button(ui, "open", .{ .label = "Open picture", .on_click = on.bind(.file) });
        if (state.unsupported) try ui.text("This host has no chooser or system text entry.", .{});
        if (state.text) |text| try ui.text(text, .{});
    }
};
// end-guide-snippet

// docs/guides/testing.md, "Answer host requests deterministically"
test "guide fake services answer dialogs menus text and choosers" {
    var h: app.testing.Harness(.{}, ServiceScreen) = try .init(.{}, .{ .services = .all });
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(ServiceScreen, .confirm), {});
    try h.answerDialog(1);
    try std.testing.expectEqual(1, h.state().answer.?);
    try h.post(h.root().handler(ServiceScreen, .menu), {});
    try h.chooseMenuItem(7);
    try std.testing.expectEqual(7, h.state().answer.?);
    try h.post(h.root().handler(ServiceScreen, .edit), {});
    try h.enterText("Ada");
    try h.post(h.root().handler(ServiceScreen, .copy), {});
    try h.post(h.root().handler(ServiceScreen, .paste), {});
    try h.expectText("Ada");
    try h.post(h.root().handler(ServiceScreen, .file), {});
    try h.chooseFile("/pictures/harbour.png");
    try h.expectText("/pictures/harbour.png");
    try h.post(h.root().handler(ServiceScreen, .directory), {});
    try h.chooseDirectory("/pictures");
    try h.expectText("/pictures");
    try std.testing.expect(!try h.requestClose(.window));
    try h.answerDialog(0);
    try std.testing.expect(!h.state().dirty);
}
// end-guide-snippet

test "guide absent services use a private clipboard and drawn confirmation" {
    var h: app.testing.Harness(.{}, ServiceScreen) = try .init(.{}, .{ .widgets = .drawn, .services = .none });
    defer h.deinit();
    try h.frame();
    try h.click("Open picture");
    try std.testing.expect(h.state().unsupported);
    try h.post(h.root().handler(ServiceScreen, .copy), {});
    try h.post(h.root().handler(ServiceScreen, .paste), {});
    try h.expectText("copied");
    try h.post(h.root().handler(ServiceScreen, .confirm), {});
    try h.click("Cancel");
    try std.testing.expectEqual(1, h.state().answer.?);
    try std.testing.expectError(error.Unsupported, h.post(h.root().handler(ServiceScreen, .close), {}));
}

// docs/guides/concurrency.md, "Load data and clone the result"
const Loader = struct {
    pub const State = struct {
        result: ?[]u8 = null,
        progress: usize = 0,
        generation: usize = 0,
        failed: bool = false,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.result) |result| gpa.free(result);
        }
    };
    pub const Msg = union(enum) { load, independent, cancel, refresh, result: anyerror![]const u8, progress: usize };
    pub const Props = struct { name: []const u8 = "Gallery", declared: bool = true };

    pub fn load(task: *app.Task, name: []const u8, on_progress: app.Handler(usize)) anyerror![]const u8 {
        try task.checkCancel();
        try task.post(on_progress, 1);
        const progress = try task.progress(on_progress);
        try progress.post(2);
        return try task.gpa.dupe(u8, name);
    }
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Loader)) !void {
        switch (msg) {
            .load => try ctx.runKey("load", load, .{ ctx.props.name, ctx.handler(.progress) }, ctx.handler(.result)),
            .independent => try ctx.run(load, .{ ctx.props.name, ctx.handler(.progress) }, ctx.handler(.result)),
            .cancel => try ctx.cancel("load"),
            .refresh => state.generation += 1,
            .result => |result| {
                const borrowed = result catch {
                    state.failed = true;
                    return;
                };
                const owned = try ctx.gpa.dupe(u8, borrowed);
                if (state.result) |old| ctx.gpa.free(old);
                state.result = owned;
            },
            .progress => |value| state.progress = value,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Loader);
        if (props.declared) try ui.task("catalogue", .{ .restart = state.generation }, load, .{ props.name, on.handler(.progress) }, on.handler(.result));
        try ui.text(state.result orelse "Loading", .{});
    }
};
// end-guide-snippet

// docs/guides/testing.md, "Complete tasks without I/O"
test "guide declared tasks retain results until an explicit restart" {
    var h: app.testing.Harness(.{}, Loader) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.taskStarted("catalogue"));
    try h.completeTask("catalogue", Loader.load, "Fake gallery");
    try h.expectText("Fake gallery");
    try std.testing.expectError(error.TaskAlreadyCompleted, h.completeTask("catalogue", Loader.load, "Again"));
    h.props.name = "New gallery";
    try h.post(h.root().handler(Loader, .refresh), {});
    try h.runTasks();
    try h.expectText("New gallery");
    try std.testing.expectEqual(2, h.state().progress);
}
// end-guide-snippet

test "guide keyed commands cancel and unkeyed commands run independently" {
    var h: app.testing.Harness(.{}, Loader) = try .init(.{ .declared = false }, .{});
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Loader, .load), {});
    try h.post(h.root().handler(Loader, .cancel), {});
    try std.testing.expect(!h.taskStarted("load"));
    try h.post(h.root().handler(Loader, .independent), {});
    try h.runTasks();
    try h.expectText("Gallery");
}

// docs/guides/concurrency.md, "Post progress from a producer thread"
fn threadedWork(task: *app.Task, handler: app.Handler(usize)) anyerror!usize {
    const Producer = struct {
        fn run(progress: app.Task.Progress(usize)) void {
            progress.post(50) catch {};
        }
    };
    const progress = try task.progress(handler);
    var group: std.Io.Group = .init;
    defer group.cancel(task.io);
    try group.concurrent(task.io, Producer.run, .{progress});
    try group.await(task.io);
    try task.checkCancel();
    return 100;
}
// end-guide-snippet

test "guide progress producer joins before task returns" {
    const Screen = struct {
        pub const State = struct { progress: usize = 0, result: usize = 0 };
        pub const Msg = union(enum) { progress: usize, result: anyerror!usize };
        pub const Props = struct {};
        pub fn update(state: *State, msg: Msg, _: *app.Update(@This())) !void {
            switch (msg) {
                .progress => |p| state.progress = p,
                .result => |r| state.result = try r,
            }
        }
        pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
            const on = ui.messages(@This());
            try ui.task("producer", .{}, threadedWork, .{on.handler(.progress)}, on.handler(.result));
        }
    };
    var h: app.testing.Harness(.{}, Screen) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(50, h.state().progress);
    try std.testing.expectEqual(100, h.state().result);
}

// docs/guides/timers-and-animation.md, "Declare a clock and a one-shot notification"
const Clock = struct {
    pub const State = struct { ticks: usize = 0, waiting: bool = true, last_tick: std.Io.Timestamp = .zero };
    pub const Msg = union(enum) { tick, ready };
    pub const Props = struct { running: bool = true };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Clock)) void {
        switch (msg) {
            .tick => {
                state.ticks += 1;
                state.last_tick = ctx.now();
            },
            .ready => state.waiting = false,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Clock);
        if (props.running) try ui.every("clock", .fromSeconds(1), on.bind(.tick));
        if (state.waiting) try ui.after("ready", .fromMilliseconds(250), on.bind(.ready));
        try ui.print(.{}, "Ticks: {d}", .{state.ticks});
        if (!state.waiting) try ui.text("Ready", .{});
    }
};

test "guide timers use virtual time and do not burst after a stall" {
    var h: app.testing.Harness(.{}, Clock) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(250));
    try h.expectText("Ready");
    try h.advance(.fromMilliseconds(750));
    try h.expectText("Ticks: 1");
    try h.advance(.fromSeconds(10));
    try h.expectText("Ticks: 2");
    h.props.running = false;
    try h.frame();
    try std.testing.expect(h.runtime.nextFrame() == null);
}
// end-guide-snippet

// docs/guides/timers-and-animation.md, "Animate from elapsed time"
const Pulse = struct {
    pub const Props = struct { start: std.Io.Timestamp = .zero, duration: std.Io.Duration = .fromSeconds(1) };
    pub fn view(ui: *app.Ui, props: Props) !void {
        const elapsed = props.start.durationTo(ui.now()).toNanoseconds();
        const duration = props.duration.toNanoseconds();
        const t: f32 = std.math.clamp(@as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(@max(duration, 1))), 0, 1);
        const width = if (ui.capabilities().animates()) 20 + 80 * t else 100;
        if (t < 1 and ui.capabilities().animates()) ui.animate();
        try ui.open("bar", .{ .layout = .{ .sizing = .fixedXY(width, 8) }, .background_color = ui.use(app.native.Theme).accent });
        ui.close();
    }
};
// end-guide-snippet

test "guide animation respects reduced motion and stops scheduling" {
    var h: app.testing.Harness(.{}, Pulse) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.advance(.fromMilliseconds(500));
    try std.testing.expectEqual(60, h.findElement(h.root().element("bar")).?.bbox.w);
    try h.advance(.fromMilliseconds(500));
    try std.testing.expect(h.runtime.nextFrame() == null);
    var reduced: app.testing.Harness(.{}, Pulse) = try .init(.{}, .{ .capabilities = .{ .animation = .none } });
    defer reduced.deinit();
    try reduced.frame();
    try std.testing.expectEqual(100, reduced.findElement(reduced.root().element("bar")).?.bbox.w);
    try std.testing.expect(reduced.runtime.nextFrame() == null);
}

// docs/guides/custom-content.md, "Implement measurement and ownership"
const Tile = struct {
    content: layout.Content = .{ .vtable = &vtable, .limit = .parent },
    color: fabrum.Color = .rgb(40, 90, 160),
    released: bool = false,
    const vtable: layout.Content.VTable = .{
        .measure = measure,
        .measure_min = minimum,
        .deinit = release,
        .fingerprint = fingerprint,
        .debug_name = "Tile",
    };
    fn measure(_: *layout.Content, constraints: layout.Constraints) layout.Content.MeasureError!Vec2 {
        return constraints.clamp(.init(64, 32));
    }
    fn minimum(_: *layout.Content, _: layout.Constraints) layout.Content.MeasureError!Vec2 {
        return .init(8, 8);
    }
    fn release(content: *layout.Content) void {
        const self: *Tile = @fieldParentPtr("content", content);
        self.released = true;
    }
    fn fingerprint(content: *const layout.Content) u64 {
        const self: *const Tile = @fieldParentPtr("content", content);
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&self.color));
    }
    pub fn from(content: *const layout.Content) ?*const Tile {
        if (content.vtable != &vtable) return null;
        return @fieldParentPtr("content", content);
    }
};
// end-guide-snippet

// docs/guides/custom-content.md, "Teach a renderer to draw your content"
const TileRenderer = struct {
    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
    gpa: std.mem.Allocator,
    inner: layout.TestRenderer = .{},
    pub fn render(self: *TileRenderer, commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void {
        var translated: std.ArrayList(layout.RenderCommand) = .empty;
        defer translated.deinit(self.gpa);
        for (commands) |command| {
            var output = command;
            if (command.data == .content) if (Tile.from(command.data.content)) |tile| {
                output.data = .{ .rectangle = .{ .color = tile.color, .corner_radius = .{} } };
            };
            try translated.append(self.gpa, output);
        }
        try self.inner.render(translated.items, surface, damage);
    }
};
// end-guide-snippet

test "guide custom content measures draws fingerprints and releases explicitly" {
    const gpa = std.testing.allocator;
    var tile: Tile = .{};
    var context: layout.Context = try .init(gpa, .{ .units = 16 });
    defer context.deinit(gpa);
    context.begin(.{ .sizing = .fixedXY(100, 60) });
    try context.appendContentId(.fromString("tile"), &tile.content);
    context.end();
    try context.computeLayout();
    try std.testing.expectEqual(Vec2.init(64, 32), context.getUnitByStringId("tile").?.size);
    try std.testing.expectEqual(Vec2.init(8, 8), try tile.content.measureMin(.{}));
    var list: std.ArrayList(layout.RenderCommand) = .empty;
    defer list.deinit(gpa);
    var iterator = context.renderCommands();
    while (iterator.next()) |command| try list.append(gpa, command);
    var damage: layout.Damage = .{};
    defer damage.deinit(gpa);
    const pixels = try gpa.alignedAlloc(u8, .@"4", 100 * 60 * 4);
    defer gpa.free(pixels);
    var renderer: TileRenderer = .{ .gpa = gpa };
    try layout.draw(&renderer, list.items, .pixels, .packed_(pixels, 100, 60, .rgba8_premultiplied), try damage.update(gpa, list.items, .init(100, 60)));
    try std.testing.expectEqual(40, pixels[0]);
    try std.testing.expectEqual(0, (try damage.update(gpa, list.items, .init(100, 60))).len);
    tile.color = .white;
    try std.testing.expect((try damage.update(gpa, list.items, .init(100, 60))).len > 0);
    context.begin(.{ .sizing = .fixedXY(100, 60) });
    context.end();
    try std.testing.expect(!tile.released);
    tile.content.deinit();
    try std.testing.expect(tile.released);
}

// docs/guides/custom-content.md, "Use a renderer-specific picture"
fn pictureExample(gpa: std.mem.Allocator) !void {
    if (comptime app.platform.kind == .appkit) {
        const Quartz = fabrum.render.Quartz;
        var picture = try Quartz.svgPicture(gpa, "<svg viewBox=\"0 0 16 16\"><path d=\"M0 0 L16 0 L8 16 Z\"/></svg>");
        defer picture.deinit();
        picture.style = .{ .fit_mode = .contain, .alignment = .center, .color = .black };
        var context: layout.Context = try .init(gpa, .{ .units = 16 });
        defer context.deinit(gpa);
        context.begin(.{ .sizing = .fixedXY(100, 100) });
        try context.appendContent(&picture.content);
        context.end();
        try context.computeLayout();
        var commands = context.renderCommands();
        while (commands.next()) |command| {
            if (command.data == .content) try std.testing.expect(Quartz.content.Picture.asPictureContent(command.data.content) != null);
        }
    }
}
// end-guide-snippet

test "guide picture content remains alive through command consumption" {
    try pictureExample(std.testing.allocator);
}

// docs/guides/writing-a-renderer.md, "Start with a contract-checked renderer"
const BoxRenderer = struct {
    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};
    text_context: Text.Context = .default,
    inner: layout.TestRenderer = .{},
    pub fn render(self: *BoxRenderer, commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void {
        try self.inner.render(commands, surface, damage);
    }
};

comptime {
    layout.checkRenderer(BoxRenderer);
    std.debug.assert(layout.accepts(BoxRenderer, .pixels));
    std.debug.assert(!layout.accepts(BoxRenderer, .cairo));
}
// end-guide-snippet

// docs/guides/writing-a-renderer.md, "Compare partial drawing with a full redraw"
test "guide renderer partial redraw equals full redraw" {
    const gpa = std.testing.allocator;
    var renderer: BoxRenderer = .{};
    var partial: [20 * 20]u8 align(4) = undefined;
    var full: [20 * 20]u8 align(4) = undefined;
    var commands = [_]layout.RenderCommand{.{
        .bbox = .init(2, 2, 8, 8),
        .unit_id = 1,
        .data = .{ .rectangle = .{ .color = .black, .corner_radius = .{} } },
    }};
    var damage: layout.Damage = .{};
    defer damage.deinit(gpa);
    try layout.draw(&renderer, &commands, .pixels, .packed_(&partial, 20, 20, .gray8), try damage.update(gpa, &commands, .init(20, 20)));
    commands[0].bbox.x = 6;
    const changed = try damage.update(gpa, &commands, .init(20, 20));
    try layout.draw(&renderer, &commands, .pixels, .packed_(&partial, 20, 20, .gray8), changed);
    try layout.draw(&renderer, &commands, .pixels, .packed_(&full, 20, 20, .gray8), null);
    try std.testing.expectEqualSlices(u8, &full, &partial);
}
// end-guide-snippet

// docs/guides/hosting.md, "Supply a wakeup and minimal services"
const Host = struct {
    wake: std.atomic.Value(bool) = .init(false),
    running: bool = true,
    presents: usize = 0,
    last_refresh: app.Refresh = .content,
    pub fn platform(self: *Host) app.Platform {
        return .{ .ptr = self, .vtable = &.{ .requestFrame = requestFrame } };
    }
    fn requestFrame(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.wake.store(true, .release);
        // A real host also signals its event loop here.
    }
    pub fn services(self: *Host) app.platform.Services {
        return .{ .ptr = self, .vtable = &.{ .quit = quit, .close = quit } };
    }
    fn quit(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.running = false;
    }
    fn present(self: *Host, _: layout.Surface.Pixels, _: []const Rect, hint: app.Refresh) void {
        self.presents += 1;
        self.last_refresh = hint;
    }
};
// end-guide-snippet

// docs/guides/hosting.md, "Run one event-loop turn"
fn hostTurn(rt: *app.Runtime(.{ .Text = BoxRenderer.Text }), host: *Host, renderer: *BoxRenderer, pixels: layout.Surface.Pixels, now: std.Io.Timestamp) !void {
    const due = rt.nextFrame() orelse return;
    if (due.nanoseconds > now.nanoseconds) return;
    _ = try rt.frame(Counter, .{}, pixels.pointSize(), now);
    const changed = try rt.damage();
    if (changed.len > 0) {
        try layout.draw(renderer, rt.commands(), .pixels, pixels, changed);
        host.present(pixels, changed, rt.refresh());
    }
}

fn hostExample(gpa: std.mem.Allocator, io: std.Io) !void {
    var host: Host = .{};
    var renderer: BoxRenderer = .{};
    var pixels: [320 * 200]u8 align(4) = undefined;
    const surface: layout.Surface.Pixels = .packed_(&pixels, 320, 200, .gray8);
    var rt: app.Runtime(.{ .Text = BoxRenderer.Text }) = try .init(gpa, .{
        .io = io,
        .text_context = renderer.text_context,
        .platform = host.platform(),
        .services = host.services(),
        .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
    });
    defer rt.deinit();
    try hostTurn(&rt, &host, &renderer, surface, .zero);
    _ = try rt.mouse(.{ .position = .init(20, 50) });
    _ = try rt.key(.{ .key = .tab });
    _ = try rt.textInput(.{ .commit = "text from an input method" });
    try rt.cancelPointer();
    try hostTurn(&rt, &host, &renderer, surface, .fromNanoseconds(16_000_000));
    rt.cancelTasks();
    // Stop domain services and external posters before rt.deinit().
}
// end-guide-snippet

test "guide custom host draws only due damaged frames" {
    try hostExample(std.testing.allocator, std.testing.io);
}

// docs/guides/writing-a-platform.md, "Implement a service with a delayed reply"
const ChooserService = struct {
    gpa: std.mem.Allocator,
    title: ?[]u8 = null,
    pending: ?app.platform.Reply = null,
    pub fn services(self: *ChooserService) app.platform.Services {
        return .{ .ptr = self, .vtable = &.{ .openFile = openFile } };
    }
    fn openFile(ptr: *anyopaque, request: *const app.platform.FileRequest, reply: app.platform.Reply) app.platform.Services.Error!void {
        const self: *ChooserService = @ptrCast(@alignCast(ptr));
        if (self.pending != null) return error.ServiceFailed;
        self.title = try self.gpa.dupe(u8, request.message);
        self.pending = reply;
    }
    pub fn answer(self: *ChooserService, path: ?[]const u8) !void {
        const reply = self.pending orelse return error.NoFileChooser;
        self.pending = null;
        defer {
            self.gpa.free(self.title.?);
            self.title = null;
        }
        try reply.send(path);
    }
    pub fn deinit(self: *ChooserService) void {
        if (self.title) |title| self.gpa.free(title);
    }
};
// end-guide-snippet

test "guide external service copies requests and queues borrowed replies" {
    var service: ChooserService = .{ .gpa = std.testing.allocator };
    defer service.deinit();
    var rt: app.Runtime(.{}) = try .init(std.testing.allocator, .{ .io = std.testing.io, .services = service.services() });
    defer rt.deinit();
    _ = try rt.frame(ServiceScreen, .{}, .init(320, 200), .zero);
    try rt.post(app.testing.rootInstance(ServiceScreen).handler(ServiceScreen, .file), {});
    _ = try rt.frame(ServiceScreen, .{}, .init(320, 200), .zero);
    try std.testing.expectEqualStrings("Open a picture", service.title.?);
    try service.answer("/pictures/harbour.png");
    _ = try rt.frame(ServiceScreen, .{}, .init(320, 200), .zero);
    try std.testing.expectEqualStrings("/pictures/harbour.png", rt.rootState(ServiceScreen).?.text.?);
}

// docs/guides/layout.md, "Use layout without the application runtime"
test "guide raw layout percentage widths and manual clipping" {
    const gpa = std.testing.allocator;
    var context: layout.Context = try .init(gpa, .{ .units = 32 });
    defer context.deinit(gpa);
    var text: layout.text.HeuristicContent = .init("Text beside a fixed icon wraps at its final width.", .{});
    context.begin(.{ .sizing = .fixedXY(240, 120), .axis = .y });
    const row = try context.openContainerId(.fromString("row"), .{
        .layout = .{ .sizing = .{ .width = .percent(0.75), .height = .fixed(60) }, .child_gap = 8 },
        .clip = .{ .horizontal = true, .vertical = true, .child_offset = .init(0, -4) },
    });
    const icon = try context.openContainer(.{ .layout = .{ .sizing = .fixed(24) }, .background_color = .black });
    context.closeContainer(icon);
    try context.appendContent(&text.content);
    context.closeContainer(row);
    context.end();
    try context.computeLayout();
    try std.testing.expectEqual(180, context.getUnitByStringId("row").?.bbox.w);
    var commands = context.renderCommands();
    var count: usize = 0;
    while (commands.next()) |_| count += 1;
    try std.testing.expect(count >= 4);
}
// end-guide-snippet

test "guide build functions compile" {
    const build = @import("guide_project/build.zig");
    _ = &build.addRenderer;
    _ = &build.addFabrum;
}

// docs/guides/timers-and-animation.md, "Schedule a discrete visual change"
const Deadline = struct {
    pub const Props = struct { due: std.Io.Timestamp };
    pub fn view(ui: *app.Ui, props: Props) !void {
        const waiting = ui.now().nanoseconds < props.due.nanoseconds;
        if (waiting) ui.frameAt(props.due);
        try ui.text(if (waiting) "Waiting" else "Due", .{});
    }
};

test "guide frameAt requests only the next visual boundary" {
    var h: app.testing.Harness(.{}, Deadline) = try .init(.{ .due = std.Io.Timestamp.zero.addDuration(.fromSeconds(2)) }, .{});
    defer h.deinit();
    try h.frame();
    try h.expectText("Waiting");
    try std.testing.expectEqual(h.props.due.nanoseconds, h.runtime.nextFrame().?.nanoseconds);
    try h.advance(.fromSeconds(2));
    try h.expectText("Due");
    try std.testing.expect(h.runtime.nextFrame() == null);
}
// end-guide-snippet

// docs/guides/concurrency.md, "Run cleanup without a result message"
const Cleanup = struct {
    pub const State = struct {};
    pub const Msg = union(enum) { clean };
    pub const Props = struct { shared: *Shared };
    fn clean(_: *app.Task, shared: *Shared) void {
        // Only this task accesses shared while it runs in this example.
        shared.saves += 1;
    }
    pub fn update(_: *State, _: Msg, ctx: *app.Update(Cleanup)) !void {
        try ctx.runKey("cleanup", clean, .{ctx.props.shared}, null);
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try widgets.button(ui, "clean", .{ .label = "Clean", .on_click = ui.messages(Cleanup).bind(.clean) });
    }
};

test "guide a plain void task accepts a null handler" {
    var shared: Shared = .{};
    var h: app.testing.Harness(.{}, Cleanup) = try .init(.{ .shared = &shared }, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Clean");
    try h.runTasks();
    try std.testing.expectEqual(1, shared.saves);
}
// end-guide-snippet

// docs/guides/testing.md, "Test native composition and disabled controls"
test "guide native composition reports only committed text" {
    var h: app.testing.Harness(.{}, Settings) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const field = h.root().native("name");
    try h.compose(field, "uncommitted");
    try std.testing.expectEqualStrings("", h.state().text.items);
    try h.commit(field, "committed");
    try std.testing.expectEqualStrings("committed", h.state().text.items);
    try h.clickNative(h.root().native("enabled"));
    try h.clickNative(h.root().native("save"));
    try std.testing.expectEqual(0, h.state().saves);
}
// end-guide-snippet

// docs/guides/services.md, "Choose a dialog style"
const Question = struct {
    pub const State = struct { asking: bool = true, answer: ?usize = null };
    pub const Msg = union(enum) { answered: usize };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(Question)) void {
        switch (msg) {
            .answered => |answer| {
                state.asking = false;
                state.answer = answer;
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.text("Settings", .{});
        if (state.asking) try app.dialogs.alert(ui, "question", .{
            .title = "Apply settings?",
            .buttons = &.{ "Apply", "Cancel" },
            .on_response = ui.messages(Question).handler(.answered),
        });
    }
};

test "guide declared alerts disappear after answering in both widget modes" {
    inline for (.{ app.testing.Widgets.native, app.testing.Widgets.drawn }) |mode| {
        var h: app.testing.Harness(.{}, Question) = try .init(.{}, .{ .widgets = mode });
        defer h.deinit();
        try h.frame();
        if (mode == .native) try h.respond(h.root().native("question"), 0) else try h.click("Apply");
        try std.testing.expectEqual(0, h.state().answer.?);
        try std.testing.expect(!h.state().asking);
        try h.expectNoText("Apply settings?");
    }
}
// end-guide-snippet

const guide_docs = @import("guide_docs");
const Guide = struct { path: []const u8, text: []const u8 };
const guides = [_]Guide{
    .{ .path = "docs/guides/README.md", .text = guide_docs.README },
    .{ .path = "docs/guides/first-app.md", .text = guide_docs.first_app },
    .{ .path = "docs/guides/components.md", .text = guide_docs.components },
    .{ .path = "docs/guides/layout.md", .text = guide_docs.layout },
    .{ .path = "docs/guides/widgets-and-input.md", .text = guide_docs.widgets_and_input },
    .{ .path = "docs/guides/services.md", .text = guide_docs.services },
    .{ .path = "docs/guides/concurrency.md", .text = guide_docs.concurrency },
    .{ .path = "docs/guides/timers-and-animation.md", .text = guide_docs.timers_and_animation },
    .{ .path = "docs/guides/testing.md", .text = guide_docs.testing },
    .{ .path = "docs/guides/custom-content.md", .text = guide_docs.custom_content },
    .{ .path = "docs/guides/hosting.md", .text = guide_docs.hosting },
    .{ .path = "docs/guides/writing-a-renderer.md", .text = guide_docs.writing_a_renderer },
    .{ .path = "docs/guides/writing-a-platform.md", .text = guide_docs.writing_a_platform },
};

fn verifyQuotes(source: []const u8) !usize {
    var remaining = source;
    var count: usize = 0;
    while (std.mem.indexOf(u8, remaining, "// docs/" ++ "guides/")) |start| {
        remaining = remaining[start + 3 ..];
        const end_header = std.mem.indexOfScalar(u8, remaining, '\n').?;
        const header = remaining[0..end_header];
        const separator = std.mem.indexOf(u8, header, ", \"").?;
        const path = header[0..separator];
        const heading = header[separator + 3 .. header.len - 1];
        remaining = remaining[end_header + 1 ..];
        const end_code = std.mem.indexOf(u8, remaining, "// end-guide-snippet").?;
        const code = std.mem.trimEnd(u8, remaining[0..end_code], "\n");
        const quoted = try std.fmt.allocPrint(std.testing.allocator, "```zig\n{s}\n```", .{code});
        defer std.testing.allocator.free(quoted);
        var found = false;
        for (guides) |guide| {
            if (!std.mem.eql(u8, path, guide.path)) continue;
            found = std.mem.indexOf(u8, guide.text, quoted) != null;
        }
        if (!found) std.debug.print("guide snippet differs: {s}, \"{s}\"\n", .{ path, heading });
        try std.testing.expect(found);
        count += 1;
        remaining = remaining[end_code + "// end-guide-snippet".len ..];
    }
    return count;
}

test "guide Zig blocks exactly match their compiled sources" {
    const source = @embedFile("guide_snippets.zig");
    const build = @embedFile("guide_project/build.zig");
    const quoted = try verifyQuotes(source) + try verifyQuotes(build);
    var blocks: usize = 0;
    for (guides) |guide| blocks += std.mem.count(u8, guide.text, "```zig\n");
    try std.testing.expectEqual(blocks, quoted);
    const consumer = @embedFile("guide_project/src/main.zig");
    var first_app = std.mem.splitSequence(u8, source, "// docs/" ++ "guides/first-app.md, ");
    _ = first_app.next();
    while (first_app.next()) |part| {
        const begin = std.mem.indexOfScalar(u8, part, '\n').? + 1;
        const end = std.mem.indexOf(u8, part, "// end-guide-snippet").?;
        try std.testing.expect(std.mem.indexOf(u8, consumer, part[begin..end]) != null);
    }
}
