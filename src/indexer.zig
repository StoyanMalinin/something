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
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        // Gone again, replaced by a file or a link, or not ours to read
        error.FileNotFound, error.NotDir, error.SymLinkLoop, error.AccessDenied => return,
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

/// The watched folder, what `rebuild` walks.
var rootPath: []u8 = &.{};

/// Walks `rootPath` into a fresh index and swaps its trie in. Searches keep using the old trie
/// until the swap, and the new one is packed exactly: it has no dead or half-empty blocks, which
/// editing the old one in place only ever adds. Needs room for both tries at once.
///
/// Runs on the watcher's queue, so events that arrive meanwhile wait and are applied to the new
/// trie afterwards, which is harmless: they are idempotent.
fn rebuild() !void {
    const fresh = try fileIndex.init(gpa, io, .{});
    defer fresh.deinit();

    walk.index = fresh;
    defer walk.index = index;

    try fresh.beginBulk();
    _ = try walk.walk(rootPath);
    try fresh.endBulk();

    index.swapTrie(fresh);
}

fn trimSlashes(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "/");
}

/// Whether `path` is the watched folder or one above it.
fn coversRoot(path: []const u8) bool {
    const p = trimSlashes(path);
    const root = trimSlashes(rootPath);
    if (!std.mem.startsWith(u8, root, p)) return false;
    return root.len == p.len or root[p.len] == '/';
}

/// What dead space in the trie is worth a rebuild: it is only ever given back by one.
const compact_min_dead_bytes = 64 << 20;

fn needsCompaction() bool {
    const dead = index.trie.dead_bytes;
    return dead >= compact_min_dead_bytes and dead * 4 >= index.trie.used;
}

/// Events were lost under `path`: read it from disk again.
fn rescanIndex(path: []const u8) !void {
    if (coversRoot(path)) return rebuild();

    // Entries that vanished while we were not told are only dropped by removing the whole folder.
    // Searches may briefly miss that folder while it is rebuilt.
    _ = try index.removeFileName(index.rootPosition(), path, true);
    try addToIndex(path, .folder);
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
        .rescan => |e| {
            rescanIndex(e.path) catch |err| reportIndexError("rescan", e.path, err);
        },
    }

    if (needsCompaction()) {
        rebuild() catch |err| reportIndexError("compact", rootPath, err);
    }
}

/// Indexes everything under `path` (absolute), then returns the watcher that keeps
/// `index` up to date. Stop it with `fsWatcher.stop(allocator)`.
pub fn start(allocator: std.mem.Allocator, theIo: std.Io, path: []const u8) !*watcher.Watcher {
    gpa = allocator;
    io = theIo;
    walk.gpa = gpa;
    walk.io = io;
    rootPath = try gpa.dupe(u8, path);

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

test "a rescan covers the root when it is the root or above it" {
    const saved = rootPath;
    defer rootPath = saved;
    rootPath = @constCast("/Users/me/code");

    try std.testing.expect(coversRoot("/Users/me/code"));
    try std.testing.expect(coversRoot("/Users/me/code/"));
    try std.testing.expect(coversRoot("/Users/me"));
    try std.testing.expect(coversRoot("/"));
    try std.testing.expect(!coversRoot("/Users/me/code/src"));
    try std.testing.expect(!coversRoot("/Users/me/cod"));
    try std.testing.expect(!coversRoot("/Users/other"));
}
