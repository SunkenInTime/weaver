const std = @import("std");

const c = @cImport({
    @cInclude("renderer_server.h");
});

pub fn main(_: std.process.Init) !void {
    if (c.weaver_renderer_run() != 0) return error.RendererFailed;
}
