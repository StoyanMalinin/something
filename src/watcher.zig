const std = @import("std");
const c = @import("c");

pub const Kind = enum {
    /// Anything that is not a folder, symlinks included.
    file,
    folder,
};

pub const Event = union(enum) {
    add: Change,
    remove: Change,
    move: Move,

    pub const Change = struct { path: []const u8, kind: Kind };
    pub const Move = struct { from: []const u8, to: []const u8, kind: Kind };
};

/// The paths inside an event are only valid during the call.
pub const Handler = *const fn (context: ?*anyopaque, event: Event) void;

/// One event as FSEvents reports it.
const Raw = struct {
    path: [:0]const u8,
    flags: u32,
    /// The inode, 0 if FSEvents did not say. Both halves of a rename have the same one.
    id: u64,

    present: bool = false,
    /// Not reported on its own: either irrelevant, or the old half of a move.
    consumed: bool = false,
    /// On the new half of a move: index of the old half.
    movedFrom: ?usize = null,

    fn has(self: Raw, flag: u32) bool {
        return self.flags & flag != 0;
    }

    fn renamed(self: Raw) bool {
        return self.has(c.kFSEventStreamEventFlagItemRenamed);
    }

    fn relevant(self: Raw) bool {
        return self.has(c.kFSEventStreamEventFlagItemCreated) or
            self.has(c.kFSEventStreamEventFlagItemRemoved) or
            self.renamed();
    }

    fn kind(self: Raw) Kind {
        return if (self.has(c.kFSEventStreamEventFlagItemIsDir)) .folder else .file;
    }
};

const ExistsFn = *const fn (path: [:0]const u8) bool;

/// Turns one batch of raw events into add, remove and move events.
///
/// The flags of an event can be a mix (created and removed, or modified on top), so they only
/// say that something happened to the path. Whether it is there now decides between add and
/// remove. A rename shows up as two events, one for the old path and one for the new one,
/// which are paired by their inode. A half without a partner (moved in from or out of the
/// watched tree, or the other half arrived in another batch) is an add or a remove.
fn translate(raws: []Raw, exists: ExistsFn, handler: Handler, context: ?*anyopaque) void {
    for (raws) |*raw| {
        raw.consumed = !raw.relevant();
        if (!raw.consumed) {
            raw.present = exists(raw.path);
        }
    }

    for (raws) |*to| {
        if (to.consumed or !to.renamed() or !to.present or to.id == 0) continue;

        for (raws, 0..) |*from, i| {
            if (from.consumed or !from.renamed() or from.present) continue;
            if (from.id != to.id or from.kind() != to.kind()) continue;

            from.consumed = true;
            to.movedFrom = i;
            break;
        }
    }

    for (raws) |*raw| {
        if (raw.consumed) continue;

        if (raw.movedFrom) |i| {
            handler(context, .{ .move = .{ .from = raws[i].path, .to = raw.path, .kind = raw.kind() } });
        } else if (raw.present) {
            handler(context, .{ .add = .{ .path = raw.path, .kind = raw.kind() } });
        } else {
            handler(context, .{ .remove = .{ .path = raw.path, .kind = raw.kind() } });
        }
    }
}

pub const Watcher = struct {
    stream: c.FSEventStreamRef,
    queue: c.dispatch_queue_t,
    handler: Handler,
    context: ?*anyopaque,
    allocator: std.mem.Allocator,

    pub fn start(
        allocator: std.mem.Allocator,
        path: []const u8,
        latency_seconds: f64,
        handler: Handler,
        context: ?*anyopaque,
    ) !*Watcher {
        const self = try allocator.create(Watcher);
        errdefer allocator.destroy(self);
        self.handler = handler;
        self.context = context;
        self.allocator = allocator;

        const pathZ = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(pathZ);

        const cfPath = c.CFStringCreateWithCString(null, pathZ.ptr, c.kCFStringEncodingUTF8) orelse
            return error.OutOfMemory;
        defer c.CFRelease(cfPath);

        var values = [_]?*const anyopaque{cfPath};
        const cfPaths = c.CFArrayCreate(null, @ptrCast(&values), 1, &c.kCFTypeArrayCallBacks) orelse
            return error.OutOfMemory;
        defer c.CFRelease(cfPaths);

        var streamContext = c.FSEventStreamContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        // FileEvents: report individual files, not only the containing directory.
        // UseExtendedData (needs UseCFTypes): every event also carries the inode, which is what
        // pairs the two halves of a rename.
        // No NoDefer: it would deliver the first half of a rename on its own, before the second.
        const flags: c.FSEventStreamCreateFlags =
            c.kFSEventStreamCreateFlagFileEvents |
            c.kFSEventStreamCreateFlagUseCFTypes |
            c.kFSEventStreamCreateFlagUseExtendedData;

        self.stream = c.FSEventStreamCreate(
            null,
            callback,
            &streamContext,
            cfPaths,
            c.kFSEventStreamEventIdSinceNow,
            latency_seconds,
            flags,
        ) orelse return error.StreamCreateFailed;
        errdefer c.FSEventStreamRelease(self.stream);

        self.queue = c.dispatch_queue_create("something.fsevents", null) orelse
            return error.OutOfMemory;
        errdefer c.dispatch_release(.{ ._dq = self.queue });

        c.FSEventStreamSetDispatchQueue(self.stream, self.queue);
        if (c.FSEventStreamStart(self.stream) == 0) return error.StreamStartFailed;

        return self;
    }

    pub fn stop(self: *Watcher, allocator: std.mem.Allocator) void {
        c.FSEventStreamStop(self.stream);
        c.FSEventStreamInvalidate(self.stream);
        c.FSEventStreamRelease(self.stream);
        c.dispatch_release(.{ ._dq = self.queue });
        allocator.destroy(self);
    }
};

