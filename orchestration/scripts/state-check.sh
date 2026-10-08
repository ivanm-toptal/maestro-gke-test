#!/usr/bin/env bash
# state-check.sh — is docs/STATE.md still true about this repository?
#
# THE PROBLEM IT SOLVES. The batch procedure (docs/OPERATING.md) rests on one
# claim: a session can be reset because everything worth keeping is in the
# documents. That claim is only as good as the documents, and a document drifts
# silently -- a landing nobody added to section 2, a worker section 3 still calls
# running, a VM left on, a brief named in section 4 that does not exist. None of
# those is visible to a reader, because a stale STATE.md reads exactly like a
# fresh one. This script is the mechanical half of the reset contract: it asks
# the repository, the run directory, Compute Engine and the session record the
# six questions whose answers STATE.md asserts, and fails when an answer differs.
#
# It is called TWICE per batch and both calls matter. `batch-start.sh` runs it
# before starting: a batch begins on a clean state or not at all. The
# orchestrator runs it before ending: a batch that ends on a stale STATE.md has
# not ended, because the next session will read that file and believe it.
#
# WHAT IT DOES NOT DO. It does not judge prose. Sections 1, 5, 6 and 7 are the
# orchestrator's account of where things are, and no script can check them --
# the reset DRILL does that half (`batch-start.sh --drill`), by having a fresh
# session describe the state from the documents alone so a human can compare.
# What is checkable here is exactly what is countable.
#
# THE CONVENTIONS IT READS. STATE.md is prose with four machine-readable
# anchors, all of them visible to a human reader on purpose (an HTML comment
# would be invisible in the rendered document and would rot unnoticed):
#
#   **Last reset:** <date>, batch <ID>, at commit `<hash>`.   the reset point
#   ## 2. ...                merge hashes landed since that commit
#   ## 3. ...                `**Batch <ID>: running|ended**` and `- Workers: ...`
#   ## 4. ...                `### Batch <ID>` blocks naming `<brief>.md` files
#
# docs/OPERATING.md section 4 is the human statement of the same contract.
#
# Usage:
#   state-check.sh                 the six checks, one row each
#   state-check.sh --no-vm         skip the Compute Engine read (offline, or no
#                                  project to read: STATE_CHECK_NO_VM_REASON says why)
#   state-check.sh --quiet         rows only on failure
#
# Environment:
#   STATE_CHECK_ROOT   the repository to check       (default /workspace)
#   STATE_CHECK_RUNDIR the worker status directory   (default $STATE_CHECK_ROOT/.maestro/run)
#   CLOUDSDK_CORE_PROJECT  the project to look in    (default ORCH_GCP_PROJECT)
#   ORCH_GCP_PROJECT, ORCH_VM_PREFIX   from <root>/orchestration/local.env
#                      (orch-env.sh; the environment wins). No default: without
#                      them check 3 FAILS naming the key, and --no-vm skips it.
#   STATE_CHECK_NO_VM_REASON  with --no-vm, the reason printed on the skipped row.
#                      batch-start.sh sets it when no brief of the batch declares
#                      machines and no GCP project is recorded (task P-5).
#
# THE RUN DIRECTORY IS SEPARATELY OVERRIDABLE because it is the one input that
# does NOT live in the repository. `.maestro/run/` is git-ignored per-container
# litter belonging to the checkout at /workspace, and a git WORKTREE -- which is
# how every worker gets its own tree -- shares the object store but not that
# directory. So a worker checking the STATE.md on its own branch against the
# container's real workers points this at /workspace/.maestro/run; the
# orchestrator, running at /workspace, never needs it.
#
# Exit codes: 0 every check passed / 1 a check failed / 2 usage

set -uo pipefail

#: batch-lib.sh, for the ONE definition of what a brief name looks like and the
#: ONE reader of section 3's anchor. Both questions are asked by the launchers
#: too, and a second copy of either would drift from this one silently.
STATE_CHECK_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$STATE_CHECK_HERE/batch-lib.sh"

