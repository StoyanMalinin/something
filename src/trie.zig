//! The compact trie of paths that serves searches: everything lives in one
//! byte arena, with no per-node headers elsewhere.
//!
//! A node is an entry inside its parent's children block:
//! - a leaf (a file nothing extends): `[length][label]`
//! - an internal node (a directory, a split point, or a file another name
//!   extends): `[length][label][flags][sub: u64][children: u32]`, where
//!   `children` is the offset of the node's own children block.
//!
//! So a node's siblings, their labels and their masks sit next to it, and the
//! search reads a whole level in one pass, jumping only into the children
//! blocks of nodes it doesn't prune. Leaves store no mask; the search builds it
//! from the label bytes, which it has at hand.
//!
//! An `Index` (a position) is the offset of an internal node's entry; the root
//! is a fixed entry at offset 0. Changing a block's entries (adding, removing
//! or splitting one) can move all of them, so a position stays valid only
//! until its parent's children change. Adding below a node never moves the
//! node itself, so holding a folder's position while adding below it is safe.
//!
//! Blocks start with a 4-byte header: the bytes of entries in use (low 24
//! bits) and the size class (high 8). `fromVanilla` packs a whole trie into
//! exact-size blocks in depth-first order (class `exact`). Later changes are
//! copy-on-write: a block that has to grow moves to a size-class block from
//! the end of the arena, and the old one becomes dead (exact) or free
//! (size class, reused through per-class free lists).

const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const vanilla = @import("vanilla-trie.zig");
const build_options = @import("build_options");

/// Whether the search counts its work (`zig build -Dstats=true`).
pub const collect_stats = build_options.stats;

/// What one search did, when `collect_stats` is on.
pub const SearchStats = struct {
    internal_seen: u64 = 0,
    internal_pruned: u64 = 0,
    leaves_seen: u64 = 0,
    leaves_pruned: u64 = 0,
    /// Label bytes fed to the matcher, and those of pruned children (not fed).
    internal_bytes_fed: u64 = 0,
    leaf_bytes_fed: u64 = 0,
    bytes_pruned: u64 = 0,
    /// Complete words reached, those `finishBound` let through to a full
    /// `finish`, and those that made the top.
    finals_seen: u64 = 0,
    finals_scored: u64 = 0,
    finals_kept: u64 = 0,
};

pub const Index = enum(u32) {
    root = 0,
    /// Also what `add` returns for a word that ends in a leaf.
    none = std.math.maxInt(u32),
    _,
};

const none: u32 = std.math.maxInt(u32);

// --------------------------------------------------------------- entries

const internal_bit: u8 = 0x80;
const long_bit: u8 = 0x40;
const max_label = 0x3fff;
/// flags (1), sub (8), children (4)
const tail_len: u32 = 13;
const final_flag: u8 = 1;

/// A decoded entry header.
const Entry = struct {
    off: u32,
    internal: bool,
    label_start: u32,
    label_len: u32,

    /// Where an internal entry's flags start (and a leaf ends).
    fn tail(e: Entry) u32 {
        return e.label_start + e.label_len;
    }

    fn end(e: Entry) u32 {
        return e.tail() + if (e.internal) tail_len else 0;
    }
};

fn entrySize(internal: bool, len: usize) usize {
    return @as(usize, if (len <= 0x3f) 1 else 2) + len + @as(usize, if (internal) tail_len else 0);
}

// ---------------------------------------------------------------- blocks

const block_header = 4;
const exact: u8 = 0xff;

/// 16, 24, ..., 72, then about 12.5% apart (multiples of 8), header included.
const class_sizes = blk: {
    @setEvalBranchQuota(10_000);
    var sizes: [200]u32 = undefined;
    var n = 0;
    var s: u32 = 16;
    while (s < (1 << 24)) : (n += 1) {
        sizes[n] = s;
        s = @max(s + 8, (s * 9 / 8 + 7) / 8 * 8);
    }
    break :blk sizes[0..n].*;
};

comptime {
    std.debug.assert(class_sizes.len < exact);
}

fn classFor(bytes: usize) error{OutOfMemory}!u8 {
    for (class_sizes, 0..) |s, c| {
        if (s >= bytes) return @intCast(c);
    }
    return error.OutOfMemory;
}

/// A subtree taken out by `removeRecursive`: its children block and mask.
pub const Detached = struct {
    children: u32,
    sub: u64,
};

pub const Limits = struct {
    /// Reserved up front, so it costs address space, not memory.
    max_bytes: u32 = 1 << 31,
};

