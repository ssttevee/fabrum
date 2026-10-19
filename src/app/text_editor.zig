//! `TextEditor`: controlled text with a caret, a selection and undo, for
//! drawn text fields. The app's state owns one per field; the field's view
//! shows it, and every key, command or pasted text reaches the app as a
//! `TextInput` message, which `update` applies with `apply` (or
//! `Update.editText`, which also serves the clipboard). The app can set and
//! clear the text itself, as a line editor that sends its text on Enter
//! does.
//!
//! Every offset the editor stores is a byte offset on a grapheme boundary,
//! so a Backspace removes `e` + U+0301 or a seven-code-point family emoji
//! in one. Words are UAX #29's, skipping spaces and punctuation
//! (`segmentation.zig`). Vertical moves and line edges need the field's
//! visual lines as laid out, which the field's view records as a
//! `TextGeometry` the runtime passes along (`Env.geometry`).
//!
//! Undo groups coalesce consecutive typing: a group ends when the caret
//! moves by itself, another kind of edit happens, more than a second
//! passes between keystrokes (`Env.now`), or a word is followed by a space
//! and another word starts, as macOS does. Each group restores the
//! selection it had.
//!
//! Lines are left to right: bidirectional text is a later stage, as is the
//! IME pre-edit (`TextInput.preedit`, accepted but shown as nothing yet).
const std = @import("std");
const Allocator = std.mem.Allocator;

const fabrum = @import("../root.zig");
const Vec2 = fabrum.Vec2;
const Rect = fabrum.Rect;
const seg = @import("segmentation.zig");

/// A range of bytes of the text: `start` to `end`, exclusive.
pub const ByteRange = struct { start: usize, end: usize };

/// One neutral vocabulary of editing, fed by the platform keymaps
/// (`Keymap`) and by hosts that translate their own key bindings.
pub const EditCommand = union(enum) {
    move: Move,
    delete: Delete,
    /// Enter: a newline in multi-line fields; in single-line ones, a
    /// submission (`Outcome.submitted`).
    insert_newline,
    /// Shift-Enter: a newline even where Enter submits, if the field is
    /// multi-line; nothing otherwise.
    insert_line_break,
    insert_tab,
    insert_backtab,
    select_all,
    select_word,
    select_paragraph,
    undo,
    redo,
    copy,
    cut,
    paste,
    /// Swaps the two graphemes around the caret (Control-T).
    transpose,
    /// Deletes to the end of the paragraph and keeps it for `yank`
    /// (Control-K).
    kill_to_line_end,
    yank,
    /// Escape: drops the selection to the caret.
    cancel,

    pub const Move = struct { by: Unit, direction: Direction, extend: bool = false };
    pub const Delete = struct { by: Unit, direction: Direction };

    pub const Unit = enum {
        grapheme,
        /// To the start of the previous word backwards, or of the next
        /// one forwards (Ctrl-Right on Windows).
        word_start,
        /// To the end of the word (Option-Right on macOS, Ctrl-Right in
        /// GTK); backwards, the same as `word_start`.
        word_end,
        /// Up or down a visual (wrapped) line, keeping the preferred
        /// column.
        visual_line,
        /// The start or end of the visual line (Cmd-Left and Cmd-Right,
        /// Home and End).
        visual_line_edge,
        /// The start or end of the paragraph (Ctrl-A and Ctrl-E).
        paragraph_edge,
        /// A page of visual lines.
        page,
        /// The start or end of the text.
        document,
    };
    pub const Direction = enum { backward, forward };
};

/// What reaches a text field: typed or pasted text, a command, or what an
/// input method or a pointer did. Text is borrowed by the message; the
/// editor copies what it keeps.
pub const TextInput = union(enum) {
    /// Insert `text` at the caret, replacing the selection, as typing
    /// does. Typing coalesces into one undo group.
    commit: []const u8,
    /// Insert pasted text: its own undo group. In a single-line field,
    /// each run of line breaks becomes one space, and nothing is
    /// submitted.
    paste: []const u8,
    /// Replace the whole text, as a system keyboard's result does, and put
    /// the caret at its end.
    set: []const u8,
    /// Replace a byte range with `text` (reconversion, autocorrect).
    replace: struct { range: ByteRange, text: []const u8 },
    /// Set the selection, from a pointer: `anchor` stays where the press
    /// was and `head` follows the drag. Offsets are snapped to grapheme
    /// boundaries. `clicks` of 2 and 3 select by word and paragraph.
    select: Select,
    /// An input method's pre-edit, shown at the caret and never part of
    /// the text until committed. Accepted but not shown yet (stage 2).
    preedit: Preedit,
    command: EditCommand,

    pub const Select = struct {
        anchor: usize,
        head: usize,
        clicks: u8 = 1,
    };

    pub const Preedit = struct {
        text: []const u8,
        cursor: ?ByteRange = null,
    };
};

/// The caret and the selection, as byte offsets: the caret is `head`, and
/// the selection runs from `anchor` to it, in either order.
pub const Selection = struct {
    anchor: usize = 0,
    head: usize = 0,

    pub fn collapsed(at: usize) Selection {
        return .{ .anchor = at, .head = at };
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.head);
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.head;
    }

    pub fn eql(a: Selection, b: Selection) bool {
        return a.anchor == b.anchor and a.head == b.head;
    }
};

