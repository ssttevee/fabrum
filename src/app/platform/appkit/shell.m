// The AppKit half of fabrum's macOS platform: independent windows whose content is
// fabrum's host view, holding canvas layers (drawn by the app's renderer)
// interleaved with AppKit's own controls, and scroll views whose documents
// hold canvas layers and controls of their own, plus the menu bar, alerts, the
// cursor, frame requests, focus routing, the theme, and the in-process
// automation that debug scripts use.
//
// Everything is driven from Zig: `appkit.zig` reconciles, and this file
// only makes, changes and arranges AppKit objects, and reports what the
// user did through `fabrum_appkit_host`.
//
// Moved from the Kitchen's temporary copy (zig-fabrum-kitchen,
// src/platform/macos/shell.m at e902587).
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdint.h>
#import <objc/runtime.h>

typedef struct {
    void *ctx;
    // Runs a frame for content of `width` by `height` points.
    void (*frame)(void *ctx, double width, double height);
    // Draws canvas layer `layer` into `cg`, flipped so that its origin is the
    // top left, y down, as fabrum's `.cg_context` surface wants.
    void (*draw_layer)(void *ctx, unsigned layer, CGContextRef cg, double width, double height);
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
    // Unconsumed Return: drawn focused controls, then the window default.
    bool (*enter)(void *ctx);
    // What the user did to native element `id`; see `EventKind` in appkit.zig.
    void (*event)(void *ctx, uint64_t id, int kind, double number, const char *text, size_t len);
    // Whether the window may close (`quit` 0) or the app quit (1) now.
    bool (*should_close)(void *ctx, int quit);
    void (*will_terminate)(void *ctx);
} fabrum_appkit_host;

// Called with text, or NULL for none, valid for the call.
typedef void (*fabrum_appkit_text_callback)(void *ctx, const char *text, size_t len);

// Called with the index of the button or item chosen, or -1 for none.
typedef void (*fabrum_appkit_index_callback)(void *ctx, long index);

// A dialog's look, as `app.platform.DialogKind`.
enum {
    DIALOG_INFO,
    DIALOG_QUESTION,
    DIALOG_WARNING,
    DIALOG_ERROR,
};

// One item of a owner.popupOwner menu, as `app.platform.MenuItem` flattened: a
// submenu's items follow it, one deeper.
typedef struct {
    const char *title;
    size_t title_len;
    // 0 item, 1 header, 2 separator, 3 submenu, as `app.platform.MenuItemKind`.
    int kind;
    long id;
    bool enabled;
    unsigned depth;
} fabrum_appkit_menu_item;

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
    EVENT_SELECT,
};

