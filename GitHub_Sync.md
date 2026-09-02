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

## Setup (repeat on each Omarchy machine)

**1. Generate a dedicated key.** No passphrase — it has to authenticate
with nobody present to type one:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/working_memory_sync -N "" -C "omarchy-working-memory sync"
```

**2. Add it as a GitHub deploy key**, not a personal SSH key:

- GitHub → your working-memory repo → **Settings → Deploy keys → Add deploy key**
- Title: something identifying this machine, e.g. `omarchy-working-memory sync (laptop)`
- Key: paste the contents of `~/.ssh/working_memory_sync.pub`
- Check **Allow write access** (sync needs to push, not just pull)

A deploy key only grants access to this one repo — even if it leaked, it
can't touch anything else in your GitHub account. You can reuse the same
key on every machine, or generate one per machine (as the title above
suggests) if you'd rather be able to revoke one machine's access
individually without affecting the others.

**3. Point SSH at that key for this host, bypassing any agent.** Add to
`~/.ssh/config`:

```
Host working-memory-sync
  HostName github.com
  User git
  IdentityFile ~/.ssh/working_memory_sync
  IdentitiesOnly yes
```

`IdentitiesOnly yes` is the important line — it tells ssh to use *only* the
specified key file and never fall back to querying the SSH agent (1Password
or otherwise) for this host at all.

**4. Set the data repo's remote to use that host alias**, not `github.com`
directly:

```sh
git -C ~/.local/share/omarchy-working-memory remote add origin git@working-memory-sync:<you>/<repo>.git
```

(Use `remote set-url` instead of `remote add` if a remote named `origin` is
already configured on this machine.)

**5. Verify it, non-interactively:**

```sh
ssh -T git@working-memory-sync
```

Should greet you by the repo/deploy-key identity without any prompt. If it
hangs or asks for a passphrase, something above didn't take — check the
`IdentityFile` path and that `IdentitiesOnly yes` is actually in the config
block for that `Host`.

That's it — no app restart needed. The next autosave commit (or `Ctrl+S`)
will push through the new key, and the footer status should read `synced`
instead of `offline`.