/// Which side of a soft wrap the caret is drawn on, when its offset ends
/// one visual line and starts the next.
pub const Affinity = enum { upstream, downstream };

/// A field's visual lines as laid out, for moves by line and for drawing
/// the caret and selection; the field's view builds one each frame from
/// the layout's line breaks and the renderer's text measurement.
pub const TextGeometry = struct {
    /// The field's whole text, which `lines` index.
    text: []const u8,
    /// In order from the top.
    lines: []const Line,
    /// Measures a prefix of a line in the field's style, from its start:
    /// the caret's x before `text.len`.
    measure: Measure,
    /// How many points a page spans, for page moves; the field's height.
    page_height: f32 = 0,

    pub const Line = struct {
        /// The bytes of the line, in `text`: `end` excludes the newline or
        /// space it broke at.
        start: usize,
        end: usize,
        /// The line's box, from the field's content origin.
        x: f32,
        y: f32,
        height: f32,
    };

    pub const Measure = struct {
        ctx: *const anyopaque,
        width: *const fn (ctx: *const anyopaque, text: []const u8) f32,

        pub fn of(self: Measure, text: []const u8) f32 {
            return self.width(self.ctx, text);
        }
    };

    /// The index of the visual line holding `offset`: at a soft wrap, the
    /// line before it for `upstream`, the one after for `downstream`.
    pub fn lineOf(self: *const TextGeometry, offset: usize, affinity: Affinity) usize {
        if (self.lines.len == 0) return 0;
        for (self.lines, 0..) |line, i| {
            if (offset < line.end) return i;
            if (offset == line.end) {
                const last = i + 1 == self.lines.len;
                if (last) return i;
                // a hard break ends the paragraph: the caret after the
                // newline belongs to the next line
                const next = self.lines[i + 1];
                const soft = next.start == line.end or (next.start > line.end and self.text[line.end] != '\n');
                if (!soft) {
                    if (next.start > line.end) return i;
                    return i + 1;
                }
                return if (affinity == .upstream) i else i + 1;
            }
        }
        return self.lines.len - 1;
    }

    /// The caret's x before `offset` on line `index`.
    pub fn caretX(self: *const TextGeometry, index: usize, offset: usize) f32 {
        const line = self.lines[index];
        const to = std.math.clamp(offset, line.start, line.end);
        return line.x + self.measure.of(self.text[line.start..to]);
    }

    /// The grapheme boundary of line `index` nearest `x`.
    pub fn offsetAtX(self: *const TextGeometry, index: usize, x: f32) usize {
        const line = self.lines[index];
        const slice = self.text[line.start..line.end];
        var previous: usize = 0;
        var previous_x: f32 = line.x;
        var offset: usize = 0;
        while (offset < slice.len) {
            const next = seg.nextGrapheme(slice, offset);
            const next_x = line.x + self.measure.of(slice[0..next]);
            if (x < (previous_x + next_x) / 2) return line.start + previous;
            previous = next;
            previous_x = next_x;
            offset = next;
        }
        return line.start + previous;
    }

    /// The offset nearest `point`, in the field's content coordinates, and
    /// the affinity that keeps the caret on that line.
    pub fn offsetAt(self: *const TextGeometry, point: Vec2) struct { offset: usize, affinity: Affinity } {
        if (self.lines.len == 0) return .{ .offset = 0, .affinity = .downstream };
        var index: usize = self.lines.len - 1;
        for (self.lines, 0..) |line, i| {
            if (point.y < line.y + line.height) {
                index = i;
                break;
            }
        }
        const offset = self.offsetAtX(index, point.x);
        const line = self.lines[index];
        return .{ .offset = offset, .affinity = if (offset == line.end and offset > line.start) .upstream else .downstream };
    }

    /// Where the caret is drawn for `offset`, one point wide.
    pub fn caretRect(self: *const TextGeometry, offset: usize, affinity: Affinity, line_height: f32) Rect {
        if (self.lines.len == 0) return .init(0, 0, 1, line_height);
        const index = self.lineOf(offset, affinity);
        const line = self.lines[index];
        return .init(self.caretX(index, offset), line.y, 1, line.height);
    }

    /// The rectangles covering the selected bytes `from` to `to`, one per
    /// visual line, written to `out`; returns how many there are.
    pub fn selectionRects(self: *const TextGeometry, from: usize, to: usize, out: []Rect) usize {
        var n: usize = 0;
        for (self.lines) |line| {
            if (n == out.len) break;
            const a = @max(from, line.start);
            const b = @min(to, line.end);
            if (a > b or (a == b and !(from < line.start and to > line.end))) continue;
            const x0 = line.x + self.measure.of(self.text[line.start..a]);
            var x1 = line.x + self.measure.of(self.text[line.start..b]);
            // a line wholly inside the selection shows the break it ends with
            if (to > line.end and b == line.end) x1 += self.measure.of(" ") / 2;
            out[n] = .init(x0, line.y, @max(x1 - x0, 1), line.height);
            n += 1;
        }
        return n;
    }
};

