const std = @import("std");
const log = std.log;
const protocol = @import("protocol.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");

const c = protocol.c;
const Phase = types.Phase;
pub const LayoutMode = types.LayoutMode;
const LayoutRect = types.LayoutRect;
pub const OpKind = types.OpKind;
pub const Window = types.Window;
pub const Output = types.Output;
pub const Seat = types.Seat;

const fallback_width = protocol.fallback_width;
const fallback_height = protocol.fallback_height;
const min_floating_width = protocol.min_floating_width;
const min_floating_height = protocol.min_floating_height;

pub const QueuedAction = struct {
    action: config_mod.Action,
    owned_cmd: bool = false,
};

pub const KeyBindingRuntime = struct {
    state: *State,
    obj: *c.river_xkb_binding_v1,
    action: config_mod.Action,
    pending_enable: bool = true,
};

pub const PointerBindingRuntime = struct {
    state: *State,
    obj: *c.river_pointer_binding_v1,
    action: config_mod.Action,
    pending_enable: bool = true,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    config: config_mod.RuntimeConfig,

    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    wm: ?*c.river_window_manager_v1 = null,
    xkb: ?*c.river_xkb_bindings_v1 = null,
    layer_shell: ?*c.river_layer_shell_v1 = null,

    running: bool = true,
    phase: Phase = .idle,

    layout_mode: LayoutMode = .i3,
    focus_on_interaction: bool = true,

    windows: std.ArrayListUnmanaged(Window) = .{},
    outputs: std.ArrayListUnmanaged(Output) = .{},
    seats: std.ArrayListUnmanaged(Seat) = .{},

    key_runtime: std.ArrayListUnmanaged(*KeyBindingRuntime) = .{},
    pointer_runtime: std.ArrayListUnmanaged(*PointerBindingRuntime) = .{},
    pending_actions: std.ArrayListUnmanaged(QueuedAction) = .{},

    focused_window: ?*c.river_window_v1 = null,

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.RuntimeConfig) State {
        return .{
            .allocator = allocator,
            .config = cfg,
            .layout_mode = @enumFromInt(@intFromEnum(cfg.layout_mode)),
            .focus_on_interaction = cfg.focus_on_interaction,
        };
    }

    pub fn deinit(state: *State) void {
        state.focused_window = null;
        state.phase = .idle;

        for (state.key_runtime.items) |binding| {
            c.river_xkb_binding_v1_destroy(binding.obj);
            state.allocator.destroy(binding);
        }
        state.key_runtime.deinit(state.allocator);

        for (state.pointer_runtime.items) |binding| {
            c.river_pointer_binding_v1_destroy(binding.obj);
            state.allocator.destroy(binding);
        }
        state.pointer_runtime.deinit(state.allocator);

        freePendingActions(state);
        state.pending_actions.deinit(state.allocator);

        var i: usize = 0;
        while (i < state.windows.items.len) : (i += 1) {
            freeWindowStrings(state.allocator, &state.windows.items[i]);
            c.river_node_v1_destroy(state.windows.items[i].node);
            c.river_window_v1_destroy(state.windows.items[i].obj);
        }
        state.windows.deinit(state.allocator);
        state.windows = .{};

        i = 0;
        while (i < state.outputs.items.len) : (i += 1) {
            if (state.outputs.items[i].layer_output) |layer_output| {
                c.river_layer_shell_output_v1_destroy(layer_output);
            }
            c.river_output_v1_destroy(state.outputs.items[i].obj);
        }
        state.outputs.deinit(state.allocator);
        state.outputs = .{};

        i = 0;
        while (i < state.seats.items.len) : (i += 1) {
            if (state.seats.items[i].xkb_seat) |xkb_seat| {
                c.river_xkb_bindings_seat_v1_destroy(xkb_seat);
            }
            if (state.seats.items[i].layer_seat) |layer_seat| {
                c.river_layer_shell_seat_v1_destroy(layer_seat);
            }
            c.river_seat_v1_destroy(state.seats.items[i].obj);
        }
        state.seats.deinit(state.allocator);
        state.seats = .{};

        if (state.xkb) |xkb| {
            c.river_xkb_bindings_v1_destroy(xkb);
            state.xkb = null;
        }
        if (state.layer_shell) |layer_shell| {
            c.river_layer_shell_v1_destroy(layer_shell);
            state.layer_shell = null;
        }
        if (state.wm) |wm| {
            c.river_window_manager_v1_destroy(wm);
            state.wm = null;
        }
        if (state.registry) |registry| {
            c.wl_registry_destroy(registry);
            state.registry = null;
        }

        state.config.deinit();
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
            const style = if (focused) state.config.focused_border else state.config.unfocused_border;
            const width: i32 = @max(0, style.width);
            const edges: u32 = if (width == 0) 0 else @intCast(c.RIVER_WINDOW_V1_EDGES_TOP |
                c.RIVER_WINDOW_V1_EDGES_BOTTOM |
                c.RIVER_WINDOW_V1_EDGES_LEFT |
                c.RIVER_WINDOW_V1_EDGES_RIGHT);
            c.river_window_v1_set_borders(window.obj, edges, width, style.r, style.g, style.b, style.a);
        }

        c.river_window_v1_show(window.obj);
        c.river_node_v1_place_top(window.node);
    }

    pub fn removeWindow(state: *State, window_obj: *c.river_window_v1) bool {
        const idx = state.findWindowIndex(window_obj) orelse return false;

        for (state.seats.items) |*seat| {
            if (seat.op.target == window_obj) {
                seat.op.pending_end = true;
                seat.op.released = true;
            }
        }

        if (state.focused_window == window_obj) state.focused_window = null;

        freeWindowStrings(state.allocator, &state.windows.items[idx]);
        c.river_node_v1_destroy(state.windows.items[idx].node);
        c.river_window_v1_destroy(state.windows.items[idx].obj);
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

        if (state.outputs.items[idx].layer_output) |layer_output| {
            c.river_layer_shell_output_v1_destroy(layer_output);
        }
        c.river_output_v1_destroy(state.outputs.items[idx].obj);
        _ = state.outputs.swapRemove(idx);
        state.ensureWindowOutputAssignments();
        return true;
    }

    pub fn removeSeat(state: *State, seat_obj: *c.river_seat_v1) bool {
        const idx = state.findSeatIndex(seat_obj) orelse return false;

        if (state.seats.items[idx].xkb_seat) |xkb_seat| {
            c.river_xkb_bindings_seat_v1_destroy(xkb_seat);
        }
        if (state.seats.items[idx].layer_seat) |layer_seat| {
            c.river_layer_shell_seat_v1_destroy(layer_seat);
        }
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

    pub fn queueAction(state: *State, action: config_mod.Action, owned_cmd: bool) void {
        state.pending_actions.append(state.allocator, .{ .action = action, .owned_cmd = owned_cmd }) catch {
            if (owned_cmd and action.cmd != null) state.allocator.free(action.cmd.?);
        };
    }

    pub fn executePendingActions(state: *State) void {
        var i: usize = 0;
        while (i < state.pending_actions.items.len) : (i += 1) {
            const item = state.pending_actions.items[i];
            defer if (item.owned_cmd and item.action.cmd != null) state.allocator.free(item.action.cmd.?);

            switch (item.action.kind) {
                .none => {},
                .spawn => if (item.action.cmd) |cmd| spawnCommand(cmd) else {},
                .close => if (state.focused_window) |w| c.river_window_v1_close(w),
                .focus_next => state.focusShift(1),
                .focus_prev => state.focusShift(-1),
                .swap_next => state.swapFocused(1),
                .swap_prev => state.swapFocused(-1),
                .layout_next => state.cycleLayout(),
                .layout_set => {
                    if (item.action.layout) |mode| state.layout_mode = @enumFromInt(@intFromEnum(mode));
                },
            }
        }
        state.pending_actions.clearRetainingCapacity();
    }

    pub fn enablePendingBindings(state: *State) void {
        for (state.key_runtime.items) |binding| {
            if (binding.pending_enable) {
                c.river_xkb_binding_v1_enable(binding.obj);
                binding.pending_enable = false;
            }
        }
        for (state.pointer_runtime.items) |binding| {
            if (binding.pending_enable) {
                c.river_pointer_binding_v1_enable(binding.obj);
                binding.pending_enable = false;
            }
        }
    }

    pub fn applyRulesForWindow(state: *State, idx: usize) void {
        if (idx >= state.windows.items.len) return;
        var w = &state.windows.items[idx];

        for (state.config.rules.items) |rule| {
            if (!ruleMatches(w, rule)) continue;

            if (rule.floating) |v| w.floating = v;
            if (rule.fullscreen) |v| {
                w.fullscreen = v;
                if (v and w.fullscreen_output == null) w.fullscreen_output = w.assigned_output;
            }
            if (rule.output_index) |out_idx| {
                if (out_idx < state.outputs.items.len) {
                    w.assigned_output = state.outputs.items[out_idx].obj;
                }
            }
        }
    }

    pub fn updateWindowAppId(state: *State, window_obj: *c.river_window_v1, app_id: [*c]const u8) void {
        const idx = state.findWindowIndex(window_obj) orelse return;
        if (state.windows.items[idx].app_id) |s| state.allocator.free(s);
        state.windows.items[idx].app_id = null;

        if (app_id != null) {
            state.windows.items[idx].app_id = dup(state.allocator, std.mem.span(app_id)) catch null;
        }
        state.applyRulesForWindow(idx);
    }

    pub fn updateWindowTitle(state: *State, window_obj: *c.river_window_v1, title: [*c]const u8) void {
        const idx = state.findWindowIndex(window_obj) orelse return;
        if (state.windows.items[idx].title) |s| state.allocator.free(s);
        state.windows.items[idx].title = null;

        if (title != null) {
            state.windows.items[idx].title = dup(state.allocator, std.mem.span(title)) catch null;
        }
        state.applyRulesForWindow(idx);
    }

    pub fn setupControlPath(state: *State) void {
        const path = state.config.control_path orelse return;
        const dir = std.fs.path.dirname(path) orelse return;
        std.fs.cwd().makePath(dir) catch {};
        _ = std.fs.cwd().createFile(path, .{}) catch {};
    }

    pub fn pollControlCommands(state: *State) void {
        const path = state.config.control_path orelse return;

        var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch return;
        defer file.close();

        const data = file.readToEndAlloc(state.allocator, 64 * 1024) catch return;
        defer state.allocator.free(data);

        if (data.len == 0) return;

        file.seekTo(0) catch {};
        file.setEndPos(0) catch {};

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            state.parseAndQueueControl(line);
        }
    }

    fn parseAndQueueControl(state: *State, line: []const u8) void {
        if (std.mem.eql(u8, line, "focus next")) return state.queueAction(.{ .kind = .focus_next }, false);
        if (std.mem.eql(u8, line, "focus prev")) return state.queueAction(.{ .kind = .focus_prev }, false);
        if (std.mem.eql(u8, line, "swap next")) return state.queueAction(.{ .kind = .swap_next }, false);
        if (std.mem.eql(u8, line, "swap prev")) return state.queueAction(.{ .kind = .swap_prev }, false);
        if (std.mem.eql(u8, line, "layout next")) return state.queueAction(.{ .kind = .layout_next }, false);
        if (std.mem.eql(u8, line, "layout i3")) return state.queueAction(.{ .kind = .layout_set, .layout = .i3 }, false);
        if (std.mem.eql(u8, line, "layout monocle")) return state.queueAction(.{ .kind = .layout_set, .layout = .monocle }, false);
        if (std.mem.eql(u8, line, "layout master")) return state.queueAction(.{ .kind = .layout_set, .layout = .master_stack }, false);
        if (std.mem.eql(u8, line, "layout vertical")) return state.queueAction(.{ .kind = .layout_set, .layout = .vertical_stack }, false);
        if (std.mem.eql(u8, line, "close")) return state.queueAction(.{ .kind = .close }, false);

        if (std.mem.startsWith(u8, line, "spawn ")) {
            const cmd = std.mem.trim(u8, line[6..], " \t");
            if (cmd.len == 0) return;
            const owned = dup(state.allocator, cmd) catch return;
            state.queueAction(.{ .kind = .spawn, .cmd = owned }, true);
        }
    }

    pub fn focusShift(state: *State, dir: i32) void {
        if (state.windows.items.len == 0) return;

        const cur_idx = if (state.focused_window) |w| state.findWindowIndex(w) orelse 0 else 0;
        const count: i32 = @intCast(state.windows.items.len);
        const step: i32 = if (dir >= 0) 1 else -1;
        var idx: i32 = @intCast(cur_idx);
        idx = @mod(idx + step + count, count);
        state.focused_window = state.windows.items[@intCast(idx)].obj;
    }

    pub fn swapFocused(state: *State, dir: i32) void {
        if (state.windows.items.len < 2) return;
        const focused = state.focused_window orelse return;
        const cur = state.findWindowIndex(focused) orelse return;

        const count: i32 = @intCast(state.windows.items.len);
        const step: i32 = if (dir >= 0) 1 else -1;
        const other_i32 = @mod(@as(i32, @intCast(cur)) + step + count, count);
        const other: usize = @intCast(other_i32);

        const tmp = state.windows.items[cur];
        state.windows.items[cur] = state.windows.items[other];
        state.windows.items[other] = tmp;
    }

    pub fn cycleLayout(state: *State) void {
        state.layout_mode = switch (state.layout_mode) {
            .i3 => .master_stack,
            .master_stack => .vertical_stack,
            .vertical_stack => .monocle,
            .monocle => .i3,
        };
    }
};

fn spawnCommand(cmd: []const u8) void {
    var buf: [1024]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{s} >/dev/null 2>&1 &", .{cmd}) catch return;

    const args = [_][]const u8{ "sh", "-lc", rendered };
    _ = std.process.Child.run(.{ .allocator = std.heap.page_allocator, .argv = &args }) catch {};
}

fn ruleMatches(window: *const Window, rule: config_mod.Rule) bool {
    if (rule.app_id_contains) |needle| {
        const hay = window.app_id orelse return false;
        if (std.mem.indexOf(u8, hay, needle) == null) return false;
    }
    if (rule.title_contains) |needle| {
        const hay = window.title orelse return false;
        if (std.mem.indexOf(u8, hay, needle) == null) return false;
    }
    return true;
}

fn freeWindowStrings(allocator: std.mem.Allocator, window: *Window) void {
    if (window.app_id) |s| allocator.free(s);
    if (window.title) |s| allocator.free(s);
    window.app_id = null;
    window.title = null;
}

fn freePendingActions(state: *State) void {
    for (state.pending_actions.items) |item| {
        if (item.owned_cmd and item.action.cmd != null) state.allocator.free(item.action.cmd.?);
    }
}

fn dup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}
