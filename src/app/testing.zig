//! Testing apps without a window or a renderer.
//!
//! `Harness` runs a root component in a `Runtime` with a fixed viewport, and
//! finds, clicks and checks what the last frame laid out, as a user would:
//!
//! ```zig
//! var h: app.testing.Harness(.{}, Counter) = try .init(.{}, .{});
//! defer h.deinit();
//! try h.frame();
//! try h.click("+");
//! try h.expectText("count = 1");
//! try std.testing.expectEqual(1, h.state().count);
//! ```
//!
//! Native widgets are the headless platform's (`app.platform.headless`), on
//! every OS, so tests drive them as a user would and check what fabrum made
//! of them:
//!
//! ```zig
//! const name = h.root().native("name");
//! try h.typeText(name, "Ada");
//! try std.testing.expectEqualStrings("Ada", h.state().name);
//! try h.tab();
//! try h.expectFocused(h.root().element("ok"));
//! ```
//!
//! The text queries below the harness work on any runtime's layout, so
//! debugging tools in a real app can find what to click the same way.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

const component = @import("component.zig");
const InstanceId = component.InstanceId;
const RootValue = @import("context.zig").RootValue;
const MouseEvent = @import("input.zig").MouseEvent;
const runtime = @import("runtime.zig");
const Config = runtime.Config;
const Poster = @import("message.zig").Poster;
const native = @import("native.zig");
const native_api = native;
const headless = @import("platform/headless.zig");

