//! A plain compressed trie for building the index in bulk: every node is a
//! 16-byte entry in one growable array, linked to its first child and next
//! sibling by index, with its label in a separate byte buffer.
//!
//! It only grows (no removal), keeps no search masks, and an `Index` never
//! changes, so the walker threads can hold positions across inserts. Once the
//! walk is done, `trie.Trie.fromVanilla` packs it into the compact trie that
//! serves searches and later changes, and this one is freed.

const std = @import("std");

pub const Index = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,
};

pub const Node = struct {
    label_off: u32,
    first_child: Index,
    next_sibling: Index,
    label_len: u16,
    is_final: bool,
};

comptime {
    std.debug.assert(@sizeOf(Node) == 16);
}

pub const Trie = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    labels: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !Trie {
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(allocator, .{
            .label_off = 0,
            .first_child = .none,
            .next_sibling = .none,
            .label_len = 0,
            .is_final = false,
        });
        return .{ .allocator = allocator, .nodes = nodes, .labels = .empty };
    }

    pub fn deinit(self: *Trie) void {
        self.nodes.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.* = undefined;
    }

    fn at(self: *Trie, i: Index) *Node {
        return &self.nodes.items[@intFromEnum(i)];
    }

    pub fn label(self: *Trie, i: Index) []const u8 {
        const n = self.at(i);
        return self.labels.items[n.label_off..][0..n.label_len];
    }

    pub fn isFinal(self: *Trie, i: Index) bool {
        return self.at(i).is_final;
    }

    pub fn firstChild(self: *Trie, i: Index) Index {
        return self.at(i).first_child;
    }

    pub fn nextSibling(self: *Trie, i: Index) Index {
        return self.at(i).next_sibling;
    }

    pub fn nodeCount(self: *Trie) usize {
        return self.nodes.items.len;
    }

    fn newNode(self: *Trie, label_off: u32, label_len: u16) error{OutOfMemory}!Index {
        const i: Index = @enumFromInt(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .label_off = label_off,
            .first_child = .none,
            .next_sibling = .none,
            .label_len = label_len,
            .is_final = false,
        });
        return i;
    }

    fn findChild(self: *Trie, parent: Index, first: u8) Index {
        var c = self.at(parent).first_child;
        while (c != .none) : (c = self.at(c).next_sibling) {
            if (self.labels.items[self.at(c).label_off] == first) return c;
        }
        return .none;
    }

    /// Adds `word` below `from` and returns the node it ends at.
    pub fn add(self: *Trie, from: Index, word: []const u8) error{ OutOfMemory, NameTooLong }!Index {
        std.debug.assert(word.len > 0);
        var cur = from;
        var rest = word;
        while (true) {
            const child = self.findChild(cur, rest[0]);
            if (child == .none) {
                const len = std.math.cast(u16, rest.len) orelse return error.NameTooLong;
                const off: u32 = @intCast(self.labels.items.len);
                try self.labels.appendSlice(self.allocator, rest);
                const leaf = try self.newNode(off, len);
                self.at(leaf).is_final = true;
                self.at(leaf).next_sibling = self.at(cur).first_child;
                self.at(cur).first_child = leaf;
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

            // Ends or branches off inside the label: a new node takes the
            // first part and `child`'s place, and `child` keeps the rest (and
            // its index)
            const mid = try self.newNode(self.at(child).label_off, common);
            const c = self.at(child);
            self.at(mid).next_sibling = c.next_sibling;
            self.at(mid).first_child = child;
            c.next_sibling = .none;
            c.label_off += common;
            c.label_len -= common;

            const p = self.at(cur);
            if (p.first_child == child) {
                p.first_child = mid;
            } else {
                var s = p.first_child;
                while (self.at(s).next_sibling != child) s = self.at(s).next_sibling;
                self.at(s).next_sibling = mid;
            }

            if (common == rest.len) {
                self.at(mid).is_final = true;
                return mid;
            }
            cur = mid;
            rest = rest[common..];
        }
    }

    /// For tests: how many added words there are.
    pub fn countFinalNodes(self: *Trie) usize {
        var n: usize = 0;
        for (self.nodes.items) |node| n += @intFromBool(node.is_final);
        return n;
    }
};

test "adds, splits and extensions keep their indices" {
    var t = try Trie.init(std.testing.allocator);
    defer t.deinit();

    const hello = try t.add(.root, "hello");
    _ = try t.add(.root, "help");
    try std.testing.expectEqual(hello, try t.add(.root, "hello"));
    const hell = try t.add(.root, "hell");
    try std.testing.expect(hell != hello);
    try std.testing.expectEqual(hello, try t.add(hell, "o"));
    try std.testing.expectEqualStrings("o", t.label(hello));

    const d = try t.add(.root, "d/");
    _ = try t.add(d, "x");
    try std.testing.expectEqual(5, t.countFinalNodes()); // hello, help, hell, d/, d/x
}
