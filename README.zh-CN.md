# devilwm（简体中文）

英文主文档：`README.md`

## 警告

- 这份代码主要由 Codex 自动实现，不是人类开发者手工逐行编写。
- 项目定位为实验性原型。
- 不建议作为日常生产桌面环境使用。

## 功能概览

- 默认 i3 风格平铺（等宽列）
- 其他布局：`master_stack`、`vertical_stack`、`monocle`
- 多输出分配与布局
- 全屏与浮动/临时窗口支持
- seat 操作的交互式移动与缩放
- 键盘绑定（`river_xkb_bindings_v1`）与鼠标绑定
- Lua 配置（默认 `lua5.1`）
- 运行时控制工具：`devilctl`

## 依赖

请在你的机器上安装：
- `zig`（强制 0.15.x）
- `wayland-scanner`
- Wayland 客户端开发库（`libwayland-client`）
- Lua 5.1 开发库（`lua5.1`）
- `river`（用于嵌套测试脚本/目标协议环境）
- `swaybg`（用于嵌套测试脚本设置壁纸）
- 可提供 river 协议的会话环境（真实运行）或 `scripts/test-in-hyprland.sh` 所需的嵌套测试环境

### 常见发行版安装命令

不同发行版和版本的包名可能略有差异，下面给出常用基线依赖。

Debian（`apt`）：
```bash
sudo apt update
sudo apt install -y zig wayland-scanner libwayland-dev liblua5.1-0-dev pkg-config swaybg
```

Fedora（`dnf`）：
```bash
sudo dnf install -y zig wayland-devel lua-devel pkgconf-pkg-config wayland-protocols-devel swaybg river
```

Arch Linux（`pacman`）：
```bash
sudo pacman -S --needed zig wayland lua51 pkgconf wayland-protocols swaybg river
```

Gentoo（`emerge`）：
```bash
sudo emerge --ask dev-lang/zig dev-libs/wayland dev-lang/lua:5.1 dev-util/pkgconf gui-apps/swaybg
```

openSUSE（`zypper`）：
```bash
sudo zypper install -y zig wayland-devel lua51-devel pkgconf-pkg-config wayland-protocols-devel swaybg river
```

### River 版本策略（必须是 0.4.0）

本项目要求 river `0.4.0`。
截至 2026 年 2 月 17 日，各发行版仓库里的 river 通常不是 `0.4.0`（或官方仓库不提供），所以请先检查版本：

```bash
river --version
```

如果不是 `0.4.0`，请从源码编译 river `0.4.0`：
```bash
mkdir -p ~/src
cd ~/src
git clone https://codeberg.org/river/river.git river-0.4.0
cd river-0.4.0
git fetch --tags
git checkout v0.4.0
zig build -Dman-pages=false
```

然后让测试脚本使用该目录：
```bash
cd /path/to/devilwm
RIVER_DIR=~/src/river-0.4.0 ./scripts/test-in-hyprland.sh
```

## 编译

```bash
cd devilwm
zig build
```

可选参数：
- `-Dverbose-logs=true`
- `-Dlua-lib=<name>`（默认 `lua5.1`）

产物路径：
- `zig-out/bin/devilwm`
- `zig-out/bin/devilctl`

安装后的默认配置模板：
- `zig-out/share/devilwm/default-config.lua`（或安装前缀下的 `<prefix>/share/devilwm/default-config.lua`）

## 快速测试（嵌套）

```bash
cd devilwm
./scripts/test-in-hyprland.sh
```

常用环境变量：
- `APP_COUNT`（默认 `4`）
- `APP_STAGGER_SEC`（默认 `0.25`）
- `SKIP_BUILD=1`（跳过重新编译）
- `WALLPAPER_FILE=/path/to/wallpaper`（默认 `assets/default-wallpaper.png`）
- `WALLPAPER_CMD='...'`（覆盖壁纸启动命令）
- `WALLPAPER_DELAY_SEC=0.5`（启动 swaybg 前延时，避免启动竞态）
- `SWAYBG_LOG=/tmp/swaybg.log`（记录 swaybg 输出，便于排查）
- `WALLPAPER_FALLBACK_COLOR=#9b111e`（图片壁纸加载失败时使用）

