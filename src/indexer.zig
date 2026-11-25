//! Builds the file index for a folder and keeps it in step with the file system.
//! Shared by the REPL (main.zig) and the daemon (daemon.zig).
const std = @import("std");
const fileIndex = @import("file-index.zig");
const watcher = @import("watcher.zig");
const walk = @import("walk.zig");

pub var index: *fileIndex.FileIndex = undefined;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

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

/// Indexes everything under `path` (absolute), then returns the watcher that keeps
/// `index` up to date. Stop it with `fsWatcher.stop(allocator)`.
pub fn start(allocator: std.mem.Allocator, theIo: std.Io, path: []const u8) !*watcher.Watcher {
    gpa = allocator;
    io = theIo;
    walk.gpa = gpa;
    walk.io = io;

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

    return watcher.Watcher.start(gpa, path, 0.1, onFsEvent, null);
}
