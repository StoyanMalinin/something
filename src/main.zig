const std = @import("std");
const fileIndex = @import("file-index.zig");
const trie = @import("trie.zig");
const indexer = @import("indexer.zig");
const watcher = @import("watcher.zig");
const walk = @import("walk.zig");
const config = @import("config.zig");

var index: *fileIndex.FileIndex = undefined;

var gpa: std.mem.Allocator = undefined;
var io: std.Io = undefined;

fn queryLoop() !void {
    var buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &buf);

    while (true) {
        std.debug.print("query (:q or ctrl-d to quit)> ", .{});

        const line = (try stdin.interface.takeDelimiter('\n')) orelse return;
        const word = std.mem.trim(u8, line, " \t\r");
        if (word.len == 0) continue;
        if (std.mem.eql(u8, word, ":q")) return;

        const startTime = std.Io.Clock.awake.now(io);
        const searchResult = try index.search(gpa, word, .{ .limit = 10 });
        const endTime = std.Io.Clock.awake.now(io);

        // Microsecond resolution: many queries take a few milliseconds (scripts/bench.sh reads this)
        const micros: u64 = @intCast(startTime.durationTo(endTime).toMicroseconds());
        std.debug.print("{d} matches in {d}.{d:0>3}ms\n", .{ searchResult.len, micros / 1000, micros % 1000 });
        if (trie.collect_stats) {
            const s = index.trie.stats;
            std.debug.print(
                "stats: internal {d} seen {d} pruned, leaves {d} seen {d} pruned, bytes fed {d} internal {d} leaf, {d} pruned, finals {d} seen {d} scored {d} kept, bound misses {d}\n",
                .{ s.internal_seen, s.internal_pruned, s.leaves_seen, s.leaves_pruned, s.internal_bytes_fed, s.leaf_bytes_fed, s.bytes_pruned, s.finals_seen, s.finals_scored, s.finals_kept, s.bound_misses },
            );
        }
        for (searchResult) |result| {
            std.debug.print("{d} {s}\n", .{ result.score, result.path });
        }

        for (searchResult) |result| {
            gpa.free(result.path);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = try std.Io.Dir.cwd().realPathFileAlloc(io, if (args.len > 1) args[1] else "/", init.arena.allocator());

    try indexer.start(gpa, io, .{ .include = &.{path}, .exclude = config.default_exclude, .limit = config.default_limit });
    defer indexer.stop();
    index = indexer.index;

    const passsthroughCnt = index.trie.scanPassthoughNodes();
    const allCnt = index.trie.scanAllNodes();
    const ratio = @as(f64, @floatFromInt(passsthroughCnt)) / @as(f64, @floatFromInt(allCnt));
    std.debug.print("Passthrough nodes are {d} / {d} = {d:.2}\n", .{
        passsthroughCnt,
        allCnt,
        ratio,
    });
    var childHist: [257]usize = undefined;
    index.trie.scanChildCounts(&childHist);
    std.debug.print("Children per node (count: nodes):\n", .{});
    for (childHist, 0..) |n, k| {
        if (n == 0) continue;
        const plus: []const u8 = if (k == childHist.len - 1) "+" else "";
        std.debug.print("  {d}{s}: {d}\n", .{ k, plus, n });
    }
    std.debug.print("Total chars used are {d}\n", .{index.trie.scanTotalCharCount()});
    std.debug.print("Total direct data used for nodes {d}\n", .{index.trie.scanSize()});

    try queryLoop();

    // The index is deliberately never freed. On return, the leak checker would print a stack
    // trace (loading DWARF each time) for every allocation, which takes minutes and stalls
    // profiling and benchmark runs. Debug and ReleaseSafe builds still report leaks.
    if (@import("builtin").mode == .fast) std.process.exit(0);
}

test {
    // Pull in the other files' tests; `zig build test` is rooted here
    _ = fileIndex;
    _ = indexer;
    _ = trie;
    _ = watcher;
    _ = walk;
    _ = config;
}
