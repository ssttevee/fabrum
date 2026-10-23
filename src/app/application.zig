//! Event-thread window lifetime and application quit coordination.
const std = @import("std");
const CloseReason = @import("platform.zig").CloseReason;

/// An application-local slot and generation. Never persist across applications.
pub const WindowId = enum(u64) { _ };

/// A host-owned, stable-address window. Destruction must stop callbacks and
/// join runtime tasks before releasing the host or runtime allocation.
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// false leaves the request pending for explicit approval or cancellation.
        guard: *const fn (*anyopaque, CloseReason) anyerror!bool,
        destroy: *const fn (*anyopaque) void,
        present: ?*const fn (*anyopaque) void = null,
        hide: ?*const fn (*anyopaque) void = null,
        requestFrame: ?*const fn (*anyopaque) void = null,
    };
};

/// Call only on the native event thread. Requests are deferred until `drain`,
/// which hosts call after returning from runtime and native callbacks.
pub const Application = struct {
    gpa: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    quitting: bool = false,
    /// Latched when a quit transaction has destroyed every window.
    quit_completed: bool = false,
    draining: bool = false,
    shutting_down: bool = false,

    const State = enum { idle, requested, waiting, approved };
    const Slot = struct {
        generation: u32 = 1,
        window: ?Window = null,
        state: State = .idle,
        reason: CloseReason = .window,
        revision: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator) Application {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Application) void {
        self.shutting_down = true;
        // Invalidate before calling host teardown, which can run callbacks.
        for (0..self.slots.items.len) |i| self.destroy(i);
        self.slots.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn add(self: *Application, window: Window) !WindowId {
        if (self.quitting or self.quit_completed or self.shutting_down) return error.ApplicationQuitting;
        for (self.slots.items, 0..) |*slot, i| {
            if (slot.window == null and slot.generation != 0) {
                slot.window = window;
                slot.state = .idle;
                return id(i, slot.generation);
            }
        }
        if (self.slots.items.len >= std.math.maxInt(u32)) return error.TooManyWindows;
        try self.slots.append(self.gpa, .{ .window = window });
        return id(self.slots.items.len - 1, 1);
    }

    pub fn contains(self: *const Application, window_id: WindowId) bool {
        return self.index(window_id) != null;
    }
    pub fn count(self: *const Application) usize {
        var n: usize = 0;
        for (self.slots.items) |slot| {
            if (slot.window != null) n += 1;
        }
        return n;
    }

    /// Stale IDs are ignored. These operations never extend a window's lifetime.
    pub fn present(self: *Application, window_id: WindowId) void {
        const i = self.index(window_id) orelse return;
        const window = self.slots.items[i].window.?;
        if (window.vtable.present) |callback| callback(window.ptr);
    }

    /// Shows a hidden window using its native presentation policy.
    pub fn show(self: *Application, window_id: WindowId) void {
        self.present(window_id);
    }

    /// Hiding keeps the runtime and generational window ID alive.
    pub fn hide(self: *Application, window_id: WindowId) void {
        const i = self.index(window_id) orelse return;
        const window = self.slots.items[i].window.?;
        if (window.vtable.hide) |callback| callback(window.ptr);
    }

    pub fn requestFrame(self: *Application, window_id: WindowId) void {
        const i = self.index(window_id) orelse return;
        const window = self.slots.items[i].window.?;
        if (window.vtable.requestFrame) |callback| callback(window.ptr);
    }

    pub fn requestClose(self: *Application, window_id: WindowId, reason: CloseReason) void {
        if (!self.contains(window_id)) return;
        if (reason == .quit) {
            self.requestQuit(null);
            return;
        }
        const i = self.index(window_id) orelse return;
        if (self.slots.items[i].state == .idle) {
            self.slots.items[i].revision +%= 1;
            self.slots.items[i].state = .requested;
            self.slots.items[i].reason = reason;
        }
    }

    /// Approves a pending guard, or queues an unconditional window close.
    pub fn approveClose(self: *Application, window_id: WindowId) void {
        const i = self.index(window_id) orelse return;
        self.slots.items[i].state = .approved;
    }

    /// A cancelled quit resets every window's approval. A later quit asks again.
    pub fn cancelClose(self: *Application, window_id: WindowId) void {
        const i = self.index(window_id) orelse return;
        if (self.quitting) {
            self.quitting = false;
            for (self.slots.items) |*slot| {
                slot.revision +%= 1;
                slot.state = .idle;
            }
        } else {
            self.slots.items[i].revision +%= 1;
            self.slots.items[i].state = .idle;
        }
    }

    /// Only the originating window is approved; all others still run guards.
    pub fn requestQuit(self: *Application, approved_origin: ?WindowId) void {
        if (approved_origin) |origin| {
            if (!self.contains(origin)) return;
        }
        if (!self.quitting) {
            self.quitting = true;
            for (self.slots.items) |*slot| {
                if (slot.window != null) {
                    slot.revision +%= 1;
                    slot.state = .requested;
                    slot.reason = .quit;
                }
            }
        }
        if (approved_origin) |origin| self.approveClose(origin);
    }

    pub fn drain(self: *Application) !void {
        if (self.draining) return;
        self.draining = true;
        defer self.draining = false;
        if (self.quitting) {
            for (self.slots.items) |slot| {
                if (slot.window != null and slot.state == .waiting) return;
            }
        }
        var first_error: ?anyerror = null;
        var i: usize = 0;
        while (i < self.slots.items.len) : (i += 1) {
            const slot = self.slots.items[i];
            if (slot.window == null or slot.state != .requested) continue;
            const window_id = id(i, slot.generation);
            self.slots.items[i].state = .waiting;
            const approved = slot.window.?.vtable.guard(slot.window.?.ptr, slot.reason) catch |err| {
                self.cancelClose(window_id);
                // Ordinary close requests are independent. Keep processing
                // them and return the first guard error after teardown.
                // A quit failure resets all approvals before continuing.
                if (first_error == null) first_error = err;
                continue;
            };
            // Guards can synchronously approve, cancel or append windows.
            if (approved and self.contains(window_id) and self.slots.items[i].state == .waiting and self.slots.items[i].revision == slot.revision)
                self.slots.items[i].state = .approved;
            // A quit asks one window at a time, so cancellation cannot leave
            // another window's confirmation prompt outstanding.
            if (self.quitting and self.contains(window_id) and self.slots.items[i].state != .approved) {
                if (first_error) |err| return err;
                return;
            }
        }
        const finishing_quit = self.quitting;
        if (finishing_quit) {
            for (self.slots.items) |slot| {
                if (slot.window != null and slot.state != .approved) {
                    if (first_error) |err| return err;
                    return;
                }
            }
        }
        self.destroyApproved();
        if (self.count() == 0) {
            self.quit_completed = self.quit_completed or finishing_quit;
            self.quitting = false;
        }
        if (first_error) |err| return err;
    }

    fn destroyApproved(self: *Application) void {
        for (0..self.slots.items.len) |i| {
            if (self.slots.items[i].state == .approved) self.destroy(i);
        }
    }

    fn destroy(self: *Application, i: usize) void {
        const window = self.slots.items[i].window orelse return;
        self.slots.items[i].window = null;
        self.slots.items[i].state = .idle;
        // Retire exhausted generations rather than revalidating an old handle.
        self.slots.items[i].generation +%= 1;
        window.vtable.destroy(window.ptr);
    }

    fn id(i: usize, generation: u32) WindowId {
        return @fromBackingInt(@intCast((@as(u64, generation) << 32) | @as(u64, @intCast(i))));
    }
    fn index(self: *const Application, window_id: WindowId) ?usize {
        const bits = @backingInt(window_id);
        const i: usize = @intCast(bits & 0xffffffff);
        if (i >= self.slots.items.len) return null;
        const slot = self.slots.items[i];
        return if (slot.window != null and slot.generation == bits >> 32) i else null;
    }
};

test "queued close, generational handles and atomic asynchronous quit" {
    const Fake = struct {
        guards: usize = 0,
        destroyed: bool = false,
        allow: bool = true,
        fn guard(ptr: *anyopaque, _: CloseReason) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.guards += 1;
            return self.allow;
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
        const vtable: Window.VTable = .{ .guard = guard, .destroy = destroy };
        fn window(self: *@This()) Window {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };
    var application = Application.init(std.testing.allocator);
    defer application.deinit();
    var a: Fake = .{};
    var b: Fake = .{ .allow = false };
    const first = try application.add(a.window());
    application.requestClose(first, .window);
    try std.testing.expect(!a.destroyed);
    try application.drain();
    try std.testing.expect(a.destroyed);
    a.destroyed = false;
    const second = try application.add(a.window());
    try std.testing.expect(first != second);
    const third = try application.add(b.window());
    var c: Fake = .{};
    _ = try application.add(c.window());
    application.approveClose(first);
    try std.testing.expect(application.contains(second));
    application.requestQuit(second);
    try std.testing.expectError(error.ApplicationQuitting, application.add(a.window()));
    try application.drain();
    application.approveClose(second);
    try application.drain();
    try std.testing.expectEqual(@as(usize, 0), c.guards);
    try std.testing.expect(!a.destroyed and !b.destroyed);
    application.cancelClose(third);
    application.requestQuit(second);
    try application.drain();
    try std.testing.expectEqual(@as(usize, 2), b.guards);
    application.approveClose(third);
    try application.drain();
    try std.testing.expect(a.destroyed and b.destroyed);
    try std.testing.expectEqual(@as(usize, 0), application.count());
}

test "stale quit requests and callback cancellation do not approve a later request" {
    const Fake = struct {
        application: *Application,
        window_id: WindowId = @fromBackingInt(@intCast(0)),
        calls: usize = 0,
        destroyed: bool = false,
        add_on_destroy: bool = false,
        rejected_add: bool = false,
        fn guard(ptr: *anyopaque, _: CloseReason) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                self.application.cancelClose(self.window_id);
                self.application.requestQuit(null);
                // This approval belongs to the cancelled request.
                return true;
            }
            return false;
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
            if (self.add_on_destroy) {
                _ = self.application.add(.{ .ptr = self, .vtable = &vtable }) catch {
                    self.rejected_add = true;
                    return;
                };
            }
        }
        const vtable: Window.VTable = .{ .guard = guard, .destroy = destroy };
    };
    var application = Application.init(std.testing.allocator);
    var fake: Fake = .{ .application = &application };
    fake.window_id = try application.add(.{ .ptr = &fake, .vtable = &Fake.vtable });
    const stale: WindowId = @fromBackingInt(@intCast(0));
    application.requestQuit(stale);
    application.requestClose(stale, .quit);
    try std.testing.expect(!application.quitting);
    application.requestQuit(null);
    try application.drain();
    try std.testing.expect(!fake.destroyed);
    try application.drain();
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(!fake.destroyed);
    application.cancelClose(fake.window_id);
    fake.add_on_destroy = true;
    application.approveClose(fake.window_id);
    try application.drain();
    try std.testing.expectEqual(@as(usize, 1), application.count());
    try std.testing.expect(!application.contains(fake.window_id));
    try std.testing.expect(!fake.rejected_add);
    application.deinit();
    try std.testing.expect(fake.destroyed and fake.rejected_add);
}

