# omarchy-working-memory

A plain-text scratchpad for [Omarchy](https://omarchy.org/), built around Cal
Newport's [working-memory.txt](https://calnewport.com/deep-habits-workingmemory-txt-the-most-important-productivity-tool-youve-never-heard-of/)
idea: one always-available text file to park notes, half-formed thoughts, and
things to paste back out later, without breaking your flow to open a full
editor. Built with Qt Quick and C++, in the same stack as
[omawrite](https://github.com/omacom-io/omawrite) and Omarchy's own shell.

- **Open/focus from anywhere**: `Super+N` or click the bar icon. A plain
  floating window — drag it, resize it, put it beside whatever you're
  actually working on. It's meant to sit alongside other windows for
  anywhere from a few seconds to several minutes, not be hidden behind an
  overlay; close it normally (`Super+W`) when you're done with it.
- **Plain text**, not markdown. No formatting to fight with.
- **Real, native text selection**: it's a real `TextArea`, so `Shift`+arrows,
  double/triple-click, click-and-drag — all of it works exactly like every
  other text field on your desktop. No terminal to fight for this.
- **Clipboard just works**: `Ctrl+C`/`Ctrl+V` (and Omarchy's `Super+C`/
  `Super+V`) are native Qt clipboard handling — no `wl-copy`/`wl-paste`
  plumbing needed (see "Why C++/Qt" below for why that's not incidental).
- **Versioned like git, because it is git**: every save auto-commits to a
  local git repo, so the file's history is just `git log` /
  `git show <rev>:working-memory.txt` away. No custom diffing engine — real
  git, real commits.
- **Time machine (`Ctrl+R`)**: a searchable list of every past version on the
  left, its full text read-only on the right — the preview follows the list
  as you move through it, so skimming many versions to find one is one
  continuous motion, not select-view-back-select-view. Select text and
  `Ctrl+C`/`Super+C` copy it out same as ever; `Enter` restores that whole
  version to the present as a new commit — nothing is ever destructively
  lost, since the state right before a restore is itself still in the log,
  restorable the same way.
- **Follows Omarchy's live theme**: background/foreground/accent/selection
  colors and dark/light mode are read straight from
  `~/.local/state/omarchy/current/theme/colors.toml` and update immediately
  when you switch themes.
- **Errors get a real screen**, not a truncated status line: a save/commit
  failure switches to a full-screen, scrollable, selectable view of the
  whole error, and every error is also appended to
  `~/.local/share/omarchy-working-memory/error.log` with a timestamp.

## Why C++/Qt (not the terminal)

This was originally a Go + Bubble Tea TUI. It got the git-backed history and
auto-save/commit logic right, but kept needing hand-built workarounds for
things a GUI toolkit gives you for free:

- `bubbles/textarea` (the terminal text-editing library, in both its v1 and
  v2 releases) has **no text-selection concept at all** — no shift-arrow, no
  mouse selection, nothing to copy a specific chunk of text from. Getting
  keyboard selection working at all would have meant hand-rolling anchor
  tracking and wrap-aware highlight rendering against a library that assumes
  none of this exists.
- Terminal windows need Omarchy's `Super+C`/`Super+V` to be specially
  routed to `Ctrl+Insert`/`Shift+Insert` (see `apps/terminals.lua`'s
  terminal-tag rule) — which then needs the terminal itself (foot, in the
  old version) configured to convert those into real clipboard actions,
  since Bubble Tea's own key decoder can't even represent that combo.
- A one-line, right-aligned footer status is the wrong place for an error
  message: a long one silently overflowed the terminal width with no
  wrapping, corrupting the display into cut-off, unselectable red text.

A real `QQuickTextArea` gets shift-arrow/word/mouse selection, native OS
clipboard (`Ctrl+C`/`Ctrl+V`, and Omarchy's `Super+C`/`Super+V` route to
those directly once the window isn't tagged as a terminal — see below),
native window focus, and text wrapping/scrolling for free. The git-backed
store logic carried over almost unchanged — it was already just a thin
wrapper around shelling out to `git`.

## Install

Requires Qt 6 (`qt6-base`, `qt6-declarative`, `qt6-quickcontrols2` — the
latter may already be pulled in by `qt6-declarative` on Arch/Omarchy) and a
C++ toolchain (`gcc`, `make`, `qmake6`/`qmake`).

```sh
cd ~/code/personal/omarchy-working-memory
./install.sh
```

This builds the binary (`bin/build`, a plain `qmake && make`) onto
`~/.local/bin`, symlinks the Quickshell bar-widget plugin into
`~/.config/omarchy/plugins/`, wires the Hyprland window rule + `Super+N`
binding into `~/.config/hypr/`, and adds the bar icon via `omarchy bar put`.

## Keys

| Key                  | Action                                    |
|-----------------------|-------------------------------------------|
| `Ctrl+C` / `Super+C`  | Copy selection (or `Ctrl+V`/`Super+V` to paste) |
| `Ctrl+R`              | Open history (time machine)               |
| `Ctrl+S`              | Save + commit immediately                 |

Otherwise it's a normal text field — click-drag or `Shift`+arrows to select,
double/triple-click for word/line, everything you'd expect. Saving happens
automatically ~1s after you stop typing, with a git commit ~20s after that.

### History (`Ctrl+R`)

A list of every past version on the left; the selected one's full text,
read-only, on the right — following the list live, not waiting for
`Enter`, since the point is skimming through many versions quickly to find
one. A "Read-only — <date>" title strip above the preview and a faint
background tint both make it unmistakable you're not looking at the live
note.

| Key                  | Action                                  |
|-----------------------|-------------------------------------------|
| Type                 | filter the list by content preview        |
| `↑`/`↓`, click        | move through the list — preview updates live |
| `Enter`               | restore the selected version to the present |
| `Ctrl+C`/`Super+C`    | select text in the preview and copy it out |
| `Esc`                 | back to editing                           |

A save/commit failure (or a history operation failing) switches to a
full-screen error view instead: `Esc`/`Enter` dismisses it, `Ctrl+C`/
`Super+C` copies the error text, and it's always in `error.log` too.

## Data

The note lives at `~/.local/share/omarchy-working-memory/working-memory.txt`
(override with `OMARCHY_WORKING_MEMORY_DIR`), inside a git repo created on
first run.

## Gotchas this repo works around

- **Hyprland's Lua-config fork rejects the classic `hyprctl dispatch <name>
  <args>` CLI form** — it prints a Lua parse error to stderr but exits 0
  without acting. The working form is
  `hyprctl eval 'hl.dispatch(hl.dsp.<category>.<action>(...))'` (see
  `bin/omarchy-working-memory-toggle`'s `reveal()`).
- **A Hyprland special workspace is the wrong tool for a window meant to
  sit alongside others.** The first version parked the scratchpad on one
  (toggled via `hl.dsp.workspace.toggle_special`) so `Super+N` could
  hide/show it as a unit. But a special workspace is an overlay that sits
  on top of and blocks interaction with whatever's underneath until it's
  explicitly dismissed — confirmed directly: after copying text, moving
  the mouse over another window and clicking couldn't refocus it at all,
  because the scratchpad was still covering it; the only way out was to
  close the scratchpad, which then broke the very copy that was just made
  (a Wayland clipboard's data source has to stay alive for paste to work).
  `bin/omarchy-working-memory-toggle` now just launches the app (a plain
  floating window, per the window rule above) or focuses it if already
  running — no special workspace involved.
- **Don't use an `org.omarchy.*` class/app-id for a non-terminal app.**
  Omarchy's terminal-tag rule (`apps/terminals.lua`) matches that prefix
  unconditionally to tag Omarchy-launched TUIs as terminals, which makes
  `Super+C`/`Super+V` send the terminal-style `Ctrl+Insert`/`Shift+Insert`
  instead of literal `Ctrl+C`/`Ctrl+V` — confirmed directly: the clipboard
  stayed untouched after `Super+C` while the window carried the
  `terminal*` tag, and started working the moment the class no longer
  matched that prefix. `app.setDesktopFileName()` in `src/main.cpp` and the
  window-rule match in `hypr/working-memory.lua` both use a plain
  `omarchy-working-memory` class for exactly this reason.

## Roadmap

- Daily rotation / "show me the last few days" browsing.
- Branching off a note for a side train of thought.

The git-backed storage was deliberately shaped for these from the start —
they're just more UI on top of the same `git log`/`git show`/`git branch`
the history picker (`Ctrl+R`) already uses.
