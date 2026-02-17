# devilwm

Experimental Wayland WM client for river's `river-window-management-v1` protocol.

Language:
- English (this document)
- Simplified Chinese: `README.zh-CN.md`

## Warning

- This codebase is primarily implemented by Codex, not handwritten by a human developer.
- This project is an experiment/prototype.
- Not recommended for daily-use desktop environments.

## What It Provides

- i3-like default tiling (equal-width columns)
- Other layouts: `master_stack`, `vertical_stack`, `monocle`
- Multi-output assignment and layout
- Fullscreen and floating/transient support
- Interactive move/resize via seat operations
- Key bindings (`river_xkb_bindings_v1`) and pointer bindings
- Lua config (`lua5.1` by default)
- Runtime control tool: `devilctl`

## Requirements

Install these on your machine:
- `zig` (0.15.x recommended)
- `wayland-scanner`
- Wayland client development files (`libwayland-client`)
- Lua 5.1 development files (`lua5.1`)
- A compositor/session where river protocols are available (for real run), or nested test prerequisites for `scripts/test-in-hyprland.sh`

### Common Distro Packages

Package names can vary slightly by distro release. The following sets are the usual baseline.

Debian / Ubuntu (`apt`):
```bash
sudo apt update
sudo apt install -y zig wayland-scanner libwayland-dev liblua5.1-0-dev pkg-config
```

Fedora (`dnf`, RPM family):
```bash
sudo dnf install -y zig wayland-devel lua-devel pkgconf-pkg-config wayland-protocols-devel
```

RHEL / Rocky / AlmaLinux (`dnf`, RPM family):
```bash
sudo dnf install -y zig wayland-devel lua-devel pkgconf-pkg-config wayland-protocols-devel
```

Arch Linux (`pacman`):
```bash
sudo pacman -S --needed zig wayland lua51 pkgconf wayland-protocols
```

Gentoo (`emerge`):
```bash
sudo emerge --ask dev-lang/zig dev-libs/wayland dev-lang/lua:5.1 dev-util/pkgconf
```

## Build

```bash
cd devilwm
zig build
```

Optional flags:
- `-Dverbose-logs=true`
- `-Dlua-lib=<name>` (default: `lua5.1`)

Binaries are produced at:
- `zig-out/bin/devilwm`
- `zig-out/bin/devilctl`

## Quick Test (Nested)

```bash
cd devilwm
./scripts/test-in-hyprland.sh
```

Useful env vars:
- `APP_COUNT` (default `4`)
- `APP_STAGGER_SEC` (default `0.25`)
- `SKIP_BUILD=1` (skip rebuild)

## Run In Your Session

1. Build first: `zig build`
2. Start `devilwm` in a session where `river-window-management-v1` is exposed.
3. Use `devilctl` to send runtime commands.

Examples:
```bash
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

Note: runtime commands are consumed during manage cycles.

## Lua Configuration

Config search order:
1. `$DEVILWM_CONFIG`
2. `$XDG_CONFIG_HOME/devilwm/config.lua`
3. `$HOME/.config/devilwm/config.lua`
4. `./devilwm.lua`

Start from `config/default.lua`.

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
