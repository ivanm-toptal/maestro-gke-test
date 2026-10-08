#!/usr/bin/env bash
# gcp-janitor.sh — report (and optionally stop) project-labeled GPU VMs.
# Touches ONLY instances labeled purpose=$JANITOR_LABEL. Never anything else.
# Env: JANITOR_LABEL (required), JANITOR_PROJECTS (space-separated, required).
# Usage: gcp-janitor.sh [--report-only|--stop]   (env: JANITOR_MAX_HOURS=3)
set -euo pipefail
MODE="${1:---report-only}"; case "$MODE" in --report-only|--stop) ;; *) echo "usage: gcp-janitor.sh [--report-only|--stop]" >&2; exit 2;; esac
MAX_H="${JANITOR_MAX_HOURS:-3}"
LABEL="${JANITOR_LABEL:?set JANITOR_LABEL}"
read -r -a PROJECTS <<< "${JANITOR_PROJECTS:?set JANITOR_PROJECTS (space-separated)}"
now=$(date +%s)
for p in "${PROJECTS[@]}"; do
  echo "== $p =="
  # stderr is captured SEPARATELY, not folded into $out with 2>&1. gcloud prints
  # "WARNING: The following filter keys were not present in any resource" on a project with no
  # labelled VMs, and merged that line was parsed as a CSV row -- every clean report of an empty
  # project printed a phantom instance ("... age=?h keep=no"). The report is the audit trail
  # CLAUDE.md requires in every task report, so it has to be readable.
  err_file=$(mktemp)
  out=$(gcloud compute instances list --project="$p" \
        --filter="labels.purpose=$LABEL" \
        --format="csv[no-heading](name,zone.basename(),status,lastStartTimestamp,labels.keep)" 2>"$err_file") || {
    echo "  ERROR listing instances: $(cat "$err_file")"
    echo "  (auth/permission problem? surface this)"; rm -f "$err_file"; continue; }
  # Warnings are still shown -- suppressed diagnostics are how a broken filter goes unnoticed.
  if [ -s "$err_file" ]; then sed 's/^/  note: /' "$err_file"; fi
  rm -f "$err_file"
  [ -z "$out" ] && { echo "  (no $LABEL instances)"; continue; }
  while IFS=, read -r name zone status started keep; do
    [ -z "$name" ] && continue
    age_h="?"
    if [ -n "$started" ]; then
      st=$(date -d "$started" +%s 2>/dev/null || echo "$now")
      age_h=$(( (now - st) / 3600 ))
    fi
    printf '  %-38s %-14s %-10s age=%sh keep=%s\n' "$name" "$zone" "$status" "$age_h" "${keep:-no}"
    if [ "$MODE" = "--stop" ] && [ "$status" = "RUNNING" ] && [ "${keep:-}" != "true" ] \
       && [ "$age_h" != "?" ] && [ "$age_h" -ge "$MAX_H" ]; then
      echo "    -> stopping (running ${age_h}h >= ${MAX_H}h, no keep=true)"
      gcloud compute instances stop "$name" --zone="$zone" --project="$p" --quiet
    fi
  done <<< "$out"
done
echo "janitor done (mode=$MODE, max=${MAX_H}h; only purpose=$LABEL is ever touched)"
