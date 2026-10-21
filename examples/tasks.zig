//! Commands, screen-scoped tasks and deterministic task results.
const std = @import("std");
const app = @import("fabrum").app;

pub const Example = struct {
    pub const Props = struct {};
    pub const State = struct {
        text: []const u8 = "",
        show: bool = true,
        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            if (self.text.len != 0) gpa.free(self.text);
        }
    };
    pub const Msg = union(enum) { read, read_unkeyed, read_bound, hide, cancel, result: anyerror![]const u8 };

    pub fn read(task: *app.Task, text: []const u8) anyerror![]const u8 {
        try task.checkCancel();
        return try task.gpa.dupe(u8, text);
    }

    pub fn noResult(_: *app.Task) void {}

    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .read => {
                const text = try ctx.gpa.dupe(u8, "command");
                defer ctx.gpa.free(text);
                try ctx.runKey("read", read, .{text}, ctx.handler(.result));
            },
            .read_bound => {
                const text = try ctx.gpa.dupe(u8, "bound");
                defer ctx.gpa.free(text);
                const action = try ctx.handler(.result).withAlloc(ctx.core.arena.allocator(), text);
                try ctx.run(noResult, .{}, action);
            },
            .read_unkeyed => try ctx.run(read, .{"independent"}, ctx.handler(.result)),
            .hide => state.show = false,
            .cancel => try ctx.cancel("read"),
            .result => |result| {
                const text = result catch "failed";
                const owned = try ctx.gpa.dupe(u8, text);
                if (state.text.len != 0) ctx.gpa.free(state.text);
                state.text = owned;
            },
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(@This());
        if (state.show) try ui.task("greeting", .{}, read, .{"hello"}, on.handler(.result));
        try ui.text(state.text, .{});
    }
};

pub fn main(init: std.process.Init) !void {
    var rt: app.Runtime(.{}) = try .init(init.gpa, .{ .io = init.io });
    defer rt.deinit();
    _ = try rt.frame(Example, .{}, .init(400, 200), .zero);
}

const H = app.testing.Harness(.{}, Example);

test "declared tasks run once and arguments survive their caller" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try std.testing.expect(h.taskStarted("greeting"));
    try std.testing.expectEqualStrings("", h.state().text);
    try h.runTasks();
    try h.expectText("hello");
    try h.runTasks();
    try h.post(h.root().handler(Example, .hide), {});
    try h.post(h.root().handler(Example, .read), {});
    try h.runTasks();
    try h.expectText("command");
}

test "fake results are borrowed copies and errors reach update" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.completeTask("greeting", Example.read, "fake");
    try h.expectText("fake");
    try h.post(h.root().handler(Example, .read), {});
    try h.completeTask("read", Example.read, error.NoFile);
    try h.expectText("failed");
}

test "replacing and canceling commands suppress old results" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Example, .hide), {});
    try h.post(h.root().handler(Example, .read), {});
    try h.post(h.root().handler(Example, .read), {});
    try h.post(h.root().handler(Example, .cancel), {});
    try h.runTasks();
    try std.testing.expectEqualStrings("", h.state().text);
    try std.testing.expect(!h.taskStarted("read"));
}

const Streams = struct {
    pub const Props = struct {};
    pub const State = struct { total: u32 = 0 };
    pub const Msg = union(enum) { stop, sample: u32, finished: u32 };
    pub fn work(task: *app.Task, stop: app.Action, sample: app.Handler(u32)) u32 {
        task.post(sample, 1) catch unreachable;
        task.post(stop, {}) catch unreachable;
        task.post(sample, 100) catch unreachable;
        return 1000;
    }
    pub fn update(state: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .stop => try ctx.cancel("stream"),
            .sample, .finished => |n| state.total += n,
        }
    }
    pub fn view(ui: *app.Ui, _: *const State, _: Props) !void {
        const on = ui.messages(@This());
        try ui.task("stream", .{}, work, .{ on.bind(.stop), on.handler(.sample) }, on.handler(.finished));
    }
};

test "cancellation discards queued progress and the final result" {
    var h: app.testing.Harness(.{}, Streams) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(1, h.state().total);
}