test "a failed guard completes independent ordinary closes in either order and cancels atomic quit" {
    const Fake = struct {
        fail: bool = false,
        destroyed: bool = false,
        fn guard(ptr: *anyopaque, _: CloseReason) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.fail) return error.GuardFailed;
            return true;
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
        const vtable: Window.VTable = .{ .guard = guard, .destroy = destroy };
        fn window(self: *@This()) Window {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };
    inline for (.{ false, true }) |failure_first| {
        inline for (.{ CloseReason.window, CloseReason.quit }) |reason| {
            var application = Application.init(std.testing.allocator);
            defer application.deinit();
            var a: Fake = .{};
            var b: Fake = .{ .fail = true };
            const failed: ?WindowId = if (failure_first) try application.add(b.window()) else null;
            const first = try application.add(a.window());
            const second = failed orelse try application.add(b.window());
            application.requestClose(first, reason);
            application.requestClose(second, reason);
            try std.testing.expectError(error.GuardFailed, application.drain());
            try std.testing.expectEqual(reason == .window, a.destroyed);
            try std.testing.expect(!b.destroyed);
            try std.testing.expectEqual(reason == .quit, application.contains(first));
            try std.testing.expect(application.contains(second));
            try std.testing.expect(!application.quitting and !application.quit_completed);
        }
    }
}

