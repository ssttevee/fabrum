//! Desktop integration: native messages, controlled reconciliation and teardown.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.win32;
const Hwnd = *anyopaque;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Header = extern struct { hwnd: Hwnd, id: usize, code: u32 };
const UpDown = extern struct { header: Header, position: i32, delta: i32 };
extern "user32" fn GetWindow(Hwnd, u32) callconv(.winapi) ?Hwnd;
extern "user32" fn GetParent(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn GetClassNameW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn GetWindowTextW(Hwnd, [*]u16, c_int) callconv(.winapi) c_int;
extern "user32" fn IsWindowVisible(Hwnd) callconv(.winapi) c_int;
extern "user32" fn EnumThreadWindows(u32, *const fn (Hwnd, isize) callconv(.winapi) c_int, isize) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "user32" fn GetWindowRect(Hwnd, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetDlgCtrlID(Hwnd) callconv(.winapi) c_int;
extern "user32" fn GetDlgItem(Hwnd, c_int) callconv(.winapi) ?Hwnd;
extern "user32" fn IsWindow(Hwnd) callconv(.winapi) c_int;
extern "user32" fn IsWindowEnabled(Hwnd) callconv(.winapi) c_int;
extern "user32" fn SetFocus(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn GetFocus() callconv(.winapi) ?Hwnd;
extern "user32" fn SendMessageW(Hwnd, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PostMessageW(Hwnd, u32, usize, isize) callconv(.winapi) c_int;
extern "user32" fn GetMenu(Hwnd) callconv(.winapi) ?Hwnd;
extern "user32" fn GetSubMenu(Hwnd, c_int) callconv(.winapi) ?Hwnd;
extern "user32" fn GetMenuItemCount(Hwnd) callconv(.winapi) c_int;
extern "user32" fn GetMenuItemID(Hwnd, c_int) callconv(.winapi) u32;
extern "user32" fn GetMenuState(Hwnd, u32, u32) callconv(.winapi) u32;
extern "user32" fn GetMenuStringW(Hwnd, u32, [*]u16, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) c_int;
extern "user32" fn SetKeyboardState(*const [256]u8) callconv(.winapi) c_int;
fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        std.debug.print("native-win32-controls FAIL: {s}\n", .{message});
        std.debug.print("phase={d} scenario={d} selections={d} numbers={d} menus={d} answers={d}\n", .{ diagnostics.phase.load(.acquire), diagnostics.scenario.load(.acquire), diagnostics.selections.load(.acquire), diagnostics.numbers.load(.acquire), diagnostics.menus.load(.acquire), observed_answers.load(.acquire) });
        std.process.exit(1);
    }
}
fn classIs(hwnd: Hwnd, name: []const u8) bool {
    var buffer: [128]u16 = undefined;
    const n = GetClassNameW(hwnd, &buffer, buffer.len);
    if (n != name.len) return false;
    for (name, buffer[0..name.len]) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(@as(u8, @truncate(b)))) return false;
    return true;
}
fn child(parent: Hwnd, name: []const u8, index: usize) ?Hwnd {
    var next = GetWindow(parent, 5); // GW_CHILD
    var found: usize = 0;
    while (next) |hwnd| : (next = GetWindow(hwnd, 2)) {
        if (!classIs(hwnd, name)) continue;
        if (found == index) return hwnd;
        found += 1;
    }
    return null;
}
fn rect(hwnd: Hwnd) Rect {
    var result: Rect = undefined;
    check(GetWindowRect(hwnd, &result) != 0, "control geometry available");
    return result;
}
var observed_answers: std.atomic.Value(usize) = .init(0);
var diagnostics: struct {
    phase: std.atomic.Value(u8) = .init(0),
    scenario: std.atomic.Value(u8) = .init(0),
    selections: std.atomic.Value(usize) = .init(0),
    numbers: std.atomic.Value(usize) = .init(0),
    menus: std.atomic.Value(usize) = .init(0),
} = .{};
const ResponseExit = enum { none, close, quit };
var response_exit: ResponseExit = .none;
var modal_stack = false;
const Root = struct {
    pub const Props = struct {};
    pub const State = struct {
        scenario: u8 = 0,
        selected: ?usize = null,
        number: f64 = 0.25,
        selections: usize = 0,
        numbers: usize = 0,
        menus: usize = 0,
        answers: usize = 0,
        answer: usize = 99,
        stepper_enabled: bool = true,
    };
    pub const Msg = union(enum) { scenario: u8, stepper_enabled: bool, selected: usize, number: f64, menu, answer: usize, quit };
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .scenario => |n| {
                state.scenario = n;
                // Explicit independent starting values for each input regression.
                state.selected = if (n == 1) 2 else null;
                state.number = if (n == 13) 1 else if (n == 3) -0.5 else 0.25;
                state.stepper_enabled = true;
            },
            .stepper_enabled => |enabled| state.stepper_enabled = enabled,
            .selected => |n| {
                state.selections += 1;
                diagnostics.selections.store(state.selections, .release);
                if (state.scenario != 1) state.selected = n;
            },
            .number => |n| {
                state.numbers += 1;
                diagnostics.numbers.store(state.numbers, .release);
                state.number = n;
            },
            .menu => {
                state.menus += 1;
                diagnostics.menus.store(state.menus, .release);
            },
            .answer => |n| {
                state.answers += 1;
                observed_answers.store(state.answers, .release);
                state.answer = n;
                if (state.scenario == 15) state.scenario = 16;
                if (state.scenario == 14) switch (response_exit) {
                    .none => unreachable,
                    .close => try ctx.close(),
                    .quit => try ctx.quit(),
                };
            },
            .quit => try ctx.quit(),
        }
    }
    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Root);
        try ui.open("root", .{ .layout = .{ .axis = .y, .padding = .all(16), .child_gap = 12, .sizing = .grow(.{}) } });
        defer ui.close();
        if (state.scenario < 7 or state.scenario == 13) {
            try app.widgets.radioGroup(ui, "radio", .{
                .items = if (state.scenario >= 2) &.{ "Updated A", "Updated B" } else &.{ "One", "Two", "Three" },
                .selected = state.selected,
                .horizontal = state.scenario >= 2,
                .enabled = state.scenario != 4,
                .on_select = on.handler(.selected),
                .sizing = .fixedXY(300, 96),
            });
            try app.widgets.stepper(ui, "stepper", .{
                .value = state.number,
                .min = if (state.scenario == 3) -0.5 else 0,
                .max = if (state.scenario == 13) 10 else if (state.scenario == 3) 0.5 else 1,
                .step = if (state.scenario == 13) 0.5 else if (state.scenario == 3) 0.125 else 0.25,
                .enabled = state.scenario != 4 and state.stepper_enabled,
                .on_change = on.handler(.number),
                .sizing = .fixedXY(160, 32),
            });
        }
        if ((state.scenario >= 7 and state.scenario <= 12) or state.scenario >= 14)
            try app.widgets.textField(ui, "alert-focus", .{ .text = "Alert focus anchor", .sizing = .fixedXY(240, 32) });
        if (state.scenario < 6) {
            try ui.native("menu-a", .{ .spec = .{ .menu_item = .{ .menu = if (state.scenario == 5) "Changed" else "Actions", .title = "First", .key = "k", .enabled = state.scenario != 4 } }, .handlers = .{ .on_activate = on.bind(.menu) } });
            try ui.native("menu-b", .{ .spec = .{ .menu_item = .{ .menu = "Actions", .title = "Second" } }, .handlers = .{ .on_activate = on.bind(.menu) } });
            try ui.native("menu-c", .{ .spec = .{ .menu_item = .{ .menu = "Other", .title = "Third" } }, .handlers = .{ .on_activate = on.bind(.menu) } });
        }
        if (state.scenario == 8 or state.scenario == 10 or state.scenario == 12 or state.scenario == 14 or state.scenario == 15)
            try ui.native("alert", .{ .spec = .{ .alert = .{ .title = "Controls declared alert", .message = "Choose a response", .buttons = &.{ "Accept", "Cancel" } } }, .handlers = .{ .on_response = on.handler(.answer) } });
        // Add each declaration in a separate frame so A, B, C is the actual
        // modal presentation order, independent of reconciler map iteration.
        if (state.scenario >= 21 and state.scenario <= 23)
            try ui.native("stack-a", .{ .spec = .{ .alert = .{ .title = "Controls stack A" } }, .handlers = .{ .on_response = on.handler(.answer) } });
        if (state.scenario >= 22 and state.scenario <= 25)
            try ui.native("stack-b", .{ .spec = .{ .alert = .{ .title = "Controls stack B" } }, .handlers = .{ .on_response = on.handler(.answer) } });
        if (state.scenario >= 23 and state.scenario <= 24)
            try ui.native("stack-c", .{ .spec = .{ .alert = .{ .title = "Controls stack C" } }, .handlers = .{ .on_response = on.handler(.answer) } });
    }
};
const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    phase: u8 = 0,
    observed_phase: std.atomic.Value(u8) = .init(0),
    saved_keys: [256]u8 = undefined,
    radio: Hwnd = undefined,
    spin: Hwnd = undefined,
    stale_menu: u32 = 0,
    alert_hwnd: ?Hwnd = null,
    quiet_ticks: u8 = 0,
    expected_numbers: usize = 0,
    typed_field: ?Hwnd = null,
    alert_focus: ?Hwnd = null,
    stack: [3]Hwnd = undefined,
    fn handle(self: *Probe, key: []const u8) ?app.native.Handle {
        return self.gui.handleOf(app.testing.rootInstance(Root).native(key));
    }
    fn hwnd(self: *Probe, key: []const u8) ?Hwnd {
        return platform.automation.widgetHwnd(self.handle(key) orelse return null);
    }
    fn scenario(self: *Probe, n: u8) void {
        self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, .scenario), n) catch @panic("scenario");
    }
    fn enableStepper(self: *Probe, enabled: bool) void {
        self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, .stepper_enabled), enabled) catch @panic("stepper enabled");
    }
    fn typeNumber(self: *Probe, text: []const u8) void {
        const field = self.typed_field.?;
        _ = SetFocus(field);
        check(GetFocus() == field, "stepper edit accepts focus for typing");
        _ = SendMessageW(field, 0x00b1, 0, -1); // EM_SETSEL: replace all
        for (text) |c| _ = SendMessageW(field, 0x0102, c, 0); // WM_CHAR
    }
    fn radioButton(self: *Probe, n: usize) Hwnd {
        return GetDlgItem(self.hwnd("radio").?, @intCast(100 + n)) orelse @panic("missing radio button HWND");
    }
    fn checkRadio(self: *Probe, count: usize, selected: ?usize) void {
        for (0..count) |i| {
            const checked = SendMessageW(self.radioButton(i), 0x00f0, 0, 0);
            if (checked != @as(isize, if (selected == i) 1 else 0)) {
                std.debug.print("radio phase={d} item={d} checked={d} expected={?d}\n", .{ self.phase, i, checked, selected });
                check(false, "native radio check state matches controlled selection");
            }
        }
        check(child(self.hwnd("radio").?, "Button", count) == null, "radio item count matches updated list");
    }
    fn checkNumber(self: *Probe, expected: f64) void {
        const field = child(self.hwnd("stepper").?, "Edit", 0) orelse @panic("missing stepper field");
        var wide: [128]u16 = undefined;
        const n = GetWindowTextW(field, &wide, wide.len);
        check(n > 0 and n < wide.len, "stepper field contains a number");
        var bytes: [128]u8 = undefined;
        for (wide[0..@intCast(n)], 0..) |c, i| {
            check(c < 128, "stepper numeric field uses ASCII digits");
            bytes[i] = @intCast(c);
        }
        const number = std.fmt.parseFloat(f64, bytes[0..@intCast(n)]) catch @panic("invalid stepper field number");
        check(@abs(number - expected) < 0.000001, "native stepper field reflects controlled number");
    }
    const AlertSearch = struct { owner: Hwnd, title: ?[]const u8 = null, found: ?Hwnd = null };
    fn findAlert(dialog_hwnd: Hwnd, context: isize) callconv(.winapi) c_int {
        const search: *AlertSearch = @ptrFromInt(@as(usize, @bitCast(context)));
        if (GetWindow(dialog_hwnd, 4) == search.owner and classIs(dialog_hwnd, "FabrumDialog") and IsWindowVisible(dialog_hwnd) != 0) {
            if (search.title) |title| {
                var buffer: [128]u16 = undefined;
                const n = GetWindowTextW(dialog_hwnd, &buffer, buffer.len);
                if (n != title.len) return 1;
                for (title, buffer[0..title.len]) |a, b| if (a != b) return 1;
            }
            check(search.found == null, "only one declared dialog is live");
            search.found = dialog_hwnd;
        }
        return 1;
    }
    fn alert(self: *Probe) ?Hwnd {
        var search: AlertSearch = .{ .owner = self.gui.hwnd() };
        _ = EnumThreadWindows(GetCurrentThreadId(), findAlert, @bitCast(@intFromPtr(&search)));
        return search.found;
    }
    fn stackDialog(self: *Probe, title: []const u8) ?Hwnd {
        var search: AlertSearch = .{ .owner = self.gui.hwnd(), .title = title };
        _ = EnumThreadWindows(GetCurrentThreadId(), findAlert, @bitCast(@intFromPtr(&search)));
        return search.found;
    }
    fn checkStack(self: *Probe, active: usize, first_live: usize, last_live: usize) void {
        check(IsWindowEnabled(self.gui.hwnd()) == 0, "modal stack keeps owner disabled");
        for (self.stack, 0..) |dialog, i| {
            if (i < first_live or i > last_live) continue;
            check(IsWindow(dialog) != 0, "remaining modal dialog HWND is live");
            check((IsWindowEnabled(dialog) != 0) == (i == active), "only the top remaining modal dialog is enabled");
        }
        check(GetFocus() == GetDlgItem(self.stack[active], 100), "top remaining modal retains default-button focus");
    }
    fn delta(self: *Probe, amount: i32) void {
        const container = self.hwnd("stepper").?;
        const spin = child(container, "msctls_updown32", 0) orelse @panic("missing updown HWND");
        var notification: UpDown = .{ .header = .{ .hwnd = spin, .id = @intCast(GetDlgCtrlID(spin)), .code = @bitCast(@as(i32, -722)) }, .position = 0, .delta = amount };
        _ = SendMessageW(GetParent(spin).?, 0x004e, notification.header.id, @intCast(@intFromPtr(&notification)));
    }
    const Menu = struct { menu: Hwnd, id: u32 };
    fn menuItem(self: *Probe, group: []const u8, title: []const u8) ?Menu {
        const bar = GetMenu(self.gui.hwnd()) orelse return null;
        var i: c_int = 0;
        while (i < GetMenuItemCount(bar)) : (i += 1) {
            if (!menuTitle(bar, @intCast(i), group)) continue;
            const menu = GetSubMenu(bar, i) orelse return null;
            var j: c_int = 0;
            while (j < GetMenuItemCount(menu)) : (j += 1) {
                if (menuTitle(menu, @intCast(j), title)) return .{ .menu = menu, .id = GetMenuItemID(menu, j) };
            }
        }
        return null;
    }
    fn menuTitle(menu: Hwnd, index: u32, title: []const u8) bool {
        var buffer: [256]u16 = undefined;
        const n = GetMenuStringW(menu, index, &buffer, buffer.len, 0x400);
        if (n < title.len) return false;
        for (title, buffer[0..title.len]) |a, b| if (a != b) return false;
        return n == title.len or buffer[title.len] == '\t';
    }
    fn command(self: *Probe, id: u32) void {
        _ = SendMessageW(self.gui.hwnd(), 0x0111, id, 0);
    }
    fn queueMenuShortcut(self: *Probe) void {
        check(GetKeyboardState(&self.saved_keys) != 0, "save keyboard state");
        var keys = self.saved_keys;
        keys[0x11] = 0x80; // VK_CONTROL
        keys[0x10] = 0; // VK_SHIFT
        keys[0x12] = 0; // VK_MENU
        check(SetKeyboardState(&keys) != 0, "set shortcut modifier");
        const field = child(self.spin, "Edit", 0).?;
        if (IsWindowEnabled(field) != 0) _ = SetFocus(field);
        check(PostMessageW(field, 0x0100, 'K', 0) != 0, "queue native menu shortcut through edit control");
    }
    fn terminate(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        const response_case = response_exit != .none;
        check(self.phase == (if (modal_stack) @as(u8, 58) else if (response_case) @as(u8, 43) else 25), "termination before every controls phase completed");
        check(observed_answers.load(.acquire) == (if (modal_stack) @as(usize, 0) else if (response_case) @as(usize, 1) else 2), "response and teardown must deliver exactly the expected alert replies");
        if (!modal_stack) check(IsWindow(self.alert_hwnd.?) == 0, "window close destroys declared alert HWND");
        check(!self.done.swap(true, .acq_rel), "termination callback runs exactly once");
        std.debug.print("native-win32-controls ({s}) PASS\n", .{if (modal_stack) "modal-stack" else @tagName(response_exit)});
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire)) return;
        self.observed_phase.store(self.phase, .release);
        const s = self.gui.runtime.rootState(Root) orelse return;
        diagnostics.phase.store(self.phase, .release);
        diagnostics.scenario.store(s.scenario, .release);
        switch (self.phase) {
            0 => {
                self.radio = self.hwnd("radio") orelse return;
                self.spin = self.hwnd("stepper") orelse return;
                self.checkRadio(3, null);
                self.checkNumber(0.25);
                const a = rect(self.radioButton(0));
                const b = rect(self.radioButton(1));
                check(b.top > a.top, "initial radio layout is vertical");
                check(self.menuItem("Actions", "First") != null and self.menuItem("Actions", "Second") != null and self.menuItem("Other", "Third") != null, "native menu grouping");
                _ = SendMessageW(self.radioButton(1), 0x00f5, 0, 0); // BM_CLICK -> BN_CLICKED
                self.phase = 1;
            },
            1 => {
                if (s.selections == 0) return;
                check(s.selections == 1 and s.selected == 1, "native radio click emits exactly one selection");
                self.checkRadio(3, 1);
                self.scenario(1);
                self.phase = 2;
            },
            2 => {
                if (s.scenario != 1) return;
                self.checkRadio(3, 2);
                _ = SendMessageW(self.radioButton(0), 0x00f5, 0, 0);
                self.phase = 3;
            },
            3 => {
                if (s.selections != 2) return;
                check(s.selected == 2, "radio handler can reject proposed selection");
                self.checkRadio(3, 2);
                // Keep a surviving item focused while its label and siblings
                // are replaced. The native part itself may be recreated.
                _ = SetFocus(self.radioButton(1));
                check(GetFocus() == self.radioButton(1), "radio has focus before item replacement");
                self.scenario(2);
                self.phase = 4;
            },
            4 => {
                if (s.scenario != 2) return;
                check(self.hwnd("radio").? == self.radio, "radio update retains container");
                check(GetFocus() == self.radioButton(1), "radio replacement restores focus to corresponding native item");
                self.checkRadio(2, null);
                var title: [64]u16 = undefined;
                const title_len = GetWindowTextW(self.radioButton(0), &title, title.len);
                check(title_len == 9 and std.mem.eql(u16, title[0..9], std.unicode.utf8ToUtf16LeStringLiteral("Updated A")), "radio item update replaces native labels");
                const a = rect(self.radioButton(0));
                const b = rect(self.radioButton(1));
                check(b.left > a.left and b.top == a.top, "orientation update lays radios horizontally");
                _ = SetFocus(self.radioButton(0));
                check(GetFocus() == self.radioButton(0), "radio accepts keyboard focus");
                _ = SendMessageW(self.radioButton(0), 0x0100, 0x27, 0); // Right
                self.phase = 5;
            },
            5 => {
                check(s.selections <= 3, "radio Right must not emit duplicate selection callbacks");
                if (s.selections != 3) return;
                check(s.selected == 1, "radio Right selects next item");
                self.checkRadio(2, 1);
                self.delta(-1);
                self.phase = 6;
            },
            6 => {
                if (s.numbers == 0) return;
                check(s.numbers == 1 and s.number == 0.5, "UDN_DELTAPOS increments fractional step");
                self.checkNumber(0.5);
                self.delta(20);
                self.phase = 7;
            },
            7 => {
                if (s.numbers != 2) return;
                check(s.number == 0, "large native decrement clamps to minimum");
                self.checkNumber(0);
                self.delta(-20);
                self.phase = 8;
            },
            8 => {
                if (s.numbers != 3) return;
                check(s.number == 1, "large native increment clamps to maximum");
                self.checkNumber(1);
                self.scenario(3);
                self.phase = 9;
            },
            9 => {
                if (s.scenario != 3) return;
                check(self.hwnd("stepper").? == self.spin, "stepper range update retains container");
                self.checkNumber(-0.5);
                self.delta(-1);
                self.phase = 10;
            },
            10 => {
                if (s.numbers != 4) return;
                check(s.number == -0.375, "updated negative range and fractional step apply to real notification");
                self.checkNumber(-0.375);
                self.scenario(4);
                self.phase = 11;
            },
            11 => {
                if (s.scenario != 4) return;
                check(IsWindowEnabled(self.radioButton(0)) == 0 and IsWindowEnabled(child(self.spin, "msctls_updown32", 0).?) == 0, "disabled state propagates to interactive children");
                const item = self.menuItem("Actions", "First").?;
                check(GetMenuState(item.menu, item.id, 0) & 3 != 0, "disabled menu state is native");
                self.command(item.id);
                self.delta(-1);
                _ = SendMessageW(self.radioButton(0), 0x00f5, 0, 0);
                self.queueMenuShortcut();
                self.phase = 12;
            },
            12 => {
                check(SetKeyboardState(&self.saved_keys) != 0, "restore keyboard state");
                check(s.menus == 0 and s.numbers == 4 and s.selections == 3, "disabled controls ignore native notifications and Ctrl+K");
                self.scenario(5);
                self.phase = 13;
            },
            13 => {
                if (s.scenario != 5) return;
                check(IsWindowEnabled(self.radioButton(0)) != 0 and IsWindowEnabled(child(self.spin, "msctls_updown32", 0).?) != 0, "interactive children reenabled after update");
                self.checkNumber(0.25);
                check(self.menuItem("Actions", "First") == null, "moving menu item removes old group entry");
                const item = self.menuItem("Changed", "First").?;
                check(GetMenuState(item.menu, item.id, 0) & 3 == 0, "menu reenabled after update");
                self.stale_menu = item.id;
                self.command(item.id);
                self.phase = 14;
            },
            14 => {
                if (s.menus != 1) return;
                self.queueMenuShortcut();
                self.phase = 15;
            },
            15 => {
                check(SetKeyboardState(&self.saved_keys) != 0, "restore keyboard state");
                check(s.menus == 2, "Ctrl+K dispatches enabled menu shortcut once");
                self.scenario(6);
                self.phase = 16;
            },
            16 => {
                if (s.scenario != 6) return;
                check(self.menuItem("Changed", "First") == null and self.menuItem("Actions", "Second") == null and self.menuItem("Other", "Third") == null, "removed menu entries disappear");
                self.command(self.stale_menu);
                self.queueMenuShortcut();
                self.phase = 17;
            },
            17 => {
                check(SetKeyboardState(&self.saved_keys) != 0, "restore keyboard state");
                check(s.menus == 2, "removed menu command and Ctrl+K cannot invoke stale handler");
                self.scenario(13);
                self.phase = 27;
            },
            27 => {
                if (s.scenario != 13) return;
                self.checkNumber(1);
                self.expected_numbers = s.numbers;
                self.typed_field = child(self.spin, "Edit", 0).?;
                self.typeNumber("2.5");
                self.checkNumber(2.5);
                check(s.number == 1 and s.numbers == self.expected_numbers, "typing leaves an uncommitted fractional draft");
                self.enableStepper(false);
                self.phase = 28;
            },
            28 => {
                if (s.stepper_enabled) return;
                check(child(self.spin, "Edit", 0) == self.typed_field, "enabled update retains stepper edit HWND");
                check(IsWindowEnabled(self.typed_field.?) == 0, "stepper edit disabled by spec-only update");
                self.checkNumber(2.5);
                // Native disabling may transfer focus and commit the draft.
                // Either way, it must preserve the text and never commit twice.
                check(s.numbers <= self.expected_numbers + 1, "disabling commits a pending edit at most once");
                check(if (s.numbers == self.expected_numbers) s.number == 1 else s.number == 2.5, "enabled-only update preserves draft or its focus-loss commit");
                self.enableStepper(true);
                self.phase = 29;
            },
            29 => {
                if (!s.stepper_enabled) return;
                check(IsWindowEnabled(self.typed_field.?) != 0, "stepper edit reenabled");
                self.checkNumber(2.5);
                check(s.numbers <= self.expected_numbers + 1, "reenabling does not duplicate draft commit");
                _ = SetFocus(self.typed_field.?);
                check(GetFocus() == self.typed_field.?, "reenabled edit regains native focus");
                self.expected_numbers = s.numbers + 1;
                _ = SendMessageW(self.typed_field.?, 0x0100, 0x26, 0); // Up, using draft 2.5 + 0.5
                self.phase = 30;
            },
            30 => {
                check(s.numbers <= self.expected_numbers, "Up emits one final numeric value, without a duplicate draft commit");
                if (s.numbers < self.expected_numbers) return;
                check(s.number == 3, "Up starts from typed fractional value rather than previous controlled value");
                self.checkNumber(3);
                self.typeNumber("3.5");
                check(s.numbers == self.expected_numbers, "second typed draft remains uncommitted");
                self.expected_numbers += 1;
                _ = SendMessageW(self.typed_field.?, 0x0100, 0x0d, 0); // Return commits once
                self.phase = 31;
            },
            31 => {
                check(s.numbers <= self.expected_numbers, "Return commits edited stepper value exactly once");
                if (s.numbers < self.expected_numbers) return;
                check(s.number == 3.5, "Return delivers typed fractional number");
                self.checkNumber(3.5);
                _ = SendMessageW(self.typed_field.?, 0x0100, 0x0d, 0);
                _ = SetFocus(self.radioButton(0)); // WM_KILLFOCUS / EN_KILLFOCUS must not repeat the commit
                self.quiet_ticks = 0;
                self.phase = 32;
            },
            32 => {
                check(s.numbers == self.expected_numbers, "repeated Return and focus loss do not duplicate completed commit");
                if (self.quiet_ticks < 3) {
                    self.quiet_ticks += 1;
                    return;
                }
                self.quiet_ticks = 0;
                self.scenario(7);
                self.phase = 18;
            },
            18 => {
                if (s.scenario != 7) return;
                check(self.handle("radio") == null and self.handle("stepper") == null, "removed controls leave reconciler");
                check(IsWindow(self.radio) == 0 and IsWindow(self.spin) == 0, "removed control HWNDs destroyed");
                self.alert_focus = self.hwnd("alert-focus") orelse return;
                _ = SetFocus(self.alert_focus.?);
                check(GetFocus() == self.alert_focus.?, "native field focused before declared alert opens");
                self.scenario(8);
                self.phase = 19;
            },
            19 => {
                if (s.scenario != 8 or self.handle("alert") == null) return;
                const dialog = self.alert() orelse return;
                check(IsWindowEnabled(self.gui.hwnd()) == 0, "declared alert disables owner while live");
                self.alert_hwnd = dialog;
                _ = SendMessageW(GetDlgItem(dialog, 101).?, 0x00f5, 0, 0);
                self.phase = 20;
            },
            20 => {
                if (s.answers == 0) return;
                check(s.answers == 1 and s.answer == 1, "declared alert delivers selected button index once");
                check(IsWindow(self.alert_hwnd.?) == 0 and self.alert() == null, "answered alert closes native dialog");
                check(IsWindowEnabled(self.gui.hwnd()) != 0, "answer restores owner enabled state");
                // Restoring a native field produces synchronous native focus
                // events. Completion must survive that runtime reentry and
                // still deliver its response exactly once.
                check(GetFocus() == self.alert_focus.?, "alert completion restores prior native focus through focus-event reentry");
                // Keep the same declaration alive; answering/rebuilding must not reopen it.
                self.gui.automation().answerAlert(0);
                self.scenario(8);
                self.phase = 26;
            },
            26 => {
                check(s.answers == 1 and self.alert() == null, "answered declaration stays dismissed after rebuild");
                if (self.quiet_ticks < 3) {
                    self.quiet_ticks += 1;
                    return;
                }
                self.quiet_ticks = 0;
                self.scenario(9);
                self.phase = 21;
            },
            21 => {
                if (s.scenario != 9 or self.handle("alert") != null) return;
                check(s.answers == 1, "answered declaration cannot reply twice");
                self.scenario(10);
                self.phase = 22;
            },
            22 => {
                if (s.scenario != 10 or self.handle("alert") == null) return;
                self.alert_hwnd = self.alert() orelse return;
                self.scenario(11); // remove an unanswered alert
                self.phase = 23;
            },
            23 => {
                if (s.scenario != 11 or self.handle("alert") != null) return;
                check(IsWindow(self.alert_hwnd.?) == 0 and self.alert() == null, "removal destroys unanswered native dialog");
                check(IsWindowEnabled(self.gui.hwnd()) != 0, "removal restores owner enabled state");
                check(GetFocus() == self.alert_focus.?, "unanswered alert removal restores prior native focus");
                self.gui.automation().answerAlert(0);
                if (self.quiet_ticks < 3) {
                    self.quiet_ticks += 1;
                    return;
                }
                check(s.answers == 1, "removed alert rejects stale answers");
                self.quiet_ticks = 0;
                self.scenario(15);
                self.phase = 33;
            },
            33 => {
                if (s.scenario != 15) return;
                self.alert_hwnd = self.alert() orelse return;
                self.phase = 34;
                _ = SendMessageW(GetDlgItem(self.alert_hwnd.?, 100).?, 0x00f5, 0, 0);
            },
            34 => {
                check(s.answers <= 2, "response-handler removal must not reply twice");
                if (s.answers < 2 or s.scenario != 16 or self.handle("alert") != null) return;
                check(s.answer == 0, "response handler received the selected index before removing declaration");
                check(IsWindow(self.alert_hwnd.?) == 0 and self.alert() == null, "response handler immediately removes declared alert safely");
                check(IsWindowEnabled(self.gui.hwnd()) != 0 and GetFocus() == self.alert_focus.?, "response-handler removal restores owner and prior native focus");
                if (self.quiet_ticks < 3) {
                    self.quiet_ticks += 1;
                    return;
                }
                self.scenario(12);
                self.phase = 24;
            },
            24 => {
                if (s.scenario != 12 or self.handle("alert") == null) return;
                self.alert_hwnd = self.alert() orelse return;
                self.phase = 25;
                _ = PostMessageW(self.gui.hwnd(), 0x0010, 0, 0); // close with an unanswered declared alert
            },
            // Separate process variants: the answer update itself closes or
            // quits the owner while native dialog completion is on the stack.
            40 => {
                self.scenario(16);
                self.phase = 41;
            },
            41 => {
                if (s.scenario != 16) return;
                self.alert_focus = self.hwnd("alert-focus") orelse return;
                _ = SetFocus(self.alert_focus.?);
                check(GetFocus() == self.alert_focus.?, "response-exit case starts with native field focused");
                self.scenario(14);
                self.phase = 42;
            },
            42 => {
                if (s.scenario != 14) return;
                self.alert_hwnd = self.alert() orelse return;
                self.phase = 43;
                _ = SendMessageW(GetDlgItem(self.alert_hwnd.?, 100).?, 0x00f5, 0, 0);
            },
            50 => {
                self.scenario(20);
                self.phase = 51;
            },
            51 => {
                if (s.scenario != 20) return;
                self.alert_focus = self.hwnd("alert-focus") orelse return;
                _ = SetFocus(self.alert_focus.?);
                check(GetFocus() == self.alert_focus.?, "modal-stack case starts with native owner field focused");
                self.scenario(21);
                self.phase = 52;
            },
            52 => {
                if (s.scenario != 21) return;
                self.stack[0] = self.stackDialog("Controls stack A") orelse return;
                // Initialize unused slots before passing the array to the
                // helper; only the declared prefix is checked in this phase.
                self.stack[1] = self.stack[0];
                self.stack[2] = self.stack[0];
                self.checkStack(0, 0, 0);
                self.scenario(22);
                self.phase = 53;
            },
            53 => {
                if (s.scenario != 22) return;
                self.stack[1] = self.stackDialog("Controls stack B") orelse return;
                self.checkStack(1, 0, 1);
                self.scenario(23);
                self.phase = 54;
            },
            54 => {
                if (s.scenario != 23) return;
                self.stack[2] = self.stackDialog("Controls stack C") orelse return;
                self.checkStack(2, 0, 2);
                self.scenario(24); // Remove covered A while C remains active.
                self.phase = 55;
            },
            55 => {
                if (s.scenario != 24 or self.handle("stack-a") != null) return;
                check(IsWindow(self.stack[0]) == 0, "covered first dialog is destroyed");
                self.checkStack(2, 1, 2);
                check(s.answers == 0, "removing covered dialog produces no fabricated response");
                self.scenario(25); // Remove C; B must be the sole enabled modal.
                self.phase = 56;
            },
            56 => {
                if (s.scenario != 25 or self.handle("stack-c") != null) return;
                check(IsWindow(self.stack[2]) == 0, "top dialog removal destroys C");
                self.checkStack(1, 1, 1);
                check(s.answers == 0, "removing top dialog produces no fabricated response");
                self.scenario(26);
                self.phase = 57;
            },
            57 => {
                if (s.scenario != 26 or self.handle("stack-b") != null) return;
                check(IsWindow(self.stack[1]) == 0, "last dialog removal destroys B");
                check(IsWindowEnabled(self.gui.hwnd()) != 0, "removing last modal restores owner");
                check(GetFocus() == self.alert_focus.?, "removing last modal restores original owner focus");
                check(s.answers == 0, "modal removals deliver no stale replies");
                self.phase = 58;
                self.gui.runtime.post(app.testing.rootInstance(Root).handler(Root, .quit), {}) catch @panic("stack quit");
            },
            else => {},
        }
    }
    fn timer(self: *Probe) void {
        for (0..600) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            // Keep the watchdog alive after teardown: returning from the
            // termination callback is insufficient if the native loop hangs.
            if (!self.done.load(.acquire) and !self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }

        std.debug.print("controls watchdog expired in phase {d}\n", .{self.observed_phase.load(.acquire)});
        check(false, "watchdog expired before completion");
    }
};
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    _ = args.next();
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--modal-stack")) {
            modal_stack = true;
        } else {
            response_exit = if (std.mem.eql(u8, arg, "--response-close")) .close else if (std.mem.eql(u8, arg, "--response-quit")) .quit else return error.InvalidTestArgument;
        }
        if (args.next() != null) return error.InvalidTestArgument;
    }
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io, .phase = if (modal_stack) 50 else if (response_exit == .none) 0 else 40 };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Win32 controls regression", .width = 420, .height = 300 }, .{ .watchdog_ms = null, .on_terminate = .{ .ctx = probe, .call = Probe.terminate } });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