const Scoped = struct {
    pub const Props = struct { show: bool = true, generation: u32 = 0, duplicate: bool = false };
    pub const State = struct { total: u32 = 0 };
    pub const Msg = union(enum) { finished: u32 };
    pub fn update(state: *State, msg: Msg, _: *app.Update(@This())) void {
        state.total += msg.finished;
    }
    pub const Child = struct {
        pub const Props = struct { generation: u32, duplicate: bool };
        pub fn work(_: *app.Task) u32 {
            return 1;
        }
        pub fn view(ui: *app.Ui, props: @This().Props) !void {
            const on = ui.messages(Scoped);
            try ui.task("work", .{ .restart = props.generation }, work, .{}, on.handler(.finished));
            if (props.duplicate) try ui.task("work", .{ .restart = props.generation }, work, .{}, on.handler(.finished));
        }
    };
    pub fn view(ui: *app.Ui, _: *const State, props: Props) !void {
        if (props.show) try ui.one(Child, .{ .generation = props.generation, .duplicate = props.duplicate });
    }
};

test "stateless tasks reconcile by scope and key and remount" {
    var h: app.testing.Harness(.{}, Scoped) = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const child = h.root().one(Scoped.Child);
    try std.testing.expect(h.taskStartedFor(child, "work"));
    try h.completeTaskFor(child, "work", Scoped.Child.work, 4);
    try h.frame();
    try std.testing.expectEqual(4, h.state().total);
    h.props.generation = 1;
    try h.frame();
    try std.testing.expect(h.taskStartedFor(child, "work"));
    h.props.show = false;
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(4, h.state().total);
    h.props.show = true;
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(5, h.state().total);
}

test "duplicate task keys fail the frame" {
    var h: app.testing.Harness(.{}, Scoped) = try .init(.{ .duplicate = true }, .{});
    defer h.deinit();
    try std.testing.expectError(error.DuplicateTaskKey, h.frame());
}

const Blocking = struct {
    pub const Sync = struct {
        started: std.Io.Event = .unset,
        finished: std.Io.Event = .unset,
        never: std.Io.Event = .unset,
    };
    pub const Props = struct { sync: *Sync, show: bool = true };
    pub const State = struct { delivered: bool = false };
    pub const Msg = union(enum) { result: anyerror!void };
    pub fn work(task: *app.Task, sync: *Sync) anyerror!void {
        defer sync.finished.set(task.io);
        sync.started.set(task.io);
        try sync.never.wait(task.io);
    }
    pub fn update(state: *State, _: Msg, _: *app.Update(@This())) void {
        state.delivered = true;
    }
    pub fn view(ui: *app.Ui, _: *const State, props: Props) !void {
        if (props.show) try ui.task("blocked", .{}, work, .{props.sync}, ui.messages(@This()).handler(.result));
    }
};

test "runtime shutdown interrupts concurrent I/O and joins tasks" {
    var sync: Blocking.Sync = .{};
    var h: app.testing.Harness(.{}, Blocking) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try sync.started.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    h.runtime.cancelTasks();
    try std.testing.expect(sync.finished.isSet());
    try std.testing.expect(!h.state().delivered);
}

test "removing a declared task interrupts its I/O without delivering" {
    var sync: Blocking.Sync = .{};
    var h: app.testing.Harness(.{}, Blocking) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try sync.started.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    h.props.show = false;
    try h.frame();
    try sync.finished.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try h.frame();
    try std.testing.expect(!h.state().delivered);
    try std.testing.expect(!h.taskStarted("blocked"));
}

test "unkeyed commands run through the deterministic queue" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Example, .hide), {});
    try h.post(h.root().handler(Example, .read_unkeyed), {});
    try h.runTasks();
    try h.expectText("independent");
}

test "task actions copy indirectly bound payloads beyond a frame" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    try h.post(h.root().handler(Example, .hide), {});
    try h.post(h.root().handler(Example, .read_bound), {});
    try h.frame();
    try h.runTasks();
    try h.expectText("bound");
}

