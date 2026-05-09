#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --repo <git-url> --vault-dir <path> [--vault-label <label>] [--branch <name>]"
  exit 1
}

REPO_URL=""
VAULT_DIR=""
VAULT_LABEL=""
BRANCH="main"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT_DIR/templates/vault"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --vault-dir)
      VAULT_DIR="${2:-}"
      shift 2
      ;;
    --vault-label)
      VAULT_LABEL="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$REPO_URL" && -n "$VAULT_DIR" ]] || usage

if [[ ! -d "$VAULT_DIR/.git" ]]; then
  git clone --branch "$BRANCH" "$REPO_URL" "$VAULT_DIR"
fi

if [[ -z "$VAULT_LABEL" ]]; then
  VAULT_LABEL="$(basename "$VAULT_DIR")"
fi

mkdir -p "$VAULT_DIR/raw" "$VAULT_DIR/wiki" "$VAULT_DIR/.obsidian"

cp -f "$TEMPLATE_DIR/manifest.json" "$VAULT_DIR/manifest.json"
cp -f "$TEMPLATE_DIR/.gitignore.tmpl" "$VAULT_DIR/.gitignore"
cp -f "$TEMPLATE_DIR/wiki/index.md.tmpl" "$VAULT_DIR/wiki/index.md"

sed "s/{{VAULT_LABEL}}/$VAULT_LABEL/g" "$TEMPLATE_DIR/CLAUDE.md.tmpl" > "$VAULT_DIR/CLAUDE.md"

"$ROOT_DIR/scripts/install-skills.sh" --vault-dir "$VAULT_DIR"

git -C "$VAULT_DIR" add raw wiki manifest.json CLAUDE.md .gitignore .claude/skills

if ! git -C "$VAULT_DIR" diff --cached --quiet; then
  git -C "$VAULT_DIR" commit -m "Bootstrap vault with templates and shared skills"
fi

echo "Vault initialized at $VAULT_DIR"
echo "Next: git -C \"$VAULT_DIR\" push origin \"$BRANCH\""
