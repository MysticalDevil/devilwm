const wm = @import("wm.zig");

pub const std_options = wm.std_options;

pub fn main() !void {
    return wm.run();
}
