//! The query server: indexes the tree, keeps the index current, and answers queries on a
//! socket someone else bound. It never writes to disk or opens sockets, so it runs inside
//! the sandbox.
//!
//! Protocol, one request per connection:
//!   request:  one JSON object on a line, with a "command" field:
//!             {"command":"search","query":"main.zig","limit":50}   ("limit" is optional)
//!             {"command":"version"}
//!   response: one JSON object on a line, then the server closes. It always has a "version"
//!             field, errors included, so a client can check it before reading anything else:
//!             {"version":1,"matches":[{"score":123,"path":"/Users/me/work/main.zig"}]}
//!             {"version":1}
//!             {"version":1,"error":"unknown command: foo"}
//!             Matches are best first. Folder paths end with "/".
//!   Bump `protocol_version` when a change would break an older client; unknown fields in a
//!   request are ignored, unknown commands get an error response.
const std = @import("std");
const fileIndex = @import("file-index.zig");
const indexer = @import("indexer.zig");
const watcher = @import("watcher.zig");

const default_limit = 50;
const max_limit = 1000;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

pub const protocol_version = 1;

const Request = struct {
    command: ?[]const u8 = null,
    query: ?[]const u8 = null,
    limit: ?i64 = null,
};

fn serve(stream: std.Io.net.Stream) !void {
    var inBuf: [4096]u8 = undefined;
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
        const limit: usize = @intCast(std.math.clamp(request.limit orelse default_limit, 1, max_limit));
        if (query.len == 0) return finish(&writer, writeResults(&writer.interface, &.{}));

        const results = try indexer.index.search(gpa, query, .{ .limit = limit });
        defer fileIndex.freeSearchResults(gpa, results);
        return finish(&writer, writeResults(&writer.interface, results));
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
    try out.writeAll("]}\n");
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
