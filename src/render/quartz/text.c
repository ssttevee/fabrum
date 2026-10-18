// Fonts and text measurement for fabrum's Quartz renderer, with Core Text
// alone: no AppKit, so it works in programs without a window, such as one
// drawing into a PDF or a bitmap with fabrum's `none` platform.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>

static CFStringRef string_from_zig(const char *bytes, size_t len) {
    return CFStringCreateWithBytes(NULL, (const UInt8 *)bytes, (CFIndex)len, kCFStringEncodingUTF8, false);
}

// Copies `string` as UTF-8 into `out`, up to `cap` bytes, and returns its
// whole length in bytes.
static size_t string_to_zig(CFStringRef string, char *out, size_t cap) {
    if (!string) return 0;
    CFIndex length = CFStringGetLength(string);
    CFIndex needed = 0;
    CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF8, '?', false, NULL, 0, &needed);
    CFIndex used = 0;
    CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF8, '?', false, (UInt8 *)out, (CFIndex)cap, &used);
    return (size_t)needed;
}

// The names of the font families installed, sorted. Release it.
CFArrayRef quartz_renderer_text_content_font_family_names_array(void) {
    CFArrayRef names = CTFontManagerCopyAvailableFontFamilyNames();
    if (!names) return NULL;
    CFMutableArrayRef sorted = CFArrayCreateMutableCopy(NULL, 0, names);
    CFRelease(names);
    CFArraySortValues(sorted, CFRangeMake(0, CFArrayGetCount(sorted)), (CFComparatorFunction)CFStringCompare, NULL);
    return sorted;
}

// The fonts of a family, as Core Text font descriptors. Release it.
CFArrayRef quartz_renderer_text_content_font_names_for_family_name(const char *family_name, size_t family_name_len) {
    CFStringRef family = string_from_zig(family_name, family_name_len);
    if (!family) return NULL;
    const void *keys[] = {kCTFontFamilyNameAttribute};
    const void *values[] = {family};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    CFRelease(family);
    const void *descriptors[] = {descriptor};
    CFArrayRef wanted = CFArrayCreate(NULL, descriptors, 1, &kCFTypeArrayCallBacks);
    CFRelease(descriptor);
    CTFontCollectionRef collection = CTFontCollectionCreateWithFontDescriptors(wanted, NULL);
    CFRelease(wanted);
    CFArrayRef members = CTFontCollectionCreateMatchingFontDescriptors(collection);
    CFRelease(collection);
    return members;
}

// Copies the name at `index` into `out`, returning its length, or SIZE_MAX
// past the end.
size_t quartz_renderer_text_content_font_family_names_index(CFArrayRef names, size_t index, char *out, size_t cap) {
    if ((CFIndex)index >= CFArrayGetCount(names)) return SIZE_MAX;
    return string_to_zig(CFArrayGetValueAtIndex(names, (CFIndex)index), out, cap);
}

// The member at `index`, retained, or NULL past the end.
CTFontDescriptorRef quartz_renderer_text_content_font_family_members_index(CFArrayRef members, size_t index) {
    if (!members || (CFIndex)index >= CFArrayGetCount(members)) return NULL;
    return CFRetain(CFArrayGetValueAtIndex(members, (CFIndex)index));
}

static size_t descriptor_string(CTFontDescriptorRef member, CFStringRef attribute, char *out, size_t cap) {
    CFStringRef value = CTFontDescriptorCopyAttribute(member, attribute);
    size_t len = string_to_zig(value, out, cap);
    if (value) CFRelease(value);
    return len;
}

// The member's PostScript name.
size_t quartz_renderer_text_content_font_family_member_name(CTFontDescriptorRef member, char *out, size_t cap) {
    return descriptor_string(member, kCTFontNameAttribute, out, cap);
}

// The member's style, such as "Bold Italic".
size_t quartz_renderer_text_content_font_family_member_variant_name(CTFontDescriptorRef member, char *out, size_t cap) {
    return descriptor_string(member, kCTFontStyleNameAttribute, out, cap);
}

static CFNumberRef trait(CTFontDescriptorRef member, CFStringRef key) {
    CFDictionaryRef traits = CTFontDescriptorCopyAttribute(member, kCTFontTraitsAttribute);
    if (!traits) return NULL;
    CFNumberRef value = CFDictionaryGetValue(traits, key);
    if (value) CFRetain(value);
    CFRelease(traits);
    return value;
}

