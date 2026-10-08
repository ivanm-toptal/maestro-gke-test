#!/usr/bin/env bash
# orch-env.sh -- the one place an orchestration script learns WHOSE programme it
# is running for. Sourced, never executed (task P-4).
#
# WHY A FILE AND NOT LITERALS. These scripts are vendored verbatim into the
# team kit (`toptal/maestro-k8s`, formerly `astyanax42/maestro-utils`; `templates/orchestration/scripts/`), and
# until P-4 four of them carried this programme's GCP project, machine prefix,
# Slack channel and name as literals, with a PARAMETERS.md in the kit telling
# every new project which lines to edit by hand. A hand edit in a copied script
# is a fork: the next re-vendor overwrites it or does not happen. So the
# scripts name no project, and each pod says which one it is in ONE git-ignored
# file, `orchestration/local.env`, whose committed `local.env.example` documents
# every key. `tests/test_orchestration_params.py` fails naming file and line if
# a literal comes back.
#
# THE KEYS, and which of them have a default:
#
#   ORCH_PROJECT             the programme's short name (prompts, the status row)   no default
#   ORCH_GCP_PROJECT         the GCP project our machines are in                   no default
#   ORCH_VM_PREFIX           the name prefix that makes a machine OURS             no default
#   ORCH_SLACK_CHANNEL       the channel id the launchers post to                  no default
#   ORCH_REPO_NAME           owner/name of this repository                         derived from `origin`
#   ORCH_MODEL_ORCHESTRATOR  the launchers' first model                            claude-fable-5-1
#   ORCH_MODEL_FALLBACK      when that one is refused for usage credits; the drill claude-opus-5
#   ORCH_MODEL_WORKER        spawn-worker.sh's model when the caller names none    claude-opus-5-5
#
# THE FOUR WITHOUT A DEFAULT HAVE NONE ON PURPOSE. A default project is a
# teammate's `status.sh` listing somebody else's machines as "ours", and a
# default channel is their launcher posting into somebody else's session. So a
# script that needs one of them and does not have it says so BY NAME
# (`orch_require`) -- a refusal from a launcher, a FAIL row from state-check, an
# UNCHECKED row from status -- and nothing guesses. The models do have defaults:
# they are the researcher's decision (docs/STATE.md section 5, OPERATING
# section 2), the same on every pod, and a wrong one costs money, not safety.
#
# THE ENVIRONMENT WINS over the file, as it does for `scripts/external-host.sh`
# (D-17): `ORCH_GCP_PROJECT=x orchestration/scripts/status.sh` works on a
# checkout that has a local.env. The values are set as SHELL variables and never
# exported, so they do not ride into `claude`'s environment and from there into
# a detached verification's suite -- which is the P-3-cont failure
# (docs/ledgers/HARDENING.md section 43). `verify-detached.sh` scrubs every name
# below as well, for a value an operator exported by hand.
#
# WHICH FILE. `$ORCH_ENV_FILE` when set (the tests pin it to a fixture), else
# `<root>/orchestration/local.env` where <root> is the repository the calling
# script OPERATES ON -- `/workspace` for every one of them by default -- and not
# the checkout the script was run from. The file describes the pod, and a worker
# running `status.sh` from its own worktree is asking about the pod.
#
# THE FILE IS SOURCED IN A SUBSHELL and only these keys come back, for the reason
# `scripts/external-host.sh` gives: a private file must not be able to set PATH,
# define a function or `exit` inside the launcher that read it. A file that is
# not valid shell is reported in `ORCH_ENV_FILE_READ` and otherwise ignored.

ORCH_KEYS="ORCH_PROJECT ORCH_GCP_PROJECT ORCH_VM_PREFIX ORCH_SLACK_CHANNEL ORCH_REPO_NAME ORCH_MODEL_ORCHESTRATOR ORCH_MODEL_FALLBACK ORCH_MODEL_WORKER"

orch_env_load() {  # orch_env_load [<root>] -- default: this checkout's root
    local root file answer key value i
    root=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
    file="${ORCH_ENV_FILE:-$root/orchestration/local.env}"
    ORCH_ENV_FILE_READ="none ($file absent)"
    if [ -r "$file" ]; then
        # shellcheck disable=SC2030,SC2031 -- the subshell is the point
        # The keys are printed from an EXIT trap onto the saved stdout (fd 3), so
        # a file that ends in `exit` -- which runs while the file's own output
        # goes to /dev/null -- still hands back what it set before it; a file
        # that does not parse makes the subshell's status 7 and is ignored whole.
        if answer="$(
                set +u
                exec 3>&1
                for key in $ORCH_KEYS; do unset "$key"; done
                trap 'for key in $ORCH_KEYS; do printf "%s\n" "${!key:-}" >&3; done' EXIT
                # shellcheck source=/dev/null
                . "$file" >/dev/null 2>&1 || exit 7
            )"; then
            ORCH_ENV_FILE_READ="$file"
            i=1
            for key in $ORCH_KEYS; do
                value=$(printf '%s\n' "$answer" | sed -n "${i}p")
                i=$((i + 1))
                [ -n "${!key:-}" ] && continue
                [ -n "$value" ] && printf -v "$key" '%s' "$value"
            done
        else
            ORCH_ENV_FILE_READ="$file (NOT VALID SHELL -- ignored)"
        fi
    fi
    ORCH_MODEL_ORCHESTRATOR=${ORCH_MODEL_ORCHESTRATOR:-claude-fable-5-1}
    ORCH_MODEL_FALLBACK=${ORCH_MODEL_FALLBACK:-claude-opus-5}
    ORCH_MODEL_WORKER=${ORCH_MODEL_WORKER:-claude-opus-5-5}
    # The repository's name is a fact of the checkout, so it is read from it
    # rather than required: `https://github.com/o/r.git` and `git@github.com:o/r`
    # both give `o/r`. No origin is an empty name, not an error: fetch-secrets.sh
    # sources this under `set -e -o pipefail`, where a failed `git` would end it.
    if [ -z "${ORCH_REPO_NAME:-}" ]; then
        ORCH_REPO_NAME=$(git -C "$root" remote get-url origin 2>/dev/null \
            | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#') || ORCH_REPO_NAME=""
    fi
    return 0
}

#: Names every key in the arguments that is empty, one line each on stderr, and
#: returns 1 if there was one. The caller decides what a missing key means for
#: it; the message is the same everywhere so it can be grepped for.
orch_require() {  # orch_require <key>...
    local key missing=0
    for key in "$@"; do
        if [ -z "${!key:-}" ]; then
            printf '%s is not set -- put it in orchestration/local.env (every key is in orchestration/local.env.example); read: %s\n' \
                "$key" "${ORCH_ENV_FILE_READ:-not loaded}" >&2
            missing=1
        fi
    done
    return "$missing"
}

#: Machine names on stdin, `<name><TAB><status>` per line; prints the ones whose
#: name begins with $ORCH_VM_PREFIX (`--theirs`: the others). A fixed-string
#: prefix, not a regex: a prefix is a name, and `grep -E "^$prefix"` would read
#: a `.` in one as "any character".
orch_vm_filter() {  # orch_vm_filter [--theirs] < name<TAB>status lines
    local want=1
    [ "${1:-}" = --theirs ] && want=0
    awk -v p="${ORCH_VM_PREFIX:-}" -v want="$want" \
        'NF { ours = (p != "" && index($0, p) == 1); if (ours == want) print }'
}
