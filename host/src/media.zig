const std = @import("std");

const native = @cImport({
    @cInclude("windows_providers.h");
});

pub const max_text_bytes: usize = 512;

pub const Frame = struct {
    title: [max_text_bytes]u8 = @splat(0),
    title_len: usize = 0,
    artist: [max_text_bytes]u8 = @splat(0),
    artist_len: usize = 0,
    album: [max_text_bytes]u8 = @splat(0),
    album_len: usize = 0,
    playing: bool = false,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,

    pub fn titleSlice(self: *const Frame) []const u8 { return self.title[0..self.title_len]; }
    pub fn artistSlice(self: *const Frame) []const u8 { return self.artist[0..self.artist_len]; }
    pub fn albumSlice(self: *const Frame) []const u8 { return self.album[0..self.album_len]; }
};

pub const Provider = struct {
    session: ?*native.WeaverMediaSession = null,
    next_open_ms: u64 = 0,
    next_poll_ms: u64 = 0,

    pub fn deinit(self: *Provider) void { self.close(); }

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
        const result = native.weaver_media_poll(self.session, &source);
        if (result < 0) {
            self.close();
            self.next_open_ms = now_ms + 1000;
            return null;
        }
        if (result == 0) return .{};
        var frame: Frame = .{
            .playing = source.playing != 0,
            .position_ms = @intCast(@max(0, source.position_ms)),
            .duration_ms = @intCast(@max(0, source.duration_ms)),
        };
        copyText(&frame.title, &frame.title_len, std.mem.sliceTo(&source.title, 0));
        copyText(&frame.artist, &frame.artist_len, std.mem.sliceTo(&source.artist, 0));
        copyText(&frame.album, &frame.album_len, std.mem.sliceTo(&source.album, 0));
        return frame;
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
    try json.write(frame.playing);
    try json.objectField("positionMs");
    try json.write(frame.position_ms);
    try json.objectField("durationMs");
    try json.write(frame.duration_ms);
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
    return writer.buffered();
}

fn copyText(destination: *[max_text_bytes]u8, length: *usize, source: []const u8) void {
    length.* = @min(source.len, destination.len);
    @memcpy(destination[0..length.*], source[0..length.*]);
}

test "media provider frame escapes metadata and uses contract fields" {
    var frame: Frame = .{ .playing = true, .position_ms = 1200, .duration_ms = 8000 };
    copyText(&frame.title, &frame.title_len, "A \"quoted\" song");
    copyText(&frame.artist, &frame.artist_len, "Artist");
    var output: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"provider\":\"media\",\"value\":{\"title\":\"A \\\"quoted\\\" song\",\"artist\":\"Artist\",\"album\":\"\",\"playing\":true,\"positionMs\":1200,\"durationMs\":8000}}\n",
        try formatFrame(&frame, &output),
    );
}