const Serial = struct {
    const Sync = struct {
        entered: std.Io.Event = .unset,
        canceled: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        never: std.Io.Event = .unset,
        old_finished: std.atomic.Value(bool) = .init(false),
        new_finished: std.Io.Event = .unset,
        replacement: std.atomic.Value(u32) = .init(0),
        overlap: std.atomic.Value(bool) = .init(false),
    };
    pub const Props = struct { sync: *Sync };
    pub const State = struct {};
    pub const Msg = union(enum) { start: u32, cancel };

    pub fn work(task: *app.Task, sync: *Sync, id: u32) void {
        if (id == 1) {
            sync.entered.set(task.io);
            sync.never.wait(task.io) catch {};
            sync.canceled.set(task.io);
            // Model cleanup that must finish even after cancellation.
            sync.release.waitUncancelable(task.io);
            sync.old_finished.store(true, .release);
        } else {
            if (!sync.old_finished.load(.acquire)) sync.overlap.store(true, .release);
            sync.replacement.store(id, .release);
            sync.new_finished.set(task.io);
        }
    }
    pub fn update(_: *State, msg: Msg, ctx: *app.Update(@This())) !void {
        switch (msg) {
            .start => |id| try ctx.runKey("serial", work, .{ ctx.props.sync, id }, null),
            .cancel => try ctx.cancel("serial"),
        }
    }
    pub fn view(_: *app.Ui, _: *const State, _: Props) !void {}
};
const SerialHarness = app.testing.Harness(.{}, Serial);

fn waitEvent(event: *std.Io.Event) !void {
    try event.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
}

fn startBlocked(h: *SerialHarness, sync: *Serial.Sync) !void {
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try h.post(h.root().handler(Serial, .start), 1);
    try waitEvent(&sync.entered);
}

fn releaseBlocked(h: *SerialHarness, sync: *Serial.Sync) void {
    sync.release.set(std.testing.io);
    // Wait only in the test. The runtime uses the background cancellation
    // worker, so posting a replacement or cancellation never waits here.
    h.runtime.core.tasks.records.items[0].reaper.await(std.testing.io) catch unreachable;
}

test "replacement waits for canceled I/O and cleanup to return" {
    var sync: Serial.Sync = .{};
    var h: SerialHarness = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    try startBlocked(&h, &sync);
    try h.post(h.root().handler(Serial, .start), 2);
    try waitEvent(&sync.canceled);
    try std.testing.expectEqual(0, sync.replacement.load(.acquire));
    releaseBlocked(&h, &sync);
    try h.frame();
    try waitEvent(&sync.new_finished);
    h.runtime.cancelTasks();
    try std.testing.expectEqual(2, sync.replacement.load(.acquire));
    try std.testing.expect(!sync.overlap.load(.acquire));
}

test "queued pending replacement can be superseded without running" {
    var sync: Serial.Sync = .{};
    var h: SerialHarness = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    try startBlocked(&h, &sync);
    h.runtime.core.tasks.queued = true;
    try h.post(h.root().handler(Serial, .start), 2);
    try waitEvent(&sync.canceled);
    try std.testing.expectError(error.TaskPending, h.completeTask("serial", Serial.work, {}));
    try h.runTasks();
    try std.testing.expectEqual(0, sync.replacement.load(.acquire));
    try h.post(h.root().handler(Serial, .start), 3);
    releaseBlocked(&h, &sync);
    try h.runTasks();
    try std.testing.expectEqual(3, sync.replacement.load(.acquire));
    try std.testing.expect(!sync.overlap.load(.acquire));
}

test "canceling a pending replacement drops it" {
    var sync: Serial.Sync = .{};
    var h: SerialHarness = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    try startBlocked(&h, &sync);
    h.runtime.core.tasks.queued = true;
    try h.post(h.root().handler(Serial, .start), 2);
    try h.post(h.root().handler(Serial, .cancel), {});
    releaseBlocked(&h, &sync);
    try h.runTasks();
    try std.testing.expectEqual(0, sync.replacement.load(.acquire));
    try std.testing.expectEqual(0, h.runtime.core.tasks.records.items.len);
}

