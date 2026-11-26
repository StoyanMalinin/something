//! The query server: indexes the tree, keeps the index current, and answers queries on a
//! socket someone else bound. It never writes to disk or opens sockets, so it runs inside
//! the sandbox.
//!
//! Protocol, one request per connection:
//!   request:  one JSON object on a line, with a "command" field:
//!             {"command":"search","query":"main.zig","limit":50}   ("limit" is optional: the
//!                                              config's limit is the default)
//!             {"command":"version"}
//!             {"command":"config"}                 the config, as the daemon has it
//!             {"command":"setConfig","config":{"include":["/Users/me"],"exclude":["node_modules"],"limit":30}}
//!                 Any field of "config" can be left out to keep it. The daemon checks, saves and
//!                 applies it, and answers with the config as saved. A change to the includes or
//!                 excludes rebuilds the index in the background; searches go on meanwhile.
//!             {"command":"status"}                 whether the index is being rebuilt
//!   response: one JSON object on a line, then the server closes. It always has a "version"
//!             field, errors included, so a client can check it before reading anything else:
//!             {"version":3,"matches":[{"score":123,"path":"/Users/me/work/main.zig"}]}
//!             {"version":3}
//!             {"version":3,"config":{"include":[...],"exclude":[...],"limit":50}}
//!             {"version":3,"indexing":false}
//!             {"version":3,"error":"unknown command: foo"}
//!             Matches are best first. Folder paths end with "/".
//!   Search and status responses also have an "issues" field, only when something is wrong:
//!             "issues":{"unreadable":12,"failed":0,"samples":["/Users/me/Library/Mail"]}
//!             "unreadable" counts folders the daemon may not open (on macOS: no Full Disk
//!             Access), whose files are missing from the results. "failed" counts other errors
//!             that left the index incomplete or stale. "samples" lists a few unreadable folders,
//!             shallowest first.
//!   The config lives in a file the daemon alone writes, see config.zig.
//!   Bump `protocol_version` when a change would break an older client; unknown fields in a
//!   request are ignored, unknown commands get an error response.
const std = @import("std");
const fileIndex = @import("file-index.zig");
const indexer = @import("indexer.zig");
const config = @import("config.zig");
const issues = @import("issues.zig");

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

/// 2: the config, setConfig and status commands; the search limit defaults to the config's.
/// 3: search and status responses carry an "issues" field when part of the tree could not be read.
pub const protocol_version = 3;

var store: *config.Store = undefined;

const Request = struct {
    command: ?[]const u8 = null,
    query: ?[]const u8 = null,
    limit: ?i64 = null,
    config: ?config.Wire = null,
};

fn serve(stream: std.Io.net.Stream) !void {
    // Room for a long list of folders in setConfig
    var inBuf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &inBuf);
    var outBuf: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &outBuf);

    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return if (clientLeft(reader.err.?)) {} else reader.err.?,
        error.StreamTooLong => {
            return finish(&writer, writeError(&writer.interface, "request too long"));
        },
    } orelse return;

    const parsed = std.json.parseFromSlice(Request, gpa, line, .{ .ignore_unknown_fields = true }) catch {
        return finish(&writer, writeError(&writer.interface, "request is not a valid JSON object"));
    };
    defer parsed.deinit();
    const request = parsed.value;

    const command = request.command orelse {
        return finish(&writer, writeError(&writer.interface, "missing \"command\" field"));
    };

    if (std.mem.eql(u8, command, "version")) {
        return finish(&writer, writeVersion(&writer.interface));
    }
    if (std.mem.eql(u8, command, "search")) {
        const query = std.mem.trim(u8, request.query orelse "", " \t\r");
        const limit: usize = if (request.limit) |l|
            @intCast(std.math.clamp(l, 1, config.max_limit))
        else
            store.limit.load(.monotonic);
        if (query.len == 0) return finish(&writer, writeResults(&writer.interface, &.{}));

        const results = try indexer.index.search(gpa, query, .{ .limit = limit });
        defer fileIndex.freeSearchResults(gpa, results);
        return finish(&writer, writeResults(&writer.interface, results));
    }

    if (std.mem.eql(u8, command, "config")) {
        var current = try store.snapshot();
        defer current.deinit();
        return finish(&writer, writeConfig(&writer.interface, current.value));
    }
    if (std.mem.eql(u8, command, "setConfig")) {
        const wire = request.config orelse {
            return finish(&writer, writeError(&writer.interface, "missing \"config\" field"));
        };
        var diag: config.Diagnostic = .{};
        var change = store.update(wire, &diag) catch |err| switch (err) {
            error.InvalidConfig => return finish(&writer, writeError(&writer.interface, diag.message())),
            else => {
                std.debug.print("config: saving failed: {any}\n", .{err});
                return finish(&writer, writeError(&writer.interface, "could not save the config"));
            },
        };
        defer change.config.deinit();
        if (change.scopeChanged) requestReindex();
        return finish(&writer, writeConfig(&writer.interface, change.config.value));
    }
    if (std.mem.eql(u8, command, "status")) {
        return finish(&writer, writeStatus(&writer.interface, isIndexing()));
    }

    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "unknown command: {s}", .{command[0..@min(command.len, 100)]}) catch "unknown command";
    return finish(&writer, writeError(&writer.interface, message));
}

