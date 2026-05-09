#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --vault-dir <path> [--skills-dir <path>]"
  exit 1
}

VAULT_DIR=""
SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-dir)
      VAULT_DIR="${2:-}"
      shift 2
      ;;
    --skills-dir)
      SKILLS_DIR="${2:-}"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$VAULT_DIR" ]] || usage
[[ -d "$VAULT_DIR" ]] || { echo "Vault dir not found: $VAULT_DIR" >&2; exit 1; }
[[ -d "$SKILLS_DIR" ]] || { echo "Skills dir not found: $SKILLS_DIR" >&2; exit 1; }

TARGET_DIR="$VAULT_DIR/.claude/skills"
mkdir -p "$TARGET_DIR"

cp -f "$SKILLS_DIR"/*.md "$TARGET_DIR"/

if git -C "$VAULT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$VAULT_DIR" add .claude/skills
fi

echo "Installed skills to $TARGET_DIR"