@class FabrumTarget, FabrumPopup;
@interface FabrumPopup : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic) fabrum_appkit_index_callback done;
@property(nonatomic) void *ctx;
@property(nonatomic) BOOL answered;
- (void)answer:(long)index;
@end
@interface FabrumWindowContext : NSObject
@property(nonatomic) fabrum_appkit_host host;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) FabrumTarget *target;
@property(nonatomic, strong) NSView *hostView;
@property(nonatomic, strong) NSMutableArray<NSView *> *layers;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenu *windowsMenu;
@property(nonatomic, strong) NSOpenPanel *openPanel;
@property(nonatomic) fabrum_appkit_text_callback openPanelDone;
@property(nonatomic) void *openPanelCtx;
@property(nonatomic, strong) FabrumPopup *popupOwner;
@property(nonatomic) BOOL frameRequested;
@property(nonatomic) BOOL closed;
@property(nonatomic) BOOL ready;
@end
@implementation FabrumWindowContext
@end
static NSMutableArray<FabrumWindowContext *> *windows;
static char owner_key;
static FabrumWindowContext *owner_of(id object) {
    FabrumWindowContext *owner = objc_getAssociatedObject(object, &owner_key);
    if (!owner && [object isKindOfClass:[NSView class]]) owner = owner_of([(NSView *)object superview]);
    return owner;
}
static void own(id object, FabrumWindowContext *owner) {
    objc_setAssociatedObject(object, &owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static FabrumWindowContext *active_owner(void) {
    return owner_of(NSApp.keyWindow) ?: windows.lastObject;
}
static void report(FabrumWindowContext *owner, uint64_t id, int kind, double number, NSString *text) {
    if (!owner || owner.closed) return;
    const char *utf8 = text ? text.UTF8String : NULL;
    owner.host.event(owner.host.ctx, id, kind, number, utf8, utf8 ? strlen(utf8) : 0);
}
static void run_frame(FabrumWindowContext *owner) {
    owner.frameRequested = NO;
    if (!owner || owner.closed || !owner.ready || !owner.hostView) return;
    NSSize size = owner.hostView.bounds.size;
    owner.host.frame(owner.host.ctx, size.width, size.height);
}

// Native controls report focus by their element ID.
#define FABRUM_FOCUS_REPORTING                                                                                         \
    @synthesize fabrumId = _fabrumId;                                                                                  \
    -(BOOL)becomeFirstResponder {                                                                                      \
        BOOL became = [super becomeFirstResponder];                                                                    \
        if (became) report(owner_of(self), self.fabrumId, EVENT_FOCUS, 1, nil);                                                        \
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

// Something the user types into: a field's field editor while it is
// edited, or a text area's text view.
@protocol FabrumEditable
- (NSTextView *)editor;
- (BOOL)composing;
// Writes the text, keeping editing going with the caret at the end.
- (void)setFabrumText:(NSString *)text;
// The text shown, marked text included.
- (NSString *)fabrumText;
@end

// The three looks of a single-line field share one implementation: the
// field is its own delegate, reports its text after each edit (not while
// composing), and routes Tab and Return to fabrum.
#define FABRUM_TEXT_FIELD_IMPLEMENTATION                                                                               \
    FABRUM_FOCUS_REPORTING                                                                                             \
    @synthesize composed = _composed;                                                                                  \
    -(NSTextView *)editor {                                                                                            \
        NSText *editor = self.currentEditor;                                                                           \
        return [editor isKindOfClass:[NSTextView class]] ? (NSTextView *)editor : nil;                                 \
    }                                                                                                                  \
    -(BOOL)composing {                                                                                                 \
        return [[self editor] hasMarkedText];                                                                          \
    }                                                                                                                  \
    -(void)setFabrumText : (NSString *)text {                                                                          \
        NSTextView *editor = [self editor];                                                                            \
        if (editor) {                                                                                                  \
            editor.string = text;                                                                                      \
            editor.selectedRange = NSMakeRange(text.length, 0);                                                        \
        }                                                                                                              \
        self.stringValue = text;                                                                                       \
    }                                                                                                                  \
    -(NSString *)fabrumText {                                                                                          \
        NSTextView *editor = [self editor];                                                                            \
        return editor ? editor.string : self.stringValue;                                                              \
    }                                                                                                                  \
    -(void)controlTextDidChange : (NSNotification *)notification {                                                     \
        NSTextView *editor = notification.userInfo[@"NSFieldEditor"];                                                  \
        if ([editor hasMarkedText]) {                                                                                  \
            self.composed = YES;                                                                                       \
            return;                                                                                                    \
        }                                                                                                              \
        report(owner_of(self), self.fabrumId, EVENT_TEXT, 0, editor ? editor.string : self.stringValue);                               \
        if (self.composed) {                                                                                           \
            self.composed = NO;                                                                                        \
            report(owner_of(self), self.fabrumId, EVENT_COMPOSITION_END, 0, nil);                                                      \
        }                                                                                                              \
    }                                                                                                                  \
    -(BOOL)control : (NSControl *)control textView : (NSTextView *)textView doCommandBySelector : (SEL)selector {      \
        if (owner_of(self).closed) return NO; \
        if (selector == @selector(insertTab:)) {                                                                       \
            owner_of(self).host.tab(owner_of(self).host.ctx, 1);                                                                                     \
            return YES;                                                                                                \
        }                                                                                                              \
        if (selector == @selector(insertBacktab:)) {                                                                   \
            owner_of(self).host.tab(owner_of(self).host.ctx, 0);                                                                                     \
            return YES;                                                                                                \
        }                                                                                                              \
        if (selector == @selector(insertNewline:)) {                                                                   \
            report(owner_of(self), self.fabrumId, EVENT_SUBMIT, 0, nil);                                                               \
            return YES;                                                                                                \
        }                                                                                                              \
        return NO;                                                                                                     \
    }

@interface FabrumTextField : NSTextField <FabrumElement, FabrumEditable, NSTextFieldDelegate>
// Whether the last change seen was made while composing.
@property(nonatomic) BOOL composed;
@end
@implementation FabrumTextField
FABRUM_TEXT_FIELD_IMPLEMENTATION
@end

@interface FabrumSearchField : NSSearchField <FabrumElement, FabrumEditable, NSSearchFieldDelegate>
@property(nonatomic) BOOL composed;
@end
@implementation FabrumSearchField
FABRUM_TEXT_FIELD_IMPLEMENTATION
@end

@interface FabrumSecureField : NSSecureTextField <FabrumElement, FabrumEditable, NSTextFieldDelegate>
@property(nonatomic) BOOL composed;
@end
@implementation FabrumSecureField
FABRUM_TEXT_FIELD_IMPLEMENTATION
@end

// The text view of a text area, reporting focus with the area's ID.
@interface FabrumTextView : NSTextView
@property(nonatomic) uint64_t areaId;
@end
@implementation FabrumTextView
- (BOOL)becomeFirstResponder {
    FabrumWindowContext *owner = owner_of(self); \
        BOOL became = [super becomeFirstResponder];
    if (became) report(owner_of(self), self.areaId, EVENT_FOCUS, 1, nil);
    return became;
}
// fabrum owns the Tab order; a text area doesn't take Tab as text
- (void)insertTab:(id)sender {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 1);
}
- (void)insertBacktab:(id)sender {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 0);
}
@end

// A multi-line text area: an NSTextView in a scroll view, whose text is
// controlled like a field's, and whose input method work (marked text,
// candidates) is the text view's own.
@interface FabrumTextArea : NSScrollView <FabrumElement, FabrumEditable, NSTextViewDelegate>
@property(nonatomic, strong) FabrumTextView *textView;
@property(nonatomic) BOOL composed;
@end

@implementation FabrumTextArea
@synthesize fabrumId = _fabrumId;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.hasVerticalScroller = YES;
        self.autohidesScrollers = YES;
        self.borderType = NSBezelBorder;
        FabrumTextView *view = [[FabrumTextView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        view.minSize = NSMakeSize(0, 0);
        view.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        view.verticallyResizable = YES;
        view.horizontallyResizable = NO;
        view.autoresizingMask = NSViewWidthSizable;
        view.textContainer.widthTracksTextView = YES;
        view.textContainer.containerSize = NSMakeSize(frame.size.width, CGFLOAT_MAX);
        view.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
        view.richText = NO;
        view.allowsUndo = YES;
        view.delegate = self;
        self.textView = view;
        self.documentView = view;
    }
    return self;
}

- (void)setFabrumId:(uint64_t)fabrumId {
    _fabrumId = fabrumId;
    self.textView.areaId = fabrumId;
}

- (NSTextView *)editor {
    return self.textView;
}

- (BOOL)composing {
    return self.textView.hasMarkedText;
}

- (void)setFabrumText:(NSString *)text {
    self.textView.string = text;
    self.textView.selectedRange = NSMakeRange(text.length, 0);
}

- (NSString *)fabrumText {
    return self.textView.string;
}

- (void)textDidChange:(NSNotification *)notification {
    if (self.textView.hasMarkedText) {
        self.composed = YES;
        return;
    }
    report(owner_of(self), self.fabrumId, EVENT_TEXT, 0, self.textView.string);
    if (self.composed) {
        self.composed = NO;
        report(owner_of(self), self.fabrumId, EVENT_COMPOSITION_END, 0, nil);
    }
}

// Three lines of text by default, and the box's width: apps bound its
// height through the element's sizing.
- (NSSize)fittingSize {
    double line = [self.textView.layoutManager defaultLineHeightForFont:self.textView.font];
    return NSMakeSize(0, 3 * line + 2 * self.textView.textContainerInset.height + 4);
}
@end

// A owner.popupOwner button, reporting the item chosen.
@interface FabrumPopUp : NSPopUpButton <FabrumElement>
@end
@implementation FabrumPopUp
FABRUM_FOCUS_REPORTING
@end

// A radio button of a group, reporting focus with the group's ID.
@interface FabrumRadioButton : NSButton
@property(nonatomic) uint64_t groupId;
@end
@implementation FabrumRadioButton
- (BOOL)becomeFirstResponder {
    FabrumWindowContext *owner = owner_of(self); \
        BOOL became = [super becomeFirstResponder];
    if (became) report(owner_of(self), self.groupId, EVENT_FOCUS, 1, nil);
    return became;
}
@end

// Radio buttons in a column or a row, exclusive by AppKit's rule (one
// superview, one action), reporting the one turned on.
@interface FabrumRadioGroup : NSView <FabrumElement>
@property(nonatomic) BOOL horizontal;
@end

@implementation FabrumRadioGroup
@synthesize fabrumId = _fabrumId;

- (BOOL)isFlipped {
    return YES;
}

- (void)setTitles:(NSArray<NSString *> *)titles {
    FabrumWindowContext *owner = owner_of(self);
    self.subviews = @[];
    for (NSUInteger i = 0; i < titles.count; i++) {
        FabrumRadioButton *button = [FabrumRadioButton radioButtonWithTitle:titles[i] target:owner.target action:@selector(radioChosen:)];
        button.groupId = self.fabrumId;
        button.tag = (NSInteger)i;
        [self addSubview:button];
    }
    [self place];
}

- (NSArray<NSButton *> *)buttons {
    return (NSArray<NSButton *> *)self.subviews;
}

// Each button at its fitting size, one under (or after) the other.
- (void)place {
    double at = 0;
    for (NSButton *button in self.buttons) {
        NSSize size = button.fittingSize;
        button.frame = self.horizontal ? NSMakeRect(at, 0, size.width, size.height) : NSMakeRect(0, at, size.width, size.height);
        at += (self.horizontal ? size.width + 12 : size.height + 2);
    }
}

- (NSSize)fittingSize {
    double width = 0, height = 0;
    NSUInteger n = 0;
    for (NSButton *button in self.buttons) {
        NSSize size = button.fittingSize;
        if (self.horizontal) {
            width += size.width + (n > 0 ? 12 : 0);
            height = MAX(height, size.height);
        } else {
            width = MAX(width, size.width);
            height += size.height + (n > 0 ? 2 : 0);
        }
        n++;
    }
    return NSMakeSize(width, height);
}

- (void)setSelection:(long)index {
    for (NSButton *button in self.buttons) button.state = button.tag == index ? NSControlStateValueOn : NSControlStateValueOff;
}

- (long)selection {
    for (NSButton *button in self.buttons)
        if (button.state == NSControlStateValueOn) return button.tag;
    return -1;
}

- (void)setGroupEnabled:(BOOL)enabled {
    for (NSButton *button in self.buttons) button.enabled = enabled;
}

- (BOOL)anyCanBecomeKeyView {
    for (NSButton *button in self.buttons)
        if (button.canBecomeKeyView) return YES;
    return NO;
}

- (NSView *)focusView {
    for (NSButton *button in self.buttons)
        if (button.state == NSControlStateValueOn) return button;
    return self.buttons.firstObject;
}
@end

// The field of a stepper, reporting focus with the stepper's ID.
@interface FabrumStepperField : NSTextField
@property(nonatomic) uint64_t stepperId;
@end
@implementation FabrumStepperField
- (BOOL)becomeFirstResponder {
    FabrumWindowContext *owner = owner_of(self); \
        BOOL became = [super becomeFirstResponder];
    if (became) report(owner_of(self), self.stepperId, EVENT_FOCUS, 1, nil);
    return became;
}
@end

// A number in a field with an NSStepper beside it: the arrows step it,
// and a number typed into the field (ending with Return or by leaving it)
// is clamped to the range. Both report the value.
@interface FabrumStepper : NSView <FabrumElement, NSTextFieldDelegate>
@property(nonatomic, strong) FabrumStepperField *field;
@property(nonatomic, strong) NSStepper *stepper;
@end

@implementation FabrumStepper
@synthesize fabrumId = _fabrumId;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.field = [FabrumStepperField textFieldWithString:@"0"];
        self.field.alignment = NSTextAlignmentRight;
        self.field.delegate = self;
        self.field.cell.sendsActionOnEndEditing = YES;
        self.field.target = self;
        self.field.action = @selector(typed:);
        self.stepper = [[NSStepper alloc] init];
        self.stepper.valueWraps = NO;
        self.stepper.target = self;
        self.stepper.action = @selector(stepped:);
        [self addSubview:self.field];
        [self addSubview:self.stepper];
        [self place];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setFabrumId:(uint64_t)fabrumId {
    _fabrumId = fabrumId;
    self.field.stepperId = fabrumId;
}

- (void)place {
    NSSize arrows = self.stepper.fittingSize;
    double height = MAX(self.field.fittingSize.height, arrows.height);
    self.field.frame = NSMakeRect(0, (height - self.field.fittingSize.height) / 2, 60, self.field.fittingSize.height);
    self.stepper.frame = NSMakeRect(64, (height - arrows.height) / 2, arrows.width, arrows.height);
}

- (NSSize)fittingSize {
    NSSize arrows = self.stepper.fittingSize;
    return NSMakeSize(64 + arrows.width, MAX(self.field.fittingSize.height, arrows.height));
}

- (void)setNumber:(double)value {
    self.stepper.doubleValue = value;
    self.field.stringValue = [NSString stringWithFormat:@"%g", self.stepper.doubleValue];
}

- (void)stepped:(id)sender {
    self.field.stringValue = [NSString stringWithFormat:@"%g", self.stepper.doubleValue];
    report(owner_of(self), self.fabrumId, EVENT_NUMBER, self.stepper.doubleValue, nil);
}

- (void)typed:(id)sender {
    double value = MIN(MAX(self.field.doubleValue, self.stepper.minValue), self.stepper.maxValue);
    if (value == self.stepper.doubleValue) {
        self.field.stringValue = [NSString stringWithFormat:@"%g", value];
        return;
    }
    [self setNumber:value];
    report(owner_of(self), self.fabrumId, EVENT_NUMBER, value, nil);
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return NO;
    if (selector == @selector(insertTab:)) {
        owner.host.tab(owner.host.ctx, 1);
        return YES;
    }
    if (selector == @selector(insertBacktab:)) {
        owner.host.tab(owner.host.ctx, 0);
        return YES;
    }
    return NO;
}

- (void)setGroupEnabled:(BOOL)enabled {
    self.field.enabled = enabled;
    self.stepper.enabled = enabled;
}
@end

// The platform's own label: wraps within the width fabrum measures it
// under, and is selectable if asked.
@interface FabrumLabel : NSTextField <FabrumElement>
@end
@implementation FabrumLabel
@synthesize fabrumId = _fabrumId;
@end

// A scroll view's document: what fabrum lays the content out in, top left
// first, with canvas layers and controls as subviews.
@interface FabrumDocumentView : NSView
@end

@implementation FabrumDocumentView
- (BOOL)isFlipped {
    return YES;
}
@end

// A native container that scrolls: AppKit scrolls, clips and draws the
// scrollers; fabrum sizes the document and arranges what is in it, and is
// told where it scrolled to.
@interface FabrumScrollView : NSScrollView <FabrumElement>
// The content's size, as fabrum laid it out.
@property(nonatomic) NSSize fabrumContentSize;
@end

@implementation FabrumScrollView
@synthesize fabrumId = _fabrumId;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.drawsBackground = NO;
        self.autohidesScrollers = YES;
        self.documentView = [[FabrumDocumentView alloc] initWithFrame:NSZeroRect];
        self.contentView.postsBoundsChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scrolled:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:self.contentView];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// The document covers the content, and the view where the content is
