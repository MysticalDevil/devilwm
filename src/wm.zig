const std = @import("std");
const log = std.log;
const build_options = @import("build_options");

const config = @import("wm/config.zig");
const protocol = @import("wm/protocol.zig");
const env = @import("wm/env.zig");
const handlers = @import("wm/handlers.zig");
const state_mod = @import("wm/state.zig");

const c = protocol.c;
const State = state_mod.State;

pub const std_options: std.Options = .{
    .log_level = if (build_options.verbose_logs) .debug else .warn,
};

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) @panic("memory leak detected");
    }

    var cfg = try config.load(gpa.allocator());
    // Env vars override config for quick experiments.
    if (env.parseLayoutModeEnv()) |mode| cfg.layout_mode = @enumFromInt(@intFromEnum(mode));
    if (env.parseFocusOnInteractionEnv()) |focus| cfg.focus_on_interaction = focus;

    var state = State.init(gpa.allocator(), cfg);
    state.setupControlPath();

    state.display = c.wl_display_connect(null);
    if (state.display == null) {
        log.err("failed to connect to wayland display", .{});
        return error.DisplayConnectFailed;
    }
    defer c.wl_display_disconnect(state.display);

    state.registry = c.wl_display_get_registry(state.display);
    if (state.registry == null) {
        log.err("failed to get wayland registry", .{});
        return error.RegistryUnavailable;
    }

    _ = c.wl_registry_add_listener(state.registry, &handlers.registry_listener, &state);

    if (c.wl_display_roundtrip(state.display) < 0) {
        return error.RoundtripFailed;
    }

    if (state.wm == null) {
        log.err("river_window_manager_v1 not advertised on this compositor", .{});
        return error.MissingRiverProtocol;
    }

    if (c.wl_display_roundtrip(state.display) < 0) {
        return error.RoundtripFailed;
    }

    while (state.running) {
        if (c.wl_display_dispatch(state.display) < 0) {
            log.warn("wayland dispatch returned error, exiting", .{});
            break;
        }
    }

    state.deinit();
}
