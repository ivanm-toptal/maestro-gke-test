#!/usr/bin/env bash
# bootstrap-session.sh — make a fresh Maestro remote session ready, and print a
# table that says whether it is.
#
# THE PROBLEM IT SOLVES. A session that is FRESH -- newly started, or resumed
# onto a rebuilt image -- has /workspace and nothing else this repository needs:
# no credential files (they live in $HOME and come from Secret Manager), no
# .venv, and until .devcontainer/Dockerfile existed no ffmpeg and no espeak-ng
# either. Four separate tasks have recorded that last one as a fresh-container
# finding and one of them reported it as a code regression
# (docs/ledgers/ACCESS-REPORT.md).
#
# It is NOT true that a remote `maestro resume --latest` loses those:
# `orchestration/HANDOVER.md` section 7 verified that a remote resume keeps the
# workspace, the home directory and the conversation. This script is therefore
# cheap to run when nothing was lost -- every stage is idempotent and
# `--table-only` changes nothing at all -- which is the property that lets it be
# the unconditional first command of every session instead of a judgement call.
#
# This is the single command that closes the gap and, more importantly, the
# single command that MEASURES it.
#
# WHY THE TABLE IS PRINTED EVEN WHEN A STAGE FAILS. A bootstrap that dies at its
# first problem tells you one thing about the session. The table tells you all
# of them at once, which is the difference between one round trip and five when
# the session is remote and the connector layer is what broke.
#
# EVERY EXTERNAL COMMAND IS CALLED BY NAME FROM PATH, deliberately, so the table
# can be exercised against a directory of stubs -- `tests/test_bootstrap_
# session.py` does exactly that. Nothing here hard-codes /usr/bin/anything.
#
# Usage:
#   bootstrap-session.sh                 secrets, uv sync, fast lane, table
#   bootstrap-session.sh --table-only    the table alone; changes nothing
#   bootstrap-session.sh --no-secrets    skip the Secret Manager read
#   bootstrap-session.sh --no-sync       skip `uv sync`
#   bootstrap-session.sh --no-tests      skip the fast lane
#   bootstrap-session.sh --prefetch      also fetch the models into HF_HOME
#
# Exit codes: 0 ready / 2 usage / 6 a required row is NOT ok

set -uo pipefail

ROOT="${BOOTSTRAP_ROOT:-/workspace}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$HERE/orch-env.sh"
orch_env_load "$ROOT"
PROJECT="${CLOUDSDK_CORE_PROJECT:-${ORCH_GCP_PROJECT:-}}"
PREFETCH_SCRIPT="${PREFETCH_SCRIPT:-/usr/local/share/avatar/prefetch-models.py}"

do_secrets=1 do_sync=1 do_tests=1 do_prefetch=0
while [ $# -gt 0 ]; do
    case "$1" in
        --table-only) do_secrets=0; do_sync=0; do_tests=0; shift ;;
        --no-secrets) do_secrets=0; shift ;;
        --no-sync)    do_sync=0; shift ;;
        --no-tests)   do_tests=0; shift ;;
        --prefetch)   do_prefetch=1; shift ;;
        -h|--help)    sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'bootstrap-session: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------
# Rows accumulate as `state<TAB>what<TAB>detail` and are printed at the end in
# the order they were added. `state` is one of ok / WARN / FAIL, and only FAIL
# on a REQUIRED row changes the exit code -- a missing credential file is a WARN
# because a session doing offline work is legitimately ready without one.
ROWS=()
required_failed=0

row() {  # row <state> <required:0|1> <what> <detail>
    ROWS+=("$1	$3	$4")
    [ "$1" = FAIL ] && [ "$2" = 1 ] && required_failed=$((required_failed + 1))
    return 0
}

#: `tool <required> <name> <version-argv...>` -- present and what version.
tool() {
    local req=$1 name=$2; shift 2
    if ! command -v "$name" >/dev/null 2>&1; then
        row FAIL "$req" "$name" "NOT ON PATH"
        return
    fi
    local out
    out=$("$@" 2>&1 | head -1 | cut -c1-58)
    row ok "$req" "$name" "${out:-present}"
}