// smaller, so its first canvas layer takes clicks everywhere.
- (void)fitDocument {
    NSSize visible = self.contentView.bounds.size;
    NSSize size = self.fabrumContentSize;
    [self.documentView setFrameSize:NSMakeSize(MAX(size.width, visible.width), MAX(size.height, visible.height))];
}

- (void)tile {
    [super tile];
    [self fitDocument];
}

- (void)scrolled:(NSNotification *)notification {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    NSPoint origin = self.contentView.bounds.origin;
    owner.host.scroll(owner.host.ctx, self.fabrumId, origin.x, origin.y);
}
@end

// Receives controls' actions and reports them.
@interface FabrumTarget : NSObject
@end

@implementation FabrumTarget
- (void)pressed:(NSButton *)sender {
    report(owner_of(self), [(id<FabrumElement>)sender fabrumId], EVENT_ACTIVATE, 0, nil);
}
- (void)toggled:(NSControl *)sender {
    NSControlStateValue state = [sender isKindOfClass:[NSSwitch class]] ? ((NSSwitch *)sender).state : ((NSButton *)sender).state;
    report(owner_of(self), [(id<FabrumElement>)sender fabrumId], EVENT_TOGGLE, state == NSControlStateValueOn, nil);
}
- (void)moved:(NSControl *)sender {
    report(owner_of(self), [(id<FabrumElement>)sender fabrumId], EVENT_NUMBER, sender.doubleValue, nil);
}
- (void)chosen:(NSMenuItem *)sender {
    report(owner_of(self), (uint64_t)sender.tag, EVENT_ACTIVATE, 0, nil);
}
- (void)selected:(NSPopUpButton *)sender {
    report(owner_of(self), [(id<FabrumElement>)sender fabrumId], EVENT_SELECT, (double)sender.indexOfSelectedItem, nil);
}
- (void)radioChosen:(FabrumRadioButton *)sender {
    report(owner_of(self), sender.groupId, EVENT_SELECT, (double)sender.tag, nil);
}
@end

// An alert shown as a sheet while declared.
@interface FabrumAlert : NSObject
@property(nonatomic) uint64_t fabrumId;
@property(nonatomic, strong) NSAlert *alert;
@property(nonatomic) BOOL showing;
@end

@implementation FabrumAlert
- (void)show {
    FabrumWindowContext *owner = owner_of(self);
    if (self.showing) return;
    self.showing = YES;
    __weak FabrumAlert *weak = self;
    [self.alert beginSheetModalForWindow:owner.window
                       completionHandler:^(NSModalResponse response) {
                         FabrumAlert *strong = weak;
                         if (!strong || !strong.showing) return;
                         strong.showing = NO;
                         report(owner_of(strong), strong.fabrumId, EVENT_RESPONSE, (double)(response - NSAlertFirstButtonReturn), nil);
                       }];
}
- (void)dismiss {
    FabrumWindowContext *owner = owner_of(self);
    if (!self.showing) return;
    self.showing = NO;
    [owner.window endSheet:self.alert.window];
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
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return nil;
    NSView *hit = [super hitTest:point];
    if (hit != self) return hit;
    // a first layer, of the host or of a scroll view's document, takes it all
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return owner.host.hit_layer(owner.host.ctx, self.index, local.x, self.bounds.size.height - local.y) ? self : nil;
}

- (void)forward:(NSEvent *)event {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    owner.host.mouse(owner.host.ctx, (int)self.index, p.x, self.bounds.size.height - p.y, _buttons, 0, 0);
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
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    owner.host.mouse(owner.host.ctx, (int)self.index, p.x, self.bounds.size.height - p.y, _buttons, -event.scrollingDeltaX, -event.scrollingDeltaY);
    // and on up the responder chain, to the scroll view this is in, if any
    [super scrollWheel:event];
}

- (void)keyDown:(NSEvent *)event {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    switch (event.keyCode) {
    case 48: // Tab
        owner.host.tab(owner.host.ctx, !(event.modifierFlags & NSEventModifierFlagShift));
        return;
    case 49: // Space
        owner.host.activate(owner.host.ctx);
        return;
    case 36: // Return
        if (!(event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) && owner.host.enter(owner.host.ctx)) return;
        [super keyDown:event];
        return;
    default:
        [super keyDown:event];
    }
}

- (void)drawRect:(NSRect)dirty {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(cg);
    // fabrum's coordinates: the top left, y down
    CGContextTranslateCTM(cg, 0, self.bounds.size.height);
    CGContextScaleCTM(cg, 1, -1);
    owner.host.draw_layer(owner.host.ctx, self.index, cg, self.bounds.size.width, self.bounds.size.height);
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
    FabrumWindowContext *owner = owner_of(self);
    [super setFrameSize:size];
    for (NSView *canvas in owner.layers) canvas.frame = self.bounds;
    if (owner.window) run_frame(owner);
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
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    owner.host.mouse(owner.host.ctx, -1, p.x, p.y, 0, 0, 0);
}

