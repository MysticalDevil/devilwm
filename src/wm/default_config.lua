return {
  -- Layout mode:
  -- "i3" | "master_stack" | "vertical_stack" | "monocle"
  layout = "i3",

  -- When true, pointer interactions can affect focus behavior.
  focus_on_interaction = true,

  -- Default command for spawn actions when binding has no explicit cmd.
  default_app = "foot",

  -- Optional runtime control file path used by devilctl.
  -- If omitted, devilwm uses:
  --   $XDG_RUNTIME_DIR/devilwm-<uid>.commands
  --   or /tmp/devilwm-<uid>.commands
  -- control_path = "/tmp/devilwm-1000.commands",

  -- Focused window border style.
  focused_border = {
    width = 2,
    r = 0x2A2A2AFF,
    g = 0x6AA4FFFF,
    b = 0xEAF2FFFF,
    a = 0xFFFFFFFF,
  },

  -- Unfocused window border style.
  unfocused_border = {
    width = 1,
    r = 0x303030FF,
    g = 0x505050FF,
    b = 0x707070FF,
    a = 0xFFFFFFFF,
  },

  -- Rules are matched by substring:
  -- app_id/title fields are "contains" matching, not exact matching.
  -- output is 1-based index (1 = first output).
  rules = {
    -- Example: float all pavucontrol windows.
    -- { app_id = "pavucontrol", floating = true },
    -- Example: force fullscreen by title keyword.
    -- { title = "Presentation", fullscreen = true },
    -- Example: route an app to second output.
    -- { app_id = "firefox", output = 2 },
  },

  -- Keyboard bindings:
  -- mods: "Shift", "Ctrl", "Alt", "Mod4", "Mod5", combinations with "+".
  -- key:
  --   - single character, e.g. "j"
  --   - common names: "Return", "space", "tab", "escape"
  --   - numeric keysym value, e.g. "0xff0d"
  -- action:
  --   "spawn" | "close" | "focus_next" | "focus_prev" |
  --   "swap_next" | "swap_prev" | "layout_next" | "layout_set"
  -- extra fields:
  --   cmd for spawn, layout for layout_set
  bindings = {
    { mods = "Mod4", key = "Return", action = "spawn", cmd = "foot" },
    { mods = "Mod4", key = "q", action = "close" },
    { mods = "Mod4", key = "j", action = "focus_next" },
    { mods = "Mod4", key = "k", action = "focus_prev" },
    { mods = "Mod4+Shift", key = "j", action = "swap_next" },
    { mods = "Mod4+Shift", key = "k", action = "swap_prev" },
    { mods = "Mod4", key = "space", action = "layout_next" },
    -- { mods = "Mod4", key = "m", action = "layout_set", layout = "master_stack" },
    -- { mods = "Mod4", key = "v", action = "layout_set", layout = "vertical_stack" },
    -- { mods = "Mod4", key = "f", action = "layout_set", layout = "monocle" },
  },

  -- Pointer bindings:
  -- button uses Linux input button code (left button is usually 272).
  -- Supports same actions as keyboard bindings.
  -- extra fields:
  --   cmd for spawn, layout for layout_set
  pointer_bindings = {
    { mods = "Mod4", button = 272, action = "focus_next" },
    -- { mods = "Mod4", button = 273, action = "layout_set", layout = "i3" },
  },
}
