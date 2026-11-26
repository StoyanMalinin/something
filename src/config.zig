//! The daemon's configuration: which folders to index, what to leave out, and how many results
//! a query returns.
//!
//! It lives in one JSON file that only the daemon writes (read-only mode, replaced atomically).
//! Everything else, the Raycast extension included, reads the file and asks the daemon to change
//! it with the "setConfig" command. The daemon does not watch the file: it reads it at startup,
//! and from then on its own copy is the truth.
//!
//!   {
//!     "version": 1,
//!     "include": ["/Users/me"],
//!     "exclude": ["/Users/me/Library", "node_modules"],
//!     "limit": 50
//!   }
//!
//! An include is an absolute folder (`~` stands for the home folder). An exclude is either an
//! absolute path, which leaves that file or folder, and everything under it, out; or a bare name
//! with no slash, which leaves out every file or folder of that name below an include.
const std = @import("std");

pub const default_limit = 50;
pub const max_limit = 1000;
pub const file_version = 1;

/// What a new install indexes: everything, except the data volume, which macOS also shows
/// under /Users, /Applications and the like (firmlinks), so it would be indexed twice.
pub const default_include: []const []const u8 = &.{"/"};
pub const default_exclude: []const []const u8 = &.{"/System/Volumes/Data"};

pub const Config = struct {
    include: []const []const u8,
    exclude: []const []const u8,
    limit: usize,
};

/// A config together with the memory behind its strings.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Config,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }

    pub fn clone(self: Owned, gpa: std.mem.Allocator) !Owned {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const value: Config = .{
            .include = try dupeAll(arena.allocator(), self.value.include),
            .exclude = try dupeAll(arena.allocator(), self.value.exclude),
            .limit = self.value.limit,
        };
        return .{ .arena = arena, .value = value };
    }
};

fn dupeAll(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try allocator.dupe(u8, item);
    return out;
}

/// What a person or a client may send: any field can be left out.
pub const Wire = struct {
    include: ?[]const []const u8 = null,
    exclude: ?[]const []const u8 = null,
    limit: ?i64 = null,
};

/// Why a config was refused, in words for whoever wrote it.
pub const Diagnostic = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    fn fail(self: *Diagnostic, comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
        const text = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..];
        self.len = text.len;
        return error.InvalidConfig;
    }
};

/// Resolves `.` and `..` without touching the disk, and drops repeated and trailing slashes.
fn normalizeAbsolute(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    if (parts.items.len == 0) return "/";

    var out: std.ArrayList(u8) = .empty;
    for (parts.items) |part| {
        try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    return out.items;
}

fn expandHome(arena: std.mem.Allocator, home: []const u8, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "~")) return home;
    if (std.mem.startsWith(u8, raw, "~/")) return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, raw[2..] });
    return raw;
}

fn isPathEntry(raw: []const u8) bool {
    return raw[0] == '/' or raw[0] == '~' or std.mem.indexOfScalar(u8, raw, '/') != null;
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, item)) return;
    }
    try list.append(arena, item);
}

fn normalizeIncludes(arena: std.mem.Allocator, home: []const u8, raw: []const []const u8, diag: *Diagnostic) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;

        const expanded = try expandHome(arena, home, trimmed);
        if (expanded[0] != '/') return diag.fail("include \"{s}\" is not an absolute folder path", .{trimmed});
        try appendUnique(arena, &out, try normalizeAbsolute(arena, expanded));
    }
    if (out.items.len == 0) return diag.fail("include at least one folder to index", .{});
    return out.items;
}

fn normalizeExcludes(arena: std.mem.Allocator, home: []const u8, raw: []const []const u8, diag: *Diagnostic) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (raw) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (!isPathEntry(trimmed)) {
            if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) {
                return diag.fail("exclude \"{s}\" is not a name or an absolute path", .{trimmed});
            }
            try appendUnique(arena, &out, try arena.dupe(u8, trimmed));
            continue;
        }

        const expanded = try expandHome(arena, home, trimmed);
        if (expanded[0] != '/') return diag.fail("exclude \"{s}\" must be an absolute path or a bare name", .{trimmed});
        try appendUnique(arena, &out, try normalizeAbsolute(arena, expanded));
    }
    return out.items;
}

