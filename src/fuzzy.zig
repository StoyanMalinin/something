//! Streaming fuzzy matcher for ranking paths against a query.
//!
//! The query is fixed up front; the candidate is fed in incrementally, one
//! byte or one chunk at a time. That fits a trie walk: feed each edge label
//! on the way down, and since `State` is a plain value, copy it before
//! descending and restore the copy when backtracking. Shared prefixes are then
//! scored once per query instead of once per path.
//!
//! Scoring is a simplified Smith-Waterman (the same family as fzf/frizbee):
//!   - query bytes must appear in order in the candidate
//!   - bonuses for matching at word starts (after `/`, `_`, `-`, `.`, space,
//!     camelCase humps, letter->digit) and for consecutive matches
//!   - affine gap penalties between matched bytes
//!   - a filename bonus when the whole query matches inside the last path
//!     segment (a trailing `/`, as directories have in the index, does not
//!     count as starting a new, empty segment)
//!   - a small, capped penalty per byte after the end of the match, so a
//!     path that ends where the match ends beats the paths below it
//!
//! Typos are part of the model: a query byte may be matched against a
//! different byte, or be dropped altogether, each at a penalty, in the same
//! DP: no extra state, just more transitions.
//! A query gets one typo per `Config.chars_per_typo` bytes, so short queries
//! stay strict. A candidate matches if its best alignment scores above a floor
//! derived from that, so the number of typos is only bounded through the score.
//!
//! Case handling is "smart case": an all-lowercase query matches
//! case-insensitively, a query with any uppercase letter matches exactly.
//! Comparison is bytewise; only ASCII letters are case-folded.

const std = @import("std");

pub const max_query_len = 64;

const Score = i16;
/// "No alignment". Kept well above minInt so subtracting penalties can't overflow.
const NEG: Score = std.math.minInt(Score) / 2;
/// The same, for the i32 accumulator of the trailing-drop maximum.
const no_alignment: i32 = std.math.minInt(i32) / 2;

pub const Config = struct {
    score_match: Score = 16,
    gap_open: Score = 3,
    gap_extend: Score = 1,
    /// Match right after `/` (or at the very start of the candidate).
    bonus_path_boundary: Score = 10,
    /// Match right after `_`, `-`, `.`, space or other ASCII punctuation.
    bonus_boundary: Score = 8,
    /// lower->Upper hump, or non-digit->digit.
    bonus_camel: Score = 7,
    /// Minimum bonus for a match directly following the previous one.
    bonus_consecutive: Score = 4,
    /// The first query byte's bonus is multiplied by this.
    first_char_multiplier: Score = 2,
    /// Added when the whole query matches within the filename (last segment).
    filename_bonus: Score = 32,
    /// Subtract 1 per this many bytes after the end of the match. 0 disables.
    trailing_divisor: u16 = 4,
    /// Upper bound on that penalty, so it only reorders close matches.
    max_trailing_penalty: i32 = 16,

    /// One typo is allowed per this many query bytes, so short queries stay
    /// strict. 0 turns typos off: every query byte must then match, in order.
    chars_per_typo: u8 = 3,
    /// Charged when a query byte is matched against a different candidate byte,
    /// on top of the match reward it gives up.
    typo_penalty: Score = 24,
    /// Charged per query byte that is dropped because no candidate byte matches it.
    skip_penalty: Score = 24,
};

/// Matching progress is two DP rows. `m[j]`: best alignment of query[0..=j]
/// whose last match is the current byte. `g[j]`: best alignment of
/// query[0..=j] whose last match is an earlier byte, already charged the gap
/// penalty up to now. `done`: best complete alignment seen so far;
/// `done_end`: how many candidate bytes had been fed when it ended (the latest
/// such point, on ties).
const Rows = struct {
    m: [max_query_len]Score = @splat(NEG),
    g: [max_query_len]Score = @splat(NEG),
    done: Score = NEG,
    done_end: u32 = 0,
};