// The member's weight, from -1 (lightest) to 1 (heaviest), 0 being regular.
double quartz_renderer_text_content_font_family_member_weight(CTFontDescriptorRef member) {
    CFNumberRef value = trait(member, kCTFontWeightTrait);
    double weight = 0;
    if (value) {
        CFNumberGetValue(value, kCFNumberDoubleType, &weight);
        CFRelease(value);
    }
    return weight;
}

// The member's Core Text symbolic traits (`CTFontSymbolicTraits`).
uint32_t quartz_renderer_text_content_font_family_member_traits(CTFontDescriptorRef member) {
    CFNumberRef value = trait(member, kCTFontSymbolicTrait);
    uint32_t traits = 0;
    if (value) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &traits);
        CFRelease(value);
    }
    return traits;
}

void quartz_renderer_text_content_release_array(CFTypeRef object) {
    CFRelease(object);
}

// The font named `name` (a PostScript or full name), or NULL.
CTFontRef quartz_renderer_text_content_get_font(const char *name, size_t name_len, double font_size) {
    CFStringRef string = string_from_zig(name, name_len);
    if (!string) return NULL;
    CTFontRef font = CTFontCreateWithName(string, font_size, NULL);
    CFRelease(string);
    return font;
}

static CTFontDescriptorRef with_weight(CTFontDescriptorRef base, double weight) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberDoubleType, &weight);
    const void *trait_keys[] = {kCTFontWeightTrait};
    const void *trait_values[] = {number};
    CFDictionaryRef traits = CFDictionaryCreate(NULL, trait_keys, trait_values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    const void *keys[] = {kCTFontTraitsAttribute};
    const void *values[] = {traits};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(traits);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes);
    CFRelease(attributes);
    return descriptor;
}

// The font of a family closest to `weight`, or NULL.
CTFontRef quartz_renderer_text_content_get_font_by_family(const char *family_name, size_t family_name_len, double font_size, double weight) {
    CFStringRef family = string_from_zig(family_name, family_name_len);
    if (!family) return NULL;
    const void *keys[] = {kCTFontFamilyNameAttribute};
    const void *values[] = {family};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(family);
    CTFontDescriptorRef base = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    CTFontDescriptorRef descriptor = with_weight(base, weight);
    CFRelease(base);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, font_size, NULL);
    CFRelease(descriptor);
    return font;
}

// The system font, the one native controls use, at `weight`, as AppKit's
// `+[NSFont systemFontOfSize:weight:]` gives it.
CTFontRef quartz_renderer_text_content_get_system_font(double font_size, double weight) {
    CTFontRef regular = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, font_size, NULL);
    if (weight == 0) return regular;
    CTFontDescriptorRef base = CTFontCopyFontDescriptor(regular);
    CTFontDescriptorRef descriptor = with_weight(base, weight);
    CFRelease(base);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, font_size, NULL);
    CFRelease(descriptor);
    CFRelease(regular);
    return font;
}

void quartz_renderer_text_content_release_font(CTFontRef font) {
    CFRelease(font);
}

// A one-line typeset string in `font`, with the color the context fills
// with. Release it.
CTLineRef quartz_renderer_text_line(const char *text, size_t text_len, CTFontRef font) {
    CFStringRef string = string_from_zig(text, text_len);
    if (!string) return NULL;
    const void *keys[] = {kCTFontAttributeName, kCTForegroundColorFromContextAttributeName};
    const void *values[] = {font, kCFBooleanTrue};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CFRelease(attributes);
    CFRelease(string);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFRelease(attributed);
    return line;
}

// The height of a line of text in `font`, top to bottom, and how far its
// baseline is from the top, as AppKit's text system lays out a line (its
// `defaultLineHeightForFont:`, which native labels use): the ascent,
// descent and leading, each rounded to whole points. The primary font's
// metrics decide, even where fallback fonts draw some of the text.
void quartz_renderer_line_metrics(CTLineRef line, CTFontRef font, double *height_out, double *baseline_out) {
    (void)line;
    const double ascent = round(CTFontGetAscent(font));
    *height_out = ascent + round(CTFontGetDescent(font)) + round(CTFontGetLeading(font));
    *baseline_out = ascent;
}

// The size of one line of `text` in `font`: its typographic width, and the
// line's height.
void quartz_renderer_text_content_measure(const char *text, size_t text_len, CTFontRef font, double *width_out, double *height_out) {
    *width_out = 0;
    *height_out = 0;
    CTLineRef line = quartz_renderer_text_line(text, text_len, font);
    if (!line) return;
    double baseline;
    *width_out = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    quartz_renderer_line_metrics(line, font, height_out, &baseline);
    CFRelease(line);
}
