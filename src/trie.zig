const std = @import("std");

const TrieChild = struct {
    path: std.ArrayList(u8),
    trie: *Trie,
};

fn extendString(allocator: *std.mem.Allocator, s: []const u8, c: u8) ![]const u8 {
    var newStr = try allocator.alloc(u8, s.len + 1);
    for (0..s.len) |i| {
        newStr[i] = s[i];
    }
    newStr[s.len] = c;

    return newStr;
}

pub const Trie = struct {
    children: std.ArrayList(TrieChild),
    allocator: *std.mem.Allocator,
    isFinal: bool,

    pub fn scanPassthoughNodes(self: *Trie) usize {
        var cnt: usize = 0;
        if (self.children.items.len == 1) {
            cnt += 1;
        }

        for (self.children.items) |child| {
            cnt += child.trie.scanPassthoughNodes();
        }

        return cnt;
    }

    pub fn scanTotalCharCount(self: *Trie) usize {
        var cnt: usize = 0;
        for (self.children.items) |child| {
            cnt += child.path.items.len;
            cnt += child.trie.scanTotalCharCount();
        }

        return cnt;
    }

    pub fn scanSize(self: *Trie) usize {
        var cnt: usize = @sizeOf(Trie);
        cnt += self.children.items.len * @sizeOf(TrieChild);

        for (self.children.items) |child| {
            cnt += child.path.items.len * @sizeOf(u8);
            cnt += child.trie.scanSize();
        }

        return cnt;
    }

    pub fn scanAllNodes(self: *Trie) usize {
        var cnt: usize = 1;
        for (self.children.items) |child| {
            cnt += child.trie.scanAllNodes();
        }

        return cnt;
    }

    pub fn countFinalNodes(self: *Trie) usize {
        var cnt: usize = 0;
        if (self.isFinal) {
            cnt += 1;
        }

        for (self.children.items) |child| {
            cnt += child.trie.countFinalNodes();
        }

        return cnt;
    }

    fn getChildPtr(self: *Trie, c: u8) ?*TrieChild {
        for (0..self.children.items.len) |i| {
            if (self.children.items[i].path.items[0] == c) {
                return &self.children.items[i];
            }
        }

        return null;
    }

    fn findChildIndex(self: *Trie, c: u8) ?usize {
        for (0..self.children.items.len) |i| {
            if (self.children.items[i].path.items[0] == c) {
                return i;
            }
        }

        return null;
    }

    fn putChild(self: *Trie, c: u8, child: *Trie) !*TrieChild {
        var path = std.ArrayList(u8).init(self.allocator.*);
        try path.append(c);
        try self.children.append(TrieChild{ .path = path, .trie = child });

        return &self.children.items[self.children.items.len - 1];
    }

    pub fn add(self: *Trie, word: []const u8) !*Trie {
        var node = self;

        var childInProgress: ?*TrieChild = null;
        var pathPos: usize = 0;
        var didIPlaceIt = false;

        var i: i32 = 0;
        while (i < word.len) {
            defer i += 1;

            const c = word[@as(usize, @intCast(i))];

            if (pathPos == 0) {
                if (node.getChildPtr(c)) |child| {
                    pathPos += 1;
                    childInProgress = child;
                    didIPlaceIt = false;
                } else {
                    const newNode = try init(self.allocator);
                    const newChild = try node.putChild(c, newNode);

                    childInProgress = newChild;
                    pathPos = 1;
                    didIPlaceIt = true;
                }
            } else {
                if (pathPos == childInProgress.?.path.items.len) {
                    if (didIPlaceIt) {
                        try childInProgress.?.path.append(c);
                        pathPos += 1;
                    } else {
                        node = childInProgress.?.trie;
                        childInProgress = null;
                        pathPos = 0;

                        // Continue with the same character, but just move one level down
                        i -= 1;
                    }
                } else if (childInProgress.?.path.items[pathPos] == c) {
                    pathPos += 1;
                } else { // We have a mismatch, so we need to split the node
                    var oldPath = try std.ArrayList(u8).initCapacity(
                        self.allocator.*,
                        childInProgress.?.path.items.len - pathPos,
                    );
                    try oldPath.appendSlice(childInProgress.?.path.items[pathPos..]);

                    const commonNode = try initWithChild(self.allocator, TrieChild{
                        .path = oldPath,
                        .trie = childInProgress.?.trie,
                    });

                    childInProgress.?.path.shrinkAndFree(pathPos);
                    childInProgress.?.trie = commonNode;

                    const newNode = try init(self.allocator);
                    const newChild = try commonNode.putChild(c, newNode);

                    node = commonNode;
                    childInProgress = newChild;
                    pathPos = 1;
                    didIPlaceIt = true;
                }
            }
        }

        if (childInProgress) |child| {
            if (pathPos == child.path.items.len) {
                child.trie.isFinal = true;
                return child.trie;
            }

            // Should be a rare case unless we count the cases when an empty folder is first created
            // and then it is extended with a file inside it

            var newNodePath = try std.ArrayList(u8).initCapacity(
                self.allocator.*,
                child.path.items.len - pathPos,
            );
            try newNodePath.appendSlice(child.path.items[pathPos..]);

            const newNode = try initWithChild(self.allocator, TrieChild{
                .path = newNodePath,
                .trie = child.trie,
            });

            child.path.shrinkAndFree(pathPos);
            child.*.trie = newNode;

            newNode.isFinal = true;
            return newNode;
        } else {
            unreachable;
        }

        return node;
    }

    fn queryInternal(self: *Trie, word: []const u8, f: []const usize, matchLen: usize) usize {
        if (matchLen == word.len) {
            return self.countFinalNodes();
        }

        var cnt: usize = 0;
        for (self.children.items) |child| {
            var newMatchLen = matchLen;
            for (child.path.items) |c| {
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

    pub fn deinit(self: *Trie) void {
        for (self.children.items) |child| {
            child.path.deinit();

            child.trie.deinit();
            self.allocator.destroy(child.trie);
        }

        self.children.deinit();
    }
};

pub fn init(allocator: *std.mem.Allocator) !*Trie {
    const t = try allocator.create(Trie);
    t.* = Trie{
        .children = std.ArrayList(TrieChild).init(allocator.*),
        .allocator = allocator,
        .isFinal = false,
    };

    return t;
}

fn initWithChild(allocator: *std.mem.Allocator, child: TrieChild) !*Trie {
    const t = try allocator.create(Trie);
    t.* = Trie{
        .children = std.ArrayList(TrieChild).init(allocator.*),
        .allocator = allocator,
        .isFinal = false,
    };
    try t.children.append(child);

    return t;
}

test "extend string" {
    var allocator = std.heap.page_allocator;
    try std.testing.expect((try extendString(&allocator, "a", 'b')).len == 2);
}

test "single add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("abcd");

    try std.testing.expect(try trie.query("abcd") == 1);
}

test "add that splits" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("abcd");
    _ = try trie.add("abe");

    try std.testing.expect(try trie.query("hello") == 0);
    try std.testing.expect(try trie.query("ab") == 2);
    try std.testing.expect(try trie.query("abcd") == 1);
    try std.testing.expect(try trie.query("abe") == 1);
}

test "add that is a prefix of an existing file" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello");
    _ = try trie.add("hell");

    try std.testing.expect(try trie.query("hello") == 1);
    try std.testing.expect(try trie.query("hell") == 2);
}

