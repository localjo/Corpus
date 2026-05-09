# deprecate

## Purpose

Deprecate stale wiki content while preserving provenance history.

## Procedure

1. Identify deprecated wiki page path (relative to `wiki/`).
2. Remove that page path from each source entry's `wiki_pages`.
3. If a source entry reaches zero pages, keep the source entry as a historical record.
4. Update related wiki index/navigation pages as needed.

## Rules

- Preserve `filename` and historical provenance records.
- Do not delete manifest source entries solely because `wiki_pages` becomes empty.
