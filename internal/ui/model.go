// Package ui implements the Bubble Tea program: a single scrollable text
// area over the working-memory file, with explicit clipboard actions and
// debounced save/commit to the git-backed store.
package ui

import (
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
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

// editorFinishedMsg reports the result of a Ctrl+E trip out to $EDITOR.
type editorFinishedMsg struct{ err error }

// mode selects which of the app's three screens Update/View dispatch to.
type mode int

const (
	modeEdit        mode = iota
	modeHistoryList      // browsing the commit log
	modeHistoryView      // read-only look at one past version
)

// Model is the top-level Bubble Tea model for the app.
type Model struct {
	ta    textarea.Model
	store *store.Store
	mode  mode

	width, height int

	lastEdit      time.Time
	unsaved       bool // in-memory changes not yet written to disk
	uncommitted   bool // written to disk but not yet committed to git
	status        string
	statusExpires time.Time
	err           error

	// History browsing (Ctrl+R). historyList is the commit picker;
	// historyView is a read-only look at the selected commit's content.
	// historySelected is what historyView is currently showing, kept
	// around so "restore" (in history.go) knows what to restore.
	historyList     list.Model
	historyView     viewport.Model
	historyContent  string // full text at historySelected — viewport.View() only has the visible slice
	historySelected store.Commit
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
		// SetValue leaves the cursor at (0,0); land where you left off
		// instead of at the top of yesterday's notes.
		ta.CursorEnd()
	}
	// Must happen here, not in Init(): Init has a value receiver, so any
	// mutation of m.ta made there (Focus() included) is applied to a local
	// copy and discarded — the model actually driven by the runtime would
	// stay unfocused, silently swallowing every typed character.
	ta.Focus()

	// Never left as the zero value: list.Model.SetSize (called on every
	// WindowSizeMsg, since history can be opened at any time) panics inside
	// bubbles/list's pagination code when called on an uninitialized list.
	historyList := list.New(nil, list.NewDefaultDelegate(), 0, 0)

	return Model{ta: ta, store: s, err: err, historyList: historyList}
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
		m.historyList.SetSize(msg.Width, msg.Height-2)
		m.historyView.Width, m.historyView.Height = msg.Width, msg.Height-2
		return m, nil

	case tickMsg:
		if m.mode == modeEdit {
			m.onTick()
		}
		return m, tick()

	case editorFinishedMsg:
		return m.editorFinished(msg.err)
	}

	switch m.mode {
	case modeHistoryList:
		return m.updateHistoryList(msg)
	case modeHistoryView:
		return m.updateHistoryView(msg)
	}

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "ctrl+q":
			m.flush()
			return m, tea.Quit

		case "ctrl+r":
			return m.openHistory()

		// Bubbles/textarea has no concept of a text selection at all — no
		// shift-arrow, no visual mode — so there's nothing in-app to hook
		// keyboard-driven selection onto. Rather than reimplement a worse
		// version of what's already sitting on this machine, hand the real
		// file to a real editor: flush first so it's current on disk, then
		// pause the TUI and give the terminal to $EDITOR (nvim by default,
		// LazyVim config and all) via tea.ExecProcess — the same mechanism
		// git/ranger/lf use. Resumes and reloads once it exits.
		case "ctrl+e":
			m.flush()
			return m, m.openEditor()

		case "ctrl+s":
			m.flush()
			m.setStatus("saved")
			return m, nil

		// Omarchy's Super+V/Super+C send Shift+Insert/Ctrl+Insert to
		// focused terminal windows, not literal Ctrl+V/Ctrl+C (see
		// bindings/clipboard.lua in the omarchy package) — but Bubble
		// Tea's key decoder has no table entry for either combo, so an
		// app-level bind here could never fire no matter how it's
		// written. foot itself handles both instead (see
		// foot-scratchpad.ini): clipboard-copy/clipboard-paste, rebound
		// to include Ctrl+Insert/Shift+Insert, talk to the real
		// clipboard directly and land here as ordinary typed input.
		// Ctrl+V/Ctrl+Y remain as an explicit, selection-independent
		// fallback: paste at cursor / copy the whole buffer.
		case "ctrl+v":
			text, err := clip.Paste()
			if err != nil {
				m.setStatus("paste failed: " + err.Error())
				return m, nil
			}
			m.ta.InsertString(text)
			m.markDirty()
			m.setStatus("pasted")
			return m, nil

		case "ctrl+y":
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
	}

	// Non-key messages (cursor blink, etc.) still need to reach the
	// textarea in edit mode.
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

// openEditor suspends the program and hands the terminal to $EDITOR (nvim
// if unset) on the store's actual file, so selection, visual mode, yank,
// registers, macros — all of it — are genuinely nvim's, not a reimplementation.
func (m Model) openEditor() tea.Cmd {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "nvim"
	}
	cmd := exec.Command(editor, m.store.Path())
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return editorFinishedMsg{err: err}
	})
}

// editorFinished reloads whatever $EDITOR left on disk and commits it, so a
// Ctrl+E trip shows up in history (Ctrl+R) same as any other edit.
func (m Model) editorFinished(err error) (tea.Model, tea.Cmd) {
	if err != nil {
		m.err = err
		return m, nil
	}
	content, loadErr := m.store.Load()
	if loadErr != nil {
		m.err = loadErr
		return m, nil
	}
	m.ta.SetValue(content)
	m.ta.CursorEnd()
	m.unsaved, m.err = false, nil
	if _, commitErr := m.store.Commit(); commitErr != nil {
		m.err = commitErr
	} else {
		m.uncommitted = false
	}
	m.setStatus("back from editor")
	return m, nil
}

var (
	footerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	statusStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	errStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
)

func (m Model) View() string {
	switch m.mode {
	case modeHistoryList:
		return m.viewHistoryList()
	case modeHistoryView:
		return m.viewHistoryView()
	default:
		return m.viewEdit()
	}
}

// renderFooter lays out the one-line hint bar shared by every screen: left
// side static key hints, right side a short status word, padded to fill
// the width in between.
func (m Model) renderFooter(hints, right string) string {
	footer := footerStyle.Render(hints)
	pad := m.width - lipgloss.Width(footer) - lipgloss.Width(right)
	if pad < 1 {
		pad = 1
	}
	return footer + fmt.Sprintf("%*s", pad, "") + right
}

func (m Model) viewEdit() string {
	hints := "super+v/ctrl+v paste · super+c/ctrl+y copy all · ctrl+e edit in $EDITOR · ctrl+r history · ctrl+s save · ctrl+q quit"

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

	return m.ta.View() + "\n" + m.renderFooter(hints, right)
}
