#include <stdbool.h>
// Drawing for fabrum's Cairo renderer: rectangles, borders and clips into
// any cairo_t whose user space is fabrum's (top left, y down, in points),
// and text through Pango, which GTK's own labels are set with, so drawn
// and native text measure and render alike.
#include <cairo.h>
#include <pango/pangocairo.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// The default font family, which the GTK platform sets from the toolkit's
// `gtk-font-name` so drawn text matches the controls; "Sans" otherwise.
static char default_family[128] = "Sans";

void fabrum_cairo_set_default_family(const char *family, size_t len) {
    if (len >= sizeof default_family) len = sizeof default_family - 1;
    memcpy(default_family, family, len);
    default_family[len] = 0;
}

static void set_source(cairo_t *cr, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    cairo_set_source_rgba(cr, r / 255.0, g / 255.0, b / 255.0, a / 255.0);
}

void fabrum_cairo_save(cairo_t *cr) {
    cairo_save(cr);
}

void fabrum_cairo_restore(cairo_t *cr) {
    cairo_restore(cr);
}

void fabrum_cairo_clip(cairo_t *cr, double x, double y, double w, double h) {
    cairo_rectangle(cr, x, y, w, h);
    cairo_clip(cr);
}

// Clips to the union of `count` rectangles, given as x, y, w, h each.
void fabrum_cairo_clip_rects(cairo_t *cr, const double *rects, size_t count) {
    for (size_t i = 0; i < count; i++) cairo_rectangle(cr, rects[i * 4], rects[i * 4 + 1], rects[i * 4 + 2], rects[i * 4 + 3]);
    cairo_clip(cr);
}

// A path around a rectangle with each corner rounded by its own radius.
static void rounded_path(cairo_t *cr, double x, double y, double w, double h, double tl, double tr, double br, double bl) {
    const double pi = 3.14159265358979323846;
    cairo_new_path(cr);
    cairo_arc(cr, x + w - tr, y + tr, tr, -pi / 2, 0);
    cairo_arc(cr, x + w - br, y + h - br, br, 0, pi / 2);
    cairo_arc(cr, x + bl, y + h - bl, bl, pi / 2, pi);
    cairo_arc(cr, x + tl, y + tl, tl, pi, 3 * pi / 2);
    cairo_close_path(cr);
}

void fabrum_cairo_fill_rect(cairo_t *cr, double x, double y, double w, double h, double tl, double tr, double br, double bl,
                            uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    set_source(cr, r, g, b, a);
    if (tl == 0 && tr == 0 && br == 0 && bl == 0) {
        cairo_rectangle(cr, x, y, w, h);
    } else {
        rounded_path(cr, x, y, w, h, tl, tr, br, bl);
    }
    cairo_fill(cr);
}

// Strokes a rectangle inset by half the line width, so the stroke lies
// inside the box, as fabrum draws borders.
void fabrum_cairo_stroke_rect(cairo_t *cr, double x, double y, double w, double h, double tl, double tr, double br, double bl,
                              double line_width, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    set_source(cr, r, g, b, a);
    cairo_set_line_width(cr, line_width);
    const double half = line_width / 2;
    const double ix = x + half, iy = y + half, iw = w - line_width, ih = h - line_width;
    if (tl == 0 && tr == 0 && br == 0 && bl == 0) {
        cairo_rectangle(cr, ix, iy, iw, ih);
    } else {
        rounded_path(cr, ix, iy, iw, ih, tl > half ? tl - half : 0, tr > half ? tr - half : 0, br > half ? br - half : 0, bl > half ? bl - half : 0);
    }
    cairo_stroke(cr);
}

// Text

// One Pango context for measuring, shared with drawing's font options so
// the two agree.
static PangoContext *measure_context(void) {
    static PangoContext *context;
    if (!context) {
        context = pango_font_map_create_context(pango_cairo_font_map_get_default());
        cairo_font_options_t *options = cairo_font_options_create();
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF);
        pango_cairo_context_set_font_options(context, options);
        cairo_font_options_destroy(options);
    }
    return context;
}

