#!/usr/bin/env bash
# pod-setup.sh — make THIS pod ready to run an orchestrator and its workers. Idempotent; the bootstrap
# (scripts/bootstrap-repo.sh in the kit, run by every first message) runs it, the tutorial's stage 3.4
# runs it again by hand, and so does a pod restart; nothing here needs the Maestro CLI, a laptop, or
# ssh — it runs inside the pod, so a session created from the web UI can set itself up by being told
# to run it. BOOTSTRAP_SESSION overrides the session name read from the hostname (scripts/self-test.sh).
#
# What it does, each step a row in the table it prints:
#   1. ~/.claude/settings.json: merge (never replace) the keys the launchers need — bypass permissions,
#      per-model effort, the subagent model, no co-author trailer. Maestro's own keys are kept.
#   2. ~/.bashrc: one marked block — caches under /workspace (the home volume is small), the effort
#      variable unset (it overrides modelSettings), the orchestrator model exported.
#   3. The Claude token pin: if ~/.maestro/claude_token exists and no pin does, record its sha256 so
#      status.sh and the launchers can tell a re-injected token from the wanted one.
#   3a. A git identity GitHub accepts on push (the noreply address), only when none is set.
#   3b. This pod's parameters: is orchestration/local.env present, and what does it name.
#   4. The project environment: `uv sync` when a pyproject.toml is present.
#   4b. The accesses, read-only: gh (who), gcloud (the account; calls run through the connector), slack.
#   4b2. The session's Slack channel #maestro-<session>, resolved by name and written to local.env.
#   4b3. Your GitHub-registered public keys into ~/.ssh/authorized_keys, and is sshd listening.
#   4c. The pod's cgroup limits and volumes, ANTHROPIC_MODEL, the checkout. One command in the web terminal
#       (which does not paste) answers the tutorial's stages 3.4 and 3.5.
#   5. The table, and the status script if the repository has one.
set -u
cd /workspace 2>/dev/null || cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# The models come from orchestration/local.env when the repository carries the P-4 loader; the
# environment wins, and the defaults below are orch-env.sh's.
if [ -r orchestration/scripts/orch-env.sh ]; then . orchestration/scripts/orch-env.sh; orch_env_load "$PWD"; fi
MODEL="${ORCH_MODEL_ORCHESTRATOR:-claude-fable-5-1}"
SUBAGENT="${ORCH_MODEL_WORKER:-claude-opus-5-5}"
rows=(); row() { rows+=("$(printf '%-6s %-22s %s' "$1" "$2" "$3")"); }

# 1. settings.json, merged
S="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"
[ -s "$S" ] || echo '{}' > "$S"
if python3 - "$S" "$MODEL" "$SUBAGENT" <<'PY'
import json, sys
p, model, sub = sys.argv[1:4]
try: d = json.load(open(p))
except Exception: d = {}
d.setdefault("permissions", {})["defaultMode"] = "bypassPermissions"
d["skipDangerousModePermissionPrompt"] = True
d["includeCoAuthoredBy"] = False
d.setdefault("env", {})["CLAUDE_CODE_SUBAGENT_MODEL"] = sub
ms = d.setdefault("modelSettings", {})
ms.setdefault("claude-fable-5-1", {})["effortLevel"] = "medium"
ms.setdefault("claude-opus-5", {})["effortLevel"] = "high"
ms.setdefault("claude-opus-5-5", {})["effortLevel"] = "high"
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
then row ok "settings.json" "bypass permissions, modelSettings, subagent $SUBAGENT (merged, Maestro keys kept)"
else row FAIL "settings.json" "could not merge $S"; fi

