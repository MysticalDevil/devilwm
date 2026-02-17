const protocol = @import("protocol.zig");
const c = protocol.c;

pub fn windowDimensionsHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
pub fn windowString(_: ?*anyopaque, _: ?*c.river_window_v1, _: [*c]const u8) callconv(.c) void {}
pub fn windowDecorationHint(_: ?*anyopaque, _: ?*c.river_window_v1, _: u32) callconv(.c) void {}
pub fn windowMenuReq(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32, _: i32) callconv(.c) void {}
pub fn windowSimple(_: ?*anyopaque, _: ?*c.river_window_v1) callconv(.c) void {}
pub fn windowPid(_: ?*anyopaque, _: ?*c.river_window_v1, _: i32) callconv(.c) void {}
pub fn outputWlOutput(_: ?*anyopaque, _: ?*c.river_output_v1, _: u32) callconv(.c) void {}
pub fn seatWlSeat(_: ?*anyopaque, _: ?*c.river_seat_v1, _: u32) callconv(.c) void {}
pub fn seatPointerEnter(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_window_v1) callconv(.c) void {}
pub fn seatPointerLeave(_: ?*anyopaque, _: ?*c.river_seat_v1) callconv(.c) void {}
pub fn seatShellSurfaceInteraction(_: ?*anyopaque, _: ?*c.river_seat_v1, _: ?*c.river_shell_surface_v1) callconv(.c) void {}
