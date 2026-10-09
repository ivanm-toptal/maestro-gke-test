# LESSONS — operational gotchas a future orchestrator would otherwise rediscover

One entry per lesson, dated, with the fact and the consequence. Prune an entry when the underlying
cause is fixed in code and say so in the commit. Product defects belong in `docs/ledgers/HARDENING.md`.
The entries below are inherited from the programme this kit was distilled from (August–September 2026);
keep the ones that apply, add your own.

## The pod and the session
- **Pods reboot without warning.** Workers commit and push a WIP as soon as they have read their
  evidence; the orchestrator resumes within the batch.
- **On a CLI-created pod the home volume is small (about 5 GB) and `--storage` sizes the workspace
  volume only; a web-created pod has one volume for both.** Large caches live under `/workspace` either
  way (`UV_CACHE_DIR`, `HF_HOME` exported from `~/.bashrc`; `.caches/` is git-ignored).
- **A pod restart re-injects the Claude token fixed at session creation.** Pin the wanted token's hash
  and let `status.sh` and the launchers check it; every symptom of the wrong account reads as a limit.
- **The container carries `ANTHROPIC_MODEL` and `CLAUDE_CODE_EFFORT_LEVEL` from the session record**;
  the effort variable overrides `modelSettings`. Unset it in `~/.bashrc`; pass `--model` on every launch.

## Limits and models
- **The five-hour window is shared by the orchestrator and its workers.** Fresh conversations per batch
  and grep-not-read for the ledgers are the remedy. Fable says "requires usage credits"; Opus says
  "You've hit your session limit · resets …". The launcher retries every five minutes.
- **A turn in print mode is one turn.** Nothing wakes the orchestrator when a worker or a drill
  finishes; "runs as a background task and will notify me" ENDS the turn. Poll inside a tool call.

## Reaching the pod
- **`ssh pod-<session>` (the kubectl route, `docs/TUTORIAL.md` stage 4.3) is the everyday transport.**
  Host keys change on a pod restart: `ssh-keygen -R pod-<session>` on the laptop, then connect again.
- (CLI route) **`ssh maestro-<session>` (after `maestro open`) beats `maestro exec`**, which leaks a
  process per call; `maestro open` re-pins the host key.
- (CLI route) **`maestro start` and `resume` need a running ssh agent**; a tmux session environment can negate
  `SSH_AUTH_SOCK` — pass the global value on the command line.
- (CLI route) **The CLI's login lives in the kernel keyring** unless `maestro config security --credential-storage
  file`; ssh and cron shells otherwise see "Not authenticated", and the ssh bridge times out.
- **`pgrep -f` matches the shell that runs it.** Bracket the pattern or kill by pid; never `pkill -f`
  with a pattern your own command line contains.

## Coordination
- **Two orchestrators on one batch destroy each other's detached verification** (one fixed worktree
  path per branch). One owner per batch, written into STATE §3 as the batch's first commit.
- **The session's Slack channel is an inlet**: a post there is a prompt to the Maestro session's chat
  conversation, which is not the orchestrator. Steer work through STATE §4 and briefs, between batches.
- **A conversation's role is `ORCH_ROLE`, not its own opinion.** On 30 September the reference
  programme's chat conversation, asked in Slack whether it was the single orchestrator, said yes. The
  launchers set `ORCH_ROLE`, and `CLAUDE.md` sends each conversation to its rules by it.
- **Write STATE §3's `running` line first**, or a conversation that dies early leaves a deadlock: resume refuses
  ("the batch has ended") and start refuses (an unnamed landing).

## The tooling in this repository
- **The tooling says `master`; a repository whose default branch is `main` breaks it in one loud way
  and two silent ones.** 9 October 2026, batch B1: `land-branch.sh` exited 2 at `git checkout -q master`
  before merging anything, so the landing was done by hand with the script's own semantics (fetch,
  `--no-ff` merge with the message file, push, prune). The silent half is the one to watch for, because
  nothing reports it: `status.sh` printed `0 unlanded remote branch(es)` with one unlanded, and
  `state-check.sh`'s "landings in §2" row — the check the whole reset contract rests on — reported `ok`
  on a `git log` that had failed. Until the fix lands (H-1 in `docs/ledgers/HARDENING.md`, batch B2),
  check `git branch -r --no-merged origin/<default>` by hand before believing either row, and expect to
  land by hand. Pass `--base origin/main` to `spawn-worker.sh`, whose `BASE` defaults to `origin/master`.
- **`spawn-worker.sh` runs `uv sync` and this repository has no Python manifest.** `--no-sync` is the
  flag; without it the spawn exits 4 before the worker ever starts. The same goes for
  `verify-detached.sh`, which is built around `uv` and pytest: verification here is a detached worktree,
  the branch's own guard script, and a read of the diff.

## Machines
- **Compute Engine `start` can report DONE without the VM booting** when a zone has no capacity;
  check `lastStartTimestamp`.
- **A laptop-style login has no sudo on a VM**; a script that re-arms `shutdown -P` from there fails
  silently unless it checks. Read the real deadline from `/run/systemd/shutdown/scheduled`.
- **Nothing system-wide is installed on anyone's machine by a task**; user-space only.
