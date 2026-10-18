// The AppKit half of fabrum's macOS platform: one window whose content is
// fabrum's host view, holding canvas layers (drawn by the app's renderer)
// interleaved with AppKit's own controls, plus the menu bar, alerts, the
// cursor, frame requests, focus routing, the theme, and the in-process
// automation that debug scripts use.
//
// Everything is driven from Zig: `appkit.zig` reconciles, and this file
// only makes, changes and arranges AppKit objects, and reports what the
// user did through `fabrum_appkit_host`.
//
// Moved from the Kitchen's temporary copy (zig-fabrum-kitchen,
// src/platform/macos/shell.m at e902587), itself from OpenEtcher's GUI.
#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <stdint.h>

typedef struct {
    void *ctx;
    // Runs a frame for content of `width` by `height` points.
    void (*frame)(void *ctx, double width, double height);
    // Draws canvas layer `layer` into `cg`, flipped so that its origin is the
    // top left, y down, as fabrum's `.cg_context` surface wants.
    void (*draw_layer)(void *ctx, unsigned layer, CGContextRef cg, double width, double height);
    // Whether canvas layer `layer` (above the first) has something drawn at
    // (x, y), in points from the top left.
    bool (*hit_layer)(void *ctx, unsigned layer, double x, double y);
    // The pointer, from the top left of the content in points. Bit 0 of
    // `buttons` is the primary button.
    void (*mouse)(void *ctx, double x, double y, unsigned buttons, double scroll_x, double scroll_y);
    // Tab (forward nonzero) or Shift-Tab, from wherever focus is.
    void (*tab)(void *ctx, int forward);
    // Space or Return while the canvas has focus.
    void (*activate)(void *ctx);
    // What the user did to native element `id`; see `EventKind` in appkit.zig.
    void (*event)(void *ctx, uint64_t id, int kind, double number, const char *text, size_t len);
    void (*will_terminate)(void *ctx);
} fabrum_appkit_host;

typedef struct {
    const char *title;
    double width;
    double height;
    double min_width;
    double min_height;
    int dark;
} fabrum_appkit_options;

// One stop in the host's stacking order, bottom to top.
typedef struct {
    // The canvas layer's index, or -1 for a native view.
    int canvas;
    void *view;
} fabrum_appkit_slot;

typedef struct {
    double accent[4], text[4], secondary_text[4], window_background[4], control_background[4], separator[4], focus_ring[4];
    double font_size;
    double control_height;
    int full_keyboard_access;
    int dark;
} fabrum_appkit_theme_values;

// Kinds of native object, as in appkit.zig's `Kind`.
enum {
    KIND_BUTTON,
    KIND_CHECKBOX,
    KIND_SWITCH,
    KIND_SLIDER,
    KIND_TEXT_FIELD,
    KIND_PROGRESS,
    KIND_MENU_ITEM,
    KIND_ALERT,
    KIND_LEVEL_INDICATOR,
};

// Kinds of event, as in appkit.zig's `EventKind`.
enum {
    EVENT_ACTIVATE,
    EVENT_TOGGLE,
    EVENT_NUMBER,
    EVENT_TEXT,
    EVENT_SUBMIT,
    EVENT_FOCUS,
    EVENT_COMPOSITION_END,
    EVENT_RESPONSE,
};

static fabrum_appkit_host host;
static NSWindow *shared_window;
static NSView *shared_host_view;
static NSMutableArray<NSView *> *canvases;
static atomic_bool frame_requested;
// Set while Zig runs a frame, when AppKit must not call back into it.
static bool in_frame;

static void report(uint64_t id, int kind, double number, NSString *text) {
    if (in_frame) {
        NSLog(@"fabrum: event %d for %llx during a frame, dropped", kind, id);
        return;
    }
    const char *utf8 = text ? text.UTF8String : NULL;
    host.event(host.ctx, id, kind, number, utf8, utf8 ? strlen(utf8) : 0);
}

static void run_frame(void) {
    atomic_store(&frame_requested, false);
    NSSize size = shared_host_view.bounds.size;
    in_frame = true;
    host.frame(host.ctx, size.width, size.height);
    in_frame = false;
}

// Native controls report focus by their element ID.
#define FABRUM_FOCUS_REPORTING                                                                                         \
    @synthesize fabrumId = _fabrumId;                                                                                  \
    -(BOOL)becomeFirstResponder {                                                                                      \
        BOOL became = [super becomeFirstResponder];                                                                    \
        if (became) report(self.fabrumId, EVENT_FOCUS, 1, nil);                                                        \
        return became;                                                                                                 \
    }

@protocol FabrumElement
@property(nonatomic) uint64_t fabrumId;
@end