# ---------------------------------------------------------------------------
# Stage 1 — credentials
# ---------------------------------------------------------------------------
secrets_state=skipped
if [ "$do_secrets" = 1 ]; then
    echo "== fetching credentials from Secret Manager =="
    if "$HERE/fetch-secrets.sh"; then
        secrets_state=ok
    else
        # rc 3 (missing/unreadable secret) and rc 4 (a newer local file) are
        # both legitimate states for a session to be in and neither is this
        # script's to resolve. fetch-secrets.sh has already printed the named
        # secret and the command that creates it.
        secrets_state="FAILED rc=$?"
    fi
    echo
fi

# ---------------------------------------------------------------------------
# Stage 2 — the project environment
# ---------------------------------------------------------------------------
sync_state=skipped
if [ "$do_sync" = 1 ]; then
    echo "== uv sync --all-groups =="
    # `--all-groups`, NOT `--all-extras`: the `kernel` extra pins a private
    # GitHub repository and `uv sync --extra kernel` therefore needs a GitHub
    # credential wherever it runs (pyproject.toml). A bootstrap that required it
    # would fail on every session whose connector had expired.
    if (cd "$ROOT" && uv sync --all-groups); then
        sync_state=ok
    else
        sync_state="FAILED rc=$?"
    fi
    echo
fi

# ---------------------------------------------------------------------------
# Stage 3 — the models, only when asked
# ---------------------------------------------------------------------------
prefetch_state=skipped
if [ "$do_prefetch" = 1 ]; then
    echo "== prefetching models into ${HF_HOME:-the default HF cache} =="
    # MINUTES, NOT SECONDS: 475.5 MB measured at about 0.40 MB/s from this
    # network -- 19 m 46 s for the pair. .devcontainer/Dockerfile carries the
    # per-repository breakdown and the reason the image does not do this by
    # default.
    if [ -r "$PREFETCH_SCRIPT" ]; then
        if (cd "$ROOT" && uv run --no-project --with huggingface_hub "$PREFETCH_SCRIPT"); then
            prefetch_state=ok
        else
            prefetch_state="FAILED rc=$?"
        fi
    else
        prefetch_state="script not in image: $PREFETCH_SCRIPT"
    fi
    echo
fi

# ---------------------------------------------------------------------------
# Stage 4 — the fast lane
# ---------------------------------------------------------------------------
fast_state=skipped
if [ "$do_tests" = 1 ]; then
    echo '== uv run pytest -m "not slow" =='
    fast_log=$(mktemp)
    if (cd "$ROOT" && uv run pytest -m "not slow") > "$fast_log" 2>&1; then
        fast_state="ok -- $(grep -Eo '[0-9]+ passed[^=]*' "$fast_log" | tail -1 | cut -c1-48)"
    else
        fast_state="FAILED -- $(grep -Eo '[0-9]+ failed[^=]*|[0-9]+ error[^=]*' "$fast_log" | tail -1 | cut -c1-48)"
        printf '%s\n' "--- the failures ---"
        grep -E '^(FAILED|ERROR)' "$fast_log" | head -15
    fi
    tail -3 "$fast_log"
    rm -f "$fast_log"
    echo
fi

# ---------------------------------------------------------------------------
# The rows
# ---------------------------------------------------------------------------
tool 1 python3   python3 -V
tool 1 uv        uv --version
tool 1 node      node --version
tool 1 ffmpeg    ffmpeg -version
tool 1 espeak-ng espeak-ng --version
tool 1 git       git --version
tool 1 tmux      tmux -V
tool 1 jq        jq --version
tool 1 curl      curl --version

# libsndfile is a LIBRARY, so `command -v` cannot see it: the thing that loads
# it is `soundfile`, through ctypes, by soname. `ldconfig -p` is the question
# actually being asked.
#
# AND `ldconfig` IS NOT ON THIS USER'S PATH. It lives in /sbin, which a non-root
# PATH does not include, so the first version of this row asked `ldconfig -p`,
# got `command not found`, and reported FAIL for a library that was installed and
# working -- on a container where `dpkg -l` shows libsndfile1 1.2.2-2+deb13u1 and
# the .so is right there at
# /usr/lib/x86_64-linux-gnu/libsndfile.so.1 -> libsndfile.so.1.0.37. A readiness
# table that cries wolf about a present dependency is worse than no row, because
# the next person learns to ignore it.
#
# So: find ldconfig where it actually is, and if there is no ldconfig at all,
# answer the question directly by looking for the soname on the loader's search
# path. The row says WHICH method answered, so a fallback is visible rather than
# silent.
ldconfig_bin=""
for candidate in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
    if command -v "$candidate" >/dev/null 2>&1; then ldconfig_bin=$candidate; break; fi
