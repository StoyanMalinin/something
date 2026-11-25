const std = @import("std");
const fileIndex = @import("file-index.zig");
const trie = @import("trie.zig");
const watcher = @import("watcher.zig");
const walk = @import("walk.zig");

var index: *fileIndex.FileIndex = undefined;

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

    _ = try walk.walkSingleThreaded(&dir, position);
    try index.refreshMasks(position, path);
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

        // Microsecond resolution: many queries take a few milliseconds (scripts/bench.sh reads this)
        const micros: u64 = @intCast(startTime.durationTo(endTime).toMicroseconds());
        std.debug.print("{d} matches in {d}.{d:0>3}ms\n", .{ searchResult.len, micros / 1000, micros % 1000 });
        for (searchResult) |result| {
            std.debug.print("{d} {s}\n", .{ result.score, result.path });
        }

        for (searchResult) |result| {
            gpa.free(result.path);
        }
    }
}

pub fn createIndex(path: []const u8) !void {
    // Reserves the trie's node and label buffers at their largest; pages are
    // only backed as they fill up
    index = try fileIndex.init(gpa, io, .{});

    const startTime = std.Io.Clock.awake.now(io);
    walk.index = index;
    // The walk adds into a plain trie, packed into the search trie once done
    try index.beginBulk();
    const cnt = try walk.walk(path);
    const walkedTime = std.Io.Clock.awake.now(io);
    try index.endBulk();
    const endTime = std.Io.Clock.awake.now(io);

    std.debug.print("Indexing took {d}ms (packing {d}ms)\n", .{
        startTime.durationTo(endTime).toMilliseconds(),
        walkedTime.durationTo(endTime).toMilliseconds(),
    });
    std.debug.print("Total files: {d}\n", .{cnt});
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;
    walk.gpa = gpa;
    walk.io = io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len > 1) args[1] else "/", init.arena.allocator());

    try createIndex(path);

    const fsWatcher = try watcher.Watcher.start(gpa, path, 0.1, onFsEvent, null);
    defer fsWatcher.stop(gpa);

    const passsthroughCnt = index.trie.scanPassthoughNodes();
    const allCnt = index.trie.scanAllNodes();
    const ratio = @as(f64, @floatFromInt(passsthroughCnt)) / @as(f64, @floatFromInt(allCnt));
    std.debug.print("Passthrough nodes are {d} / {d} = {d:.2}\n", .{
        passsthroughCnt,
        allCnt,
        ratio,
    });
    var childHist: [257]usize = undefined;
    index.trie.scanChildCounts(&childHist);
    std.debug.print("Children per node (count: nodes):\n", .{});
    for (childHist, 0..) |n, k| {
        if (n == 0) continue;
        const plus: []const u8 = if (k == childHist.len - 1) "+" else "";
        std.debug.print("  {d}{s}: {d}\n", .{ k, plus, n });
    }
    std.debug.print("Total chars used are {d}\n", .{index.trie.scanTotalCharCount()});
    std.debug.print("Total direct data used for nodes {d}\n", .{index.trie.scanSize()});

    try queryLoop();

    // The index is deliberately never freed. On return, the leak checker would print a stack
    // trace (loading DWARF each time) for every allocation, which takes minutes and stalls
    // profiling and benchmark runs. Debug and ReleaseSafe builds still report leaks.
    if (@import("builtin").mode == .fast) std.process.exit(0);
}

test {
    // Pull in the other files' tests; `zig build test` is rooted here
    _ = fileIndex;
    _ = trie;
    _ = watcher;
    _ = walk;
}
