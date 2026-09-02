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
  continuous motion, not select-view-back-select-view. Fully keyboard-driven,
  vim-style: `j`/`k` (or `↑`/`↓`) move through the list, `v`/`V` starts a
  charwise/linewise selection in the preview, `h`/`j`/`k`/`l` extend it, `y`
  (or `Ctrl+C`/`Super+C`) yanks it out. `Enter` restores that whole
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

On another Omarchy (Arch-based) machine:

```sh
sudo pacman -S --needed qt6-base qt6-declarative gcc make git jq
git clone https://github.com/dogacid/omarchy-working-memory.git
cd omarchy-working-memory
./install.sh
```

`qt6-quickcontrols2` isn't a separate package on Arch/Omarchy — it's bundled
into `qt6-declarative` (confirmed via `pacman -Qo` against the actual
installed `.so`). `jq` and `git` are almost certainly already on any real
Omarchy install (Omarchy's own scripts and this repo's toggle script both
lean on `jq` for parsing `hyprctl` output), but `--needed` makes the pacman
call a safe no-op either way if so.

`install.sh` is location-independent — clone it anywhere, `cd` in, run it
from there. It builds the binary (`bin/build`, a plain `qmake && make`)
onto `~/.local/bin`, symlinks the Quickshell bar-widget plugin into
`~/.config/omarchy/plugins/`, wires the Hyprland window rule + `Super+N`
binding into `~/.config/hypr/`, and adds the bar icon via `omarchy bar put`.
Re-running it after a `git pull` picks up any update — it's idempotent.

## Keys

| Key                  | Action                                    |
|-----------------------|-------------------------------------------|
| `Ctrl+C` / `Super+C`  | Copy selection (or `Ctrl+V`/`Super+V` to paste) |
| `Ctrl+R`              | Open history (time machine)               |
| `Ctrl+S`              | Save + commit immediately                 |
| `Alt+D`               | Insert today's date as `[YYYY-MM-DD]`     |
| `Alt+T`               | Insert date + time as `[YYYY-MM-DD HH:MM]` (24h) |
| `Ctrl+1`..`Ctrl+9`     | Jump to the Nth heading in the note        |

Otherwise it's a normal text field — click-drag or `Shift`+arrows to select,
double/triple-click for word/line, everything you'd expect. Saving happens
automatically ~1s after you stop typing, with a git commit ~20s after that.

### Headings and jumping (`Ctrl+1`..`Ctrl+9`)

A line starting with one or more `#` followed by a space (`# `, `## `,
`### `, ...) is a heading — standard markdown ATX heading syntax, not
markdown rendering, just a plain-text marker. The required space is what
keeps this from colliding with things you'd naturally type at the start of
a line, like a hex color (`#fff`) or an issue reference (`#123`) — neither
has a space right after the `#`. `Ctrl+1` jumps to the first heading in the
note, `Ctrl+2` the second, and so on through `Ctrl+9`; a number past the
last heading is a no-op. Useful for splitting the note into a few running
threads — work, a project, a hobby — and jumping straight to one. There's
no separate management step: start a line with `#` (any number of them) and
a space to create one, delete or move it to remove or reorder it.

### History (`Ctrl+R`)

A list of every past version on the left; the selected one's full text,
read-only, on the right — following the list live, not waiting for
`Enter`, since the point is skimming through many versions quickly to find
one. A "Read-only — <date>" title strip above the preview and a faint
background tint both make it unmistakable you're not looking at the live
note. Fully keyboard-driven, vim-style:

| Key                  | Where     | Action                                  |
|-----------------------|-----------|-------------------------------------------|
| `j`/`k`, `↑`/`↓`, click | list    | move through the list — preview updates live |
| `/`                   | list      | jump to the search field                  |
| `v` / `V`             | list      | enter visual selection in the preview — charwise / linewise |
| `h`/`j`/`k`/`l`, arrows | visual  | move the cursor, extending the selection from where `v`/`V` started |
| `y`, `Ctrl+C`/`Super+C` | visual  | yank the selection to the clipboard, back to the list |
| `Esc`                 | visual    | cancel the selection, back to the list (not out of history) |
| `Enter`               | list      | restore the selected version to the present |
| `Esc`                 | list      | back to editing                           |

Mouse selection (click-drag, double/triple-click) still works in the
preview too — `v`/`V` is there for going fully keyboard-driven, not a
replacement for it.

A save/commit failure (or a history operation failing) switches to a
full-screen error view instead: `Esc`/`Enter` dismisses it, `Ctrl+C`/
`Super+C` copies the error text, and it's always in `error.log` too.

## Data

The note lives at `~/.local/share/omarchy-working-memory/working-memory.txt`
(override with `OMARCHY_WORKING_MEMORY_DIR`), inside a git repo created on
first run, always normalized onto a branch named `main` (regardless of this
machine's own `git init` default) so multiple machines sharing a remote
never end up pushing/pulling different refs without noticing.

## Syncing across machines

The same note can follow you across several Omarchy machines by pointing
the data repo's git remote at a shared one — a private GitHub/GitLab repo to
start, though any plain git remote works (a self-hosted Forgejo/Gitea
instance, for example — just a URL, nothing GitHub-specific in how this
works). One-time setup per machine, outside the app:

```sh
git -C ~/.local/share/omarchy-working-memory remote add origin <url>
```

(SSH recommended — see [GitHub_Sync.md](GitHub_Sync.md) for the concrete
step-by-step if you're syncing through GitHub, including setting up a
dedicated deploy key so an interactive-approval SSH agent, like 1Password's,
doesn't stall the background sync.) Nothing else to configure — sync piggybacks on the
existing save/commit flow: a pull happens once when the app opens, and a
pull-then-push happens after every autosave commit (~20s after you stop
typing) and after `Ctrl+S`, plus a background check every 5 minutes so a
window left open but idle still picks up another machine's changes. All of
it runs on a background thread — typing and `Ctrl+S` never wait on the
network, however slow or unreachable the remote is. The status word in the
footer picks up one new value, `offline`, when a sync attempt can't reach
the remote — your edits keep saving and committing locally regardless,
exactly as if no remote were configured at all; it just hasn't reached
`origin` yet and will on the next cycle.

Merges are configured as a **union merge** for the note (a `.gitattributes`
entry the app writes itself): on any conflicting hunk, git keeps *both*
sides rather than stopping to ask — including the very first sync on a
machine that already had its own local history before a remote existed,
which would otherwise be a whole-file "unrelated histories" conflict. So
upgrading an existing install onto a populated remote just merges both
notes' content together automatically; nothing is ever lost, only
occasionally duplicated, which is the right trade for a mostly-append
scratchpad — tidy up any duplication by hand at your leisure. The
full-screen error view is reserved for the rare case a real conflict still
can't auto-resolve. Nothing is ever destructively lost either way: every
version from every machine stays in the log, reachable through `Ctrl+R`.

The app never manages credentials or SSH keys itself — remote auth is
whatever you'd normally set up for that git host, non-interactively (an SSH
key, typically), the same as any other repo.

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
- Branching off a note for a side train of thought — a "rabbit hole" you can
  wander into and later merge back or abandon, using real git branches
  (distinct from the `#` headings above, which stay inside one branch).
- A read-only combined overview of all headings at a glance (a table of
  contents view) — floated alongside the `Ctrl+1`-`9` heading jump above,
  deferred in favor of the simpler jump-only version for now.

The git-backed storage was deliberately shaped for these from the start —
they're just more UI on top of the same `git log`/`git show`/`git branch`
the history picker (`Ctrl+R`) already uses.
