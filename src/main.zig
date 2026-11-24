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

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;
const WalkErrorType = std.Io.Dir.OpenError || std.Thread.SpawnError || std.mem.Allocator.Error;

fn scanFolder(path: []const u8, position: fileIndex.Position) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        // Gone again, replaced by a file, or not ours to read
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);

    _ = try walkSingleThreaded(&dir, position);
}

fn addToIndex(path: []const u8, kind: watcher.Kind) !void {
    const position = try index.addFileName(index.rootPosition(), path, kind == .folder);

    // Generally not necessary: new files are reported one by one, and the add is idempotent.
    // It only matters for a folder that arrives already full (moved in from outside the
    // watched tree, or one half of a rename that was split across batches), whose contents
    // are not reported.
    if (kind == .folder) {
        try scanFolder(path, position);
    }
}

fn removeFromIndex(path: []const u8, kind: watcher.Kind) !void {
    _ = try index.removeFileName(index.rootPosition(), path, kind == .folder);
}

fn moveInIndex(from: []const u8, to: []const u8, kind: watcher.Kind) !void {
    const root = index.rootPosition();
    const moved = switch (kind) {
        .file => try index.moveOrdinaryFile(root, from, root, to),
        .folder => try index.moveFolder(root, from, root, to),
    };

    // The source was never indexed, so the destination is new to us
    if (!moved) {
        try addToIndex(to, kind);
    }
}

fn reportIndexError(what: []const u8, path: []const u8, err: anyerror) void {
    std.debug.print("index: {s} {s} failed: {any}\n", .{ what, path, err });
}

fn onFsEvent(_: ?*anyopaque, event: watcher.Event) void {
    switch (event) {
        .add => |e| {
            addToIndex(e.path, e.kind) catch |err| reportIndexError("add", e.path, err);
        },
        .remove => |e| {
            removeFromIndex(e.path, e.kind) catch |err| reportIndexError("remove", e.path, err);
        },
        .move => |e| {
            moveInIndex(e.from, e.to, e.kind) catch |err| reportIndexError("move", e.to, err);
        },
    }
}

fn queryLoop() !void {
    var buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buf);

    while (true) {
        std.debug.print("query (:q or ctrl-d to quit)> ", .{});

        const line = (try stdin.interface.takeDelimiter('\n')) orelse return;
        const word = std.mem.trim(u8, line, " \t\r");
        if (word.len == 0) continue;
        if (std.mem.eql(u8, word, ":q")) return;

        const startTime = std.Io.Clock.awake.now(io);
        const searchResult = try index.search(gpa, word, .{ .limit = 10 });
        const endTime = std.Io.Clock.awake.now(io);

        std.debug.print("{d} matches in {d}ms\n", .{ searchResult.len, startTime.durationTo(endTime).toMilliseconds() });
        for (searchResult) |result| {
            std.debug.print("{d} {s}\n", .{ result.score, result.path });
        }

        for (searchResult) |result| {
            gpa.free(result.path);
        }
    }
}

pub fn createIndex(path: []const u8) !void {
    var _stringAllocator = std.heap.FixedBufferAllocator.init(
        try std.heap.page_allocator.alloc(u8, 40 * 1024 * 1024), // 40 MB
    );
    var stringAllocator = _stringAllocator.allocator();

    index = try fileIndex.init(&gpa, &stringAllocator, io);

    const startTime = std.Io.Clock.awake.now(io);
    const cnt = try walk(path);
    const endTime = std.Io.Clock.awake.now(io);

    std.debug.print("Indexing took {d}ms\n", .{startTime.durationTo(endTime).toMilliseconds()});
    std.debug.print("Total files: {d}\n", .{cnt});
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len > 1) args[1] else "/", init.arena.allocator());

    try createIndex(path);

    const fsWatcher = try watcher.Watcher.start(gpa, path, 0.1, onFsEvent, null);
    defer fsWatcher.stop(gpa);

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

    try queryLoop();
}
