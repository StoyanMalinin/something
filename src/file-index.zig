const std = @import("std");
const trie = @import("trie.zig");
const vanilla = @import("vanilla-trie.zig");
const fuzzy = @import("fuzzy.zig");

pub const Position = trie.Index;

pub const SearchOptions = struct {
    limit: usize = 50,
    includeDirs: bool = true,
};

pub const SearchResult = struct {
    score: i32,
    path: []u8,
};

pub fn freeSearchResults(allocator: std.mem.Allocator, results: []SearchResult) void {
    for (results) |r| allocator.free(r.path);
    allocator.free(results);
}

const separator = '/';
const KeyBuf = [std.Io.Dir.max_path_bytes + 1]u8;

pub const FileIndex = struct {
    io: std.Io,
    mut: std.Io.Mutex,
    trie: trie.Trie,
    limits: trie.Limits,
    /// While building in bulk (`beginBulk`), adds go here instead of `trie`.
    bulk: ?vanilla.Trie = null,
    allocator: std.mem.Allocator,

    pub fn rootPosition(_: *FileIndex) Position {
        return .root;
    }

    pub fn deinit(self: *FileIndex) void {
        if (self.bulk) |*b| b.deinit();
        self.trie.deinit();
        self.allocator.destroy(self);
    }

    /// Starts building in bulk: adds go to a plain trie whose positions never
    /// move, so walker threads can hold them across adds, until `endBulk`
    /// packs it into the search trie. The index must be empty. Only adds (and
    /// `refreshMasks`, which does nothing until then) are allowed in between.
    pub fn beginBulk(self: *FileIndex) !void {
        std.debug.assert(self.bulk == null and self.trie.countFinalNodes() == 0);
        // Straight from the OS, so freeing it in `endBulk` gives the pages
        // back: malloc may keep large freed blocks cached
        self.bulk = try vanilla.Trie.init(std.heap.page_allocator);
    }

    /// Packs what was added since `beginBulk` into the search trie, with
    /// every search mask computed. Positions from the bulk phase are void.
    pub fn endBulk(self: *FileIndex) !void {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        var b = self.bulk.?;
        const packed_trie = try trie.Trie.fromVanilla(self.allocator, self.limits, &b);
        self.trie.deinit();
        self.trie = packed_trie;
        b.deinit();
        self.bulk = null;
    }

    fn entryKey(name: []const u8, isDir: bool, buf: *KeyBuf) ![]const u8 {
        if (!isDir or std.mem.endsWith(u8, name, "/")) {
            return name;
        }
        if (name.len + 1 > buf.len) {
            return error.NameTooLong;
        }

        @memcpy(buf[0..name.len], name);
        buf[name.len] = separator;
        return buf[0 .. name.len + 1];
    }

    /// Adding below a position other than the root leaves the search masks
    /// above that position stale: call `refreshMasks` once done (see `trie.Trie.sub`).
    ///
    /// `position` must be the root or a folder's. Returns a folder's
    /// position. In bulk it stays valid; otherwise only until the folder's
    /// parent changes (adding below the folder is fine; see `trie.Trie`).
    /// Files have no use for theirs.
    pub fn addFileName(self: *FileIndex, position: Position, name: []const u8, isDir: bool) !Position {
        var buf: KeyBuf = undefined;
        const key = try entryKey(name, isDir, &buf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        if (self.bulk) |*b| {
            const at = try b.add(@enumFromInt(@intFromEnum(position)), key);
            return @enumFromInt(@intFromEnum(at));
        }
        return self.trie.add(position, key);
    }

    /// After adding entries below `position`, the folder `name` from the root:
    /// brings the search masks of its subtree and the folders above it up to date.
    pub fn refreshMasks(self: *FileIndex, position: Position, name: []const u8) !void {
        var buf: KeyBuf = undefined;
        const key = try entryKey(name, true, &buf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        // In bulk, `endBulk` computes every mask
        if (self.bulk != null) return;
        self.trie.refreshMasks(.root, key, position);
    }

    pub fn query(self: *FileIndex, name: []const u8) !usize {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        return self.trie.query(name);
    }

    pub fn search(
        self: *FileIndex,
        allocator: std.mem.Allocator,
        text: []const u8,
        options: SearchOptions,
    ) ![]SearchResult {
        const matcher = try fuzzy.Matcher.init(text, .{});

        const buf = try allocator.alloc(fuzzy.TopK([]u8).Entry, options.limit);
        defer allocator.free(buf);
        var top = fuzzy.TopK([]u8).init(buf);
        errdefer for (top.items()) |e| allocator.free(e.item);

        {
            self.mut.lockUncancelable(self.io);
            defer self.mut.unlock(self.io);

            try self.trie.fuzzySearch(&matcher, &top, allocator, options.includeDirs);
        }

        const results = try allocator.alloc(SearchResult, top.len);
        for (top.items(), results) |e, *r| {
            r.* = .{ .score = e.score, .path = e.item };
        }
        return results;
    }

    pub fn removeFileName(self: *FileIndex, position: Position, name: []const u8, isDir: bool) !bool {
        var buf: KeyBuf = undefined;
        const key = try entryKey(name, isDir, &buf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        if (isDir) {
            std.debug.assert(std.mem.endsWith(u8, key, "/"));
            const removed = self.trie.removeRecursive(position, key) orelse return false;
            self.trie.freeDetached(removed);
            return true;
        }

        return self.trie.removeSingle(position, key);
    }

    pub fn moveOrdinaryFile(
        self: *FileIndex,
        fromPosition: Position,
        fromName: []const u8,
        toPosition: Position,
        toName: []const u8,
    ) !bool {
        var fromBuf: KeyBuf = undefined;
        var toBuf: KeyBuf = undefined;
        const fromKey = try entryKey(fromName, false, &fromBuf);
        const toKey = try entryKey(toName, false, &toBuf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        if (!self.trie.removeSingle(fromPosition, fromKey)) {
            return false;
        }

        _ = try self.trie.add(toPosition, toKey);
        return true;
    }

    pub fn moveFolder(
        self: *FileIndex,
        fromPosition: Position,
        fromName: []const u8,
        toPosition: Position,
        toName: []const u8,
    ) !bool {
        var fromBuf: KeyBuf = undefined;
        var toBuf: KeyBuf = undefined;
        const fromKey = try entryKey(fromName, true, &fromBuf);
        const toKey = try entryKey(toName, true, &toBuf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        // An existing folder at the destination is replaced
        return self.trie.moveFolder(fromPosition, fromKey, toPosition, toKey);
    }
};

/// `limits` bounds the trie; its storage is reserved up front (see `trie.Limits`).
pub fn init(allocator: std.mem.Allocator, io: std.Io, limits: trie.Limits) !*FileIndex {
    const t = try allocator.create(FileIndex);
    errdefer allocator.destroy(t);
    t.* = FileIndex{
        .trie = try trie.Trie.init(allocator, limits),
        .limits = limits,
        .io = io,
        .mut = .init,
        .allocator = allocator,
    };

    return t;
}

test "siblings that share a prefix do not collide" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    // /r/, /r/foo/, /r/foo/bar and /r/foobar
    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const foo = try index.addFileName(root, "foo", true);
    _ = try index.addFileName(foo, "bar", false);
    _ = try index.addFileName(root, "foobar", false);

    try std.testing.expectEqual(1, try index.query("foobar"));
    try std.testing.expectEqual(1, try index.query("foo/bar"));
}

test "a root that already ends with a slash is not doubled" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    const root = try index.addFileName(index.rootPosition(), "/", true);
    const etc = try index.addFileName(root, "etc", true);
    _ = try index.addFileName(etc, "hosts", false);

    try std.testing.expectEqual(0, try index.query("//"));
    try std.testing.expectEqual(1, try index.query("/etc/hosts"));
}

test "removing a directory takes its contents but not its siblings" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const foo = try index.addFileName(root, "foo", true);
    _ = try index.addFileName(foo, "baz", false);
    const q = try index.addFileName(root, "q", true);
    _ = try index.addFileName(q, "x", false);
    _ = try index.addFileName(root, "foobar", false);

    // With and without the trailing slash
    try std.testing.expectEqual(true, try index.removeFileName(root, "foo", true));
    try std.testing.expectEqual(true, try index.removeFileName(root, "q/", true));
    try std.testing.expectEqual(2, index.trie.countFinalNodes());
    try std.testing.expectEqual(0, try index.query("baz"));
    try std.testing.expectEqual(0, try index.query("x"));
    try std.testing.expectEqual(1, try index.query("foobar"));

    // Already gone, and never there
    try std.testing.expectEqual(false, try index.removeFileName(root, "foo", true));
    try std.testing.expectEqual(false, try index.removeFileName(root, "nope", true));
}

test "a file and a directory with the same name are removed separately" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const file = try index.addFileName(root, "foo", false);
    const dir = try index.addFileName(root, "foo", true);
    _ = try index.addFileName(dir, "a", false);

    try std.testing.expect(file != dir);

    try std.testing.expectEqual(true, try index.removeFileName(root, "foo", false));
    try std.testing.expectEqual(1, try index.query("foo/a"));
    try std.testing.expectEqual(false, try index.removeFileName(root, "foo", false));

    try std.testing.expectEqual(true, try index.removeFileName(root, "foo", true));
    try std.testing.expectEqual(1, index.trie.countFinalNodes());
}

test "moving an ordinary file" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const a = try index.addFileName(root, "a", true);
    const b = try index.addFileName(root, "b", true);
    _ = try index.addFileName(a, "x.txt", false);
    _ = try index.addFileName(b, "y.txt", false);

    // Into another directory, under a new name
    try std.testing.expectEqual(true, try index.moveOrdinaryFile(a, "x.txt", b, "z.txt"));
    try std.testing.expectEqual(0, try index.query("x.txt"));
    try std.testing.expectEqual(1, try index.query("b/z.txt"));
    try std.testing.expectEqual(5, index.trie.countFinalNodes()); // /r/, a/, b/, y.txt, z.txt

    // Over an existing file
    try std.testing.expectEqual(true, try index.moveOrdinaryFile(b, "z.txt", b, "y.txt"));
    try std.testing.expectEqual(0, try index.query("z.txt"));
    try std.testing.expectEqual(4, index.trie.countFinalNodes());

    // A missing source changes nothing
    try std.testing.expectEqual(false, try index.moveOrdinaryFile(a, "nope", b, "n.txt"));
    try std.testing.expectEqual(0, try index.query("n.txt"));
    try std.testing.expectEqual(4, index.trie.countFinalNodes());
}

