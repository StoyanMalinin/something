const std = @import("std");
const fileIndex = @import("file-index.zig");

pub var index: *fileIndex.FileIndex = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;

pub fn walkSingleThreaded(dir: *std.Io.Dir, position: fileIndex.Position) !i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

        if (entry.kind == std.Io.File.Kind.directory) {
            var subDir: ?std.Io.Dir = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err|
                switch (err) {
                    error.PermissionDenied => null,
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

pub fn walk(path: []const u8) !i32 {
    var pq = std.PriorityQueue(
        MyDir,
        void,
        compareDir,
    ).initContext({});
    defer pq.deinit(gpa);

    const dir = try gpa.create(?std.Io.Dir);
    dir.* = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    const pathPosition = try index.addFileName(index.rootPosition(), path, true);
    try pq.push(gpa, MyDir{ .dir = dir, .stat = try dir.*.?.stat(io), .position = pathPosition });

    var cnt: i32 = 0;
    var mutex: std.Io.Mutex = .init;

    var explored: usize = 0;
    while (explored + pq.count() < 1000 and pq.count() > 0) {
        explored += 1;

        const item: MyDir = pq.pop().?;
        defer gpa.destroy(item.dir);
        defer item.dir.*.?.close(io);

        const position = item.position;

        var it = item.dir.*.?.iterate();
        while (try it.next(io)) |entry| {
            const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

            if (entry.kind == std.Io.File.Kind.directory) {
                const subDir = try gpa.create(?std.Io.Dir);
                subDir.* = item.dir.*.?.openDir(io, entry.name, .{ .iterate = true }) catch |err|
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

    var group: std.Io.Group = .init;

    while (pq.count() > 0) {
        const item = pq.pop().?;

        group.async(io, walkWrapper, .{
            item.dir,
            item.position,
            &mutex,
            &cnt,
        });
    }

    try group.await(io);

    return cnt;
}
