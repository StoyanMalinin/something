//! A compressed trie of paths.
//!
//! Directories (words ending in '/'), nodes made by a split, and files that
//! another name extends ("foo" when "foo.bak" exists) are internal nodes:
//! fixed 24-byte headers in one array, addressed by `Index`, holding the label
//! of the edge into the node, its mask, and references to its children.
//!
//! Every other file is a leaf, and a leaf is not an object: it is an entry
//! `[length][label bytes]` packed in its parent's leaf blob, next to its
//! siblings. It has no index, no mask (the search computes it from the bytes,
//! which are right there) and no header, so it costs a byte or two beyond its
//! name. It can't be changed in place: adding or removing one rewrites the
//! blob, which holds at most 256 entries (one per first byte).
//!
//! An internal node's index stays valid as long as it is in the trie: the
//! positions held across inserts by the walker threads are all directories.
//! A leaf that gets a child or is split is taken out of the blob and becomes
//! an internal node.
//!
//! Internal children are a single `Index` stored in `kids` itself, or a block
//! of indices from a per-size-class pool (2, 4, ..., 256 slots). Leaf blobs
//! come from one byte arena in size classes about 1.5x apart.
//!
//! Headers, label bytes, child blocks and the leaf arena live in buffers
//! reserved once at the largest size allowed; the OS backs their pages only as
//! they are used. Removed nodes, blocks and blobs are reused through free
//! lists. Removed label bytes of internal nodes are not reused;
//! `dead_label_bytes` counts them.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Index = enum(u32) {
    root = 0,
    /// Also what `add` returns for a word that ends in a leaf.
    none = std.math.maxInt(u32),
    _,
};

pub const Node = struct {
    /// The byte classes (`fuzzy.byteBit`) of this node's label and of
    /// everything below, so a search can bound the best score in a subtree
    /// (`fuzzy.Matcher.subtreeBound`) and skip it. Always covers the
    /// children's masks and leaf labels; it may cover more after a removal,
    /// which only costs pruning power.
    ///
    /// Nodes don't know their parent, so a change below a node can only reach
    /// the masks of the nodes it went through. `add` and `adoptChildren` keep
    /// the masks right from the node they are called on down; the nodes above
    /// it are left stale. Changes made from the root are complete. After
    /// changes below a deeper position, call `refreshMasks` from the root.
    sub: u64 align(4),
    /// The internal children (see `Kids`). Also links the free list.
    kids: u32,
    /// The byte offset of the leaf blob in `Trie.leaf_arena`, or `Blob.none`.
    leaves: u32,
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

/// How `Node.kids` encodes the internal children:
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

/// A leaf blob: a 4-byte header (bytes of entries in use in the low 24 bits,
/// the size class in the high 8) and then the entries. An entry is the label
/// length in one byte (below 0x80) or two (0x80 | high bits, low byte), then
/// the label. A free blob links its class's free list through the header.
const Blob = struct {
    const none: u32 = std.math.maxInt(u32);
    const header = 4;
    const n_classes = 32;
    const max_label = 0x7fff;

    /// 16, 24, 32, 48, 64, 96, ... bytes, header included.
    fn size(c: u5) u32 {
        const base: u32 = if (c & 1 == 0) 16 else 24;
        return base << (c >> 1);
    }

    fn classFor(bytes: usize) error{NameTooLong}!u5 {
        for (0..Blob.n_classes) |c| {
            if (size(@intCast(c)) >= bytes) return @intCast(c);
        }
        return error.NameTooLong;
    }

    fn entrySize(len: usize) usize {
        return len + @as(usize, if (len < 0x80) 1 else 2);
    }
};

pub const Leaf = struct {
    /// Where the entry starts and ends in the blob's entries.
    pos: usize,
    end: usize,
    label: []const u8,
};

const LeafIter = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn next(it: *LeafIter) ?Leaf {
        if (it.pos >= it.bytes.len) return null;
        const b = it.bytes;
        const p = it.pos;
        var len: usize = b[p];
        var start = p + 1;
        if (len >= 0x80) {
            len = ((len & 0x7f) << 8) | b[p + 1];
            start += 1;
        }
        it.pos = start + len;
        return .{ .pos = p, .end = it.pos, .label = b[start..it.pos] };
    }
};

