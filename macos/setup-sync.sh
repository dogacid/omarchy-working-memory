#!/bin/bash
# Sets up GitHub sync on this Mac — section B of GitHub_Sync.md, end to end:
#   1. installs the deploy key from 1Password (op://Private/working_memory)
#      as ~/.ssh/working_memory_sync
#   2. adds the working-memory-sync host alias to the top of
#      ~/.ssh/config_local, so it bypasses the 1Password agent
#   3. points the data repo's origin at git@working-memory-sync:<repo>
#   4. checks each step non-interactively, including write access
# Idempotent: rerun any time (e.g. after the key is rotated in 1Password).
#
# Usage: macos/setup-sync.sh [owner/repo]   (default: dogacid/working_memory)
set -euo pipefail

REPO="${1:-dogacid/working_memory}"
OP_ITEM="op://Private/working_memory"
KEY="$HOME/.ssh/working_memory_sync"
ALIAS="working-memory-sync"
SSH_CONFIG="$HOME/.ssh/config"
SSH_LOCAL="$HOME/.ssh/config_local"
DATA="${OMARCHY_WORKING_MEMORY_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-working-memory}"

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v op >/dev/null || die "the 1Password CLI isn't installed: brew install 1password-cli"
[[ -d "$DATA/.git" ]] || die "no data repo at $DATA yet. Open Working Memory once first, then rerun this."

step "1. Deploy key from 1Password"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
umask 077
tmp="$(mktemp "$HOME/.ssh/.working_memory_sync.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Prompts for 1Password unlock (Touch ID) if it's locked.
op read "$OP_ITEM/private key?ssh-format=openssh" >"$tmp" || die "couldn't read $OP_ITEM from 1Password"
if [[ -f "$KEY" ]] && cmp -s "$tmp" "$KEY"; then
  echo "already installed: $KEY"
else
  mv "$tmp" "$KEY"
  echo "installed: $KEY"
fi
chmod 600 "$KEY"
ssh-keygen -y -f "$KEY" >"$KEY.pub"

step "2. SSH host alias '$ALIAS' (bypassing the 1Password agent)"
# The app's sync runs unattended with BatchMode=yes, so an agent that wants
# Touch ID per use just fails it. This block has to come before any
# `Host *` setting IdentityAgent: ssh keeps the first value it sees.
touch "$SSH_LOCAL"
if grep -qE "^Host[[:space:]]+$ALIAS\$" "$SSH_LOCAL"; then
  echo "already in $SSH_LOCAL"
else
  backup="$SSH_LOCAL.bak.$(date +%s)"
  cp "$SSH_LOCAL" "$backup"
  { cat <<EOF
# omarchy-working-memory sync: deploy key, never the agent (see GitHub_Sync.md)
Host $ALIAS
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
  IdentityAgent none

EOF
    cat "$backup"
  } >"$SSH_LOCAL.new"
  mv "$SSH_LOCAL.new" "$SSH_LOCAL"
  chmod 600 "$SSH_LOCAL"
  echo "added to the top of $SSH_LOCAL"
fi
# config_local only counts if the main config includes it.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+~/.ssh/config_local' "$SSH_CONFIG" 2>/dev/null; then
  if [[ -L "$SSH_CONFIG" ]]; then
    die "$SSH_CONFIG (a symlink, so not edited here) doesn't Include ~/.ssh/config_local — add 'Include ~/.ssh/config_local' as its first line"
  fi
  touch "$SSH_CONFIG"
  printf 'Include ~/.ssh/config_local\n\n%s' "$(cat "$SSH_CONFIG")" >"$SSH_CONFIG"
  echo "added 'Include ~/.ssh/config_local' to the top of $SSH_CONFIG"
fi
agent="$(ssh -G "$ALIAS" | awk '$1 == "identityagent" { print $2 }')"
[[ "$agent" == "none" ]] || die "ssh still resolves IdentityAgent=$agent for $ALIAS — something earlier in your ssh config sets it first"
greeting="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -T "git@$ALIAS" 2>&1 || true)"
[[ "$greeting" == *"Hi $REPO!"* ]] || die "GitHub didn't accept the key for $REPO: $greeting"
echo "GitHub says: ${greeting%%!*}!"

step "3. Data repo remote"
url="git@$ALIAS:$REPO.git"
if git -C "$DATA" remote get-url origin >/dev/null 2>&1; then
  git -C "$DATA" remote set-url origin "$url"
else
  git -C "$DATA" remote add origin "$url"
fi
echo "origin = $url"

step "4. Read and write access"
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" git -C "$DATA" ls-remote --heads origin >/dev/null \
  || die "can't fetch from $url"
echo "fetch: ok"
# A dry-run push to a branch that doesn't exist reaches GitHub's write
# check (a read-only deploy key is refused here) without changing anything.
if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5" \
    git -C "$DATA" push --dry-run origin "HEAD:refs/heads/setup-sync-write-check" >/dev/null 2>&1; then
  echo "push: ok"
else
  die "push refused: the deploy key on $REPO needs 'Allow write access' (repo Settings → Deploy keys)"
fi

printf '\nDone. Working Memory syncs on its next save (Cmd+S to do it now), when\nits window is reopened, or within 5 minutes.\n'
