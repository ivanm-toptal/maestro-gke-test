#!/usr/bin/env bash
# land-branch.sh <branch> <message-file> — merge origin/<branch> into master with
# --no-ff, resolve document conflicts, refuse code conflicts, push, prune.
#
# THE TWO RULES THIS SCRIPT EXISTS TO ENFORCE, and they are asymmetric on
# purpose:
#
#   a DOCUMENT conflict is resolved       (docs/*.md, RESULTS.md and the rest are
#                                          append-mostly ledgers; two tasks
#                                          adding a row each is not a
#                                          disagreement, and resolve-any.py
#                                          keeps both sides)
#   a CODE conflict ABORTS the merge      (.py .sh .js .mjs .yaml .json .toml
#                                          .lock -- two branches that changed
#                                          the same code are a decision a
#                                          person has to make, and a union
#                                          merge of two Python functions is a
#                                          syntax error at best and a silently
#                                          doubled statement at worst)
#
# WHAT CHANGED WHEN THE ORCHESTRATOR MOVED INTO ONE CONTAINER. Two things, both
# in the version this replaces:
#
#   `cd ~/<ORCH_REPO_NAME>`            ->  $ROOT, default /workspace
#   `python3 /tmp/resolve-any.py`      ->  the copy committed beside this file
#
# and the third is the bigger one: the old script ended with a loop over three
# container names written out as literals --
# `for C in maestro-<session>3-... maestro-<session>5-... ; do docker
# exec -u vscode $C ... git pull ...` -- to refresh each dev-box checkout to
# the new master. There is one checkout now and this script just updated it, so
# there is nothing to refresh. What replaces the loop is a REPORT: each live
# worktree, its branch, and how far behind the new master it is, because that is
# the question the loop was really answering ("who has to rebase now?").
#
# THE LOCK, AND WHY A LANDER NEEDS THE SAME ONE AS A VERIFIER (task P-3). A
# land and a verification of one branch are the same critical section seen from
# two ends: the verification says whether the branch may land, and the land
# makes the branch's commit reachable from master and then DELETES the remote
# branch. Running them together means verifying a ref that is being removed,
# and the B3 pair proved the class is real. So both take
# `<root>/.maestro/lock/<branch-tag>` (orchestration/scripts/run-lock.sh). A
# lander WAITS for the lock rather than refusing on it, which is the one place
# it differs from `verify-detached.sh`: a land arriving while its own branch is
# still being verified is a legitimate order of events, not a mistake.
#
# THE DIRTY TREE, AND WHAT "ITS OWN" MEANS. This script stashes the
# orchestrator's scratch before it merges and restores it afterwards. Two things
# about that were unsafe and are now refused rather than risked:
#
#   THE STASH STACK IS SHARED. `git stash` is per-repository, not per-worktree,
#   and every worker worktree under .worktrees/ shares /workspace/.git. A bare
#   `git stash pop` therefore pops whatever is on TOP, which may be another
#   session's entry -- so this script now records its own entry's commit id and
#   restores with `apply <sha>` + a drop that re-finds the entry by its unique
#   message.
#
#   A TREE THAT IS STILL DIRTY AFTER THE STASH IS NOT THIS SCRIPT'S TREE.
#   Something else is writing into it concurrently, and merging on top of that
#   would commit somebody else's half-written work under this task's message.
#   Refused (exit 6), with the files named.
#
# Usage: land-branch.sh <branch> <message-file>
# Exit codes: 0 landed / 2 usage / 3 the push failed / 4 the resolver failed /
#             5 a CODE conflict / 6 a dirty tree this script did not stash, or
#             the lock is held by a live run of the same branch

set -uo pipefail

ROOT="${SPAWN_WORKER_ROOT:-/workspace}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVER="$HERE/resolve-any.py"
# shellcheck source=/dev/null
. "$HERE/run-lock.sh"
# shellcheck source=/dev/null
. "$HERE/orch-env.sh"
orch_env_load "$ROOT"