# 2. bashrc block, idempotent
B="$HOME/.bashrc"; M1="# >>> maestro-kit pod-setup >>>"; M2="# <<< maestro-kit pod-setup <<<"
python3 - "$B" "$M1" "$M2" "$MODEL" <<'PY'
import sys, re
p, m1, m2, model = sys.argv[1:5]
block = f"""{m1}
export PATH="$HOME/.local/bin:$PATH"
export UV_CACHE_DIR=/workspace/.caches/uv
export HF_HOME=/workspace/.caches/hf
export PLAYWRIGHT_BROWSERS_PATH=/workspace/.caches/ms-playwright
# the container environment carries CLAUDE_CODE_EFFORT_LEVEL from the session record; it overrides modelSettings
unset CLAUDE_CODE_EFFORT_LEVEL
export ANTHROPIC_MODEL={model}
{m2}
"""
try: s = open(p).read()
except FileNotFoundError: s = ""
s = re.sub(re.escape(m1) + r".*?" + re.escape(m2) + r"\n?", "", s, flags=re.S)
open(p, "w").write(s.rstrip("\n") + "\n\n" + block)
PY
mkdir -p /workspace/.caches/uv /workspace/.caches/hf /workspace/.caches/ms-playwright
row ok "bashrc" "caches under /workspace, effort unset, ANTHROPIC_MODEL=$MODEL"

# 3. the token pin — hashed EXACTLY as token-guard.sh does: the content with all whitespace removed, never
#    the file's bytes (the file ends in a newline; the two hashes differ, and the launchers refuse on MISMATCH)
T="$HOME/.maestro/claude_token"; P="$HOME/.maestro/expected_claude_token_sha256"
trimmed_hash() { tr -d '[:space:]' < "$1" 2>/dev/null | sha256sum | cut -d' ' -f1; }
raw_hash() { sha256sum < "$1" | cut -d' ' -f1; }
if [ -s "$T" ]; then
  want=$(trimmed_hash "$T")
  if [ -s "$P" ]; then
    have=$(tr -d '[:space:]' < "$P")
    if [ "$want" = "$have" ]; then row ok "token pin" "running token matches the pin (${want:0:12}…)"
    elif [ "$(raw_hash "$T")" = "$have" ]; then printf '%s\n' "$want" > "$P"; chmod 600 "$P"; row ok "token pin" "re-pinned ${want:0:12}…: the earlier pin hashed the file's bytes, the guard hashes the trimmed content (same token)"
    else row FAIL "token pin" "running token ${want:0:12}… differs from the pin ${have:0:12}… (re-injected on restart?) — see LESSONS; to accept the running one: rm $P and rerun"; fi
  else printf '%s\n' "$want" > "$P"; chmod 600 "$P"; row ok "token pin" "pinned the current token ${want:0:12}…"; fi
else row warn "token pin" "no ~/.maestro/claude_token here (a different wiring); skipped"; fi

# 3a. a git identity that GitHub accepts on push: only when none is set; a private address is rejected
#     ("email privacy restrictions"), so the noreply one is the safe default
if [ -z "$(git config --global user.email 2>/dev/null)" ] && command -v gh >/dev/null 2>&1 && id=$(gh api user -q .id 2>/dev/null) && login=$(gh api user -q .login 2>/dev/null) && [ -n "$id" ]; then
  git config --global user.email "$id+$login@users.noreply.github.com"; git config --global user.name "$login"
  row ok "git identity" "set to $id+$login@users.noreply.github.com (was unset)"
else row ok "git identity" "$(git config --global user.email 2>/dev/null || echo unset) (left as found)"; fi

# 3b. this pod's parameters (bootstrap-repo.sh writes the file; the Slack channel is added in 4b2)
L=orchestration/local.env
if [ -s "$L" ]; then row ok "local.env" "$(grep -E '^ORCH_(PROJECT|GCP_PROJECT|VM_PREFIX|SLACK_CHANNEL)=' "$L" | tr '\n' ' ')"
else row warn "local.env" "absent: bootstrap-repo.sh writes it (project, GCP project, VM prefix); the Slack channel is resolved below"; fi

# 4. the environment
if [ -f pyproject.toml ]; then
  export UV_CACHE_DIR=/workspace/.caches/uv
  if command -v uv >/dev/null 2>&1; then
    if out=$(uv sync 2>&1); then row ok "uv sync" "$(printf '%s\n' "$out" | tail -1)"; else row FAIL "uv sync" "$(printf '%s\n' "$out" | tail -1)"; fi
  else row FAIL "uv sync" "uv not installed in this image"; fi