@interface FabrumButton : NSButton <FabrumElement>
@end
@implementation FabrumButton
FABRUM_FOCUS_REPORTING
@end

@interface FabrumSwitch : NSSwitch <FabrumElement>
@end
@implementation FabrumSwitch
FABRUM_FOCUS_REPORTING
@end

@interface FabrumSlider : NSSlider <FabrumElement>
@end
@implementation FabrumSlider
FABRUM_FOCUS_REPORTING
@end

@interface FabrumLevelIndicator : NSLevelIndicator <FabrumElement>
@end
@implementation FabrumLevelIndicator
FABRUM_FOCUS_REPORTING
@end

@interface FabrumProgress : NSProgressIndicator <FabrumElement>
@end
@implementation FabrumProgress
@synthesize fabrumId = _fabrumId;
@end

@interface FabrumTextField : NSTextField <FabrumElement, NSTextFieldDelegate>
// Whether the last change seen was made while composing.
@property(nonatomic) BOOL composed;
@end

@implementation FabrumTextField
FABRUM_FOCUS_REPORTING

- (NSTextView *)editor {
    NSText *editor = self.currentEditor;
    return [editor isKindOfClass:[NSTextView class]] ? (NSTextView *)editor : nil;
}

- (BOOL)composing {
    return [[self editor] hasMarkedText];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSTextView *editor = notification.userInfo[@"NSFieldEditor"];
    if ([editor hasMarkedText]) {
        // the pre-edit isn't the field's text yet
        self.composed = YES;
        return;
    }
    report(self.fabrumId, EVENT_TEXT, 0, editor ? editor.string : self.stringValue);
    if (self.composed) {
        self.composed = NO;
        report(self.fabrumId, EVENT_COMPOSITION_END, 0, nil);
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    // fabrum owns the Tab order across native and drawn elements
    if (selector == @selector(insertTab:)) {
        host.tab(host.ctx, 1);
        return YES;
    }
    if (selector == @selector(insertBacktab:)) {
        host.tab(host.ctx, 0);
        return YES;
    }
    if (selector == @selector(insertNewline:)) {
        report(self.fabrumId, EVENT_SUBMIT, 0, nil);
        return YES;
    }
    return NO;
}
@end

// Receives controls' actions and reports them.
@interface FabrumTarget : NSObject
@end

@implementation FabrumTarget
- (void)pressed:(NSButton *)sender {
    report([(id<FabrumElement>)sender fabrumId], EVENT_ACTIVATE, 0, nil);
}
- (void)toggled:(NSControl *)sender {
    NSControlStateValue state = [sender isKindOfClass:[NSSwitch class]] ? ((NSSwitch *)sender).state : ((NSButton *)sender).state;
    report([(id<FabrumElement>)sender fabrumId], EVENT_TOGGLE, state == NSControlStateValueOn, nil);
}
- (void)moved:(NSControl *)sender {
    report([(id<FabrumElement>)sender fabrumId], EVENT_NUMBER, sender.doubleValue, nil);
}
- (void)chosen:(NSMenuItem *)sender {
    report((uint64_t)sender.tag, EVENT_ACTIVATE, 0, nil);
}
@end

static FabrumTarget *shared_target;

// An alert shown as a sheet while declared.
@interface FabrumAlert : NSObject
@property(nonatomic) uint64_t fabrumId;
@property(nonatomic, strong) NSAlert *alert;
@property(nonatomic) BOOL showing;
@end

@implementation FabrumAlert
- (void)show {
    if (self.showing) return;
    self.showing = YES;
    __weak FabrumAlert *weak = self;
    [self.alert beginSheetModalForWindow:shared_window
                       completionHandler:^(NSModalResponse response) {
                         FabrumAlert *strong = weak;
                         if (!strong || !strong.showing) return;
                         strong.showing = NO;
                         report(strong.fabrumId, EVENT_RESPONSE, (double)(response - NSAlertFirstButtonReturn), nil);
                       }];
}
- (void)dismiss {
    if (!self.showing) return;
    self.showing = NO;
    [shared_window endSheet:self.alert.window];
}
@end

// Canvas layer 0 takes all the pointer input native views leave; higher
// layers only where they have something drawn. Every layer forwards to
// fabrum's runtime, which hit-tests its whole layout.
@interface FabrumCanvasView : NSView
@property(nonatomic) unsigned index;
@end

@implementation FabrumCanvasView {
    unsigned _buttons;
}

- (BOOL)isOpaque {
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    // the canvas takes keys while a drawn element has focus
    return self.index == 0;
}

- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (hit != self || self.index == 0) return hit;
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return host.hit_layer(host.ctx, self.index, local.x, self.bounds.size.height - local.y) ? self : nil;
}

