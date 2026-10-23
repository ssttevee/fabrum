//! The snippets in `docs/` that aren't quoted from `examples/`, as code
//! that compiles and runs on every platform, so the docs can't drift from
//! the API. Each section names the document and heading it is quoted in.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const widgets = app.widgets;
const menus = app.menus;
const dialogs = app.dialogs;
const Rect = fabrum.Rect;
const Vec2 = fabrum.Vec2;

// docs/app.md, "Components"

// stateless: a view function with its own element keys
const Badge = struct {
    pub const Props = struct { label: []const u8 };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.open("badge", .{ .layout = .{ .padding = .xy(6, 2) }, .background_color = .gray(230), .corner_radius = .uniform(8) });
        defer ui.close();
        try ui.text(props.label, .{ .font_size = 12 });
    }
};

// stateful: state that persists across frames, changed by messages
const Counter = struct {
    pub const State = struct { count: i32 = 0 }; // optional `deinit(gpa)`
    pub const Msg = union(enum) { increment, decrement }; // optional, with `update`
    pub const Props = struct { step: i32 = 1, on_change: ?app.Handler(i32) = null };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Counter)) !void {
        switch (msg) {
            .increment => state.count += ctx.props.step,
            .decrement => state.count -= ctx.props.step,
        }
        try ctx.emit(ctx.props.on_change, state.count);
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(Counter);
        try ui.open(null, .{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        try ui.print(.{}, "count = {d}", .{state.count});
        try ui.open("minus", .{ .layout = .{ .padding = .all(4) }, .on_click = on.bind(.decrement) });
        try ui.text("-", .{});
        ui.close();
        try ui.open("plus", .{ .layout = .{ .padding = .all(4) }, .on_click = on.bind(.increment) });
        try ui.text("+", .{});
        ui.close();
        try ui.one(Badge, .{ .label = try ui.fmt("step {d}", .{props.step}) });
    }
};

// docs/app.md, "Testing"
test "harness" {
    var h: app.testing.Harness(.{}, Counter) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.click("+");
    try h.expectText("count = 1");
    try std.testing.expectEqual(1, h.state().count);
}

// docs/app.md, "Containers"
const Panel = struct {
    pub const State = struct { open: bool = false };
    pub const Msg = union(enum) { open };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(Panel)) void {
        switch (msg) {
            .open => state.open = true,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Panel);
        try ui.open("panel", .{
            .layout = .{ .axis = .y, .sizing = .grow(.{}), .padding = .all(10), .child_gap = 8, .child_alignment = .center_left },
            .background_color = .rgba(255, 255, 255, 200),
            .corner_radius = .uniform(6),
            .border = .{ .color = .gray(200), .widths = .outside(1) },
            .on_click = on.bind(.open),
        });
        defer ui.close();
        try ui.text(if (state.open) "open" else "closed", .{});
    }
};

test "a panel opens when clicked" {
    var h: app.testing.Harness(.{}, Panel) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.click("closed");
    try h.expectText("open");
}

// docs/app.md, "Messages and handlers"
const Row = struct {
    pub const Props = struct { on_click: app.Action };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.open("row", .{ .layout = .{ .padding = .all(4) }, .on_click = props.on_click });
        defer ui.close();
        try ui.text("row", .{});
    }
};

const Picker = struct {
    pub const Props = struct { on_pick: app.Handler([]const u8) };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.open("pick", .{ .layout = .{ .padding = .all(4) }, .on_click = props.on_pick.with("picked") });
        defer ui.close();
        try ui.text("pick", .{});
    }
};

const App = struct {
    pub const State = struct { saves: usize = 0, chosen: ?usize = null, picked: ?[]const u8 = null };
    pub const Msg = union(enum) { save, choose: usize, picked: []const u8 };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, _: *app.Update(App)) void {
        switch (msg) {
            .save => state.saves += 1,
            .choose => |i| state.chosen = i,
            // the message borrows the text; this one is a literal, so keeping it is fine
            .picked => |text| state.picked = text,
        }
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y } });
        defer ui.close();
        const on = ui.messages(App);
        try widgets.button(ui, "save", .{ .label = "Save", .on_click = on.bind(.save) });
        for (0..3) |i| try ui.child(Row, i, .{ .on_click = on.bind(.{ .choose = i }) });
        try ui.child(Picker, {}, .{ .on_pick = on.handler(.picked) });
    }
};