ROOT="${STATE_CHECK_ROOT:-/workspace}"
orch_env_load "$ROOT"
PROJECT="${CLOUDSDK_CORE_PROJECT:-${ORCH_GCP_PROJECT:-}}"
STATE="$ROOT/docs/STATE.md"
BRIEFS="$ROOT/orchestration/briefs"
RUNDIR="${STATE_CHECK_RUNDIR:-$ROOT/.maestro/run}"

do_vm=1 quiet=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-vm)  do_vm=0; shift ;;
        --quiet)  quiet=1; shift ;;
        -h|--help) sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'state-check: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# The rows
# ---------------------------------------------------------------------------
# Accumulated as `state<TAB>check<TAB>detail` and printed together at the end,
# for the same reason bootstrap-session.sh does it: one round trip instead of
# five when the session is remote. FIRST_FAILURE is kept separately because the
# brief asks the script to NAME the first failure rather than leave a human to
# scan for it -- a check list whose verdict is a count is a check list people
# stop reading.
ROWS=()
failed=0
FIRST_FAILURE=""

row() {  # row <ok|FAIL|warn|skip> <check> <detail>
    ROWS+=("$1	$2	$3")
    if [ "$1" = FAIL ]; then
        failed=$((failed + 1))
        [ -z "$FIRST_FAILURE" ] && FIRST_FAILURE="$2: $3"
    fi
    return 0
}

#: STATE.md's "## <n>." block, heading excluded. Stops at the next `## `, so a
#: `### Batch B1` sub-heading inside section 4 stays part of section 4.
section() {
    awk -v n="$1" '
        $0 ~ "^## " n "\\." { inside = 1; next }
        /^## /              { inside = 0 }
        inside              { print }
    ' "$STATE"
}

if [ ! -r "$STATE" ]; then
    printf 'state-check: no readable %s\n' "$STATE" >&2
    exit 1
fi
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'state-check: %s is not a git repository\n' "$ROOT" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Every merge since the last reset is named in section 2
# ---------------------------------------------------------------------------
# The check that catches the expensive drift: a landing that happened and was
# never written down. The next orchestrator reads section 2, does not see it,
# and either redoes the work or reasons from a master it does not know about.
#
# MATCHED BY PREFIX, NOT BY EQUALITY. Section 2 is written by a human (or by an
# orchestrator quoting `git log --oneline`) and carries SHORT hashes of whatever
# length git chose that day. Comparing a 40-character commit id against a
# 7-character one by string equality would fail every single time, so each merge
# is looked for as a prefix of any hex token in the section.
#
# `--first-parent`, AND THE CHECK IS WRONG WITHOUT IT. A plain `--merges` walk
# also returns the "Merge origin/master into <branch>" commits a worker makes to
# refresh its own branch -- five of them between 16 and 17 September -- which are
# not landings, were never announced, and have no business in section 2. Asking
# for them would make the check fail on a correct document, and a check that
# cries wolf is a check the orchestrator learns to skip. Walking only the first
# parent asks the question actually being asked: what landed ON master.
reset_line=$(grep -m1 '^\*\*Last reset:\*\*' "$STATE" 2>/dev/null)
reset=$(printf '%s' "$reset_line" | sed -nE 's/.*`([0-9a-f]{7,40})`.*/\1/p' | head -1)

if [ -z "$reset" ]; then
    row FAIL "reset commit" "STATE.md has no '**Last reset:** … at commit \`<hash>\`.' line"
elif ! git -C "$ROOT" rev-parse --verify -q "${reset}^{commit}" >/dev/null 2>&1; then
    row FAIL "reset commit" "STATE.md names $reset, which is not a commit in this repository"
