//! A compressed trie of paths, stored as arrays of node headers linked by index.
//!
//! Every node has a header: the label of the edge into it and its mask. A
//! node that can have children (an internal node) also has `kids`, a
//! reference to them, and lives in `internals`; a node that can't (a leaf)
//! lives in `leaves` without it, 16 bytes instead of 20. The kind is a bit of
//! the `Index`. Directories (words ending in '/') and nodes made by a split
//! are internal from the start; everything else starts as a leaf and is moved
//! to `internals` when it gets its first child (a file whose name another
//! name extends, like "foo" and then "foo.bak"). That is the only time a
//! node's `Index` changes, so the positions held across inserts by the
//! walker threads, which are all directories, stay valid.
//!
//! A single child is stored in `kids` itself; two or more live in a
//! contiguous block of child indices from a per-size-class pool (2, 4, ...,
//! 256 slots; a node has at most 256 children, one per first byte).
//!
//! Headers, label bytes and each pool live in buffers reserved once at the
//! largest size allowed; the OS backs their pages only as they are used.
//! Removed nodes and blocks are reused through free lists. Removed label
//! bytes are not reused; `dead_label_bytes` counts them.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Index = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,
};

/// Set in the `Index` of a node in `leaves`.
const leaf_bit: u32 = 1 << 30;

pub fn isLeaf(i: Index) bool {
    return i != .none and @intFromEnum(i) & leaf_bit != 0;
}

/// What every node has, leaf or internal.
pub const Node = struct {
    /// The byte classes (`fuzzy.byteBit`) of this node's label and of
    /// everything below, so a search can bound the best score in a subtree
    /// (`fuzzy.Matcher.subtreeBound`) and skip it. Always covers the
    /// children's masks; it may cover more after a removal, which only costs
    /// pruning power.
    ///
    /// Nodes don't know their parent, so a change below a node can only reach
    /// the masks of the nodes it went through. `add` and `adoptChildren` keep
    /// the masks right from the node they are called on down; the nodes above
    /// it are left stale. Changes made from the root are complete. After
    /// changes below a deeper position, call `refreshMasks` from the root.
    sub: u64 align(4),
    /// The label of the edge into this node, in `Trie.labels`. A free leaf
    /// links the free list through it.
    label_off: u32,
    label_len: u16,
    /// The label's first byte, so looking up a child doesn't touch the labels.
    first_byte: u8,
    is_final: bool,
};

const Internal = struct {
    node: Node,
    /// The children (see `Kids`). Also links the free list.
    kids: u32,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 16);
    std.debug.assert(@sizeOf(Internal) == 20);
}

/// How `Internal.kids` encodes the children:
/// - `none`: no children
/// - top bit clear: exactly one child, whose `Index` this is
/// - top bit set: a block of `class_cap(class)` slots in `pools[class]`, the
///   children first and `.none` after them. Blocks hold two or more children.
const Kids = struct {
    const none: u32 = std.math.maxInt(u32);
    const array_bit: u32 = 1 << 31;
    const block_bits = 28;
    const block_mask: u32 = (1 << block_bits) - 1;

    fn isArray(k: u32) bool {
        return k != none and k & array_bit != 0;
    }
    fn class(k: u32) u3 {
        return @intCast((k >> block_bits) & 7);
    }
    fn make(c: u3, block: u32) u32 {
        return array_bit | (@as(u32, c) << block_bits) | block;
    }
};

const n_classes = 8;

fn classCap(c: u3) u32 {
    return @as(u32, 2) << c;
}

/// Fixed-size blocks of child indices for one size class: bump allocated,
/// with freed blocks reused first (the first slot links them).
const Pool = struct {
    slots: []Index,
    used_blocks: u32 = 0,
    free: u32 = Kids.none,
};

/// The most nodes (leaves and internal together) and label bytes a trie can
/// hold. Reserved up front, so the defaults cost address space, not memory.
pub const Limits = struct {
    max_nodes: u32 = 1 << 26, // 2.25 GiB of address space for the headers
    max_label_bytes: u32 = 1 << 30,
};

