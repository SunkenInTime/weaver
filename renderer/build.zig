const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "weaver-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .Windows;
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "src/renderer_server.cpp",
            "../runtime/native-sdk/src/platform/windows/d3d_presenter.cpp",
        },
        .flags = &.{ "-std=c++17" },
    });
    exe.root_module.addIncludePath(b.path("../runtime/native-sdk/src/platform/windows"));
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.linkSystemLibrary("c++", .{});
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("d3d11", .{});
    exe.root_module.linkSystemLibrary("dxgi", .{});
    exe.root_module.linkSystemLibrary("dcomp", .{});
    b.installArtifact(exe);
}
