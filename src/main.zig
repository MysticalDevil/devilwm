const std = @import("std");
const log = std.log;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("river-window-management-v1-client-protocol.h");
});

const max_proto_version: u32 = 3;
// Nested sessions can transiently report no output geometry; keep windows visible.
const fallback_width: i32 = 1280;
const fallback_height: i32 = 720;

const LayoutRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const Window = struct {
    obj: *c.river_window_v1,
    node: *c.river_node_v1,
    width: i32 = 0,
    height: i32 = 0,
};

const Output = struct {
    obj: *c.river_output_v1,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 1280,
    height: i32 = 720,
};

const Seat = struct {
    obj: *c.river_seat_v1,
};

const State = struct {
    allocator: std.mem.Allocator,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    wm: ?*c.river_window_manager_v1 = null,
    running: bool = true,

    windows: std.ArrayListUnmanaged(Window) = .{},
    outputs: std.ArrayListUnmanaged(Output) = .{},
    seats: std.ArrayListUnmanaged(Seat) = .{},

    focused_window: ?*c.river_window_v1 = null,

    fn deinit(state: *State) void {
        var i: usize = 0;
        while (i < state.windows.items.len) : (i += 1) {
            c.river_node_v1_destroy(state.windows.items[i].node);
            c.river_window_v1_destroy(state.windows.items[i].obj);
        }
        state.windows.deinit(state.allocator);

        i = 0;
        while (i < state.outputs.items.len) : (i += 1) {
            c.river_output_v1_destroy(state.outputs.items[i].obj);
        }
        state.outputs.deinit(state.allocator);

        i = 0;
        while (i < state.seats.items.len) : (i += 1) {
            c.river_seat_v1_destroy(state.seats.items[i].obj);
        }
        state.seats.deinit(state.allocator);

        if (state.wm) |wm| c.river_window_manager_v1_destroy(wm);
    }

    fn firstOutput(state: *State) ?*Output {
        if (state.outputs.items.len == 0) return null;
        return &state.outputs.items[0];
    }

    fn layoutRect(state: *State) LayoutRect {
        if (state.firstOutput()) |out| {
            if (out.width > 0 and out.height > 0) {
                return .{
                    .x = out.x,
                    .y = out.y,
                    .width = out.width,
                    .height = out.height,
                };
            }
        }
        return .{
            .x = 0,
            .y = 0,
            .width = fallback_width,
            .height = fallback_height,
        };
    }

    fn findWindowIndex(state: *State, window_obj: *c.river_window_v1) ?usize {
        var i: usize = 0;
        while (i < state.windows.items.len) : (i += 1) {
            if (state.windows.items[i].obj == window_obj) return i;
        }
        return null;
    }

    fn findOutputIndex(state: *State, output_obj: *c.river_output_v1) ?usize {
        var i: usize = 0;
        while (i < state.outputs.items.len) : (i += 1) {
            if (state.outputs.items[i].obj == output_obj) return i;
        }
        return null;
    }

    fn findSeatIndex(state: *State, seat_obj: *c.river_seat_v1) ?usize {
        var i: usize = 0;
        while (i < state.seats.items.len) : (i += 1) {
            if (state.seats.items[i].obj == seat_obj) return i;
        }
        return null;
    }
};

fn getState(data: ?*anyopaque) *State {
    return @ptrCast(@alignCast(data.?));
}

fn bindTyped(comptime T: type, registry: *c.wl_registry, name: u32, iface: *const c.wl_interface, version: u32) ?*T {
    const raw = c.wl_registry_bind(registry, name, iface, version);
    if (raw == null) return null;
    return @ptrCast(raw);
}