- (void)mouseExited:(NSEvent *)event {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    // far outside, so nothing stays hovered
    owner.host.mouse(owner.host.ctx, -1, -1e6, -1e6, 0, 0, 0);
}
@end

// Routes Tab between native views to fabrum, so one order covers native
// and drawn elements.
@interface FabrumWindow : NSWindow
@end

@implementation FabrumWindow
- (void)keyDown:(NSEvent *)event {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    // Native responders have already had their chance to consume Return.
    NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand);
    if (event.keyCode == 36 && !modifiers && owner.host.enter(owner.host.ctx)) return;
    [super keyDown:event];
}
- (void)selectNextKeyView:(id)sender {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 1);
}
- (void)selectPreviousKeyView:(id)sender {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 0);
}
- (void)selectKeyViewFollowingView:(NSView *)view {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 1);
}
- (void)selectKeyViewPrecedingView:(NSView *)view {
    FabrumWindowContext *owner = owner_of(self);
    if (!owner || owner.closed) return;
    owner.host.tab(owner.host.ctx, 0);
}
@end

@interface FabrumAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

// Set by `fabrum_appkit_quit_now`, once the app has confirmed.
static bool quitting;

@implementation FabrumAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (quitting) return NSTerminateNow;
    for (FabrumWindowContext *owner in [windows copy]) {
        if (!owner.closed && !owner.host.should_close(owner.host.ctx, 1)) return NSTerminateCancel;
    }
    return NSTerminateNow;
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    FabrumWindowContext *owner = owner_of(window);
    return quitting || owner.host.should_close(owner.host.ctx, 0);
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    FabrumWindowContext *owner = owner_of(notification.object);
    if (owner.menu) {
        NSApp.mainMenu = owner.menu;
        NSApp.windowsMenu = owner.windowsMenu;
    }
}
- (void)windowWillClose:(NSNotification *)notification {
    FabrumWindowContext *owner = owner_of(notification.object);
    if (!owner.closed) owner.host.will_terminate(owner.host.ctx);
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    for (FabrumWindowContext *owner in [windows copy]) if (!owner.closed) owner.host.will_terminate(owner.host.ctx);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    for (FabrumWindowContext *owner in [windows copy]) { run_frame(owner); [owner.window makeKeyAndOrderFront:nil]; }
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

static FabrumAppDelegate *application_delegate;
static void prepare_application(void) {
    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (!windows) windows = [NSMutableArray array];
    if (!application_delegate) {
        application_delegate = [FabrumAppDelegate new];
        application.delegate = application_delegate;
    }
    if (!application.mainMenu) build_menu(NSProcessInfo.processInfo.processName);
}
void *fabrum_appkit_open(fabrum_appkit_options options, fabrum_appkit_host callbacks) {
    prepare_application();
    FabrumWindowContext *owner = [FabrumWindowContext new];
    owner.host = callbacks;
    owner.layers = [NSMutableArray array];
    owner.target = [FabrumTarget new]; own(owner.target, owner);
    NSString *title = [NSString stringWithUTF8String:options.title];
    build_menu(title); owner.menu = NSApp.mainMenu; owner.windowsMenu = NSApp.windowsMenu;
    NSWindow *window = [[FabrumWindow alloc] initWithContentRect:NSMakeRect(0, 0, options.width, options.height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    owner.window = window; own(window, owner);
    window.title = title;
    window.appearance = [NSAppearance appearanceNamed:options.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    window.contentMinSize = NSMakeSize(options.min_width, options.min_height);
    window.releasedWhenClosed = NO;
    owner.hostView = [[FabrumHostView alloc] initWithFrame:NSMakeRect(0, 0, options.width, options.height)];
    own(owner.hostView, owner); window.contentView = owner.hostView;
    window.delegate = application_delegate; [window center];
    owner.ready = YES;
    [windows addObject:owner];
    [window makeKeyAndOrderFront:nil];
    return (__bridge_retained void *)owner;
}
void fabrum_appkit_present(void *context) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    if (!owner.closed) [owner.window makeKeyAndOrderFront:nil];
}
bool fabrum_appkit_alive(void *context) { return !((__bridge FabrumWindowContext *)context).closed; }
void fabrum_appkit_invalidate(void *context) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    owner.closed = YES;
    owner.frameRequested = NO;
}
void fabrum_appkit_release(void *context) {
    FabrumWindowContext *owner = (__bridge_transfer FabrumWindowContext *)context;
    owner.closed = YES;
    if (owner.popupOwner) { [[(id)owner.popupOwner menu] cancelTracking]; [(id)owner.popupOwner answer:-1]; }
    if (owner.window.attachedSheet) [owner.window endSheet:owner.window.attachedSheet returnCode:NSModalResponseCancel];
    if (owner.openPanelDone) owner.openPanelDone(owner.openPanelCtx, NULL, 0);
    owner.openPanelDone = NULL;
    [owner.window close];
    [windows removeObject:owner];
    own(owner.window, nil); own(owner.target, nil); own(owner.hostView, nil);
    for (NSView *canvas in owner.layers) own(canvas, nil);
    owner.window = nil; owner.target = nil; owner.hostView = nil; owner.layers = nil;
}
void fabrum_appkit_loop(void) { @autoreleasepool { prepare_application(); [NSApp run]; } exit(0); }
static NSView *host_view(FabrumWindowContext *owner) { return owner.hostView; }
void fabrum_appkit_request_frame(void *context) {
    if (!context) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (FabrumWindowContext *window in [windows copy]) fabrum_appkit_request_frame((__bridge void *)window);
        });
        return;
    }
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!owner.closed && !owner.frameRequested) {
            owner.frameRequested = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ if (owner.frameRequested) run_frame(owner); });
        }
    });
}

// 0: arrow, 1: pointing hand, 2: I-beam. Only over the canvas; native
// views set their own. Main thread only.
void fabrum_appkit_set_cursor(void *context, int cursor, double x, double y) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSView *view = owner.hostView;
    NSView *hit = [view hitTest:[view convertPoint:NSMakePoint(x, y) toView:view.superview]];
    if (hit && ![hit isKindOfClass:[FabrumCanvasView class]]) return;
    [cursor == 1 ? [NSCursor pointingHandCursor] : cursor == 2 ? [NSCursor IBeamCursor] : [NSCursor arrowCursor] set];
}

@interface FabrumDeferred : NSObject
@property(nonatomic) void (*callback)(void *);
@property(nonatomic) void *context;
@end
@implementation FabrumDeferred
@end
void *fabrum_appkit_defer(void (*callback)(void *), void *context) {
    FabrumDeferred *task = [FabrumDeferred new]; task.callback = callback; task.context = context;
    dispatch_async(dispatch_get_main_queue(), ^{ if (task.callback) task.callback(task.context); });
    return (__bridge_retained void *)task;
}
void fabrum_appkit_cancel_defer(void *handle) {
    FabrumDeferred *task = (__bridge_transfer FabrumDeferred *)handle;
    task.callback = NULL; task.context = NULL;
}

void fabrum_appkit_run_on_main(void (*callback)(void *ctx), void *ctx) {
    dispatch_async_f(dispatch_get_main_queue(), ctx, callback);
}

void fabrum_appkit_quit(void) {
    [NSApp terminate:nil];
}

// Quits without asking the app: it has confirmed.
void fabrum_appkit_quit_now(void) {
    quitting = true;
    [NSApp terminate:nil];
}

// Closes the window without asking the app. It is the only window, so the
// app then quits, without asking either.
void fabrum_appkit_close_now(void *context) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    [owner.window close];
}

// The file chooser being shown, if any, and what answers it, for
// automation.




static void answer_open_panel(FabrumWindowContext *owner, const char *path) {
    fabrum_appkit_text_callback done = owner.openPanelDone;
    void *ctx = owner.openPanelCtx;
    owner.openPanel = nil;
    owner.openPanelDone = NULL;
    if (done) done(ctx, path, path ? strlen(path) : 0);
}