/// Controlled text being edited; see the module's doc.
pub const TextEditor = struct {
    /// UTF-8.
    text: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    affinity: Affinity = .downstream,
    /// The column vertical moves keep, in points.
    preferred_x: ?f32 = null,
    /// An input method's pre-edit, kept out of `text`.
    preedit: ?Preedit = null,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,
    /// The last edit, for coalescing typing into one undo group.
    last_edit: ?LastEdit = null,
    /// What `kill_to_line_end` cut, for `yank`.
    kill_buffer: std.ArrayList(u8) = .empty,
    /// What `copy` and `cut` put on the clipboard, for `Outcome.copy`.
    clipboard_out: std.ArrayList(u8) = .empty,
    /// Bumped whenever the app changes the text or selection itself
    /// (`setText`), so a platform can discard an input method's
    /// composition.
    generation: u64 = 0,

    const Self = @This();

    pub const Preedit = struct {
        text: std.ArrayList(u8) = .empty,
        cursor: ?ByteRange = null,
    };

    const Snapshot = struct {
        text: []u8,
        selection: Selection,

        fn free(self: Snapshot, gpa: Allocator) void {
            gpa.free(self.text);
        }
    };

    const LastEdit = struct {
        kind: enum { insert, delete_backward, delete_forward, other },
        at: std.Io.Timestamp,
        /// Whether the last inserted text ended in a space.
        space: bool,
    };

    /// The most undo groups kept.
    pub const history_limit = 200;
    /// Keystrokes further apart than this start a new undo group.
    pub const coalesce_within: std.Io.Duration = .fromSeconds(1);

    pub const Options = struct {
        /// One line: Enter submits, line breaks pasted become spaces.
        single_line: bool = false,
        /// The most bytes the text may hold; insertions past it are cut
        /// on a grapheme boundary.
        max_len: ?usize = null,
    };

    /// What `apply` needs from outside: the time, for undo coalescing; the
    /// field's options; and its visual lines, for moves by line.
    pub const Env = struct {
        now: std.Io.Timestamp = .zero,
        options: Options = .{},
        geometry: ?*const TextGeometry = null,
    };

    pub const Outcome = struct {
        /// Whether the text changed.
        changed: bool = false,
        /// Whether the caret or selection changed.
        selection_changed: bool = false,
        /// Enter in a single-line field.
        submitted: bool = false,
        /// Text `copy` or `cut` wants on the clipboard, valid until the
        /// next `apply`.
        copy: ?[]const u8 = null,
        /// `paste`: the caller reads the clipboard and applies
        /// `TextInput.paste` with what it holds.
        paste: bool = false,
    };

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.text.deinit(gpa);
        self.clearHistory(gpa);
        self.undo_stack.deinit(gpa);
        self.redo_stack.deinit(gpa);
        self.kill_buffer.deinit(gpa);
        self.clipboard_out.deinit(gpa);
        if (self.preedit) |*p| p.text.deinit(gpa);
        self.* = undefined;
    }

    /// Replaces the text, puts the caret at its end, forgets the history
    /// and any composition, and bumps `generation`.
    pub fn setText(self: *Self, gpa: Allocator, text: []const u8) Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, text);
        self.selection = .collapsed(text.len);
        self.affinity = .downstream;
        self.preferred_x = null;
        self.clearHistory(gpa);
        self.last_edit = null;
        self.dropPreedit(gpa);
        self.generation +%= 1;
    }

    /// The caret's byte offset.
    pub fn caret(self: *const Self) usize {
        return self.selection.head;
    }

    /// The selected bytes.
    pub fn selectedText(self: *const Self) []const u8 {
        return self.text.items[self.selection.start()..self.selection.end()];
    }

    /// Whether an input method is composing.
    pub fn composing(self: *const Self) bool {
        return self.preedit != null;
    }

    /// Applies one input; see `TextInput` and `EditCommand`.
    pub fn apply(self: *Self, gpa: Allocator, input: TextInput, env: Env) Allocator.Error!Outcome {
        const before_text_len = self.text.items.len;
        const before_hash = std.hash.Wyhash.hash(0, self.text.items);
        const before_sel = self.selection;
        var outcome: Outcome = .{};
        switch (input) {
            .commit => |text| {
                self.dropPreedit(gpa);
                try self.insertTyped(gpa, text, env, .commit);
            },
            .paste => |text| {
                self.dropPreedit(gpa);
                try self.insertTyped(gpa, text, env, .paste);
            },
            .set => |text| {
                try self.beginGroup(gpa);
                self.text.clearRetainingCapacity();
                try self.text.appendSlice(gpa, text);
                self.selection = .collapsed(text.len);
                self.last_edit = null;
                self.dropPreedit(gpa);
            },
            .replace => |r| {
                self.dropPreedit(gpa);
                try self.beginGroup(gpa);
                const start = seg.graphemeStart(self.text.items, @min(r.range.start, self.text.items.len));
                const end = seg.nextGraphemeOrSame(self.text.items, @min(r.range.end, self.text.items.len));
                try self.text.replaceRange(gpa, start, end - start, r.text);
                self.selection = .collapsed(start + r.text.len);
                self.last_edit = null;
            },
            .select => |s| {
                self.last_edit = null;
                const text = self.text.items;
                var anchor = seg.graphemeStart(text, @min(s.anchor, text.len));
                var head = seg.graphemeStart(text, @min(s.head, text.len));
                switch (s.clicks) {
                    2 => {
                        const a = seg.wordAt(text, anchor);
                        const h = seg.wordAt(text, head);
                        if (head >= anchor) {
                            anchor = a.start;
                            head = h.end;
                        } else {
                            anchor = a.end;
                            head = h.start;
                        }
                    },
                    3 => {
                        const a = paragraphOf(text, anchor);
                        const h = paragraphOf(text, head);
                        if (head >= anchor) {
                            anchor = a.start;
                            head = h.end;
                        } else {
                            anchor = a.end;
                            head = h.start;
                        }
                    },
                    else => {},
                }
                self.selection = .{ .anchor = anchor, .head = head };
                self.preferred_x = null;
            },
            .preedit => |p| {
                if (p.text.len == 0) {
                    self.dropPreedit(gpa);
                } else {
                    if (self.preedit == null) self.preedit = .{};
                    self.preedit.?.text.clearRetainingCapacity();
                    try self.preedit.?.text.appendSlice(gpa, p.text);
                    self.preedit.?.cursor = p.cursor;
                }
            },
            .command => |c| try self.runCommand(gpa, c, env, &outcome),
        }
        const changed = self.text.items.len != before_text_len or std.hash.Wyhash.hash(0, self.text.items) != before_hash;
        outcome.changed = changed;
        outcome.selection_changed = !self.selection.eql(before_sel);
        return outcome;
    }

    fn runCommand(self: *Self, gpa: Allocator, command: EditCommand, env: Env, outcome: *Outcome) Allocator.Error!void {
        const text = self.text.items;
        switch (command) {
            .move => |m| {
                self.last_edit = null;
                const target = self.moveTarget(m.by, m.direction, env);
                if (!m.extend and !self.selection.isEmpty() and m.by == .grapheme) {
                    // a plain arrow collapses the selection to its edge
                    const edge = if (m.direction == .backward) self.selection.start() else self.selection.end();
                    self.selection = .collapsed(edge);
                } else {
                    self.selection.head = target.offset;
                    if (!m.extend) self.selection.anchor = target.offset;
                }
                self.affinity = target.affinity;
                if (m.by != .visual_line and m.by != .page) self.preferred_x = null;
            },
            .delete => |d| {
                if (self.preedit != null) return;
                if (!self.selection.isEmpty()) {
                    try self.beginGroup(gpa);
                    try self.deleteSelection(gpa);
                    self.last_edit = .{ .kind = .other, .at = env.now, .space = false };
                    return;
                }
                const target = self.moveTarget(d.by, d.direction, env);
                const from = @min(target.offset, self.selection.head);
                const to = @max(target.offset, self.selection.head);
                if (from == to) return;
                const kind: @FieldType(LastEdit, "kind") = if (d.direction == .backward) .delete_backward else .delete_forward;
                const coalesce = d.by == .grapheme and self.last_edit != null and self.last_edit.?.kind == kind and withinCoalesce(self.last_edit.?.at, env.now);
                if (!coalesce) try self.beginGroup(gpa);
                self.text.replaceRangeAssumeCapacity(from, to - from, "");
                self.selection = .collapsed(from);
                self.last_edit = .{ .kind = kind, .at = env.now, .space = false };
                self.preferred_x = null;
            },
            .insert_newline => {
                if (self.preedit != null) return;
                if (env.options.single_line) {
                    outcome.submitted = true;
                    return;
                }
                try self.insertTyped(gpa, "\n", env, .other);
            },
            .insert_line_break => {
                if (self.preedit != null or env.options.single_line) return;
                try self.insertTyped(gpa, "\n", env, .other);
            },
            .insert_tab => try self.insertTyped(gpa, "\t", env, .other),
            .insert_backtab => {},
            .select_all => {
                self.selection = .{ .anchor = 0, .head = text.len };
                self.last_edit = null;
            },
            .select_word => {
                const w = seg.wordAt(text, self.selection.head);
                self.selection = .{ .anchor = w.start, .head = w.end };
                self.last_edit = null;
            },
            .select_paragraph => {
                const p = paragraphOf(text, self.selection.head);
                self.selection = .{ .anchor = p.start, .head = p.end };
                self.last_edit = null;
            },
            .undo => try self.undo(gpa),
            .redo => try self.redo(gpa),
            .copy => {
                if (self.selection.isEmpty()) return;
                self.clipboard_out.clearRetainingCapacity();
                try self.clipboard_out.appendSlice(gpa, self.selectedText());
                outcome.copy = self.clipboard_out.items;
            },
            .cut => {
                if (self.selection.isEmpty()) return;
                self.clipboard_out.clearRetainingCapacity();
                try self.clipboard_out.appendSlice(gpa, self.selectedText());
                try self.beginGroup(gpa);
                try self.deleteSelection(gpa);
                self.last_edit = .{ .kind = .other, .at = env.now, .space = false };
                outcome.copy = self.clipboard_out.items;
            },
            .paste => outcome.paste = true,
            .transpose => {
                if (!self.selection.isEmpty() or text.len < 2) return;
                var at = self.selection.head;
                if (at == text.len) at = seg.previousGrapheme(text, at);
                if (at == 0) return;
                const a = seg.previousGrapheme(text, at);
                const b = seg.nextGrapheme(text, at);
                try self.beginGroup(gpa);
                const first = try gpa.dupe(u8, text[a..at]);
                defer gpa.free(first);
                const second = try gpa.dupe(u8, text[at..b]);
                defer gpa.free(second);
                self.text.replaceRangeAssumeCapacity(a, b - a, "");
                try self.text.insertSlice(gpa, a, first);
                try self.text.insertSlice(gpa, a, second);
                self.selection = .collapsed(b);
                self.last_edit = null;
            },
            .kill_to_line_end => {
                if (self.preedit != null) return;
                const head = self.selection.head;
                var end = std.mem.indexOfScalarPos(u8, text, head, '\n') orelse text.len;
                // at the end of a paragraph, kill the newline
                if (end == head and end < text.len) end += 1;
                if (end == head) return;
                self.kill_buffer.clearRetainingCapacity();
                try self.kill_buffer.appendSlice(gpa, text[head..end]);
                try self.beginGroup(gpa);
                self.text.replaceRangeAssumeCapacity(head, end - head, "");
                self.selection = .collapsed(head);
                self.last_edit = null;
            },
            .yank => {
                if (self.kill_buffer.items.len == 0) return;
                const kill = try gpa.dupe(u8, self.kill_buffer.items);
                defer gpa.free(kill);
                try self.insertTyped(gpa, kill, env, .paste);
            },
            .cancel => {
                self.selection = .collapsed(self.selection.head);
                self.last_edit = null;
            },
        }
    }

    const InsertKind = enum { commit, paste, other };

    /// Inserts `text` at the caret, replacing the selection, under the
    /// field's options, in an undo group that coalesces typing.
    fn insertTyped(self: *Self, gpa: Allocator, text: []const u8, env: Env, kind: InsertKind) Allocator.Error!void {
        var cleaned: std.ArrayList(u8) = .empty;
        defer cleaned.deinit(gpa);
        const insert: []const u8 = if (env.options.single_line and std.mem.indexOfAny(u8, text, "\r\n") != null) blk: {
            // each run of line breaks becomes one space
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\r' or text[i] == '\n') {
                    try cleaned.append(gpa, ' ');
                    while (i + 1 < text.len and (text[i + 1] == '\r' or text[i + 1] == '\n')) i += 1;
                } else try cleaned.append(gpa, text[i]);
            }
            break :blk cleaned.items;
        } else text;
        if (insert.len == 0 and self.selection.isEmpty()) return;

        const starts_word = insert.len > 0 and !isSpaceByte(insert[0]);
        const coalesce = kind == .commit and self.selection.isEmpty() and self.last_edit != null and
            self.last_edit.?.kind == .insert and withinCoalesce(self.last_edit.?.at, env.now) and
            !(self.last_edit.?.space and starts_word);
        if (!coalesce) try self.beginGroup(gpa);
        if (!self.selection.isEmpty()) try self.deleteSelection(gpa);

        var fitting = insert;
        if (env.options.max_len) |max| {
            const room = max -| self.text.items.len;
            if (fitting.len > room) fitting = fitting[0..seg.graphemeStart(fitting, room)];
        }
        const at = self.selection.head;
        try self.text.insertSlice(gpa, at, fitting);
        self.selection = .collapsed(at + fitting.len);
        self.affinity = .downstream;
        self.preferred_x = null;
        self.last_edit = if (kind == .commit) .{ .kind = .insert, .at = env.now, .space = fitting.len > 0 and isSpaceByte(fitting[fitting.len - 1]) } else .{ .kind = .other, .at = env.now, .space = false };
    }

    fn deleteSelection(self: *Self, gpa: Allocator) Allocator.Error!void {
        _ = gpa;
        const start = self.selection.start();
        const len = self.selection.end() - start;
        self.text.replaceRangeAssumeCapacity(start, len, "");
        self.selection = .collapsed(start);
        self.preferred_x = null;
    }

    /// Where a move by `unit` lands from the caret.
    fn moveTarget(self: *const Self, unit: EditCommand.Unit, direction: EditCommand.Direction, env: Env) struct { offset: usize, affinity: Affinity } {
        const text = self.text.items;
        const head = self.selection.head;
        const back = direction == .backward;
        switch (unit) {
            .grapheme => return .{ .offset = if (back) seg.previousGrapheme(text, head) else seg.nextGrapheme(text, head), .affinity = .downstream },
            .word_start => return .{ .offset = if (back) seg.previousWordStart(text, head) else seg.nextWordStart(text, head), .affinity = .downstream },
            .word_end => return .{ .offset = if (back) seg.previousWordStart(text, head) else seg.nextWordEnd(text, head), .affinity = .downstream },
            .paragraph_edge => {
                const p = paragraphOf(text, head);
                return .{ .offset = if (back) p.start else p.end, .affinity = if (back) .downstream else .upstream };
            },
            .document => return .{ .offset = if (back) 0 else text.len, .affinity = .downstream },
            .visual_line_edge => {
                const g = env.geometry orelse {
                    const p = paragraphOf(text, head);
                    return .{ .offset = if (back) p.start else p.end, .affinity = if (back) .downstream else .upstream };
                };
                if (g.lines.len == 0) return .{ .offset = head, .affinity = self.affinity };
                const line = g.lines[g.lineOf(head, self.affinity)];
                return .{ .offset = if (back) line.start else line.end, .affinity = if (back) .downstream else .upstream };
            },
            .visual_line, .page => {
                const g = env.geometry orelse {
                    // no lines known: the start or the end
                    return .{ .offset = if (back) 0 else text.len, .affinity = .downstream };
                };
                if (g.lines.len == 0) return .{ .offset = head, .affinity = self.affinity };
                const index = g.lineOf(head, self.affinity);
                const x = self.preferred_x orelse g.caretX(index, head);
                var steps: usize = 1;
                if (unit == .page) {
                    const height = if (g.lines.len > 0) g.lines[0].height else 0;
                    if (height > 0) steps = @max(1, @as(usize, @intFromFloat(g.page_height / height)));
                }
                if (back and index == 0) return .{ .offset = 0, .affinity = .downstream };
                if (!back and index + 1 == g.lines.len) return .{ .offset = text.len, .affinity = .downstream };
                const target = if (back) index -| steps else @min(index + steps, g.lines.len - 1);
                const offset = g.offsetAtX(target, x);
                const line = g.lines[target];
                // keep the column in a mutable editor: the caller stores it
                @constCast(self).preferred_x = x;
                return .{ .offset = offset, .affinity = if (offset == line.end and offset > line.start) .upstream else .downstream };
            },
        }
    }

    fn withinCoalesce(then: std.Io.Timestamp, now: std.Io.Timestamp) bool {
        const gap = now.nanoseconds - then.nanoseconds;
        return gap >= 0 and gap <= coalesce_within.nanoseconds;
    }

    fn isSpaceByte(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
    }

    // Undo

    /// Opens a new undo group: the state as of now is what undo restores.
    fn beginGroup(self: *Self, gpa: Allocator) Allocator.Error!void {
        for (self.redo_stack.items) |s| s.free(gpa);
        self.redo_stack.clearRetainingCapacity();
        if (self.undo_stack.items.len == history_limit) {
            self.undo_stack.orderedRemove(0).free(gpa);
        }
        try self.undo_stack.ensureUnusedCapacity(gpa, 1);
        self.undo_stack.appendAssumeCapacity(try self.snapshot(gpa));
    }

    fn snapshot(self: *const Self, gpa: Allocator) Allocator.Error!Snapshot {
        return .{ .text = try gpa.dupe(u8, self.text.items), .selection = self.selection };
    }

    fn restore(self: *Self, gpa: Allocator, s: Snapshot) Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, s.text);
        self.selection = s.selection;
        self.affinity = .downstream;
        self.preferred_x = null;
    }

    fn undo(self: *Self, gpa: Allocator) Allocator.Error!void {
        const s = self.undo_stack.pop() orelse return;
        defer s.free(gpa);
        try self.redo_stack.ensureUnusedCapacity(gpa, 1);
        self.redo_stack.appendAssumeCapacity(try self.snapshot(gpa));
        try self.restore(gpa, s);
        self.last_edit = null;
    }

    fn redo(self: *Self, gpa: Allocator) Allocator.Error!void {
        const s = self.redo_stack.pop() orelse return;
        defer s.free(gpa);
        try self.undo_stack.ensureUnusedCapacity(gpa, 1);
        self.undo_stack.appendAssumeCapacity(try self.snapshot(gpa));
        try self.restore(gpa, s);
        self.last_edit = null;
    }

    fn clearHistory(self: *Self, gpa: Allocator) void {
        for (self.undo_stack.items) |s| s.free(gpa);
        for (self.redo_stack.items) |s| s.free(gpa);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    fn dropPreedit(self: *Self, gpa: Allocator) void {
        if (self.preedit) |*p| {
            p.text.deinit(gpa);
            self.preedit = null;
        }
    }
};