/// The most nodes, label bytes and leaf bytes a trie can hold. Reserved up
/// front, so the defaults cost address space, not memory.
pub const Limits = struct {
    max_nodes: u32 = 1 << 26, // 1.5 GiB of address space for the headers
    max_label_bytes: u32 = 1 << 30,
    max_leaf_bytes: u32 = 1 << 30,
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
    pools: [n_classes]Pool,
    leaf_arena: []u8,
    leaf_used: u32 = 0,
    leaf_free: [Blob.n_classes]u32 = @splat(Blob.none),

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !Trie {
        const nodes = try allocator.alloc(Node, limits.max_nodes);
        errdefer allocator.free(nodes);
        const labels = try allocator.alloc(u8, limits.max_label_bytes);
        errdefer allocator.free(labels);
        const leaf_arena = try allocator.alloc(u8, limits.max_leaf_bytes);
        errdefer allocator.free(leaf_arena);

        // Every child sits in at most one block, and a block is at least half
        // full when it is made, so twice the node count is enough per class
        var pools: [n_classes]Pool = undefined;
        var made: usize = 0;
        errdefer for (pools[0..made]) |p| allocator.free(p.slots);
        for (&pools) |*p| {
            p.* = .{ .slots = try allocator.alloc(Index, @as(usize, limits.max_nodes) * 2) };
            made += 1;
        }

        nodes[0] = .{
            .sub = 0,
            .kids = Kids.none,
            .leaves = Blob.none,
            .label_off = 0,
            .label_len = 0,
            .first_byte = 0,
            .is_final = false,
        };
        return .{
            .allocator = allocator,
            .nodes = nodes,
            .node_count = 1,
            .labels = labels,
            .pools = pools,
            .leaf_arena = leaf_arena,
        };
    }

    pub fn deinit(self: *Trie) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.labels);
        self.allocator.free(self.leaf_arena);
        for (self.pools) |p| self.allocator.free(p.slots);
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

    // ------------------------------------------------------- child blocks

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

    /// `i`'s internal children, in place: writing to the slice changes them.
    fn children(self: *Trie, i: Index) []Index {
        const k = &self.at(i).kids;
        if (k.* == Kids.none) return &.{};
        if (!Kids.isArray(k.*)) return @as([*]Index, @ptrCast(k))[0..1];
        const blk = self.block(k.*);
        return blk[0 .. std.mem.indexOfScalar(Index, blk, .none) orelse blk.len];
    }

    /// Drops `i`'s internal children (not freeing them) and their block.
    fn releaseKids(self: *Trie, i: Index) void {
        const k = self.at(i).kids;
        if (Kids.isArray(k)) self.freeBlock(k);
        self.at(i).kids = Kids.none;
    }

    // --------------------------------------------------------- leaf blobs

    fn blobHeader(self: *Trie, off: u32) struct { used: u32, class: u5 } {
        const h = std.mem.readInt(u32, self.leaf_arena[off..][0..4], .little);
        return .{ .used = h & 0xffffff, .class = @intCast(h >> 24) };
    }

    fn setBlobHeader(self: *Trie, off: u32, used: usize, class: u5) void {
        const h: u32 = @as(u32, @intCast(used)) | (@as(u32, class) << 24);
        std.mem.writeInt(u32, self.leaf_arena[off..][0..4], h, .little);
    }

    fn allocBlob(self: *Trie, c: u5) error{OutOfMemory}!u32 {
        const off: u32 = if (self.leaf_free[c] != Blob.none) blk: {
            const reused = self.leaf_free[c];
            self.leaf_free[c] = std.mem.readInt(u32, self.leaf_arena[reused..][0..4], .little);
            break :blk reused;
        } else blk: {
            const sz = Blob.size(c);
            if (self.leaf_arena.len - self.leaf_used < sz) return error.OutOfMemory;
            self.leaf_used += sz;
            break :blk self.leaf_used - sz;
        };
        self.setBlobHeader(off, 0, c);
        return off;
    }

    fn freeBlob(self: *Trie, off: u32) void {
        const c = self.blobHeader(off).class;
        std.mem.writeInt(u32, self.leaf_arena[off..][0..4], self.leaf_free[c], .little);
        self.leaf_free[c] = off;
    }

    /// The entries of `i`'s leaf blob.
    fn leafBytes(self: *Trie, i: Index) []u8 {
        const off = self.at(i).leaves;
        if (off == Blob.none) return &.{};
        return self.leaf_arena[off + Blob.header ..][0..self.blobHeader(off).used];
    }

    fn leafIter(self: *Trie, i: Index) LeafIter {
        return .{ .bytes = self.leafBytes(i) };
    }

    fn findLeaf(self: *Trie, i: Index, first: u8) ?Leaf {
        var it = self.leafIter(i);
        while (it.next()) |leaf| {
            if (leaf.label[0] == first) return leaf;
        }
        return null;
    }

    fn leafCount(self: *Trie, i: Index) usize {
        var n: usize = 0;
        var it = self.leafIter(i);
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Appends a leaf to `i`'s blob, moving the blob to a bigger class if it
    /// is full. `bytes` must not be in `i`'s own blob.
    fn leafInsert(self: *Trie, i: Index, bytes: []const u8) error{ OutOfMemory, NameTooLong }!void {
        if (bytes.len > Blob.max_label) return error.NameTooLong;
        const need = Blob.entrySize(bytes.len);
        const n = self.at(i);
        const old = n.leaves;
        const used: usize = if (old == Blob.none) 0 else self.blobHeader(old).used;
        const fits = old != Blob.none and Blob.header + used + need <= Blob.size(self.blobHeader(old).class);

        const off = if (fits) old else blk: {
            const nb = try self.allocBlob(try Blob.classFor(Blob.header + used + need));
            if (old != Blob.none) {
                @memcpy(self.leaf_arena[nb + Blob.header ..][0..used], self.leaf_arena[old + Blob.header ..][0..used]);
                self.freeBlob(old);
            }
            n.leaves = nb;
            break :blk nb;
        };

        var w = self.leaf_arena[off + Blob.header + used ..];
        if (bytes.len < 0x80) {
            w[0] = @intCast(bytes.len);
            w = w[1..];
        } else {
            w[0] = @intCast(0x80 | (bytes.len >> 8));
            w[1] = @truncate(bytes.len);
            w = w[2..];
        }
        @memcpy(w[0..bytes.len], bytes);
        self.setBlobHeader(off, used + need, self.blobHeader(off).class);
    }

    /// Takes `leaf` out of `i`'s blob, returning the blob once it is empty.
    fn leafRemove(self: *Trie, i: Index, leaf: Leaf) void {
        const n = self.at(i);
        const off = n.leaves;
        const h = self.blobHeader(off);
        const bytes = self.leaf_arena[off + Blob.header ..][0..h.used];
        std.mem.copyForwards(u8, bytes[leaf.pos..], bytes[leaf.end..]);
        const used = h.used - (leaf.end - leaf.pos);
        if (used == 0) {
            self.freeBlob(off);
            n.leaves = Blob.none;
        } else {
            self.setBlobHeader(off, used, h.class);
        }
    }

    fn releaseLeaves(self: *Trie, i: Index) void {
        const off = self.at(i).leaves;
        if (off != Blob.none) self.freeBlob(off);
        self.at(i).leaves = Blob.none;
    }

    // -------------------------------------------------------------- nodes

    fn newNode(self: *Trie, label_off: u32, label_len: u16) error{OutOfMemory}!Index {
        const i: Index = if (self.free_nodes != .none) blk: {
            const reused = self.free_nodes;
            self.free_nodes = @enumFromInt(self.at(reused).kids);
            self.free_count -= 1;
            break :blk reused;
        } else blk: {
            if (self.node_count == self.nodes.len) return error.OutOfMemory;
            self.node_count += 1;
            break :blk @enumFromInt(self.node_count - 1);
        };
        self.at(i).* = .{
            .sub = 0,
            .kids = Kids.none,
            .leaves = Blob.none,
            .label_off = label_off,
            .label_len = label_len,
            .first_byte = self.labels[label_off],
            .is_final = false,
        };
        return i;
    }

    /// A new childless node with a copy of `bytes` as its label, and its mask.
    fn newNodeCopy(self: *Trie, bytes: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        const len = std.math.cast(u16, bytes.len) orelse return error.NameTooLong;
        if (self.labels.len - self.labels_used < len) return error.OutOfMemory;
        const off = self.labels_used;
        @memcpy(self.labels[off..][0..len], bytes);

        const i = try self.newNode(off, len);
        self.labels_used += len;
        self.at(i).sub = fuzzy.labelMask(bytes);
        return i;
    }

    fn freeNode(self: *Trie, i: Index) void {
        std.debug.assert(i != .root);
        std.debug.assert(self.at(i).kids == Kids.none and self.at(i).leaves == Blob.none);
        const n = self.at(i);
        self.dead_label_bytes += n.label_len;
        n.kids = @intFromEnum(self.free_nodes);
        self.free_nodes = i;
        self.free_count += 1;
    }

    /// Frees `i` and everything below it. `i` must not be linked into the
    /// trie. `.none` (a removed leaf, see `removeRecursive`) is a no-op.
    pub fn freeSubtree(self: *Trie, i: Index) void {
        if (i == .none) return;
        for (self.children(i)) |c| self.freeSubtree(c);
        self.releaseKids(i);
        self.releaseLeaves(i);
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
        const kp = &self.at(parent).kids;
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
            self.at(parent).kids = Kids.none;
            return;
        }
        std.mem.copyForwards(Index, cs[pos..], cs[pos + 1 ..]);
        cs[cs.len - 1] = .none;
        // Blocks hold two or more; a lone child goes back into `kids`
        if (cs.len == 2) {
            const only = cs[0];
            self.releaseKids(parent);
            self.at(parent).kids = @intFromEnum(only);
        }
    }

    /// Splits `child`'s label after `len` bytes: a new node takes the first
    /// part and `child`'s place under `parent`, and `child` keeps the rest
    /// (and its index, so positions held on it stay valid).
    fn splitAbove(self: *Trie, parent: Index, child: Index, len: u16) error{OutOfMemory}!Index {
        const mid = try self.newNode(self.at(child).label_off, len);
        const c = self.at(child);
        // Covers both halves of the label and everything below. The lower node
        // keeps its mask too, which still covers its (now shorter) label.
        self.at(mid).sub = c.sub;
        self.replaceChild(parent, child, mid);
        self.at(mid).kids = @intFromEnum(child);

        c.label_off += len;
        c.label_len -= len;
        c.first_byte = self.labels[c.label_off];
        return mid;
    }

    /// Turns `leaf`, in `parent`'s blob, into an internal node labeled with
    /// its first `len` bytes; the rest, if any, stays a leaf below it.
    fn leafToNode(self: *Trie, parent: Index, leaf: Leaf, len: usize) error{ OutOfMemory, NameTooLong }!Index {
        const lbl = leaf.label;
        const node = try self.newNodeCopy(lbl[0..len]);
        errdefer self.freeSubtree(node);
        // Covers the whole leaf label, whichever node it ends up in
        self.at(node).sub = fuzzy.labelMask(lbl);
        if (len < lbl.len) {
            try self.leafInsert(node, lbl[len..]);
        } else {
            self.at(node).is_final = true;
        }
        try self.appendChild(parent, node);
        // Last: it moves the bytes `lbl` points to
        self.leafRemove(parent, leaf);
        return node;
    }

    /// Adds `word` below `from` and returns the internal node it ends at, or
    /// `.none` if it ends in a leaf (a file nothing extends).
    ///
    /// Internal nodes keep their indices. A leaf that `word` extends or
    /// branches off inside becomes an internal node.
    pub fn add(self: *Trie, from: Index, word: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        std.debug.assert(word.len > 0);
        var cur = from;
        var rest = word;
        while (true) {
            const child = self.findChild(cur, rest[0]);
            if (child != .none) {
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
                continue;
            }

            if (self.findLeaf(cur, rest[0])) |leaf| {
                const common = std.mem.indexOfDiff(u8, leaf.label, rest) orelse return .none;
                // `word` extends the leaf, or they part inside it
                const node = try self.leafToNode(cur, leaf, common);
                if (common == rest.len) {
                    self.at(node).is_final = true;
                    return node;
                }
                cur = node;
                rest = rest[common..];
                continue;
            }

            // Nothing starts with this byte: a new end, a node for a directory
            const end: Index = if (rest[rest.len - 1] == '/') blk: {
                const n = try self.newNodeCopy(rest);
                errdefer self.freeSubtree(n);
                self.at(n).is_final = true;
                try self.appendChild(cur, n);
                break :blk n;
            } else blk: {
                try self.leafInsert(cur, rest);
                break :blk .none;
            };
            // Every node on the way down from `from` now has these below
            self.widenAlong(from, word, fuzzy.labelMask(rest));
            return end;
        }
    }

    const Found = struct {
        parent: Index,
        /// The node `word` ends at, or `.none` if it is `leaf`.
        node: Index,
        leaf: ?Leaf = null,
    };

    /// Where `word` ends below `from`, if it ends exactly at a node or leaf.
    fn lookup(self: *Trie, from: Index, word: []const u8) ?Found {
        var parent = from;
        var rest = word;
        while (rest.len > 0) {
            const child = self.findChild(parent, rest[0]);
            if (child == .none) {
                const leaf = self.findLeaf(parent, rest[0]) orelse return null;
                if (!std.mem.eql(u8, leaf.label, rest)) return null;
                return .{ .parent = parent, .node = .none, .leaf = leaf };
            }
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
    /// A leaf is removed outright and gives `.none`. Null if `word` was never
    /// added (or only passes through a node).
    pub fn removeRecursive(self: *Trie, from: Index, word: []const u8) ?Index {
        const found = self.lookup(from, word) orelse return null;
        if (found.leaf) |leaf| {
            self.leafRemove(found.parent, leaf);
            return .none;
        }
        if (!self.at(found.node).is_final) return null;
        self.unlinkChild(found.parent, found.node);
        return found.node;
    }

    /// Unmarks `word` as added, keeping everything below it. False if it
    /// wasn't added.
    pub fn removeSingle(self: *Trie, from: Index, word: []const u8) bool {
        const found = self.lookup(from, word) orelse return false;
        if (found.leaf) |leaf| {
            self.leafRemove(found.parent, leaf);
            return true;
        }
        if (!self.at(found.node).is_final) return false;
        self.at(found.node).is_final = false;
        return true;
    }

    /// Takes over `other`'s children and leaves (it keeps none), freeing
    /// `to`'s own. Widens `to`'s mask, not its ancestors' (see `Node.sub`):
    /// returns the children's byte classes, for `widenAlong` from above.
    pub fn adoptChildren(self: *Trie, to: Index, other: Index) u64 {
        for (self.children(to)) |c| self.freeSubtree(c);
        self.releaseKids(to);
        self.releaseLeaves(to);
        self.at(to).kids = self.at(other).kids;
        self.at(to).leaves = self.at(other).leaves;
        self.at(other).kids = Kids.none;
        self.at(other).leaves = Blob.none;

        const below = self.maskBelow(to);
        self.at(to).sub |= below;
        return below;
    }

    /// Frees a node unlinked by `removeRecursive` whose children were adopted.
    pub fn freeEmptied(self: *Trie, i: Index) void {
        self.freeNode(i);
    }

    // -------------------------------------------------------------- masks

    /// What `i`'s children's masks and leaf labels add up to.
    fn maskBelow(self: *Trie, i: Index) u64 {
        var below: u64 = 0;
        for (self.children(i)) |c| below |= self.at(c).sub;
        var it = self.leafIter(i);
        while (it.next()) |leaf| below |= fuzzy.labelMask(leaf.label);
        return below;
    }

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
        var it = self.leafIter(i);
        while (it.next()) |leaf| below |= fuzzy.labelMask(leaf.label);
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
        return cnt + @intFromBool(cs.len + self.leafCount(i) == 1);
    }

    /// `hist[k]` counts nodes and leaves with exactly `k` children; the last
    /// bucket collects everything at or above it.
    pub fn scanChildCounts(self: *Trie, hist: []usize) void {
        @memset(hist, 0);
        self.childCountsBelow(.root, hist);
    }

    fn childCountsBelow(self: *Trie, i: Index, hist: []usize) void {
        const cs = self.children(i);
        const leaves = self.leafCount(i);
        for (cs) |c| self.childCountsBelow(c, hist);
        hist[0] += leaves;
        hist[@min(cs.len + leaves, hist.len - 1)] += 1;
    }

    /// Label bytes in use: internal labels (not counting removed ones) and
    /// leaf labels.
    pub fn scanTotalCharCount(self: *Trie) usize {
        return self.labels_used - self.dead_label_bytes + self.leafLabelBytesBelow(.root);
    }

    fn leafLabelBytesBelow(self: *Trie, i: Index) usize {
        var n: usize = 0;
        for (self.children(i)) |c| n += self.leafLabelBytesBelow(c);
        var it = self.leafIter(i);
        while (it.next()) |leaf| n += leaf.label.len;
        return n;
    }

    /// Bytes of headers, labels, child blocks and leaf blobs handed out,
    /// including freed ones not yet reused.
    pub fn scanSize(self: *Trie) usize {
        return @as(usize, self.node_count) * @sizeOf(Node) + self.labels_used +
            self.scanBlockBytes() + self.leaf_used;
    }

    /// Bytes of child blocks handed out, including freed ones not yet reused.
    pub fn scanBlockBytes(self: *Trie) usize {
        var total: usize = 0;
        for (self.pools, 0..) |p, c| total += @as(usize, p.used_blocks) * classCap(@intCast(c)) * @sizeOf(Index);
        return total;
    }

    /// Internal nodes and leaves.
    pub fn scanAllNodes(self: *Trie) usize {
        return self.node_count - self.free_count + self.leavesBelow(.root);
    }

    fn leavesBelow(self: *Trie, i: Index) usize {
        var n = self.leafCount(i);
        for (self.children(i)) |c| n += self.leavesBelow(c);
        return n;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        return self.finalsBelow(.root);
    }

    fn finalsBelow(self: *Trie, i: Index) usize {
        var cnt: usize = @intFromBool(self.at(i).is_final) + self.leafCount(i);
        for (self.children(i)) |c| cnt += self.finalsBelow(c);
        return cnt;
    }

    /// For tests: every node's mask covers its label, its children's masks
    /// and its leaves' labels.
    pub fn masksAreConsistent(self: *Trie) bool {
        return self.masksConsistentBelow(.root);
    }

    fn masksConsistentBelow(self: *Trie, i: Index) bool {
        const sub = self.at(i).sub;
        for (self.children(i)) |c| {
            const need = fuzzy.labelMask(self.label(c));
            if (self.at(c).sub & need != need) return false;
            if (sub & self.at(c).sub != self.at(c).sub) return false;
            if (!self.masksConsistentBelow(c)) return false;
        }
        var it = self.leafIter(i);
        while (it.next()) |leaf| {
            const need = fuzzy.labelMask(leaf.label);
            if (sub & need != need) return false;
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

    fn advance(word: []const u8, f: []const usize, matchLen: usize, bytes: []const u8) usize {
        var m = matchLen;
        for (bytes) |ch| {
            while (m > 0 and ch != word[m]) m = f[m - 1];
            if (ch == word[m]) m += 1;
            if (m == word.len) break;
        }
        return m;
    }

    fn queryBelow(self: *Trie, i: Index, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) return self.finalsBelow(i);

        var cnt: usize = 0;
        for (self.children(i)) |c| {
            cnt += self.queryBelow(c, word, f, advance(word, f, matchLen, self.label(c)));
        }
        var it = self.leafIter(i);
        while (it.next()) |leaf| {
            cnt += @intFromBool(advance(word, f, matchLen, leaf.label) == word.len);
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

    /// Scores `path`, a final word the walk has fed into `state`, and keeps it
    /// if it makes the top.
    fn consider(
        comptime L: usize,
        matcher: *const fuzzy.Matcher,
        state: *const fuzzy.StateOf(L),
        items: []const u8,
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        if (items.len == 0 or !(includeDirs or items[items.len - 1] != '/')) return;
        const tiebreak: u32 = @intCast(@min(items.len, std.math.maxInt(u32)));
        // Most finals can't make it even with the best filename match, and
        // that is the cheap check: the filename match is built only past it
        const bound = matcher.finishBound(state) orelse return;
        if (!top.accepts(bound, tiebreak)) return;
        const score = matcher.finish(state, items) orelse return;
        if (!top.accepts(score, tiebreak)) return;
        const copy = try allocator.dupe(u8, items);
        if (top.push(score, tiebreak, copy)) |dropped| allocator.free(dropped);
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
        if (self.at(i).is_final) try consider(L, matcher, state, path.items, top, allocator, includeDirs);

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
            if (Kids.isArray(node.kids)) {
                @prefetch(self.block(node.kids).ptr, .{});
            } else if (node.kids != Kids.none) {
                @prefetch(self.at(@enumFromInt(node.kids)), .{});
            }
            if (node.leaves != Blob.none) @prefetch(&self.leaf_arena[node.leaves], .{});

            const lbl = self.label(c);
            var childState = state.*;
            matcher.feed(&childState, lbl);

            const len = path.items.len;
            try path.appendSlice(allocator, lbl);
            defer path.shrinkRetainingCapacity(len);

            try self.fuzzyWalk(L, c, matcher, &childState, path, top, allocator, includeDirs);
        }

        // Leaves have no stored mask; their bytes are at hand, so build it
        var it = self.leafIter(i);
        while (it.next()) |leaf| {
            const bound = matcher.subtreeBound(state, fuzzy.labelMask(leaf.label));
            if (!matcher.canReach(bound, top.threshold())) continue;

            var leafState = state.*;
            matcher.feed(&leafState, leaf.label);

            const len = path.items.len;
            try path.appendSlice(allocator, leaf.label);
            defer path.shrinkRetainingCapacity(len);

            try consider(L, matcher, &leafState, path.items, top, allocator, includeDirs);
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
pub const test_limits: Limits = .{ .max_nodes = 1 << 12, .max_label_bytes = 1 << 16, .max_leaf_bytes = 1 << 16 };

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
    try testing.expectEqual(1, t.countFinalNodes());
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

test "files are leaves until something extends or splits them" {
    var t = try testTrie();
    defer t.deinit();

    const dir = try t.add(.root, "d/");
    try testing.expect(dir != .none);
    try testing.expectEqual(Index.none, try t.add(dir, "foo"));
    try testing.expect(t.lookup(.root, "d/foo").?.leaf != null);

    // "foo.bak" extends "foo": it becomes a final node, with ".bak" a leaf below
    try testing.expectEqual(Index.none, try t.add(dir, "foo.bak"));
    const foo = t.lookup(.root, "d/foo").?.node;
    try testing.expect(foo != .none and t.isFinal(foo));
    try testing.expect(t.lookup(.root, "d/foo.bak").?.leaf != null);
    try testing.expectEqual(2, try t.query("foo"));

    // A split puts a node above "foo", which keeps its index; "b" is a leaf
    try testing.expectEqual(Index.none, try t.add(dir, "fob"));
    try testing.expectEqual(foo, t.lookup(.root, "d/foo").?.node);
    try testing.expect(t.lookup(.root, "d/fob").?.leaf != null);
    try testing.expectEqual(6, t.scanAllNodes()); // root, d/, fo, o and the leaves .bak and b

    // A leaf that a new word extends: leaf "b" becomes a final node "b"
    _ = try t.add(dir, "fobx");
    try testing.expectEqual(4, try t.query("fo"));
    t.refreshMasks(.root, "d/", dir);
    try testing.expect(t.masksAreConsistent());
}

test "a split keeps the index of the node below it" {
    var t = try testTrie();
    defer t.deinit();

    const hello = try t.add(.root, "hello/");
    _ = try t.add(.root, "help/");
    try testing.expectEqual(hello, try t.add(.root, "hello/"));
    const hell = try t.add(.root, "hell");
    try testing.expect(hell != hello and hell != .none);
    try testing.expectEqual(hello, try t.add(hell, "o/"));
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
    try testing.expectEqual(Index.none, t.removeRecursive(.root, "heaven").?);
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

test "freed nodes and blobs are reused" {
    var t = try testTrie();
    defer t.deinit();

    _ = try t.add(.root, "a/b/");
    _ = try t.add(.root, "a/x/");
    const count = t.node_count;
    t.freeSubtree(t.removeRecursive(.root, "a/x/").?);
    _ = try t.add(.root, "a/y/");
    try testing.expectEqual(count, t.node_count);
    try testing.expectEqual(2, t.dead_label_bytes);

    _ = try t.add(.root, "a/f1");
    const used = t.leaf_used;
    try testing.expect(t.removeSingle(.root, "a/f1"));
    _ = try t.add(.root, "a/f2");
    try testing.expectEqual(used, t.leaf_used);
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
    var t = try Trie.init(testing.allocator, .{ .max_nodes = 2, .max_label_bytes = 4, .max_leaf_bytes = 32 });
    defer t.deinit();

    _ = try t.add(.root, "abc"); // a 16-byte blob
    // Needs a 32-byte blob while the old one is still held
    try testing.expectError(error.OutOfMemory, t.add(.root, "xxxxxxxxxxxxxxxxxxxx"));
    _ = try t.add(.root, "ab"); // a split: a node, and "c" a leaf below it
    _ = try t.add(.root, "abd");
    try testing.expectError(error.OutOfMemory, t.add(.root, "q/")); // no node left
    try testing.expectEqual(3, try t.query("ab"));
}

test "children grow through every block class and shrink back" {
    var t = try testTrie();
    defer t.deinit();

    // Directories, so they are internal children
    var buf: [3]u8 = .{ 'p', 0, '/' };
    for (0..256) |b| {
        buf[1] = @intCast(b);
        _ = try t.add(.root, &buf);
    }
    const p = t.findChild(.root, 'p');
    try testing.expectEqual(256, t.children(p).len);
    try testing.expectEqual(7, Kids.class(t.at(p).kids));
    try testing.expect(t.masksAreConsistent());

    for (0..255) |b| {
        buf[1] = @intCast(b);
        t.freeSubtree(t.removeRecursive(.root, &buf).?);
    }
    // One child left: back in `kids` itself, its block returned
    try testing.expect(!Kids.isArray(t.at(p).kids));
    try testing.expectEqual(1, t.children(p).len);
    try testing.expectEqual(1, try t.query("p\xff/"));
    try testing.expect(t.pools[7].free != Kids.none);
}

test "a blob grows to hold 256 leaves, long names included, and empties" {
    var t = try testTrie();
    defer t.deinit();

    var buf: [300]u8 = undefined;
    buf[0] = 'p';
    for (0..256) |b| {
        buf[1] = @intCast(b);
        // Every 16th name is too long for a one-byte length
        const len: usize = if (b % 16 == 0) 300 else 2 + b % 7;
        @memset(buf[2..len], 'z');
        if (b == '/') continue; // "p/..." would be a path, not a sibling
        _ = try t.add(.root, buf[0..len]);
    }
    const p = t.findChild(.root, 'p');
    try testing.expectEqual(255, t.leafCount(p));
    try testing.expectEqual(255, try t.query("p"));
    try testing.expect(t.masksAreConsistent());

    for (0..256) |b| {
        if (b == '/') continue;
        buf[1] = @intCast(b);
        const len: usize = if (b % 16 == 0) 300 else 2 + b % 7;
        try testing.expect(t.removeSingle(.root, buf[0..len]));
    }
    try testing.expectEqual(Blob.none, t.at(p).leaves);
    try testing.expectEqual(0, try t.query("p"));
}
