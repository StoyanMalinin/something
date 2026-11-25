//! Streaming fuzzy matcher for ranking paths against a query.
//!
//! The query is fixed up front; the candidate is fed in incrementally, one
//! byte or one chunk at a time. That fits a trie walk: feed each edge label
//! on the way down, and since `State` is a plain value, copy it before
//! descending and restore the copy when backtracking. Shared prefixes are then
//! scored once per query instead of once per path.
//!
//! Scoring is a simplified Smith-Waterman (the same family as fzf/frizbee):
//!   - query bytes are matched in order in the candidate
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
//! DP: no extra state, just more transitions. There is no limit on them and
//! no cutoff: every non-empty candidate gets a score, and typos only push it
//! down the ranking. One exception: between two matched query bytes, at most
//! one query byte can be dropped (any number can be at the start or the end).
//! Allowing more costs a full prefix max per candidate byte, which is the
//! critical path of the DP, and rarely changes the ranking: two drops in a
//! row already cost more than most matches earn.
//!
//! Case handling is "smart case": an all-lowercase query matches
//! case-insensitively, a query with any uppercase letter matches exactly.
//! Comparison is bytewise; only ASCII letters are case-folded.

const std = @import("std");

pub const max_query_len = 64;

const Score = i16;
/// "No alignment". Kept well above minInt so subtracting penalties can't overflow.
const NEG: Score = std.math.minInt(Score) / 2;

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
///
/// `L` is the number of query positions it has room for (a multiple of the
/// vector width, at least the query's length), so short queries carry small
/// states.
fn RowsOf(comptime L: usize) type {
    return struct {
        pub const lanes = L;

        m: [L]Score = @splat(NEG),
        g: [L]Score = @splat(NEG),
        done: Score = NEG,
        done_end: u32 = 0,
    };
}

/// The lane count to use for a query of this length: the smallest of 8, 16,
/// 32 and `max_query_len` that fits it. Callers switch on this to turn the
/// runtime length into the comptime `L` of `StateOf`.
pub fn lanesFor(query_len: usize) usize {
    return switch (query_len) {
        0...8 => 8,
        9...16 => 16,
        17...32 => 32,
        else => max_query_len,
    };
}

/// Matching progress over the candidate bytes fed so far. Plain value:
/// copy it to snapshot, assign the copy back to restore.
pub fn StateOf(comptime L: usize) type {
    return struct {
        pub const lanes = L;

        /// Over the whole candidate. The filename match (the query matched
        /// inside the last segment alone) isn't tracked while feeding: `finish`
        /// rebuilds it from the candidate, which costs a segment's worth of
        /// steps but only for candidates that get that far.
        full: RowsOf(L) = .{},
        prev: u8 = '/',
        /// Candidate bytes fed so far.
        len: u32 = 0,
    };
}

/// A state with room for any query.
pub const State = StateOf(max_query_len);

