return {
  layout = "i3",
  focus_on_interaction = true,
  default_app = "foot",

  -- Change if you need a custom runtime command path.
  -- control_path = "/tmp/devilwm-1000.commands",

  focused_border = {
    width = 2,
    r = 0x2A2A2AFF,
    g = 0x6AA4FFFF,
    b = 0xEAF2FFFF,
    a = 0xFFFFFFFF,
  },

  unfocused_border = {
    width = 1,
    r = 0x303030FF,
    g = 0x505050FF,
    b = 0x707070FF,
    a = 0xFFFFFFFF,
  },

  rules = {
    -- Example: float all pavucontrol windows
    -- { app_id = "pavucontrol", floating = true },
  },

  bindings = {
    { mods = "Mod4", key = "Return", action = "spawn", cmd = "foot" },
    { mods = "Mod4", key = "q", action = "close" },
    { mods = "Mod4", key = "j", action = "focus_next" },
    { mods = "Mod4", key = "k", action = "focus_prev" },
    { mods = "Mod4+Shift", key = "j", action = "swap_next" },
    { mods = "Mod4+Shift", key = "k", action = "swap_prev" },
    { mods = "Mod4", key = "space", action = "layout_next" },
    -- { mods = "Mod4", key = "m", action = "layout_set", layout = "master_stack" },
  },

  pointer_bindings = {
    { mods = "Mod4", button = 272, action = "focus_next" },
  },
}
