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
    allocator: *std.mem.Allocator,

    pub fn add(self: *Trie, word: []const u8) !*Trie {
        self.wordCnt += 1;

        var node = self;
        for (word) |c| {
            const child = node.children.get(c);
            if (child) |childNode| {
                node = childNode;
            } else {
                const newNode = try init(self.allocator);
                try node.children.put(c, newNode);
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
        var it = self.children.iterator();
        while (it.next()) |entry| {
            const c = entry.key_ptr.*;

            var newMatchLen = matchLen;
            while (newMatchLen > 0 and c != word[newMatchLen]) {
                newMatchLen = f[newMatchLen - 1];
            }
            if (c == word[newMatchLen]) {
                newMatchLen += 1;
            }

            cnt += entry.value_ptr.*.queryInternal(word, f, newMatchLen);
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
        .children = TrieMap.init(allocator.*),
        .allocator = allocator,
    };

    return t;
}
