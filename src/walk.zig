const std = @import("std");
const fileIndex = @import("file-index.zig");

pub var index: *fileIndex.FileIndex = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;

/// macOS firmlinks `/Users`, `/Applications`, `/Library`, ... from the data volume
/// mounted at `/System/Volumes/Data`. Firmlinks read as plain folders, so walking `/`
/// would index all of those twice. Set by `walk` when that folder exists.
var dataVolumeInode: ?std.Io.File.INode = null;

/// Whether to leave out the folder `name` inside `dir`. Only stats folders named "Data",
/// so the check is free for everything else.
fn skipDir(dir: std.Io.Dir, name: []const u8) bool {
    const inode = dataVolumeInode orelse return false;
    if (!std.mem.eql(u8, name, "Data")) return false;
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return st.inode == inode;
}

pub fn walkSingleThreaded(dir: *std.Io.Dir, position: fileIndex.Position) !i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == std.Io.File.Kind.directory and skipDir(dir.*, entry.name)) continue;

        const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

        if (entry.kind == std.Io.File.Kind.directory) {
            var subDir: ?std.Io.Dir = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
                switch (err) {
                    error.PermissionDenied, error.AccessDenied => null,
                    else => |leftoverErr| return leftoverErr,
                };

            if (subDir != null) {
                defer subDir.?.close(io);
                cnt += try walkSingleThreaded(&subDir.?, subPosition);
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
};

fn compareDir(_: void, a: MyDir, b: MyDir) std.math.Order {
    if (a.stat.size > b.stat.size) {
        return std.math.Order.lt;
    } else if (a.stat.size < b.stat.size) {
        return std.math.Order.gt;
    }

    return std.math.Order.eq;
}

fn walkWrapper(dir: *?std.Io.Dir, position: fileIndex.Position, mut: *std.Io.Mutex, cnt: *i32) void {
    defer gpa.destroy(dir);
    defer dir.*.?.close(io);

    const currCnt = walkSingleThreaded(&dir.*.?, position) catch |walkErr| blk: {
        std.debug.print("Error: {any}\n", .{walkErr});
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
        walkWrapper(item.dir, item.position, queue.mutex, queue.cnt);
    }
}

pub fn walk(path: []const u8) !i32 {
    var pq = DirQueue.initContext({});
    defer pq.deinit(gpa);

    dataVolumeInode = if (std.Io.Dir.cwd().statFile(io, "/System/Volumes/Data", .{ .follow_symlinks = false })) |st| st.inode else |_| null;

    const dir = try gpa.create(?std.Io.Dir);
    dir.* = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    const pathPosition = try index.addFileName(index.rootPosition(), path, true);
    try pq.push(gpa, MyDir{ .dir = dir, .stat = try dir.*.?.stat(io), .position = pathPosition });

    var cnt: i32 = 0;
    var mutex: std.Io.Mutex = .init;

    var explored: usize = 0;
    while (explored + pq.count() < initial_dirs and pq.count() > 0) {
        explored += 1;

        const item: MyDir = pq.pop().?;
        defer gpa.destroy(item.dir);
        defer item.dir.*.?.close(io);

        const position = item.position;

        var it = item.dir.*.?.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == std.Io.File.Kind.directory and skipDir(item.dir.*.?, entry.name)) continue;

            const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

            if (entry.kind == std.Io.File.Kind.directory) {
                const subDir = try gpa.create(?std.Io.Dir);
                subDir.* = item.dir.*.?.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
                    switch (err) {
                        error.PermissionDenied => null,
                        else => |leftoverErr| return leftoverErr,
                    };

                if (subDir.* != null) {
                    try pq.push(gpa, MyDir{
                        .dir = subDir,
                        .stat = try subDir.*.?.stat(io),
                        .position = subPosition,
                    });
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
    try index.refreshMasks(pathPosition, path);

    return cnt;
}
