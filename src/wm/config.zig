const std = @import("std");

const c = @cImport({
    @cInclude("lua5.1/lua.h");
    @cInclude("lua5.1/lauxlib.h");
    @cInclude("lua5.1/lualib.h");
});

const bundled_default_config = @embedFile("default_config.lua");

pub const LayoutMode = enum {
    i3,
    monocle,
    master_stack,
    vertical_stack,
};

pub const BorderStyle = struct {
    width: i32 = 2,
    r: u32 = 0x2A2A2AFF,
    g: u32 = 0x6AA4FFFF,
    b: u32 = 0xEAF2FFFF,
    a: u32 = 0xFFFFFFFF,
};

pub const Rule = struct {
    app_id_contains: ?[]u8 = null,
    title_contains: ?[]u8 = null,
    floating: ?bool = null,
    fullscreen: ?bool = null,
    output_index: ?usize = null,
};

pub const ActionKind = enum {
    none,
    spawn,
    close,
    focus_next,
    focus_prev,
    swap_next,
    swap_prev,
    layout_next,
    layout_set,
};

pub const Action = struct {
    kind: ActionKind = .none,
    cmd: ?[]u8 = null,
    layout: ?LayoutMode = null,
};

pub const KeyBinding = struct {
    mods: u32,
    keysym: u32,
    action: Action,
};

pub const PointerBinding = struct {
    mods: u32,
    button: u32,
    action: Action,
};

pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,

    layout_mode: LayoutMode = .i3,
    focus_on_interaction: bool = true,

    default_app: []u8,
    control_path: ?[]u8 = null,

    focused_border: BorderStyle = .{},
    unfocused_border: BorderStyle = .{
        .width = 1,
        .r = 0x303030FF,
        .g = 0x505050FF,
        .b = 0x707070FF,
        .a = 0xFFFFFFFF,
    },

    rules: std.ArrayListUnmanaged(Rule) = .{},
    key_bindings: std.ArrayListUnmanaged(KeyBinding) = .{},
    pointer_bindings: std.ArrayListUnmanaged(PointerBinding) = .{},

    pub fn initDefault(allocator: std.mem.Allocator) !RuntimeConfig {
        var cfg = RuntimeConfig{
            .allocator = allocator,
            .default_app = try dup(allocator, "foot"),
            .control_path = try defaultControlPath(allocator),
        };

        try cfg.key_bindings.append(allocator, .{ .mods = 64, .keysym = 0xff0d, .action = .{ .kind = .spawn, .cmd = try dup(allocator, "foot") } });
        try cfg.key_bindings.append(allocator, .{ .mods = 64, .keysym = 'q', .action = .{ .kind = .close } });
        try cfg.key_bindings.append(allocator, .{ .mods = 64, .keysym = 'j', .action = .{ .kind = .focus_next } });
        try cfg.key_bindings.append(allocator, .{ .mods = 64, .keysym = 'k', .action = .{ .kind = .focus_prev } });
        try cfg.key_bindings.append(allocator, .{ .mods = 65, .keysym = 'j', .action = .{ .kind = .swap_next } });
        try cfg.key_bindings.append(allocator, .{ .mods = 65, .keysym = 'k', .action = .{ .kind = .swap_prev } });
        try cfg.key_bindings.append(allocator, .{ .mods = 64, .keysym = 0x20, .action = .{ .kind = .layout_next } });

        try cfg.pointer_bindings.append(allocator, .{ .mods = 64, .button = 272, .action = .{ .kind = .focus_next } });
        return cfg;
    }

    pub fn deinit(cfg: *RuntimeConfig) void {
        cfg.allocator.free(cfg.default_app);
        if (cfg.control_path) |p| cfg.allocator.free(p);

        for (cfg.rules.items) |rule| {
            if (rule.app_id_contains) |s| cfg.allocator.free(s);
            if (rule.title_contains) |s| cfg.allocator.free(s);
        }
        cfg.rules.deinit(cfg.allocator);

        freeActions(cfg.allocator, cfg.key_bindings.items);
        cfg.key_bindings.deinit(cfg.allocator);

        freeActions(cfg.allocator, cfg.pointer_bindings.items);
        cfg.pointer_bindings.deinit(cfg.allocator);
    }
};