- (void)forward:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    host.mouse(host.ctx, p.x, self.bounds.size.height - p.y, _buttons, 0, 0);
}

- (void)mouseDown:(NSEvent *)event {
    _buttons |= 1;
    [self forward:event];
}

- (void)mouseUp:(NSEvent *)event {
    _buttons &= ~1u;
    [self forward:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self forward:event];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    host.mouse(host.ctx, p.x, self.bounds.size.height - p.y, _buttons, -event.scrollingDeltaX, -event.scrollingDeltaY);
}

- (void)keyDown:(NSEvent *)event {
    switch (event.keyCode) {
    case 48: // Tab
        host.tab(host.ctx, !(event.modifierFlags & NSEventModifierFlagShift));
        return;
    case 49: // Space
    case 36: // Return
        host.activate(host.ctx);
        return;
    default:
        [super keyDown:event];
    }
}

- (void)drawRect:(NSRect)dirty {
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(cg);
    // fabrum's coordinates: the top left, y down
    CGContextTranslateCTM(cg, 0, self.bounds.size.height);
    CGContextScaleCTM(cg, 1, -1);
    host.draw_layer(host.ctx, self.index, cg, self.bounds.size.width, self.bounds.size.height);
    CGContextRestoreGState(cg);
}
@end

// The window's content: fabrum lays out everything in it, top-left origin.
@interface FabrumHostView : NSView
@end

@implementation FabrumHostView {
    NSTrackingArea *_tracking;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    for (NSView *canvas in canvases) canvas.frame = self.bounds;
    if (shared_window) run_frame();
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    host.mouse(host.ctx, p.x, p.y, 0, 0, 0);
}

- (void)mouseExited:(NSEvent *)event {
    // far outside, so nothing stays hovered
    host.mouse(host.ctx, -1e6, -1e6, 0, 0, 0);
}
@end

// Routes Tab between native views to fabrum, so one order covers native
// and drawn elements.
@interface FabrumWindow : NSWindow
@end

@implementation FabrumWindow
- (void)selectNextKeyView:(id)sender {
    host.tab(host.ctx, 1);
}
- (void)selectPreviousKeyView:(id)sender {
    host.tab(host.ctx, 0);
}
- (void)selectKeyViewFollowingView:(NSView *)view {
    host.tab(host.ctx, 1);
}
- (void)selectKeyViewPrecedingView:(NSView *)view {
    host.tab(host.ctx, 0);
}
@end

@interface FabrumAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation FabrumAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    host.will_terminate(host.ctx);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    run_frame();
    [shared_window makeKeyAndOrderFront:nil];
    [NSApp activate];
}
@end

