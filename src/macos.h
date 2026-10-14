#pragma once

#include <functional>

// The macOS stand-in for what the compositor does on Linux. There's no
// Hyprland/sway to bind Super+N or float the window, so the app stays
// running as a menu-bar app (LSUIElement: no Dock icon) and handles these
// itself:
//   - a system-wide hotkey, Ctrl+Option+N, that opens or focuses the window
//     (Carbon's RegisterEventHotKey: still the one global-hotkey API that
//     needs no Accessibility permission)
//   - a menu-bar item: open, "Open at Login" (SMAppService), quit
namespace MacOS {

// onOpen: show and focus the window. onQuit: quit the app.
void install(std::function<void()> onOpen, std::function<void()> onQuit);

// Brings this (accessory) app to the front, so the window it's about to
// show gets keyboard focus instead of opening behind the current app.
void activate();

} // namespace MacOS
