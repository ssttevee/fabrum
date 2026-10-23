// Independent GTK 4.24.1 macOS hide/show critical reproducer.
// cc test/gtk_hide_repro.c -o /tmp/gtk-hide-repro $(pkg-config --cflags --libs gtk4)
// G_DEBUG=fatal-criticals /tmp/gtk-hide-repro
#include <gtk/gtk.h>
static GtkWindow *window;
static unsigned phase;
static gboolean step(gpointer app) {
 switch(phase++) {
 case 0: gtk_widget_set_visible(GTK_WIDGET(window), FALSE); break;
 case 1: gtk_window_present(window); break;
 default: g_application_quit(app); return G_SOURCE_REMOVE;
 }
 return G_SOURCE_CONTINUE;
}
static void activate(GtkApplication *app, gpointer data) {
 window=GTK_WINDOW(gtk_application_window_new(app));
 gtk_window_set_default_size(window,320,240);
 gtk_window_set_decorated(window,FALSE);
 gtk_window_present(window);
 g_timeout_add(250,step,app);
}
int main(void) {
 GtkApplication *app=gtk_application_new("org.fabrum.GtkHideRepro",G_APPLICATION_NON_UNIQUE);
 g_signal_connect(app,"activate",G_CALLBACK(activate),NULL);
 return g_application_run(G_APPLICATION(app),0,NULL);
}
