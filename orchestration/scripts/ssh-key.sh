#!/usr/bin/env bash
# ssh-key.sh — let your laptop's ssh into this pod: append your public key(s) to ~/.ssh/authorized_keys,
# check that sshd listens, and print the ~/.ssh/config block for the laptop with the session name filled
# in. One word to type in the web terminal, which does not paste:
#   bash orchestration/scripts/ssh-key.sh                 the public keys registered on your GitHub
#                                                          account (Settings → SSH and GPG keys), fetched
#                                                          from https://github.com/<login>.keys — no scope
#                                                          needed, the login comes from gh
#   bash orchestration/scripts/ssh-key.sh '<key line>'…   the given key line(s); what the agent runs when
#                                                          you paste your key into the chat instead
# Kit-only (docs/TUTORIAL.md stage 4.3); not part of the research repository's launchers.
set -uo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
keys=()
if [ $# -gt 0 ]; then keys=("$@")
else
  login=$(gh api user -q .login 2>/dev/null || true)
  [ -z "$login" ] && { echo "ssh-key: gh cannot say who you are (GitHub not connected in Maestro Settings); pass your key line as an argument instead."; exit 1; }
  mapfile -t keys < <(curl -fsSL "https://github.com/$login.keys" 2>/dev/null | grep -E '^(ssh|ecdsa)-')
  [ ${#keys[@]} -eq 0 ] && { echo "ssh-key: no public key on the GitHub account $login (Settings → SSH and GPG keys)."; echo "  Add your laptop's ~/.ssh/id_ed25519.pub there and rerun, or tell the agent in the chat:"; echo "  run bash orchestration/scripts/ssh-key.sh '<your public key line>'"; exit 1; }
fi
added=0; present=0
for k in "${keys[@]}"; do
  case "$k" in ssh-*|ecdsa-*) ;; *) echo "ssh-key: not a public key line, skipped: $(printf '%s' "$k" | cut -c1-30)…"; continue;; esac
  k2=$(printf '%s' "$k" | awk '{print $1" "$2}')
  if grep -qF "$k2" ~/.ssh/authorized_keys; then present=$((present+1)); else printf '%s\n' "$k" >> ~/.ssh/authorized_keys; added=$((added+1)); fi
done
echo "ssh-key: $added key(s) added, $present already there; $(grep -c -E '^(ssh|ecdsa)-' ~/.ssh/authorized_keys) in ~/.ssh/authorized_keys"
if ss -ltn 2>/dev/null | grep -q ':2222 '; then echo "ssh-key: sshd is listening on 2222"; else echo "ssh-key: WARNING — nothing listens on 2222 here; report it"; fi
S=$(hostname 2>/dev/null | sed -E 's/^maestro-//; s/-0$//')
cat <<EOF

On the laptop, put this in ~/.ssh/config (Windows: the full path to kubectl, in quotes, in the ProxyCommand), then: ssh pod-$S

Host pod-$S
    HostName maestro-$S-0
    User vscode
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    HostKeyAlias pod-$S
    ProxyCommand kubectl -n sessions-prod exec -i -c main maestro-$S-0 -- socat - TCP:127.0.0.1:2222
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
