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

On another Omarchy (Arch-based) machine, or an archsway (Arch + sway) one:

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

### On sway (archsway)

`install.sh` picks the desktop from what's configured: the Hyprland steps
above run only if `~/.config/hypr/hyprland.lua` exists, and the sway steps
run if `~/.config/sway` exists. On sway it symlinks
`sway/working-memory.conf` (the floating-window rule + `Super+N`, the sway
equivalent of `hypr/working-memory.lua`) into `~/.config/sway/config.d/`,
which archsway's sway config includes, then reloads sway. The toggle script
detects sway through `$SWAYSOCK` and uses `swaymsg` instead of `hyprctl`.

What's different from Omarchy:

- **No bar icon**: archsway uses waybar, not Omarchy's Quickshell bar, so
  `Super+N` is the only way in.
- **Theme**: there's no `~/.local/state/omarchy/current/theme/colors.toml`,
  so the app uses its built-in Tokyo Night fallback, which is also
  archsway's palette.
- **`Super+C`/`Super+V`**: archsway's `archsway-clipboard` mirrors Omarchy's
  universal clipboard keys and treats `omarchy-working-memory` as a normal
  (non-terminal) window, so these send plain `Ctrl+C`/`Ctrl+V` here too.
- **Sync**: the setup in [GitHub_Sync.md](GitHub_Sync.md) is the same.
  archsway's seeded `~/.ssh/config_local` already includes the
  `working-memory-sync` host block, so only the key itself (step 1) and the
  remote (step 3) are needed.

## Keys

| Key                  | Action                                    |
|-----------------------|-------------------------------------------|
| `Ctrl+C` / `Super+C`  | Copy selection (or `Ctrl+V`/`Super+V` to paste) |
| `Ctrl+R`              | Open history (time machine)               |
| `Ctrl+S`              | Save + commit immediately — and force a sync even if there was nothing new to save (see below) |
| `Alt+D`               | Insert today's date as `[YYYY-MM-DD]`     |
| `Alt+T`               | Insert date + time as `[YYYY-MM-DD HH:MM]` (24h) |
| `Ctrl+1`..`Ctrl+9`     | Jump to the Nth heading in the note        |
| `Ctrl+T`               | Switch topic (see below)                  |
| `Ctrl+Shift+T`         | Create a new topic                        |
| `Ctrl+I`               | Index cards in this topic (see below)     |
| `Ctrl+Shift+I`         | New index card after the open one         |
| `Ctrl+O`               | Jump back after following a card link     |
| `Ctrl+B`               | Inbox of browser captures (see below)     |
| `Esc`                 | Enter vim Normal mode (see below); `?` once there for the full shortcut reference |

Otherwise it's a normal text field — click-drag or `Shift`+arrows to select,
double/triple-click for word/line, everything you'd expect. Saving happens
automatically ~1s after you stop typing, with a git commit ~20s after that.

`Ctrl+S` always also forces a sync attempt, even when there's nothing new to
save — the normal debounced/periodic sync only ever runs off your own
edits, so this is how you manually say "check the remote right now" when
you know something's waiting to come down (e.g. you just edited on another
machine and don't want to wait for the next cycle).

### Vim mode (`Esc`, then `?` for the full list)

`Esc` drops the editor into a lightweight vim-style Normal mode — a few
familiar commands, not a full vim emulation:

| Key       | Where          | Action                                    |
|-----------|----------------|--------------------------------------------|
| `i`       | Normal         | Back to Insert mode (resume typing)        |
| `h`/`j`/`k`/`l`, arrows | Normal / Visual | Move the cursor (or extend the selection, in Visual) |
| `v`       | Normal         | Visual mode (character)                    |
| `V`       | Normal         | Visual line mode                           |
| `dd`      | Normal         | Delete the current line, copied to the clipboard |
| `D`       | Normal         | Delete to end of line, copied to the clipboard |
| `y`       | Visual         | Yank the selection to the clipboard        |
| `d` / `x` | Visual         | Delete the selection, copied to the clipboard |
| `Esc`     | Visual         | Cancel, back to Normal                     |
| `?`       | Normal         | Toggle a popup listing every shortcut in the app |

The footer only ever shows a one-line hint plus the current mode
(`NORMAL`/`VISUAL`/`VISUAL LINE`) — `?` is the actual reference, so the
footer doesn't have to spell out every shortcut as more of them accumulate.
A background sync reloading the note (or restoring from history) always
drops back to Insert mode first, since a Visual selection can't mean
anything once the underlying text has been replaced.

### Topics (`Ctrl+T` / `Ctrl+Shift+T`)

A topic is a separate note for a specific train of thought — a project,
a concentrated piece of thinking, anything you want kept apart from the
general scratchpad — that you can switch to and back from. Under the hood
a topic is just a git branch: `main` is the default note, and each topic is
`topic/<name>`, with its own independent commit history. There's no merge
back into main — a topic is meant to carry its own thread, not to be
reconciled into anything else; if you ever want its content elsewhere,
copy it across by hand the same way you'd copy from any other note.

