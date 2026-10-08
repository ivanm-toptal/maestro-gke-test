#!/usr/bin/env bash
# verify-detached.sh — verify a branch end to end without holding a tool call
# open for it.
#
# WHAT CHANGED WHEN THE ORCHESTRATOR MOVED INTO ONE CONTAINER. The version this
# replaces took a CONTAINER NAME as its first argument and ran
# `docker exec -u vscode "$C" bash -lc 'git checkout --detach
# origin/<branch> ...'`. Neither half survives the move: there is no second
# container to exec into, and a detached checkout IN /workspace would yank the
# tree out from under the orchestrator that started the verification. So the
# verification gets its own worktree, and the container argument is gone.
#
# WHAT CHANGED AFTER 18 SEPTEMBER 14:19 UTC, and it is the reason this script
# was rewritten (task P-3). The version before this one derived its worktree
# path from the BRANCH NAME ALONE -- `.worktrees/verify-<branch>` -- and began
# by clearing whatever was there with `worktree remove --force`. Two
# orchestrator conversations were running batch B3 at once; both verified
# `worker/p-2`; the second start deleted the first's checkout at 14:19:00 and
# the first's own cleanup deleted the second's at 14:19:31. The survivor's
# pytest ran to 100 % inside a directory that no longer existed and ended with
# `pytest_exit=1` and no summary line -- which reads exactly like a red branch.
# Three changes come out of that and each one closes a different half:
#
#   A PER-RUN TAG on the worktree and the output file, so two runs never share
#   a directory and no run can delete another's by name. Nothing is ever
#   force-removed at startup any more; a path that already exists is a bug and
#   is refused.
#
#   A LOCK PER BRANCH (orchestration/scripts/run-lock.sh), so the second run is
#   refused loudly rather than quietly racing the first. It waits only if asked
#   to (VERIFY_LOCK_WAIT), and it NEVER removes a live run's anything.
#
#   A THIRD VERDICT, `truncated`. A run that ends before pytest's summary line
#   has not measured the branch, and saying "1 failed" about it is worse than
#   saying nothing. `--report` answers pass / fail / truncated / running, and a
#   truncated answer carries the reason.
#
# WHY IT DETACHES AT ALL. One tool call is capped at 600 s and the full suite is
# about 13 minutes (docs/runbooks/DEVELOPMENT.md). The alternative to detaching is
# `scripts/suite-chunks.py`, which is the right answer when a HUMAN or an agent
# is reading each chunk's output; this is the right answer when nobody is, which
# is the case a verification of somebody else's branch is in. The `setsid` +
# `&` here is the house rule's own idiom for long-running work and it is the one
# place in this directory that uses it: the run outlives the shell that started
# it, and the result file is the only thing anybody reads.
#
# HOW YOU KNOW IT FINISHED, and it is not "the file exists". The file is created
# immediately and appended to throughout, so its presence means "started". The
# last line of a completed run is exactly `VERIFY_DONE`; anything else means
# still running, or killed. Poll for the line, or ask `--report`, which knows
# the difference between the two.
#
# Usage:
#   verify-detached.sh <branch> [uv-sync-args]        # default --all-groups
#   verify-detached.sh --report <branch|result-file>  # pass/fail/truncated/running
#   tail -f <the result file this prints>
#
# Environment:
#   VERIFY_PYTEST_ARGS   replaces the pytest argv (a smoke test passes one file).
#                        Do NOT add `-q`: pyproject's addopts already has one and
#                        `-qq` suppresses the summary line the verdict is read from.
#   VERIFY_KEEP_TREE=1   leave the worktree behind for inspection
#   VERIFY_LOCK_WAIT     seconds to wait for another run of the same branch (default 0 = refuse)
#   VERIFY_RUN_TAG       the per-run tag, for a test that needs a predictable path
#   VERIFY_OUT_DIR       where result files go (default /tmp)
#   VERIFY_STALL_SECONDS how long the pytest log may go without a byte before
#                        `--report` calls a running verification STALLED (default
#                        1200 = 20 minutes). It reports; it never kills anything.
#
# Exit codes (of THIS script, not of the verification): 0 started / 2 usage /
#   3 git failure / 4 another run of this branch holds the lock.
#   The verification's own result is in the file, and in `--report`, whose exit
#   codes are ITS OWN: 0 pass / 1 fail or truncated / 2 still running.