pub const Matcher = struct {
    query: [max_query_len]u8,
    /// `byteBit` of each query byte, for `subtreeBound`, which runs once per
    /// child visited.
    query_bits: [max_query_len]u64,
    len: usize,
    case_sensitive: bool,
    /// `lowercase_table` or `identity_table`, per `case_sensitive`.
    fold_table: *const [256]u8,
    /// `bonus_kinds` with this config's values filled in.
    bonus_table: [byte_classes][byte_classes]Score,
    config: Config,

    pub fn init(query: []const u8, config: Config) error{QueryTooLong}!Matcher {
        if (query.len > max_query_len) return error.QueryTooLong;

        var self: Matcher = .{
            // Zeros past the end: the vector step compares whole registers
            .query = @splat(0),
            .query_bits = @splat(0),
            .len = query.len,
            .case_sensitive = false,
            .fold_table = &lowercase_table,
            .bonus_table = undefined,
            .config = config,
        };
        for (query) |c| {
            if (std.ascii.isUpper(c)) {
                self.case_sensitive = true;
                self.fold_table = &identity_table;
                break;
            }
        }
        for (&self.bonus_table, bonus_kinds) |*row, kinds| {
            for (row, kinds) |*b, kind| b.* = switch (kind) {
                .none => 0,
                .path_boundary => config.bonus_path_boundary,
                .boundary => config.bonus_boundary,
                .camel => config.bonus_camel,
            };
        }
        for (query, 0..) |c, i| {
            self.query[i] = self.fold(c);
            self.query_bits[i] = byteBit(self.query[i]);
        }
        return self;
    }

    /// A fresh state with room for any query. Use `StateOf(lanesFor(len))` for
    /// a smaller one.
    pub fn start(_: *const Matcher) State {
        return .{};
    }

    /// `state` is a pointer to a `StateOf(L)` with `L >= self.len`.
    pub fn feed(self: *const Matcher, state: anytype, chunk: []const u8) void {
        for (chunk) |c| self.feedByte(state, c);
    }

    pub fn feedByte(self: *const Matcher, state: anytype, c: u8) void {
        defer state.prev = c;
        state.len +|= 1;

        if (self.len == 0) return;
        self.step(&state.full, c, self.bonus(state.prev, c), state.len);
    }

    /// Upper bound on what `finish` returns for the candidate fed so far, or
    /// null if `finish` would. Needs no candidate bytes, so a caller can drop
    /// candidates that can't make it before building them: the filename match
    /// is a subset of the alignments of the whole candidate, so the most it
    /// adds is the filename bonus.
    pub fn finishBound(self: *const Matcher, state: anytype) ?i32 {
        if (self.len == 0) return 0;
        if (state.full.done <= NEG) return null;
        return @as(i32, state.full.done) + self.config.filename_bonus;
    }

    /// Score for the candidate fed so far, or null if nothing has been fed
    /// yet. Higher is better. Does not modify the state, so you can keep
    /// feeding. `candidate` is everything that was fed.
    pub fn finish(self: *const Matcher, state: anytype, candidate: []const u8) ?i32 {
        if (self.len == 0) return 0;
        if (state.full.done <= NEG) return null;

        var s: i32 = state.full.done - self.trailingPenalty(state, &state.full);

        // The filename: the last run of bytes between slashes (so a trailing
        // `/`, as directories have in the index, doesn't start an empty one)
        var end = candidate.len;
        while (end > 0 and candidate[end - 1] == '/') end -= 1;
        var name_start = end;
        while (name_start > 0 and candidate[name_start - 1] != '/') name_start -= 1;
        if (name_start == end) return s;

        var seg: @TypeOf(state.full) = .{};
        var prev: u8 = '/';
        for (candidate[name_start..end], name_start..) |c, i| {
            self.step(&seg, c, self.bonus(prev, c), @intCast(i + 1));
            prev = c;
        }
        if (seg.done > NEG) {
            const in_filename = @as(i32, seg.done) + self.config.filename_bonus -
                self.trailingPenalty(state, &seg);
            s = @max(s, in_filename);
        }
        return s;
    }

    fn trailingPenalty(self: *const Matcher, state: anytype, rows: anytype) i32 {
        const cfg = &self.config;
        if (cfg.trailing_divisor == 0) return 0;
        const trailing = (state.len - rows.done_end) / cfg.trailing_divisor;
        return @intCast(@min(trailing, @as(u32, @intCast(cfg.max_trailing_penalty))));
    }

    /// One-shot convenience: score a whole candidate.
    pub fn score(self: *const Matcher, candidate: []const u8) ?i32 {
        return switch (lanesFor(self.len)) {
            8 => self.scoreL(8, candidate),
            16 => self.scoreL(16, candidate),
            32 => self.scoreL(32, candidate),
            else => self.scoreL(max_query_len, candidate),
        };
    }

    fn scoreL(self: *const Matcher, comptime L: usize, candidate: []const u8) ?i32 {
        var state: StateOf(L) = .{};
        self.feed(&state, candidate);
        return self.finish(&state, candidate);
    }

    /// Upper bound on the `full.done` reachable by feeding more bytes, all
    /// with byte classes in `mask` (see `byteBit`). It also bounds the segment
    /// rows, whose alignments are a subset. Assumes every remaining query byte
    /// gets the best case: an exact match with the largest bonus if its class
    /// is in the mask, otherwise a typo with the largest bonus. Starting over
    /// at any query byte, dropping the ones before it, is covered too.
    pub fn subtreeBound(self: *const Matcher, state: anytype, mask: u64) i32 {
        const n = self.len;
        if (n == 0) return 0;
        const L = @TypeOf(state.full).lanes;
        std.debug.assert(n <= L);
        const V = @Vector(L, Score);
        const cfg = &self.config;
        const max_b = self.maxBonusBelow(state.prev, mask);
        const exact: Score = cfg.score_match;
        // Dropping a query byte instead is never better with sane penalties,
        // but costs nothing to account for.
        const typo: Score = @intCast(@max(@as(i32, exact) - cfg.typo_penalty, -@as(i32, cfg.skip_penalty) - max_b));

        // Lane j is query[j]; lanes from `n` up are padding and count for nothing.
        const in_query = std.simd.iota(u8, L) < @as(@Vector(L, u8), @splat(@intCast(n)));
        const bits: @Vector(L, u64) = self.query_bits[0..L].*;
        const present = (bits & @as(@Vector(L, u64), @splat(mask))) != @as(@Vector(L, u64), @splat(0));
        const match = @select(Score, present, @as(V, @splat(exact)), @as(V, @splat(typo)));

        // The best case of each query byte, and the exclusive suffix sum of it:
        // `after[j]` is the best case for the query bytes after j. The sum is a
        // log2(L)-round scan, shifting lanes down and adding.
        const zero: V = @splat(0);
        const per_byte = @select(Score, in_query, match + @as(V, @splat(max_b)), zero);
        var inclusive = per_byte;
        comptime var k: usize = 1;
        inline while (k < L) : (k *= 2) inclusive += shiftDown(L, inclusive, k);
        const after = inclusive - per_byte;

        // j is the first match, everything before it dropped
        const j_skip = std.simd.iota(Score, L) * @as(V, @splat(cfg.skip_penalty));
        const first = match + @as(V, @splat(max_b * cfg.first_char_multiplier)) - j_skip + after;
        // Or an alignment that is already live at j
        const live = @max(@as(V, state.full.m[0..L].*), @as(V, state.full.g[0..L].*));
        const neg: V = @splat(NEG);
        const from_live = @select(Score, live > neg, live + after, neg);

        const best = @select(Score, in_query, @max(first, from_live), @as(V, @splat(std.math.minInt(Score))));
        return @max(@as(i32, state.full.done), @as(i32, @reduce(.Max, best)));
    }

    /// The largest bonus a byte can earn when the bytes fed next have classes
    /// in `mask` and the one before them is `prev`. A bonus kind needs its
    /// trigger: `/` (in the mask, or `prev`) for path_boundary, punctuation
    /// for boundary, a letter or digit for camel (the mask folds case, so an
    /// uppercase letter can't be ruled out). The shared bucket of `byteBit`
    /// may hold punctuation, so it counts as one. The consecutive bonus needs
    /// nothing.
    fn maxBonusBelow(self: *const Matcher, prev: u8, mask: u64) Score {
        const cfg = &self.config;
        const prev_class = byte_class[prev];
        const alnum_bits: u64 = (@as(u64, 1) << 36) - 1;
        const punct_bits: u64 = byteBit('.') | byteBit('_') | byteBit('-') | byteBit(' ') | (~@as(u64, 0) << 41);

        var max_b = cfg.bonus_consecutive;
        if (prev_class == .slash or mask & byteBit('/') != 0) max_b = @max(max_b, cfg.bonus_path_boundary);
        if (prev_class == .punct or mask & punct_bits != 0) max_b = @max(max_b, cfg.bonus_boundary);
        if (mask & alnum_bits != 0) max_b = @max(max_b, cfg.bonus_camel);
        return max_b;
    }

    /// Whether a subtree with this bound can still produce a result that gets
    /// into a TopK whose `threshold()` is `threshold`. The trailing penalty is
    /// left out, so this errs on the side of keeping.
    pub fn canReach(self: *const Matcher, bound: i32, threshold: ?i32) bool {
        const t = threshold orelse return true;
        return bound + self.config.filename_bonus >= t;
    }

    fn fold(self: *const Matcher, c: u8) u8 {
        return self.fold_table[c];
    }

    fn step(self: *const Matcher, rows: anytype, c: u8, b: Score, fed: u32) void {
        std.debug.assert(self.len != 0 and self.len <= @TypeOf(rows.*).lanes);
        self.stepLanes(@TypeOf(rows.*).lanes, rows, c, b, fed);
    }

    /// Feeds one candidate byte to all query positions at once: lane j holds
    /// query[j]. Lanes from `len` up hold values that are never read, and
    /// nothing flows from a higher lane to a lower one.
    fn stepLanes(self: *const Matcher, comptime L: usize, rows: anytype, c: u8, b: Score, fed: u32) void {
        const V = @Vector(L, Score);
        const cfg = &self.config;
        const n = self.len;
        const skip: V = @splat(cfg.skip_penalty);
        const j_skip = std.simd.iota(Score, L) * skip;

        const old_m: V = rows.m[0..L].*;
        const old_g: V = rows.g[0..L].*;

        // A byte that differs from query[j] can still be matched to it as a
        // typo, at a price.
        const query: @Vector(L, u8) = self.query[0..L].*;
        const exact = query == @as(@Vector(L, u8), @splat(self.fold(c)));
        const match_score = @select(Score, exact, @as(V, @splat(cfg.score_match)), @as(V, @splat(cfg.score_match - cfg.typo_penalty)));

        // The best alignment of query[0..j-1] to come from: one that ended at
        // query[i], followed by dropping query[i+1..j-1]. Only i = j-1 and
        // i = j-2 (one byte dropped) are allowed, see the top of the file:
        //   max over i in {j-2, j-1} of old[i] - (j-1-i) * skip_penalty
        //   = (max over i in {j-2, j-1} of old[i] + i * skip_penalty) - (j-1) * skip_penalty
        // Lane 0 has nothing before it (NEG), lane 1 only lane 0.
        const adjacent = maxOfPrevTwo(L, old_m + j_skip) - j_skip + skip;
        const gapped = maxOfPrevTwo(L, old_g + j_skip) - j_skip + skip;

        // The best alignment of query[0..=j] ending here is the best of three.
        // One built on "no alignment" (NEG) can never win: `first` is at least
        // score_match - typo_penalty - (max_query_len - 1) * skip_penalty,
        // far above NEG plus any reward.
        // Everything before j dropped: j is the first match.
        const first = match_score + @as(V, @splat(b * cfg.first_char_multiplier)) - j_skip;
        // Right after the previous match.
        const consecutive = adjacent + match_score + @as(V, @splat(@max(b, cfg.bonus_consecutive)));
        // After a gap since the previous match.
        const after_gap = gapped + match_score + @as(V, @splat(b));
        const new_m = @max(first, @max(consecutive, after_gap));

        const extended = old_g - @as(V, @splat(cfg.gap_extend));
        const opened = old_m - @as(V, @splat(cfg.gap_open));
        rows.m[0..L].* = new_m;
        rows.g[0..L].* = @max(@max(extended, opened), @as(V, @splat(NEG)));

        // A complete alignment ends here by matching the last query byte, or
        // by matching an earlier one and dropping the rest
        const before_last = std.simd.iota(u8, L) < @as(@Vector(L, u8), @splat(@intCast(n - 1)));
        const dropping = @select(Score, before_last, new_m + j_skip, @as(V, @splat(NEG)));
        const ended = @reduce(.Max, dropping) - @as(Score, @intCast(n - 1)) * cfg.skip_penalty;
        const complete = @max(rows.m[n - 1], ended);
        if (complete >= rows.done) {
            rows.done = complete;
            rows.done_end = fed;
        }
    }

    /// Bonus for matching `c` right after `prev`. Two table lookups: the rules
    /// are in `bonusKind`, below.
    fn bonus(self: *const Matcher, prev: u8, c: u8) Score {
        return self.bonus_table[@backingInt(byte_class[prev])][@backingInt(byte_class[c])];
    }
};

