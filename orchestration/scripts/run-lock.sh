#!/usr/bin/env bash
# run-lock.sh — one lock per branch, so two runs of the orchestration tooling
# cannot destroy each other's work. Sourced, never executed.
#
# WHY IT EXISTS, and the date is 18 September 2026, 14:19 UTC. Two orchestrator
# conversations ran batch B3 at once and both called `verify-detached.sh
# worker/p-2`. That script derived its worktree path from the branch name
# ALONE, and cleared an existing tree with `worktree remove --force` before
# starting; so the second start deleted the first run's checkout at 14:19:00
# and the first run's own cleanup deleted the second's at 14:19:31. The
# survivor's pytest ran to 100 % inside a directory that no longer existed,
# ended in FileNotFoundError with `pytest_exit=1` and NO summary line, and that
# was reported as a verdict on the branch. Nothing wrong reached master, but
# only because a human read the output closely.
#
# Two mechanisms come out of that, and they are different mechanisms:
#
#   the per-run TAG   (in verify-detached.sh) means two runs never share a
#                     directory, so neither can delete the other's by name
#   the LOCK          (here) means two runs of the same branch do not overlap
#                     at all, so the SECOND one is refused loudly instead of
#                     quietly racing the first
#
# The tag alone would let two verifications of one branch run concurrently and
# report two different answers about the same commit; the lock alone would
# leave the fixed path in place for anything that bypasses it. Both.
#
# WHY `mkdir` AND NOT A LOCK FILE. `mkdir` is atomic on every filesystem this
# runs on: it either creates the directory or fails, with no window between the
# test and the create. `[ -e lock ] || touch lock` has that window and it is
# exactly the width of the race being prevented.
#
# WHY THE PID IS INSIDE IT. A lock that outlives its owner is a lock nobody can
# ever take again -- and a killed verification (which is the case this whole
# file is about) leaves precisely that. So the holder's pid is written into the
# directory and a lock whose pid is not alive is STALE and may be reclaimed. The
# liveness test is the one docs/LESSONS.md spells out: `[ -e /proc/$pid ]` is
# NOT enough, because a killed process stays in the table as a zombie until its
# parent reaps it, and a zombie's `cmdline` is empty. Non-empty `cmdline` is
# the test.
#
# Usage, from a script that has ROOT set:
#   . "$HERE/run-lock.sh"
#   run_lock_acquire "$ROOT" "$tag" "$$" 0   || exit 4   # 0 = do not wait
#   trap 'run_lock_release "$ROOT" "$tag" "$$"' EXIT
#
# The lock directory is "$ROOT/.maestro/lock/<tag>"; `.maestro/*` is git-ignored
# (.gitignore), so a lock is per-container litter and never reaches a commit.

#: Where a tag's lock lives. One function so the path exists in one place and a
#: test can point the whole mechanism at a throwaway root.
run_lock_dir() {  # run_lock_dir <root> <tag>
    printf '%s/.maestro/lock/%s\n' "$1" "$2"
}

#: The pid currently recorded in a lock, or the empty string.
run_lock_holder() {  # run_lock_holder <root> <tag>
    local d
    d=$(run_lock_dir "$1" "$2")
    [ -r "$d/pid" ] || return 1
    tr -dc '0-9' < "$d/pid"
}

#: Is <pid> a live process? NOT `[ -e /proc/$pid ]`: a killed child stays in the
#: process table as a zombie until it is reaped, and a zombie holds no lock.
#: A zombie's cmdline is empty, so a non-empty cmdline is the discriminator, and
#: it is checked on the pseudo-filesystem rather than through `ps` because `ps`
#: is not guaranteed to be installed in a minimal container.
#:
#: `[ -s /proc/$pid/cmdline ]` IS NOT THE TEST, and writing it that way is a
#: silent catastrophe rather than a bug: procfs reports st_size 0 for every one
#: of these files, live process or not (measured on this pod, 21 September --
#: `ls -l /proc/$$/cmdline` says 0 while `tr -d '\0' <` it prints the whole
#: argv). A `-s` test is therefore ALWAYS false, every lock looks stale, every
#: holder gets reclaimed, and the lock silently degrades into no lock at all --
#: which is precisely the failure it was written to prevent. The content has to
#: be read.
run_lock_pid_alive() {  # run_lock_pid_alive <pid>
    local pid=$1 argv
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    argv=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null)
    [ -n "$argv" ] || return 1   # empty => zombie, or gone mid-read
    RUN_LOCK_PID_ARGV=$argv
    return 0
}

