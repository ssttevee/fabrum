// The GTK 4 half of fabrum's GTK platform: one window whose content is an
// overlay of fabrum's base canvas (a GtkDrawingArea drawn by the app's
// renderer) and a GtkFixed host holding GTK's own widgets and more canvas
// layers, placed at the frames fabrum lays out; scrolled windows whose
// documents hold canvases and widgets of their own; the application's
// menu bar, alert and file dialogs, popover menus, the clipboard, frame
// requests, focus routing, the theme, and the in-process automation
// debug scripts use.
//
// Everything is driven from Zig: `gtk.zig` reconciles, and this file only
// makes, changes and arranges GTK objects, and reports what the user did
// through `fabrum_gtk_host`. A port of `appkit/shell.m`.
#include <gtk/gtk.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    void *ctx;
    // Runs a frame for content of `width` by `height` points.
    void (*frame)(void *ctx, double width, double height);
    // Draws canvas layer `layer` into `cr`, whose origin is its top left.
    void (*draw_layer)(void *ctx, unsigned layer, cairo_t *cr, double width, double height);
    // Whether canvas layer `layer` takes pointer input at (x, y), in points
    // from its top left.
    bool (*hit_layer)(void *ctx, unsigned layer, double x, double y);
    // The pointer, in points from the top left of canvas layer `layer`, or
    // of the content if `layer` is -1. Bit 0 of `buttons` is the primary
    // button.
    void (*mouse)(void *ctx, int layer, double x, double y, unsigned buttons, double scroll_x, double scroll_y);
    // Native container `id` scrolled: what it shows starts at (x, y) of its
    // content.
    void (*scroll)(void *ctx, uint64_t id, double x, double y);
    // Tab (forward nonzero) or Shift-Tab, from wherever focus is.
    void (*tab)(void *ctx, int forward);
    // Space or Return while the canvas has focus.
    void (*activate)(void *ctx);
    // What the user did to native element `id`; see `EventKind` in gtk.zig.
    void (*event)(void *ctx, uint64_t id, int kind, double number, const char *text, size_t len);
    // Whether the window may close (`quit` 0) or the app quit (1) now.
    bool (*should_close)(void *ctx, int quit);
    void (*will_terminate)(void *ctx);
} fabrum_gtk_host;

// Called with text, or NULL for none, valid for the call.
typedef void (*fabrum_gtk_text_callback)(void *ctx, const char *text, size_t len);
// Called with the index of the button or item chosen, or -1 for none.
typedef void (*fabrum_gtk_index_callback)(void *ctx, long index);

typedef struct {
    const char *title;
    double width;
    double height;
    double min_width;
    double min_height;
    int dark;
} fabrum_gtk_options;

// One stop in a stacking order, bottom to top.
typedef struct {
    // The canvas layer's index, or -1 for a native widget.
    int canvas;
    void *widget;
} fabrum_gtk_slot;

typedef struct {
    double accent[4], text[4], secondary_text[4], window_background[4], control_background[4], separator[4], focus_ring[4];
    double font_size;
    double control_height;
    int full_keyboard_access;
    int dark;
} fabrum_gtk_theme_values;

// One item of a popup menu, as `app.platform.MenuItem` flattened.
typedef struct {
    const char *title;
    size_t title_len;
    int kind; // 0 item, 1 header, 2 separator, 3 submenu
    long id;
    bool enabled;
    unsigned depth;
} fabrum_gtk_menu_item;

// Kinds of native object, as in gtk.zig's `Kind`.
enum {
    KIND_BUTTON,
    KIND_CHECKBOX,
    KIND_SWITCH,
    KIND_SLIDER,
    KIND_TEXT_FIELD,
    KIND_PROGRESS,
    KIND_MENU_ITEM,
    KIND_ALERT,
    KIND_SCROLL_VIEW,
    KIND_TEXT_AREA,
    KIND_SEARCH_FIELD,
    KIND_SECURE_FIELD,
    KIND_SPINNER,
    KIND_DROPDOWN,
    KIND_RADIO_GROUP,
    KIND_STEPPER,
    KIND_LABEL,
};

// Kinds of event, as in gtk.zig's `EventKind`.
enum {
    EVENT_ACTIVATE,
    EVENT_TOGGLE,
    EVENT_NUMBER,
    EVENT_TEXT,
    EVENT_SUBMIT,
    EVENT_FOCUS,
    EVENT_COMPOSITION_END,
    EVENT_RESPONSE,
    EVENT_SELECT,
};

// A native object: a widget of the host or of a document, a menu item, or
// an alert. Handles are pointers to these.
typedef struct {
    int kind;
    uint64_t id;
    // The widget fabrum places, or NULL for items and alerts.
    GtkWidget *widget;
    // What takes focus and text inside a composite: a text area's text
    // view, a stepper's spin button, a radio group's buttons' box.
    GtkWidget *inner;
    // A scrolled window's document (a GtkFixed) and its content's size.
    GtkWidget *document;
    double content_w, content_h;
    // Where fabrum last put the widget in its parent.
    double x, y;
    // A menu item's action and the menu it is in.
    GSimpleAction *action;
    char *action_name;
    GMenu *menu;
    char *menu_title;
    char *title;
    char *key;
    // An alert: its dialog, what cancels it, and its buttons.
    GtkAlertDialog *alert;
    GCancellable *cancel;
    GPtrArray *buttons;
    bool showing;
    // Whether a field's text is being composed (a pre-edit is up).
    bool composing;
    // Whether a radio group is in a row.
    bool horizontal;
} Object;

static fabrum_gtk_host host;
static GtkApplication *application;
static GtkWindow *window;
static GtkWidget *overlay;
static GtkWidget *host_fixed;
static GPtrArray *canvases;
static atomic_bool frame_requested;
static bool quitting;
static GMenu *menubar;
static fabrum_gtk_options options_copy;
static char title_copy[256];
// The upper canvas layers of the host, top first, which take presses
// where they drew something.
static GArray *host_upper;
// The layer a press was routed to, for the drag and release that follow.
static int captured_layer = -2;
static double last_x, last_y;

static void report(uint64_t id, int kind, double number, const char *text) {
    host.event(host.ctx, id, kind, number, text, text ? strlen(text) : 0);
}

static void run_frame(void) {
    atomic_store(&frame_requested, false);
    if (!overlay) return;
    host.frame(host.ctx, gtk_widget_get_width(overlay), gtk_widget_get_height(overlay));
}

static gboolean run_frame_idle(gpointer data) {
    (void)data;
    if (atomic_load(&frame_requested)) run_frame();
    return G_SOURCE_REMOVE;
}

// Asks for a frame soon. Safe from any thread; requests made before the
// frame runs are coalesced.
void fabrum_gtk_request_frame(void) {
    if (atomic_exchange(&frame_requested, true)) return;
    g_main_context_invoke(NULL, run_frame_idle, NULL);
}

typedef struct {
    void (*callback)(void *ctx);
    void *ctx;
} MainCall;

// Calls a `fabrum_gtk_run_on_main` callback once: it returns nothing, so
// it can't be a GSourceFunc, whose result says whether to call it again.
static gboolean run_main_call(gpointer data) {
    MainCall *call = data;
    call->callback(call->ctx);
    g_free(call);
    return G_SOURCE_REMOVE;
}

void fabrum_gtk_run_on_main(void (*callback)(void *ctx), void *ctx) {
    MainCall *call = g_new(MainCall, 1);
    call->callback = callback;
    call->ctx = ctx;
    g_main_context_invoke(NULL, run_main_call, call);
}

static Object *object_of(void *handle) {
    return (Object *)handle;
}

static Object *object_of_widget(GtkWidget *widget) {
    while (widget) {
        Object *object = g_object_get_data(G_OBJECT(widget), "fabrum-object");
        if (object) return object;
        widget = gtk_widget_get_parent(widget);
    }
    return NULL;
}

static int layer_of(GtkWidget *widget) {
    gpointer data = g_object_get_data(G_OBJECT(widget), "fabrum-layer");
    return data ? GPOINTER_TO_INT(data) - 1 : -1;
}

// Canvas layers

static void canvas_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    host.draw_layer(host.ctx, (unsigned)layer_of(GTK_WIDGET(area)), cr, width, height);
}

static void base_resized(GtkDrawingArea *area, int width, int height, gpointer data) {
    (void)area;
    (void)data;
    if (width > 0 && height > 0 && window) run_frame();
}

static GtkWidget *canvas_at(unsigned layer) {
    while (canvases->len <= layer) {
        GtkWidget *canvas = gtk_drawing_area_new();
        g_object_set_data(G_OBJECT(canvas), "fabrum-layer", GINT_TO_POINTER((int)canvases->len + 1));
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(canvas), canvas_draw, NULL, NULL);
        // input reaches canvases through the host's own controllers
        gtk_widget_set_can_target(canvas, FALSE);
        gtk_widget_set_focusable(canvas, canvases->len == 0);
        g_ptr_array_add(canvases, canvas);
    }
    return g_ptr_array_index(canvases, layer);
}