test "show and hide preserve window lifetime and ignore stale handles" {
    const Fake = struct {
        visible: bool = true,
        presentations: usize = 0,
        hides: usize = 0,
        destroyed: bool = false,
        fn guard(_: *anyopaque, _: CloseReason) !bool {
            return true;
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
        fn present(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.visible = true;
            self.presentations += 1;
        }
        fn hide(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.visible = false;
            self.hides += 1;
        }
        const vtable: Window.VTable = .{ .guard = guard, .destroy = destroy, .present = present, .hide = hide };
    };
    var application = Application.init(std.testing.allocator);
    defer application.deinit();
    var fake: Fake = .{};
    const first = try application.add(.{ .ptr = &fake, .vtable = &Fake.vtable });
    application.hide(first);
    try std.testing.expect(!fake.visible and !fake.destroyed);
    try std.testing.expect(application.contains(first));
    application.show(first);
    try std.testing.expect(fake.visible);
    application.approveClose(first);
    try application.drain();
    const second = try application.add(.{ .ptr = &fake, .vtable = &Fake.vtable });
    try std.testing.expect(first != second);
    application.hide(first);
    application.show(first);
    try std.testing.expectEqual(@as(usize, 1), fake.hides);
    try std.testing.expectEqual(@as(usize, 1), fake.presentations);
}