fn chooseVersion(advertised: u32) u32 {
    return @min(advertised, max_proto_version);
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
    const rect = state.layoutRect();
    log.debug("manage_start windows={} outputs={} seats={} rect=({},{} {}x{})", .{
        state.windows.items.len,
        state.outputs.items.len,
        state.seats.items.len,
        rect.x,
        rect.y,
        rect.width,
        rect.height,
    });

    const count = state.windows.items.len;
    const n_i32: i32 = if (count > 0) @intCast(count) else 1;
    const base_h: i32 = @divTrunc(rect.height, n_i32);
    var y_acc: i32 = rect.y;

    var manage_i: usize = 0;
    while (manage_i < count) : (manage_i += 1) {
        const is_last = manage_i + 1 == count;
        const h = if (is_last) (rect.y + rect.height - y_acc) else base_h;
        const w = state.windows.items[manage_i];

        // Proposing dimensions is window-management state, so it must happen in manage.
        c.river_window_v1_propose_dimensions(w.obj, rect.width, h);
        c.river_window_v1_set_tiled(w.obj, c.RIVER_WINDOW_V1_EDGES_NONE);
        c.river_window_v1_set_capabilities(
            w.obj,
            c.RIVER_WINDOW_V1_CAPABILITIES_WINDOW_MENU |
                c.RIVER_WINDOW_V1_CAPABILITIES_MAXIMIZE |
                c.RIVER_WINDOW_V1_CAPABILITIES_FULLSCREEN,
        );
        y_acc += h;
    }

    if (state.windows.items.len > 0 and state.seats.items.len > 0) {
        const target = state.focused_window orelse state.windows.items[0].obj;
        var i: usize = 0;
        while (i < state.seats.items.len) : (i += 1) {
            c.river_seat_v1_focus_window(state.seats.items[i].obj, target);
        }
        state.focused_window = target;
    }

    c.river_window_manager_v1_manage_finish(wm_obj);
}

fn wmRenderStart(data: ?*anyopaque, wm: ?*c.river_window_manager_v1) callconv(.c) void {
    const state = getState(data);
    const wm_obj = wm orelse return;
    const rect = state.layoutRect();
    const count = state.windows.items.len;
    log.debug("render_start windows={} rect=({},{} {}x{})", .{
        count,
        rect.x,
        rect.y,
        rect.width,
        rect.height,
    });
    if (count > 0 and rect.width > 0 and rect.height > 0) {
        const n_i32: i32 = @intCast(count);
        const base_h: i32 = @divTrunc(rect.height, n_i32);
        var y_acc: i32 = rect.y;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const is_last = i + 1 == count;
            const h = if (is_last) (rect.y + rect.height - y_acc) else base_h;
            const win = state.windows.items[i];

            // Render phase only updates rendering state (position/visibility/order).
            c.river_node_v1_set_position(win.node, rect.x, y_acc);
            c.river_window_v1_show(win.obj);
            c.river_node_v1_place_top(win.node);

            y_acc += h;
        }
    }

    c.river_window_manager_v1_render_finish(wm_obj);
}

fn wmSessionLocked(_: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {}
fn wmSessionUnlocked(_: ?*anyopaque, _: ?*c.river_window_manager_v1) callconv(.c) void {}

fn wmWindow(data: ?*anyopaque, _: ?*c.river_window_manager_v1, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    log.info("new window", .{});

    const node = c.river_window_v1_get_node(window_obj) orelse {
        log.err("failed to create node for new window", .{});
        return;
    };

    _ = c.river_window_v1_add_listener(window_obj, &window_listener, data);

    state.windows.append(state.allocator, .{
        .obj = window_obj,
        .node = node,
    }) catch {
        log.err("out of memory while tracking window", .{});
        c.river_node_v1_destroy(node);
        c.river_window_v1_destroy(window_obj);
        return;
    };

    if (state.focused_window == null) state.focused_window = window_obj;
}

fn wmOutput(data: ?*anyopaque, _: ?*c.river_window_manager_v1, output: ?*c.river_output_v1) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;
    log.info("new output", .{});

    _ = c.river_output_v1_add_listener(output_obj, &output_listener, data);

    state.outputs.append(state.allocator, .{ .obj = output_obj }) catch {
        log.err("out of memory while tracking output", .{});
        c.river_output_v1_destroy(output_obj);
    };
}