pub const Trie = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    used: u32,
    free: [class_sizes.len]u32 = @splat(none),
    /// Bytes of exact blocks that were replaced or shrunk; only a new
    /// `fromVanilla` (or a future compaction) gets them back.
    dead_bytes: usize = 0,
    /// Where new entries are put together before they go into a block.
    scratch: std.ArrayList(u8) = .empty,
    /// The last search's work, when `collect_stats` is on.
    stats: SearchStats = .{},

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Trie {
        const bytes = try allocator.alloc(u8, limits.max_bytes);
        // The root entry: internal, no label, no children
        bytes[0] = internal_bit;
        var t: Trie = .{ .allocator = allocator, .bytes = bytes, .used = 16 };
        const r = t.entry(0);
        t.bytes[r.tail()] = 0;
        t.setSub(r, 0);
        t.setChildren(r, none);
        return t;
    }

    pub fn deinit(self: *Trie) void {
        self.allocator.free(self.bytes);
        self.scratch.deinit(self.allocator);
        self.* = undefined;
    }

    // ------------------------------------------------------- entry access

    fn entry(self: *const Trie, off: u32) Entry {
        const b0 = self.bytes[off];
        var len: u32 = b0 & 0x3f;
        var start = off + 1;
        if (b0 & long_bit != 0) {
            len = (len << 8) | self.bytes[off + 1];
            start += 1;
        }
        return .{ .off = off, .internal = b0 & internal_bit != 0, .label_start = start, .label_len = len };
    }

    fn labelOf(self: *const Trie, e: Entry) []const u8 {
        return self.bytes[e.label_start..][0..e.label_len];
    }

    fn finalAt(self: *const Trie, e: Entry) bool {
        return self.bytes[e.tail()] & final_flag != 0;
    }

    fn setFinal(self: *Trie, e: Entry, final: bool) void {
        self.bytes[e.tail()] = if (final) final_flag else 0;
    }

    fn subAt(self: *const Trie, e: Entry) u64 {
        return std.mem.readInt(u64, self.bytes[e.tail() + 1 ..][0..8], .little);
    }

    fn setSub(self: *Trie, e: Entry, sub: u64) void {
        std.mem.writeInt(u64, self.bytes[e.tail() + 1 ..][0..8], sub, .little);
    }

    fn childrenAt(self: *const Trie, e: Entry) u32 {
        return std.mem.readInt(u32, self.bytes[e.tail() + 9 ..][0..4], .little);
    }

    fn setChildren(self: *Trie, e: Entry, block: u32) void {
        std.mem.writeInt(u32, self.bytes[e.tail() + 9 ..][0..4], block, .little);
    }

    fn nodeAt(self: *const Trie, i: Index) Entry {
        const e = self.entry(@intFromEnum(i));
        std.debug.assert(e.internal);
        return e;
    }

    pub fn isFinal(self: *const Trie, i: Index) bool {
        return self.finalAt(self.nodeAt(i));
    }

    /// Puts an entry together in `scratch` and returns it.
    fn buildEntry(self: *Trie, internal: bool, lbl: []const u8, final: bool, sub: u64, kids: u32) error{ OutOfMemory, NameTooLong }![]const u8 {
        if (lbl.len > max_label) return error.NameTooLong;
        const s = &self.scratch;
        s.clearRetainingCapacity();
        const kind: u8 = if (internal) internal_bit else 0;
        if (lbl.len <= 0x3f) {
            try s.append(self.allocator, kind | @as(u8, @intCast(lbl.len)));
        } else {
            try s.append(self.allocator, kind | long_bit | @as(u8, @intCast(lbl.len >> 8)));
            try s.append(self.allocator, @truncate(lbl.len));
        }
        try s.appendSlice(self.allocator, lbl);
        if (internal) {
            try s.append(self.allocator, if (final) final_flag else 0);
            var buf: [12]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], sub, .little);
            std.mem.writeInt(u32, buf[8..12], kids, .little);
            try s.appendSlice(self.allocator, &buf);
        }
        return s.items;
    }

    // ------------------------------------------------------- block access

    fn blockUsed(self: *const Trie, b: u32) u32 {
        return std.mem.readInt(u32, self.bytes[b..][0..4], .little) & 0xffffff;
    }

    fn blockClass(self: *const Trie, b: u32) u8 {
        return self.bytes[b + 3];
    }

    fn setBlockHeader(self: *Trie, b: u32, used: usize, class: u8) void {
        const h: u32 = @as(u32, @intCast(used)) | (@as(u32, class) << 24);
        std.mem.writeInt(u32, self.bytes[b..][0..4], h, .little);
    }

    fn blockCap(self: *const Trie, b: u32) u32 {
        const c = self.blockClass(b);
        return if (c == exact) self.blockUsed(b) else class_sizes[c] - block_header;
    }

    fn bump(self: *Trie, size: usize) error{OutOfMemory}!u32 {
        if (self.bytes.len - self.used < size) return error.OutOfMemory;
        const b = self.used;
        self.used += @intCast(size);
        return b;
    }

    fn allocBlock(self: *Trie, class: u8) error{OutOfMemory}!u32 {
        const b = if (self.free[class] != none) blk: {
            const reused = self.free[class];
            self.free[class] = std.mem.readInt(u32, self.bytes[reused..][0..4], .little);
            break :blk reused;
        } else try self.bump(class_sizes[class]);
        self.setBlockHeader(b, 0, class);
        return b;
    }

    fn freeBlock(self: *Trie, b: u32) void {
        const c = self.blockClass(b);
        if (c == exact) {
            self.dead_bytes += block_header + self.blockUsed(b);
            return;
        }
        std.mem.writeInt(u32, self.bytes[b..][0..4], self.free[c], .little);
        self.free[c] = b;
    }

    /// A new size-class block holding `content`.
    fn newBlockWith(self: *Trie, content: []const u8) error{OutOfMemory}!u32 {
        const b = try self.allocBlock(try classFor(block_header + content.len));
        @memcpy(self.bytes[b + block_header ..][0..content.len], content);
        self.setBlockHeader(b, content.len, self.blockClass(b));
        return b;
    }

    /// Replaces `old_len` bytes at `at` (relative to the entries) in the
    /// children block of the internal entry at `parent` with `new`, moving the
    /// block if it has to grow. Returns where `new` starts, or `none` if the
    /// block is left empty (and freed). `new` must not be in this block.
    fn edit(self: *Trie, parent: u32, at: u32, old_len: u32, new: []const u8) error{OutOfMemory}!u32 {
        const pe = self.entry(parent);
        const b = self.childrenAt(pe);
        const used: u32 = if (b == none) 0 else self.blockUsed(b);
        const new_len: u32 = @intCast(new.len);
        const new_used = used - old_len + new_len;

        if (new_used == 0) {
            if (b != none) self.freeBlock(b);
            self.setChildren(pe, none);
            return none;
        }

        if (b != none and new_used <= self.blockCap(b)) {
            const base = b + block_header;
            const tail_bytes = used - at - old_len;
            const src = self.bytes[base + at + old_len ..][0..tail_bytes];
            const dst = self.bytes[base + at + new_len ..][0..tail_bytes];
            if (new_len > old_len) std.mem.copyBackwards(u8, dst, src) else std.mem.copyForwards(u8, dst, src);
            @memcpy(self.bytes[base + at ..][0..new_len], new);
            // An exact block only shrinks in place; the bytes past it are lost
            if (self.blockClass(b) == exact) self.dead_bytes += used - new_used;
            self.setBlockHeader(b, new_used, self.blockClass(b));
            return base + at;
        }

        const nb = try self.allocBlock(try classFor(block_header + new_used));
        const nbase = nb + block_header;
        if (b != none) {
            const base = b + block_header;
            @memcpy(self.bytes[nbase..][0..at], self.bytes[base..][0..at]);
            const tail_bytes = used - at - old_len;
            @memcpy(self.bytes[nbase + at + new_len ..][0..tail_bytes], self.bytes[base + at + old_len ..][0..tail_bytes]);
            self.freeBlock(b);
        }
        @memcpy(self.bytes[nbase + at ..][0..new_len], new);
        self.setBlockHeader(nb, new_used, self.blockClass(nb));
        self.setChildren(self.entry(parent), nb);
        return nbase + at;
    }

    // ----------------------------------------------------------- children

    const Children = struct {
        t: *const Trie,
        pos: u32,
        end: u32,

        fn next(it: *Children) ?Entry {
            if (it.pos >= it.end) return null;
            const e = it.t.entry(it.pos);
            it.pos = e.end();
            return e;
        }
    };

    fn blockChildren(self: *const Trie, b: u32) Children {
        if (b == none) return .{ .t = self, .pos = 0, .end = 0 };
        const start = b + block_header;
        return .{ .t = self, .pos = start, .end = start + self.blockUsed(b) };
    }

    fn children(self: *const Trie, e: Entry) Children {
        if (!e.internal) return .{ .t = self, .pos = 0, .end = 0 };
        return self.blockChildren(self.childrenAt(e));
    }

    fn findChild(self: *const Trie, e: Entry, first: u8) ?Entry {
        var it = self.children(e);
        while (it.next()) |c| {
            if (self.bytes[c.label_start] == first) return c;
        }
        return null;
    }

    /// Where `c`, a child of `parent`, starts within its block's entries.
    fn relative(self: *const Trie, parent: Entry, c: Entry) u32 {
        return c.off - (self.childrenAt(parent) + block_header);
    }

    /// Frees the children block `b` and everything below it.
    fn freeBlockTree(self: *Trie, b: u32) void {
        if (b == none) return;
        var it = self.blockChildren(b);
        while (it.next()) |c| {
            if (c.internal) self.freeBlockTree(self.childrenAt(c));
        }
        self.freeBlock(b);
    }

    pub fn freeDetached(self: *Trie, d: Detached) void {
        self.freeBlockTree(d.children);
    }

    // ---------------------------------------------------------- structure

    /// Adds `word` below `from` and returns the internal node it ends at, or
    /// `.none` if it ends in a leaf. `from` stays where it is; other positions
    /// below it may move (see the top of the file).
    pub fn add(self: *Trie, from: Index, word: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        std.debug.assert(word.len > 0);
        var cur: u32 = @intFromEnum(from);
        var rest = word;
        while (true) {
            const ce = self.entry(cur);
            const found = self.findChild(ce, rest[0]) orelse {
                // Nothing starts with this byte: a new entry, internal for a directory
                const dir = rest[rest.len - 1] == '/';
                const mask = fuzzy.labelMask(rest);
                const bytes = try self.buildEntry(dir, rest, true, mask, none);
                const b = self.childrenAt(ce);
                const end = try self.edit(cur, if (b == none) 0 else self.blockUsed(b), 0, bytes);
                // Every node on the way down from `from` now has these below
                self.widenAlong(from, word, mask);
                return if (dir) @enumFromInt(end) else .none;
            };

            const lbl = self.labelOf(found);
            const common: u32 = @intCast(std.mem.indexOfDiff(u8, lbl, rest) orelse lbl.len);
            const at = self.relative(ce, found);
            const old_len = found.end() - found.off;

            if (found.internal and common == lbl.len) {
                if (common == rest.len) {
                    self.setFinal(found, true);
                    return @enumFromInt(found.off);
                }
                cur = found.off;
                rest = rest[common..];
                continue;
            }
            if (!found.internal and common == lbl.len and common == rest.len) return .none;

            // `word` ends or branches off inside the label, or extends a leaf:
            // an internal node takes the first `common` bytes, and what the
            // found entry had left goes into a block below it
            var below: u32 = none;
            var sub: u64 = undefined;
            if (found.internal) {
                sub = self.subAt(found);
                below = try self.newBlockWith(try self.buildEntry(true, lbl[common..], self.finalAt(found), sub, self.childrenAt(found)));
            } else {
                sub = fuzzy.labelMask(lbl);
                if (common < lbl.len) below = try self.newBlockWith(try self.buildEntry(false, lbl[common..], false, 0, none));
            }
            errdefer if (below != none) self.freeBlock(below);
            // A leaf that `word` extends was itself a word
            const final = !found.internal and common == lbl.len;
            const node = try self.edit(cur, at, old_len, try self.buildEntry(true, lbl[0..common], final, sub, below));

            if (common == rest.len) {
                self.setFinal(self.entry(node), true);
                return @enumFromInt(node);
            }
            cur = node;
            rest = rest[common..];
        }
    }

    const Found = struct { parent: Entry, e: Entry };

    /// Where `word` ends below `from`, if it ends exactly at an entry.
    fn lookup(self: *const Trie, from: Index, word: []const u8) ?Found {
        var parent = self.nodeAt(from);
        var rest = word;
        while (rest.len > 0) {
            const c = self.findChild(parent, rest[0]) orelse return null;
            const lbl = self.labelOf(c);
            if (!std.mem.startsWith(u8, rest, lbl)) return null;
            if (rest.len == lbl.len) return .{ .parent = parent, .e = c };
            if (!c.internal) return null;
            parent = c;
            rest = rest[lbl.len..];
        }
        return null;
    }

    /// Takes the final entry `word` ends at, with everything below it, out of
    /// the trie, for the caller to `freeDetached` or adopt (`moveFolder`). A
    /// leaf has nothing to hand back. Null if `word` was never added (or only
    /// passes through a node).
    pub fn removeRecursive(self: *Trie, from: Index, word: []const u8) ?Detached {
        const found = self.lookup(from, word) orelse return null;
        return self.detach(found);
    }

    fn detach(self: *Trie, found: Found) ?Detached {
        const e = found.e;
        var d: Detached = .{ .children = none, .sub = 0 };
        if (e.internal) {
            if (!self.finalAt(e)) return null;
            d = .{ .children = self.childrenAt(e), .sub = self.subAt(e) };
        }
        // Shrinking never moves a block, so this can't fail
        _ = self.edit(found.parent.off, self.relative(found.parent, e), e.end() - e.off, &.{}) catch unreachable;
        return d;
    }

    /// Unmarks `word` as added, keeping everything below it. False if it
    /// wasn't added.
    pub fn removeSingle(self: *Trie, from: Index, word: []const u8) bool {
        const found = self.lookup(from, word) orelse return false;
        const e = found.e;
        if (!e.internal) {
            _ = self.detach(found);
            return true;
        }
        if (!self.finalAt(e)) return false;
        self.setFinal(e, false);
        return true;
    }

    /// Moves the folder `from_word` below `from` to `to_word` below `to`,
    /// replacing what was there. False if there is no such folder.
    pub fn moveFolder(self: *Trie, from: Index, from_word: []const u8, to: Index, to_word: []const u8) error{ OutOfMemory, NameTooLong }!bool {
        const found = self.lookup(from, from_word) orelse return false;
        if (!found.e.internal) return false;
        const b = self.childrenAt(found.parent);
        const start = b + block_header;
        const end = start + self.blockUsed(b);
        const at = found.e.off;
        const len = found.e.end() - found.e.off;
        const d = self.detach(found) orelse return false;
        errdefer self.freeDetached(d);

        // Taking the entry out shifted the siblings after it, `to` among them
        var dest: u32 = @intFromEnum(to);
        if (dest >= start and dest < end) {
            std.debug.assert(dest != at);
            if (dest > at) dest -= len;
        }

        const moved = try self.add(@enumFromInt(dest), to_word);
        const below = self.adoptChildren(moved, d);
        // The adopted children's byte classes, for the folders above
        self.widenAlong(@enumFromInt(dest), to_word, below);
        return true;
    }

    /// Gives `to` the detached subtree's children, freeing its own. Widens
    /// `to`'s mask, not its ancestors': returns the children's byte classes.
    fn adoptChildren(self: *Trie, to: Index, d: Detached) u64 {
        const e = self.nodeAt(to);
        self.freeBlockTree(self.childrenAt(e));
        self.setChildren(e, d.children);
        const below = self.maskOfBlock(d.children);
        self.setSub(e, self.subAt(e) | below);
        return below;
    }

    // -------------------------------------------------------------- masks

    /// What the entries of block `b` need from their parent's mask.
    fn maskOfBlock(self: *const Trie, b: u32) u64 {
        var below: u64 = 0;
        var it = self.blockChildren(b);
        while (it.next()) |c| below |= if (c.internal) self.subAt(c) else fuzzy.labelMask(self.labelOf(c));
        return below;
    }

    /// Adds `mask` to the masks of `from` and of every node on the way down
    /// along `word`, which must be in the trie.
    pub fn widenAlong(self: *Trie, from: Index, word: []const u8, mask: u64) void {
        var cur = self.nodeAt(from);
        var rest = word;
        while (true) {
            self.setSub(cur, self.subAt(cur) | mask);
            if (rest.len == 0) return;
            const c = self.findChild(cur, rest[0]) orelse return;
            if (!c.internal) return;
            const lbl = self.labelOf(c);
            if (!std.mem.startsWith(u8, rest, lbl)) return;
            cur = c;
            rest = rest[lbl.len..];
        }
    }

    fn recomputeBelow(self: *Trie, e: Entry) u64 {
        var below: u64 = 0;
        var it = self.children(e);
        while (it.next()) |c| {
            if (c.internal) {
                const sub = fuzzy.labelMask(self.labelOf(c)) | self.recomputeBelow(c);
                self.setSub(c, sub);
                below |= sub;
            } else {
                below |= fuzzy.labelMask(self.labelOf(c));
            }
        }
        return below;
    }

    /// Rebuilds the masks of everything below `i` from the labels. Returns
    /// what `i`'s mask needs to cover from below.
    pub fn recomputeMasks(self: *Trie, i: Index) u64 {
        return self.recomputeBelow(self.nodeAt(i));
    }

    /// For after a bulk of changes below `position`, the node `word` leads to
    /// from `from` (usually the root): rebuilds `position`'s subtree masks
    /// and carries them up to `from`.
    pub fn refreshMasks(self: *Trie, from: Index, word: []const u8, position: Index) void {
        self.widenAlong(from, word, self.recomputeMasks(position));
    }

    // ------------------------------------------------------ serialization

    /// Packs `v` into a new trie: exact-size blocks in depth-first order, each
    /// node's block right before its subtrees, with the masks computed on the
    /// way back up.
    pub fn fromVanilla(allocator: std.mem.Allocator, limits: Limits, v: *vanilla.Trie) !Trie {
        var t = try Trie.init(allocator, limits);
        errdefer t.deinit();
        const root = t.entry(0);
        t.setFinal(root, v.isFinal(.root));
        t.setSub(root, try t.writeBlock(v, .root, 0));
        return t;
    }

    fn isInternal(v: *vanilla.Trie, i: vanilla.Index) bool {
        const lbl = v.label(i);
        return v.firstChild(i) != .none or lbl[lbl.len - 1] == '/';
    }

    /// Writes `vi`'s children block, points the entry at `entry_off` to it,
    /// then writes the children's own blocks. Returns the children's masks.
    fn writeBlock(self: *Trie, v: *vanilla.Trie, vi: vanilla.Index, entry_off: u32) error{ OutOfMemory, NameTooLong }!u64 {
        var size: usize = 0;
        var c = v.firstChild(vi);
        while (c != .none) : (c = v.nextSibling(c)) {
            size += entrySize(isInternal(v, c), v.label(c).len);
        }
        if (size == 0) {
            self.setChildren(self.entry(entry_off), none);
            return 0;
        }
        if (size > 0xffffff) return error.OutOfMemory;

        const b = try self.bump(block_header + size);
        self.setBlockHeader(b, size, exact);
        self.setChildren(self.entry(entry_off), b);

        var below: u64 = 0;
        var pos = b + block_header;
        c = v.firstChild(vi);
        while (c != .none) : (c = v.nextSibling(c)) {
            const internal = isInternal(v, c);
            const lbl = v.label(c);
            if (!internal) std.debug.assert(v.isFinal(c));
            // The mask and children are filled in below, once known
            const bytes = try self.buildEntry(internal, lbl, v.isFinal(c), 0, none);
            @memcpy(self.bytes[pos..][0..bytes.len], bytes);
            pos += @intCast(bytes.len);
            if (!internal) below |= fuzzy.labelMask(lbl);
        }

        // Then the subtrees, in the same order, so the first one follows this block
        var it = self.blockChildren(b);
        c = v.firstChild(vi);
        while (it.next()) |e| : (c = v.nextSibling(c)) {
            if (!e.internal) continue;
            const sub = fuzzy.labelMask(self.labelOf(e)) | try self.writeBlock(v, c, e.off);
            self.setSub(e, sub);
            below |= sub;
        }
        return below;
    }

    // -------------------------------------------------------------- stats

    /// Nodes with exactly one child.
    pub fn scanPassthoughNodes(self: *Trie) usize {
        var hist: [3]usize = undefined;
        self.scanChildCounts(&hist);
        return hist[1];
    }

    /// `hist[k]` counts nodes and leaves with exactly `k` children; the last
    /// bucket collects everything at or above it.
    pub fn scanChildCounts(self: *Trie, hist: []usize) void {
        @memset(hist, 0);
        self.childCountsBelow(self.entry(0), hist);
    }

    fn childCountsBelow(self: *Trie, e: Entry, hist: []usize) void {
        var n: usize = 0;
        var it = self.children(e);
        while (it.next()) |c| {
            n += 1;
            self.childCountsBelow(c, hist);
        }
        hist[@min(n, hist.len - 1)] += 1;
    }

    /// The root, internal nodes and leaves.
    pub fn scanAllNodes(self: *Trie) usize {
        return self.countBelow(self.entry(0)) + 1;
    }

    fn countBelow(self: *Trie, e: Entry) usize {
        var n: usize = 0;
        var it = self.children(e);
        while (it.next()) |c| n += 1 + self.countBelow(c);
        return n;
    }

    /// Label bytes in use.
    pub fn scanTotalCharCount(self: *Trie) usize {
        return self.charsBelow(self.entry(0));
    }

    fn charsBelow(self: *Trie, e: Entry) usize {
        var n: usize = 0;
        var it = self.children(e);
        while (it.next()) |c| n += c.label_len + self.charsBelow(c);
        return n;
    }

    /// Bytes of the arena handed out, including dead and free blocks.
    pub fn scanSize(self: *Trie) usize {
        return self.used;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        return self.finalsBelow(self.entry(0));
    }

    fn finalsBelow(self: *Trie, e: Entry) usize {
        var n: usize = @intFromBool(e.internal and self.finalAt(e));
        if (!e.internal) return 1;
        var it = self.children(e);
        while (it.next()) |c| n += self.finalsBelow(c);
        return n;
    }

    /// For tests: every node's mask covers its label, its internal children's
    /// masks and its leaves' labels.
    pub fn masksAreConsistent(self: *Trie) bool {
        return self.masksConsistentBelow(self.entry(0));
    }

    fn masksConsistentBelow(self: *Trie, e: Entry) bool {
        const sub = self.subAt(e);
        var it = self.children(e);
        while (it.next()) |c| {
            const need = fuzzy.labelMask(self.labelOf(c));
            if (c.internal) {
                if (self.subAt(c) & need != need) return false;
                if (sub & self.subAt(c) != self.subAt(c)) return false;
                if (!self.masksConsistentBelow(c)) return false;
            } else if (sub & need != need) return false;
        }
        return true;
    }

    // ------------------------------------------------------------- search

    /// How many added words contain `word`.
    pub fn query(self: *Trie, word: []const u8) !usize {
        var f = try self.allocator.alloc(usize, word.len);
        defer self.allocator.free(f);

        f[0] = 0;
        for (1..word.len) |i| {
            var j = f[i - 1];
            while (j > 0 and word[i] != word[j]) j = f[j - 1];
            if (word[i] == word[j]) j += 1;
            f[i] = j;
        }

        return self.queryBelow(self.entry(0), word, f, 0);
    }

    fn queryBelow(self: *Trie, e: Entry, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) return self.finalsBelow(e);

        var cnt: usize = 0;
        var it = self.children(e);
        while (it.next()) |c| {
            var m = matchLen;
            for (self.labelOf(c)) |ch| {
                while (m > 0 and ch != word[m]) m = f[m - 1];
                if (ch == word[m]) m += 1;
                if (m == word.len) break;
            }
            cnt += self.queryBelow(c, word, f, m);
        }
        return cnt;
    }

    pub fn fuzzySearch(
        self: *Trie,
        matcher: *const fuzzy.Matcher,
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        // The walk copies a state per edge, so use one just big enough for the query
        switch (fuzzy.lanesFor(matcher.len)) {
            8 => try self.fuzzySearchL(8, matcher, top, allocator, includeDirs),
            16 => try self.fuzzySearchL(16, matcher, top, allocator, includeDirs),
            32 => try self.fuzzySearchL(32, matcher, top, allocator, includeDirs),
            else => try self.fuzzySearchL(fuzzy.max_query_len, matcher, top, allocator, includeDirs),
        }
    }

    fn fuzzySearchL(
        self: *Trie,
        comptime L: usize,
        matcher: *const fuzzy.Matcher,
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(allocator);

        var state: fuzzy.StateOf(L) = .{};
        self.stats = .{};
        try self.fuzzyWalk(L, self.entry(0), matcher, &state, &path, top, allocator, includeDirs);
    }

    /// Scores `items`, a final word the walk has fed into `state`, and keeps
    /// it if it makes the top.
    fn consider(
        self: *Trie,
        comptime L: usize,
        matcher: *const fuzzy.Matcher,
        state: *const fuzzy.StateOf(L),
        items: []const u8,
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        if (items.len == 0 or !(includeDirs or items[items.len - 1] != '/')) return;
        if (collect_stats) self.stats.finals_seen += 1;
        const tiebreak: u32 = @intCast(@min(items.len, std.math.maxInt(u32)));
        // Most finals can't make it even with the best filename match, and
        // that is the cheap check: the filename match is built only past it
        const bound = matcher.finishBound(state) orelse return;
        if (!top.accepts(bound, tiebreak)) return;
        if (collect_stats) self.stats.finals_scored += 1;
        const score = matcher.finish(state, items) orelse return;
        if (!top.accepts(score, tiebreak)) return;
        if (collect_stats) self.stats.finals_kept += 1;
        const copy = try allocator.dupe(u8, items);
        if (top.push(score, tiebreak, copy)) |dropped| allocator.free(dropped);
    }

    fn fuzzyWalk(
        self: *Trie,
        comptime L: usize,
        e: Entry,
        matcher: *const fuzzy.Matcher,
        state: *const fuzzy.StateOf(L),
        path: *std.ArrayList(u8),
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        if (self.finalAt(e)) try self.consider(L, matcher, state, path.items, top, allocator, includeDirs);

        // One pass over the level: labels and masks are side by side
        var it = self.children(e);
        while (it.next()) |c| {
            const lbl = self.labelOf(c);
            // Skip what can't produce a result; leaves have no stored mask
            const mask = if (c.internal) self.subAt(c) else fuzzy.labelMask(lbl);
            const bound = matcher.subtreeBound(state, mask);
            // Every word below is at least the path so far plus this label long
            const min_len = @min(path.items.len + lbl.len, std.math.maxInt(u32));
            const pass = matcher.canEnter(bound, top, @intCast(min_len));
            if (collect_stats) {
                const st = &self.stats;
                if (c.internal) st.internal_seen += 1 else st.leaves_seen += 1;
                if (!pass) {
                    if (c.internal) st.internal_pruned += 1 else st.leaves_pruned += 1;
                    st.bytes_pruned += lbl.len;
                } else if (c.internal) st.internal_bytes_fed += lbl.len else st.leaf_bytes_fed += lbl.len;
            }
            if (!pass) continue;

            // The children block is read after the feed; start loading it
            if (c.internal) {
                const b = self.childrenAt(c);
                if (b != none) @prefetch(&self.bytes[b], .{});
            }
            var childState = state.*;
            matcher.feed(&childState, lbl);

            const len = path.items.len;
            try path.appendSlice(allocator, lbl);
            defer path.shrinkRetainingCapacity(len);

            if (c.internal) {
                try self.fuzzyWalk(L, c, matcher, &childState, path, top, allocator, includeDirs);
            } else {
                try self.consider(L, matcher, &childState, path.items, top, allocator, includeDirs);
            }
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
pub const test_limits: Limits = .{ .max_bytes = 1 << 20 };

fn testTrie() !Trie {
    return Trie.init(testing.allocator, test_limits);
}

test "single add" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "abcd");
    try testing.expectEqual(1, try t.query("abcd"));
}

