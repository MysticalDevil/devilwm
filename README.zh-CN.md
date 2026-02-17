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
- `zig`（建议 0.15.x）
- `wayland-scanner`
- Wayland 客户端开发库（`libwayland-client`）
- Lua 5.1 开发库（`lua5.1`）
- 可提供 river 协议的会话环境（真实运行）或 `scripts/test-in-hyprland.sh` 所需的嵌套测试环境

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

## 快速测试（嵌套）

```bash
cd devilwm
./scripts/test-in-hyprland.sh
```

常用环境变量：
- `APP_COUNT`（默认 `4`）
- `APP_STAGGER_SEC`（默认 `0.25`）
- `SKIP_BUILD=1`（跳过重新编译）

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