// Shows a chooser for one existing file, as a sheet, offering files with
// `extensions` (or any), or for one directory if `directory`, and calls
// `done` with its path, or NULL if cancelled. Main thread only.
void fabrum_appkit_open_file(void *context, const char *message, size_t message_len, const char *const *extensions, const size_t *lengths,
                             size_t count, bool directory, fabrum_appkit_text_callback done, void *ctx) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (size_t i = 0; i < count; i++) {
        UTType *type = [UTType typeWithFilenameExtension:string(extensions[i], lengths[i])];
        if (type) [types addObject:type];
    }
    // Copy borrowed request data before returning to update. NSOpenPanel's
    // first creation can be slow; create the sheet on the next main turn.
    NSString *panel_message = string(message, message_len);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (owner.closed) { done(ctx, NULL, 0); return; }
        if (owner.openPanel) answer_open_panel(owner, NULL);
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = !directory;
        panel.canChooseDirectories = directory;
        panel.canCreateDirectories = directory;
        panel.allowsMultipleSelection = NO;
        panel.resolvesAliases = YES;
        panel.message = panel_message;
        if (!directory && types.count > 0) panel.allowedContentTypes = types;
        owner.openPanel = panel;
        owner.openPanelDone = done;
        owner.openPanelCtx = ctx;
        [panel beginSheetModalForWindow:owner.window
                      completionHandler:^(NSModalResponse result) {
                        if (owner.openPanel != panel) return; // answered already
                        answer_open_panel(owner, result == NSModalResponseOK && panel.URLs.count > 0
                                              ? panel.URLs.firstObject.fileSystemRepresentation
                                              : NULL);
                      }];
    });
}

// The pasteboard the clipboard is: the general one, or a private one for
// automation, so checks never touch the user's clipboard.
static NSPasteboard *clipboard_pasteboard;

static NSPasteboard *pasteboard(void) {
    return clipboard_pasteboard ?: [NSPasteboard generalPasteboard];
}

bool fabrum_appkit_write_clipboard(const char *bytes, size_t len) {
    NSPasteboard *board = pasteboard();
    [board clearContents];
    return [board setString:string(bytes, len) forType:NSPasteboardTypeString];
}

// Calls `done` with the clipboard's text, or NULL if it has none.
void fabrum_appkit_read_clipboard(fabrum_appkit_text_callback done, void *ctx) {
    NSString *text = [pasteboard() stringForType:NSPasteboardTypeString];
    const char *utf8 = text.UTF8String;
    done(ctx, utf8, utf8 ? strlen(utf8) : 0);
}

// Dialogs and menus asked for from `update` (`app.platform.Services`).

static NSAlertStyle alert_style(int kind) {
    switch (kind) {
    case DIALOG_WARNING: return NSAlertStyleWarning;
    case DIALOG_ERROR: return NSAlertStyleCritical;
    default: return NSAlertStyleInformational;
    }
}

// Shows a message as a sheet with an OK button, which goes away by itself
// after `timeout_ms` if nonzero. Main thread only.
void fabrum_appkit_message(void *context, const char *title, size_t title_len, const char *text, size_t text_len, int kind, unsigned timeout_ms) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = alert_style(kind);
    alert.messageText = string(title, title_len);
    alert.informativeText = string(text, text_len);
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:owner.window completionHandler:nil];
    if (timeout_ms > 0) {
        NSWindow *sheet = alert.window;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          if (owner.window.attachedSheet == sheet) [owner.window endSheet:sheet];
        });
    }
}

// Asks with up to three buttons as a sheet, the one at `default_index`
// answering Return, and calls `done` with the index pressed. Main thread
// only.
void fabrum_appkit_confirm(void *context, const char *title, size_t title_len, const char *text, size_t text_len, const char *const *buttons,
                           const size_t *lengths, size_t count, size_t default_index, int kind,
                           fabrum_appkit_index_callback done, void *ctx) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = alert_style(kind);
    alert.messageText = string(title, title_len);
    alert.informativeText = string(text, text_len);
    for (size_t i = 0; i < count; i++) {
        NSButton *button = [alert addButtonWithTitle:string(buttons[i], lengths[i])];
        // the first button is AppKit's default; another asked for takes
        // Return instead, and Escape stays with a "Cancel"
        if (i == default_index) button.keyEquivalent = @"\r";
        else if (i == 0) button.keyEquivalent = @"";
    }
    [alert beginSheetModalForWindow:owner.window
                  completionHandler:^(NSModalResponse response) {
                    long index = owner.closed ? -1 : response - NSAlertFirstButtonReturn;
                    done(ctx, index >= 0 && (size_t)index < count ? index : -1);
                  }];
}

// The owner.popupOwner menu being shown, if any: it answers once, through `done`,
// with the item chosen or -1.




@implementation FabrumPopup
- (void)answer:(long)index {
    FabrumWindowContext *owner = owner_of(self);
    if (self.answered) return;
    self.answered = YES;
    if (owner.popupOwner == self) owner.popupOwner = nil;
    self.done(self.ctx, index);
}
- (void)chose:(NSMenuItem *)sender {
    [self answer:sender.tag];
}
- (void)menuDidClose:(NSMenu *)menu {
    if (menu != self.menu) return;
    // the chosen item's action comes after the menu closes: give it a turn
    dispatch_async(dispatch_get_main_queue(), ^{
      [self answer:-1];
    });
}
@end

static NSMenu *build_popup(FabrumPopup *owner, const fabrum_appkit_menu_item *items, size_t count, size_t *index, unsigned depth) {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    while (*index < count) {
        const fabrum_appkit_menu_item *item = &items[*index];
        if (item->depth < depth) break;
        (*index)++;
        NSString *title = string(item->title, item->title_len);
        switch (item->kind) {
        case 1: { // header
            NSMenuItem *header;
            if (@available(macOS 14.0, *)) header = [NSMenuItem sectionHeaderWithTitle:title];
            else {
                header = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
                header.enabled = NO;
            }
            [menu addItem:header];
            break;
        }
        case 2: // separator
            [menu addItem:[NSMenuItem separatorItem]];
            break;
        case 3: { // submenu: the items one deeper follow
            NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            holder.enabled = item->enabled;
            holder.submenu = build_popup(owner, items, count, index, depth + 1);
            [menu addItem:holder];
            break;
        }
        default: {
            NSMenuItem *entry = [[NSMenuItem alloc] initWithTitle:title action:@selector(chose:) keyEquivalent:@""];
            entry.target = owner;
            entry.tag = (NSInteger)item->id;
            entry.enabled = item->enabled;
            [menu addItem:entry];
        }
        }
    }
    return menu;
}

// Shows a owner.popupOwner menu with its top left at (x, y) of the content, and calls
// `done` with the id of the item chosen, or -1 if it was dismissed. The
// menu opens after the current event, since AppKit tracks it in a loop of
// its own, which must not run inside a call into fabrum. Main thread
// only.
void fabrum_appkit_popup_menu(void *context, const fabrum_appkit_menu_item *items, size_t count, double x, double y, fabrum_appkit_index_callback done, void *ctx) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    FabrumPopup *menu_owner = [[FabrumPopup alloc] init];
    menu_owner.done = done;
    menu_owner.ctx = ctx;
    size_t index = 0;
    menu_owner.menu = build_popup(menu_owner, items, count, &index, 0);
    menu_owner.menu.delegate = menu_owner; own(menu_owner, owner);
    if (owner.popupOwner) [owner.popupOwner answer:-1];
    owner.popupOwner = menu_owner;
    NSView *view = host_view(owner);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (owner.closed) { [menu_owner answer:-1]; return; }
      if (owner.popupOwner != menu_owner) return;
      [menu_owner.menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(x, y) inView:view];
    });
}

// Native objects. Handles are retained Objective-C objects.

