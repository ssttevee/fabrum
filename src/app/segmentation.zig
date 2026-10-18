//! Grapheme and word boundaries (UAX #29), from zg, for the drawn text
//! editor: every offset it stores lies on a grapheme boundary, and words
//! are what Option-Right and Ctrl-Right move by.
//!
//! A "word" for movement skips runs of spaces and punctuation, as the
//! platforms do: from `foo|, bar`, a word forward lands after `bar`.
//!
//! Words come from zg's `Words` (UAX #29's rules: apostrophes stay in
//! `don't`, CJK ideographs are words of their own) on 64-bit targets. zg
//! 0.18.0's word tables don't build for 32-bit targets (a `u64` used as an
//! index in `micro_runeset.zig`), so there words are runs of letters and
//! digits between spaces and punctuation, which agrees with UAX #29 on
//! Latin text; the same on both for graphemes.
const std = @import("std");
const builtin = @import("builtin");
const Graphemes = @import("Graphemes");

/// Whether zg's word segmentation is used; see the module's doc.
pub const uax29_words = @sizeOf(usize) >= 8;

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

/// `offset` if it is on a grapheme boundary, else the boundary after it.
pub fn nextGraphemeOrSame(text: []const u8, offset: usize) usize {
    if (isGraphemeBoundary(text, offset)) return offset;
    return nextGrapheme(text, offset);
}

/// A run of text the segmenter cuts: a word, or spaces and punctuation
/// between words.
const Segment = struct { start: usize, end: usize, word: bool };

/// Calls `visit(segment)` for each segment of `text` in order, until it
/// returns a result.
fn segments(text: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), Segment) ?usize) ?usize {
    if (uax29_words) {
        const Words = @import("Words");
        var it = Words.iterator(text);
        while (it.next()) |w| {
            if (visit(ctx, .{ .start = w.offset, .end = w.offset + w.len, .word = isWordLike(w.bytes(text)) })) |r| return r;
        }
        return null;
    }
    // runs of word-like code points, and runs of the rest
    var start: usize = 0;
    var word: ?bool = null;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var at: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const is_word = isWordLike(slice);
        if (word) |w| if (w != is_word) {
            if (visit(ctx, .{ .start = start, .end = at, .word = w })) |r| return r;
            start = at;
        };
        word = is_word;
        at += slice.len;
    }
    if (word) |w| if (visit(ctx, .{ .start = start, .end = at, .word = w })) |r| return r;
    return null;
}

/// Whether a run is a word for movement: letters, digits or anything else
/// that isn't only spaces and punctuation.
fn isWordLike(bytes: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            if (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_') return true;
        } else if (!isSpace(cp) and !isPunctuation(cp)) {
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

/// Whether a code point beyond ASCII is common punctuation: Latin-1's,
/// general punctuation, and CJK's.
fn isPunctuation(cp: u21) bool {
    return (cp >= 0xa1 and cp <= 0xbf) or (cp >= 0x2010 and cp <= 0x2027) or (cp >= 0x2030 and cp <= 0x205e) or (cp >= 0x3001 and cp <= 0x3003) or (cp >= 0x3008 and cp <= 0x3011);
}

/// The end of the word after `offset`: past the next run of letters or
/// digits (Option-Right on macOS, Ctrl-Right in GTK).
pub fn nextWordEnd(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return segments(text, offset, struct {
        fn visit(from: usize, s: Segment) ?usize {
            if (s.end <= from) return null;
            return if (s.word) s.end else null;
        }
    }.visit) orelse text.len;
}

/// The start of the next word after `offset` (Ctrl-Right on Windows): the
/// start of the next run of letters or digits, or the end.
pub fn nextWordStart(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    return segments(text, offset, struct {
        fn visit(from: usize, s: Segment) ?usize {
            if (s.word and s.start > from) return s.start;
            return null;
        }
    }.visit) orelse text.len;
}

/// The start of the word before `offset`: the start of the previous run
/// of letters or digits (Option-Left, Ctrl-Left).
pub fn previousWordStart(text: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    const Last = struct { from: usize, start: usize = 0 };
    var last: Last = .{ .from = offset };
    _ = segments(text, &last, struct {
        fn visit(l: *Last, s: Segment) ?usize {
            if (s.start >= l.from) return 0;
            if (s.word) l.start = s.start;
            return null;
        }
    }.visit);
    return last.start;
}

/// The word around `offset`, for a double-click: the segment containing
/// it, or the one before it at its end.
pub fn wordAt(text: []const u8, offset: usize) struct { start: usize, end: usize } {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    const at = @min(offset, text.len);
    const Search = struct { at: usize, last: ?Segment = null, found: ?Segment = null };
    var search: Search = .{ .at = at };
    _ = segments(text, &search, struct {
        fn visit(s: *Search, seg: Segment) ?usize {
            if (seg.start <= s.at and s.at < seg.end) {
                s.found = seg;
                return 0;
            }
            s.last = seg;
            return if (seg.start >= s.at) 0 else null;
        }
    }.visit);
    if (search.found) |f| return .{ .start = f.start, .end = f.end };
    if (search.last) |l| return .{ .start = l.start, .end = l.end };
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
    // accented letters are letters
    const accents = "héllo wörld";
    try std.testing.expectEqual(6, nextWordEnd(accents, 0));
    try std.testing.expectEqual(7, previousWordStart(accents, accents.len));
}