/// Checks `wire` and fills what it leaves out from `base`. Everything in the result is
/// allocated from `arena`.
pub fn normalize(arena: std.mem.Allocator, home: []const u8, wire: Wire, base: Config, diag: *Diagnostic) !Config {
    const limit: usize = if (wire.limit) |l| blk: {
        if (l < 1 or l > max_limit) return diag.fail("limit must be between 1 and {d}", .{max_limit});
        break :blk @intCast(l);
    } else base.limit;

    return .{
        .include = if (wire.include) |raw| try normalizeIncludes(arena, home, raw, diag) else try dupeAll(arena, base.include),
        .exclude = if (wire.exclude) |raw| try normalizeExcludes(arena, home, raw, diag) else try dupeAll(arena, base.exclude),
        .limit = limit,
    };
}

/// Parses and checks the text of a config file; missing fields take their value from `base`.
pub fn parse(gpa: std.mem.Allocator, home: []const u8, text: []const u8, base: Config, diag: *Diagnostic) !Owned {
    const parsed = std.json.parseFromSlice(Wire, gpa, text, .{ .ignore_unknown_fields = true }) catch
        return diag.fail("not a valid JSON config", .{});
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = try normalize(arena.allocator(), home, parsed.value, base, diag);
    return .{ .arena = arena, .value = value };
}

/// Whether two configs cover the same files, so the index does not need to be rebuilt.
pub fn sameScope(a: Config, b: Config) bool {
    return sameList(a.include, b.include) and sameList(a.exclude, b.exclude);
}

