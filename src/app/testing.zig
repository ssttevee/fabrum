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
//! Native widgets live in a fake tree (`NativeTree`), whatever platform the
//! app is built for and on every OS, so tests drive them as a user would and
//! check what fabrum made of them:
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
const KeyEvent = @import("input.zig").KeyEvent;
const platform = @import("platform.zig");
const runtime = @import("runtime.zig");
const Config = runtime.Config;
const ScrollInfo = runtime.ScrollInfo;
const Capabilities = @import("capabilities.zig").Capabilities;
const Keymap = @import("keymap.zig").Keymap;
const text_editor = @import("text_editor.zig");
const TextInput = text_editor.TextInput;
const EditCommand = text_editor.EditCommand;
const Poster = @import("message.zig").Poster;
const native = @import("native.zig");
const native_api = native;
const native_tree = @import("testing/native_tree.zig");

/// A fake native widget tree, which `Harness` runs native widgets in.
pub const NativeTree = native_tree.NativeTree;
/// One native widget of a `NativeTree`, as data.
pub const Widget = native_tree.Widget;

/// How a `Harness` shows `app.widgets`.
pub const Widgets = enum {
    /// As native widgets, in a fake tree (`Harness.tree`) that tests drive
    /// with `clickNative`, `typeText` and the like.
    native,
    /// Drawn by fabrum, as on the `none` platform, and clicked like any
    /// drawn element.
    drawn,

    /// What the platform this program is built for does: drawn on `none`,
    /// native elsewhere.
    pub const default: Widgets = if (platform.kind == .none) .drawn else .native;
};

