# lint

## Purpose

Report structural/provenance problems without auto-fixing.

## Checks

- Manifest entries pointing to missing `filename` files.
- Manifest entries with `wiki_pages` paths that do not exist under `wiki/`.
- Wiki pages that have no manifest source references.
- Orphaned wiki pages not reachable by current indexing conventions.

## Rules

- Report-only by default.
- Never mutate files unless the user explicitly requests fixes.