/// Runs `Root` in a `Runtime(config)` with a fixed viewport, and drives it
/// through the runtime's own input: clicks are a primary button press and
/// release at the center of what is clicked. Every input, and every
/// `post`, is followed by a frame, so queries always see the result.
///
/// Uses `std.testing.allocator` and `std.testing.io` unless told otherwise,
/// so leaks fail the test. Must not be moved after its first frame.
pub fn Harness(comptime config: Config, comptime Root: type) type {
    return struct {
        runtime: Runtime,
        /// The props `Root` is rendered with; change them between frames.
        props: Root.Props,
        viewport: Vec2,
        /// The native widgets, as data.
        platform: *headless.Backend,

        const Self = @This();

        pub const Runtime = runtime.Runtime(config);
        pub const Text = config.Text;

        pub const Options = struct {
            /// The size every frame is laid out at.
            viewport: Vec2 = .init(800, 600),
            /// Root values, as in `Runtime.Options.provide`.
            provide: []const RootValue = &.{},
            /// Measures `Text`. Optional when `Text.Context` declares a
            /// `default`, as `layout.text.HeuristicContent`'s does.
            text_context: ?Text.Context = null,
            /// Defaults to `std.testing.allocator`.
            gpa: ?Allocator = null,
            /// Defaults to `std.testing.io`.
            io: ?std.Io = null,
            /// Capacity of the layout built each frame.
            context: layout.Context.Config = .{},
            /// Whether every native control takes keyboard focus, as with
            /// macOS's "Keyboard navigation" on, or only text fields.
            full_keyboard_access: bool = false,
        };

        /// A harness that hasn't run a frame yet; start with `frame`.
        pub fn init(props: Root.Props, options: Options) !Self {
            const gpa = options.gpa orelse std.testing.allocator;
            const platform = try headless.Backend.create(gpa);
            errdefer platform.destroy();
            platform.full_keyboard_access = options.full_keyboard_access;
            return .{
                .runtime = try .init(gpa, .{
                    .io = options.io orelse std.testing.io,
                    .text_context = options.text_context,
                    .provide = options.provide,
                    .context = options.context,
                    .native = platform.backend(),
                }),
                .props = props,
                .viewport = options.viewport,
                .platform = platform,
            };
        }

        pub fn deinit(self: *Self) void {
            self.runtime.deinit();
            self.platform.destroy();
            self.* = undefined;
        }

        /// Runs a frame: delivers queued messages, then renders and lays
        /// out `Root` with `props`.
        pub fn frame(self: *Self) !void {
            _ = try self.runtime.frame(Root, self.props, self.viewport);
        }

        /// The root component's state. Panics before the first frame.
        pub fn state(self: *Self) *Root.State {
            return self.runtime.rootState(Root) orelse @panic("app.testing.Harness.state: no frame has run");
        }

        /// Posts `payload` to `handler`, as a service answering would, then
        /// runs a frame. An `Action` is posted with `{}`.
        pub fn post(self: *Self, handler: anytype, payload: anytype) !void {
            try self.runtime.post(handler, payload);
            try self.frame();
        }

        /// A thread-safe poster, for code under test that posts by itself.
        pub fn poster(self: *Self) Poster {
            return self.runtime.poster();
        }

        // Finding

        /// The text units of the last frame, in layout order.
        pub fn texts(self: *Self) TextIterator(Text) {
            return .init(self.runtime.context());
        }

        /// The text unit showing exactly `string` in the last frame, or
        /// null. The first, if there are several.
        pub fn findText(self: *Self, string: []const u8) ?*const layout.Unit {
            return findTextIn(Text, self.runtime.context(), string);
        }

        pub fn hasText(self: *Self, string: []const u8) bool {
            return self.findText(string) != null;
        }

        /// Fails, listing the texts on screen, unless the last frame shows
        /// exactly `string`.
        pub fn expectText(self: *Self, string: []const u8) error{TestExpectedText}!void {
            if (self.hasText(string)) return;
            std.debug.print("expected the text \"{s}\" on screen\n", .{string});
            self.printTexts();
            return error.TestExpectedText;
        }

        /// Fails if the last frame shows exactly `string`.
        pub fn expectNoText(self: *Self, string: []const u8) error{TestUnexpectedText}!void {
            if (!self.hasText(string)) return;
            std.debug.print("expected no text \"{s}\" on screen\n", .{string});
            return error.TestUnexpectedText;
        }

        /// The root component's instance, to find elements by key:
        /// `h.findElement(h.root().one(Dialog).element("ok"))`.
        pub fn root(_: *const Self) Instance {
            return .{ .id = component.instanceId(component.root_parent, Root, {}) };
        }

        /// The element with `id` in the last frame, or null.
        pub fn findElement(self: *Self, id: layout.Unit.Id) ?*const layout.Unit {
            return self.runtime.context().getUnitById(id);
        }

        // Input

        /// Clicks the middle of the text `string`, then runs a frame.
        /// Clicks bubble up from the text to the element around it with an
        /// `on_click`, as a user's would; a click on nothing clickable does
        /// nothing.
        pub fn click(self: *Self, string: []const u8) !void {
            try self.clickAt(center(try self.textUnit(string)));
        }

        /// Clicks the middle of the element with `id`, then runs a frame.
        pub fn clickElement(self: *Self, id: layout.Unit.Id) !void {
            try self.clickAt(center(try self.elementUnit(id)));
        }

        /// Moves the pointer over the middle of the text `string`, then
        /// runs a frame.
        pub fn hover(self: *Self, string: []const u8) !void {
            try self.moveTo(center(try self.textUnit(string)));
        }

        /// Moves the pointer over the middle of the element with `id`, then
        /// runs a frame.
        pub fn hoverElement(self: *Self, id: layout.Unit.Id) !void {
            try self.moveTo(center(try self.elementUnit(id)));
        }

        /// Moves the pointer out of the viewport, then runs a frame.
        pub fn leave(self: *Self) !void {
            try self.moveTo(.init(-1, -1));
        }

        /// Presses and releases the primary button at `point`, then runs a
        /// frame.
        pub fn clickAt(self: *Self, point: Vec2) !void {
            var buttons: MouseEvent.Buttons = .empty;
            buttons.set(MouseEvent.primary);
            try self.runtime.mouse(.{ .position = point, .pressed = buttons });
            try self.runtime.mouse(.{ .position = point });
            try self.frame();
        }

        /// Moves the pointer to `point` with no button held, then runs a
        /// frame.
        pub fn moveTo(self: *Self, point: Vec2) !void {
            try self.runtime.mouse(.{ .position = point });
            try self.frame();
        }

        // Native widgets

        /// The headless widget made for the native element `id`, as from
        /// `root().native(key)`, or null.
        pub fn widget(self: *Self, id: native.Id) ?*headless.Widget {
            return self.platform.find(id);
        }

        /// The widget for `id`, or an error listing the widgets there are.
        pub fn expectWidget(self: *Self, id: native.Id) error{NoSuchWidget}!*headless.Widget {
            return self.widget(id) orelse {
                std.debug.print("no native widget for element {x}; widgets:\n", .{id});
                for (self.platform.all()) |w| std.debug.print("  {x}: {t}\n", .{ w.id, w.spec });
                return error.NoSuchWidget;
            };
        }

        /// Clicks a native widget: presses a button or menu item, flips a
        /// checkbox or switch, or focuses a text field. Then runs a frame.
        pub fn clickNative(self: *Self, id: native.Id) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.platform.click(w));
        }

        /// Selects a menu item, then runs a frame.
        pub fn selectMenu(self: *Self, id: native.Id) !void {
            return self.clickNative(id);
        }

        /// Types `text` at the end of a native field, one keystroke per
        /// code point, as a keyboard would: each reports the field's text.
        /// Runs a frame after each.
        pub fn typeText(self: *Self, id: native.Id, text: []const u8) !void {
            var it = (try std.unicode.Utf8View.init(text)).iterator();
            while (it.nextCodepointSlice()) |keystroke| {
                const w = try self.expectWidget(id);
                if (w.marked != null) return error.Composing;
                try self.deliver(w.id, try self.platform.insert(w, keystroke));
            }
        }

        /// Replaces a native field's whole text in one edit, as pasting
        /// over a selection does. Then runs a frame.
        pub fn setText(self: *Self, id: native.Id, text: []const u8) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.platform.replace(w, text));
        }

        /// Starts or changes an IME composition in a native field: `marked`
        /// shows uncommitted and isn't reported. Then runs a frame.
        pub fn compose(self: *Self, id: native.Id, marked: []const u8) !void {
            try self.platform.compose(try self.expectWidget(id), marked);
            try self.frame();
        }

        /// Ends a composition by committing `text`, as choosing a candidate
        /// does: reports the text, then the end of the composition. Runs a
        /// frame after each.
        pub fn commit(self: *Self, id: native.Id, text: []const u8) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.platform.commit(w, text));
            try self.deliver(id, .composition_end);
        }

        /// Presses Return in a native field, then runs a frame.
        pub fn submit(self: *Self, id: native.Id) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, .submit);
        }

        /// Drags a native slider to `value`, then runs a frame.
        pub fn slide(self: *Self, id: native.Id, value: f64) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.platform.slide(w, value));
        }

        /// Answers a native alert with the button at `index`, then runs a
        /// frame.
        pub fn respond(self: *Self, id: native.Id, index: usize) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, .{ .response = index });
        }

        fn deliver(self: *Self, id: native.Id, event: ?native.Event) !void {
            if (event) |e| try self.runtime.nativeEvent(id, e);
            try self.frame();
        }

        // Focus

        /// Presses Tab: focus moves to the next element in paint order,
        /// native or drawn. Then runs a frame.
        pub fn tab(self: *Self) !void {
            self.runtime.focusMove(.next);
            try self.frame();
        }

        /// Presses Shift-Tab, then runs a frame.
        pub fn shiftTab(self: *Self) !void {
            self.runtime.focusMove(.previous);
            try self.frame();
        }

        /// Presses Space: clicks the focused drawn element. Then runs a
        /// frame.
        pub fn pressSpace(self: *Self) !void {
            try self.runtime.activateFocused();
            try self.frame();
        }

        /// Fails unless the element whose layout ID is `id` has focus, as
        /// from `root().element(key)`; a native element's box counts.
        pub fn expectFocused(self: *Self, id: layout.Unit.Id) error{TestExpectedFocus}!void {
            const focus = self.runtime.focused();
            if (focus != null and focus.?.unit == id.id) {
                // and the platform agrees about where keys go
                const target = self.platform.focus;
                const agrees = if (focus.?.native) |nid| target == .native and self.platform.widgets.get(target.native).?.id == nid else target == .canvas;
                if (agrees) return;
            }
            std.debug.print("expected focus on element {d}, but it is on {?}, and the platform's on {t}\n", .{ id.id, focus, self.platform.focus });
            return error.TestExpectedFocus;
        }

        fn textUnit(self: *Self, string: []const u8) error{NoSuchText}!*const layout.Unit {
            return self.findText(string) orelse {
                std.debug.print("no text \"{s}\" on screen\n", .{string});
                self.printTexts();
                return error.NoSuchText;
            };
        }

        fn elementUnit(self: *Self, id: layout.Unit.Id) error{NoSuchElement}!*const layout.Unit {
            return self.findElement(id) orelse {
                std.debug.print("no element with ID {d} on screen\n", .{id.id});
                return error.NoSuchElement;
            };
        }

        fn printTexts(self: *Self) void {
            std.debug.print("texts on screen:\n", .{});
            var it = self.texts();
            while (it.next()) |found| std.debug.print("  \"{s}\"\n", .{found.content.text});
        }
    };
}

