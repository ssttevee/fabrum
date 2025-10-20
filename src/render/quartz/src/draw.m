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
