#!/usr/bin/env bash
# orchestration/scripts/status.sh -- "what is running right now, and is anything owed?"
#
# Answers, in one screen, the three questions the Maestro web UI cannot: is the ORCHESTRATOR
# thinking, waiting for a human, or gone; are any WORKER agents alive; and is anything still
# owed (a rented VM powered on, a branch unlanded, a dirty tree). Reads only; changes nothing.
#
# Verdict lines and their meaning:
#   WORKING           the orchestrator's own Claude process is alive and its transcript is growing
#   WAITING           alive, but the transcript has not moved -- it is waiting for a human turn
#   HALTED+WORKERS    no orchestrator, but worker agents are still running (they survive it)
#   HALTED            nothing of ours is running here
# Exit code: 0 all clear, 3 attention owed (halted with workers, a VM left powered on,
#            a STALE branch lock, a verification that ended `truncated`, or a VM row
#            left UNCHECKED because orchestration/local.env lacks the project or prefix).
#            The `inbox` row never moves it: an unhandled message is a warning.
set -uo pipefail
now=$(date -u +%s); attention=0
W=${WORKSPACE:-/workspace}
say() { printf '%-18s %s\n' "$1" "$2"; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$HERE/orch-env.sh"
orch_env_load "$W"
LOG=/dev/null
# shellcheck source=/dev/null
. "$HERE/batch-lib.sh"
PROJ=${CLOUDSDK_CORE_PROJECT:-${ORCH_GCP_PROJECT:-}}

# --- whose values this screen is using -------------------------------------
# FIRST, because every row below is read against it (task P-4). The same scripts
# run on a teammate's pod with that pod's orchestration/local.env, and a status
# screen that does not say which programme it is reporting for is one that can
# be read as yours when it is theirs.
say "programme" "${ORCH_PROJECT:-UNSET (ORCH_PROJECT)} -- repo ${ORCH_REPO_NAME:-?}, GCP ${PROJ:-UNSET (ORCH_GCP_PROJECT)}, machines ${ORCH_VM_PREFIX:-UNSET (ORCH_VM_PREFIX)}*; values from $ORCH_ENV_FILE_READ"

# --- the orchestrator -------------------------------------------------------
# BY ORCH_ROLE, NOT BY ARGV (8 October): the pgrep for "claude --session-id|
# --resume" that stood here named the chat conversation a RUNNING orchestrator
# on a pod where Maestro resumes it as `claude --resume <id>`. batch-lib.sh's
# batch_claude_pids is the one reader of the role: this row, the chat row below
# and the launchers' gate.
pid=$(batch_claude_pids orchestrator | head -1)
T=$(ls -t "$HOME"/.claude/projects/-workspace/*.jsonl 2>/dev/null | head -1)
idle=-1; [ -n "$T" ] && idle=$(( now - $(stat -c %Y "$T") ))
if [ -n "$pid" ]; then
    et=$(ps -o etimes= -p "$pid" | tr -d ' ')
    say "orchestrator" "RUNNING pid=$pid up=${et}s"
    [ "$idle" -ge 0 ] && [ "$idle" -lt 120 ] && verdict=WORKING || verdict=WAITING
else
    say "orchestrator" "not running"; verdict=HALTED
fi
[ -n "$T" ] && say "transcript" "$(basename "$T" .jsonl | cut -c1-8) idle=${idle}s size=$(stat -c %s "$T")B"
say "pod tmux" "$(tmux -S /tmp/tmux-shared/maestro.sock ls 2>/dev/null | wc -l) session(s)"

# --- the chat conversation --------------------------------------------------
# THE ROW 30 SEPTEMBER NEEDED. Asked in Slack whether it was the single
# orchestrator, the Maestro session's chat conversation said yes, and this
# screen said nothing either way: the chat conversation runs as `claude -r` or
# `claude --resume`, Maestro's choice by version, and between messages it
# is no process at all, because Maestro resumes it for each one. A `claude`
# without ORCH_ROLE in its environment was started by neither launcher nor
# spawn-agent.sh: it is the chat conversation answering a message, or a claude
# somebody started by hand (orchestration/CHAT.md).
chat=$(batch_claude_pids none | sed 's/^/ /' | tr -d '\n')
if [ -n "$chat" ]; then
    say "chat conversation" "answering now, no ORCH_ROLE: pid$chat (the Maestro session's chat, or a claude started by hand)"
else
    say "chat conversation" "not running (Maestro resumes it for each message; orchestration/CHAT.md)"
fi

# --- WHO OWNS THIS BATCH ----------------------------------------------------
# THE ROW THE 18 SEPTEMBER COLLISION NEEDED AND DID NOT HAVE. `pgrep` above
# answers "is A claude running"; this answers "is the process that IS this
# batch running, and which session is it". Two orchestrators ran batch B3 for
# 31 minutes and nothing on any screen said so. Both launchers refuse on a live
# owner, and the batch prompt tells the orchestrator to read THIS row first and
# stop if it names somebody else.
if [ -r "$HERE/batch-lib.sh" ]; then
    if batch_owner_alive "$W/.maestro/orchestrator.pid"; then
        say "orchestrator owner" "LIVE pid=$BATCH_OWNER_PID session=$(printf '%s' "$BATCH_OWNER_SID" | cut -c1-8)"
    elif [ -r "$W/.maestro/orchestrator.pid" ]; then
        say "orchestrator owner" "none live (last: $(tr -d '\n' < "$W/.maestro/orchestrator.pid" | cut -c1-45))"
    else
        say "orchestrator owner" "no .maestro/orchestrator.pid -- no launcher has run here"
    fi
    # `-r` and not `2>/dev/null` on the `tr`: the `<` fails before the redirection
    # of stderr is set up, and printed "No such file" on every pod no launcher used.
    sess=""
    [ -r "$W/.maestro/orchestrator-session" ] && sess=$(tr -d '[:space:]' < "$W/.maestro/orchestrator-session")
    [ -n "$sess" ] && say "batch session" "$(printf '%s' "$sess" | cut -c1-8) -> batch $(batch_session_batch "$W/.maestro/orchestrator-sessions.log" "$sess" 2>/dev/null || echo '?')"

    # --- the researcher's messages nobody has acted on -----------------------
    # THE ROW 30 SEPTEMBER NEEDED NEXT. A message the platform acknowledged as
    # "Queued" reached no conversation, and nothing here recorded it had been
    # sent; the chat now writes every message to INBOX.md first (CHAT.md), and
    # this row is what makes an unhandled one visible to whoever looks, whether
    # chat, orchestrator or researcher. A WARNING, NEVER ATTENTION: exit 3 means a
    # machine or a worker is owed, and a message is the batch close's to drain
    # (docs/OPERATING.md section 1, step 8; state-check.sh fails a close that
    # leaves one).
    inbox="$W/orchestration/INBOX.md"
    batch_inbox_scan "$inbox"
    case $? in
        0) if [ "$INBOX_NEW" -eq 0 ]; then
               say "inbox" "ok -- 0 new of $INBOX_ENTRIES entries ($inbox)"
           else
               say "inbox" "warn -- $INBOX_NEW new of $INBOX_ENTRIES, oldest $INBOX_OLDEST (line $INBOX_OLDEST_LINE of $inbox): nobody has acted on it; a batch's close drains it"
           fi ;;
        1) say "inbox" "warn -- NOT READ, malformed: $INBOX_ERROR ($inbox; state-check.sh fails on this)" ;;
        *) say "inbox" "none -- no $inbox" ;;
    esac
fi

# --- branch locks and the latest verification -------------------------------
# A LOCK IS A THING SOMEBODY IS DOING, so it belongs on the screen that says
# what is running. A lock whose pid is dead is reported as STALE rather than
# hidden: it is the signature of a killed verification, and it names the branch
# whose result file is worth reading with `verify-detached.sh --report`.
locks=""
for d in "$W"/.maestro/lock/*/; do
    [ -d "$d" ] || continue
    lt=$(basename "$d"); lp=$(tr -dc '0-9' < "$d/pid" 2>/dev/null)
    if [ -d "/proc/$lp" ] && [ -n "$(tr -d '\0' < "/proc/$lp/cmdline" 2>/dev/null)" ]; then
        locks="$locks $lt=pid$lp"
    else
        locks="$locks $lt=STALE(pid${lp:-?})"; attention=1
    fi
done
[ -n "$locks" ] && say "branch locks" "${locks# }"

# THE VERDICT OF THE LAST VERIFICATION OF EACH BRANCH, read through
# `verify-detached.sh --report` rather than grepped here, so `truncated` means
# the same thing on this screen as it does everywhere else. A truncated run
# measured NOTHING; reporting it as a pass or a fail is the B3 mistake.
for ptr in "${VERIFY_OUT_DIR:-/tmp}"/verify-*.latest; do
    [ -e "$ptr" ] || continue
    vb=$(basename "$ptr" .latest); vb=${vb#verify-}
    vline=$(bash "$HERE/verify-detached.sh" --report "$vb" 2>/dev/null | sed -n 's/^VERIFY_VERDICT=//p')
    case "$vline" in
        truncated*) attention=1 ;;
    esac
    [ -n "$vline" ] && printf '  %-18s %s\n' "verify $vb" "$(printf '%s' "$vline" | cut -c1-90)"
done

# --- worker agents ----------------------------------------------------------
live=0; total=0
for f in "$W"/.maestro/run/*.status; do
    [ -e "$f" ] || continue
    total=$((total+1)); n=$(basename "$f" .status); s=$(tr '\t' ' ' < "$f")
    l="$W/.maestro/logs/$n.jsonl"; la=-1; [ -f "$l" ] && la=$(( now - $(stat -c %Y "$l") ))
    case "$s" in running*) live=$((live+1)); mark="LIVE " ;; *) mark="done " ;; esac
    printf '  %s%-28s %-22s log_idle=%ss\n' "$mark" "$n" "$s" "$la"
done
[ "$total" -eq 0 ] && say "workers" "none ever spawned in this container"
[ "$total" -gt 0 ] && say "workers" "$live live of $total"
[ "$verdict" = HALTED ] && [ "$live" -gt 0 ] && { verdict=HALTED+WORKERS; attention=1; }

# --- what is owed -----------------------------------------------------------
git -C "$W" fetch -q origin 2>/dev/null
say "git HEAD" "$(git -C "$W" log --oneline -1 2>/dev/null | cut -c1-58)"
dirty=$(git -C "$W" status --short 2>/dev/null | wc -l)
unlanded=$(git -C "$W" branch -r --no-merged origin/master 2>/dev/null | grep -v HEAD | wc -l)
say "git working tree" "$dirty dirty file(s), $unlanded unlanded remote branch(es)"
# OURS AND THEIRS, SEPARATELY, because this row used to make the whole screen
# say "attention owed" for machines nobody here can switch off:
# `rl-playground-gpu` has been RUNNING since 14 September and is not ours, and
# neither is `ai-research-webrtc`. A verdict that is permanently red is a
# verdict people stop reading -- and it would bury the token row below. The
# ownership test is the name prefix $ORCH_VM_PREFIX, the same one
# scripts/gcp-janitor.sh and state-check.sh use: ours is what we can be asked to
# account for. WITHOUT A PROJECT OR A PREFIX THE QUESTION IS NOT ASKED, and the
# row says which key is missing: "none powered on" from a guessed project would
# be a false all-clear.
if orch_require ORCH_VM_PREFIX 2>/dev/null && [ -n "$PROJ" ]; then
    vms=$(timeout 60 gcloud compute instances list --project "$PROJ" \
            --filter='status!=TERMINATED' --format='value(name,status)' 2>/dev/null)
    ours=$(printf '%s\n' "$vms" | orch_vm_filter | tr '\t' '=' | tr '\n' ' ')
    theirs=$(printf '%s\n' "$vms" | orch_vm_filter --theirs | tr '\t' '=' | tr '\n' ' ')
    if [ -n "$ours" ]; then say "OUR VMs powered on" "$ours"; attention=1; else say "our VMs" "none powered on"; fi
    [ -n "$theirs" ] && say "other people's VMs" "$theirs (reported, not ours to stop)"
else
    say "our VMs" "UNCHECKED -- $( [ -n "$PROJ" ] || printf 'ORCH_GCP_PROJECT ')$( [ -n "${ORCH_VM_PREFIX:-}" ] || printf 'ORCH_VM_PREFIX ')not set (orchestration/local.env)"
    attention=1
fi

# --- which Claude account is this pod on? -----------------------------------
# A ROW HERE BECAUSE THE ANSWER IS OTHERWISE INVISIBLE. A pod restart
# re-injects ~/.maestro/claude_token from the session record, which holds the
# token the session was CREATED with; on 17 September that silently moved the
# whole afternoon onto a Pro account, and every symptom -- no Fable, a short
# window, "requires usage credits" -- reads as a usage problem rather than as
# the wrong identity. `status.sh` is the screen a human looks at when something
# is odd, so this is where the answer belongs. MISMATCH is attention owed: the
# remedy is manual (docs/LESSONS.md) and nothing downstream can work around it.
if [ -r "$HERE/token-guard.sh" ]; then
    # shellcheck source=/dev/null
    . "$HERE/token-guard.sh"
    token_guard_evaluate
    say "claude token" "$TOKEN_GUARD_STATE -- $TOKEN_GUARD_DETAIL"
    [ "$TOKEN_GUARD_STATE" = MISMATCH ] && attention=1
else
    say "claude token" "unchecked -- token-guard.sh is not beside this script"
fi

printf '\nVERDICT: %s%s\n' "$verdict" "$([ "$attention" = 1 ] && echo '  (attention owed -- see above)')"
[ "$attention" = 1 ] && exit 3 || exit 0
