# The index — what is in this repository, who reads it, and how

One table per top-level folder (the repository root first), one row per file or sub-folder. **Who**
says which reader the file is for: *a human browsing*, *an agent on a task* (a worker, or the
Maestro session's chat conversation), or *the orchestrator after a reset* (a fresh batch
conversation whose only memory is this repository). **How** says how much of it that reader takes
in: *whole*, *by section*, or *grepped by task id*. Scripts are run, not read; their rows point at
the header comment, which says what the script does and why.

Where to start: a newcomer reads [README.md](../README.md), then [CLAUDE.md](../CLAUDE.md), then
[STATE.md](STATE.md); an agent reads `CLAUDE.md` and the rules file its `ORCH_ROLE` names there.

Keeping this true: a new document goes into `docs/` and into this index in the same commit
(`docs/OPERATING.md` §6). `bash scripts/check-docs-index.sh` fails when a Markdown file under `docs/`
has no row here, or when this file names a path that is not on disk.

Several documents copied from the kit (toptal/maestro-k8s, cloned to `~/.kit` in every pod) cite
kit-only paths — the tutorial, the ignore-block script, the overview diagram, the janitor cron — which
are in `~/.kit`, not here: `~/.kit/docs/TUTORIAL.md`, `~/.kit/scripts/ignore-block.sh`,
`~/.kit/docs/diagrams/overview.svg`, `~/.kit/scripts/janitor-cron.sh` (defect H-2 in
`docs/ledgers/HARDENING.md`).

## The repository root

| Path | What it holds | Who | How |
|---|---|---|---|
| `README.md` | The front page: the repository's name and a link to this index. | a human browsing | whole |
| `CLAUDE.md` | Every agent's entry point: `ORCH_ROLE` picks the rules file (orchestrator, worker or chat), then the house rules every role follows (access probe, cost, secrets, colleague repositories, craft). | an agent on a task; the orchestrator after a reset; a human browsing | whole |
| `.gitignore` | The kit's ignore block: what a pod writes into the workspace that is not content. Each line is a launch condition, since the launchers refuse a batch on any untracked file. | an agent on a task, when it adds a new kind of litter | whole |
| `.maestroignore` | Maestro's deny-all allow-list (`*`, then `!` entries) that goes with the devcontainer when a session is built (`docs/ops/MAESTRO.md` §1). | a human browsing | whole |

## `.devcontainer/` — the image a Maestro session runs in

| Path | What it holds | Who | How |
|---|---|---|---|
| `.devcontainer/Dockerfile` | A minimal image: the reference programme's Python 3.11 base plus `uv`. System packages the code needs go here as one layer, since anything installed by hand in a pod is lost at the next build. | a human browsing | whole |
| `.devcontainer/devcontainer.json` | The session's build definition: project name, Dockerfile, remote user, and the kit's `maestro-k8s` block (GCP zone `us-east1-b`). | a human browsing | whole |

## `.maestro/` — Maestro session configuration

| Path | What it holds | Who | How |
|---|---|---|---|
| `.maestro/config.json` | The default pod size and storage, and the named scripts Maestro offers (bootstrap, ready, secrets, status, state-check, batch-start, batch-resume, batch-chain, kit-diff). The only committed file in `.maestro/`; the rest is session state and is git-ignored. | a human browsing | whole |

## `docs/` — the programme's documents