/// The paragraph (a line between newlines) around `offset`.
fn paragraphOf(text: []const u8, offset: usize) struct { start: usize, end: usize } {
    const at = @min(offset, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return .{ .start = start, .end = end };
}

const testing = std.testing;

fn commit(editor: *TextEditor, text: []const u8, now: i64) !TextEditor.Outcome {
    return editor.apply(testing.allocator, .{ .commit = text }, .{ .now = .fromNanoseconds(now * std.time.ns_per_ms) });
}

fn cmd(editor: *TextEditor, command: EditCommand) !TextEditor.Outcome {
    return editor.apply(testing.allocator, .{ .command = command }, .{});
}

fn move(by: EditCommand.Unit, direction: EditCommand.Direction, extend: bool) EditCommand {
    return .{ .move = .{ .by = by, .direction = direction, .extend = extend } };
}

test "typing inserts at the caret and replaces the selection" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "hello", 0);
    try testing.expectEqualStrings("hello", e.text.items);
    try testing.expectEqual(5, e.caret());
    _ = try cmd(&e, move(.grapheme, .backward, false));
    _ = try cmd(&e, move(.grapheme, .backward, true));
    try testing.expectEqualStrings("l", e.selectedText());
    _ = try commit(&e, "LL", 10);
    try testing.expectEqualStrings("helLLo", e.text.items);
    try testing.expectEqual(5, e.caret());
}