test "moving a folder" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    // /r/ with a/b/f.txt, a sibling file a.txt and an empty folder d/
    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const a = try index.addFileName(root, "a", true);
    const b = try index.addFileName(a, "b", true);
    _ = try index.addFileName(b, "f.txt", false);
    _ = try index.addFileName(root, "a.txt", false);
    const d = try index.addFileName(root, "d", true);

    // Into another folder, under a new name, without touching the sibling that shares its prefix
    try std.testing.expectEqual(true, try index.moveFolder(root, "a", d, "z"));
    try std.testing.expectEqual(0, try index.query("a/b"));
    try std.testing.expectEqual(1, try index.query("d/z/b/f.txt"));
    try std.testing.expectEqual(1, try index.query("a.txt"));
    try std.testing.expectEqual(6, index.trie.countFinalNodes());
    // Positions below the moved folder are still the same nodes
    try std.testing.expect(index.trie.isFinal(b));
    try std.testing.expectEqual(1, try index.query("b/f.txt"));

    // A rename inside the same folder
    try std.testing.expectEqual(true, try index.moveFolder(root, "d", root, "e"));
    try std.testing.expectEqual(1, try index.query("e/z/b/f.txt"));
    try std.testing.expectEqual(0, try index.query("d/"));
    try std.testing.expectEqual(6, index.trie.countFinalNodes());

    // A missing source, and a file, are not folders
    try std.testing.expectEqual(false, try index.moveFolder(root, "nope", root, "n"));
    try std.testing.expectEqual(false, try index.moveFolder(root, "a.txt", root, "n"));
    try std.testing.expectEqual(0, try index.query("n/"));
    try std.testing.expectEqual(6, index.trie.countFinalNodes());
}

