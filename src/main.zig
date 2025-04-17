const std = @import("std");

fn walkSingleThreaded(dir: *std.fs.Dir, depth: usize) std.fs.Dir.OpenError!i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const fileName = entry.name;
        const kind = entry.kind;

        cnt += 1;
        if (kind == std.fs.File.Kind.directory) {
            var subDir: ?std.fs.Dir = dir.openDir(fileName, .{ .iterate = true }) catch |err|
                switch (err) {
                    error.AccessDenied => null,
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close();
                cnt += try walkSingleThreaded(&subDir.?, depth + 1);
            }
        }
    }

    return cnt;
}

var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
var gpa = _gpa.allocator();
const WalkErrorType = std.fs.Dir.OpenError || std.Thread.SpawnError || std.mem.Allocator.Error;

fn walkMultiThreaded(dir: *std.fs.Dir, depth: usize, cnt: *i32, err: *?WalkErrorType) void {
    cnt.* += 1;
    if (depth > 3) {
        cnt.* = walkSingleThreaded(dir, depth) catch |singleErr| blk: {
            err.* = singleErr;
            break :blk 0;
        };
        return;
    }

    var threadPool: std.Thread.Pool = undefined;
    threadPool.init(std.Thread.Pool.Options{
        .n_jobs = 10,
        .allocator = gpa,
    }) catch |initErr| {
        err.* = initErr;
        return;
    };
    defer threadPool.deinit();

    var wg: std.Thread.WaitGroup = undefined;
    wg.reset();

    // var threadErrors = std.ArrayList(*?std.fs.Dir.OpenError);
    // threadErrors.init(std.heap.page_allocator);
    // defer threadErrors.deinit();

    var it = dir.iterate();
    while (it.next() catch |nextError| {
        err.* = nextError;
        return;
    }) |entry| {
        const fileName = entry.name;
        const kind = entry.kind;

        if (kind == std.fs.File.Kind.directory) {
            var subDir: ?std.fs.Dir = dir.openDir(fileName, .{ .iterate = true }) catch |dirErr|
                switch (dirErr) {
                    error.AccessDenied => null,
                    else => |leftoverErr| {
                        err.* = leftoverErr;
                        return;
                    },
                };

            if (subDir != null) {
                defer subDir.?.close();

                var currentErr: ?WalkErrorType = (gpa.alloc(?WalkErrorType, 1) catch |allocError| {
                    err.* = allocError;
                    return;
                })[0];
                threadPool.spawnWg(&wg, walkMultiThreaded, .{ &subDir.?, depth + 1, cnt, &currentErr });
            }
        }
    }

    wg.wait();
}

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
    const path = "C:/";
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });

    const count = try walkSingleThreaded(&dir, 0);
    std.debug.print("Total files: {}\n", .{count});

    // try setupWatcher(path);
}
