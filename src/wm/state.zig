const std = @import("std");
const log = std.log;
const protocol = @import("protocol.zig");
const types = @import("types.zig");

const c = protocol.c;
const Phase = types.Phase;
const LayoutMode = types.LayoutMode;
const LayoutRect = types.LayoutRect;
const OpKind = types.OpKind;
const Window = types.Window;
const Output = types.Output;
const Seat = types.Seat;

const fallback_width = protocol.fallback_width;
const fallback_height = protocol.fallback_height;
const min_floating_width = protocol.min_floating_width;
const min_floating_height = protocol.min_floating_height;

pub const State = struct {
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

    pub fn deinit(state: *State) void {
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

    pub fn beginPhase(state: *State, phase: Phase) bool {
        if (state.phase != .idle) {
            log.err("protocol phase violation: begin {s} while in {s}", .{ @tagName(phase), @tagName(state.phase) });
            state.running = false;
            return false;
        }
        state.phase = phase;
        return true;
    }

    pub fn endPhase(state: *State, phase: Phase) void {
        if (state.phase != phase) {
            log.err("protocol phase violation: end {s} while in {s}", .{ @tagName(phase), @tagName(state.phase) });
            state.running = false;
            state.phase = .idle;
            return;
        }
        state.phase = .idle;
    }

    pub fn findWindowIndex(state: *State, window_obj: *c.river_window_v1) ?usize {
        for (state.windows.items, 0..) |window, i| {
            if (window.obj == window_obj) return i;
        }
        return null;
    }

    pub fn findOutputIndex(state: *State, output_obj: *c.river_output_v1) ?usize {
        for (state.outputs.items, 0..) |output, i| {
            if (output.obj == output_obj) return i;
        }
        return null;
    }

    pub fn findSeatIndex(state: *State, seat_obj: *c.river_seat_v1) ?usize {
        for (state.seats.items, 0..) |seat, i| {
            if (seat.obj == seat_obj) return i;
        }
        return null;
    }

    pub fn hasOutput(state: *State, output_obj: *c.river_output_v1) bool {
        return state.findOutputIndex(output_obj) != null;
    }

    pub fn firstOutputObject(state: *State) ?*c.river_output_v1 {
        if (state.outputs.items.len == 0) return null;
        return state.outputs.items[0].obj;
    }

    pub fn outputRectFromObject(state: *State, output_obj: ?*c.river_output_v1) LayoutRect {
        if (output_obj) |obj| {
            if (state.findOutputIndex(obj)) |idx| {
                return state.outputs.items[idx].rect();
            }
        }
        return .{ .x = 0, .y = 0, .width = fallback_width, .height = fallback_height };
    }

    pub fn outputAtPoint(state: *State, x: i32, y: i32) ?*c.river_output_v1 {
        for (state.outputs.items) |*output| {
            const rect = output.rect();
            if (x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height) {
                return output.obj;
            }
        }
        return null;
    }

    pub fn chooseOutputForNewWindow(state: *State) ?*c.river_output_v1 {
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

    pub fn ensureWindowOutputAssignments(state: *State) void {
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

    pub fn reconcileFocus(state: *State) void {
        if (state.focused_window) |focused| {
            if (state.findWindowIndex(focused) != null) return;
            state.focused_window = null;
        }

        if (state.windows.items.len > 0) {
            state.focused_window = state.windows.items[state.windows.items.len - 1].obj;
        }
    }

    pub fn applyManageWindowState(state: *State, window: *Window, width: i32, height: i32, tiled_edges: u32) void {
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

    pub fn applyRenderWindowState(state: *State, window: *Window, show: bool, focused: bool, fullscreen: bool) void {
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

    pub fn removeWindow(state: *State, window_obj: *c.river_window_v1) bool {
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

    pub fn removeOutput(state: *State, output_obj: *c.river_output_v1) bool {
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

    pub fn removeSeat(state: *State, seat_obj: *c.river_seat_v1) bool {
        const idx = state.findSeatIndex(seat_obj) orelse return false;
        c.river_seat_v1_destroy(state.seats.items[idx].obj);
        _ = state.seats.swapRemove(idx);
        return true;
    }

    pub fn windowBelongsToOutput(window: *const Window, output_obj: ?*c.river_output_v1) bool {
        return window.assigned_output == output_obj;
    }

    pub fn ensureFloatingGeometry(state: *State, window: *Window) void {
        if (window.floating_initialized and window.render_w > 0 and window.render_h > 0) return;

        const rect = state.outputRectFromObject(window.assigned_output);
        window.render_w = @max(min_floating_width, @divTrunc(rect.width * 3, 5));
        window.render_h = @max(min_floating_height, @divTrunc(rect.height * 3, 5));
        window.render_x = rect.x + @divTrunc(rect.width - window.render_w, 2);
        window.render_y = rect.y + @divTrunc(rect.height - window.render_h, 2);
        window.floating_initialized = true;
    }

    pub fn beginSeatOperation(state: *State, seat_obj: *c.river_seat_v1, window_obj: *c.river_window_v1, kind: OpKind, edges: u32) void {
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

    pub fn applySeatOps(state: *State) void {
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
};
