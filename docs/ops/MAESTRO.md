# Maestro: operating knowledge for an orchestrator in a remote session

Facts proven in production, August–September 2026, against Maestro CLI 0.10–0.12 (0.12.1 on 24
September 2026; the picture of the whole is `docs/diagrams/overview.svg`). Every claim here
cost a real failure to learn. The model this document assumes: **one orchestrator agent runs inside
a Maestro remote (GKE) session and spawns its worker agents in the same pod**; a Linux box or laptop
is only where the owner types `maestro` commands. The older model — Docker containers on the owner's
hardware as workers, an orchestrator outside Maestro — was retired on 18 September 2026 and is not
described here.

## 1. Sessions, pods and volumes
- A session is a devcontainer built from the repo's `.devcontainer/devcontainer.json` plus
  `.maestroignore` (deny-all allow-list: `*` then `!` entries). Code is mounted, not baked. A
  repository without a `devcontainer.json` cannot start a session, the web UI's Custom Repository
  included: commit one first (this kit's own `.devcontainer/`, copied as it is; the bootstrap fills in the name).
- `maestro start <name> --remote --size <small|medium|large> --storage <n>Gi -b -p "<seed>"`
  starts detached with the first prompt submitted. `--storage` sizes the **workspace** volume only;
  the **home** volume is about 4.9 GB. Every large cache goes under `/workspace`
  (`UV_CACHE_DIR=/workspace/.caches/uv`, `HF_HOME=/workspace/.caches/hf`,
  `PLAYWRIGHT_BROWSERS_PATH=/workspace/.caches/ms-playwright`, exported from `~/.bashrc` by
  `pod-setup.sh`), or `uv sync` fails on space. Cursor's remote server also lands on the home volume
  by default (`~/.cursor-server`: 2.3 GB on 24 Sep 2026, most of it the ChatGPT and Claude Code
  extensions) and filled it: Cursor's connect then failed twice with `tar: … No space left on device`
  and got through on the third try only because space had been freed in between. Point Cursor at the
  workspace volume **before the first connect**, in the laptop's Cursor `settings.json`:
  `"remote.SSH.serverInstallPath": {"<ssh alias>": "/workspace"}` (the server then lives in
  `/workspace/.cursor-server`; VS Code's Remote-SSH has the same setting). On an existing pod, add the
  setting, reconnect once, then delete the old `~/.cursor-server`. Check with `df -h /home/vscode`.
- **Sizes** (`maestro sizes`, 24 Sep 2026): nano 0.25–1 CPU / 1–2 GiB / 10 Gi workspace ($17 a
  month), micro 0.5–2 / 2–6 / 10 Gi ($28), small 1–4 / 4–12 / 10 Gi ($52), medium 2–8 / 8–24 / 20 Gi
  ($100), large 4–16 / 16–48 / 50 Gi ($196), xlarge and 2xlarge above that; `*-guaranteed` variants
  at request = limit. **nano is the default wherever no size is given, and every web-created session
  gets it** unless an admin configured the package (Admin → Package Sizes). `maestro config compute
  --size <s>` and `maestro config storage --size <n>Gi` write the committed `.maestro/config.json`
  (`remote.default_size`, `remote.storage`), which every CLI launch from the repository honours; the
  kit's `new-project.sh` writes them from `SIZE` and `STORAGE`. The web UI does not read them.
- Remote sessions are reaped after about four hours idle unless `maestro sessions keep-alive --on
  <name>` (the web UI's Persist toggle is the same switch; Maestro's Persist confirmation quotes roughly
  $45 a month for an always-on session, its sizes table $17 for a nano at 730 hours).
  The web UI shows a reaped or sleeping pod as a yellow dot with a Restart button. A **web-created**
  session that stays stopped for 30 days is deleted with its volumes and its conversation; a
  CLI-created one is kept indefinitely.
- **Pods reboot without warning** (seen mid-tool-call, orchestrator and workers gone together;
  `uptime -s` and PID resets prove it; keep-alive does not prevent it). Workers therefore commit and
  push a WIP as soon as they have read their evidence, and the orchestrator resumes within the batch.
- A **restart** (reboot, `resume --latest`) re-injects the Claude token fixed in the session record
  at CREATION; a plain stop/resume keeps the home volume's token file. See §2.2.
- SSH host keys change on every restart: `maestro open <name>` re-pins the alias on the box that
  runs it; a laptop runs `ssh-keygen -R <alias>`.
- Session names are cluster-wide unique. Clone mode checks out the remote's default branch. There
  is no `--dry-run`. `maestro run` was removed in 0.10.0; scripts run over ssh or `maestro exec -s`.
- In-container user is `vscode` (uid 1000). No docker-in-docker. Servers bind `0.0.0.0`; reach them
  through ssh tunnels on the alias.

## 2. The four authentications
Four different credentials fail in four different ways. Diagnose which before fixing anything.

### 2.1 The CLI's own login (`maestro auth login`; CLI route only)
On the tutorial's route there is no CLI: Maestro holds the token and the connectors server-side (§8).
- SSO through the browser; renews silently while it can, and expires on the org's schedule. When
  it has expired every CLI call says "Not authenticated" and the ssh bridge to the pod
  (`maestro.toptal.net/api/auth/k8s-credentials`) times out, which looks like a platform outage.
  `curl -sI https://maestro.toptal.net` returning 200 while the CLI fails is the tell: re-login.
- The JWT lives in the **kernel session keyring** of the login session that ran the command, so
  ssh, cron and other tmux servers see "Not authenticated". Either run CLI commands inside that tmux
  server (`tmux -S <socket> new-window -d "<cmd> > out"`) or, once, switch to
  `maestro config security --credential-storage file`, which puts it in `~/.maestro/credentials.json`.
- Try the login yourself before escalating; only a real SSO prompt needs the owner. An assistant
  running under a permission classifier may be refused the switch to file storage; the owner runs it.
- `maestro start` and `maestro resume` REQUIRE a running ssh-agent (`SSH_AUTH_SOCK`), and a tmux
  **session** environment can negate the variable the global environment has. Read the global value
  (`tmux -S <sock> show-environment -g SSH_AUTH_SOCK | cut -d= -f2-`) and pass it on the command line.
- `maestro` is not on PATH in non-interactive shells: call `~/.maestro/bin/maestro` by path or export
  the PATH at the top of every script; "command not found" in a script's output means nothing happened.

### 2.2 The Claude token the agents run on
- **Two stores, one per surface.** A **web-created** session takes the Claude token from the web UI's
  **Settings → Claude Code** (paste the output of `claude setup-token`, Test, Save; held server-side
  with the connectors and GitHub, injected at creation). A **CLI-created** session takes it from the
  machine that runs `maestro start`: `maestro config claude --oauth-token "$(claude setup-token)"`
  stores it there. Configure both if you use both surfaces. Either way the in-container `claude` is a
  wrapper that reads `~/.maestro/claude_token` on every launch. Make the
  setup-token on the **account whose models and limits you want**: models differ per account
  (Fable is not on every plan), and so do the five-hour windows.
- The token is fixed in the session record at CREATION. A pod restart re-injects THAT token even if
  the file on the home volume was changed since. Re-inject the wanted one by streaming it over the
  ssh channel's stdin (never as a command-line argument, never printed) and keep a guard file with
  its sha256 (`~/.maestro/expected_claude_token_sha256`); a `token-guard.sh` compares the running
  token's hash against it and `status.sh` prints `token: ok|MISMATCH`.
- **Two reset clocks that disagree mean two accounts.** "requires usage credits" (Fable) or "You've
  hit your session limit · resets HH:MM" (Opus) while the owner's usage page shows a few percent
  means the pod is on a different account than the owner is looking at. Check the guard before
  believing a limit.
- The five-hour window is shared by the orchestrator and every worker on the same token. An Opus
  orchestrator on a multi-megabyte conversation plus two Opus workers spent one in ninety minutes.
  Fresh conversations per batch and grep-not-read for the ledgers are the remedy (AGENT-PATTERNS §1).
- `maestro-runtime refresh-token` never fetches a Claude token; it renews connector tokens only.

### 2.3 GCP inside the pod
- `gcloud` uses the owner's own OAuth (`cloud-platform`) injected as a connector token, refreshed
  per exec; ADC resolves to a workload identity minted from the session. An expired CLI login (§2.1)
  makes every ADC call fail with `invalid_grant: ID Token ... is stale to sign-in` while the
  connector token FILE (`~/.maestro/gcp_token`) keeps refreshing and hides it. Cure: `maestro auth
  login`, then `maestro stop <name>` and `maestro resume <name> -b`; `maestro-runtime refresh-token`
  does not fix it. Check `maestro auth status` first whenever ADC fails.
- `gcloud compute ssh` from a laptop or a dev box logs in under the caller's username with no sudo;
  a control-plane VM's files belong to the owner's user. Log in as `<owner>@<vm>` and drop `sudo`.
- Enabling a cloud API needs a role the owner may not hold on every project; check `gcloud services
  list --enabled` per project first.

### 2.4 GitHub, Slack and the other connectors
- `maestro-runtime connector-probe` says what works. Push identity comes from the connector; a
  commit stamped with an address the owner's GitHub account keeps private is **rejected on push**
  ("push declined due to email privacy restrictions") — use the noreply identity the repo is
  configured with and never override `user.email`.
- **Slack is two things.** The **Slack app** (the Maestro bot, added in Slack via the AI agents icon) is
  the inbound side: on 15 September 2026 it offered to create a channel for the session and made the
  private `#maestro-<session>` (members: the owner and the app; topic: owner and the session's link).
  An `@Maestro` mention there, or a reply in one of its threads, is delivered to the session's
  **chat conversation** as a prompt (not to an orchestrator; its rules are `orchestration/CHAT.md`) and answered in a thread; messages sent while a turn runs
  join the session's queue, shared with the web chat. The **Slack connector** (a preview feature) is
  the outbound side: it ships a pre-authenticated `slack` CLI (`slack auth-test`, `slack
  chat-post-message --channel <C…> --text …`) that acts under the **owner's** user token, so every
  line the orchestrator posts appears as the owner. Posting needs the read-write grant, which the
  owner does once (`maestro connectors slack auth login --readwrite`); a session keeps the token it
  fetched and sees a new grant only after `~/.maestro/slack_token{,_meta}` are dropped. The pod has
  no notion of "its" channel: the id goes into `orchestration/local.env` (`ORCH_SLACK_CHANNEL`), and
  the launchers refuse to guess one. Never a self-DM: that is the owner talking to themselves, and
  every other pod of theirs would post there too (the readiness line of 15 September did).

## 3. Reaching the pod (CLI route; the tutorial's kubectl route is §9 and `docs/TUTORIAL.md` stage 4.3)
- `maestro open <name>` writes an ssh alias; **`ssh <alias>` beats `maestro exec`**: exec leaks a
  process (and a tmux window) per call, and forwards stdin only on remote sessions. Stream secrets
  over ssh stdin; run scripts by copying a file over and executing it, never as nested quoted
  strings (ssh → bash -lc → $(...) breaks silently).
- The bridge times out intermittently even when everything is healthy: wrap pod ssh in a short
  retry loop and distinguish it from the expired login of §2.1.
- **IDE attach**: Cursor or VS Code reach the pod through Remote-SSH on the alias (the Dev
  Containers extension is for local Docker and does not apply). Install the Claude extension "in
  SSH: <alias>"; that is the correct install state. Open `/workspace`.
- The orchestrator's headless `claude -p` transcripts do not appear in the extension's `/resume`
  picker (their records are not indexable); resume by explicit session id, which the launcher
  records in `.maestro/orchestrator-session`.
- Single files cannot be mounted into a pod (mounts are folders and live only while the CLI is
  attached), so credential files come from a secret store fetched at session start
  (`fetch-secrets.sh` pattern). The owner creates the secrets; the pod reads them.

## 4. Models, effort and permissions
- `~/.claude/settings.json` `modelSettings` (per-model effort) and `permissions.defaultMode:
  bypassPermissions` belong in the **user** settings in the pod's home; the container environment
  carries `ANTHROPIC_MODEL` and `CLAUDE_CODE_EFFORT_LEVEL` from the session record fixed at creation,
  and the effort variable overrides `modelSettings`. `~/.bashrc` unsets it and sets the model; pass
  `--model` explicitly on every launch line anyway. `CLAUDE_CODE_SUBAGENT_MODEL` pins subagents.
- Fable reports an exhausted window as "requires usage credits"; Opus as "You've hit your session
  limit · resets …". A print-mode run exits non-zero on either; the launcher retries in five minutes
  and falls back from Fable to Opus (AGENT-PATTERNS §1).

## 5. The orchestrator inside the pod
- **A turn in print mode is one turn.** Nothing wakes the orchestrator when a worker finishes;
  "waiting for the background waits to report" as a message ENDS the process with exit 0 and orphans
  every worker. Waits happen inside a tool call (a bounded poll, repeated as many calls as it takes),
  never as a message, and a turn never ends while a worker or a rented machine runs.
- Transparency, because the web UI does not show whether the conversation is alive: `status.sh`
  (workers from `.maestro/run/*.status`, machines from `gcloud`, the token guard), `pgrep -f
  "claude --(session-id|resume) [0-9a-f]{8}-"` for the orchestrator itself, the launcher's log in
  `/tmp/batch-<id>.log`, and one Slack line per landing. A quiet Slack plus an exited launcher plus
  workers still `running` means the orchestrator ended its turn early: `batch-resume.sh`.
- `pgrep -f` matches the shell that runs it; put a bracket in the pattern (`826153d[0]`) or kill by
  explicit pid; `pkill -f` from an ssh shell has killed the shell.
- Workers: one worktree per worker (`spawn-worker.sh`), never two agents on one worktree, `--model`
  pinned, commit and push after every step, a detached run never re-invoked, suites in chunks that
  each finish under nine minutes (a tool call is capped at ten and a longer one is backgrounded
  without its result).

## 6. Diagnosing in one line
- Pod alive? `ssh <alias> uptime -s`. Orchestrator alive? the `pgrep` above. Account right?
  `token-guard.sh`. CLI login alive? `maestro auth status`. Platform alive? `curl -sI` on the
  Maestro host. Limits? the error string names the model, the guard names the account.

## 7. Starting a programme's session with the CLI (the checklist that worked; the web route is `docs/TUTORIAL.md`)
1. Owner, once: `maestro auth login`; `maestro config security --credential-storage file`;
   `maestro config claude --oauth-token "$(claude setup-token)"` on the account with the wanted
   models; the secrets in the secret store; the Slack read-write grant.
2. `maestro start <name> --remote --size large --storage 100Gi -b -p "$(cat seed.md)"` with
   `SSH_AUTH_SOCK` set; the seed prompt reads a handover file, runs the bootstrap script, posts one
   readiness message to the channel and **waits for an explicit word** before spawning, merging or
   spending. `maestro sessions keep-alive --on <name>`; `maestro open <name>`.
3. In the pod: the same first message as the web route (`templates/orchestration/FIRST-MESSAGE.md`, as
   the seed) runs the bootstrap — the layer, `pod-setup.sh`, `orchestration/local.env`; the Slack channel
   is found by name once it exists (`templates/orchestration/PARAMETERS.md`). Then `batch-start.sh
   --batch <id>` for every batch.

## 8. Without the CLI: what the web UI can and cannot do (verified 24 September 2026)
- **Create a session on any GitHub repository**: New Session → package "Custom Repository" → the
  repository URL → first message. No model, size, storage, branch or persist field on the form (the
  model is Maestro's default for web sessions):
  defaults apply (size `nano` unless an admin configured the package; the default volume); Persist is
  toggled on the session page afterwards. Sessions from the web UI and the CLI are the same kind;
  `maestro open` on a CLI machine reaches either. A web-created session resolves its Claude token,
  GitHub credential and connectors **server-side** from what Settings holds; a CLI-created one takes
  them from the launching machine's Maestro configuration (connectors are server-side either way).
- **Talk to the chat conversation** on the session page. It is the same conversation the Slack
  channel feeds (§2.4), and it is not the orchestrator: a message there is a prompt, with the same one-owner rule while a batch runs.
- **The API behind both** is `https://maestro.toptal.net/api/graphql`, called with the JWT from
  `maestro auth login` (the CLI's `sessions` commands) or the browser session (the web UI). Scripting
  it without the CLI is possible and unsupported; the CLI is a static binary under `~/.maestro/bin`.
- **Only with the CLI**: `ssh maestro-<session>` and the IDE through `maestro open` (the ProxyCommand is
  the CLI; the `kubectl` route of §9 is the CLI-free alternative), `logs`, `exec`, `keep-alive` from a
  script, and a pod size or storage of your choice at creation: the web UI gives the package default
  (nano unless an admin set one), and the committed `.maestro/config.json` counts for CLI launches only.
- **A web-created session, seen on 25 September 2026** (`test-maestro-00-d8jx`, from a README plus
  devcontainer repository): Maestro named it after the repository plus a suffix; the chat conversation
  ran Sonnet 5 with `ANTHROPIC_MODEL` unset; the pod's global git identity was the owner's Toptal
  address, which GitHub refuses on push ("email privacy restrictions"), so the bootstrap sets the
  noreply one; `gcloud auth list` showed `maestro-session-p1@toptal-maestro.iam.gserviceaccount.com`
  as the active account while an instance list in the owner's project succeeded through the
  connector; `nproc` and `free` report the node (8 CPU, 31 GiB), the cgroup files hold the pod's
  limits, and they said nano: 1 CPU, 2 GiB; `/workspace` and `/home/vscode` were two directories of one
  128 GB network volume (NFS, the session's PVC), not the block volumes with the separate 4.9 GB home
  that CLI-created sessions had on 24 September; the first message was delivered twice (queued at
  creation, then sent again).
- **The pod carries the Maestro CLI too** (0.9.1 on 24 Sep 2026 in a pod created by CLI 0.10; authenticated
  as the owner through `MAESTRO_JWT`), and the docs say a session can create and manage sessions. Whether a
  nano web-created session can start a larger sibling from inside — the size escape hatch for the no-CLI
  route — is untested.
- **The pod sets itself up from inside** when told to: `orchestration/scripts/pod-setup.sh` (settings,
  caches, the token pin, `uv sync`) is what the bootstrap runs, and stage 3.4 by hand, so a web-created
  session needs nothing from a laptop. Every session takes the same first message
  (`templates/orchestration/FIRST-MESSAGE.md`), which runs `scripts/bootstrap-repo.sh` in the pod: the
  facts from the pod and from `.devcontainer/devcontainer.json` (`name`; an optional `customizations.maestro-k8s` block for defaults), the layer scaffolded if missing (default branch for a new repository, a branch for an
  existing codebase), pod setup, probes, a table. The pod clones the kit with the owner's GitHub
  credential, so the kit must be readable by them.
- **Which Claude account a web-created session spends** (answered 24 September from the Maestro docs):
  the token saved in **Settings → Claude Code**, injected at creation; a CLI-created session carries
  the launching machine's `maestro config claude --oauth-token` instead. **Settings → Usage** shows the
  five-hour and weekly allowance left per connected provider, which is where to look before believing
  a limit message.

## 9. The ssh ProxyCommand: what it is, and where it can live (24 September 2026)
`maestro open <session>` writes an ssh alias whose transport is
`ProxyCommand "~/.maestro/bin/maestro" ssh-proxy --session <session>` — the CLI's own words: "Internal
SSH ProxyCommand bridge to a remote session pod". It authenticates to maestro-api with your Maestro
login (a 24-hour JWT, renewed for 30 days), obtains short-lived Kubernetes credentials (the brokered
`maestro-cli-remote` service account, or your own kubeconfig if you hold one), and opens an exec-style
channel **through the Kubernetes API server** to the pod's `sshd` (which listens inside the pod; the
session key `maestro open` installed is the one line in `~/.ssh/authorized_keys`). The API-server route
is why it works at all: each pod has a NetworkPolicy that refuses direct connections from anything but
Maestro's own components. Nothing else about it is special, and nothing about it needs to run on your
laptop — only *somewhere* that has the CLI and your login. Five places it can live:

| Where the bridge runs | What you need | Cursor/ssh? | Notes |
|---|---|---|---|
| Your laptop | the CLI (`curl -fsSL https://maestro.toptal.net/install.sh \| bash`, or `irm https://maestro.toptal.net/install.ps1 \| iex`), `maestro auth login`, `maestro open` | yes | user-space, `~/.maestro/bin`, no admin rights; `MAESTRO_NO_MODIFY_PATH=1` leaves your shell config alone |
| A box you own (the owner's headless server) | the CLI and your login there; on the laptop `ProxyJump <box>` to the alias | yes, two hops | the reference setup; the laptop has no Maestro |
| A shared jump VM in GCP | one small VM, the CLI installed once, each person's own `maestro auth login --no-browser` (headless prints the URL) and `--credential-storage file` under their own Unix user; reached over IAP or a tailnet | yes, two hops | "the owner's box, for everyone"; official transport, so it survives the Maestro team's tightening of cluster permissions |
| Nowhere: `kubectl` instead | `gcloud` + `kubectl` + the GKE auth plugin, and your Google identity's access to cluster `prod-1` in project `toptal-maestro` (every Maestro user's group holds `edit`); `ProxyCommand kubectl -n sessions-prod exec -i -c main maestro-<session>-0 -- socat - TCP:127.0.0.1:2222` (sshd listens on **2222**, user `vscode`); your own public key appended to the pod's `~/.ssh/authorized_keys` once | yes | **verified 24 Sep 2026** from the owner's box: `get pod`, `exec` and a full ssh login through the bridge worked. Caveats: the same role sees and can `exec` into every session pod in the namespace (305 that day), which is exactly what the docs say is being narrowed toward the brokered identity — so a fallback, not a design; `kubectl` needs `gke-gcloud-auth-plugin` (a component of a user-space gcloud SDK install; the snap package lacks it — a 1-hour `gcloud auth print-access-token` in a private kubeconfig works for a test). Verified the same day from a Windows laptop with no Maestro installed: Cursor attaches to the pod through it (`docs/TUTORIAL.md` stages 1.5, 1.6 and 4.3 for the Windows specifics) |
| Nowhere: the web UI | a browser | no | the session page's chat and its terminal reach the pod; batches start from the terminal; no IDE |

Not options: a tunnel opened from inside the pod (Tailscale, cloudflared, `ssh -R`) would bypass the
cluster's isolation; do not build on it without the Maestro team.

Scripting session creation without the CLI: `POST /api/v1/sessions` (401 without a token; fields
include `package`, `agent_type`, `herdr_control`) and the GraphQL endpoint behind the web UI both take
the Maestro JWT. There is no documented personal API token yet; ask in `#-maestro-help`. Every pod
carries the CLI (nested sessions), so an existing session can create and manage sessions too.


## 10. CLI 0.12 (23 September 2026): what changed that matters here (CLI route)
- `maestro start --teams <team>` injects a team's shared configuration (defaults, and secrets fetched
  at the moment of use with `maestro-runtime with-secret`) into a session. Shared *settings*, not a
  shared *session*: ownership of a remote session is still per person (SHARED-ORCHESTRATORS §5).
- `maestro sizes` lists the sizes with their monthly cost; `maestro list` reports the same states as
  the web UI (`creating`, `running`, `stopped`, `failed`) and includes stopped sessions.
- An experiment (`remote_server_side_lifecycle`) makes `maestro start --remote` create the session
  through the API like the web UI does; while it is on, per-agent workspace settings (model, effort)
  are not forwarded, which is one more reason the launchers pass `--model` explicitly.
- `maestro check-updates` said 0.12.3 was available on 24 September; the installer line in §9
  updates in place.