else
    # `origin/master` and not `master`: the question is what LANDED, and a local
    # master that has not been fetched is this container's opinion, not the
    # programme's. batch-start.sh and status.sh both fetch before calling.
    ref=origin/master
    git -C "$ROOT" rev-parse --verify -q "$ref" >/dev/null 2>&1 || ref=master
    sec2=$(section 2)
    tokens=$(printf '%s' "$sec2" | grep -oE '\b[0-9a-f]{7,40}\b' | sort -u)
    missing=""
    count=0
    while read -r merge; do
        [ -n "$merge" ] || continue
        count=$((count + 1))
        found=0
        for tok in $tokens; do
            case "$merge" in "$tok"*) found=1; break ;; esac
        done
        [ "$found" = 0 ] && missing="$missing $(printf '%s' "$merge" | cut -c1-7)"
    done <<< "$(git -C "$ROOT" log --first-parent --format='%H' --merges "${reset}..${ref}" 2>/dev/null)"

    if [ -n "$missing" ]; then
        row FAIL "landings in §2" "$ref has merge(s) since ${reset} that §2 does not name:$missing"
    else
        row ok "landings in §2" "$count merge(s) since ${reset}, all named"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Section 3's account of the workers matches .maestro/run/
# ---------------------------------------------------------------------------
# BOTH DIRECTIONS, because both have happened. A worker running that STATE does
# not mention is a batch that cannot be reset (the next session would spawn over
# it). A worker STATE calls running that is not is the 17 September case: the pod
# restart left two `.status` files saying `running` for processes that were gone,
# and `status.sh` reported them live until they were rewritten by hand.
#
# The convention in section 3 is one line:
#     - Workers: none running.
#     - Workers: running — `d-1`, `d-2`.
claimed=""
workers_line=$(printf '%s' "$(section 3)" | grep -m1 -E '^[[:space:]]*-[[:space:]]*Workers:')
if [ -z "$workers_line" ]; then
    row FAIL "workers in §3" "§3 has no '- Workers: …' line"
