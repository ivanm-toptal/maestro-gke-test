#!/usr/bin/env bash
# kit-diff.sh <kit-checkout> -- what the team kit must re-vendor from this repository.
#
# THE KIT (`toptal/maestro-k8s`, formerly `astyanax42/maestro-utils`) carries these scripts VERBATIM under
# `templates/orchestration/scripts/`, and `.maestro/config.json` as
# `templates/orchestration/config.json`. Verbatim is the whole design: since
# task P-4 nothing in them names a programme (`orch-env.sh` reads each pod's
# `orchestration/local.env`), so a copy needs no edit and the kit can be
# re-vendored by `cp`. What verbatim cannot do is notice that this repository
# moved on. A fix landed here and not re-vendored is a fix every teammate's
# pod lacks, and nobody finds out until their batch hits the bug this one
# already paid for. So this script says, file by file, where the two differ.
#
# It compares; it never writes to the kit, and it never pushes anything.
#
# Usage:
#   kit-diff.sh <kit-checkout>          one row per file, then the summary
#   kit-diff.sh --diff <kit-checkout>   the same, with each CHANGED file's diff
#
# Rows:
#   same      identical in both
#   CHANGED   in both, different -- re-vendor it (+added -removed lines, kit -> here)
#   NEW       here and not in the kit -- the kit must add it
#   KIT-ONLY  in the kit and not here -- the kit is carrying a file this
#             repository dropped (or never had); remove it or say why it stays
#
# Exit codes: 0 the kit is in sync / 1 the kit must re-vendor / 2 usage

set -uo pipefail

show_diff=0
[ "${1:-}" = --diff ] && { show_diff=1; shift; }
case "${1:-}" in
    -h|--help) sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    '') printf 'usage: kit-diff.sh [--diff] <kit-checkout>\n' >&2; exit 2 ;;
esac
KIT=$1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
KIT_SCRIPTS="$KIT/templates/orchestration/scripts"
[ -d "$KIT_SCRIPTS" ] || {
    printf 'kit-diff: %s has no templates/orchestration/scripts/ -- is it a checkout of the kit?\n' "$KIT" >&2
    exit 2
}

rev() {  # rev <dir> -> "<short hash> <commit date>", or "not a git checkout"
    git -C "$1" log -1 --format='%h %cs' 2>/dev/null || printf 'not a git checkout\n'
}
printf 'kit   %s at %s\n' "$KIT" "$(rev "$KIT")"
printf 'repo  %s at %s\n\n' "$REPO" "$(rev "$REPO")"

same=0 changed=0 new=0 kit_only=0
# Every file name on either side, once.
mapfile -t names < <(for f in "$HERE"/* "$KIT_SCRIPTS"/*; do
    [ -f "$f" ] && basename "$f"; done | sort -u)
# `<here-path>|<kit-path>|<name shown>`: the scripts, then the config the kit
# carries under a different name.
rows=()
for n in "${names[@]}"; do rows+=("$HERE/$n|$KIT_SCRIPTS/$n|scripts/$n"); done
rows+=("$REPO/.maestro/config.json|$KIT/templates/orchestration/config.json|config.json")

for row in "${rows[@]}"; do
    IFS='|' read -r here kit name <<< "$row"
    if [ -f "$here" ] && [ -f "$kit" ]; then
        if cmp -s "$kit" "$here"; then
            printf '%-9s %s\n' same "$name"; same=$((same + 1))
        else
            d=$(diff -u "$kit" "$here")
            plus=$(printf '%s\n' "$d" | grep -c '^+[^+]')
            minus=$(printf '%s\n' "$d" | grep -c '^-[^-]')
            printf '%-9s %-34s +%s -%s\n' CHANGED "$name" "$plus" "$minus"; changed=$((changed + 1))
            [ "$show_diff" = 1 ] && printf '%s\n\n' "$d"
        fi
    elif [ -f "$here" ]; then
        printf '%-9s %s\n' NEW "$name"; new=$((new + 1))
    elif [ -f "$kit" ]; then
        printf '%-9s %s\n' KIT-ONLY "$name"; kit_only=$((kit_only + 1))
    fi
done

owed=$((changed + new + kit_only))
printf '\n%d same, %d changed, %d new, %d kit-only' "$same" "$changed" "$new" "$kit_only"
if [ "$owed" -eq 0 ]; then
    printf ' -- the kit is in sync with this repository\n'
    exit 0
fi
printf ' -- the kit must re-vendor %d file(s)\n' "$owed"
printf 'Re-vendor: copy every CHANGED and NEW file\n  from %s\n  into %s\n' "$HERE" "$KIT_SCRIPTS"
printf 'and .maestro/config.json to templates/orchestration/config.json; a KIT-ONLY file is\n'
printf 'removed, or kept with a reason in the kit.\n'
exit 1