void *fabrum_appkit_create(void *context, int kind, uint64_t element) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    host_view(owner);
    if (!owner.target) owner.target = [[FabrumTarget alloc] init];
    id made = nil;
    switch (kind) {
    case KIND_BUTTON: {
        FabrumButton *button = [FabrumButton buttonWithTitle:@"" target:owner.target action:@selector(pressed:)];
        button.fabrumId = element;
        made = button;
        break;
    }
    case KIND_CHECKBOX: {
        FabrumButton *box = [FabrumButton checkboxWithTitle:@"" target:owner.target action:@selector(toggled:)];
        box.fabrumId = element;
        made = box;
        break;
    }
    case KIND_SWITCH: {
        FabrumSwitch *toggle = [[FabrumSwitch alloc] init];
        toggle.target = owner.target;
        toggle.action = @selector(toggled:);
        toggle.fabrumId = element;
        made = toggle;
        break;
    }
    case KIND_SLIDER: {
        FabrumSlider *slider = [FabrumSlider sliderWithTarget:owner.target action:@selector(moved:)];
        slider.continuous = YES;
        slider.fabrumId = element;
        made = slider;
        break;
    }
    case KIND_LEVEL_INDICATOR: {
        FabrumLevelIndicator *level = [[FabrumLevelIndicator alloc] init];
        level.levelIndicatorStyle = NSLevelIndicatorStyleRating;
        level.editable = YES;
        level.target = owner.target;
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
        item.target = owner.target;
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
    case KIND_SCROLL_VIEW: {
        FabrumScrollView *scroll = [[FabrumScrollView alloc] initWithFrame:NSZeroRect];
        scroll.fabrumId = element;
        made = scroll;
        break;
    }
    case KIND_TEXT_AREA: {
        FabrumTextArea *area = [[FabrumTextArea alloc] initWithFrame:NSMakeRect(0, 0, 200, 60)];
        area.fabrumId = element;
        made = area;
        break;
    }
    case KIND_SEARCH_FIELD: {
        FabrumSearchField *field = [[FabrumSearchField alloc] init];
        field.delegate = (id<NSSearchFieldDelegate>)field;
        field.fabrumId = element;
        field.cell.sendsActionOnEndEditing = NO;
        made = field;
        break;
    }
    case KIND_SECURE_FIELD: {
        FabrumSecureField *field = [[FabrumSecureField alloc] init];
        field.delegate = field;
        field.fabrumId = element;
        field.cell.sendsActionOnEndEditing = NO;
        field.cell.scrollable = YES;
        field.cell.wraps = NO;
        field.usesSingleLineMode = YES;
        made = field;
        break;
    }
    case KIND_SPINNER: {
        FabrumProgress *spinner = [[FabrumProgress alloc] init];
        spinner.style = NSProgressIndicatorStyleSpinning;
        spinner.indeterminate = YES;
        spinner.displayedWhenStopped = YES;
        spinner.fabrumId = element;
        [spinner startAnimation:nil];
        made = spinner;
        break;
    }
    case KIND_DROPDOWN: {
        FabrumPopUp *popup_button = [[FabrumPopUp alloc] initWithFrame:NSZeroRect pullsDown:NO];
        popup_button.target = owner.target;
        popup_button.action = @selector(selected:);
        popup_button.fabrumId = element;
        made = popup_button;
        break;
    }
    case KIND_RADIO_GROUP: {
        FabrumRadioGroup *group = [[FabrumRadioGroup alloc] initWithFrame:NSZeroRect];
        group.fabrumId = element;
        made = group;
        break;
    }
    case KIND_STEPPER: {
        FabrumStepper *stepper = [[FabrumStepper alloc] initWithFrame:NSZeroRect];
        stepper.fabrumId = element;
        made = stepper;
        break;
    }
    case KIND_LABEL: {
        FabrumLabel *label = [FabrumLabel labelWithString:@""];
        label.fabrumId = element;
        made = label;
        break;
    }
    }
    if ([made isKindOfClass:[NSView class]]) {
        NSView *view = made;
        // positioned by frame; `arrange` adds it to the host
        view.translatesAutoresizingMaskIntoConstraints = YES;
    }
    own(made, owner);
    return (__bridge_retained void *)made;
}

