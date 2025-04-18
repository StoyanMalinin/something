const std = @import("std");

fn walkSingleThreaded(dir: *std.fs.Dir, depth: usize) std.fs.Dir.OpenError!i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const fileName = entry.name;
        const kind = entry.kind;

        if (kind == std.fs.File.Kind.directory) {
            var subDir: ?std.fs.Dir = dir.openDir(fileName, .{ .iterate = true, .no_follow = true }) catch |err|
                switch (err) {
                    error.AccessDenied => null,
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close();
                cnt += try walkSingleThreaded(&subDir.?, depth + 1);
            }
        } else {
            cnt += 1;
        }
    }

    return cnt;
}

fn walkWrapper(dir: *std.fs.Dir, depth: usize, dirToDestroy: *?std.fs.Dir, wg: *std.Thread.WaitGroup, mut: *std.Thread.Mutex, cnt: *i32, err: *?WalkErrorType) void {
    defer wg.*.finish();
    defer gpa.destroy(dirToDestroy);
    defer dir.close();

    const currCnt = walkMultiThreadedV2(dir, depth) catch |walkErr| blk: {
        err.* = walkErr;
        std.debug.print("Error: {any}\n", .{walkErr});

        break :blk 0;
    };

    mut.*.lock();
    cnt.* += currCnt;
    mut.*.unlock();
}

var threadPool: std.Thread.Pool = undefined;
fn walkMultiThreadedV2(dir: *std.fs.Dir, depth: usize) WalkErrorType!i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();

    if (depth <= 1) {
        var wg: std.Thread.WaitGroup = std.Thread.WaitGroup{};
        wg.reset();

        var currErr: ?WalkErrorType = null;
        var mut = std.Thread.Mutex{};

        while (try it.next()) |entry| {
            const fileName = entry.name;
            const kind = entry.kind;

            if (kind == std.fs.File.Kind.directory) {
                const subDir = try gpa.create(?std.fs.Dir);
                subDir.* = dir.openDir(fileName, .{ .iterate = true, .no_follow = true }) catch |err|
                    switch (err) {
                        error.AccessDenied => null,
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir.* != null) {
                    wg.start();
                    _ = try std.Thread.spawn(.{}, walkWrapper, .{ &subDir.*.?, depth + 1, subDir, &wg, &mut, &cnt, &currErr });
                }
            } else {
                mut.lock();
                cnt += 1;
                mut.unlock();
            }
        }

        wg.wait();
        if (currErr != null) {
            return currErr.?;
        }
    } else {
        while (try it.next()) |entry| {
            const fileName = entry.name;
            const kind = entry.kind;

            if (kind == std.fs.File.Kind.directory) {
                var subDir: ?std.fs.Dir = dir.openDir(fileName, .{ .iterate = true, .no_follow = true }) catch |err|
                    switch (err) {
                        error.AccessDenied => null,
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir != null) {
                    defer subDir.?.close();
                    cnt += try walkMultiThreadedV2(&subDir.?, depth + 1);
                }
            } else {
                cnt += 1;
            }
        }
    }

    return cnt;
}

const MyDir = struct {
    dir: *std.fs.Dir,
    stat: std.fs.Dir.Stat,
    name: []const u8,
};

fn compareDir(_: void, a: MyDir, b: MyDir) std.math.Order {
    if (a.stat.size > b.stat.size) {
        return std.math.Order.lt;
    } else if (a.stat.size < b.stat.size) {
        return std.math.Order.gt;
    }

    return std.math.Order.eq;
}

fn walkWrapperV2(dir: *std.fs.Dir, depth: usize, wg: *std.Thread.WaitGroup, mut: *std.Thread.Mutex, cnt: *i32) void {
    defer wg.*.finish();
    defer dir.close();

    const currCnt = walkSingleThreaded(dir, depth) catch |walkErr| blk: {
        std.debug.print("Error: {any}\n", .{walkErr});
        break :blk 0;
    };

    mut.*.lock();
    cnt.* += currCnt;
    mut.*.unlock();
}

