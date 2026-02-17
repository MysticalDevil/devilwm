const std = @import("std");
const protocol = @import("protocol.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const c = protocol.c;
const fallback_width = protocol.fallback_width;

const State = state_mod.State;
const LayoutMode = types.LayoutMode;
const LayoutRect = types.LayoutRect;

fn applyLayoutForOutput(state: *State, output_obj: ?*c.river_output_v1, rect: LayoutRect) void {
    var tiled = std.ArrayListUnmanaged(usize){};
    defer tiled.deinit(state.allocator);

    var floating = std.ArrayListUnmanaged(usize){};
    defer floating.deinit(state.allocator);

    var fullscreen_idx: ?usize = null;

    for (state.windows.items, 0..) |window, i| {
        if (!State.windowBelongsToOutput(&window, output_obj)) continue;

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
        if (!State.windowBelongsToOutput(window, output_obj)) continue;
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

pub fn applyManageLayout(state: *State) void {
    state.ensureWindowOutputAssignments();
    state.reconcileFocus();
    state.applySeatOps();

    if (state.outputs.items.len == 0) {
        applyLayoutForOutput(state, null, .{ .x = 0, .y = 0, .width = fallback_width, .height = protocol.fallback_height });
    } else {
        for (state.outputs.items) |output| {
            applyLayoutForOutput(state, output.obj, output.rect());
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
        if (!State.windowBelongsToOutput(&window, output_obj)) continue;
        if (!window.fullscreen) continue;
        if (top == null or window.obj == state.focused_window) {
            top = i;
        }
    }
    return top;
}

pub fn renderForOutput(state: *State, output_obj: ?*c.river_output_v1) void {
    const fullscreen_idx = topFullscreenForOutput(state, output_obj);
    if (fullscreen_idx) |idx| {
        const focused = state.windows.items[idx].obj == state.focused_window;
        state.applyRenderWindowState(&state.windows.items[idx], true, focused, true);
        return;
    }

    for (state.windows.items) |*window| {
        if (!State.windowBelongsToOutput(window, output_obj)) continue;
        if (window.floating or window.parent != null) continue;
        const focused = window.obj == state.focused_window;
        state.applyRenderWindowState(window, true, focused, false);
    }

    for (state.windows.items) |*window| {
        if (!State.windowBelongsToOutput(window, output_obj)) continue;
        if (!(window.floating or window.parent != null)) continue;
        if (window.parent != null) continue;
        const focused = window.obj == state.focused_window;
        state.applyRenderWindowState(window, true, focused, false);
    }

    for (state.windows.items) |*window| {
        if (!State.windowBelongsToOutput(window, output_obj)) continue;
        if (!(window.floating or window.parent != null)) continue;
        if (window.parent == null) continue;
        const focused = window.obj == state.focused_window;
        state.applyRenderWindowState(window, true, focused, false);
    }
}
