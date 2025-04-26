const std = @import("std");
const fileIndex = @import("file-index.zig");
const trie = @import("trie.zig");

var index: *fileIndex.FileIndex = undefined;

fn walkSingleThreaded(dir: *std.fs.Dir, position: fileIndex.Position, depth: usize) !i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const subPosition = try index.addFileName(position, entry.name);

        if (entry.kind == std.fs.File.Kind.directory) {
            var subDir: ?std.fs.Dir = dir.openDir(entry.name, .{ .iterate = true, .no_follow = false }) catch |err|
                switch (err) {
                    error.AccessDenied => null,
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close();
                cnt += try walkSingleThreaded(&subDir.?, subPosition, depth + 1);
            }
        } else {
            cnt += 1;
        }
    }

    return cnt;
}

const MyDir = struct {
    dir: *?std.fs.Dir,
    stat: std.fs.Dir.Stat,
    depth: usize,
    position: fileIndex.Position,
};

fn compareDir(_: void, a: MyDir, b: MyDir) std.math.Order {
    if (a.stat.size > b.stat.size) {
        return std.math.Order.lt;
    } else if (a.stat.size < b.stat.size) {
        return std.math.Order.gt;
    }

    return std.math.Order.eq;
}

fn walkWrapper(dir: *?std.fs.Dir, position: fileIndex.Position, depth: usize, wg: *std.Thread.WaitGroup, mut: *std.Thread.Mutex, cnt: *i32) void {
    defer wg.*.finish();
    defer gpa.destroy(dir);
    defer dir.*.?.close();

    const currCnt = walkSingleThreaded(&dir.*.?, position, depth) catch |walkErr| blk: {
        std.debug.print("Error: {any}\n", .{walkErr});
        break :blk 0;
    };

    mut.*.lock();
    cnt.* += currCnt;
    mut.*.unlock();
}

fn walk(path: []const u8) !i32 {
    var threadPool: std.Thread.Pool = undefined;
    try threadPool.init(std.Thread.Pool.Options{
        .n_jobs = 10,
        .allocator = gpa,
    });
    defer threadPool.deinit();

    var pq = std.PriorityQueue(
        MyDir,
        void,
        compareDir,
    ).init(gpa, void{});
    defer pq.deinit();

    const dir = try gpa.create(?std.fs.Dir);
    dir.* = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = false });

    const pathPosition = try index.addFileName(index.rootPosition(), path);
    try pq.add(MyDir{ .dir = dir, .stat = try dir.*.?.stat(), .depth = 0, .position = pathPosition });

    var cnt: i32 = 0;
    var mutex = std.Thread.Mutex{};

    var explored: usize = 0;
    while (explored + pq.count() < 1000 and pq.count() > 0) {
        explored += 1;

        const item: MyDir = pq.remove();
        defer gpa.destroy(item.dir);
        defer item.dir.*.?.close();

        const position = item.position;

        var it = item.dir.*.?.iterate();
        while (try it.next()) |entry| {
            const subPosition = try index.addFileName(position, entry.name);

            if (entry.kind == std.fs.File.Kind.directory) {
                const subDir = try gpa.create(?std.fs.Dir);
                subDir.* = item.dir.*.?.openDir(entry.name, .{ .iterate = true, .no_follow = false }) catch |err|
                    switch (err) {
                        error.AccessDenied => null,
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir.* != null) {
                    try pq.add(MyDir{
                        .dir = subDir,
                        .stat = try subDir.*.?.stat(),
                        .depth = item.depth + 1,
                        .position = subPosition,
                    });
                }
            } else {
                cnt += 1;
            }
        }
    }

    var wg: std.Thread.WaitGroup = std.Thread.WaitGroup{};
    wg.reset();

    while (pq.count() > 0) {
        const item = pq.remove();

        wg.start();
        try threadPool.spawn(walkWrapper, .{
            item.dir,
            item.position,
            item.depth + 1,
            &wg,
            &mutex,
            &cnt,
        });
    }

    wg.wait();

    return cnt;
}

var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
var gpa = _gpa.allocator();
const WalkErrorType = std.fs.Dir.OpenError || std.Thread.SpawnError || std.mem.Allocator.Error;

const Actions = enum(u32) {
    Add = 1,
    Remove = 2,
    Modify = 3,
    RenameOldName = 4,
    RenameNewName = 5,
};

fn actionIntToEnum(action: std.os.windows.DWORD) Actions {
    switch (action) {
        1 => return Actions.Add,
        2 => return Actions.Remove,
        3 => return Actions.Modify,
        4 => return Actions.RenameOldName,
        5 => return Actions.RenameNewName,
        else => unreachable,
    }
}