test "offsets never land inside a grapheme (checklist 3)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "e\u{301}x", 0);
    try testing.expectEqual(4, e.caret());
    _ = try cmd(&e, move(.grapheme, .backward, false));
    try testing.expectEqual(3, e.caret());
    _ = try cmd(&e, move(.grapheme, .backward, false));
    try testing.expectEqual(0, e.caret());
    // a pointer selection inside the mark snaps to its start
    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 2, .head = 2 } }, .{});
    try testing.expectEqual(0, e.caret());
}

test "one Backspace deletes a combining sequence or a ZWJ emoji (checklist 4)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "ae\u{301}" ++ "👨‍👩‍👧", 0);
    const backspace: EditCommand = .{ .delete = .{ .by = .grapheme, .direction = .backward } };
    _ = try cmd(&e, backspace);
    try testing.expectEqualStrings("ae\u{301}", e.text.items);
    _ = try cmd(&e, backspace);
    try testing.expectEqualStrings("a", e.text.items);
    _ = try cmd(&e, move(.document, .backward, false));
    _ = try cmd(&e, .{ .delete = .{ .by = .grapheme, .direction = .forward } });
    try testing.expectEqualStrings("", e.text.items);
}

test "a repeated arrow is a move each time (checklist 6)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "abcde", 0);
    for (0..4) |_| _ = try cmd(&e, move(.grapheme, .backward, false));
    try testing.expectEqual(1, e.caret());
}

