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

## Commits vs VPS cron

### Cloud Claude Code

Finish ingest as **`git commit` then `git push`** when the logical batch is coherent. GitHub stays the source of truth for whole commits.

### Local / VPS tree (Syncthing)

Cron on the VPS **skips committing** automatically when Syncthing pull **temporary copies** exist (**`.syncthing.*.tmp`** or **`~syncthing~*.tmp`**, see [Syncthing “Temporary files”](https://docs.syncthing.net/users/syncing.html)), or unresolved conflict files **`*.sync-conflict-*`** / **`.sync-conflict-*`** exist under the vault.

Cron **creates `.corpus-git-in-progress`** for the duration of each run so other tooling can observe an in-flight git sync.

## Procedure

1. Identify pending sources by diffing `raw/` files against `manifest.sources[].filename`.
2. Reconcile content into existing `wiki/` pages when possible (avoid duplicates).
3. For each processed source, set `wiki_pages` to the full current derived page list (not a delta).
4. Add manifest source entry if missing.
5. Set/update `ingested_at` to current UTC timestamp.
6. **Cloud Claude:** coherent commit(s) + push to GitHub.
