//! A fake native widget tree: native widgets as plain data in memory, with
//! no window and no toolkit, for tests.
//!
//! `app.testing.Harness` runs apps against it, whatever platform they are
//! built for, so tests click native buttons, type into native fields and
//! tab through focus on any OS, and check the widgets fabrum made, their
//! frames and their values. It is not a platform: programs never run on it.
//!
//! It behaves as macOS does where platforms differ: only text fields take
//! focus unless `full_keyboard_access` is on, and sizes are close to
//! AppKit's regular controls.
//!
//! It is also fake services (`services`, an `app.platform.Services`): a
//! clipboard, and dialogs, menus, text entries and file and directory
//! choosers that wait for a test to answer them, with counts of quits and
//! closes.
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../../root.zig");
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

const native = @import("../native.zig");
const platform = @import("../platform.zig");
const Spec = native.Spec;
const Value = native.Value;
const Event = native.Event;

/// The in-memory widget tree. Must not move once its `backend` is in use;
/// `create` puts one on the heap.
pub const NativeTree = struct {
    gpa: Allocator,
    widgets: std.AutoArrayHashMapUnmanaged(native.Handle, Widget) = .empty,
    /// Handles are never reused, so a stale one finds nothing.
    next_handle: usize = 1,
    focus: native.FocusTarget = .none,
    /// The last scene presented; valid until the runtime's next frame.
    scene: native.Scene = .{},
    presents: usize = 0,
    /// Whether every control takes focus (macOS's "Keyboard navigation"),
    /// or only text fields.
    full_keyboard_access: bool = false,
    look: native.Theme = .{},
    /// Whether writes are reported back as events, as GTK's `changed`
    /// signal reports `gtk_editable_set_text`. They arrive while a frame
    /// runs, from inside `setValue`.
    report_writes: bool = false,
    /// Whether focusing a widget reports `.focus = true`, as AppKit's
    /// `becomeFirstResponder` does, from inside `focus`.
    report_focus: bool = false,
    /// Where events the tree reports by itself go: the runtime's
    /// `nativeEvent`. `app.testing.Harness` sets it.
    listener: ?Listener = null,
    /// The first error the listener returned, as the backend's calls can't.
    listener_error: ?anyerror = null,

    /// The fake services' clipboard text, owned.
    clipboard: ?[]u8 = null,
    /// File choosers shown and not answered yet, oldest first.
    file_requests: std.ArrayList(FileRequest) = .empty,
    /// Directory choosers shown and not answered yet, oldest first.
    directory_requests: std.ArrayList(FileRequest) = .empty,
    /// Dialogs shown and not answered yet, oldest first; message boxes
    /// are answered at once (they have no reply) but still listed.
    dialogs: std.ArrayList(DialogRequest) = .empty,
    /// Menus shown and not answered yet, oldest first.
    menus: std.ArrayList(MenuRequest) = .empty,
    /// Text entries shown and not answered yet, oldest first.
    text_requests: std.ArrayList(TextRequest) = .empty,
    /// How many times the app quit, and closed its window.
    quits: usize = 0,
    closes: usize = 0,

    pub fn create(gpa: Allocator) Allocator.Error!*NativeTree {
        const self = try gpa.create(NativeTree);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Frees the widget tree. The runtime destroys its widgets first.
    pub fn destroy(self: *NativeTree) void {
        for (self.widgets.values()) |*widget| widget.deinit(self.gpa);
        self.widgets.deinit(self.gpa);
        for (self.file_requests.items) |request| request.deinit(self.gpa);
        self.file_requests.deinit(self.gpa);
        for (self.directory_requests.items) |request| request.deinit(self.gpa);
        self.directory_requests.deinit(self.gpa);
        for (self.dialogs.items) |request| request.deinit(self.gpa);
        self.dialogs.deinit(self.gpa);
        for (self.menus.items) |request| request.deinit(self.gpa);
        self.menus.deinit(self.gpa);
        for (self.text_requests.items) |request| request.deinit(self.gpa);
        self.text_requests.deinit(self.gpa);
        if (self.clipboard) |text| self.gpa.free(text);
        self.gpa.destroy(self);
    }

    /// A file chooser the app asked for, waiting for an answer.
    pub const FileRequest = struct {
        /// Its message and extensions, owned.
        message: []const u8,
        extensions: []const []const u8,
        reply: platform.Reply,

        fn deinit(self: FileRequest, gpa: Allocator) void {
            gpa.free(self.message);
            for (self.extensions) |extension| gpa.free(extension);
            gpa.free(self.extensions);
        }
    };

    /// A dialog the app asked for, waiting for an answer.
    pub const DialogRequest = struct {
        title: []const u8,
        text: []const u8,
        buttons: []const []const u8,
        kind: platform.DialogKind,
        /// Null for a message box, which has no answer.
        reply: ?platform.IndexReply,

        fn deinit(self: DialogRequest, gpa: Allocator) void {
            gpa.free(self.title);
            gpa.free(self.text);
            for (self.buttons) |button| gpa.free(button);
            gpa.free(self.buttons);
        }
    };

    /// A menu the app asked for, waiting for a choice: its items
    /// flattened, submenus after their item, with their depth.
    pub const MenuRequest = struct {
        items: []const Item,
        at: Vec2,
        reply: platform.IndexReply,

        pub const Item = struct {
            title: []const u8,
            kind: platform.MenuItem.Kind,
            id: usize,
            enabled: bool,
            depth: u8,
        };

        fn deinit(self: MenuRequest, gpa: Allocator) void {
            for (self.items) |item| gpa.free(item.title);
            gpa.free(self.items);
        }

        /// The first enabled item titled `title`, if any.
        pub fn find(self: MenuRequest, title: []const u8) ?Item {
            for (self.items) |item| if (std.mem.eql(u8, item.title, title)) return item;
            return null;
        }
    };

    /// A text entry the app asked for, waiting for its text.
    pub const TextRequest = struct {
        title: []const u8,
        initial: []const u8,
        flags: platform.TextRequest.Flags,
        reply: platform.Reply,

        fn deinit(self: TextRequest, gpa: Allocator) void {
            gpa.free(self.title);
            gpa.free(self.initial);
        }
    };

    /// The fake services, all of them.
    pub fn services(self: *NativeTree) platform.Services {
        return .{ .ptr = self, .vtable = &services_vtable };
    }

    /// Fake services with only the clipboard, quitting and closing, as a
    /// host without its own dialogs and menus: the runtime draws them.
    pub fn basicServices(self: *NativeTree) platform.Services {
        return .{ .ptr = self, .vtable = &basic_vtable };
    }

    /// The fake shell of N1: the services.
    pub fn shell(self: *NativeTree) platform.Services {
        return self.services();
    }

    /// Answers the oldest file chooser with `path`, or cancels it with
    /// null, as the user would. Errors if none is shown.
    pub fn chooseFile(self: *NativeTree, path: ?[]const u8) !void {
        if (self.file_requests.items.len == 0) return error.NoFileChooser;
        const request = self.file_requests.orderedRemove(0);
        defer request.deinit(self.gpa);
        try request.reply.send(path);
    }

    /// Answers the oldest directory chooser with `path`, or cancels it.
    pub fn chooseDirectory(self: *NativeTree, path: ?[]const u8) !void {
        if (self.directory_requests.items.len == 0) return error.NoDirectoryChooser;
        const request = self.directory_requests.orderedRemove(0);
        defer request.deinit(self.gpa);
        try request.reply.send(path);
    }

    /// Answers the oldest dialog with the button at `index`, or dismisses
    /// it with null. Errors if none is shown.
    pub fn answerDialog(self: *NativeTree, index: ?usize) !void {
        if (self.dialogs.items.len == 0) return error.NoDialog;
        const request = self.dialogs.orderedRemove(0);
        defer request.deinit(self.gpa);
        if (request.reply) |reply| try reply.send(index) else if (index != null) return error.MessageHasNoButtons;
    }

    /// Chooses the item with `id` of the oldest menu, or dismisses it with
    /// null. Errors if none is shown.
    pub fn chooseMenuItem(self: *NativeTree, id: ?usize) !void {
        if (self.menus.items.len == 0) return error.NoMenu;
        if (id) |wanted| {
            for (self.menus.items[0].items) |item| {
                if (item.id == wanted and item.kind == .item) {
                    if (!item.enabled) return error.MenuItemDisabled;
                    break;
                }
            }
        }
        const request = self.menus.orderedRemove(0);
        defer request.deinit(self.gpa);
        try request.reply.send(id);
    }

    /// Answers the oldest text entry with `text`, or cancels it with null.
    pub fn enterText(self: *NativeTree, text: ?[]const u8) !void {
        if (self.text_requests.items.len == 0) return error.NoTextEntry;
        const request = self.text_requests.orderedRemove(0);
        defer request.deinit(self.gpa);
        try request.reply.send(text);
    }

    /// Puts `text` on the fake clipboard, as another app would.
    pub fn setClipboard(self: *NativeTree, text: ?[]const u8) Allocator.Error!void {
        const copy = if (text) |t| try self.gpa.dupe(u8, t) else null;
        if (self.clipboard) |old| self.gpa.free(old);
        self.clipboard = copy;
    }

    const services_vtable: platform.Services.VTable = .{
        .message = serviceMessage,
        .confirm = serviceConfirm,
        .menu = serviceMenu,
        .editText = serviceEditText,
        .openFile = serviceOpenFile,
        .openDirectory = serviceOpenDirectory,
        .writeClipboard = serviceWriteClipboard,
        .readClipboard = serviceReadClipboard,
        .quit = serviceQuit,
        .close = serviceClose,
    };

    const basic_vtable: platform.Services.VTable = .{
        .writeClipboard = serviceWriteClipboard,
        .readClipboard = serviceReadClipboard,
        .quit = serviceQuit,
        .close = serviceClose,
    };

    fn dupeAll(gpa: Allocator, strings: []const []const u8) Allocator.Error![]const []const u8 {
        const copies = try gpa.alloc([]const u8, strings.len);
        var done: usize = 0;
        errdefer {
            for (copies[0..done]) |copy| gpa.free(copy);
            gpa.free(copies);
        }
        for (copies, strings) |*to, from| {
            to.* = try gpa.dupe(u8, from);
            done += 1;
        }
        return copies;
    }

    fn fileRequest(self: *NativeTree, request: *const platform.FileRequest, reply: platform.Reply) Allocator.Error!FileRequest {
        const message = try self.gpa.dupe(u8, request.message);
        errdefer self.gpa.free(message);
        const extensions = try dupeAll(self.gpa, request.extensions);
        return .{ .message = message, .extensions = extensions, .reply = reply };
    }

    fn serviceOpenFile(ptr: *anyopaque, request: *const platform.FileRequest, reply: platform.Reply) platform.Services.Error!void {
        const self = cast(ptr);
        try self.file_requests.append(self.gpa, try self.fileRequest(request, reply));
    }

    fn serviceOpenDirectory(ptr: *anyopaque, request: *const platform.FileRequest, reply: platform.Reply) platform.Services.Error!void {
        const self = cast(ptr);
        try self.directory_requests.append(self.gpa, try self.fileRequest(request, reply));
    }

    fn dialog(self: *NativeTree, title: []const u8, text: []const u8, buttons: []const []const u8, kind: platform.DialogKind, reply: ?platform.IndexReply) Allocator.Error!void {
        const owned_title = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned_title);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        const owned_buttons = try dupeAll(self.gpa, buttons);
        try self.dialogs.append(self.gpa, .{ .title = owned_title, .text = owned_text, .buttons = owned_buttons, .kind = kind, .reply = reply });
    }

    fn serviceMessage(ptr: *anyopaque, request: *const platform.MessageRequest) platform.Services.Error!void {
        try cast(ptr).dialog(request.title, request.text, &.{}, request.kind, null);
    }

    fn serviceConfirm(ptr: *anyopaque, request: *const platform.ConfirmRequest, reply: platform.IndexReply) platform.Services.Error!void {
        if (request.buttons.len == 0 or request.buttons.len > 3) return error.ServiceFailed;
        try cast(ptr).dialog(request.title, request.text, request.buttons, request.kind, reply);
    }

    fn flatten(gpa: Allocator, items: []const platform.MenuItem, depth: u8, out: *std.ArrayList(MenuRequest.Item)) Allocator.Error!void {
        for (items) |item| {
            const title = try gpa.dupe(u8, item.title);
            errdefer gpa.free(title);
            try out.append(gpa, .{ .title = title, .kind = item.kind, .id = item.id, .enabled = item.enabled, .depth = depth });
            if (item.kind == .submenu) try flatten(gpa, item.submenu, depth + 1, out);
        }
    }

    fn serviceMenu(ptr: *anyopaque, request: *const platform.MenuRequest, reply: platform.IndexReply) platform.Services.Error!void {
        const self = cast(ptr);
        var items: std.ArrayList(MenuRequest.Item) = .empty;
        errdefer {
            for (items.items) |item| self.gpa.free(item.title);
            items.deinit(self.gpa);
        }
        try flatten(self.gpa, request.items, 0, &items);
        try self.menus.append(self.gpa, .{ .items = try items.toOwnedSlice(self.gpa), .at = request.at, .reply = reply });
    }

    fn serviceEditText(ptr: *anyopaque, request: *const platform.TextRequest, reply: platform.Reply) platform.Services.Error!void {
        const self = cast(ptr);
        const title = try self.gpa.dupe(u8, request.title);
        errdefer self.gpa.free(title);
        const initial = try self.gpa.dupe(u8, request.initial);
        errdefer self.gpa.free(initial);
        try self.text_requests.append(self.gpa, .{ .title = title, .initial = initial, .flags = request.flags, .reply = reply });
    }

    fn serviceWriteClipboard(ptr: *anyopaque, text: []const u8) platform.Services.Error!void {
        try cast(ptr).setClipboard(text);
    }

    fn serviceReadClipboard(ptr: *anyopaque, reply: platform.Reply) platform.Services.Error!void {
        try reply.send(cast(ptr).clipboard);
    }

    fn serviceQuit(ptr: *anyopaque) void {
        cast(ptr).quits += 1;
    }

    fn serviceClose(ptr: *anyopaque) void {
        cast(ptr).closes += 1;
    }

    pub fn backend(self: *NativeTree) native.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Receives events the tree reports by itself, from inside backend
    /// calls, as a toolkit's signals and delegates do.
    pub const Listener = struct {
        ctx: *anyopaque,
        report: *const fn (ctx: *anyopaque, id: native.Id, event: Event) anyerror!void,
    };

    fn emit(self: *NativeTree, id: native.Id, event: Event) void {
        const listener = self.listener orelse return;
        listener.report(listener.ctx, id, event) catch |err| {
            if (self.listener_error == null) self.listener_error = err;
        };
    }

    /// The widget made for the element with `id`, or null.
    pub fn find(self: *NativeTree, id: native.Id) ?*Widget {
        for (self.widgets.values()) |*widget| {
            if (widget.id == id) return widget;
        }
        return null;
    }

    /// The widgets in the order they were made.
    pub fn all(self: *NativeTree) []Widget {
        return self.widgets.values();
    }

    /// The focused widget, if a native one is.
    pub fn focusedWidget(self: *NativeTree) ?*Widget {
        return switch (self.focus) {
            .native => |handle| self.widgets.getPtr(handle),
            else => null,
        };
    }

    // What the user does. Each returns the event the toolkit would report,
    // for the caller to give `Runtime.nativeEvent`, or null if nothing
    // happens, as for a disabled control.

    /// A click: presses a button or menu item, flips a checkbox or switch,
    /// focuses a text field.
    pub fn click(self: *NativeTree, widget: *Widget) Allocator.Error!?Event {
        if (!widget.enabled()) return null;
        switch (widget.spec) {
            .button, .menu_item => return .activate,
            .checkbox, .@"switch" => {
                const on = !(widget.value == .toggle and widget.value.toggle);
                try widget.show(self.gpa, .{ .toggle = on });
                return .{ .toggle = on };
            },
            .text_field, .text_area, .search_field, .secure_field => {
                self.focus = .{ .native = widget.handle };
                return .{ .focus = true };
            },
            else => return null,
        }
    }

    /// An item of a dropdown or radio group chosen, by index.
    pub fn select(self: *NativeTree, widget: *Widget, index: usize) Allocator.Error!?Event {
        if (!widget.enabled()) return null;
        const items = switch (widget.spec) {
            .dropdown, .radio_group => |props| props.items,
            else => return null,
        };
        if (index >= items.len) return null;
        try widget.show(self.gpa, .{ .selection = index });
        return .{ .select = index };
    }

    /// A stepper stepped up (or down, for a negative `steps`), within its
    /// range, as clicking its arrows does.
    pub fn step(self: *NativeTree, widget: *Widget, steps: i32) Allocator.Error!?Event {
        if (!widget.enabled() or widget.spec != .stepper) return null;
        const props = widget.spec.stepper;
        const current = if (widget.value == .number) widget.value.number else props.min;
        const stepped = std.math.clamp(current + props.step * @as(f64, @floatFromInt(steps)), props.min, props.max);
        try widget.show(self.gpa, .{ .number = stepped });
        return .{ .number = stepped };
    }

    /// Text inserted at the end of a field, as one keystroke.
    pub fn insert(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (!widget.enabled() or !widget.spec.isTextInput()) return null;
        const old = if (widget.value == .text) widget.value.text else "";
        const joined = try std.mem.concat(self.gpa, u8, &.{ old, text });
        defer self.gpa.free(joined);
        try widget.show(self.gpa, .{ .text = joined });
        return .{ .text = widget.value.text };
    }

    /// A field's whole text replaced, as by pasting over a selection.
    pub fn replace(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (!widget.enabled() or !widget.spec.isTextInput()) return null;
        try widget.show(self.gpa, .{ .text = text });
        return .{ .text = widget.value.text };
    }

    /// An IME pre-edit: `marked` shows after the text, uncommitted, and is
    /// not reported.
    pub fn compose(self: *NativeTree, widget: *Widget, marked: []const u8) Allocator.Error!void {
        std.debug.assert(widget.spec.isTextInput());
        const copy = try self.gpa.dupe(u8, marked);
        if (widget.marked) |old| self.gpa.free(old);
        widget.marked = copy;
    }

    /// Ends a composition by committing `text` in place of the pre-edit.
    /// Returns the text event; the caller then reports `composition_end`.
    pub fn commit(self: *NativeTree, widget: *Widget, text: []const u8) Allocator.Error!?Event {
        if (widget.marked) |old| self.gpa.free(old);
        widget.marked = null;
        return self.insert(widget, text);
    }

    /// A scroll view scrolled so that `offset` of its content is at its
    /// top left, kept within its content as the toolkit keeps it.
    pub fn scroll(self: *NativeTree, widget: *Widget, offset: fabrum.Vec2) ?Event {
        _ = self;
        if (widget.spec != .scroll_view) return null;
        const view = widget.frame orelse return null;
        const content = widget.content_size orelse return null;
        const s = widget.spec.scroll_view;
        widget.scroll = .init(
            if (s.horizontal) std.math.clamp(offset.x, 0, @max(content.x - view.w, 0)) else 0,
            if (s.vertical) std.math.clamp(offset.y, 0, @max(content.y - view.h, 0)) else 0,
        );
        return .{ .scroll = widget.scroll };
    }

    /// The widgets inside the container `parent`, or in the host if null,
    /// in the order they were made.
    pub fn children(self: *NativeTree, gpa: Allocator, parent: ?native.Handle) Allocator.Error![]*Widget {
        var out: std.ArrayList(*Widget) = .empty;
        for (self.widgets.values()) |*widget| {
            if (widget.parent == parent) try out.append(gpa, widget);
        }
        return out.toOwnedSlice(gpa);
    }

    /// A slider dragged to `number`, clamped to its range.
    pub fn slide(self: *NativeTree, widget: *Widget, number: f64) Allocator.Error!?Event {
        if (!widget.enabled() or widget.spec != .slider) return null;
        const clamped = std.math.clamp(number, widget.spec.slider.min, widget.spec.slider.max);
        try widget.show(self.gpa, .{ .number = clamped });
        return .{ .number = clamped };
    }

    const vtable: native.Backend.VTable = .{
        .create = vtCreate,
        .update = vtUpdate,
        .destroy = vtDestroy,
        .setFrame = vtSetFrame,
        .setContentSize = vtSetContentSize,
        .measure = vtMeasure,
        .setValue = vtSetValue,
        .composing = vtComposing,
        .canFocus = vtCanFocus,
        .focus = vtFocus,
        .present = vtPresent,
        .theme = vtTheme,
        .reparent = vtReparent,
    };

    fn cast(ptr: *anyopaque) *NativeTree {
        return @ptrCast(@alignCast(ptr));
    }

    fn get(self: *NativeTree, handle: native.Handle) *Widget {
        return self.widgets.getPtr(handle) orelse std.debug.panic("app.testing.NativeTree: no widget {d}", .{@backingInt(handle)});
    }

    fn vtCreate(ptr: *anyopaque, id: native.Id, spec: *const Spec, value: *const Value, parent: ?native.Handle) native.Backend.Error!native.Handle {
        const self = cast(ptr);
        if (parent) |p| std.debug.assert(self.get(p).spec.isContainer());
        const handle: native.Handle = @fromBackingInt(@intCast(self.next_handle));
        const owned_spec = try spec.clone(self.gpa);
        errdefer owned_spec.free(self.gpa);
        const owned_value = try value.clone(self.gpa);
        errdefer owned_value.free(self.gpa);
        try self.widgets.put(self.gpa, handle, .{ .id = id, .handle = handle, .spec = owned_spec, .value = owned_value, .parent = parent });
        self.next_handle += 1;
        return handle;
    }

    fn vtUpdate(ptr: *anyopaque, handle: native.Handle, old: *const Spec, new: *const Spec) void {
        _ = old;
        const self = cast(ptr);
        const widget = self.get(handle);
        const copy = new.clone(self.gpa) catch @panic("app.testing.NativeTree: out of memory");
        widget.spec.free(self.gpa);
        widget.spec = copy;
        widget.updates += 1;
    }

    fn vtDestroy(ptr: *anyopaque, handle: native.Handle) void {
        const self = cast(ptr);
        // what is inside a container goes first, as toolkits need
        for (self.widgets.values()) |widget| {
            if (widget.parent == handle) std.debug.panic("app.testing.NativeTree: container {d} destroyed before its child {d}", .{ @backingInt(handle), @backingInt(widget.handle) });
        }
        var removed = (self.widgets.fetchOrderedRemove(handle) orelse return).value;
        if (self.focus == .native and self.focus.native == handle) self.focus = .none;
        removed.deinit(self.gpa);
    }

    fn vtSetFrame(ptr: *anyopaque, handle: native.Handle, frame: Rect) void {
        const widget = cast(ptr).get(handle);
        widget.frame = frame;
        widget.frames += 1;
    }

    fn vtSetContentSize(ptr: *anyopaque, handle: native.Handle, size: fabrum.Vec2) void {
        const widget = cast(ptr).get(handle);
        widget.content_size = size;
    }

    fn vtMeasure(ptr: *anyopaque, handle: native.Handle, constraints: layout.Constraints) Vec2 {
        return cast(ptr).get(handle).fittingSize(constraints);
    }

    fn vtSetValue(ptr: *anyopaque, handle: native.Handle, value: *const Value) void {
        const self = cast(ptr);
        const widget = self.get(handle);
        widget.show(self.gpa, value.*) catch @panic("app.testing.NativeTree: out of memory");
        widget.writes += 1;
        if (self.report_writes) switch (widget.value) {
            .none => {},
            .toggle => |on| self.emit(widget.id, .{ .toggle = on }),
            .number => |n| self.emit(widget.id, .{ .number = n }),
            .text => |t| self.emit(widget.id, .{ .text = t }),
            .selection => |i| if (i) |index| self.emit(widget.id, .{ .select = index }),
        };
    }

    fn vtComposing(ptr: *anyopaque, handle: native.Handle) bool {
        return cast(ptr).get(handle).marked != null;
    }

    fn vtCanFocus(ptr: *anyopaque, handle: native.Handle) bool {
        const self = cast(ptr);
        const widget = self.get(handle);
        if (!widget.enabled()) return false;
        return switch (widget.spec) {
            .text_field, .text_area, .search_field, .secure_field => true,
            .button, .checkbox, .@"switch", .slider, .dropdown, .radio_group, .stepper => self.full_keyboard_access,
            else => false,
        };
    }

    fn vtFocus(ptr: *anyopaque, target: native.FocusTarget) void {
        const self = cast(ptr);
        self.focus = target;
        if (self.report_focus and target == .native) self.emit(self.get(target.native).id, .{ .focus = true });
    }

    fn vtPresent(ptr: *anyopaque, scene: *const native.Scene) void {
        const self = cast(ptr);
        self.scene = scene.*;
        self.presents += 1;
    }

    fn vtReparent(ptr: *anyopaque, handle: native.Handle, parent: ?native.Handle) void {
        const self = cast(ptr);
        if (parent) |p| std.debug.assert(self.get(p).spec.isContainer());
        const widget = self.get(handle);
        widget.parent = parent;
        widget.frame = null;
        widget.reparents += 1;
    }

    fn vtTheme(ptr: *anyopaque) native.Theme {
        const self = cast(ptr);
        var look = self.look;
        look.full_keyboard_access = self.full_keyboard_access;
        return look;
    }
};

