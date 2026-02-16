const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const river_dep = b.dependency("river", .{});
    const protocol_xml = river_dep.path("protocol/river-window-management-v1.xml");

    const gen_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    gen_header.addFileArg(protocol_xml);
    const protocol_header = gen_header.addOutputFileArg("river-window-management-v1-client-protocol.h");

    const gen_private = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    gen_private.addFileArg(protocol_xml);
    const protocol_code = gen_private.addOutputFileArg("river-window-management-v1-client-protocol.c");

    const exe = b.addExecutable(.{
        .name = "devilwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.addIncludePath(protocol_header.dirname());
    exe.addCSourceFile(.{
        .file = protocol_code,
        .flags = &.{ "-std=c99" },
    });

    b.installArtifact(exe);

    const run_artifact = b.addRunArtifact(exe);
    if (b.args) |args| run_artifact.addArgs(args);

    const run_step = b.step("run", "Run devilwm");
    run_step.dependOn(&run_artifact.step);
}
