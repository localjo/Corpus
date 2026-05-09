# query

## Purpose

Answer questions from the curated `wiki/` first, then consult `raw/` sources when requested or needed.

## Rules

- Prefer canonical wiki pages over raw notes for normal responses.
- If source grounding is requested, use manifest reverse mapping:
  - Find source entries where `wiki_pages` contains the target page path.
  - Read corresponding `filename` source files.
- Distinguish confirmed facts from uncertain claims.