/// A rendered component instance, to find its elements by key. Its children
/// are found the way they were rendered: `child(C, key)` for
/// `ui.child(C, key, props)`, `one(C)` for `ui.one(C, props)`.
pub const Instance = struct {
    id: InstanceId,

    pub fn child(self: Instance, comptime C: type, key: anytype) Instance {
        return .{ .id = component.instanceId(self.id, C, key) };
    }

    pub fn one(self: Instance, comptime C: type) Instance {
        return self.child(C, {});
    }

    /// The layout ID of the instance's element opened with `key`, as
    /// `ui.id(key)` gives it inside the instance's view. A native view's
    /// element is its box.
    pub fn element(self: Instance, key: anytype) layout.Unit.Id {
        return component.elementId(self.id, key);
    }

    /// The ID of the instance's native element declared with `key`, as
    /// `ui.nativeId(key)` gives it inside the instance's view.
    pub fn native(self: Instance, key: anytype) native_api.Id {
        return component.elementKey(self.id, key);
    }
};

/// Iterates the text units of a layout whose text is `Text`, a
/// `layout.text.Content(...)` type, in layout order.
pub fn TextIterator(comptime Text: type) type {
    return struct {
        units: []const layout.Unit,
        index: usize = 0,

        pub const Found = struct {
            unit: *const layout.Unit,
            content: *const Text,
        };

        pub fn init(context: *const layout.Context) @This() {
            return .{ .units = context.units.items };
        }

        pub fn next(self: *@This()) ?Found {
            while (self.index < self.units.len) {
                const unit = &self.units[self.index];
                self.index += 1;
                if (unit.data != .content) continue;
                const content = Text.asTextContent(unit.data.content) orelse continue;
                return .{ .unit = unit, .content = content };
            }
            return null;
        }
    };
}