branch=${1:?usage: land-branch.sh <branch> <message-file>}
msg=${2:?usage: land-branch.sh <branch> <message-file>}
[ -r "$msg" ] || { printf 'land-branch: message file not readable: %s\n' "$msg" >&2; exit 2; }
msg_abs=$(cd "$(dirname "$msg")" && pwd)/$(basename "$msg")
[ -r "$RESOLVER" ] || { printf 'land-branch: resolver missing: %s\n' "$RESOLVER" >&2; exit 2; }

cd "$ROOT" || exit 2

# THE LOCK, BEFORE THE STASH. Everything below this line -- the stash, the
# merge, the push, the restore -- is the critical section, so the lock is taken
# in front of all of it and released by the EXIT trap however this script ends.
lock_tag=$(run_lock_tag "$branch")
RUN_LOCK_WHAT="land $branch"
export RUN_LOCK_WHAT
if ! run_lock_acquire "$ROOT" "$lock_tag" "$$" "${LAND_LOCK_WAIT:-300}"; then
    printf 'land-branch: REFUSED -- %s is being verified or landed by another run.\n' "$branch" >&2
    printf '  %s\n' "$RUN_LOCK_DETAIL" >&2
    printf '  Nothing was stashed, merged or pushed. Wait for it, or raise LAND_LOCK_WAIT.\n' >&2
    exit 6
fi
trap 'run_lock_release "$ROOT" "$lock_tag" "$$" >/dev/null 2>&1 || true' EXIT
printf 'lock: %s\n' "$RUN_LOCK_DETAIL"
printf 'landing into: %s at %s\n' "${ORCH_REPO_NAME:-<no origin>}" "$ROOT"

# The orchestrator's own tree collects smoke artefacts. Stashed rather than
# committed or discarded, and restored at the end -- the same dance the previous
# version did, for the same reason: a merge cannot start dirty and a human's
# scratch is not this script's to throw away. What changed is HOW it comes back:
# by commit id, not by position on a stack this repository shares between every
# worktree.
stashed=0
stash_sha=""
stash_msg="land-branch: orchestrator scratch $lock_tag $$"
if [ -n "$(git status --short)" ]; then
    git stash push -q -u -m "$stash_msg" && stashed=1
    if [ "$stashed" = 1 ]; then
        stash_sha=$(git stash list --format='%H %gs' | grep -F -- "$stash_msg" | head -1 | cut -d' ' -f1)
        printf 'stashed the orchestrator scratch as %s\n' "${stash_sha:-<unknown>}"
    fi
fi

# STILL DIRTY AFTER A STASH means another process is writing into this checkout
# right now, and this script's own restore would fight it. Refuse before
# anything is merged; the stash, if one was taken, is named so it is not lost.
residue=$(git status --short)
if [ -n "$residue" ]; then
    printf 'land-branch: REFUSED -- the tree is dirty after its own stash, so something else is writing to %s:\n' "$ROOT" >&2
    printf '%s\n' "$residue" | head -20 >&2
    [ -n "$stash_sha" ] && printf '  this run stashed your earlier scratch as %s -- git stash apply %s\n' "$stash_sha" "$stash_sha" >&2
    exit 6
fi

