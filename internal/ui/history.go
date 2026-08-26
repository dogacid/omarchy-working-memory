package ui

import (
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"omarchy-working-memory/internal/clip"
	"omarchy-working-memory/internal/store"
)

// historyItem adapts a store.Commit to bubbles/list's DefaultItem, so the
// list gets fuzzy filtering (press "/") for free — the point of "quickly
// find the note I dropped" is not having to scroll past everything else to
// get there.
type historyItem store.Commit

func (h historyItem) Title() string       { return h.Time.Format("Mon Jan 2  15:04") }
func (h historyItem) Description() string { return h.Message }
func (h historyItem) FilterValue() string { return h.Message }

// openHistory loads the commit log and switches into the picker. Called
// from edit mode via Ctrl+R.
func (m Model) openHistory() (tea.Model, tea.Cmd) {
	commits, err := m.store.Log()
	if err != nil {
		m.err = err
		return m, nil
	}
	if len(commits) == 0 {
		m.setStatus("no history yet")
		return m, nil
	}

	items := make([]list.Item, len(commits))
	for i, c := range commits {
		items[i] = historyItem(c)
	}

	l := list.New(items, list.NewDefaultDelegate(), m.width, m.height-2)
	l.Title = "History — enter to view, / to search, esc to go back"
	l.SetShowStatusBar(false)
	l.SetShowHelp(false)
	l.Styles.Title = l.Styles.Title.Background(lipgloss.Color("8"))

	m.historyList = l
	m.mode = modeHistoryList
	return m, nil
}

func (m Model) updateHistoryList(msg tea.Msg) (tea.Model, tea.Cmd) {
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "esc", "ctrl+r":
			// Filtering (bubbles/list) also uses Esc to clear the filter;
			// only treat it as "leave history" when we're not filtering.
			if m.historyList.FilterState() == list.Filtering {
				break
			}
			m.mode = modeEdit
			return m, nil

		case "enter":
			if item, ok := m.historyList.SelectedItem().(historyItem); ok {
				return m.openHistoryView(store.Commit(item))
			}
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.historyList, cmd = m.historyList.Update(msg)
	return m, cmd
}

func (m Model) viewHistoryList() string {
	return m.historyList.View()
}

func (m Model) openHistoryView(c store.Commit) (tea.Model, tea.Cmd) {
	content, err := m.store.ShowAt(c.Hash)
	if err != nil {
		m.err = err
		return m, nil
	}
	vp := viewport.Model{Width: m.width, Height: m.height - 2}
	vp.SetContent(content)
	m.historyView = vp
	m.historyContent = content
	m.historySelected = c
	m.mode = modeHistoryView
	return m, nil
}

func (m Model) updateHistoryView(msg tea.Msg) (tea.Model, tea.Cmd) {
	if key, ok := msg.(tea.KeyMsg); ok {
		switch key.String() {
		case "esc":
			m.mode = modeHistoryList
			return m, nil

		case "ctrl+r":
			m.mode = modeEdit
			return m, nil

		case "r":
			if err := m.store.RestoreAt(m.historySelected.Hash, m.historySelected.Time); err != nil {
				m.err = err
				return m, nil
			}
			content, err := m.store.Load()
			if err != nil {
				m.err = err
				return m, nil
			}
			m.ta.SetValue(content)
			m.ta.CursorEnd()
			m.unsaved, m.uncommitted, m.err = false, false, nil
			m.mode = modeEdit
			m.setStatus("restored " + m.historySelected.Time.Format("Jan 2 15:04"))
			return m, nil

		case "ctrl+y":
			if err := clip.Copy(m.historyContent); err != nil {
				m.setStatus("copy failed: " + err.Error())
				return m, nil
			}
			m.setStatus("copied this version to clipboard")
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.historyView, cmd = m.historyView.Update(msg)
	return m, cmd
}

func (m Model) viewHistoryView() string {
	hints := "select+super+c/ctrl+y copy · r restore to present · esc back · ctrl+r editing"
	right := footerStyle.Render(m.historySelected.Time.Format("Mon Jan 2 15:04"))
	return m.historyView.View() + "\n" + m.renderFooter(hints, right)
}
