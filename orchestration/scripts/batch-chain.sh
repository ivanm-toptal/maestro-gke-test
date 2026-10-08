#!/usr/bin/env bash
# batch-chain.sh <id> [<id>...] — run a batch to its quiet point, then start the
# next one, with nobody watching.
#
# WHAT IT REPLACES. Three hand-written files in /tmp on this pod --
# `batch-chain.sh`, `batch-chain2.sh`, `batch-chain3.sh`, written by the
# researcher on 18 and 20 September for unattended evenings. They worked, and
# the shape below is theirs. What was wrong with them was not the logic: it was
# that they lived in /tmp, which `tmpfiles.d` empties at every boot; that each
# was a copy of the last with one clause changed; and that two of them were
# armed at once and both tried to start B4, which only the launcher's own gate
# stopped. An unattended evening should not need a file nobody else can read.
#
# WHAT IT DOES NOT DO, and this is the whole safety argument. It calls the
# COMMITTED launchers and nothing else. It does not write docs/STATE.md, it does
# not touch `.maestro/orchestrator-session`, it does not land, spawn, verify or
# decide anything about a batch. Every refusal that protects a batch still comes
# from `batch-start.sh`'s own gates, which is where it can be reasoned about.
# The single thing it changes in the repository is an optional `git pull
# --ff-only` before a start (--no-pull turns it off), because `state-check.sh`'s
# "clean and pushed" row fails on a master that is merely behind, and a chain
# that refused every start for that reason would be a chain nobody armed twice.
#
# SETTLING, AND WHY IT RESUMES AT ALL. A launcher exits when its conversation
# ends, and a conversation can end with work still running: that is the print-mode
# failure in docs/LESSONS.md, where an orchestrator says it is "waiting for the
# background task" and its process exits. The batch is not over then -- workers
# are still going and nobody is reading them. So: wait for the launcher to exit;
# if a worker is still running, `batch-resume.sh` puts a process back on the
# conversation; at most three times, because a fourth would be a loop rather
# than a rescue, and a chain that spins for ever fails invisibly.
#
# ONE CHAIN AT A TIME. It takes the same mkdir lock the rest of this directory
# uses (orchestration/scripts/run-lock.sh), under the tag `batch-chain`. Two
# chains armed at once is not hypothetical: it happened on 20 September.
#
# Usage:
#   batch-chain.sh <id> [<id>...]   settle what is running, then start each id in turn
#   batch-chain.sh --settle-only    settle what is running and stop
#   batch-chain.sh --dry-run <id>…  print the plan, call no launcher
#
# Detached, which is how an unattended evening arms it (docs/OPERATING.md §0):
#   setsid nohup bash orchestration/scripts/batch-chain.sh B5 B6 < /dev/null > /dev/null 2>&1 &
#   tail -f /workspace/.maestro/run/chain.log
#
# Environment:
#   BATCH_ROOT            the repository            (default /workspace)
#   CHAIN_POLL            seconds between polls     (default 120)
#   CHAIN_MAX_RESUMES     resumes per batch         (default 3)
#   CHAIN_SCRIPTS         where the launchers are   (default beside this script)
#
# Exit codes: 0 every id ran / 2 usage / 3 a launcher refused, or a batch would
#             not settle / 4 another chain holds the lock

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
ROOT="${BATCH_ROOT:-/workspace}"
#: SEPARATELY OVERRIDABLE so the tests can point the chain at stub launchers and
#: exercise the settle/resume/start sequence without minting a session or
#: spending a penny. Every other script in this directory takes its root the
#: same way, for the same reason.
SCRIPTS="${CHAIN_SCRIPTS:-$HERE}"
POLL="${CHAIN_POLL:-120}"
MAX_RESUMES="${CHAIN_MAX_RESUMES:-3}"

cd "$ROOT" || { printf 'batch-chain: cannot cd to %s\n' "$ROOT" >&2; exit 2; }
# shellcheck source=/dev/null
. "$HERE/run-lock.sh"
# shellcheck source=/dev/null
LOG=/dev/null . "$HERE/batch-lib.sh"

RUNDIR="$ROOT/.maestro/run"
CHAIN_LOG="$RUNDIR/chain.log"
PID_FILE="${BATCH_PID_FILE:-$ROOT/.maestro/orchestrator.pid}"

ids=() dry=0 settle_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --settle-only) settle_only=1; shift ;;
        --dry-run)     dry=1; shift ;;
        -h|--help)     sed -n '/^# Usage:/,/^# Exit codes/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --no-pull)     no_pull=1; shift ;;
        --*)           printf 'batch-chain: unknown flag: %s\n' "$1" >&2; exit 2 ;;
        *)             ids+=("$1"); shift ;;
    esac
done
no_pull="${no_pull:-0}"

if [ "$settle_only" = 0 ] && [ "${#ids[@]}" -eq 0 ]; then
    printf 'batch-chain: which batches? batch-chain.sh <id> [<id>...], or --settle-only\n' >&2
    exit 2
fi

mkdir -p "$RUNDIR"
log() {  # one line, to the chain log and to stdout
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$CHAIN_LOG"
}

# ---------------------------------------------------------------------------
# What is running
# ---------------------------------------------------------------------------
#: An orchestrator is running if the owner file names a live `claude`, or if the
#: broad pgrep sees one. BOTH, because the owner file is new: a launcher started
#: before it existed, or by hand, leaves no owner record and would otherwise be
#: invisible to this chain.
#:
#: The pgrep pattern is bracketed so it cannot match this script's own argv --
#: `pgrep -f` matches the shell that runs it (docs/LESSONS.md), and a chain that
#: waited for itself would wait for ever.
orchestrator_running() {
    batch_owner_alive "$PID_FILE" && return 0
    pgrep -u "$(id -u)" -f "claude --(session-id|resume) [0-9a-f]{8}-" >/dev/null 2>&1
}