test "add a string and then extend it" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hell");
    _ = try trie.add("hello");

    try std.testing.expect(try trie.query("hello") == 1);
    try std.testing.expect(try trie.query("hell") == 2);
}

test "test basic add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello");
    _ = try trie.add("hell");
    _ = try trie.add("heaven");

    try std.testing.expect(try trie.query("he") == 3);
    try std.testing.expect(try trie.query("hell") == 2);
    try std.testing.expect(try trie.query("hello") == 1);
}

pub fn memoryTest1() !void {
    const sz = 1_000_000;
    var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = _gpa.allocator();

    const trie = try init(&allocator);

    var str = try allocator.alloc(u8, sz);
    defer allocator.free(str);
    for (0..sz) |i| {
        str[i] = 'a';
    }

    _ = try trie.add(str);
    std.debug.print("Done", .{});

    while (true) {}
}

pub fn memoryTest2() !void {
    const sz = 100;
    // var _gpa = std.heap.GeneralPurposeAllocator(.{ .page_size = 512 }){};
    var _arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = _arena.allocator();

    const trie = try init(&allocator);

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var str = try allocator.alloc(u8, sz);
    defer allocator.free(str);

    for (0..10_000) |_| {
        for (0..sz) |i| {
            str[i] = rand.int(u8);
        }

        _ = try trie.add(str);
    }

    std.debug.print("Done\n", .{});
    std.debug.print("Node count: {}\n", .{trie.scanAllNodes()});
    std.debug.print("Trie size: {}\n", .{trie.scanSize()});
    std.debug.print("Total char count: {}\n", .{trie.scanTotalCharCount()});

    trie.deinit();
    // allocator.destroy(trie);
    // allocator.free(str);

    // _ = _gpa.detectLeaks();

    while (true) {}
}

pub fn memoryTest3() !void {
    var _gpa = std.heap.GeneralPurposeAllocator(.{ .page_size = 64 * 1024 }){};
    var allocator = _gpa.allocator();

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    for (0..20_000) |_| {
        const str = try allocator.alloc(u8, 100);
        for (0..100) |i| {
            str[i] = rand.int(u8);
        }
    }

    while (true) {}
}
