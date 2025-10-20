#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <AppKit/AppKit.h>

static NSString *string_from_zig(const char *bytes, size_t len) {
    NSData *data = [NSData dataWithBytes:bytes length:len];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void string_to_zig(NSString *str, char *buf, size_t *buflen) {
    const char *utf8 = [str UTF8String];

    size_t fulllen = strlen(utf8);
    size_t copylen = *buflen;
    if (copylen > fulllen) {
        copylen = fulllen;
    }

    if (buf) {
        strncpy(buf, utf8, copylen);
    }

    *buflen = fulllen;
}

const void *quartz_renderer_text_content_font_family_names_array() {
    return CFBridgingRetain([[NSFontManager sharedFontManager] availableFontFamilies]);
}

const void *quartz_renderer_text_content_font_names_for_family_name(const char *family_name, size_t family_name_len) {
    return CFBridgingRetain([[NSFontManager sharedFontManager] availableMembersOfFontFamily:string_from_zig(family_name, family_name_len)]);
}

const char *quartz_renderer_text_content_font_family_names_index(const NSArray *font_names, size_t index, size_t *len_out) {
    @try {
        NSString *font_name = [font_names objectAtIndex:index];
        if (!font_name) {
            return NULL;
        }

        const char *utf8 = [font_name UTF8String];

        *len_out = strlen(utf8);
        return utf8;
    } @catch (NSException *exception) {
        return NULL;
    }
}

const void *quartz_renderer_text_content_font_family_members_index(const NSArray *font_members, size_t index) {
    @try {
        return CFBridgingRetain([font_members objectAtIndex:index]);
    } @catch (NSException *exception) {
        return NULL;
    }
}

const char *quartz_renderer_text_content_font_family_member_name(const NSArray *font_member, size_t *len_out) {
    NSString *name = [font_member objectAtIndex:0];
    const char *utf8 = [name UTF8String];
    *len_out = strlen(utf8);
    return utf8;
}

const char *quartz_renderer_text_content_font_family_member_variant_name(const NSArray *font_member, size_t *len_out) {
    NSString *name = [font_member objectAtIndex:1];
    const char *utf8 = [name UTF8String];
    *len_out = strlen(utf8);
    return utf8;
}

long quartz_renderer_text_content_font_family_member_weight(const NSArray *font_member) {
    return [[font_member objectAtIndex:2] longValue];
}

long quartz_renderer_text_content_font_family_member_traits(const NSArray *font_member) {
    return [[font_member objectAtIndex:3] longValue];
}

void quartz_renderer_text_content_release_array(void *names) {
    const NSArray *_ = CFBridgingRelease(names);
}

const void *quartz_renderer_text_content_get_font(const char *name, size_t name_len, double font_size) {
    return CFBridgingRetain([NSFont fontWithName:string_from_zig(name, name_len) size:font_size]);
}

const void *quartz_renderer_text_content_get_font_by_family(const char *family_name, size_t family_name_len, double font_size, NSFontWeight weight) {
    NSDictionary *attributes = @{
        (NSString *)kCTFontFamilyNameAttribute: string_from_zig(family_name, family_name_len),
        (NSString *)kCTFontTraitsAttribute: @{
            (NSString *)kCTFontWeightTrait: @(weight)
        }
    };

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(
        (__bridge CFDictionaryRef)attributes
    );

    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, font_size, NULL);
    CFRelease(descriptor);

    return font;
}

const void *quartz_renderer_text_content_get_system_font(double font_size, NSFontWeight weight) {
    return CFBridgingRetain([NSFont systemFontOfSize:font_size weight:weight]);
}

void quartz_renderer_text_content_release_font(void *font) {
    NSFont *_ = CFBridgingRelease(font);
}

void quartz_renderer_text_content_measure(const char *text, size_t text_len, NSFont *font, double *width_out, double *height_out) {
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
    };

    CGSize constrainedSize = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);

    CGRect boundingBox = [string_from_zig(text, text_len) boundingRectWithSize:constrainedSize
                                                                       options:0 // No options needed for single-line measurement
                                                                    attributes:attributes
                                                                       context:nil];

    *width_out = boundingBox.size.width;
    *height_out = boundingBox.size.height;
}
