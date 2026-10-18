const std = @import("std");
const fabrum = @import("../../root.zig");

const Vec2 = fabrum.Vec2;

/// A Core Foundation array (`CFArrayRef`).
const CFArray = opaque {};

/// The font families installed, by name, sorted.
pub const FontFamilyIterator = struct {
    context: ?*const CFArray,
    position: usize = 0,
    /// Holds the name `next` or `index` returned last.
    buffer: [256]u8 = undefined,

    /// The next family's name, valid until the next call.
    pub fn next(self: *FontFamilyIterator) ?[]const u8 {
        const name = self.index(self.position) orelse return null;
        self.position += 1;
        return name;
    }

    /// The name of the family at `i`, valid until the next call.
    pub fn index(self: *FontFamilyIterator, i: usize) ?[]const u8 {
        const len = quartz_renderer_text_content_font_family_names_index(self.context orelse return null, i, &self.buffer, self.buffer.len);
        if (len == std.math.maxInt(usize)) return null;
        return self.buffer[0..@min(len, self.buffer.len)];
    }

    pub fn deinit(self: *FontFamilyIterator) void {
        if (self.context) |ptr| {
            quartz_renderer_text_content_release_array(ptr);
        }

        self.* = undefined;
    }
};

/// The fonts of one family.
pub const FontFamilyMemberIterator = struct {
    context: ?*const CFArray,
    position: usize = 0,

    /// The next member; `deinit` it.
    pub fn next(self: *FontFamilyMemberIterator) ?*const FontFamilyMember {
        const member = self.index(self.position) orelse return null;
        self.position += 1;
        return member;
    }

    /// The member at `i`; `deinit` it.
    pub fn index(self: *FontFamilyMemberIterator, i: usize) ?*const FontFamilyMember {
        return quartz_renderer_text_content_font_family_members_index(self.context orelse return null, i);
    }

    pub fn deinit(self: *FontFamilyMemberIterator) void {
        if (self.context) |ptr| {
            quartz_renderer_text_content_release_array(ptr);
        }

        self.* = undefined;
    }
};

/// One font of a family: a Core Text font descriptor.
pub const FontFamilyMember = opaque {
    /// Its PostScript name, written into `buffer`.
    pub fn name(self: *const FontFamilyMember, buffer: []u8) []const u8 {
        const len = quartz_renderer_text_content_font_family_member_name(self, buffer.ptr, buffer.len);
        return buffer[0..@min(len, buffer.len)];
    }

    /// Its style, such as "Bold Italic", written into `buffer`.
    pub fn variantName(self: *const FontFamilyMember, buffer: []u8) []const u8 {
        const len = quartz_renderer_text_content_font_family_member_variant_name(self, buffer.ptr, buffer.len);
        return buffer[0..@min(len, buffer.len)];
    }

    /// The nearest of fabrum's weights to its Core Text weight.
    pub fn weight(self: *const FontFamilyMember) fabrum.layout.text.Weight {
        const w = quartz_renderer_text_content_font_family_member_weight(self);
        // halfway between AppKit's named weights
        const Weight = fabrum.layout.text.Weight;
        const steps = [_]struct { below: f64, weight: Weight }{
            .{ .below = -0.7, .weight = .ultralight },
            .{ .below = -0.5, .weight = .thin },
            .{ .below = -0.2, .weight = .light },
            .{ .below = 0.115, .weight = .regular },
            .{ .below = 0.265, .weight = .medium },
            .{ .below = 0.35, .weight = .semibold },
            .{ .below = 0.48, .weight = .bold },
            .{ .below = 0.59, .weight = .heavy },
        };
        for (steps) |step| if (w < step.below) return step.weight;
        return .black;
    }

    /// Its Core Text symbolic traits (`CTFontSymbolicTraits`): bit 0 is
    /// italic, bit 1 bold, bit 10 monospace.
    pub fn traits(self: *const FontFamilyMember) u32 {
        return quartz_renderer_text_content_font_family_member_traits(self);
    }

    pub fn deinit(self: *const FontFamilyMember) void {
        quartz_renderer_text_content_release_array(self);
    }
};