test "repeated replacements reclaim records and cancellation groups" {
    var sync: Serial.Sync = .{};
    var h: SerialHarness = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    for (0..64) |_| {
        sync = .{};
        try startBlocked(&h, &sync);
        try h.post(h.root().handler(Serial, .start), 2);
        try h.post(h.root().handler(Serial, .cancel), {});
        try std.testing.expect(h.runtime.core.tasks.records.items.len <= 2);
        releaseBlocked(&h, &sync);
        try h.frame();
        try std.testing.expectEqual(0, h.runtime.core.tasks.records.items.len);
    }
}

test "progress handles post from a thread and safely drop after reclamation" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const record = h.runtime.core.tasks.records.items[0];
    var task: app.Task = .{ .io = std.testing.io, .gpa = record.arena.allocator(), .record = record };
    const action = try h.root().handler(Example, .result).withAlloc(task.gpa, "thread");
    const handle = try task.progress(action);
    const Thread = struct {
        fn post(progress: app.Task.Progress(void)) void {
            progress.post({}) catch unreachable;
        }
        fn taskPost(_: *app.Task, progress: app.Task.Progress(void)) void {
            post(progress);
        }
    };
    var group: std.Io.Group = .init;
    try group.concurrent(std.testing.io, Thread.post, .{handle});
    try group.await(std.testing.io);
    try h.frame();
    try h.expectText("thread");
    try h.runTasks();
    try h.expectText("hello");
    try std.testing.expect(record.reclaimed);
    // The completed declaration remains, but its bound handler arena is gone.
    try handle.post({});
    try h.frame();
    try h.expectText("hello");
    try h.post(h.root().handler(Example, .hide), {});
    try std.testing.expectEqual(0, h.runtime.core.tasks.records.items.len);
    // The record is gone too. Copies of the handle need no release, even
    // when passed through the recursive task-argument copier after expiry.
    try handle.post({});
    const core = &h.runtime.core;
    try core.tasks.start(core, h.root().id, null, false, 0, Thread.taskPost, .{handle}, null);
    try h.runTasks();
    try h.expectText("hello");
}

test "failed task enqueue releases the message reference" {
    var h: H = try .init(.{}, .{});
    defer h.deinit();
    try h.frame();
    const core = &h.runtime.core;
    const record = core.tasks.records.items[0];
    var task: app.Task = .{ .io = core.io, .gpa = record.arena.allocator(), .record = record };
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const original = core.gpa;
    core.gpa = failing.allocator();
    defer core.gpa = original;
    try std.testing.expectError(error.OutOfMemory, task.post(h.root().handler(Example, .result), "lost"));
    try std.testing.expectEqual(0, record.messages.load(.acquire));
}

const DeclaredSerial = struct {
    pub const Props = struct { sync: *Serial.Sync, key: u32 = 0, generation: u32 = 0 };
    pub fn view(ui: *app.Ui, props: Props) !void {
        try ui.task(props.key, .{ .restart = props.generation }, Serial.work, .{ props.sync, props.generation + 1 }, null);
    }
};

test "changing a declared restart waits for the old function to return" {
    var sync: Serial.Sync = .{};
    var h: app.testing.Harness(.{}, DeclaredSerial) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try waitEvent(&sync.entered);
    h.props.generation = 1;
    try h.frame();
    try waitEvent(&sync.canceled);
    try std.testing.expectEqual(0, sync.replacement.load(.acquire));
    sync.release.set(std.testing.io);
    h.runtime.core.tasks.records.items[0].reaper.await(std.testing.io) catch unreachable;
    try h.frame();
    try waitEvent(&sync.new_finished);
    try std.testing.expectEqual(2, sync.replacement.load(.acquire));
    try std.testing.expect(!sync.overlap.load(.acquire));
}

test "same declared restart retains running and completed tasks" {
    var sync: Serial.Sync = .{};
    var h: app.testing.Harness(.{}, DeclaredSerial) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try waitEvent(&sync.entered);
    const first_id = h.runtime.core.tasks.records.items[0].id;
    try h.frame();
    try std.testing.expectEqual(1, h.runtime.core.tasks.records.items.len);
    try std.testing.expectEqual(first_id, h.runtime.core.tasks.records.items[0].id);
    try std.testing.expect(!sync.canceled.isSet());
    h.props.generation = 1;
    try h.frame();
    try waitEvent(&sync.canceled);
    sync.release.set(std.testing.io);
    h.runtime.core.tasks.records.items[0].reaper.await(std.testing.io) catch unreachable;
    try h.frame();
    try waitEvent(&sync.new_finished);
    try h.runtime.core.tasks.records.items[0].group.await(std.testing.io);
    try h.frame();
    const completed = h.runtime.core.tasks.records.items[0];
    try std.testing.expect(completed.reclaimed);
    try h.frame();
    try std.testing.expectEqual(1, h.runtime.core.tasks.records.items.len);
    try std.testing.expectEqual(completed.id, h.runtime.core.tasks.records.items[0].id);
}