test "a multi-line paste into a single-line field becomes spaces and never submits (checklist 8)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    const single: TextEditor.Env = .{ .options = .{ .single_line = true } };
    const outcome = try e.apply(testing.allocator, .{ .paste = "a\nb\r\nc" }, single);
    try testing.expectEqualStrings("a b c", e.text.items);
    try testing.expect(!outcome.submitted);
    // Enter submits, without changing the text
    const enter = try e.apply(testing.allocator, .{ .command = .insert_newline }, single);
    try testing.expect(enter.submitted);
    try testing.expect(!enter.changed);
    try testing.expectEqualStrings("a b c", e.text.items);
    // in a multi-line field it is a newline
    const multi = try e.apply(testing.allocator, .{ .command = .insert_newline }, .{});
    try testing.expect(!multi.submitted);
    try testing.expectEqualStrings("a b c\n", e.text.items);
}

test "typing coalesces into undo groups per word and per second (checklist 9)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    var t: i64 = 0;
    for ("hello world") |c| {
        _ = try commit(&e, &.{c}, t);
        t += 50;
    }
    _ = try cmd(&e, .undo);
    try testing.expectEqualStrings("hello ", e.text.items);
    _ = try cmd(&e, .undo);
    try testing.expectEqualStrings("", e.text.items);
    _ = try cmd(&e, .redo);
    try testing.expectEqualStrings("hello ", e.text.items);
    _ = try cmd(&e, .redo);
    try testing.expectEqualStrings("hello world", e.text.items);

    // a pause of over a second splits a group
    _ = try commit(&e, "a", t);
    _ = try commit(&e, "b", t + 1500);
    _ = try cmd(&e, .undo);
    try testing.expectEqualStrings("hello worlda", e.text.items);
    // a new edit clears the redo stack
    _ = try commit(&e, "c", t + 1600);
    _ = try cmd(&e, .redo);
    try testing.expectEqualStrings("hello worldac", e.text.items);
    // undo restores the selection it had
    _ = try cmd(&e, .select_all);
    _ = try commit(&e, "x", t + 5000);
    try testing.expectEqualStrings("x", e.text.items);
    _ = try cmd(&e, .undo);
    try testing.expectEqualStrings("hello worldac", e.text.items);
    try testing.expectEqualStrings("hello worldac", e.selectedText());
}

