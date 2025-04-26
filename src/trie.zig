const std = @import("std");

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

    pub fn add(self: *Trie, word: []const u8, allocator: *std.mem.Allocator, stringAllocator: *std.mem.Allocator) !*Trie {
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
                    didIPlaceIt = true;

                    i = @as(i32, @intCast(word.len)) - 1;
                    break;
                }
            } else {
                if (pathPos == childInProgress.?.path.len) {
                    if (didIPlaceIt) {
                        unreachable;
                    } else {
                        node = childInProgress.?.trie;
                        childInProgress = null;
                        pathPos = 0;

                        // Continue with the same character, but just move one level down
                        i -= 1;
                    }
                } else if (childInProgress.?.path[pathPos] == c) {
                    pathPos += 1;
                } else { // We have a mismatch, so we need to split the node
                    const commonNodeChild = try allocator.create(TrieChild);
                    commonNodeChild.* = TrieChild{
                        .path = childInProgress.?.path[pathPos..],
                        .trie = childInProgress.?.trie,
                    };
                    const commonNode = try initWithChild(allocator, commonNodeChild);

                    childInProgress.?.path = childInProgress.?.path[0..pathPos];
                    childInProgress.?.trie = commonNode;

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
                    didIPlaceIt = true;

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

            // Should be a rare case unless we count the cases when an empty folder is first created
            // and then it is extended with a file inside it

            const newChild = try allocator.create(TrieChild);
            newChild.* = TrieChild{
                .path = child.path[pathPos..],
                .trie = child.trie,
            };
            const newNode = try initWithChild(allocator, newChild);

            child.path = child.path[0..pathPos];
            child.trie = newNode;

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

    pub fn deinit(_: *Trie) void {
        // for (self.children.items) |child| {
        //     // child.path.deinit();

        //     // child.trie.deinit();
        //     // allocator.destroy(child.trie);
        // }

        // self.children.deinit();
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

    try std.testing.expect(try trie.query("abcd", &allocator) == 1);
}

test "add that splits" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("abcd", &allocator, &allocator);
    _ = try trie.add("abe", &allocator, &allocator);

    try std.testing.expect(try trie.query("hello", &allocator) == 0);
    try std.testing.expect(try trie.query("ab", &allocator) == 2);
    try std.testing.expect(try trie.query("abcd", &allocator) == 1);
    try std.testing.expect(try trie.query("abe", &allocator) == 1);
}

test "add that is a prefix of an existing file" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);

    try std.testing.expect(try trie.query("hello", &allocator) == 1);
    try std.testing.expect(try trie.query("hell", &allocator) == 2);
}

test "add a string and then extend it" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("hello", &allocator, &allocator);

    try std.testing.expect(try trie.query("hello", &allocator) == 1);
    try std.testing.expect(try trie.query("hell", &allocator) == 2);
}

test "test basic add" {
    var allocator = std.heap.page_allocator;
    const trie = try init(&allocator);
    defer allocator.destroy(trie);

    _ = try trie.add("hello", &allocator, &allocator);
    _ = try trie.add("hell", &allocator, &allocator);
    _ = try trie.add("heaven", &allocator, &allocator);

    try std.testing.expect(try trie.query("he", &allocator) == 3);
    try std.testing.expect(try trie.query("hell", &allocator) == 2);
    try std.testing.expect(try trie.query("hello", &allocator) == 1);
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
