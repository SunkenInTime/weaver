const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "weaverd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .Windows;
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("psapi", .{});
    exe.root_module.linkSystemLibrary("ntdll", .{});
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.linkSystemLibrary("c", .{});
    tests.root_module.linkSystemLibrary("kernel32", .{});
    tests.root_module.linkSystemLibrary("user32", .{});
    tests.root_module.linkSystemLibrary("psapi", .{});
    tests.root_module.linkSystemLibrary("ntdll", .{});
    const test_step = b.step("test", "Run weaverd unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