fn wmSeat(data: ?*anyopaque, _: ?*c.river_window_manager_v1, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;
    log.info("new seat", .{});

    _ = c.river_seat_v1_add_listener(seat_obj, &seat_listener, data);

    state.seats.append(state.allocator, .{ .obj = seat_obj }) catch {
        log.err("out of memory while tracking seat", .{});
        c.river_seat_v1_destroy(seat_obj);
    };
}

fn windowClosed(data: ?*anyopaque, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;
    log.info("window closed", .{});

    const idx = state.findWindowIndex(window_obj) orelse return;
    const w = state.windows.items[idx];

    if (state.focused_window == window_obj) state.focused_window = null;

    c.river_node_v1_destroy(w.node);
    c.river_window_v1_destroy(w.obj);
    _ = state.windows.swapRemove(idx);

    if (state.focused_window == null and state.windows.items.len > 0) {
        state.focused_window = state.windows.items[0].obj;
    }
}

fn windowDimensions(data: ?*anyopaque, window: ?*c.river_window_v1, width: i32, height: i32) callconv(.c) void {
    const state = getState(data);
    const window_obj = window orelse return;

    const idx = state.findWindowIndex(window_obj) orelse return;
    state.windows.items[idx].width = width;
    state.windows.items[idx].height = height;
}

fn outputRemoved(data: ?*anyopaque, output: ?*c.river_output_v1) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;
    log.info("output removed", .{});

    const idx = state.findOutputIndex(output_obj) orelse return;
    c.river_output_v1_destroy(state.outputs.items[idx].obj);
    _ = state.outputs.swapRemove(idx);
}

fn outputPosition(data: ?*anyopaque, output: ?*c.river_output_v1, x: i32, y: i32) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    const idx = state.findOutputIndex(output_obj) orelse return;
    state.outputs.items[idx].x = x;
    state.outputs.items[idx].y = y;
    log.debug("output position idx={} -> ({},{})", .{ idx, x, y });
}

fn outputDimensions(data: ?*anyopaque, output: ?*c.river_output_v1, width: i32, height: i32) callconv(.c) void {
    const state = getState(data);
    const output_obj = output orelse return;

    const idx = state.findOutputIndex(output_obj) orelse return;
    state.outputs.items[idx].width = width;
    state.outputs.items[idx].height = height;
    log.debug("output dimensions idx={} -> {}x{}", .{ idx, width, height });
}

fn seatRemoved(data: ?*anyopaque, seat: ?*c.river_seat_v1) callconv(.c) void {
    const state = getState(data);
    const seat_obj = seat orelse return;
    log.info("seat removed", .{});

    const idx = state.findSeatIndex(seat_obj) orelse return;
    c.river_seat_v1_destroy(state.seats.items[idx].obj);
    _ = state.seats.swapRemove(idx);
}

fn seatWindowInteraction(data: ?*anyopaque, _: ?*c.river_seat_v1, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    state.focused_window = window;
    log.debug("seat window interaction: focused updated", .{});
}