test "actions and handlers reach the app" {
    var h: app.testing.Harness(.{}, App) = try .init(.{}, .{ .widgets = .drawn });
    defer h.deinit();
    try h.frame();
    try h.click("Save");
    try h.clickElement(h.root().child(Row, 2).element("row"));
    try h.click("pick");
    try std.testing.expectEqual(1, h.state().saves);
    try std.testing.expectEqual(2, h.state().chosen.?);
    try std.testing.expectEqualStrings("picked", h.state().picked.?);
}

// docs/app.md, "The widget set", "Menus and dialogs", "Focus and keys"
const Form = struct {
    pub const State = struct {
        name: std.ArrayList(u8) = .empty,
        agree: bool = false,
        sent: usize = 0,
        greeted: usize = 0,
        confirming: bool = false,
        answer: ?usize = null,
        keys: usize = 0,
        focused: bool = false,
        saved: usize = 0,

        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.name.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { name_changed: []const u8, agreed: bool, send, greet, answered: usize, key: app.KeyEvent, focused: bool, save };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Form)) !void {
        switch (msg) {
            .name_changed => |text| {
                // the message borrows the text: copy it
                state.name.clearRetainingCapacity();
                try state.name.appendSlice(ctx.gpa, text);
            },
            .agreed => |on| state.agree = on,
            .send => {
                state.sent += 1;
                state.confirming = true;
            },
            .greet => state.greeted += 1,
            .answered => |i| {
                state.answer = i;
                state.confirming = false;
            },
            .key => state.keys += 1,
            .focused => |on| state.focused = on,
            .save => state.saved += 1,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 8 } });
        defer ui.close();

        const on = ui.messages(Form);
        try widgets.textField(ui, "name", .{ .text = state.name.items, .on_change = on.handler(.name_changed) });
        try widgets.checkbox(ui, "agree", .{ .label = "I agree", .checked = state.agree, .on_change = on.handler(.agreed) });
        try widgets.button(ui, "send", .{ .label = "Send", .on_click = on.bind(.send), .enabled = state.agree });

        switch (comptime fabrum.app.platform.kind) {
            .appkit => try fabrum.app.platform.appkit.widgets.levelIndicator(ui, "rating", .{ .value = 3, .max = 5 }),
            else => try fabrum.app.widgets.slider(ui, "rating", .{ .value = 3, .max = 5 }),
        }

        try menus.item(ui, "greet", .{ .menu = "Kitchen", .title = "Say Hello", .key = "k", .on_select = on.bind(.greet) });

        if (state.confirming) try dialogs.alert(ui, "erase?", .{
            .title = "Erase the disk?",
            .buttons = &.{ "Erase", "Cancel" },
            .on_response = on.handler(.answered), // usize: the button's index
        });

        try ui.open("list", .{
            .focusable = true,
            .focus = .{
                .on_key = on.handler(.key), // Handler(app.KeyEvent)
                .keys = .navigation_only, // which keys on_key takes: a KeyFilter
                .on_focus = on.handler(.focused), // Handler(bool)
            },
        });
        defer ui.close();
        try ui.text("list", .{});

        try ui.shortcut(.{ .key = .{ .char = 's' }, .shortcut = true }, on.bind(.save));
    }
};

