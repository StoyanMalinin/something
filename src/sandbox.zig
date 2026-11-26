//! Drops the daemon's ability to use the network or write to disk.
//!
//! Called once startup is done: by then the socket is bound, which was the only network
//! operation the daemon needs. From then on it only reads the file tree, keeps the index in
//! memory and accepts connections on the socket it already has. The one thing it may still
//! write is its config file.
//! Logging keeps working because stdout/stderr are file descriptors opened by launchd.
//!
//! This uses sandbox_init, which Apple has deprecated but not removed; Chrome and
//! Firefox use it the same way. The profile is allow-by-default with the two capabilities
//! denied, so it cannot break the FSEvents or file-reading paths by omission.
const std = @import("std");

extern fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern fn sandbox_free_error(errorbuf: [*:0]u8) void;

const profile =
    \\(version 1)
    \\(allow default)
    \\(deny network*)
    \\(deny file-write*)
    \\(allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper"))
    \\(allow network-inbound (local unix-socket))
    \\
;

/// Enters the sandbox. `writable` are the files that may still be written, created and
/// removed: the config file and the temporary one it is replaced through.
pub fn enter(gpa: std.mem.Allocator, writable: []const []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, profile);
    for (writable) |path| {
        // The path goes into a quoted string of the profile
        if (std.mem.indexOfAny(u8, path, "\"\\\n") != null) return error.BadPath;
        try text.print(gpa, "(allow file-write* (literal \"{s}\"))\n", .{path});
    }
    const profileZ = try gpa.dupeSentinel(u8, text.items, 0);
    defer gpa.free(profileZ);

    var err: ?[*:0]u8 = null;
    // flags 0: `profile` is the profile text itself, not the name of a built-in one
    if (sandbox_init(profileZ.ptr, 0, &err) != 0) {
        if (err) |msg| {
            defer sandbox_free_error(msg);
            std.debug.print("sandbox_init failed: {s}\n", .{msg});
        }
        return error.SandboxFailed;
    }
}
