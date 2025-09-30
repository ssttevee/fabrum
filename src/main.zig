const std = @import("std");
const fabrum = @import("fabrum");

const FramingContext = fabrum.FramingContext(.{});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Simple hand-authored render command list (no dynamic layout yet).
    // Demonstrates a root background + three child rectangles.
    var ctx = try FramingContext.init(allocator);
    defer ctx.deinit(allocator);

    ctx.begin();

    {
        const outer = ctx.openContainer(.{
            .background_color = .rgb(0x1f, 0x77, 0xb4),
            .layout = .{
                .padding = .all(10),
                .child_gap = 10,
                .child_alignment = .center,
            },
        });
        defer ctx.closeElement(outer);

        ctx.closeElement(ctx.openContainer(.{
            .id = "child_1",
            .layout = .{
                .sizing = .fixedXY(80, 120),
            },
            .background_color = .rgb(0xe3, 0x77, 0xc2),
        }));

        ctx.closeElement(ctx.openContainer(.{
            .id = "child_2",
            .layout = .{
                .sizing = .fixed(60),
            },
            .background_color = .rgb(0x8c, 0x6d, 0x31),
        }));

        ctx.closeElement(ctx.openContainer(.{
            .id = "child_3",
            .layout = .{
                .sizing = .fixedXY(100, 80),
            },
            .background_color = .rgb(0xd6, 0x27, 0x28),
        }));
    }

    var commands = ctx.end(400, 200);

    // Render to SVG (with ids shown).
    const svg = try fabrum.SvgRenderer.render(allocator, &commands.iterator, .{
        .show_ids = true,
        .margin = 12,
        .background = .rgba(255, 255, 255, 255),
    });
    defer allocator.free(svg);

    // Determine output path (env HELLO_SVG_OUT overrides).
    var out_path_buf: [256]u8 = undefined;
    const out_path = blk: {
        if (std.process.getEnvVarOwned(allocator, "HELLO_SVG_OUT")) |value| {
            defer allocator.free(value);
            break :blk value;
        } else |_| {
            const d = try std.fmt.bufPrint(&out_path_buf, "hello.svg", .{});
            break :blk d;
        }
    };

    // Write file
    var file = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(svg);

    // Also echo a short notice to stdout.
    std.log.info("Wrote SVG to {s} ({} bytes)\n", .{ out_path, svg.len });
}
