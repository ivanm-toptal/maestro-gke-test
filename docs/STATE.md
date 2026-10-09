# STATE — where the maestro-gke-test programme is, for whoever reads this next with no other memory

Short, and read whole after every reset. Rewritten at every batch end; sections 2 and 3 updated at every
landing. Ledgers are elsewhere and grepped by task id. Reset contract: docs/OPERATING.md §4.

**Last reset:** 2026-10-08, the scaffold — section 2 counts landings from `f61ec8d`, the commit the layer was added onto; no batch has run yet.

## 1. Where we are (three sentences)
The programme was scaffolded from toptal/maestro-k8s on 2026-10-08 by ivanm-toptal. Nothing has been built yet. The
first batch is the tutorial task T-1.

## 2. Landed since the previous reset (`<scaffold commit>`, the scaffold)
Nothing yet. Format when there is: **B<n> merges, in landing order:** `<hash>` (one line on what it
did). **Direct commits, all documents:** `<hash>` … `state-check.sh` polices merges only.

## 3. In flight (must be empty at a batch end)
**Batch B1: running** — started 2026-10-09 11:36 UTC, session 782f746d-88da-4ec2-878b-3720c19c5dfe, pod maestro-gke-test-0lpw, owner ivanm-toptal. (The literal `running`, later `ended`, is the anchor the launchers read.)
- Workers: running — `docs-index` (T-1, branch `worker/docs-index`, worktree `/workspace/.worktrees/docs-index`, model claude-opus-5-5).
- Machines: none; no brief of B1 declares any (every **Machines** line says `none`).
- Worktrees: `/workspace/.worktrees/docs-index`.

## 4. The batch queue
### Batch B1 — T-1 alone (the tutorial task)
1. `T-1-full.md` — the tutorial task: a human-readable index of the repository, zero spend.
### Unscheduled — proposals awaiting the owner's pick
(none)

## 5. Decisions the owner has taken (do not re-open)
- Coding is done by workers in their own worktrees, never in the orchestrator's checkout.
- Machines are labelled `purpose=maestro-gke-test,owner=ivanm-toptal` and stopped by the same command that started
  them; every stretch has a ledger row.
- Two workers at most; models per OPERATING §2.

## 6. Open items for the owner (not blocking the batch)
(none)

## 7. Cost since the previous reset
Nothing spent.

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
| the session | Maestro remote session `maestro-gke-test-0lpw`, project `(not recorded yet: vm-probe.sh --project writes it to orchestration/local.env)`, zone `us-east1-b` |