test "Enter during a pre-edit submits nothing (checklist 1, the second guard)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    const single: TextEditor.Env = .{ .options = .{ .single_line = true } };
    _ = try e.apply(testing.allocator, .{ .preedit = .{ .text = "にほん" } }, single);
    try testing.expect(e.composing());
    const enter = try e.apply(testing.allocator, .{ .command = .insert_newline }, single);
    try testing.expect(!enter.submitted);
    // the commit replaces the pre-edit
    _ = try e.apply(testing.allocator, .{ .commit = "日本" }, single);
    try testing.expect(!e.composing());
    try testing.expectEqualStrings("日本", e.text.items);
}

test "words, paragraphs, selection commands and the clipboard" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "foo, bar\nbaz qux", 0);
    _ = try cmd(&e, move(.document, .backward, false));
    _ = try cmd(&e, move(.word_end, .forward, false));
    try testing.expectEqual(3, e.caret());
    _ = try cmd(&e, move(.word_end, .forward, false));
    try testing.expectEqual(8, e.caret());
    _ = try cmd(&e, move(.paragraph_edge, .backward, false));
    try testing.expectEqual(0, e.caret());
    _ = try cmd(&e, move(.paragraph_edge, .forward, true));
    try testing.expectEqualStrings("foo, bar", e.selectedText());
    const copied = try cmd(&e, .copy);
    try testing.expectEqualStrings("foo, bar", copied.copy.?);
    const cut = try cmd(&e, .cut);
    try testing.expectEqualStrings("foo, bar", cut.copy.?);
    try testing.expectEqualStrings("\nbaz qux", e.text.items);
    try testing.expect((try cmd(&e, .paste)).paste);
    _ = try e.apply(testing.allocator, .{ .paste = cut.copy.? }, .{});
    try testing.expectEqualStrings("foo, bar\nbaz qux", e.text.items);
    // a double-click selects the word, a triple-click the paragraph
    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 10, .head = 10, .clicks = 2 } }, .{});
    try testing.expectEqualStrings("baz", e.selectedText());
    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 10, .head = 10, .clicks = 3 } }, .{});
    try testing.expectEqualStrings("baz qux", e.selectedText());
    _ = try cmd(&e, .cancel);
    try testing.expect(e.selection.isEmpty());
    // Escape leaves the caret where the head was
    try testing.expectEqual(16, e.caret());
    // a plain arrow collapses a selection to its edge
    _ = try cmd(&e, .select_all);
    _ = try cmd(&e, move(.grapheme, .backward, false));
    try testing.expectEqual(0, e.caret());
    _ = try cmd(&e, .transpose);
    try testing.expectEqualStrings("foo, bar\nbaz qux", e.text.items);
    _ = try cmd(&e, move(.grapheme, .forward, false));
    _ = try cmd(&e, .transpose);
    try testing.expectEqualStrings("ofo, bar\nbaz qux", e.text.items);
    _ = try cmd(&e, .kill_to_line_end);
    try testing.expectEqualStrings("of\nbaz qux", e.text.items);
    _ = try cmd(&e, .yank);
    try testing.expectEqualStrings("ofo, bar\nbaz qux", e.text.items);
}