# THE RESTORE, and it is `apply <sha>` + a targeted drop rather than `pop`.
# `pop` takes whatever is at the TOP of the stack, and this repository's stash
# stack is shared by /workspace and every worker worktree hanging off its .git
# -- so a concurrent session that pushed after this script did would have its
# work restored into the orchestrator's checkout and then dropped. The entry is
# found again by its unique message because dropping needs the stack POSITION,
# which moves whenever anybody else pushes or drops.
restore_scratch() {
    [ "$stashed" = 1 ] || return 0
    if [ -z "$stash_sha" ]; then
        printf 'orchestrator scratch NOT restored: this run could not record its stash id.\n' >&2
        printf '  It is still on the stack -- git stash list | grep %s\n' "$lock_tag" >&2
        return 1
    fi
    if ! git stash apply -q "$stash_sha" 2>/dev/null; then
        printf 'orchestrator scratch NOT restored: git stash apply %s failed (it conflicts with the new master).\n' "$stash_sha" >&2
        printf '  Nothing was dropped; it is still reachable as %s\n' "$stash_sha" >&2
        return 1
    fi
    entry=$(git stash list --format='%gd %gs' | grep -F -- "$stash_msg" | head -1 | cut -d' ' -f1)
    if [ -n "$entry" ]; then
        git stash drop -q "$entry"
    fi
    echo "orchestrator scratch restored"
    return 0
}

git checkout -q master || exit 2
git pull -q --ff-only origin master || { printf 'land-branch: master is not fast-forwardable from origin\n' >&2; exit 2; }
git fetch -q origin "$branch" || { printf 'land-branch: cannot fetch origin/%s\n' "$branch" >&2; exit 2; }

# `--no-ff` ALWAYS, even when a fast-forward is possible: the merge commit is
# where the task's close-out message lives, and this repository's history is read
# as a list of those. `|| true` because a conflicting merge exits nonzero and the
# conflict is what the next twenty lines are for.
git merge --no-ff --no-edit "origin/$branch" -F "$msg_abs" > /tmp/land-merge.out 2>&1 || true

conflicts=$(git status --short | grep -E "^(UU|AA|DU|UD)" || true)
if [ -z "$conflicts" ]; then
    echo "no-conflicts"
else
    printf '%s\n' "$conflicts"
fi

# THE CODE GATE, and it is checked BEFORE the resolver runs so the resolver can
# never be the thing that decides a .py file.
if printf '%s\n' "$conflicts" | grep -qE "^(UU|AA|DU|UD) .*\.(py|sh|js|mjs|yaml|yml|json|toml|lock)$"; then
    echo "CODE CONFLICT -- merge aborted, nothing pushed"
    printf '%s\n' "$conflicts" | grep -E "\.(py|sh|js|mjs|yaml|yml|json|toml|lock)$"
    git merge --abort
    restore_scratch
    exit 5
fi

if [ -n "$conflicts" ]; then
    python3 "$RESOLVER" || { echo "RESOLVER FAILED -- merge left in place for a human"; exit 4; }
    git add -A
    git diff --cached --quiet || git commit -q --no-edit
fi

echo "master: $(git log --oneline -1 | cut -c1-100)"

# PUSH AND CHECK THE EXIT CODE, because in this container it has hung.
# docs/ledgers/ACCESS-REPORT.md finding 1: `git push` over HTTPS sends its headers and
# then receives nothing, intermittently, and a task that pushes once at the end
# can lose a session's work to it. Not retried in a loop here -- reported.
if git push origin master; then
    echo "pushed master"
else
    echo "PUSH FAILED (rc=$?) -- master is landed LOCALLY ONLY."
    echo "  This container has a recorded intermittent HTTPS push stall:"
    echo "  docs/ledgers/ACCESS-REPORT.md finding 1. Surface it; do not retry in a loop."
    exit 3
fi

git push -q origin --delete "$branch" 2>/dev/null && echo "pruned origin/$branch" || echo "origin/$branch not pruned (already gone, or push refused)"

# What the old docker-exec refresh loop was really asking.
echo "--- worktrees, against the new master ---"
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
    [ "$wt" = "$ROOT" ] && continue
    wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    behind=$(git -C "$wt" rev-list --count "HEAD..master" 2>/dev/null || echo "?")
    printf '  %-40s %-28s %s commit(s) behind master\n' "${wt#"$ROOT"/}" "$wt_branch" "$behind"
done

restore_scratch
printf 'host status: %s dirty; remote branches: %s\n' \
    "$(git status --short | wc -l)" "$(git branch -r | grep -vc HEAD)"
