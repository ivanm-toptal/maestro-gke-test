#!/usr/bin/env bash
# fetch-secrets.sh — put this session's three credential files on disk from
# GCP Secret Manager, using the session's own connector identity.
#
# WHY SECRET MANAGER AND NOT A MOUNT. A Maestro host mount exists only while the
# CLI is attached and it cannot carry a single file
# (https://maestro.toptal.net/docs/mounts.md), and $HOME -- which is where all
# three files live -- is reproduced from the image on a rebuild and absent in
# any fresh session. (A remote `maestro resume --latest` DOES keep $HOME;
# `orchestration/HANDOVER.md` section 7 verified that. The case this script
# exists for is the first start and the rebuild, not the resume.) So the three
# files every live path in this repository reads by absolute path --
# ~/.zoom.env, ~/.livekit.env, ~/.liveavatar.key -- have to be fetchable, and
# Secret Manager is the one store the session is already authenticated against.
#
# THE SECRETS ARE THE SOURCE OF TRUTH, not the files. docs/contracts/DEPLOYMENT.md says so
# and says how to update one; this script is the read side of that statement and
# nothing else. It never writes to Secret Manager.
#
# WHAT IT REFUSES TO DO. Overwrite a local file that is NEWER than the secret
# version it would be replaced by. That is the shape of the accident worth
# preventing: somebody edits ~/.livekit.env in a session to chase a credential
# problem, runs the bootstrap again an hour later, and silently loses the edit.
# `--force` is the override and it is never implied.
#
# WHAT IT NEVER PRINTS. A byte of any secret. Every fetch writes gcloud's stdout
# straight into a file with a redirect -- the value is never in a variable, an
# argument, a log line or this script's own output -- and what is reported is the
# file name, its byte count and its mode. `set -x` would break that promise, so
# there is deliberately no debug flag.
#
# Usage:
#   fetch-secrets.sh            fetch any file that is missing or older
#   fetch-secrets.sh --force    fetch all three, newer local file or not
#   fetch-secrets.sh --check    report presence, mode and size; fetch nothing
#
# Environment:
#   AVATAR_SECRETS_PROJECT   the Secret Manager project (default
#                            ORCH_GCP_PROJECT, orchestration/local.env)
#   ORCH_VM_PREFIX           the programme's resource prefix; the secrets are
#                            named <prefix>zoom-env, <prefix>livekit-env and
#                            <prefix>liveavatar-key (orchestration/local.env)
#   AVATAR_SECRETS_HOME      where the three files go (default $HOME). Use THIS
#                            and never HOME to redirect them -- see below.
#
# Exit codes: 0 ok / 2 usage / 3 a secret is missing or unreadable /
#             4 a local file is newer and --force was not given /
#             5 gcloud is not on PATH

set -euo pipefail

# EVERY file this script creates, and every temporary file on the way, is 0600.
# Set before the first redirect rather than per-file, because the failure mode
# of per-file chmod is a window in which the file exists world-readable.
umask 077

# WHOSE SECRETS come from orchestration/local.env (task P-4): the project, and
# the prefix every resource of the programme carries -- its machines and these
# three secrets alike. Neither has a default; `--check` needs neither, and a
# fetch without them is refused below, naming the key.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orch-env.sh"
orch_env_load
PROJECT="${AVATAR_SECRETS_PROJECT:-${ORCH_GCP_PROJECT:-}}"

# WHERE THE FILES GO, AS ITS OWN VARIABLE, AND THE REASON IS A TRAP WORTH
# NAMING. The obvious way to test this script is `HOME=/tmp/somewhere
# fetch-secrets.sh` -- and it cannot work, because Maestro's gcloud wrapper
# resolves the session's bridged token as `$HOME/.maestro/gcp_token`. Override
# HOME and gcloud loses its credential: the run fails with "You do not
# currently have an active account selected", which reads exactly like an
# expired connector and is not one. (Measured both ways on 2026-09-14: tmp HOME
# -> no active account, real HOME -> the project's actual SERVICE_DISABLED
# error.)
#
# So the DESTINATION directory is separate from HOME. A test points
# AVATAR_SECRETS_HOME at a temporary directory and leaves the credential lookup
# alone; production sets neither and gets $HOME, which is what every reader in
# this repository expects.
DEST_HOME="${AVATAR_SECRETS_HOME:-$HOME}"