test "the form's widgets, menu item, alert, focus and shortcut work in the harness" {
    var h: app.testing.Harness(.{}, Form) = try .init(.{}, .{ .widgets = .native });
    defer h.deinit();
    try h.frame();
    const root = h.root();
    try h.typeText(root.native("name"), "Ada");
    try std.testing.expectEqualStrings("Ada", h.state().name.items);
    try h.clickNative(root.native("agree"));
    try h.clickNative(root.native("send"));
    try h.selectMenu(root.native("greet"));
    try std.testing.expectEqual(1, h.state().greeted);
    try h.respond(root.native("erase?"), 1);
    try std.testing.expectEqual(1, h.state().answer.?);

    try h.clickElement(root.element("list"));
    try h.tab();
    try h.shiftTab();
    try h.expectFocused(root.element("list"));
    try std.testing.expect(h.state().focused);
    try h.press(.down, .{});
    try std.testing.expectEqual(1, h.state().keys);
    const shortcut: app.KeyEvent.Modifiers = if (h.runtime.core.keymap.superIsShortcut()) .{ .super = true } else .{ .control = true };
    try h.press(.{ .char = 's' }, shortcut);
    try std.testing.expectEqual(1, h.state().saved);
}

// docs/app.md, "Text editing"
const Line = struct {
    pub const State = struct {
        editor: app.TextEditor = .{},
        sent: usize = 0,

        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.editor.deinit(gpa);
        }
    };
    pub const Msg = union(enum) { input: app.TextInput, pasted: ?[]const u8, send };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Line)) !void {
        switch (msg) {
            .input => |input| {
                const outcome = try ctx.editText(&state.editor, input, .{ .single_line = true }, ctx.handler(.pasted));
                if (outcome.submitted) try ctx.emit(ctx.handler(.send), {});
            },
            .pasted => |text| if (text) |t| {
                _ = try state.editor.apply(ctx.gpa, .{ .paste = t }, ctx.textEnv(.{ .single_line = true }));
            },
            .send => state.sent += 1,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Line);
        try app.drawn.textEditor(ui, "line", &state.editor, .{ .on_input = on.handler(.input), .single_line = true });
    }
};

test "an app-owned editor takes typing and submits on Enter" {
    var h: app.testing.Harness(.{}, Line) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.clickElement(h.root().child(app.drawn.TextBox, "line").element("field"));
    try h.type_("hi");
    try std.testing.expectEqualStrings("hi", h.state().editor.text.items);
    try h.press(.enter, .{});
    try std.testing.expectEqual(1, h.state().sent);
}

// docs/app.md, "`update` and its context": the platform's file chooser
const Viewer = struct {
    pub const State = struct {
        path: ?[]u8 = null,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.path) |p| gpa.free(p);
        }
    };
    pub const Msg = union(enum) { pick_picture, picture_picked: ?[]const u8 };
    pub const Props = struct {};
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(Viewer)) !void {
        switch (msg) {
            .pick_picture => try ctx.openFile(.{ .message = "Choose a picture", .extensions = &.{ "png", "jpg" } }, ctx.handler(.picture_picked)),
            .picture_picked => |picked| {
                const borrowed = picked orelse return; // cancelled
                const path = try ctx.gpa.dupe(u8, borrowed);
                if (state.path) |old| ctx.gpa.free(old);
                state.path = path;
            },
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Viewer);
        try ui.open("pick", .{ .layout = .{ .padding = .all(4) }, .on_click = on.bind(.pick_picture) });
        defer ui.close();
        try ui.text(state.path orelse "Open a picture", .{});
    }
};

test "the file chooser answers through the harness" {
    var h: app.testing.Harness(.{}, Viewer) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.click("Open a picture");
    try h.chooseFile("/pictures/harbour.png");
    try h.expectText("/pictures/harbour.png");
}

