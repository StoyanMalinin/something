const std = @import("std");
const os = @import("os");

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

fn setupWatcher(path: *const []u8) !void {
    std.os.windows.kernel32.ReadDirectoryChangesW(hDirectory: windows.HANDLE, lpBuffer: [*]align(@alignOf(windows.FILE_NOTIFY_INFORMATION))u8, nBufferLength: windows.DWORD, bWatchSubtree: windows.BOOL, dwNotifyFilter: windows.FileNotifyChangeFilter, lpBytesReturned: ?*windows.DWORD, lpOverlapped: ?*windows.OVERLAPPED, lpCompletionRoutine: windows.LPOVERLAPPED_COMPLETION_ROUTINE)
}

pub fn main() !void {
    const path = "C:/";

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    const startTime: f64 = @floatFromInt(std.time.milliTimestamp());
    const listedFiles = try walk(&dir, 0);
    const endTime: f64 = @floatFromInt(std.time.milliTimestamp());

    std.debug.print("Done listing files in directory: {s}\n", .{path});
    std.debug.print("Total files listed: {d}\n", .{listedFiles});
    std.debug.print("Time taken: {d} s\n", .{(endTime - startTime) / 1000.0});
}