else
    if ! printf '%s' "$workers_line" | grep -qi 'none running'; then
        claimed=$(printf '%s' "$workers_line" | grep -oE '`[A-Za-z0-9._-]+`' | tr -d '`' | sort -u)
    fi
    actual=""
    if [ -d "$RUNDIR" ]; then
        for f in "$RUNDIR"/*.status; do
            [ -e "$f" ] || continue
            # `running` as the FIRST field only. `killed … note=…` mentions the
            # word and is precisely not a running worker.
            case "$(head -1 "$f")" in
                running*) actual="$actual$(basename "$f" .status)
" ;;
            esac
        done
    fi
    actual=$(printf '%s' "$actual" | grep -v '^$' | sort -u)

    only_real=$(comm -13 <(printf '%s\n' $claimed | grep -v '^$' | sort -u) \
                         <(printf '%s\n' $actual  | grep -v '^$' | sort -u) | tr '\n' ' ')
    only_state=$(comm -23 <(printf '%s\n' $claimed | grep -v '^$' | sort -u) \
                          <(printf '%s\n' $actual  | grep -v '^$' | sort -u) | tr '\n' ' ')
    only_real=$(printf '%s' "$only_real" | sed 's/[[:space:]]*$//')
    only_state=$(printf '%s' "$only_state" | sed 's/[[:space:]]*$//')

    if [ -n "$only_real" ] && [ -n "$only_state" ]; then
        row FAIL "workers in §3" "running but not in §3: $only_real; in §3 but not running: $only_state"
    elif [ -n "$only_real" ]; then
        row FAIL "workers in §3" "running but not named in §3: $only_real"
    elif [ -n "$only_state" ]; then
        row FAIL "workers in §3" "§3 calls these running, and they are not: $only_state"
    else
        n=$(printf '%s' "$actual" | grep -c . )
        row ok "workers in §3" "$n running, and §3 says so"
    fi
fi

# ---------------------------------------------------------------------------
# 3. No machine of OURS is powered on
# ---------------------------------------------------------------------------
# THE NAME PREFIX ($ORCH_VM_PREFIX) IS THE OWNERSHIP TEST, and the brief is explicit that other
# people's machines are REPORTED and not failed. `rl-playground-gpu` has been
# running since 14 September and is not ours; a check that failed on it would be
# a check the orchestrator learns to pass with --no-vm, which is worse than no
# check. The janitor's own rule is the same one (`scripts/gcp-janitor.sh` touches
# only machines carrying the programme's purpose label).
#
# NO PROJECT OR NO PREFIX IS A FAILED CHECK (task P-4), for the same reason as an
# unanswered gcloud call: "nothing of ours is on" is a claim, and without the
# two keys this script cannot make it about anybody's programme.
if [ "$do_vm" = 1 ]; then
    if [ -z "$PROJECT" ] || [ -z "${ORCH_VM_PREFIX:-}" ]; then
        row FAIL "our machines off" "$( [ -n "$PROJECT" ] || printf 'ORCH_GCP_PROJECT ')$( [ -n "${ORCH_VM_PREFIX:-}" ] || printf 'ORCH_VM_PREFIX ')not set -- orchestration/local.env"
    elif ! command -v gcloud >/dev/null 2>&1; then
        row FAIL "our machines off" "gcloud NOT ON PATH -- the GCP connector is gone"
    else
        vm_out=$(timeout 60 gcloud compute instances list --project "$PROJECT" \
                   --filter='status!=TERMINATED' --format='value(name,status)' 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            # AN UNANSWERED QUESTION IS A FAILED CHECK, not a passed one. The
            # janitor lesson in docs/LESSONS.md is exactly this: an exit code is
            # not evidence unless the gcloud call succeeded.
            row FAIL "our machines off" "gcloud failed (rc=$rc): $(printf '%s' "$vm_out" | head -1 | cut -c1-58)"
        else
            ours=$(printf '%s\n' "$vm_out" | orch_vm_filter | tr '\t' '=' | tr '\n' ' ')
            theirs=$(printf '%s\n' "$vm_out" | orch_vm_filter --theirs | tr '\t' '=' | tr '\n' ' ')
            if [ -n "$ours" ]; then
                row FAIL "our machines off" "powered on: $ours"
            else
                row ok "our machines off" "no ${ORCH_VM_PREFIX}* instance is other than TERMINATED"
            fi
            [ -n "$theirs" ] && row warn "other machines" "not ours, reported only: $theirs"
        fi
    fi
else
    # A SKIP SAYS WHY (task P-5). batch-start.sh skips this check when no brief of
    # the batch declares machines and no GCP project is recorded, and a bare
    # "SKIPPED" row cannot be told apart from somebody switching the check off to
    # get past it. The reason is the caller's; the row is `skip`, never `ok`.
    row skip "our machines off" "${STATE_CHECK_NO_VM_REASON:-SKIPPED (--no-vm) -- this check did not run}"
fi

# ---------------------------------------------------------------------------
# 4. Section 4 names a brief that exists
# ---------------------------------------------------------------------------
# The cheapest of the five and the one that fails most often: a batch plan is
# written from memory, a brief is renamed or never committed, and the next
# session's first action is a file-not-found. At least ONE has to resolve -- the
# check is that section 4 is connected to the repository at all, not that every
# future brief has been written yet (batch B2's often have not).
# IT READS BRIEF NAMES, NOT EVERY MARKDOWN NAME IN THE PROSE, and the
# difference is a row that lied for two batches. Section 4 is written for
# humans: its task descriptions cite other documents, and the old
# `grep -oE '`[^`]+\.md`' ` swept all of them up. On the B3 block it reported
# "not yet written: CLAUDE.md README.md" -- P-2's task was ABOUT those two
# files -- and on B4's it reported "8 of 11 … CLAUDE.md 2026-09-17.md
# OPERATING.md", none of which is a brief and none of which anyone was meant
# to write. A row that names phantom missing files is a row the orchestrator
# learns to skim, and this is the row that catches a batch plan pointing at a
# brief nobody committed.
#
# Two restrictions, and each one is needed for a case the other misses:
#
#   ONLY INSIDE A `### Batch <id>` BLOCK. Section 4 also holds the
#   "### Unscheduled" list of proposals, which is prose about the repository
#   and cites files freely; `CLAUDE.md` and `bench/results/reset-drill/2026-09-17.md`
#   are both in there today.
#
#   ONLY BRIEF-SHAPED NAMES. `docs/OPERATING.md` is cited INSIDE the B4 block
#   (D-14's item points at the rule it takes its skip from), so the block
#   restriction alone does not catch it. A brief is named `<task-id>-<role>.md`
#   -- `D-17-full.md`, `D-17-pod.md`, `P-3-full.md`, `A-S-full.md`,
#   `23-continue.md`, `D-evidence-note.md` -- so the shape is: a task id of one
#   to four characters that either starts with a letter or is one or two
#   digits, then at least one `-<part>`, then `.md`, and no `/` anywhere.
#   Measured against the 151 files in orchestration/briefs/ on 21 September: it
#   accepts 149 and rejects `TEMPLATE.md` (never a queue item) and
#   `r31r-continue.md`. It rejects `CLAUDE.md` and `README.md` (no hyphen),
#   `docs/OPERATING.md` (a path) and `2026-09-17.md` (a four-digit first
#   segment, i.e. a date rather than a task).
#
# The row NAMES what it found, both ways, because a count on its own cannot be
# checked against the batch plan a human just wrote.
sec4=$(section 4)
batch_blocks=$(printf '%s\n' "$sec4" | awk '
    /^### Batch /  { inside = 1; print; next }
    /^### /        { inside = 0 }
    inside         { print }
')
named=$(printf '%s' "$batch_blocks" | batch_briefs_in_block)
present="" absent=""
for b in $named; do
    if [ -f "$BRIEFS/$b" ]; then
        present="$present $b"
    else
        absent="$absent $b"
    fi
done
if [ -z "$named" ]; then
    row FAIL "briefs in §4" "no \`<task-id>-<role>.md\` brief is named in any '### Batch' block of §4"
elif [ -z "$present" ]; then
    row FAIL "briefs in §4" "none of §4's briefs exist in orchestration/briefs/:$absent"
else
    n=$(printf '%s' "$present" | wc -w)
    detail="$n of $(printf '%s' "$named" | wc -w) named brief(s) exist:$present"
    [ -n "$absent" ] && detail="$detail; not yet written:$absent"
    row ok "briefs in §4" "$detail"
fi

# ---------------------------------------------------------------------------
# 6. Section 3 names the batch this pod is actually running
# ---------------------------------------------------------------------------
# THE OTHER HALF OF THE 18 SEPTEMBER DEADLOCK. Section 3 carries one
# `**Batch <id>: running|ended**` anchor and it is supposed to name the batch in
# flight. B3's orchestrator never wrote it, so the anchor still said
# "**Batch B2: ended**" while B3 was running -- and from that one stale line
# `batch-resume.sh` concluded the batch had ended and refused, while
# `batch-start.sh` refused because section 2 did not name the landing. The
# programme stopped for two days and nothing anywhere reported a problem,
# because every individual file was internally consistent.
#
# `.maestro/orchestrator-sessions.log` knows better: batch-start.sh records
# `<time> <batch> <session>` there when it mints a conversation, so the batch
# this pod belongs to is a fact rather than a claim. This check compares the
# two.
#
# A LIVE OWNER MAKES IT A FAILURE, ITS ABSENCE MAKES IT A WARNING, and the
# asymmetry is deliberate. While somebody is driving, a section 3 naming
# another batch is actively dangerous -- it is the state the resume path
# misreads. With nobody driving, it is merely stale, and failing there would
# make `batch-start.sh` refuse to start the NEXT batch over the previous
# batch's correctly-ended section 3, which is the normal boundary.
#
# It is also why the batch prompt says section 3 is the FIRST commit of a
# batch: between minting a session and that commit, this check is red on
# purpose.
sess_file="$ROOT/.maestro/orchestrator-session"
sess_log="$ROOT/.maestro/orchestrator-sessions.log"
state_batch=$(batch_state_id "$STATE")
# GUARDED BY `-r` AND NOT BY `2>/dev/null` ON THE `tr`. Redirections are set up
# left to right, so `tr ... < missing 2>/dev/null` fails on the `<` while stderr
# is still the terminal and prints "No such file or directory" anyway -- on
# every run in a checkout no launcher has used, which is most of them.
sess_id=""
[ -r "$sess_file" ] && sess_id=$(tr -d '[:space:]' < "$sess_file")
sess_batch=""
[ -n "$sess_id" ] && sess_batch=$(batch_session_batch "$sess_log" "$sess_id" || true)
owner_pid=$(awk '{print $1; exit}' "$ROOT/.maestro/orchestrator.pid" 2>/dev/null | tr -dc '0-9')
owner_live=0
if [ -n "$owner_pid" ] && [ -d "/proc/$owner_pid" ] \
   && [ -n "$(tr -d '\0' < "/proc/$owner_pid/cmdline" 2>/dev/null)" ]; then
    owner_live=1
fi

if [ -z "$state_batch" ]; then
    row FAIL "§3 names this batch" "§3 has no '**Batch <id>: running|ended**' anchor at all"
elif [ -z "$sess_id" ]; then
    row warn "§3 names this batch" "§3 says $state_batch; no session recorded in .maestro/orchestrator-session, so there is nothing to compare"
elif [ -z "$sess_batch" ]; then
    row warn "§3 names this batch" "§3 says $state_batch; session ${sess_id%%-*} is not in .maestro/orchestrator-sessions.log"
elif [ "$state_batch" = "$sess_batch" ]; then
    row ok "§3 names this batch" "§3 and the session record both say $sess_batch"
elif [ "$owner_live" = 1 ]; then
    row FAIL "§3 names this batch" "§3 says $state_batch, but live orchestrator pid $owner_pid is running batch $sess_batch -- write §3 NOW, this is the 18 September deadlock"
else
    row warn "§3 names this batch" "§3 says $state_batch, the recorded session belongs to $sess_batch, and no orchestrator is running"
fi

# ---------------------------------------------------------------------------
# 5. The working tree is clean and pushed
# ---------------------------------------------------------------------------
# "Pushed" and not merely "committed", because the pod reboots. The 17 September
# restart took two workers with it seven minutes in, and what survived was
# exactly what had been pushed: nothing. A batch boundary whose state is in a
# container's filesystem is a batch boundary that a restart deletes.
dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)
branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
local_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
remote_head=$(git -C "$ROOT" rev-parse -q --verify "origin/$branch" 2>/dev/null)

if [ "$dirty" -ne 0 ]; then
    row FAIL "tree clean & pushed" "$dirty uncommitted file(s) -- git status --short"
elif [ -z "$remote_head" ]; then
    row FAIL "tree clean & pushed" "branch '$branch' has no origin/$branch -- nothing is pushed"
elif [ "$local_head" != "$remote_head" ]; then
    ahead=$(git -C "$ROOT" rev-list --count "origin/$branch..HEAD" 2>/dev/null)
    behind=$(git -C "$ROOT" rev-list --count "HEAD..origin/$branch" 2>/dev/null)
    row FAIL "tree clean & pushed" "$branch is $ahead ahead / $behind behind origin/$branch"
else
    row ok "tree clean & pushed" "clean, and $branch == origin/$branch at $(printf '%s' "$local_head" | cut -c1-7)"
fi

# ---------------------------------------------------------------------------
# Print it
# ---------------------------------------------------------------------------
if [ "$quiet" = 0 ] || [ "$failed" -ne 0 ]; then
    printf '== state-check (%s) ==\n' "$ROOT"
    printf '%-6s %-20s %s\n' STATE CHECK DETAIL
    printf '%-6s %-20s %s\n' ------ -------------------- ------
    for entry in "${ROWS[@]}"; do
        IFS=$'\t' read -r state check detail <<< "$entry"
        printf '%-6s %-20s %s\n' "$state" "$check" "$detail"
    done
    echo
fi

if [ "$failed" -eq 0 ]; then
    [ "$quiet" = 0 ] && echo "STATE IS CURRENT: every check passed"
    exit 0
fi
printf 'STATE IS STALE: %d check(s) failed. First failure -- %s\n' "$failed" "$FIRST_FAILURE"
exit 1