test "add that splits" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "abcd");
    _ = try t.add(.root, "abe");

    try testing.expectEqual(0, try t.query("hello"));
    try testing.expectEqual(2, try t.query("ab"));
    try testing.expectEqual(1, try t.query("abcd"));
    try testing.expectEqual(1, try t.query("abe"));
}

test "add that is a prefix of an existing file" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "hell");

    try testing.expectEqual(1, try t.query("hello"));
    try testing.expectEqual(2, try t.query("hell"));
}

test "add a string and then extend it" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "hell");
    _ = try t.add(.root, "hello");

    try testing.expectEqual(1, try t.query("hello"));
    try testing.expectEqual(2, try t.query("hell"));
}

test "basic add" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "hell");
    _ = try t.add(.root, "heaven");

    try testing.expectEqual(3, try t.query("he"));
    try testing.expectEqual(2, try t.query("hell"));
    try testing.expectEqual(1, try t.query("hello"));
}

test "adding the same word twice keeps one" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "a/x");
    try testing.expectEqual(Index.none, try t.add(.root, "a/x"));
    const d = try t.add(.root, "a/d/");
    try testing.expectEqual(d, try t.add(.root, "a/d/"));
    try testing.expectEqual(2, t.countFinalNodes());
}

test "add with chaining" {
    var t = try testTrie();
    defer t.deinit();

    const he = try t.add(.root, "he/");
    _ = try t.add(he, "llo");
    const hero = try t.add(he, "ro/");
    _ = try t.add(hero, "ic");

    try testing.expectEqual(4, try t.query("h"));
    try testing.expectEqual(3, try t.query("o"));
    try testing.expectEqual(1, try t.query("he/llo"));
    try testing.expectEqual(2, try t.query("he/ro/"));
    try testing.expectEqual(1, try t.query("he/ro/ic"));
}