pub fn load(allocator: std.mem.Allocator) !RuntimeConfig {
    var cfg = try RuntimeConfig.initDefault(allocator);
    errdefer cfg.deinit();

    const resolved = try resolveConfigPath(allocator);
    defer allocator.free(resolved.path);

    if (std.fs.cwd().access(resolved.path, .{})) |_| {} else |_| {
        if (resolved.should_seed_default) {
            ensureDefaultConfigFile(resolved.path);
        }
        if (std.fs.cwd().access(resolved.path, .{})) |_| {} else |_| {
            return cfg;
        }
    }

    const L = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    if (c.luaL_dofile(L, resolved.path.ptr)) {
        return error.ConfigLuaLoadFailed;
    }

    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
        return error.ConfigLuaMustReturnTable;
    }

    try parseRoot(L, allocator, &cfg);
    return cfg;
}

fn parseRoot(L: ?*c.lua_State, allocator: std.mem.Allocator, cfg: *RuntimeConfig) !void {
    try parseLayout(L, cfg);
    try parseFocus(L, cfg);
    try parseStringField(L, allocator, -1, "default_app", &cfg.default_app);
    try parseOptionalStringField(L, allocator, -1, "control_path", &cfg.control_path);

    try parseBorder(L, -1, "focused_border", &cfg.focused_border);
    try parseBorder(L, -1, "unfocused_border", &cfg.unfocused_border);

    try parseRules(L, allocator, cfg);
    try parseKeyBindings(L, allocator, cfg);
    try parsePointerBindings(L, allocator, cfg);
}

fn parseLayout(L: ?*c.lua_State, cfg: *RuntimeConfig) !void {
    c.lua_getfield(L, -1, "layout");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return;
    const value = luaString(L, -1) orelse return;
    cfg.layout_mode = parseLayoutMode(value);
}

fn parseFocus(L: ?*c.lua_State, cfg: *RuntimeConfig) !void {
    c.lua_getfield(L, -1, "focus_on_interaction");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) {
        cfg.focus_on_interaction = c.lua_toboolean(L, -1) != 0;
    }
}

fn parseBorder(L: ?*c.lua_State, idx: c_int, field: [*:0]const u8, out: *BorderStyle) !void {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return;

    out.width = @intCast(try intFieldOr(L, -1, "width", out.width));
    out.r = @intCast(try intFieldOr(L, -1, "r", out.r));
    out.g = @intCast(try intFieldOr(L, -1, "g", out.g));
    out.b = @intCast(try intFieldOr(L, -1, "b", out.b));
    out.a = @intCast(try intFieldOr(L, -1, "a", out.a));
}

fn parseRules(L: ?*c.lua_State, allocator: std.mem.Allocator, cfg: *RuntimeConfig) !void {
    c.lua_getfield(L, -1, "rules");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return;

    for (cfg.rules.items) |rule| {
        if (rule.app_id_contains) |s| allocator.free(s);
        if (rule.title_contains) |s| allocator.free(s);
    }
    cfg.rules.clearRetainingCapacity();

    const n = c.lua_objlen(L, -1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        c.lua_rawgeti(L, -1, @intCast(i));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;

        var rule = Rule{};
        rule.app_id_contains = try dupFieldOptional(L, allocator, -1, "app_id");
        rule.title_contains = try dupFieldOptional(L, allocator, -1, "title");
        rule.floating = boolFieldOptional(L, -1, "floating");
        rule.fullscreen = boolFieldOptional(L, -1, "fullscreen");

        c.lua_getfield(L, -1, "output");
        if (c.lua_type(L, -1) == c.LUA_TNUMBER) {
            const one_based = c.lua_tointeger(L, -1);
            if (one_based > 0) rule.output_index = @intCast(one_based - 1);
        }
        c.lua_pop(L, 1);

        try cfg.rules.append(allocator, rule);
    }
}

