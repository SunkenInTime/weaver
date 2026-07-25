const std = @import("std");

const windows = std.os.windows;

extern "kernel32" fn MoveFileExW(
    existing_file_name: [*:0]const u16,
    new_file_name: [*:0]const u16,
    flags: u32,
) callconv(.winapi) windows.BOOL;

const movefile_write_through: u32 = 0x00000008;

pub const max_input_bytes: usize = 1024 * 1024;
pub const max_files: usize = 32;
pub const hash_hex_bytes: usize = 64;
pub const max_path_bytes: usize = 259;

pub const Publication = struct {
    path: [max_path_bytes]u8 = @splat(0),
    path_len: usize = 0,
    hash: [hash_hex_bytes]u8 = @splat(0),

    pub fn pathSlice(self: *const Publication) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// weaverd is the sole writer. The filesystem mtime is the LRU clock and is
/// touched only after a complete file becomes the successfully published
/// hash.
pub const Cache = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []u8,
    published_hash: [hash_hex_bytes]u8 = @splat(0),
    published: bool = false,
    temp_nonce: u64 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Cache {
        var self: Cache = .{
            .io = io,
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
        };
        errdefer allocator.free(self.root);
        try std.Io.Dir.cwd().createDirPath(io, self.root);
        try self.cleanupTemps();
        try self.prune();
        return self;
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn clearPublished(self: *Cache) void {
        self.published = false;
    }

    pub fn publish(self: *Cache, bytes: []const u8) !?Publication {
        if (bytes.len > max_input_bytes) return null;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var hash: [hash_hex_bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash, "{x}", .{digest});
        var filename_buffer: [hash_hex_bytes + ".img".len]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buffer, "{s}.img", .{hash});
        const final_path = try std.fs.path.join(self.allocator, &.{ self.root, filename });
        defer self.allocator.free(final_path);
        if (final_path.len > max_path_bytes) return error.ArtPathTooLong;

        var cwd = std.Io.Dir.cwd();
        const exists = block: {
            _ = cwd.statFile(self.io, final_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :block false,
                else => return err,
            };
            break :block true;
        };
        if (!exists) {
            self.temp_nonce +%= 1;
            const temp_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.{d}.{d}.tmp",
                .{ final_path, windows.GetCurrentProcessId(), self.temp_nonce },
            );
            defer self.allocator.free(temp_path);
            errdefer cwd.deleteFile(self.io, temp_path) catch {};
            {
                var file = try cwd.createFile(self.io, temp_path, .{ .exclusive = true });
                defer file.close(self.io);
                var write_buffer: [64 * 1024]u8 = undefined;
                var writer = file.writer(self.io, &write_buffer);
                try writer.interface.writeAll(bytes);
                try writer.interface.flush();
                try file.sync(self.io);
            }
            const moved = try moveNoReplace(self.allocator, temp_path, final_path);
            if (!moved) cwd.deleteFile(self.io, temp_path) catch {};
        }

        {
            var file = try cwd.openFile(self.io, final_path, .{ .mode = .write_only });
            defer file.close(self.io);
            try file.setTimestampsNow(self.io);
        }
        self.published_hash = hash;
        self.published = true;
        try self.prune();

        var result: Publication = .{ .hash = hash };
        @memcpy(result.path[0..final_path.len], final_path);
        result.path_len = final_path.len;
        return result;
    }

    fn cleanupTemps(self: *Cache) !void {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tmp")) continue;
            directory.deleteFile(self.io, entry.name) catch {};
        }
    }

    fn prune(self: *Cache) !void {
        var count = try self.imageCount();
        while (count > max_files) : (count -= 1) {
            var directory = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
            defer directory.close(self.io);
            var iterator = directory.iterate();
            var oldest_name: [hash_hex_bytes + ".img".len]u8 = undefined;
            var oldest_len: usize = 0;
            var oldest_mtime: i128 = std.math.maxInt(i128);
            while (try iterator.next(self.io)) |entry| {
                if (entry.kind != .file or !isImageFilename(entry.name)) continue;
                const hash = entry.name[0..hash_hex_bytes];
                if (self.published and std.mem.eql(u8, hash, &self.published_hash)) continue;
                const stat = directory.statFile(self.io, entry.name, .{}) catch continue;
                if (stat.mtime.nanoseconds >= oldest_mtime) continue;
                oldest_mtime = stat.mtime.nanoseconds;
                oldest_len = entry.name.len;
                @memcpy(oldest_name[0..oldest_len], entry.name);
            }
            if (oldest_len == 0) return error.ArtCachePinExceedsLimit;
            try directory.deleteFile(self.io, oldest_name[0..oldest_len]);
        }
    }

    fn imageCount(self: *Cache) !usize {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file and isImageFilename(entry.name)) count += 1;
        }
        return count;
    }
};