fn sameList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn isUnder(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// What the config means for walking and watching: the folders to start from, and a quick way to
/// ask whether something is left out.
pub const Filter = struct {
    arena: std.heap.ArenaAllocator,
    /// Where to walk and watch: the includes that are not left out themselves, and not inside
    /// another include.
    roots: []const []const u8,
    /// Absolute excludes
    paths: []const []const u8,
    /// Bare-name excludes
    names: std.StringHashMapUnmanaged(void),
    /// Folder -> names left out inside it, for the absolute excludes. Lets a walk ask once per
    /// folder instead of once per entry.
    inside: std.StringHashMapUnmanaged([]const []const u8),

    pub fn init(gpa: std.mem.Allocator, cfg: Config) !Filter {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var paths: std.ArrayList([]const u8) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (cfg.exclude) |entry| {
            if (isPathEntry(entry)) {
                try paths.append(a, try a.dupe(u8, entry));
            } else {
                try names.put(a, try a.dupe(u8, entry), {});
            }
        }

        var inside_lists: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (paths.items) |p| {
            if (std.mem.eql(u8, p, "/")) continue;
            const slash = std.mem.lastIndexOfScalar(u8, p, '/').?;
            const parent = if (slash == 0) "/" else p[0..slash];
            const entry = try inside_lists.getOrPut(a, parent);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(a, p[slash + 1 ..]);
        }
        var inside: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        var it = inside_lists.iterator();
        while (it.next()) |e| try inside.put(a, e.key_ptr.*, e.value_ptr.items);

        var self: Filter = .{ .arena = arena, .roots = &.{}, .paths = paths.items, .names = names, .inside = inside };

        var roots: std.ArrayList([]const u8) = .empty;
        for (cfg.include, 0..) |candidate, i| {
            if (self.excludedByPath(candidate)) continue;

            var covered = false;
            for (cfg.include, 0..) |other, j| {
                if (i == j) continue;
                // Of two roots where one holds the other, the outer one walks both
                if (isUnder(candidate, other) and (candidate.len != other.len or j < i)) covered = true;
            }
            if (!covered) try roots.append(a, try a.dupe(u8, candidate));
        }
        self.roots = roots.items;
        return self;
    }

    pub fn deinit(self: *Filter) void {
        self.arena.deinit();
    }

    fn excludedByPath(self: *const Filter, path: []const u8) bool {
        for (self.paths) |p| {
            if (isUnder(path, p)) return true;
        }
        return false;
    }

    /// The names left out inside the folder `dir` by absolute excludes. Usually none.
    pub fn leftOutIn(self: *const Filter, dir: []const u8) []const []const u8 {
        if (self.inside.count() == 0) return &.{};
        return self.inside.get(dir) orelse &.{};
    }

    /// Whether an entry called `name` is left out, either by a bare name or because it is one of
    /// `leftOut`, what `leftOutIn` said about the folder it is in.
    pub fn skips(self: *const Filter, leftOut: []const []const u8, name: []const u8) bool {
        for (leftOut) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return self.names.count() != 0 and self.names.contains(name);
    }

    /// Whether the absolute `path` is left out: it is, or is below, an excluded path, or some
    /// folder between its include and it has an excluded name.
    pub fn excludes(self: *const Filter, path: []const u8) bool {
        if (self.excludedByPath(path)) return true;
        if (self.names.count() == 0) return false;

        for (self.roots) |root| {
            if (!isUnder(path, root)) continue;
            const below = std.mem.trimStart(u8, path[root.len..], "/");
            var it = std.mem.tokenizeScalar(u8, below, '/');
            while (it.next()) |part| {
                if (self.names.contains(part)) return true;
            }
            return false;
        }
        return false;
    }

    /// Whether `path` is one of the roots, or inside one.
    pub fn covers(self: *const Filter, path: []const u8) bool {
        for (self.roots) |root| {
            if (isUnder(path, root)) return true;
        }
        return false;
    }

    /// Whether `path` is a root or above one, so everything indexed is at or below it.
    pub fn isAboveRoot(self: *const Filter, path: []const u8) bool {
        for (self.roots) |root| {
            if (isUnder(root, path)) return true;
        }
        return false;
    }
};

/// The file a `Config` is stored in, and the copy of it the daemon works from. The daemon is the
/// only writer.
pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    /// What a "~" in the config stands for
    home: []const u8,
    /// Guards `current` and the file
    mutex: std.Io.Mutex = .init,
    current: Owned,
    /// Mirrors `current.value.limit`, so queries read it without the lock
    limit: std.atomic.Value(usize),

    /// Loads the config at `path`. If there is none yet it is created from `initial`, which is
    /// why this runs before the sandbox. A file that cannot be read or is invalid is reported and
    /// replaced in memory by `initial`; it is left on disk for its author to fix, until the next
    /// change saves over it.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8, initial: Config) !Store {
        const ownedPath = try gpa.dupe(u8, path);
        errdefer gpa.free(ownedPath);
        const ownedHome = try gpa.dupe(u8, home);
        errdefer gpa.free(ownedHome);

        var self: Store = .{
            .gpa = gpa,
            .io = io,
            .path = ownedPath,
            .home = ownedHome,
            .current = undefined,
            .limit = undefined,
        };

        var diag: Diagnostic = .{};
        const loaded: ?Owned = blk: {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
                error.FileNotFound => break :blk null,
                else => {
                    std.debug.print("config: cannot read {s}: {any}\n", .{ path, err });
                    break :blk try cloneConfig(gpa, initial);
                },
            };
            defer gpa.free(text);
            break :blk parse(gpa, home, text, initial, &diag) catch |err| switch (err) {
                error.InvalidConfig => {
                    std.debug.print("config: {s} is invalid ({s}); using the defaults\n", .{ path, diag.message() });
                    break :blk try cloneConfig(gpa, initial);
                },
                else => return err,
            };
        };

        if (loaded) |owned| {
            self.current = owned;
        } else {
            self.current = try cloneConfig(gpa, initial);
            errdefer self.current.deinit();
            try self.writeFile(self.current.value);
            std.debug.print("config: created {s}\n", .{path});
        }
        self.limit = .init(self.current.value.limit);
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.current.deinit();
        self.gpa.free(self.path);
        self.gpa.free(self.home);
    }

    /// A copy of the config as it is now
    pub fn snapshot(self: *Store) !Owned {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.current.clone(self.gpa);
    }

    pub const Change = struct {
        config: Owned,
        /// The includes or excludes differ from before: the index has to be rebuilt
        scopeChanged: bool,
    };

    /// Applies `wire` on top of the current config and saves it. Nothing changes if it is
    /// invalid (`error.InvalidConfig`, see `diag`) or the file cannot be written.
    pub fn update(self: *Store, wire: Wire, diag: *Diagnostic) !Change {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const value = try normalize(arena.allocator(), self.home, wire, self.current.value, diag);
        const next: Owned = .{ .arena = arena, .value = value };

        if (!sameConfig(next.value, self.current.value)) {
            try self.writeFile(next.value);
        }

        // Last fallible step, so that a failure leaves `arena` to the errdefer above
        const copy = try next.clone(self.gpa);

        const scopeChanged = !sameScope(next.value, self.current.value);
        self.current.deinit();
        self.current = next;
        self.limit.store(next.value.limit, .monotonic);
        return .{ .config = copy, .scopeChanged = scopeChanged };
    }

    fn writeFile(self: *Store, cfg: Config) !void {
        const File = struct {
            version: u32 = file_version,
            include: []const []const u8,
            exclude: []const []const u8,
            limit: usize,
        };
        const body = try std.json.Stringify.valueAlloc(
            self.gpa,
            File{ .include = cfg.include, .exclude = cfg.exclude, .limit = cfg.limit },
            .{ .whitespace = .indent_2 },
        );
        defer self.gpa.free(body);
        const text = try std.fmt.allocPrint(self.gpa, "{s}\n", .{body});
        defer self.gpa.free(text);

        // The sandbox lets the daemon write these two paths and nothing else (see `tempPath`)
        const tmp = try tempPath(self.gpa, self.path);
        defer self.gpa.free(tmp);
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(self.io, tmp) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        // Read-only: a hand edit is refused, and would be overwritten anyway
        try cwd.writeFile(self.io, .{
            .sub_path = tmp,
            .data = text,
            .flags = .{ .permissions = .fromMode(0o444) },
        });
        try cwd.rename(tmp, cwd, self.path, self.io);
    }
};

