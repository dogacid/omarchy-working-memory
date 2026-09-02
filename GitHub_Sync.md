# Setting up GitHub sync on a machine

Cross-machine sync (see the "Syncing across machines" section in
[README.md](README.md)) works with any plain git remote, but this is the
concrete, step-by-step setup for the common case: a private GitHub repo,
authenticated with a dedicated SSH deploy key rather than your regular
SSH agent.

## Why a dedicated deploy key, not your regular SSH key/agent

The sync runs unattended, in the background, with no one at the keyboard —
`omarchy-working-memory` pulls/pushes automatically after each edit and
every 5 minutes (see README). It sets `BatchMode=yes` deliberately, so a
stalled auth attempt fails fast instead of hanging the app: that's exactly
right for a normal key, but it means an agent that needs interactive
approval for each signing request (1Password's SSH agent, for example, when
it prompts for touch/biometric confirmation) will just fail rather than
wait for you — which shows up as recurring `offline` status or timeouts in
`error.log` for no obvious reason.

The fix is a **deploy key**: a passphrase-less SSH key dedicated to this one
repo, with write access scoped to *only* that repo (not your whole GitHub
account), configured to bypass any agent entirely. This is standard
practice for unattended git access, not specific to this app — and it needs
no code changes here, because the app never manages credentials itself; all
of this lives in your normal SSH/git config.

## Setup

The key is generated **once** and lives in 1Password
(`op://Private/working_memory`, an SSH Key item). Every Omarchy machine
installs that same key, so a single deploy key covers the fleet and can be
revoked in one place. First-time setup is section A; each additional machine
only needs section B.

### A. One-time: create the key and register it (already done)

Generate the key directly inside 1Password, so the private half never sits in
shell history or a stray file:

```sh
op item create --category "SSH Key" --title working_memory \
  --vault Private --ssh-generate-key=ed25519
```

Then register the public half as a **deploy key** — not a personal SSH key —
with write access, since sync pushes as well as pulls:

```sh
op read "op://Private/working_memory/public key" > /tmp/wm.pub
gh repo deploy-key add /tmp/wm.pub --repo <you>/<repo> \
  --title "omarchy-working-memory sync (1Password: working_memory)" --allow-write
```

A deploy key only grants access to this one repo — even if it leaked, it
can't touch anything else in your GitHub account. Revoke it at the repo's
**Settings → Deploy keys**, which cuts off every machine at once; if you'd
rather revoke machines individually, generate one key per machine instead and
give each its own 1Password item and deploy-key title.

Note: 1Password's CLI cannot write the Notes field on an SSH Key item
(`op item edit` refuses, and `notesPlain=` is ignored on create), so the item
carries the key alone — these instructions are the documentation for it.

### B. Per machine: install the key

**1. Pull the private key out of 1Password.** No passphrase — it has to
authenticate with nobody present to type one:

```sh
umask 077
op read "op://Private/working_memory/private key?ssh-format=openssh" \
  > ~/.ssh/working_memory_sync
chmod 600 ~/.ssh/working_memory_sync
ssh-keygen -y -f ~/.ssh/working_memory_sync > ~/.ssh/working_memory_sync.pub
```

**2. Point SSH at that key for this host, bypassing any agent.** Add to
`~/.ssh/config_local` (which `~/.ssh/config` already `Include`s — keeping it
out of the main file means machine-local setup never conflicts):

```
Host working-memory-sync
  HostName github.com
  User git
  IdentityFile ~/.ssh/working_memory_sync
  IdentitiesOnly yes
  IdentityAgent none
```

`IdentitiesOnly yes` tells ssh to use *only* the specified key file and never
fall back to querying an agent for its own keys. `IdentityAgent none` is the
belt-and-braces companion: this config has `Match host github.com` blocks that
select the 1Password agent, and `Match host` is evaluated *after* `HostName`
substitution — so the alias would otherwise still pick up the agent. ssh takes
the **first** value it obtains for a keyword, and the `Include` sits above
those `Match` blocks, so setting it here wins. Verify with
`ssh -G working-memory-sync | grep -i identityagent`.

**3. Set the data repo's remote to use that host alias**, not `github.com`
directly:

```sh
git -C ~/.local/share/omarchy-working-memory remote set-url origin \
  git@working-memory-sync:<you>/<repo>.git
```

(Use `remote add` instead of `remote set-url` if no remote named `origin`
exists on this machine yet.) No upstream tracking branch is needed — the app
always pushes and pulls an explicit `origin <branch>`.

**4. Verify it, non-interactively:**

```sh
ssh -o BatchMode=yes -T git@working-memory-sync
```

Should greet you as `Hi <you>/<repo>!` with no prompt — that's the deploy-key
identity, not your personal account. If it hangs or asks for a passphrase,
something above didn't take — check the `IdentityFile` path and that
`IdentitiesOnly yes` is actually in the config block for that `Host`.

To confirm *write* access specifically, `git push --dry-run origin main` from
the data repo: a read-only deploy key is refused at this point, so reaching
"Everything up-to-date" means the push path works.

That's it — no app restart needed. The next autosave commit (or `Ctrl+S`)
will push through the new key, and the footer status should read `synced`
instead of `offline`.
