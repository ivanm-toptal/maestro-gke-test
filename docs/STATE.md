# STATE — where the maestro-gke-test programme is, for whoever reads this next with no other memory

Short, and read whole after every reset. Rewritten at every batch end; sections 2 and 3 updated at every
landing. Ledgers are elsewhere and grepped by task id. Reset contract: docs/OPERATING.md §4.

**Last reset:** 2026-10-08, the scaffold — section 2 counts landings from `f61ec8d`, the commit the layer was added onto; batch B1 has run.

## 1. Where we are (three sentences)
The programme was scaffolded from toptal/maestro-k8s on 2026-10-08 by ivanm-toptal, and batch B1 ran
the tutorial task T-1 on 2026-10-09: the repository now has a human-readable index, `docs/README.md`,
with a guard script that fails when it drifts from the files on disk. The loop itself is proven end to
end — brief, batch, worker in its own worktree, detached verification, landing, state rewrite — on zero
spend. The one thing it proved broken is the tooling's own assumption that the default branch is called
`master`: this repository's is `main`, so `land-branch.sh` refused and B1's landing was done by hand
(defect H-1, and the proposed next batch).

## 2. Landed since the previous reset (`f61ec8d`, the scaffold)
**B1 merges, in landing order:** `7212ad9` (T-1 — `docs/README.md`, the repository index: 6 tables,
52 rows, every Markdown file under `docs/`; `scripts/check-docs-index.sh`, the guard that fails when a
`docs/` Markdown file is missing from the index or the index names a path not on disk; a root
`README.md` link on its first screen; the first rows of `RESULTS.md` and `HARDENING.md`).
**Direct commits, all documents:** `cdc02c4` (STATE §3, B1 running) `be230d6` (STATE §3, worker named)
and this batch-end rewrite. `state-check.sh` polices merges only.

## 3. In flight (must be empty at a batch end)
**Batch B1: ended** — 2026-10-09, session 782f746d-88da-4ec2-878b-3720c19c5dfe, pod maestro-gke-test-0lpw,
owner ivanm-toptal; one landing, zero spend. When a batch starts, its orchestrator's FIRST commit rewrites
this line as `**Batch B<n>: running** — started <time>, session <id>, pod <session name>, owner <who>`
(the literal `running`, later `ended`, is the anchor the launchers read).
- Workers: none running.
- Machines: none; none were started in B1 and none of ours is other than TERMINATED.
- Worktrees: none.

## 4. The batch queue
### Batch B2 — H-1 alone (make the tooling true of a `main` repository)
1. `H-1-full.md` — the orchestration scripts hardcode `master`; this repository's default branch is
   `main`. Loud symptom: `land-branch.sh` exits 2 before merging. Silent symptoms, and the reason this
   is next rather than cosmetic: `status.sh` undercounts unlanded branches and `state-check.sh` passes
   its "landings in §2" row vacuously — the one check the reset contract rests on. Zero spend, no
   machine. **The owner approves, re-scopes or drops this before B2 runs** (§6).
### Unscheduled — proposals awaiting the owner's pick
1. **H-2, the kit-only paths.** Documents copied from the kit cite `docs/TUTORIAL.md`,
   `scripts/ignore-block.sh`, `docs/diagrams/overview.svg` and `scripts/janitor-cron.sh` as though they
   were here; all four live in `~/.kit`. `orchestration/README.md`, cited by `spawn-worker.sh`, exists in
   neither. Cosmetic, and it misleads the newcomers the index is for. Evidence: `H-2` in HARDENING.md.
2. **The reset drill.** `docs/OPERATING.md` §1 runs it every third batch; none has run yet.

## 5. Decisions the owner has taken (do not re-open)
- Coding is done by workers in their own worktrees, never in the orchestrator's checkout.
- Machines are labelled `purpose=maestro-gke-test,owner=ivanm-toptal` and stopped by the same command that started
  them; every stretch has a ledger row.
- Two workers at most; models per OPERATING §2.

## 6. Open items for the owner (not blocking the batch)
1. **Approve, re-scope or drop B2 (`H-1-full.md`).** It was written by B1's orchestrator from a defect
   B1 proved, not by the owner, and OPERATING §5 says the owner writes or approves briefs.
2. **Where should H-1's fix live?** These scripts were vendored from `toptal/maestro-k8s`. Fixing them
   here leaves the kit wrong for the next project scaffolded from it; `kit-diff.sh` exists for exactly
   that hand-back and H-1's brief asks the worker to report what it would carry.
3. **`gh`'s token lacks the `read:org` scope.** Harmless to T-1, recorded in ACCESS-REPORT.md; it will
   matter the first time a task reads organisation membership.

## 7. Cost since the previous reset
Zero against the programme's ceilings: no machine was started, no vendor call was made, no model was
under test. The only spend was the agents' own tokens; B1's worker run cost about USD 1.61 over 31
turns, from its own result record.

## 8. Where things are
| What | Where |
|---|---|
| the rules | `docs/OPERATING.md` |
| operational gotchas | `docs/LESSONS.md` |
| briefs | `orchestration/briefs/` (`TEMPLATE.md` is the shape) |
| the launchers | `orchestration/scripts/batch-start.sh`, `batch-resume.sh`, `state-check.sh`, `status.sh` |
| this pod's parameters | `orchestration/local.env` (git-ignored; `local.env.example` documents the keys) |
| results, defects, access | `docs/ledgers/RESULTS.md`, `HARDENING.md`, `ACCESS-REPORT.md` (create on first use; grep by id) |
| machines and their ledger | `docs/ledgers/RESOURCES.md` |
| the session | Maestro remote session `maestro-gke-test-0lpw`, project `toptal-ai-research-staging`, zone `us-east1-b` |
| the index | `docs/README.md` |
| the batch log | `orchestration/QUEUE.md` |