void fabrum_appkit_destroy(void *handle) {
    FabrumWindowContext *owner = owner_of((__bridge id)handle);
    id made = (__bridge_transfer id)handle;
    if ([made isKindOfClass:[NSView class]]) {
        [(NSView *)made removeFromSuperview];
    } else if ([made isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = made;
        NSMenu *menu = item.menu;
        [menu removeItem:item];
        // drop a menu fabrum made once it is empty
        if (menu && menu.numberOfItems == 0) {
            NSMenuItem *holder = [owner.menu itemWithTitle:menu.title];
            if (holder) [owner.menu removeItem:holder];
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
    else if ([made isKindOfClass:[FabrumLabel class]]) ((FabrumLabel *)made).stringValue = title;
}

// A label's look: wrapping (or one line cut with an ellipsis), selectable,
// a font size (0 for the system's control size), the secondary color.
void fabrum_appkit_set_label_style(void *handle, bool wrap, bool selectable, double font_size, bool secondary) {
    FabrumLabel *label = object(handle);
    label.font = [NSFont systemFontOfSize:font_size > 0 ? font_size : NSFont.systemFontSize];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    label.selectable = selectable;
    label.cell.wraps = wrap;
    label.cell.truncatesLastVisibleLine = YES;
    label.lineBreakMode = wrap ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = wrap ? 0 : 1;
}

// The items of a owner.popupOwner button or radio group, replacing any.
void fabrum_appkit_set_items(void *handle, const char *const *titles, const size_t *lengths, size_t count) {
    FabrumWindowContext *owner = owner_of((__bridge id)handle);
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [strings addObject:string(titles[i], lengths[i])];
    id made = object(handle);
    if ([made isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton *popup_button = made;
        [popup_button removeAllItems];
        // addItemsWithTitles: merges duplicates; items are added one by one
        for (NSString *title in strings) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
            [popup_button.menu addItem:item];
        }
        [popup_button sizeToFit];
    } else if ([made isKindOfClass:[FabrumRadioGroup class]]) {
        [(FabrumRadioGroup *)made setTitles:strings];
    }
}

// Which item of a owner.popupOwner button or radio group is chosen, or -1 for none.
void fabrum_appkit_set_selection(void *handle, long index) {
    FabrumWindowContext *owner = owner_of((__bridge id)handle);
    id made = object(handle);
    if ([made isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton *popup_button = made;
        if (index >= 0 && index < popup_button.numberOfItems) [popup_button selectItemAtIndex:index];
        else [popup_button selectItem:nil];
    } else if ([made isKindOfClass:[FabrumRadioGroup class]]) {
        [(FabrumRadioGroup *)made setSelection:index];
    }
}

// Whether a radio group's buttons are in a row.
void fabrum_appkit_set_horizontal(void *handle, bool horizontal) {
    FabrumRadioGroup *group = object(handle);
    group.horizontal = horizontal;
    [group place];
}

// What one click of a stepper's arrows adds.
void fabrum_appkit_set_increment(void *handle, double step) {
    ((FabrumStepper *)object(handle)).stepper.increment = step;
}

// A spinner's size: small (16 points) or regular (32).
void fabrum_appkit_set_spinner_size(void *handle, bool small) {
    ((NSProgressIndicator *)object(handle)).controlSize = small ? NSControlSizeSmall : NSControlSizeRegular;
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
    else if ([made isKindOfClass:[FabrumTextArea class]]) {
        NSTextView *view = ((FabrumTextArea *)made).textView;
        view.editable = enabled;
        view.selectable = enabled;
        view.textColor = enabled ? NSColor.textColor : NSColor.disabledControlTextColor;
    } else if ([made isKindOfClass:[FabrumRadioGroup class]]) [(FabrumRadioGroup *)made setGroupEnabled:enabled];
    else if ([made isKindOfClass:[FabrumStepper class]]) [(FabrumStepper *)made setGroupEnabled:enabled];
}

void fabrum_appkit_set_default(void *handle, bool is_default) {
    ((NSButton *)object(handle)).keyEquivalent = is_default ? @"\r" : @"";
}

void fabrum_appkit_set_placeholder(void *handle, const char *bytes, size_t len) {
    id made = object(handle);
    if ([made isKindOfClass:[NSTextField class]]) ((NSTextField *)made).placeholderString = string(bytes, len);
    else if ([made isKindOfClass:[FabrumTextArea class]]) {
        // NSTextView shows a placeholder through a property AppKit doesn't
        // declare; it is set by name, and left out where it isn't there
        NSTextView *view = ((FabrumTextArea *)made).textView;
        if ([view respondsToSelector:@selector(setPlaceholderAttributedString:)]) {
            NSDictionary *attributes = @{NSForegroundColorAttributeName : NSColor.placeholderTextColor, NSFontAttributeName : view.font};
            [view setValue:[[NSAttributedString alloc] initWithString:string(bytes, len) attributes:attributes] forKey:@"placeholderAttributedString"];
        }
    }
}

void fabrum_appkit_set_range(void *handle, double min, double max) {
    id made = object(handle);
    if ([made isKindOfClass:[NSSlider class]]) {
        ((NSSlider *)made).minValue = min;
        ((NSSlider *)made).maxValue = max;
    } else if ([made isKindOfClass:[NSLevelIndicator class]]) {
        ((NSLevelIndicator *)made).minValue = min;
        ((NSLevelIndicator *)made).maxValue = max;
    } else if ([made isKindOfClass:[FabrumStepper class]]) {
        ((FabrumStepper *)made).stepper.minValue = min;
        ((FabrumStepper *)made).stepper.maxValue = max;
    }
}

void fabrum_appkit_set_bool(void *handle, bool on) {
    id made = object(handle);
    NSControlStateValue state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ([made isKindOfClass:[NSSwitch class]]) ((NSSwitch *)made).state = state;
    else ((NSButton *)made).state = state;
}

void fabrum_appkit_set_number(void *handle, double value) {
    id made = object(handle);
    if ([made isKindOfClass:[FabrumStepper class]]) [(FabrumStepper *)made setNumber:value];
    else ((NSControl *)made).doubleValue = value;
}

// Writes a field's or text area's text. While the user edits a field, the
// field editor holds the text, so it is written there, keeping editing
// going with the caret at the end.
void fabrum_appkit_set_text(void *handle, const char *bytes, size_t len) {
    [(id<FabrumEditable>)object(handle) setFabrumText:string(bytes, len)];
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
    FabrumWindowContext *owner = owner_of(item);
    NSMenu *bar = owner.menu;
    if (!bar) return;
    if (item.menu) {
        if ([item.menu.title isEqualToString:title]) return;
        [item.menu removeItem:item];
    }
    NSMenuItem *holder = [bar itemWithTitle:title];
    if (!holder) {
        holder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        holder.submenu = [[NSMenu alloc] initWithTitle:title];
        NSInteger window_index = owner.windowsMenu ? [bar indexOfItemWithSubmenu:owner.windowsMenu] : -1;
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

// Which ways a scroll view scrolls, with scrollers that show while it does.
void fabrum_appkit_set_scroll_axes(void *handle, bool horizontal, bool vertical) {
    FabrumScrollView *scroll = object(handle);
    scroll.hasHorizontalScroller = horizontal;
    scroll.hasVerticalScroller = vertical;
}

// The size of a scroll view's content, which its document covers.
void fabrum_appkit_set_content_size(void *handle, double w, double h) {
    FabrumScrollView *scroll = object(handle);
    scroll.fabrumContentSize = NSMakeSize(w, h);
    [scroll fitDocument];
}

// Moves a context's user space by (dx, dy), for canvas layers that draw in
// a scroll view's document.
void fabrum_appkit_translate(CGContextRef cg, double dx, double dy) {
    CGContextTranslateCTM(cg, dx, dy);
}

// The size a view wants, under a width limit (`max_width` 0 for none): a
// wrapping label gives the height of its text wrapped to the limit.
void fabrum_appkit_fitting_size(void *handle, double max_width, double *w, double *h) {
    NSView *view = object(handle);
    if ([view isKindOfClass:[FabrumLabel class]] && max_width > 0) {
        // wrapped to the limit, or one line cut with an ellipsis at it
        NSSize wrapped = [((FabrumLabel *)view).cell cellSizeForBounds:NSMakeRect(0, 0, max_width, CGFLOAT_MAX)];
        *w = MIN(wrapped.width, max_width);
        *h = ((FabrumLabel *)view).cell.wraps ? wrapped.height : view.fittingSize.height;
        return;
    }
    NSSize size = view.fittingSize;
    NSSize intrinsic = view.intrinsicContentSize;
    // views without an intrinsic width, such as progress bars, fit to none
    *w = size.width > 0 ? size.width : (intrinsic.width == NSViewNoIntrinsicMetric ? 0 : intrinsic.width);
    *h = size.height > 0 ? size.height : (intrinsic.height == NSViewNoIntrinsicMetric ? 0 : intrinsic.height);
}

bool fabrum_appkit_is_composing(void *handle) {
    id made = object(handle);
    return [made conformsToProtocol:@protocol(FabrumEditable)] && [(id<FabrumEditable>)made composing];
}

bool fabrum_appkit_can_focus(void *handle) {
    NSView *view = object(handle);
    if (![view isKindOfClass:[NSView class]] || !view.superview) return false;
    // AppKit's own rule, which follows the Keyboard navigation setting
    if ([view isKindOfClass:[FabrumTextArea class]]) return ((FabrumTextArea *)view).textView.editable;
    if ([view isKindOfClass:[FabrumRadioGroup class]]) return [(FabrumRadioGroup *)view anyCanBecomeKeyView];
    if ([view isKindOfClass:[FabrumStepper class]]) return ((FabrumStepper *)view).field.enabled;
    return view.canBecomeKeyView || (view.acceptsFirstResponder && [view isKindOfClass:[NSTextField class]]);
}

// Gives keyboard focus to a native view, to the canvas (`canvas` nonzero),
// or to nothing.
void fabrum_appkit_focus(void *context, void *handle, int canvas) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSWindow *window = owner.window;
    if (!window) return;
    if (handle) {
        NSView *view = object(handle);
        NSView *target = view;
        if ([view isKindOfClass:[FabrumTextArea class]]) target = ((FabrumTextArea *)view).textView;
        else if ([view isKindOfClass:[FabrumRadioGroup class]]) target = [(FabrumRadioGroup *)view focusView];
        else if ([view isKindOfClass:[FabrumStepper class]]) target = ((FabrumStepper *)view).field;
        [window makeFirstResponder:target];
        // in a scroll view, into sight, as AppKit's own key-view loop does
        [view scrollRectToVisible:view.bounds];
    } else if (canvas && owner.layers.count > 0) {
        [window makeFirstResponder:owner.layers[0]];
    } else {
        [window makeFirstResponder:nil];
    }
}

// Stacks the subviews of the host, or of a scroll view's document if
// `container` is one: canvas layers and native views, bottom to top. A view
// that was in another parent last frame (a reparented element, or a canvas
// layer that moved between the host and a document) is taken out of it
// first. Canvas layers are redrawn where `fabrum_appkit_damage_layer`
// says, not here.
void fabrum_appkit_arrange(void *context, void *container, const fabrum_appkit_slot *slots, size_t count) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSView *view = container ? ((FabrumScrollView *)object(container)).documentView : host_view(owner);
    NSMutableArray<NSView *> *order = [NSMutableArray arrayWithCapacity:count];
    // taken before anything moves, since removing the first responder's
    // view resigns it
    NSWindow *window = view.window ?: owner.window;
    NSResponder *responder = window.firstResponder;
    for (size_t i = 0; i < count; i++) {
        NSView *subview;
        if (slots[i].canvas >= 0) {
            unsigned layer = (unsigned)slots[i].canvas;
            while (owner.layers.count <= layer) {
                FabrumCanvasView *canvas = [[FabrumCanvasView alloc] initWithFrame:view.bounds];
                canvas.index = (unsigned)owner.layers.count;
                own(canvas, owner);
                canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                [owner.layers addObject:canvas];
            }
            subview = owner.layers[layer];
            // layers move between the host and documents from frame to frame
            if (subview.superview != view || !NSEqualRects(subview.frame, view.bounds)) subview.frame = view.bounds;
        } else {
            subview = object(slots[i].view);
        }
        if (subview.superview && subview.superview != view) [subview removeFromSuperview];
        [order addObject:subview];
    }
    if (![view.subviews isEqualToArray:order]) {
        view.subviews = order;
    }
    // keep the first responder if it stays
    if (responder && window.firstResponder != responder && [responder isKindOfClass:[NSView class]] &&
        [(NSView *)responder isDescendantOf:view]) {
        [window makeFirstResponder:responder];
    }
}

// Redraws part of canvas layer `layer`: a rectangle in points from its
// top left. Only what fabrum's damage says changed is redrawn, so a scroll
// step that moves nothing in a document's canvas redraws nothing.
void fabrum_appkit_damage_layer(void *context, unsigned layer, double x, double y, double w, double h) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    if (layer >= owner.layers.count) return;
    NSView *canvas = owner.layers[layer];
    NSRect bounds = canvas.bounds;
    // the view isn't flipped: fabrum's y runs down from the top
    NSRect dirty = NSIntersectionRect(NSMakeRect(x, bounds.size.height - (y + h), w, h), bounds);
    if (!NSIsEmptyRect(dirty)) [canvas setNeedsDisplayInRect:dirty];
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

void fabrum_appkit_theme(void *context, fabrum_appkit_theme_values *out) {
    FabrumWindowContext *owner = (__bridge FabrumWindowContext *)context;
    NSAppearance *appearance = owner.window ? owner.window.effectiveAppearance : NSApp.effectiveAppearance;
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
bool fabrum_appkit_snapshot(void *context, const char *path, double scale) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSView *view = owner.window ? owner.window.contentView : owner.hostView;
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
long fabrum_appkit_window_number(void *context) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    return owner.window.windowNumber;
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
    FabrumWindowContext *owner = owner_of((__bridge id)handle);
    id<FabrumEditable> field = object(handle);
    if (![field editor] || owner.window.firstResponder != [field editor]) fabrum_appkit_focus((__bridge void *)owner_of((__bridge id)handle), handle, 0);
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
    id<FabrumEditable> field = object(handle);
    if (![field editor]) fabrum_appkit_focus((__bridge void *)owner_of((__bridge id)handle), handle, 0);
    NSTextView *editor = [field editor];
    NSString *text = string(bytes, len);
    [editor setMarkedText:text selectedRange:NSMakeRange(text.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
}

// Commits a composition with `text`, as choosing a candidate does.
void fabrum_appkit_commit(void *handle, const char *bytes, size_t len) {
    NSTextView *editor = [(id<FabrumEditable>)object(handle) editor];
    [editor insertText:string(bytes, len) replacementRange:NSMakeRange(NSNotFound, 0)];
}

// The text a field shows, marked text included, into `out`; returns its
// length in bytes, or 0.
size_t fabrum_appkit_text(void *handle, char *out, size_t cap) {
    NSString *text = [(id<FabrumEditable>)object(handle) fabrumText];
    const char *utf8 = text.UTF8String;
    size_t n = MIN(strlen(utf8), cap);
    memcpy(out, utf8, n);
    return n;
}

// Presses Return in a field being edited, as the key would through the
// field editor's `insertNewline:`.
void fabrum_appkit_newline(void *handle) {
    id<FabrumEditable> field = object(handle);
    if (![field editor]) fabrum_appkit_focus((__bridge void *)owner_of((__bridge id)handle), handle, 0);
    [[field editor] doCommandBySelector:@selector(insertNewline:)];
}

// Chooses item `index` of a owner.popupOwner button or radio group, sending its
// action as a click does.
void fabrum_appkit_select(void *handle, long index) {
    FabrumWindowContext *owner = owner_of((__bridge id)handle);
    id made = object(handle);
    if ([made isKindOfClass:[NSPopUpButton class]]) {
        NSPopUpButton *popup_button = made;
        if (index < 0 || index >= popup_button.numberOfItems) return;
        [popup_button selectItemAtIndex:index];
        [popup_button sendAction:popup_button.action to:popup_button.target];
    } else if ([made isKindOfClass:[FabrumRadioGroup class]]) {
        NSArray<NSButton *> *buttons = [(FabrumRadioGroup *)made buttons];
        if (index < 0 || (NSUInteger)index >= buttons.count) return;
        [buttons[(NSUInteger)index] performClick:nil];
    }
}

// Scrolls a scroll view so that (x, y) of its content is at its top left,
// as far as it goes, as the wheel would, in process.
void fabrum_appkit_scroll_to(void *handle, double x, double y) {
    FabrumScrollView *scroll = object(handle);
    NSClipView *clip = scroll.contentView;
    NSSize document = scroll.documentView.frame.size;
    NSSize visible = clip.bounds.size;
    NSPoint point = NSMakePoint(MIN(MAX(x, 0), MAX(document.width - visible.width, 0)), MIN(MAX(y, 0), MAX(document.height - visible.height, 0)));
    [clip scrollToPoint:point];
    [scroll reflectScrolledClipView:clip];
}

// Steps a stepper `steps` up (or down, if negative), as its arrows do.
void fabrum_appkit_step(void *handle, long steps) {
    FabrumStepper *stepper = object(handle);
    stepper.stepper.doubleValue = stepper.stepper.doubleValue + stepper.stepper.increment * steps;
    [stepper stepped:nil];
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
void fabrum_appkit_tab(void *context, int forward) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSResponder *responder = owner.window.firstResponder;
    if ([responder isKindOfClass:[NSTextView class]]) {
        [(NSTextView *)responder doCommandBySelector:forward ? @selector(insertTab:) : @selector(insertBacktab:)];
    } else if (forward) {
        [owner.window selectNextKeyView:nil];
    } else {
        [owner.window selectPreviousKeyView:nil];
    }
}

// Answers the alert being shown with the button at `index`.
void fabrum_appkit_answer_alert(void *context, int index) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSWindow *sheet = owner.window.attachedSheet;
    if (sheet) [owner.window endSheet:sheet returnCode:NSAlertFirstButtonReturn + index];
}

// Chooses the item with `id` in the owner.popupOwner menu being shown (or dismisses
// it with -1), closing it. Returns whether one was shown.
bool fabrum_appkit_answer_popup(void *context, long id) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    FabrumPopup *menu_owner = owner.popupOwner;
    if (!menu_owner) return false;
    [menu_owner.menu cancelTracking];
    [menu_owner answer:id];
    return true;
}

// Chooses the item titled `title` in the menu titled `menu`, as the menu
// bar would.
bool fabrum_appkit_choose_menu(void *context, const char *menu, const char *title) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSMenuItem *holder = [owner.menu itemWithTitle:[NSString stringWithUTF8String:menu]];
    NSMenu *submenu = holder.submenu;
    NSInteger index = [submenu indexOfItemWithTitle:[NSString stringWithUTF8String:title]];
    if (index < 0) return false;
    [submenu performActionForItemAtIndex:index];
    return true;
}

// Resizes the window's content, as dragging its corner does.
void fabrum_appkit_resize(void *context, double width, double height) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    [owner.window setContentSize:NSMakeSize(width, height)];
}

// A description of the first responder, into `out`.
size_t fabrum_appkit_describe_focus(void *context, char *out, size_t cap) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSResponder *responder = owner.window.firstResponder;
    if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder isFieldEditor]) {
        responder = (NSResponder *)((NSTextView *)responder).delegate;
    }
    // a part of a composite control (a radio button, a stepper's field, a
    // text area's text view) stands for the control
    NSView *view = [responder isKindOfClass:[NSView class]] ? (NSView *)responder : nil;
    while (view && ![view conformsToProtocol:@protocol(FabrumElement)] && ![view isKindOfClass:[FabrumCanvasView class]]) view = view.superview;
    if (view) responder = view;
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
size_t fabrum_appkit_describe_hit(void *context, double x, double y, char *out, size_t cap) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSView *content = owner.window.contentView;
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
void fabrum_appkit_synthesize_click(void *context, double x, double y) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSWindow *window = owner.window;
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
void fabrum_appkit_synthesize_key(void *context, unsigned short key_code, const char *characters, bool shift) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSWindow *window = owner.window;
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

