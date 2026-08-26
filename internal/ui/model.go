// Package ui implements the Bubble Tea program: a single scrollable text
// area over the working-memory file, with explicit clipboard actions and
// debounced save/commit to the git-backed store.
package ui

import (
	"fmt"
	"time"

	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"omarchy-working-memory/internal/clip"
	"omarchy-working-memory/internal/store"
)

const (
	saveDebounce   = 1 * time.Second
	commitDebounce = 20 * time.Second
	statusDuration = 2 * time.Second
	tickInterval   = 500 * time.Millisecond
)

type tickMsg time.Time

// Model is the top-level Bubble Tea model for the app.
type Model struct {
	ta    textarea.Model
	store *store.Store

	width, height int

	lastEdit      time.Time
	unsaved       bool // in-memory changes not yet written to disk
	uncommitted   bool // written to disk but not yet committed to git
	status        string
	statusExpires time.Time
	err           error
}

// New builds the initial model, loading existing content from s.
func New(s *store.Store) Model {
	ta := textarea.New()
	ta.Placeholder = "Start typing. This is your working memory — jot it down, come back to it."
	ta.Prompt = ""
	ta.ShowLineNumbers = false
	ta.CharLimit = 0
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle()

	content, err := s.Load()
	if err == nil {
		ta.SetValue(content)
	}
	// Must happen here, not in Init(): Init has a value receiver, so any
	// mutation of m.ta made there (Focus() included) is applied to a local
	// copy and discarded — the model actually driven by the runtime would
	// stay unfocused, silently swallowing every typed character.
	ta.Focus()

	return Model{ta: ta, store: s, err: err}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(textarea.Blink, tick())
}

func tick() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.ta.SetWidth(msg.Width)
		m.ta.SetHeight(msg.Height - 2) // leave room for the footer
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "ctrl+q":
			m.flush()
			return m, tea.Quit

		case "ctrl+s":
			m.flush()
			m.setStatus("saved")
			return m, nil

		// "shift+insert"/"ctrl+insert" are what actually arrives here for
		// Omarchy's system-wide Super+V/Super+C: Hyprland's universal
		// clipboard shortcut synthesizes those specific combos for
		// terminal-tagged windows (see bindings/clipboard.lua) rather than
		// forwarding literal Ctrl+V/Ctrl+C. Ctrl+V/Ctrl+Y stay bound too, as
		// a plain-terminal fallback.
		case "ctrl+v", "shift+insert":
			text, err := clip.Paste()
			if err != nil {
				m.setStatus("paste failed: " + err.Error())
				return m, nil
			}
			m.ta.InsertString(text)
			m.markDirty()
			m.setStatus("pasted")
			return m, nil

		case "ctrl+y", "ctrl+insert":
			if err := clip.Copy(m.ta.Value()); err != nil {
				m.setStatus("copy failed: " + err.Error())
				return m, nil
			}
			m.setStatus("copied everything to clipboard")
			return m, nil

		// bubbles/textarea has no handling for Tab at all - it isn't in its
		// KeyMap and isn't a KeyRunes message, so it's silently dropped.
		// Insert a literal tab character ourselves.
		case "tab":
			m.ta.InsertRune('\t')
			m.markDirty()
			return m, nil
		}

		var cmd tea.Cmd
		m.ta, cmd = m.ta.Update(msg)
		m.markDirty()
		return m, cmd

	case tickMsg:
		m.onTick()
		return m, tick()
	}

	var cmd tea.Cmd
	m.ta, cmd = m.ta.Update(msg)
	return m, cmd
}

func (m *Model) markDirty() {
	m.unsaved = true
	m.lastEdit = time.Now()
}

func (m *Model) setStatus(s string) {
	m.status = s
	m.statusExpires = time.Now().Add(statusDuration)
}

func (m *Model) onTick() {
	now := time.Now()

	if m.unsaved && now.Sub(m.lastEdit) >= saveDebounce {
		if err := m.store.Save(m.ta.Value()); err != nil {
			m.err = err
		} else {
			m.unsaved = false
			m.uncommitted = true
			m.err = nil
		}
	}

	if m.uncommitted && !m.unsaved && now.Sub(m.lastEdit) >= commitDebounce {
		if committed, err := m.store.Commit(); err != nil {
			m.err = err
		} else if committed {
			m.uncommitted = false
		}
	}
}

// flush saves and commits immediately, bypassing the debounce — used on
// quit and on the explicit Ctrl+S save.
func (m *Model) flush() {
	if err := m.store.Save(m.ta.Value()); err != nil {
		m.err = err
		return
	}
	m.unsaved = false
	if _, err := m.store.Commit(); err != nil {
		m.err = err
		return
	}
	m.uncommitted = false
}

var (
	footerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	statusStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	errStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
)

func (m Model) View() string {
	hints := "super+v/ctrl+v paste · super+c/ctrl+y copy all · ctrl+s save · ctrl+q quit"

	var right string
	switch {
	case m.err != nil:
		right = errStyle.Render(m.err.Error())
	case m.status != "" && time.Now().Before(m.statusExpires):
		right = statusStyle.Render(m.status)
	case m.unsaved:
		right = footerStyle.Render("editing…")
	case m.uncommitted:
		right = footerStyle.Render("saved")
	default:
		right = footerStyle.Render("synced")
	}

	footer := footerStyle.Render(hints)
	pad := m.width - lipgloss.Width(footer) - lipgloss.Width(right)
	if pad < 1 {
		pad = 1
	}
	footerLine := footer + fmt.Sprintf("%*s", pad, "") + right

	return m.ta.View() + "\n" + footerLine
}