test "removed and moved folders are freed" {
    const index = try init(std.testing.allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const a = try index.addFileName(root, "a", true);
    const b = try index.addFileName(a, "b", true);
    _ = try index.addFileName(b, "f.txt", false);
    const d = try index.addFileName(root, "d", true);
    _ = try index.addFileName(d, "old.txt", false);
    const e = try index.addFileName(root, "e", true);
    _ = try index.addFileName(e, "g.txt", false);
    // As the walker does once done, since these adds were below `root`
    try index.refreshMasks(root, "/r");

    // Onto a folder that already has content: what was there is freed
    try std.testing.expectEqual(true, try index.moveFolder(root, "a", root, "d"));
    try std.testing.expectEqual(0, try index.query("old.txt"));
    try std.testing.expectEqual(1, try index.query("d/b/f.txt"));

    // The moved contents' bytes are now covered by the destination's masks
    try std.testing.expect(index.trie.masksAreConsistent());
    const found = try index.search(std.heap.page_allocator, "dbftxt", .{});
    defer freeSearchResults(std.heap.page_allocator, found);
    try std.testing.expectEqualStrings("/r/d/b/f.txt", found[0].path);

    try std.testing.expectEqual(true, try index.removeFileName(root, "d", true));
    try std.testing.expectEqual(true, try index.removeFileName(root, "e", true));
    try std.testing.expectEqual(1, index.trie.countFinalNodes());
}

fn buildSearchFixture(index: *FileIndex) !void {
    // /p/ with src/{main,trie,file-index,watcher}.zig, build.zig, docs/, docs/notes.md
    const root = try index.addFileName(index.rootPosition(), "/p", true);
    const src = try index.addFileName(root, "src", true);
    _ = try index.addFileName(src, "main.zig", false);
    _ = try index.addFileName(src, "trie.zig", false);
    _ = try index.addFileName(src, "file-index.zig", false);
    _ = try index.addFileName(src, "watcher.zig", false);
    _ = try index.addFileName(root, "build.zig", false);
    const docs = try index.addFileName(root, "docs", true);
    _ = try index.addFileName(docs, "notes.md", false);
    // As the walker does once done, since these adds were below `root`
    try index.refreshMasks(root, "/p");
}

test "fuzzy search ranks full paths, best first" {
    const allocator = std.testing.allocator;
    const index = try init(allocator, std.testing.io, trie.test_limits);
    defer index.deinit();
    try buildSearchFixture(index);

    // Every entry gets a score; the real match leads
    const results = try index.search(allocator, "fidx", .{});
    defer freeSearchResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 9), results.len);
    try std.testing.expectEqualStrings("/p/src/file-index.zig", results[0].path);

    const mains = try index.search(allocator, "main", .{});
    defer freeSearchResults(allocator, mains);
    try std.testing.expect(mains.len >= 1);
    try std.testing.expectEqualStrings("/p/src/main.zig", mains[0].path);

    // Nothing in common still ranks something: the best of the typo matches
    const none = try index.search(allocator, "qqq", .{ .limit = 2 });
    defer freeSearchResults(allocator, none);
    try std.testing.expectEqual(@as(usize, 2), none.len);
    try std.testing.expect(none[0].score < mains[0].score);
}