// Pointer input: the host decides, in the capture phase, whether a press
// goes to an upper canvas layer where it drew something, to a canvas
// under the native widgets (the host's base, or a document's), or on to
// the native widget there.

// The canvas a point of the overlay lands on, if no native widget is
// above it there, with the point in the canvas's coordinates.
static GtkWidget *canvas_under(double x, double y, double *local_x, double *local_y) {
    for (guint i = 0; host_upper && i < host_upper->len; i++) {
        unsigned layer = g_array_index(host_upper, unsigned, i);
        if (host.hit_layer(host.ctx, layer, x, y)) {
            *local_x = x;
            *local_y = y;
            return canvas_at(layer);
        }
    }
    GtkWidget *picked = gtk_widget_pick(overlay, x, y, GTK_PICK_DEFAULT);
    // a document's canvas can't be picked (it isn't targetable): look
    // under the picked fixed for a base canvas there
    while (picked && picked != overlay) {
        if (GTK_IS_FIXED(picked)) {
            for (GtkWidget *child = gtk_widget_get_first_child(picked); child; child = gtk_widget_get_next_sibling(child)) {
                if (layer_of(child) >= 0) {
                    graphene_point_t in, out;
                    graphene_point_init(&in, x, y);
                    if (gtk_widget_compute_point(overlay, child, &in, &out)) {
                        *local_x = out.x;
                        *local_y = out.y;
                        return child;
                    }
                }
            }
            return NULL;
        }
        if (!GTK_IS_SCROLLED_WINDOW(picked) && !GTK_IS_VIEWPORT(picked) && GTK_IS_WIDGET(picked) && object_of_widget(picked)) return NULL;
        picked = gtk_widget_get_parent(picked);
    }
    // nothing native: the host's base canvas
    *local_x = x;
    *local_y = y;
    return canvas_at(0);
}

static void pressed(GtkGestureClick *gesture, int n, double x, double y, gpointer data) {
    (void)n;
    (void)data;
    double lx, ly;
    GtkWidget *canvas = canvas_under(x, y, &lx, &ly);
    if (!canvas) {
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_DENIED);
        captured_layer = -2;
        return;
    }
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    captured_layer = layer_of(canvas);
    // a press on drawn content takes keyboard focus from native widgets,
    // as a click on a canvas does
    if (captured_layer == 0 && gtk_window_get_focus(window) && !gtk_widget_has_focus(canvas_at(0))) gtk_widget_grab_focus(canvas_at(0));
    host.mouse(host.ctx, captured_layer, lx, ly, 1, 0, 0);
}

static void released(GtkGestureClick *gesture, int n, double x, double y, gpointer data) {
    (void)gesture;
    (void)n;
    (void)data;
    if (captured_layer < 0) return;
    double lx = x, ly = y;
    GtkWidget *canvas = canvas_at((unsigned)captured_layer);
    graphene_point_t in, out;
    graphene_point_init(&in, x, y);
    if (gtk_widget_compute_point(overlay, canvas, &in, &out)) {
        lx = out.x;
        ly = out.y;
    }
    host.mouse(host.ctx, captured_layer, lx, ly, 0, 0, 0);
    captured_layer = -2;
}

static void moved(GtkEventControllerMotion *controller, double x, double y, gpointer data) {
    (void)controller;
    (void)data;
    last_x = x;
    last_y = y;
    if (captured_layer >= 0) {
        GtkWidget *canvas = canvas_at((unsigned)captured_layer);
        graphene_point_t in, out;
        graphene_point_init(&in, x, y);
        if (gtk_widget_compute_point(overlay, canvas, &in, &out)) host.mouse(host.ctx, captured_layer, out.x, out.y, 1, 0, 0);
        return;
    }
    host.mouse(host.ctx, -1, x, y, 0, 0, 0);
}

static void left(GtkEventControllerMotion *controller, gpointer data) {
    (void)controller;
    (void)data;
    host.mouse(host.ctx, -1, -1e6, -1e6, 0, 0, 0);
}

static gboolean scrolled_wheel(GtkEventControllerScroll *controller, double dx, double dy, gpointer data) {
    (void)data;
    double lx, ly;
    GtkWidget *canvas = canvas_under(last_x, last_y, &lx, &ly);
    if (!canvas) return FALSE;
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    double unit = (event && gdk_scroll_event_get_unit(event) == GDK_SCROLL_UNIT_WHEEL) ? 40 : 1;
    host.mouse(host.ctx, layer_of(canvas), lx, ly, 0, dx * unit, dy * unit);
    // a document's canvas: on to its scrolled window
    return layer_of(canvas) == 0 || (host_upper && host_upper->len > 0 && gtk_widget_get_parent(canvas) == host_fixed);
}

// Keys: fabrum owns the Tab order, and the canvas's Space and Return
// click the focused drawn element.
static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)controller;
    (void)keycode;
    (void)data;
    if (keyval == GDK_KEY_Tab || keyval == GDK_KEY_ISO_Left_Tab || keyval == GDK_KEY_KP_Tab) {
        host.tab(host.ctx, keyval == GDK_KEY_Tab && !(state & GDK_SHIFT_MASK));
        return TRUE;
    }
    GtkWidget *focus = gtk_window_get_focus(window);
    if (focus && layer_of(focus) == 0 && (keyval == GDK_KEY_space || keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter)) {
        host.activate(host.ctx);
        return TRUE;
    }
    return FALSE;
}

// The window

static gboolean close_requested(GtkWindow *w, gpointer data) {
    (void)w;
    (void)data;
    if (quitting) return FALSE;
    // closing the window is quitting: there is one window
    return host.should_close(host.ctx, 1) ? FALSE : TRUE;
}

static void shutdown_(GApplication *app, gpointer data) {
    (void)app;
    (void)data;
    host.will_terminate(host.ctx);
}

static void startup(GtkApplication *app, gpointer data) {
    (void)data;
    // the menu bar can only be set once the application is registered
    gtk_application_set_menubar(app, G_MENU_MODEL(menubar));
}

static void activate(GtkApplication *app, gpointer data) {
    (void)data;
    window = GTK_WINDOW(gtk_application_window_new(app));
    gtk_application_window_set_show_menubar(GTK_APPLICATION_WINDOW(window), TRUE);
    gtk_window_set_title(window, title_copy);
    gtk_window_set_default_size(window, (int)options_copy.width, (int)options_copy.height);
    gtk_widget_set_size_request(GTK_WIDGET(window), (int)options_copy.min_width, (int)options_copy.min_height);
    g_signal_connect(window, "close-request", G_CALLBACK(close_requested), NULL);

    overlay = gtk_overlay_new();
    GtkWidget *base = canvas_at(0);
    gtk_widget_set_hexpand(base, TRUE);
    gtk_widget_set_vexpand(base, TRUE);
    g_signal_connect(base, "resize", G_CALLBACK(base_resized), NULL);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), base);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), host_fixed);
    gtk_widget_set_halign(host_fixed, GTK_ALIGN_FILL);
    gtk_widget_set_valign(host_fixed, GTK_ALIGN_FILL);
    gtk_window_set_child(window, overlay);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(click), GTK_PHASE_CAPTURE);
    g_signal_connect(click, "pressed", G_CALLBACK(pressed), NULL);
    g_signal_connect(click, "released", G_CALLBACK(released), NULL);
    gtk_widget_add_controller(overlay, GTK_EVENT_CONTROLLER(click));
    GtkEventController *motion = gtk_event_controller_motion_new();
    gtk_event_controller_set_propagation_phase(motion, GTK_PHASE_CAPTURE);
    g_signal_connect(motion, "motion", G_CALLBACK(moved), NULL);
    g_signal_connect(motion, "leave", G_CALLBACK(left), NULL);
    gtk_widget_add_controller(overlay, motion);
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    gtk_event_controller_set_propagation_phase(scroll, GTK_PHASE_CAPTURE);
    g_signal_connect(scroll, "scroll", G_CALLBACK(scrolled_wheel), NULL);
    gtk_widget_add_controller(overlay, scroll);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), NULL);
    gtk_widget_add_controller(GTK_WIDGET(window), keys);

    if (options_copy.dark) g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", TRUE, NULL);
    gtk_window_present(window);
    // the first frame, once the base canvas has its size
}

// Makes what native objects need before the window exists: the host and
// the canvases, since views are reconciled from the first frame on.
static void prepare(void) {
    // the runtime reads the theme, and may make widgets, before `run`
    if (!gtk_is_initialized()) gtk_init();
    if (!canvases) canvases = g_ptr_array_new();
    if (!host_fixed) host_fixed = gtk_fixed_new();
    if (!host_upper) host_upper = g_array_new(FALSE, FALSE, sizeof(unsigned));
    if (!menubar) menubar = g_menu_new();
}

