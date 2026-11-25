//! Keeps the index in memory and answers queries over a Unix socket.
//!
//! Usage: something-daemon [root]   (root defaults to /)
//! Socket: $SOMETHING_SOCKET, or ~/Library/Caches/something/daemon.sock
//!
//! Protocol, one query per connection:
//!   request:  "<limit>\t<query>\n"   (or just "<query>\n" for the default limit)
//!   response: one JSON object per line, best match first, then the server closes:
//!             {"score":123,"path":"/Users/me/work/main.zig"}
//!             Folder paths end with "/".
const std = @import("std");
const fileIndex = @import("file-index.zig");
const indexer = @import("indexer.zig");

const default_limit = 50;
const max_limit = 1000;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

fn socketPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("SOMETHING_SOCKET")) |p| return p;

    const home = env.get("HOME") orelse return error.NoHome;
    const dir = try std.fs.path.join(arena, &.{ home, "Library", "Caches", "something" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // Only we may connect: the answers list every file name we can see
    const dirZ = try arena.dupeSentinel(u8, dir, 0);
    _ = std.c.chmod(dirZ.ptr, 0o700);

    return std.fs.path.join(arena, &.{ dir, "daemon.sock" });
}

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

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len > 1) args[1] else "/", arena);
    const sockPath = try socketPath(arena, init.environ_map);

    const fsWatcher = try indexer.start(gpa, io, root);
    defer fsWatcher.stop(gpa);

    // Left behind by an earlier run that did not shut down cleanly
    std.Io.Dir.cwd().deleteFile(io, sockPath) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    // sun_path holds 104 bytes on macOS, less than UnixAddress.max_len allows
    if (sockPath.len >= 104) {
        std.debug.print("socket path too long ({d} bytes, max 103): {s}\n", .{ sockPath.len, sockPath });
        return error.NameTooLong;
    }
    const address = try std.Io.net.UnixAddress.init(sockPath);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    std.debug.print("Listening on {s}\n", .{sockPath});

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        // A slow client must not hold up the others
        group.concurrent(io, handle, .{stream}) catch handle(stream);
    }
}
