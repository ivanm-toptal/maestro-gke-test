#!/usr/bin/env bash
# spawn-worker.sh — give one worker agent its own git worktree, its own .venv
# and a detached console, inside this one container.
#
# THE LAYOUT THIS SCRIPT IMPLEMENTS, and orchestration/README.md is the long
# version: one checkout at /workspace, one worktree per worker under
# /workspace/.worktrees/<name>, each with its own .venv. That replaces the model
# this repository actually ran on until now -- one Maestro session per worker,
# each a separate container refreshed by `docker exec` from a laptop, which is
# why `land-branch.sh` used to carry three container names as a literal list.
#
# WHY WORKTREES AND NOT CLONES. A clone of this repository is 2 GB of history
# and `bench/results/` per worker and it needs a GitHub credential to make.
# `git worktree` shares the one object store, so a worker costs its checkout
# (~90 MB) plus its .venv, and `origin/master` is fetched once for everybody.
# The cost of that sharing is the thing to know about: THE WORKTREES SHARE
# /workspace/.git. `git gc`, a `git fetch --prune` that removes a branch a
# worktree is on, or deleting /workspace, takes every worker down at once.
#
# WHY A SEPARATE .venv PER WORKER AND NOT ONE SHARED ONE. `uv sync` is
# destructive to the environment it manages: a worker that runs
# `uv sync --group speech` would install torch into a sibling's interpreter, and
# a worker on a branch that changed uv.lock would uninstall packages a sibling's
# suite is mid-run against. The disk is cheaper than that class of failure.
#
# Usage:
#   spawn-worker.sh <name> <task-file> [extra claude args...]
#   spawn-worker.sh --remove <name>
#
# Flags (before <name>):
#   --no-sync    create the worktree, skip `uv sync` (the caller will run it)
#   --no-agent   create and sync the worktree, do not start an agent
#   --base <ref> branch from <ref> instead of origin/master
#
# Exit codes: 0 ok / 2 usage / 3 git/worktree failure / 4 uv sync failure

set -euo pipefail

ROOT="${SPAWN_WORKER_ROOT:-/workspace}"
TREES="$ROOT/.worktrees"
BASE="${SPAWN_WORKER_BASE:-origin/master}"
SYNC_ARGS="${SPAWN_WORKER_SYNC_ARGS:---all-groups}"
do_sync=1
do_agent=1

die() { printf 'spawn-worker: %s\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# --remove, and it is first because it must work when the rest cannot
# ---------------------------------------------------------------------------
if [ "${1-}" = "--remove" ]; then
    name=${2:?usage: spawn-worker.sh --remove <name>}
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "name must be [A-Za-z0-9._-], got: $name" 2
    tree="$TREES/$name"
    [ -e "$tree" ] || die "no worktree at $tree" 3
    # The .venv is INSIDE the worktree, so `git worktree remove --force` takes
    # it with the checkout. `--force` because a .venv and a stray pytest cache
    # are untracked files and the unforced form refuses to remove a dirty tree
    # -- which would make every worktree this script ever created unremovable.
    git -C "$ROOT" worktree remove --force "$tree"
    # `worktree remove` leaves the BRANCH. Deleting it here would throw away a
    # worker's unmerged commits, so it is reported and not done.
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/worker/$name"; then
        printf 'removed %s; branch worker/%s KEPT (%s)\n' "$tree" "$name" \
            "$(git -C "$ROOT" log --oneline -1 "worker/$name" | cut -c1-60)"
        printf '  delete it when it is landed:  git -C %s branch -D worker/%s\n' "$ROOT" "$name"
    else
        printf 'removed %s\n' "$tree"
    fi
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --no-sync)  do_sync=0; shift ;;
        --no-agent) do_agent=0; shift ;;
        --base)     BASE=${2:?--base needs a ref}; shift 2 ;;
        -h|--help)  sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)        die "unknown flag: $1" 2 ;;
        *)          break ;;
    esac
