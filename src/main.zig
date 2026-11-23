const std = @import("std");
const fileIndex = @import("file-index.zig");
const trie = @import("trie.zig");
const watcher = @import("watcher.zig");

var index: *fileIndex.FileIndex = undefined;

fn walkSingleThreaded(dir: *std.Io.Dir, position: fileIndex.Position) !i32 {
    var cnt: i32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const subPosition = try index.addFileName(position, entry.name, entry.kind == std.Io.File.Kind.directory);

        if (entry.kind == std.Io.File.Kind.directory) {
            var subDir: ?std.Io.Dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err|
                switch (err) {
                    error.AccessDenied => null,
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

fn walk(path: []const u8) !i32 {
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
                        error.AccessDenied => null,
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

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
const WalkErrorType = std.Io.Dir.OpenError || std.Thread.SpawnError || std.mem.Allocator.Error;

fn onFsEvent(_: ?*anyopaque, event: watcher.Event) void {
    // TODO: apply the change to the index
    std.debug.print("fs event: {s} created={} removed={} modified={} renamed={} dir={}\n", .{
        event.path,
        event.created(),
        event.removed(),
        event.modified(),
        event.renamed(),
        event.isDir(),
    });
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;

    var _stringAllocator = std.heap.FixedBufferAllocator.init(
        try std.heap.page_allocator.alloc(u8, 30 * 1024 * 1024), // 30 MB
    );
    var stringAllocator = _stringAllocator.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "/";
    const needle = if (args.len > 2) args[2] else "boxes.cpp";
    index = try fileIndex.init(&gpa, &stringAllocator, io);

    const cnt = try walk(path);
    std.debug.print("Total files: {d}\n", .{cnt});

    const fsWatcher = try watcher.Watcher.start(gpa, path, 0.1, onFsEvent, null);
    defer fsWatcher.stop(gpa);

    const startTime = std.Io.Clock.awake.now(io);
    const queryCnt = try index.query(needle);
    const endTime = std.Io.Clock.awake.now(io);
    std.debug.print("Matching files are {d} in {d}ms\n", .{ queryCnt, startTime.durationTo(endTime).toMilliseconds() });

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
        try std.Io.sleep(io, .fromSeconds(1), .awake);
    }
}