fn pathExists(path: [:0]const u8) bool {
    var st: std.c.Stat = undefined;
    return std.c.fstatat(std.c.AT.FDCWD, path.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0;
}

fn copyString(allocator: std.mem.Allocator, string: c.CFStringRef) ![:0]const u8 {
    const max: usize = @intCast(c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(string), c.kCFStringEncodingUTF8) + 1);
    const buf = try allocator.alloc(u8, max);
    if (c.CFStringGetCString(string, buf.ptr, @intCast(max), c.kCFStringEncodingUTF8) == 0) {
        return error.BadPath;
    }

    const len = std.mem.len(@as([*:0]const u8, @ptrCast(buf.ptr)));
    return buf[0..len :0];
}

fn fileId(entry: c.CFDictionaryRef, key: c.CFStringRef) u64 {
    const value = c.CFDictionaryGetValue(entry, key) orelse return 0;

    var id: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &id) == 0) return 0;
    return @bitCast(id);
}

fn readEvents(
    allocator: std.mem.Allocator,
    entries: c.CFArrayRef,
    flags: [*c]const c.FSEventStreamEventFlags,
    count: usize,
) ![]Raw {
    const raws = try allocator.alloc(Raw, count);

    // kFSEventStreamEventExtendedDataPathKey and ...FileIDKey are CFSTR macros that translate-c
    // can't evaluate, so the same two strings are made here.
    const pathKey = c.CFStringCreateWithCString(null, "path", c.kCFStringEncodingUTF8) orelse
        return error.OutOfMemory;
    defer c.CFRelease(pathKey);
    const idKey = c.CFStringCreateWithCString(null, "fileID", c.kCFStringEncodingUTF8) orelse
        return error.OutOfMemory;
    defer c.CFRelease(idKey);

    for (raws, 0..) |*raw, i| {
        const entry: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(entries, @intCast(i)));
        const path = c.CFDictionaryGetValue(entry, pathKey) orelse return error.BadPath;

        raw.* = .{
            .path = try copyString(allocator, @ptrCast(path)),
            .flags = flags[i],
            .id = fileId(entry, idKey),
        };
    }

    return raws;
}

fn callback(
    _: c.ConstFSEventStreamRef,
    info: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    eventFlags: [*c]const c.FSEventStreamEventFlags,
    _: [*c]const c.FSEventStreamEventId,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(info.?));

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const raws = readEvents(arena.allocator(), @ptrCast(eventPaths.?), eventFlags, numEvents) catch |err| {
        std.debug.print("watcher: dropped {d} events: {any}\n", .{ numEvents, err });
        return;
    };

    translate(raws, pathExists, self.handler, self.context);
}

const Collected = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,

    fn handler(context: ?*anyopaque, event: Event) void {
        const self: *Collected = @ptrCast(@alignCast(context.?));
        self.events.append(self.gpa, event) catch @panic("out of memory");
    }
};

// Paths below /gone do not exist, everything else does
fn fakeExists(path: [:0]const u8) bool {
    return !std.mem.startsWith(u8, path, "/gone");
}

const created = c.kFSEventStreamEventFlagItemCreated;
const removed = c.kFSEventStreamEventFlagItemRemoved;
const modified = c.kFSEventStreamEventFlagItemModified;
const renamedFlag = c.kFSEventStreamEventFlagItemRenamed;
const isFile = c.kFSEventStreamEventFlagItemIsFile;
const isDir = c.kFSEventStreamEventFlagItemIsDir;

test "the two halves of a rename become one move" {
    var raws = [_]Raw{
        .{ .path = "/gone/a.txt", .flags = renamedFlag | isFile, .id = 7 },
        .{ .path = "/w/b.txt", .flags = renamedFlag | isFile, .id = 7 },
        .{ .path = "/w/e", .flags = renamedFlag | isDir, .id = 8 },
        .{ .path = "/gone/d", .flags = renamedFlag | isDir, .id = 8 },
    };

    var collected = Collected{ .gpa = std.testing.allocator };
    defer collected.events.deinit(std.testing.allocator);
    translate(&raws, fakeExists, Collected.handler, &collected);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .move = .{ .from = "/gone/a.txt", .to = "/w/b.txt", .kind = .file } },
        .{ .move = .{ .from = "/gone/d", .to = "/w/e", .kind = .folder } },
    }, collected.events.items);
}