test "different declared keys run while a removed task is still returning" {
    var sync: Serial.Sync = .{};
    var h: app.testing.Harness(.{}, DeclaredSerial) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try waitEvent(&sync.entered);
    h.props.key = 1;
    h.props.generation = 1;
    try h.frame();
    try waitEvent(&sync.canceled);
    try waitEvent(&sync.new_finished);
    try std.testing.expect(!sync.old_finished.load(.acquire));
    try std.testing.expectEqual(2, sync.replacement.load(.acquire));
    try std.testing.expect(sync.overlap.load(.acquire));
}

test "queued declared restarts wait and skip superseded work" {
    var sync: Serial.Sync = .{};
    var h: app.testing.Harness(.{}, DeclaredSerial) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try waitEvent(&sync.entered);
    h.runtime.core.tasks.queued = true;
    h.props.generation = 1;
    try h.frame();
    try waitEvent(&sync.canceled);
    try std.testing.expectError(error.TaskPending, h.completeTask(@as(u32, 0), Serial.work, {}));
    try h.runTasks();
    try std.testing.expectEqual(0, sync.replacement.load(.acquire));
    h.props.generation = 2;
    try h.frame();
    sync.release.set(std.testing.io);
    h.runtime.core.tasks.records.items[0].reaper.await(std.testing.io) catch unreachable;
    try h.runTasks();
    try std.testing.expectEqual(3, sync.replacement.load(.acquire));
    try std.testing.expect(!sync.overlap.load(.acquire));
    try h.runTasks();
    try std.testing.expectEqual(1, h.runtime.core.tasks.records.items.len);
}

test "queued different keys do not wait for removed running tasks" {
    var sync: Serial.Sync = .{};
    var h: app.testing.Harness(.{}, DeclaredSerial) = try .init(.{ .sync = &sync }, .{});
    defer h.deinit();
    defer sync.release.set(std.testing.io);
    h.runtime.core.tasks.queued = false;
    try h.frame();
    try waitEvent(&sync.entered);
    h.runtime.core.tasks.queued = true;
    h.props.key = 1;
    h.props.generation = 1;
    try h.frame();
    try waitEvent(&sync.canceled);
    try h.runTasks();
    try std.testing.expect(!sync.old_finished.load(.acquire));
    try std.testing.expectEqual(2, sync.replacement.load(.acquire));
    try std.testing.expect(sync.overlap.load(.acquire));
}

test "declared restart hashes slice contents and ignores argument changes" {
    const View = struct {
        pub const Props = struct { restart: []const u8, id: u32 = 2, sync: *Serial.Sync };
        pub fn view(ui: *app.Ui, props: Props) !void {
            try ui.task("work", .{ .restart = props.restart }, Serial.work, .{ props.sync, props.id }, null);
        }
    };
    var sync: Serial.Sync = .{};
    var text = [_]u8{ 'o', 'n', 'e' };
    var h: app.testing.Harness(.{}, View) = try .init(.{ .restart = &text, .sync = &sync }, .{});
    defer h.deinit();
    try h.frame();
    const first_id = h.runtime.core.tasks.records.items[0].id;
    h.props.restart = "one";
    h.props.id = 3;
    try h.frame();
    try std.testing.expectEqual(first_id, h.runtime.core.tasks.records.items[0].id);
    try h.runTasks();
    try std.testing.expectEqual(2, sync.replacement.load(.acquire));
    text[0] = 'd';
    h.props.restart = &text;
    try h.frame();
    try h.runTasks();
    try std.testing.expectEqual(3, sync.replacement.load(.acquire));
}
