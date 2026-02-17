# devilwm

A minimal Wayland window manager client for river's `river-window-management-v1` protocol.

Language:
- English (this document)
- Simplified Chinese: `README.zh-CN.md`

## Features

- i3-like default tiled layout (equal-width columns)
- Additional layouts: `master_stack`, `vertical_stack`, `monocle`
- Multi-output window assignment and layout
- Fullscreen workflow (`fullscreen_requested` / `exit_fullscreen_requested`)
- Floating dialogs/transient windows (`parent` hint)
- Interactive move/resize via seat operations
- Key bindings via `river_xkb_bindings_v1`
- Pointer bindings via `river_seat_v1.get_pointer_binding`
- Lua-based configuration (`lua5.1` by default)
- Runtime command interface with `devilctl`

## Build

```bash
cd devilwm
zig build
```

Optional build flags:
- `-Dverbose-logs=true`
- `-Dlua-lib=<name>` (default: `lua5.1`)

## Run Nested Test

```bash
cd devilwm
./scripts/test-in-hyprland.sh
```

Environment:
- `APP_COUNT` default `4`
- `APP_STAGGER_SEC` default `0.25`
- `SKIP_BUILD=1` to skip rebuilding

## Configuration (Lua)

Search order:
1. `$DEVILWM_CONFIG`
2. `$XDG_CONFIG_HOME/devilwm/config.lua`
3. `$HOME/.config/devilwm/config.lua`
4. `./devilwm.lua`

Use `config/default.lua` as a starting point.

Supported top-level fields:
- `layout = "i3" | "master_stack" | "vertical_stack" | "monocle"`
- `focus_on_interaction = true|false`
- `default_app = "foot"`
- `control_path = "/tmp/devilwm-1000.commands"`
- `focused_border = { width=2, r=0x..., g=0x..., b=0x..., a=0x... }`
- `unfocused_border = { ... }`
- `rules = { { app_id="foo", title="bar", floating=true, fullscreen=false, output=1 } }`
- `bindings = { ... }`
- `pointer_bindings = { ... }`

Binding action names:
- `spawn`, `close`
- `focus_next`, `focus_prev`
- `swap_next`, `swap_prev`
- `layout_next`, `layout_set`

## Runtime Commands (`devilctl`)

`devilctl` appends commands to the control file.

```bash
cd devilwm
./zig-out/bin/devilctl focus next
./zig-out/bin/devilctl layout monocle
./zig-out/bin/devilctl spawn foot
```

Supported commands:
- `focus next|prev`
- `swap next|prev`
- `layout next|i3|monocle|master|vertical`
- `close`
- `spawn <shell command>`

Note: commands are consumed during manage cycles.