/// WriteFailed hides the cause, which the stream keeps
fn finish(writer: *std.Io.net.Stream.Writer, result: std.Io.Writer.Error!void) !void {
    result catch return if (clientLeft(writer.err.?)) {} else writer.err.?;
}

/// The client hung up before reading everything: Raycast does this to every query a
/// newer keystroke replaces. EPIPE surfaces as SocketUnconnected.
fn clientLeft(err: anyerror) bool {
    return err == error.SocketUnconnected or err == error.ConnectionResetByPeer;
}

fn writeVersion(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{{\"version\":{d}}}\n", .{protocol_version});
    try out.flush();
}

fn writeConfig(out: *std.Io.Writer, cfg: config.Config) std.Io.Writer.Error!void {
    try out.print("{{\"version\":{d},\"config\":", .{protocol_version});
    try std.json.Stringify.value(cfg, .{}, out);
    try out.writeAll("}\n");
    try out.flush();
}

fn writeStatus(out: *std.Io.Writer, indexing: bool) std.Io.Writer.Error!void {
    try out.print("{{\"version\":{d},\"indexing\":{}", .{ protocol_version, indexing });
    try issues.writeJson(out, &issues.snapshot());
    try out.writeAll("}\n");
    try out.flush();
}

fn writeError(out: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    try out.print("{{\"version\":{d},\"error\":", .{protocol_version});
    try std.json.Stringify.encodeJsonString(message, .{}, out);
    try out.writeAll("}\n");
    try out.flush();
}

fn writeResults(out: *std.Io.Writer, results: []const fileIndex.SearchResult) std.Io.Writer.Error!void {
    try out.print("{{\"version\":{d},\"matches\":[", .{protocol_version});
    for (results, 0..) |r, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("{{\"score\":{d},\"path\":", .{r.score});
        try std.json.Stringify.encodeJsonString(r.path, .{}, out);
        try out.writeAll("}");
    }
    try out.writeAll("]");
    try issues.writeJson(out, &issues.snapshot());
    try out.writeAll("}\n");
    try out.flush();
}

fn handle(stream: std.Io.net.Stream) void {
    defer stream.close(io);
    serve(stream) catch |err| std.debug.print("query failed: {any}\n", .{err});
}

/// The walk keeps up to `initial_dirs` (256) folders open while it spreads them over the
/// walker threads, plus one per level of depth for each thread: about 350-400 in practice.
/// launchd starts jobs with a soft limit of 256 open files (a shell usually allows far
/// more), so raise ours to 1024, or whatever the hard limit allows.
fn raiseOpenFileLimit() void {
    const wanted: std.posix.rlim_t = 1024;
    var limits = std.posix.getrlimit(.NOFILE) catch return;
    if (limits.cur >= wanted) return;

    limits.cur = @min(wanted, limits.max);
    std.posix.setrlimit(.NOFILE, limits) catch |err| {
        std.debug.print("could not raise the open file limit: {any}\n", .{err});
    };
}

/// Rebuilds the index for the current config, off the request that asked for it. Changes that
/// arrive while it runs are picked up by one more round, so a burst of edits costs two rebuilds
/// at most.
var reindexMutex: std.Io.Mutex = .init;
var reindexRunning = false;
var reindexAgain = false;

fn requestReindex() void {
    reindexMutex.lockUncancelable(io);
    defer reindexMutex.unlock(io);

    if (reindexRunning) {
        reindexAgain = true;
        return;
    }
    const thread = std.Thread.spawn(.{}, reindexLoop, .{}) catch |err| {
        std.debug.print("config: cannot start the reindex: {any}\n", .{err});
        return;
    };
    reindexRunning = true;
    thread.detach();
}

fn reindexLoop() void {
    while (true) {
        if (store.snapshot()) |snapshot| {
            var current = snapshot;
            defer current.deinit();
            indexer.reconfigure(current.value) catch |err| std.debug.print("config: reindex failed: {any}\n", .{err});
        } else |err| std.debug.print("config: reindex failed: {any}\n", .{err});

        reindexMutex.lockUncancelable(io);
        defer reindexMutex.unlock(io);
        if (!reindexAgain) {
            reindexRunning = false;
            return;
        }
        reindexAgain = false;
    }
}

fn isIndexing() bool {
    reindexMutex.lockUncancelable(io);
    defer reindexMutex.unlock(io);
    return reindexRunning;
}

pub const Server = struct {
    /// Indexes what the config in `configStore` includes and starts watching it for changes.
    pub fn start(allocator: std.mem.Allocator, theIo: std.Io, configStore: *config.Store) !Server {
        gpa = allocator;
        io = theIo;
        store = configStore;
        raiseOpenFileLimit();

        var current = try store.snapshot();
        defer current.deinit();
        try indexer.start(gpa, io, current.value);
        return .{};
    }

    pub fn stop(self: *Server) void {
        _ = self;
        indexer.stop();
    }

    /// Answers queries on the already-bound socket until accept fails.
    pub fn serve(self: *Server, listener: *std.Io.net.Server) !void {
        _ = self;
        var group: std.Io.Group = .init;
        defer group.cancel(io);

        while (true) {
            const stream = listener.accept(io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            // A slow client must not hold up the others
            group.concurrent(io, handle, .{stream}) catch handle(stream);
        }
    }
};
