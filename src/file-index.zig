const std = @import("std");
const trie = @import("trie.zig");

pub const Position = *trie.Trie;

pub const FileIndex = struct {
    io: std.Io,
    mut: std.Io.Mutex,
    trie: *trie.Trie,
    allocator: *std.mem.Allocator,
    stringAllocator: *std.mem.Allocator,

    pub fn rootPosition(self: *FileIndex) *trie.Trie {
        return self.trie;
    }

    pub fn addFileName(self: *FileIndex, position: *trie.Trie, name: []const u8) !*trie.Trie {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        return position.add(name, self.allocator, self.stringAllocator);
    }

    pub fn query(self: *FileIndex, name: []const u8) !usize {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        return self.trie.query(name, self.allocator);
    }

    pub fn removeFileName(self: *FileIndex, name: []const u8) !void {
        self.mut.lockUncancelable(self.io);
        defer self.mut.unlock(self.io);

        try self.trie.remove(name, self.allocator);
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