set -uo pipefail

ROOT="${SPAWN_WORKER_ROOT:-/workspace}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="${VERIFY_OUT_DIR:-/tmp}"
# shellcheck source=/dev/null
. "$HERE/run-lock.sh"

die() { printf 'verify-detached: %s\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# --report: what does a result file actually say?
# ---------------------------------------------------------------------------
# SEPARATED FROM THE RUN so that the question "is this branch green?" has one
# implementation, and so that a human, `status.sh` and a test all get the same
# answer from the same bytes. The alternative -- everybody greps the file for
# `passed` -- is what reported a deleted directory as a red branch in B3.
#
# The four answers:
#   pass       the suite ran and its summary line says nothing failed
#   fail       the suite ran and its summary line says something did
#   truncated  the run ended before a summary line existed -- the branch was
#              NOT measured, and no count may be quoted from it
#   running    the runner process is still alive
#
# AND `running` ON ITS OWN IS A LIVENESS ANSWER, NOT A PROGRESS ONE. On 22
# September at 00:00 UTC the two first detached verifications of batch B5 sat at
# the 50 % mark for 37 and 51 minutes and `--report` said `running` every time
# it was asked: true, and indistinguishable from a suite that is merely slow.
# (The cause was a chain test waiting on the POD's own orchestrator pid, reached
# through an inherited BATCH_PID_FILE -- task P-3-cont, docs/ledgers/HARDENING.md
# `## 43`.) So a `running` report now also carries how old the `uv run pytest`
# process is and how long its log has gone without a byte, and says STALLED past
# VERIFY_STALL_SECONDS.
#
# IT KILLS NOTHING, and that is a decision rather than an omission. A stall is a
# finding for a human: the 22 September one was a defect in a test, and a script
# that had quietly killed the run would have hidden it behind a `truncated`
# nobody could explain.
verify_progress_report() {  # verify_progress_report <result-file>
    local out=$1 pid log age idle last now stall
    stall="${VERIFY_STALL_SECONDS:-1200}"
    pid=$(sed -n 's/^VERIFY_PYTEST_PID=//p' "$out" | head -1)
    log=$(sed -n 's/^VERIFY_PYTEST_LOG=//p' "$out" | head -1)

    if [ -z "$pid" ]; then
        # Before pytest: uv sync or ruff is still going, and neither can hang on
        # another process's liveness. Nothing to measure yet, and saying so beats
        # printing an age of zero that reads like a stall.
        printf 'VERIFY_PYTEST_AGE=none reason=pytest has not started yet (uv sync or ruff is still running)\n'
        return 0
    fi
    if run_lock_pid_alive "$pid"; then
        # `ps -o etimes=` is elapsed SECONDS since the process started -- the age
        # the reader wants, without parsing /proc/<pid>/stat's clock ticks.
        age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -dc '0-9')
        printf 'VERIFY_PYTEST_AGE=%ss pid=%s\n' "${age:-unknown}" "$pid"
    else
        printf 'VERIFY_PYTEST_AGE=none pid=%s has exited; the runner is past pytest and writing its verdict\n' "$pid"
    fi

    if [ ! -r "$log" ]; then
        printf 'VERIFY_PYTEST_PROGRESS=no readable log at %s\n' "${log:-<unrecorded>}"
        return 0
    fi
    now=$(date +%s)
    idle=$(( now - $(stat -c %Y "$log" 2>/dev/null || echo "$now") ))
    # pytest's progress bar is one long line ending in \r, so the carriage
    # returns are turned into newlines before the last one is taken -- otherwise
    # "the last line" is the whole bar since the last newline.
    last=$(tr '\r' '\n' < "$log" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-100)
    printf 'VERIFY_PYTEST_PROGRESS=idle %ss last=%s\n' "$idle" "${last:-(nothing written yet)}"
    if [ "$idle" -ge "$stall" ]; then
        printf 'VERIFY_STALLED=the pytest log has not advanced for %ss (threshold %ss). NOTHING WAS KILLED -- read %s and the process tree under pid %s.\n' \
            "$idle" "$stall" "$log" "$pid"
    fi
}

