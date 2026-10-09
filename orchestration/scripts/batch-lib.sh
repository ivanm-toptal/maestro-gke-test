#!/usr/bin/env bash
# batch-lib.sh — what batch-start.sh and batch-resume.sh both do.
#
# Sourced, never executed. The two launchers differ only in WHICH conversation
# they talk to and WHAT they say to it; everything around that -- the token gate,
# the Slack line, the Fable-first/Opus-fallback ladder, the five-minute retry
# while the account's window is shut -- is identical, and identical code that
# exists twice drifts. The fallback ladder in particular is the piece nobody
# would notice was subtly different until the one night it mattered.

#: WHOSE PROGRAMME THIS IS comes from orchestration/local.env through
#: orch-env.sh (task P-4). Sourcing defines the functions and loads nothing: each
#: script calls `orch_env_load "$ROOT"` once it knows which root it runs on, and
#: a load here, against the default root, would pre-empt that one -- the loader
#: lets a value already set win, as it must for the environment.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orch-env.sh"
#: How many five-minute retries before giving up. 60 is five hours, which is the
#: length of the account's window: past that the problem is not a window, and a
#: launcher that spins for ever is a launcher whose failure is invisible.
BATCH_MAX_RETRIES="${BATCH_MAX_RETRIES:-60}"
BATCH_RETRY_SLEEP="${BATCH_RETRY_SLEEP:-300}"

batch_say() {  # batch_say <message...> -- timestamped, to stdout and $LOG
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "${LOG:-/dev/null}"
}

#: One line to the researcher's channel, and NEVER to their self-DM
#: (docs/LESSONS.md). Absent `slack`, it says so and carries on: a launcher that
#: died because it could not talk to Slack would be a worse failure than the one
#: it was reporting. The channel is `BATCH_SLACK_CHANNEL` when set, else
#: `ORCH_SLACK_CHANNEL`; with neither, the line is logged as NOT SENT with the
#: key's name -- never posted to a guessed channel.
batch_slack() {  # batch_slack <text>
    local channel=${BATCH_SLACK_CHANNEL:-${ORCH_SLACK_CHANNEL:-}}
    [ -n "${BATCH_NO_SLACK:-}" ] && { batch_say "slack SUPPRESSED (BATCH_NO_SLACK): $1"; return 0; }
    if [ -z "$channel" ]; then
        batch_say "slack NOT SENT, ORCH_SLACK_CHANNEL is not set (orchestration/local.env): $1"
        return 0
    fi
    if ! command -v slack >/dev/null 2>&1; then
        batch_say "slack NOT ON PATH, message not sent: $1"
        return 0
    fi
    slack chat-post-message --channel "$channel" --text "$1" >/dev/null 2>&1 \
        || batch_say "slack post FAILED (the message is above; the batch is unaffected)"
}

#: THE TOKEN GATE. Refuses on MISMATCH and says so in Slack, because the whole
#: point of the 17 September lesson is that the wrong account is INVISIBLE from
#: inside: every symptom reads as a usage limit. `unpinned` and `absent` are
#: reported and allowed -- a session that never pinned an account is legitimate,
#: and refusing there would make the guard impossible to introduce.
batch_token_gate() {  # batch_token_gate <what-is-being-started>
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=/dev/null
    . "$here/token-guard.sh"
    token_guard_evaluate
    batch_say "token: $TOKEN_GUARD_STATE — $TOKEN_GUARD_DETAIL"
    if [ "$TOKEN_GUARD_STATE" = MISMATCH ]; then
        batch_slack ":rotating_light: $1 REFUSED — the pod is on the wrong Claude account. $TOKEN_GUARD_DETAIL"
        batch_say "REFUSED: token MISMATCH"
        return 1
    fi
    return 0
}

