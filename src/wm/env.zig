const std = @import("std");
const types = @import("types.zig");

pub fn parseLayoutModeEnv() types.LayoutMode {
    const raw = std.posix.getenv("DEVILWM_LAYOUT") orelse return .i3;
    const value: []const u8 = raw;

    if (std.ascii.eqlIgnoreCase(value, "i3") or std.ascii.eqlIgnoreCase(value, "i3-like") or std.ascii.eqlIgnoreCase(value, "split")) {
        return .i3;
    }
    if (std.ascii.eqlIgnoreCase(value, "monocle")) return .monocle;
    if (std.ascii.eqlIgnoreCase(value, "master") or std.ascii.eqlIgnoreCase(value, "master-stack") or std.ascii.eqlIgnoreCase(value, "master_stack")) {
        return .master_stack;
    }
    if (std.ascii.eqlIgnoreCase(value, "vertical") or std.ascii.eqlIgnoreCase(value, "vstack") or std.ascii.eqlIgnoreCase(value, "vertical-stack")) {
        return .vertical_stack;
    }
    return .i3;
}

pub fn parseFocusOnInteractionEnv() bool {
    const raw = std.posix.getenv("DEVILWM_FOCUS_ON_INTERACTION") orelse return true;
    const value: []const u8 = raw;

    if (std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off")) {
        return false;
    }
    return true;
}