else row skip "uv sync" "no pyproject.toml"; fi

# 4b. the accesses, read-only, one row each (docs/TUTORIAL.md stage 3.5)
if command -v gh >/dev/null 2>&1 && login=$(gh api user -q .login 2>/dev/null) && [ -n "$login" ]; then row ok "gh" "$login"
else row warn "gh" "not authenticated: connect GitHub in Maestro Settings"; fi
acct=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)
if [ -n "$acct" ]; then row ok "gcloud" "$acct (informational: calls run through your Google Cloud connector)"
else row warn "gcloud" "no active account: connect the Google Cloud connector in Maestro Settings"; fi
if command -v slack >/dev/null 2>&1; then
  so=$(slack auth-test 2>/dev/null | head -c 400)
  case "$so" in *user_id*) row ok "slack" "connected ($(printf '%s' "$so" | grep -o '"user_id":"[^"]*"' | head -1))";; *) row warn "slack" "not connected (the Slack connector is optional)";; esac
else row warn "slack" "no slack CLI in this image"; fi

# 4b2. the session's Slack channel, found by its name: Maestro's app creates `#maestro-<session>` and the
#      pod knows its session, so nobody copies an id. The pod's slack CLI acts as the owner and sees the
#      private channel; the id is the last segment of the channel's permalink.
SESSION_NAME=${BOOTSTRAP_SESSION:-}
[ -z "$SESSION_NAME" ] && case "$(hostname 2>/dev/null)" in maestro-*-0) SESSION_NAME=$(hostname | sed -E 's/^maestro-//; s/-0$//');; esac
REC=$(grep '^ORCH_SLACK_CHANNEL=' "$L" 2>/dev/null | tail -1 | cut -d= -f2)
if ! command -v slack >/dev/null 2>&1 || [ -z "$SESSION_NAME" ]; then
  if [ -n "$REC" ]; then row ok "slack channel" "$REC (from orchestration/local.env; not re-checked: no slack CLI here, or the session name is unknown)"
  else row warn "slack channel" "not resolved: no slack CLI here, or the session name is unknown"; fi
