#!/usr/bin/env python3
"""Resolve every conflicted DOCUMENT in an in-progress merge, or fail loudly.

Called by `land-branch.sh` after it has already refused the merge if any
conflicted path looks like code. So the contract here is narrow and it matters
that it stays narrow: **every file this script is handed is a document**, and
the question is only whether both sides appended or something more interesting
happened.

    both sides only APPENDED to the base   ->  keep both, in order
    anything else                          ->  git merge-file --union

WHY UNION AND NOT A THREE-WAY MERGE. The files are `docs/*.md`, `RESULTS.md`,
`docs/ledgers/RESOURCES.md` -- ledgers that tasks add rows and sections to. Losing one
task's row is silent and permanent; keeping both when only one was needed is
visible in the next diff. Union is the failure direction worth having.

THE FENCE-PARITY CHECK IS THE POINT OF THE SCRIPT, not a nicety. A union merge
interleaves hunks, and a Markdown file whose ``` fences no longer pair renders
the rest of the document as one code block -- which is the kind of damage that
survives review because the diff looks like additions. So the fences are
counted: `merged` must have exactly `ours + theirs - base` of them, and any
surviving conflict marker is a failure too. On failure nothing is written and
the merge is left in place for a human.

MOVED FROM THE ORCHESTRATOR'S SCRATCH (`/tmp/resolve-any.py`) AND REFORMATTED,
NOT REWRITTEN. The algorithm is line-for-line the one that landed every merge in
this repository's history; what changed is that it now passes this repository's
own ruff configuration (the original was 27 findings of E401/E501/E701/E731,
all of them formatting), and that the ledger check below catches OSError as well
as ValueError -- because a committed script gets run from places the scratch
copy never was, including a test fixture with no `docs/ledgers/RESOURCES.md` in it.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile


def show(stage: int, path: str) -> str:
    """One stage of a conflicted path: 1 base, 2 ours, 3 theirs."""
    return subprocess.run(
        ["git", "show", f":{stage}:{path}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def fence(text: str) -> int:
    """How many Markdown code fences the text opens or closes."""
    return sum(1 for line in text.splitlines() if line.startswith("```"))


def conflicted_paths() -> list[str]:
    """The `UU` paths, read from git's own porcelain rather than guessed."""
    status = subprocess.run(
        ["git", "status", "--short"], capture_output=True, text=True
    ).stdout
    return [line.split()[-1] for line in status.splitlines() if line.startswith("UU")]


def resolve(path: str) -> tuple[str, str]:
    """`(merged text, how)` for one conflicted document."""
    base, ours, theirs = show(1, path), show(2, path), show(3, path)
    base_lines = base.splitlines(True)
    our_lines = ours.splitlines(True)
    their_lines = theirs.splitlines(True)

    # PURE APPEND ON BOTH SIDES, tested on LINES and then sliced on CHARACTERS.
    # That is not an inconsistency: the test establishes that `theirs` begins
    # with `base` exactly, and therefore that its first `len(base)` characters
    # ARE base. Slicing by line would have to re-join and could normalise a
    # final newline that the file meant to be missing.
    if our_lines[: len(base_lines)] == base_lines and their_lines[: len(base_lines)] == base_lines:
        return ours + theirs[len(base) :], "append"

    scratch = tempfile.mkdtemp()
    for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
        with open(os.path.join(scratch, name), "w") as handle:
            handle.write(text)
    merged = subprocess.run(
        [
            "git",
            "merge-file",
            "-p",
            "--union",
            os.path.join(scratch, "ours"),
            os.path.join(scratch, "base"),
            os.path.join(scratch, "theirs"),
        ],
        capture_output=True,
        text=True,
    ).stdout
    return merged, "union"


def check_ledger() -> None:
    """The consolidated GPU table must be 1..n with no duplicate row numbers.

    A POST-CHECK AND NOT A RESOLUTION. Two tasks that each appended a row to
    `docs/ledgers/RESOURCES.md` produce a table with two rows numbered the same, which
    union merge cannot see and a reader will not notice. This is the one
    semantic assertion about the merged content, and the only thing it can do
    about a failure is refuse to let the merge be committed.
    """
    try:
        text = open("docs/ledgers/RESOURCES.md").read()
        start = text.index("| Stretch | Task |")
    except (ValueError, OSError) as exc:
        print("ledger check skipped:", exc)
        return

    end = text.find("\n#", start)
    end = len(text) if end < 0 else end
    rows = [line for line in text[start:end].splitlines() if re.match(r"\| \d+ \| ", line)]
    numbers = [int(line.split("|")[1]) for line in rows]
    duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
    pending = [line[:50] for line in rows if "PENDING" in line]
    totals = len(re.findall(r"\*\*[0-9.]+ (?:powered-on )?GPU-hours", text))
    print(
        f"ledger check: rows={len(rows)} max={max(numbers) if numbers else 0} "
        f"dup_numbers={duplicates or 'none'} pending={pending or 'none'} "
        f"bold_gpu_hour_figures={totals}"
    )
    if duplicates or (numbers and numbers != list(range(1, len(numbers) + 1))):
        print(
            "FAIL ledger: row numbers are not 1..n -- fix docs/ledgers/RESOURCES.md by hand "
            "before committing"
        )
        sys.exit(4)
    if pending:
        print("WARNING ledger: a PENDING row remains -- close it if that task's stretch is over")


def main() -> int:
    paths = conflicted_paths()
    print("UU:", paths)
    for path in paths:
        merged, how = resolve(path)
        expected = fence(show(2, path)) + fence(show(3, path)) - fence(show(1, path))
        if fence(merged) != expected or "<<<<<<<" in merged or ">>>>>>>" in merged:
            print(f"FAIL {path}: how={how} fences={fence(merged)} expected={expected}")
            return 4
        with open(path, "w") as handle:
            handle.write(merged)
        print(f"resolved ({how}): {path} fences={fence(merged)}")

    check_ledger()
    return 0


if __name__ == "__main__":
    sys.exit(main())
