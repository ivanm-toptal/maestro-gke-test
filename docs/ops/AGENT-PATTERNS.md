# Agent patterns: the batch procedure, task briefs, and the traps

## Task briefs that work
- Phase 0 access probe FIRST in every task: gh auth, one cheap gcloud call,
  janitor report. Any auth failure = log it, push, exit nonzero. Fail-loud is
  the house style; a silent retry wastes a night.
- Numeric budgets for anything billable: live API calls, vendor sessions, VM
  powered-on minutes. Include the fallback ("a denial is a REPORTED FINDING,
  not a task failure — exit 0 with the evidence").
- Etiquette rules as HARD RULES when touching a colleague's repo: branch from
  their default branch (CHECK its name — main vs master cost us a run), never
  touch that branch, zero default behavior change (feature gates on an env),
  follow THEIR conventions (read their contract docs first), write
  PR_DESCRIPTION.md into the branch instead of opening a PR, small additive
  diff, no CI edits.
- Secrets: absolute never-print/never-commit rules, key delivered as a FILE
  path outside every repo, defensive .gitignore entries, and a key-leak grep
  in the watcher (run the grep IN the right context — an empty pattern from a
  wrong-host path matches everything and cries wolf).
- Ask for a REPORT structure explicitly (tables, verbatim errors, file:line
  evidence). The agents rise to it — WP-series reports repeatedly contained
  release-blocker finds because the brief demanded adversarial verification.
- A driver script OWNS the enable-flags its guarded components need. A spend
  guard that refuses to run without `ENABLE=1` protects nothing if the guarded
  component ACQUIRES the billable resource (a booked session, a meeting join)
  and only then refuses — the resource is already spent. Put the flags in the
  driver, and make the guard refuse BEFORE acquiring, not after.
- A detached `claude -p` agent is NEVER re-invoked. Tell it in the brief to run
  its own test suite synchronously and wait, and to commit and push after every
  step: one agent "armed a background waiter" on its final suite and ended its
  turn, so the run finished with rc=0 and every change uncommitted in the
  worktree. The status file said success; the branch said nothing happened.
- WHY that keeps happening, and the rule that stops it: a single tool call is
  capped at 10 minutes; a call that runs longer is moved to the background and
  the agent's turn continues without its result, so a full suite that takes 10+
  minutes can never be awaited in one call. Three agents in a row ended their
  turn "waiting for the suite" with everything uncommitted. Brief rule: run the
  suite in chunks that each finish under 9 minutes, sequentially, one chunk per
  call (by directory or file list), read each summary line, never put `&`
  behind pytest. Also: `pgrep -f pytest` matches the agent's own `claude -p`
  command line when the brief text mentions pytest; kill by pid only.
- GCP inside the pod is an injected env token, not an on-disk credential
  file; it expires about an hour after the session (re)start and the refresh
  cron does not update shells that already hold it. Tests that exercise the
  ADC path fail with `invalid_grant` in a container an hour old and pass in a
  fresh one. Verify suites within the hour after a stop+resume, or resume first.

## 1. The batch procedure (the orchestration loop, September 2026)

The orchestrator is an agent in the pod (MAESTRO.md §5). It works in **batches**, and every batch
starts in a **fresh conversation whose only memory is the repository**. Reference implementation:
the programme repository's `orchestration/scripts/` and `docs/{STATE,OPERATING,LESSONS}.md`.

- **The state lives in three files, not in a conversation.** `docs/STATE.md` is short and read
  whole after a reset: where we are, what landed since the last reset (merge hashes), what is in
  flight (empty at a boundary), the batch queue, decisions, open items for the owner, cost, where
  things are. `docs/OPERATING.md` holds the rules (the batch cycle, spend ceilings, the reset
  contract, brief rules). `docs/LESSONS.md` holds operational gotchas only. Ledgers (results,
  hardening, access) are append-only and **grepped by task id, never read end to end** — reading
  them whole is what spent a five-hour window in ninety minutes.
- **Docs are updated at every worker's Done**, not at the end: a new lesson, a coherent progress
  line, the landing's hash in STATE. The explicit goal is that the conversation can be reset at any
  quiet point without losing anything a successor needs.
- **`batch-start.sh --batch <id>`** refuses on an unclean state (an orchestrator conversation running, a
  worker `running`, one of our machines on, `state-check.sh` red), mints a session id and records it,
  seeds the standard prompt (read STATE whole, then OPERATING, then LESSONS, then the briefs STATE
  names; post the plan to the channel; execute; before ending rewrite STATE, commit, push, run
  `state-check.sh`, post one summary; end only at a quiet point), prefers Fable at medium effort and
  falls back to Opus when Fable is refused for usage credits, and retries every five minutes while
  the window is exhausted. **`batch-resume.sh`** resumes the recorded session within a batch (after
  a pod reboot or an early turn end). **`state-check.sh`** is the green gate both ends of a batch
  run: every merge on the default branch since the last reset is named in STATE, no worker is
  `running` that STATE does not list and vice versa, no machine of ours is on, STATE names at least
  one existing brief, the tree is clean and pushed. **`--drill`** starts a throwaway fresh session
  that only reads the documents and writes its account of the state, compared against `status.sh`
  and `git log`; run it every third batch so the reset contract is proven, not assumed.
- **Two workers at most**, each in its own worktree (`spawn-worker.sh`), polled from inside the
  turn every five minutes (`.maestro/run/*.status`), verified then landed (`land-branch.sh`), one
  channel line per landing. A turn never ends while a worker or a machine runs (MAESTRO.md §5).
- **Briefs** are files in `orchestration/briefs/`, one per task, from `TEMPLATE.md`; what one must
  contain is `docs/OPERATING.md` §5 in every project (the same paragraph everywhere). The rule that
  matters: the owner writes or approves briefs; the orchestrator expands them into worker tasks and
  never invents scope.
- **Liveness is read from processes, not from status files alone**: `pgrep` for the orchestrator's
  own `claude --session-id|--resume` line, the launcher's log, `status.sh`. A run killed from
  outside leaves `running` in its status file forever; whoever kills it writes the final line.
- **Reset the conversation on purpose** at batch boundaries, not only when it dies: the cost of a
  long conversation is paid on every turn, and a fresh one that reads STATE is cheaper and safer.

## Shell traps that ate real hours (check every script against these)
1. `pkill -f <pattern>` where the pattern appears in YOUR OWN wrapper's
   command line: the script kills itself mid-run, silently. Kill by port
   (`fuser -k PORT/tcp`) or pidfile instead.
2. `set -e` + `[ -n "$X" ] && break` inside a poll loop: the false test
   aborts the whole script. Keep polls out of set -e or use if-statements.
3. Heredoc/quoting across ssh + docker exec + remote bash (3-4 layers): $VAR
   and $() collapse unpredictably. RULE: anything with substitutions ships as
   a FILE (scp + docker cp + chmod) and runs as a script; only trivial
   commands go inline.
4. sed with slashes/# in patterns corrupts files silently. Use a python
   replace with a count assertion (`assert s.count(bad)==1`) — it refuses to
   half-apply.
5. Backgrounded processes via docker exec die with the exec: use
   `setsid ... < /dev/null &` and verify with a fresh exec afterwards.
6. `env VAR=x script.sh` does NOT override a variable the script hardcodes
   internally. grep the script first.
7. docker exec defaults to root; root can't read vscode's 600-mode files
   (no DAC override in these containers) — pass `-u vscode` for secret work.
8. Truncating diagnostics (`| head -c`, `tail -1`) hides the line you need:
   when a mystery persists two rounds, dump generously once.
9. Editing a script FILE while it is still executing: bash reads a script by
   byte offset as it runs, so an edit mid-run resumes at a shifted offset and
   runs garbage. Finish the run, or copy-then-edit a separate file; never edit
   the file a live process is interpreting.
10. A process whose stdout passes through a wrapper (redactor, tee, filter)
    and is then killed by a signal never flushes its buffer — the log comes
    back EMPTY and the session's record is gone. For any long or interactive
    driver: force line buffering (`PYTHONUNBUFFERED=1` / `stdbuf -oL`) AND give
    the process a SIGINT/SIGTERM handler that flushes its log and releases its
    resource (leave the call, write the ledger row) before exit — a human who
    ends a live session early must lose neither the transcript nor the booked
    resource.

## Debugging discipline
- When two components disagree (200 in one log, error in the other), find the
  EXACT failing frame before theorizing: we blamed a tunnel for what was our
  own shim's missing non-streaming mode, and "moved" infrastructure to fix it.
  The traceback's bottom frame names the caller; read it literally.
- Version skew across sibling repos: an app importing a research package may
  need a specific unpushed BRANCH of it (grep the import, then check which
  branches contain the symbol via the GitHub contents API per branch).
- Distinguish design-guards from bugs: fail-at-boot health checks
  (require_health) are friction for smokes but correct for production — shim
  around them, don't remove them.

## Live-vendor integration lessons (LiveAvatar as the case study)
- Read the vendor's llms.txt / agent docs first; then TRUST THE LIVE RUN over
  the docs: session caps, billing grain, event correlation ids, and error
  shapes all differed from documentation. Budget 1-2 real sessions to learn.
- WebRTC-to-browser vendors bypass server-side network restrictions entirely
  (video flows vendor->browser; the server only pushes audio out over WSS) —
  this can make an "impossible" GCP networking problem irrelevant.
- adaptiveStream + a zero-size video element = video never subscribes
  (chicken-and-egg). Fix the element's size or disable adaptiveStream.
- Concurrent room joins with one identity kick each other: single-flight the
  join, release the flag in `finally`.
- If your audio drives someone else's lip-sync, someone must own each turn:
  an `owns_audio` flag end-to-end, mic floor-hold while the face speaks, and
  session-rollover turns handed to the fallback player IN FULL.

## A dead agent can leave a half-finished merge

When an agent dies mid-task (token expiry, account usage limit, a kill), its
workspace may be mid-merge: `MERGE_HEAD` present, dozens of dirty files, some
conflicts resolved and some not. Spawning the next agent into that state hands
it a puzzle it did not create and a `git merge` that git will refuse
("You have not concluded your merge").

Before re-spawning into a worktree, check and reset (from that worktree):

```bash
cd /workspace
[ -f .git/MERGE_HEAD ] && echo "half-merge present"
git status --short | wc -l
git merge --abort            # print its errors -- never 2>/dev/null here
git reset --hard <last pushed commit> && git clean -fd
rm -f .git/MERGE_HEAD .git/MERGE_MSG .git/MERGE_MODE .git/AUTO_MERGE
```

`git merge --abort` fails when an unstaged edit exists on a file the merge
touched ("Entry 'X' not uptodate. Cannot merge."), and a silenced failure looks
exactly like success. The hard reset is safe only because the rule "commit and
push after every step" means nothing uncommitted is worth keeping. Mark the dead
run's status file finished by hand so an "is anything running" guard is not
fooled, then spawn the continuation on the clean tree.

An account-wide usage limit kills every running agent at once, at the same
second; when it resets, inspect every worktree this way before continuing.

## A turn never ends while a rented machine is powered on

An agent that starts a cloud VM, launches a long job on it and then ends its
turn ("I'll report when the arms close out") has handed the job to nobody. The
run's exit trap stops the machine when the agent's process exits, so the job
dies with it, the partial result never reaches the repository, and the
accounting row for that stretch is left open. Seen twice: a 67-minute stretch
of a powered-on card with no agent on the other end, and a compile arm killed
mid-compile.

Write the rule into every brief that touches a VM:

- a long job on the box is polled from inside the turn — a foreground poll
  under the tool-call cap, repeated as many calls as it takes; never "I'll come
  back to it";
- before the turn ends for ANY reason, the machine is stopped and its stretch
  has a ledger row (start, stop, minutes, what for, stopped by whom);
- the continuation brief's first step is to close the previous stretch's row
  from the cloud provider's own operation records, because the agent that
  opened it is gone.

The orchestrator's independent VM monitor (a poll that emits when the set of
RUNNING instances changes) is what catches the case where all of this fails.