fn isImageFilename(name: []const u8) bool {
    if (name.len != hash_hex_bytes + ".img".len or !std.mem.endsWith(u8, name, ".img")) return false;
    for (name[0..hash_hex_bytes]) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn moveNoReplace(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !bool {
    const source_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, source);
    defer allocator.free(source_w);
    const destination_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, destination);
    defer allocator.free(destination_w);
    if (MoveFileExW(source_w.ptr, destination_w.ptr, movefile_write_through).toBool()) return true;
    return switch (windows.GetLastError()) {
        .ALREADY_EXISTS, .FILE_EXISTS => false,
        else => error.ArtCacheRenameFailed,
    };
}

fn testRoot(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/weaver-art-cache-{d}-{s}", .{ windows.GetCurrentProcessId(), suffix });
}

fn testImageCount(io: std.Io, root: []const u8) !usize {
    var cache: Cache = .{ .io = io, .allocator = std.testing.allocator, .root = @constCast(root) };
    return cache.imageCount();
}

test "art cache hash-dedupes and never exposes a partial file" {
    const root = try testRoot(std.testing.allocator, "dedupe");
    defer std.testing.allocator.free(root);
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();

    const first = (try cache.publish("complete-image")).?;
    const second = (try cache.publish("complete-image")).?;
    try std.testing.expectEqualStrings(first.pathSlice(), second.pathSlice());
    try std.testing.expectEqual(@as(usize, 1), try testImageCount(std.testing.io, root));
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, first.pathSlice(), std.testing.allocator, .limited(max_input_bytes));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("complete-image", contents);
}

test "art cache skips oversized input and cleans startup temps" {
    const root = try testRoot(std.testing.allocator, "limits");
    defer std.testing.allocator.free(root);
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const stale = try std.fs.path.join(std.testing.allocator, &.{ root, "orphan.1.tmp" });
    defer std.testing.allocator.free(stale);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stale, .data = "partial" });
    var cache = try Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, stale, .{}));
    const oversized = try std.testing.allocator.alloc(u8, max_input_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0xaa);
    try std.testing.expect((try cache.publish(oversized)) == null);
    try std.testing.expectEqual(@as(usize, 0), try testImageCount(std.testing.io, root));
}

test "art cache prunes to 32 files without pruning the published hash" {
    const root = try testRoot(std.testing.allocator, "prune");
    defer std.testing.allocator.free(root);
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var cache = try Cache.init(std.testing.io, std.testing.allocator, root);
    defer cache.deinit();
    var published: Publication = undefined;
    var payload: [16]u8 = @splat(0);
    for (0..max_files + 5) |index| {
        std.mem.writeInt(u64, payload[0..8], index, .little);
        published = (try cache.publish(&payload)).?;
    }
    try std.testing.expectEqual(@as(usize, max_files), try testImageCount(std.testing.io, root));

    // Make the pinned publication the oldest file, then force a prune without
    // changing the published hash. Age must never outrank the pin.
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, published.pathSlice(), .{ .mode = .write_only });
        defer file.close(std.testing.io);
        try file.setTimestamps(std.testing.io, .{
            .access_timestamp = .{ .new = .zero },
            .modify_timestamp = .{ .new = .zero },
        });
    }
    const extra_name = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.img";
    const extra_path = try std.fs.path.join(std.testing.allocator, &.{ root, extra_name });
    defer std.testing.allocator.free(extra_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = extra_path, .data = "complete-extra" });
    try cache.prune();
    try std.testing.expectEqual(@as(usize, max_files), try testImageCount(std.testing.io, root));
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, published.pathSlice(), .{});
}
