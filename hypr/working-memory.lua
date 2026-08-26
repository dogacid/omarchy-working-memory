-- Working-memory scratchpad: window rules + keybinding.
-- Installed by symlinking this file to ~/.config/hypr/working-memory.lua
-- and adding `require("hypr.working-memory")` to ~/.config/hypr/hyprland.lua.

-- Float, center, and size the scratchpad terminal, and park it on its own
-- special workspace so toggling hides/shows it instead of closing it.
--
-- The toggle script launches this via `foot --app-id=org.omarchy.working-memory`
-- explicitly (not the default terminal) specifically so this class match is
-- reliable — Ghostty, this system's default, ignores --app-id. The
-- org.omarchy.* class also matches Omarchy's own terminal-tag rule
-- (default/hypr/apps/terminals.lua), which the Super+V/Super+C universal
-- clipboard shortcuts key off to send Shift+Insert/Ctrl+Insert instead of
-- literal Ctrl+V/Ctrl+C to this window.
o.window("org.omarchy.working-memory", { float = true, center = true, size = { 900, 640 } })
o.window("org.omarchy.working-memory", { workspace = "special:working-memory silent" })

o.bind("SUPER + N", "Toggle working memory", "omarchy-working-memory-toggle")