// Runs the app until it quits. Never returns.
void fabrum_gtk_run(fabrum_gtk_options options, fabrum_gtk_host new_host) {
    host = new_host;
    options_copy = options;
    g_strlcpy(title_copy, options.title, sizeof title_copy);
    prepare();
    application = gtk_application_new("org.fabrum.app", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(application, "startup", G_CALLBACK(startup), NULL);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    g_signal_connect(application, "shutdown", G_CALLBACK(shutdown_), NULL);
    int status = g_application_run(G_APPLICATION(application), 0, NULL);
    exit(status);
}

// Quits as the application's Quit would: asking the app first.
void fabrum_gtk_quit(void) {
    if (!application) return;
    if (!host.should_close(host.ctx, 1)) return;
    quitting = true;
    g_application_quit(G_APPLICATION(application));
}

// Quits without asking the app: it has confirmed.
void fabrum_gtk_quit_now(void) {
    quitting = true;
    g_application_quit(G_APPLICATION(application));
}

// Services: dialogs, the popup menu, the file chooser, the clipboard.

static void message_timeout(gpointer data) {
    g_cancellable_cancel(G_CANCELLABLE(data));
    g_object_unref(data);
}

void fabrum_gtk_message(const char *title, size_t title_len, const char *text, size_t text_len, int kind, unsigned timeout_ms) {
    (void)kind;
    char *t = g_strndup(title, title_len);
    char *d = g_strndup(text, text_len);
    GtkAlertDialog *dialog = gtk_alert_dialog_new("%s", t);
    gtk_alert_dialog_set_detail(dialog, d);
    const char *buttons[] = {"OK", NULL};
    gtk_alert_dialog_set_buttons(dialog, buttons);
    GCancellable *cancel = g_cancellable_new();
    gtk_alert_dialog_choose(dialog, window, cancel, NULL, NULL);
    if (timeout_ms > 0) g_timeout_add_once(timeout_ms, message_timeout, g_object_ref(cancel));
    g_object_unref(cancel);
    g_object_unref(dialog);
    g_free(t);
    g_free(d);
}

typedef struct {
    fabrum_gtk_index_callback done;
    void *ctx;
    bool answered;
    GCancellable *cancel;
    GtkAlertDialog *dialog;
} PendingChoice;

static PendingChoice *pending_confirm;

static void confirm_done(GObject *source, GAsyncResult *result, gpointer data) {
    PendingChoice *pending = data;
    GError *error = NULL;
    int index = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    if (pending_confirm == pending) pending_confirm = NULL;
    if (!pending->answered) pending->done(pending->ctx, error ? -1 : index);
    g_object_unref(pending->cancel);
    g_free(pending);
}

// Asks with up to three buttons, the one at `default_index` answering
// Return, and calls `done` with the index pressed, or -1 if dismissed.
void fabrum_gtk_confirm(const char *title, size_t title_len, const char *text, size_t text_len, const char *const *buttons, const size_t *lengths, size_t count,
                        size_t default_index, int kind, fabrum_gtk_index_callback done, void *ctx) {
    (void)kind;
    char *t = g_strndup(title, title_len);
    char *d = g_strndup(text, text_len);
    GtkAlertDialog *dialog = gtk_alert_dialog_new("%s", t);
    gtk_alert_dialog_set_detail(dialog, d);
    const char *labels[4] = {NULL, NULL, NULL, NULL};
    char *owned[3] = {NULL, NULL, NULL};
    for (size_t i = 0; i < count && i < 3; i++) labels[i] = owned[i] = g_strndup(buttons[i], lengths[i]);
    gtk_alert_dialog_set_buttons(dialog, labels);
    gtk_alert_dialog_set_default_button(dialog, (int)default_index);
    PendingChoice *pending = g_new0(PendingChoice, 1);
    pending->done = done;
    pending->ctx = ctx;
    pending->cancel = g_cancellable_new();
    pending->dialog = dialog;
    pending_confirm = pending;
    gtk_alert_dialog_choose(dialog, window, pending->cancel, confirm_done, pending);
    g_object_unref(dialog);
    for (size_t i = 0; i < 3; i++) g_free(owned[i]);
    g_free(t);
    g_free(d);
}

// The popup menu being shown, answering once.
typedef struct {
    fabrum_gtk_index_callback done;
    void *ctx;
    bool answered;
    GtkWidget *popover;
    GSimpleActionGroup *actions;
} Popup;

static Popup *popup;

static void popup_answer(Popup *p, long index) {
    if (p->answered) return;
    p->answered = true;
    if (popup == p) popup = NULL;
    p->done(p->ctx, index);
}

static void popup_chosen(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)parameter;
    const char *name = g_action_get_name(G_ACTION(action));
    popup_answer(data, strtol(name + 1, NULL, 10));
}

static gboolean popup_free(gpointer data) {
    Popup *p = data;
    popup_answer(p, -1);
    gtk_widget_unparent(p->popover);
    g_object_unref(p->actions);
    g_free(p);
    return G_SOURCE_REMOVE;
}

static void popup_closed(GtkPopover *popover, gpointer data) {
    (void)popover;
    // the chosen item's action comes after the menu closes: give it a turn
    g_idle_add(popup_free, data);
}

static GMenu *build_popup(Popup *p, const fabrum_gtk_menu_item *items, size_t count, size_t *index, unsigned depth) {
    GMenu *menu = g_menu_new();
    GMenu *section = g_menu_new();
    char *section_label = NULL;
    while (*index < count) {
        const fabrum_gtk_menu_item *item = &items[*index];
        if (item->depth < depth) break;
        (*index)++;
        char *title = g_strndup(item->title, item->title_len);
        switch (item->kind) {
        case 1: // header: a labelled section follows
            if (g_menu_model_get_n_items(G_MENU_MODEL(section)) > 0 || section_label) {
                g_menu_append_section(menu, section_label, G_MENU_MODEL(section));
                g_object_unref(section);
                section = g_menu_new();
            }
            g_free(section_label);
            section_label = g_strdup(title);
            break;
        case 2: // separator: a new section
            g_menu_append_section(menu, section_label, G_MENU_MODEL(section));
            g_object_unref(section);
            section = g_menu_new();
            g_free(section_label);
            section_label = NULL;
            break;
        case 3: { // submenu: the items one deeper follow
            GMenu *sub = build_popup(p, items, count, index, depth + 1);
            g_menu_append_submenu(section, title, G_MENU_MODEL(sub));
            g_object_unref(sub);
            break;
        }
        default: {
            char *name = g_strdup_printf("i%ld", item->id);
            GSimpleAction *action = g_simple_action_new(name, NULL);
            g_simple_action_set_enabled(action, item->enabled);
            g_signal_connect(action, "activate", G_CALLBACK(popup_chosen), p);
            g_action_map_add_action(G_ACTION_MAP(p->actions), G_ACTION(action));
            char *detailed = g_strdup_printf("popup.%s", name);
            g_menu_append(section, title, detailed);
            g_free(detailed);
            g_free(name);
            g_object_unref(action);
        }
        }
        g_free(title);
    }
    g_menu_append_section(menu, section_label, G_MENU_MODEL(section));
    g_object_unref(section);
    g_free(section_label);
    return menu;
}

static gboolean popup_show(gpointer data) {
    Popup *p = data;
    if (popup != p) return G_SOURCE_REMOVE;
    gtk_popover_popup(GTK_POPOVER(p->popover));
    return G_SOURCE_REMOVE;
}

// Shows a popover menu with its top left at (x, y) of the content, and
// calls `done` with the id of the item chosen, or -1 if dismissed; it
// opens from the next turn of the loop.
void fabrum_gtk_popup_menu(const fabrum_gtk_menu_item *items, size_t count, double x, double y, fabrum_gtk_index_callback done, void *ctx) {
    prepare();
    Popup *p = g_new0(Popup, 1);
    p->done = done;
    p->ctx = ctx;
    p->actions = g_simple_action_group_new();
    size_t index = 0;
    GMenu *model = build_popup(p, items, count, &index, 0);
    p->popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(model));
    g_object_unref(model);
    gtk_widget_insert_action_group(p->popover, "popup", G_ACTION_GROUP(p->actions));
    gtk_widget_set_parent(p->popover, host_fixed);
    GdkRectangle at = {(int)x, (int)y, 1, 1};
    gtk_popover_set_pointing_to(GTK_POPOVER(p->popover), &at);
    gtk_popover_set_has_arrow(GTK_POPOVER(p->popover), FALSE);
    gtk_popover_set_position(GTK_POPOVER(p->popover), GTK_POS_BOTTOM);
    g_signal_connect(p->popover, "closed", G_CALLBACK(popup_closed), p);
    if (popup) popup_answer(popup, -1);
    popup = p;
    g_idle_add(popup_show, p);
}