if [ "${1-}" = "--report" ]; then
    what=${2:?usage: verify-detached.sh --report <branch|result-file>}
    if [ -r "$what" ]; then
        out=$what
    else
        pointer="$OUT_DIR/verify-$(run_lock_tag "$what").latest"
        [ -r "$pointer" ] || die "no result file, and no pointer at $pointer" 2
        out=$(cat "$pointer")
        [ -r "$out" ] || die "the pointer names $out, which is not readable" 2
    fi

    if [ "$(tail -n 1 "$out")" = VERIFY_DONE ]; then
        verdict_line=$(grep -m1 '^VERIFY_VERDICT=' "$out")
        printf 'file=%s\n%s\n' "$out" "${verdict_line:-VERIFY_VERDICT=truncated reason=the run finished without writing a verdict}"
        case "$verdict_line" in *=pass*) exit 0 ;; *) exit 1 ;; esac
    fi

    # NOT DONE. Alive means running; dead means it was killed or the pod went
    # down, and either way the branch was not measured.
    runner_pid=$(sed -n 's/^VERIFY_RUNNER_PID=//p' "$out" | head -1)
    if run_lock_pid_alive "$runner_pid"; then
        printf 'file=%s\nVERIFY_VERDICT=running reason=runner pid %s is alive, last line: %s\n' \
            "$out" "$runner_pid" "$(tail -n 1 "$out" | cut -c1-80)"
        verify_progress_report "$out"
        exit 2
    fi
    # THE ORPHANED WORKTREE IS NAMED, because a killed run never reached its
    # own cleanup and nobody else will guess the path now that it carries a
    # per-run tag. An unremoved tree is a checkout plus a .venv on a volume
    # that has run out before.
    printf 'file=%s\nVERIFY_VERDICT=truncated reason=the run ended without VERIFY_DONE (runner pid %s is gone); last line: %s\n' \
        "$out" "${runner_pid:-unknown}" "$(tail -n 1 "$out" | cut -c1-80)"
    orphan=$(sed -n 's/^VERIFY_TREE=//p' "$out" | head -1)
    [ -n "$orphan" ] && [ -d "$orphan" ] && printf 'orphaned worktree, remove it: git -C %s worktree remove --force %s\n' "$ROOT" "$orphan"
    exit 1
fi

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------
branch=${1:?usage: verify-detached.sh <branch> [uv-sync-args]}
sync_args=${2:---all-groups}
tag=$(run_lock_tag "$branch")
# NO `-q` HERE, AND ITS ABSENCE IS LOAD-BEARING. pyproject.toml already sets
# `addopts = "-q"`, so a second one makes `-qq`, and `-qq` SUPPRESSES THE
# SUMMARY LINE -- measured on this tree, 21 September: `pytest -p
# no:cacheprovider tests/test_ports.py` ends "16 passed in 0.37s" and the same
# command with `-q` ends on the progress bar. The version before this one passed
# `-q` by default, which is why no detached verification in this repository has
# ever printed a count: D-15's result file ends at `pytest_exit=1` and a FAILED
# line, and the old `grep -E 'passed|failed|error'` found nothing to print.
#
# That also means the B3 lesson -- "a pytest_exit with no summary line means the
# tree vanished" -- was never actually diagnostic here: NO run had a summary
# line. The `truncated` verdict below is only worth anything if a healthy run
# produces one, so the default argv has to let it.
pytest_args=${VERIFY_PYTEST_ARGS:--p no:cacheprovider}

