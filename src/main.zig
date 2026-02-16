const std = @import("std");
const log = std.log;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("river-window-management-v1-client-protocol.h");
});

const max_proto_version: u32 = 3;

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

    const out = state.firstOutput();
    if (out) |output| {
        var i: usize = 0;
        while (i < state.windows.items.len) : (i += 1) {
            const w = state.windows.items[i];
            c.river_window_v1_propose_dimensions(w.obj, output.width, output.height);
            c.river_window_v1_set_tiled(w.obj, c.RIVER_WINDOW_V1_EDGES_NONE);
            c.river_window_v1_set_capabilities(
                w.obj,
                c.RIVER_WINDOW_V1_CAPABILITIES_WINDOW_MENU |
                    c.RIVER_WINDOW_V1_CAPABILITIES_MAXIMIZE |
                    c.RIVER_WINDOW_V1_CAPABILITIES_FULLSCREEN,
            );
        }
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

    const out = state.firstOutput();
    if (out) |output| {
        const count = state.windows.items.len;
        if (count > 0 and output.width > 0 and output.height > 0) {
            const n_i32: i32 = @intCast(count);
            const base_h: i32 = @divTrunc(output.height, n_i32);
            var y_acc: i32 = output.y;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const is_last = i + 1 == count;
                const h = if (is_last) (output.y + output.height - y_acc) else base_h;
                const win = state.windows.items[i];

                c.river_node_v1_set_position(win.node, output.x, y_acc);
                c.river_window_v1_propose_dimensions(win.obj, output.width, h);
                c.river_window_v1_show(win.obj);
                c.river_node_v1_place_top(win.node);

                y_acc += h;
            }
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

    _ = c.river_output_v1_add_listener(output_obj, &output_listener, data);

    state.outputs.append(state.allocator, .{ .obj = output_obj }) catch {
        log.err("out of memory while tracking output", .{});
        c.river_output_v1_destroy(output_obj);
    };
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

    const idx = state.findSeatIndex(seat_obj) orelse return;
    c.river_seat_v1_destroy(state.seats.items[idx].obj);
    _ = state.seats.swapRemove(idx);
}

fn seatWindowInteraction(data: ?*anyopaque, _: ?*c.river_seat_v1, window: ?*c.river_window_v1) callconv(.c) void {
    const state = getState(data);
    state.focused_window = window;
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
    .dimensions_hint = null,
    .dimensions = windowDimensions,
    .app_id = null,
    .title = null,
    .parent = null,
    .decoration_hint = null,
    .pointer_move_requested = null,
    .pointer_resize_requested = null,
    .show_window_menu_requested = null,
    .maximize_requested = null,
    .unmaximize_requested = null,
    .fullscreen_requested = null,
    .exit_fullscreen_requested = null,
    .minimize_requested = null,
    .unreliable_pid = null,
};

const output_listener = c.river_output_v1_listener{
    .removed = outputRemoved,
    .wl_output = null,
    .position = outputPosition,
    .dimensions = outputDimensions,
};

const seat_listener = c.river_seat_v1_listener{
    .removed = seatRemoved,
    .wl_seat = null,
    .pointer_enter = null,
    .pointer_leave = null,
    .window_interaction = seatWindowInteraction,
    .shell_surface_interaction = null,
    .op_delta = null,
    .op_release = null,
    .pointer_position = null,
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

    if (c.wl_display_roundtrip(state.display) < 0) {
        return error.RoundtripFailed;
    }

    if (state.wm == null) {
        log.err("river_window_manager_v1 not advertised on this compositor", .{});
        return error.MissingRiverProtocol;
    }

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