#: THE ACQUIRE. Returns 0 holding the lock, 1 having given up.
#:
#: `wait_s` is the number of seconds to keep trying before giving up; 0 means
#: refuse immediately. Refusing is the DEFAULT for a verification because two
#: verifications of one branch are almost always a mistake somebody should hear
#: about (they were, in B3) rather than a queue to be served politely; landing
#: waits, because a land that arrives while its own branch is being verified is
#: a legitimate order of events.
#:
#: RUN_LOCK_DETAIL is set on every return so the caller can print WHY.
run_lock_acquire() {  # run_lock_acquire <root> <tag> <pid> [wait_s]
    local root=$1 tag=$2 pid=$3 wait_s=${4:-0}
    local d waited=0 holder reclaimed=""
    d=$(run_lock_dir "$root" "$tag")
    mkdir -p "$(dirname "$d")" 2>/dev/null || {
        RUN_LOCK_DETAIL="cannot create $(dirname "$d")"
        return 1
    }

    while :; do
        if mkdir "$d" 2>/dev/null; then
            printf '%s\n' "$pid" > "$d/pid"
            printf '%s %s\n' "$(date -u +%FT%TZ)" "${RUN_LOCK_WHAT:-run}" > "$d/what"
            # THE RECLAIM IS CARRIED THROUGH TO THE SUCCESS MESSAGE. Setting
            # RUN_LOCK_DETAIL at the reclaim and then overwriting it here would
            # make a reclaimed lock look like a free one, and "a previous run of
            # this branch was killed" is exactly the thing the caller must see.
            RUN_LOCK_DETAIL="acquired $d for pid $pid$reclaimed"
            return 0
        fi

        holder=$(run_lock_holder "$root" "$tag" || true)
        if ! run_lock_pid_alive "$holder"; then
            # A STALE LOCK IS RECLAIMED, NOT WAITED ON. This is the killed-run
            # case and it is the common one: a verification that was killed
            # mid-suite never ran its release. Reclaiming is announced in
            # RUN_LOCK_DETAIL so it appears in the caller's output -- a lock
            # that silently reappears is a lock nobody debugs.
            rm -rf "$d"
            reclaimed=" (after reclaiming a STALE lock held by pid ${holder:-?}, which is not alive -- that run was killed and may have left a worktree behind)"
            # Loop rather than assume: another process may reclaim it first, and
            # the mkdir above is what decides.
            continue
        fi

        if [ "$waited" -ge "$wait_s" ]; then
            RUN_LOCK_DETAIL="held by pid $holder$( [ -r "$d/what" ] && printf ' (%s)' "$(cat "$d/what")" )"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

#: THE RELEASE, and it only releases a lock THIS pid holds. A release that did
#: not check would let a late EXIT trap from a dead run remove a live run's
#: lock, which is the same bug as the force-remove this file exists to stop --
#: one level up.
run_lock_release() {  # run_lock_release <root> <tag> <pid>
    local root=$1 tag=$2 pid=$3 d holder
    d=$(run_lock_dir "$root" "$tag")
    [ -d "$d" ] || return 0
    holder=$(run_lock_holder "$root" "$tag" || true)
    if [ "$holder" = "$pid" ]; then
        rm -rf "$d"
        return 0
    fi
    RUN_LOCK_DETAIL="not released: $d is held by pid ${holder:-?}, not by $pid"
    return 1
}

#: Hand the lock to another pid, without ever letting it go. `verify-detached.sh`
#: takes the lock in the parent process and then execs a DETACHED runner that
#: outlives it; the lock has to survive that hand-off, and releasing and
#: re-acquiring would open exactly the window the lock closes.
run_lock_handover() {  # run_lock_handover <root> <tag> <from-pid> <to-pid>
    local root=$1 tag=$2 from=$3 to=$4 d holder
    d=$(run_lock_dir "$root" "$tag")
    holder=$(run_lock_holder "$root" "$tag" || true)
    [ "$holder" = "$from" ] || {
        RUN_LOCK_DETAIL="cannot hand over $d: held by ${holder:-?}, not by $from"
        return 1
    }
    printf '%s\n' "$to" > "$d/pid"
    RUN_LOCK_DETAIL="handed $d from $from to $to"
    return 0
}

#: A branch name as a filesystem tag. `worker/d-15` -> `worker-d-15`. The same
#: transformation verify-detached.sh already used for its output file, lifted
#: here so the lock and the paths cannot drift apart.
run_lock_tag() {  # run_lock_tag <branch>
    printf '%s' "$1" | tr '/' '-'
}
