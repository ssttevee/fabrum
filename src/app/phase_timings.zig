//! CPU wall times for instrumented builds. Runtime use is compiled out unless
//! fabrum is built with phase_timings=true. Runtime-disabled collection performs
//! no clock reads, allocations, or logging.
const std = @import("std");
const Self = @This();

pub const Phase = enum {
    /// Inclusive Runtime.frame time; do not add to its component phases.
    frame,
    messages,
    prepare,
    views,
    /// Includes text measurement performed by computeLayout.
    layout,
    scroll,
    commands,
    /// Includes scene construction and synchronous backend calls.
    reconcile,
    cleanup,
    damage,
    /// Host drawing callback, including command translation. Not GPU time or presentation.
    render,
};

pub const Sample = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
};

enabled: bool = false,
samples: [@typeInfo(Phase).@"enum".field_names.len]Sample = @splat(.{}),

pub fn get(self: *const Self, phase: Phase) Sample {
    return self.samples[@backingInt(phase)];
}

/// Reset counters between workloads. Call on the runtime's owning thread,
/// outside an active measurement. The enabled setting is preserved.
pub fn reset(self: *Self) void {
    self.samples = @splat(.{});
}

pub fn start(self: *const Self, io: std.Io) std.Io.Timestamp {
    return if (self.enabled) std.Io.Clock.awake.now(io) else .zero;
}

pub fn end(self: *Self, io: std.Io, phase: Phase, started: std.Io.Timestamp) void {
    if (!self.enabled) return;
    self.record(phase, @intCast(@max(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), 0)));
}

/// End a consecutive phase and begin the next at the same clock sample.
pub fn lap(self: *Self, io: std.Io, phase: Phase, started: *std.Io.Timestamp) void {
    if (!self.enabled) return;
    const now = std.Io.Clock.awake.now(io);
    self.record(phase, @intCast(@max(started.durationTo(now).toNanoseconds(), 0)));
    started.* = now;
}

fn record(self: *Self, phase: Phase, ns: u64) void {
    const sample = &self.samples[@backingInt(phase)];
    sample.calls += 1;
    sample.total_ns += ns;
    sample.last_ns = ns;
    sample.max_ns = @max(sample.max_ns, ns);
}

test "phase counters aggregate independently and reset without disabling" {
    var timings: Self = .{ .enabled = true };
    timings.record(.views, 20);
    timings.record(.views, 10);
    timings.record(.layout, 7);
    try std.testing.expectEqual(Sample{ .calls = 2, .total_ns = 30, .last_ns = 10, .max_ns = 20 }, timings.get(.views));
    try std.testing.expectEqual(@as(u64, 7), timings.get(.layout).total_ns);
    timings.reset();
    try std.testing.expect(timings.enabled);
    try std.testing.expectEqual(Sample{}, timings.get(.views));
}

test "disabled measurements do not touch the clock or counters" {
    var timings: Self = .{};
    const io: std.Io = undefined;
    var started = timings.start(io);
    timings.lap(io, .views, &started);
    timings.end(io, .frame, started);
    try std.testing.expectEqual(Sample{}, timings.get(.frame));
    try std.testing.expectEqual(Sample{}, timings.get(.views));
}
