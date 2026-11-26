//! The query server: indexes the tree, keeps the index current, and answers queries on a
//! socket someone else bound. It never writes to disk or opens sockets, so it runs inside
//! the sandbox.
//!
//! Protocol, one query per connection:
//!   request:  "<limit>\t<query>\n"   (or just "<query>\n" for the default limit)
//!   response: one JSON object per line, best match first, then the server closes:
//!             {"score":123,"path":"/Users/me/work/main.zig"}
//!             Folder paths end with "/".
const std = @import("std");
const fileIndex = @import("file-index.zig");
const indexer = @import("indexer.zig");
const watcher = @import("watcher.zig");

const default_limit = 50;
const max_limit = 1000;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

fn parseRequest(line: []const u8) struct { limit: usize, query: []const u8 } {
    if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
        if (std.fmt.parseInt(usize, line[0..tab], 10)) |limit| {
            return .{ .limit = std.math.clamp(limit, 1, max_limit), .query = line[tab + 1 ..] };
        } else |_| {}
    }
    return .{ .limit = default_limit, .query = line };
}

fn serve(stream: std.Io.net.Stream) !void {
    var inBuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &inBuf);
    var outBuf: [16 * 1024]u8 = undefined;
    var writer = stream.writer(io, &outBuf);

    const line = (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return if (clientLeft(reader.err.?)) {} else reader.err.?,
        else => return err,
    }) orelse return;
    const request = parseRequest(line);
    const query = std.mem.trim(u8, request.query, " \t\r");
    if (query.len == 0) return;

    const results = try indexer.index.search(gpa, query, .{ .limit = request.limit });
    defer fileIndex.freeSearchResults(gpa, results);

    writeResults(&writer.interface, results) catch {
        // WriteFailed hides the cause, which the stream keeps
        return if (clientLeft(writer.err.?)) {} else writer.err.?;
    };
}

/// The client hung up before reading everything: Raycast does this to every query a
/// newer keystroke replaces. EPIPE surfaces as SocketUnconnected.
fn clientLeft(err: anyerror) bool {
    return err == error.SocketUnconnected or err == error.ConnectionResetByPeer;
}

fn writeResults(out: *std.Io.Writer, results: []const fileIndex.SearchResult) std.Io.Writer.Error!void {
    for (results) |r| {
        try out.print("{{\"score\":{d},\"path\":", .{r.score});
        try std.json.Stringify.encodeJsonString(r.path, .{}, out);
        try out.writeAll("}\n");
    }
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

pub const Server = struct {
    fsWatcher: *watcher.Watcher,

    /// Indexes everything under `root` (absolute) and starts watching it for changes.
    pub fn start(allocator: std.mem.Allocator, theIo: std.Io, root: []const u8) !Server {
        gpa = allocator;
        io = theIo;
        raiseOpenFileLimit();
        return .{ .fsWatcher = try indexer.start(gpa, io, root) };
    }

    pub fn stop(self: *Server) void {
        self.fsWatcher.stop(gpa);
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
