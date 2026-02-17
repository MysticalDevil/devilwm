# devilwm（简体中文）

英文主文档：`README.md`

## 快速开始

```bash
cd devilwm
zig build
./scripts/test-in-hyprland.sh
```

## 配置文件

按以下顺序查找 Lua 配置：
1. `$DEVILWM_CONFIG`
2. `$XDG_CONFIG_HOME/devilwm/config.lua`
3. `$HOME/.config/devilwm/config.lua`
4. `./devilwm.lua`

可从 `config/default.lua` 复制一份作为起点。

## 运行时命令

```bash
./zig-out/bin/devilctl focus next
./zig-out/bin/devilctl layout master
./zig-out/bin/devilctl spawn foot
```

支持：
- `focus next|prev`
- `swap next|prev`
- `layout next|i3|monocle|master|vertical`
- `close`
- `spawn <命令>`
