const std = @import("std");
const trie = @import("trie.zig");

pub const Position = *trie.Trie;

const separator = '/';
const KeyBuf = [std.Io.Dir.max_path_bytes + 1]u8;

pub const FileIndex = struct {
    io: std.Io,
    mut: std.Io.Mutex,
    trie: *trie.Trie,
    allocator: *std.mem.Allocator,
    stringAllocator: *std.mem.Allocator,

    pub fn rootPosition(self: *FileIndex) *trie.Trie {
        return self.trie;
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

    pub fn addFileName(self: *FileIndex, position: *trie.Trie, name: []const u8, isDir: bool) !*trie.Trie {
        var buf: KeyBuf = undefined;
        const key = try entryKey(name, isDir, &buf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        return position.add(key, self.allocator, self.stringAllocator);
    }

    pub fn query(self: *FileIndex, name: []const u8) !usize {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        return self.trie.query(name, self.allocator);
    }

    pub fn removeFileName(self: *FileIndex, position: *trie.Trie, name: []const u8, isDir: bool) !bool {
        var buf: KeyBuf = undefined;
        const key = try entryKey(name, isDir, &buf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        if (isDir) {
            std.debug.assert(std.mem.endsWith(u8, key, "/"));
            const removed = position.removeRecursive(key, self.allocator) orelse return false;
            removed.destroy(self.allocator);
            return true;
        }

        return position.removeSingle(key) != null;
    }

    pub fn moveOrdinaryFile(
        self: *FileIndex,
        fromPosition: *trie.Trie,
        fromName: []const u8,
        toPosition: *trie.Trie,
        toName: []const u8,
    ) !bool {
        var fromBuf: KeyBuf = undefined;
        var toBuf: KeyBuf = undefined;
        const fromKey = try entryKey(fromName, false, &fromBuf);
        const toKey = try entryKey(toName, false, &toBuf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        if (fromPosition.removeSingle(fromKey) == null) {
            return false;
        }

        _ = try toPosition.add(toKey, self.allocator, self.stringAllocator);
        return true;
    }

    pub fn moveFolder(
        self: *FileIndex,
        fromPosition: *trie.Trie,
        fromName: []const u8,
        toPosition: *trie.Trie,
        toName: []const u8,
    ) !bool {
        var fromBuf: KeyBuf = undefined;
        var toBuf: KeyBuf = undefined;
        const fromKey = try entryKey(fromName, true, &fromBuf);
        const toKey = try entryKey(toName, true, &toBuf);

        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        const old = fromPosition.removeRecursive(fromKey, self.allocator) orelse return false;
        errdefer old.destroy(self.allocator);
        const moved = try toPosition.add(toKey, self.allocator, self.stringAllocator);

        // An existing folder at the destination is replaced
        moved.destroyChildren(self.allocator);
        moved.children = old.children;
        self.allocator.destroy(old);
        return true;
    }
};

pub fn init(allocator: *std.mem.Allocator, stringAllocator: *std.mem.Allocator, io: std.Io) !*FileIndex {
    const t = try allocator.create(FileIndex);
    t.* = FileIndex{
        .trie = try trie.init(allocator),
        .io = io,
        .mut = .init,
        .allocator = allocator,
        .stringAllocator = stringAllocator,
    };

    return t;
}

test "siblings that share a prefix do not collide" {
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

    // /r/, /r/foo/, /r/foo/bar and /r/foobar
    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const foo = try index.addFileName(root, "foo", true);
    const fooBar = try index.addFileName(foo, "bar", false);
    const foobar = try index.addFileName(root, "foobar", false);

    try std.testing.expect(fooBar != foobar);
    try std.testing.expectEqual(1, try index.query("foobar"));
    try std.testing.expectEqual(1, try index.query("foo/bar"));
}

test "a root that already ends with a slash is not doubled" {
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

    const root = try index.addFileName(index.rootPosition(), "/", true);
    const etc = try index.addFileName(root, "etc", true);
    _ = try index.addFileName(etc, "hosts", false);

    try std.testing.expectEqual(0, try index.query("//"));
    try std.testing.expectEqual(1, try index.query("/etc/hosts"));
}

test "removing a directory takes its contents but not its siblings" {
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

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
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

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
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

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
    var allocator = std.heap.page_allocator;
    const index = try init(&allocator, &allocator, std.testing.io);

    // /r/ with a/b/f.txt, a sibling file a.txt and an empty folder d/
    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const a = try index.addFileName(root, "a", true);
    const b = try index.addFileName(a, "b", true);
    const f = try index.addFileName(b, "f.txt", false);
    _ = try index.addFileName(root, "a.txt", false);
    const d = try index.addFileName(root, "d", true);

    // Into another folder, under a new name, without touching the sibling that shares its prefix
    try std.testing.expectEqual(true, try index.moveFolder(root, "a", d, "z"));
    try std.testing.expectEqual(0, try index.query("a/b"));
    try std.testing.expectEqual(1, try index.query("d/z/b/f.txt"));
    try std.testing.expectEqual(1, try index.query("a.txt"));
    try std.testing.expectEqual(6, index.trie.countFinalNodes());
    // Positions below the moved folder are still the same nodes
    try std.testing.expect(b.isFinal and f.isFinal);

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
    // Fails the test on a leak. The strings are never freed one by one, so they get an arena.
    var allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var strings = arena.allocator();

    const index = try init(&allocator, &strings, std.testing.io);
    defer allocator.destroy(index);
    defer index.trie.destroy(&allocator);

    const root = try index.addFileName(index.rootPosition(), "/r", true);
    const a = try index.addFileName(root, "a", true);
    const b = try index.addFileName(a, "b", true);
    _ = try index.addFileName(b, "f.txt", false);
    const d = try index.addFileName(root, "d", true);
    _ = try index.addFileName(d, "old.txt", false);
    const e = try index.addFileName(root, "e", true);
    _ = try index.addFileName(e, "g.txt", false);

    // Onto a folder that already has content: what was there is freed
    try std.testing.expectEqual(true, try index.moveFolder(root, "a", root, "d"));
    try std.testing.expectEqual(0, try index.query("old.txt"));
    try std.testing.expectEqual(1, try index.query("d/b/f.txt"));

    try std.testing.expectEqual(true, try index.removeFileName(root, "d", true));
    try std.testing.expectEqual(true, try index.removeFileName(root, "e", true));
    try std.testing.expectEqual(1, index.trie.countFinalNodes());
}
