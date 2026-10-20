//! Runtime-owned concurrent work and its borrowed messages.
const std = @import("std");
const component = @import("component.zig");
const message = @import("message.zig");
const Core = @import("runtime.zig").Core;
const Allocator = std.mem.Allocator;

/// Only task functions receive I/O. Allocate temporary arguments, progress
/// and results with `gpa`; they remain alive through result delivery, then
/// are freed together. Updates must copy anything they keep. External
/// resources still need `defer`; arena reclamation only frees memory.
pub const Task = struct {
    io: std.Io,
    gpa: Allocator,
    record: *Record,

    pub fn checkCancel(self: *Task) std.Io.Cancelable!void {
        if (self.record.canceled.load(.acquire)) return error.Canceled;
        try self.io.checkCancel();
    }

    /// Posts progress that borrows task memory. Do not mutate it after
    /// posting. Canceled tasks' progress and results are discarded.
    pub fn post(self: *Task, handler: anytype, payload: @TypeOf(handler).Payload) Allocator.Error!void {
        if (self.record.canceled.load(.acquire)) return;
        var msg = try if (@TypeOf(handler).Payload == void) message.make(handler, self.record.core.gpa, payload) else message.makeBorrowed(handler, self.record.core.gpa, payload);
        _ = self.record.messages.fetchAdd(1, .monotonic);
        msg.task = self.record;
        try self.record.core.enqueue(msg);
        if (self.record.core.platform) |platform| platform.requestFrame();
    }
};

pub fn Result(comptime function: anytype) type {
    const info = @typeInfo(@TypeOf(function));
    if (info != .@"fn") @compileError("app task: expected a function with first parameter *app.Task");
    if (info.@"fn".param_types.len == 0 or info.@"fn".param_types[0] != *Task)
        @compileError("app task: first parameter must be *app.Task");
    if (info.@"fn".is_generic or info.@"fn".attrs.varargs)
        @compileError("app task: generic and variadic functions are not supported");
    return info.@"fn".return_type.?;
}

pub fn functionTag(comptime function: anytype) component.TypeTag {
    return component.typeTag(Wrapper(function, message.Handler(Result(function))));
}

/// Deep-copies slices, arrays, optionals, error unions and value structs.
/// Single pointers (including service handles) are borrowed and must outlive
/// the task. Tagged unions copy only their active payload.
pub fn copy(gpa: Allocator, value: anytype) Allocator.Error!struct { value: @TypeOf(value) } {
    const T = @TypeOf(value);
    if (T == @FieldType(message.Action, "bound")) return .{ .value = try value.clone(gpa) };
    var out = value;
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) {
            const slice = if (p.sentinel()) |sentinel|
                try gpa.allocSentinel(p.child, value.len, sentinel)
            else
                try gpa.alloc(p.child, value.len);
            for (value, slice) |v, *dest| dest.* = (try copy(gpa, v)).value;
            out = slice;
        },
        .@"struct" => |s| {
            inline for (s.field_names, s.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") @field(out, name) = (try copy(gpa, @field(value, name))).value;
            }
        },
        .array => {
            for (value, &out) |v, *dest| dest.* = (try copy(gpa, v)).value;
        },
        .optional => out = if (value) |v| (try copy(gpa, v)).value else null,
        .error_union => out = if (value) |v| (try copy(gpa, v)).value else |err| @as(T, err),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("app task: untagged union arguments cannot be copied");
            inline for (u.field_names) |name| {
                if (std.mem.eql(u8, @tagName(value), name)) {
                    out = @unionInit(T, name, (try copy(gpa, @field(value, name))).value);
                    break;
                }
            }
        },
        else => {},
    }
    return .{ .value = out };
}

pub const Record = struct {
    core: *Core,
    owner: component.InstanceId,
    key: ?u64,
    declared: bool,
    seen: bool = true,
    arena: std.heap.ArenaAllocator,
    group: std.Io.Group = .init,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    messages: std.atomic.Value(usize) = .init(0),
    reaping: bool = false,
    reaped: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    reclaimed: bool = false,
    function: component.TypeTag,
    run: *const fn (*Record) void,
    destroy: *const fn (*Record) void,
    complete: *const fn (*Record, component.TypeTag, *const anyopaque) anyerror!void,
};

