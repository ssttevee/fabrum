const std = @import("std");
const fabrum = @import("fabrum");
const SVGPathData = @import("picture/svg.zig");

const LayoutContent = fabrum.layout.Content;
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;

pub const CGImage = opaque {};

pub const Source = union(enum) {
    vector: Vector,
    bitmap: Bitmap,

    pub const Vector = struct {
        path: *SVGPathData.CGPath,
        viewbox: Rect,
        owns_image: bool,
    };

    pub const Bitmap = struct {
        image: *CGImage,
        width: f32,
        height: f32,
        owns_image: bool,
    };
};

source: Source,
style: Style = .{},
content: LayoutContent = .{
    .vtable = vtable,
},

const Picture = @This();

pub const FitMode = enum {
    contain,
    cover,
    crop,
    stretch,
};

pub const Style = struct {
    fit_mode: FitMode = .contain,
    alignment: fabrum.layout.Alignment = .center,
};

const vtable = &LayoutContent.VTable{
    .measure = measureFn,
    .debug_name = "Picture",
};

pub fn isPictureContent(content: *const LayoutContent) bool {
    return content.vtable == vtable;
}

pub fn asPictureContent(content: *const LayoutContent) ?*const Picture {
    if (!isPictureContent(content)) {
        return null;
    }

    return @fieldParentPtr("content", content);
}

pub fn fromSVG(allocator: std.mem.Allocator, svg_data: []const u8) SVGPathData.ParseError!Picture {
    var path_data = try SVGPathData.parse(allocator, svg_data);
    defer path_data.deinit(allocator);

    return .fromSVGPathData(path_data);
}

pub fn fromSVGPathData(path_data: SVGPathData) SVGPathData.ParseError!Picture {
    return .{
        .source = .{
            .vector = .{
                .path = path_data.toCGPath(),
                .viewbox = path_data.viewbox,
                .owns_image = true,
            },
        },
        .style = .{},
        .content = .{
            .vtable = vtable,
        },
    };
}

pub fn fromSVGPath(path: *SVGPathData.CGPath, viewbox: Rect) SVGPathData.ParseError!Picture {
    return .{
        .source = .{
            .vector = .{
                .path = path,
                .viewbox = viewbox,
                .owns_image = true,
            },
        },
        .style = .{},
        .content = .{
            .vtable = vtable,
        },
    };
}

pub fn fromCGImage(image_ref: *CGImage, width: f32, height: f32, owns_image: bool) Picture {
    return .{
        .source = .{
            .bitmap = .{
                .image = image_ref,
                .width = width,
                .height = height,
                .owns_image = owns_image,
            },
        },
        .style = .{},
        .content = .{
            .vtable = vtable,
        },
    };
}

pub fn deinit(self: *Picture) void {
    switch (self.source) {
        .vector => |vector| {
            if (vector.owns_image) {
                vector.path.deinit();
            }
        },
        .bitmap => |bitmap| {
            if (bitmap.owns_image) {
                cgimage_release(bitmap.image);
            }
        },
    }
    self.* = undefined;
}

fn measureFn(content: *const LayoutContent, constraints: fabrum.layout.Constraints) LayoutContent.MeasureError!Vec2 {
    const self: *const Picture = @fieldParentPtr("content", content);

    const intrinsic_width, const intrinsic_height = switch (self.source) {
        .vector => |vector| blk: {
            break :blk .{ vector.viewbox.w, vector.viewbox.h };
        },
        .bitmap => |bitmap| .{ bitmap.width, bitmap.height },
    };

    const max_width = constraints.max_width orelse std.math.floatMax(f32);
    const max_height = constraints.max_height orelse std.math.floatMax(f32);

    const aspect_ratio = intrinsic_width / intrinsic_height;
    const constraint_ratio = max_width / max_height;

    return switch (self.style.fit_mode) {
        .contain => blk: {
            if (aspect_ratio > constraint_ratio) {
                const width = max_width;
                const height = width / aspect_ratio;
                break :blk .init(width, height);
            } else {
                const height = max_height;
                const width = height * aspect_ratio;
                break :blk .init(width, height);
            }
        },
        .cover => blk: {
            if (aspect_ratio > constraint_ratio) {
                const height = max_height;
                const width = height * aspect_ratio;
                break :blk .init(width, height);
            } else {
                const width = max_width;
                const height = width / aspect_ratio;
                break :blk .init(width, height);
            }
        },
        .crop => .init(@min(intrinsic_width, max_width), @min(intrinsic_height, max_height)),
        .stretch => .init(max_width, max_height),
    };
}

extern fn cgimage_release(image_ref: *CGImage) void;