// Wayland listeners may not be NULL for events the compositor can emit.
fn noopWindowDimensionsHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn noopWindowString(_: ?*anyopaque, _: ?*c.river_window_v1, _: [*c]const u8) callconv(.c) void {}
fn noopWindowParent(_: ?*anyopaque, _: ?*c.river_window_v1, _: ?*c.river_window_v1) callconv(.c) void {}
fn noopWindowDecorationHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: u32) callconv(.c) void {}
fn noopWindowMoveReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: ?*c.river_seat_v1) callconv(.c) void {}
fn noopWindowResizeReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: ?*c.river_seat_v1, _: u32) callconv(.c) void {}
fn noopWindowMenuReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32) callconv(.c) void {}
fn noopWindowSimple(_: ?*anyopaque, _: ?*c.river_window_v1) callconv(.c) void {}
fn noopWindowFullscreenReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: ?*c.river_output_v1) callconv(.c) void {}
fn noopWindowPid(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32) callconv(.c) void {}
fn noopOutputWlOutput(_: ?*anyopaque, _: ?*c.river_output_v1, _: u32) callconv(.c) void {}
fn noopSeatWlSeat(_: ?*anyopaque, _: ?*c.river_seat_v1, _: u32) callconv(.c) void {}
fn noopSeatPointerEnter(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_window_v1) callconv(.c) void {}
fn noopSeatPointerLeave(_: ?*anyopaque, _: ?*c.river_seat_v1) callconv(.c) void {}
fn noopSeatShellSurfaceInteraction(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_shell_surface_v1) callconv(.c) void {}
fn noopSeatOpDelta(_: ?*anyopaque, _: ?*c.river_seat_v1, _: i32, _: i32) callconv(.c) void {}
fn noopSeatOpRelease(_: ?*anyopaque, _: ?*c.river_seat_v1) callconv(.c) void {}
fn noopSeatPointerPosition(_: ?*anyopaque, _: ?*c.river_seat_v1, _: i32, _: i32) callconv(.c) void {}

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state = getState(data);
    const registry_obj = registry orelse return;
    if (interface == null) return;

    const iface_name = std.mem.span(interface);
    log.debug("registry global: {s} name={} version={}", .{ iface_name, name, version });
    if (!std.mem.eql(u8, iface_name, "river_window_manager_v1")) return;
    if (state.wm != null) return;

    state.wm = bindTyped(c.river_window_manager_v1, registry_obj, name, &c.river_window_manager_v1_interface, chooseVersion(version));
    if (state.wm == null) {
        log.err("failed to bind river_window_manager_v1", .{});
        state.running = false;
        return;
    }
    log.info("bound river_window_manager_v1 version={}", .{chooseVersion(version)});

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
    .dimensions_hint = noopWindowDimensionsHint,
    .dimensions = windowDimensions,
    .app_id = noopWindowString,
    .title = noopWindowString,
    .parent = noopWindowParent,
    .decoration_hint = noopWindowDecorationHint,
    .pointer_move_requested = noopWindowMoveReq,
    .pointer_resize_requested = noopWindowResizeReq,
    .show_window_menu_requested = noopWindowMenuReq,
    .maximize_requested = noopWindowSimple,
    .unmaximize_requested = noopWindowSimple,
    .fullscreen_requested = noopWindowFullscreenReq,
    .exit_fullscreen_requested = noopWindowSimple,
    .minimize_requested = noopWindowSimple,
    .unreliable_pid = noopWindowPid,
};

const output_listener = c.river_output_v1_listener{
    .removed = outputRemoved,
    .wl_output = noopOutputWlOutput,
    .position = outputPosition,
    .dimensions = outputDimensions,
};

const seat_listener = c.river_seat_v1_listener{
    .removed = seatRemoved,
    .wl_seat = noopSeatWlSeat,
    .pointer_enter = noopSeatPointerEnter,
    .pointer_leave = noopSeatPointerLeave,
    .window_interaction = seatWindowInteraction,
    .shell_surface_interaction = noopSeatShellSurfaceInteraction,
    .op_delta = noopSeatOpDelta,
    .op_release = noopSeatOpRelease,
    .pointer_position = noopSeatPointerPosition,
};

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) @panic("memory leak detected");
    }

    var state = State{
        .allocator = gpa.allocator(),
    };

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

    _ = c.wl_registry_add_listener(state.registry, &registry_listener, &state);
    log.info("waiting for globals...", .{});

    if (c.wl_display_roundtrip(state.display) < 0) {
        return error.RoundtripFailed;
    }

    if (state.wm == null) {
        log.err("river_window_manager_v1 not advertised on this compositor", .{});
        return error.MissingRiverProtocol;
    }
    log.info("devilwm initialized", .{});

    // Fetch initial objects/state and allow first manage/render sequences.
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