static PangoFontDescription *description(const char *family, size_t family_len, double size, int weight) {
    PangoFontDescription *desc = pango_font_description_new();
    if (family_len > 0) {
        char name[128];
        if (family_len >= sizeof name) family_len = sizeof name - 1;
        memcpy(name, family, family_len);
        name[family_len] = 0;
        pango_font_description_set_family(desc, name);
    } else {
        pango_font_description_set_family(desc, default_family);
    }
    // points are pixels at 96 dpi, which is what fabrum's units are
    pango_font_description_set_absolute_size(desc, size * PANGO_SCALE);
    pango_font_description_set_weight(desc, (PangoWeight)weight);
    return desc;
}

static PangoLayout *layout_for(PangoContext *context, const char *text, size_t len, const char *family, size_t family_len, double size, int weight, double letter_spacing) {
    PangoLayout *layout = pango_layout_new(context);
    PangoFontDescription *desc = description(family, family_len, size, weight);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    pango_layout_set_text(layout, text, (int)len);
    if (letter_spacing != 0) {
        PangoAttrList *attrs = pango_attr_list_new();
        pango_attr_list_insert(attrs, pango_attr_letter_spacing_new((int)(letter_spacing * PANGO_SCALE)));
        pango_layout_set_attributes(layout, attrs);
        pango_attr_list_unref(attrs);
    }
    return layout;
}

// The size of one line of `text`: its logical width and the line's height
// (ascent plus descent of the font, as GtkLabel lays out a line).
void fabrum_cairo_measure(const char *text, size_t len, const char *family, size_t family_len, double size, int weight, double letter_spacing, double *w, double *h) {
    PangoLayout *layout = layout_for(measure_context(), text, len, family, family_len, size, weight, letter_spacing);
    PangoRectangle logical;
    pango_layout_get_extents(layout, NULL, &logical);
    *w = (double)logical.width / PANGO_SCALE;
    *h = (double)logical.height / PANGO_SCALE;
    g_object_unref(layout);
}

// Draws one line of `text` with its top left at (x, y).
void fabrum_cairo_draw_text(cairo_t *cr, const char *text, size_t len, const char *family, size_t family_len, double size, int weight, double letter_spacing,
                            double x, double y, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    PangoLayout *layout = layout_for(measure_context(), text, len, family, family_len, size, weight, letter_spacing);
    set_source(cr, r, g, b, a);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

// Bitmaps, for tests and snapshots: an ARGB32 image surface and a context
// over it, and the PNG it is saved as.

void *fabrum_cairo_image_create(int width, int height, void **context_out) {
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    *context_out = cairo_create(surface);
    return surface;
}

const unsigned char *fabrum_cairo_image_data(void *surface, int *stride_out) {
    cairo_surface_flush((cairo_surface_t *)surface);
    *stride_out = cairo_image_surface_get_stride((cairo_surface_t *)surface);
    return cairo_image_surface_get_data((cairo_surface_t *)surface);
}

bool fabrum_cairo_image_write_png(void *surface, const char *path) {
    return cairo_surface_write_to_png((cairo_surface_t *)surface, path) == CAIRO_STATUS_SUCCESS;
}

void fabrum_cairo_image_destroy(void *surface, void *context) {
    cairo_destroy((cairo_t *)context);
    cairo_surface_destroy((cairo_surface_t *)surface);
}

void fabrum_cairo_clip_axes(cairo_t *cr, double x, double y, double w, double h, bool horizontal, bool vertical) {
    double x0, y0, x1, y1;
    cairo_clip_extents(cr, &x0, &y0, &x1, &y1);
    fabrum_cairo_clip(cr, horizontal ? x : x0, vertical ? y : y0,
        horizontal ? w : x1 - x0, vertical ? h : y1 - y0);
}
