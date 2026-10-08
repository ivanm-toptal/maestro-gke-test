#!/usr/bin/env bash
# token-guard.sh — is this pod running on the Claude account we think it is?
#
# WHY THIS EXISTS, and it cost an afternoon to learn (17 September 2026). A pod
# RESTART re-injects `~/.maestro/claude_token` from Maestro's session record,
# and that record holds the token the session was CREATED with -- here, a Pro
# account from 15 September. After the 11:40 UTC reboot the whole afternoon
# therefore ran on Pro: no Fable, a small five-hour window, two windows
# exhausted, while the Max account the work was supposed to be on sat at 2 per
# cent. Nothing anywhere said so. Every symptom pointed at usage limits, which
# is precisely the wrong diagnosis, and "requires usage credits" is a true
# message about an account nobody chose.
#
# The intended account is pinned by hash in
# `~/.maestro/expected_claude_token_sha256`. This file is the one comparison,
# used by four callers -- status.sh and bootstrap-session.sh report the row,
# batch-start.sh and batch-resume.sh REFUSE on a mismatch -- because four copies
# of a hash comparison is three chances to get it subtly different.
#
# THE TRIMMING IS THE WHOLE TRICK, AND GETTING IT WRONG INVERTS THE ANSWER.
# The expected hash is the sha256 of the token's CONTENT with surrounding
# whitespace removed, NOT of the file's bytes. Measured on this pod, 17
# September: the file hashes to 6f6f1c91… and its trimmed content to 0228f181…,
# and the expected file holds 0228f181…. A guard written the obvious way --
# `sha256sum ~/.maestro/claude_token` -- therefore reports MISMATCH on a
# perfectly correct token, and since batch-start.sh refuses on MISMATCH it would
# refuse to start every batch, for ever, with a message blaming the account. A
# false alarm on this particular check is worse than no check at all.
#
# NOTHING HERE PRINTS A TOKEN. The only values that leave this file are hash
# PREFIXES (12 hex characters), which identify an account without being a
# credential. `docs/OPERATING.md` section 2: never print a secret, compare
# hashes.
#
# Usage:
#   . token-guard.sh   &&  token_guard_state      -> ok | MISMATCH | unpinned | absent
#                          token_guard_detail     -> a printable, secret-free detail
#   token-guard.sh                                -> prints "token: <state> — <detail>"
#                                                    exit 0 ok/unpinned, 1 MISMATCH, 2 absent
#
# The token and the pin are read from $HOME, which is what makes this testable:
# a test points HOME at a temporary directory and writes whichever pair it wants
# to assert about.

_token_guard_file()     { printf '%s/.maestro/claude_token' "$HOME"; }
_token_guard_pin_file() { printf '%s/.maestro/expected_claude_token_sha256' "$HOME"; }

#: The sha256 of a file's content with ALL whitespace stripped -- see the header.
_token_guard_hash() {
    # `tr -d '[:space:]'` and not `cat`: a trailing newline is the difference
    # between the two hashes measured above.
    tr -d '[:space:]' < "$1" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1
}

#: Sets TOKEN_GUARD_STATE and TOKEN_GUARD_DETAIL. Idempotent, reads only.
token_guard_evaluate() {
    local token pin actual expected
    token=$(_token_guard_file)
    pin=$(_token_guard_pin_file)

    if [ ! -r "$token" ]; then
        TOKEN_GUARD_STATE=absent
        TOKEN_GUARD_DETAIL="no readable $token -- this session has no Claude token of its own"
        return 0
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        TOKEN_GUARD_STATE=absent
        TOKEN_GUARD_DETAIL="sha256sum is not on PATH, so the account cannot be identified"
        return 0
    fi
    actual=$(_token_guard_hash "$token")
    if [ ! -r "$pin" ]; then
        # NOT A FAILURE. A session that never pinned an account is in a
        # legitimate state; it simply cannot be checked. Saying so, and saying
        # how to pin it, beats a FAIL that means "unconfigured".
        TOKEN_GUARD_STATE=unpinned
        TOKEN_GUARD_DETAIL="running ${actual:0:12}…; no pin at $pin (write the sha256 there to arm this check)"
        return 0
    fi
    expected=$(tr -d '[:space:]' < "$pin" | tr 'A-F' 'a-f')
    if [ "$actual" = "$expected" ]; then
        TOKEN_GUARD_STATE=ok
        TOKEN_GUARD_DETAIL="${actual:0:12}… matches the pinned account"
    else
        TOKEN_GUARD_STATE=MISMATCH
        TOKEN_GUARD_DETAIL="running ${actual:0:12}…, pinned ${expected:0:12}… -- the pod is on the WRONG Claude account (docs/LESSONS.md: re-inject over ssh stdin from the dev box)"
    fi
    return 0
}

token_guard_state()  { token_guard_evaluate; printf '%s' "$TOKEN_GUARD_STATE"; }
token_guard_detail() { token_guard_evaluate; printf '%s' "$TOKEN_GUARD_DETAIL"; }

# Executed rather than sourced: print the row and answer with the exit code.
# `$0` comparison rather than BASH_SOURCE equality so a `bash token-guard.sh`
# and a `./token-guard.sh` behave the same.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    token_guard_evaluate
    printf 'token: %s — %s\n' "$TOKEN_GUARD_STATE" "$TOKEN_GUARD_DETAIL"
    case "$TOKEN_GUARD_STATE" in
        ok|unpinned) exit 0 ;;
        MISMATCH)    exit 1 ;;
        *)           exit 2 ;;
    esac
fi
