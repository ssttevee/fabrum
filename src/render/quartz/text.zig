const std = @import("std");
const fabrum = @import("../../root.zig");

const Vec2 = fabrum.Vec2;

const NSArray = opaque {};

pub const FontFamilyIterator = struct {
    context: ?*const NSArray,
    position: usize = 0,

    pub fn next(self: *FontFamilyIterator) ?[]const u8 {
        const name = self.index(self.position) orelse return null;
        self.position += 1;
        return name;
    }

    pub fn index(self: *FontFamilyIterator, i: usize) ?[]const u8 {
        var len: usize = 0;
        const name = quartz_renderer_text_content_font_family_names_index(
            self.context orelse return null,
            i,
            &len,
        ) orelse return null;
        return name[0..len];
    }

    pub fn deinit(self: *FontFamilyIterator) void {
        if (self.context) |ptr| {
            quartz_renderer_text_content_release_array(ptr);
        }

        self.* = undefined;
    }
};

pub const FontFamilyMemberIterator = struct {
    context: ?*const NSArray,
    position: usize = 0,

    pub fn next(self: *FontFamilyMemberIterator) ?*const FontFamilyMember {
        const member = self.index(self.position) orelse return null;
        self.position += 1;
        return member;
    }

    pub fn index(self: *FontFamilyMemberIterator, i: usize) ?*const FontFamilyMember {
        return quartz_renderer_text_content_font_family_members_index(
            self.context orelse return null,
            i,
        );
    }

    pub fn deinit(self: *FontFamilyMemberIterator) void {
        if (self.context) |ptr| {
            quartz_renderer_text_content_release_array(ptr);
        }

        self.* = undefined;
    }
};

pub const FontFamilyMember = opaque {
    pub fn name(self: *const FontFamilyMember) []const u8 {
        var len: usize = 0;
        const ptr = quartz_renderer_text_content_font_family_member_name(self, &len);
        return ptr[0..len];
    }

    pub fn variantName(self: *const FontFamilyMember) []const u8 {
        var len: usize = 0;
        const ptr = quartz_renderer_text_content_font_family_member_variant_name(self, &len);
        return ptr[0..len];
    }

    pub fn weight(self: *const FontFamilyMember) fabrum.layout.text.Weight {
        return switch (quartz_renderer_text_content_font_family_member_weight(self)) {
            1, 2 => .ultralight,
            3 => .thin,
            4 => .light,
            else => .regular,
            6 => .medium,
            7, 8 => .semibold,
            9 => .bold,
            10, 11 => .heavy,
            12, 13, 14, 15 => .black,
        };
    }

    pub fn traits(self: *const FontFamilyMember) u32 {
        return @intCast(quartz_renderer_text_content_font_family_member_traits(self));
    }

    pub fn deinit(self: *const FontFamilyMember) void {
        quartz_renderer_text_content_release_array(self);
    }
};

pub const Font = opaque {
    pub fn families() FontFamilyIterator {
        return .{ .context = quartz_renderer_text_content_font_family_names_array() };
    }

    pub fn familyMembers(family_name: []const u8) FontFamilyMemberIterator {
        return .{ .context = quartz_renderer_text_content_font_names_for_family_name(family_name.ptr, family_name.len) };
    }

    pub fn fromName(name: []const u8, size: f64) ?*const Font {
        return quartz_renderer_text_content_get_font(name.ptr, name.len, size);
    }

    pub fn fromFamilyName(family_name: []const u8, size: f64, weight: fabrum.layout.text.Weight) ?*const Font {
        return quartz_renderer_text_content_get_font_by_family(family_name.ptr, family_name.len, size, convertWeight(weight));
    }

    pub fn systemFont(size: f64, weight: fabrum.layout.text.Weight) *const Font {
        return quartz_renderer_text_content_get_system_font(size, convertWeight(weight));
    }

    fn convertWeight(weight: fabrum.layout.text.Weight) f64 {
        return switch (weight) {
            .ultralight => NSFontWeightUltraLight,
            .thin => NSFontWeightThin,
            .light => NSFontWeightLight,
            .regular => NSFontWeightRegular,
            .medium => NSFontWeightMedium,
            .semibold => NSFontWeightSemibold,
            .bold => NSFontWeightBold,
            .heavy => NSFontWeightHeavy,
            .black => NSFontWeightBlack,
        };
    }

    pub fn measureText(self: *const Font, text: []const u8) Vec2 {
        var width: f64 = 0.0;
        var height: f64 = 0.0;
        quartz_renderer_text_content_measure(text.ptr, text.len, self, &width, &height);
        return .init(@floatCast(width), @floatCast(height));
    }

    pub fn deinit(self: *const Font) void {
        return quartz_renderer_text_content_release_font(self);
    }
};

