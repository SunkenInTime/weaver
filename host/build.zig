const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const supervisor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/supervisor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const supervisor_test_step = b.step("test-supervisor", "Run platform-neutral supervisor tests");
    supervisor_test_step.dependOn(&b.addRunArtifact(supervisor_tests).step);
    if (target.result.os.tag == .macos) {
        const exe = b.addExecutable(.{
            .name = "weaverd",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        addMacosAudio(exe.root_module, b);
        exe.root_module.linkSystemLibrary("c", .{});
        b.installArtifact(exe);
        const bundle_executable = b.addInstallFile(exe.getEmittedBin(), "Weaverd.app/Contents/MacOS/weaverd");
        const bundle_plist = b.addInstallFile(b.path("macos/Info.plist"), "Weaverd.app/Contents/Info.plist");
        const bundle_path = b.getInstallPath(.prefix, "Weaverd.app");
        const sign_bundle = b.addSystemCommand(&.{
            "codesign", "--force", "--deep", "--sign", "-", "--identifier",
            "com.sunkenintime.weaver.host", bundle_path,
        });
        sign_bundle.step.dependOn(&bundle_executable.step);
        sign_bundle.step.dependOn(&bundle_plist.step);
        b.getInstallStep().dependOn(&sign_bundle.step);
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        addMacosAudio(tests.root_module, b);
        tests.root_module.linkSystemLibrary("c", .{});
        const test_step = b.step("test", "Run macOS host and portable supervisor tests");
        test_step.dependOn(&b.addRunArtifact(tests).step);
        return;
    }
    if (target.result.os.tag != .windows) @panic("weaverd supports only Windows and macOS");
    const windows_sdk = std.zig.WindowsSdk.find(b.allocator, b.graph.io, target.result.cpu.arch, &b.graph.environ_map) catch @panic("Windows 10 SDK is required to build weaverd providers");
    defer windows_sdk.free(b.allocator);
    const windows_10 = windows_sdk.windows10sdk orelse @panic("Windows 10 SDK is required to build weaverd providers");
    const windows_arch: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => @panic("unsupported Windows host architecture"),
    };
    const windows_lib_path = b.pathJoin(&.{ windows_10.path, "Lib", windows_10.version, "um", windows_arch });
    const cppwinrt_include = b.pathJoin(&.{ windows_10.path, "Include", windows_10.version, "cppwinrt" });
    const exe = b.addExecutable(.{
        .name = "weaverd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.subsystem = .Windows;
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/windows_providers.cpp"),
        .flags = &.{ "-std=c++20", "-fexceptions", "-frtti" },
    });
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = cppwinrt_include });
    exe.root_module.addLibraryPath(.{ .cwd_relative = windows_lib_path });
    exe.root_module.linkSystemLibrary("c++", .{});
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("psapi", .{});
    exe.root_module.linkSystemLibrary("ntdll", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("windowsapp", .{});
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/windows_providers.cpp"),
        .flags = &.{ "-std=c++20", "-fexceptions", "-frtti" },
    });
    tests.root_module.addIncludePath(b.path("src"));
    tests.root_module.addSystemIncludePath(.{ .cwd_relative = cppwinrt_include });
    tests.root_module.addLibraryPath(.{ .cwd_relative = windows_lib_path });
    tests.root_module.linkSystemLibrary("c++", .{});
    tests.root_module.linkSystemLibrary("c", .{});
    tests.root_module.linkSystemLibrary("kernel32", .{});
    tests.root_module.linkSystemLibrary("user32", .{});
    tests.root_module.linkSystemLibrary("psapi", .{});
    tests.root_module.linkSystemLibrary("ntdll", .{});
    tests.root_module.linkSystemLibrary("ole32", .{});
    tests.root_module.linkSystemLibrary("windowsapp", .{});
    const test_step = b.step("test", "Run weaverd unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addMacosAudio(module: *std.Build.Module, b: *std.Build) void {
    module.addCSourceFile(.{
        .file = b.path("src/macos_audio.m"),
        .flags = &.{ "-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.2" },
    });
    module.addIncludePath(b.path("src"));
    module.linkFramework("CoreAudio", .{});
    module.linkFramework("Foundation", .{});
}