# THE PER-RUN TAG. Pid AND nanoseconds: the pid alone repeats after a pod
# restart (and B3's two runs were in different containers, where pids collide
# freely), the clock alone can repeat inside one nanosecond only in theory but
# costs nothing to guard against. This is the change that makes the two paths
# below unable to name each other.
run_tag="${VERIFY_RUN_TAG:-$$-$(date -u +%s%N)}"
out="$OUT_DIR/verify-$tag-$run_tag.out"
pointer="$OUT_DIR/verify-$tag.latest"
tree="$ROOT/.worktrees/verify-$tag-$run_tag"
runner="$OUT_DIR/verify-$tag-$run_tag.sh"

# THE LOCK, TAKEN BEFORE ANYTHING IS TOUCHED. Refusing is the default and the
# wait is opt-in: two verifications of one branch at once is nearly always the
# B3 mistake -- somebody else is already doing this -- and a tool that silently
# queues hides that. Exit 4 so a caller can tell "somebody else has it" from
# "git failed".
RUN_LOCK_WHAT="verify $branch"
export RUN_LOCK_WHAT
if ! run_lock_acquire "$ROOT" "$tag" "$$" "${VERIFY_LOCK_WAIT:-0}"; then
    printf 'verify-detached: REFUSED -- %s is already being verified or landed.\n' "$branch" >&2
    printf '  %s\n' "$RUN_LOCK_DETAIL" >&2
    printf '  Nothing was removed. Wait for it, or re-run with VERIFY_LOCK_WAIT=<seconds>.\n' >&2
    printf '  If that pid is a stray second orchestrator, stop IT (docs/LESSONS.md, "Two orchestrators").\n' >&2
    exit 4
fi
# Released here only on a failure BEFORE the runner starts; once the runner owns
# it, the trap is cleared and the runner releases it at its end.
trap 'run_lock_release "$ROOT" "$tag" "$$" >/dev/null 2>&1 || true' EXIT
printf 'lock: %s\n' "$RUN_LOCK_DETAIL"

git -C "$ROOT" fetch -q origin "$branch" \
    || die "git fetch origin $branch failed -- access finding, not a retry" 3

# NO FORCE-REMOVE HERE, and its absence is the point of the rewrite. With a
# per-run tag the path cannot belong to another run, so an existing one is a
# tag collision -- a bug to report, never a tree to delete. The line that used
# to be here (`worktree remove --force "$tree"`) is what killed a live run.
[ -e "$tree" ] && die "worktree path already exists, which a per-run tag makes impossible: $tree" 3
mkdir -p "$ROOT/.worktrees"
# DETACHED, so no local branch is created and two verifications of the same
# branch cannot collide on a ref.
git -C "$ROOT" worktree add -q --detach "$tree" "origin/$branch" \
    || die "git worktree add --detach failed" 3

# The runner is written to a FILE rather than nested inside the quoting of a
# `bash -lc` string. The version this replaces was four levels of escaping deep
# and that is where its bugs lived.
cat > "$runner" <<RUNNER
#!/usr/bin/env bash
# Generated by verify-detached.sh -- safe to read, edit or delete.
# No 'set -e': every stage's exit code has to be RECORDED, including the
# failures, which is the whole output of this script.
set -uo pipefail
. "$HERE/run-lock.sh"

# THE HAND-OVER, FIRST THING. The parent took the lock under its own pid and is
# about to exit; from here the lock belongs to this process, so a stale-lock
# check by anybody else tests the pid that is actually doing the work. Done
# before the cd, because a failed cd must still leave a coherent lock.
run_lock_handover "$ROOT" "$tag" "$$" \$\$ >/dev/null 2>&1
echo "VERIFY_RUNNER_PID=\$\$"
echo "VERIFY_BRANCH=$branch"
echo "VERIFY_TREE=$tree"
trap 'run_lock_release "$ROOT" "$tag" \$\$ >/dev/null 2>&1 || true' EXIT