test "adding below a folder keeps its position" {
    var t = try testTrie();
    defer t.deinit();

    const d = try t.add(.root, "d/");
    // Enough to move d/'s children block through several classes
    var buf: [8]u8 = undefined;
    for (0..200) |i| {
        const name = try std.fmt.bufPrint(&buf, "{d}x", .{i});
        _ = try t.add(d, name);
    }
    try testing.expect(t.isFinal(d));
    try testing.expectEqual(200, try t.query("x"));
    try testing.expectEqual(201, t.countFinalNodes());
}

test "files are leaves until something extends or splits them" {
    var t = try testTrie();
    defer t.deinit();

    const dir = try t.add(.root, "d/");
    try testing.expectEqual(Index.none, try t.add(dir, "foo"));
    try testing.expect(!t.lookup(.root, "d/foo").?.e.internal);

    // "foo.bak" extends "foo": it becomes a final node, with ".bak" a leaf below
    try testing.expectEqual(Index.none, try t.add(dir, "foo.bak"));
    const foo = t.lookup(.root, "d/foo").?.e;
    try testing.expect(foo.internal and t.finalAt(foo));
    try testing.expect(!t.lookup(.root, "d/foo.bak").?.e.internal);
    try testing.expectEqual(2, try t.query("foo"));

    // A split puts a node above "foo"; "b" is a leaf
    try testing.expectEqual(Index.none, try t.add(dir, "fob"));
    try testing.expect(t.lookup(.root, "d/fo").?.e.internal);
    try testing.expect(!t.lookup(.root, "d/fob").?.e.internal);
    try testing.expectEqual(6, t.scanAllNodes()); // root, d/, fo, o and the leaves .bak and b

    // A leaf that a new word extends: leaf "b" becomes a final node "b"
    _ = try t.add(dir, "fobx");
    try testing.expectEqual(4, try t.query("fo"));
    t.refreshMasks(.root, "d/", dir);
    try testing.expect(t.masksAreConsistent());
}