done

name=${1-}
[ -n "$name" ] || die "usage: spawn-worker.sh [flags] <name> <task-file> [extra claude args...]" 2
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "name must be [A-Za-z0-9._-], got: $name" 2
shift
task_file=${1-}
if [ "$do_agent" = 1 ]; then
    [ -n "$task_file" ] || die "a task file is required unless --no-agent is given" 2
    [ -r "$task_file" ] || die "task file not readable: $task_file" 2
    task_abs=$(cd "$(dirname "$task_file")" && pwd)/$(basename "$task_file")
fi
[ $# -gt 0 ] && shift || true

tree="$TREES/$name"
branch="worker/$name"

[ -e "$tree" ] && die "$tree already exists -- pick another name, or:
  $0 --remove $name" 3

# ---------------------------------------------------------------------------
# The worktree
# ---------------------------------------------------------------------------
# FETCH FIRST, ALWAYS. `origin/master` is a local ref and a stale one is the
# expensive mistake here: a worker branched from yesterday's master does a day's
# work and then meets a merge. R3-4 recorded fifteen minutes of `git push`
# against exactly that (docs/ledgers/ACCESS-REPORT.md).
git -C "$ROOT" fetch -q origin || die "git fetch origin failed -- this is an access finding, not a retry" 3
git -C "$ROOT" rev-parse --verify -q "$BASE" >/dev/null \
    || die "base ref '$BASE' does not exist after a fetch" 3

mkdir -p "$TREES"
git -C "$ROOT" worktree add -q -b "$branch" "$tree" "$BASE" \
    || die "git worktree add failed" 3
printf 'worktree %s\n  branch %s at %s (from %s)\n' \
    "$tree" "$branch" "$(git -C "$tree" rev-parse --short HEAD)" "$BASE"

# ---------------------------------------------------------------------------
# The worker's own environment
# ---------------------------------------------------------------------------
# `--all-groups` and NOT `--all-extras`: the `kernel` extra pins a private
# GitHub repository (pyproject.toml), so making it the default would turn "no
# GitHub credential here" into a broken spawn. A worker that needs it runs
# `uv sync --extra kernel` in its own tree, which is the point of the tree.
if [ "$do_sync" = 1 ]; then
    printf 'uv sync %s in %s ...\n' "$SYNC_ARGS" "$tree"
    # shellcheck disable=SC2086 -- SYNC_ARGS is a deliberate word list
    (cd "$tree" && uv sync $SYNC_ARGS) || die "uv sync failed in $tree" 4
    printf '  python %s\n' "$("$tree/.venv/bin/python" -V 2>&1)"
else
    printf 'uv sync SKIPPED (--no-sync); the worktree has no .venv yet\n'
fi

if [ "$do_agent" = 0 ]; then
    printf 'agent NOT started (--no-agent)\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# The agent
# ---------------------------------------------------------------------------
# DELEGATED to scripts/spawn-agent.sh rather than reimplemented. That script
# owns the things that are easy to get quietly wrong -- the tmux server whose
# parent is PID 1 so the agent outlives an IDE disconnect, the explicit
# `--model` because the bundled CLI defaults lower, the status and log files --
# and it already takes the working directory as SPAWN_AGENT_CWD. Two copies of
# that logic would be one copy too many.
#
# THE MODEL is ORCH_MODEL_WORKER (orch-env.sh; the researcher's decision in
# docs/OPERATING.md section 2) unless the caller set SPAWN_AGENT_MODEL, and a
# `--model` among the arguments still wins over both inside spawn-agent.sh.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orch-env.sh"
orch_env_load "$ROOT"
SPAWN_AGENT_MODEL="${SPAWN_AGENT_MODEL:-$ORCH_MODEL_WORKER}" SPAWN_AGENT_CWD="$tree" \
    exec "$ROOT/scripts/spawn-agent.sh" "$name" "$task_abs" "$@"