/// What a byte counts as, for the bonus rules.
const ByteClass = enum(u3) {
    slash,
    /// Space, `_`, `-`, `.` and any other ASCII byte that isn't a letter or digit.
    punct,
    lower,
    upper,
    digit,
    /// Non-ASCII.
    other,
};
const byte_classes = @typeInfo(ByteClass).@"enum".field_names.len;

fn classify(c: u8) ByteClass {
    if (c == '/') return .slash;
    if (std.ascii.isLower(c)) return .lower;
    if (std.ascii.isUpper(c)) return .upper;
    if (std.ascii.isDigit(c)) return .digit;
    if (c < 0x80) return .punct;
    return .other;
}

const BonusKind = enum { none, path_boundary, boundary, camel };

/// The bonus rules: what matching a byte of class `c` right after one of
/// class `prev` earns.
fn bonusKind(prev: ByteClass, c: ByteClass) BonusKind {
    // Only letters and digits earn a bonus
    switch (c) {
        .lower, .upper, .digit => {},
        .slash, .punct, .other => return .none,
    }
    return switch (prev) {
        // Also the start of the candidate, as `prev` starts out as `/`
        .slash => .path_boundary,
        .punct => .boundary,
        // camelCase hump, or letter -> digit
        .lower => if (c == .upper or c == .digit) .camel else .none,
        // non-digit -> digit
        .upper, .other => if (c == .digit) .camel else .none,
        .digit => .none,
    };
}

