const std = @import("std");

fn controlPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("DEVILWM_CONTROL_PATH")) |p| return dup(allocator, p);

    const uid = std.posix.getuid();
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime| {
        return std.fmt.allocPrint(allocator, "{s}/devilwm-{d}.commands", .{ runtime, uid });
    }
    return std.fmt.allocPrint(allocator, "/tmp/devilwm-{d}.commands", .{uid});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const cmd = args.next() orelse {
        std.debug.print(
            "usage: devilctl <command> [args...]\n" ++
                "commands: focus next|prev, swap next|prev, layout next|i3|monocle|master|vertical, close, spawn <cmd>\n",
            .{},
        );
        return error.InvalidArguments;
    };

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, cmd);
    while (args.next()) |part| {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, part);
    }
    try buf.append(allocator, '\n');

    const path = try controlPath(allocator);
    defer allocator.free(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch {
        var created = try std.fs.cwd().createFile(path, .{});
        created.close();
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
        return;
    };
    defer file.close();

    try file.seekFromEnd(0);
    _ = try file.write(buf.items);
}

fn dup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}
