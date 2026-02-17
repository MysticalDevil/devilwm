const std = @import("std");
const log = std.log;
const build_options = @import("build_options");
const protocol = @import("wm/protocol.zig");
const env = @import("wm/env.zig");
const types = @import("wm/types.zig");
const c = protocol.c;

const max_proto_version = protocol.max_proto_version;
const fallback_width = protocol.fallback_width;
const fallback_height = protocol.fallback_height;
const min_floating_width = protocol.min_floating_width;
const min_floating_height = protocol.min_floating_height;

pub const std_options: std.Options = .{
    .log_level = if (build_options.verbose_logs) .debug else .warn,
};

const Phase = types.Phase;
const LayoutMode = types.LayoutMode;
const OpKind = types.OpKind;
const LayoutRect = types.LayoutRect;
const Window = types.Window;
const Output = types.Output;
const Seat = types.Seat;

const State = struct {
    allocator: std.mem.Allocator,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    wm: ?*c.river_window_manager_v1 = null,
    running: bool = true,
    phase: Phase = .idle,

    layout_mode: LayoutMode = .i3,
    focus_on_interaction: bool = true,

    windows: std.ArrayListUnmanaged(Window) = .{},
    outputs: std.ArrayListUnmanaged(Output) = .{},
    seats: std.ArrayListUnmanaged(Seat) = .{},

    focused_window: ?*c.river_window_v1 = null,

    fn deinit(state: *State) void {
        state.focused_window = null;
        state.phase = .idle;

        var i: usize = 0;
        while (i < state.windows.items.len) : (i += 1) {
            c.river_node_v1_destroy(state.windows.items[i].node);
            c.river_window_v1_destroy(state.windows.items[i].obj);
        }
        state.windows.deinit(state.allocator);
        state.windows = .{};

        i = 0;
        while (i < state.outputs.items.len) : (i += 1) {
            c.river_output_v1_destroy(state.outputs.items[i].obj);
        }
        state.outputs.deinit(state.allocator);
        state.outputs = .{};

        i = 0;
        while (i < state.seats.items.len) : (i += 1) {
            c.river_seat_v1_destroy(state.seats.items[i].obj);
        }
        state.seats.deinit(state.allocator);
        state.seats = .{};

        if (state.wm) |wm| {
            c.river_window_manager_v1_destroy(wm);
            state.wm = null;
        }
        if (state.registry) |registry| {
            c.wl_registry_destroy(registry);
            state.registry = null;
        }
    }

    fn beginPhase(state: *State, phase: Phase) bool {
        if (state.phase != .idle) {
            log.err("protocol phase violation: begin {s} while in {s}", .{ @tagName(phase), @tagName(state.phase) });
            state.running = false;
            return false;
        }
        state.phase = phase;
        return true;
    }

    fn endPhase(state: *State, phase: Phase) void {
        if (state.phase != phase) {
            log.err("protocol phase violation: end {s} while in {s}", .{ @tagName(phase), @tagName(state.phase) });
            state.running = false;
            state.phase = .idle;
            return;
        }
        state.phase = .idle;
    }

    fn findWindowIndex(state: *State, window_obj: *c.river_window_v1) ?usize {
        for (state.windows.items, 0..) |window, i| {
            if (window.obj == window_obj) return i;
        }
        return null;
    }

    fn findOutputIndex(state: *State, output_obj: *c.river_output_v1) ?usize {
        for (state.outputs.items, 0..) |output, i| {
            if (output.obj == output_obj) return i;
        }
        return null;
    }

    fn findSeatIndex(state: *State, seat_obj: *c.river_seat_v1) ?usize {
        for (state.seats.items, 0..) |seat, i| {
            if (seat.obj == seat_obj) return i;
        }
        return null;
    }

    fn hasOutput(state: *State, output_obj: *c.river_output_v1) bool {
        return state.findOutputIndex(output_obj) != null;
    }

    fn firstOutputObject(state: *State) ?*c.river_output_v1 {
        if (state.outputs.items.len == 0) return null;
        return state.outputs.items[0].obj;
    }

    fn outputRectFromObject(state: *State, output_obj: ?*c.river_output_v1) LayoutRect {
        if (output_obj) |obj| {
            if (state.findOutputIndex(obj)) |idx| {
                return state.outputs.items[idx].rect();
            }
        }
        return .{ .x = 0, .y = 0, .width = fallback_width, .height = fallback_height };
    }

    fn outputAtPoint(state: *State, x: i32, y: i32) ?*c.river_output_v1 {
        for (state.outputs.items) |*output| {
            const rect = output.rect();
            if (x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height) {
                return output.obj;
            }
        }
        return null;
    }

    fn chooseOutputForNewWindow(state: *State) ?*c.river_output_v1 {
        if (state.focused_window) |focused| {
            if (state.findWindowIndex(focused)) |idx| {
                if (state.windows.items[idx].assigned_output) |output_obj| {
                    if (state.hasOutput(output_obj)) return output_obj;
                }
            }
        }

        for (state.seats.items) |seat| {
            if (seat.has_pointer_position) {
                if (state.outputAtPoint(seat.pointer_x, seat.pointer_y)) |output_obj| {
                    return output_obj;
                }
            }
        }

        return state.firstOutputObject();
    }

    fn ensureWindowOutputAssignments(state: *State) void {
        for (state.windows.items) |*window| {
            if (window.assigned_output) |out| {
                if (!state.hasOutput(out)) window.assigned_output = null;
            }
            if (window.fullscreen_output) |out| {
                if (!state.hasOutput(out)) window.fullscreen_output = null;
            }
            if (window.assigned_output == null and state.outputs.items.len > 0) {
                window.assigned_output = state.outputs.items[0].obj;
            }
        }
    }

    fn reconcileFocus(state: *State) void {
        if (state.focused_window) |focused| {
            if (state.findWindowIndex(focused) != null) return;
            state.focused_window = null;
        }

        if (state.windows.items.len > 0) {
            state.focused_window = state.windows.items[state.windows.items.len - 1].obj;
        }
    }

    fn applyManageWindowState(state: *State, window: *Window, width: i32, height: i32, tiled_edges: u32) void {
        if (state.phase != .manage) {
            log.err("protocol phase violation: window-management state requested outside manage phase", .{});
            state.running = false;
            return;
        }

        const safe_w = @max(1, width);
        const safe_h = @max(1, height);

        window.render_w = safe_w;
        window.render_h = safe_h;

        c.river_window_v1_propose_dimensions(window.obj, safe_w, safe_h);
        c.river_window_v1_set_tiled(window.obj, tiled_edges);
        c.river_window_v1_set_capabilities(
            window.obj,
            c.RIVER_WINDOW_V1_CAPABILITIES_WINDOW_MENU |
                c.RIVER_WINDOW_V1_CAPABILITIES_MAXIMIZE |
                c.RIVER_WINDOW_V1_CAPABILITIES_FULLSCREEN,
        );
    }

    fn applyRenderWindowState(state: *State, window: *Window, show: bool, focused: bool, fullscreen: bool) void {
        if (state.phase != .render) {
            log.err("protocol phase violation: rendering state requested outside render phase", .{});
            state.running = false;
            return;
        }

        if (!show) {
            c.river_window_v1_hide(window.obj);
            return;
        }

        c.river_node_v1_set_position(window.node, window.render_x, window.render_y);

        if (fullscreen) {
            c.river_window_v1_set_borders(window.obj, c.RIVER_WINDOW_V1_EDGES_NONE, 0, 0, 0, 0, 0);
        } else {
            const border_width: i32 = if (focused) 2 else 1;
            const edges: u32 = @intCast(c.RIVER_WINDOW_V1_EDGES_TOP |
                c.RIVER_WINDOW_V1_EDGES_BOTTOM |
                c.RIVER_WINDOW_V1_EDGES_LEFT |
                c.RIVER_WINDOW_V1_EDGES_RIGHT);
            if (focused) {
                c.river_window_v1_set_borders(window.obj, edges, border_width, 0x2A2A2AFF, 0x6AA4FFFF, 0xEAF2FFFF, 0xFFFFFFFF);
            } else {
                c.river_window_v1_set_borders(window.obj, edges, border_width, 0x303030FF, 0x505050FF, 0x707070FF, 0xFFFFFFFF);
            }
        }

        c.river_window_v1_show(window.obj);
        c.river_node_v1_place_top(window.node);
    }

    fn removeWindow(state: *State, window_obj: *c.river_window_v1) bool {
        const idx = state.findWindowIndex(window_obj) orelse return false;
        const tracked = state.windows.items[idx];

        for (state.seats.items) |*seat| {
            if (seat.op.target == window_obj) {
                seat.op.pending_end = true;
                seat.op.released = true;
            }
        }

        if (state.focused_window == window_obj) state.focused_window = null;

        c.river_node_v1_destroy(tracked.node);
        c.river_window_v1_destroy(tracked.obj);
        _ = state.windows.swapRemove(idx);

        state.reconcileFocus();
        return true;
    }

    fn removeOutput(state: *State, output_obj: *c.river_output_v1) bool {
        const idx = state.findOutputIndex(output_obj) orelse return false;

        for (state.windows.items) |*window| {
            if (window.assigned_output == output_obj) window.assigned_output = null;
            if (window.fullscreen_output == output_obj) {
                window.fullscreen_output = null;
                window.fullscreen = false;
            }
        }

        c.river_output_v1_destroy(state.outputs.items[idx].obj);
        _ = state.outputs.swapRemove(idx);
        state.ensureWindowOutputAssignments();
        return true;
    }

    fn removeSeat(state: *State, seat_obj: *c.river_seat_v1) bool {
        const idx = state.findSeatIndex(seat_obj) orelse return false;
        c.river_seat_v1_destroy(state.seats.items[idx].obj);
        _ = state.seats.swapRemove(idx);
        return true;
    }

    fn windowBelongsToOutput(window: *const Window, output_obj: ?*c.river_output_v1) bool {
        return window.assigned_output == output_obj;
    }

    fn ensureFloatingGeometry(state: *State, window: *Window) void {
        if (window.floating_initialized and window.render_w > 0 and window.render_h > 0) return;

        const rect = state.outputRectFromObject(window.assigned_output);
        window.render_w = @max(min_floating_width, @divTrunc(rect.width * 3, 5));
        window.render_h = @max(min_floating_height, @divTrunc(rect.height * 3, 5));
        window.render_x = rect.x + @divTrunc(rect.width - window.render_w, 2);
        window.render_y = rect.y + @divTrunc(rect.height - window.render_h, 2);
        window.floating_initialized = true;
    }

    fn beginSeatOperation(state: *State, seat_obj: *c.river_seat_v1, window_obj: *c.river_window_v1, kind: OpKind, edges: u32) void {
        const seat_idx = state.findSeatIndex(seat_obj) orelse return;
        const window_idx = state.findWindowIndex(window_obj) orelse return;

        const window = &state.windows.items[window_idx];
        window.floating = true;
        state.ensureFloatingGeometry(window);

        state.seats.items[seat_idx].op = .{
            .kind = kind,
            .target = window_obj,
            .edges = edges,
            .pending_start = true,
            .pending_end = false,
            .released = false,
            .delta_x = 0,
            .delta_y = 0,
            .base_x = window.render_x,
            .base_y = window.render_y,
            .base_w = window.render_w,
            .base_h = window.render_h,
        };
    }

    fn applySeatOps(state: *State) void {
        for (state.seats.items) |*seat| {
            if (seat.op.kind == .none) continue;

            const target_obj = seat.op.target orelse {
                seat.op = .{};
                continue;
            };
            const target_idx = state.findWindowIndex(target_obj) orelse {
                seat.op = .{};
                continue;
            };
            const target = &state.windows.items[target_idx];

            if (seat.op.pending_start) {
                c.river_seat_v1_op_start_pointer(seat.obj);
                if (seat.op.kind == .resize) {
                    c.river_window_v1_inform_resize_start(target.obj);
                }
                seat.op.pending_start = false;
            }

            if (seat.op.kind == .move) {
                target.render_x = seat.op.base_x + seat.op.delta_x;
                target.render_y = seat.op.base_y + seat.op.delta_y;
            } else if (seat.op.kind == .resize) {
                var new_x = seat.op.base_x;
                var new_y = seat.op.base_y;
                var new_w = seat.op.base_w;
                var new_h = seat.op.base_h;

                if ((seat.op.edges & c.RIVER_WINDOW_V1_EDGES_LEFT) != 0) {
                    new_x = seat.op.base_x + seat.op.delta_x;
                    new_w = seat.op.base_w - seat.op.delta_x;
                }
                if ((seat.op.edges & c.RIVER_WINDOW_V1_EDGES_RIGHT) != 0) {
                    new_w = seat.op.base_w + seat.op.delta_x;
                }
                if ((seat.op.edges & c.RIVER_WINDOW_V1_EDGES_TOP) != 0) {
                    new_y = seat.op.base_y + seat.op.delta_y;
                    new_h = seat.op.base_h - seat.op.delta_y;
                }
                if ((seat.op.edges & c.RIVER_WINDOW_V1_EDGES_BOTTOM) != 0) {
                    new_h = seat.op.base_h + seat.op.delta_y;
                }

                target.render_x = new_x;
                target.render_y = new_y;
                target.render_w = @max(min_floating_width, new_w);
                target.render_h = @max(min_floating_height, new_h);
            }
            target.floating_initialized = true;

            if (seat.op.pending_end or seat.op.released) {
                if (seat.op.kind == .resize) {
                    c.river_window_v1_inform_resize_end(target.obj);
                }
                c.river_seat_v1_op_end(seat.obj);
                seat.op = .{};
            }
        }
    }

    fn applyLayoutForOutput(state: *State, output_obj: ?*c.river_output_v1, rect: LayoutRect) void {
        var tiled = std.ArrayListUnmanaged(usize){};
        defer tiled.deinit(state.allocator);

        var floating = std.ArrayListUnmanaged(usize){};
        defer floating.deinit(state.allocator);

        var fullscreen_idx: ?usize = null;

        for (state.windows.items, 0..) |window, i| {
            if (!windowBelongsToOutput(&window, output_obj)) continue;

            if (window.fullscreen) {
                if (fullscreen_idx == null or window.obj == state.focused_window) {
                    fullscreen_idx = i;
                }
                continue;
            }

            if (window.floating or window.parent != null) {
                floating.append(state.allocator, i) catch {
                    state.running = false;
                    return;
                };
            } else {
                tiled.append(state.allocator, i) catch {
                    state.running = false;
                    return;
                };
            }
        }

        if (fullscreen_idx) |idx| {
            const window = &state.windows.items[idx];
            const fullscreen_out = if (window.fullscreen_output != null and state.hasOutput(window.fullscreen_output.?))
                window.fullscreen_output
            else
                output_obj;
            if (fullscreen_out != null) {
                c.river_window_v1_fullscreen(window.obj, fullscreen_out.?);
                c.river_window_v1_inform_fullscreen(window.obj);
                window.fullscreen_applied = true;
                window.render_x = rect.x;
                window.render_y = rect.y;
                window.render_w = rect.width;
                window.render_h = rect.height;
            }
        }

        for (state.windows.items) |*window| {
            if (!windowBelongsToOutput(window, output_obj)) continue;
            if (!window.fullscreen and window.fullscreen_applied) {
                c.river_window_v1_exit_fullscreen(window.obj);
                c.river_window_v1_inform_not_fullscreen(window.obj);
                window.fullscreen_applied = false;
            }
        }

        const tiled_count = tiled.items.len;
        switch (state.layout_mode) {
            .monocle => {
                for (tiled.items) |idx| {
                    const window = &state.windows.items[idx];
                    window.render_x = rect.x;
                    window.render_y = rect.y;
                    state.applyManageWindowState(window, rect.width, rect.height, c.RIVER_WINDOW_V1_EDGES_NONE);
                }
            },
            .master_stack => {
                if (tiled_count == 0) {} else if (tiled_count == 1) {
                    const window = &state.windows.items[tiled.items[0]];
                    window.render_x = rect.x;
                    window.render_y = rect.y;
                    state.applyManageWindowState(window, rect.width, rect.height, c.RIVER_WINDOW_V1_EDGES_NONE);
                } else {
                    const master_w = @max(1, @divTrunc(rect.width * 3, 5));
                    const stack_w = @max(1, rect.width - master_w);

                    {
                        const master = &state.windows.items[tiled.items[0]];
                        master.render_x = rect.x;
                        master.render_y = rect.y;
                        const edges: u32 = @intCast(c.RIVER_WINDOW_V1_EDGES_TOP |
                            c.RIVER_WINDOW_V1_EDGES_BOTTOM |
                            c.RIVER_WINDOW_V1_EDGES_RIGHT);
                        state.applyManageWindowState(master, master_w, rect.height, edges);
                    }

                    const stack_count: i32 = @intCast(tiled_count - 1);
                    const base_h = @divTrunc(rect.height, stack_count);
                    var y_acc = rect.y;
                    var i: usize = 1;
                    while (i < tiled_count) : (i += 1) {
                        const is_last = i + 1 == tiled_count;
                        const h = if (is_last) (rect.y + rect.height - y_acc) else base_h;
                        const window = &state.windows.items[tiled.items[i]];
                        window.render_x = rect.x + master_w;
                        window.render_y = y_acc;
                        const edges: u32 = @intCast(c.RIVER_WINDOW_V1_EDGES_LEFT |
                            c.RIVER_WINDOW_V1_EDGES_RIGHT |
                            (if (i > 1) c.RIVER_WINDOW_V1_EDGES_TOP else c.RIVER_WINDOW_V1_EDGES_NONE) |
                            (if (!is_last) c.RIVER_WINDOW_V1_EDGES_BOTTOM else c.RIVER_WINDOW_V1_EDGES_NONE));
                        state.applyManageWindowState(window, stack_w, h, edges);
                        y_acc += h;
                    }
                }
            },
            .vertical_stack => {
                if (tiled_count > 0) {
                    const n_i32: i32 = @intCast(tiled_count);
                    const base_h: i32 = @divTrunc(rect.height, n_i32);
                    var y_acc: i32 = rect.y;

                    for (tiled.items, 0..) |idx, i| {
                        const is_last = i + 1 == tiled_count;
                        const h = if (is_last) (rect.y + rect.height - y_acc) else base_h;
                        const window = &state.windows.items[idx];
                        window.render_x = rect.x;
                        window.render_y = y_acc;
                        const edges: u32 = @intCast(c.RIVER_WINDOW_V1_EDGES_LEFT |
                            c.RIVER_WINDOW_V1_EDGES_RIGHT |
                            (if (i > 0) c.RIVER_WINDOW_V1_EDGES_TOP else c.RIVER_WINDOW_V1_EDGES_NONE) |
                            (if (!is_last) c.RIVER_WINDOW_V1_EDGES_BOTTOM else c.RIVER_WINDOW_V1_EDGES_NONE));
                        state.applyManageWindowState(window, rect.width, h, edges);
                        y_acc += h;
                    }
                }
            },
            .i3 => {
                if (tiled_count > 0) {
                    const n_i32: i32 = @intCast(tiled_count);
                    const base_w: i32 = @divTrunc(rect.width, n_i32);
                    var x_acc: i32 = rect.x;

                    for (tiled.items, 0..) |idx, i| {
                        const is_last = i + 1 == tiled_count;
                        const w = if (is_last) (rect.x + rect.width - x_acc) else base_w;
                        const window = &state.windows.items[idx];
                        window.render_x = x_acc;
                        window.render_y = rect.y;
                        const edges: u32 = @intCast(c.RIVER_WINDOW_V1_EDGES_TOP |
                            c.RIVER_WINDOW_V1_EDGES_BOTTOM |
                            (if (i > 0) c.RIVER_WINDOW_V1_EDGES_LEFT else c.RIVER_WINDOW_V1_EDGES_NONE) |
                            (if (!is_last) c.RIVER_WINDOW_V1_EDGES_RIGHT else c.RIVER_WINDOW_V1_EDGES_NONE));
                        state.applyManageWindowState(window, w, rect.height, edges);
                        x_acc += w;
                    }
                }
            },
        }

        for (floating.items) |idx| {
            const window = &state.windows.items[idx];
            window.floating = true;
            state.ensureFloatingGeometry(window);
            state.applyManageWindowState(window, window.render_w, window.render_h, c.RIVER_WINDOW_V1_EDGES_NONE);
        }
    }

    fn applyManageLayout(state: *State) void {
        state.ensureWindowOutputAssignments();
        state.reconcileFocus();
        state.applySeatOps();

        if (state.outputs.items.len == 0) {
            state.applyLayoutForOutput(null, .{ .x = 0, .y = 0, .width = fallback_width, .height = fallback_height });
        } else {
            for (state.outputs.items) |output| {
                state.applyLayoutForOutput(output.obj, output.rect());
            }
        }

        if (state.seats.items.len > 0) {
            if (state.focused_window) |target| {
                for (state.seats.items) |seat| {
                    c.river_seat_v1_focus_window(seat.obj, target);
                }
            } else {
                for (state.seats.items) |seat| {
                    c.river_seat_v1_clear_focus(seat.obj);
                }
            }
        }
    }

    fn topFullscreenForOutput(state: *State, output_obj: ?*c.river_output_v1) ?usize {
        var top: ?usize = null;
        for (state.windows.items, 0..) |window, i| {
            if (!windowBelongsToOutput(&window, output_obj)) continue;
            if (!window.fullscreen) continue;
            if (top == null or window.obj == state.focused_window) {
                top = i;
            }
        }
        return top;
    }

    fn renderForOutput(state: *State, output_obj: ?*c.river_output_v1) void {
        const fullscreen_idx = state.topFullscreenForOutput(output_obj);
        if (fullscreen_idx) |idx| {
            const focused = state.windows.items[idx].obj == state.focused_window;
            state.applyRenderWindowState(&state.windows.items[idx], true, focused, true);
            return;
        }

        for (state.windows.items) |*window| {
            if (!windowBelongsToOutput(window, output_obj)) continue;
            if (window.floating or window.parent != null) continue;
            const focused = window.obj == state.focused_window;
            state.applyRenderWindowState(window, true, focused, false);
        }

        for (state.windows.items) |*window| {
            if (!windowBelongsToOutput(window, output_obj)) continue;
            if (!(window.floating or window.parent != null)) continue;
            if (window.parent != null) continue;
            const focused = window.obj == state.focused_window;
            state.applyRenderWindowState(window, true, focused, false);
        }

        for (state.windows.items) |*window| {
            if (!windowBelongsToOutput(window, output_obj)) continue;
            if (!(window.floating or window.parent != null)) continue;
            if (window.parent == null) continue;
            const focused = window.obj == state.focused_window;
            state.applyRenderWindowState(window, true, focused, false);
        }
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

    state.applyManageLayout();
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
        state.renderForOutput(null);
    } else {
        for (state.outputs.items) |output| {
            state.renderForOutput(output.obj);
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

    // i3-like default: focus follows newly mapped window.
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

// Wayland listeners may not be NULL for events the compositor can emit.
fn noopWindowDimensionsHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn noopWindowString(_: ?*anyopaque, _: ?*c.river_window_v1, _: [*c]const u8) callconv(.c) void {}
fn noopWindowDecorationHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: u32) callconv(.c) void {}
fn noopWindowMenuReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32) callconv(.c) void {}
fn noopWindowSimple(_: ?*anyopaque, _: ?*c.river_window_v1) callconv(.c) void {}
fn noopWindowPid(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32) callconv(.c) void {}
fn noopOutputWlOutput(_: ?*anyopaque, _: ?*c.river_output_v1, _: u32) callconv(.c) void {}
fn noopSeatWlSeat(_: ?*anyopaque, _: ?*c.river_seat_v1, _: u32) callconv(.c) void {}
fn noopSeatPointerEnter(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_window_v1) callconv(.c) void {}
fn noopSeatPointerLeave(_: ?*anyopaque, _: ?*c.river_seat_v1) callconv(.c) void {}
fn noopSeatShellSurfaceInteraction(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_shell_surface_v1) callconv(.c) void {}

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
    .dimensions_hint = noopWindowDimensionsHint,
    .dimensions = windowDimensions,
    .app_id = noopWindowString,
    .title = noopWindowString,
    .parent = windowParent,
    .decoration_hint = noopWindowDecorationHint,
    .pointer_move_requested = windowMoveRequested,
    .pointer_resize_requested = windowResizeRequested,
    .show_window_menu_requested = noopWindowMenuReq,
    .maximize_requested = windowMaximizeRequested,
    .unmaximize_requested = windowUnmaximizeRequested,
    .fullscreen_requested = windowFullscreenRequested,
    .exit_fullscreen_requested = windowExitFullscreenRequested,
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
    .op_delta = seatOpDelta,
    .op_release = seatOpRelease,
    .pointer_position = seatPointerPosition,
};

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak = gpa.deinit();
        if (leak == .leak) @panic("memory leak detected");
    }

    var state = State{
        .allocator = gpa.allocator(),
        .layout_mode = env.parseLayoutModeEnv(),
        .focus_on_interaction = env.parseFocusOnInteractionEnv(),
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