// docs/layout.md, "Floating" and "Surfaces and drawing"
test "a floating thumb attaches to its parent's corner, and draw takes pixels and damage" {
    const gpa = std.testing.allocator;
    var ctx: layout.Context = try .init(gpa, .{ .units = 16 });
    defer ctx.deinit(gpa);
    ctx.begin(.{ .sizing = .fixedXY(800, 600) });
    const box = try ctx.openContainer(.{ .layout = .{ .sizing = .grow(.{}) }, .background_color = .gray(240) });
    const thumb = try ctx.openContainer(.{
        .layout = .{ .sizing = .fixedXY(6, 40) },
        .floating = .{
            .mode = .parent, // .parent, .root, .unit_id (parent = .{ .id = ... }), .unit_index
            .parent_point = .right_top, // an AttachPoint
            .unit_point = .right_top,
            .offset = .init(-8, 8),
        },
        .background_color = .gray(120),
    });
    ctx.closeContainer(thumb);
    ctx.closeContainer(box);
    ctx.end();
    try ctx.computeLayout();
    try std.testing.expectEqual(Rect.init(800 - 8 - 6, 8, 6, 40), ctx.getUnitByIndex(thumb).?.bbox);

    var commands: std.ArrayList(layout.RenderCommand) = .empty;
    defer commands.deinit(gpa);
    var it = ctx.renderCommands();
    while (it.next()) |command| try commands.append(gpa, command);

    const buffer = try gpa.alignedAlloc(u8, .@"4", 800 * 600 * 4);
    defer gpa.free(buffer);
    const damage: ?[]const Rect = &.{.init(780, 0, 20, 60)};
    var renderer: layout.TestRenderer = .{};
    try fabrum.layout.draw(&renderer, commands.items, .pixels, .packed_(buffer, 800, 600, .rgba8_premultiplied), damage);
}

// docs/platforms.md, "The host contract": the loop, against a host made of
// data and a renderer that draws boxes
const Root = Counter;

const Renderer = struct {
    inner: layout.TestRenderer = .{},
    text_context: Text.Context = .default,

    pub const Text = layout.text.HeuristicContent;
    pub const surfaces: []const layout.Surface.Kind = &.{.pixels};

    pub fn render(self: *Renderer, commands: []const layout.RenderCommand, surface: layout.Surface, damage: ?[]const Rect) !void {
        try self.inner.render(commands, surface, damage);
    }
};

const Host = struct {
    io: std.Io,
    now: std.Io.Timestamp = .zero,
    running: bool = true,
    turns: usize = 0,
    queued: []const Input = &.{},
    passed_on: usize = 0,
    presented: usize = 0,

    const Input = union(enum) { pointer: app.MouseEvent, key: app.KeyEvent, text: []const u8 };

    fn services(_: *Host) ?app.platform.Services {
        return null;
    }
    fn pendingInput(self: *Host) []const Input {
        defer self.queued = &.{};
        return self.queued;
    }
    fn passOn(self: *Host, _: Input) void {
        self.passed_on += 1;
    }
    fn clock(self: *Host) std.Io.Timestamp {
        return self.now;
    }
    fn present(self: *Host, _: layout.Surface.Pixels, _: []const Rect, _: app.Refresh) void {
        self.presented += 1;
    }
    fn inputArrives(_: *Host) bool {
        return false;
    }
    fn sleepUntil(self: *Host, _: ?std.Io.Timestamp, _: bool) void {
        self.now = self.now.addDuration(.fromMilliseconds(16));
        self.turns += 1;
        if (self.turns == 3) self.running = false;
    }
};

fn hostLoop(gpa: std.mem.Allocator, io: std.Io, host: *Host, renderer: *Renderer, pixels: layout.Surface.Pixels) !void {
    const viewport = pixels.pointSize();
    const props: Root.Props = .{};
    var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{
        .io = io,
        .text_context = renderer.text_context,
        .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none, .color = .gray16, .keyboard = .on_screen },
        .services = host.services(), // dialogs, a system keyboard, quitting: what the host has
    });
    defer rt.deinit();
    while (host.running) {
        for (host.pendingInput()) |input| {
            const taken = switch (input) {
                .pointer => |event| try rt.mouse(event),
                .key => |event| try rt.key(event),
                .text => |text| try rt.textInput(.{ .commit = text }),
            };
            if (!taken) host.passOn(input);
        }
        const now = host.clock();
        if (rt.nextFrame()) |due| if (due.nanoseconds <= now.nanoseconds) {
            const commands = try rt.frame(Root, props, viewport, now);
            const damage = try rt.damage();
            if (damage.len > 0) {
                try fabrum.layout.draw(renderer, commands, .pixels, pixels, damage);
                host.present(pixels, damage, rt.refresh());
            }
        };
        host.sleepUntil(rt.nextFrame(), host.inputArrives());
    }
}