else
  # resolved by name every time: a channel made again (8 October: one made by hand, then the app's) gets a new id
  CH=$(slack search --query "maestro-$SESSION_NAME" --content-types channels --channel-types private_channel,public_channel 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    for c in ((d.get("data") or {}).get("results") or {}).get("channels") or []:
        if c.get("name") == want and not c.get("is_archived"):
            print(c.get("permalink", "").rstrip("/").rsplit("/", 1)[-1]); sys.exit(0)
' "maestro-$SESSION_NAME")
  if [ -n "$CH" ] && [ "$CH" = "$REC" ]; then row ok "slack channel" "#maestro-$SESSION_NAME is $CH (as orchestration/local.env says)"
  elif [ -n "$CH" ] && [ -n "$REC" ]; then sed -i "s|^ORCH_SLACK_CHANNEL=.*|ORCH_SLACK_CHANNEL=$CH|" "$L"; row ok "slack channel" "#maestro-$SESSION_NAME is $CH now, not $REC as orchestration/local.env said — rewritten (the channel was made again)"
  elif [ -n "$CH" ]; then printf 'ORCH_SLACK_CHANNEL=%s\n' "$CH" >> "$L"; row ok "slack channel" "#maestro-$SESSION_NAME is $CH — written to orchestration/local.env"
  elif [ -n "$REC" ]; then row warn "slack channel" "$REC (from orchestration/local.env), but no open channel #maestro-$SESSION_NAME is visible to the pod's slack CLI now: renamed, archived, or the connector gone?"
  else row warn "slack channel" "no channel #maestro-$SESSION_NAME yet: let the Maestro app create it (docs/TUTORIAL.md 4.2; one made by hand is not linked to the session), then rerun this script"; fi
fi

# 4b3. your laptop's ssh key, without interaction: the public keys registered on your GitHub account
#      (https://github.com/<login>.keys, public, no scope needed) appended to ~/.ssh/authorized_keys.
#      A key that is not on GitHub goes through ssh-key.sh '<key line>' from the chat.
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
gh_login=$(gh api user -q .login 2>/dev/null || true); k_added=0; k_have=0
if [ -n "$gh_login" ]; then
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    k2=$(printf '%s' "$k" | awk '{print $1" "$2}')
    if grep -qF "$k2" "$HOME/.ssh/authorized_keys"; then k_have=$((k_have+1)); else printf '%s\n' "$k" >> "$HOME/.ssh/authorized_keys"; k_added=$((k_added+1)); fi
  done < <(curl -fsSL "https://github.com/$gh_login.keys" 2>/dev/null | grep -E '^(ssh|ecdsa)-')
fi
k_total=$(grep -c -E '^(ssh|ecdsa)-' "$HOME/.ssh/authorized_keys")
if ss -ltn 2>/dev/null | grep -q ':2222 '; then sshd_note="sshd on 2222"; else sshd_note="NO sshd on 2222 — report it"; fi
if [ "$k_total" -gt 0 ]; then row ok "ssh keys" "$k_total in authorized_keys ($k_added added now, $k_have already there, from github.com/${gh_login:-?}.keys); $sshd_note"
else row warn "ssh keys" "none yet: add your laptop's public key to GitHub (Settings → SSH and GPG keys) and rerun, or paste it into the chat for ssh-key.sh; $sshd_note"; fi

# 4c. the pod's limits and volumes, the model, the checkout
vol() { local o; o=$(df -h --output=source,size,pcent "$1" 2>/dev/null | awk 'NR==2 { src=$1; if (src ~ /:/) src="a network volume"; else if (src ~ /^overlay/) src="the EPHEMERAL root"; print $2 " (" $3 " used, " src ")" }'); echo "${o:-not mounted}"; }
if read -r q p 2>/dev/null < /sys/fs/cgroup/cpu.max; then
  if [ "$q" = max ]; then cpus="no cpu limit"; else cpus="$(awk -v q="$q" -v p="$p" 'BEGIN {printf "%.2g", q/p}') cpu limit"; fi
else cpus="$(nproc 2>/dev/null || echo '?') cpu"; fi
mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "?")
case "$mem_max" in max) mem="no memory limit";; "?") mem="$(free -g 2>/dev/null | awk '/^Mem/ {print $2}') GiB";; *) mem="$(awk -v b="$mem_max" 'BEGIN {printf "%.1f", b/1073741824}') GiB limit";; esac
row info "pod" "$cpus · $mem · /workspace $(vol /workspace) · home $(vol "$HOME")"
model_now=${ANTHROPIC_MODEL:-}; [ -z "$model_now" ] && model_now="(unset: the Maestro default)"
row info "model" "ANTHROPIC_MODEL=$model_now — the launchers pin theirs per batch"
row info "repo" "$(git rev-parse --short HEAD 2>/dev/null || echo '?') on $(git branch --show-current 2>/dev/null || echo '?'); $(git status --short 2>/dev/null | wc -l) uncommitted"

# 5. the table — printed, and saved under .maestro/run/ (git-ignored) so an agent can read it back and
#    paste it into the chat: the web terminal neither pastes nor copies
mkdir -p .maestro/run 2>/dev/null; OUT=.maestro/run/pod-setup.txt
{ printf '%-6s %-22s %s\n' state step detail; printf '%-6s %-22s %s\n' ----- ---- ------; printf '%s\n' "${rows[@]}"; } | tee "$OUT" 2>/dev/null
[ -x orchestration/scripts/status.sh ] && { echo; bash orchestration/scripts/status.sh 2>&1 | tail -12 | tee -a "$OUT" 2>/dev/null; }
printf '%s\n' "${rows[@]}" | grep -q '^FAIL' && exit 1 || exit 0