/// The first unit of `context` whose `Text` is exactly `string`, or null.
pub fn findText(comptime Text: type, context: *const layout.Context, string: []const u8) ?*const layout.Unit {
    var it: TextIterator(Text) = .init(context);
    while (it.next()) |found| {
        if (std.mem.eql(u8, found.content.text, string)) return found.unit;
    }
    return null;
}

const findTextIn = findText;

/// The middle of a unit's bounds, where clicks land.
pub fn center(unit: *const layout.Unit) Vec2 {
    const box = unit.bbox;
    return .init(box.x + box.w / 2, box.y + box.h / 2);
}

const Ui = @import("ui.zig").Ui;
const Update = @import("message.zig").Update;
const Handler = @import("message.zig").Handler;
const Action = @import("message.zig").Action;

const Tally = struct {
    pub const State = struct { count: i32 = 0 };
    pub const Msg = union(enum) { add: i32, reset };
    pub const Props = struct { label: []const u8 = "count" };

    pub fn update(state: *State, msg: Msg, _: *Update(Tally)) void {
        switch (msg) {
            .add => |amount| state.count += amount,
            .reset => state.count = 0,
        }
    }

    pub fn view(ui: *Ui, state: *const State, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .axis = .y, .child_gap = 4 } });
        defer ui.close();
        try ui.print(.{}, "{s} = {d}", .{ props.label, state.count });
        const on = ui.messages(Tally);
        try ui.one(Buttons, .{ .on_add = on.handler(.add), .on_reset = on.bind(.reset) });
    }
};

const Buttons = struct {
    pub const Props = struct { on_add: Handler(i32), on_reset: Action };

    pub fn view(ui: *Ui, props: Props) !void {
        try ui.open(null, .{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        inline for (.{ .{ "plus", "+", props.on_add.with(1) }, .{ "reset", "reset", props.on_reset } }) |button| {
            try ui.open(button[0], .{ .layout = .{ .padding = .all(4) }, .on_click = button[2] });
            defer ui.close();
            try ui.text(button[1], .{});
        }
        if (ui.hovered("reset")) try ui.text("pointing at reset", .{});
    }
};

test "Harness clicks by text and by key, and shows state and props" {
    var h: Harness(.{}, Tally) = try .init(.{}, .{ .viewport = .init(300, 200) });
    defer h.deinit();
    try h.frame();
    try h.expectText("count = 0");

    try h.click("+");
    try h.click("+");
    try h.expectText("count = 2");
    try h.expectNoText("count = 0");
    try std.testing.expectEqual(2, h.state().count);

    // the stateless `Buttons` has its own keys, found under its instance
    const reset = h.root().one(Buttons).element("reset");
    try std.testing.expect(h.findElement(reset) != null);
    try h.clickElement(reset);
    try h.expectText("count = 0");

    h.props.label = "total";
    try h.frame();
    try h.expectText("total = 0");

    // the pointer is still over "reset", which shows one more text
    try h.leave();
    var shown: usize = 0;
    var it = h.texts();
    while (it.next()) |_| shown += 1;
    try std.testing.expectEqual(3, shown);
}

test "Harness hovers and moves the pointer away" {
    var h: Harness(.{}, Tally) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();

    try h.hover("reset");
    try h.expectText("pointing at reset");
    try h.leave();
    try h.expectNoText("pointing at reset");

    try h.hoverElement(h.root().one(Buttons).element("reset"));
    try h.expectText("pointing at reset");
}

test "Harness posts to handlers and runs the frame that delivers them" {
    var h: Harness(.{}, Tally) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.post(@import("message.zig").bindHandler(Tally, h.root().id, .add), 5);
    try h.expectText("count = 5");
}
