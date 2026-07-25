const std = @import("std");
const art_cache = @import("art_cache.zig");
const media_commands = @import("media_commands.zig");

const native = @cImport({
    @cInclude("windows_providers.h");
});

pub const max_text_bytes: usize = 512;
pub const max_source_app_bytes: usize = 256;
pub const max_art_path_bytes: usize = 259;
pub const max_json_escape_bytes: usize = 6;

// The bound reserves the PR 02 artPath key now so the transport framing does
// not change underneath a stacked runtime. Every source byte may expand to a
// six-byte JSON \u00XX escape; the fixed form uses the longest status/bool and
// two maximum-width u64 values.
const max_media_frame_fixed =
    "{\"provider\":\"media\",\"value\":{\"title\":\"\",\"artist\":\"\",\"album\":\"\",\"playing\":false,\"status\":\"stopped\",\"sourceApp\":\"\",\"artPath\":\"\",\"positionMs\":18446744073709551615,\"durationMs\":18446744073709551615}}\n";
pub const max_media_frame_bytes: usize = max_media_frame_fixed.len +
    max_json_escape_bytes * (3 * max_text_bytes + max_source_app_bytes + max_art_path_bytes);

pub const Status = enum {
    playing,
    paused,
    stopped,

    fn wire(self: Status) []const u8 {
        return switch (self) {
            .playing => "playing",
            .paused => "paused",
            .stopped => "stopped",
        };
    }
};

pub const Frame = struct {
    title: [max_text_bytes]u8 = @splat(0),
    title_len: usize = 0,
    artist: [max_text_bytes]u8 = @splat(0),
    artist_len: usize = 0,
    album: [max_text_bytes]u8 = @splat(0),
    album_len: usize = 0,
    status: Status = .stopped,
    source_app: [max_source_app_bytes]u8 = @splat(0),
    source_app_len: usize = 0,
    art_path: [max_art_path_bytes]u8 = @splat(0),
    art_path_len: usize = 0,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,

    pub fn titleSlice(self: *const Frame) []const u8 {
        return self.title[0..self.title_len];
    }
    pub fn artistSlice(self: *const Frame) []const u8 {
        return self.artist[0..self.artist_len];
    }
    pub fn albumSlice(self: *const Frame) []const u8 {
        return self.album[0..self.album_len];
    }
    pub fn sourceAppSlice(self: *const Frame) []const u8 {
        return self.source_app[0..self.source_app_len];
    }
    pub fn artPathSlice(self: *const Frame) []const u8 {
        return self.art_path[0..self.art_path_len];
    }
};