test "removeRecursive" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "he");
    _ = try t.add(.root, "hell");
    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "heaven");

    try testing.expectEqual(4, try t.query("he"));

    // A leaf goes at once
    t.freeDetached(t.removeRecursive(.root, "heaven").?);
    try testing.expectEqual(3, try t.query("he"));

    t.freeDetached(t.removeRecursive(.root, "hell").?);
    try testing.expectEqual(1, try t.query("he"));

    t.freeDetached(t.removeRecursive(.root, "he").?);
    try testing.expectEqual(0, try t.query("he"));
    try testing.expectEqual(1, t.scanAllNodes()); // only the root is left
}

test "removeRecursive with missing, short and empty words" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "heaven");

    try testing.expectEqual(null, t.removeRecursive(.root, "zzz"));
    try testing.expectEqual(null, t.removeRecursive(.root, "hex"));
    try testing.expectEqual(null, t.removeRecursive(.root, "hel"));
    try testing.expectEqual(null, t.removeRecursive(.root, "hellos"));
    try testing.expectEqual(null, t.removeRecursive(.root, ""));
    // "he" is only the shared start of the two words, it must not take them along
    try testing.expectEqual(null, t.removeRecursive(.root, "he"));
    try testing.expectEqual(2, try t.query("he"));
}