#: `secret-name<TAB>destination`. The basenames are the paths the code reads and
#: are NOT configurable: a credential file this repository cannot find is the
#: same outage as one that does not exist.
MAP=(
    "${ORCH_VM_PREFIX:-}zoom-env	${DEST_HOME}/.zoom.env"
    "${ORCH_VM_PREFIX:-}livekit-env	${DEST_HOME}/.livekit.env"
    "${ORCH_VM_PREFIX:-}liveavatar-key	${DEST_HOME}/.liveavatar.key"
)

die() { printf 'fetch-secrets: %s\n' "$1" >&2; exit "${2:-1}"; }

mode=fetch
case "${1-}" in
    ""|--fetch) ;;
    --force) mode=force ;;
    --check) mode=check ;;
    -h|--help) sed -n '/^# Usage:/,/^#  *5 gcloud/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --check, --force, --help)" 2 ;;
esac

# ---------------------------------------------------------------------------
# --check: report, fetch nothing, need no network and no credential
# ---------------------------------------------------------------------------
if [ "$mode" = check ]; then
    missing=0
    permissive=0
    printf '%-26s %-6s %10s  %s\n' FILE MODE BYTES STATE
    for row in "${MAP[@]}"; do
        dest=${row#*$'\t'}
        if [ -e "$dest" ]; then
            # `stat` and not `ls`: the mode as four octal digits is the thing
            # being asserted, and `-L` so a symlinked credential reports the
            # target's mode rather than a symlink's meaningless 0777.
            file_mode=$(stat -L -c '%04a' "$dest")
            # A CREDENTIAL ANY OTHER USER CAN READ IS A FINDING, not a detail,
            # and reporting the mode without judging it would leave the caller
            # to notice. `0600` is the only value this script ever writes, so
            # anything else was set by something else -- a `docker cp`, an
            # editor, a copy from a mount -- and the bootstrap's table says
            # "3 of 3 present, mode 0600" only when that is literally true.
            if [ "$file_mode" = 0600 ]; then
                file_state=present
            else
                file_state="PERMISSIVE (want 0600)"
                permissive=$((permissive + 1))
            fi
            printf '%-26s %-6s %10s  %s\n' \
                "$(basename "$dest")" \
                "$file_mode" \
                "$(stat -L -c '%s' "$dest")" \
                "$file_state"
        else
            printf '%-26s %-6s %10s  %s\n' "$(basename "$dest")" - - MISSING
            missing=$((missing + 1))
        fi
    done
    printf '%d of %d present in %s' "$(( ${#MAP[@]} - missing ))" "${#MAP[@]}" "$DEST_HOME"
    [ "$permissive" -gt 0 ] && printf ', %d with a mode other than 0600' "$permissive"
    printf '\n'
    if [ "$permissive" -gt 0 ]; then
        printf 'tighten them:  chmod 600 %s/.zoom.env %s/.livekit.env %s/.liveavatar.key\n' \
            "$DEST_HOME" "$DEST_HOME" "$DEST_HOME"
    fi
    # rc 0 even when files are missing or loose: --check is a REPORT, and the
    # bootstrap reads the table. A missing file is the fetch's problem and a
    # loose mode is the table's row, neither is this report's exit code.
    exit 0
fi

[ -n "$PROJECT" ] || die "no Secret Manager project: ORCH_GCP_PROJECT is not set (orchestration/local.env; every key is in local.env.example), and AVATAR_SECRETS_PROJECT is not set either." 2
[ -n "${ORCH_VM_PREFIX:-}" ] || die "no secret names: ORCH_VM_PREFIX is not set (orchestration/local.env; every key is in local.env.example)." 2

command -v gcloud >/dev/null || die "gcloud not on PATH.
  In a Maestro session the SDK comes from the platform layer and the connector
  wrapper at /usr/local/bin/gcloud, not from .devcontainer/Dockerfile.
  If it is gone, the GCP connector is gone: run 'maestro connectors gcp auth
  login' ON THE HOST (not in this container)." 5

# ---------------------------------------------------------------------------
# The fetch
# ---------------------------------------------------------------------------
fetched=0
kept=0
for row in "${MAP[@]}"; do
    secret=${row%%$'\t'*}
    dest=${row#*$'\t'}

    # The version's create time, which is what "newer" is measured against. It
    # is also the cheapest existence check there is, so a missing secret is
    # diagnosed HERE -- before anything is written and before the value of a
    # secret that does exist has been read.
    # `--quiet` IS LOAD-BEARING AND NOT TIDINESS. Without it, gcloud answers a
    # disabled Secret Manager API by PROMPTING -- "API [secretmanager.
    # googleapis.com] not enabled on project [...]. Would you like to enable and
    # retry (this will take a few minutes)? (y/N)?" -- and a bootstrap that
    # blocks on a hidden y/N is a session that looks hung. It also means this
    # script can never be the thing that enables an API by accident.
    if ! created=$(gcloud secrets versions describe latest \
            --secret="$secret" --project="$PROJECT" --quiet \
            --format='value(createTime)' 2>/tmp/fetch-secrets.err); then
        # The ERROR: line, not a blind tail. gcloud writes a paragraph, an
        # activation URL and a YAML error-info block, and the connector wrapper
        # prepends its own health warning on stderr -- a `tail -3` of all that
        # lands on whichever boilerplate happens to be last, which the first
        # draft of this script demonstrated.
        detail=$(grep -m1 '^ERROR:' /tmp/fetch-secrets.err | cut -c1-300)
        [ -n "$detail" ] || detail=$(grep -vE '^(⚠|  )' /tmp/fetch-secrets.err | grep -v '^$' | head -1)
        classified=$(cat /tmp/fetch-secrets.err)
        rm -f /tmp/fetch-secrets.err

        # THREE DIFFERENT PROBLEMS WEAR THE SAME EXIT CODE OUT OF gcloud, and
        # they need three different humans to do three different things. Telling
        # somebody to run `gcloud secrets create` when the API is switched off
        # sends them to a command that fails the same way.
        case "$classified" in
            *SERVICE_DISABLED*|*"has not been used in project"*)
                die "the Secret Manager API is NOT ENABLED in project '$PROJECT',
  so '$secret' cannot be read and cannot yet be created there.
  gcloud: $detail

  orchestration/HANDOVER.md section 7 records which of the programme's
  projects has the API and that enabling it elsewhere was refused for the
  researcher's identity. So it is a HUMAN action and not a retry:

    1. enable the API once, with an identity that may:
         gcloud services enable secretmanager.googleapis.com --project=$PROJECT
    2. then create the secret and its first version from the file:
         gcloud secrets create $secret \\
             --project=$PROJECT --replication-policy=automatic
         gcloud secrets versions add $secret \\
             --project=$PROJECT --data-file=$dest

  Or point this script at the project that HAS the API, which needs no new
  permission at all:

    AVATAR_SECRETS_PROJECT=<the project that has it> $0

  Surface it in docs/ledgers/ACCESS-REPORT.md. Do not retry." 3
                ;;
            *"do not currently have an active account"*|*"credentials were not found"*)
                # SEEN ONCE, TRANSIENTLY, ON 2026-09-14: the same command
                # answered SERVICE_DISABLED before and after, so the bridged
                # token was simply not delivered to that one invocation. The
                # connector's health marker said `reason=refresh-unavailable` at
                # the time. It gets its own branch because the generic advice
                # below -- "ask for the accessor role" -- is the wrong errand
                # for it, and because a caller that cannot tell the two apart
                # will retry the one that must not be retried.
                die "gcloud had NO CREDENTIAL for this call in project '$PROJECT'.
  gcloud: $detail

  The session's bridged token was not delivered. If ~/.maestro/connector_health_gcp
  says 'connector_unavailable' then renewal has stopped and the fix is on the
  host, not here:

    maestro connectors gcp auth login

  This has also been seen as a one-off while other gcloud calls in the same
  minute succeeded. Either way it is an ACCESS FINDING: record it in
  docs/ledgers/ACCESS-REPORT.md. Do not retry in a loop." 3
                ;;
            *NOT_FOUND*|*"was not found"*)
                die "secret '$secret' does not exist in project '$PROJECT'.
  gcloud: $detail

  These two commands create it from the file you already have -- run them where
  that file is, never in this repository:

    gcloud secrets create $secret \\
        --project=$PROJECT --replication-policy=automatic
    gcloud secrets versions add $secret \\
        --project=$PROJECT --data-file=$dest" 3
                ;;
            *)
                die "cannot read secret '$secret' in project '$PROJECT'.
  gcloud: $detail

  If the secret exists, this is an access problem and not a missing secret: the
  session identity needs roles/secretmanager.secretAccessor on it. If the
  connector warned that its token stopped renewing, that is the cause and the
  fix is on the host:

    maestro connectors gcp auth login

  Surface it in docs/ledgers/ACCESS-REPORT.md rather than retrying." 3
                ;;
        esac
    fi
    rm -f /tmp/fetch-secrets.err

    # `date -d` parses the RFC 3339 gcloud prints. Compared as epoch seconds so
    # the test is arithmetic rather than string ordering.
    created_epoch=$(date -d "$created" +%s)

    # WHAT "NEWER" MEANS, AND WHY IT IS DECIDABLE AT ALL. An installed file's
    # mtime is set BELOW to the create time of the version it came from, so the
    # mtime is not "when I last ran this" -- it is a record of WHICH VERSION is
    # on disk. That makes the three cases distinct instead of one moving
    # target, and it is what makes a second run of the bootstrap a no-op
    # rather than a refusal:
    #
    #   mtime == version    this file IS the latest version   -> keep
    #   mtime <  version    a newer version was published     -> fetch
    #   mtime >  version    somebody edited it here           -> refuse
    #
    # Without the stamp, every successful fetch would leave a file "newer" than
    # its own source and the next run would refuse -- the bug this comment
    # exists because the first draft had.
    if [ -e "$dest" ] && [ "$mode" != force ]; then
        local_epoch=$(stat -L -c '%Y' "$dest")
        if [ "$local_epoch" -eq "$created_epoch" ]; then
            printf 'kept    %-22s -> %-24s %8s bytes  mode %s  (already the latest version)\n' \
                "$secret" "$(basename "$dest")" "$(stat -L -c '%s' "$dest")" "$(stat -L -c '%04a' "$dest")"
            kept=$((kept + 1))
            continue
        fi
        if [ "$local_epoch" -gt "$created_epoch" ]; then
            die "$(basename "$dest") is NEWER than the latest version of '$secret'
  ($(date -d "@$local_epoch" -Is) local vs $created in Secret Manager).

  Overwriting it would discard an edit nobody recorded. Either publish the
  local file as a new version --

    gcloud secrets versions add $secret \\
        --project=$PROJECT --data-file=$dest

  -- or discard it deliberately with 'fetch-secrets.sh --force'." 4
        fi
    fi

    # ATOMIC, AND THE REASON IS NOT TIDINESS. A half-written credential file is
    # indistinguishable from a wrong one to every reader in this repository, and
    # the readers are live paths in a meeting. Write beside the destination (same
    # filesystem, so mv is a rename) and swap.
    tmp="${dest}.fetching.$$"
    trap 'rm -f "$tmp"' EXIT
    if ! gcloud secrets versions access latest \
            --secret="$secret" --project="$PROJECT" --quiet > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "reading the value of '$secret' failed after its version described cleanly.
  That is a transient or a permission boundary between describe and access;
  nothing was written. Do not retry in a loop -- surface it." 3
    fi
    bytes=$(stat -c '%s' "$tmp")
    [ "$bytes" -gt 0 ] || { rm -f "$tmp"; die "'$secret' latest version is EMPTY (0 bytes); refusing to install it" 3; }
    mv -f "$tmp" "$dest"
    trap - EXIT
    chmod 600 "$dest"
    # The stamp the comparison above depends on. `-d "$created"` and not
    # `-r`/now: the file's mtime becomes the identity of the version it holds.
    touch -d "$created" "$dest"
    printf 'fetched %-22s -> %-24s %8s bytes  mode %s  version %s\n' \
        "$secret" "$(basename "$dest")" "$bytes" "$(stat -c '%04a' "$dest")" "$created"
    fetched=$((fetched + 1))
done

printf '%d fetched, %d kept, project %s\n' "$fetched" "$kept" "$PROJECT"
