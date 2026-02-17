const std = @import("std");
const log = std.log;
const protocol = @import("protocol.zig");
const noop = @import("noop.zig");
const layout = @import("layout.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const c = protocol.c;
const State = state_mod.State;
const OpKind = types.OpKind;

fn getState(data: ?*anyopaque) *State {
    return @ptrCast(@alignCast(data.?));
}

fn bindTyped(comptime T: type, registry: *c.wl_registry, name: u32, iface: *const c.wl_interface, version: u32) ?*T {
    const raw = c.wl_registry_bind(registry, name, iface, version);
    if (raw == null) return null;
    return @ptrCast(raw);
}

fn chooseVersion(advertised: u32) u32 {
    return @min(advertised, protocol.max_proto_version);
}

fn wmUnavailable(data: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {
    const state = getState(data);
    log.err("river window manager protocol unavailable (another WM may be active)", .{});
    state.running = false;
}

fn wmFinished(data: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {
    const state = getState(data);
    log.info("compositor finished devilwm session", .{});
    state.running = false;
}

fn wmManageStart(data: ?*anyopaque, wm: ?*c.river_window_manager_v1) callconv(.c) void {
    const state = getState(data);
    const wm_obj = wm orelse return;
    if (!state.beginPhase(.manage)) {
        c.river_window_manager_v1_manage_finish(wm_obj);
        return;
    }
    defer state.endPhase(.manage);

    log.debug("manage_start windows={} outputs={} seats={} layout={s}", .{
        state.windows.items.len,
        state.outputs.items.len,
        state.seats.items.len,
        @tagName(state.layout_mode),
    });

    layout.applyManageLayout(state);
    c.river_window_manager_v1_manage_finish(wm_obj);
}

fn wmRenderStart(data: ?*anyopaque, wm: ?*c.river_window_manager_v1) callconv(.c) void {
    const state = getState(data);
    const wm_obj = wm orelse return;
    if (!state.beginPhase(.render)) {
        c.river_window_manager_v1_render_finish(wm_obj);
        return;
    }
    defer state.endPhase(.render);

    for (state.windows.items) |*window| {
        state.applyRenderWindowState(window, false, false, false);
    }

    if (state.outputs.items.len == 0) {
        layout.renderForOutput(state, null);
    } else {
        for (state.outputs.items) |output| {
            layout.renderForOutput(state, output.obj);
        }
    }

    if (state.focused_window) |focused| {
        if (state.findWindowIndex(focused)) |idx| {
            c.river_node_v1_place_top(state.windows.items[idx].node);
        }
    }

    c.river_window_manager_v1_render_finish(wm_obj);
}

fn wmSessionLocked(_: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {}
fn wmSessionUnlocked(_: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {}

fn wmWindow(data: ?*anyopaque, _: ?*c.river_window_manager_v1, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;

    const node = c.river_window_v1_get_node(window_obj) orelse {
        log.err("failed to create node for new window", .{});
        return;
    };

    _ = c.river_window_v1_add_listener(window_obj, &window_listener, data);

    const assigned_output = state.chooseOutputForNewWindow();
    state.windows.append(state.allocator, .{
        .obj = window_obj,
        .node = node,
        .assigned_output = assigned_output,
    }) catch {
        log.err("out of memory while tracking window", .{});
        c.river_node_v1_destroy(node);
        c.river_window_v1_destroy(window_obj);
        return;
    };

    state.focused_window = window_obj;
}

fn wmOutput(data: ?*anyopaque, _: ?*c.river_window_manager_v1, output: ?*c.river_output_v1) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    _ = c.river_output_v1_add_listener(output_obj, &output_listener, data);

    state.outputs.append(state.allocator, .{ .obj = output_obj }) catch {
        log.err("out of memory while tracking output", .{});
        c.river_output_v1_destroy(output_obj);
        return;
    };

    state.ensureWindowOutputAssignments();
}

fn wmSeat(data: ?*anyopaque, _: ?*c.river_window_manager_v1, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;

    _ = c.river_seat_v1_add_listener(seat_obj, &seat_listener, data);

    state.seats.append(state.allocator, .{ .obj = seat_obj }) catch {
        log.err("out of memory while tracking seat", .{});
        c.river_seat_v1_destroy(seat_obj);
    };
}

fn windowClosed(data: ?*anyopaque, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;

    if (!state.removeWindow(window_obj)) {
        log.warn("window closed for unknown window", .{});
    }
}

fn windowDimensions(data: ?*anyopaque, window: ?*c.river_window_v1, width: i32, height: i32) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;

    const idx = state.findWindowIndex(window_obj) orelse return;
    state.windows.items[idx].width = width;
    state.windows.items[idx].height = height;
}

fn windowParent(data: ?*anyopaque, window: ?*c.river_window_v1, parent: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const idx = state.findWindowIndex(window_obj) orelse return;

    state.windows.items[idx].parent = parent;
    if (parent != null) {
        state.windows.items[idx].floating = true;
        state.ensureFloatingGeometry(&state.windows.items[idx]);
    }
}

fn windowMoveRequested(data: ?*anyopaque, window: ?*c.river_window_v1, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const seat_obj = seat orelse return;

    state.beginSeatOperation(seat_obj, window_obj, .move, c.RIVER_WINDOW_V1_EDGES_NONE);
}

fn windowResizeRequested(data: ?*anyopaque, window: ?*c.river_window_v1, seat: ?*c.river_seat_v1, edges: u32) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const seat_obj = seat orelse return;

    state.beginSeatOperation(seat_obj, window_obj, .resize, edges);
}

fn windowMaximizeRequested(data: ?*anyopaque, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const idx = state.findWindowIndex(window_obj) orelse return;

    state.windows.items[idx].fullscreen = true;
    state.windows.items[idx].fullscreen_output = state.windows.items[idx].assigned_output;
}

fn windowUnmaximizeRequested(data: ?*anyopaque, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const idx = state.findWindowIndex(window_obj) orelse return;

    state.windows.items[idx].fullscreen = false;
}

fn windowFullscreenRequested(data: ?*anyopaque, window: ?*c.river_window_v1, output: ?*c.river_output_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const idx = state.findWindowIndex(window_obj) orelse return;

    state.windows.items[idx].fullscreen = true;
    state.windows.items[idx].fullscreen_output = output orelse state.windows.items[idx].assigned_output;
}

fn windowExitFullscreenRequested(data: ?*anyopaque, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    const idx = state.findWindowIndex(window_obj) orelse return;

    state.windows.items[idx].fullscreen = false;
}

fn outputRemoved(data: ?*anyopaque, output: ?*c.river_output_v1) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    if (!state.removeOutput(output_obj)) {
        log.warn("output removed for unknown output", .{});
    }
}

fn outputPosition(data: ?*anyopaque, output: ?*c.river_output_v1, x: i32, y: i32) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    const idx = state.findOutputIndex(output_obj) orelse return;
    state.outputs.items[idx].x = x;
    state.outputs.items[idx].y = y;
}

