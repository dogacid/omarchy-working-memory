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
- **Clipboard-first**: `Super+V`/`Ctrl+V` paste straight from the system
  clipboard via `wl-paste`; `Super+C`/`Ctrl+Y` copy the whole buffer out via
  `wl-copy`. `Super+V`/`Super+C` are Omarchy's own universal clipboard
  shortcuts (see "Gotchas" below for why that needs a dedicated foot config).
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

| Key                  | Action                            |
|----------------------|------------------------------------|
| `Super+V` / `Ctrl+V` | Paste system clipboard at cursor  |
| `Super+C` / `Ctrl+Y` | Copy the whole buffer to clipboard |
| `Ctrl+S`             | Save + commit immediately         |
| `Ctrl+Q`             | Save + commit, then quit          |

Otherwise it's a normal text area (arrows, backspace, word-jump with
`Alt+Left/Right`, etc. — see `github.com/charmbracelet/bubbles/textarea`).

## Data

The note lives at `~/.local/share/omarchy-working-memory/working-memory.txt`
(override with `OMARCHY_WORKING_MEMORY_DIR`), inside a git repo that's
created on first run. Edits autosave ~1s after you stop typing, and
auto-commit ~20s after that (or immediately on `Ctrl+S` / quit).

## Gotchas this repo already works around

- **Ghostty ignores `--app-id`/`--class`** when launched via `xdg-terminal-exec`
  or directly. Since Hyprland window rules need a stable identifier at the
  moment the window maps, the toggle script launches the scratchpad via
  `foot` explicitly (which does honor `--app-id`) rather than through the
  system's default terminal.
- **`hyprctl dispatch <name> <args>`** (the classic two-token CLI form) is
  silently rejected on this Omarchy/Hyprland build — it prints a Lua parse
  error to stderr but still exits non-zero without acting. The working form
  is `hyprctl eval 'hl.dispatch(hl.dsp.<category>.<action>(...))'` (see
  `bin/omarchy-working-memory-toggle`'s `reveal()`). Bindings written inside
  `.lua` config files (e.g. `o.bind(...)`) are unaffected — this only bites
  ad hoc CLI dispatches.
- **Window rules apply once, at map time.** A rule matched on `title` won't
  retroactively apply once a late title update arrives (which is how Ghostty
  behaves) — hence matching on `class` via `foot` instead.
- **Omarchy's `Super+V`/`Super+C` aren't literally Ctrl+V/Ctrl+C for terminal
  windows.** `bindings/clipboard.lua` in the omarchy package detects the
  focused window is a terminal and synthesizes `Shift+Insert`/`Ctrl+Insert`
  instead, but only for windows whose class matches its own fixed
  terminal-tag list (`default/hypr/apps/terminals.lua`) — which is why the
  window class is `org.omarchy.working-memory` (matching that list's
  `org\.omarchy\..*` pattern) rather than something arbitrary; an
  unrecognized class falls back to literal `Ctrl+V`/`Ctrl+C`.
- **Bubble Tea cannot decode `Shift+Insert`/`Ctrl+Insert` at all**, so an
  app-level keybinding for either can never fire no matter how it's
  written — `charmbracelet/bubbletea@v1.3.10`'s key-sequence table
  (`key.go`) has no entry for the modified form of Insert, only the bare
  key. `foot-scratchpad.ini` handles both at the terminal level instead:
  `clipboard-copy`/`clipboard-paste` are rebound to also trigger on
  `Control+Insert`/`Shift+Insert` (on top of foot's own defaults), which
  talk to the real Wayland clipboard directly and land in the app as
  ordinary typed input — no app-side decoding needed. This also fixes a
  semantic mismatch an app-level bind would have had anyway: foot's
  clipboard-copy copies whatever is actually *selected*, not the whole
  buffer regardless of selection.
- **Bubble Tea's `Init()` has a value receiver.** Calling `ta.Focus()` there
  mutates a local copy that gets discarded — the model the runtime actually
  drives never becomes focused, so it silently accepts keypresses without
  ever inserting characters (an easy one to miss, since paste — which
  mutates the buffer directly via `InsertString`, bypassing focus entirely —
  still works fine). Focus in `New()` instead, before the model is built.

## Roadmap

- Daily rotation / "show me the last few days" browsing.
- An in-app history view (`git log` browsing without leaving the TUI).
- Branching off a note for a side train of thought.

The git-backed storage is deliberately already shaped for these — they're
just UI on top of `git log`, `git show`, and `git branch` against the same
repo.