fn walkMultiThreadedV3(dir: *std.fs.Dir) !i32 {
    var pq = std.PriorityQueue(
        MyDir,
        void,
        compareDir,
    ).init(gpa, void{});

    try pq.add(MyDir{
        .dir = dir,
        .stat = try dir.stat(),
        .name = ".",
    });

    var cnt: i32 = 0;
    var explored: usize = 0;
    while (explored + pq.count() < 1000 and pq.count() > 0) {
        explored += 1;

        const item: MyDir = pq.remove();
        defer item.dir.close();

        var it = item.dir.iterate();
        while (try it.next()) |entry| {
            const fileName = entry.name;
            const kind = entry.kind;

            if (kind == std.fs.File.Kind.directory) {
                const subDir = try gpa.create(?std.fs.Dir);
                subDir.* = item.dir.openDir(fileName, .{ .iterate = true, .no_follow = true }) catch |err|
                    switch (err) {
                        error.AccessDenied => null,
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir.* != null) {
                    try pq.add(MyDir{
                        .dir = &subDir.*.?,
                        .stat = try subDir.*.?.stat(),
                        .name = _fileName,
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
        try threadPool.spawn(walkWrapperV2, .{
            item.dir,
            0, // TODO: fix depth
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

const DirIter = struct {
    deadPill: bool,
    dir: *std.fs.Dir,
    it: *std.fs.Dir.Iterator,
    node: std.DoublyLinkedList.Node,
};

fn createDirIter(dir: *std.fs.Dir, it: *std.fs.Dir.Iterator) !*DirIter {
    const item = try gpa.create(DirIter);
    item.* = .{ .it = it, .dir = dir, .deadPill = false, .node = .{} };

    return item;
}

fn createDeadPill() !*DirIter {
    const item = try gpa.create(DirIter);
    item.* = .{ .it = undefined, .dir = undefined, .deadPill = true, .node = .{} };

    return item;
}

var activeFolders: i32 = 1;
var mutex = std.Thread.Mutex{};
var queueSize = std.Thread.Semaphore{};

var fileCnt: i32 = 0;
var q: std.DoublyLinkedList = std.DoublyLinkedList{};

fn queueFront() *DirIter {
    const dirIter: *DirIter = @fieldParentPtr("node", q.first.?);
    return dirIter;
}

fn walkWorkerOperation() !i32 {
    queueSize.wait();
    mutex.lock();
    const dirIter: *DirIter = queueFront();
    _ = q.popFirst();
    mutex.unlock();

    if (dirIter.deadPill) {
        return error.ScanIsOver;
    }

    const entry = try dirIter.it.next();
    if (entry == null) {
        {
            mutex.lock();
            defer mutex.unlock();

            activeFolders -= 1;
            if (activeFolders == 0) {
                for (0..1000) |_| {
                    queueSize.post();
                    const x = try createDeadPill();
                    q.append(&x.node);
                }

                return error.ScanIsOver;
            }
        }

        dirIter.dir.close(); // we no longer need this directory's fd
        return 0;
    }

    // std.debug.print("Found file {s}\n", .{entry.?.name});

    if (entry.?.kind == std.fs.File.Kind.directory) {
        const subDir: *?std.fs.Dir = try gpa.create(?std.fs.Dir);
        subDir.* = dirIter.dir.openDir(entry.?.name, .{ .iterate = true }) catch |dirErr|
            switch (dirErr) {
                error.AccessDenied => null,
                else => |leftoverErr| return leftoverErr,
            };

        if (subDir.* != null) {
            const subDirIt = try gpa.create(std.fs.Dir.Iterator);
            subDirIt.* = subDir.*.?.iterate();
            var newSubDirIter = try createDirIter(&(subDir.*.?), subDirIt);

            mutex.lock();
            activeFolders += 1;
            q.append(&newSubDirIter.node);
            mutex.unlock();
            queueSize.post();
        }
    }

    mutex.lock();
    dirIter.node = .{};
    q.append(&dirIter.node);
    mutex.unlock();
    queueSize.post();

    return 1;
}

fn walkWorker() void {
    while (true) {
        const cnt = walkWorkerOperation() catch |err| blk: {
            if (err == error.ScanIsOver) {
                return;
            }

            std.debug.print("Error: {any}\n", .{err});
            break :blk 0;
        };

        mutex.lock();
        fileCnt += cnt;
        mutex.unlock();
    }
}

fn walk(dir: *std.fs.Dir) !i32 {
    var it = dir.iterate();
    q.append(&(try createDirIter(dir, &it)).node);

    // init size semaphore
    queueSize.post();

    var threads: [500]std.Thread = undefined;
    for (0..50) |i| {
        threads[i] = try std.Thread.spawn(.{}, walkWorker, .{});
    }

    for (0..50) |i| {
        threads[i].join();
    }

    return fileCnt;
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
    try threadPool.init(std.Thread.Pool.Options{
        .n_jobs = 10,
        .allocator = gpa,
    });

    const path = "C:/Users/Znayko/Desktop";
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });

    const count = try walkMultiThreadedV3(&dir);
    std.debug.print("Total files: {}\n", .{count});
}
