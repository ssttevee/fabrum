//! Opt-in desktop overlay integration test; requires a real native event loop.
const std = @import("std");
const fabrum = @import("fabrum");
const app = fabrum.app;
const platform = app.platform.current;
const is_appkit = app.platform.kind == .appkit;

const Page = struct {
    pub const Props = struct {};
    pub const State = struct { count: usize = 0 };
    pub const Msg = union(enum) { increment };
    pub fn update(state: *State, _: Msg, _: *app.Update(Page)) void {
        state.count += 1;
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        try ui.open(null, .{ .layout = .{ .sizing = .grow(.{}), .padding = .all(24) } });
        defer ui.close();
        try ui.open("red", .{ .layout = .{ .sizing = .fixedXY(48, 48) }, .background_color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });
        ui.close();
    }
};
const Normal = platform.App(Page);
const Overlay = platform.Window(Page, if (is_appkit) .{
    .decorations = .none,
    .background = .transparent,
    .level = .floating,
    .activation = .never,
    .pointer = .passthrough,
    .shadow = .none,
    .placement = .positioned,
} else .{ .decorations = .none, .background = .transparent });
const Borderless = platform.Window(Page, .{ .decorations = .none });
const Passthrough = platform.Window(Page, .{ .decorations = .none, .pointer = .passthrough });

const Smoke = struct {
    gui: platform.Application,
    io: std.Io,
    worker: std.Io.Group = .init,
    stop: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    normal: app.WindowId = @fromBackingInt(0),
    overlay: app.WindowId = @fromBackingInt(0),
    late_overlay: ?app.WindowId = null,
    transparent: bool = true,
    phase: u8 = 0,
    ticks: usize = 0,
    posted: bool = false,
    expected: usize = 0,
    terminated: usize = 0,

    fn fail(message: []const u8) noreturn {
        std.debug.print("native-overlays FAIL: {s}\n", .{message});
        std.process.exit(1);
    }
    fn check(ok: bool, message: []const u8) void {
        if (!ok) fail(message);
    }
    fn flag(comptime W: type, window: *W, name: []const u8, value: bool) void {
        var buffer: [512]u8 = undefined;
        var wanted_buffer: [80]u8 = undefined;
        const description = window.automation().describeWindow(&buffer);
        const wanted = std.fmt.bufPrint(&wanted_buffer, "{s}={d}", .{ name, @intFromBool(value) }) catch unreachable;
        if (std.mem.indexOf(u8, description, wanted) == null) {
            std.debug.print("native-overlays flags: {s}; expected {s}\n", .{ description, wanted });
            fail("native policy flag mismatch");
        }
    }
    fn terminatedWindow(ptr: ?*anyopaque) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr.?));
        self.terminated += 1;
        if (self.phase != 6 or self.gui.windows.count() != 0) return;
        check(self.terminated == self.expected, "teardown callback count mismatch");
        self.stop.store(true, .release);
        std.debug.print("native-overlays PASS (transparent coverage={s})\n", .{if (self.transparent) "yes" else "unavailable"});
    }
    fn options(self: *Smoke, comptime W: type) W.InitOptions {
        return .{ .watchdog_ms = null, .on_terminate = .{ .ctx = self, .call = terminatedWindow } };
    }
    fn timer(self: *Smoke) void {
        for (0..240) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            if (self.stop.load(.acquire)) return;
            if (!self.pending.swap(true, .acq_rel)) platform.automation.runOnMain(tick, self);
        }
        self.timed_out.store(true, .release);
        platform.automation.runOnMain(tick, self);
    }
    fn inspect(self: *Smoke, comptime W: type) void {
        const w = self.gui.get(W, self.overlay) orelse fail("typed overlay lookup failed");
        const normal = self.gui.get(Normal, self.normal) orelse fail("normal window disappeared");
        check(self.gui.get(Normal, self.overlay) == null, "default policy accepted overlay ID");
        check(self.gui.get(W, self.normal) == null, "overlay policy accepted ordinary ID");
        check(self.gui.window(Page, self.overlay) == null, "legacy lookup accepted nondefault policy");
        flag(Normal, normal, "transparent", false);
        flag(Normal, normal, "decorated", true);
        flag(W, w, "decorated", false);
        flag(W, w, "transparent", self.transparent);
        if (is_appkit) {
            check(w.automation().windowFlags() & 512 != 0, "never activation requires a native nonactivating panel");
            flag(W, w, "floating", true);
            flag(W, w, "passthrough", true);
            flag(W, w, "shadowless", true);
            flag(W, w, "can_key", false);
            flag(W, w, "can_main", false);
            flag(W, w, "key", false);
            flag(Normal, normal, "key", true);
        }
        switch (self.phase) {
            0 => {
                flag(W, w, "visible", false);
                // Leave the initially hidden window alive through several event-loop turns.
                self.ticks += 1;
                if (self.ticks < 4) return;
                check(self.gui.show(self.overlay), "show rejected");
                self.phase = 1;
            },
            1 => {
                flag(W, w, "visible", true);
                const state = w.runtime.rootState(Page) orelse return;
                if (!self.posted) {
                    self.posted = true;
                    w.runtime.post(app.testing.rootInstance(Page).handler(Page, .increment), {}) catch fail("post increment");
                    return;
                }
                if (state.count != 1) return;
                check(self.gui.hide(self.overlay), "hide rejected");
                self.phase = 2;
            },
            2 => {
                flag(W, w, "visible", false);
                check(w.runtime.rootState(Page).?.count == 1, "hide reset component state");
                check(self.gui.present(self.overlay), "present rejected");
                self.phase = 3;
                self.ticks = 0;
            },
            3 => {
                flag(W, w, "visible", true);
                check(w.runtime.rootState(Page).?.count == 1, "show reset component state");
                self.ticks += 1;
                if (self.ticks < 4) return;
                if (self.transparent) w.automation().snapshot(if (is_appkit) "/tmp/fabrum-overlay-appkit.png" else "/tmp/fabrum-overlay-gtk.png", 1) catch fail("transparent source snapshot failed");
                self.phase = 4;
            },
            4 => {
                const before = self.gui.windows.count();
                const probe = self.gui.open(Passthrough, .{}, .{ .title = "Passthrough probe", .width = 120, .height = 120, .visible = false }, self.options(Passthrough)) catch |err| {
                    if (is_appkit or err != error.PointerPassthroughUnsupported) fail("unexpected passthrough creation error");
                    check(self.gui.windows.count() == before, "unsupported creation changed registry");
                    std.debug.print("native-overlays LIMITED: pointer passthrough unavailable on this GTK display\n", .{});
                    self.phase = 5;
                    return;
                };
                self.expected += 1;
                check(self.gui.get(W, probe) == null, "different nondefault policies shared a type tag");
                check(self.gui.get(Passthrough, self.overlay) == null, "different nondefault policies accepted overlay ID");
                flag(Passthrough, self.gui.get(Passthrough, probe).?, "passthrough", true);
                check(self.gui.close(probe), "close probe rejected");
                if (is_appkit) {
                    self.late_overlay = self.gui.open(Overlay, .{}, .{ .title = "Late nonactivating overlay", .width = 140, .height = 120 }, self.options(Overlay)) catch fail("open overlay while foreground window is key");
                    self.expected += 1;
                    self.phase = 7;
                } else self.phase = 5;
            },
            7 => {
                const late = self.gui.get(Overlay, self.late_overlay.?) orelse fail("late overlay disappeared");
                flag(Overlay, late, "visible", true);
                flag(Overlay, late, "key", false);
                flag(Normal, normal, "key", true);
                check(self.gui.close(self.late_overlay.?), "close late overlay rejected");
                self.phase = 5;
            },
            5 => {
                self.phase = 6;
                self.gui.quit();
            },
            else => {},
        }
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Smoke = @ptrCast(@alignCast(ptr.?));
        if (self.stop.load(.acquire)) return;
        self.pending.store(false, .release);
        if (self.timed_out.load(.acquire)) {
            std.debug.print("phase={d} ticks={d}\n", .{ self.phase, self.ticks });
            fail("bounded event-loop timeout");
        }
        if (self.transparent) self.inspect(Overlay) else self.inspect(Borderless);
    }
};

