const protocol = @import("protocol.zig");
const c = protocol.c;

pub const Phase = enum {
    idle,
    manage,
    render,
};

pub const LayoutMode = enum {
    // i3-like default: split output into equal columns.
    i3,
    monocle,
    master_stack,
    vertical_stack,
};

pub const OpKind = enum {
    none,
    move,
    resize,
};

pub const LayoutRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const SeatOp = struct {
    kind: OpKind = .none,
    target: ?*c.river_window_v1 = null,
    edges: u32 = c.RIVER_WINDOW_V1_EDGES_NONE,
    pending_start: bool = false,
    pending_end: bool = false,
    released: bool = false,
    delta_x: i32 = 0,
    delta_y: i32 = 0,
    base_x: i32 = 0,
    base_y: i32 = 0,
    base_w: i32 = 0,
    base_h: i32 = 0,
};

pub const Window = struct {
    obj: *c.river_window_v1,
    node: *c.river_node_v1,

    width: i32 = 0,
    height: i32 = 0,

    assigned_output: ?*c.river_output_v1 = null,
    parent: ?*c.river_window_v1 = null,
    app_id: ?[]u8 = null,
    title: ?[]u8 = null,

    floating: bool = false,
    floating_initialized: bool = false,

    fullscreen: bool = false,
    fullscreen_applied: bool = false,
    fullscreen_output: ?*c.river_output_v1 = null,

    render_x: i32 = 0,
    render_y: i32 = 0,
    render_w: i32 = 0,
    render_h: i32 = 0,
};

pub const Output = struct {
    obj: *c.river_output_v1,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = protocol.fallback_width,
    height: i32 = protocol.fallback_height,

    pub fn rect(output: *const Output) LayoutRect {
        if (output.width > 0 and output.height > 0) {
            return .{ .x = output.x, .y = output.y, .width = output.width, .height = output.height };
        }
        return .{ .x = output.x, .y = output.y, .width = protocol.fallback_width, .height = protocol.fallback_height };
    }
};

pub const Seat = struct {
    obj: *c.river_seat_v1,
    xkb_seat: ?*c.river_xkb_bindings_seat_v1 = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    has_pointer_position: bool = false,
    op: SeatOp = .{},
};