// The file chooser being shown, if any.
typedef struct {
    fabrum_gtk_text_callback done;
    void *ctx;
    bool answered;
    GCancellable *cancel;
} PendingFile;

static PendingFile *pending_file;

static void file_done(GObject *source, GAsyncResult *result, gpointer data) {
    PendingFile *pending = data;
    GError *error = NULL;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    if (pending_file == pending) pending_file = NULL;
    if (!pending->answered) {
        char *path = file ? g_file_get_path(file) : NULL;
        pending->done(pending->ctx, path, path ? strlen(path) : 0);
        g_free(path);
    }
    if (file) g_object_unref(file);
    g_object_unref(pending->cancel);
    g_free(pending);
}

// Shows a chooser for one existing file with `extensions` (or any), and
// calls `done` with its path, or NULL if cancelled.
void fabrum_gtk_open_file(const char *message, size_t message_len, const char *const *extensions, const size_t *lengths, size_t count,
                          fabrum_gtk_text_callback done, void *ctx) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    char *title = g_strndup(message, message_len);
    gtk_file_dialog_set_title(dialog, title);
    g_free(title);
    if (count > 0) {
        GtkFileFilter *filter = gtk_file_filter_new();
        gtk_file_filter_set_name(filter, "Supported files");
        for (size_t i = 0; i < count; i++) {
            char *suffix = g_strndup(extensions[i], lengths[i]);
            gtk_file_filter_add_suffix(filter, suffix);
            g_free(suffix);
        }
        GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter);
        gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
        gtk_file_dialog_set_default_filter(dialog, filter);
        g_object_unref(filters);
        g_object_unref(filter);
    }
    if (pending_file) {
        pending_file->answered = true;
        pending_file->done(pending_file->ctx, NULL, 0);
        g_cancellable_cancel(pending_file->cancel);
    }
    PendingFile *pending = g_new0(PendingFile, 1);
    pending->done = done;
    pending->ctx = ctx;
    pending->cancel = g_cancellable_new();
    pending_file = pending;
    gtk_file_dialog_open(dialog, window, pending->cancel, file_done, pending);
    g_object_unref(dialog);
}

static GdkClipboard *clipboard(void) {
    prepare();
    return gtk_widget_get_clipboard(window ? GTK_WIDGET(window) : host_fixed);
}

void fabrum_gtk_write_clipboard(const char *bytes, size_t len) {
    char *text = g_strndup(bytes, len);
    gdk_clipboard_set_text(clipboard(), text);
    g_free(text);
}

typedef struct {
    fabrum_gtk_text_callback done;
    void *ctx;
} PendingRead;

static void clipboard_read(GObject *source, GAsyncResult *result, gpointer data) {
    PendingRead *pending = data;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, NULL);
    pending->done(pending->ctx, text, text ? strlen(text) : 0);
    g_free(text);
    g_free(pending);
}

// Reads the clipboard's text, asynchronously, and calls `done` with it
// (NULL for none).
void fabrum_gtk_read_clipboard(fabrum_gtk_text_callback done, void *ctx) {
    PendingRead *pending = g_new0(PendingRead, 1);
    pending->done = done;
    pending->ctx = ctx;
    gdk_clipboard_read_text_async(clipboard(), NULL, clipboard_read, pending);
}

// Native objects

static void clicked(GtkButton *button, gpointer data) {
    (void)button;
    report(object_of(data)->id, EVENT_ACTIVATE, 0, NULL);
}

static void toggled(GtkCheckButton *button, gpointer data) {
    report(object_of(data)->id, EVENT_TOGGLE, gtk_check_button_get_active(button), NULL);
}

static void switched(GObject *sw, GParamSpec *spec, gpointer data) {
    (void)spec;
    report(object_of(data)->id, EVENT_TOGGLE, gtk_switch_get_active(GTK_SWITCH(sw)), NULL);
}

static void value_changed(GtkRange *range, gpointer data) {
    report(object_of(data)->id, EVENT_NUMBER, gtk_range_get_value(range), NULL);
}

static void spin_changed(GtkSpinButton *spin, gpointer data) {
    report(object_of(data)->id, EVENT_NUMBER, gtk_spin_button_get_value(spin), NULL);
}

static void entry_changed(GtkEditable *editable, gpointer data) {
    Object *object = data;
    // the pre-edit isn't the field's text yet
    if (object->composing) return;
    report(object->id, EVENT_TEXT, 0, gtk_editable_get_text(editable));
}

static void entry_activated(GtkEntry *entry, gpointer data) {
    (void)entry;
    report(object_of(data)->id, EVENT_SUBMIT, 0, NULL);
}

// GtkText and GtkTextView tell of their pre-edit (an input method's
// composition): while one is up, writes are held and changes aren't
// reported; its end reports the text and the end of the composition.
static void preedit_changed(GtkWidget *text, const char *preedit, gpointer data) {
    Object *object = data;
    bool composing = preedit && *preedit;
    if (object->composing && !composing) {
        object->composing = false;
        if (GTK_IS_TEXT_VIEW(text)) {
            GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(text));
            GtkTextIter start, end;
            gtk_text_buffer_get_bounds(buffer, &start, &end);
            char *all = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
            report(object->id, EVENT_TEXT, 0, all);
            g_free(all);
        } else {
            report(object->id, EVENT_TEXT, 0, gtk_editable_get_text(GTK_EDITABLE(object->widget)));
        }
        report(object->id, EVENT_COMPOSITION_END, 0, NULL);
    }
    object->composing = composing;
}

static void buffer_changed(GtkTextBuffer *buffer, gpointer data) {
    Object *object = data;
    if (object->composing) return;
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *all = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    report(object->id, EVENT_TEXT, 0, all);
    g_free(all);
}

static void focus_changed(GObject *widget, GParamSpec *spec, gpointer data) {
    (void)spec;
    if (gtk_widget_has_focus(GTK_WIDGET(widget))) report(object_of(data)->id, EVENT_FOCUS, 1, NULL);
}

static void selected_changed(GObject *dropdown, GParamSpec *spec, gpointer data) {
    (void)spec;
    guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown));
    if (selected != GTK_INVALID_LIST_POSITION) report(object_of(data)->id, EVENT_SELECT, selected, NULL);
}

static void radio_toggled(GtkCheckButton *button, gpointer data) {
    if (!gtk_check_button_get_active(button)) return;
    int index = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(object_of(data)->inner); child; child = gtk_widget_get_next_sibling(child), index++) {
        if (child == GTK_WIDGET(button)) report(object_of(data)->id, EVENT_SELECT, index, NULL);
    }
}

static void menu_activated(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    (void)parameter;
    report(object_of(data)->id, EVENT_ACTIVATE, 0, NULL);
}

static void scrolled_to(GtkAdjustment *adjustment, gpointer data) {
    (void)adjustment;
    Object *object = data;
    GtkScrolledWindow *sw = GTK_SCROLLED_WINDOW(object->widget);
    host.scroll(host.ctx, object->id, gtk_adjustment_get_value(gtk_scrolled_window_get_hadjustment(sw)), gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(sw)));
}

static void watch_focus(GtkWidget *widget, Object *object) {
    g_signal_connect(widget, "notify::has-focus", G_CALLBACK(focus_changed), object);
}

static void connect_entry(Object *object, GtkWidget *entry) {
    g_signal_connect(entry, "changed", G_CALLBACK(entry_changed), object);
    if (GTK_IS_ENTRY(entry)) g_signal_connect(entry, "activate", G_CALLBACK(entry_activated), object);
    if (GTK_IS_SEARCH_ENTRY(entry)) g_signal_connect(entry, "activate", G_CALLBACK(entry_activated), object);
    GtkWidget *text = GTK_WIDGET(gtk_editable_get_delegate(GTK_EDITABLE(entry)));
    if (text && GTK_IS_TEXT(text)) {
        g_signal_connect(text, "preedit-changed", G_CALLBACK(preedit_changed), object);
        watch_focus(text, object);
    } else {
        watch_focus(entry, object);
    }
}

// Every object made and not destroyed, for automation that looks for
// alerts and menu items.
static GPtrArray *all_objects;