test "fuzzy search respects the limit and can leave out directories" {
    const allocator = std.testing.allocator;
    const index = try init(allocator, std.testing.io, trie.test_limits);
    defer index.deinit();
    try buildSearchFixture(index);

    // Empty query matches every entry: /p/, src/, docs/ and 6 files
    const all = try index.search(allocator, "", .{ .limit = 100 });
    defer freeSearchResults(allocator, all);
    try std.testing.expectEqual(@as(usize, 9), all.len);

    const files = try index.search(allocator, "", .{ .limit = 100, .includeDirs = false });
    defer freeSearchResults(allocator, files);
    try std.testing.expectEqual(@as(usize, 6), files.len);
    for (files) |r| try std.testing.expect(!std.mem.endsWith(u8, r.path, "/"));

    const two = try index.search(allocator, "zig", .{ .limit = 2 });
    defer freeSearchResults(allocator, two);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expect(two[0].score >= two[1].score);

    const dirs = try index.search(allocator, "docs", .{});
    defer freeSearchResults(allocator, dirs);
    try std.testing.expectEqualStrings("/p/docs/", dirs[0].path);
}

test "fuzzy search over the trie matches scoring each path on its own" {
    const allocator = std.testing.allocator;
    const index = try init(allocator, std.testing.io, trie.test_limits);
    defer index.deinit();
    try buildSearchFixture(index);

    const all = try index.search(allocator, "", .{ .limit = 100 });
    defer freeSearchResults(allocator, all);

    for ([_][]const u8{ "zig", "src", "tz", "pn", "w", "/" }) |q| {
        const m = try fuzzy.Matcher.init(q, .{});

        // Best scores by scoring every path in one go
        var expected: [16]i32 = undefined;
        var n: usize = 0;
        for (all) |r| {
            if (m.score(r.path)) |s| {
                expected[n] = s;
                n += 1;
            }
        }
        std.mem.sort(i32, expected[0..n], {}, std.sort.desc(i32));

        const got = try index.search(allocator, q, .{ .limit = 3 });
        defer freeSearchResults(allocator, got);
        try std.testing.expectEqual(@min(n, 3), got.len);
        for (got, 0..) |r, i| {
            try std.testing.expectEqual(m.score(r.path).?, r.score);
            try std.testing.expectEqual(expected[i], r.score);
        }
    }
}

