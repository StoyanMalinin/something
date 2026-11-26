//! The part of the daemon that is allowed to do dangerous things: write to disk and open
//! sockets. It binds the socket, enters the sandbox, and only then hands the socket to `server`,
//! which indexes the tree and answers queries; from that point the process can only read.
//!
//! Usage: something-daemon [root]
//! Socket: $SOMETHING_SOCKET, or ~/Library/Caches/something/daemon.sock
//! Config: $SOMETHING_CONFIG, or ~/Library/Application Support/something/config.json
//!         Only the daemon writes it (see config.zig). `root`, or / without it, is only what a
//!         config file that does not exist yet starts out including. The default is / without
//!         /System/Volumes/Data.
const std = @import("std");
const sandbox = @import("sandbox.zig");
const server = @import("server.zig");
const config = @import("config.zig");

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

fn configPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const path = if (env.get("SOMETHING_CONFIG")) |p| p else blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "something", "config.json" });
    };

    const dir = std.fs.path.dirname(path) orelse return error.BadConfigPath;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // The sandbox matches real paths, so a symlinked folder has to be resolved
    return std.fs.path.join(arena, &.{ try std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena), std.fs.path.basename(path) });
}

/// Everything that needs to write to disk or open sockets: create the socket directory,
/// remove a stale socket, bind. The indexer and the file watcher only read, so they start
/// after the sandbox is entered. Connections made while it indexes wait in the socket's
/// backlog until `server.run` starts accepting.
fn bindSocket(init: std.process.Init) !std.Io.net.Server {
    const arena = init.arena.allocator();
    const sockPath = try socketPath(arena, init.environ_map);

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
    const listener = try address.listen(io, .{});
    std.debug.print("Listening on {s}\n", .{sockPath});
    return listener;
}

/// Gives up network and disk writes for the rest of the process's life. SOMETHING_NO_SANDBOX
/// is an escape hatch for debugging (profilers and tracers write files).
fn enterSandbox(init: std.process.Init, store: *const config.Store) !void {
    if (init.environ_map.get("SOMETHING_NO_SANDBOX") != null) return;

    const tmp = try config.tempPath(gpa, store.path);
    defer gpa.free(tmp);
    try sandbox.enter(gpa, &.{ store.path, tmp });
    std.debug.print("Sandboxed: no network, no disk writes except the config file\n", .{});
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len > 1) args[1] else "/", arena);
    const home = init.environ_map.get("HOME") orelse return error.NoHome;

    // Created now, with the root as its only include, if it does not exist
    var store = try config.Store.open(gpa, io, try configPath(arena, init.environ_map), home, .{
        .include = if (args.len > 1) &.{root} else config.default_include,
        .exclude = config.default_exclude,
        .limit = config.default_limit,
    });
    defer store.deinit();

    var listener = try bindSocket(init);
    defer listener.deinit(io);

    try enterSandbox(init, &store);

    // From here on the process can only read, and write its config file
    var srv = try server.Server.start(gpa, io, &store);
    defer srv.stop();
    try srv.serve(&listener);
}
