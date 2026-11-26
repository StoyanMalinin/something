//! What the index could not cover, kept so the server can tell clients: a folder the daemon is
//! not allowed to read (on macOS usually a missing Full Disk Access grant) is silently absent
//! from every search, which looks like a broken search to the user.
//!
//! A rebuild collects into its own tally and replaces the published one only when it succeeds,
//! so a warning does not flicker away while the index is being rebuilt. Everything else
//! (the first walk, rescans, failed watcher updates) records straight into the published one.
const std = @import("std");

/// Unreadable folders kept as examples. The shallowest ones are kept: they say the most.
pub const max_samples = 5;
const max_sample_len = 512;

pub const Tally = struct {
    /// Folders the daemon was not allowed to open
    unreadable: u32 = 0,
    /// Anything else that left part of the index out of date or incomplete
    failed: u32 = 0,
    sampleLens: [max_samples]u16 = @splat(0),
    sampleBytes: [max_samples][max_sample_len]u8 = undefined,
    sampleCount: u8 = 0,

    pub fn isEmpty(self: *const Tally) bool {
        return self.unreadable == 0 and self.failed == 0;
    }

    pub fn sample(self: *const Tally, i: usize) []const u8 {
        return self.sampleBytes[i][0..self.sampleLens[i]];
    }

    fn record(self: *Tally, kind: Kind, path: []const u8) void {
        switch (kind) {
            .unreadable => self.unreadable +|= 1,
            .failed => {
                self.failed +|= 1;
                return;
            },
        }

        const shown = path[0..@min(path.len, max_sample_len)];
        var slot: usize = self.sampleCount;
        if (slot < max_samples) {
            for (0..slot) |i| if (std.mem.eql(u8, self.sample(i), shown)) return;
            self.sampleCount += 1;
        } else {
            // Full: the longest one makes room for a shallower path
            slot = 0;
            for (0..max_samples) |i| {
                if (std.mem.eql(u8, self.sample(i), shown)) return;
                if (self.sampleLens[i] > self.sampleLens[slot]) slot = i;
            }
            if (shown.len >= self.sampleLens[slot]) return;
        }
        @memcpy(self.sampleBytes[slot][0..shown.len], shown);
        self.sampleLens[slot] = @intCast(shown.len);
    }
};

pub const Kind = enum { unreadable, failed };

var io: std.Io = undefined;
var mutex: std.Io.Mutex = .init;
var published: Tally = .{};
var pending: Tally = .{};
var collecting = false;

pub fn init(theIo: std.Io) void {
    io = theIo;
}

/// The caller is a rebuild: what it records only replaces the published tally on `end(true)`.
pub fn begin() void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    pending = .{};
    collecting = true;
}

pub fn end(succeeded: bool) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (succeeded) published = pending;
    collecting = false;
}

pub fn record(kind: Kind, path: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    (if (collecting) &pending else &published).record(kind, path);
}

/// The folder `path` could not be opened or read because of `err`
pub fn recordError(path: []const u8, err: anyerror) void {
    record(if (isDenied(err)) .unreadable else .failed, path);
}

/// EPERM (what macOS privacy protection answers with) and EACCES
pub fn isDenied(err: anyerror) bool {
    return err == error.PermissionDenied or err == error.AccessDenied;
}

pub fn snapshot() Tally {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return published;
}

/// `,"issues":{...}` for a response, or nothing when all is well
pub fn writeJson(out: *std.Io.Writer, tally: *const Tally) std.Io.Writer.Error!void {
    if (tally.isEmpty()) return;
    try out.print(",\"issues\":{{\"unreadable\":{d},\"failed\":{d},\"samples\":[", .{ tally.unreadable, tally.failed });
    for (0..tally.sampleCount) |i| {
        if (i > 0) try out.writeAll(",");
        try std.json.Stringify.encodeJsonString(tally.sample(i), .{}, out);
    }
    try out.writeAll("]}");
}

fn resetForTest() void {
    published = .{};
    pending = .{};
    collecting = false;
}

test "keeps the shallowest unreadable folders and counts them all" {
    io = std.testing.io;
    resetForTest();

    const deep = [_][]const u8{ "/a/b/c/d", "/a/b/c/e", "/a/b/c/f", "/a/b/c/g", "/a/b/c/h" };
    for (deep) |p| record(.unreadable, p);
    record(.unreadable, "/a/b");
    record(.unreadable, "/a/b"); // the same folder again: counted, not listed twice
    record(.failed, "/x");

    const t = snapshot();
    try std.testing.expectEqual(@as(u32, 7), t.unreadable);
    try std.testing.expectEqual(@as(u32, 1), t.failed);
    try std.testing.expectEqual(@as(u8, max_samples), t.sampleCount);
    var found = false;
    for (0..t.sampleCount) |i| found = found or std.mem.eql(u8, t.sample(i), "/a/b");
    try std.testing.expect(found);
}

test "a rebuild's tally replaces the published one only when it succeeds" {
    io = std.testing.io;
    resetForTest();
    record(.unreadable, "/old");

    begin();
    record(.unreadable, "/new1");
    record(.unreadable, "/new2");
    end(false);
    try std.testing.expectEqual(@as(u32, 1), snapshot().unreadable);

    begin();
    record(.failed, "/new");
    end(true);
    const t = snapshot();
    try std.testing.expectEqual(@as(u32, 0), t.unreadable);
    try std.testing.expectEqual(@as(u32, 1), t.failed);
}

test "writes nothing when there are no issues, and escaped JSON when there are" {
    io = std.testing.io;
    resetForTest();
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try writeJson(&w, &snapshot());
    try std.testing.expectEqualStrings("", w.buffered());

    record(.unreadable, "/Users/me/\"Library\"");
    try writeJson(&w, &snapshot());
    try std.testing.expectEqualStrings(
        ",\"issues\":{\"unreadable\":1,\"failed\":0,\"samples\":[\"/Users/me/\\\"Library\\\"\"]}",
        w.buffered(),
    );
}
