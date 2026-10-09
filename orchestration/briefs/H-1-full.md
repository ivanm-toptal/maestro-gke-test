# Task H-1: the orchestration scripts work on a repository whose default branch is `main`

**Why (the orchestrator of B1, 2026-10-09, with T-1's evidence):** T-1 landed and the kit's own
landing script could not do it. `land-branch.sh` runs `git checkout -q master || exit 2`, and this
repository's default branch is `main` (`git ls-remote --heads origin` lists only `main`), so the
orchestrator of B1 landed `worker/docs-index` by hand with the script's own semantics. Observed
verbatim on 2026-10-09:

    lock: acquired /workspace/.maestro/lock/worker-docs-index for pid 25938
    landing into: ivanm-toptal/maestro-gke-test at /workspace
    error: pathspec 'master' did not match any file(s) known to git
    LAND_RC=2

Two further symptoms were measured the same day and are the dangerous half, because they are
silent rather than loud: `status.sh` printed `0 unlanded remote branch(es)` while
`origin/worker/docs-index` was in fact unlanded (`git branch -r --no-merged origin/master` fails
with `fatal: malformed object name`, and `2>/dev/null` hides it); and `state-check.sh`'s
"landings in §2" row reported `ok -- 0 merge(s), all named` for the same reason, which is the
one check the reset contract rests on. Full evidence with file:line is `H-1` in
`docs/ledgers/HARDENING.md`.

**This brief is the orchestrator's proposal, not yet the owner's decision.** It names a defect
B1 proved; the owner approves, re-scopes or drops it before B2 runs. Nothing here invents scope
beyond making the existing scripts true of this repository.

**Route** `orchestration/scripts/` (`land-branch.sh`, `status.sh`, `state-check.sh`,
`spawn-worker.sh`, `batch-chain.sh`, `batch-resume.sh`), and `orchestration/local.env.example` if a
new key is the chosen remedy. **Size** one worker-run, zero spend: no machine, no vendor, no model
beyond the worker itself. **Machines** none. **Branch** `fix/default-branch` from the default
branch. **Worktree** the worker's own, via `orchestration/scripts/spawn-worker.sh`.

This repository has no test runner and no Python manifest; there is no suite to chunk. Commit and
push after every step, and push a WIP as soon as the evidence has been read; kill nothing by
pattern; a detached run is never re-invoked.

## Evidence to read first
`grep -n 'H-1' docs/ledgers/HARDENING.md` (by id, never the ledger end to end); the header comment
of each script in the route; `docs/OPERATING.md` §0 and §4; `git ls-remote --heads origin`.

## What to do
1. **Resolve the default branch once, in one place.** `orch-env.sh` is the existing single place a
   script learns whose programme it runs for; put the resolution there (read `origin/HEAD`, fall
   back to an `ORCH_DEFAULT_BRANCH` key in `orchestration/local.env`, and fail loudly rather than
   defaulting to `master`). Done: one function, one definition, no second copy.
2. **Use it in every script of the route**, replacing each literal `master`. Done: `grep -rn
   '\bmaster\b' orchestration/scripts/ scripts/` returns only comments that are about git's
   history, not code.
3. **Make the two silent failures loud.** `status.sh`'s unlanded-branch count and
   `state-check.sh`'s "landings in §2" row must FAIL, naming the ref, when the branch they ask
   about does not resolve. An unanswered question is a failed check, never a passed one --
   `state-check.sh`'s own machine row already says so and is the pattern to copy. Done: both,
   demonstrated against a deliberately wrong branch name.
4. **Prove it end to end without landing anything of your own.** Show `state-check.sh` green,
   `status.sh` reporting the true unlanded count against a scratch branch you push and then
   delete, and `land-branch.sh --help` plus a dry read of its checkout line. You never land; the
   orchestrator does.
5. **Report the kit divergence.** These files were vendored from `toptal/maestro-k8s`; run
   `orchestration/scripts/kit-diff.sh` and say in your report exactly what the kit would need to
   re-vendor. Do not edit `~/.kit`.

## Documents
`docs/ledgers/RESULTS.md` row for H-1; `docs/ledgers/HARDENING.md` -- update H-1's status rather
than adding a second row; `docs/ledgers/ACCESS-REPORT.md` close-out with the Phase 0 probe and the
zero spend; `docs/README.md` (the index) wherever a row's description changes, and
`scripts/check-docs-index.sh` must still exit 0.

## Report
Proven versus assumed; every deviation with its reason; the before and after of the two silent
checks, verbatim; `grep -rn '\bmaster\b'` output; `git status --short` empty and the pushed head.