done
sndfile_row=""
if [ -n "$ldconfig_bin" ]; then
    sndfile_row=$("$ldconfig_bin" -p 2>/dev/null | grep -m1 'libsndfile\.so\.1' | sed 's/^ *//')
fi
if [ -z "$sndfile_row" ]; then
    # `ls` over the multiarch directories rather than a `find /`: the loader only
    # looks in these without an LD_LIBRARY_PATH, so anywhere else is not an
    # answer to the question.
    for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu /lib; do
        if [ -e "$dir/libsndfile.so.1" ]; then
            sndfile_row="libsndfile.so.1 => $dir/libsndfile.so.1 (found on the loader path)"
            break
        fi
    done
fi
if [ -n "$sndfile_row" ]; then
    row ok 1 libsndfile "$(printf '%s' "$sndfile_row" | cut -c1-58)"
else
    row FAIL 1 libsndfile "no libsndfile.so.1 in the loader cache or on its search path"
fi

# gh and gcloud are PLATFORM-PROVIDED in a Maestro session (the connector
# wrappers in /usr/local/bin), not image-provided, so their absence is a
# connector finding rather than an image bug -- and it is required either way,
# because fetch-secrets.sh cannot run without gcloud.
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/tmp/bootstrap-gh.out 2>&1; then
        row ok 1 "gh auth" "$(grep -m1 'Logged in' /tmp/bootstrap-gh.out | sed 's/^ *//' | cut -c1-58)"
        # The warning that matters: the connector's token stops renewing and
        # access ends within 8 h. Surfaced as its own row, because it is a
        # finding for a human and not a failure now.
        if grep -q 'stopped renewing' /tmp/bootstrap-gh.out; then
            row WARN 0 "gh connector" "token stopped renewing -- 'maestro connectors github auth login' ON THE HOST"
        fi
    else
        row FAIL 1 "gh auth" "$(head -1 /tmp/bootstrap-gh.out | cut -c1-58)"
    fi
    rm -f /tmp/bootstrap-gh.out
else
    row FAIL 1 "gh auth" "gh NOT ON PATH -- the GitHub connector is gone"
fi

if [ -z "$PROJECT" ]; then
    row FAIL 1 "gcp connector" "no project to read -- ORCH_GCP_PROJECT is not set (orchestration/local.env)"
elif command -v gcloud >/dev/null 2>&1; then
    # ONE read, and it is the connector check the brief asks for: it proves the
    # bridged token is live, the project resolves and the identity can read.
    # Read-only, unbilled, and nothing is created, started, stopped or labelled.
    if gcloud compute instances list --project="$PROJECT" >/tmp/bootstrap-gcp.out 2>&1; then
        row ok 1 "gcp connector" "$(( $(wc -l < /tmp/bootstrap-gcp.out) - 1 )) instance(s) visible in $PROJECT"
    else
        row FAIL 1 "gcp connector" "$(grep -m1 -iE 'error|denied|unauth' /tmp/bootstrap-gcp.out | cut -c1-58)"
    fi
    rm -f /tmp/bootstrap-gcp.out
else
    row FAIL 1 "gcp connector" "gcloud NOT ON PATH -- the GCP connector is gone"
fi