pub const Provider = struct {
    session: ?*native.WeaverMediaSession = null,
    cache: ?*art_cache.Cache = null,
    next_open_ms: u64 = 0,
    next_poll_ms: u64 = 0,
    current_art_path: [max_art_path_bytes]u8 = @splat(0),
    current_art_path_len: usize = 0,
    refresh_failure_logged: bool = false,

    pub fn deinit(self: *Provider) void {
        self.close();
    }

    pub fn setActive(self: *Provider, active: bool, now_ms: u64) void {
        if (!active) {
            self.close();
            return;
        }
        if (self.session == null and now_ms >= self.next_open_ms) self.open(now_ms);
    }

    /// SMTC is naturally change-oriented. Polling once per second observes
    /// timeline movement while playing and session/property transitions; the
    /// host's serialized-frame comparison suppresses every unchanged result.
    pub fn poll(self: *Provider, now_ms: u64) ?Frame {
        if (self.session == null) {
            if (now_ms >= self.next_open_ms) self.open(now_ms);
            return null;
        }
        if (now_ms < self.next_poll_ms) return null;
        self.next_poll_ms = now_ms + 1000;
        var source: native.WeaverMediaState = undefined;
        var artwork: native.WeaverMediaArtwork = undefined;
        const result = native.weaver_media_poll(self.session, &source, &artwork);
        defer native.weaver_media_artwork_release(&artwork);
        if (result < 0) {
            self.close();
            self.next_open_ms = now_ms + 1000;
            return null;
        }
        if (artwork.refresh_failed != 0) {
            if (!self.refresh_failure_logged) {
                std.log.warn("SMTC media properties or thumbnail refresh failed; waiting for the next change event", .{});
                self.refresh_failure_logged = true;
            }
        } else {
            self.refresh_failure_logged = false;
        }
        if (artwork.changed != 0) {
            self.current_art_path_len = 0;
            if (self.cache) |cache| {
                cache.clearPublished();
                if (artwork.too_large != 0) {
                    std.log.warn("SMTC thumbnail exceeds the 1 MiB art-cache limit; omitting art", .{});
                } else if (artwork.bytes != null and artwork.length > 0) {
                    const publication: ?art_cache.Publication = cache.publish(artwork.bytes[0..artwork.length]) catch |err| failure: {
                        std.log.err("media artwork cache publication failed: {s}", .{@errorName(err)});
                        break :failure null;
                    };
                    if (publication) |published| {
                        @memcpy(self.current_art_path[0..published.path_len], published.path[0..published.path_len]);
                        self.current_art_path_len = published.path_len;
                    }
                }
            }
        }
        if (result == 0) return .{};
        var frame: Frame = .{
            .status = statusFromNative(source.status),
            .position_ms = @intCast(@max(0, source.position_ms)),
            .duration_ms = @intCast(@max(0, source.duration_ms)),
        };
        copyText(&frame.title, &frame.title_len, std.mem.sliceTo(&source.title, 0));
        copyText(&frame.artist, &frame.artist_len, std.mem.sliceTo(&source.artist, 0));
        copyText(&frame.album, &frame.album_len, std.mem.sliceTo(&source.album, 0));
        copyText(&frame.source_app, &frame.source_app_len, std.mem.sliceTo(&source.source_app, 0));
        copyText(&frame.art_path, &frame.art_path_len, self.current_art_path[0..self.current_art_path_len]);
        return frame;
    }

    pub fn command(self: *Provider, verb: media_commands.Verb, seek_ms: ?u64, now_ms: u64) bool {
        if (self.session == null and now_ms >= self.next_open_ms) self.open(now_ms);
        const session = self.session orelse return false;
        const native_verb: c_int = switch (verb) {
            .play => native.WEAVER_MEDIA_COMMAND_PLAY,
            .pause => native.WEAVER_MEDIA_COMMAND_PAUSE,
            .next => native.WEAVER_MEDIA_COMMAND_NEXT,
            .previous => native.WEAVER_MEDIA_COMMAND_PREVIOUS,
            .seek => native.WEAVER_MEDIA_COMMAND_SEEK,
        };
        return native.weaver_media_command(session, native_verb, seek_ms orelse 0) != 0;
    }

    fn open(self: *Provider, now_ms: u64) void {
        self.session = native.weaver_media_create();
        if (self.session != null) {
            self.next_poll_ms = now_ms;
            return;
        }
        self.next_open_ms = now_ms + 1000;
    }

    fn close(self: *Provider) void {
        if (self.session) |session| native.weaver_media_destroy(session);
        self.session = null;
    }
};

pub fn formatFrame(frame: *const Frame, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    var json: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    try json.beginObject();
    try json.objectField("provider");
    try json.write("media");
    try json.objectField("value");
    try json.beginObject();
    try json.objectField("title");
    try json.write(frame.titleSlice());
    try json.objectField("artist");
    try json.write(frame.artistSlice());
    try json.objectField("album");
    try json.write(frame.albumSlice());
    try json.objectField("playing");
    try json.write(frame.status == .playing);
    try json.objectField("status");
    try json.write(frame.status.wire());
    try json.objectField("sourceApp");
    try json.write(frame.sourceAppSlice());
    if (frame.art_path_len > 0) {
        try json.objectField("artPath");
        try json.write(frame.artPathSlice());
    }
    try json.objectField("positionMs");
    try json.write(frame.position_ms);
    try json.objectField("durationMs");
    try json.write(frame.duration_ms);
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
    return writer.buffered();
}

