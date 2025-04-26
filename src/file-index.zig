const std = @import("std");
const trie = @import("trie.zig");

pub const Position = *trie.Trie;

pub const FileIndex = struct {
    mut: std.Thread.Mutex,
    trie: *trie.Trie,
    allocator: *std.mem.Allocator,
    stringAllocator: *std.mem.Allocator,

    pub fn rootPosition(self: *FileIndex) *trie.Trie {
        return self.trie;
    }

    pub fn addFileName(self: *FileIndex, position: *trie.Trie, name: []const u8) !*trie.Trie {
        self.mut.lock();
        defer self.mut.unlock();

        return position.add(name, self.allocator, self.stringAllocator);
    }

    pub fn query(self: *FileIndex, name: []const u8) !usize {
        self.mut.lock();
        defer self.mut.unlock();

        return self.trie.query(name, self.allocator);
    }

    pub fn removeFileName(self: *FileIndex, name: []const u8) !void {
        self.mut.lock();
        defer self.mut.unlock();

        try self.trie.remove(name, self.allocator);
    }
};

pub fn init(allocator: *std.mem.Allocator, stringAllocator: *std.mem.Allocator) !*FileIndex {
    const t = try allocator.create(FileIndex);
    t.* = FileIndex{
        .trie = try trie.init(allocator),
        .mut = std.Thread.Mutex{},
        .allocator = allocator,
        .stringAllocator = stringAllocator,
    };

    return t;
}
