const std = @import("std");
const fuzzy = @import("fuzzy.zig");

const TrieChild = struct {
    path: []const u8,
    trie: *Trie,

    node: std.SinglyLinkedList.Node = .{},
};

pub const Trie = struct {
    children: std.SinglyLinkedList,
    isFinal: bool,

    pub fn scanPassthoughNodes(self: *Trie) usize {
        var cnt: usize = 0;
        var childrenCnt: usize = 0;

        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);

            childrenCnt += 1;
            cnt += child.trie.scanPassthoughNodes();

            node = n.next;
        }

        if (childrenCnt == 1) {
            cnt += 1;
        }

        return cnt;
    }

    pub fn scanTotalCharCount(self: *Trie) usize {
        var cnt: usize = 0;

        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);

            cnt += child.path.len;
            cnt += child.trie.scanTotalCharCount();

            node = n.next;
        }

        return cnt;
    }

    pub fn scanSize(self: *Trie) usize {
        var cnt: usize = @sizeOf(Trie);

        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);

            cnt += @sizeOf(TrieChild);
            cnt += child.path.len * @sizeOf(u8);
            cnt += child.trie.scanSize();

            node = n.next;
        }

        return cnt;
    }

    pub fn scanAllNodes(self: *Trie) usize {
        var cnt: usize = 1;

        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);
            cnt += child.trie.scanAllNodes();

            node = n.next;
        }

        return cnt;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        var cnt: usize = 0;
        if (self.isFinal) {
            cnt += 1;
        }

        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);
            cnt += child.trie.countFinalNodes();

            node = n.next;
        }

        return cnt;
    }

    fn getChildPtr(self: *Trie, c: u8) ?*TrieChild {
        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);
            if (child.path[0] == c) {
                return child;
            }

            node = n.next;
        }

        return null;
    }

    fn appendChild(self: *Trie, child: *TrieChild) void {
        self.children.prepend(&child.node);
    }

    fn splitChild(allocator: *std.mem.Allocator, child: *TrieChild, splitPos: usize) !*Trie {
        const newChild = try allocator.create(TrieChild);
        newChild.* = TrieChild{
            .path = child.path[splitPos..],
            .trie = child.trie,
        };

        const newNode = try initWithChild(allocator, newChild);

        child.path = child.path[0..splitPos];
        child.trie = newNode;

        return newNode;
    }

    pub fn add(self: *Trie, word: []const u8, allocator: *std.mem.Allocator, stringAllocator: *std.mem.Allocator) !*Trie {
        var node = self;

        var childInProgress: ?*TrieChild = null;
        var pathPos: usize = 0;

        var i: i32 = 0;
        while (i < word.len) {
            defer i += 1;

            const c = word[@intCast(i)];

            if (pathPos == 0) {
                if (node.getChildPtr(c)) |child| {
                    pathPos += 1;
                    childInProgress = child;
                } else {
                    const remLen = word.len - @as(usize, @intCast(i));

                    const newNode = try init(allocator);
                    const newChildPath = try stringAllocator.alloc(u8, remLen);
                    @memcpy(newChildPath, word[@as(usize, @intCast(i))..]);
                    const newChild = try allocator.create(TrieChild);
                    newChild.* = TrieChild{
                        .path = newChildPath,
                        .trie = newNode,
                    };
                    node.appendChild(newChild);

                    childInProgress = newChild;
                    pathPos = remLen;

                    i = @as(i32, @intCast(word.len)) - 1;
                    break;
                }
            } else {
                if (pathPos == childInProgress.?.path.len) {
                    node = childInProgress.?.trie;
                    childInProgress = null;
                    pathPos = 0;

                    // Continue with the same character, but just move one level down
                    i -= 1;
                } else if (childInProgress.?.path[pathPos] == c) {
                    pathPos += 1;
                } else { // We have a mismatch, so we need to split the node
                    const commonNode = try splitChild(allocator, childInProgress.?, pathPos);

                    const remLen = word.len - @as(usize, @intCast(i));
                    const newNode = try init(allocator);
                    const newChildPath = try stringAllocator.alloc(u8, remLen);
                    @memcpy(newChildPath, word[@as(usize, @intCast(i))..]);
                    const newChild = try allocator.create(TrieChild);
                    newChild.* = TrieChild{
                        .path = newChildPath,
                        .trie = newNode,
                    };
                    commonNode.appendChild(newChild);

                    node = commonNode;
                    childInProgress = newChild;
                    pathPos = remLen;

                    i = @as(i32, @intCast(word.len)) - 1;
                    break;
                }
            }
        }

        if (childInProgress) |child| {
            if (pathPos == child.path.len) {
                child.trie.isFinal = true;
                return child.trie;
            }

            // We are a proper prefix of an existing child, so we need to split

            const newNode = try splitChild(allocator, child, pathPos);
            newNode.isFinal = true;

            return newNode;
        } else {
            unreachable;
        }

        return node;
    }

    pub fn removeRecursive(self: *Trie, word: []const u8, allocator: *std.mem.Allocator) ?*Trie {
        if (word.len == 0) return null;

        const node = self.getChildPtr(word[0]);
        if (node) |child| {
            const len = child.path.len;
            if (!std.mem.startsWith(u8, word, child.path)) {
                return null;
            }

            if (word.len == len) {
                // Only an intermediate node of the trie, the word itself was never added (or is already gone)
                if (!child.trie.isFinal) {
                    return null;
                }

                self.children.remove(&child.node);
                const removed = child.trie;
                allocator.destroy(child);
                return removed;
            } else {
                return child.trie.removeRecursive(word[len..], allocator);
            }
        } else {
            return null;
        }
    }

    pub fn removeSingle(self: *Trie, word: []const u8) ?*Trie {
        if (word.len == 0) return null;

        const node = self.getChildPtr(word[0]);
        if (node) |child| {
            const len = child.path.len;
            if (!std.mem.startsWith(u8, word, child.path)) {
                return null;
            }

            if (word.len == len) {
                // Only an intermediate node of the trie, the word itself was never added (or is already gone)
                if (!child.trie.isFinal) {
                    return null;
                }

                child.trie.isFinal = false;
                return child.trie;
            } else {
                return child.trie.removeSingle(word[len..]);
            }
        } else {
            return null;
        }
    }

    pub fn destroyChildren(self: *Trie, allocator: *std.mem.Allocator) void {
        var node = self.children.first;
        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);
            node = n.next;

            child.trie.destroy(allocator);
            allocator.destroy(child);
        }

        self.children = .{};
    }

    pub fn destroy(self: *Trie, allocator: *std.mem.Allocator) void {
        self.destroyChildren(allocator);
        allocator.destroy(self);
    }

    fn queryInternal(self: *Trie, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) {
            return self.countFinalNodes();
        }

        var cnt: usize = 0;
        var node = self.children.first;

        while (node) |n| {
            const child: *TrieChild = @fieldParentPtr("node", n);

            var newMatchLen = matchLen;
            for (child.path) |c| {
                while (newMatchLen > 0 and c != word[newMatchLen]) {
                    newMatchLen = f[newMatchLen - 1];
                }
                if (c == word[newMatchLen]) {
                    newMatchLen += 1;
                }

                if (newMatchLen == word.len) {
                    break;
                }
            }

            cnt += child.trie.queryInternal(word, f, newMatchLen);

            node = n.next;
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
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(allocator);

        try self.fuzzyWalk(matcher, matcher.start(), &path, top, allocator, includeDirs);
    }

    fn fuzzyWalk(
        self: *Trie,
        matcher: *const fuzzy.Matcher,
        state: fuzzy.State,
        path: *std.ArrayList(u8),
        top: *fuzzy.TopK([]u8),
        allocator: std.mem.Allocator,
        includeDirs: bool,
    ) error{OutOfMemory}!void {
        const items = path.items;
        if (self.isFinal and items.len > 0 and (includeDirs or items[items.len - 1] != '/')) {
            if (matcher.finish(&state)) |score| {
                const tiebreak: u32 = @intCast(@min(items.len, std.math.maxInt(u32)));
                if (top.accepts(score, tiebreak)) {
                    const copy = try allocator.dupe(u8, items);
                    if (top.push(score, tiebreak, copy)) |dropped| allocator.free(dropped);
                }
            }
        }

        var node = self.children.first;
        while (node) |n| : (node = n.next) {
            const child: *TrieChild = @fieldParentPtr("node", n);

            var childState = state;
            matcher.feed(&childState, child.path);

            const len = path.items.len;
            try path.appendSlice(allocator, child.path);
            defer path.shrinkRetainingCapacity(len);

            try child.trie.fuzzyWalk(matcher, childState, path, top, allocator, includeDirs);
        }
    }

    pub fn query(self: *Trie, word: []const u8, allocator: *std.mem.Allocator) !usize {
        var f = try allocator.alloc(usize, word.len);
        defer allocator.free(f);

        f[0] = 0;
        for (1..word.len) |i| {
            var j = f[i - 1];
            while (j > 0 and word[i] != word[j]) {
                j = f[j - 1];
            }
            if (word[i] == word[j]) {
                j += 1;
            }

            f[i] = j;
        }

        return self.queryInternal(word, f, 0);
    }
};

