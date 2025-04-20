const std = @import("std");

const TrieMapContext = struct {
    pub fn hash(_: *const TrieMapContext, item: u8) u32 {
        return @as(u32, item);
    }

    pub fn eql(_: *const TrieMapContext, a: u8, b: u8, _: usize) bool {
        return a == b;
    }
};

const TrieChild = struct {
    c: u8,
    trie: *Trie,
};

pub const Trie = struct {
    wordCnt: usize,
    children: []const TrieChild,
    allocator: *std.mem.Allocator,

    pub fn scanPassthoughNodes(self: *Trie) usize {
        var cnt: usize = 0;
        if (self.children.len == 1) {
            cnt += 1;
        }

        for (self.children) |child| {
            cnt += child.trie.scanPassthoughNodes();
        }

        return cnt;
    }

    pub fn scanAllNodes(self: *Trie) usize {
        var cnt: usize = 1;
        for (self.children) |child| {
            cnt += child.trie.scanAllNodes();
        }

        return cnt;
    }

    fn getChild(self: *Trie, c: u8) ?*Trie {
        for (self.children) |child| {
            if (child.c == c) {
                return child.trie;
            }
        }

        return null;
    }

    fn putChild(self: *Trie, c: u8, child: *Trie) !void {
        var newChildren = try self.allocator.alloc(TrieChild, self.children.len + 1);
        for (0..self.children.len) |i| {
            newChildren[i] = self.children[i];
        }
        newChildren[self.children.len] = TrieChild{ .c = c, .trie = child };

        self.allocator.free(self.children);
        self.children = newChildren;
    }

    fn removeChild(self: *Trie, c: u8) !void {
        var newChildren = try self.allocator.alloc(TrieChild, self.children.len - 1);
        var j: usize = 0;
        for (self.children) |child| {
            if (child.c != c) {
                newChildren[j] = child;
                j += 1;
            }
        }

        self.allocator.free(self.children);
        self.children = newChildren;
    }

    pub fn add(self: *Trie, word: []const u8) !*Trie {
        self.wordCnt += 1;

        var node = self;
        for (word) |c| {
            const child = node.getChild(c);
            if (child) |childNode| {
                node = childNode;
            } else {
                const newNode = try init(self.allocator);
                try node.putChild(c, newNode);
                node = newNode;
            }

            node.wordCnt += 1;
        }

        return node;
    }

    pub fn remove(self: *Trie, word: []const u8) !void {
        self.wordCnt -= 1;
        if (word.len == 0) {
            return;
        }

        const child = self.children.get(word[0]);
        if (child == null) {
            return error.WordNotFound;
        }

        try remove(child.?, word[1..]);

        if (child.?.wordCnt == 0) {
            _ = self.children.fetchSwapRemove(word[0]);
            self.allocator.destroy(child.?);
        }
    }

    fn queryInternal(self: *Trie, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) {
            return self.wordCnt;
        }

        var cnt: usize = 0;
        for (self.children) |child| {
            var newMatchLen = matchLen;
            while (newMatchLen > 0 and child.c != word[newMatchLen]) {
                newMatchLen = f[newMatchLen - 1];
            }
            if (child.c == word[newMatchLen]) {
                newMatchLen += 1;
            }

            cnt += child.trie.queryInternal(word, f, newMatchLen);
        }

        return cnt;
    }

    pub fn query(self: *Trie, word: []const u8) !usize {
        var f = try self.allocator.alloc(usize, word.len);
        defer self.allocator.free(f);

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
        .wordCnt = 0,
        .children = try allocator.alloc(TrieChild, 0),
        .allocator = allocator,
    };

    return t;
}

test "test basic add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello");
    _ = try trie.add("hell");
    _ = try trie.add("heaven");

    std.debug.print("Answer for he is {d}\n", .{try trie.query("he")});
    std.debug.assert(try trie.query("he") == 3);
    std.debug.assert(try trie.query("hell") == 2);
    std.debug.assert(try trie.query("hello") == 1);
}
