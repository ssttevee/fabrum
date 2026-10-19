//! fabrum hosted by its own program, as on the `none` platform: no window,
//! no toolkit and no renderer. The program is the host, as a VNC proxy, a
//! game overlay or an e-reader's toolkit would be (see
//! `fabrum.app.platform.none`): it feeds input in, runs frames on its own
//! clock, and takes the render commands and the changed regions out. Here
//! they are printed; a real host hands them to a renderer with
//! `fabrum.layout.draw` and shows the pixels.
//!
//! It builds with any `-Dplatform`, since the runtime needs no backend:
//! without one, `app.widgets` are drawn by fabrum (`app.drawn`), and text
//! is measured by `layout.text.HeuristicContent`, which is rough but
//! needs no font.
//!
//!     zig build run-headless
const std = @import("std");
const Io = std.Io;
const fabrum = @import("fabrum");
const app = fabrum.app;
const layout = fabrum.layout;
const Vec2 = fabrum.Vec2;

/// The screen: a count, a button that raises it, and a checkbox.
pub const Root = struct {
    pub const State = struct { count: u32 = 0, flagged: bool = false };
    pub const Msg = union(enum) { more, flag: bool };
    pub const Props = struct {};

    pub fn update(state: *State, msg: Msg, _: *app.Update(Root)) void {
        switch (msg) {
            .more => state.count += 1,
            .flag => |on| state.flagged = on,
        }
    }

    pub fn view(ui: *app.Ui, state: *const State, _: Props) !void {
        const on = ui.messages(Root);
        const theme = ui.use(app.native.Theme);
        try ui.open(null, .{
            .layout = .{ .sizing = .grow(.{}), .axis = .y, .padding = .all(12), .child_gap = 8 },
            .background_color = theme.window_background,
        });
        defer ui.close();
        try ui.print(.{ .font_size = theme.font_size, .color = theme.text }, "clicked {d} times", .{state.count});
        try app.widgets.button(ui, "more", .{ .label = "More", .on_click = on.bind(.more) });
        try app.widgets.checkbox(ui, "flag", .{ .label = if (state.flagged) "Flagged" else "Flag", .checked = state.flagged, .on_change = on.handler(.flag) });
    }
};

/// The runtime with the default text, `layout.text.HeuristicContent`. A
/// host with a renderer passes the renderer's: `.{ .Text = Renderer.Text }`.
const Runtime = app.Runtime(.{});

const viewport: Vec2 = .init(240, 120);

/// What a host keeps: the runtime and its clock.
const Host = struct {
    rt: *Runtime,
    out: *Io.Writer,
    /// The host's clock, which views see as `ui.now()`. A frame apart per
    /// frame here; a real host reads a monotonic clock.
    now: Io.Timestamp = .zero,

    /// Runs the frames that are due, then prints what the last one drew
    /// and which regions changed since the previous print.
    fn frames(self: *Host) !void {
        var ran: usize = 0;
        while (self.rt.nextFrame()) |due| {
            // null means wait for input; a later time means wait until then
            if (due.nanoseconds > self.now.nanoseconds or ran == 4) break;
            _ = try self.rt.frame(Root, .{}, viewport, self.now);
            self.now = self.now.addDuration(.fromMilliseconds(16));
            ran += 1;
        }
        if (ran == 0) return;

        try self.out.print("frame at {d} ms: {d} render commands\n", .{ @divTrunc(self.now.nanoseconds, std.time.ns_per_ms), self.rt.commands().len });
        for (self.rt.commands()) |command| try printCommand(self.out, command);

        // what a renderer must redraw, and how an e-ink host should show it
        const damage = try self.rt.damage();
        try self.out.print("  damage ({t} refresh):", .{self.rt.refresh()});
        for (damage) |r| try self.out.print(" {d:.0}x{d:.0}@{d:.0},{d:.0}", .{ r.w, r.h, r.x, r.y });
        try self.out.writeAll("\n");
    }

    /// Presses and releases the primary button over the element `key` of
    /// the root component, as a pointer would, then runs the frames.
    fn click(self: *Host, key: []const u8) !void {
        const unit = self.rt.context().getUnitById(app.testing.rootInstance(Root).element(key)) orelse return error.NoSuchElement;
        const point = app.testing.center(unit);
        var pressed: app.MouseEvent.Buttons = .empty;
        pressed.set(app.MouseEvent.primary);
        const taken = try self.rt.mouse(.{ .position = point, .pressed = pressed });
        _ = try self.rt.mouse(.{ .position = point });
        try self.out.print("click on \"{s}\" at {d:.0},{d:.0}: {s}\n", .{ key, point.x, point.y, if (taken) "taken by the app" else "passed on" });
        try self.frames();
    }
};

fn printCommand(out: *Io.Writer, command: layout.RenderCommand) !void {
    const box = command.bbox;
    try out.print("  {d:.0}x{d:.0} at {d:.0},{d:.0}: ", .{ box.w, box.h, box.x, box.y });
    switch (command.data) {
        .rectangle => |r| try out.print("rectangle #{x:0>2}{x:0>2}{x:0>2} alpha {d}, radius {d:.0}\n", .{ r.color.r, r.color.g, r.color.b, r.color.a, r.corner_radius.top_left }),
        .border => |b| try out.print("border #{x:0>2}{x:0>2}{x:0>2}, {d:.0} wide\n", .{ b.color.r, b.color.g, b.color.b, b.widths.top }),
        // the runtime's text content is `Runtime.Text`; other content (pictures) is the app's own
        .content => |content| if (Runtime.Text.asTextContent(content)) |text| {
            try out.print("text \"{s}\" at {d:.0}pt\n", .{ text.text, text.style.font_size });
        } else {
            try out.writeAll("content\n");
        },
        .scissor_start => |s| try out.print("clip {s}{s}\n", .{ if (s.horizontal) "x" else "", if (s.vertical) "y" else "" }),
        .scissor_end => try out.writeAll("end clip\n"),
    }
}

pub fn main(init: std.process.Init) !void {
    var out_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &out_buffer);
    const out = &stdout.interface;

    // a touch screen without hover or animation, as an e-reader's; the
    // theme is the default look of drawn widgets
    var rt: Runtime = try .init(init.gpa, .{
        .io = init.io,
        .capabilities = .{ .pointer = .touch, .hover = false, .animation = .none },
    });
    defer rt.deinit();

    var host: Host = .{ .rt = &rt, .out = out };
    try host.frames();
    try host.click("more");
    try host.click("more");
    try host.click("flag");
    try out.flush();
}

test "the host's clicks reach the component, and only what changed is damaged" {
    var rt: Runtime = try .init(std.testing.allocator, .{ .io = std.testing.io });
    defer rt.deinit();
    var sink: Io.Writer.Discarding = .init(&.{});
    var host: Host = .{ .rt = &rt, .out = &sink.writer };

    try host.frames();
    try std.testing.expect(app.testing.findText(Runtime.Text, rt.context(), "clicked 0 times") != null);

    try host.click("more");
    try host.click("more");
    try std.testing.expectEqual(2, rt.rootState(Root).?.count);
    try std.testing.expect(app.testing.findText(Runtime.Text, rt.context(), "clicked 2 times") != null);

    try host.click("flag");
    try std.testing.expect(rt.rootState(Root).?.flagged);

    // nothing changed since the last frame: nothing to redraw, and no frame due
    try std.testing.expectEqual(0, (try rt.damage()).len);
    try std.testing.expectEqual(null, rt.nextFrame());
}
