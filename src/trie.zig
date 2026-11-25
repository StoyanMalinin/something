//! A compressed trie of paths, stored as one array of nodes linked by index.
//!
//! Every node holds the label of the edge into it, its first child and its
//! next sibling, so a child is one 24-byte entry (no separate edge object,
//! no pointers). Nodes and label bytes live in two buffers reserved once at
//! the largest size allowed; the OS backs their pages only as they are used,
//! and since they never move, an `Index` stays valid as long as its node is
//! in the trie (positions are held across inserts by the walker threads).
//!
//! Removed nodes are reused through a free list. Removed label bytes are not
//! reused; `dead_label_bytes` counts them.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Index = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,
};

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
    sub: u64,
    first_child: Index,
    /// Also links the free list.
    next_sibling: Index,
    /// The label of the edge into this node, in `Trie.labels`.
    label_off: u32,
    label_len: u16,
    /// The label's first byte, so looking up a child doesn't touch the labels.
    first_byte: u8,
    is_final: bool,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 24);
}

/// The most nodes and label bytes a trie can hold. Reserved up front, so
/// the defaults cost address space, not memory.
pub const Limits = struct {
    max_nodes: u32 = 1 << 26, // 1.5 GiB of address space
    max_label_bytes: u32 = 1 << 30,
};