- **`Ctrl+T`** opens a searchable list of every topic (main included,
  always first) — type to filter, `↑`/`↓`/`j`/`k` to move, `Enter` to
  switch, `Esc` to cancel.
- **`Ctrl+Shift+T`** prompts for a name and creates a new topic. It starts
  as a genuinely blank note — nothing from main or wherever you currently
  are carries over — so it's a clean space for that new line of thinking.
  The name becomes the branch's identity (lowercased, spaces and
  punctuation collapsed to `-`), and a duplicate name is rejected rather
  than silently switching you to the existing topic of that name.
- Either action **flushes the topic you're leaving first** — the same
  save + commit `Ctrl+S` does, synchronously, so nothing from it is ever at
  risk — before switching or creating.
- The window title shows which topic you're in (nothing for `main`, the
  topic's name otherwise), since the footer stays too compact to spell it
  out on every line.
- Topics sync the same way `main` does: created on one machine, `Ctrl+T`
  will see it on another once the regular background sync has had a chance
  to fetch — no separate setup. Switching to a topic pulls its latest
  content immediately, same as opening the app fresh does for `main`.

### Index cards (`Ctrl+I` / `Ctrl+Shift+I`)

Within any topic you can keep a set of index cards, numbered the way Niklas
Luhmann numbered the slips in his Zettelkasten. A card's number is its
permanent address and is never changed, and the number itself says where
the card sits in a line of thought:

- **Continuing** a thought takes the next number in the same run: `1` → `2`,
  `1a` → `1b`, `1a1` → `1a2`.
- **Branching** off a card adds a level: `1` → `1a`, `1a` → `1a1`. Numbers
  and letters alternate, and letters run `a`…`z`, `aa`, `ab`, …
- In order, a branch files directly behind the card it grew from and ahead
  of that card's next sibling: `1, 1a, 1a1, 1a2, 1b, 2`. That's how
  Luhmann put a new card "in between" without renumbering anything.

**`Ctrl+Shift+I`** creates a new card after the one you're on, using
Luhmann's own rule: the next number if it's free, or a branch if that
number is already taken (e.g. continuing from `1` when `2` already exists
gives `1a`). From the topic's note it starts the next top-level card.

