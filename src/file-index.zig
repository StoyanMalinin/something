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
            return position.removeRecursive(key) != null;
        }

        return position.removeSingle(key) != null;
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