test "a directory comes before its own contents when the query names it" {
    const allocator = std.testing.allocator;
    const index = try init(allocator, std.testing.io, trie.test_limits);
    defer index.deinit();
    try buildSearchFixture(index);

    for ([_][]const u8{ "src/", "src" }) |q| {
        const results = try index.search(allocator, q, .{ .limit = 3 });
        defer freeSearchResults(allocator, results);
        try std.testing.expectEqualStrings("/p/src/", results[0].path);
    }
}

test "pruned search returns the same top results as scoring every path" {
    const allocator = std.testing.allocator;
    const index = try init(allocator, std.testing.io, trie.test_limits);
    defer index.deinit();

    // Random folders and files over a small alphabet, so names share prefixes
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const alphabet = "abcdmainzgtrx._-";
    const root = try index.addFileName(index.rootPosition(), "/r", true);
    for (0..400) |_| {
        var buf: [40]u8 = undefined;
        var len: usize = 0;
        const parts = rnd.intRangeAtMost(usize, 1, 4);
        for (0..parts) |p| {
            if (p > 0) {
                buf[len] = '/';
                len += 1;
            }
            for (0..rnd.intRangeAtMost(usize, 1, 6)) |_| {
                buf[len] = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                len += 1;
            }
        }
        _ = try index.addFileName(root, buf[0..len], false);
    }
    const everything = try index.search(allocator, "", .{ .limit = 10_000 });
    defer freeSearchResults(allocator, everything);

    for ([_][]const u8{ "a", "ma", "main", "mxin", "zig", "trie", "abc", "x.z", "dmain", "qqqq" }) |q| {
        for ([_]usize{ 1, 5, 20 }) |limit| {
            const got = try index.search(allocator, q, .{ .limit = limit });
            defer freeSearchResults(allocator, got);

            // Ties may be ordered differently, but (score, length) pairs may not
            const m = try fuzzy.Matcher.init(q, .{});
            const buf = try allocator.alloc(fuzzy.TopK(void).Entry, limit);
            defer allocator.free(buf);
            var top = fuzzy.TopK(void).init(buf);
            for (everything) |e| {
                if (m.score(e.path)) |sc| _ = top.push(sc, @intCast(e.path.len), {});
            }

            try std.testing.expectEqual(top.items().len, got.len);
            for (top.items(), got) |want, g| {
                try std.testing.expectEqual(want.score, g.score);
                try std.testing.expectEqual(want.tiebreak, @as(u32, @intCast(g.path.len)));
            }
        }
    }
}