fn parseKeyBindings(L: ?*c.lua_State, allocator: std.mem.Allocator, cfg: *RuntimeConfig) !void {
    c.lua_getfield(L, -1, "bindings");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return;

    freeActions(allocator, cfg.key_bindings.items);
    cfg.key_bindings.clearRetainingCapacity();

    const n = c.lua_objlen(L, -1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        c.lua_rawgeti(L, -1, @intCast(i));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;

        const mods_s = try dupFieldOptional(L, allocator, -1, "mods") orelse continue;
        defer allocator.free(mods_s);
        const key_s = try dupFieldOptional(L, allocator, -1, "key") orelse continue;
        defer allocator.free(key_s);
        const action_s = try dupFieldOptional(L, allocator, -1, "action") orelse continue;
        defer allocator.free(action_s);

        const keysym = parseKeysym(key_s) orelse continue;

        var action = parseActionName(action_s);
        if (action.kind == .spawn) {
            if (try dupFieldOptional(L, allocator, -1, "cmd")) |cmd| {
                action.cmd = cmd;
            } else {
                action.cmd = try dup(allocator, cfg.default_app);
            }
        }
        if (action.kind == .layout_set) {
            if (try dupFieldOptional(L, allocator, -1, "layout")) |layout_s| {
                defer allocator.free(layout_s);
                action.layout = parseLayoutMode(layout_s);
            }
        }

        try cfg.key_bindings.append(allocator, .{
            .mods = parseModifiers(mods_s),
            .keysym = keysym,
            .action = action,
        });
    }
}

fn parsePointerBindings(L: ?*c.lua_State, allocator: std.mem.Allocator, cfg: *RuntimeConfig) !void {
    c.lua_getfield(L, -1, "pointer_bindings");
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return;

    freeActions(allocator, cfg.pointer_bindings.items);
    cfg.pointer_bindings.clearRetainingCapacity();

    const n = c.lua_objlen(L, -1);
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        c.lua_rawgeti(L, -1, @intCast(i));
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) continue;

        const mods_s = try dupFieldOptional(L, allocator, -1, "mods") orelse continue;
        defer allocator.free(mods_s);
        const action_s = try dupFieldOptional(L, allocator, -1, "action") orelse continue;
        defer allocator.free(action_s);

        c.lua_getfield(L, -1, "button");
        if (c.lua_type(L, -1) != c.LUA_TNUMBER) {
            c.lua_pop(L, 1);
            continue;
        }
        const button: u32 = @intCast(c.lua_tointeger(L, -1));
        c.lua_pop(L, 1);

        var action = parseActionName(action_s);
        if (action.kind == .spawn) {
            if (try dupFieldOptional(L, allocator, -1, "cmd")) |cmd| {
                action.cmd = cmd;
            } else {
                action.cmd = try dup(allocator, cfg.default_app);
            }
        }
        if (action.kind == .layout_set) {
            if (try dupFieldOptional(L, allocator, -1, "layout")) |layout_s| {
                defer allocator.free(layout_s);
                action.layout = parseLayoutMode(layout_s);
            }
        }

        try cfg.pointer_bindings.append(allocator, .{
            .mods = parseModifiers(mods_s),
            .button = button,
            .action = action,
        });
    }
}

fn parseActionName(name: []const u8) Action {
    if (std.mem.eql(u8, name, "spawn")) return .{ .kind = .spawn };
    if (std.mem.eql(u8, name, "close")) return .{ .kind = .close };
    if (std.mem.eql(u8, name, "focus_next")) return .{ .kind = .focus_next };
    if (std.mem.eql(u8, name, "focus_prev")) return .{ .kind = .focus_prev };
    if (std.mem.eql(u8, name, "swap_next")) return .{ .kind = .swap_next };
    if (std.mem.eql(u8, name, "swap_prev")) return .{ .kind = .swap_prev };
    if (std.mem.eql(u8, name, "layout_next")) return .{ .kind = .layout_next };
    if (std.mem.eql(u8, name, "layout_set")) return .{ .kind = .layout_set };
    return .{ .kind = .none };
}

pub fn parseLayoutMode(value: []const u8) LayoutMode {
    if (std.ascii.eqlIgnoreCase(value, "monocle")) return .monocle;
    if (std.ascii.eqlIgnoreCase(value, "master") or std.ascii.eqlIgnoreCase(value, "master-stack") or std.ascii.eqlIgnoreCase(value, "master_stack")) {
        return .master_stack;
    }
    if (std.ascii.eqlIgnoreCase(value, "vertical") or std.ascii.eqlIgnoreCase(value, "vstack") or std.ascii.eqlIgnoreCase(value, "vertical-stack")) {
        return .vertical_stack;
    }
    return .i3;
}

