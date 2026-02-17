const std = @import("std");
const config = @import("config.zig");
const state = @import("state.zig");

pub fn parseLayoutModeEnv() ?state.LayoutMode {
    const raw = std.posix.getenv("DEVILWM_LAYOUT") orelse return null;
    const value: []const u8 = raw;
    return @enumFromInt(@intFromEnum(config.parseLayoutMode(value)));
}

pub fn parseFocusOnInteractionEnv() ?bool {
    const raw = std.posix.getenv("DEVILWM_FOCUS_ON_INTERACTION") orelse return null;
    const value: []const u8 = raw;

    if (std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off")) {
        return false;
    }
    return true;
}
