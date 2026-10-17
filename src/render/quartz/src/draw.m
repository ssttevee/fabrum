#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <AppKit/AppKit.h>

static NSString *string_from_zig(const char *bytes, size_t len) {
    NSData *data = [NSData dataWithBytes:bytes length:len];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

void quartz_renderer_flip_canvas(CGContextRef context, CGFloat canvas_height) {
    CGContextTranslateCTM(context, 0.0, canvas_height);
    CGContextScaleCTM(context, 1.0, -1.0);
}

void quartz_renderer_save_state(CGContextRef context) {
    CGContextSaveGState(context);
}

void quartz_renderer_restore_state(CGContextRef context) {
    CGContextRestoreGState(context);
}

void quartz_renderer_clip_to_rect(CGContextRef context, CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    CGContextClipToRect(context, CGRectMake(x, y, width, height));
}

void quartz_renderer_fill_rect(
    CGContextRef context,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    CGContextSetRGBFillColor(context, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    CGContextFillRect(context, CGRectMake(x, y, width, height));
}

void quartz_renderer_fill_rounded_rect(
    CGContextRef context,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat top_left,
    CGFloat top_right,
    CGFloat bottom_right,
    CGFloat bottom_left,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    CGContextSetRGBFillColor(context, r / 255.0, g / 255.0, b / 255.0, a / 255.0);

    CGMutablePathRef path = CGPathCreateMutable();

    CGFloat minX = x;
    CGFloat minY = y;
    CGFloat maxX = x + width;
    CGFloat maxY = y + height;

    CGPathMoveToPoint(path, NULL, minX + top_left, minY);
    CGPathAddLineToPoint(path, NULL, maxX - top_right, minY);

    if (top_right > 0) {
        CGPathAddArc(path, NULL, maxX - top_right, minY + top_right, top_right, -M_PI_2, 0, false);
    }

    CGPathAddLineToPoint(path, NULL, maxX, maxY - bottom_right);

    if (bottom_right > 0) {
        CGPathAddArc(path, NULL, maxX - bottom_right, maxY - bottom_right, bottom_right, 0, M_PI_2, false);
    }

    CGPathAddLineToPoint(path, NULL, minX + bottom_left, maxY);

    if (bottom_left > 0) {
        CGPathAddArc(path, NULL, minX + bottom_left, maxY - bottom_left, bottom_left, M_PI_2, M_PI, false);
    }

    CGPathAddLineToPoint(path, NULL, minX, minY + top_left);

    if (top_left > 0) {
        CGPathAddArc(path, NULL, minX + top_left, minY + top_left, top_left, M_PI, M_PI + M_PI_2, false);
    }

    CGPathCloseSubpath(path);

    CGContextAddPath(context, path);
    CGContextFillPath(context);

    CGPathRelease(path);
}

void quartz_renderer_stroke_rect(
    CGContextRef context,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat line_width,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    CGContextSetRGBStrokeColor(context, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    CGContextSetLineWidth(context, line_width);
    CGContextStrokeRect(context, CGRectMake(x, y, width, height));
}

void quartz_renderer_stroke_rounded_rect(
    CGContextRef context,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height,
    CGFloat top_left,
    CGFloat top_right,
    CGFloat bottom_right,
    CGFloat bottom_left,
    CGFloat line_width,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    CGContextSetRGBStrokeColor(context, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
    CGContextSetLineWidth(context, line_width);

    CGMutablePathRef path = CGPathCreateMutable();

    CGFloat minX = x;
    CGFloat minY = y;
    CGFloat maxX = x + width;
    CGFloat maxY = y + height;

    CGPathMoveToPoint(path, NULL, minX + top_left, minY);
    CGPathAddLineToPoint(path, NULL, maxX - top_right, minY);

    if (top_right > 0) {
        CGPathAddArc(path, NULL, maxX - top_right, minY + top_right, top_right, -M_PI_2, 0, false);
    }

    CGPathAddLineToPoint(path, NULL, maxX, maxY - bottom_right);

    if (bottom_right > 0) {
        CGPathAddArc(path, NULL, maxX - bottom_right, maxY - bottom_right, bottom_right, 0, M_PI_2, false);
    }

    CGPathAddLineToPoint(path, NULL, minX + bottom_left, maxY);

    if (bottom_left > 0) {
        CGPathAddArc(path, NULL, minX + bottom_left, maxY - bottom_left, bottom_left, M_PI_2, M_PI, false);
    }

    CGPathAddLineToPoint(path, NULL, minX, minY + top_left);

    if (top_left > 0) {
        CGPathAddArc(path, NULL, minX + top_left, minY + top_left, top_left, M_PI, M_PI + M_PI_2, false);
    }

    CGPathCloseSubpath(path);

    CGContextAddPath(context, path);
    CGContextStrokePath(context);

    CGPathRelease(path);
}

void quartz_renderer_draw_text(
    CGContextRef context,
    const char *text,
    size_t text_len,
    CGFloat x,
    CGFloat y,
    NSFont *font,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    NSString *str = string_from_zig(text, text_len);
    NSColor *color = [NSColor colorWithCalibratedRed:r / 255.0
                                                green:g / 255.0
                                                 blue:b / 255.0
                                                alpha:a / 255.0];

    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    };

    NSLog(@"Drawing text: %@ x=%f y=%f", str, x, y);

    CGContextSaveGState(context);

    NSGraphicsContext *nsContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nsContext];

    [str drawAtPoint:NSMakePoint(x, y) withAttributes:attributes];

    [NSGraphicsContext restoreGraphicsState];
    CGContextRestoreGState(context);
}

void quartz_renderer_draw_path(
    CGContextRef context,
    CGPathRef path,
    CGFloat x,
    CGFloat y,
    CGFloat scale_x,
    CGFloat scale_y,
    uint8_t fill_r,
    uint8_t fill_g,
    uint8_t fill_b,
    uint8_t fill_a,
    uint8_t stroke_r,
    uint8_t stroke_g,
    uint8_t stroke_b,
    uint8_t stroke_a,
    CGFloat stroke_width
) {
    CGContextSaveGState(context);

    CGContextTranslateCTM(context, x, y);
    CGContextScaleCTM(context, scale_x, scale_y);

    CGContextAddPath(context, path);

    if (fill_a > 0) {
        CGContextSetRGBFillColor(context, fill_r / 255.0, fill_g / 255.0, fill_b / 255.0, fill_a / 255.0);
        if (stroke_a > 0 && stroke_width > 0) {
            CGContextSetRGBStrokeColor(context, stroke_r / 255.0, stroke_g / 255.0, stroke_b / 255.0, stroke_a / 255.0);
            CGContextSetLineWidth(context, stroke_width);
            CGContextDrawPath(context, kCGPathFillStroke);
        } else {
            CGContextFillPath(context);
        }
    } else if (stroke_a > 0 && stroke_width > 0) {
        CGContextSetRGBStrokeColor(context, stroke_r / 255.0, stroke_g / 255.0, stroke_b / 255.0, stroke_a / 255.0);
        CGContextSetLineWidth(context, stroke_width);
        CGContextStrokePath(context);
    }

    CGContextRestoreGState(context);
}

CGMutablePathRef quartz_renderer_create_path(void) {
    return CGPathCreateMutable();
}

void quartz_renderer_path_move_to(CGMutablePathRef path, CGFloat x, CGFloat y) {
    CGPathMoveToPoint(path, NULL, x, y);
}

void quartz_renderer_path_line_to(CGMutablePathRef path, CGFloat x, CGFloat y) {
    CGPathAddLineToPoint(path, NULL, x, y);
}

void quartz_renderer_path_curve_to(
    CGMutablePathRef path,
    CGFloat x1,
    CGFloat y1,
    CGFloat x2,
    CGFloat y2,
    CGFloat x,
    CGFloat y
) {
    CGPathAddCurveToPoint(path, NULL, x1, y1, x2, y2, x, y);
}

void quartz_renderer_path_quadratic_to(
    CGMutablePathRef path,
    CGFloat x1,
    CGFloat y1,
    CGFloat x,
    CGFloat y
) {
    CGPathAddQuadCurveToPoint(path, NULL, x1, y1, x, y);
}

void quartz_renderer_path_close(CGMutablePathRef path) {
    CGPathCloseSubpath(path);
}

void quartz_renderer_path_release(CGMutablePathRef path) {
    CGPathRelease(path);
}

void quartz_renderer_draw_image(
    CGContextRef context,
    CGImageRef image,
    CGFloat x,
    CGFloat y,
    CGFloat width,
    CGFloat height
) {
    CGRect rect = CGRectMake(x, y, width, height);
    CGContextDrawImage(context, rect, image);
}

CGImageRef quartz_renderer_cgimage_retain(CGImageRef image) {
    return CGImageRetain(image);
}

void cgimage_release(CGImageRef image) {
    CGImageRelease(image);
}

CGFloat cgimage_get_width(CGImageRef image) {
    return (CGFloat)CGImageGetWidth(image);
}

CGFloat cgimage_get_height(CGImageRef image) {
    return (CGFloat)CGImageGetHeight(image);
}
