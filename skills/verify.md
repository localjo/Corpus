# verify

## Purpose

Audit wiki claims against source material using manifest provenance.

## Procedure

1. Select target wiki page(s).
2. Build reverse index from manifest: page path -> source `filename` list.
3. Read source files and compare against target claims.
4. Classify results (confirmed, uncertain, mismatched, untraceable).

## Rules

- Report-only; do not silently edit wiki pages.
- Surface contradictions explicitly.