| Path | What it holds | Who | How |
|---|---|---|---|
| `docs/README.md` | This index. | a human browsing; an agent on a task | whole |
| `docs/STATE.md` | Where the programme is now: what landed since the last reset, what is in flight, the batch queue, the owner's decisions, open items, cost, and where things are. Rewritten at every batch end. | the orchestrator after a reset; a human browsing | whole |
| `docs/OPERATING.md` | The orchestrator's rules: the commands, the batch cycle, hard rules (spend ceilings, models, two workers at most), the reset contract, briefs, documents. | the orchestrator after a reset | whole |
| `docs/LESSONS.md` | Dated operational gotchas a future orchestrator would otherwise rediscover: the pod, limits and models, reaching the pod, coordination, machines. | the orchestrator after a reset | whole |
| `docs/ledgers/` | Append-only records, one row per task. Never read end to end. | an agent on a task; the orchestrator after a reset | grepped by task id |
| `docs/ledgers/ACCESS-REPORT.md` | What each task's Phase 0 probe found the pod could and could not reach (gh, gcloud, the janitor), by date. | an agent on a task; the orchestrator after a reset | grepped by task id |
| `docs/ledgers/HARDENING.md` | Product defects tasks found, with file:line evidence, consequence and status. | the orchestrator after a reset; an agent on a task | grepped by task id |
| `docs/ledgers/RESULTS.md` | What each task measured (or "measures nothing") and what it produced. | the orchestrator after a reset | grepped by task id |
| `docs/ops/` | The kit's operating knowledge, copied in when the project was scaffolded. The kit's own copy in `~/.kit` is the current one. | a human browsing; an agent on a task | by section |
| `docs/ops/MAESTRO.md` | Maestro as proven in production: sessions, pods and volumes, the four authentications, reaching the pod, models and effort, the orchestrator inside the pod, the web UI's limits, the ssh ProxyCommand. | a human browsing; an agent on a task | by section |
| `docs/ops/AGENT-PATTERNS.md` | Task briefs that work, the batch procedure, shell traps that ate real hours, debugging discipline, live-vendor lessons, half-finished merges. | an agent on a task; a human browsing | by section |
| `docs/ops/GCP.md` | GCP operating knowledge: the three credential stores, identity rules, IAP access, capacity and quota, shared-VM etiquette, Windows client quirks. | an agent on a task; a human browsing | by section |
| `docs/ops/COST-CONTROL.md` | Cost policies (labels, stop-after-test, ledger rows, numeric budgets), the janitor, and observed agent-time economics. | an agent on a task; a human browsing | by section |
| `docs/ops/SHARED-ORCHESTRATORS.md` | How a colleague addresses, resumes or takes over an orchestrated project while its owner is away, and the incident behind each rule. | a human browsing | by section |

## `orchestration/` — the batch machinery: role rules, briefs, launchers