pub const Trie = struct {
    allocator: std.mem.Allocator,
    leaves: []Node,
    internals: []Internal,
    /// Header slots handed out, leaves and internal together (some may be
    /// free again); bounded by `Limits.max_nodes`.
    node_count: u32,
    leaf_count: u32 = 0,
    internal_count: u32,
    free_leaves: Index = .none,
    free_internals: Index = .none,
    free_count: u32 = 0,
    labels: []u8,
    labels_used: u32 = 0,
    dead_label_bytes: u32 = 0,
    pools: [n_classes]Pool,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Trie {
        const leaves = try allocator.alloc(Node, limits.max_nodes);
        errdefer allocator.free(leaves);
        const internals = try allocator.alloc(Internal, limits.max_nodes);
        errdefer allocator.free(internals);
        const labels = try allocator.alloc(u8, limits.max_label_bytes);
        errdefer allocator.free(labels);

        // Every child sits in at most one block, and a block is at least half
        // full when it is made, so twice the node count is enough per class
        var pools: [n_classes]Pool = undefined;
        var made: usize = 0;
        errdefer for (pools[0..made]) |p| allocator.free(p.slots);
        for (&pools) |*p| {
            p.* = .{ .slots = try allocator.alloc(Index, @as(usize, limits.max_nodes) * 2) };
            made += 1;
        }

        internals[0] = .{
            .node = .{ .sub = 0, .label_off = 0, .label_len = 0, .first_byte = 0, .is_final = false },
            .kids = Kids.none,
        };
        return .{
            .allocator = allocator,
            .leaves = leaves,
            .internals = internals,
            .node_count = 1,
            .internal_count = 1,
            .labels = labels,
            .pools = pools,
        };
    }

    pub fn deinit(self: *Trie) void {
        self.allocator.free(self.leaves);
        self.allocator.free(self.internals);
        self.allocator.free(self.labels);
        for (self.pools) |p| self.allocator.free(p.slots);
        self.* = undefined;
    }

    fn at(self: *Trie, i: Index) *Node {
        const v = @intFromEnum(i);
        if (v & leaf_bit != 0) return &self.leaves[v & ~leaf_bit];
        return &self.internals[v].node;
    }

    fn kidsOf(self: *Trie, i: Index) *u32 {
        std.debug.assert(!isLeaf(i));
        return &self.internals[@intFromEnum(i)].kids;
    }

    fn label(self: *Trie, i: Index) []const u8 {
        const n = self.at(i);
        return self.labels[n.label_off..][0..n.label_len];
    }

    pub fn isFinal(self: *Trie, i: Index) bool {
        return self.at(i).is_final;
    }

    // ------------------------------------------------------------ storage

    fn block(self: *Trie, k: u32) []Index {
        const c = Kids.class(k);
        const cap = classCap(c);
        return self.pools[c].slots[(k & Kids.block_mask) * cap ..][0..cap];
    }

    fn allocBlock(self: *Trie, c: u3) error{OutOfMemory}!u32 {
        const p = &self.pools[c];
        const cap = classCap(c);
        const b: u32 = if (p.free != Kids.none) blk: {
            const reused = p.free;
            p.free = @intFromEnum(p.slots[reused * cap]);
            break :blk reused;
        } else blk: {
            if ((@as(usize, p.used_blocks) + 1) * cap > p.slots.len) return error.OutOfMemory;
            p.used_blocks += 1;
            break :blk p.used_blocks - 1;
        };
        const k = Kids.make(c, b);
        @memset(self.block(k), .none);
        return k;
    }

    fn freeBlock(self: *Trie, k: u32) void {
        const p = &self.pools[Kids.class(k)];
        self.block(k)[0] = @enumFromInt(p.free);
        p.free = k & Kids.block_mask;
    }

    /// `i`'s children, in place: writing to the slice changes them.
    fn children(self: *Trie, i: Index) []Index {
        if (isLeaf(i)) return &.{};
        const k = self.kidsOf(i);
        if (k.* == Kids.none) return &.{};
        if (!Kids.isArray(k.*)) return @as([*]Index, @ptrCast(k))[0..1];
        const blk = self.block(k.*);
        return blk[0 .. std.mem.indexOfScalar(Index, blk, .none) orelse blk.len];
    }

    /// Drops `i`'s children (not freeing them) and their block.
    fn releaseKids(self: *Trie, i: Index) void {
        if (isLeaf(i)) return;
        const k = self.kidsOf(i);
        if (Kids.isArray(k.*)) self.freeBlock(k.*);
        k.* = Kids.none;
    }

    /// A header slot of the given kind, its contents undefined.
    fn allocSlot(self: *Trie, leaf: bool) error{OutOfMemory}!Index {
        if (leaf and self.free_leaves != .none) {
            const reused = self.free_leaves;
            self.free_leaves = @enumFromInt(self.at(reused).label_off);
            self.free_count -= 1;
            return reused;
        }
        if (!leaf and self.free_internals != .none) {
            const reused = self.free_internals;
            self.free_internals = @enumFromInt(self.kidsOf(reused).*);
            self.free_count -= 1;
            return reused;
        }
        if (self.node_count == self.leaves.len) return error.OutOfMemory;
        self.node_count += 1;
        if (leaf) {
            self.leaf_count += 1;
            return @enumFromInt(leaf_bit | (self.leaf_count - 1));
        }
        self.internal_count += 1;
        return @enumFromInt(self.internal_count - 1);
    }

    /// Puts `i`'s slot on its free list. `i` must have no children.
    fn releaseSlot(self: *Trie, i: Index) void {
        std.debug.assert(i != .root);
        if (isLeaf(i)) {
            self.at(i).label_off = @intFromEnum(self.free_leaves);
            self.free_leaves = i;
        } else {
            std.debug.assert(self.kidsOf(i).* == Kids.none);
            self.kidsOf(i).* = @intFromEnum(self.free_internals);
            self.free_internals = i;
        }
        self.free_count += 1;
    }

    fn newNode(self: *Trie, leaf: bool, label_off: u32, label_len: u16) error{OutOfMemory}!Index {
        const i = try self.allocSlot(leaf);
        self.at(i).* = .{
            .sub = 0,
            .label_off = label_off,
            .label_len = label_len,
            .first_byte = self.labels[label_off],
            .is_final = false,
        };
        if (!leaf) self.kidsOf(i).* = Kids.none;
        return i;
    }

    /// A new childless node with a copy of `bytes`, the end of a word, as its
    /// label: internal if the word is a directory, else a leaf.
    fn newEnd(self: *Trie, bytes: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        const len = std.math.cast(u16, bytes.len) orelse return error.NameTooLong;
        if (self.labels.len - self.labels_used < len) return error.OutOfMemory;
        const off = self.labels_used;
        @memcpy(self.labels[off..][0..len], bytes);

        const i = try self.newNode(bytes[bytes.len - 1] != '/', off, len);
        self.labels_used += len;
        self.at(i).sub = fuzzy.labelMask(bytes);
        return i;
    }

    fn freeNode(self: *Trie, i: Index) void {
        self.dead_label_bytes += self.at(i).label_len;
        self.releaseSlot(i);
    }

    /// Moves leaf `i`, a child of `parent`, to `internals` so it can take
    /// children, and returns its new index.
    fn promote(self: *Trie, parent: Index, i: Index) error{OutOfMemory}!Index {
        const n = try self.allocSlot(false);
        self.at(n).* = self.at(i).*;
        self.kidsOf(n).* = Kids.none;
        self.replaceChild(parent, i, n);
        self.releaseSlot(i);
        return n;
    }

    /// Frees `i` and everything below it. `i` must not be linked into the trie.
    pub fn freeSubtree(self: *Trie, i: Index) void {
        for (self.children(i)) |c| self.freeSubtree(c);
        self.releaseKids(i);
        self.freeNode(i);
    }

    // ---------------------------------------------------------- structure

    fn findChild(self: *Trie, parent: Index, first: u8) Index {
        for (self.children(parent)) |c| {
            if (self.at(c).first_byte == first) return c;
        }
        return .none;
    }

    fn appendChild(self: *Trie, parent: Index, child: Index) error{OutOfMemory}!void {
        const kp = self.kidsOf(parent);
        const k = kp.*;
        if (k == Kids.none) {
            kp.* = @intFromEnum(child);
            return;
        }
        if (!Kids.isArray(k)) {
            const nk = try self.allocBlock(0);
            const blk = self.block(nk);
            blk[0] = @enumFromInt(k);
            blk[1] = child;
            kp.* = nk;
            return;
        }
        const blk = self.block(k);
        if (std.mem.indexOfScalar(Index, blk, .none)) |n| {
            blk[n] = child;
            return;
        }
        // Full: move up a class. 256 children (one per byte) fill the last one
        const nk = try self.allocBlock(Kids.class(k) + 1);
        const nb = self.block(nk);
        @memcpy(nb[0..blk.len], blk);
        nb[blk.len] = child;
        self.freeBlock(k);
        kp.* = nk;
    }

    /// Puts `replacement` where `old` is in `parent`'s children.
    fn replaceChild(self: *Trie, parent: Index, old: Index, replacement: Index) void {
        const cs = self.children(parent);
        cs[std.mem.indexOfScalar(Index, cs, old).?] = replacement;
    }

    fn unlinkChild(self: *Trie, parent: Index, child: Index) void {
        const cs = self.children(parent);
        const pos = std.mem.indexOfScalar(Index, cs, child).?;
        if (cs.len == 1) {
            self.kidsOf(parent).* = Kids.none;
            return;
        }
        std.mem.copyForwards(Index, cs[pos..], cs[pos + 1 ..]);
        cs[cs.len - 1] = .none;
        // Blocks hold two or more; a lone child goes back into `kids`
        if (cs.len == 2) {
            const only = cs[0];
            self.releaseKids(parent);
            self.kidsOf(parent).* = @intFromEnum(only);
        }
    }

    /// Splits `child`'s label after `len` bytes: a new internal node takes
    /// the first part and `child`'s place under `parent`, and `child` keeps
    /// the rest (and its index, so positions held on it stay valid).
    fn splitAbove(self: *Trie, parent: Index, child: Index, len: u16) error{OutOfMemory}!Index {
        const mid = try self.newNode(false, self.at(child).label_off, len);
        const c = self.at(child);
        // Covers both halves of the label and everything below. The lower node
        // keeps its mask too, which still covers its (now shorter) label.
        self.at(mid).sub = c.sub;
        self.replaceChild(parent, child, mid);
        self.kidsOf(mid).* = @intFromEnum(child);

        c.label_off += len;
        c.label_len -= len;
        c.first_byte = self.labels[c.label_off];
        return mid;
    }

    /// Adds `word` below `from` and returns the node it ends at. `from` must
    /// be internal: the root, a directory or a node a split made.
    ///
    /// Indices stay valid except for a leaf that `word` passes through and
    /// that is not final for it: one whose word `word` extends (a file "foo"
    /// when adding "foo.bak"). It moves to `internals` under a new index.
    pub fn add(self: *Trie, from: Index, word: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        std.debug.assert(word.len > 0);
        std.debug.assert(!isLeaf(from));
        var parent: Index = .none;
        var cur = from;
        var rest = word;
        while (true) {
            const child = self.findChild(cur, rest[0]);
            if (child == .none) {
                // Never `from`, which is internal, so its parent is known
                if (isLeaf(cur)) cur = try self.promote(parent, cur);
                const end = try self.newEnd(rest);
                self.at(end).is_final = true;
                self.appendChild(cur, end) catch |err| {
                    self.freeNode(end);
                    return err;
                };
                // Every node on the way down from `from` now has these below
                self.widenAlong(from, word, self.at(end).sub);
                return end;
            }

            const lbl = self.label(child);
            const common: u16 = @intCast(std.mem.indexOfDiff(u8, lbl, rest) orelse lbl.len);
            if (common == lbl.len) {
                if (common == rest.len) {
                    self.at(child).is_final = true;
                    return child;
                }
                parent = cur;
                cur = child;
                rest = rest[common..];
                continue;
            }

            // Ends or branches off inside the label: split it there
            const mid = try self.splitAbove(cur, child, common);
            if (common == rest.len) {
                self.at(mid).is_final = true;
                return mid;
            }
            parent = cur;
            cur = mid;
            rest = rest[common..];
        }
    }

    /// The node `word` ends at below `from`, if it ends exactly at one.
    fn lookup(self: *Trie, from: Index, word: []const u8) ?struct { parent: Index, node: Index } {
        var parent = from;
        var rest = word;
        while (rest.len > 0) {
            const child = self.findChild(parent, rest[0]);
            if (child == .none) return null;
            const lbl = self.label(child);
            if (!std.mem.startsWith(u8, rest, lbl)) return null;
            if (rest.len == lbl.len) return .{ .parent = parent, .node = child };
            parent = child;
            rest = rest[lbl.len..];
        }
        return null;
    }

    /// Unlinks the final node `word` ends at, with everything below it, and
    /// returns it for the caller to `freeSubtree` or `adoptChildren` from.
    /// Null if `word` was never added (or only passes through a node).
    pub fn removeRecursive(self: *Trie, from: Index, word: []const u8) ?Index {
        const found = self.lookup(from, word) orelse return null;
        if (!self.at(found.node).is_final) return null;
        self.unlinkChild(found.parent, found.node);
        return found.node;
    }

    /// Unmarks `word` as added, keeping everything below it.
    pub fn removeSingle(self: *Trie, from: Index, word: []const u8) ?Index {
        const found = self.lookup(from, word) orelse return null;
        if (!self.at(found.node).is_final) return null;
        self.at(found.node).is_final = false;
        return found.node;
    }

    /// Takes over `other`'s children (it keeps none), freeing `to`'s own.
    /// Widens `to`'s mask, not its ancestors' (see `Node.sub`): returns the
    /// children's byte classes, for `widenAlong` from above.
    pub fn adoptChildren(self: *Trie, to: Index, other: Index) u64 {
        for (self.children(to)) |c| self.freeSubtree(c);
        self.releaseKids(to);
        self.kidsOf(to).* = self.kidsOf(other).*;
        self.kidsOf(other).* = Kids.none;

        var below: u64 = 0;
        for (self.children(to)) |c| below |= self.at(c).sub;
        self.at(to).sub |= below;
        return below;
    }

    /// Frees a node unlinked by `removeRecursive` whose children were adopted.
    pub fn freeEmptied(self: *Trie, i: Index) void {
        self.freeNode(i);
    }

    // -------------------------------------------------------------- masks

    /// Adds `mask` to the masks of `from` and of every node on the way down
    /// along `word`, which must be in the trie.
    pub fn widenAlong(self: *Trie, from: Index, word: []const u8, mask: u64) void {
        var cur = from;
        var rest = word;
        while (true) {
            self.at(cur).sub |= mask;
            if (rest.len == 0) return;
            const child = self.findChild(cur, rest[0]);
            if (child == .none) return;
            const lbl = self.label(child);
            if (!std.mem.startsWith(u8, rest, lbl)) return;
            cur = child;
            rest = rest[lbl.len..];
        }
    }

    /// Rebuilds the masks of everything below `i` from the labels. Returns
    /// what `i`'s mask needs to cover from below.
    pub fn recomputeMasks(self: *Trie, i: Index) u64 {
        var below: u64 = 0;
        for (self.children(i)) |c| {
            const sub = fuzzy.labelMask(self.label(c)) | self.recomputeMasks(c);
            self.at(c).sub = sub;
            below |= sub;
        }
        return below;
    }

    /// For after a bulk of changes below `position`, the node `word` leads to
    /// from `from` (usually the root): rebuilds `position`'s subtree masks
    /// and carries them up to `from`.
    pub fn refreshMasks(self: *Trie, from: Index, word: []const u8, position: Index) void {
        self.widenAlong(from, word, self.recomputeMasks(position));
    }

    // -------------------------------------------------------------- stats

    pub fn scanPassthoughNodes(self: *Trie) usize {
        return self.passthroughBelow(.root);
    }

    fn passthroughBelow(self: *Trie, i: Index) usize {
        const cs = self.children(i);
        var cnt: usize = 0;
        for (cs) |c| cnt += self.passthroughBelow(c);
        return cnt + @intFromBool(cs.len == 1);
    }

    /// `hist[k]` counts nodes with exactly `k` children; the last bucket
    /// collects everything at or above it.
    pub fn scanChildCounts(self: *Trie, hist: []usize) void {
        @memset(hist, 0);
        self.childCountsBelow(.root, hist);
    }

    fn childCountsBelow(self: *Trie, i: Index, hist: []usize) void {
        const cs = self.children(i);
        for (cs) |c| self.childCountsBelow(c, hist);
        hist[@min(cs.len, hist.len - 1)] += 1;
    }

    /// Label bytes in use (not counting removed ones).
    pub fn scanTotalCharCount(self: *Trie) usize {
        return self.labels_used - self.dead_label_bytes;
    }

    /// Bytes of nodes and labels in use, including freed ones not yet reused.
    pub fn scanSize(self: *Trie) usize {
        return @as(usize, self.leaf_count) * @sizeOf(Node) +
            @as(usize, self.internal_count) * @sizeOf(Internal) +
            self.labels_used + self.scanBlockBytes();
    }

    /// Bytes of child blocks handed out, including freed ones not yet reused.
    pub fn scanBlockBytes(self: *Trie) usize {
        var total: usize = 0;
        for (self.pools, 0..) |p, c| total += @as(usize, p.used_blocks) * classCap(@intCast(c)) * @sizeOf(Index);
        return total;
    }

    pub fn scanAllNodes(self: *Trie) usize {
        return self.node_count - self.free_count;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        return self.finalsBelow(.root);
    }

    fn finalsBelow(self: *Trie, i: Index) usize {
        var cnt: usize = @intFromBool(self.at(i).is_final);
        for (self.children(i)) |c| cnt += self.finalsBelow(c);
        return cnt;
    }

    /// For tests: every node's mask covers its label and its children's masks.
    pub fn masksAreConsistent(self: *Trie) bool {
        return self.masksConsistentBelow(.root);
    }

    fn masksConsistentBelow(self: *Trie, i: Index) bool {
        for (self.children(i)) |c| {
            const need = fuzzy.labelMask(self.label(c));
            if (self.at(c).sub & need != need) return false;
            if (self.at(i).sub & self.at(c).sub != self.at(c).sub) return false;
            if (!self.masksConsistentBelow(c)) return false;
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

        return self.queryBelow(.root, word, f, 0);
    }

    fn queryBelow(self: *Trie, i: Index, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) return self.finalsBelow(i);

        var cnt: usize = 0;
        for (self.children(i)) |c| {
            var m = matchLen;
            for (self.label(c)) |ch| {
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
        try self.fuzzyWalk(L, .root, matcher, &state, &path, top, allocator, includeDirs);
    }

    fn fuzzyWalk(
        self: *Trie,
        comptime L: usize,
        i: Index,
        matcher: *const fuzzy.Matcher,
        state: *const fuzzy.StateOf(L),
        path: *std.ArrayList(u8),
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        const items = path.items;
        if (self.at(i).is_final and items.len > 0 and (includeDirs or items[items.len - 1] != '/')) {
            const tiebreak: u32 = @intCast(@min(items.len, std.math.maxInt(u32)));
            // Most finals can't make it even with the best filename match, and
            // that is the cheap check: the filename match is built only past it
            if (matcher.finishBound(state)) |bound| {
                if (top.accepts(bound, tiebreak)) {
                    if (matcher.finish(state, items)) |score| {
                        if (top.accepts(score, tiebreak)) {
                            const copy = try allocator.dupe(u8, items);
                            if (top.push(score, tiebreak, copy)) |dropped| allocator.free(dropped);
                        }
                    }
                }
            }
        }

        // The children's headers are rarely adjacent in memory, but their
        // indices are all known here, so start every load at once
        const cs = self.children(i);
        for (cs) |c| @prefetch(self.at(c), .{});

        for (cs) |c| {
            const node = self.at(c);

            // Skip subtrees whose best possible score can't produce a result
            const bound = matcher.subtreeBound(state, node.sub);
            if (!matcher.canReach(bound, top.threshold())) continue;

            // Likewise where the children are, which the walk reads after the feed
            if (!isLeaf(c)) {
                const k = self.kidsOf(c).*;
                if (Kids.isArray(k)) {
                    @prefetch(self.block(k).ptr, .{});
                } else if (k != Kids.none) {
                    @prefetch(self.at(@enumFromInt(k)), .{});
                }
            }
            const lbl = self.label(c);
            var childState = state.*;
            matcher.feed(&childState, lbl);

            const len = path.items.len;
            try path.appendSlice(allocator, lbl);
            defer path.shrinkRetainingCapacity(len);

            try self.fuzzyWalk(L, c, matcher, &childState, path, top, allocator, includeDirs);
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
pub const test_limits: Limits = .{ .max_nodes = 1 << 12, .max_label_bytes = 1 << 16 };

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

test "directories and split nodes are internal, other words start as leaves" {
    var t = try testTrie();
    defer t.deinit();

    const dir = try t.add(.root, "d/");
    const file = try t.add(dir, "foo");
    try testing.expect(!isLeaf(dir));
    try testing.expect(isLeaf(file));

    // "foo.bak" extends "foo": the leaf moves to `internals`, keeping its word
    const bak = try t.add(dir, "foo.bak");
    try testing.expect(isLeaf(bak));
    const moved = t.lookup(.root, "d/foo").?.node;
    try testing.expect(moved != file and !isLeaf(moved));
    try testing.expect(t.isFinal(moved));
    // The old leaf slot went straight back into use for ".bak"
    try testing.expectEqual(file, bak);
    try testing.expectEqual(4, t.scanAllNodes()); // root, d/, foo, .bak
    try testing.expectEqual(2, try t.query("foo"));

    // A split puts an internal node above the leaf, which keeps its index
    const fob = try t.add(dir, "fob");
    try testing.expect(!isLeaf(t.lookup(.root, "d/fo").?.node));
    try testing.expectEqual(bak, t.lookup(.root, "d/foo.bak").?.node);
    try testing.expectEqual(fob, t.lookup(.root, "d/fob").?.node);
    t.refreshMasks(.root, "d/", dir);
    try testing.expect(t.masksAreConsistent());
}

test "a split keeps the index of the node below it" {
    var t = try testTrie();
    defer t.deinit();

    const hello = try t.add(.root, "hello");
    _ = try t.add(.root, "help");
    try testing.expectEqual(hello, try t.add(.root, "hello"));
    const hell = try t.add(.root, "hell");
    try testing.expect(hell != hello);
    try testing.expectEqual(hello, try t.add(hell, "o"));
}

test "removeRecursive" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "he");
    _ = try t.add(.root, "hell");
    _ = try t.add(.root, "hello");
    _ = try t.add(.root, "heaven");

    try testing.expectEqual(4, try t.query("he"));

    t.freeSubtree(t.removeRecursive(.root, "heaven").?);
    try testing.expectEqual(3, try t.query("he"));

    t.freeSubtree(t.removeRecursive(.root, "hell").?);
    try testing.expectEqual(1, try t.query("he"));

    t.freeSubtree(t.removeRecursive(.root, "he").?);
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
    try testing.expect(t.removeSingle(.root, "hell") != null);
    try testing.expectEqual(3, try t.query("he"));
    try testing.expectEqual(1, try t.query("hell"));

    // Already removed, never added, ending in the middle of an edge, and empty
    try testing.expectEqual(null, t.removeSingle(.root, "hell"));
    try testing.expectEqual(null, t.removeSingle(.root, "hex"));
    try testing.expectEqual(null, t.removeSingle(.root, "hel"));
    try testing.expectEqual(null, t.removeSingle(.root, ""));
    try testing.expectEqual(3, try t.query("he"));
}

test "freed nodes are reused" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "a/b/c");
    _ = try t.add(.root, "a/x");
    const count = t.node_count;
    t.freeSubtree(t.removeRecursive(.root, "a/x").?);
    _ = try t.add(.root, "a/y");
    try testing.expectEqual(count, t.node_count);
    try testing.expectEqual(1, t.dead_label_bytes);
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
    try testing.expect(t.at(deep).sub & fuzzy.byteBit('q') != 0);
    try testing.expect(t.at(.root).sub & fuzzy.byteBit('q') == 0);
    t.refreshMasks(.root, "deep/", deep);
    try testing.expect(t.masksAreConsistent());
    try testing.expect(t.at(.root).sub & fuzzy.byteBit('r') != 0);
}

test "recomputing masks gives what adds from the root keep up" {
    var t = try testTrie();
    defer t.deinit();

    for ([_][]const u8{ "hello", "hell", "heaven", "he", "help/me", "help/you", "x/y/z", "x/yy", "x/" }) |w| {
        _ = try t.add(.root, w);
    }
    const x = t.findChild(.root, 'x');
    const kept = t.at(x).sub;
    try testing.expectEqual(t.at(.root).sub, t.recomputeMasks(.root));
    try testing.expectEqual(kept, t.at(x).sub);
    try testing.expect(t.masksAreConsistent());
}

test "running out of room is an error, not a crash" {
    var t = try Trie.init(testing.allocator, .{ .max_nodes = 3, .max_label_bytes = 8 });
    defer t.deinit();

    _ = try t.add(.root, "abc");
    try testing.expectError(error.OutOfMemory, t.add(.root, "xxxxxx"));
    _ = try t.add(.root, "ab"); // a split, no new label bytes
    try testing.expectError(error.OutOfMemory, t.add(.root, "q"));
}

test "children grow through every block class and shrink back" {
    var t = try testTrie();
    defer t.deinit();

    var buf: [2]u8 = .{ 'p', 0 };
    for (0..256) |b| {
        buf[1] = @intCast(b);
        _ = try t.add(.root, &buf);
    }
    const p = t.findChild(.root, 'p');
    try testing.expectEqual(256, t.children(p).len);
    try testing.expectEqual(7, Kids.class(t.kidsOf(p).*));
    try testing.expect(t.masksAreConsistent());

    for (0..255) |b| {
        buf[1] = @intCast(b);
        t.freeSubtree(t.removeRecursive(.root, &buf).?);
    }
    // One child left: back in `kids` itself, its block returned
    try testing.expect(!Kids.isArray(t.kidsOf(p).*));
    try testing.expectEqual(1, t.children(p).len);
    try testing.expectEqual(1, try t.query("p\xff"));
    try testing.expect(t.pools[7].free != Kids.none);
}
