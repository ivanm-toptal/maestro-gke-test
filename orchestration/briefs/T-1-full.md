# Task T-1: a human-readable index of this repository, so a newcomer and their agent can navigate it

**Why (the owner, at the tutorial):** the first task an orchestrated project runs should prove the
loop — brief, batch, worker, verification, landing, state rewrite — while producing something the
team wanted anyway: "a human-readable index file of the repo so a colleague (and their agents) can
navigate it before the tutorial" (18 September 2026 meeting, action item for the owner).

**Route** `docs/README.md` (new), `README.md` (one link to it). **Size** one worker-run, zero spend:
no machine, no vendor, no model beyond the worker itself. **Machines** none. **Branch** `docs/index` from the default
branch. **Worktree** the worker's own, via `orchestration/scripts/spawn-worker.sh`.

Run any test suite the repository has in chunks that each finish under nine minutes, one chunk per
call; never `&` behind a test runner; kill nothing by pattern; commit and push after every step; a
detached run is never re-invoked.

## Evidence to read first
`ls -R` to two levels; every top-level README or doc; `pyproject.toml` or the equivalent manifest;
`git log --oneline | head -30` for what the repository has been about.

## What to build
1. **`docs/README.md`**: one table per top-level folder — path, one plain-language line on what it
   holds, who reads it (a human browsing, an agent on a task, the orchestrator after a reset), and how
   (whole, by section, grepped by id). Every file under `docs/` appears; nothing is described that does
   not exist.
2. **A test** (or a script, where the repository has no test runner) that fails when a Markdown file
   under `docs/` is missing from the index or the index names a path that does not exist.
3. **One link** from the root `README.md` to the index, in its first screen.

## Documents
`docs/README.md` itself; `docs/STATE.md` §8 gains the row "the index"; `docs/ledgers/RESULTS.md` row
(measures nothing); `docs/ledgers/ACCESS-REPORT.md` close-out (the Phase 0 probe).

## Report
The index's folder count and file count; the test's output; `git status --short` empty.
