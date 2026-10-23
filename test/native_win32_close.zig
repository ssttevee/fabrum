//! A native WM_CLOSE must tear down a standalone host and exit its loop.
const std = @import("std");
const fabrum = @import("fabrum");
const platform = fabrum.app.platform.win32;
const guarded = @import("close_options").guarded;

extern "user32" fn SendMessageW(hwnd: *anyopaque, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;

const Root = struct {
    pub const Props = struct {};
    pub const State = struct { asking: bool = false };
    pub const Msg = union(enum) { closing: fabrum.app.platform.CloseReason, answered: ?usize };
    pub fn update(state: *State, msg: Msg, ctx: *fabrum.app.Update(@This())) !void {
        switch (msg) {
            .closing => {
                state.asking = true;
                try ctx.confirm(.{ .title = "Close confirmation", .text = "Close this window?" }, ctx.handler(.answered));
            },
            .answered => |answer| {
                if (answer == 0) try ctx.close() else try ctx.cancelClose();
            },
        }
    }
    pub fn view(ui: *fabrum.app.Ui, _: *const State, _: Props) !void {
        if (guarded) ui.guardClose(ui.messages(@This()).handler(.closing));
        try ui.text("Native close regression", .{});
        try fabrum.app.widgets.textField(ui, "field", .{ .text = "Focus before closing" });
    }
};

const Probe = struct {
    gui: platform.App(Root),
    io: std.Io,
    workers: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    closing: bool = false,

    fn terminated(ptr: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        if (self.done.swap(true, .acq_rel)) @panic("duplicate termination");
        std.debug.print("native-win32-close ({s}) PASS\n", .{if (guarded) "guarded" else "unguarded"});
    }

    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(ptr.?));
        self.pending.store(false, .release);
        if (self.done.load(.acquire) or self.gui.viewport.x == 0) return;
        if (!self.closing) {
            // The scene's only drawn content is text. Require nontransparent
            // glyph pixels in the bitmap successfully uploaded to its HWND;
            // a laid-out scene with an unpainted layered child must fail.
            if (!self.gui.automation().canvasHasInk(0)) return;
            const field = self.gui.handleOf(fabrum.app.testing.rootInstance(Root).native("field")) orelse return;
            self.gui.backend.backend().focus(.{ .native = field });
            self.closing = true;
            _ = SendMessageW(self.gui.hwnd(), 0x0010, 0, 0); // WM_CLOSE, as from window chrome.
        } else if (guarded and self.gui.runtime.rootState(Root).?.asking) {
            self.gui.automation().answerAlert(0);
        }
    }

    fn timer(self: *Probe) void {
        for (0..200) |_| {
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch return;
            // Keep the timeout active even after teardown: the message loop
            // must exit as well, rather than leave a windowless process alive.
            if (!self.done.load(.acquire) and !self.pending.swap(true, .acq_rel))
                platform.automation.runOnMain(tick, self);
        }
        std.debug.print("native-win32-close FAIL: message loop did not exit\n", .{});
        std.process.exit(1);
    }
};

pub fn main(init: std.process.Init) !void {
    const probe = try init.gpa.create(Probe);
    probe.* = .{ .gui = undefined, .io = init.io };
    try probe.gui.init(init.gpa, init.io, .{}, .{ .title = "Native close regression" }, .{
        .watchdog_ms = null,
        .on_terminate = .{ .ctx = probe, .call = Probe.terminated },
    });
    try probe.workers.concurrent(init.io, Probe.timer, .{probe});
    probe.gui.run();
}