fn getBaseFileName(path: []const u8) []const u8 {
    const lastSlash = std.mem.lastIndexOf(u8, path, "\\");
    if (lastSlash == null) {
        return path;
    }

    return path[lastSlash.? + 1 ..];
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

        var eIndex: usize = 0;
        var events = [_]*windows.FILE_NOTIFY_INFORMATION{undefined} ** 100;
        var fileNames = [_][]const u8{undefined} ** 100;

        while (offset < bytesReturned) {
            offset = ((offset + 3) / 4) * 4; // Align to 4 bytes
            const fileNotifyInfo: *windows.FILE_NOTIFY_INFORMATION = @alignCast(@ptrCast(&buffer[offset]));
            offset += @sizeOf(windows.FILE_NOTIFY_INFORMATION);

            const changedFileName: []u8 = @alignCast(buffer[offset .. offset + fileNotifyInfo.FileNameLength]);
            offset += fileNotifyInfo.FileNameLength;

            events[eIndex] = fileNotifyInfo;
            fileNames[eIndex] = changedFileName;
            eIndex += 1;
        }

        // TODO: study updates more
        // var i: usize = 0;
        // while (i < eIndex) {
        //     defer i += 1;

        //     const action = actionIntToEnum(events[i].Action);
        //     if (i == eIndex - 1) {
        //         std.debug.print("Action {} on file {s}\n", .{ actionIntToEnum(events[i].Action), fileNames[i] });

        //         const changedBaseFileName = getBaseFileName(fileNames[0]);
        //         switch (action) {
        //             Actions.Add => try index.addFileName(changedBaseFileName),
        //             Actions.Remove => try index.removeFileName(changedBaseFileName),
        //             else => unreachable,
        //         }

        //         continue;
        //     }

        //     const nextAction = actionIntToEnum(events[i + 1].Action);

        //     if (action == Actions.RenameOldName) {
        //         std.debug.assert(nextAction == Actions.RenameNewName);

        //         // Rename
        //         std.debug.print("Renamed {s} to {s}\n", .{ fileNames[i], fileNames[i + 1] });
        //         i += 1;
        //         continue;
        //     } else if (action == Actions.RenameNewName) {
        //         std.debug.assert(nextAction == Actions.RenameOldName);

        //         // Rename
        //         std.debug.print("Renamed {s} to {s}\n", .{ fileNames[i + 1], fileNames[i] });
        //         i += 1;
        //         continue;
        //     } else if (action == Actions.Remove and nextAction == Actions.Add and
        //         std.mem.eql(u8, getBaseFileName(fileNames[i]), getBaseFileName(fileNames[i + 1])))
        //     {

        //         // Move
        //         std.debug.print("Moved {s} to {s}\n", .{ fileNames[i], fileNames[i + 1] });
        //         i += 1;
        //         continue;
        //     } else {
        //         std.debug.print("Action {} on file {s}\n", .{ actionIntToEnum(events[i].Action), fileNames[i] });

        //         const changedBaseFileName = getBaseFileName(fileNames[0]);
        //         switch (action) {
        //             Actions.Add => try index.addFileName(changedBaseFileName),
        //             Actions.Remove => try index.removeFileName(changedBaseFileName),
        //             else => unreachable,
        //         }
        //     }

        //     std.debug.print("Action {} on file {s}\n", .{ action, fileNames[i] });
        //     i += 1;
        // }

        // std.debug.print("----------------------------\n", .{});
    }
}

pub fn main() !void {
    var _stringAllocator = std.heap.FixedBufferAllocator.init(
        try std.heap.page_allocator.alloc(u8, 30 * 1024 * 1024), // 30 MB
    );
    var stringAllocator = _stringAllocator.allocator();

    const path = "C:/";
    index = try fileIndex.init(&gpa, &stringAllocator);

    const cnt = try walk(path);
    std.debug.print("Total files: {d}\n", .{cnt});

    // _ = try std.Thread.spawn(.{}, setupWatcher, .{path});

    const startTime = std.time.milliTimestamp();
    const queryCnt = try index.query("boxes.cpp");
    const endTime = std.time.milliTimestamp();
    std.debug.print("Matching files are {d} in {d}ms\n", .{ queryCnt, endTime - startTime });

    const passsthroughCnt = index.rootPosition().scanPassthoughNodes();
    const allCnt = index.rootPosition().scanAllNodes();
    const ratio = @as(f64, @floatFromInt(passsthroughCnt)) / @as(f64, @floatFromInt(allCnt));
    std.debug.print("Passthrough nodes are {d} / {d} = {d:.2}\n", .{
        passsthroughCnt,
        allCnt,
        ratio,
    });
    std.debug.print("Total chars used are {d}\n", .{index.rootPosition().scanTotalCharCount()});
    std.debug.print("Total direct data used for nodes {d}\n", .{index.rootPosition().scanSize()});

    while (true) {
        std.Thread.sleep(1_000_000_000);
    }
}