static void build_menu(NSString *name) {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *app_item = [[NSMenuItem alloc] init];
    [bar addItem:app_item];
    NSMenu *app_menu = [[NSMenu alloc] init];
    [app_menu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hide:) keyEquivalent:@"h"];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
    app_item.submenu = app_menu;

    // standard editing commands, which native fields answer through the
    // responder chain
    NSMenuItem *edit_item = [[NSMenuItem alloc] init];
    [bar addItem:edit_item];
    NSMenu *edit_menu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit_menu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit_menu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit_menu addItem:[NSMenuItem separatorItem]];
    [edit_menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit_menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit_menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit_menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    edit_item.submenu = edit_menu;

    NSMenuItem *window_item = [[NSMenuItem alloc] init];
    [bar addItem:window_item];
    NSMenu *window_menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [window_menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [window_menu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    window_item.submenu = window_menu;
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window_menu;
}

static NSString *string(const char *bytes, size_t len) {
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
}

static id object(void *handle) {
    return (__bridge id)handle;
}

// Runs the app until it quits. Never returns.
void fabrum_appkit_run(fabrum_appkit_options options, fabrum_appkit_host new_host) {
    host = new_host;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSString *title = [NSString stringWithUTF8String:options.title];
        build_menu(title);
        shared_target = [[FabrumTarget alloc] init];
        if (!canvases) canvases = [NSMutableArray array];

        FabrumAppDelegate *delegate = [[FabrumAppDelegate alloc] init];
        NSWindow *window = [[FabrumWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, options.width, options.height)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = title;
        window.appearance = [NSAppearance appearanceNamed:options.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        window.contentMinSize = NSMakeSize(options.min_width, options.min_height);
        window.releasedWhenClosed = NO;

        if (!shared_host_view) shared_host_view = [[FabrumHostView alloc] initWithFrame:NSMakeRect(0, 0, options.width, options.height)];
        window.contentView = shared_host_view;
        [window center];
        shared_window = window;
        app.delegate = delegate;
        [app run];
    }
    exit(0);
}

// The host view, made early so native views can be made and measured
// before the window opens.
static NSView *host_view(void) {
    if (!shared_host_view) shared_host_view = [[FabrumHostView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    if (!canvases) canvases = [NSMutableArray array];
    return shared_host_view;
}

// Asks for a frame soon. Safe from any thread; requests made before the
// frame runs are coalesced.
void fabrum_appkit_request_frame(void) {
    if (atomic_exchange(&frame_requested, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (atomic_load(&frame_requested)) run_frame();
    });
}

// 0: arrow, 1: pointing hand. Only over the canvas; native views set their
// own. Main thread only.
void fabrum_appkit_set_cursor(int cursor, double x, double y) {
    NSView *view = shared_host_view;
    NSView *hit = [view hitTest:[view convertPoint:NSMakePoint(x, y) toView:view.superview]];
    if (hit && ![hit isKindOfClass:[FabrumCanvasView class]]) return;
    [cursor == 1 ? [NSCursor pointingHandCursor] : [NSCursor arrowCursor] set];
}

void fabrum_appkit_run_on_main(void (*callback)(void *ctx), void *ctx) {
    dispatch_async_f(dispatch_get_main_queue(), ctx, callback);
}

void fabrum_appkit_quit(void) {
    [NSApp terminate:nil];
}

// Native objects. Handles are retained Objective-C objects.

void *fabrum_appkit_create(int kind, uint64_t element) {
    host_view();
    if (!shared_target) shared_target = [[FabrumTarget alloc] init];
    id made = nil;
    switch (kind) {
    case KIND_BUTTON: {
        FabrumButton *button = [FabrumButton buttonWithTitle:@"" target:shared_target action:@selector(pressed:)];
        button.fabrumId = element;
        made = button;
        break;
    }
    case KIND_CHECKBOX: {
        FabrumButton *box = [FabrumButton checkboxWithTitle:@"" target:shared_target action:@selector(toggled:)];
        box.fabrumId = element;
        made = box;
        break;
    }
    case KIND_SWITCH: {
        FabrumSwitch *toggle = [[FabrumSwitch alloc] init];
        toggle.target = shared_target;
        toggle.action = @selector(toggled:);
        toggle.fabrumId = element;
        made = toggle;
        break;
    }
    case KIND_SLIDER: {
        FabrumSlider *slider = [FabrumSlider sliderWithTarget:shared_target action:@selector(moved:)];
        slider.continuous = YES;
        slider.fabrumId = element;
        made = slider;
        break;
    }
    case KIND_LEVEL_INDICATOR: {
        FabrumLevelIndicator *level = [[FabrumLevelIndicator alloc] init];
        level.levelIndicatorStyle = NSLevelIndicatorStyleRating;
        level.editable = YES;
        level.target = shared_target;
        level.action = @selector(moved:);
        level.fabrumId = element;
        made = level;
        break;
    }
    case KIND_TEXT_FIELD: {
        FabrumTextField *field = [FabrumTextField textFieldWithString:@""];
        field.delegate = field;
        field.fabrumId = element;
        field.cell.sendsActionOnEndEditing = NO;
        field.cell.scrollable = YES;
        field.cell.wraps = NO;
        field.usesSingleLineMode = YES;
        made = field;
        break;
    }
    case KIND_PROGRESS: {
        FabrumProgress *bar = [[FabrumProgress alloc] init];
        bar.style = NSProgressIndicatorStyleBar;
        bar.indeterminate = NO;
        bar.minValue = 0;
        bar.maxValue = 1;
        bar.fabrumId = element;
        made = bar;
        break;
    }
    case KIND_MENU_ITEM: {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(chosen:) keyEquivalent:@""];
        item.target = shared_target;
        item.tag = (NSInteger)element;
        made = item;
        break;
    }
    case KIND_ALERT: {
        FabrumAlert *alert = [[FabrumAlert alloc] init];
        alert.alert = [[NSAlert alloc] init];
        alert.fabrumId = element;
        made = alert;
        break;
    }
    }
    if ([made isKindOfClass:[NSView class]]) {
        NSView *view = made;
        // positioned by frame; `arrange` adds it to the host
        view.translatesAutoresizingMaskIntoConstraints = YES;
    }
    return (__bridge_retained void *)made;
}

void fabrum_appkit_destroy(void *handle) {
    id made = (__bridge_transfer id)handle;
    if ([made isKindOfClass:[NSView class]]) {
        [(NSView *)made removeFromSuperview];
    } else if ([made isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = made;
        NSMenu *menu = item.menu;
        [menu removeItem:item];
        // drop a menu fabrum made once it is empty
        if (menu && menu.numberOfItems == 0) {
            NSMenuItem *holder = [NSApp.mainMenu itemWithTitle:menu.title];
            if (holder) [NSApp.mainMenu removeItem:holder];
        }
    } else if ([made isKindOfClass:[FabrumAlert class]]) {
        [(FabrumAlert *)made dismiss];
    }
}

void fabrum_appkit_set_title(void *handle, const char *bytes, size_t len) {
    id made = object(handle);
    NSString *title = string(bytes, len);
    if ([made isKindOfClass:[NSButton class]]) ((NSButton *)made).title = title;
    else if ([made isKindOfClass:[NSMenuItem class]]) ((NSMenuItem *)made).title = title;
    else if ([made isKindOfClass:[FabrumAlert class]]) ((FabrumAlert *)made).alert.messageText = title;
}

void fabrum_appkit_set_message(void *handle, const char *bytes, size_t len) {
    ((FabrumAlert *)object(handle)).alert.informativeText = string(bytes, len);
}

void fabrum_appkit_add_button(void *handle, const char *bytes, size_t len) {
    [((FabrumAlert *)object(handle)).alert addButtonWithTitle:string(bytes, len)];
}

void fabrum_appkit_show_alert(void *handle) {
    [(FabrumAlert *)object(handle) show];
}

void fabrum_appkit_set_enabled(void *handle, bool enabled) {
    id made = object(handle);
    if ([made isKindOfClass:[NSControl class]]) ((NSControl *)made).enabled = enabled;
    else if ([made isKindOfClass:[NSMenuItem class]]) ((NSMenuItem *)made).enabled = enabled;
}

void fabrum_appkit_set_default(void *handle, bool is_default) {
    ((NSButton *)object(handle)).keyEquivalent = is_default ? @"\r" : @"";
}

void fabrum_appkit_set_placeholder(void *handle, const char *bytes, size_t len) {
    ((NSTextField *)object(handle)).placeholderString = string(bytes, len);
}

void fabrum_appkit_set_range(void *handle, double min, double max) {
    id made = object(handle);
    if ([made isKindOfClass:[NSSlider class]]) {
        ((NSSlider *)made).minValue = min;
        ((NSSlider *)made).maxValue = max;
    } else if ([made isKindOfClass:[NSLevelIndicator class]]) {
        ((NSLevelIndicator *)made).minValue = min;
        ((NSLevelIndicator *)made).maxValue = max;
    }
}

void fabrum_appkit_set_bool(void *handle, bool on) {
    id made = object(handle);
    NSControlStateValue state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ([made isKindOfClass:[NSSwitch class]]) ((NSSwitch *)made).state = state;
    else ((NSButton *)made).state = state;
}

void fabrum_appkit_set_number(void *handle, double value) {
    ((NSControl *)object(handle)).doubleValue = value;
}

// Writes a field's text. While the user edits it, the field editor holds
// the text, so it is written there, keeping editing going with the caret at
// the end.
void fabrum_appkit_set_text(void *handle, const char *bytes, size_t len) {
    FabrumTextField *field = object(handle);
    NSString *text = string(bytes, len);
    NSTextView *editor = [field editor];
    if (editor) {
        editor.string = text;
        editor.selectedRange = NSMakeRange(text.length, 0);
    }
    field.stringValue = text;
}

void fabrum_appkit_set_progress(void *handle, double value, bool indeterminate) {
    NSProgressIndicator *bar = object(handle);
    if (bar.indeterminate != indeterminate) {
        bar.indeterminate = indeterminate;
        if (indeterminate) [bar startAnimation:nil];
        else [bar stopAnimation:nil];
    }
    bar.doubleValue = value;
}

// Puts a menu item in the menu titled `menu`, making the menu if missing,
// before the Window menu.
void fabrum_appkit_place_menu_item(void *handle, const char *bytes, size_t len) {
    NSMenuItem *item = object(handle);
    NSString *title = string(bytes, len);
    NSMenu *bar = NSApp.mainMenu;
    if (!bar) return;
    if (item.menu) {
        if ([item.menu.title isEqualToString:title]) return;
        [item.menu removeItem:item];
    }
    NSMenuItem *holder = [bar itemWithTitle:title];
    if (!holder) {
        holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        holder.submenu = [[NSMenu alloc] initWithTitle:title];
        NSInteger window_index = NSApp.windowsMenu ? [bar indexOfItemWithSubmenu:NSApp.windowsMenu] : -1;
        if (window_index >= 0) [bar insertItem:holder atIndex:window_index];
        else [bar addItem:holder];
    }
    [holder.submenu addItem:item];
}

void fabrum_appkit_set_key_equivalent(void *handle, const char *bytes, size_t len) {
    ((NSMenuItem *)object(handle)).keyEquivalent = string(bytes, len);
}

void fabrum_appkit_set_frame(void *handle, double x, double y, double w, double h) {
    ((NSView *)object(handle)).frame = NSMakeRect(x, y, w, h);
}

void fabrum_appkit_fitting_size(void *handle, double *w, double *h) {
    NSView *view = object(handle);
    NSSize size = view.fittingSize;
    NSSize intrinsic = view.intrinsicContentSize;
    // views without an intrinsic width, such as progress bars, fit to none
    *w = size.width > 0 ? size.width : (intrinsic.width == NSViewNoIntrinsicMetric ? 0 : intrinsic.width);
    *h = size.height > 0 ? size.height : (intrinsic.height == NSViewNoIntrinsicMetric ? 0 : intrinsic.height);
}

bool fabrum_appkit_is_composing(void *handle) {
    id made = object(handle);
    return [made isKindOfClass:[FabrumTextField class]] && [(FabrumTextField *)made composing];
}

bool fabrum_appkit_can_focus(void *handle) {
    NSView *view = object(handle);
    if (![view isKindOfClass:[NSView class]] || !view.superview) return false;
    // AppKit's own rule, which follows the Keyboard navigation setting
    return view.canBecomeKeyView || (view.acceptsFirstResponder && [view isKindOfClass:[NSTextField class]]);
}

// Gives keyboard focus to a native view, to the canvas (`canvas` nonzero),
// or to nothing.
void fabrum_appkit_focus(void *handle, int canvas) {
    NSWindow *window = shared_window;
    if (!window) return;
    if (handle) {
        [window makeFirstResponder:object(handle)];
    } else if (canvas && canvases.count > 0) {
        [window makeFirstResponder:canvases[0]];
    } else {
        [window makeFirstResponder:nil];
    }
}

// Stacks the host's subviews: canvas layers and native views, bottom to
// top. Every canvas is redrawn, since its commands are new.
void fabrum_appkit_arrange(const fabrum_appkit_slot *slots, size_t count) {
    NSView *view = host_view();
    NSMutableArray<NSView *> *order = [NSMutableArray arrayWithCapacity:count];
    NSUInteger used = 0;
    for (size_t i = 0; i < count; i++) {
        if (slots[i].canvas >= 0) {
            unsigned layer = (unsigned)slots[i].canvas;
            while (canvases.count <= layer) {
                FabrumCanvasView *canvas = [[FabrumCanvasView alloc] initWithFrame:view.bounds];
                canvas.index = (unsigned)canvases.count;
                canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                [canvases addObject:canvas];
            }
            used = MAX(used, layer + 1);
            [order addObject:canvases[layer]];
        } else {
            [order addObject:object(slots[i].view)];
        }
    }
    if (![view.subviews isEqualToArray:order]) {
        // keep the first responder if it stays
        NSResponder *responder = view.window.firstResponder;
        view.subviews = order;
        if (responder && view.window.firstResponder != responder && [responder isKindOfClass:[NSView class]] &&
            [(NSView *)responder isDescendantOf:view]) {
            [view.window makeFirstResponder:responder];
        }
    }
    for (NSUInteger i = 0; i < used; i++) canvases[i].needsDisplay = YES;
}

static void components(NSColor *color, NSAppearance *appearance, double out[4]) {
    __block NSColor *resolved = nil;
    [appearance performAsCurrentDrawingAppearance:^{
      resolved = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    out[0] = resolved.redComponent;
    out[1] = resolved.greenComponent;
    out[2] = resolved.blueComponent;
    out[3] = resolved.alphaComponent;
}

void fabrum_appkit_theme(fabrum_appkit_theme_values *out) {
    NSAppearance *appearance = shared_window ? shared_window.effectiveAppearance : NSApp.effectiveAppearance;
    if (!appearance) appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    components(NSColor.controlAccentColor, appearance, out->accent);
    components(NSColor.labelColor, appearance, out->text);
    components(NSColor.secondaryLabelColor, appearance, out->secondary_text);
    components(NSColor.windowBackgroundColor, appearance, out->window_background);
    components(NSColor.controlBackgroundColor, appearance, out->control_background);
    components(NSColor.separatorColor, appearance, out->separator);
    components(NSColor.keyboardFocusIndicatorColor, appearance, out->focus_ring);
    out->font_size = NSFont.systemFontSize;
    static double control_height = 0;
    if (control_height == 0) control_height = [NSButton buttonWithTitle:@"M" target:nil action:nil].fittingSize.height;
    out->control_height = control_height;
    out->full_keyboard_access = NSApp.fullKeyboardAccessEnabled;
    out->dark = [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

// Automation: what debug scripts do, in process. Nothing reaches the
// system's event stream and the real pointer never moves. Main thread only.

// Draws the window's content, native views included as far as AppKit
// draws them into a bitmap, at `scale` pixels per point (or the screen's
// if 0), and saves it as a PNG. Works while the screen is locked.
bool fabrum_appkit_snapshot(const char *path, double scale) {
    NSView *view = shared_window ? shared_window.contentView : shared_host_view;
    NSBitmapImageRep *bitmap;
    if (scale > 0) {
        NSSize size = view.bounds.size;
        bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                         pixelsWide:(NSInteger)(size.width * scale)
                                                         pixelsHigh:(NSInteger)(size.height * scale)
                                                      bitsPerSample:8
                                                    samplesPerPixel:4
                                                           hasAlpha:YES
                                                           isPlanar:NO
                                                     colorSpaceName:NSDeviceRGBColorSpace
                                                        bytesPerRow:0
                                                       bitsPerPixel:0];
        if (bitmap) bitmap.size = size;
    } else {
        bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    }
    if (!bitmap) return false;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
}

// The window's number, for `screencapture -l`.
long fabrum_appkit_window_number(void) {
    return shared_window.windowNumber;
}

// Clicks a native control as its own `performClick:` does: it highlights
// and sends its action. Menu items are chosen through their menu.
void fabrum_appkit_perform_click(void *handle) {
    id made = object(handle);
    if ([made isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = made;
        [item.menu performActionForItemAtIndex:[item.menu indexOfItem:item]];
    } else if ([made isKindOfClass:[NSSwitch class]]) {
        NSSwitch *toggle = made;
        toggle.state = toggle.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
        [toggle sendAction:toggle.action to:toggle.target];
    } else if ([made isKindOfClass:[NSControl class]]) {
        [(NSControl *)made performClick:nil];
    }
}

// Focuses a field and types `text` into its field editor with
// `insertText:`, as the keyboard's text input does, one character at a
// time.
void fabrum_appkit_type(void *handle, const char *bytes, size_t len) {
    FabrumTextField *field = object(handle);
    if (![field editor]) [shared_window makeFirstResponder:field];
    NSTextView *editor = [field editor];
    if (!editor) return;
    // keep the caret where the user left it: at the end after focusing
    if (editor.selectedRange.length > 0) editor.selectedRange = NSMakeRange(editor.string.length, 0);
    NSString *text = string(bytes, len);
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                            [editor insertText:character replacementRange:editor.selectedRange];
                          }];
}

// Starts or changes an IME composition in a field, as an input method does
// with `setMarkedText:`.
void fabrum_appkit_mark(void *handle, const char *bytes, size_t len) {
    FabrumTextField *field = object(handle);
    if (![field editor]) [shared_window makeFirstResponder:field];
    NSTextView *editor = [field editor];
    NSString *text = string(bytes, len);
    [editor setMarkedText:text selectedRange:NSMakeRange(text.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
}

// Commits a composition with `text`, as choosing a candidate does.
void fabrum_appkit_commit(void *handle, const char *bytes, size_t len) {
    NSTextView *editor = [(FabrumTextField *)object(handle) editor];
    [editor insertText:string(bytes, len) replacementRange:NSMakeRange(NSNotFound, 0)];
}

// The text a field shows, marked text included, into `out`; returns its
// length in bytes, or 0.
size_t fabrum_appkit_text(void *handle, char *out, size_t cap) {
    FabrumTextField *field = object(handle);
    NSTextView *editor = [field editor];
    NSString *text = editor ? editor.string : field.stringValue;
    const char *utf8 = text.UTF8String;
    size_t n = MIN(strlen(utf8), cap);
    memcpy(out, utf8, n);
    return n;
}

// Presses Return in a field being edited, as the key would through the
// field editor's `insertNewline:`.
void fabrum_appkit_newline(void *handle) {
    FabrumTextField *field = object(handle);
    if (![field editor]) [shared_window makeFirstResponder:field];
    [[field editor] doCommandBySelector:@selector(insertNewline:)];
}

// Moves a slider as a drag does, sending its action.
void fabrum_appkit_slide(void *handle, double value) {
    NSSlider *slider = object(handle);
    slider.doubleValue = value;
    [slider sendAction:slider.action to:slider.target];
}

// Presses Tab where focus is, as the key would: through the field editor
// when a field is being edited, the canvas when it has focus, and the
// window otherwise.
void fabrum_appkit_tab(int forward) {
    NSResponder *responder = shared_window.firstResponder;
    if ([responder isKindOfClass:[NSTextView class]]) {
        [(NSTextView *)responder doCommandBySelector:forward ? @selector(insertTab:) : @selector(insertBacktab:)];
    } else if (forward) {
        [shared_window selectNextKeyView:nil];
    } else {
        [shared_window selectPreviousKeyView:nil];
    }
}

// Answers the alert being shown with the button at `index`.
void fabrum_appkit_answer_alert(int index) {
    NSWindow *sheet = shared_window.attachedSheet;
    if (sheet) [shared_window endSheet:sheet returnCode:NSAlertFirstButtonReturn + index];
}

// Chooses the item titled `title` in the menu titled `menu`, as the menu
// bar would.
bool fabrum_appkit_choose_menu(const char *menu, const char *title) {
    NSMenuItem *holder = [NSApp.mainMenu itemWithTitle:[NSString stringWithUTF8String:menu]];
    NSMenu *submenu = holder.submenu;
    NSInteger index = [submenu indexOfItemWithTitle:[NSString stringWithUTF8String:title]];
    if (index < 0) return false;
    [submenu performActionForItemAtIndex:index];
    return true;
}

// Resizes the window's content, as dragging its corner does.
void fabrum_appkit_resize(double width, double height) {
    [shared_window setContentSize:NSMakeSize(width, height)];
}

// A description of the first responder, into `out`.
size_t fabrum_appkit_describe_focus(char *out, size_t cap) {
    NSResponder *responder = shared_window.firstResponder;
    if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder isFieldEditor]) {
        responder = (NSResponder *)((NSTextView *)responder).delegate;
    }
    NSString *text;
    if ([responder conformsToProtocol:@protocol(FabrumElement)]) {
        text = [NSString stringWithFormat:@"%@ %llx", NSStringFromClass([responder class]), [(id<FabrumElement>)responder fabrumId]];
    } else if ([responder isKindOfClass:[FabrumCanvasView class]]) {
        text = @"canvas";
    } else {
        text = responder ? NSStringFromClass([responder class]) : @"nothing";
    }
    const char *utf8 = text.UTF8String;
    size_t n = MIN(strlen(utf8), cap);
    memcpy(out, utf8, n);
    return n;
}

// Describes the view AppKit's hit-testing gives a click at (x, y), in
// points from the top left of the content, into `out`.
size_t fabrum_appkit_describe_hit(double x, double y, char *out, size_t cap) {
    NSView *content = shared_window.contentView;
    NSView *hit = [content hitTest:[content convertPoint:NSMakePoint(x, y) toView:content.superview]];
    NSString *text;
    if ([hit isKindOfClass:[FabrumCanvasView class]]) {
        text = [NSString stringWithFormat:@"canvas layer %u", ((FabrumCanvasView *)hit).index];
    } else {
        while (hit && ![hit conformsToProtocol:@protocol(FabrumElement)] && hit != content) hit = hit.superview;
        text = [hit conformsToProtocol:@protocol(FabrumElement)]
                   ? [NSString stringWithFormat:@"%@ %llx", NSStringFromClass([hit class]), [(id<FabrumElement>)hit fabrumId]]
                   : (hit ? NSStringFromClass([hit class]) : @"nothing");
    }
    const char *utf8 = text.UTF8String;
    size_t n = MIN(strlen(utf8), cap);
    memcpy(out, utf8, n);
    return n;
}

// Clicks at (x, y), in points from the top left of the content, with mouse
// events sent through the window as AppKit delivers them. Window-level
// events: only for an unlocked session. Nothing reaches the system's event
// stream and the real pointer doesn't move.
void fabrum_appkit_synthesize_click(double x, double y) {
    NSWindow *window = shared_window;
    NSView *view = window.contentView;
    NSPoint point = [view convertPoint:NSMakePoint(x, y) toView:nil];
    NSEventType types[] = {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp};
    for (size_t i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent mouseEventWithType:types[i]
                                            location:point
                                       modifierFlags:0
                                           timestamp:[[NSProcessInfo processInfo] systemUptime]
                                        windowNumber:window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:1
                                            pressure:types[i] == NSEventTypeLeftMouseDown ? 1 : 0];
        [window sendEvent:event];
    }
}

// Presses and releases a key through the window, as the keyboard would,
// with `characters` as its text. Window-level events: only for an unlocked
// session.
void fabrum_appkit_synthesize_key(unsigned short key_code, const char *characters, bool shift) {
    NSWindow *window = shared_window;
    NSString *chars = [NSString stringWithUTF8String:characters];
    NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
    for (size_t i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:types[i]
                                          location:NSZeroPoint
                                     modifierFlags:shift ? NSEventModifierFlagShift : 0
                                         timestamp:[[NSProcessInfo processInfo] systemUptime]
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:chars
                       charactersIgnoringModifiers:chars
                                         isARepeat:NO
                                           keyCode:key_code];
        [window sendEvent:event];
    }
}