#: ---------------------------------------------------------------------------
#: WHAT IS A BRIEF NAME, and it lives here because two scripts have to agree
#: ---------------------------------------------------------------------------
#: `batch-start.sh` builds its prompt from the brief names in a `### Batch <id>`
#: block, and `state-check.sh` checks that those briefs exist. Both used to
#: sweep up EVERY backticked Markdown name in the block, which is prose written
#: for humans and cites other documents freely: on the B3 block that produced
#: "not yet written: CLAUDE.md README.md" (P-2's task was about those two files)
#: and on B4's "8 of 11 … CLAUDE.md 2026-09-17.md OPERATING.md". One told a
#: fresh orchestrator to read `CLAUDE.md` as if it were a task brief; the other
#: reported phantom missing files in the row that is supposed to catch a batch
#: plan pointing at a brief nobody committed.
#:
#: A brief is named `<task-id>-<role>.md`: `D-17-full.md`, `D-17-pod.md`,
#: `P-3-full.md`, `A-S-full.md`, `23-continue.md`, `D-evidence-note.md`. So the
#: shape is a task id of one to four characters -- starting with a letter, or
#: one or two digits -- then at least one `-<part>`, then `.md`. Measured
#: against the 151 files in orchestration/briefs/ on 21 September 2026: 149
#: accepted; `TEMPLATE.md` and `r31r-continue.md` rejected. It rejects
#: `CLAUDE.md` and `README.md` (no hyphen), `docs/OPERATING.md` (a path, and
#: paths are excluded outright) and `2026-09-17.md` (four leading digits: a
#: date, not a task).
#:
#: ONE DEFINITION FOR BOTH READERS. A regex that exists twice is a regex that
#: drifts, and the failure mode of drift here is a launcher and its own gate
#: disagreeing about what the batch contains.
BATCH_BRIEF_SHAPE='^([A-Za-z][A-Za-z0-9]{0,3}|[0-9]{1,2})(-[A-Za-z0-9]+)+\.md$'

#: Every brief named in one `### Batch <id>` block of STATE section 4, one per
#: line. Reads the block as given on stdin.
batch_briefs_in_block() {  # batch_briefs_in_block  < <block text>
    grep -oE '`[A-Za-z0-9._/-]+\.md`' | tr -d '`' | grep -E "$BATCH_BRIEF_SHAPE" | sort -u
}

#: One `### Batch <id>` block of STATE section 4, heading included; empty when
#: there is none. batch-start.sh reads it to build its prompt and batch-resume.sh
#: to know which briefs the batch it is waking holds.
batch_block_of() {  # batch_block_of <state.md> <batch-id>
    awk -v id="$2" '
        $0 ~ "^### Batch " id "([^A-Za-z0-9._-]|$)" { inside = 1; print; next }
        /^### / || /^## /                           { inside = 0 }
        inside                                      { print }
    ' "$1" 2>/dev/null
}

#: ---------------------------------------------------------------------------
#: DOES THIS BATCH NEED MACHINES? -- each brief's **Machines** line (task P-5)
#: ---------------------------------------------------------------------------
#: The launchers used to require ORCH_GCP_PROJECT for every batch (P-4), so a
#: programme that never starts a machine -- the kit's tutorial task, a
#: documentation-only project -- could not start its first batch until its owner
#: named a GCP project it would never use. The researcher, 25 September: a pod is
#: not tied to one GCP project, and pods are created "without forcing any choice
#: at that point". So a brief now DECLARES whether it needs machines, in one bold
#: field after **Size** (orchestration/briefs/TEMPLATE.md): `**Machines** none`,
#: or the machines, their project and zone, and the stretch's ceiling.
#:
#: A BRIEF WITHOUT THE LINE COUNTS AS NEEDING MACHINES. Every brief written before
#: P-5 lacks it, and some of them start GPUs; reading silence as "none" would let
#: exactly those through a pod that cannot see its machines. The refusal names
#: the brief and the line to add, so the safe default costs one edit.
#:
#: The value runs from the field to the next `**` or the end of its line. A field
#: in backticks is a QUOTATION of the syntax (P-5-full.md and TEMPLATE.md both
#: cite `**Machines** none` in their prose), not a declaration, and is skipped.
#: Returns 1 when the brief declares nothing.
batch_brief_machines() {  # batch_brief_machines <brief-file>
    awk '
        {
            line = $0
            while ((i = index(line, "**Machines**")) > 0) {
                if (i == 1 || substr(line, i - 1, 1) != "`") {
                    v = substr(line, i + 12)
                    j = index(v, "**"); if (j > 0) v = substr(v, 1, j - 1)
                    gsub(/^[ \t]+|[ \t]+$/, "", v)
                    print v; found = 1; exit
                }
                line = substr(line, i + 12)
            }
        }
        END { exit (found ? 0 : 1) }
    ' "$1" 2>/dev/null
}