void *fabrum_gtk_create(int kind, uint64_t element) {
    prepare();
    if (!all_objects) all_objects = g_ptr_array_new();
    Object *object = g_new0(Object, 1);
    object->kind = kind;
    object->id = element;
    g_ptr_array_add(all_objects, object);
    GtkWidget *w = NULL;
    switch (kind) {
    case KIND_BUTTON:
        w = gtk_button_new_with_label("");
        g_signal_connect(w, "clicked", G_CALLBACK(clicked), object);
        watch_focus(w, object);
        break;
    case KIND_CHECKBOX:
        w = gtk_check_button_new_with_label("");
        g_signal_connect(w, "toggled", G_CALLBACK(toggled), object);
        watch_focus(w, object);
        break;
    case KIND_SWITCH:
        w = gtk_switch_new();
        g_signal_connect(w, "notify::active", G_CALLBACK(switched), object);
        watch_focus(w, object);
        break;
    case KIND_SLIDER:
        w = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01);
        gtk_scale_set_draw_value(GTK_SCALE(w), FALSE);
        gtk_widget_set_size_request(w, 96, -1);
        g_signal_connect(w, "value-changed", G_CALLBACK(value_changed), object);
        watch_focus(w, object);
        break;
    case KIND_TEXT_FIELD:
        w = gtk_entry_new();
        connect_entry(object, w);
        break;
    case KIND_SEARCH_FIELD:
        w = gtk_search_entry_new();
        connect_entry(object, w);
        break;
    case KIND_SECURE_FIELD:
        w = gtk_password_entry_new();
        gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(w), TRUE);
        connect_entry(object, w);
        break;
    case KIND_TEXT_AREA: {
        w = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(w), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(w), TRUE);
        GtkWidget *view = gtk_text_view_new();
        gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
        gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 4);
        gtk_text_view_set_right_margin(GTK_TEXT_VIEW(view), 4);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(w), view);
        object->inner = view;
        g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), "changed", G_CALLBACK(buffer_changed), object);
        g_signal_connect(view, "preedit-changed", G_CALLBACK(preedit_changed), object);
        watch_focus(view, object);
        break;
    }
    case KIND_PROGRESS:
        w = gtk_progress_bar_new();
        gtk_widget_set_size_request(w, 96, -1);
        gtk_widget_set_valign(w, GTK_ALIGN_CENTER);
        break;
    case KIND_SPINNER:
        w = gtk_spinner_new();
        gtk_spinner_start(GTK_SPINNER(w));
        break;
    case KIND_DROPDOWN:
        w = gtk_drop_down_new(NULL, NULL);
        g_signal_connect(w, "notify::selected", G_CALLBACK(selected_changed), object);
        watch_focus(w, object);
        break;
    case KIND_RADIO_GROUP:
        w = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        object->inner = w;
        break;
    case KIND_STEPPER:
        w = gtk_spin_button_new_with_range(0, 100, 1);
        object->inner = w;
        g_signal_connect(w, "value-changed", G_CALLBACK(spin_changed), object);
        watch_focus(w, object);
        break;
    case KIND_LABEL:
        w = gtk_label_new("");
        gtk_label_set_xalign(GTK_LABEL(w), 0);
        break;
    case KIND_SCROLL_VIEW: {
        w = gtk_scrolled_window_new();
        object->document = gtk_fixed_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(w), object->document);
        g_signal_connect(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(w)), "value-changed", G_CALLBACK(scrolled_to), object);
        g_signal_connect(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(w)), "value-changed", G_CALLBACK(scrolled_to), object);
        break;
    }
    case KIND_MENU_ITEM: {
        object->action_name = g_strdup_printf("item%" PRIu64, element);
        object->action = g_simple_action_new(object->action_name, NULL);
        g_signal_connect(object->action, "activate", G_CALLBACK(menu_activated), object);
        g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(object->action));
        break;
    }
    case KIND_ALERT:
        object->buttons = g_ptr_array_new_with_free_func(g_free);
        object->cancel = g_cancellable_new();
        break;
    }
    if (w) {
        object->widget = w;
        g_object_ref_sink(w);
        g_object_set_data(G_OBJECT(w), "fabrum-object", object);
    }
    return object;
}

static void menu_remove_item(Object *object) {
    if (!object->menu) return;
    int n = g_menu_model_get_n_items(G_MENU_MODEL(object->menu));
    for (int i = 0; i < n; i++) {
        GVariant *action = g_menu_model_get_item_attribute_value(G_MENU_MODEL(object->menu), i, G_MENU_ATTRIBUTE_ACTION, G_VARIANT_TYPE_STRING);
        if (!action) continue;
        bool match = g_str_has_suffix(g_variant_get_string(action, NULL), object->action_name);
        g_variant_unref(action);
        if (match) {
            g_menu_remove(object->menu, i);
            break;
        }
    }
    // drop a menu fabrum made once it is empty
    if (g_menu_model_get_n_items(G_MENU_MODEL(object->menu)) == 0) {
        int bars = g_menu_model_get_n_items(G_MENU_MODEL(menubar));
        for (int i = 0; i < bars; i++) {
            GVariant *label = g_menu_model_get_item_attribute_value(G_MENU_MODEL(menubar), i, G_MENU_ATTRIBUTE_LABEL, G_VARIANT_TYPE_STRING);
            bool match = label && object->menu_title && strcmp(g_variant_get_string(label, NULL), object->menu_title) == 0;
            if (label) g_variant_unref(label);
            if (match) {
                g_menu_remove(menubar, i);
                break;
            }
        }
    }
    g_object_unref(object->menu);
    object->menu = NULL;
}

static void alert_dismiss(Object *object);

void fabrum_gtk_destroy(void *handle) {
    Object *object = object_of(handle);
    g_ptr_array_remove(all_objects, object);
    if (object->widget) {
        GtkWidget *parent = gtk_widget_get_parent(object->widget);
        if (parent && GTK_IS_FIXED(parent)) gtk_fixed_remove(GTK_FIXED(parent), object->widget);
        g_object_unref(object->widget);
    }
    if (object->action) {
        menu_remove_item(object);
        g_action_map_remove_action(G_ACTION_MAP(application), object->action_name);
        g_object_unref(object->action);
    }
    if (object->alert) alert_dismiss(object);
    if (object->cancel) g_object_unref(object->cancel);
    if (object->buttons) g_ptr_array_unref(object->buttons);
    g_free(object->action_name);
    g_free(object->menu_title);
    g_free(object->title);
    g_free(object->key);
    g_free(object);
}

static char *string_of(const char *bytes, size_t len) {
    return g_strndup(bytes, len);
}

void fabrum_gtk_set_title(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    char *title = string_of(bytes, len);
    switch (object->kind) {
    case KIND_BUTTON: gtk_button_set_label(GTK_BUTTON(object->widget), title); break;
    case KIND_CHECKBOX: gtk_check_button_set_label(GTK_CHECK_BUTTON(object->widget), title); break;
    case KIND_LABEL: gtk_label_set_text(GTK_LABEL(object->widget), title); break;
    case KIND_MENU_ITEM:
        g_free(object->title);
        object->title = g_strdup(title);
        break;
    case KIND_ALERT:
        g_free(object->title);
        object->title = g_strdup(title);
        break;
    }
    g_free(title);
}

void fabrum_gtk_set_message(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    g_free(object->key);
    object->key = string_of(bytes, len);
}

void fabrum_gtk_add_button(void *handle, const char *bytes, size_t len) {
    g_ptr_array_add(object_of(handle)->buttons, string_of(bytes, len));
}

static void alert_done(GObject *source, GAsyncResult *result, gpointer data) {
    Object *object = data;
    GError *error = NULL;
    int index = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    if (!object->showing) return;
    object->showing = false;
    if (!error) report(object->id, EVENT_RESPONSE, index, NULL);
}

void fabrum_gtk_show_alert(void *handle) {
    Object *object = object_of(handle);
    if (object->showing) return;
    object->alert = gtk_alert_dialog_new("%s", object->title ? object->title : "");
    if (object->key) gtk_alert_dialog_set_detail(object->alert, object->key);
    const char **labels = g_new0(const char *, object->buttons->len + 1);
    for (guint i = 0; i < object->buttons->len; i++) labels[i] = g_ptr_array_index(object->buttons, i);
    gtk_alert_dialog_set_buttons(object->alert, labels);
    gtk_alert_dialog_set_default_button(object->alert, 0);
    g_free(labels);
    object->showing = true;
    gtk_alert_dialog_choose(object->alert, window, object->cancel, alert_done, object);
}

static void alert_dismiss(Object *object) {
    if (object->showing) {
        object->showing = false;
        g_cancellable_cancel(object->cancel);
    }
    if (object->alert) g_object_unref(object->alert);
    object->alert = NULL;
}

void fabrum_gtk_set_enabled(void *handle, bool enabled) {
    Object *object = object_of(handle);
    if (object->widget) gtk_widget_set_sensitive(object->widget, enabled);
    if (object->action) g_simple_action_set_enabled(object->action, enabled);
}

void fabrum_gtk_set_default(void *handle, bool is_default) {
    Object *object = object_of(handle);
    if (is_default) gtk_widget_add_css_class(object->widget, "suggested-action");
    else gtk_widget_remove_css_class(object->widget, "suggested-action");
}

void fabrum_gtk_set_placeholder(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    char *text = string_of(bytes, len);
    if (GTK_IS_ENTRY(object->widget)) gtk_entry_set_placeholder_text(GTK_ENTRY(object->widget), text);
    else if (GTK_IS_SEARCH_ENTRY(object->widget)) gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(object->widget), text);
    g_free(text);
}

