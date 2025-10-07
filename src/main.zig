const std = @import("std");
const tvg = @import("thorvg");
const fabrum = @import("fabrum");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Simple hand-authored render command list (no dynamic layout yet).
    // Demonstrates a root background + three child rectangles.
    var ctx = try fabrum.Context.init(allocator, .{});
    defer ctx.deinit(allocator);

    const width = 400;
    const height = 200;

    ctx.begin(.{ .sizing = .fixedXY(width, height) });

    // Initialize ThorVG
    var engines = tvg.Engines.sw;
    try engines.init(0);
    defer engines.deinit();

    try tvg.loadFont("arial.ttf");

    var text = fabrum.TextContent{
        .text = "Hello World",
        .style = .{
            .font = "arial.ttf",
            .measure_fn = fabrum.measureTextThorVG,
        },
    };

    {
        const vert = ctx.openContainerId(.fromString("vertical"), .{
            .background_color = .rgb(0x1f, 0x77, 0xb4),
            .layout = .{
                .axis = .y,
                .padding = .all(10),
                .child_gap = 10,
                .child_alignment = .center,
                .sizing = .grow(.{}),
            },
        });
        defer ctx.closeContainer(vert);

        {
            const outer = ctx.openContainerId(.fromString("bg"), .{
                .layout = .{
                    .child_gap = 10,
                    .child_alignment = .center,
                    .sizing = .grow(.{}),
                },
            });
            defer ctx.closeContainer(outer);

            ctx.closeContainer(ctx.openContainerId(.fromString("child_1"), .{
                .layout = .{
                    .sizing = .fixedXY(80, 120),
                },
                .background_color = .rgb(0xe3, 0x77, 0xc2),
            }));

            ctx.closeContainer(ctx.openContainerId(.fromString("child_2"), .{
                .layout = .{
                    .sizing = .fixed(60),
                },
                .background_color = .rgb(0x8c, 0x6d, 0x31),
            }));

            ctx.closeContainer(ctx.openContainerId(.fromString("child_3"), .{
                .layout = .{
                    .sizing = .fixedXY(100, 80),
                },
                .background_color = .rgb(0xd6, 0x27, 0x28),
            }));
        }

        const text_bg = ctx.openContainer(.{ .background_color = .rgb(0, 255, 0) });
        defer ctx.closeContainer(text_bg);

        ctx.appendContent(&text.content);
    }

    ctx.end();
    ctx.computeLayout();
    var commands = ctx.renderCommands();

    // Create renderer
    var renderer = try fabrum.ThorVGRenderer.init(allocator);
    // defer renderer.deinit();

    // Build the scene
    try renderer.render(&commands);

    const swc = try tvg.SoftwareCanvas.init();
    defer swc.deinit();

    const buf = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(buf);

    try swc.setTarget(@ptrCast(@alignCast(buf)), width, width, height, .abgr8888);

    const canvas = swc.asCanvas();

    // Save to file
    try canvas.push(renderer.scene.asPaint());
    canvas.draw();
    _ = canvas.sync();

    const f = try std.fs.cwd().createFile("hello.ppm", .{});
    defer f.close();

    var wbuf: [1 << 14]u8 = undefined;
    var w = f.writer(&wbuf);

    // TODO: write to disk as PPM
    try w.interface.print("P6\n{d} {d}\n255\n", .{ width, height });
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = buf[(y * width + x) * 4 ..];
            try w.interface.writeAll(pixel[0..3]);
        }
    }
    try w.interface.flush();

    std.log.info("Wrote PNG to hello.ppm\n", .{});
}
