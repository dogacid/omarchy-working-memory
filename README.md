# omarchy-working-memory

A plain-text scratchpad for [Omarchy](https://omarchy.org/), built around Cal
Newport's [working-memory.txt](https://calnewport.com/deep-habits-workingmemory-txt-the-most-important-productivity-tool-youve-never-heard-of/)
idea: one always-available text file to park notes, half-formed thoughts, and
things to paste back out later, without breaking your flow to open a full
editor.

- **Toggle from anywhere**: `Super+N` or click the bar icon. It shows/hides
  a floating terminal via a dedicated Hyprland special workspace — closing it
  just hides it, so whatever's unsaved stays put.
- **Plain text**, not markdown. No formatting to fight with.
- **Clipboard-first**: `Ctrl+V` pastes straight from the system clipboard via
  `wl-paste`; `Ctrl+Y` copies the whole buffer out via `wl-copy`.
- **Versioned like git, because it is git**: every save auto-commits to a
  local git repo, so the file's history is just `git log` /
  `git show <rev>:working-memory.txt` away. No custom diffing engine — real
  git, real commits.

## Install

```sh
cd ~/code/personal/omarchy-working-memory
./install.sh
```

This builds the binary onto `~/.local/bin`, symlinks the Quickshell
bar-widget plugin into `~/.config/omarchy/plugins/`, wires the Hyprland
window rule + `Super+N` binding into `~/.config/hypr/`, and adds the bar
icon via `omarchy bar put`.

## Keys (inside the scratchpad)

| Key      | Action                          |
|----------|----------------------------------|
| `Ctrl+V` | Paste system clipboard at cursor |
| `Ctrl+Y` | Copy the whole buffer to clipboard |
| `Ctrl+S` | Save + commit immediately        |
| `Ctrl+Q` | Save + commit, then quit          |

Otherwise it's a normal text area (arrows, backspace, word-jump with
`Alt+Left/Right`, etc. — see `github.com/charmbracelet/bubbles/textarea`).

## Data

The note lives at `~/.local/share/omarchy-working-memory/working-memory.txt`
(override with `OMARCHY_WORKING_MEMORY_DIR`), inside a git repo that's
created on first run. Edits autosave ~1s after you stop typing, and
auto-commit ~20s after that (or immediately on `Ctrl+S` / quit).

## Roadmap

- Daily rotation / "show me the last few days" browsing.
- An in-app history view (`git log` browsing without leaving the TUI).
- Branching off a note for a side train of thought.

The git-backed storage is deliberately already shaped for these — they're
just UI on top of `git log`, `git show`, and `git branch` against the same
repo.