fn copyText(destination: anytype, length: *usize, source: []const u8) void {
    length.* = @min(source.len, destination.len);
    @memcpy(destination[0..length.*], source[0..length.*]);
}

test "media provider frame escapes metadata and uses contract fields" {
    var frame: Frame = .{ .status = .playing, .position_ms = 1200, .duration_ms = 8000 };
    copyText(&frame.title, &frame.title_len, "A \"quoted\" song");
    copyText(&frame.artist, &frame.artist_len, "Artist");
    copyText(&frame.source_app, &frame.source_app_len, "Spotify");
    var output: [max_media_frame_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"provider\":\"media\",\"value\":{\"title\":\"A \\\"quoted\\\" song\",\"artist\":\"Artist\",\"album\":\"\",\"playing\":true,\"status\":\"playing\",\"sourceApp\":\"Spotify\",\"positionMs\":1200,\"durationMs\":8000}}\n",
        try formatFrame(&frame, &output),
    );
}

test "media frame bound covers maximum escaped fields and future art path" {
    try std.testing.expectEqual(@as(usize, 12_502), max_media_frame_bytes);
    var frame: Frame = .{
        .status = .stopped,
        .position_ms = std.math.maxInt(u64),
        .duration_ms = std.math.maxInt(u64),
    };
    @memset(&frame.title, 0x01);
    frame.title_len = frame.title.len;
    @memset(&frame.artist, 0x01);
    frame.artist_len = frame.artist.len;
    @memset(&frame.album, 0x01);
    frame.album_len = frame.album.len;
    @memset(&frame.source_app, 0x01);
    frame.source_app_len = frame.source_app.len;
    @memset(&frame.art_path, 0x01);
    frame.art_path_len = frame.art_path.len;
    var output: [max_media_frame_bytes]u8 = undefined;
    const encoded = try formatFrame(&frame, &output);
    try std.testing.expectEqual(
        max_media_frame_fixed.len + max_json_escape_bytes * (3 * max_text_bytes + max_source_app_bytes + max_art_path_bytes),
        encoded.len,
    );
    try std.testing.expectEqual(max_media_frame_bytes, encoded.len);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\\u0001") != null);
}

test "source app mapping prefers packaged display names and honestly falls back" {
    const fixtures = [_]struct {
        raw: [:0]const u8,
        resolved: [:0]const u8,
        expected: []const u8,
    }{
        .{ .raw = "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify", .resolved = "Spotify", .expected = "Spotify" },
        .{ .raw = "Spotify.exe", .resolved = "", .expected = "Spotify.exe" },
        .{ .raw = "Missing.Package_123!App", .resolved = "", .expected = "Missing.Package_123!App" },
        .{ .raw = "", .resolved = "", .expected = "" },
    };
    for (fixtures) |fixture| {
        var output: [max_source_app_bytes + 1]u8 = @splat(0);
        native.weaver_media_select_source_app(fixture.raw.ptr, fixture.resolved.ptr, &output);
        try std.testing.expectEqualStrings(fixture.expected, std.mem.sliceTo(&output, 0));
    }
}

fn statusFromNative(value: c_int) Status {
    return switch (value) {
        native.WEAVER_MEDIA_STATUS_PLAYING => .playing,
        native.WEAVER_MEDIA_STATUS_PAUSED => .paused,
        else => .stopped,
    };
}

test "native playback status maps to the frozen tri-state" {
    try std.testing.expectEqual(Status.playing, statusFromNative(native.WEAVER_MEDIA_STATUS_PLAYING));
    try std.testing.expectEqual(Status.paused, statusFromNative(native.WEAVER_MEDIA_STATUS_PAUSED));
    try std.testing.expectEqual(Status.stopped, statusFromNative(native.WEAVER_MEDIA_STATUS_STOPPED));
    try std.testing.expectEqual(Status.stopped, statusFromNative(99));
}

test "native media dirty flags start dirty and coalesce duplicate events" {
    try std.testing.expectEqual(@as(c_int, 1), native.weaver_media_test_dirty_coalescing());
}
