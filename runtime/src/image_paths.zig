const std = @import("std");
const builtin = @import("builtin");
const media_protocol = @import("media_protocol.zig");

pub const Kind = enum { widget_asset, host_art };

pub const Resolved = struct {
    path: [:0]u8,
    kind: Kind,
};

pub const Resolver = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    widget_root: [:0]u8,
    art_root: ?[:0]u8,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        widget_directory: []const u8,
        art_cache_environment: ?[]const u8,
    ) !Resolver {
        const widget_root = try std.Io.Dir.cwd().realPathFileAlloc(io, widget_directory, allocator);
        errdefer allocator.free(widget_root);
        var art_root: ?[:0]u8 = null;
        if (art_cache_environment) |root| {
            if (!validAbsoluteArtPath(root)) return error.InvalidArtCacheRoot;
            art_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
        }
        return .{
            .io = io,
            .allocator = allocator,
            .widget_root = widget_root,
            .art_root = art_root,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.allocator.free(self.widget_root);
        if (self.art_root) |root| self.allocator.free(root);
        self.* = undefined;
    }

    pub fn resolve(self: *const Resolver, source: []const u8) !Resolved {
        if (isLocalAssetPath(source)) {
            const relative = if (std.mem.startsWith(u8, source, "./") or std.mem.startsWith(u8, source, ".\\")) source[2..] else source;
            const joined = try std.fs.path.join(self.allocator, &.{ self.widget_root, relative });
            defer self.allocator.free(joined);
            const resolved = try std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, self.allocator);
            errdefer self.allocator.free(resolved);
            if (!componentContained(self.widget_root, resolved, builtin.os.tag == .windows)) return error.WidgetAssetEscapesRoot;
            return .{ .path = resolved, .kind = .widget_asset };
        }
        const root = self.art_root orelse return error.InvalidImageSource;
        if (!validAbsoluteArtPath(source) or hasParentComponent(source)) return error.InvalidImageSource;
        const resolved = try std.Io.Dir.realPathFileAbsoluteAlloc(self.io, source, self.allocator);
        errdefer self.allocator.free(resolved);
        if (!componentContained(root, resolved, builtin.os.tag == .windows)) return error.ArtPathOutsideCache;
        if (resolved.len > media_protocol.max_art_path_bytes) return error.ArtPathTooLong;
        return .{ .path = resolved, .kind = .host_art };
    }
};

/// This is the original startup-asset rule. The startup loader continues to
/// use it unchanged; dynamic resolution adds the one host-cache acceptance.
pub fn isLocalAssetPath(source: []const u8) bool {
    if (source.len == 0 or std.fs.path.isAbsolute(source) or std.mem.indexOf(u8, source, "://") != null) return false;
    var components = std.mem.tokenizeAny(u8, source, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn hasParentComponent(path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return true;
    return false;
}

fn validAbsoluteArtPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOf(u8, path, "://") != null) return false;
    if (builtin.os.tag != .windows) return std.fs.path.isAbsolute(path);
    // Only ordinary drive-absolute paths are accepted. This excludes
    // drive-relative, rooted-current-drive, UNC, and both device namespaces.
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSeparator(path[2]);
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn componentContained(root: []const u8, candidate: []const u8, case_insensitive: bool) bool {
    var root_components = std.mem.tokenizeAny(u8, root, "/\\");
    var candidate_components = std.mem.tokenizeAny(u8, candidate, "/\\");
    while (root_components.next()) |root_component| {
        const candidate_component = candidate_components.next() orelse return false;
        const equal = if (case_insensitive)
            std.ascii.eqlIgnoreCase(root_component, candidate_component)
        else
            std.mem.eql(u8, root_component, candidate_component);
        if (!equal) return false;
    }
    // An image must be a child of the cache root, not the root itself.
    return candidate_components.next() != null;
}

fn windowsLexicallyContained(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < 3 or !std.ascii.isAlphabetic(candidate[0]) or candidate[1] != ':' or !isSeparator(candidate[2])) return false;
    if (hasParentComponent(candidate)) return false;
    return componentContained(root, candidate, true);
}

test "Windows art containment rejects traversal prefixes and namespaces" {
    const root = "C:\\Users\\Dara\\AppData\\Local\\weaver\\artcache";
    try std.testing.expect(windowsLexicallyContained(root, "c:/users/DARA/AppData/Local/WEAVER/artcache/abc.img"));
    try std.testing.expect(windowsLexicallyContained(root, "C:\\Users\\Dara/AppData\\Local/weaver\\artcache\\abc.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "C:\\Users\\Dara\\AppData\\Local\\weaver\\artcache\\..\\x.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "C:\\Users\\Dara\\AppData\\Local\\weaver\\artcache-evil\\x.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "C:artcache\\x.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "\\\\server\\share\\x.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "\\\\?\\C:\\Users\\Dara\\AppData\\Local\\weaver\\artcache\\x.img"));
    try std.testing.expect(!windowsLexicallyContained(root, "\\\\.\\C:\\Users\\Dara\\AppData\\Local\\weaver\\artcache\\x.img"));
}

test "resolver accepts only a real file under the canonical host art root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const root = ".zig-cache/weaver-image-path-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const widget_root = try std.fs.path.join(std.testing.allocator, &.{ root, "widget" });
    defer std.testing.allocator.free(widget_root);
    const art_root = try std.fs.path.join(std.testing.allocator, &.{ root, "artcache" });
    defer std.testing.allocator.free(art_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, widget_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, art_root);
    const art = try std.fs.path.join(std.testing.allocator, &.{ art_root, "abc.img" });
    defer std.testing.allocator.free(art);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = art, .data = "image" });
    const absolute_art_root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, art_root, std.testing.allocator);
    defer std.testing.allocator.free(absolute_art_root);
    const absolute_art = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, art, std.testing.allocator);
    defer std.testing.allocator.free(absolute_art);
    var resolver = try Resolver.init(std.testing.io, std.testing.allocator, widget_root, absolute_art_root);
    defer resolver.deinit();
    const resolved = try resolver.resolve(absolute_art);
    defer std.testing.allocator.free(resolved.path);
    try std.testing.expectEqual(Kind.host_art, resolved.kind);
    try std.testing.expectEqualStrings(absolute_art, resolved.path);
}