launcher_running() {
    pgrep -u "$(id -u)" -f "[b]atch-(start|resume)\.sh" >/dev/null 2>&1
}

#: `running` AS THE FIRST FIELD, the same test state-check.sh makes: a status
#: line reading `killed … note=the runner was still running` mentions the word
#: and is precisely not a running worker.
workers_running() {
    local f
    for f in "$RUNDIR"/*.status; do
        [ -e "$f" ] || continue
        case "$(head -1 "$f")" in running*) return 0 ;; esac
    done
    return 1
}

live_workers() {
    local f out=""
    for f in "$RUNDIR"/*.status; do
        [ -e "$f" ] || continue
        case "$(head -1 "$f")" in running*) out="$out $(basename "$f" .status)" ;; esac
    done
    printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# settle: this batch is over when no process is driving it and no worker runs
# ---------------------------------------------------------------------------
settle() {  # settle <label>
    local label=$1 tries=0 rc

    while orchestrator_running || launcher_running; do
        log "$label: an orchestrator is still running; waiting ${POLL}s"
        sleep "$POLL"
    done
    log "$label: no orchestrator is running"

    while workers_running; do
        tries=$((tries + 1))
        if [ "$tries" -gt "$MAX_RESUMES" ]; then
            log "$label: workers still running after $MAX_RESUMES resume(s) ($(live_workers)) -- STOPPING THE CHAIN"
            log "$label: a human is needed; nothing further will be started"
            return 1
        fi
        log "$label: worker(s) running with nobody driving ($(live_workers)); resuming, attempt $tries of $MAX_RESUMES"
        if [ "$dry" = 1 ]; then
            log "$label: DRY RUN -- batch-resume.sh not called"
            return 0
        fi
        bash "$SCRIPTS/batch-resume.sh" >> "$RUNDIR/chain-resume.log" 2>&1
        rc=$?
        log "$label: batch-resume.sh exited rc=$rc"
        # A REFUSAL IS NOT A RETRY. batch-resume.sh refuses on a token mismatch,
        # a live orchestrator or an ended batch, and every one of those means
        # this chain has misread the situation rather than that it should try
        # again in a minute.
        if [ "$rc" -eq 3 ]; then
            log "$label: the resume was REFUSED by a gate (rc=3) -- see $RUNDIR/chain-resume.log. Stopping."
            return 1
        fi
        sleep "$POLL"
    done
    log "$label: settled -- no orchestrator, no worker"
    return 0
}

# ---------------------------------------------------------------------------
# The chain
# ---------------------------------------------------------------------------
RUN_LOCK_WHAT="batch-chain ${ids[*]:-settle-only}"
export RUN_LOCK_WHAT
if ! run_lock_acquire "$ROOT" batch-chain "$$" 0; then
    printf 'batch-chain: REFUSED -- another chain is armed on this pod.\n' >&2
    printf '  %s\n' "$RUN_LOCK_DETAIL" >&2
    printf '  Two chains were armed at once on 20 September and both tried to start B4.\n' >&2
    exit 4
fi
trap 'run_lock_release "$ROOT" batch-chain "$$" >/dev/null 2>&1 || true' EXIT

log "chain armed: settle what is running, then start ${ids[*]:-nothing} (poll ${POLL}s, ${MAX_RESUMES} resume(s) max)"
[ "$dry" = 1 ] && log "DRY RUN: no launcher will be called"

settle "current" || exit 3
[ "$settle_only" = 1 ] && { log "chain done (--settle-only)"; exit 0; }

for id in "${ids[@]}"; do
    if [ "$no_pull" = 0 ]; then
        # THE ONE MUTATION, and it is a fast-forward or nothing. state-check.sh's
        # last row fails on a master that is behind origin, so a chain that never
        # pulled would refuse every start on a pod that had merely not caught up.
        if [ "$dry" = 1 ]; then
            log "$id: DRY RUN -- git pull --ff-only not called"
        elif git pull -q --ff-only origin master 2>>"$CHAIN_LOG"; then
            log "$id: master fast-forwarded to $(git log --oneline -1 | cut -c1-60)"
        else
            log "$id: master would not fast-forward -- not pulling; batch-start.sh's gate decides"
        fi
    fi

    log "$id: starting via batch-start.sh --batch $id"
    if [ "$dry" = 1 ]; then
        log "$id: DRY RUN -- batch-start.sh not called"
    else
        bash "$SCRIPTS/batch-start.sh" --batch "$id" >> "$RUNDIR/chain-$id.launch.log" 2>&1
        rc=$?
        log "$id: batch-start.sh exited rc=$rc (log: $RUNDIR/chain-$id.launch.log)"
        # A GATE REFUSAL ENDS THE CHAIN. batch-start.sh exits 3 when the state is
        # not one a batch may begin on -- a stale STATE.md, a live orchestrator, a
        # worker still running, a machine left powered on. None of those gets
        # better by starting the NEXT id on top of it.
        if [ "$rc" -eq 3 ]; then
            log "$id: REFUSED by a gate (rc=3). The remaining ids are not started; see the log above."
            exit 3
        fi
    fi

    settle "$id" || exit 3
done

log "chain done: ${ids[*]}"
