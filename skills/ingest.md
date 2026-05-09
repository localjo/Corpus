# ingest

## Purpose

Update `wiki/` from `raw/` using the tracked `manifest.json` provenance contract.

## Required contract

- `manifest.json` exists and is tracked in git.
- Schema:
  - `version` (number)
  - `sources` (array of objects)
  - Source object keys: `filename`, `wiki_pages`, `ingested_at`
- `filename` is vault-root-relative (for example `raw/2026-05-01-notes.md`).
- `wiki_pages` paths are relative to `wiki/` with no `wiki/` prefix.
- `ingested_at` is ISO 8601 UTC.

## Procedure

1. Identify pending sources by diffing `raw/` files against `manifest.sources[].filename`.
2. Reconcile content into existing `wiki/` pages when possible (avoid duplicates).
3. For each processed source, set `wiki_pages` to the full current derived page list (not a delta).
4. Add manifest source entry if missing.
5. Set/update `ingested_at` to current UTC timestamp.
6. Stage and commit local changes.
7. Run `git pull --rebase`.
8. Resolve safe rebase conflicts only when explicitly requested; otherwise stop and notify.
9. Push rebased commit(s).
