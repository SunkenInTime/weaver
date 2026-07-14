const std = @import("std");

pub const Registration = struct {
    name: []const u8,
    sourcePath: []const u8,
    enabled: bool = true,
};

pub const Document = struct {
    widgets: []const Registration = &.{},
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Document) {
    return std.json.parseFromSlice(Document, allocator, bytes, .{ .ignore_unknown_fields = false });
}

pub fn stringify(allocator: std.mem.Allocator, document: Document) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.write(document);
    return output.toOwnedSlice();
}

test "registry round-trips source-is-artifact registrations" {
    const source = "E:\\\\Widgets\\\\clock";
    const encoded = try stringify(std.testing.allocator, .{ .widgets = &.{.{
        .name = "Clock",
        .sourcePath = source,
        .enabled = true,
    }} });
    defer std.testing.allocator.free(encoded);
    const decoded = try parse(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.widgets.len);
    try std.testing.expectEqualStrings("Clock", decoded.value.widgets[0].name);
    try std.testing.expectEqualStrings(source, decoded.value.widgets[0].sourcePath);
    try std.testing.expect(decoded.value.widgets[0].enabled);
}