const byte_class: [256]ByteClass = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]ByteClass = undefined;
    for (&t, 0..) |*e, c| e.* = classify(@intCast(c));
    break :blk t;
};

const bonus_kinds: [byte_classes][byte_classes]BonusKind = blk: {
    var t: [byte_classes][byte_classes]BonusKind = undefined;
    for (&t, 0..) |*row, prev| {
        for (row, 0..) |*e, c| e.* = bonusKind(@fromBackingInt(@intCast(prev)), @fromBackingInt(@intCast(c)));
    }
    break :blk t;
};

const identity_table: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, c| e.* = @intCast(c);
    break :blk t;
};

/// Smart case's fold for an all-lowercase query: ASCII letters only.
const lowercase_table: [256]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, c| e.* = std.ascii.toLower(@intCast(c));
    break :blk t;
};

/// Lane j: the maximum of lanes j-2 and j-1 of `v` (NEG where they don't
/// exist). The first round of a prefix maximum: the full one would take
/// log2(L) dependent shift-and-max rounds.
fn maxOfPrevTwo(comptime L: usize, v: @Vector(L, Score)) @Vector(L, Score) {
    const prev = shiftUp(L, v, 1);
    return @max(prev, shiftUp(L, prev, 1));
}

/// `v` moved `k` lanes down (lane j takes lane j+k), with 0 shifted into the
/// top lanes.
fn shiftDown(comptime L: usize, v: @Vector(L, Score), comptime k: usize) @Vector(L, Score) {
    const mask = comptime blk: {
        var m: @Vector(L, i32) = undefined;
        for (0..L) |i| m[i] = if (i + k < L) @intCast(i + k) else -1;
        break :blk m;
    };
    return @shuffle(Score, v, @as(@Vector(L, Score), @splat(0)), mask);
}

