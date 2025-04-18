const std = @import("std");

const TrieMapContext = struct {
    pub fn hash(_: *const TrieMapContext, item: u8) u32 {
        return @as(u32, item);
    }

    pub fn eql(_: *const TrieMapContext, a: u8, b: u8, _: usize) bool {
        return a == b;
    }
};

const TrieMap = std.ArrayHashMap(u8, *Trie, TrieMapContext, false);

pub const Trie = struct {
    wordCnt: usize,
    children: TrieMap,
    wordEndCnt: usize,

    pub fn add(self: *Trie, word: []const u8) !void {
        self.wordCnt += 1;

        var node = self;
        for (word) |c| {
            const child = node.children.get(c);
            if (child) |childNode| {
                node = childNode;
            } else {
                const newNode = try init();
                try node.children.put(c, newNode);
                node = newNode;
            }
            node.wordCnt += 1;
        }

        node.wordEndCnt += 1;
    }

    pub fn remove(self: *Trie, word: []const u8) !void {
        self.wordCnt -= 1;
        if (word.len == 0) {
            self.wordEndCnt -= 1;
            return;
        }

        const child = self.children.get(word[0]);
        if (child == null) {
            return error.WordNotFound;
        }

        try remove(child.?, word[1..]);

        if (child.?.wordCnt == 0) {
            _ = self.children.fetchSwapRemove(word[0]);
            std.heap.page_allocator.destroy(child.?);
        }
    }

    pub fn contains(self: *Trie, word: []const u8) bool {
        var node = self;
        for (word) |c| {
            const child = node.children.get(c);
            if (child == null) {
                return false;
            }
            node = child.?;
        }

        return node.wordEndCnt > 0;
    }
};

pub fn init() !*Trie {
    const t = try std.heap.page_allocator.create(Trie);
    t.* = Trie{
        .wordCnt = 0,
        .children = TrieMap.init(std.heap.page_allocator),
        .wordEndCnt = 0,
    };

    return t;
}
