# Covering for each other: how a colleague addresses, resumes or takes over an orchestrated project

The goal from the 18 September meeting: when any one of us is away, the others can continue the work
and run the demos. This document says what makes that possible, what the rules are, and what is still
open with the Maestro team.

## 1. The design fact that makes it possible: the repository is the handover

Nothing the orchestrator needs lives in a conversation or on anyone's laptop. Every batch starts in a
fresh conversation whose only memory is the repository: `docs/STATE.md` (where we are, what landed,
what is in flight, the queue), `docs/OPERATING.md` (the rules), `docs/LESSONS.md` (gotchas), the briefs
in `orchestration/briefs/`, and the launchers in `orchestration/scripts/`. Secrets live in Secret
Manager, keyed to the GCP project, not to a person. Runbooks for demos (start the machines, bring the
stack up, take it down) are scripts in the repository, not knowledge in a head.

So a colleague with three accesses — the repository, the GCP project, a Claude account — can start
**their own** Maestro session on the same repository and run the same launcher. The orchestrator that
wakes there is as competent as yours, because it reads the same files.

## 2. Three ways to address a colleague's project, from cheapest to fullest

| Need | Do this | Notes |
|---|---|---|
| Ask a question, have a demo run, or say go between batches | `@Maestro …` in the session's Slack channel `#maestro-<session>`, or a reply in one of its threads (a private channel: the owner and the Maestro app are its members, the owner invites you), or type in the Maestro web UI if the owner shared their screen | The message is delivered to the Maestro session's **chat conversation**, not to an orchestrator (`orchestration/CHAT.md`), as a prompt and answered in a thread; while a turn runs it waits in the session's queue. Questions, demos, wishes for work and go; while a batch runs it answers questions and holds new work until the batch ends (see §4). |
| Read the state | `docs/STATE.md` §1 and §4 on the default branch | No pod needed. |
| Continue the work | Start your own session on the repository and run `batch-start.sh --batch <next>` | Only when STATE §3 says no batch is in flight; the gate refuses otherwise. |

Maestro sessions are owner-gated server-side (CLI 0.11.1 has no share command), so nobody can `ssh`
into a colleague's pod or resume their conversation. That is fine: the pod is disposable, the
repository is not.

## 3. Taking over a project while the owner is away (the procedure)

1. **Access.** Repository write access; the GCP project roles listed in `PREREQUISITES.md`; for
   projects with secrets, `roles/secretmanager.secretAccessor` on that project. Your own Claude token
   (`claude setup-token`) — your account pays for your pod's agents.
2. **Is a batch in flight?** Read STATE §3 on the default branch. If it names a running batch and a
   session, the owner's pod may still be working: wait, or confirm with the owner that their pod is
   stopped. Never start a second orchestrator on a batch that has one.
3. **Your session.** In the web UI: New Session → Custom Repository → the repository's URL → the first
   message (`templates/orchestration/FIRST-MESSAGE.md` in the kit; the repository's `orchestration/SEED.md`
   is the same text) → Persist on (`docs/TUTORIAL.md` stage 3). The bootstrap it runs writes your pod's
   `orchestration/local.env`, and `pod-setup.sh` finds your channel by name once the Maestro app has
   created it (stage 4.2). CLI route: `maestro start <project>-<you>-00 --remote --size medium --storage
   <n>Gi -b -p "$(cat orchestration/SEED.md)"`, then `keep-alive --on`, `maestro open`.
4. **Continue.** `batch-start.sh --batch <next id>`; the gate checks STATE against the repository and
   refuses if they disagree. Fix the document, not the check.
5. **Leave it as you found it.** STATE rewritten at the batch end, machines off, `state-check.sh`
   green, the summary line in the channel. When the owner returns, their pod resumes on the same
   repository with a fresh conversation, as always.

## 4. The rules, and the incident behind each

- **One owner per batch.** Two orchestrators on one batch destroyed each other's verification runs
  on 18 September (LESSONS "Two orchestrators"). The launcher records the owner; P-3 makes it refuse
  a second one, including from another pod, by writing the owner and session into STATE §3 as the
  batch's first commit.
- **The session channel is an inlet.** A post in `#maestro-<session>` is a prompt to the chat
  conversation, which is not the orchestrator. Use it to ask and to demo; steer work through STATE §4 and briefs, between batches.
- **Your token, your spend.** Each pod runs on its owner's Claude account. Cost rows in STATE §7 say
  whose pod ran a batch.
- **Machines carry `owner=` and `purpose=` labels** and every stretch has a ledger row; the janitor
  stops what is left on. A colleague never stops a machine that is not labelled with the project.
- **Nothing system-wide on shared boxes; nothing hardcoded to a person's hardware.** Machines outside
  GCP are parameters (`EXTERNAL_HOST`), never names in the tree.

## 5. Open with the Maestro team

- Sharing a remote session between owners (read-only or full) — not in CLI 0.12.1 either; the web UI
  may grow it. CLI 0.12 adds `maestro start --teams <team>`, a team's shared *configuration* (defaults
  and secrets) injected into one's own session — not a shared session. Until then the repository is
  the shared surface, and the channel is where a colleague asks.
- The Slack connector is a preview behind a feature flag; ask for it to be enabled for the team if
  the channel is to be the common way to address orchestrators.

## 6. Reaching a pod from a laptop that has no Maestro CLI
The tutorial's route is `kubectl` against the cluster with your own Google identity (`docs/TUTORIAL.md`
stage 4.3; `docs/MAESTRO.md` §9; verified 24 and 25 September from Linux and from a Windows laptop with
no Maestro at all). It rides a broad cluster role the Maestro team is narrowing, so the fallbacks, in
order: the web UI's chat and terminal (nothing to install; no IDE); a shared jump VM where the CLI and
each person's login live (Cursor works over `ProxyJump`); their own installed CLI after all (a user-space
binary, no admin rights). The jump VM is the team answer to "everyone can work from anywhere": one
machine, every login, the official transport.