/// Matching progress over the candidate bytes fed so far. Plain value:
/// copy it to snapshot, assign the copy back to restore.
pub const State = struct {
    /// Over the whole candidate.
    full: Rows = .{},
    /// Over the current path segment only.
    seg: Rows = .{},
    prev: u8 = '/',
    /// Candidate bytes fed so far.
    len: u32 = 0,
    /// A `/` was seen; the segment rows are reset lazily on the next byte so
    /// that a trailing `/` keeps the previous segment as the filename.
    seg_reset_pending: bool = false,
};

pub const Matcher = struct {
    query: [max_query_len]u8,
    len: usize,
    case_sensitive: bool,
    config: Config,
    /// How many typos this query may have. 0 means strict matching.
    typos: usize,
    /// With typos allowed (`typos > 0`), a candidate matches only if its best alignment
    /// scores at least this much (before the filename bonus and trailing
    /// penalty): the match reward of the query bytes that are not allowed to
    /// be typos. Nothing counts the typos an alignment really used, so this is
    /// an approximation in both directions. One that has more typos than
    /// allowed gets through when its bonuses make up for them (`mxyn` finds
    /// `main`), and a legitimate one with weak bonuses can miss (`mian` against
    /// `xmain`, where the match starts mid-word). Measured on a handful of
    /// queries, it still rejects every query with nothing in common.
    min_done: i32,

    pub fn init(query: []const u8, config: Config) error{QueryTooLong}!Matcher {
        if (query.len > max_query_len) return error.QueryTooLong;

        const typos = if (config.chars_per_typo == 0) 0 else query.len / config.chars_per_typo;

        var self: Matcher = .{
            .query = undefined,
            .len = query.len,
            .case_sensitive = false,
            .config = config,
            .typos = typos,
            .min_done = @as(i32, @intCast(query.len - typos)) * config.score_match,
        };
        for (query) |c| {
            if (std.ascii.isUpper(c)) {
                self.case_sensitive = true;
                break;
            }
        }
        for (query, 0..) |c, i| {
            self.query[i] = self.fold(c);
        }
        return self;
    }

    pub fn start(_: *const Matcher) State {
        return .{};
    }

    pub fn feed(self: *const Matcher, state: *State, chunk: []const u8) void {
        for (chunk) |c| self.feedByte(state, c);
    }

    pub fn feedByte(self: *const Matcher, state: *State, c: u8) void {
        defer state.prev = c;
        state.len +|= 1;

        if (c == '/') {
            if (self.len != 0) self.step(&state.full, c, 0, state.len);
            state.seg_reset_pending = true;
            return;
        }

        if (state.seg_reset_pending) {
            state.seg = .{};
            state.seg_reset_pending = false;
        }

        if (self.len == 0) return;
        const b = self.bonus(state.prev, c);
        self.step(&state.full, c, b, state.len);
        self.step(&state.seg, c, b, state.len);
    }

    /// Score for the candidate fed so far, or null if it doesn't match.
    /// Higher is better. Does not modify the state, so you can keep feeding.
    pub fn finish(self: *const Matcher, state: *const State) ?i32 {
        if (self.len == 0) return 0;
        if (state.full.done <= NEG) return null;
        // The segment rows hold a subset of the alignments the full rows do,
        // so this also rules the filename score out.
        if (self.typos > 0 and state.full.done < self.min_done) return null;

        var s: i32 = state.full.done - self.trailingPenalty(state, &state.full);
        if (state.seg.done > NEG) {
            const in_filename = @as(i32, state.seg.done) + self.config.filename_bonus -
                self.trailingPenalty(state, &state.seg);
            s = @max(s, in_filename);
        }
        return s;
    }

    fn trailingPenalty(self: *const Matcher, state: *const State, rows: *const Rows) i32 {
        const cfg = &self.config;
        if (cfg.trailing_divisor == 0) return 0;
        const trailing = (state.len - rows.done_end) / cfg.trailing_divisor;
        return @intCast(@min(trailing, @as(u32, @intCast(cfg.max_trailing_penalty))));
    }

    /// One-shot convenience: score a whole candidate.
    pub fn score(self: *const Matcher, candidate: []const u8) ?i32 {
        var state = self.start();
        self.feed(&state, candidate);
        return self.finish(&state);
    }

    fn fold(self: *const Matcher, c: u8) u8 {
        return if (self.case_sensitive) c else std.ascii.toLower(c);
    }

    fn step(self: *const Matcher, rows: *Rows, c: u8, b: Score, fed: u32) void {
        const cfg = &self.config;
        const key = self.fold(c);
        const n = self.len;
        const tolerant = self.typos > 0;

        // Walk j upwards, in place. Writing m[j] and g[j] destroys the values
        // from the previous byte that index j+1 needs, so they are carried in
        // `prev_*`, along with the best ways to have arrived at index j-1 by
        // dropping query bytes (`drop_*`). Dropping consumes no candidate byte,
        // so it is a running maximum along j, and a chain of any length costs
        // O(1) per index:
        //   drop[i] = max(m[i-1], drop[i-1]) - skip_penalty
        var prev_m: Score = NEG;
        var prev_g: Score = NEG;
        var drop_m: Score = NEG;
        var drop_g: Score = NEG;
        // For alignments that end by dropping the rest of the query: the best
        // m[i] + i * skip_penalty over the indexes before the last one.
        var trailing: i32 = no_alignment;

        var j: usize = 0;
        while (j < n) : (j += 1) {
            const old_m = rows.m[j];
            const old_g = rows.g[j];

            // A byte that differs from query[j] can still be matched to it as
            // a typo, at a price.
            const exact = self.query[j] == key;
            var new_m: Score = NEG;
            if (exact or tolerant) {
                const match_score = cfg.score_match - if (exact) 0 else cfg.typo_penalty;
                const first = match_score + b * cfg.first_char_multiplier;

                if (j == 0) {
                    new_m = first;
                } else {
                    // Everything before j dropped: j is the first match.
                    if (tolerant) new_m = first - @as(Score, @intCast(j)) * cfg.skip_penalty;

                    const adjacent = @max(prev_m, drop_m);
                    const gapped = @max(prev_g, drop_g);
                    if (adjacent > NEG) {
                        new_m = @max(new_m, adjacent + match_score + @max(b, cfg.bonus_consecutive));
                    }
                    if (gapped > NEG) {
                        new_m = @max(new_m, gapped + match_score + b);
                    }
                }
            }

            if (tolerant) {
                drop_m = dropped(@max(prev_m, drop_m), cfg.skip_penalty);
                drop_g = dropped(@max(prev_g, drop_g), cfg.skip_penalty);
                if (j + 1 < n and new_m > NEG) {
                    trailing = @max(trailing, @as(i32, new_m) + @as(i32, @intCast(j)) * cfg.skip_penalty);
                }
            }

            const extended = @max(old_g - cfg.gap_extend, NEG);
            const opened = @max(old_m - cfg.gap_open, NEG);
            rows.g[j] = @max(extended, opened);
            rows.m[j] = new_m;
            prev_m = old_m;
            prev_g = old_g;
        }

        var complete = rows.m[n - 1];
        if (trailing > no_alignment) {
            const ended = trailing - @as(i32, @intCast(n - 1)) * cfg.skip_penalty;
            if (ended > NEG) complete = @max(complete, @as(Score, @intCast(ended)));
        }
        if (complete > NEG and complete >= rows.done) {
            rows.done = complete;
            rows.done_end = fed;
        }
    }

    /// `value` after dropping one more query byte; still "no alignment" if it was.
    fn dropped(value: Score, skip_penalty: Score) Score {
        if (value <= NEG) return NEG;
        return @max(value - skip_penalty, NEG);
    }

    fn bonus(self: *const Matcher, prev: u8, c: u8) Score {
        const cfg = &self.config;
        if (!std.ascii.isAlphanumeric(c)) return 0;
        return switch (prev) {
            '/' => cfg.bonus_path_boundary,
            ' ', '_', '-', '.' => cfg.bonus_boundary,
            else => blk: {
                if (prev < 0x80 and !std.ascii.isAlphanumeric(prev)) break :blk cfg.bonus_boundary;
                if (std.ascii.isLower(prev) and std.ascii.isUpper(c)) break :blk cfg.bonus_camel;
                if (!std.ascii.isDigit(prev) and std.ascii.isDigit(c)) break :blk cfg.bonus_camel;
                break :blk 0;
            },
        };
    }
};

