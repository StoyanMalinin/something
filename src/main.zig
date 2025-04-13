const std = @import("std");

fn walk(dir: *std.fs.Dir, depth: usize) !i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const fileName = entry.name;
        const kind = entry.kind;

        cnt += 1;
        if (kind == std.fs.File.Kind.directory) {
            var subDir: ?std.fs.Dir = dir.openDir(fileName, .{ .iterate = true }) catch |err|
                switch (err) {
                    error.AccessDenied => blk: {
                        break :blk null;
                    },
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close();
                cnt += try walk(&subDir.?, depth + 1);
            }
        }
    }

    return cnt;
}

fn actionIntToString(action: std.os.windows.DWORD) []const u8 {
    switch (action) {
        1 => return "Add",
        2 => return "Remove",
        3 => return "Modify",
        4 => return "Rename (old name)",
        5 => return "Rename (new name)",
        else => unreachable,
    }
}

fn setupWatcher(path: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const windows = std.os.windows;
    const kernel = windows.kernel32;

    const utf16Path = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(utf16Path);

    const handle = kernel.CreateFileW(
        utf16Path,
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return error.UnknownDirectory;
    }
    defer windows.CloseHandle(handle);

    std.debug.print("Starting to watch changes in {s}\n", .{path});

    // The buffer should be big enough, otherwise the events won't be populated
    var buffer: [16 * 1024]u8 align(4) = undefined;
    var bytesReturned: u32 = 0;

    while (true) {
        const result = kernel.ReadDirectoryChangesW(
            handle,
            &buffer,
            buffer.len,
            windows.TRUE,
            .{ .file_name = true, .dir_name = true },
            &bytesReturned,
            null,
            null,
        );
        if (result == 0) {
            return error.OSIssue;
        }
        if (bytesReturned == 0) {
            return error.InsufficientBuffer;
        }

        var offset: usize = 0;
        while (offset < bytesReturned) {
            offset = ((offset + 3) / 4) * 4; // Align to 4 bytes
            const fileNotifyInfo: *windows.FILE_NOTIFY_INFORMATION = @alignCast(@ptrCast(&buffer[offset]));
            offset += @sizeOf(windows.FILE_NOTIFY_INFORMATION);

            const changedFileName: []u8 = @alignCast(buffer[offset .. offset + fileNotifyInfo.FileNameLength]);
            offset += fileNotifyInfo.FileNameLength;

            std.debug.print("Action {s} on file {s}\n", .{ actionIntToString(fileNotifyInfo.Action), changedFileName });
        }
        std.debug.assert(offset == bytesReturned);
    }
}

pub fn main() !void {
    const path = "C:/Users/Znayko/Desktop/test-test";

    try setupWatcher(path);
}
