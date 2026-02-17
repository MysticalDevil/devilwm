const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const verbose_logs = b.option(bool, "verbose-logs", "Enable verbose runtime logging") orelse false;
    const lua_lib = b.option([]const u8, "lua-lib", "Lua library to link (default: lua5.1)") orelse "lua5.1";
    const river_dep = b.dependency("river", .{});
    const wm_protocol_xml = river_dep.path("protocol/river-window-management-v1.xml");
    const xkb_protocol_xml = river_dep.path("protocol/river-xkb-bindings-v1.xml");
    const options = b.addOptions();
    options.addOption(bool, "verbose_logs", verbose_logs);

    const gen_wm_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    gen_wm_header.addFileArg(wm_protocol_xml);
    const wm_protocol_header = gen_wm_header.addOutputFileArg("river-window-management-v1-client-protocol.h");

    const gen_wm_private = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    gen_wm_private.addFileArg(wm_protocol_xml);
    const wm_protocol_code = gen_wm_private.addOutputFileArg("river-window-management-v1-client-protocol.c");

    const gen_xkb_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    gen_xkb_header.addFileArg(xkb_protocol_xml);
    const xkb_protocol_header = gen_xkb_header.addOutputFileArg("river-xkb-bindings-v1-client-protocol.h");

    const gen_xkb_private = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    gen_xkb_private.addFileArg(xkb_protocol_xml);
    const xkb_protocol_code = gen_xkb_private.addOutputFileArg("river-xkb-bindings-v1-client-protocol.c");

    const exe = b.addExecutable(.{
        .name = "devilwm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary(lua_lib);
    exe.addIncludePath(wm_protocol_header.dirname());
    exe.addIncludePath(xkb_protocol_header.dirname());
    exe.addCSourceFile(.{
        .file = wm_protocol_code,
        .flags = &.{"-std=c99"},
    });
    exe.addCSourceFile(.{
        .file = xkb_protocol_code,
        .flags = &.{"-std=c99"},
    });

    b.installArtifact(exe);

    const ctl = b.addExecutable(.{
        .name = "devilctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/devilctl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(ctl);
    b.installFile("config/default.lua", "share/devilwm/default-config.lua");

    const run_artifact = b.addRunArtifact(exe);
    if (b.args) |args| run_artifact.addArgs(args);

    const run_step = b.step("run", "Run devilwm");
    run_step.dependOn(&run_artifact.step);

    const protocol_timing_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol_timing_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_protocol_timing_test = b.addRunArtifact(protocol_timing_test);

    const test_step = b.step("test", "Run protocol timing tests");
    test_step.dependOn(&run_protocol_timing_test.step);
}