/// Where a new version of the file is written before it replaces the old one.
pub fn tempPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
}

fn cloneConfig(gpa: std.mem.Allocator, cfg: Config) !Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Allocate first: `arena` is copied into the result at the point it is named
    const value: Config = .{
        .include = try dupeAll(a, cfg.include),
        .exclude = try dupeAll(a, cfg.exclude),
        .limit = cfg.limit,
    };
    return .{ .arena = arena, .value = value };
}

fn sameConfig(a: Config, b: Config) bool {
    return a.limit == b.limit and sameScope(a, b);
}

const test_base: Config = .{ .include = &.{"/"}, .exclude = &.{}, .limit = default_limit };

test "paths are made absolute, tidy and unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const cfg = try normalize(arena.allocator(), "/Users/me", .{
        .include = &.{ "~/code/", "/Users/me/code/./src/..", "/tmp//x", "  " },
        .exclude = &.{ "~/Library", "node_modules", "node_modules", "/a/b/../c/" },
        .limit = 20,
    }, test_base, &diag);

    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/Users/me/code", "/tmp/x" }), cfg.include);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/Users/me/Library", "node_modules", "/a/c" }), cfg.exclude);
    try std.testing.expectEqual(20, cfg.limit);
}

test "missing fields keep their value, bad ones are refused with a reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const kept = try normalize(arena.allocator(), "/h", .{ .limit = 7 }, test_base, &diag);
    try std.testing.expectEqualDeep(test_base.include, kept.include);
    try std.testing.expectEqual(7, kept.limit);

    try std.testing.expectError(error.InvalidConfig, normalize(arena.allocator(), "/h", .{ .limit = 0 }, test_base, &diag));
    try std.testing.expectError(error.InvalidConfig, normalize(arena.allocator(), "/h", .{ .limit = max_limit + 1 }, test_base, &diag));
    try std.testing.expectError(error.InvalidConfig, normalize(arena.allocator(), "/h", .{ .include = &.{"relative/dir"} }, test_base, &diag));
    try std.testing.expectError(error.InvalidConfig, normalize(arena.allocator(), "/h", .{ .include = &.{} }, test_base, &diag));
    try std.testing.expectError(error.InvalidConfig, normalize(arena.allocator(), "/h", .{ .exclude = &.{"a/relative"} }, test_base, &diag));
    try std.testing.expect(diag.message().len > 0);
}