默认会使用内置恶魔 emoji 壁纸（`assets/default-wallpaper.png`）。
说明：很多发行版的 swaybg 若未启用 gdk-pixbuf，仅支持 PNG。
如果系统有 `swaybg`，脚本会自动启动它设置壁纸；没有则跳过壁纸设置。

## 在你的会话中运行

1. 先编译：`zig build`
2. 在可暴露 `river-window-management-v1` 的会话中启动 `devilwm`
3. 使用 `devilctl` 发送运行时命令

示例：
```bash
./zig-out/bin/devilctl focus next
./zig-out/bin/devilctl layout master
./zig-out/bin/devilctl spawn foot
```

支持命令：
- `focus next|prev`
- `swap next|prev`
- `layout next|i3|monocle|master|vertical`
- `close`
- `spawn <命令>`

说明：运行时命令会在 manage 周期中被消费。

## Lua 配置

按以下顺序查找配置：
1. `$DEVILWM_CONFIG`
2. `$XDG_CONFIG_HOME/devilwm/config.lua`
3. `$HOME/.config/devilwm/config.lua`
4. `./devilwm.lua`

可从 `config/default.lua` 复制作为起点。
首次运行时，如果未设置 `$DEVILWM_CONFIG` 且用户配置不存在，devilwm 会自动生成：
- `$XDG_CONFIG_HOME/devilwm/config.lua`（优先），或
- `$HOME/.config/devilwm/config.lua`

### 配置文件使用方式

1. 创建用户配置：
```bash
mkdir -p ~/.config/devilwm
cp config/default.lua ~/.config/devilwm/config.lua
```
2. 编辑 `~/.config/devilwm/config.lua`。
3. 重启 `devilwm` 使配置生效。

使用自定义配置路径：
```bash
DEVILWM_CONFIG=/path/to/config.lua ./zig-out/bin/devilwm
```

最小示例：
```lua
return {
  layout = "master_stack",
  focus_on_interaction = true,
  default_app = "foot",
  bindings = {
    { mods = "Mod4", key = "Return", action = "spawn", cmd = "foot" },
    { mods = "Mod4", key = "q", action = "close" },
    { mods = "Mod4", key = "space", action = "layout_next" },
  },
}
```

完整支持项说明：
- `layout`: `"i3" | "master_stack" | "vertical_stack" | "monocle"`
- `focus_on_interaction`: `true|false`
- `default_app`: 默认 `spawn` 命令
- `control_path`: 运行时控制文件路径
- `focused_border` / `unfocused_border`:
- `width`: 边框宽度（整数）
- `r/g/b/a`: 32 位颜色值（例如 `0x2A2A2AFF`）
- `rules[*]`:
- `app_id`: 子串匹配（可选）
- `title`: 子串匹配（可选）
- `floating`: 布尔（可选）
- `fullscreen`: 布尔（可选）
- `output`: 输出索引（从 1 开始，可选）
- `bindings[*]`:
- `mods`: 修饰键字符串，如 `Mod4`、`Mod4+Shift`、`Ctrl+Alt`
- `key`: 单字符、常见键名（`Return`/`space`/`tab`/`escape`）或 keysym 数字字符串
- `action`: `spawn|close|focus_next|focus_prev|swap_next|swap_prev|layout_next|layout_set`
- `cmd`: `spawn` 时使用（可选，不填则退回 `default_app`）
- `layout`: `layout_set` 时使用（`i3|master_stack|vertical_stack|monocle`）
- `pointer_bindings[*]`:
- `mods`: 与键盘绑定同格式
- `button`: Linux input 按钮码（左键通常为 `272`）
- `action`: 同上
- `cmd`: `spawn` 时可选
- `layout`: `layout_set` 时可选