pub const Manager = struct {
    records: std.ArrayList(*Record) = .empty,
    reapers: std.Io.Group = .init,
    /// Harnesses explicitly drain this queue instead of spawning workers.
    queued: bool = false,

    pub fn start(self: *Manager, core: *Core, owner: component.InstanceId, key: ?u64, declared: bool, comptime function: anytype, args: anytype, handler: message.Handler(Result(function))) !void {
        if (key) |k| {
            for (self.records.items) |record| {
                if (record.owner == owner and record.key == k and !record.canceled.load(.acquire)) {
                    if (declared) {
                        if (!record.declared or record.seen) return error.DuplicateTaskKey;
                        if (record.function != component.typeTag(Wrapper(function, @TypeOf(handler)))) return error.TaskFunctionChanged;
                        record.seen = true;
                        return;
                    }
                }
            }
            try self.cancel(core, owner, k);
        }
        const W = Wrapper(function, @TypeOf(handler));
        if (@typeInfo(@TypeOf(args)).@"struct".field_names.len + 1 != @typeInfo(W.Args).@"struct".field_names.len)
            @compileError("app task: argument count must match the function after *app.Task");
        const stored = try core.gpa.create(W);
        stored.* = .{
            .record = .{
                .core = core,
                .owner = owner,
                .key = key,
                .declared = declared,
                .arena = .init(core.gpa),
                .function = component.typeTag(W),
                .run = W.run,
                .destroy = W.destroy,
                .complete = W.complete,
            },
            .args = undefined,
            .handler = undefined,
        };
        errdefer W.destroy(&stored.record);
        stored.handler = (try copy(stored.record.arena.allocator(), handler)).value;
        stored.args[0] = undefined;
        inline for (@typeInfo(W.Args).@"struct".field_names[1..], 0..) |name, i| {
            @field(stored.args, name) = (try copy(stored.record.arena.allocator(), @as(@FieldType(W.Args, name), args[i]))).value;
        }
        try self.records.ensureUnusedCapacity(core.gpa, 1);
        if (!self.queued) {
            try stored.record.group.concurrent(core.io, W.run, .{&stored.record});
            stored.record.started = true;
        }
        self.records.appendAssumeCapacity(&stored.record);
    }

    pub fn cancel(self: *Manager, core: *Core, owner: component.InstanceId, key: u64) !void {
        for (self.records.items) |record| {
            if (record.owner == owner and record.key == key) try self.cancelRecord(core, record);
        }
    }

    fn cancelRecord(self: *Manager, core: *Core, record: *Record) !void {
        record.canceled.store(true, .release);
        if (!record.started) record.done.store(true, .release);
        if (record.started and !record.done.load(.acquire) and !record.reaping) {
            // Group.cancel waits: only this worker performs that wait.
            try self.reapers.concurrent(core.io, reap, .{record});
            record.reaping = true;
        }
    }

    fn reap(record: *Record) void {
        record.group.cancel(record.core.io);
        const platform = record.core.platform;
        record.reaped.store(true, .release);
        if (platform) |p| p.requestFrame();
    }

    pub fn begin(self: *Manager) void {
        for (self.records.items) |record| if (record.declared) {
            record.seen = false;
        };
    }

    pub fn finish(self: *Manager, core: *Core) !void {
        for (self.records.items) |record| {
            if ((record.declared and !record.seen) or (!core.instances.contains(record.owner) and !core.stateless.contains(record.owner))) try self.cancelRecord(core, record);
        }
        self.collect(core);
    }

    pub fn collect(self: *Manager, core: *Core) void {
        var i: usize = 0;
        while (i < self.records.items.len) {
            const record = self.records.items[i];
            const retired = !record.declared or record.canceled.load(.acquire);
            const finished = if (record.reaping) record.reaped.load(.acquire) else record.done.load(.acquire);
            if (finished and record.messages.load(.acquire) == 0 and !record.reclaimed) {
                record.group.cancel(core.io);
                record.arena.deinit();
                record.arena = .init(core.gpa);
                record.reclaimed = true;
            }
            if (retired and record.reclaimed) {
                _ = self.records.orderedRemove(i);
                record.destroy(record);
            } else i += 1;
        }
    }

    pub fn deinit(self: *Manager, core: *Core) void {
        for (self.records.items) |record| record.canceled.store(true, .release);
        self.reapers.await(core.io) catch {};
        for (self.records.items) |record| record.group.cancel(core.io);
        // Messages must be discarded before destroying their task arenas.
    }

    pub fn destroy(self: *Manager, core: *Core) void {
        for (self.records.items) |record| record.destroy(record);
        self.records.deinit(core.gpa);
    }

    pub fn runQueued(self: *Manager) void {
        std.debug.assert(self.queued);
        for (self.records.items) |record| {
            if (!record.started and !record.done.load(.acquire)) {
                record.started = true;
                record.run(record);
            }
        }
    }

    pub fn find(self: *Manager, owner: component.InstanceId, key: u64) ?*Record {
        for (self.records.items) |record| {
            if (record.owner == owner and record.key == key and !record.canceled.load(.acquire)) return record;
        }
        return null;
    }
};

fn Wrapper(comptime function: anytype, comptime H: type) type {
    const R = Result(function);
    return struct {
        record: Record,
        args: Args,
        handler: H,
        const Self = @This();
        const Args = std.meta.ArgsTuple(@TypeOf(function));

        fn run(record: *Record) void {
            const self: *Self = @fieldParentPtr("record", record);
            defer {
                const platform = record.core.platform;
                record.done.store(true, .release);
                if (platform) |p| p.requestFrame();
            }
            var task: Task = .{ .io = record.core.io, .gpa = record.arena.allocator(), .record = record };
            self.args[0] = &task;
            if (record.canceled.load(.acquire)) return;
            const result = @call(.auto, function, self.args);
            self.postResult(&task, result) catch |err| std.log.err("app task: dropped result: {t}", .{err});
        }

        fn postResult(self: *Self, task: *Task, result: R) Allocator.Error!void {
            if (@typeInfo(R) == .error_union) {
                if (result) |_| {} else |err| {
                    if (err == error.Canceled) return;
                }
            }
            try task.post(self.handler, result);
        }

        fn complete(record: *Record, tag: component.TypeTag, payload: *const anyopaque) !void {
            if (record.started or record.done.load(.acquire)) return error.TaskAlreadyCompleted;
            if (tag != component.typeTag(R)) return error.TaskResultTypeMismatch;
            const self: *Self = @fieldParentPtr("record", record);
            const result = (try copy(record.arena.allocator(), @as(*const R, @ptrCast(@alignCast(payload))).*)).value;
            var task: Task = .{ .io = record.core.io, .gpa = record.arena.allocator(), .record = record };
            try self.postResult(&task, result);
            record.done.store(true, .release);
        }

        fn destroy(record: *Record) void {
            record.arena.deinit();
            record.core.gpa.destroy(@as(*Self, @fieldParentPtr("record", record)));
        }
    };
}