pub fn init(allocator: *std.mem.Allocator) !*Trie {
    const t = try allocator.create(Trie);
    t.* = Trie{
        .children = .{},
        .isFinal = false,
    };

    return t;
}

fn initWithChild(allocator: *std.mem.Allocator, child: *TrieChild) !*Trie {
    const t = try allocator.create(Trie);
    t.* = Trie{
        .children = .{},
        .isFinal = false,
    };
    t.appendChild(child);

    return t;
}

test "single add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("abcd", &allocator, &allocator);

    try std.testing.expectEqual(1, try trie.query("abcd", &allocator));
}

test "add that splits" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("abcd", &allocator, &allocator);
    _ = try trie.add("abe", &allocator, &allocator);

    try std.testing.expectEqual(0, try trie.query("hello", &allocator));
    try std.testing.expectEqual(2, try trie.query("ab", &allocator));
    try std.testing.expectEqual(1, try trie.query("abcd", &allocator));
    try std.testing.expectEqual(1, try trie.query("abe", &allocator));
}

test "add that is a prefix of an existing file" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);

    try std.testing.expectEqual(1, try trie.query("hello", &allocator));
    try std.testing.expectEqual(2, try trie.query("hell", &allocator));
}

test "add a string and then extend it" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("hello", &allocator, &allocator);

    try std.testing.expectEqual(1, try trie.query("hello", &allocator));
    try std.testing.expectEqual(2, try trie.query("hell", &allocator));
}