void fabrum_gtk_set_range(void *handle, double min, double max) {
    Object *object = object_of(handle);
    if (GTK_IS_SPIN_BUTTON(object->widget)) gtk_spin_button_set_range(GTK_SPIN_BUTTON(object->widget), min, max);
    else if (GTK_IS_RANGE(object->widget)) gtk_range_set_range(GTK_RANGE(object->widget), min, max);
}

void fabrum_gtk_set_increment(void *handle, double step) {
    gtk_spin_button_set_increments(GTK_SPIN_BUTTON(object_of(handle)->widget), step, step * 10);
}

void fabrum_gtk_set_bool(void *handle, bool on) {
    Object *object = object_of(handle);
    if (GTK_IS_SWITCH(object->widget)) {
        g_signal_handlers_block_by_func(object->widget, switched, object);
        gtk_switch_set_active(GTK_SWITCH(object->widget), on);
        g_signal_handlers_unblock_by_func(object->widget, switched, object);
    } else {
        g_signal_handlers_block_by_func(object->widget, toggled, object);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(object->widget), on);
        g_signal_handlers_unblock_by_func(object->widget, toggled, object);
    }
}

void fabrum_gtk_set_number(void *handle, double value) {
    Object *object = object_of(handle);
    if (GTK_IS_SPIN_BUTTON(object->widget)) {
        g_signal_handlers_block_by_func(object->widget, spin_changed, object);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(object->widget), value);
        g_signal_handlers_unblock_by_func(object->widget, spin_changed, object);
    } else if (GTK_IS_RANGE(object->widget)) {
        g_signal_handlers_block_by_func(object->widget, value_changed, object);
        gtk_range_set_value(GTK_RANGE(object->widget), value);
        g_signal_handlers_unblock_by_func(object->widget, value_changed, object);
    }
}

// Writes a field's or area's text, with the caret at the end, without
// reporting it back.
void fabrum_gtk_set_text(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    char *text = string_of(bytes, len);
    if (object->kind == KIND_TEXT_AREA) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(object->inner));
        g_signal_handlers_block_by_func(buffer, buffer_changed, object);
        gtk_text_buffer_set_text(buffer, text, -1);
        g_signal_handlers_unblock_by_func(buffer, buffer_changed, object);
        GtkTextIter end;
        gtk_text_buffer_get_end_iter(buffer, &end);
        gtk_text_buffer_place_cursor(buffer, &end);
    } else {
        g_signal_handlers_block_by_func(object->widget, entry_changed, object);
        gtk_editable_set_text(GTK_EDITABLE(object->widget), text);
        g_signal_handlers_unblock_by_func(object->widget, entry_changed, object);
        gtk_editable_set_position(GTK_EDITABLE(object->widget), -1);
    }
    g_free(text);
}

void fabrum_gtk_set_progress(void *handle, double value, bool indeterminate) {
    GtkProgressBar *bar = GTK_PROGRESS_BAR(object_of(handle)->widget);
    if (indeterminate) gtk_progress_bar_pulse(bar);
    else gtk_progress_bar_set_fraction(bar, value);
}

void fabrum_gtk_set_spinner_size(void *handle, bool small) {
    gtk_widget_set_size_request(object_of(handle)->widget, small ? 16 : 32, small ? 16 : 32);
}

void fabrum_gtk_set_items(void *handle, const char *const *titles, const size_t *lengths, size_t count) {
    Object *object = object_of(handle);
    if (object->kind == KIND_DROPDOWN) {
        GtkStringList *list = gtk_string_list_new(NULL);
        for (size_t i = 0; i < count; i++) {
            char *title = string_of(titles[i], lengths[i]);
            gtk_string_list_append(list, title);
            g_free(title);
        }
        g_signal_handlers_block_by_func(object->widget, selected_changed, object);
        gtk_drop_down_set_model(GTK_DROP_DOWN(object->widget), G_LIST_MODEL(list));
        g_signal_handlers_unblock_by_func(object->widget, selected_changed, object);
        g_object_unref(list);
    } else if (object->kind == KIND_RADIO_GROUP) {
        GtkWidget *child;
        while ((child = gtk_widget_get_first_child(object->inner))) gtk_box_remove(GTK_BOX(object->inner), child);
        GtkWidget *group = NULL;
        for (size_t i = 0; i < count; i++) {
            char *title = string_of(titles[i], lengths[i]);
            GtkWidget *button = gtk_check_button_new_with_label(title);
            g_free(title);
            if (group) gtk_check_button_set_group(GTK_CHECK_BUTTON(button), GTK_CHECK_BUTTON(group));
            else group = button;
            g_signal_connect(button, "toggled", G_CALLBACK(radio_toggled), object);
            watch_focus(button, object);
            gtk_box_append(GTK_BOX(object->inner), button);
        }
    }
}

void fabrum_gtk_set_selection(void *handle, long index) {
    Object *object = object_of(handle);
    if (object->kind == KIND_DROPDOWN) {
        g_signal_handlers_block_by_func(object->widget, selected_changed, object);
        gtk_drop_down_set_selected(GTK_DROP_DOWN(object->widget), index < 0 ? GTK_INVALID_LIST_POSITION : (guint)index);
        g_signal_handlers_unblock_by_func(object->widget, selected_changed, object);
    } else if (object->kind == KIND_RADIO_GROUP) {
        long i = 0;
        for (GtkWidget *child = gtk_widget_get_first_child(object->inner); child; child = gtk_widget_get_next_sibling(child), i++) {
            g_signal_handlers_block_by_func(child, radio_toggled, object);
            gtk_check_button_set_active(GTK_CHECK_BUTTON(child), i == index);
            g_signal_handlers_unblock_by_func(child, radio_toggled, object);
        }
    }
}

void fabrum_gtk_set_horizontal(void *handle, bool horizontal) {
    Object *object = object_of(handle);
    object->horizontal = horizontal;
    gtk_orientable_set_orientation(GTK_ORIENTABLE(object->inner), horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL);
    gtk_box_set_spacing(GTK_BOX(object->inner), horizontal ? 12 : 2);
}

void fabrum_gtk_set_label_style(void *handle, bool wrap, bool selectable, double font_size, bool secondary) {
    GtkLabel *label = GTK_LABEL(object_of(handle)->widget);
    gtk_label_set_wrap(label, wrap);
    gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_ellipsize(label, wrap ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END);
    gtk_label_set_selectable(label, selectable);
    if (secondary) gtk_widget_add_css_class(GTK_WIDGET(label), "dim-label");
    else gtk_widget_remove_css_class(GTK_WIDGET(label), "dim-label");
    if (font_size > 0) {
        PangoAttrList *attrs = pango_attr_list_new();
        pango_attr_list_insert(attrs, pango_attr_size_new_absolute((int)(font_size * PANGO_SCALE)));
        gtk_label_set_attributes(label, attrs);
        pango_attr_list_unref(attrs);
    } else {
        gtk_label_set_attributes(label, NULL);
    }
}

// Puts a menu item in the menu titled `menu` of the menu bar, making the
// menu if missing.
void fabrum_gtk_place_menu_item(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    char *title = string_of(bytes, len);
    if (object->menu && object->menu_title && strcmp(object->menu_title, title) == 0) {
        g_free(title);
        return;
    }
    menu_remove_item(object);
    GMenu *menu = NULL;
    int n = g_menu_model_get_n_items(G_MENU_MODEL(menubar));
    for (int i = 0; i < n && !menu; i++) {
        GVariant *label = g_menu_model_get_item_attribute_value(G_MENU_MODEL(menubar), i, G_MENU_ATTRIBUTE_LABEL, G_VARIANT_TYPE_STRING);
        if (label && strcmp(g_variant_get_string(label, NULL), title) == 0) {
            GMenuModel *sub = g_menu_model_get_item_link(G_MENU_MODEL(menubar), i, G_MENU_LINK_SUBMENU);
            if (sub) menu = G_MENU(sub);
        }
        if (label) g_variant_unref(label);
    }
    if (!menu) {
        menu = g_menu_new();
        g_menu_append_submenu(menubar, title, G_MENU_MODEL(menu));
    }
    char *detailed = g_strdup_printf("app.%s", object->action_name);
    g_menu_append(menu, object->title ? object->title : "", detailed);
    g_free(detailed);
    object->menu = menu;
    g_free(object->menu_title);
    object->menu_title = title;
}

void fabrum_gtk_set_key_equivalent(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    char *detailed = g_strdup_printf("app.%s", object->action_name);
    if (len > 0) {
        char *key = string_of(bytes, len);
        char *accel = g_strdup_printf("<Primary>%s", key);
        const char *accels[] = {accel, NULL};
        gtk_application_set_accels_for_action(application, detailed, accels);
        g_free(accel);
        g_free(key);
    } else {
        const char *none[] = {NULL};
        gtk_application_set_accels_for_action(application, detailed, none);
    }
    g_free(detailed);
}