test "events without a partner, and coalesced flags" {
    var raws = [_]Raw{
        // Moved in from, or out of, the watched tree: only one half is reported
        .{ .path = "/w/in.txt", .flags = renamedFlag | isFile, .id = 1 },
        .{ .path = "/gone/out.txt", .flags = renamedFlag | isFile, .id = 2 },
        // The same id, but a file does not turn into a folder
        .{ .path = "/gone/x", .flags = renamedFlag | isFile, .id = 3 },
        .{ .path = "/w/x2", .flags = renamedFlag | isDir, .id = 3 },
        // Created and removed again before we looked, replaced by a new file, and only modified
        .{ .path = "/gone/short.txt", .flags = created | removed | isFile, .id = 4 },
        .{ .path = "/w/replaced.txt", .flags = removed | created | isFile, .id = 5 },
        .{ .path = "/w/changed.txt", .flags = modified | isFile, .id = 6 },
        // A new folder
        .{ .path = "/w/new", .flags = created | isDir, .id = 9 },
    };

    var collected = Collected{ .gpa = std.testing.allocator };
    defer collected.events.deinit(std.testing.allocator);
    translate(&raws, fakeExists, Collected.handler, &collected);

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .add = .{ .path = "/w/in.txt", .kind = .file } },
        .{ .remove = .{ .path = "/gone/out.txt", .kind = .file } },
        .{ .remove = .{ .path = "/gone/x", .kind = .file } },
        .{ .add = .{ .path = "/w/x2", .kind = .folder } },
        .{ .remove = .{ .path = "/gone/short.txt", .kind = .file } },
        .{ .add = .{ .path = "/w/replaced.txt", .kind = .file } },
        .{ .add = .{ .path = "/w/new", .kind = .folder } },
    }, collected.events.items);
}

const LiveState = struct {
    fileAdded: std.atomic.Value(bool) = .init(false),
    fileMoved: std.atomic.Value(bool) = .init(false),
    fileRemoved: std.atomic.Value(bool) = .init(false),
    folderAdded: std.atomic.Value(bool) = .init(false),
    folderMoved: std.atomic.Value(bool) = .init(false),
    folderRemoved: std.atomic.Value(bool) = .init(false),
};

fn liveHandler(context: ?*anyopaque, event: Event) void {
    const state: *LiveState = @ptrCast(@alignCast(context.?));
    switch (event) {
        .add => |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.path, "hello.txt")) state.fileAdded.store(true, .release);
            if (e.kind == .folder and std.mem.endsWith(u8, e.path, "folder-a")) state.folderAdded.store(true, .release);
        },
        .move => |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.from, "hello.txt") and std.mem.endsWith(u8, e.to, "renamed.txt"))
                state.fileMoved.store(true, .release);
            if (e.kind == .folder and std.mem.endsWith(u8, e.from, "folder-a") and std.mem.endsWith(u8, e.to, "folder-b"))
                state.folderMoved.store(true, .release);
        },
        .remove => |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.path, "renamed.txt")) state.fileRemoved.store(true, .release);
            if (e.kind == .folder and std.mem.endsWith(u8, e.path, "folder-b")) state.folderRemoved.store(true, .release);
        },
    }
}

fn waitFor(flag: *std.atomic.Value(bool), io: std.Io) !void {
    for (0..100) |_| {
        if (flag.load(.acquire)) return;
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    }
    return error.TimedOut;
}

fn pathIn(buf: []u8, root: []const u8, name: []const u8) ![:0]const u8 {
    return std.mem.printSentinel(buf, "{s}/{s}", .{ root, name }, 0);
}

test "reports adds, removes and moves of files and folders" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const root = buf[0..len];

    var state = LiveState{};
    const w = try Watcher.start(gpa, root, 0.05, liveHandler, &state);
    defer w.stop(gpa);

    var from: [std.posix.PATH_MAX]u8 = undefined;
    var to: [std.posix.PATH_MAX]u8 = undefined;

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hi" });
    try waitFor(&state.fileAdded, io);

    try std.testing.expectEqual(0, std.c.rename((try pathIn(&from, root, "hello.txt")).ptr, (try pathIn(&to, root, "renamed.txt")).ptr));
    try waitFor(&state.fileMoved, io);

    try tmp.dir.deleteFile(io, "renamed.txt");
    try waitFor(&state.fileRemoved, io);

    try std.testing.expectEqual(0, std.c.mkdir((try pathIn(&from, root, "folder-a")).ptr, 0o755));
    try waitFor(&state.folderAdded, io);

    try std.testing.expectEqual(0, std.c.rename((try pathIn(&from, root, "folder-a")).ptr, (try pathIn(&to, root, "folder-b")).ptr));
    try waitFor(&state.folderMoved, io);

    try std.testing.expectEqual(0, std.c.rmdir((try pathIn(&from, root, "folder-b")).ptr));
    try waitFor(&state.folderRemoved, io);
}