pub fn main(init: std.process.Init) !void {
    const self = try init.gpa.create(Smoke);
    self.* = .{ .gui = undefined, .io = init.io };
    try self.gui.init(init.gpa, init.io, .{ .quit_on_last_window_closed = false });
    self.normal = try self.gui.open(Normal, .{}, .{ .title = "Overlay foreground control", .width = 260, .height = 180 }, self.options(Normal));
    self.expected += 1;
    const before = self.gui.windows.count();
    self.overlay = self.gui.open(Overlay, .{}, .{ .title = "Hidden overlay", .width = 180, .height = 140, .visible = false, .position = if (is_appkit) .{ .x = 80, .y = 80 } else null }, self.options(Overlay)) catch |err| blk: {
        if (is_appkit or err != error.TransparentWindowUnsupported) return err;
        Smoke.check(self.gui.windows.count() == before, "unsupported transparency changed registry");
        self.transparent = false;
        std.debug.print("native-overlays LIMITED: transparent windows unavailable on this GTK display; testing explicit system-background borderless policy\n", .{});
        break :blk try self.gui.open(Borderless, .{}, .{ .title = "Borderless lifecycle control", .width = 180, .height = 140, .visible = false }, self.options(Borderless));
    };
    self.expected += 1;
    try self.worker.concurrent(init.io, Smoke.timer, .{self});
    self.gui.run();
}