/// Runs `Root` in a `Runtime(config)` with a fixed viewport, and drives it
/// through the runtime's own input: clicks are a primary button press and
/// release at the center of what is clicked. Every input, and every
/// `post`, is followed by a frame, so queries always see the result.
///
/// Time stands still unless a test moves it with `advance`.
///
/// Uses `std.testing.allocator` and `std.testing.io` unless told otherwise,
/// so leaks fail the test. Must not be moved after its first frame.
pub fn Harness(comptime config: Config, comptime Root: type) type {
    return struct {
        runtime: Runtime,
        /// The props `Root` is rendered with; change them between frames.
        props: Root.Props,
        viewport: Vec2,
        /// The native widgets, as data. Empty when widgets are drawn.
        tree: *NativeTree,
        /// The time frames run at.
        now: std.Io.Timestamp = .zero,

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
            /// Whether `app.widgets` are native, in `tree`, or drawn.
            widgets: Widgets = .default,
            /// The look of drawn widgets.
            theme: native.Theme = .{},
            /// Which of the tree's fake services the runtime has: all of
            /// them, only the basic ones (the clipboard, quitting and
            /// closing, so the runtime draws dialogs and menus), or none,
            /// as a `none` host that gives no `Services`.
            services: Services = .all,
            /// What the platform can do, or the platform's own.
            capabilities: ?Capabilities = null,
            /// Which keys mean which edit commands, or the platform's own.
            keymap: ?Keymap = null,
        };

        pub const Services = enum { all, basic, none };

        /// A harness that hasn't run a frame yet; start with `frame`.
        pub fn init(props: Root.Props, options: Options) !Self {
            const gpa = options.gpa orelse std.testing.allocator;
            const tree = try NativeTree.create(gpa);
            errdefer tree.destroy();
            tree.full_keyboard_access = options.full_keyboard_access;
            var result: Self = .{
                .runtime = try .init(gpa, .{
                    .io = options.io orelse std.testing.io,
                    .text_context = options.text_context,
                    .provide = options.provide,
                    .context = options.context,
                    .native = switch (options.widgets) {
                        .native => tree.backend(),
                        .drawn => null,
                    },
                    .theme = options.theme,
                    .capabilities = options.capabilities,
                    .keymap = options.keymap,
                    .services = switch (options.services) {
                        .all => tree.services(),
                        .basic => tree.basicServices(),
                        .none => null,
                    },
                }),
                .props = props,
                .viewport = options.viewport,
                .tree = tree,
            };
            result.runtime.core.tasks.queued = true;
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.runtime.deinit();
            self.tree.destroy();
            self.* = undefined;
        }

        /// Runs a frame: delivers queued messages, then renders and lays
        /// out `Root` with `props`.
        pub fn frame(self: *Self) !void {
            // the harness is in place by now, for events the tree reports itself
            self.tree.listener = .{ .ctx = &self.runtime, .report = report };
            _ = try self.runtime.frame(Root, self.props, self.viewport, self.now);
            if (self.tree.listener_error) |err| return err;
        }

        fn report(ctx: *anyopaque, id: native.Id, event: native.Event) anyerror!void {
            const rt: *Runtime = @ptrCast(@alignCast(ctx));
            try rt.nativeEvent(id, event);
        }

        /// Moves time on by `duration`, then runs a frame.
        pub fn advance(self: *Self, duration: std.Io.Duration) !void {
            self.now = self.now.addDuration(duration);
            try self.frame();
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

        /// Runs the tasks currently queued, in declaration order, then
        /// delivers their results and renders a frame. Tasks created by
        /// those results wait for the next runTasks call.
        pub fn runTasks(self: *Self) !void {
            self.runtime.core.tasks.runQueued();
            try self.frame();
        }

        /// Whether the root has an active or completed task with `key`.
        /// Declared tasks keep this key across changes to their restart value.
        pub fn taskStarted(self: *Self, key: anytype) bool {
            return self.taskStartedFor(self.root(), key);
        }

        /// taskStarted for a child or stateless component scope.
        pub fn taskStartedFor(self: *Self, instance: Instance, key: anytype) bool {
            return self.runtime.core.tasks.find(instance.id, component.elementKey(instance.id, key)) != null;
        }

        /// Completes a queued root task without running its function.
        /// The function supplies the result type. Result memory is copied;
        /// the caller retains its original value.
        pub fn completeTask(self: *Self, key: anytype, comptime function: anytype, result: @import("task.zig").Result(function)) !void {
            try self.completeTaskFor(self.root(), key, function, result);
        }

        /// completeTask for a child or stateless component scope.
        pub fn completeTaskFor(self: *Self, instance: Instance, key: anytype, comptime function: anytype, result: @import("task.zig").Result(function)) !void {
            const record = self.runtime.core.tasks.find(instance.id, component.elementKey(instance.id, key)) orelse return error.TaskNotFound;
            if (record.function != @import("task.zig").functionTag(function)) return error.TaskFunctionChanged;
            try record.complete(record, component.typeTag(@import("task.zig").Result(function)), component.erase(&result));
            try self.frame();
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
            return rootInstance(Root);
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
            _ = try self.runtime.mouse(.{ .position = point, .pressed = buttons });
            _ = try self.runtime.mouse(.{ .position = point });
            try self.frame();
        }

        /// Moves the pointer to `point` with no button held, then runs a
        /// frame.
        pub fn moveTo(self: *Self, point: Vec2) !void {
            _ = try self.runtime.mouse(.{ .position = point });
            try self.frame();
        }

        /// Delivers any pointer event, then runs a frame. Returns whether
        /// the app took it; see `Runtime.mouse`.
        pub fn mouse(self: *Self, event: MouseEvent) !bool {
            const taken = try self.runtime.mouse(event);
            try self.frame();
            return taken;
        }

        /// Presses and releases `key`, then runs a frame. Returns whether
        /// the app took it; see `Runtime.key`.
        pub fn pressKey(self: *Self, k: KeyEvent.Key, modifiers: KeyEvent.Modifiers) !bool {
            const taken = try self.runtime.key(.{ .key = k, .modifiers = modifiers });
            _ = try self.runtime.key(.{ .key = k, .phase = .release, .modifiers = modifiers });
            try self.frame();
            return taken;
        }

        /// Presses and releases `key` with `modifiers`, with a frame after
        /// each, and fails unless the app took it. A character key is
        /// `.{ .char = 'a' }`; the text it would type isn't sent (use
        /// `type_` for typing).
        pub fn press(self: *Self, k: KeyEvent.Key, modifiers: KeyEvent.Modifiers) !void {
            if (!try self.runtime.key(.{ .key = k, .modifiers = modifiers })) {
                std.debug.print("the app didn't take the key {any} with {any}\n", .{ k, modifiers });
                return error.KeyNotTaken;
            }
            try self.frame();
            _ = try self.runtime.key(.{ .key = k, .phase = .release, .modifiers = modifiers });
            try self.frame();
        }

        /// Holds `key` down: a press, then `repeats` repeats, then the
        /// release, with a frame after each.
        pub fn hold(self: *Self, k: KeyEvent.Key, modifiers: KeyEvent.Modifiers, repeats: usize) !void {
            _ = try self.runtime.key(.{ .key = k, .modifiers = modifiers });
            try self.frame();
            for (0..repeats) |_| {
                _ = try self.runtime.key(.{ .key = k, .phase = .repeat, .modifiers = modifiers });
                try self.frame();
            }
            _ = try self.runtime.key(.{ .key = k, .phase = .release, .modifiers = modifiers });
            try self.frame();
        }

        /// Delivers any key event, then runs a frame. Returns whether the
        /// app took it.
        pub fn keyEvent(self: *Self, event: KeyEvent) !bool {
            const taken = try self.runtime.key(event);
            try self.frame();
            return taken;
        }

        /// Types `text` into the focused text input as a keyboard would:
        /// one key per code point, carrying the character as its text,
        /// with a frame after each. Fails if nothing takes it.
        pub fn type_(self: *Self, text: []const u8) !void {
            var it = (try std.unicode.Utf8View.init(text)).iterator();
            while (it.nextCodepointSlice()) |slice| {
                const cp = try std.unicode.utf8Decode(slice);
                const k: KeyEvent.Key = if (cp == ' ') .space else .{ .char = std.ascii.toLower(@as(u8, @intCast(@min(cp, 127)))) };
                const event: KeyEvent = .{ .key = if (cp < 128) k else .unknown, .text = slice, .modifiers = .{ .shift = cp < 128 and std.ascii.isUpper(@intCast(cp)) } };
                if (!try self.runtime.key(event)) {
                    std.debug.print("nothing took the typed text \"{s}\"\n", .{slice});
                    return error.TextNotTaken;
                }
                _ = try self.runtime.key(.{ .key = event.key, .phase = .release, .modifiers = event.modifiers });
                try self.frame();
            }
        }

        /// Sends an edit command to the focused text input, as a keymap
        /// would, then runs a frame.
        pub fn command(self: *Self, cmd: EditCommand) !void {
            try self.textInput(.{ .command = cmd });
        }

        /// Delivers `input` to the focused text input, as a host with an
        /// input method does, then runs a frame. Fails if none has focus.
        pub fn textInput(self: *Self, input: TextInput) !void {
            if (!try self.runtime.textInput(input)) return error.NoTextInputFocused;
            try self.frame();
        }

        /// Presses at `from`, moves in `steps` to `to`, and releases, with
        /// a frame after each, as a drag does.
        pub fn drag(self: *Self, from: Vec2, to: Vec2, steps: usize) !void {
            var buttons: MouseEvent.Buttons = .empty;
            buttons.set(MouseEvent.primary);
            _ = try self.runtime.mouse(.{ .position = from, .pressed = buttons });
            try self.frame();
            const n: f32 = @floatFromInt(@max(steps, 1));
            for (1..@max(steps, 1) + 1) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / n;
                const at: Vec2 = .init(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
                _ = try self.runtime.mouse(.{ .position = at, .pressed = buttons });
                try self.frame();
            }
            _ = try self.runtime.mouse(.{ .position = to });
            try self.frame();
        }

        /// Drags from the middle of the element with `id` to `to`.
        pub fn dragElement(self: *Self, id: layout.Unit.Id, to: Vec2, steps: usize) !void {
            try self.drag(center(try self.elementUnit(id)), to, steps);
        }

        /// Presses at `point`, holds it long (as a touch screen reports),
        /// and releases, with a frame after each.
        pub fn longPress(self: *Self, point: Vec2) !void {
            var buttons: MouseEvent.Buttons = .empty;
            buttons.set(MouseEvent.primary);
            _ = try self.runtime.mouse(.{ .position = point, .pressed = buttons });
            try self.frame();
            _ = try self.runtime.mouse(.{ .position = point, .pressed = buttons, .long_press = true });
            try self.frame();
            _ = try self.runtime.mouse(.{ .position = point });
            try self.frame();
        }

        /// Scrolls the wheel by `delta` over the middle of the text
        /// `string`, then runs a frame. Returns whether anything scrolled.
        pub fn scroll(self: *Self, string: []const u8, delta: Vec2) !bool {
            return self.scrollAt(center(try self.textUnit(string)), delta);
        }

        /// Scrolls the wheel by `delta` over the middle of the element with
        /// `id`, then runs a frame.
        pub fn scrollElement(self: *Self, id: layout.Unit.Id, delta: Vec2) !bool {
            return self.scrollAt(center(try self.elementUnit(id)), delta);
        }

        /// Scrolls the wheel by `delta` at `point`, then runs a frame.
        pub fn scrollAt(self: *Self, point: Vec2, delta: Vec2) !bool {
            const taken = try self.runtime.mouse(.{ .position = point, .scroll_delta = delta });
            try self.frame();
            return taken;
        }

        /// Where the drawn scroll container with `id` is, as of the last
        /// frame.
        pub fn scrollInfo(self: *const Self, id: layout.Unit.Id) ?ScrollInfo {
            return self.runtime.scrollInfo(id);
        }

        /// The focused element's layout ID, if any.
        pub fn focusedElement(self: *const Self) ?layout.Unit.Id {
            const focus = self.runtime.focused() orelse return null;
            return .fromInt(focus.unit);
        }

        /// The fake clipboard's text.
        pub fn clipboard(self: *const Self) ?[]const u8 {
            return self.tree.clipboard;
        }

        // Native widgets

        /// The fake widget made for the native element `id`, as from
        /// `root().native(key)`, or null.
        pub fn widget(self: *Self, id: native.Id) ?*Widget {
            return self.tree.find(id);
        }

        /// The widget for `id`, or an error listing the widgets there are.
        pub fn expectWidget(self: *Self, id: native.Id) error{NoSuchWidget}!*Widget {
            return self.widget(id) orelse {
                std.debug.print("no native widget for element {x}; widgets:\n", .{id});
                for (self.tree.all()) |w| std.debug.print("  {x}: {t}\n", .{ w.id, w.spec });
                return error.NoSuchWidget;
            };
        }

        /// Clicks a native widget: presses a button or menu item, flips a
        /// checkbox or switch, or focuses a text field. Then runs a frame.
        pub fn clickNative(self: *Self, id: native.Id) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.tree.click(w));
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
                try self.deliver(w.id, try self.tree.insert(w, keystroke));
            }
        }

        /// Replaces a native field's whole text in one edit, as pasting
        /// over a selection does. Then runs a frame.
        pub fn setText(self: *Self, id: native.Id, text: []const u8) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.tree.replace(w, text));
        }

        /// Starts or changes an IME composition in a native field: `marked`
        /// shows uncommitted and isn't reported. Then runs a frame.
        pub fn compose(self: *Self, id: native.Id, marked: []const u8) !void {
            try self.tree.compose(try self.expectWidget(id), marked);
            try self.frame();
        }

        /// Ends a composition by committing `text`, as choosing a candidate
        /// does: reports the text, then the end of the composition. Runs a
        /// frame after each.
        pub fn commit(self: *Self, id: native.Id, text: []const u8) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.tree.commit(w, text));
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
            try self.deliver(w.id, try self.tree.slide(w, value));
        }

        /// Chooses item `index` of a native dropdown or radio group, then
        /// runs a frame.
        pub fn selectNative(self: *Self, id: native.Id, index: usize) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.tree.select(w, index));
        }

        /// Steps a native stepper `steps` up (or down, if negative), then
        /// runs a frame.
        pub fn stepNative(self: *Self, id: native.Id, steps: i32) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, try self.tree.step(w, steps));
        }

        /// Scrolls a native scroll view so that `offset` of its content is
        /// at its top left, as far as it goes, then runs a frame.
        pub fn scrollNative(self: *Self, id: native.Id, offset: Vec2) !void {
            const w = try self.expectWidget(id);
            try self.deliver(w.id, self.tree.scroll(w, offset));
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

        // The shell

        /// Answers the oldest file chooser the app showed with `path`, or
        /// cancels it with null, then runs a frame.
        pub fn chooseFile(self: *Self, path: ?[]const u8) !void {
            try self.tree.chooseFile(path);
            try self.frame();
        }

        /// Asks to close the window or quit, as the host does first, then
        /// runs a frame. Returns whether it may; see `Runtime.shouldClose`.
        pub fn requestClose(self: *Self, reason: platform.CloseReason) !bool {
            const may = try self.runtime.shouldClose(reason);
            try self.frame();
            return may;
        }

        /// Answers the oldest dialog the app asked the fake services for
        /// with the button at `index`, or dismisses it with null, then
        /// runs a frame.
        pub fn answerDialog(self: *Self, index: ?usize) !void {
            try self.tree.answerDialog(index);
            try self.frame();
        }

        /// Chooses the item with `id` of the oldest menu the app asked
        /// the fake services for, or dismisses it with null, then runs a
        /// frame.
        pub fn chooseMenuItem(self: *Self, id: ?usize) !void {
            try self.tree.chooseMenuItem(id);
            try self.frame();
        }

        /// Answers the oldest text entry the app asked the fake services
        /// for with `text`, or cancels it with null, then runs a frame.
        pub fn enterText(self: *Self, text: ?[]const u8) !void {
            try self.tree.enterText(text);
            try self.frame();
        }

        /// Answers the oldest directory chooser with `path`, or cancels it.
        pub fn chooseDirectory(self: *Self, path: ?[]const u8) !void {
            try self.tree.chooseDirectory(path);
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
            if (focus) |f| if (f.unit == id.id) {
                // with drawn widgets only, fabrum's focus is all there is
                if (self.runtime.reconciler().backend == null) return;
                // and the platform agrees about where keys go
                const target = self.tree.focus;
                const agrees = if (f.native) |nid| target == .native and self.tree.widgets.get(target.native).?.id == nid else target == .canvas;
                if (agrees) return;
            };
            std.debug.print("expected focus on element {d}, but it is on {?}, and the tree's on {t}\n", .{ id.id, focus, self.tree.focus });
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

/// The root instance of `Root` in any runtime, to find its elements by key
/// from debugging tools, as `Harness.root` does in tests.
pub fn rootInstance(comptime Root: type) Instance {
    return .{ .id = component.instanceId(component.root_parent, Root, {}) };
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

    /// A handler for one of the `Msg` tags of the instance, which must be
    /// one of `C`, to post to as a service would.
    pub fn handler(self: Instance, comptime C: type, comptime tag: std.meta.Tag(C.Msg)) Handler(@import("message.zig").PayloadOf(C, tag)) {
        return @import("message.zig").bindHandler(C, self.id, tag);
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