/// `v` moved `k` lanes up, with NEG shifted into the bottom lanes.
fn shiftUp(comptime L: usize, v: @Vector(L, Score), comptime k: usize) @Vector(L, Score) {
    const mask = comptime blk: {
        var m: @Vector(L, i32) = undefined;
        for (0..L) |i| m[i] = if (i < k) -1 else @intCast(i - k);
        break :blk m;
    };
    return @shuffle(Score, v, @as(@Vector(L, Score), @splat(NEG)), mask);
}

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

test "bytes in order beat bytes out of order or missing" {
    try expectBetter("abc", "a_b_c", "acb");
    try expectBetter("abc", "a_b_c", "ab");
    try testing.expect(scoreOf("abc", "") == null);
}

test "empty query matches everything with score 0" {
    try testing.expectEqual(@as(?i32, 0), scoreOf("", "anything/at/all.zig"));
    try testing.expectEqual(@as(?i32, 0), scoreOf("", ""));
}

test "smart case" {
    // All lowercase: case-insensitive
    try testing.expectEqual(scoreOf("foo", "src/foo.zig"), scoreOf("foo", "src/FOO.zig"));
    // Any uppercase: other cases only match as typos
    try expectBetter("Foo", "src/Foo.zig", "src/foo.zig");
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
            try testing.expectEqual(whole, m.finish(&by_byte, cand));

            for (1..cand.len + 1) |split| {
                var s = m.start();
                m.feed(&s, cand[0..split]);
                m.feed(&s, cand[split..]);
                try testing.expectEqual(whole, m.finish(&s, cand));
            }
        }
    }
}

