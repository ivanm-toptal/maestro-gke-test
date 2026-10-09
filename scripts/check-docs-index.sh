#!/usr/bin/env bash
# check-docs-index.sh — is docs/README.md, the repository's index, still true?
#
# Fails (exit 1) and names every offender when:
#   1. a Markdown file under docs/ has no row of its own in the index;
#   2. a row's first cell is not a backticked path, or names a path that is not on disk
#      (a trailing `/` must be a directory);
#   3. any backticked path anywhere in the index (prose included) is not on disk, so the
#      index describes nothing that does not exist;
#   4. a docs/ledgers/ row does not say "grepped by task id" (ledgers are never read whole).
# Paths are relative to the repository root. Runs from any directory; reads only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX="docs/README.md"
cd "$ROOT"

if [[ ! -f "$INDEX" ]]; then
    echo "check-docs-index: FAIL — $INDEX does not exist" >&2
    exit 1
fi

fail=0
offend() { echo "  $1" >&2; fail=1; }

# Table body rows as "first-cell<TAB>whole-row"; separator and header rows ("| Path |") skipped.
rows=$(awk -F'|' '
    /^\|/ && !/^\|[ :|-]+\|[[:space:]]*$/ {
        cell = $2; gsub(/^[ \t]+|[ \t]+$/, "", cell)
        if (cell == "Path") next
        print cell "\t" $0
    }' "$INDEX")

indexed=()
while IFS=$'\t' read -r cell row; do
    [[ -z "$cell" ]] && continue
    if [[ ! "$cell" =~ ^\`([^\`]+)\`$ ]]; then
        offend "row's first cell is not a backticked path: $cell"
        continue
    fi
    path="${BASH_REMATCH[1]}"
    indexed+=("$path")
    if [[ "$path" == */ ]]; then
        [[ -d "$path" ]] || offend "indexed folder not on disk: $path"
    else
        [[ -e "$path" ]] || offend "indexed path not on disk: $path"
    fi
    if [[ "$path" == docs/ledgers/?* && "$row" != *"grepped by task id"* ]]; then
        offend "ledger row does not say \"grepped by task id\": $path"
    fi
done <<< "$rows"

# Every backticked token that looks like a repository path: has a "/" or a file extension,
# no spaces or placeholders, not absolute, not home-relative, not a flag.
while read -r token; do
    [[ -e "$token" ]] || offend "backticked path in the text not on disk: $token"
done < <(grep -o '`[^`]*`' "$INDEX" | tr -d '`' \
    | grep -E '^[A-Za-z0-9._][A-Za-z0-9._/-]*(/|\.[A-Za-z]{1,8})$|^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$' \
    | sort -u)

docs_md=0
while read -r md; do
    docs_md=$((docs_md + 1))
    found=0
    for p in "${indexed[@]}"; do [[ "$p" == "$md" ]] && { found=1; break; }; done
    [[ $found -eq 1 ]] || offend "Markdown file under docs/ missing from the index: $md"
done < <(find docs -type f -name '*.md' | sed 's|^\./||' | sort)

if [[ $fail -ne 0 ]]; then
    echo "check-docs-index: FAIL — offenders above ($INDEX)" >&2
    exit 1
fi
echo "check-docs-index: ok — ${#indexed[@]} rows, all on disk; $docs_md Markdown files under docs/, all indexed"