test "basic add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("heaven", &allocator, &allocator);

    try std.testing.expectEqual(3, try trie.query("he", &allocator));
    try std.testing.expectEqual(2, try trie.query("hell", &allocator));
    try std.testing.expectEqual(1, try trie.query("hello", &allocator));
}

test "add with chainining" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    var subTrie = try trie.add("he", &allocator, &allocator);
    _ = try subTrie.add("llo", &allocator, &allocator);
    var subSubTrie = try subTrie.add("ro", &allocator, &allocator);
    _ = try subSubTrie.add("ic", &allocator, &allocator);

    try std.testing.expectEqual(4, try trie.query("h", &allocator));
    try std.testing.expectEqual(3, try trie.query("o", &allocator));
    try std.testing.expectEqual(1, try trie.query("hello", &allocator));
    try std.testing.expectEqual(2, try trie.query("hero", &allocator));
    try std.testing.expectEqual(1, try trie.query("heroic", &allocator));
}

test "removeRecursive" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("he", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("heaven", &allocator, &allocator);

    try std.testing.expectEqual(4, try trie.query("he", &allocator));

    _ = trie.removeRecursive("heaven", &allocator);
    try std.testing.expectEqual(3, try trie.query("he", &allocator));

    _ = trie.removeRecursive("hell", &allocator);
    try std.testing.expectEqual(1, try trie.query("he", &allocator));

    _ = trie.removeRecursive("he", &allocator);
    try std.testing.expectEqual(0, try trie.query("he", &allocator));
}

test "removeRecursive with missing, short and empty words" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("heaven", &allocator, &allocator);

    try std.testing.expectEqual(null, trie.removeRecursive("zzz", &allocator));
    try std.testing.expectEqual(null, trie.removeRecursive("hex", &allocator));
    try std.testing.expectEqual(null, trie.removeRecursive("hel", &allocator));
    try std.testing.expectEqual(null, trie.removeRecursive("", &allocator));
    // "he" is only the shared start of the two words, it must not take them along
    try std.testing.expectEqual(null, trie.removeRecursive("he", &allocator));
    try std.testing.expectEqual(2, try trie.query("he", &allocator));
}

test "removeSingle" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("he", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("heaven", &allocator, &allocator);

    try std.testing.expectEqual(4, try trie.query("he", &allocator));

    // A word that is a prefix of other words: only it is removed, its descendants stay
    try std.testing.expect(trie.removeSingle("hell") != null);
    try std.testing.expectEqual(3, try trie.query("he", &allocator));
    try std.testing.expectEqual(1, try trie.query("hell", &allocator));

    // Already removed, never added, ending in the middle of an edge, and empty
    try std.testing.expectEqual(null, trie.removeSingle("hell"));
    try std.testing.expectEqual(null, trie.removeSingle("hex"));
    try std.testing.expectEqual(null, trie.removeSingle("hel"));
    try std.testing.expectEqual(null, trie.removeSingle(""));
    try std.testing.expectEqual(3, try trie.query("he", &allocator));
}