test "finishBound never undercuts finish" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const alphabet = "abcmainzigMAx/._-1";
    const queries = [_][]const u8{ "", "a", "ma", "main", "mxin", "zig", "abc/x", "Main", "ii", "xyzzyq", "m.z" };

    for (queries) |q| {
        const m = try Matcher.init(q, .{});
        for (0..300) |_| {
            var buf: [24]u8 = undefined;
            const len = rnd.intRangeAtMost(usize, 0, buf.len);
            for (buf[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const cand = buf[0..len];

            var state = m.start();
            m.feed(&state, cand);
            const got = m.finish(&state, cand);
            const bound = m.finishBound(&state);
            try testing.expectEqual(got == null, bound == null);
            if (got) |g| try testing.expect(bound.? >= g);
        }
    }
}

test "the filename is the last run between slashes" {
    // Doubled and trailing slashes don't start an empty filename
    try testing.expectEqual(scoreOf("docs", "a/docs/"), scoreOf("docs", "a/docs//"));
    try expectBetter("docs", "project/docs//", "do/cs/");
    // The filename bonus needs the whole query inside the last segment
    try expectBetter("main", "src/main.zig", "ma/in.zig");
}

test "snapshot and restore, as in a trie walk" {
    const m = try Matcher.init("fi", .{});

    var state = m.start();
    m.feed(&state, "src/");
    const snapshot = state;

    m.feed(&state, "file-index.zig");
    try testing.expectEqual(m.score("src/file-index.zig"), m.finish(&state, "src/file-index.zig"));

    state = snapshot;
    m.feed(&state, "main.zig");
    try testing.expectEqual(m.score("src/main.zig"), m.finish(&state, "src/main.zig"));
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

    // Every path gets a score, so the TopK fills up; the real match leads
    try testing.expectEqual(@as(usize, 3), top.items().len);
    try testing.expectEqualStrings("src/file-index.zig", paths[top.items()[0].item]);
}

// ------------------------------------------------------- typo tolerance

test "typos: a wrong query byte is tolerated" {
    try expectBetter("mxin", "src/main.zig", "src/zzzz.zig");
}

test "typos: a query byte with no counterpart is dropped" {
    try expectBetter("maxin", "src/main.zig", "src/zzzz.zig");
    // Leading and trailing extras
    try expectBetter("xmain", "src/main.zig", "src/zzzz.zig");
    try expectBetter("mainx", "src/main.zig", "src/zzzz.zig");
}

test "typos: a swapped pair is one dropped byte" {
    try expectBetter("mian", "src/main.zig", "src/zzzz.zig");
}

test "typos: exact matches outrank typo matches" {
    try expectBetter("main", "src/main.zig", "src/mxin.zig");
    try expectBetter("mxin", "src/mxin.zig", "src/main.zig");
    // Even short queries: one typo costs more than the best bonus earns
    try expectBetter("ma", "xmax", "src/mx");
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
        try testing.expectEqual(whole, m.finish(&s, cand));
    }
}