test "removeSingle" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "he");
    _ = try t.add(.root, "hell");
    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "heaven");

    try testing.expectEqual(4, try t.query("he"));

    // A word that is a prefix of other words: only it is removed, its descendants stay
    try testing.expect(t.removeSingle(.root, "hell"));
    try testing.expectEqual(3, try t.query("he"));
    try testing.expectEqual(1, try t.query("hell"));

    // A leaf
    try testing.expect(t.removeSingle(.root, "heaven"));
    try testing.expectEqual(2, try t.query("he"));

    // Already removed, never added, ending in the middle of an edge, and empty
    try testing.expect(!t.removeSingle(.root, "hell"));
    try testing.expect(!t.removeSingle(.root, "heaven"));
    try testing.expect(!t.removeSingle(.root, "hex"));
    try testing.expect(!t.removeSingle(.root, "hel"));
    try testing.expect(!t.removeSingle(.root, ""));
    try testing.expectEqual(2, try t.query("he"));
}

test "freed blocks are reused" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "a/b/");
    _ = try t.add(.root, "a/f1");
    const used = t.used;
    try testing.expect(t.removeSingle(.root, "a/f1"));
    _ = try t.add(.root, "a/f2");
    try testing.expectEqual(used, t.used);

    t.freeDetached(t.removeRecursive(.root, "a/b/").?);
    _ = try t.add(.root, "a/c/");
    try testing.expectEqual(used, t.used);
}

