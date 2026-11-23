const std = @import("std");
const c = @import("c");

pub const Event = struct {
    path: []const u8,
    flags: u32,

    pub fn has(self: Event, flag: u32) bool {
        return self.flags & flag != 0;
    }

    pub fn created(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemCreated);
    }
    pub fn removed(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemRemoved);
    }
    pub fn modified(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemModified);
    }
    pub fn renamed(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemRenamed);
    }
    pub fn isDir(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemIsDir);
    }
    pub fn isFile(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagItemIsFile);
    }
    /// The kernel dropped events, so the subtree under `path` must be rescanned.
    pub fn mustRescan(self: Event) bool {
        return self.has(c.kFSEventStreamEventFlagMustScanSubDirs);
    }
};

pub const Handler = *const fn (context: ?*anyopaque, event: Event) void;

pub const Watcher = struct {
    stream: c.FSEventStreamRef,
    queue: c.dispatch_queue_t,
    handler: Handler,
    context: ?*anyopaque,

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
        // NoDefer: deliver the first event of a burst right away.
        const flags: c.FSEventStreamCreateFlags =
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer;

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

fn callback(
    _: c.ConstFSEventStreamRef,
    info: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    eventFlags: [*c]const c.FSEventStreamEventFlags,
    _: [*c]const c.FSEventStreamEventId,
) callconv(.c) void {
    const self: *Watcher = @ptrCast(@alignCast(info.?));
    // Without kFSEventStreamCreateFlagUseCFTypes the paths are a plain C string array.
    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(eventPaths.?));

    for (0..numEvents) |i| {
        self.handler(self.context, .{
            .path = std.mem.span(paths[i]),
            .flags = eventFlags[i],
        });
    }
}

const TestState = struct {
    created: std.atomic.Value(bool) = .init(false),
    removed: std.atomic.Value(bool) = .init(false),
    modified: std.atomic.Value(bool) = .init(false),
};

fn testHandler(context: ?*anyopaque, event: Event) void {
    const state: *TestState = @ptrCast(@alignCast(context.?));
    if (!std.mem.endsWith(u8, event.path, "hello.txt")) return;
    if (event.created()) state.created.store(true, .release);
    if (event.modified()) state.modified.store(true, .release);
    if (event.removed()) state.removed.store(true, .release);
}

fn waitFor(flag: *std.atomic.Value(bool), io: std.Io) !void {
    for (0..100) |_| {
        if (flag.load(.acquire)) return;
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    }
    return error.TimedOut;
}

test "reports file creation, modification and removal" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const root = buf[0..len];

    var state = TestState{};
    const w = try Watcher.start(gpa, root, 0.05, testHandler, &state);
    defer w.stop(gpa);

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hi" });
    try waitFor(&state.created, io);

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello again" });
    try waitFor(&state.modified, io);

    try tmp.dir.deleteFile(io, "hello.txt");
    try waitFor(&state.removed, io);
}