// Frames: a widget's place in its parent fixed, and its size.
void fabrum_gtk_set_frame(void *handle, double x, double y, double w, double h) {
    Object *object = object_of(handle);
    GtkWidget *parent = gtk_widget_get_parent(object->widget);
    object->x = x;
    object->y = y;
    if (parent && GTK_IS_FIXED(parent)) gtk_fixed_move(GTK_FIXED(parent), object->widget, x, y);
    gtk_widget_set_size_request(object->widget, (int)w, (int)h);
}

void fabrum_gtk_set_scroll_axes(void *handle, bool horizontal, bool vertical) {
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(object_of(handle)->widget), horizontal ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER, vertical ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER);
}

void fabrum_gtk_set_content_size(void *handle, double w, double h) {
    Object *object = object_of(handle);
    object->content_w = w;
    object->content_h = h;
    gtk_widget_set_size_request(object->document, (int)w, (int)h);
}

// The size a widget wants, under a width limit (0 for none): a wrapping
// label gives the height of its text wrapped to the limit.
void fabrum_gtk_fitting_size(void *handle, double max_width, double *w, double *h) {
    Object *object = object_of(handle);
    GtkWidget *widget = object->widget;
    if (!widget) {
        *w = 0;
        *h = 0;
        return;
    }
    int min_w, nat_w, min_h, nat_h;
    gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &min_w, &nat_w, NULL, NULL);
    int width = nat_w;
    if (object->kind == KIND_LABEL && max_width > 0 && width > max_width) width = (int)max_width;
    gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, width, &min_h, &nat_h, NULL, NULL);
    // widgets that fill their width fit to none, as AppKit's do
    *w = (object->kind == KIND_PROGRESS || object->kind == KIND_SLIDER || object->kind == KIND_TEXT_FIELD || object->kind == KIND_TEXT_AREA || object->kind == KIND_SEARCH_FIELD || object->kind == KIND_SECURE_FIELD) ? 0 : width;
    *h = nat_h;
    if (object->kind == KIND_TEXT_AREA) *h = 3 * 20 + 8;
}

bool fabrum_gtk_is_composing(void *handle) {
    return object_of(handle)->composing;
}

static GtkWidget *focus_target(Object *object) {
    if (object->kind == KIND_RADIO_GROUP) {
        for (GtkWidget *child = gtk_widget_get_first_child(object->inner); child; child = gtk_widget_get_next_sibling(child)) {
            if (gtk_check_button_get_active(GTK_CHECK_BUTTON(child))) return child;
        }
        return gtk_widget_get_first_child(object->inner);
    }
    return object->inner ? object->inner : object->widget;
}

bool fabrum_gtk_can_focus(void *handle) {
    Object *object = object_of(handle);
    if (!object->widget || !gtk_widget_get_parent(object->widget)) return false;
    GtkWidget *target = focus_target(object);
    // GTK's Tab reaches every control, as macOS's full keyboard access does
    return target && gtk_widget_get_focusable(target) && gtk_widget_get_sensitive(target);
}

void fabrum_gtk_focus(void *handle, int canvas) {
    if (!window) return;
    if (handle) {
        Object *object = object_of(handle);
        GtkWidget *target = focus_target(object);
        if (target) gtk_widget_grab_focus(target);
    } else if (canvas) {
        gtk_widget_grab_focus(canvas_at(0));
    } else {
        gtk_window_set_focus(window, NULL);
    }
}

// Stacks the children of the host, or of a scrolled window's document:
// canvas layers and native widgets, bottom to top. Canvases in the host
// above its base take presses where they drew something.
void fabrum_gtk_arrange(void *container, const fabrum_gtk_slot *slots, size_t count) {
    prepare();
    Object *holder = container ? object_of(container) : NULL;
    GtkWidget *fixed = holder ? holder->document : host_fixed;
    GtkWidget *previous = NULL;
    if (!holder) g_array_set_size(host_upper, 0);
    for (size_t i = 0; i < count; i++) {
        GtkWidget *child;
        if (slots[i].canvas >= 0) {
            unsigned layer = (unsigned)slots[i].canvas;
            child = canvas_at(layer);
            // the host's base canvas is the overlay's child, under the fixed
            if (!holder && layer == 0) continue;
            if (!holder) g_array_prepend_val(host_upper, layer);
            double w = holder ? holder->content_w : gtk_widget_get_width(overlay);
            double h = holder ? holder->content_h : gtk_widget_get_height(overlay);
            gtk_widget_set_size_request(child, (int)w, (int)h);
        } else {
            child = object_of(slots[i].widget)->widget;
        }
        GtkWidget *parent = gtk_widget_get_parent(child);
        if (parent != fixed) {
            if (parent && GTK_IS_FIXED(parent)) gtk_fixed_remove(GTK_FIXED(parent), child);
            Object *moved = slots[i].canvas >= 0 ? NULL : object_of(slots[i].widget);
            gtk_fixed_put(GTK_FIXED(fixed), child, moved ? moved->x : 0, moved ? moved->y : 0);
        }
        // in paint order: each after the one before
        if (previous ? gtk_widget_get_prev_sibling(child) != previous : gtk_widget_get_prev_sibling(child) != NULL) {
            gtk_widget_insert_after(child, fixed, previous);
        }
        previous = child;
    }
}

void fabrum_gtk_damage_layer(unsigned layer, double x, double y, double w, double h) {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    if (layer < canvases->len) gtk_widget_queue_draw(g_ptr_array_index(canvases, layer));
}

static void rgba_of(const GdkRGBA *c, double out[4]) {
    out[0] = c->red;
    out[1] = c->green;
    out[2] = c->blue;
    out[3] = c->alpha;
}

static void named_color(GtkWidget *widget, const char *name, double fallback[4], double out[4]) {
    GdkRGBA c;
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (widget && gtk_style_context_lookup_color(gtk_widget_get_style_context(widget), name, &c)) {
        rgba_of(&c, out);
        return;
    }
    G_GNUC_END_IGNORE_DEPRECATIONS
    memcpy(out, fallback, 4 * sizeof(double));
}

void fabrum_gtk_theme(fabrum_gtk_theme_values *out) {
    prepare();
    GtkWidget *widget = window ? GTK_WIDGET(window) : host_fixed;
    GdkRGBA fg = {0, 0, 0, 1};
    if (window) gtk_widget_get_color(widget, &fg);
    rgba_of(&fg, out->text);
    double secondary[4] = {fg.red, fg.green, fg.blue, 0.55};
    memcpy(out->secondary_text, secondary, sizeof secondary);
    double accent_fallback[4] = {53 / 255.0, 132 / 255.0, 228 / 255.0, 1};
    double window_fallback[4] = {246 / 255.0, 245 / 255.0, 244 / 255.0, 1};
    double view_fallback[4] = {1, 1, 1, 1};
    double borders_fallback[4] = {0, 0, 0, 0.15};
    named_color(widget, "accent_bg_color", accent_fallback, out->accent);
    named_color(widget, "window_bg_color", window_fallback, out->window_background);
    named_color(widget, "view_bg_color", view_fallback, out->control_background);
    named_color(widget, "borders", borders_fallback, out->separator);
    memcpy(out->focus_ring, out->accent, sizeof out->focus_ring);
    out->focus_ring[3] = 0.5;
    // the toolkit's font size, in points at 96 dpi
    char *font_name = NULL;
    g_object_get(gtk_settings_get_default(), "gtk-font-name", &font_name, NULL);
    double points = 10;
    if (font_name) {
        PangoFontDescription *desc = pango_font_description_from_string(font_name);
        if (pango_font_description_get_size(desc) > 0) {
            points = (double)pango_font_description_get_size(desc) / PANGO_SCALE;
            if (!pango_font_description_get_size_is_absolute(desc)) points = points * 96 / 72;
        }
        pango_font_description_free(desc);
        g_free(font_name);
    }
    out->font_size = points;
    static double control_height = 0;
    if (control_height == 0) {
        GtkWidget *probe = gtk_button_new_with_label("M");
        g_object_ref_sink(probe);
        int min_h, nat_h;
        gtk_widget_measure(probe, GTK_ORIENTATION_VERTICAL, -1, &min_h, &nat_h, NULL, NULL);
        control_height = nat_h;
        g_object_unref(probe);
    }
    out->control_height = control_height;
    out->full_keyboard_access = 1;
    gboolean dark = FALSE;
    g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &dark, NULL);
    out->dark = dark;
}

