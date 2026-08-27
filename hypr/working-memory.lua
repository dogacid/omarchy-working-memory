-- Working-memory scratchpad: window rules + keybinding.
-- Installed by symlinking this file to ~/.config/hypr/working-memory.lua
-- and adding `require("hypr.working-memory")` to ~/.config/hypr/hyprland.lua.

-- Float, center, and size the scratchpad window, and park it on its own
-- special workspace so toggling hides/shows it instead of closing it.
--
-- Deliberately not "org.omarchy.*": that prefix matches Omarchy's own
-- terminal-tag rule (default/hypr/apps/terminals.lua) unconditionally,
-- which made Super+C/Super+V send the terminal-style Ctrl+Insert/
-- Shift+Insert instead of literal Ctrl+C/Ctrl+V — a real Qt widget only
-- binds the literal form (confirmed: Super+C left the clipboard untouched
-- while tagged "terminal*"; the app.setDesktopFileName() call in
-- src/main.cpp sets this same class).
o.window("omarchy-working-memory", { float = true, center = true, size = { 900, 640 } })
o.window("omarchy-working-memory", { workspace = "special:working-memory silent" })

o.bind("SUPER + N", "Toggle working memory", "omarchy-working-memory-toggle")
