//! Grapheme and word boundaries (UAX #29), from zg, for the drawn text
//! editor: every offset it stores lies on a grapheme boundary, and words
//! are what Option-Right and Ctrl-Right move by.
//!
//! A "word" for movement skips runs of spaces and punctuation, as the
//! platforms do: from `foo|, bar`, a word forward lands after `bar`.
const std = @import("std");
const Graphemes = @import("Graphemes");
const Words = @import("Words");

/// The grapheme boundary at or before `offset` in `text`.
pub fn graphemeStart(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var it = Graphemes.iterator(text);
    var start: usize = 0;
    while (it.next()) |g| {
        if (g.offset + g.len > offset) return g.offset;
        start = g.offset + g.len;
    }
    return start;
}

/// The grapheme boundary after `offset`, or `text.len` at the end.
pub fn nextGrapheme(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var it = Graphemes.iterator(text);
    while (it.next()) |g| {
        if (g.offset + g.len > offset) return g.offset + g.len;
    }
    return text.len;
}

/// The grapheme boundary before `offset`, or 0 at the start.
pub fn previousGrapheme(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var it = Graphemes.iterator(text);
    var start: usize = 0;
    while (it.next()) |g| {
        if (g.offset >= offset) break;
        start = g.offset;
    }
    return start;
}

/// Whether `offset` is on a grapheme boundary of `text`.
pub fn isGraphemeBoundary(text: []const u8, offset: usize) bool {
    return graphemeStart(text, offset) == offset;
}

/// Whether a word, as the segmenter cuts it, is a word for movement:
/// letters, digits or anything else that isn't only spaces and
/// punctuation.
fn isWordLike(bytes: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            if (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_') return true;
        } else if (!isSpace(cp)) {
            // non-ASCII letters, CJK, emoji: a word
            return true;
        }
    }
    return false;
}

/// Whether a code point beyond ASCII is a space: the no-break space, the
/// typographic spaces and the ideographic space.
fn isSpace(cp: u21) bool {
    return cp == 0xa0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x202f or cp == 0x205f or cp == 0x3000;
}

/// The end of the word after `offset`: past the next run of letters or
/// digits (Option-Right on macOS, Ctrl-Right in GTK).
pub fn nextWordEnd(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var it = Words.iterator(text);
    while (it.next()) |w| {
        const end = w.offset + w.len;
        if (end <= offset) continue;
        if (isWordLike(w.bytes(text))) return end;
    }
    return text.len;
}

/// The start of the next word after `offset` (Ctrl-Right on Windows): the
/// start of the next run of letters or digits, or the end.
pub fn nextWordStart(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    var it = Words.iterator(text);
    var passed = false;
    while (it.next()) |w| {
        if (w.offset + w.len <= offset) continue;
        if (isWordLike(w.bytes(text))) {
            if (w.offset > offset) return w.offset;
            passed = true;
        } else if (passed or w.offset >= offset) {
            // spaces: keep going
        }
    }
    return text.len;
}

/// The start of the word before `offset`: the start of the previous run
/// of letters or digits (Option-Left, Ctrl-Left).
pub fn previousWordStart(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var it = Words.iterator(text);
    var start: usize = 0;
    while (it.next()) |w| {
        if (w.offset >= offset) break;
        if (isWordLike(w.bytes(text))) start = w.offset;
    }
    return start;
}

/// The word around `offset`, for a double-click: the segmenter's word
/// containing it, or the one before it at its end.
pub fn wordAt(text: []const u8, offset: usize) struct { start: usize, end: usize } {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    const at = @min(offset, text.len);
    var it = Words.iterator(text);
    var last: ?Words.Word = null;
    while (it.next()) |w| {
        if (w.offset <= at and at < w.offset + w.len) return .{ .start = w.offset, .end = w.offset + w.len };
        last = w;
        if (w.offset >= at) break;
    }
    if (last) |w| return .{ .start = w.offset, .end = w.offset + w.len };
    return .{ .start = at, .end = at };
}

test "grapheme boundaries keep combining marks and ZWJ sequences whole" {
    const text = "e\u{301}x" ++ "👨‍👩‍👧" ++ "z";
    try std.testing.expectEqual(3, nextGrapheme(text, 0));
    try std.testing.expectEqual(4, nextGrapheme(text, 3));
    try std.testing.expectEqual(4 + 18, nextGrapheme(text, 4));
    try std.testing.expectEqual(4, previousGrapheme(text, 4 + 18));
    try std.testing.expectEqual(0, previousGrapheme(text, 3));
    try std.testing.expectEqual(0, previousGrapheme(text, 2));
    try std.testing.expect(!isGraphemeBoundary(text, 1));
    try std.testing.expect(isGraphemeBoundary(text, 3));
    try std.testing.expectEqual(text.len, nextGrapheme(text, text.len));
}

test "words for movement skip spaces and punctuation" {
    const text = "foo, bar  baz";
    try std.testing.expectEqual(3, nextWordEnd(text, 0));
    try std.testing.expectEqual(8, nextWordEnd(text, 3));
    try std.testing.expectEqual(13, nextWordEnd(text, 8));
    try std.testing.expectEqual(5, nextWordStart(text, 0));
    try std.testing.expectEqual(10, nextWordStart(text, 5));
    try std.testing.expectEqual(13, nextWordStart(text, 10));
    try std.testing.expectEqual(10, previousWordStart(text, 13));
    try std.testing.expectEqual(5, previousWordStart(text, 10));
    try std.testing.expectEqual(5, previousWordStart(text, 7));
    try std.testing.expectEqual(0, previousWordStart(text, 5));
    const word = wordAt(text, 6);
    try std.testing.expectEqualStrings("bar", text[word.start..word.end]);
    const end = wordAt(text, 13);
    try std.testing.expectEqualStrings("baz", text[end.start..end.end]);
}