# WHICH CLAUDE ACCOUNT THIS SESSION WILL SPEND. The same row status.sh prints
# and the same comparison batch-start.sh refuses on -- one implementation in
# token-guard.sh, four callers. It belongs in the readiness table because
# "ready" that does not include "on the intended account" is the exact claim the
# 17 September afternoon disproved: a Pro token re-injected by a pod restart,
# and a whole afternoon of limit messages about an account nobody chose.
#
# MISMATCH is REQUIRED-FAIL and the two other negative states are not. A session
# with no pin, or no token file of its own, is in a legitimate state that simply
# cannot be checked; a session whose token disagrees with the pin is
# misconfigured in a way that costs real money on somebody else's account.
if [ -r "$HERE/token-guard.sh" ]; then
    # shellcheck source=/dev/null
    . "$HERE/token-guard.sh"
    token_guard_evaluate
    case "$TOKEN_GUARD_STATE" in
        ok)       row ok   0 "claude token" "$TOKEN_GUARD_DETAIL" ;;
        MISMATCH) row FAIL 1 "claude token" "$TOKEN_GUARD_DETAIL" ;;
        *)        row WARN 0 "claude token" "$TOKEN_GUARD_STATE -- $TOKEN_GUARD_DETAIL" ;;
    esac
else
    row WARN 0 "claude token" "unchecked -- token-guard.sh is not beside this script"
fi

# Compared against the programme's project from orchestration/local.env (task
# P-4), which is what the devcontainer is meant to have set it to.
if [ -z "${ORCH_GCP_PROJECT:-}" ]; then
    row WARN 0 CLOUDSDK_CORE_PROJECT "'${CLOUDSDK_CORE_PROJECT:-unset}' -- not compared: ORCH_GCP_PROJECT is not set (orchestration/local.env)"
elif [ "${CLOUDSDK_CORE_PROJECT:-}" = "$ORCH_GCP_PROJECT" ]; then
    row ok 1 CLOUDSDK_CORE_PROJECT "$CLOUDSDK_CORE_PROJECT"
else
    row WARN 0 CLOUDSDK_CORE_PROJECT "'${CLOUDSDK_CORE_PROJECT:-unset}' -- .devcontainer/Dockerfile sets it; this session did not get it"
fi

# The model cache, reported rather than required: a missing one costs a download
# at first use and not a failure.
hf_home="${HF_HOME:-$HOME/.cache/huggingface}"
if [ -d "$hf_home/hub" ]; then
    row ok 0 "model cache" "$(du -sh "$hf_home" 2>/dev/null | cut -f1) in $hf_home"
else
    row WARN 0 "model cache" "empty ($hf_home) -- first use downloads 476 MB, 19 m 46 s measured"
fi

# The credential files. `--check` prints names, modes and byte counts and never
# a byte of any value.
cred_present=0
cred_table=$("$HERE/fetch-secrets.sh" --check 2>&1)
cred_present=$(printf '%s\n' "$cred_table" | grep -c ' present$')
if [ "$cred_present" = 3 ]; then
    row ok 0 credentials "3 of 3 present, mode 0600"
else
    row WARN 0 credentials "$cred_present of 3 present -- run fetch-secrets.sh"
fi

[ "$do_secrets"  = 1 ] && row "$([ "$secrets_state"  = ok ] && echo ok || echo FAIL)" 1 "stage: secrets"   "$secrets_state"
[ "$do_sync"     = 1 ] && row "$([ "$sync_state"     = ok ] && echo ok || echo FAIL)" 1 "stage: uv sync"   "$sync_state"
[ "$do_prefetch" = 1 ] && row "$([ "$prefetch_state" = ok ] && echo ok || echo WARN)" 0 "stage: prefetch"  "$prefetch_state"
[ "$do_tests"    = 1 ] && row "$(case "$fast_state" in ok*) echo ok;; *) echo FAIL;; esac)" 1 "stage: fast lane" "$fast_state"

# ---------------------------------------------------------------------------
# Print it
# ---------------------------------------------------------------------------
echo "== session readiness =="
printf '%-6s %-22s %s\n' STATE WHAT DETAIL
printf '%-6s %-22s %s\n' ------ ---------------------- ------
for entry in "${ROWS[@]}"; do
    IFS=$'\t' read -r state what detail <<< "$entry"
    printf '%-6s %-22s %s\n' "$state" "$what" "$detail"
done
echo
printf 'credential files (names, modes and sizes only):\n'
printf '%s\n' "$cred_table" | sed 's/^/  /'
echo

if [ "$required_failed" = 0 ]; then
    echo "READY: every required row is ok"
    exit 0
fi
printf 'NOT READY: %d required row(s) FAILED -- see the table above\n' "$required_failed"
exit 6