test "the host loop runs frames, draws the damage and passes input on" {
    const gpa = std.testing.allocator;
    var host: Host = .{ .io = std.testing.io };
    host.queued = &.{ .{ .pointer = .{ .position = .init(1, 1) } }, .{ .key = .{ .key = .tab } } };
    var renderer: Renderer = .{};
    const buffer = try gpa.alignedAlloc(u8, .@"4", 300 * 200);
    defer gpa.free(buffer);
    try hostLoop(gpa, std.testing.io, &host, &renderer, .packed_(buffer, 300, 200, .gray8));
    try std.testing.expectEqual(1, host.presented);
    try std.testing.expectEqual(2, host.passed_on);
}

// docs/app.md, "Concurrency": the task snippets use these small stand-ins
// for I/O/decoding so the calls and result ownership can be tested unchanged.
const TaskScreen = struct {
    const Work = struct { unloads: usize = 0 };
    pub const State = struct {
        drive_refresh: u32 = 0,
        image_reads: usize = 0,
        drives: usize = 0,
        thumbs: usize = 0,
        progress: usize = 0,
    };
    pub const Msg = union(enum) {
        read,
        unload,
        image_read: anyerror![]const u8,
        drives_listed: anyerror!usize,
        thumb: anyerror![]const u8,
        progress: usize,
    };
    pub const Props = struct { path: []const u8 = "harbour.png", work: *Work, show_child: bool = false };

    fn readImage(task: *app.Task, path: []const u8) anyerror![]const u8 {
        try task.checkCancel();
        return try task.gpa.dupe(u8, path);
    }
    fn unloadImage(_: *app.Task, work: *Work) void {
        work.unloads += 1;
    }
    fn listDrives(task: *app.Task) anyerror!usize {
        try task.checkCancel();
        return 2;
    }
    fn loadThumbnail(task: *app.Task, path: []const u8) anyerror![]const u8 {
        try task.checkCancel();
        return try task.gpa.dupe(u8, path);
    }

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(TaskScreen)) !void {
        switch (msg) {
            .read => {
                const path = ctx.props.path;
                try ctx.run(readImage, .{path}, ctx.handler(.image_read));
                try ctx.runKey("image", readImage, .{path}, ctx.handler(.image_read));
                try ctx.cancel("image");
            },
            .unload => {
                const work = ctx.props.work;
                try ctx.runKey("image", unloadImage, .{work}, null);
            },
            .image_read => |result| {
                const image = try result;
                try std.testing.expectEqualStrings(ctx.props.path, image);
                state.image_reads += 1;
            },
            .drives_listed => |result| state.drives = try result,
            .thumb => |result| {
                const image = try result;
                try std.testing.expectEqualStrings(ctx.props.path, image);
                state.thumbs += 1;
            },
            .progress => |value| state.progress = value,
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, props: Props) !void {
        const on = ui.messages(TaskScreen);
        const path = props.path;
        try ui.task("drives", .{ .restart = state.drive_refresh }, listDrives, .{}, on.handler(.drives_listed));
        try ui.task(.{ "thumb", path }, .{}, loadThumbnail, .{path}, on.handler(.thumb));
        if (props.show_child) try ui.one(TaskChild, .{});
    }
};

test "concurrency snippets queue commands, cancel keyed work and allow null for void" {
    var work: TaskScreen.Work = .{};
    var h: app.testing.Harness(.{}, TaskScreen) = try .init(.{ .work = &work }, .{});
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(TaskScreen, .read), {});
    try std.testing.expect(!h.taskStarted("image"));
    try h.runTasks();
    try std.testing.expectEqual(1, h.state().image_reads);
    try std.testing.expectEqual(2, h.state().drives);
    try std.testing.expectEqual(1, h.state().thumbs);
    try h.post(h.root().handler(TaskScreen, .unload), {});
    try h.runTasks();
    try std.testing.expectEqual(1, work.unloads);
    try std.testing.expect(!h.taskStarted("image"));
}