test "masks stay consistent through adds and splits" {
    var t = try testTrie();
    defer t.deinit();

    for ([_][]const u8{ "hello", "hell", "heaven", "he", "help/me", "help/you", "x/y/z", "x/yy" }) |w| {
        _ = try t.add(.root, w);
        try testing.expect(t.masksAreConsistent());
    }
    // Adding below a deeper position leaves the masks above it stale, until
    // they are refreshed from the root
    const deep = try t.add(.root, "deep/");
    _ = try t.add(deep, "qqq");
    _ = try t.add(deep, "q/r/s");
    try testing.expect(t.subAt(t.nodeAt(deep)) & fuzzy.byteBit('q') != 0);
    try testing.expect(t.subAt(t.nodeAt(.root)) & fuzzy.byteBit('q') == 0);
    t.refreshMasks(.root, "deep/", deep);
    try testing.expect(t.masksAreConsistent());
    try testing.expect(t.subAt(t.nodeAt(.root)) & fuzzy.byteBit('r') != 0);
}

test "recomputing masks gives what adds from the root keep up" {
    var t = try testTrie();
    defer t.deinit();

    for ([_][]const u8{ "hello", "hell", "heaven", "he", "help/me", "help/you", "x/y/z", "x/yy", "x/" }) |w| {
        _ = try t.add(.root, w);
    }
    const x = t.findChild(t.nodeAt(.root), 'x').?;
    const kept = t.subAt(x);
    try testing.expectEqual(t.subAt(t.nodeAt(.root)), t.recomputeMasks(.root));
    try testing.expectEqual(kept, t.subAt(x));
    try testing.expect(t.masksAreConsistent());
}