test "typos: every candidate gets a score, more typos rank lower" {
    try testing.expect(scoreOf("qzx", "src/main.zig") != null);
    try expectBetter("mxyzain", "src/main.zig", "src/zzzz.zig");
    try expectBetter("mxyzain", "src/mxyzain.zig", "src/main.zig");
}

/// A byte's class, as one bit of a u64: a letter (either case), a digit, one
/// of `._- /`, or a bucket shared by all other bytes. Fine enough for "can
/// this byte occur below here", and a shared bucket only errs on the side of yes.
pub fn byteBit(c: u8) u64 {
    const l = std.ascii.toLower(c);
    const idx: u6 = switch (l) {
        'a'...'z' => @intCast(l - 'a'),
        '0'...'9' => @intCast(26 + l - '0'),
        '.' => 36,
        '_' => 37,
        '-' => 38,
        ' ' => 39,
        '/' => 40,
        else => @intCast(41 + l % 23),
    };
    return @as(u64, 1) << idx;
}

/// The byte classes in `s`.
pub fn labelMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |c| m |= byteBit(c);
    return m;
}

test "subtreeBound never undercuts what feeding the rest can reach" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    const alphabet = "abcmainzigMAx/._-1";
    const queries = [_][]const u8{ "a", "ma", "main", "mxin", "zig", "abc/x", "Main", "ii", "xyzzyq", "m.z" };

    for (queries) |q| {
        const m = try Matcher.init(q, .{});
        for (0..300) |_| {
            var buf: [24]u8 = undefined;
            const len = rnd.intRangeAtMost(usize, 1, buf.len);
            for (buf[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const cand = buf[0..len];
            const threshold = rnd.intRangeAtMost(i32, 0, 200);

            for (0..len) |split| {
                var state = m.start();
                m.feed(&state, cand[0..split]);
                const bound = m.subtreeBound(&state, labelMask(cand[split..]));
                const reachable = m.canReach(bound, threshold);

                m.feed(&state, cand[split..]);
                try testing.expect(bound >= state.full.done);
                if (!reachable) try testing.expect(m.finish(&state, cand).? < threshold);
            }
        }
    }
}

test "subtreeBound is tighter when the subtree can't hold a word boundary" {
    const m = try Matcher.init("main", .{});
    var state = m.start();
    m.feed(&state, "src/ma");
    try testing.expect(m.subtreeBound(&state, labelMask("in")) < m.subtreeBound(&state, labelMask("in/")));
    try testing.expect(m.subtreeBound(&state, labelMask("in")) < m.subtreeBound(&state, labelMask("in_")));
}

test "subtreeBound rules out subtrees missing query bytes, given a threshold" {
    const m = try Matcher.init("main", .{});
    var state = m.start();
    m.feed(&state, "src/ma");
    const t = m.score("src/main").?;
    try testing.expect(!m.canReach(m.subtreeBound(&state, labelMask("xyz.zig")), t));
    try testing.expect(m.canReach(m.subtreeBound(&state, labelMask("in.zig")), t));
    try testing.expect(m.canReach(m.subtreeBound(&state, labelMask("xyz.zig")), null));
}
