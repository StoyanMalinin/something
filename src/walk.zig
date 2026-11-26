const std = @import("std");
const fileIndex = @import("file-index.zig");
const config = @import("config.zig");
const issues = @import("issues.zig");

/// What to leave out. Set by the indexer before any walk.
pub var filter: *const config.Filter = undefined;
pub var index: *fileIndex.FileIndex = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;

/// The absolute path of the entry `name` in the folder `dir`
fn childPath(dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(gpa, "/{s}", .{name});
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

/// Adds everything below `dir`, which is the folder `path` (absolute), at `position`.
pub fn walkSingleThreaded(dir: *std.Io.Dir, position: fileIndex.Position, path: []const u8) !i32 {
    var cnt: i32 = 0;
    const leftOut = filter.leftOutIn(path);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (filter.skips(leftOut, entry.name)) continue;

        const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

        if (entry.kind == std.Io.File.Kind.directory) {
            var subDir: ?std.Io.Dir = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
                switch (err) {
                    error.PermissionDenied, error.AccessDenied => blk: {
                        const subPath = try childPath(path, entry.name);
                        defer gpa.free(subPath);
                        issues.record(.unreadable, subPath);
                        break :blk null;
                    },
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close(io);
                const subPath = try childPath(path, entry.name);
                defer gpa.free(subPath);
                cnt += try walkSingleThreaded(&subDir.?, subPosition, subPath);
            }
        } else {
            cnt += 1;
        }
    }

    return cnt;
}

const MyDir = struct {
    dir: *?std.Io.Dir,
    stat: std.Io.Dir.Stat,
    position: fileIndex.Position,
    /// Absolute path of the folder, owned by the item
    path: []u8,
};

fn compareDir(_: void, a: MyDir, b: MyDir) std.math.Order {
    if (a.stat.size > b.stat.size) {
        return std.math.Order.lt;
    } else if (a.stat.size < b.stat.size) {
        return std.math.Order.gt;
    }

    return std.math.Order.eq;
}

fn walkWrapper(dir: *?std.Io.Dir, position: fileIndex.Position, path: []u8, mut: *std.Io.Mutex, cnt: *i32) void {
    defer gpa.destroy(dir);
    defer dir.*.?.close(io);
    defer gpa.free(path);

    const currCnt = walkSingleThreaded(&dir.*.?, position, path) catch |walkErr| blk: {
        std.debug.print("Error: {any}\n", .{walkErr});
        issues.recordError(path, walkErr);
        break :blk 0;
    };

    mut.*.lockUncancelable(io);
    cnt.* += currCnt;
    mut.*.unlock(io);
}

/// Threads that walk in parallel, the caller included. Measured on 10 cores (4 performance):
/// going past 4 gained nothing, likely held back by the index's lock or the kernel.
const walker_threads = 4;

/// How many folders the single-threaded first pass splits the tree into (each held open
/// until a walker takes it). Swept 4..4000 at 4 threads: below 256 one big folder is left
/// to a single walker at the end (~1.7x slower on ~), above it the first pass grows too
/// long; 256 tied 1000 with a quarter of the open files.
const initial_dirs = 256;

const DirQueue = std.PriorityQueue(MyDir, void, compareDir);

const Queue = struct {
    pq: *DirQueue,
    /// Guards `pq` and `cnt`
    mutex: *std.Io.Mutex,
    cnt: *i32,
};

fn walker(queue: *Queue) void {
    while (true) {
        queue.mutex.lockUncancelable(io);
        const next = queue.pq.pop();
        queue.mutex.unlock(io);

        const item = next orelse return;
        walkWrapper(item.dir, item.position, item.path, queue.mutex, queue.cnt);
    }
}

/// Adds every file below the folders `roots` (absolute) to `index`, leaving out what `filter`
/// says. A root that cannot be opened is reported and skipped.
pub fn walk(roots: []const []const u8) !i32 {
    var pq = DirQueue.initContext({});
    defer pq.deinit(gpa);

    const rootPositions = try gpa.alloc(?fileIndex.Position, roots.len);
    defer gpa.free(rootPositions);
    for (roots, rootPositions) |root, *rootPosition| {
        rootPosition.* = null;

        const dir = try gpa.create(?std.Io.Dir);
        dir.* = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
            std.debug.print("walk: cannot open {s}: {any}\n", .{ root, err });
            issues.recordError(root, err);
            gpa.destroy(dir);
            continue;
        };

        const pathPosition = try index.addFileName(index.rootPosition(), root, true);
        rootPosition.* = pathPosition;
        try pq.push(gpa, MyDir{
            .dir = dir,
            .stat = try dir.*.?.stat(io),
            .position = pathPosition,
            .path = try gpa.dupe(u8, root),
        });
    }

    var cnt: i32 = 0;
    var mutex: std.Io.Mutex = .init;

    var explored: usize = 0;
    while (explored + pq.count() < initial_dirs and pq.count() > 0) {
        explored += 1;

        const item: MyDir = pq.pop().?;
        defer gpa.destroy(item.dir);
        defer item.dir.*.?.close(io);
        defer gpa.free(item.path);

        const position = item.position;
        const leftOut = filter.leftOutIn(item.path);

        var it = item.dir.*.?.iterate();
        while (try it.next(io)) |entry| {
            if (filter.skips(leftOut, entry.name)) continue;

            const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

            if (entry.kind == std.Io.File.Kind.directory) {
                const subDir = try gpa.create(?std.Io.Dir);
                subDir.* = item.dir.*.?.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
                    switch (err) {
                        error.PermissionDenied, error.AccessDenied => blk: {
                            const subPath = try childPath(item.path, entry.name);
                            defer gpa.free(subPath);
                            issues.record(.unreadable, subPath);
                            break :blk null;
                        },
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir.* != null) {
                    try pq.push(gpa, MyDir{
                        .dir = subDir,
                        .stat = try subDir.*.?.stat(io),
                        .position = subPosition,
                        .path = try childPath(item.path, entry.name),
                    });
                } else {
                    gpa.destroy(subDir);
                }
            } else {
                cnt += 1;
            }
        }
    }

    // A fixed set of walkers take folders from the queue, largest first, until it is empty.
    // The calling thread is one of them.
    var queue: Queue = .{ .pq = &pq, .mutex = &mutex, .cnt = &cnt };
    var group: std.Io.Group = .init;
    for (1..walker_threads) |_| {
        group.concurrent(io, walker, .{&queue}) catch break;
    }
    walker(&queue);
    try group.await(io);

    // The masks above each walker's starting position missed its adds
    for (roots, rootPositions) |root, rootPosition| {
        if (rootPosition) |position| try index.refreshMasks(position, root);
    }

    return cnt;
}