**`Ctrl+I`** opens the card picker, which is laid out like the history
viewer: the cards on the left in slip-box order (indented by branch, with
the topic note first and each card's creation time), and the highlighted
card's text on the right.

| Key in the picker | Action |
|-------------------|--------|
| `j`/`k`, `↑`/`↓`, `g`/`G` | Move, or jump to the top/bottom |
| `Enter`           | Open the card (or the topic note) |
| `l`               | Insert a link to the card at your cursor in the text you came from |
| `y`               | Copy the link to the clipboard |
| `c`               | New card after the highlighted one (same rule as `Ctrl+Shift+I`) |
| `b`               | New branch off the highlighted one (always a child) |
| `/`               | Search every topic (see below) |
| `Esc` / `Ctrl+I`  | Back to the editor |

Search (`/`) covers the full text of every card and every topic note, in
all topics, not just the one you're in. Every word you type has to appear
somewhere in a card, in any case and on any line, so `wire dangle` finds a
card mentioning both. Each result shows the line it matched with your words
highlighted, labelled with its topic when it's from another one, and the
preview scrolls to the first match. Typing the start of a card number
(`1a`) also lists those cards in the current topic. `Enter` opens the
highlighted result, switching topic if it's elsewhere (`Ctrl+O` comes back);
`↓` moves into the list so you can press `l` or `y` on a result instead.
Other topics are searched as of their last commit, which is at most ~20
seconds behind what you typed there.

A link looks like `[[topic:1a2]]` (e.g. `[[main:3]]`). It always names the
topic, so it still works after being copied into another topic. In vim
Normal mode, `Enter` or `gd` on a link opens that card, switching topic
first if it has to, and `Ctrl+O` jumps back to where you were.

**Two machines, same number.** Each machine hands out card numbers on
its own, so two machines adding "the next card" to a topic while out of
sync can both pick, say, `2`. A number only becomes final once it's been
pushed: before pulling, a sync checks whether this machine's unpushed new
cards clash with cards the other machine added meanwhile. This machine's
copy is the provisional one (no one else has seen it, so nothing links to
it yet), so it moves to the next free number at the same position (`2` →
`3`, or `4` if `3` is taken too). Its branches move with it (`2a` → `3a`),
links to it in that topic are updated, and if it's the card you have open,
you just keep typing in it under its new number. The footer says what
moved. Without this, git would have merged the two different cards into
one.

Each card is a plain file, `cards/<number>.txt`, on the topic's branch.
Cards are saved, committed and synced exactly like the note, `Ctrl+R` shows
the history of whichever card is open, and the window title and footer show
which card that is. A new topic starts with no cards.

### Browser capture and the inbox (`Ctrl+B`)

A small Chromium extension (in `extension/`) sends what you're reading to
an **inbox**: the selected text, or a link, or just the page, along with
its title and address. Captures wait there until you file them into the
slip box, the way Luhmann made notes on a source first and only later
wrote permanent cards from them.

- **Capturing:** right-click a selection, a link or the page and choose
  "Send … to Working Memory inbox", or press `Alt+Shift+W` (the selection
  if there is one, else the page), or click the toolbar button. The button
  flashes ✓ when it's in. This works whether or not the app is open.
- **A capture** is plain text, ready to become a card:
  ```
  > the selected text, quoted
  — Page title
    https://example.com/article   [2026-10-10 14:32]
  ```
- **`Ctrl+B`** opens the inbox: captures on the left, oldest first, the
  whole capture on the right. `j`/`k` move, `y` copies, `dd` discards.
- **Filing:** `Enter` on a capture opens the card picker to choose its
  place. The header shows exactly what will happen ("enter → 3b (after
  3a) · b → 3a1 (branch)"). `Enter` files it after the highlighted card,
  `b` as a branch of it, and the topic note row as the next top-level card.
  Search finds the right card in any topic, and typing a topic name with a
  colon (`garden:`) lists that topic's cards. The new card opens straight
  away, so you can rewrite the capture in your own words. Filing into
  another topic switches to it; `Ctrl+O` comes back. `Esc` returns to the
  inbox.
- The footer shows `inbox N` while anything's waiting.

**Setup:** run `./install.sh`, then restart Chromium. It registers the
extension's native messaging host with Chromium, Chrome and Brave
(whichever you have), and adds `extension/` to the `--load-extension` list
in `~/.config/chromium-flags.conf`, the same way Omarchy loads its own
Chromium extensions, so it's there on every launch. If an Omarchy update
ever rewrites that file, rerun `./install.sh`. For Chrome or Brave, load
`extension/` by hand: `chrome://extensions`, Developer mode on, **Load
unpacked**. Change the shortcut at `chrome://extensions/shortcuts`.

How it works: the browser starts `omarchy-working-memory --native-host`,
which passes the capture to the running app over a local socket, or, when
the app isn't open, writes it to the inbox itself. The inbox is its own
git branch, `inbox`, with one file per capture named by time and machine.
It's written directly, never checked out, so a capture never disturbs what
you're editing, and it syncs alongside everything else: captures from two
machines merge cleanly, and filing one removes it on both.

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
doesn't stall the background sync.) Nothing else to configure — sync
piggybacks on the existing save/commit flow: a pull happens the moment the
window opens, and a pull-then-push happens after every autosave commit
(~20s after you stop typing) and after `Ctrl+S`, plus a background check
every 5 minutes so a window left open but idle still picks up another
machine's changes. That same 5-minute check also self-heals: if a commit
ever fails to complete on its own (a missed timer, the machine having
suspended mid-cycle, anything), the periodic check notices and retries it,
so nothing can stay stuck un-synced for longer than one interval — `Ctrl+S`
always forces it immediately if you don't want to wait. All of it runs on a
background thread — typing and `Ctrl+S` never wait on the network, however
slow or unreachable the remote is.

The status word in the footer picks up two new values: `syncing…` while a
pull/push is actually in flight — lazygit-style feedback, so opening the
window shows it visibly working rather than leaving you to wonder whether
anything happened — and `offline` when a sync attempt can't reach the
remote. Either way your edits keep saving and committing locally
regardless, exactly as if no remote were configured at all; a sync just
hasn't reached `origin` yet and will on the next cycle.

Three things keep a sync from ever fighting your typing:

- **Opening waits for the pull.** When the app opens with a remote
  configured, the text shows dimmed and read-only, with "getting the latest
  from your other machines…" in the footer, until that first pull has
  landed: usually a second or two, and never more than 8 seconds (offline,
  it lets go straight away). Anything you type meanwhile isn't lost: it's
  held and dropped in at the cursor the moment the up-to-date text is in.
- **Changes arriving while you type are merged, not swapped.** If a
  sync brings in another machine's edit to the note or card you're typing
  in, the app does a three-way merge of the text both sides started from,
  your text and theirs (`git merge-file`, with the same keep-both-sides
  rule as below), so both sets of changes survive and your cursor stays on
  the text it was on. Autosave also never writes the file while a pull
  could still be landing in it.
- **Closing pushes.** Closing the window lets that last save's sync finish
  in the background (for up to 10 seconds) before the app exits, so the
  other machine has your latest the next time it opens, rather than only
  after this machine's next launch. If you reopen within those seconds,
  the new window waits for the old one to finish first.

None of this is aggressive enough to be a concern for GitHub or any other
host: it's the same plain `git fetch`/`pull`/`push` any developer runs by
hand, at a cadence (once per open, once per edit, every 5 minutes at most)
far below what git hosts are built to handle from a single user — nothing
here polls a REST API, which is the kind of traffic that actually has tight
rate limits.

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