pub const Trie = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    node_count: u32,
    free_nodes: Index = .none,
    free_count: u32 = 0,
    labels: []u8,
    labels_used: u32 = 0,
    dead_label_bytes: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Trie {
        const nodes = try allocator.alloc(Node, limits.max_nodes);
        errdefer allocator.free(nodes);
        const labels = try allocator.alloc(u8, limits.max_label_bytes);

        nodes[0] = .{
            .sub = 0,
            .first_child = .none,
            .next_sibling = .none,
            .label_off = 0,
            .label_len = 0,
            .first_byte = 0,
            .is_final = false,
        };
        return .{ .allocator = allocator, .nodes = nodes, .node_count = 1, .labels = labels };
    }

    pub fn deinit(self: *Trie) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.labels);
        self.* = undefined;
    }

    fn at(self: *Trie, i: Index) *Node {
        return &self.nodes[@intFromEnum(i)];
    }

    fn label(self: *Trie, i: Index) []const u8 {
        const n = self.at(i);
        return self.labels[n.label_off..][0..n.label_len];
    }

    pub fn isFinal(self: *Trie, i: Index) bool {
        return self.at(i).is_final;
    }

    // ------------------------------------------------------------ storage

    fn newNode(self: *Trie, label_off: u32, label_len: u16) error{OutOfMemory}!Index {
        const i: Index = if (self.free_nodes != .none) blk: {
            const reused = self.free_nodes;
            self.free_nodes = self.at(reused).next_sibling;
            self.free_count -= 1;
            break :blk reused;
        } else blk: {
            if (self.node_count == self.nodes.len) return error.OutOfMemory;
            self.node_count += 1;
            break :blk @enumFromInt(self.node_count - 1);
        };
        self.at(i).* = .{
            .sub = 0,
            .first_child = .none,
            .next_sibling = .none,
            .label_off = label_off,
            .label_len = label_len,
            .first_byte = self.labels[label_off],
            .is_final = false,
        };
        return i;
    }

    /// A new node with a copy of `bytes` as its label.
    fn newLeaf(self: *Trie, bytes: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        const len = std.math.cast(u16, bytes.len) orelse return error.NameTooLong;
        if (self.labels.len - self.labels_used < len) return error.OutOfMemory;
        const off = self.labels_used;
        @memcpy(self.labels[off..][0..len], bytes);
        self.labels_used += len;

        const i = try self.newNode(off, len);
        self.at(i).sub = fuzzy.labelMask(bytes);
        return i;
    }

    fn freeNode(self: *Trie, i: Index) void {
        std.debug.assert(i != .root);
        const n = self.at(i);
        self.dead_label_bytes += n.label_len;
        n.first_child = .none;
        n.next_sibling = self.free_nodes;
        self.free_nodes = i;
        self.free_count += 1;
    }

    /// Frees `i` and everything below it. `i` must not be linked into the trie.
    pub fn freeSubtree(self: *Trie, i: Index) void {
        var c = self.at(i).first_child;
        while (c != .none) {
            const next = self.at(c).next_sibling;
            self.freeSubtree(c);
            c = next;
        }
        self.freeNode(i);
    }

    // ---------------------------------------------------------- structure

    fn findChild(self: *Trie, parent: Index, first: u8) Index {
        var c = self.at(parent).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
            if (self.at(c).first_byte == first) return c;
        }
        return .none;
    }

    fn prependChild(self: *Trie, parent: Index, child: Index) void {
        self.at(child).next_sibling = self.at(parent).first_child;
        self.at(parent).first_child = child;
    }

    /// Puts `replacement` where `old` is in `parent`'s children.
    fn replaceChild(self: *Trie, parent: Index, old: Index, replacement: Index) void {
        self.at(replacement).next_sibling = self.at(old).next_sibling;
        self.at(old).next_sibling = .none;

        const p = self.at(parent);
        if (p.first_child == old) {
            p.first_child = replacement;
            return;
        }
        var c = p.first_child;
        while (self.at(c).next_sibling != old) c = self.at(c).next_sibling;
        self.at(c).next_sibling = replacement;
    }

    fn unlinkChild(self: *Trie, parent: Index, child: Index) void {
        const p = self.at(parent);
        if (p.first_child == child) {
            p.first_child = self.at(child).next_sibling;
        } else {
            var c = p.first_child;
            while (self.at(c).next_sibling != child) c = self.at(c).next_sibling;
            self.at(c).next_sibling = self.at(child).next_sibling;
        }
        self.at(child).next_sibling = .none;
    }

    /// Splits `child`'s label after `len` bytes: a new node takes the first
    /// part and `child`'s place under `parent`, and `child` keeps the rest
    /// (and its index, so positions held on it stay valid).
    fn splitAbove(self: *Trie, parent: Index, child: Index, len: u16) error{OutOfMemory}!Index {
        const c = self.at(child);
        const mid = try self.newNode(c.label_off, len);
        // Covers both halves of the label and everything below. The lower node
        // keeps its mask too, which still covers its (now shorter) label.
        self.at(mid).sub = c.sub;
        self.replaceChild(parent, child, mid);
        self.at(mid).first_child = child;

        c.label_off += len;
        c.label_len -= len;
        c.first_byte = self.labels[c.label_off];
        return mid;
    }

    /// Adds `word` below `from` and returns the node it ends at.
    pub fn add(self: *Trie, from: Index, word: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        std.debug.assert(word.len > 0);
        var cur = from;
        var rest = word;
        while (true) {
            const child = self.findChild(cur, rest[0]);
            if (child == .none) {
                const leaf = try self.newLeaf(rest);
                self.at(leaf).is_final = true;
                self.prependChild(cur, leaf);
                // Every node on the way down from `from` now has these below
                self.widenAlong(from, word, self.at(leaf).sub);
                return leaf;
            }

            const lbl = self.label(child);
            const common: u16 = @intCast(std.mem.indexOfDiff(u8, lbl, rest) orelse lbl.len);
            if (common == lbl.len) {
                if (common == rest.len) {
                    self.at(child).is_final = true;
                    return child;
                }
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
        var c = self.at(to).first_child;
        while (c != .none) {
            const next = self.at(c).next_sibling;
            self.freeSubtree(c);
            c = next;
        }
        self.at(to).first_child = self.at(other).first_child;
        self.at(other).first_child = .none;

        var below: u64 = 0;
        c = self.at(to).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) below |= self.at(c).sub;
        self.at(to).sub |= below;
        return below;
    }

    /// Frees a node unlinked by `removeRecursive` whose children were adopted.
    pub fn freeEmptied(self: *Trie, i: Index) void {
        std.debug.assert(self.at(i).first_child == .none);
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
        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
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
        var cnt: usize = 0;
        var children: usize = 0;
        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
            children += 1;
            cnt += self.passthroughBelow(c);
        }
        return cnt + @intFromBool(children == 1);
    }

    /// Label bytes in use (not counting removed ones).
    pub fn scanTotalCharCount(self: *Trie) usize {
        return self.labels_used - self.dead_label_bytes;
    }

    /// Bytes of nodes and labels in use, including freed ones not yet reused.
    pub fn scanSize(self: *Trie) usize {
        return @as(usize, self.node_count) * @sizeOf(Node) + self.labels_used;
    }

    pub fn scanAllNodes(self: *Trie) usize {
        return self.node_count - self.free_count;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        return self.finalsBelow(.root);
    }

    fn finalsBelow(self: *Trie, i: Index) usize {
        var cnt: usize = @intFromBool(self.at(i).is_final);
        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) cnt += self.finalsBelow(c);
        return cnt;
    }

    /// For tests: every node's mask covers its label and its children's masks.
    pub fn masksAreConsistent(self: *Trie) bool {
        return self.masksConsistentBelow(.root);
    }

    fn masksConsistentBelow(self: *Trie, i: Index) bool {
        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
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
        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
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

        var c = self.at(i).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
            const node = self.at(c);
            // Siblings are rarely adjacent in memory and the chain can't be
            // followed ahead, so start the next node's load while this one is
            // checked (and walked, if it passes)
            if (node.next_sibling != .none) @prefetch(self.at(node.next_sibling), .{});

            // Skip subtrees whose best possible score can't produce a result
            const bound = matcher.subtreeBound(state, node.sub);
            if (!matcher.canReach(bound, top.threshold())) continue;

            // Likewise the first child, which the walk visits after the feed
            if (node.first_child != .none) @prefetch(self.at(node.first_child), .{});
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

    const he = try t.add(.root, "he");
    _ = try t.add(he, "llo");
    const hero = try t.add(he, "ro");
    _ = try t.add(hero, "ic");

    try testing.expectEqual(4, try t.query("h"));
    try testing.expectEqual(3, try t.query("o"));
    try testing.expectEqual(1, try t.query("hello"));
    try testing.expectEqual(2, try t.query("hero"));
    try testing.expectEqual(1, try t.query("heroic"));
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
