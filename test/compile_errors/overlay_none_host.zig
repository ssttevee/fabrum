const app = @import("fabrum").app;
comptime {
    app.window_policy.validate(.none, .{ .decorations = .none });
}