/// A Core Text font (`CTFontRef`).
pub const Font = opaque {
    pub fn families() FontFamilyIterator {
        return .{ .context = quartz_renderer_text_content_font_family_names_array() };
    }

    pub fn familyMembers(family_name: []const u8) FontFamilyMemberIterator {
        return .{ .context = quartz_renderer_text_content_font_names_for_family_name(family_name.ptr, family_name.len) };
    }

    /// The font with this PostScript or full name, or null.
    pub fn fromName(name: []const u8, size: f64) ?*const Font {
        return quartz_renderer_text_content_get_font(name.ptr, name.len, size);
    }

    /// The font of a family nearest to `weight`, or null.
    pub fn fromFamilyName(family_name: []const u8, size: f64, weight: fabrum.layout.text.Weight) ?*const Font {
        return quartz_renderer_text_content_get_font_by_family(family_name.ptr, family_name.len, size, convertWeight(weight));
    }

    /// The system font, which native controls use.
    pub fn systemFont(size: f64, weight: fabrum.layout.text.Weight) *const Font {
        return quartz_renderer_text_content_get_system_font(size, convertWeight(weight));
    }

    /// AppKit's `NSFontWeight` for each weight, which Core Text's weight
    /// trait shares.
    fn convertWeight(weight: fabrum.layout.text.Weight) f64 {
        return switch (weight) {
            .ultralight => -0.800000011920929,
            .thin => -0.6000000238418579,
            .light => -0.4000000059604645,
            .regular => 0,
            .medium => 0.23000000417232513,
            .semibold => 0.30000001192092896,
            .bold => 0.4000000059604645,
            .heavy => 0.5600000023841858,
            .black => 0.6200000047683716,
        };
    }

    /// The size of one line of `text`: its typographic width, and the line
    /// height AppKit's text system gives the font.
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

extern fn quartz_renderer_text_content_font_family_names_array() callconv(.c) ?*const CFArray;
extern fn quartz_renderer_text_content_font_names_for_family_name(family_name: [*]const u8, family_name_len: usize) callconv(.c) ?*const CFArray;
extern fn quartz_renderer_text_content_font_family_names_index(font_names: *const CFArray, index: usize, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn quartz_renderer_text_content_font_family_members_index(font_members: *const CFArray, index: usize) callconv(.c) ?*const FontFamilyMember;
extern fn quartz_renderer_text_content_font_family_member_name(font_member: *const FontFamilyMember, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn quartz_renderer_text_content_font_family_member_variant_name(font_member: *const FontFamilyMember, out: [*]u8, cap: usize) callconv(.c) usize;
extern fn quartz_renderer_text_content_font_family_member_weight(font_member: *const FontFamilyMember) callconv(.c) f64;
extern fn quartz_renderer_text_content_font_family_member_traits(font_member: *const FontFamilyMember) callconv(.c) u32;
extern fn quartz_renderer_text_content_release_array(object: *const anyopaque) callconv(.c) void;
extern fn quartz_renderer_text_content_get_font(name: [*]const u8, name_len: usize, font_size: f64) callconv(.c) ?*const Font;
extern fn quartz_renderer_text_content_get_font_by_family(family_name: [*]const u8, family_name_len: usize, font_size: f64, weight: f64) callconv(.c) ?*const Font;
extern fn quartz_renderer_text_content_get_system_font(size: f64, weight: f64) callconv(.c) *const Font;
extern fn quartz_renderer_text_content_release_font(font: *const Font) callconv(.c) void;
extern fn quartz_renderer_text_content_measure(text: [*]const u8, text_len: usize, font: *const Font, width_out: *f64, height_out: *f64) callconv(.c) void;

test {
    std.testing.refAllDecls(@This());
}

test "font families list their members, with names, styles and weights" {
    var families = Font.families();
    defer families.deinit();
    var found = false;
    while (families.next()) |family| {
        if (std.mem.eql(u8, family, "Helvetica")) found = true;
    }
    try std.testing.expect(found);

    var members = Font.familyMembers("Helvetica");
    defer members.deinit();
    var bold = false;
    var name: [128]u8 = undefined;
    var style: [128]u8 = undefined;
    while (members.next()) |member| {
        defer member.deinit();
        if (!std.mem.eql(u8, member.name(&name), "Helvetica-Bold")) continue;
        bold = true;
        try std.testing.expectEqualStrings("Bold", member.variantName(&style));
        try std.testing.expectEqual(fabrum.layout.text.Weight.bold, member.weight());
        try std.testing.expect(member.traits() & 2 != 0);
    }
    try std.testing.expect(bold);
}

test "lines of the system font are as tall as AppKit lays them out" {
    // NSLayoutManager's defaultLineHeightForFont: for the system font
    for ([_]f64{ 9, 13, 16, 20, 40 }, [_]f32{ 11, 16, 18, 23, 47 }) |size, height| {
        const font = Font.systemFont(size, .regular);
        defer font.deinit();
        try std.testing.expectEqual(height, font.measureText("Ag").y);
        // fallback fonts don't make the line taller
        try std.testing.expectEqual(height, font.measureText("日本語").y);
    }
    const bold = Font.systemFont(13, .bold);
    defer bold.deinit();
    const regular = Font.systemFont(13, .regular);
    defer regular.deinit();
    try std.testing.expect(bold.measureText("Hello").x > regular.measureText("Hello").x);
}
