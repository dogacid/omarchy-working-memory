-- Working-memory scratchpad: window rules + keybinding.
-- Installed by symlinking this file to ~/.config/hypr/working-memory.lua
-- and adding `require("hypr.working-memory")` to ~/.config/hypr/hyprland.lua.

-- Float, center, and size the window on first appearance — nothing more.
-- This deliberately does NOT park it on a Hyprland special workspace: a
-- special workspace is an overlay that sits on top of and blocks
-- interaction with whatever's underneath until it's explicitly dismissed,
-- which is wrong for a window meant to sit alongside other windows as a
-- reference/paste area for anywhere from a few seconds to several minutes
-- (confirmed: with the special-workspace version, moving the mouse over
-- another window after Super+C couldn't refocus it at all — the overlay
-- was still covering it — forcing a Super+W close, which then broke the
-- Wayland clipboard too, since the app holding the copied text has to
-- stay alive for paste to work). A plain floating window has none of
-- that: click whatever you want, whenever, and close it normally when
-- you're done with it.
--
-- Deliberately not "org.omarchy.*": that prefix matches Omarchy's own
-- terminal-tag rule (default/hypr/apps/terminals.lua) unconditionally,
-- which made Super+C/Super+V send the terminal-style Ctrl+Insert/
-- Shift+Insert instead of literal Ctrl+C/Ctrl+V — a real Qt widget only
-- binds the literal form (confirmed: Super+C left the clipboard untouched
-- while tagged "terminal*"; the app.setDesktopFileName() call in
-- src/main.cpp sets this same class).
o.window("omarchy-working-memory", { float = true, center = true, size = { 900, 640 } })

o.bind("SUPER + N", "Open/focus working memory", "omarchy-working-memory-toggle")