fn outputDimensions(data: ?*anyopaque, output: ?*c.river_output_v1, width: i32, height: i32) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    const idx = state.findOutputIndex(output_obj) orelse return;
    state.outputs.items[idx].width = width;
    state.outputs.items[idx].height = height;
}

fn seatRemoved(data: ?*anyopaque, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;

    if (!state.removeSeat(seat_obj)) {
        log.warn("seat removed for unknown seat", .{});
    }
}

fn seatWindowInteraction(data: ?*anyopaque, _: ?*c.river_seat_v1, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    if (!state.focus_on_interaction) return;
    state.focused_window = window;
}

fn seatOpDelta(data: ?*anyopaque, seat: ?*c.river_seat_v1, dx: i32, dy: i32) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;
    const idx = state.findSeatIndex(seat_obj) orelse return;

    state.seats.items[idx].op.delta_x = dx;
    state.seats.items[idx].op.delta_y = dy;
}

fn seatOpRelease(data: ?*anyopaque, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;
    const idx = state.findSeatIndex(seat_obj) orelse return;

    state.seats.items[idx].op.released = true;
    state.seats.items[idx].op.pending_end = true;
}

fn seatPointerPosition(data: ?*anyopaque, seat: ?*c.river_seat_v1, x: i32, y: i32) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;
    const idx = state.findSeatIndex(seat_obj) orelse return;

    state.seats.items[idx].pointer_x = x;
    state.seats.items[idx].pointer_y = y;
    state.seats.items[idx].has_pointer_position = true;
}

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state = getState(data);
    const registry_obj = registry orelse return;
    if (interface == null) return;

    const iface_name = std.mem.span(interface);
    if (!std.mem.eql(u8, iface_name, "river_window_manager_v1")) return;
    if (state.wm != null) return;

    state.wm = bindTyped(c.river_window_manager_v1, registry_obj, name, &c.river_window_manager_v1_interface, chooseVersion(version));
    if (state.wm == null) {
        log.err("failed to bind river_window_manager_v1", .{});
        state.running = false;
        return;
    }

    _ = c.river_window_manager_v1_add_listener(state.wm.?, &wm_listener, data);
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

const wm_listener = c.river_window_manager_v1_listener{
    .unavailable = wmUnavailable,
    .finished = wmFinished,
    .manage_start = wmManageStart,
    .render_start = wmRenderStart,
    .session_locked = wmSessionLocked,
    .session_unlocked = wmSessionUnlocked,
    .window = wmWindow,
    .output = wmOutput,
    .seat = wmSeat,
};

const window_listener = c.river_window_v1_listener{
    .closed = windowClosed,
    .dimensions_hint = noop.windowDimensionsHint,
    .dimensions = windowDimensions,
    .app_id = noop.windowString,
    .title = noop.windowString,
    .parent = windowParent,
    .decoration_hint = noop.windowDecorationHint,
    .pointer_move_requested = windowMoveRequested,
    .pointer_resize_requested = windowResizeRequested,
    .show_window_menu_requested = noop.windowMenuReq,
    .maximize_requested = windowMaximizeRequested,
    .unmaximize_requested = windowUnmaximizeRequested,
    .fullscreen_requested = windowFullscreenRequested,
    .exit_fullscreen_requested = windowExitFullscreenRequested,
    .minimize_requested = noop.windowSimple,
    .unreliable_pid = noop.windowPid,
};

const output_listener = c.river_output_v1_listener{
    .removed = outputRemoved,
    .wl_output = noop.outputWlOutput,
    .position = outputPosition,
    .dimensions = outputDimensions,
};

const seat_listener = c.river_seat_v1_listener{
    .removed = seatRemoved,
    .wl_seat = noop.seatWlSeat,
    .pointer_enter = noop.seatPointerEnter,
    .pointer_leave = noop.seatPointerLeave,
    .window_interaction = seatWindowInteraction,
    .shell_surface_interaction = noop.seatShellSurfaceInteraction,
    .op_delta = seatOpDelta,
    .op_release = seatOpRelease,
    .pointer_position = seatPointerPosition,
};

pub const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};
