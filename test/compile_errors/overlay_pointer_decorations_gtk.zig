const app = @import("fabrum").app;
comptime {
    app.window_policy.validate(.gtk, .{ .pointer = .passthrough });
}
