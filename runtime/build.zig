const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "weaver-widget",
    });
    const c_flags = &.{
        "-std=c11",
        "-funsigned-char",
        "-D_GNU_SOURCE",
        "-DWIN32_LEAN_AND_MEAN",
        "-D_WIN32_WINNT=0x0601",
        "-D_CRT_SECURE_NO_WARNINGS",
    };
    const sources = &.{
        "vendor/quickjs-ng/dtoa.c",
        "vendor/quickjs-ng/libregexp.c",
        "vendor/quickjs-ng/libunicode.c",
        "vendor/quickjs-ng/quickjs.c",
    };
    addQuickJs(b, artifacts.exe, sources, c_flags);
    artifacts.exe.root_module.linkSystemLibrary("winhttp", .{});
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        addQuickJs(b, artifacts.tests, sources, c_flags);
        artifacts.tests.root_module.linkSystemLibrary("winhttp", .{});
    }
}

fn addQuickJs(b: *std.Build, compile: *std.Build.Step.Compile, sources: []const []const u8, c_flags: []const []const u8) void {
        compile.root_module.addIncludePath(b.path("vendor/quickjs-ng"));
        compile.root_module.addCSourceFiles(.{ .files = sources, .flags = c_flags });
        compile.root_module.linkSystemLibrary("c", .{});
}
