-- Working-memory scratchpad: window rules + keybinding.
-- Installed by symlinking this file to ~/.config/hypr/working-memory.lua
-- and adding `require("hypr.working-memory")` to ~/.config/hypr/hyprland.lua.

-- Float, center, and size the scratchpad terminal, and park it on its own
-- special workspace so toggling hides/shows it instead of closing it.
o.window("omarchy-working-memory", { float = true, center = true, size = { 900, 640 } })
o.window("omarchy-working-memory", { workspace = "special:working-memory silent" })

o.bind("SUPER + N", "Toggle working memory", "omarchy-working-memory-toggle")
