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
        if (state.show) try ui.task("greeting", read, .{"hello"}, on.handler(.result));
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
        try ui.task("stream", work, .{ on.bind(.stop), on.handler(.sample) }, on.handler(.finished));
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
            try ui.task(props.generation, work, .{}, on.handler(.finished));
            if (props.duplicate) try ui.task(props.generation, work, .{}, on.handler(.finished));
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
    try std.testing.expect(h.taskStartedFor(child, @as(u32, 0)));
    try h.completeTaskFor(child, @as(u32, 0), Scoped.Child.work, 4);
    try h.frame();
    try std.testing.expectEqual(4, h.state().total);
    h.props.generation = 1;
    try h.frame();
    try std.testing.expect(!h.taskStartedFor(child, @as(u32, 0)));
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
        if (props.show) try ui.task("blocked", work, .{props.sync}, ui.messages(@This()).handler(.result));
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