cd "$tree" || { echo "VERIFY_VERDICT=truncated reason=the worktree $tree could not be entered"; echo VERIFY_DONE; exit 9; }
echo "verifying $branch at \$(git rev-parse --short HEAD) in \$(hostname) at \$(date -Is)"

uv sync $sync_args > $OUT_DIR/uv-sync-$tag-$run_tag.log 2>&1
uv_sync_exit=\$?
echo "uv_sync_exit=\$uv_sync_exit"
tail -1 $OUT_DIR/uv-sync-$tag-$run_tag.log

uv run ruff check . > $OUT_DIR/ruff-$tag-$run_tag.log 2>&1
echo "ruff_exit=\$?"
tail -2 $OUT_DIR/ruff-$tag-$run_tag.log

# PYTEST IN THE BACKGROUND AND THEN `wait`, PURELY SO THE PID IS RECORDED.
# `--report` needs a process to measure the age of and a log to measure the
# idleness of; finding them afterwards would mean a `pgrep` under the runner,
# and `pgrep -f` matches the shell that runs it (docs/LESSONS.md). `wait`
# returns the child's own exit status, so this behaves exactly like the
# foreground call it replaces. The pid is `uv`'s, which is the parent of the
# real pytest and the same age to the millisecond -- and it is the process a
# human would have to stop anyway.
pytest_log=$OUT_DIR/pytest-$tag-$run_tag.log
echo "VERIFY_PYTEST_LOG=\$pytest_log"
uv run pytest $pytest_args > "\$pytest_log" 2>&1 &
pytest_pid=\$!
echo "VERIFY_PYTEST_PID=\$pytest_pid"
wait \$pytest_pid
pytest_exit=\$?
echo "pytest_exit=\$pytest_exit"
grep -E '^(FAILED|ERROR)' "\$pytest_log" | head -20
summary=\$(grep -E '(no tests ran|[0-9]+ (passed|failed|errors?|skipped|xfailed|xpassed|deselected)).* in [0-9.]+ ?s' "\$pytest_log" | tail -1)
[ -n "\$summary" ] && echo "\$summary"

echo "dirty after suite: \$(git status --short 2>/dev/null | wc -l) file(s)"
git status --short 2>/dev/null | head -10

# ---------------------------------------------------------------------------
# THE VERDICT, and 'truncated' is the one that matters
# ---------------------------------------------------------------------------
# A PYTEST EXIT CODE IS NOT A VERDICT ON ITS OWN. On 18 September a run whose
# directory had been deleted under it reached 100 %, raised FileNotFoundError
# and exited 1 with no summary line -- indistinguishable, from the exit code
# alone, from a branch with a failing test. The summary line is the evidence
# that the suite ran at all, so its ABSENCE is the finding, and the run is
# reported as having measured nothing rather than as red.
if [ "\$uv_sync_exit" -ne 0 ]; then
    echo "VERIFY_VERDICT=truncated reason=uv sync exited \$uv_sync_exit, so the suite never ran; see $OUT_DIR/uv-sync-$tag-$run_tag.log"
elif [ -z "\$summary" ]; then
    if [ ! -d "$tree" ]; then
        echo "VERIFY_VERDICT=truncated reason=the worktree $tree vanished mid-run (pytest_exit=\$pytest_exit, no summary line) -- another process removed it"
    else
        echo "VERIFY_VERDICT=truncated reason=pytest ended before its summary line (pytest_exit=\$pytest_exit) -- the branch was not measured"
    fi
elif [ "\$pytest_exit" -eq 0 ]; then
    echo "VERIFY_VERDICT=pass reason=\$summary"
else
    echo "VERIFY_VERDICT=fail reason=\$summary"
fi

if [ "\${VERIFY_KEEP_TREE:-0}" = 1 ]; then
    echo "worktree KEPT at $tree"
else
    git -C "$ROOT" worktree remove --force "$tree" 2>&1 && echo "worktree removed"
