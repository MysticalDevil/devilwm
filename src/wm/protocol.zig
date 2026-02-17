pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("river-window-management-v1-client-protocol.h");
});

pub const max_proto_version: u32 = 3;
pub const fallback_width: i32 = 1280;
pub const fallback_height: i32 = 720;
pub const min_floating_width: i32 = 200;
pub const min_floating_height: i32 = 140;
