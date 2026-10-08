# Task <ID>: <one line that says what is true when the task is done>

**Why (who asked, when, verbatim where possible):** the observation or request, and the evidence
already in hand (file, line, event, timestamp). A reader must be able to check every claim here.

**Route** the directories and files the task touches. **Size** one worker-run or a short run;
the spend rules that apply (GPU-hours ceiling and who starts and stops the machine, rooms, joins,
vendor minutes, model calls) or "zero spend". **Machines** none -- or which machines, in which GCP
project and zone, and the stretch's ceiling. MANDATORY: `batch-start.sh` reads it, and a brief without
it counts as needing machines, so its batch needs a recorded GCP project (docs/OPERATING.md section 2).
**Branch** `<kind>/<name>` from the default branch.
**Worktree** the worker's own, via `orchestration/scripts/spawn-worker.sh`.

Run the suite in chunks that each finish under nine minutes, one chunk per call, chunk totals
checked against `--collect-only`; never `&` behind pytest; kill nothing by pattern; commit and push
after every step, and push a WIP as soon as the evidence has been read; a detached run is never
re-invoked.

## Evidence to read first
Paths and sections, by task id where the file is a ledger. Nothing in RESULTS.md, HARDENING.md or
ACCESS-REPORT.md is read end to end.

## What to do
1. Numbered, each item checkable. Say what "done" looks like for each.
2. …

## Documents
RESULTS.md row (what it measures, or "measures nothing"); HARDENING.md row where a defect class is
involved; ACCESS-REPORT.md close-out with the Phase 0 probe and spend; the load-bearing document
the change belongs to (UI-CONTRACT, ARCHITECTURE, WORKER-PROTOCOL, a runbook).

## Report
Proven versus assumed; deviations with one-line reasons; the numbers the task exists to produce;
ruff and chunked-suite exit codes; `git status --short` empty.