#: True when a **Machines** value says none: `none`, `none.`, `` `none` ``, any
#: case. Anything longer is a declaration -- "none unless item 3 needs the L4"
#: needs the L4, and a gate that parsed prose would be a gate that guessed.
batch_machines_none() {  # batch_machines_none <value>
    local v=${1//\`/}
    v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/\.$//')
    [ "${v,,}" = none ]
}

#: The briefs of a list that need machines, one line each saying why, in
#: BATCH_MACHINE_BRIEFS; empty when every brief says none. No brief at all is
#: itself a line: nothing then says the batch needs no machines.
batch_machine_briefs() {  # batch_machine_briefs <briefs-dir> <brief>...
    local dir=$1 b v
    shift
    BATCH_MACHINE_BRIEFS=""
    [ $# -gt 0 ] || BATCH_MACHINE_BRIEFS="docs/STATE.md section 4 names no brief for this batch, so nothing says it needs no machines
"
    for b in "$@"; do
        if [ ! -r "$dir/$b" ]; then
            BATCH_MACHINE_BRIEFS+="\`$b\` is not in orchestration/briefs/, so it has no **Machines** line: write it with \`**Machines** none\` or name them
"
        elif ! v=$(batch_brief_machines "$dir/$b"); then
            BATCH_MACHINE_BRIEFS+="\`$b\` has no **Machines** line: add \`**Machines** none\` or name them
"
        elif ! batch_machines_none "$v"; then
            BATCH_MACHINE_BRIEFS+="\`$b\` declares machines: ${v:-an empty **Machines** line}
"
        fi
    done
}

#: THE MACHINE GATE both launchers run once they know the batch's briefs.
#: ORCH_GCP_PROJECT is needed when (a) a brief needs machines, or (b) a project
#: is recorded anyway -- then the machine check runs every batch as before,
#: because a machine left on by an earlier batch is still ours and still a
#: refusal. Only with neither is the check skipped, and the launch log says so.
#: A RECORDED PROJECT MEANS ORCH_GCP_PROJECT, not ORCH_VM_PREFIX: the kit's pod
#: setup writes the prefix at creation and its `vm-probe.sh --project` records
#: the project only once access is proven, so reading the prefix as "recorded"
#: would refuse every batch on exactly the pods this gate exists for.
#:
#: Sets BATCH_VM_CHECK (run|skip), BATCH_VM_SKIP_REASON and BATCH_MACHINES_NOTE
#: (the prompt's sentence); returns 1, having said why, when a batch needs
#: machines and no project is recorded.
batch_machine_gate() {  # batch_machine_gate <batch-id> <briefs-dir> <brief>...
    local id=$1 dir=$2 line needs
    shift 2
    batch_machine_briefs "$dir" "$@"
    needs=$(printf '%s' "$BATCH_MACHINE_BRIEFS" | sed '/^$/d' | paste -sd ';' - | sed 's/;/; /g')
    BATCH_VM_SKIP_REASON=""
    if [ -n "${ORCH_GCP_PROJECT:-}" ]; then
        BATCH_VM_CHECK=run
        if [ -n "$needs" ]; then
            BATCH_MACHINES_NOTE="MACHINES ARE IN PLAY in batch ${id}: ${needs}. Ours are the ${ORCH_VM_PREFIX:-}* instances in GCP project ${ORCH_GCP_PROJECT}; each stretch stays inside its brief's ceiling and gets its RESOURCES row."
        else
            BATCH_MACHINES_NOTE="No brief of batch ${id} declares machines (every **Machines** line says none): start none. The machine check still ran, because a GCP project is recorded."
        fi
        return 0
    fi
    if [ -n "$needs" ]; then
        batch_say "REFUSED: batch $id needs machines and no GCP project is recorded (ORCH_GCP_PROJECT; read: ${ORCH_ENV_FILE_READ:-not loaded})."
        printf '%s' "$BATCH_MACHINE_BRIEFS" | while IFS= read -r line; do
            [ -n "$line" ] && batch_say "REFUSED: $line"
        done
        batch_say "         Remedy: bash orchestration/scripts/vm-probe.sh --project <gcp-project> (the kit's vm-probe.sh;"
        batch_say "         a probe that succeeds records the project), or ORCH_GCP_PROJECT=<gcp-project> in orchestration/local.env."
        [ -n "${ORCH_VM_PREFIX:-}" ] \
            || batch_say "         ORCH_VM_PREFIX is not set either, and a recorded project needs it: the prefix is what makes a machine ours."
        return 1
    fi
    BATCH_VM_CHECK=skip
    BATCH_VM_SKIP_REASON="no brief of $id declares machines and no GCP project is recorded"
    BATCH_MACHINES_NOTE="No brief of batch ${id} declares machines and no GCP project is recorded, so the machine check was skipped: start no machine in this batch. A brief that needs one says so on its **Machines** line, and its batch needs a recorded GCP project first (docs/OPERATING.md section 2)."
    return 0
}

#: docs/STATE.md's `**Batch <id>: running|ended**` anchor, or the empty string.
batch_state_phase() {  # batch_state_phase <state.md>
    grep -m1 -oE '^\*\*Batch [A-Za-z0-9._-]+: (running|ended)\*\*' "$1" 2>/dev/null \
        | sed -E 's/.*: (running|ended)\*\*/\1/'
}

batch_state_id() {  # batch_state_id <state.md>
    grep -m1 -oE '^\*\*Batch [A-Za-z0-9._-]+: (running|ended)\*\*' "$1" 2>/dev/null \
        | sed -E 's/^\*\*Batch ([A-Za-z0-9._-]+):.*/\1/'
}

#: ---------------------------------------------------------------------------
#: THE INBOX, and its ONE reader (task G-6)
#: ---------------------------------------------------------------------------
#: `orchestration/INBOX.md` is where the chat conversation writes every message
#: from the researcher the moment it arrives, `status: new` until somebody acts
#: on it. Writing it down was half the fix for 30 September -- a message the
#: platform acknowledged as "Queued" and no conversation ever received; the
#: other half is that something READS it, and two scripts do: `status.sh`
#: shows the `new` count to every conversation, and `state-check.sh` fails a
#: batch's close that leaves one behind. Both read it through this function,
#: so the two cannot disagree about what `new` is.
#:
#: THE SHAPE IS THE FILE'S OWN HEADER, and it is a contract: an entry is a
#: `## <UTC time> — <where> — status: <word> …` heading outside a ``` fence,
#: whose first non-blank line is a `>` quote. The status is read by its FIRST
#: WORD, in any case: `new` is unhandled; `done`, `lost` and `delivered` (the
#: 30 September entry's: the platform delivered it late and it was answered)
#: are settled. ANYTHING ELSE IS MALFORMED AND FAILS, rather than being counted
#: one way or the other: an inbox whose count is a guess is the silence this
#: file exists to end, and a typo'd `nwe` read as settled would be a message
#: dropped by the reader instead of by the platform.
#:
#: Sets INBOX_ENTRIES, INBOX_NEW, INBOX_NEW_LINES (heading line numbers),
#: INBOX_OLDEST and INBOX_OLDEST_LINE (the oldest `new` by its timestamp, as
#: written), INBOX_ERROR. Returns 0 read, 1 malformed (INBOX_ERROR names the
#: first bad line), 2 no readable file.
batch_inbox_scan() {  # batch_inbox_scan <INBOX.md>
    INBOX_ENTRIES=0 INBOX_NEW=0 INBOX_NEW_LINES="" INBOX_OLDEST="" INBOX_OLDEST_LINE="" INBOX_ERROR=""
    if [ ! -r "$1" ]; then
        INBOX_ERROR="no readable $1"
        return 2
    fi
    local out rc kind cls line key ts best=""
    # Intervals (`{4}`) are spelled out: older mawk, which some pods have,
    # does not support them.
    out=$(awk '
        function err(n, msg) { printf "ERR\tline %d: %s\n", n, msg; bad = 1; exit 1 }
        function flush() {
            if (open && !quoted) err(open, "the entry has no \"> \" line quoting the researcher under its heading")
            open = 0
        }
        BEGIN { sep = " — status: "; dash = " — " }
        /^```/ { fence = !fence; fence_line = NR; next }
        fence  { next }
        /^## / {
            flush()
            h = substr($0, 4)
            p = 0
            while ((i = index(substr(h, p + 1), sep)) > 0) p += i
            if (!p) err(NR, "the heading has no \" — status: <word>\"")
            left = substr(h, 1, p - 1); st = substr(h, p + length(sep))
            q = index(left, dash)
            if (!q) err(NR, "the heading has no \" — <where it arrived> — \" between its time and its status")
            ts = substr(left, 1, q - 1); where = substr(left, q + length(dash))
            t = ts; sub(/^~/, "", t)
            if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) err(NR, "the heading does not begin with a UTC date, YYYY-MM-DD")
            if (where ~ /^[ \t]*$/) err(NR, "the heading does not say where the message arrived")
            w = st; sub(/^[ \t]+/, "", w); split(w, a, /[ \t]+/); word = tolower(a[1])
            if (word != "new" && word != "done" && word != "lost" && word != "delivered")
                err(NR, "status \"" a[1] "\" is none of new, done, lost, delivered")
            hm = "00:00"
            if (match(t, /[0-9][0-9]:[0-9][0-9]/)) hm = substr(t, RSTART, 5)
            printf "E\t%s\t%d\t%s %s\t%s\n", word, NR, substr(t, 1, 10), hm, ts
            open = NR; quoted = 0; seen = 0
            next
        }
        open && !seen && NF { seen = 1; if ($0 ~ /^>/) quoted = 1 }
        END {
            if (bad) exit 1
            if (fence) err(fence_line, "a ``` fence is never closed, so every entry after it would go unread")
            flush()
        }
    ' "$1")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        INBOX_ERROR=$(printf '%s\n' "$out" | sed -n 's/^ERR\t//p' | head -1)
        [ -n "$INBOX_ERROR" ] || INBOX_ERROR="awk failed (rc=$rc) reading $1"
        return 1
    fi
    while IFS=$'\t' read -r kind cls line key ts; do
        [ "$kind" = E ] || continue
        INBOX_ENTRIES=$((INBOX_ENTRIES + 1))
        [ "$cls" = new ] || continue
        INBOX_NEW=$((INBOX_NEW + 1))
        INBOX_NEW_LINES="$INBOX_NEW_LINES $line"
        if [ -z "$best" ] || [[ "$key" < "$best" ]]; then
            best=$key INBOX_OLDEST=$ts INBOX_OLDEST_LINE=$line
        fi
    done <<< "$out"
    INBOX_NEW_LINES=${INBOX_NEW_LINES# }
    return 0
}

#: ---------------------------------------------------------------------------
#: THE OWNER OF A BATCH, and it is a pid rather than a promise
#: ---------------------------------------------------------------------------
#: `.maestro/orchestrator-session` records WHICH CONVERSATION is the batch; it
#: does not record whether anybody is currently driving it, and on 18 September
#: that gap was the whole failure. The B2 conversation was resumed from a dev
#: box at 13:55 UTC while the B3 orchestrator was running, and for 31 minutes
#: two processes orchestrated one programme: both read worker p-2's report, both
#: verified the same branch, and they deleted each other's checkouts.
#:
#: Both launchers already ran a `pgrep` for "any claude with a session id", and
#: that gate is a broad net -- it fires on somebody's unrelated session and it
#: cannot say WHICH batch is already owned. `.maestro/orchestrator.pid` is the
#: precise answer: the pid of the `claude` process that IS this batch, and the
#: session id it is driving, written before the conversation starts and checked
#: by everything that would otherwise start a second one.
#:
#: A PID ALONE IS NOT AN OWNER. Pids are reused, and a batch that refused for
#: ever because some unrelated process inherited a number would be worse than no
#: gate. So ownership is three things together: the pid is alive, its argv is a
#: `claude`, and the file says which session -- and liveness is read from
#: /proc/<pid>/cmdline's CONTENT, never `[ -s ]`, because procfs reports size 0
#: for those files whether the process lives or not (orchestration/scripts/run-lock.sh
#: carries the measurement).
#:
#: Sets BATCH_OWNER_PID, BATCH_OWNER_SID and BATCH_OWNER_ARGV on success.
batch_owner_alive() {  # batch_owner_alive <pidfile>
    local f=$1 pid sid argv
    BATCH_OWNER_PID=""; BATCH_OWNER_SID=""; BATCH_OWNER_ARGV=""
    [ -r "$f" ] || return 1
    read -r pid sid < "$f" || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$pid" ] || return 1
    argv=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    [ -n "$argv" ] || return 1
    case "$argv" in *claude*) ;; *) return 1 ;; esac
    BATCH_OWNER_PID=$pid; BATCH_OWNER_SID=${sid:-unknown}; BATCH_OWNER_ARGV=$argv
    return 0
}

#: The gate both launchers run. Refuses when a live owner exists, and says
#: enough for a human to act: which pid, which session, and that the remedy is
#: to stop THAT process rather than to start beside it.
batch_owner_gate() {  # batch_owner_gate <pidfile> <what-is-being-started>
    if batch_owner_alive "$1"; then
        batch_say "REFUSED: batch $2 -- this programme already has a live orchestrator."
        batch_say "         pid $BATCH_OWNER_PID is driving session $BATCH_OWNER_SID."
        batch_say "         Two orchestrators on one programme destroyed each other's work on"
        batch_say "         18 September (docs/LESSONS.md, \"Two orchestrators\"). Do not start a"
        batch_say "         second: either wait for that pid, or stop IT by explicit pid first."
        return 1
    fi
    return 0
}

#: ---------------------------------------------------------------------------
#: THE NET BEHIND THE OWNER GATE, told apart by ORCH_ROLE (8 October)
#: ---------------------------------------------------------------------------
#: batch_owner_gate names the pid driving which session; this is the broad net
#: behind it, for an orchestrator started some other way. Until 8 October it was
#: a `pgrep` for "any claude with a session id", and on a pod where Maestro
#: resumes the session's chat conversation as `claude --resume <id>` that is the
#: chat itself: a teammate's pod refused every batch asked for in the chat, the
#: dry run included, with nothing running. (Ours resumes it as `claude -r`, which
#: that pgrep did not match, so we never saw it.) Argv is Maestro's to choose;
#: what is ours is ORCH_ROLE in the process's environment (CLAUDE.md's triage,
#: 30 September): the launchers start the orchestrator with
#: ORCH_ROLE=orchestrator, spawn-agent.sh a worker with ORCH_ROLE=worker, and
#: the chat conversation has none. ONE reader, here, so the launchers' gate and
#: status.sh's rows cannot disagree about who is running.
#:
#: Prints the pids of this user's `claude` processes whose ORCH_ROLE is <role>,
#: one per line; `none` is those without one, which are the chat conversation or
#: a claude started by hand. Returns 0 if there is at least one, 1 if none.
batch_claude_pids() {  # batch_claude_pids orchestrator|worker|none
    local want=$1 p role found=1
    for p in $(pgrep -u "$(id -u)" -f "(^|/)claude( |$)" 2>/dev/null); do
        [ -r "/proc/$p/environ" ] || continue
        role=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^ORCH_ROLE=//p' | head -1)
        [ "${role:-none}" = "$want" ] || continue
        printf '%s\n' "$p"; found=0
    done
    return $found
}

#: Which batch a recorded session belongs to, from batch-start.sh's own append-only
#: log (`<time> <batch> <session>`). THE LAST LINE FOR THAT SESSION WINS, because a
#: session is only ever minted once but may be written more than once.
#:
#: This is what lets batch-resume.sh tell "THIS batch ended" from "the PREVIOUS
#: batch ended", which STATE section 3 alone cannot distinguish.
batch_session_batch() {  # batch_session_batch <sessions-log> <session-id>
    [ -r "$1" ] || return 1
    awk -v sid="$2" '$3 == sid { id = $2 } END { if (id != "") print id }' "$1"
}

#: docs/STATE.md section 3's phase FOR A NAMED BATCH. Returns non-zero when
#: section 3 is about some OTHER batch, which is precisely the state B3 died in:
#: section 3 said "Batch B2: ended" while B3 was the batch in flight, and
#: `batch_state_phase` answered "ended" to the question "has B3 ended?".
batch_state_phase_for() {  # batch_state_phase_for <state.md> <batch-id>
    local got
    got=$(batch_state_id "$1")
    [ -n "$got" ] || return 1
    [ "$got" = "$2" ] || return 1
    batch_state_phase "$1"
}

#: --resume once a transcript for this id exists, --session-id to mint it.
#: GETTING THIS BACKWARDS IS FATAL IN BOTH DIRECTIONS: `--session-id` against an
#: existing id is refused by the CLI, and `--resume` against an id that was never
#: created has nothing to resume. It is decided per attempt and not once,
#: because the FIRST attempt is what creates the transcript -- a run that is
#: killed by a limit thirty seconds in has still created it, and the retry after
#: it must resume rather than mint.
batch_session_ref() {  # batch_session_ref <session-id> -> prints the two argv words
    if [ -f "$HOME/.claude/projects/-workspace/$1.jsonl" ]; then
        printf -- '--resume\n%s\n' "$1"
    else
        printf -- '--session-id\n%s\n' "$1"
    fi
}

#: ONE ATTEMPT, and the reason it is a function is the PID. The owner file has
#: to hold the pid of `claude` itself -- not this shell's, which outlives
#: nothing useful, and not `tee`'s, which is what `$!` would give for the
#: pipeline that used to be written here inline. So claude is started in the
#: background inside the pipeline's left-hand side, its pid is recorded, and
#: `wait` makes the whole thing behave exactly like the foreground call it
#: replaces -- including ${PIPESTATUS[0]}, which is still claude's own rc.
#:
#: BATCH_PID_FILE IS READ HERE AS A SHELL VARIABLE OF THE LAUNCHER'S OWN SHELL,
#: and it must not be exported into `claude`'s environment. It names a file
#: holding a LIVE pid; every process the orchestrator starts inherits its
#: environment, and a test that reads it measures the pod rather than its own
#: fixture -- which is how batch B5's first two detached verifications hung
#: (task P-3-cont, docs/ledgers/HARDENING.md `## 43`). Both launchers run
#: `export -n BATCH_PID_FILE` immediately before batch_run_claude for that
#: reason; do not turn it back into an `export` to "make it visible".
#:
#: ORCH_ROLE=orchestrator IS SET ON `claude`'S COMMAND LINE AND NOWHERE ELSE
#: (30 September). CLAUDE.md sends each conversation to its rules by this value;
#: the Maestro session's chat conversation, which has none, is the conversation
#: that runs this launcher, and asked in Slack it had called itself the
#: orchestrator. Everything the orchestrator starts inherits the value, which is
#: harmless by design: nothing reads it but CLAUDE.md, spawn-agent.sh sets
#: `worker` for its own `claude`, and the tests drop it with the other ORCH_
#: variables (tests/test_agent_roles.py).
batch_claude_attempt() {  # batch_claude_attempt <model> <sid> <prompt> <session-ref-words...>
    local model=$1 sid=$2 prompt=$3; shift 3
    local rc
    {
        ORCH_ROLE=orchestrator claude "$@" --model "$model" --effort medium -p "$prompt" 2>&1 &
        cpid=$!
        if [ -n "${BATCH_PID_FILE:-}" ]; then
            mkdir -p "$(dirname "$BATCH_PID_FILE")" 2>/dev/null
            printf '%s %s\n' "$cpid" "$sid" > "$BATCH_PID_FILE"
        fi
        wait "$cpid"
    } | tee -a "${LOG:-/dev/null}"
    rc=${PIPESTATUS[0]}
    return "$rc"
}

#: THE LADDER. Fable 5.1 at medium first, because that is the researcher's
#: decision (docs/STATE.md section 5) and it is cheaper; Opus 5 at medium when
#: Fable is refused for usage credits, because Fable is not on every account and
#: an account switch must not stop the programme; then wait five minutes and
#: begin again, because an exhausted five-hour window is a thing that ends.
#:
#: THE TWO REFUSALS READ DIFFERENTLY and both are matched (docs/LESSONS.md):
#: Fable says "requires usage credits", Opus says "You've hit your session
#: limit". A print-mode run exits non-zero on either, so the exit code alone
#: cannot tell "the account is out" from "the task failed" -- which is why the
#: log text is consulted at all.
#:
#: Returns the last rc; 0 means the conversation ended cleanly.
batch_run_claude() {  # batch_run_claude <session-id> <prompt>
    local sid=$1 prompt=$2 attempt=0 rc=1
    local -a ref
    while [ "$attempt" -lt "$BATCH_MAX_RETRIES" ]; do
        attempt=$((attempt + 1))

        mapfile -t ref < <(batch_session_ref "$sid")
        batch_say "attempt $attempt on $ORCH_MODEL_ORCHESTRATOR (${ref[0]})"
        batch_claude_attempt "$ORCH_MODEL_ORCHESTRATOR" "$sid" "$prompt" "${ref[@]}"
        rc=$?
        [ "$rc" -eq 0 ] && { batch_say "ended cleanly on $ORCH_MODEL_ORCHESTRATOR"; return 0; }

        if tail -20 "${LOG:-/dev/null}" 2>/dev/null | grep -qi 'requires usage credits'; then
            mapfile -t ref < <(batch_session_ref "$sid")
            batch_say "$ORCH_MODEL_ORCHESTRATOR refused for usage credits; attempt $attempt on $ORCH_MODEL_FALLBACK (${ref[0]})"
            batch_claude_attempt "$ORCH_MODEL_FALLBACK" "$sid" "$prompt" "${ref[@]}"
            rc=$?
            [ "$rc" -eq 0 ] && { batch_say "ended cleanly on $ORCH_MODEL_FALLBACK"; return 0; }
        fi

        batch_say "refused or limited (rc=$rc); retrying in ${BATCH_RETRY_SLEEP}s (attempt $attempt of $BATCH_MAX_RETRIES)"
        sleep "$BATCH_RETRY_SLEEP"
    done
    batch_say "GIVING UP after $BATCH_MAX_RETRIES attempts -- this is no longer a usage window"
    batch_slack ":warning: the launcher gave up after $BATCH_MAX_RETRIES attempts; a human is needed"
    return "$rc"
}
