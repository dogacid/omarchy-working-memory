import QtQuick
import qs.Commons
import qs.Ui

// Pure action button: no in-bar panel. Clicking it (or hitting Super+N,
// bound the same way in Hyprland) just runs the toggle script, which shows
// or hides the working-memory scratchpad terminal via a Hyprland special
// workspace. The actual editing happens in that terminal, not in the bar.
BarWidget {
  id: root
  moduleName: "omarchy-working-memory"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "" // Nerd Font sticky-note glyph
    tooltipText: "Working memory (Super+N)"

    onPressed: function(button_) {
      if (root.bar) root.bar.run("omarchy-working-memory-toggle")
    }
  }
}
