// Drawing for fabrum's Quartz renderer, with Core Graphics and Core Text
// alone, into any CGContext whose user space is fabrum's (top left, y down).
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

CTLineRef quartz_renderer_text_line(const char *text, size_t text_len, CTFontRef font);
void quartz_renderer_line_metrics(CTLineRef line, CTFontRef font, double *height_out, double *baseline_out);

// Colors are sRGB, explicitly: a fabrum color means the same on every
// display, and in bitmaps and PDFs of any color space, rather than taking
// the context's device space as `CGContextSetRGBFillColor` does (which on a
// Display P3 screen shows fabrum's (0, 122, 255) as a different blue than
// AppKit's controls, whose colors are tagged).
static CGColorSpaceRef srgb(void) {
    static CGColorSpaceRef space;
    if (!space) space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return space;
}

static void set_fill(CGContextRef context, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    const CGFloat components[] = {r / 255.0, g / 255.0, b / 255.0, a / 255.0};
    CGContextSetFillColorSpace(context, srgb());
    CGContextSetFillColor(context, components);
}

static void set_stroke(CGContextRef context, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    const CGFloat components[] = {r / 255.0, g / 255.0, b / 255.0, a / 255.0};
    CGContextSetStrokeColorSpace(context, srgb());
    CGContextSetStrokeColor(context, components);
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

void quartz_renderer_clip_to_rects(CGContextRef context, const CGRect *rects, size_t count) {
    CGContextClipToRects(context, rects, count);
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
    set_fill(context, r, g, b, a);
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
    set_fill(context, r, g, b, a);

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
    set_stroke(context, r, g, b, a);
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
    set_stroke(context, r, g, b, a);
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

// Draws one line of text with its top left at (x, y), as AppKit draws a
// string at a point in a flipped view: the baseline one ascent down.
void quartz_renderer_draw_text(
    CGContextRef context,
    const char *text,
    size_t text_len,
    CGFloat x,
    CGFloat y,
    CTFontRef font,
    uint8_t r,
    uint8_t g,
    uint8_t b,
    uint8_t a
) {
    CTLineRef line = quartz_renderer_text_line(text, text_len, font);
    if (!line) return;
    double height, baseline;
    quartz_renderer_line_metrics(line, font, &height, &baseline);

    CGContextSaveGState(context);
    set_fill(context, r, g, b, a);
    // y runs down, so glyphs are flipped back up
    CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1, -1));
    CGContextSetTextPosition(context, x, y + baseline);
    CTLineDraw(line, context);
    CGContextRestoreGState(context);
    CFRelease(line);
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
        set_fill(context, fill_r, fill_g, fill_b, fill_a);
        if (stroke_a > 0 && stroke_width > 0) {
            set_stroke(context, stroke_r, stroke_g, stroke_b, stroke_a);
            CGContextSetLineWidth(context, stroke_width);
            CGContextDrawPath(context, kCGPathFillStroke);
        } else {
            CGContextFillPath(context);
        }
    } else if (stroke_a > 0 && stroke_width > 0) {
        set_stroke(context, stroke_r, stroke_g, stroke_b, stroke_a);
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