test "setText resets the editor and bumps the generation" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    _ = try commit(&e, "draft", 0);
    try e.setText(testing.allocator, "");
    try testing.expectEqual(1, e.generation);
    try testing.expectEqual(0, e.caret());
    _ = try cmd(&e, .undo);
    try testing.expectEqualStrings("", e.text.items);
    // max_len cuts on a grapheme boundary
    _ = try e.apply(testing.allocator, .{ .commit = "ab" ++ "e\u{301}" }, .{ .options = .{ .max_len = 4 } });
    try testing.expectEqualStrings("ab", e.text.items);
    _ = try e.apply(testing.allocator, .{ .set = "whole" }, .{});
    try testing.expectEqualStrings("whole", e.text.items);
    try testing.expectEqual(5, e.caret());
}

/// Lines of fixed-width characters, 10 points each, 20 points tall.
const FixedGeometry = struct {
    fn width(_: *const anyopaque, text: []const u8) f32 {
        return @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len)) * 10;
    }

    fn make(text: []const u8, lines: []const TextGeometry.Line) TextGeometry {
        return .{ .text = text, .lines = lines, .measure = .{ .ctx = undefined, .width = width }, .page_height = 40 };
    }
};

test "vertical moves keep their column, and Home and End go to a visual line's edges at a soft wrap (checklist 12)" {
    var e: TextEditor = .{};
    defer e.deinit(testing.allocator);
    // "abcd efgh" wrapped after the space, then a hard break and "xy"
    const text = "abcd efgh\nxy";
    _ = try e.apply(testing.allocator, .{ .set = text }, .{});
    const lines = [_]TextGeometry.Line{
        .{ .start = 0, .end = 4, .x = 0, .y = 0, .height = 20 },
        .{ .start = 5, .end = 9, .x = 0, .y = 20, .height = 20 },
        .{ .start = 10, .end = 12, .x = 0, .y = 40, .height = 20 },
    };
    const g = FixedGeometry.make(text, &lines);
    const env: TextEditor.Env = .{ .geometry = &g };
    // the end of the first line and the start of the second share offset 4
    try testing.expectEqual(0, g.lineOf(4, .upstream));
    try testing.expectEqual(1, g.lineOf(4, .downstream));
    try testing.expectEqual(1, g.lineOf(9, .upstream));
    try testing.expectEqual(2, g.lineOf(10, .downstream));
    // before a hard break, the caret is at the end of the line that ends with it
    try testing.expectEqual(1, g.lineOf(9, .downstream));

    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 2, .head = 2 } }, env);
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line, .forward, false) }, env);
    try testing.expectEqual(7, e.caret());
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line, .forward, false) }, env);
    // the last line is shorter: the column is kept for the way back
    try testing.expectEqual(12, e.caret());
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line, .backward, false) }, env);
    try testing.expectEqual(7, e.caret());
    // End on the first line: the caret shows at the end of that line
    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 2, .head = 2 } }, env);
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line_edge, .forward, false) }, env);
    try testing.expectEqual(4, e.caret());
    try testing.expectEqual(Affinity.upstream, e.affinity);
    try testing.expectEqual(Rect.init(40, 0, 1, 20), g.caretRect(e.caret(), e.affinity, 20));
    // Home on the next line: its start, the same offset, drawn on the next line
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line, .forward, false) }, env);
    _ = try e.apply(testing.allocator, .{ .command = move(.visual_line_edge, .backward, false) }, env);
    try testing.expectEqual(5, e.caret());
    try testing.expectEqual(Rect.init(0, 20, 1, 20), g.caretRect(e.caret(), e.affinity, 20));
    // hit-testing: the nearer half of a character
    try testing.expectEqual(1, g.offsetAt(.init(14, 5)).offset);
    try testing.expectEqual(2, g.offsetAt(.init(16, 5)).offset);
    try testing.expectEqual(4, g.offsetAt(.init(200, 5)).offset);
    try testing.expectEqual(Affinity.upstream, g.offsetAt(.init(200, 5)).affinity);
    try testing.expectEqual(10, g.offsetAt(.init(-5, 45)).offset);
    // a page is two lines here
    _ = try e.apply(testing.allocator, .{ .select = .{ .anchor = 0, .head = 0 } }, env);
    _ = try e.apply(testing.allocator, .{ .command = move(.page, .forward, false) }, env);
    try testing.expectEqual(10, e.caret());
    // selection rectangles, one per line
    var rects: [4]Rect = undefined;
    try testing.expectEqual(3, g.selectionRects(2, 11, &rects));
    try testing.expectEqual(Rect.init(20, 0, 25, 20), rects[0]);
    try testing.expectEqual(Rect.init(0, 20, 45, 20), rects[1]);
    try testing.expectEqual(Rect.init(0, 40, 10, 20), rects[2]);
}
