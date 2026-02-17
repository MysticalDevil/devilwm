const std = @import("std");
const testing = std.testing;

const fallback_width: i32 = 1280;
const fallback_height: i32 = 720;

const Phase = enum {
    idle,
    manage,
    render,
};

const LayoutRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const Output = struct {
    id: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = fallback_width,
    height: i32 = fallback_height,
};

const Model = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .idle,
    windows: std.ArrayListUnmanaged(u32) = .{},
    outputs: std.ArrayListUnmanaged(Output) = .{},
    seats: std.ArrayListUnmanaged(u32) = .{},
    focused_window: ?u32 = null,

    fn deinit(model: *Model) void {
        model.windows.deinit(model.allocator);
        model.outputs.deinit(model.allocator);
        model.seats.deinit(model.allocator);
    }

    fn beginManage(model: *Model) !void {
        try model.begin(.manage);
    }

    fn endManage(model: *Model) !void {
        try model.end(.manage);
    }

    fn beginRender(model: *Model) !void {
        try model.begin(.render);
    }

    fn endRender(model: *Model) !void {
        try model.end(.render);
    }

    fn begin(model: *Model, next: Phase) !void {
        if (model.phase != .idle) return error.InvalidPhaseTransition;
        model.phase = next;
    }

    fn end(model: *Model, expected: Phase) !void {
        if (model.phase != expected) return error.InvalidPhaseTransition;
        model.phase = .idle;
    }

    fn addWindow(model: *Model, id: u32) !void {
        try model.windows.append(model.allocator, id);
        if (model.focused_window == null) model.focused_window = id;
    }

    fn removeWindow(model: *Model, id: u32) bool {
        const idx = model.findWindow(id) orelse return false;
        _ = model.windows.swapRemove(idx);
        if (model.focused_window == id) model.focused_window = null;
        if (model.focused_window == null and model.windows.items.len > 0) {
            model.focused_window = model.windows.items[0];
        }
        return true;
    }

    fn addOutput(model: *Model, id: u32) !void {
        try model.outputs.append(model.allocator, .{ .id = id });
    }

    fn updateOutput(model: *Model, id: u32, x: i32, y: i32, width: i32, height: i32) bool {
        const idx = model.findOutput(id) orelse return false;
        model.outputs.items[idx].x = x;
        model.outputs.items[idx].y = y;
        model.outputs.items[idx].width = width;
        model.outputs.items[idx].height = height;
        return true;
    }

    fn removeOutput(model: *Model, id: u32) bool {
        const idx = model.findOutput(id) orelse return false;
        _ = model.outputs.swapRemove(idx);
        return true;
    }

    fn addSeat(model: *Model, id: u32) !void {
        try model.seats.append(model.allocator, id);
    }

    fn removeSeat(model: *Model, id: u32) bool {
        const idx = model.findSeat(id) orelse return false;
        _ = model.seats.swapRemove(idx);
        return true;
    }

    fn layoutRect(model: *Model) LayoutRect {
        if (model.outputs.items.len > 0) {
            const first = model.outputs.items[0];
            if (first.width > 0 and first.height > 0) {
                return .{
                    .x = first.x,
                    .y = first.y,
                    .width = first.width,
                    .height = first.height,
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

    fn findWindow(model: *Model, id: u32) ?usize {
        for (model.windows.items, 0..) |window_id, idx| {
            if (window_id == id) return idx;
        }
        return null;
    }

    fn findOutput(model: *Model, id: u32) ?usize {
        for (model.outputs.items, 0..) |output, idx| {
            if (output.id == id) return idx;
        }
        return null;
    }

    fn findSeat(model: *Model, id: u32) ?usize {
        for (model.seats.items, 0..) |seat_id, idx| {
            if (seat_id == id) return idx;
        }
        return null;
    }
};

test "startup and first manage/render sequence" {
    var model = Model{ .allocator = testing.allocator };
    defer model.deinit();

    try testing.expectEqual(Phase.idle, model.phase);

    try model.beginManage();
    try testing.expectEqual(Phase.manage, model.phase);
    try model.endManage();

    try model.beginRender();
    try testing.expectEqual(Phase.render, model.phase);
    try model.endRender();
    try testing.expectEqual(Phase.idle, model.phase);
}

test "first window map and close updates focus" {
    var model = Model{ .allocator = testing.allocator };
    defer model.deinit();

    try model.addWindow(10);
    try model.addWindow(11);
    try testing.expectEqual(@as(?u32, 10), model.focused_window);

    try testing.expect(model.removeWindow(10));
    try testing.expectEqual(@as(?u32, 11), model.focused_window);
    try testing.expect(model.removeWindow(11));
    try testing.expectEqual(@as(?u32, null), model.focused_window);
}

test "output hotplug keeps geometry consistent" {
    var model = Model{ .allocator = testing.allocator };
    defer model.deinit();

    try testing.expectEqual(LayoutRect{ .x = 0, .y = 0, .width = fallback_width, .height = fallback_height }, model.layoutRect());

    try model.addOutput(1);
    try testing.expect(model.updateOutput(1, 100, 200, 1920, 1080));
    try testing.expectEqual(LayoutRect{ .x = 100, .y = 200, .width = 1920, .height = 1080 }, model.layoutRect());

    try testing.expect(model.removeOutput(1));
    try testing.expectEqual(LayoutRect{ .x = 0, .y = 0, .width = fallback_width, .height = fallback_height }, model.layoutRect());
}

test "seat remove keeps set clean" {
    var model = Model{ .allocator = testing.allocator };
    defer model.deinit();

    try model.addSeat(1);
    try model.addSeat(2);
    try testing.expectEqual(@as(usize, 2), model.seats.items.len);

    try testing.expect(model.removeSeat(1));
    try testing.expectEqual(@as(usize, 1), model.seats.items.len);
    try testing.expect(!model.removeSeat(1));
}

test "invalid protocol phase transitions are rejected" {
    var model = Model{ .allocator = testing.allocator };
    defer model.deinit();

    try model.beginManage();
    try testing.expectError(error.InvalidPhaseTransition, model.beginRender());
    try model.endManage();

    try testing.expectError(error.InvalidPhaseTransition, model.endRender());
    try testing.expectEqual(Phase.idle, model.phase);
}