| Path | What it holds | Who | How |
|---|---|---|---|
| `orchestration/WORKER.md` | The rules every worker carries: scope, push early, machines, waits, tests, report. | an agent on a task (every worker) | whole |
| `orchestration/QUEUE.md` | One block per batch, appended at its end: what landed, what it cost, what is next. The past tense of `docs/STATE.md`. | the orchestrator after a reset; a human browsing | by batch id |
| `orchestration/CHAT.md` | The rules for the Maestro session's chat conversation (`ORCH_ROLE` unset): it is not the orchestrator, it turns a wish into a brief and queues it, and it starts a batch only on the owner's word. | an agent on a task (the chat conversation) | whole |
| `orchestration/SEED.md` | The first message of a new session: clone the kit, run its bootstrap, report, then wait for the owner. | a human browsing (who pastes it) | whole |
| `orchestration/PARAMETERS.md` | Where the scripts come from (copied verbatim from the reference programme), the per-pod parameter file they read, what each script is for, what to adapt for a non-Python repository. | a human browsing; the orchestrator after a reset | by section |
| `orchestration/local.env.example` | Documents every key of the per-pod parameter file (the file itself is git-ignored and lives only in the pod): project, GCP project, machine prefix, Slack channel, models. | a human browsing | whole |
| `orchestration/briefs/` | One brief per task: the owner's wish, which the orchestrator expands into a worker's task file. | the orchestrator after a reset | by id (the briefs STATE §4 names) |
| `orchestration/briefs/TEMPLATE.md` | The shape of a brief: why, route, size, the mandatory **Machines** line, branch, evidence, what to do, documents, report. | a human browsing; the orchestrator after a reset | whole |
| `orchestration/briefs/T-1-full.md` | The tutorial's first brief: this index and its guard. | the orchestrator after a reset | whole |
| `orchestration/briefs/H-1-full.md` | B2's brief: make the orchestration scripts true of a repository whose default branch is `main` (defect H-1). | the orchestrator after a reset | whole |
| `orchestration/scripts/` | The launchers and their helpers. Each script's header says what it does and why. | the orchestrator after a reset; a human browsing | by section (header comment) |
| `orchestration/scripts/batch-start.sh` | Starts a batch in a fresh orchestrator conversation, after its gates (clean state, no machine on, token pinned, no live owner); `--drill` runs the reset drill. | the orchestrator after a reset; a human browsing | by section (header comment) |
| `orchestration/scripts/batch-resume.sh` | Brings the current batch's conversation back after a pod reboot, a limit, or an early turn end. | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/batch-chain.sh` | Settles the running batch, then starts each named batch in turn, unattended. | a human browsing | by section (header comment) |
| `orchestration/scripts/batch-lib.sh` | Sourced by both launchers: the token gate, the Slack line, the model ladder, the five-minute retry. | an agent on a task, when changing a launcher | by section (header comment) |
| `orchestration/scripts/orch-env.sh` | Sourced: the one place a script learns whose programme it runs for, from the per-pod parameter file. | an agent on a task, when changing a script | by section (header comment) |
| `orchestration/scripts/run-lock.sh` | Sourced: one lock per branch, so two runs of the tooling cannot destroy each other's work. | an agent on a task, when changing a script | by section (header comment) |
| `orchestration/scripts/spawn-worker.sh` | Gives one worker its own git worktree, its own `.venv`, and a detached console. | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/verify-detached.sh` | Verifies a branch end to end in its own worktree without holding a tool call open; `--report` answers pass, fail, truncated or running. | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/land-branch.sh` | Merges a worker's branch with `--no-ff`, resolves document conflicts, refuses code conflicts, pushes, prunes. Hardcodes `master` (defect H-1). | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/resolve-any.py` | Called by `orchestration/scripts/land-branch.sh` to resolve conflicted documents in a merge, or fail loudly. | an agent on a task, when changing the landing | by section (docstring) |
| `orchestration/scripts/state-check.sh` | Whether `docs/STATE.md` is still true of the repository, one row per check. | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/status.sh` | What is running now and what is owed (machines, unlanded branches, a dirty tree), and which Claude account the pod is on. Read-only. | the orchestrator after a reset; a human browsing | by section (header comment) |
| `orchestration/scripts/token-guard.sh` | Whether the pod runs on the Claude account it should: the running token's hash against the pin. | the orchestrator after a reset | by section (header comment) |
| `orchestration/scripts/bootstrap-session.sh` | The reference programme's session bootstrap (secrets, `uv sync`, a readiness table); here `orchestration/scripts/pod-setup.sh` does that job. | a human browsing | by section (header comment) |
| `orchestration/scripts/fetch-secrets.sh` | Puts the session's credential files on disk from GCP Secret Manager, as the session's own identity. | a human browsing | by section (header comment) |
| `orchestration/scripts/pod-setup.sh` | The kit's own: the pod configures itself (settings, caches, the token pin) and reports its accesses, limits and volumes in one table. Idempotent. | a human browsing | by section (header comment) |
| `orchestration/scripts/kit-diff.sh` | Says, file by file, what the kit must re-vendor from this repository. | a human browsing | by section (header comment) |
| `orchestration/scripts/ssh-key.sh` | The kit's own: adds your public keys to the pod and prints the laptop's ssh config block. | a human browsing | by section (header comment) |
| `orchestration/scripts/vm-probe.sh` | The kit's own: proves gcloud acts as you by creating, stopping and deleting the smallest labelled VM. Spends money; `--dry-run` prints the commands. | a human browsing | by section (header comment) |

## `scripts/` — repository-level tools

| Path | What it holds | Who | How |
|---|---|---|---|
| `scripts/gcp-janitor.sh` | Lists the VMs labelled `purpose=$JANITOR_LABEL`; with `--stop`, stops those that have run for `JANITOR_MAX_HOURS` (default 3) and are not labelled `keep=true`. Touches nothing else. Both `JANITOR_LABEL` and `JANITOR_PROJECTS` are required. | an agent on a task (Phase 0, `--report-only`) | by section (header comment) |
| `scripts/spawn-agent.sh` | Starts a long-running Claude agent under the pod's tmux server, so it outlives IDE disconnects; `orchestration/scripts/spawn-worker.sh` calls it. | an agent on a task, when changing spawning | by section (header comment) |
| `scripts/check-docs-index.sh` | The guard for this index: fails, naming the offenders, when a Markdown file under `docs/` is missing here or a path named here is not on disk. Runs from any directory in under a second. | an agent on a task, before committing a document | run |