/// One native widget, as data.
pub const Widget = struct {
    /// The element it was made for.
    id: native.Id,
    handle: native.Handle,
    /// Its props, as last created or updated.
    spec: Spec,
    /// What it shows: a checkbox's state, a slider's position, a field's
    /// committed text.
    value: Value,
    /// Text being composed after `value`, if any.
    marked: ?[]u8 = null,
    /// The container it is in, or null for the host.
    parent: ?native.Handle = null,
    /// In its parent, from the top left (a container's content's, inside
    /// one); null until laid out.
    frame: ?Rect = null,
    /// For containers: the size of the content, and where it is scrolled
    /// to.
    content_size: ?fabrum.Vec2 = null,
    scroll: fabrum.Vec2 = .zero,
    /// How many times fabrum changed its props, wrote its value, moved
    /// it, and moved it to another parent.
    updates: usize = 0,
    writes: usize = 0,
    frames: usize = 0,
    reparents: usize = 0,

    fn deinit(self: *Widget, gpa: Allocator) void {
        self.spec.free(gpa);
        self.value.free(gpa);
        if (self.marked) |marked| gpa.free(marked);
    }

    fn show(self: *Widget, gpa: Allocator, value: Value) Allocator.Error!void {
        const copy = try value.clone(gpa);
        self.value.free(gpa);
        self.value = copy;
    }

    pub fn enabled(self: *const Widget) bool {
        return self.spec.enabled();
    }

    /// The text a field shows, including any pre-edit; "" for others.
    pub fn text(self: *const Widget, buffer: []u8) []const u8 {
        const committed = if (self.value == .text) self.value.text else "";
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ committed, self.marked orelse "" }) catch committed;
    }

    /// Sizes close to AppKit's regular controls in the system font. A
    /// label wraps within `constraints.max_width`, as a native one does.
    fn fittingSize(self: *const Widget, constraints: layout.Constraints) Vec2 {
        const char: f32 = 7;
        const line: f32 = 16;
        return switch (self.spec) {
            .button => |b| .init(@max(char * @as(f32, @floatFromInt(b.title.len)) + 28, 64), 22),
            .checkbox => |c| .init(if (c.title.len == 0) 18 else 22 + char * @as(f32, @floatFromInt(c.title.len)), 18),
            .@"switch" => .init(38, 22),
            .slider => .init(96, 20),
            .text_field, .search_field, .secure_field => .init(96, 22),
            // three lines of text by default; the app bounds it
            .text_area => .init(96, 3 * line + 8),
            .progress => .init(96, 20),
            .spinner => |sp| .init(if (sp.size == .small) 16 else 32, if (sp.size == .small) 16 else 32),
            .dropdown => |d| .init(widest(d.items, char) + 36, 22),
            .radio_group => |g| if (g.horizontal)
                .init(@as(f32, @floatFromInt(g.items.len)) * (widest(g.items, char) + 30), 18)
            else
                .init(widest(g.items, char) + 22, @as(f32, @floatFromInt(g.items.len)) * line + 2 * @as(f32, @floatFromInt(g.items.len -| 1))),
            .stepper => .init(60 + 4 + 19, 22),
            .label => |l| label: {
                const natural = char * @as(f32, @floatFromInt(l.text.len));
                const size = l.font_size orelse 13;
                const height = line * size / 13;
                const limit = constraints.max_width orelse break :label .init(natural, height);
                if (natural <= limit) break :label .init(natural, height);
                // one line is cut with an ellipsis at the limit
                if (!l.wrap) break :label .init(limit, height);
                const lines = @ceil(natural / @max(limit, char));
                break :label .init(limit, lines * height);
            },
            .menu_item, .alert, .scroll_view => .zero,
            .extension => .init(64, 22),
        };
    }

    fn widest(items: []const []const u8, char: f32) f32 {
        var longest: usize = 0;
        for (items) |item| longest = @max(longest, item.len);
        return char * @as(f32, @floatFromInt(longest));
    }
};