test "running out of room is an error, not a crash" {
    var t = try Trie.init(testing.allocator, .{ .max_bytes = 80 });
    defer t.deinit();

    _ = try t.add(.root, "abc"); // a 16-byte block after the 16-byte root
    // Needs a 56-byte block while the old one is still held
    try testing.expectError(error.OutOfMemory, t.add(.root, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"));
    // A node "ab" (a 24-byte block) and "c" below it (16 bytes) still fit
    _ = try t.add(.root, "ab");
    try testing.expectEqual(2, try t.query("ab"));
}

test "a block holds 256 children, long names included, and empties" {
    var t = try testTrie();
    defer t.deinit();

    var buf: [300]u8 = undefined;
    @memset(&buf, 'z');
    buf[0] = 'p';
    const lenFor = struct {
        fn f(b: usize) usize {
            // Every 16th name is too long for a one-byte length
            return if (b % 16 == 0) 300 else 2 + b % 7;
        }
    }.f;
    for (0..256) |b| {
        if (b == '/') continue; // "p/..." would be a path, not a sibling
        buf[1] = @intCast(b);
        _ = try t.add(.root, buf[0..lenFor(b)]);
    }
    try testing.expectEqual(255, try t.query("p"));
    try testing.expect(t.masksAreConsistent());

    for (0..256) |b| {
        if (b == '/') continue;
        buf[1] = @intCast(b);
        try testing.expect(t.removeSingle(.root, buf[0..lenFor(b)]));
    }
    try testing.expectEqual(0, try t.query("p"));
}

test "moving a folder into a later sibling fixes up the destination" {
    var t = try testTrie();
    defer t.deinit();

    const r = try t.add(.root, "r/");
    const a = try t.add(r, "a/");
    _ = try t.add(a, "f.txt");
    _ = try t.add(r, "b.txt");
    const d = try t.add(r, "d/");
    try testing.expect(try t.moveFolder(r, "a/", d, "z/"));
    try testing.expectEqual(1, try t.query("r/d/z/f.txt"));
    try testing.expectEqual(0, try t.query("r/a/"));
    try testing.expectEqual(1, try t.query("r/b.txt"));
    // The adds were below `r`, and `r` keeps the bytes of the folder that
    // left (masks may cover more), so rebuild them all from the root
    t.refreshMasks(.root, "", .root);
    try testing.expect(t.masksAreConsistent());
}

fn randomWords(rnd: std.Random, buf: [][40]u8, out: [][]const u8) void {
    const alphabet = "abcdmainzgtrx._-";
    for (out, buf) |*w, *b| {
        var len: usize = 0;
        const parts = rnd.intRangeAtMost(usize, 1, 4);
        for (0..parts) |p| {
            if (p > 0) {
                b[len] = '/';
                len += 1;
            }
            for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| {
                b[len] = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                len += 1;
            }
        }
        // Some are folders
        if (rnd.boolean()) {
            b[len] = '/';
            len += 1;
        }
        w.* = b[0..len];
    }
}

test "a serialized vanilla trie answers like one built in place, and takes changes" {
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var bufs: [500][40]u8 = undefined;
    var words: [500][]const u8 = undefined;
    randomWords(rnd, &bufs, &words);

    var v = try vanilla.Trie.init(testing.allocator);
    defer v.deinit();
    var direct = try testTrie();
    defer direct.deinit();
    for (words[0..400]) |w| {
        _ = try v.add(.root, w);
        _ = try direct.add(.root, w);
    }

    var packed_trie = try Trie.fromVanilla(testing.allocator, test_limits, &v);
    defer packed_trie.deinit();
    try testing.expect(packed_trie.masksAreConsistent());
    try testing.expectEqual(v.countFinalNodes(), packed_trie.countFinalNodes());
    try testing.expectEqual(direct.countFinalNodes(), packed_trie.countFinalNodes());
    try testing.expectEqual(direct.scanAllNodes(), packed_trie.scanAllNodes());
    try testing.expectEqual(0, packed_trie.dead_bytes);

    // Changes to the exact blocks go copy-on-write
    for (words[400..]) |w| {
        _ = try packed_trie.add(.root, w);
        _ = try direct.add(.root, w);
    }
    for (words[0..100]) |w| {
        _ = packed_trie.removeSingle(.root, w);
        _ = direct.removeSingle(.root, w);
    }
    try testing.expect(packed_trie.dead_bytes > 0);
    try testing.expect(packed_trie.masksAreConsistent());
    try testing.expectEqual(direct.countFinalNodes(), packed_trie.countFinalNodes());
    for ([_][]const u8{ "a", "ma", "main", "x.", "/", "rt", "zz", "-_" }) |q| {
        try testing.expectEqual(try direct.query(q), try packed_trie.query(q));
    }
}