test "declared task snippets retain keys, restart and accept fake results" {
    var work: TaskScreen.Work = .{};
    var h: app.testing.Harness(.{}, TaskScreen) = try .init(.{ .work = &work }, .{});
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.taskStarted("drives"));
    try h.completeTask("drives", TaskScreen.listDrives, 3);
    try std.testing.expectEqual(3, h.state().drives);
    try std.testing.expectError(error.TaskAlreadyCompleted, h.completeTask("drives", TaskScreen.listDrives, 4));
    h.state().drive_refresh += 1; // a test may inspect/change state directly
    try h.frame();
    try h.completeTask("drives", TaskScreen.listDrives, 4);
    try std.testing.expectEqual(4, h.state().drives);
    try h.completeTask(.{ "thumb", h.props.path }, TaskScreen.loadThumbnail, h.props.path);
    try std.testing.expectEqual(1, h.state().thumbs);
}

// docs/app.md, "Concurrency": Task.progress returns Task.Progress(P).
// Post while the task is active; the harness then delivers queued messages.
const TaskChild = struct {
    pub const Props = struct {};
    fn work(task: *app.Task, handler: app.Handler(usize)) anyerror!usize {
        const progress = try task.progress(handler);
        try progress.post(5);
        try task.post(handler, 6);
        return 2;
    }
    pub fn view(ui: *app.Ui, _: Props) !void {
        const on = ui.messages(TaskScreen);
        try ui.task("progress", .{}, work, .{on.handler(.progress)}, on.handler(.drives_listed));
    }
};

test "child task helpers and progress use the declared component scope" {
    var work: TaskScreen.Work = .{};
    var h: app.testing.Harness(.{}, TaskScreen) = try .init(.{ .work = &work, .show_child = true }, .{});
    defer h.deinit();
    try h.frame();
    const child = h.root().one(TaskChild);
    try std.testing.expect(h.taskStartedFor(child, "progress"));
    try h.completeTaskFor(child, "progress", TaskChild.work, 2);
    try std.testing.expectEqual(0, h.state().progress);
    h.props.show_child = false;
    try h.frame();
    try std.testing.expect(!h.taskStartedFor(child, "progress"));
    h.props.show_child = true;
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(6, h.state().progress);
}

// docs/renderers.md, "Built in: fabrum.render": context and text helpers.
test "built-in renderer helpers use the advertised text and image contexts" {
    const gpa = std.testing.allocator;
    switch (comptime app.platform.kind) {
        .appkit => {
            const Quartz = fabrum.render.Quartz;
            var renderer: Quartz = try .init(gpa);
            defer renderer.deinit();
            var text = renderer.text("harbour", .{});
            try std.testing.expect((try text.content.measure(.{})).x > 0);
            var picture = try Quartz.svgPicture(gpa, "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 L10 10\"/></svg>");
            defer picture.deinit();
        },
        .gtk => {
            const Cairo = fabrum.render.Cairo;
            var renderer: Cairo = try .init(gpa);
            defer renderer.deinit();
            var text = renderer.text("harbour", .{});
            try std.testing.expect((try text.content.measure(.{})).x > 0);
            var image: Cairo.Image = try .init(10, 10);
            defer image.deinit();
            try layout.draw(&renderer, &.{}, .cairo, image.context, null);
        },
        else => {},
    }
}

// docs/platforms.md, "AppKit (macOS)" (also GTK's App has the same shape).
// Compile the init/run example without opening a window or entering its loop.
const WindowExample = struct {
    const Services = struct {};
    const Icons = struct {};
    var services: Services = .{};
    var icons: Icons = .{};
    fn shutdown(_: ?*anyopaque) void {}

    fn main(init: std.process.Init) !void {
        const toolkit = app.platform.current;
        const Gui = toolkit.App(Counter);
        const gui = try init.gpa.create(Gui);
        try gui.init(init.gpa, init.io, .{}, .{ .title = "Gallery", .width = 800, .height = 480 }, .{
            .provide = &.{ .of(&services), .of(&icons) },
            .on_terminate = .{ .ctx = &services, .call = shutdown },
        });
        gui.run();
    }
};

test "toolkit init and run example compiles" {
    if (comptime app.platform.kind == .appkit or app.platform.kind == .gtk or app.platform.kind == .win32) {
        _ = &WindowExample.main;
    }
}