/// Keeps the `buf.len` best items, best first: higher score wins, then lower
/// `tiebreak` (e.g. path length), then whichever was pushed first. No
/// allocation; the caller owns the buffer.
pub fn TopK(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { score: i32, tiebreak: u32, item: T };

        fn beats(score: i32, tiebreak: u32, other: Entry) bool {
            if (score != other.score) return score > other.score;
            return tiebreak < other.tiebreak;
        }

        buf: []Entry,
        len: usize = 0,

        pub fn init(buf: []Entry) Self {
            return .{ .buf = buf };
        }

        /// Whether an item with this score would be kept by `push`. Lets the
        /// caller skip building (e.g. allocating) items that won't get in.
        pub fn accepts(self: *const Self, score: i32, tiebreak: u32) bool {
            if (self.buf.len == 0) return false;
            if (self.len < self.buf.len) return true;
            return beats(score, tiebreak, self.buf[self.len - 1]);
        }

        /// Inserts the item if it scores high enough. Returns the item that
        /// is no longer held, so the caller can free it: either the one that
        /// fell off the end, or `item` itself if it didn't get in.
        pub fn push(self: *Self, score: i32, tiebreak: u32, item: T) ?T {
            if (!self.accepts(score, tiebreak)) return item;

            var dropped: ?T = null;
            if (self.len == self.buf.len) {
                dropped = self.buf[self.len - 1].item;
                self.len -= 1;
            }

            var i = self.len;
            while (i > 0 and beats(score, tiebreak, self.buf[i - 1])) : (i -= 1) {
                self.buf[i] = self.buf[i - 1];
            }
            self.buf[i] = .{ .score = score, .tiebreak = tiebreak, .item = item };
            self.len += 1;
            return dropped;
        }

        pub fn items(self: *const Self) []const Entry {
            return self.buf[0..self.len];
        }

        /// Once full, a new item must score at least this to get in (above
        /// it, or equal with a lower tiebreak). Useful for pruning subtrees
        /// whose best possible score can't reach it.
        pub fn threshold(self: *const Self) ?i32 {
            if (self.len < self.buf.len) return null;
            return self.buf[self.len - 1].score;
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn scoreOf(query: []const u8, candidate: []const u8) ?i32 {
    const m = Matcher.init(query, .{}) catch unreachable;
    return m.score(candidate);
}

fn expectBetter(query: []const u8, better: []const u8, worse: []const u8) !void {
    const a = scoreOf(query, better) orelse return error.BetterDidNotMatch;
    const b = scoreOf(query, worse) orelse return error.WorseDidNotMatch;
    if (a <= b) {
        std.debug.print("\n'{s}': '{s}'={d} should beat '{s}'={d}\n", .{ query, better, a, worse, b });
        return error.WrongOrder;
    }
}

test "bytes must appear in order, with typos off" {
    try testing.expect(strictScoreOf("abc", "a_b_c") != null);
    try testing.expect(strictScoreOf("abc", "acb") == null);
    try testing.expect(strictScoreOf("abc", "ab") == null);
    try testing.expect(strictScoreOf("abc", "") == null);
}

test "empty query matches everything with score 0" {
    try testing.expectEqual(@as(?i32, 0), scoreOf("", "anything/at/all.zig"));
    try testing.expectEqual(@as(?i32, 0), scoreOf("", ""));
}

test "smart case, with typos off" {
    try testing.expect(strictScoreOf("foo", "src/FOO.zig") != null);
    try testing.expect(strictScoreOf("Foo", "src/Foo.zig") != null);
    try testing.expect(strictScoreOf("Foo", "src/foo.zig") == null);
}

test "query longer than the limit is rejected" {
    const long: [max_query_len + 1]u8 = @splat('a');
    try testing.expectError(error.QueryTooLong, Matcher.init(&long, .{}));
    _ = try Matcher.init(long[0..max_query_len], .{});
}

test "chunked feeding gives the same score as one-shot" {
    const candidates = [_][]const u8{
        "src/main.zig",
        "src/file-index.zig",
        "deeply/nested/dir/with/FileIndexHelpers.zig",
        "docs/",
        "a//b///c",
    };
    const queries = [_][]const u8{ "main", "fidx", "FileIndex", "dc", "abc", "zig" };

    for (queries) |q| {
        const m = try Matcher.init(q, .{});
        for (candidates) |cand| {
            const whole = m.score(cand);

            var by_byte = m.start();
            for (cand) |c| m.feedByte(&by_byte, c);
            try testing.expectEqual(whole, m.finish(&by_byte));

            for (1..cand.len + 1) |split| {
                var s = m.start();
                m.feed(&s, cand[0..split]);
                m.feed(&s, cand[split..]);
                try testing.expectEqual(whole, m.finish(&s));
            }
        }
    }
}

test "snapshot and restore, as in a trie walk" {
    const m = try Matcher.init("fi", .{});

    var state = m.start();
    m.feed(&state, "src/");
    const snapshot = state;

    m.feed(&state, "file-index.zig");
    try testing.expectEqual(m.score("src/file-index.zig"), m.finish(&state));

    state = snapshot;
    m.feed(&state, "main.zig");
    try testing.expectEqual(m.score("src/main.zig"), m.finish(&state));
}

test "filename matches beat matches spread across directories" {
    try expectBetter("main", "src/main.zig", "maintenance/foo/bar.zig");
    try expectBetter("index", "lib/old/index.zig", "in/de/x.zig");
    try expectBetter("trie", "src/trie.zig", "tr/ie/x.zig");
}

test "a trailing slash keeps the directory name as the filename" {
    try expectBetter("docs", "project/docs/", "do/cs/");
}

test "word boundaries beat mid-word matches" {
    try expectBetter("fb", "foo_bar", "fxxbxx");
    try expectBetter("fi", "FileIndex", "afxxix");
    try expectBetter("fi", "file-index", "afxxix");
}

test "consecutive matches beat scattered ones" {
    try expectBetter("abc", "xabcx", "xaxbxcx");
}

test "a path that ends where the match ends beats the paths below it" {
    const root = "/Users/someone/work/proj/something/";
    try expectBetter("something/", root, root ++ "src/");
    try expectBetter("something/", root, root ++ "src/c.h");
    try expectBetter("proj", "/w/proj/", "/w/proj/src/main.zig");
}

test "shorter filenames win ties" {
    try expectBetter("main", "src/main.zig", "src/main_with_a_long_suffix.zig");
}

test "TopK breaks equal scores by the lower tiebreak" {
    var buf: [2]TopK(u32).Entry = undefined;
    var top = TopK(u32).init(&buf);

    _ = top.push(10, 9, 1);
    _ = top.push(10, 3, 2); // same score, lower tiebreak: goes first
    try testing.expectEqual(@as(?u32, 1), top.push(10, 5, 3)); // evicts the tiebreak-9 item
    try testing.expectEqual(@as(?u32, 4), top.push(10, 5, 4)); // equal to the last: pushed later loses

    const got = top.items();
    try testing.expectEqual(@as(u32, 2), got[0].item);
    try testing.expectEqual(@as(u32, 3), got[1].item);
}

test "TopK keeps the best items in order" {
    var buf: [3]TopK(u32).Entry = undefined;
    var top = TopK(u32).init(&buf);

    try testing.expectEqual(@as(?i32, null), top.threshold());
    try testing.expectEqual(@as(?u32, null), top.push(10, 0, 1));
    try testing.expectEqual(@as(?u32, null), top.push(30, 0, 2));
    try testing.expectEqual(@as(?u32, null), top.push(20, 0, 3));
    try testing.expectEqual(@as(?i32, 10), top.threshold());
    try testing.expect(!top.accepts(10, 0));
    try testing.expectEqual(@as(?u32, 4), top.push(5, 0, 4)); // too low, handed back
    try testing.expectEqual(@as(?u32, 1), top.push(25, 0, 5)); // evicts item 1
    try testing.expectEqual(@as(?u32, 3), top.push(30, 0, 6)); // ties with item 2, goes after it

    const got = top.items();
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(u32, 2), got[0].item);
    try testing.expectEqual(@as(u32, 6), got[1].item);
    try testing.expectEqual(@as(u32, 5), got[2].item);
}

test "ranking a small list end to end" {
    const paths = [_][]const u8{
        "src/watcher.zig",
        "src/trie.zig",
        "src/file-index.zig",
        "src/main.zig",
        "build.zig",
        "zig-out/bin/something",
    };
    const m = try Matcher.init("fidx", .{});

    var buf: [3]TopK(usize).Entry = undefined;
    var top = TopK(usize).init(&buf);
    for (paths, 0..) |p, i| {
        if (m.score(p)) |s| _ = top.push(s, @intCast(p.len), i);
    }

    try testing.expectEqual(@as(usize, 1), top.items().len);
    try testing.expectEqualStrings("src/file-index.zig", paths[top.items()[0].item]);
}

// ------------------------------------------------------- typo tolerance

const strict: Config = .{ .chars_per_typo = 0 };

fn strictScoreOf(query: []const u8, candidate: []const u8) ?i32 {
    const m = Matcher.init(query, strict) catch unreachable;
    return m.score(candidate);
}

test "typos can be turned off" {
    const m = try Matcher.init("mxin", strict);
    try testing.expectEqual(@as(usize, 0), m.typos);
    try testing.expect(m.score("src/main.zig") == null);
    try testing.expect(scoreOf("mxin", "src/main.zig") != null);
}

test "typos: a wrong query byte is tolerated" {
    try testing.expect(scoreOf("mxin", "src/main.zig") != null);
}

test "typos: a query byte with no counterpart is dropped" {
    try testing.expect(scoreOf("maxin", "src/main.zig") != null);
    // Leading and trailing extras
    try testing.expect(scoreOf("xmain", "src/main.zig") != null);
    try testing.expect(scoreOf("mainx", "src/main.zig") != null);
}

test "typos: a swapped pair is one dropped byte" {
    try testing.expect(strictScoreOf("mian", "src/main.zig") == null);
    try testing.expect(scoreOf("mian", "src/main.zig") != null);
}

test "typos: short queries stay strict" {
    try testing.expectEqual(@as(usize, 0), (try Matcher.init("mx", .{})).typos);
    try testing.expect(scoreOf("mx", "src/main.zig") == null);
    try testing.expectEqual(@as(usize, 1), (try Matcher.init("mxi", .{})).typos);
    try testing.expectEqual(@as(usize, 2), (try Matcher.init("mxinxx", .{})).typos);
}

test "typos: a query with nothing in common is rejected" {
    try testing.expect(scoreOf("qzx", "src/main.zig") == null);
    try testing.expect(scoreOf("qqqqqq", "src/main.zig") == null);
    try testing.expect(scoreOf("zzzz", "src/main.zig") == null);
    try testing.expect(scoreOf("wxyzab", "src/watcher.zig") == null);
}

test "typos: exact matches outrank typo matches" {
    const exact = scoreOf("main", "src/main.zig").?;
    const typo = scoreOf("mxin", "src/main.zig").?;
    try testing.expect(exact > typo);
}

test "typos: chunked feeding gives the same score as one-shot" {
    const m = try Matcher.init("mxin", .{});
    const cand = "deep/src/main.zig";
    const whole = m.score(cand);
    try testing.expect(whole != null);
    for (1..cand.len + 1) |split| {
        var s = m.start();
        m.feed(&s, cand[0..split]);
        m.feed(&s, cand[split..]);
        try testing.expectEqual(whole, m.finish(&s));
    }
}

test "typos: drops are not capped" {
    // Three query bytes with no counterpart in a row, forgiven by letting every
    // byte be a typo (a floor of 0)
    const lenient: Config = .{ .chars_per_typo = 1 };
    const m = try Matcher.init("mxyzain", lenient);
    try testing.expect(m.score("src/main.zig") != null);
    const none = try Matcher.init("mxyzain", strict);
    try testing.expect(none.score("src/main.zig") == null);
}