test "a config file parses, and garbage is refused" {
    var diag: Diagnostic = .{};
    var owned = try parse(std.testing.allocator, "/h", "{\"version\":1,\"include\":[\"~/a\"],\"limit\":3}", test_base, &diag);
    defer owned.deinit();
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"/h/a"}), owned.value.include);
    try std.testing.expectEqual(3, owned.value.limit);

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "/h", "nope", test_base, &diag));
}

test "the filter picks roots and answers what is left out" {
    var filter = try Filter.init(std.testing.allocator, .{
        .include = &.{ "/Users/me", "/Users/me/code", "/opt", "/Users/me/Library/Caches", "/srv" },
        .exclude = &.{ "/Users/me/Library", "/srv/skip.txt", "node_modules" },
        .limit = 1,
    });
    defer filter.deinit();

    // /Users/me/code is inside /Users/me, and /Users/me/Library/Caches is left out
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "/Users/me", "/opt", "/srv" }), filter.roots);

    try std.testing.expect(filter.excludes("/Users/me/Library"));
    try std.testing.expect(filter.excludes("/Users/me/Library/x/y"));
    try std.testing.expect(!filter.excludes("/Users/me/Libraryx"));
    try std.testing.expect(filter.excludes("/Users/me/code/app/node_modules/pkg/index.js"));
    try std.testing.expect(!filter.excludes("/Users/me/code/app/index.js"));
    try std.testing.expect(filter.excludes("/srv/skip.txt"));

    const here = filter.leftOutIn("/Users/me");
    try std.testing.expect(filter.skips(here, "Library"));
    try std.testing.expect(filter.skips(here, "node_modules"));
    try std.testing.expect(!filter.skips(here, "code"));
    try std.testing.expect(filter.skips(filter.leftOutIn("/srv"), "skip.txt"));
    try std.testing.expectEqual(0, filter.leftOutIn("/opt").len);

    try std.testing.expect(filter.covers("/opt/x"));
    try std.testing.expect(!filter.covers("/tmp"));
    try std.testing.expect(filter.isAboveRoot("/Users"));
    try std.testing.expect(filter.isAboveRoot("/"));
    try std.testing.expect(!filter.isAboveRoot("/Users/me/code"));
}

test "excluding the root excludes everything" {
    var filter = try Filter.init(std.testing.allocator, .{ .include = &.{"/a"}, .exclude = &.{"/"}, .limit = 1 });
    defer filter.deinit();
    try std.testing.expectEqual(0, filter.roots.len);
}

test "the store creates, updates and reloads its file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{buf[0..len]});
    defer std.testing.allocator.free(path);

    var store = try Store.open(std.testing.allocator, io, path, "/h", test_base);
    defer store.deinit();

    var diag: Diagnostic = .{};
    var change = try store.update(.{ .exclude = &.{"node_modules"}, .limit = 9 }, &diag);
    try std.testing.expect(change.scopeChanged);
    change.config.deinit();

    var again = try store.update(.{ .limit = 11 }, &diag);
    try std.testing.expect(!again.scopeChanged);
    again.config.deinit();
    try std.testing.expectEqual(11, store.limit.load(.monotonic));

    try std.testing.expectError(error.InvalidConfig, store.update(.{ .limit = 0 }, &diag));
    try std.testing.expectEqual(11, store.limit.load(.monotonic));

    var reopened = try Store.open(std.testing.allocator, io, path, "/h", test_base);
    defer reopened.deinit();
    try std.testing.expectEqual(11, reopened.current.value.limit);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"node_modules"}), reopened.current.value.exclude);
}
