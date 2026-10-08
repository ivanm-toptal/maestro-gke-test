# Cost control: policies and the janitor

## Policies (non-negotiable in task briefs)
1. Every VM we create carries `--labels=purpose=<project>,owner=<who>`;
   `keep=true` exempts one deliberately (demo day). Borrowed VMs stay
   UNLABELED, so no automation ever touches them.
2. Stop-after-test: any script that powers a VM on wraps the stop in a shell
   `EXIT trap` plus an independent time-budget watchdog, so failures cannot
   leak a running GPU. Restore the power state you found.
3. A `docs/ledgers/RESOURCES.md` ledger row for every resource created or borrowed.
4. Live vendor calls in agent tasks get explicit numeric budgets ("<= 2
   sessions, <= 90s each"), and quota/credit refusals must LATCH (stop trying)
   — a retry loop against a small pool is how the pool disappears.
5. Vendor streaming sessions bill by WALL CLOCK from open to close: open
   explicitly, close explicitly (button, pagehide, server shutdown), send a
   server-side TTL at token time so even SIGKILL cannot leak a billed session.
   Billing posts LATE and fractionally — never trust a balance read right
   after a session.

## The janitor (scripts/gcp-janitor.sh + scripts/janitor-cron.sh)
Label-scoped auto-stop for forgotten GPU VMs. Design points, all learned:
- Only touches instances with the project label; `keep=true` exempts.
- Cron wrapper: hard EXPIRY date after which it posts a disarm notice and
  removes its own crontab entry (no zombie automation).
- Errors are LOUD: any failure (auth expiry!) posts to a GitHub issue and
  writes `~/.gcp-janitor/ATTENTION`. Auth expiry WILL happen on the org's
  cadence — the janitor's job is to surface its own blindness immediately.
- Dead-man's switch: a weekly heartbeat comment; a MISSING heartbeat means the
  janitor died. Absence is the signal a crashed cron cannot fake.
- Caveat: the cron comments as YOU, and GitHub never emails you your own
  comments — the issue is an audit trail, not a push channel. Pair it with
  checking ATTENTION at the start of work sessions.
- Zero LLM involvement: plain bash + one gcloud list + gh. Costs nothing.
- Install, on the box that runs it (never a pod): `JANITOR_LABEL`, `JANITOR_PROJECTS`,
  `JANITOR_GH_REPO` and `JANITOR_ISSUE` on the crontab line, the line tagged `# gcp-janitor-<label>`
  (the expiry removes that line), and `EXPIRES` in the script set to the programme's end.

## Agent-time economics (observed)
Opus-5 agents on well-scoped tasks: scaffold ~$2-6, feature ~$8-23, audits
~$6-17. A day of heavy multi-agent building lands ~$50-60. Cheap next to GPU
hours and human time — but scope tasks tightly and give budgets, because an
unbounded agent will happily spend more.
