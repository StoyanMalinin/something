//! Builds the file index for a folder and keeps it in step with the file system.
//! Shared by the REPL (main.zig) and the daemon (daemon.zig).
const std = @import("std");
const fileIndex = @import("file-index.zig");
const watcher = @import("watcher.zig");
const walk = @import("walk.zig");
const config = @import("config.zig");
const issues = @import("issues.zig");

pub var index: *fileIndex.FileIndex = undefined;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

fn scanFolder(path: []const u8, position: fileIndex.Position) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        // Gone again, replaced by a file or a link, or not ours to read
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return,
        error.AccessDenied, error.PermissionDenied => return issues.record(.unreadable, path),
        else => return err,
    };
    defer dir.close(io);

    _ = try walk.walkSingleThreaded(&dir, position, path);
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
    // Moved out of, or into, what is left out: only one side is ours
    if (filter.excludes(to)) return removeFromIndex(from, kind);
    if (filter.excludes(from)) return addToIndex(to, kind);

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

/// What is indexed and what is left out. Only changes while the watcher is stopped.
var filter: config.Filter = undefined;
var fsWatcher: ?*watcher.Watcher = null;

/// Walks the roots into a fresh index and swaps its trie in. Searches keep using the old trie
/// until the swap, and the new one is packed exactly: it has no dead or half-empty blocks, which
/// editing the old one in place only ever adds. Needs room for both tries at once.
///
/// Runs on the watcher's queue, or while the watcher is stopped. Events that arrive meanwhile
/// wait and are applied to the new trie afterwards, which is harmless: they are idempotent.
fn rebuild() !void {
    const fresh = try fileIndex.init(gpa, io, .{});
    defer fresh.deinit();

    walk.index = fresh;
    defer walk.index = index;

    issues.begin();
    var succeeded = false;
    defer issues.end(succeeded);

    try fresh.beginBulk();
    _ = try walk.walk(filter.roots);
    try fresh.endBulk();

    index.swapTrie(fresh);
    succeeded = true;
}

/// What dead space in the trie is worth a rebuild: it is only ever given back by one.
const compact_min_dead_bytes = 64 << 20;

fn needsCompaction() bool {
    const dead = index.trie.dead_bytes;
    return dead >= compact_min_dead_bytes and dead * 4 >= index.trie.used;
}

/// Events were lost under `path`: read it from disk again.
fn rescanIndex(path: []const u8) !void {
    if (filter.isAboveRoot(path)) return rebuild();
    if (filter.excludes(path)) return;

    // Entries that vanished while we were not told are only dropped by removing the whole folder.
    // Searches may briefly miss that folder while it is rebuilt.
    _ = try index.removeFileName(index.rootPosition(), path, true);
    try addToIndex(path, .folder);
}

fn reportIndexError(what: []const u8, path: []const u8, err: anyerror) void {
    std.debug.print("index: {s} {s} failed: {any}\n", .{ what, path, err });
    issues.recordError(path, err);
}

fn onFsEvent(_: ?*anyopaque, event: watcher.Event) void {
    switch (event) {
        .add => |e| {
            if (filter.excludes(e.path)) return;
            addToIndex(e.path, e.kind) catch |err| reportIndexError("add", e.path, err);
        },
        .remove => |e| {
            if (filter.excludes(e.path)) return;
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
        rebuild() catch |err| reportIndexError("compact", "the index", err);
    }
}

/// Indexes what `cfg` includes, then watches it to keep `index` up to date. Undo with `stop`.
pub fn start(allocator: std.mem.Allocator, theIo: std.Io, cfg: config.Config) !void {
    gpa = allocator;
    io = theIo;
    walk.gpa = gpa;
    walk.io = io;
    issues.init(io);
    filter = try config.Filter.init(gpa, cfg);
    walk.filter = &filter;

    // Reserves the trie's node and label buffers at their largest; pages are
    // only backed as they fill up
    index = try fileIndex.init(gpa, io, .{});

    // Changes during the walk are reported once the watcher is up
    const since = watcher.Watcher.currentEventId();
    const startTime = std.Io.Clock.awake.now(io);
    walk.index = index;
    // The walk adds into a plain trie, packed into the search trie once done
    try index.beginBulk();
    issues.begin();
    const cnt = walk.walk(filter.roots) catch |err| {
        issues.end(false);
        return err;
    };
    issues.end(true);
    const walkedTime = std.Io.Clock.awake.now(io);
    try index.endBulk();
    const endTime = std.Io.Clock.awake.now(io);

    std.debug.print("Indexing took {d}ms (packing {d}ms)\n", .{
        startTime.durationTo(endTime).toMilliseconds(),
        walkedTime.durationTo(endTime).toMilliseconds(),
    });
    std.debug.print("Total files: {d}\n", .{cnt});

    try startWatcher(since);
}

fn startWatcher(since: ?u64) !void {
    if (filter.roots.len == 0) {
        std.debug.print("index: nothing to watch, every include is left out\n", .{});
        return;
    }
    fsWatcher = try watcher.Watcher.start(gpa, filter.roots, 0.1, since, onFsEvent, null);
}

pub fn stop() void {
    if (fsWatcher) |w| w.stop(gpa);
    fsWatcher = null;
}

/// Indexes `cfg` instead of what was indexed so far. Searches go on meanwhile, against the old
/// index until the new one is ready. One call at a time, and not from the watcher's queue.
pub fn reconfigure(cfg: config.Config) !void {
    const next = try config.Filter.init(gpa, cfg);

    // Whatever happens from here on is replayed to the new watcher
    const since = watcher.Watcher.currentEventId();
    stop();

    // No handler is running now, so nothing reads the old filter
    var old = filter;
    filter = next;
    old.deinit();

    const startTime = std.Io.Clock.awake.now(io);
    rebuild() catch |err| reportIndexError("rebuild", "after a config change", err);
    std.debug.print("Reindexed in {d}ms\n", .{startTime.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()});

    try startWatcher(since);
}
