# QUEUE — one block per batch, appended at its end. The programme's log, newest last.

Each block: the batch id and when it ran, what landed, what it cost, and what the next batch is.
STATE.md is the present tense; this file is the past one. Appended, never rewritten.

## B1 — 2026-10-09, the tutorial batch
- **Landings:** `7212ad9` — T-1, the repository index `docs/README.md` (6 tables, 52 rows, all 12
  Markdown files under `docs/`), its guard `scripts/check-docs-index.sh`, and a root `README.md` link.
  Verified on a detached checkout: the guard passes, and fails as designed on both break modes (a row
  naming a path not on disk; a Markdown file under `docs/` with no row).
- **Cost:** zero against the programme's ceilings — no machine started, no vendor call, no model under
  test. One worker run, about USD 1.61 of its own tokens over 31 turns.
- **Found:** H-1, the scripts hardcode `master` while this repository's default branch is `main`
  (`land-branch.sh` exited 2; B1's landing was done by hand with the script's own semantics). H-2, kit
  documents cite kit-only paths. Both in `docs/ledgers/HARDENING.md`; the operational half of H-1 is in
  `docs/LESSONS.md`.
- **Next:** B2 — `H-1-full.md`, alone, zero spend, pending the owner's approval (STATE §6).