// The font family the toolkit uses, for the canvas's text.
size_t fabrum_gtk_font_family(char *out, size_t cap) {
    char *font_name = NULL;
    g_object_get(gtk_settings_get_default(), "gtk-font-name", &font_name, NULL);
    if (!font_name) return 0;
    PangoFontDescription *desc = pango_font_description_from_string(font_name);
    const char *family = pango_font_description_get_family(desc);
    size_t n = family ? strlen(family) : 0;
    if (n > cap) n = cap;
    if (n) memcpy(out, family, n);
    pango_font_description_free(desc);
    g_free(font_name);
    return n;
}

// Automation: what debug scripts do, in process.

// Draws the window's content into a PNG at `path`, at `scale` pixels per
// point, through the widget's paintable: native widgets included.
bool fabrum_gtk_snapshot(const char *path, double scale) {
    if (!window || !overlay) return false;
    if (scale <= 0) scale = gtk_widget_get_scale_factor(overlay);
    int w = gtk_widget_get_width(overlay), h = gtk_widget_get_height(overlay);
    GdkPaintable *paintable = gtk_widget_paintable_new(overlay);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, snapshot, w, h);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    g_object_unref(paintable);
    if (!node) return false;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)(w * scale), (int)(h * scale));
    cairo_t *cr = cairo_create(surface);
    cairo_scale(cr, scale, scale);
    gsk_render_node_draw(node, cr);
    cairo_destroy(cr);
    gsk_render_node_unref(node);
    bool ok = cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(surface);
    return ok;
}

void fabrum_gtk_perform_click(void *handle) {
    Object *object = object_of(handle);
    switch (object->kind) {
    case KIND_BUTTON: gtk_widget_activate(object->widget); break;
    case KIND_CHECKBOX: gtk_check_button_set_active(GTK_CHECK_BUTTON(object->widget), !gtk_check_button_get_active(GTK_CHECK_BUTTON(object->widget))); break;
    case KIND_SWITCH: gtk_switch_set_active(GTK_SWITCH(object->widget), !gtk_switch_get_active(GTK_SWITCH(object->widget))); break;
    case KIND_MENU_ITEM: g_action_activate(G_ACTION(object->action), NULL); break;
    }
}

// Types `text` into a field or area at its caret, as the keyboard's text
// input does, reporting the change.
void fabrum_gtk_type(void *handle, const char *bytes, size_t len) {
    Object *object = object_of(handle);
    fabrum_gtk_focus(handle, 0);
    if (object->kind == KIND_TEXT_AREA) {
        gtk_text_buffer_insert_at_cursor(gtk_text_view_get_buffer(GTK_TEXT_VIEW(object->inner)), bytes, (int)len);
    } else {
        int position = gtk_editable_get_position(GTK_EDITABLE(object->widget));
        gtk_editable_insert_text(GTK_EDITABLE(object->widget), bytes, (int)len, &position);
        gtk_editable_set_position(GTK_EDITABLE(object->widget), position);
    }
}

size_t fabrum_gtk_text(void *handle, char *out, size_t cap) {
    Object *object = object_of(handle);
    char *text;
    if (object->kind == KIND_TEXT_AREA) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(object->inner));
        GtkTextIter start, end;
        gtk_text_buffer_get_bounds(buffer, &start, &end);
        text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    } else {
        text = g_strdup(gtk_editable_get_text(GTK_EDITABLE(object->widget)));
    }
    size_t n = strlen(text);
    if (n > cap) n = cap;
    memcpy(out, text, n);
    g_free(text);
    return n;
}

void fabrum_gtk_newline(void *handle) {
    Object *object = object_of(handle);
    if (object->kind == KIND_TEXT_AREA) gtk_text_buffer_insert_at_cursor(gtk_text_view_get_buffer(GTK_TEXT_VIEW(object->inner)), "\n", 1);
    else if (GTK_IS_ENTRY(object->widget) || GTK_IS_SEARCH_ENTRY(object->widget)) report(object->id, EVENT_SUBMIT, 0, NULL);
}

void fabrum_gtk_slide(void *handle, double value) {
    gtk_range_set_value(GTK_RANGE(object_of(handle)->widget), value);
}

void fabrum_gtk_select(void *handle, long index) {
    Object *object = object_of(handle);
    if (object->kind == KIND_DROPDOWN) gtk_drop_down_set_selected(GTK_DROP_DOWN(object->widget), (guint)index);
    else if (object->kind == KIND_RADIO_GROUP) {
        long i = 0;
        for (GtkWidget *child = gtk_widget_get_first_child(object->inner); child; child = gtk_widget_get_next_sibling(child), i++) {
            if (i == index) gtk_check_button_set_active(GTK_CHECK_BUTTON(child), TRUE);
        }
    }
}

void fabrum_gtk_step(void *handle, long steps) {
    GtkSpinButton *spin = GTK_SPIN_BUTTON(object_of(handle)->widget);
    double step, page;
    gtk_spin_button_get_increments(spin, &step, &page);
    gtk_spin_button_set_value(spin, gtk_spin_button_get_value(spin) + steps * step);
}

void fabrum_gtk_scroll_to(void *handle, double x, double y) {
    GtkScrolledWindow *sw = GTK_SCROLLED_WINDOW(object_of(handle)->widget);
    gtk_adjustment_set_value(gtk_scrolled_window_get_hadjustment(sw), x);
    gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(sw), y);
}

void fabrum_gtk_tab(int forward) {
    host.tab(host.ctx, forward);
}

// Answers the alert being shown (a declared one, or a confirm) with the
// button at `index`: the dialog is cancelled, and the answer reported as
// the button would have.
void fabrum_gtk_answer_alert(int index) {
    if (pending_confirm) {
        PendingChoice *pending = pending_confirm;
        pending_confirm = NULL;
        pending->answered = true;
        pending->done(pending->ctx, index);
        g_cancellable_cancel(pending->cancel);
        return;
    }
    // a declared alert: the one showing
    if (!all_objects) return;
    for (guint i = 0; i < all_objects->len; i++) {
        Object *object = g_ptr_array_index(all_objects, i);
        if (object->kind == KIND_ALERT && object->showing) {
            object->showing = false;
            g_cancellable_cancel(object->cancel);
            report(object->id, EVENT_RESPONSE, index, NULL);
            return;
        }
    }
}

bool fabrum_gtk_answer_popup(long id) {
    Popup *p = popup;
    if (!p) return false;
    popup_answer(p, id);
    gtk_popover_popdown(GTK_POPOVER(p->popover));
    return true;
}

bool fabrum_gtk_answer_open_panel(const char *path) {
    PendingFile *pending = pending_file;
    if (!pending) return false;
    pending_file = NULL;
    pending->answered = true;
    pending->done(pending->ctx, path, path ? strlen(path) : 0);
    g_cancellable_cancel(pending->cancel);
    return true;
}

bool fabrum_gtk_choose_menu(const char *menu, const char *title) {
    if (!all_objects) return false;
    for (guint i = 0; i < all_objects->len; i++) {
        Object *object = g_ptr_array_index(all_objects, i);
        if (object->kind == KIND_MENU_ITEM && object->menu_title && object->title && strcmp(object->menu_title, menu) == 0 && strcmp(object->title, title) == 0) {
            g_action_activate(G_ACTION(object->action), NULL);
            return true;
        }
    }
    return false;
}

void fabrum_gtk_resize(double width, double height) {
    gtk_window_set_default_size(window, (int)width, (int)height);
}

size_t fabrum_gtk_describe_focus(char *out, size_t cap) {
    GtkWidget *focus = window ? gtk_window_get_focus(window) : NULL;
    char *text;
    if (focus && layer_of(focus) >= 0) text = g_strdup("canvas");
    else if (focus && object_of_widget(focus)) text = g_strdup_printf("%s %" PRIx64, G_OBJECT_TYPE_NAME(object_of_widget(focus)->widget), object_of_widget(focus)->id);
    else text = g_strdup(focus ? G_OBJECT_TYPE_NAME(focus) : "nothing");
    size_t n = strlen(text);
    if (n > cap) n = cap;
    memcpy(out, text, n);
    g_free(text);
    return n;
}

size_t fabrum_gtk_describe_hit(double x, double y, char *out, size_t cap) {
    double lx, ly;
    GtkWidget *canvas = overlay ? canvas_under(x, y, &lx, &ly) : NULL;
    char *text;
    if (canvas) text = g_strdup_printf("canvas layer %d", layer_of(canvas));
    else {
        GtkWidget *picked = overlay ? gtk_widget_pick(overlay, x, y, GTK_PICK_DEFAULT) : NULL;
        Object *object = picked ? object_of_widget(picked) : NULL;
        text = object ? g_strdup_printf("%s %" PRIx64, G_OBJECT_TYPE_NAME(object->widget), object->id) : g_strdup(picked ? G_OBJECT_TYPE_NAME(picked) : "nothing");
    }
    size_t n = strlen(text);
    if (n > cap) n = cap;
    memcpy(out, text, n);
    g_free(text);
    return n;
}

