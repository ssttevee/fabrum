const app = @import("fabrum").app;
const Root = struct {
    pub const Props = struct {};
    pub fn view(_: *app.Ui, _: Props) void {}
};
comptime {
    _ = @sizeOf(app.platform.current.Window(Root, .{ .activation = .never }));
}
