const std = @import("std");
const trie = @import("trie.zig");

const FileData = struct {}; // TODO: add some data

pub const FileIndex = struct {
    mut: std.Thread.Mutex,
    files: std.StringHashMap(FileData),

    pub fn addFileName(self: *FileIndex, name: []const u8) !void {
        self.mut.lock();
        defer self.mut.unlock();

        if (!self.files.contains(name)) {
            const fileData = FileData{};
            try self.files.put(name, fileData);
        }
    }

    pub fn removeFileName(self: *FileIndex, name: []const u8) !void {
        self.mut.lock();
        defer self.mut.unlock();

        _ = self.files.remove(name);
    }

    pub fn query(self: *FileIndex, name: []const u8) !usize {
        self.mut.lock();
        defer self.mut.unlock();

        var f = try std.heap.page_allocator.alloc(usize, name.len);
        defer std.heap.page_allocator.free(f);

        f[0] = 0;
        for (1..name.len) |i| {
            var j = f[i - 1];
            while (j > 0 and name[i] != name[j]) {
                j = f[j - 1];
            }
            if (name[i] == name[j]) {
                j += 1;
            }

            f[i] = j;
        }

        var cnt: usize = 0;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            var matchLen: usize = 0;
            const fileName = entry.key_ptr.*;
            for (0..fileName.len) |i| {
                while (matchLen > 0 and fileName[i] != name[matchLen]) {
                    matchLen = f[matchLen - 1];
                }
                if (fileName[i] == name[matchLen]) {
                    matchLen += 1;
                }

                if (matchLen == name.len) {
                    cnt += 1;
                    break;
                }
            }
        }

        return cnt;
    }
};

pub fn init() !*FileIndex {
    const t = try std.heap.page_allocator.create(FileIndex);
    t.* = FileIndex{
        .files = std.StringHashMap(FileData).init(std.heap.page_allocator),
        .mut = std.Thread.Mutex{},
    };

    return t;
}
