# The orchestration scripts: where they come from, how a pod says whose they are, what to adapt

`orchestration/scripts/*` (the kit's own three excepted, marked below) and `scripts/spawn-agent.sh` are copied **verbatim** from
`toptal/ai-avatar-research` (commit a1859c5 of that repository, 25 September 2026), where that programme's workers built
and tested them (tasks G-1, P-1, P-3, P-4, the D series). Verbatim is the design: since task P-4 the
scripts name no project, no GCP project, no machine prefix and no Slack channel. Each pod says whose
programme it is running in **one git-ignored file**, `orchestration/local.env`, which every script
reads through `orch-env.sh`; the committed `orchestration/local.env.example` documents every key. A
hand edit in a copied script is a fork that the next re-vendor overwrites, so there is nothing to
edit in the scripts, and `kit-diff.sh <kit-checkout>` (run from the research repository) says file
by file when the kit has fallen behind.

## The file each pod needs: `orchestration/local.env`

| Key | Meaning | Default |
|---|---|---|
| `ORCH_PROJECT` | the programme's short name, in prompts and the status row | none — required |
| `ORCH_GCP_PROJECT` | the GCP project your machines live in; `status.sh`, `state-check.sh` and the launchers' gate list its instances | none — required once a brief declares machines; `vm-probe.sh --project` records it |
| `ORCH_VM_PREFIX` | the name prefix that makes a machine **ours** (the only machines a launcher refuses to start over) | none — required |
| `ORCH_SLACK_CHANNEL` | the id of `#maestro-<session>`; the launchers post there and tell the orchestrator to | none — required for Slack |
| `ORCH_REPO_NAME` | `owner/name` of the repository | read from `origin` |
| `ORCH_MODEL_ORCHESTRATOR` | the launchers' first model | `claude-fable-5-1` |
| `ORCH_MODEL_FALLBACK` | when that one is refused for usage credits; also the reset drill's | `claude-opus-5` |
| `ORCH_MODEL_WORKER` | `spawn-worker.sh`'s model when the caller names none | `claude-opus-5-5` |

The four without a default have none **on purpose**: a guessed project reports somebody else's
machines as ours, and a guessed channel posts a batch plan into somebody else's session. A script
that needs one and does not have it says so by name (`orch_require`) and refuses; nothing guesses.
The environment wins over the file (`ORCH_GCP_PROJECT=x orchestration/scripts/status.sh` works), the
values are never exported into the agents' environment, and the file is sourced in a subshell so it
cannot set `PATH` or `exit` inside a launcher. `status.sh`'s first row prints what it read and from
which file. The bootstrap writes the file in the pod (`docs/TUTORIAL.md` stage 3); `pod-setup.sh` adds
the Slack channel once `#maestro-<session>` exists, `vm-probe.sh --project` the GCP project.

**Not a parameter: `ORCH_ROLE`.** The launchers run the orchestrator's `claude` with
`ORCH_ROLE=orchestrator`, and `scripts/spawn-agent.sh` runs each worker's with `ORCH_ROLE=worker`, on
the command line and never exported; the verification runner scrubs it. `CLAUDE.md` sends each
conversation to its rules by that value, and a conversation without it, the Maestro session's chat
conversation, to `orchestration/CHAT.md`. It never goes into `local.env`.

## What each script is for

| Script | Role |
|---|---|
| `batch-start.sh --batch <id>` | a batch in a **fresh** conversation: gates (clean state, no machine on, token pinned, no live owner), the standard prompt, the retry ladder |
| `batch-resume.sh` | this batch's conversation back, after a reboot, a limit or an early turn end |
| `batch-chain.sh <id>…` | settle the running batch, then start each id in turn; an evening with nobody watching |
| `batch-lib.sh`, `orch-env.sh`, `run-lock.sh` | shared: the Slack line, the token gate, the model ladder; the parameters; the `mkdir` lock two orchestrators once needed |
| `spawn-worker.sh <name> <brief>` | a worktree from the default branch, its own `.venv`, then `scripts/spawn-agent.sh` (a detached `claude -p` under the pod's tmux server) |
| `verify-detached.sh <branch>` | the branch verified end to end in its own per-run worktree; `--report` answers pass / fail / truncated / running |
| `land-branch.sh <branch> <message-file>` | `--no-ff` merge into the default branch, document conflicts resolved by `resolve-any.py`, code conflicts abort |
| `state-check.sh` | is `docs/STATE.md` still true of this repository? one row per check |
| `status.sh` | what is running now and what is owed, which account the pod is on, and whether the chat conversation is answering |
| `token-guard.sh` | the running Claude token's hash against the pin |
| `bootstrap-session.sh`, `fetch-secrets.sh` | a fresh session made ready (credential files from Secret Manager, `uv sync`, a readiness table) |
| `kit-diff.sh <kit>` | what the kit must re-vendor from this repository |
| `pod-setup.sh` | the kit's own: the pod configures itself from inside (settings, caches, the token pin, `uv sync`) and reports itself (accesses, limits, volumes, model, checkout) in one table; the bootstrap runs it |
| `ssh-key.sh` | the kit's own: your public key(s) from GitHub, or given as arguments, into `~/.ssh/authorized_keys`; checks sshd; prints the laptop's ssh config block |
| `vm-probe.sh` | the kit's own: create, stop and delete an `e2-micro` named `<prefix>probe` with our labels, from the pod's own values; `--dry-run` prints the commands |

## What to adapt for a repository that is not Python

Three scripts assume `uv`, `ruff` and `pytest`: `bootstrap-session.sh` (`uv sync --all-groups`, a
fast test lane), `verify-detached.sh` (`uv sync`, `ruff`, the suite in chunks) and `spawn-worker.sh`
(a `.venv` per worktree via `uv sync`; `SPAWN_WORKER_SYNC_ARGS` narrows it). For another stack,
replace the three calls with your build, lint and test commands and keep the shape: a verification
that runs in its own checkout and ends with a `VERIFY_DONE` line, a landing that refuses code
conflicts, a worker that never shares a working directory. `fetch-secrets.sh` reads three named
credential files (`<prefix>zoom-env`, `<prefix>livekit-env`, `<prefix>liveavatar-key`) from Secret
Manager; keep it as the shape for your project's secrets, or drop it and its two entries from
`.maestro/config.json`.

## Where the values come from

`scripts/bootstrap-repo.sh` (in the kit; the first message runs it) takes the project's name from
`.devcontainer/devcontainer.json` `"name"` (the repository's name when that is missing or a placeholder) and, optionally, the GCP project, zone, machine prefix, size and
storage from its `customizations.maestro-k8s` block (`gcpProject`; `gcpZone` default `us-east1-b`; `vmPrefix`
default `<name>-`; `size`, `storage` defaults `medium`, `40Gi`), the repository from `origin`, the session
from the pod's hostname, the owner from `gh api user`. It writes `orchestration/local.env` from them; `pod-setup.sh`
adds the Slack channel's id once `#maestro-<session>` exists, by resolving the name; `vm-probe.sh --project`
records the GCP project the first time the programme needs machines. The launchers ask for it only when a
batch's briefs declare machines: every brief carries a **Machines** line (`none`, or which machines, in which
project and zone, and the stretch's ceiling), and a brief without the line counts as needing them (P-5, 25
September 2026). A programme whose briefs all say `none` never names a GCP project.

The scaffold also ships `.devcontainer/` — a minimal Dockerfile on the reference programme's base image plus
`uv`; system packages the code needs go there as one `apt-get` layer (the kit's `templates/Dockerfile.example`
is the full, commented one) — and `scripts/gcp-janitor.sh`, the label-scoped auto-stop the house rules name.

It also appends the kit's ignore block to `.gitignore` (`templates/gitignore` in the kit, put there line by line
by `scripts/ignore-block.sh`; lines of your own are kept): what a pod writes into `/workspace` that is not
content — `.maestro/*` except `config.json`, the worker worktrees, the caches `pod-setup.sh` points there, the
editor's server, `orchestration/local.env`, environments, stray secrets. The launchers refuse a batch on any
untracked file, so a new kind of litter is one more line, committed, before the next batch; every first message
appends the block again, so an older repository catches up.
The tutorial's first brief arrives as `orchestration/briefs/T-1-full.md`, already named in `docs/STATE.md` §4
as batch B1; the next brief is written from `TEMPLATE.md`.

`.maestro/config.json` is the research repository's script table plus, written by `new-project.sh`,
your `remote.default_size` and `remote.storage`: the project's default pod size and workspace
volume, honoured by every `maestro start --remote` from this repository. What each script does in
detail is in its own header and in `docs/ops/AGENT-PATTERNS.md` §1.