fn parseModifiers(mods: []const u8) u32 {
    var out: u32 = 0;
    var it = std.mem.tokenizeAny(u8, mods, "+| ,");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "shift")) out |= 1;
        if (std.ascii.eqlIgnoreCase(tok, "ctrl") or std.ascii.eqlIgnoreCase(tok, "control")) out |= 4;
        if (std.ascii.eqlIgnoreCase(tok, "mod1") or std.ascii.eqlIgnoreCase(tok, "alt")) out |= 8;
        if (std.ascii.eqlIgnoreCase(tok, "mod3")) out |= 32;
        if (std.ascii.eqlIgnoreCase(tok, "mod4") or std.ascii.eqlIgnoreCase(tok, "super") or std.ascii.eqlIgnoreCase(tok, "logo")) out |= 64;
        if (std.ascii.eqlIgnoreCase(tok, "mod5")) out |= 128;
    }
    return out;
}

fn parseKeysym(key: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, key, 0)) |v| return v else |_| {}

    if (key.len == 1) return key[0];

    if (std.ascii.eqlIgnoreCase(key, "return") or std.ascii.eqlIgnoreCase(key, "enter")) return 0xff0d;
    if (std.ascii.eqlIgnoreCase(key, "space")) return 0x20;
    if (std.ascii.eqlIgnoreCase(key, "tab")) return 0xff09;
    if (std.ascii.eqlIgnoreCase(key, "escape") or std.ascii.eqlIgnoreCase(key, "esc")) return 0xff1b;

    return null;
}

fn parseStringField(L: ?*c.lua_State, allocator: std.mem.Allocator, idx: c_int, field: [*:0]const u8, out: *[]u8) !void {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return;
    const s = luaString(L, -1) orelse return;
    allocator.free(out.*);
    out.* = try dup(allocator, s);
}

fn parseOptionalStringField(L: ?*c.lua_State, allocator: std.mem.Allocator, idx: c_int, field: [*:0]const u8, out: *?[]u8) !void {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return;
    const s = luaString(L, -1) orelse return;
    if (out.*) |old| allocator.free(old);
    out.* = try dup(allocator, s);
}

fn dupFieldOptional(L: ?*c.lua_State, allocator: std.mem.Allocator, idx: c_int, field: [*:0]const u8) !?[]u8 {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TSTRING) return null;
    const s = luaString(L, -1) orelse return null;
    return @as(?[]u8, try dup(allocator, s));
}

fn boolFieldOptional(L: ?*c.lua_State, idx: c_int, field: [*:0]const u8) ?bool {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return null;
    return c.lua_toboolean(L, -1) != 0;
}

fn intFieldOr(L: ?*c.lua_State, idx: c_int, field: [*:0]const u8, default_value: anytype) !@TypeOf(default_value) {
    c.lua_getfield(L, idx, field);
    defer c.lua_pop(L, 1);
    if (c.lua_type(L, -1) != c.LUA_TNUMBER) return default_value;
    return @intCast(c.lua_tointeger(L, -1));
}

const ResolvedConfigPath = struct {
    path: []u8,
    should_seed_default: bool,
};

fn resolveConfigPath(allocator: std.mem.Allocator) !ResolvedConfigPath {
    if (std.posix.getenv("DEVILWM_CONFIG")) |p| {
        return .{ .path = try dup(allocator, p), .should_seed_default = false };
    }
    if (std.posix.getenv("XDG_CONFIG_HOME")) |base| {
        return .{
            .path = try std.fmt.allocPrint(allocator, "{s}/devilwm/config.lua", .{base}),
            .should_seed_default = true,
        };
    }
    if (std.posix.getenv("HOME")) |home| {
        return .{
            .path = try std.fmt.allocPrint(allocator, "{s}/.config/devilwm/config.lua", .{home}),
            .should_seed_default = true,
        };
    }
    return .{ .path = try dup(allocator, "./devilwm.lua"), .should_seed_default = false };
}

fn defaultControlPath(allocator: std.mem.Allocator) ![]u8 {
    const uid = std.posix.getuid();
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime| {
        return std.fmt.allocPrint(allocator, "{s}/devilwm-{d}.commands", .{ runtime, uid });
    }
    return std.fmt.allocPrint(allocator, "/tmp/devilwm-{d}.commands", .{uid});
}

fn dup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out, s);
    return out;
}

fn ensureDefaultConfigFile(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.cwd().makePath(dir) catch return;
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = bundled_default_config }) catch return;
}

fn freeActions(allocator: std.mem.Allocator, items: anytype) void {
    for (items) |item| {
        if (item.action.cmd) |cmd| allocator.free(cmd);
    }
}

fn luaString(L: ?*c.lua_State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len);
    if (ptr == null) return null;
    return ptr[0..len];
}
