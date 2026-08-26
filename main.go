// Command omarchy-working-memory is a small full-screen text scratchpad:
// one plain-text file you keep open across a work session, auto-saved and
// auto-committed to a local git repo so its history is browsable later.
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"

	"omarchy-working-memory/internal/store"
	"omarchy-working-memory/internal/ui"
)

func main() {
	s, err := store.Open()
	if err != nil {
		fmt.Fprintln(os.Stderr, "omarchy-working-memory: "+err.Error())
		os.Exit(1)
	}

	p := tea.NewProgram(ui.New(s), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "omarchy-working-memory: "+err.Error())
		os.Exit(1)
	}
}