extern const NSFontWeightUltraLight: f64;
extern const NSFontWeightThin: f64;
extern const NSFontWeightLight: f64;
extern const NSFontWeightRegular: f64;
extern const NSFontWeightMedium: f64;
extern const NSFontWeightSemibold: f64;
extern const NSFontWeightBold: f64;
extern const NSFontWeightHeavy: f64;
extern const NSFontWeightBlack: f64;

extern fn quartz_renderer_text_content_font_family_names_array() callconv(.c) ?*const NSArray;
extern fn quartz_renderer_text_content_font_names_for_family_name(family_name: [*]const u8, family_name_len: usize) callconv(.c) ?*const NSArray;
extern fn quartz_renderer_text_content_font_family_names_index(font_names: *const NSArray, index: usize, len_out: *usize) callconv(.c) ?[*]const u8;
extern fn quartz_renderer_text_content_font_family_members_index(font_members: *const NSArray, index: usize) callconv(.c) *const FontFamilyMember;
extern fn quartz_renderer_text_content_font_family_member_name(font_member: *const FontFamilyMember, len_out: *usize) callconv(.c) [*]const u8;
extern fn quartz_renderer_text_content_font_family_member_variant_name(font_member: *const FontFamilyMember, len_out: *usize) callconv(.c) [*]const u8;
extern fn quartz_renderer_text_content_font_family_member_weight(font_member: *const FontFamilyMember) callconv(.c) c_long;
extern fn quartz_renderer_text_content_font_family_member_traits(font_member: *const FontFamilyMember) callconv(.c) c_long;
extern fn quartz_renderer_text_content_release_array(names: *const anyopaque) callconv(.c) void;
extern fn quartz_renderer_text_content_get_font(name: [*]const u8, name_len: usize, font_size: f64) callconv(.c) ?*const Font;
extern fn quartz_renderer_text_content_get_font_by_family(family_name: [*]const u8, family_name_len: usize, font_size: f64, weight: f64) callconv(.c) ?*const Font;
extern fn quartz_renderer_text_content_get_system_font(size: f64, weight: f64) callconv(.c) *const Font;
extern fn quartz_renderer_text_content_release_font(font: *const Font) callconv(.c) void;
extern fn quartz_renderer_text_content_measure(text: [*]const u8, text_len: usize, font: *const Font, width_out: *f64, height_out: *f64) callconv(.c) void;

test {
    std.testing.refAllDecls(@This());
}

test FontFamilyIterator {
    var it = Font.families();
    defer it.deinit();

    while (it.next()) |family| {
        // std.debug.print("Family: {s}\n", .{family});
        var member_it = Font.familyMembers(family);
        defer member_it.deinit();

        while (member_it.next()) |member| {
            _ = member;
            // std.debug.print("  Member: {s}\n", .{member.name()});
            // std.debug.print("    Variant: {s}\n", .{member.variantName()});
            // std.debug.print("    Weight: {s}\n", .{@tagName(member.weight())});
            // std.debug.print("    Traits: {b}\n", .{member.traits()});
        }
    }
}

// test FontFamilyMember {

// }