fi
echo VERIFY_DONE
RUNNER
chmod +x "$runner"

rm -f "$out"
# THE RUNNER'S ENVIRONMENT IS SCRUBBED, and these four names are the reason this
# script was touched again (task P-3-cont). A verification runs SOMEBODY ELSE'S
# branch's whole suite, and the orchestration tests in it read exactly these
# variables to find the repository, the launchers and the owner pid file they
# are supposed to be testing. Inheriting them from whoever started the
# verification points those tests at the POD: on 22 September batch B5's first
# two verifications both hung at 50 %, because `batch-chain.sh` under
# `tests/test_orchestration_locks.py` read an inherited
# BATCH_PID_FILE=/workspace/.maestro/orchestrator.pid and waited for the live
# orchestrator to die, at CHAIN_POLL=1, for 37 and 51 minutes. The launchers no
# longer export BATCH_PID_FILE and the tests now pin their own, so this is the
# third layer -- and it is the one that holds for a branch whose tests predate
# either fix, and for a human running this script by hand from a shell that
# happens to carry one of the names (the 22 September remedy was literally
# `env -u BATCH_PID_FILE bash verify-detached.sh <branch>`).
#
# AND EVERY ORCH_* NAME (task P-4), for the same reason: they say which pod's
# programme, project and machine prefix a script is working for, and
# ORCH_ENV_FILE says which parameter file to read. The orchestration scripts set
# them as shell variables and never export them, so this is for the operator
# who exported one by hand. The list is orch-env.sh's own, not a copy of it.
#
# AND ORCH_ROLE (30 September), which is not a parameter but a role: the
# launchers set ORCH_ROLE=orchestrator on the orchestrator's `claude`, so a
# verification the orchestrator starts inherits it. The suite under test is a
# branch's, and runs as no role at all (tests/test_agent_roles.py).
# shellcheck source=/dev/null
. "$HERE/orch-env.sh"
scrub=(-u BATCH_PID_FILE -u BATCH_ROOT -u CHAIN_SCRIPTS -u CHAIN_POLL -u ORCH_ENV_FILE -u ORCH_ROLE)
for key in $ORCH_KEYS; do scrub+=(-u "$key"); done
setsid nohup env "${scrub[@]}" \
    "$runner" > "$out" 2>&1 < /dev/null &
# THE POINTER, so "the latest run of this branch" still has a stable name now
# that the result file does not. Without it, a caller who did not keep this
# script's stdout has no way back to the file -- and the previous fixed name is
# exactly what let the second D-15 verification overwrite the first's record.
printf '%s\n' "$out" > "$pointer"

# WAIT FOR THE HAND-OVER BEFORE EXITING, and this poll is load-bearing. The
# lock currently records THIS pid, and this process is about to die; a second
# caller arriving in that window reads a dead holder, correctly calls the lock
# stale, reclaims it and runs -- which is the B3 collision with extra steps.
# The runner's first act is the handover, so this costs milliseconds; the
# timeout exists because a runner that never started at all must not leave a
# lock nobody can explain.
handover_waited=0
while [ "$(run_lock_holder "$ROOT" "$tag" 2>/dev/null || true)" = "$$" ]; do
    if [ "$handover_waited" -ge 15 ]; then
        run_lock_release "$ROOT" "$tag" "$$" >/dev/null 2>&1 || true
        die "the runner did not take the lock within 15 s -- it never started; lock released, nothing verified" 3
    fi
    sleep 1
    handover_waited=$((handover_waited + 1))
done

# The lock now belongs to the runner; this process must not release it on the
# way out.
trap - EXIT

cat <<EOF
started detached verification of $branch
  worktree $tree
  result   $out
  pointer  $pointer  (always names the latest run of this branch)
  runner   $runner
  lock     $(run_lock_dir "$ROOT" "$tag")

it is finished when the last line is VERIFY_DONE
  tail -n 30 $out
  bash $HERE/verify-detached.sh --report $branch   # pass / fail / truncated / running
EOF