// Uses a private pasteboard as the clipboard from now on, for automation.
void fabrum_appkit_use_private_clipboard(void) {
    clipboard_pasteboard = [NSPasteboard pasteboardWithName:@"fabrum.automation"];
}

// The private clipboard's text, for automation, into `out`.
size_t fabrum_appkit_clipboard_text(char *out, size_t cap) {
    NSString *text = [pasteboard() stringForType:NSPasteboardTypeString] ?: @"";
    const char *utf8 = text.UTF8String;
    size_t n = MIN(strlen(utf8), cap);
    memcpy(out, utf8, n);
    return n;
}

// Answers the file chooser being shown with `path` (NULL cancels), closing
// it, as if the user had chosen. Returns whether one was shown.
bool fabrum_appkit_answer_open_panel(void *context, const char *path) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    NSOpenPanel *panel = owner.openPanel;
    if (!panel) return false;
    answer_open_panel(owner, path);
    [NSApp endSheet:panel returnCode:NSModalResponseCancel];
    [panel orderOut:nil];
    return true;
}

// Asks to close the window, as its close button does, for automation.
void fabrum_appkit_perform_close(void *context) {
    FabrumWindowContext *owner = context ? (__bridge FabrumWindowContext *)context : active_owner();
    [owner.window performClose:nil];
}
